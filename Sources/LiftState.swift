import Foundation
import Darwin

enum LiftPaths {
    static let label = "local.suis.dmg-auto-eject"
    static var support: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DMG Auto Eject") }
    static var launchAgent: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/" + label + ".plist") }
    static var service: String { "gui/\(getuid())/\(label)" }
}

struct LiftCompletion: Codable, Identifiable {
    var id: String { app + date.description }
    let app: String
    let date: Date
    let path: String?
    let iconFile: String?

    init(app: String, date: Date, path: String? = nil, iconFile: String? = nil) {
        self.app = app; self.date = date; self.path = path; self.iconFile = iconFile
    }

    func cachedIconURL(in directory: URL = LiftPaths.support) -> URL? {
        guard let iconFile, iconFile == (iconFile as NSString).lastPathComponent else { return nil }
        let url = directory.appendingPathComponent("Icons").appendingPathComponent(iconFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func installedURL(in roots: [URL] = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]) -> URL? {
        let candidates = path.map { [URL(fileURLWithPath: $0)] } ?? []
        return (candidates + roots.map { $0.appendingPathComponent(app + ".app") }).first {
            var directory: ObjCBool = false
            return $0.pathExtension.lowercased() == "app" && FileManager.default.fileExists(atPath: $0.path, isDirectory: &directory) && directory.boolValue
        }
    }
}

/// Copy an existing icon asset without loading any image/UI framework in the agent.
enum LiftIconStore {
    static func capture(from app: URL, in directory: URL) -> String? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = info["CFBundleIconFile"] as? String, !name.isEmpty,
              name == (name as NSString).lastPathComponent else { return nil }
        let resources = app.appendingPathComponent("Contents/Resources")
        let candidates = [resources.appendingPathComponent(name), resources.appendingPathComponent(name + ".icns")]
        guard let source = candidates.first(where: {
            guard ["icns", "png", "tiff"].contains($0.pathExtension.lowercased()),
                  let attributes = try? fm.attributesOfItem(atPath: $0.path) else { return false }
            return attributes[.type] as? FileAttributeType == .typeRegular &&
                ((attributes[.size] as? NSNumber)?.intValue ?? .max) <= 8_388_608
        }) else { return nil }
        let icons = directory.appendingPathComponent("Icons")
        let filename = UUID().uuidString + "." + source.pathExtension
        do {
            try fm.createDirectory(at: icons, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: source, to: icons.appendingPathComponent(filename))
            return filename
        } catch { return nil }
    }

    static func prune(keeping records: [LiftCompletion], in directory: URL) {
        let fm = FileManager.default
        let used = Set(records.compactMap(\.iconFile))
        guard let files = try? fm.contentsOfDirectory(at: directory.appendingPathComponent("Icons"), includingPropertiesForKeys: nil) else { return }
        for file in files where UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil && !used.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
        }
    }
}

struct LiftVolume: Codable, Identifiable {
    var id: String { app }
    let app: String
    let preparing: Bool
}

struct LiftState: Codable {
    let pid: Int32
    let started: Date
    let monitoring: [LiftVolume]
    let completed: [LiftCompletion]
    let total: Int

    static func load(from directory: URL) -> LiftState? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LiftState.self, from: data)
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func previousCompletions(in directory: URL) -> (Int, [LiftCompletion]) {
        if let state = load(from: directory) { return (state.total, state.completed) }
        var history: [LiftCompletion] = []
        let dates = ISO8601DateFormatter()
        for file in ["agent.log.1", "agent.log"] {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains(" EJECTED ") {
                guard let range = line.range(of: "; verified "),
                      let date = dates.date(from: String(line.prefix(20))) else { continue }
                let path = String(line[range.upperBound...])
                let app = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                history.append(LiftCompletion(app: app, date: date, path: path))
            }
        }
        return (history.count, Array(history.suffix(4).reversed()))
    }
}
