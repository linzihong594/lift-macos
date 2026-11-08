import Foundation
import Darwin

@main struct GuardTests {
    static func main() throws {
        func check(_ value: Bool) { precondition(value, "guard regression") }
        let diagnostics = try command("/bin/sh", ["-c", "printf out; printf diagnostic >&2"])
        check(String(decoding: diagnostics.data, as: UTF8.self) == "out")
        check(String(decoding: diagnostics.errors, as: UTF8.self) == "diagnostic")
        check(try command("/bin/sh", ["-c", "exit 9"]).status == 9)
        print("PASS command diagnostics isolated from plist output; failures retained")
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("DMGGuardTests-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("Source.app")
        let target = temporary.appendingPathComponent("Target.app")
        func put(_ relative: String, _ data: Data, at root: URL) throws {
            let file = root.appendingPathComponent(relative)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        func info(_ version: String) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "local.test.guard", "CFBundleExecutable": "Example", "CFBundleVersion": version], format: .xml, options: 0)
        }
        try put("Contents/Info.plist", info("2"), at: source)
        try put("Contents/MacOS/Example", Data("#!/bin/sh\nexit 0\n".utf8), at: source)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("Contents/MacOS/Example").path)
        try put("Contents/Resources/payload", Data(repeating: 0x5a, count: 131_072), at: source)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("Contents/Resources/alias").path, withDestinationPath: "payload")
        let app = AppInfo.read(source)!
        let sourceTree = try scanTree(source)
        let absent = Baseline(target, source: app)
        try fm.copyItem(at: source, to: target)
        check(absent.hasInstallEvidence(InstallFingerprint.read(target, app: app)!, source: app))
        check(try sameContents(source, target, sourceTree: sourceTree, destinationTree: scanTree(target)))
        print("PASS complete bundle, executable permissions and symlink")

        let existing = Baseline(target, source: app)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        check(!existing.hasInstallEvidence(InstallFingerprint.read(target, app: app)!, source: app))
        print("PASS already installed same version does not count as installation")

        try put("Contents/Resources/payload", Data(repeating: 0x11, count: 131_072), at: target)
        check(sameShape(sourceTree, try scanTree(target)))
        check(try !sameContents(source, target, sourceTree: sourceTree, destinationTree: scanTree(target)))
        print("PASS same-size corrupt / preallocated copy rejected")

        try fm.removeItem(at: target.appendingPathComponent("Contents/Resources/payload"))
        check(!sameShape(sourceTree, try scanTree(target)))
        print("PASS incomplete or cancelled copy rejected")

        try fm.removeItem(at: target)
        try fm.copyItem(at: source, to: target)
        try put("Contents/Info.plist", info("1"), at: target)
        let oldVersion = Baseline(target, source: app)
        try put("Contents/Info.plist", info("2"), at: target)
        check(oldVersion.hasInstallEvidence(InstallFingerprint.read(target, app: app)!, source: app))
        print("PASS different-version upgrade detected")

        let sameVersion = Baseline(target, source: app)
        try fm.moveItem(at: target, to: temporary.appendingPathComponent("Old.app"))
        try fm.copyItem(at: source, to: target)
        check(sameVersion.hasInstallEvidence(InstallFingerprint.read(target, app: app)!, source: app))
        print("PASS same-version bundle replacement detected")

        let before = try scanTree(target)
        try put("Contents/Resources/payload", Data(repeating: 0x5a, count: 131_072), at: target)
        check(before != (try scanTree(target)))
        try fm.removeItem(at: target.appendingPathComponent("Contents/Resources/alias"))
        try fm.createSymbolicLink(atPath: target.appendingPathComponent("Contents/Resources/alias").path, withDestinationPath: "elsewhere")
        check(!sameShape(sourceTree, try scanTree(target)))
        print("PASS concurrent metadata changes and wrong symlink rejected")
    }
}
