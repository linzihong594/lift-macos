import Foundation
import DiskArbitration
import CoreServices
import Darwin

final class Logger {
    let url: URL
    init(_ url: URL) { self.url = url }
    func write(_ message: String) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber, size.intValue > 1_048_576 {
            try? fm.removeItem(at: url.appendingPathExtension("1"))
            try? fm.moveItem(at: url, to: url.appendingPathExtension("1"))
        }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        line.withCString { _ = Darwin.write(fd, $0, strlen($0)) }
        close(fd)
    }
}

final class Destination {
    let url: URL
    let baseline: Baseline
    var lastEvent = Date()
    var lastFingerprint: InstallFingerprint?
    var snapshot: Tree?
    var stableSince = Date()
    var verified: Tree?
    var verifiedAt = Date.distantPast
    var retryAt = Date.distantPast
    init(_ url: URL, info: AppInfo) { self.url = url; baseline = Baseline(url, source: info) }
    func changed() { lastEvent = Date(); snapshot = nil; verified = nil; retryAt = .distantPast }
}

final class Candidate {
    let image: MountedImage
    let source: URL
    let info: AppInfo
    let destinations: [Destination]
    var sourceTree: Tree?
    init(_ image: MountedImage, source: URL, info: AppInfo, roots: [URL]) {
        self.image = image; self.source = source; self.info = info
        destinations = roots.map { Destination($0.appendingPathComponent(source.lastPathComponent), info: info) }
    }
}

final class Agent {
    let queue = DispatchQueue(label: "local.suis.dmg-auto-eject", qos: .utility, autoreleaseFrequency: .workItem)
    let roots: [URL]
    let logger: Logger
    let testRoot: String?
    let quiet: TimeInterval
    let settle: TimeInterval
    let retry: TimeInterval
    var candidates: [String: Candidate] = [:]
    var handled = Set<String>()
    var timer: DispatchSourceTimer?
    var volumeWatcher: DispatchSourceFileSystemObject?
    var applicationWatchers: [DispatchSourceFileSystemObject] = []
    var stream: FSEventStreamRef?
    var diskSession: DASession?
    var rescanPending = false
    var idleDeadline = Date.distantPast
    var needsMemoryRelief = false
    let started = Date()
    var totalCompleted: Int
    var recentCompletions: [LiftCompletion]
    var savedState: Data?

    init(roots: [URL], logger: Logger, testRoot: String?) {
        self.roots = roots; self.logger = logger; self.testRoot = testRoot
        quiet = 0.35
        settle = 0.15
        retry = 2
        (totalCompleted, recentCompletions) = LiftState.previousCompletions(in: logger.url.deletingLastPathComponent())
        let directory = logger.url.deletingLastPathComponent()
        recentCompletions = recentCompletions.map { item in
            guard item.cachedIconURL(in: directory) == nil,
                  let app = item.installedURL(in: roots), let file = LiftIconStore.capture(from: app, in: directory) else { return item }
            return LiftCompletion(app: item.app, date: item.date, path: item.path, iconFile: file)
        }
        LiftIconStore.prune(keeping: recentCompletions, in: directory)
    }

    func start() {
        queue.async { self.performWork { self.watchDisks(); self.watchVolumes(); self.watchApplications(); self.reconcile() } }
    }

    func performWork(_ work: () -> Void) {
        autoreleasepool(invoking: work)
        if needsMemoryRelief {
            needsMemoryRelief = false
            // Return this process's unused allocator pages after a completed job.
            _ = malloc_zone_pressure_relief(nil, 0)
        }
    }

    func watchDisks() {
        guard let session = DASessionCreate(nil) else { logger.write("ERROR cannot observe disk events"); exit(1) }
        diskSession = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        let changed: DADiskAppearedCallback = { _, context in
            guard let context else { return }
            Unmanaged<Agent>.fromOpaque(context).takeUnretainedValue().scheduleRescan()
        }
        DARegisterDiskAppearedCallback(session, nil, changed, context)
        DARegisterDiskDisappearedCallback(session, nil, changed, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, [kDADiskDescriptionVolumePathKey] as CFArray, { _, _, context in
            guard let context else { return }
            Unmanaged<Agent>.fromOpaque(context).takeUnretainedValue().scheduleRescan()
        }, context)
        DASessionSetDispatchQueue(session, queue)
    }

