import Foundation
import Darwin

enum GuardError: Error { case unreadable(String), unsupported(String) }

func physicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

struct CommandResult {
    let status: Int32
    let data: Data
    let errors: Data
    var text: String { String(decoding: data, as: UTF8.self) + String(decoding: errors, as: UTF8.self) }
}

func command(_ executable: String, _ arguments: [String]) throws -> CommandResult {
    let process = Process()
    let pipe = Pipe()
    // Keep diagnostics out of machine-readable plist output, without risking a full stderr pipe.
    let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("dmg-eject-" + UUID().uuidString)
    guard FileManager.default.createFile(atPath: errorFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw GuardError.unreadable("temporary command diagnostics")
    }
    let errors = try FileHandle(forUpdating: errorFile)
    defer { try? errors.close(); try? FileManager.default.removeItem(at: errorFile) }
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let timeout = DispatchWorkItem { [weak process] in
        if let process, process.isRunning { process.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeout.cancel()
    try errors.seek(toOffset: 0)
    return CommandResult(status: process.terminationStatus, data: data, errors: errors.readDataToEndOfFile())
}

struct FileStamp: Equatable {
    let device: Int32
    let inode: UInt64
    let kind: UInt16
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    let bornSeconds: Int
    let bornNanos: Int
    let executable: UInt16
    let link: String?

    func sameObject(as other: FileStamp) -> Bool {
        device == other.device && inode == other.inode &&
        bornSeconds == other.bornSeconds && bornNanos == other.bornNanos
    }

    func sameShape(as other: FileStamp) -> Bool {
        kind == other.kind && executable == other.executable && link == other.link &&
        (kind != UInt16(S_IFREG) || size == other.size)
    }
}

func stamp(_ url: URL) throws -> FileStamp {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw GuardError.unreadable(url.path) }
    let kind = value.st_mode & UInt16(S_IFMT)
    guard [UInt16(S_IFREG), UInt16(S_IFDIR), UInt16(S_IFLNK)].contains(kind) else {
        throw GuardError.unsupported(url.path)
    }
    return FileStamp(device: value.st_dev, inode: value.st_ino, kind: kind,
                     size: value.st_size,
                     modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanos: value.st_mtimespec.tv_nsec,
                     changedSeconds: value.st_ctimespec.tv_sec, changedNanos: value.st_ctimespec.tv_nsec,
                     bornSeconds: value.st_birthtimespec.tv_sec, bornNanos: value.st_birthtimespec.tv_nsec,
                     executable: value.st_mode & 0o111,
                     link: kind == UInt16(S_IFLNK) ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil)
}

typealias Tree = [String: FileStamp]

func scanTree(_ root: URL) throws -> Tree {
    guard try stamp(root).kind == UInt16(S_IFDIR) else { throw GuardError.unsupported(root.path) }
    var result: Tree = [:]
    func visit(_ url: URL, _ relative: String) throws {
        let entry = try stamp(url)
        result[relative] = entry
        if entry.kind == UInt16(S_IFDIR) {
            try autoreleasepool {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    if child.lastPathComponent == ".DS_Store" { continue }
                    let path = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                    try visit(child, path)
                }
            }
        }
    }
    try visit(root, "")
    return result
}

func sameShape(_ a: Tree, _ b: Tree) -> Bool {
    a.count == b.count && a.allSatisfy { key, value in
        b[key].map { value.sameShape(as: $0) } ?? false
    }
}

