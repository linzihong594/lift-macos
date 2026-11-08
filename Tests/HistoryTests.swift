import Foundation

@main struct HistoryTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Lift-history-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let oldData = Data(#"{"app":"Example","date":"2026-11-08T06:02:31Z"}"#.utf8)
        let old = try decoder.decode(LiftCompletion.self, from: oldData)
        precondition(old.path == nil && old.app == "Example")
        let standard = root.appendingPathComponent("Example.app")
        try fm.createDirectory(at: standard, withIntermediateDirectories: true)
        precondition(old.installedURL(in: [root])?.path == standard.path)
        print("PASS legacy history resolves installed app without losing old records")

        let custom = root.appendingPathComponent("DifferentName.app")
        try fm.createDirectory(at: custom, withIntermediateDirectories: true)
        let stored = LiftCompletion(app: "Display Name", date: old.date, path: custom.path)
        precondition(stored.installedURL(in: [])?.path == custom.path)
        let state = LiftState(pid: 1, started: old.date, monitoring: [], completed: [stored], total: 1)
        let roundtrip = try decoder.decode(LiftState.self, from: state.data())
        precondition(roundtrip.completed.first?.path == custom.path)
        print("PASS exact installation path survives history save and reload")

        try fm.removeItem(at: standard)
        precondition(old.installedURL(in: [root]) == nil)
        try Data().write(to: standard)
        precondition(old.installedURL(in: [root]) == nil)
        print("PASS removed applications and non-app files use the fallback icon")

        let resources = custom.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIconFile": "AppIcon"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: custom.appendingPathComponent("Contents/Info.plist"))
        let bytes = Data("opaque icon asset".utf8)
        try bytes.write(to: resources.appendingPathComponent("AppIcon.icns"))
        let saved = LiftIconStore.capture(from: custom, in: root)!
        let persisted = LiftCompletion(app: "Display Name", date: old.date, path: custom.path, iconFile: saved)
        try fm.removeItem(at: custom)
        precondition(persisted.installedURL(in: []) == nil)
        let cached = try Data(contentsOf: persisted.cachedIconURL(in: root)!)
        precondition(cached == bytes)
        LiftIconStore.prune(keeping: [persisted], in: root)
        precondition(persisted.cachedIconURL(in: root) != nil)
        LiftIconStore.prune(keeping: [], in: root)
        precondition(persisted.cachedIconURL(in: root) == nil)
        print("PASS saved icon survives uninstall and is removed when history expires")
    }
}
