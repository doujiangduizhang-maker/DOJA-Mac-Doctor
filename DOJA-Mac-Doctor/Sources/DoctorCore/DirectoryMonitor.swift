import Foundation
import Darwin
import CoreServices

/// Event-driven metadata monitoring, independent of the foreground scan.
/// Public methods never wait for a probe; observations are a lock-protected copy.
public final class DirectoryMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.doja.macdoctor.directory-monitor", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var suspended = false
    private var refreshQueued = false
    private var activeControl: ScanControl?
    private var published: [DirectoryObservation] = []

    // The following properties are confined to queue.
    private var focuses: [MonitorFocus] = []
    private var dirty = Set<String>()
    private var nextEligible: [String: TimeInterval] = [:]
    private var nextCycleAt: TimeInterval = 0
    private var cursor = 0
    private var timer: DispatchSourceTimer?
    private var timerEpoch: UInt64 = 0
    private var stream: FSEventStreamRef?
    private var eventContext: MonitorEventContext?
    private var streamUnavailable = false
    private var restartQueued = false
    private let cooldown: TimeInterval = 300
    private let cycleBudget: TimeInterval = 5
    private let perDirectoryFileLimit = 20_000

    public init() { queue.setSpecific(key: queueKey, value: 1) }

    deinit {
        lock.lock()
        activeControl?.cancel()
        lock.unlock()
        if DispatchQueue.getSpecific(key: queueKey) == 1 { tearDown() }
        else { queue.sync { tearDown() } }
    }

    /// Paths are already authorized by the application. This method neither
    /// discovers new scopes nor asks macOS for additional access.
    public func start(paths: [String], baseline: ScanResult? = nil) {
        let unique = monitorPaths(paths)
        lock.lock()
        generation &+= 1
        let token = generation
        let oldControl = activeControl
        activeControl = nil
        refreshQueued = false
        published = unique.map { path in
            // Searching a large ScanResult is background work too.
            return DirectoryObservation(path: path, logicalBytes: nil,
                                        allocatedBytes: nil, observedAt: Date(),
                                        isComplete: false, reason: "正在建立目录通知；尚未确认当前状态")
        }
        lock.unlock()
        oldControl?.cancel()
        queue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            self.tearDown()
            self.configure(paths: unique, baseline: baseline, token: token)
        }
    }

    public func observations() -> [DirectoryObservation] {
        lock.lock()
        let result = published
        lock.unlock()
        let now = Date()
        // Old values remain visible, but cannot be used as fresh evidence.
        return result.map { value in
            let age = now.timeIntervalSince(value.observedAt)
            guard value.isComplete, age > 1_800 || age < 0 else { return value }
            return DirectoryObservation(path: value.path, logicalBytes: value.logicalBytes,
                                        allocatedBytes: value.allocatedBytes, observedAt: value.observedAt,
                                        isComplete: false, reason: age < 0
                                            ? "系统时间变化；保留历史数值，当前状态待核对"
                                            : "上次完整核对超过 30 分钟；保留历史数值，当前变化待确认")
        }
    }

    public func stop() {
        lock.lock()
        generation &+= 1
        let token = generation
        let control = activeControl
        activeControl = nil
        refreshQueued = false
        published = published.map {
            DirectoryObservation(path: $0.path, logicalBytes: $0.logicalBytes, allocatedBytes: $0.allocatedBytes,
                                 observedAt: $0.observedAt, isComplete: false, reason: "目录监控已停止；保留历史数值")
        }
        lock.unlock()
        control?.cancel()
        queue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            self.tearDown()
        }
    }

    /// An anomaly asks for focused verification, not an unrestricted new scan.
    /// Repeated calls coalesce, and the same cooldown and work budget still apply.
    public func requestRefresh() {
        lock.lock()
        guard !refreshQueued else { lock.unlock(); return }
        refreshQueued = true
        let token = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.generation == token
            if current { self.refreshQueued = false }
            self.lock.unlock()
            guard current else { return }
            self.markAllPending(reason: "请求有限核对；目录变化与异常原因仍待确认", token: token)
            self.schedule(token: token)
        }
    }

    public func setSuspended(_ value: Bool) {
        lock.lock()
        let changed = suspended != value
        suspended = value
        let token = generation
        let control = value ? activeControl : nil
        lock.unlock()
        control?.cancel()
        guard changed else { return }
        queue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            self.cancelTimer()
            self.markAllPending(reason: value ? "扫描或处理期间暂停目录核对；保留历史数值" : "暂停后目录状态待核对", token: token)
            if !value { self.schedule(token: token) }
        }
    }

    private func configure(paths: [String], baseline: ScanResult?, token: UInt64) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let now = Date()
        for path in paths {
            let record = baselineRecord(path: path, scan: baseline)
            let observedAt = record == nil ? now : (baseline?.finishedAt ?? now)
            do {
                let identity = try monitorIdentity(path)
                focuses.append(MonitorFocus(path: path, identity: identity))
                // Foreground scans deduplicate hard-link blocks across all
                // selected roots; probes deduplicate within this focus only.
                // A foreground number is reference data, not a comparable
                // monitoring baseline. Establish the latter with a bounded probe.
                dirty.insert(path)
                nextEligible[path] = uptime
                publish(DirectoryObservation(path: path, logicalBytes: record?.logicalBytes,
                                             allocatedBytes: record?.allocatedBytes, observedAt: observedAt,
                                             isComplete: false, reason: record == nil
                                                ? "缺少完整基线，等待一次有限目录核对"
                                                : "参考最近完整扫描；等待同一范围独立核对，暂不用于增长判断"), token: token)
            } catch {
                // Unreadable/linked/missing paths do not become a zero-sized
                // focus and are not sent to FSEvents for implicit access.
                publish(DirectoryObservation(path: path, logicalBytes: record?.logicalBytes,
                                             allocatedBytes: record?.allocatedBytes, observedAt: observedAt,
                                             isComplete: false, reason: error.localizedDescription), token: token)
            }
        }
        installStream(token: token)
        schedule(token: token)
    }

    private func installStream(token: UInt64) {
        guard isCurrent(token), !focuses.isEmpty else { return }
        let valid = focuses.filter { focus in
            guard let identity = try? monitorIdentity(focus.path) else { return false }
            return identity.sameObject(as: focus.identity)
        }
        guard !valid.isEmpty else {
            streamUnavailable = true
            markAllPending(reason: "目录路径或访问权限变化，系统通知不可用，等待有限核对", token: token)
            return
        }
        let box = MonitorEventContext(monitor: self, generation: token)
        eventContext = box
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                          retain: { pointer in
                                              guard let pointer else { return nil }
                                              _ = Unmanaged<MonitorEventContext>.fromOpaque(pointer).retain()
                                              return pointer
                                          }, release: { pointer in
                                              guard let pointer else { return }
                                              Unmanaged<MonitorEventContext>.fromOpaque(pointer).release()
                                          }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, directoryMonitorCallback, &context,
                                               valid.map(\.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5, flags) else {
            streamUnavailable = true
            eventContext = nil
            markAllPending(reason: "系统目录通知未启动，将按同一预算进行有限核对", token: token)
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            tearDownStream()
            streamUnavailable = true
            markAllPending(reason: "系统目录通知不可用，将按同一预算进行有限核对", token: token)
            return
        }
        streamUnavailable = false
    }

    fileprivate func received(paths: [String?], flags: [FSEventStreamEventFlags], token: UInt64, truncated: Bool) {
        guard isCurrent(token) else { return }
        let disruptive = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
                                kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged |
                                kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        var restart = false
        if truncated {
            markAllPending(reason: "目录事件数量过多，全部重点目录待完整核对；预算仍受限制", token: token)
        }
        for index in paths.indices {
            let flag = flags[index]
            if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            if flag & disruptive != 0 {
                markAllPending(reason: "目录事件丢失、路径或磁盘状态变化；原因待确认，等待有限核对", token: token)
                if flag & UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 { restart = true }
                continue
            }
            guard let eventPath = paths[index] else {
                markAllPending(reason: "目录事件路径无法表示，等待核对", token: token)
                continue
            }
            for focus in focuses where monitorEventOverlaps(eventPath, focus.path) {
                markPending(focus.path, reason: "系统报告目录有变化，大小待核对；保留上次完整数值", token: token)
            }
        }
        if restart, !restartQueued {
            restartQueued = true
            // Do not tear down a stream while its own C callback is executing.
            queue.async { [weak self] in
                guard let self, self.isCurrent(token) else { return }
                self.restartQueued = false
                self.tearDownStream()
                self.installStream(token: token)
                self.schedule(token: token)
            }
        }
        schedule(token: token)
    }

    private func markAllPending(reason: String, token: UInt64) {
        for focus in focuses { markPending(focus.path, reason: reason, token: token) }
    }

    private func markPending(_ path: String, reason: String, token: UInt64) {
        dirty.insert(path)
        lock.lock()
        if generation == token, let index = published.firstIndex(where: { $0.path == path }) {
            let old = published[index]
            published[index] = DirectoryObservation(path: old.path, logicalBytes: old.logicalBytes,
                                                   allocatedBytes: old.allocatedBytes, observedAt: old.observedAt,
                                                   isComplete: false, reason: reason)
        }
        lock.unlock()
    }

    private func schedule(token: UInt64) {
        cancelTimer()
        guard isCurrent(token), !isSuspended(), !dirty.isEmpty else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let earliest = dirty.map { nextEligible[$0] ?? uptime }.min() ?? uptime
        let delay = max(0, max(earliest, nextCycleAt) - uptime)
        let scheduled = DispatchSource.makeTimerSource(queue: queue)
        let epoch = timerEpoch
        scheduled.schedule(deadline: .now() + delay, leeway: .seconds(1))
        scheduled.setEventHandler { [weak self] in
            guard let self, self.timerEpoch == epoch else { return }
            self.probeCycle(token: token)
        }
        timer = scheduled
        scheduled.resume()
    }

    private func probeCycle(token: UInt64) {
        cancelTimer()
        guard isCurrent(token), !isSuspended(), !focuses.isEmpty else { return }
        let begun = ProcessInfo.processInfo.systemUptime
        guard begun >= nextCycleAt else { schedule(token: token); return }
        nextCycleAt = begun + cooldown
        let deadline = begun + cycleBudget
        let count = focuses.count
        let ordered = (0..<count).map { focuses[(cursor + $0) % count] }
        var visited = 0
        for focus in ordered {
            guard isCurrent(token), !isSuspended() else { break }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            guard dirty.contains(focus.path), (nextEligible[focus.path] ?? 0) <= ProcessInfo.processInfo.systemUptime else { continue }
            visited += 1
            nextEligible[focus.path] = begun + cooldown
            do {
                let before = try monitorIdentity(focus.path)
                guard before.sameObject(as: focus.identity) else {
                    throw MonitorDirectoryError("目录已被替换或移到其他位置；保留历史数值，重新扫描授权范围后再建立监控")
                }
                let scanSeconds = deadline - ProcessInfo.processInfo.systemUptime
                guard scanSeconds > 0 else {
                    markPending(focus.path, reason: "达到本周期核对预算；保留历史数值，等待下一周期", token: token)
                    break
                }
                let control = ScanControl()
                lock.lock()
                guard generation == token, !suspended else { lock.unlock(); break }
                activeControl = control
                lock.unlock()
                let result = DiskScanner().scan(options: ScanOptions(roots: [URL(fileURLWithPath: focus.path)],
                                                                     maxFiles: perDirectoryFileLimit, maxDuration: scanSeconds),
                                                control: control)
                lock.lock()
                if activeControl === control { activeControl = nil }
                lock.unlock()
                guard isCurrent(token), !isSuspended() else { break }
                let after = try monitorIdentity(focus.path)
                guard after.sameObject(as: focus.identity),
                      result.status == .completed,
                      let record = result.directories.first(where: { $0.path == focus.path }), record.isComplete else {
                    let reason = result.status == .limited
                        ? "达到本周期时间或文件数量预算，目录尚未完整核对；保留历史数值，不能按已读取部分归因"
                        : "目录未完整核对、路径变化或权限不足；保留历史数值，原因待确认"
                    markPending(focus.path, reason: reason, token: token)
                    continue
                }
                publish(DirectoryObservation(path: focus.path, logicalBytes: record.logicalBytes,
                                             allocatedBytes: record.allocatedBytes, observedAt: result.finishedAt,
                                             isComplete: true,
                                             reason: streamUnavailable ? "系统目录通知不可用；此数值仅为本次有限核对结果" : nil), token: token)
                dirty.remove(focus.path)
            } catch {
                markPending(focus.path, reason: error.localizedDescription, token: token)
            }
        }
        cursor = (cursor + max(1, visited)) % count
        // Cool down after returning from the actual work as well: a stalled
        // kernel call cannot cause catch-up bursts of newly scheduled probes.
        nextCycleAt = max(nextCycleAt, ProcessInfo.processInfo.systemUptime + cooldown)
        if streamUnavailable {
            // Fallback is bounded focused polling, never a whole-volume scan.
            dirty.formUnion(focuses.map(\.path))
        }
        schedule(token: token)
    }

    private func publish(_ observation: DirectoryObservation, token: UInt64) {
        lock.lock()
        if generation == token, let index = published.firstIndex(where: { $0.path == observation.path }) {
            published[index] = observation
        }
        lock.unlock()
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token
    }

    private func isSuspended() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return suspended
    }

    private func tearDownStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        eventContext = nil
    }

    private func tearDown() {
        cancelTimer()
        tearDownStream()
        focuses.removeAll()
        dirty.removeAll()
        nextEligible.removeAll()
        nextCycleAt = 0
        cursor = 0
        restartQueued = false
        streamUnavailable = false
    }

    private func cancelTimer() {
        timerEpoch &+= 1
        timer?.cancel()
        timer = nil
    }
}