/// Compare the actual file bytes, rather than just sizes, timestamps, or open handles.
func sameContents(_ source: URL, _ destination: URL, sourceTree: Tree, destinationTree: Tree) throws -> Bool {
    guard sameShape(sourceTree, destinationTree) else { return false }
    // Reuse two fixed buffers. FileHandle's autoreleased NSData chunks previously
    // accumulated while processing large bundles on a long-lived worker queue.
    let capacity = 128 * 1024
    let leftBuffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    let rightBuffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    defer { leftBuffer.deallocate(); rightBuffer.deallocate() }
    func readChunk(_ fd: Int32, into buffer: UnsafeMutableRawPointer) throws -> Int {
        var total = 0
        while total < capacity {
            let count = Darwin.read(fd, buffer.advanced(by: total), capacity - total)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw GuardError.unreadable("file comparison")
            }
            total += count
        }
        return total
    }
    for path in sourceTree.keys.sorted() where sourceTree[path]!.kind == UInt16(S_IFREG) {
        let left = open(source.appendingPathComponent(path).path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard left >= 0 else { throw GuardError.unreadable(path) }
        defer { close(left) }
        let right = open(destination.appendingPathComponent(path).path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard right >= 0 else { throw GuardError.unreadable(path) }
        defer { close(right) }
        while true {
            let a = try readChunk(left, into: leftBuffer)
            let b = try readChunk(right, into: rightBuffer)
            if a != b || memcmp(leftBuffer, rightBuffer, a) != 0 { return false }
            if a == 0 { break }
        }
    }
    // Reject concurrent changes during verification, including a same-size rewrite.
    return try scanTree(destination) == destinationTree
}

struct AppInfo: Equatable {
    let identifier: String
    let version: String
    let executable: String

    static func read(_ app: URL) -> AppInfo? {
        guard let root = try? stamp(app), root.kind == UInt16(S_IFDIR),
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty,
              let executable = plist["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), executable != ".", executable != ".." else { return nil }
        let version = "\(plist["CFBundleShortVersionString"] ?? "")|\(plist["CFBundleVersion"] ?? "")"
        guard let main = try? stamp(app.appendingPathComponent("Contents/MacOS/" + executable)),
              main.kind == UInt16(S_IFREG) || main.kind == UInt16(S_IFLNK) else { return nil }
        return AppInfo(identifier: id, version: version, executable: executable)
    }
}

struct InstallFingerprint: Equatable {
    let root: FileStamp
    let info: FileStamp?
    let executable: FileStamp?

    static func read(_ url: URL, app: AppInfo) -> InstallFingerprint? {
        guard let root = try? stamp(url), root.kind == UInt16(S_IFDIR) else { return nil }
        return InstallFingerprint(root: root,
                                  info: try? stamp(url.appendingPathComponent("Contents/Info.plist")),
                                  executable: try? stamp(url.appendingPathComponent("Contents/MacOS/" + app.executable)))
    }
}

struct Baseline {
    let fingerprint: InstallFingerprint?
    let app: AppInfo?

    init(_ url: URL, source: AppInfo) {
        fingerprint = InstallFingerprint.read(url, app: source)
        app = AppInfo.read(url)
    }

    func hasInstallEvidence(_ current: InstallFingerprint, source: AppInfo) -> Bool {
        guard let before = fingerprint else { return true }
        // An already installed identical version must not eject a freshly opened DMG.
        // For that case require a replacement of the bundle, not a metadata touch.
        if app == source { return !before.root.sameObject(as: current.root) }
        return !before.root.sameObject(as: current.root) ||
               before.info != current.info || before.executable != current.executable
    }
}

struct MountedImage: Equatable {
    let image: String
    let device: String
    let mount: String
    let volume: FileStamp
    var key: String { image + "|" + device + "|" + mount }

    static func catalog(_ data: Data, imagePrefix: String? = nil) throws -> [MountedImage] {
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = info["images"] as? [[String: Any]] else { throw GuardError.unsupported("disk image catalog") }
        var result: [MountedImage] = []
        for item in images {
            guard item["writeable"] as? Bool == false,
                  item["image-encrypted"] as? Bool != true,
                  let path = item["image-path"] as? String,
                  URL(fileURLWithPath: path).pathExtension.lowercased() == "dmg",
                  imagePrefix.map({ physicalPath(path).hasPrefix($0 + "/") }) ?? true,
                  let entities = item["system-entities"] as? [[String: Any]] else { continue }
            let mounted = entities.compactMap { $0["mount-point"] as? String }
            // Multi-volume images may contain another installer or data volume.
            guard mounted.count == 1, let mount = mounted.first, mount.hasPrefix("/Volumes/"),
                  let device = entities.compactMap({ $0["dev-entry"] as? String }).first(where: {
                      $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil
                  }),
                  let volume = try? stamp(URL(fileURLWithPath: mount)),
                  (try? URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true else { continue }
            result.append(MountedImage(image: path, device: device, mount: mount, volume: volume))
        }
        return result
    }

    static func discover(imagePrefix: String? = nil) throws -> [MountedImage] {
        let result = try command("/usr/bin/hdiutil", ["info", "-plist"])
        guard result.status == 0 else { throw GuardError.unreadable("hdiutil info") }
        return try catalog(result.data, imagePrefix: imagePrefix)
    }

    func stillMatches(_ current: MountedImage) -> Bool {
        key == current.key && volume.sameObject(as: current.volume)
    }
}

func installerApp(on image: MountedImage) -> (URL, AppInfo)? {
    let root = URL(fileURLWithPath: image.mount)
    guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil),
          !children.contains(where: { ["pkg", "mpkg"].contains($0.pathExtension.lowercased()) }) else { return nil }
    let apps = children.filter { $0.pathExtension.lowercased() == "app" && (try? stamp($0).kind) == UInt16(S_IFDIR) }
    guard apps.count == 1, let app = apps.first, let info = AppInfo.read(app) else { return nil }
    return (app, info)
}
