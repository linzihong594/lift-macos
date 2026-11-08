import Foundation
import Darwin

@main struct MemoryBench {
    static func usage() -> [String: UInt64] {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        precondition(result == 0)
        return ["current": info.ri_phys_footprint, "peak": info.ri_lifetime_max_phys_footprint]
    }

    static func main() {
        let args = CommandLine.arguments
        let source = URL(fileURLWithPath: args[1])
        let destination = URL(fileURLWithPath: args[2])
        let optimized = args[3] == "pooled"
        let queue = DispatchQueue(label: "Lift.memory-regression", qos: .utility,
                                  autoreleaseFrequency: optimized ? .workItem : .never)
        queue.async {
            let before = usage()["current"]!
            let started = Date()
            for _ in 0..<3 {
                let work = {
                    let a = try! scanTree(source)
                    let b = try! scanTree(destination)
                    precondition(try! sameContents(source, destination, sourceTree: a, destinationTree: b))
                }
                if optimized {
                    autoreleasepool(invoking: work)
                    _ = malloc_zone_pressure_relief(nil, 0)
                } else { work() }
            }
            let after = usage()
            let report: [String: Any] = ["before": before, "after": after["current"]!, "peak": after["peak"]!,
                                        "seconds": Date().timeIntervalSince(started)]
            let json = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(decoding: json, as: UTF8.self))
            exit(0)
        }
        dispatchMain()
    }
}