private struct MonitorFocus {
    let path: String
    let identity: MonitorRootIdentity
}

private struct MonitorRootIdentity {
    let device: dev_t
    let inode: ino_t
    let modifiedAt: Date
    func sameObject(as other: MonitorRootIdentity) -> Bool { device == other.device && inode == other.inode }
}

private struct MonitorDirectoryError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class MonitorEventContext {
    weak var monitor: DirectoryMonitor?
    let generation: UInt64
    init(monitor: DirectoryMonitor, generation: UInt64) { self.monitor = monitor; self.generation = generation }
}

private let directoryMonitorCallback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
    guard let info else { return }
    let box = Unmanaged<MonitorEventContext>.fromOpaque(info).takeUnretainedValue()
    guard let monitor = box.monitor else { return }
    let limit = min(count, 4_096)
    let pointers = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    let names = (0..<limit).map { String(validatingUTF8: pointers[$0]) }
    let events = (0..<limit).map { flags[$0] }
    monitor.received(paths: names, flags: events, token: box.generation, truncated: count > limit)
}

private func monitorIdentity(_ path: String) throws -> MonitorRootIdentity {
    let descriptor = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC) }
    guard descriptor >= 0 else {
        throw MonitorDirectoryError("重点目录无法访问、已消失或路径包含链接：未核对，不视为空目录")
    }
    defer { close(descriptor) }
    var metadata = stat()
    var volume = statfs()
    guard fstat(descriptor, &metadata) == 0,
          metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), metadata.st_flags & UInt32(SF_DATALESS) == 0,
          fstatfs(descriptor, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else {
        throw MonitorDirectoryError("重点目录是云端占位项、非本地磁盘或无法核对：保留历史数值")
    }
    return MonitorRootIdentity(device: metadata.st_dev, inode: metadata.st_ino,
                               modifiedAt: Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec) +
                                                TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000))
}

private func baselineRecord(path: String, scan: ScanResult?) -> DirectoryRecord? {
    guard let scan, scan.status == .completed else { return nil }
    return scan.directories.first { $0.path == path && $0.isComplete }
}

private func monitorPaths(_ candidates: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for path in candidates.prefix(256) {
        guard path.hasPrefix("/"), path != "/", !path.utf8.contains(0),
              !path.split(separator: "/").contains("..") else { continue }
        let normalized = "/" + path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
        if seen.insert(normalized).inserted { result.append(normalized) }
        if result.count == 8 { break }
    }
    return result
}

private func monitorEventOverlaps(_ event: String, _ watched: String) -> Bool {
    // FSEvents may report the known macOS /tmp or /var spelling. These lexical
    // mappings only mark a known focus dirty; they are never used for file access
    // and never resolve or follow arbitrary symlinks.
    var path = "/" + event.split(separator: "/").joined(separator: "/")
    if watched.hasPrefix("/private/tmp/"), path == "/tmp" || path.hasPrefix("/tmp/") { path = "/private" + path }
    if watched.hasPrefix("/private/var/"), path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
    return path == watched || path == "/" || path.hasPrefix(watched + "/") || watched.hasPrefix(path + "/")
}
