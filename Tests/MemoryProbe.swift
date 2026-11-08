import Foundation
import Darwin

@main struct MemoryProbe {
    static func main() throws {
        let pid = Int32(CommandLine.arguments[1])!
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        guard result == 0 else { exit(1) }
        let data = try JSONSerialization.data(withJSONObject: ["pid": UInt64(pid), "current": info.ri_phys_footprint,
                                                               "peak": info.ri_lifetime_max_phys_footprint], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