    func watchVolumes() {
        let fd = open("/Volumes", O_EVTONLY)
        guard fd >= 0 else { logger.write("ERROR cannot monitor /Volumes"); exit(1) }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: queue)
        watcher.setEventHandler { [weak self] in self?.scheduleRescan() }
        watcher.setCancelHandler { close(fd) }
        volumeWatcher = watcher
        watcher.resume()
    }

    func watchApplications() {
        for root in roots {
            let fd = open(root.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            watcher.setEventHandler { [weak self] in
                guard let self else { return }
                for candidate in self.candidates.values {
                    for destination in candidate.destinations where destination.url.deletingLastPathComponent() == root {
                        destination.changed()
                    }
                }
                self.wakeTimer()
            }
            watcher.setCancelHandler { close(fd) }
            applicationWatchers.append(watcher)
            watcher.resume()
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let agent = Unmanaged<Agent>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as! [String]
            let dropped = (0..<count).contains {
                flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0
            }
            for candidate in agent.candidates.values {
                for destination in candidate.destinations {
                    if dropped || changed.contains(where: { $0 == destination.url.path || $0.hasPrefix(destination.url.path + "/") }) {
                        destination.changed()
                        agent.wakeTimer()
                    }
                }
            }
        }
        let watched = roots.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
        stream = FSEventStreamCreate(nil, callback, &context, watched as CFArray,
                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
                                    FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { logger.write("ERROR cannot create file event stream"); exit(1) }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { logger.write("ERROR cannot monitor application folders"); exit(1) }
    }

    func scheduleRescan() {
        guard !rescanPending else { return }
        rescanPending = true
        queue.asyncAfter(deadline: .now() + 0.2) { self.performWork { self.rescanPending = false; self.reconcile() } }
    }

    func reconcile() {
        do {
            let images = try MountedImage.discover(imagePrefix: testRoot)
            let keys = Set(images.map(\.key))
            let oldCount = candidates.count
            candidates = candidates.filter { keys.contains($0.key) }
            if candidates.count < oldCount { needsMemoryRelief = true }
            handled.formIntersection(keys)
            var added = false
            for image in images where candidates[image.key] == nil && !handled.contains(image.key) {
                guard let (source, info) = installerApp(on: image) else { handled.insert(image.key); continue }
                candidates[image.key] = Candidate(image, source: source, info: info, roots: roots)
                added = true
                logger.write("WATCH \(source.lastPathComponent) on \(image.mount)")
            }
            if candidates.isEmpty { timer?.cancel(); timer = nil }
            else if added { wakeTimer() }
            saveState()
        } catch { logger.write("WAIT cannot read image catalog: \(error)") }
    }

    func wakeTimer() {
        guard !candidates.isEmpty else { return }
        idleDeadline = Date().addingTimeInterval(60)
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.2, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.performWork { self?.tick() } }
        self.timer = timer
        timer.resume()
    }

    func tick() {
        for (key, candidate) in Array(candidates) {
            guard let currentVolume = try? stamp(URL(fileURLWithPath: candidate.image.mount)), candidate.image.volume.sameObject(as: currentVolume) else {
                candidates.removeValue(forKey: key); scheduleRescan(); continue
            }
            for destination in candidate.destinations {
                if evaluate(candidate, destination) { break }
            }
        }
        let verified = candidates.values.contains { $0.destinations.contains { $0.verified != nil } }
        if candidates.isEmpty || (Date() > idleDeadline && !verified) {
            timer?.cancel(); timer = nil
            for candidate in candidates.values {
                candidate.sourceTree = nil
                for destination in candidate.destinations { destination.snapshot = nil; destination.verified = nil }
            }
            needsMemoryRelief = true
        }
        saveState()
    }

    func evaluate(_ candidate: Candidate, _ destination: Destination) -> Bool {
        let now = Date()
        guard let fingerprint = InstallFingerprint.read(destination.url, app: candidate.info),
              destination.baseline.hasInstallEvidence(fingerprint, source: candidate.info),
              AppInfo.read(destination.url) == candidate.info else { return false }
        if destination.lastFingerprint != fingerprint {
            destination.lastFingerprint = fingerprint
            destination.changed()
            return false
        }
        guard now.timeIntervalSince(destination.lastEvent) >= quiet, now >= destination.retryAt else { return false }
        do {
            if candidate.sourceTree == nil { candidate.sourceTree = try scanTree(candidate.source) }
            let sourceTree = candidate.sourceTree!
            let snapshot = try scanTree(destination.url)
            guard sameShape(sourceTree, snapshot) else { destination.snapshot = nil; destination.verified = nil; return false }
            if destination.snapshot != snapshot {
                destination.snapshot = snapshot; destination.stableSince = now; destination.verified = nil
                return false
            }
            guard now.timeIntervalSince(destination.stableSince) >= settle else { return false }
            if destination.verified == snapshot {
                guard now.timeIntervalSince(destination.verifiedAt) >= settle else { return false }
                // Resolve the device again: a /dev/diskN value can be reused after an unmount.
                let current = try MountedImage.discover(imagePrefix: testRoot)
                guard current.contains(where: candidate.image.stillMatches) else { finish(candidate.image.key); return true }
                let result = try command("/usr/sbin/diskutil", ["eject", candidate.image.device])
                if result.status == 0 {
                    logger.write("EJECTED \(candidate.image.mount); verified \(destination.url.path)")
                    finish(candidate.image.key, completed: destination.url)
                    return true
                }
                destination.retryAt = now.addingTimeInterval(retry)
                logger.write("BUSY/DEFER \(candidate.image.mount): \(result.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))")
            } else if try sameContents(candidate.source, destination.url, sourceTree: sourceTree, destinationTree: snapshot) {
                destination.verified = snapshot; destination.verifiedAt = Date()
                logger.write("VERIFIED \(destination.url.path); waiting for final stability check")
            } else {
                destination.retryAt = now.addingTimeInterval(retry)
                logger.write("WAIT content incomplete or different: \(destination.url.path)")
            }
        } catch {
            destination.verified = nil; destination.retryAt = now.addingTimeInterval(retry)
            logger.write("WAIT cannot verify \(destination.url.path): \(error)")
        }
        return false
    }

    func finish(_ key: String, completed: URL? = nil) {
        candidates.removeValue(forKey: key); handled.insert(key)
        if let completed {
            totalCompleted += 1
            let directory = logger.url.deletingLastPathComponent()
            let iconFile = LiftIconStore.capture(from: completed, in: directory)
            recentCompletions.insert(LiftCompletion(app: completed.deletingPathExtension().lastPathComponent, date: Date(), path: completed.path, iconFile: iconFile), at: 0)
            recentCompletions = Array(recentCompletions.prefix(4))
            LiftIconStore.prune(keeping: recentCompletions, in: directory)
        }
        needsMemoryRelief = true
    }

    func saveState() {
        let volumes = candidates.values.map {
            LiftVolume(app: $0.source.deletingPathExtension().lastPathComponent,
                       preparing: $0.destinations.contains { $0.verified != nil })
        }.sorted { $0.app < $1.app }
        let state = LiftState(pid: getpid(), started: started, monitoring: volumes, completed: recentCompletions, total: totalCompleted)
        guard let data = try? state.data(), data != savedState else { return }
        if (try? data.write(to: logger.url.deletingLastPathComponent().appendingPathComponent("state.json"), options: .atomic)) != nil {
            savedState = data
        }
    }
}

