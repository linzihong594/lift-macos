import Foundation
import ServiceManagement
import Darwin

enum ServiceControl {
    static var executable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/轻退") }
    static var service: SMAppService { .agent(plistName: LiftPaths.agentPlistName) }
    static var requiresApproval: Bool { service.status == .requiresApproval }
    static var statusName: String {
        switch service.status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    static func running(_ state: LiftState?) -> Bool {
        guard let state, state.pid > 1, kill(state.pid, 0) == 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBytes { proc_pidpath(state.pid, $0.baseAddress, UInt32($0.count)) }
        return count > 0 && String(cString: buffer) == executable.path
    }

    static func setEnabled(_ enabled: Bool) throws {
        let item = service
        if enabled {
            if item.status != .enabled && item.status != .requiresApproval { try item.register() }
            guard item.status == .enabled else {
                throw NSError(domain: "Lift", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "请在“系统设置 → 通用 → 登录项与扩展”中允许“轻退”后台运行，再开启自动弹出。"])
            }
        } else if item.status != .notRegistered && item.status != .notFound {
            try item.unregister()
        }
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