let fm = FileManager.default
let args = CommandLine.arguments
var testRoot: String?
if args.count == 3 && args[1] == "--test-root" {
    let root = physicalPath(args[2])
    guard root.hasPrefix("/private/tmp/") else { fputs("Test root must be inside /private/tmp.\n", stderr); exit(2) }
    testRoot = root
} else if args.count != 1 { fputs("Usage: dmg-auto-eject [--test-root /private/tmp/...]\n", stderr); exit(2) }

let support = testRoot.map { URL(fileURLWithPath: $0) } ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DMG Auto Eject")
try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let lock = open(support.appendingPathComponent("agent.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
let roots = testRoot.map { [URL(fileURLWithPath: $0).appendingPathComponent("Applications")] } ??
    [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
let logger = Logger(support.appendingPathComponent("agent.log"))
if testRoot == nil && Bundle.main.bundleIdentifier == LiftPaths.label {
    autoreleasepool {
        let result = LiftRegisterBackgroundIdentity()
        if result != 0 { logger.write("WARN background application identity: \(result)") }
    }
    _ = malloc_zone_pressure_relief(nil, 0)
}
logger.write("START watching normal drag-to-install DMGs; no force eject, no installer deletion")
let agent = Agent(roots: roots, logger: logger, testRoot: testRoot)
agent.start()
RunLoop.main.run()
