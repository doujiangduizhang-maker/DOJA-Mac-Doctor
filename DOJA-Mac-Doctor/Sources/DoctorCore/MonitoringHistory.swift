import Foundation
import Darwin
import CSQLite

/// A directory observation describes metadata measured at one time. Allocation
/// includes shared APFS extents and is never a promise of reclaimable space.
public struct DirectoryObservation: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let logicalBytes: Int64?
    public let allocatedBytes: Int64?
    public let observedAt: Date
    public let isComplete: Bool
    public let reason: String?

    public init(path: String, logicalBytes: Int64?, allocatedBytes: Int64?,
                observedAt: Date, isComplete: Bool, reason: String? = nil) {
        self.path = path
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.observedAt = observedAt
        self.isComplete = isComplete
        self.reason = reason
    }
}

/// These are individual comparisons. Parent and child totals overlap and must
/// not be added together or treated as a cause of a volume-level space change.
public struct DirectoryChange: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(path)::\(baselineAt.timeIntervalSince1970)::\(currentAt.timeIntervalSince1970)" }
    public let path: String
    public let beforeAllocatedBytes: Int64
    public let afterAllocatedBytes: Int64
    public let beforeLogicalBytes: Int64
    public let afterLogicalBytes: Int64
    public let baselineAt: Date
    public let currentAt: Date
    public var allocatedDeltaBytes: Int64 { afterAllocatedBytes - beforeAllocatedBytes }
    public var logicalDeltaBytes: Int64 { afterLogicalBytes - beforeLogicalBytes }

    public init(path: String, beforeAllocatedBytes: Int64, afterAllocatedBytes: Int64,
                beforeLogicalBytes: Int64, afterLogicalBytes: Int64,
                baselineAt: Date, currentAt: Date) {
        self.path = path
        self.beforeAllocatedBytes = beforeAllocatedBytes
        self.afterAllocatedBytes = afterAllocatedBytes
        self.beforeLogicalBytes = beforeLogicalBytes
        self.afterLogicalBytes = afterLogicalBytes
        self.baselineAt = baselineAt
        self.currentAt = currentAt
    }
}

public struct SpaceAnomaly: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let detectedAt: Date
    public let dropBytes: Int64
    public let memoryPressure: String
    public let swapUsedBytes: Int64?
    public let swapDeltaBytes: Int64?
    public let directoryChanges: [DirectoryChange]
    public let explanation: String

    public init(id: UUID = UUID(), startedAt: Date, detectedAt: Date, dropBytes: Int64,
                memoryPressure: String, swapUsedBytes: Int64?, swapDeltaBytes: Int64?,
                directoryChanges: [DirectoryChange], explanation: String) {
        self.id = id
        self.startedAt = startedAt
        self.detectedAt = detectedAt
        self.dropBytes = dropBytes
        self.memoryPressure = memoryPressure
        self.swapUsedBytes = swapUsedBytes
        self.swapDeltaBytes = swapDeltaBytes
        self.directoryChanges = directoryChanges
        self.explanation = explanation
    }
}

public struct HistorySnapshot: Codable, Sendable {
    public let samples: [SystemSample]
    public let events: [SpaceAnomaly]
    public let directories: [DirectoryObservation]
    public let status: String?

    public init(samples: [SystemSample], events: [SpaceAnomaly],
                directories: [DirectoryObservation], status: String? = nil) {
        self.samples = samples
        self.events = events
        self.directories = directories
        self.status = status
    }
}

public struct MonitoringHistoryError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// One bounded, local SQLite database. The lock serializes the connection, JSON
/// coders, status, and transactions; no file contents or process names are saved.
public final class MonitoringStore: @unchecked Sendable {
    public static let maximumDatabaseBytes: Int64 = 16 * 1_024 * 1_024
    public static let minimumWriteFreeBytes: Int64 = 100 * 1_024 * 1_024
    private static let maximumSamples = 20_160
    private static let maximumObservations = 4_096
    private static let maximumEvents = 256
    private static let maximumDirectoriesPerSample = 16
    private static let applicationID = 0x444F4A41
    private let lock = NSLock()
    private let url: URL
    private var database: OpaquePointer?
    private var status: String?
    private var needsWriteConfiguration = false
    private var volatileSamples: [(sample: SystemSample, volume: String)] = []
    private var volatileDirectories: [(value: DirectoryObservation, volume: String)] = []
    private var volatileCurrentDirectories: [String: DirectoryObservation] = [:]
    private var volatileEvents: [StoredEvent] = []
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else {
            throw MonitoringHistoryError("监控数据库需要使用本机的完整路径。")
        }
        self.url = url
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
        let existed = FileManager.default.fileExists(atPath: url.path)
        var metadata = stat()
        let existsByMetadata = url.path.withCString { lstat($0, &metadata) } == 0
        if existsByMetadata, (metadata.st_mode & S_IFMT) != S_IFREG {
            throw MonitoringHistoryError("监控数据库路径不是普通文件，已保留原有数据。")
        }
        if existsByMetadata, metadata.st_nlink != 1 || metadata.st_uid != geteuid() {
            throw MonitoringHistoryError("监控数据库不是当前用户独占的文件，已保留原有数据。")
        }
        if existsByMetadata, metadata.st_mode & (S_IWGRP | S_IWOTH) != 0 {
            throw MonitoringHistoryError("监控数据库允许其他用户修改，已保留原有数据；请另选历史记录文件。")
        }
        let isNew = !existed || (existsByMetadata && metadata.st_size == 0)
        let lowStorage = Self.availableSpace(near: url).map({ $0 < Self.minimumWriteFreeBytes }) == true
        if lowStorage {
            if isNew { throw MonitoringHistoryError("磁盘剩余空间不足 100 MiB，暂不创建监控历史数据库。") }
            status = "磁盘剩余空间不足 100 MiB，历史记录暂时停写。"
        }
        if isNew {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let openResult = sqlite3_open_v2(url.path, &connection, flags, nil)
        guard openResult == SQLITE_OK, let connection else {
            let detail = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开文件"
            if let connection { sqlite3_close_v2(connection) }
            throw MonitoringHistoryError("监控数据库打开失败：\(detail)。原有文件已保留。")
        }
        database = connection
        do {
            sqlite3_busy_timeout(connection, 250)
            if !isNew {
                guard try scalarText("PRAGMA quick_check(1)") == "ok" else {
                    throw MonitoringHistoryError("监控数据库检查未通过，原有文件已保留；请另选历史记录文件。")
                }
                guard try scalarInt("PRAGMA application_id") == Int64(Self.applicationID),
                      try scalarInt("PRAGMA user_version") == 1 else {
                    throw MonitoringHistoryError("监控数据库格式无法识别，原有文件已保留。")
                }
            }
            if isNew { try execute("PRAGMA page_size = 4096") }
            let pageSize = try scalarInt("PRAGMA page_size")
            guard pageSize > 0 else { throw MonitoringHistoryError("无法确认监控数据库容量限制。") }
            let maximumPages = Self.maximumDatabaseBytes / pageSize
            guard try scalarInt("PRAGMA page_count") <= maximumPages else {
                throw MonitoringHistoryError("已有监控数据库超过 16 MiB，原文件已保留；请另选历史记录文件。")
            }
            if lowStorage {
                // Existing history remains readable. Persistent PRAGMAs and
                // schema writes wait until enough disk space returns.
                needsWriteConfiguration = true
            } else {
                try configureWrites(maximumPages: maximumPages)
            }
            if isNew {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("CREATE TABLE samples (stamp REAL NOT NULL, volume TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(stamp, volume))")
                    try execute("CREATE TABLE directories (observed REAL NOT NULL, recorded REAL NOT NULL, volume TEXT NOT NULL, path TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(volume, path, observed))")
                    try execute("CREATE INDEX directory_times ON directories(observed)")
                    try execute("CREATE TABLE current_directories (volume TEXT NOT NULL, path TEXT NOT NULL, recorded REAL NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(volume, path))")
                    try execute("CREATE TABLE events (id TEXT PRIMARY KEY NOT NULL, stamp REAL NOT NULL, volume TEXT NOT NULL, baseline_available INTEGER NOT NULL, payload BLOB NOT NULL)")
                    try execute("CREATE INDEX event_times ON events(volume, stamp)")
                    try execute("PRAGMA application_id = \(Self.applicationID)")
                    try execute("PRAGMA user_version = 1")
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
                _ = url.path.withCString { chmod($0, S_IRUSR | S_IWUSR) }
            } else {
                // Read the known tables now so schema damage is surfaced before
                // accepting samples; never replace a damaged/foreign database.
                _ = try scalarInt("SELECT COUNT(*) FROM samples")
                _ = try scalarInt("SELECT COUNT(*) FROM directories")
                _ = try scalarInt("SELECT COUNT(*) FROM current_directories")
                _ = try scalarInt("SELECT COUNT(*) FROM events")
            }
        } catch {
            sqlite3_close_v2(connection)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close_v2(database) } }

    /// The primary SQLite file is capped at 16 MiB. A transaction's temporary
    /// rollback journal can additionally occupy up to roughly that file size.
    public var fileBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        var metadata = stat()
        return url.path.withCString { lstat($0, &metadata) } == 0 ? Int64(metadata.st_size) : 0
    }

    /// Returns a new or revised episode, or nil when this sample has no anomaly.
    /// Low-space pause is a status, not a failed destructive repair attempt.
    public func record(sample: SystemSample, directories: [DirectoryObservation]) throws -> SpaceAnomaly? {
        lock.lock()
        defer { lock.unlock() }
        status = nil
        do {
            try validate(sample: sample, directories: directories)
            let identity = Self.volumeIdentity(path: sample.volumePath)
            let volume = identity ?? "unconfirmed:\(sample.volumePath)"
            if sample.availableBytes.map({ $0 < Self.minimumWriteFreeBytes }) == true ||
                Self.availableSpace(near: url).map({ $0 < Self.minimumWriteFreeBytes }) == true {
                let event = identity == nil ? nil : try detectAnomaly(sample: sample, directories: directories, volume: volume)
                try rememberVolatile(sample: sample, directories: directories, volume: volume, event: event)
                status = "磁盘剩余空间不足 100 MiB，历史暂时停写；最近采样和异常仅保留在本次运行中，尚未保存。"
                return event
            }
            if needsWriteConfiguration {
                let pageSize = try scalarInt("PRAGMA page_size")
                guard pageSize > 0 else { throw MonitoringHistoryError("无法确认监控数据库容量限制。") }
                try configureWrites(maximumPages: Self.maximumDatabaseBytes / pageSize)
                needsWriteConfiguration = false
            }
            if identity == nil { status = "磁盘身份暂时无法确认，本次采样不会用于生成空间异常。" }
            else if !volatileSamples.isEmpty { status = "此前低空间阶段的部分记录仅保留在本次运行中，重启后不保留。" }
            let sampleData = try encode(sample, maximum: 16_384)
            try execute("BEGIN IMMEDIATE")
            do {
                try rotateIfNeeded(asOf: sample.timestamp)
                let event = identity == nil ? nil : try detectAnomaly(sample: sample, directories: directories, volume: volume)
                try run("INSERT OR REPLACE INTO samples(stamp, volume, payload) VALUES (?, ?, ?)",
                        [.real(sample.timestamp.timeIntervalSince1970), .text(volume), .blob(sampleData)])
                var seen = Set<String>()
                for observation in directories where seen.insert(observation.path).inserted {
                    let directoryVolume = Self.volumeIdentity(path: observation.path) ?? "unconfirmed:\(observation.path)"
                    // A previously measured complete baseline is immutable.
                    // Becoming dirty later changes current status, not history.
                    let observationData = try encode(observation, maximum: 16_384)
                    try run("INSERT OR IGNORE INTO directories(observed, recorded, volume, path, payload) VALUES (?, ?, ?, ?, ?)",
                            [.real(observation.observedAt.timeIntervalSince1970), .real(sample.timestamp.timeIntervalSince1970),
                             .text(directoryVolume), .text(observation.path), .blob(observationData)])
                    try run("INSERT OR REPLACE INTO current_directories(volume, path, recorded, payload) VALUES (?, ?, ?, ?)",
                            [.text(directoryVolume), .text(observation.path), .real(sample.timestamp.timeIntervalSince1970), .blob(observationData)])
                }
                if let event {
                    // A revised event retains the original high-water baseline.
                    let existing = try storedEvent(id: event.id)
                    let baseline = existing?.baselineAvailable ?? (sample.availableBytes! + event.dropBytes)
                    try run("INSERT OR REPLACE INTO events(id, stamp, volume, baseline_available, payload) VALUES (?, ?, ?, ?, ?)",
                            [.text(event.id.uuidString), .real(event.detectedAt.timeIntervalSince1970), .text(volume),
                             .integer(baseline), .blob(try encode(event, maximum: 262_144))])
                }
                try prune(asOf: sample.timestamp)
                try execute("COMMIT")
                volatileSamples.removeAll { $0.volume == volume && $0.sample.timestamp == sample.timestamp }
                if let event { volatileEvents.removeAll { $0.event.id == event.id } }
                for observation in directories { volatileCurrentDirectories.removeValue(forKey: observation.path) }
                return event
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        } catch {
            status = "历史记录写入暂停：\(error.localizedDescription)；已保存的记录保留。"
            throw error
        }
    }

    public func loadSnapshot(limit: Int = 1_440) throws -> HistorySnapshot {
        lock.lock()
        defer { lock.unlock() }
        let count = min(Self.maximumSamples, max(1, limit))
        let persistedSamples: [SystemSample] = try payloads("SELECT payload FROM samples ORDER BY stamp DESC LIMIT ?", [.integer(Int64(count))])
        var sampleMap: [String: SystemSample] = [:]
        for sample in persistedSamples + volatileSamples.map(\.sample) {
            sampleMap["\(sample.volumePath)::\(sample.timestamp.timeIntervalSince1970)"] = sample
        }
        let samples = Array(sampleMap.values.sorted { $0.timestamp > $1.timestamp }.prefix(count))
        let persistedEvents: [SpaceAnomaly] = try payloads("SELECT payload FROM events ORDER BY stamp DESC LIMIT ?", [.integer(Int64(Self.maximumEvents))])
        var eventMap: [UUID: SpaceAnomaly] = [:]
        for event in persistedEvents + volatileEvents.map(\.event) {
            if eventMap[event.id].map({ $0.detectedAt > event.detectedAt }) != true { eventMap[event.id] = event }
        }
        let events = Array(eventMap.values.sorted { $0.detectedAt > $1.detectedAt }.prefix(Self.maximumEvents))
        let persistedObservations: [DirectoryObservation] = try payloads("SELECT payload FROM current_directories ORDER BY recorded DESC LIMIT 256")
        // Current incomplete states take precedence over an earlier complete
        // observation with the same measured-at timestamp.
        var observationMap = Dictionary(persistedObservations.reversed().map { ($0.path, $0) }, uniquingKeysWith: { _, newest in newest })
        for (path, observation) in volatileCurrentDirectories { observationMap[path] = observation }
        let observations = observationMap.values.sorted { $0.observedAt > $1.observedAt }
        var paths = Set<String>()
        let latest = observations.filter { paths.insert($0.path).inserted }.prefix(Self.maximumDirectoriesPerSample)
        return HistorySnapshot(samples: samples.reversed(), events: events,
                               directories: latest.sorted { $0.path < $1.path }, status: status)
    }

    private struct StoredEvent {
        let event: SpaceAnomaly
        let baselineAvailable: Int64
        let volume: String
    }

    private func detectAnomaly(sample: SystemSample, directories: [DirectoryObservation], volume: String) throws -> SpaceAnomaly? {
        guard let currentAvailable = sample.availableBytes else { return nil }
        let now = sample.timestamp.timeIntervalSince1970
        let persisted: [SystemSample] = try payloads(
            "SELECT payload FROM samples WHERE volume = ? AND stamp >= ? AND stamp < ? ORDER BY stamp DESC LIMIT 32",
            [.text(volume), .real(now - 600), .real(now)])
        let buffered = volatileSamples.filter { $0.volume == volume && $0.sample.timestamp < sample.timestamp && $0.sample.timestamp >= sample.timestamp.addingTimeInterval(-600) }.map(\.sample)
        var uniquePrevious: [Date: SystemSample] = [:]
        for entry in persisted + buffered { uniquePrevious[entry.timestamp] = entry }
        let previous = uniquePrevious.values.sorted { $0.timestamp > $1.timestamp }
        var contiguous: [SystemSample] = []
        var later = sample.timestamp
        for entry in previous {
            let gap = later.timeIntervalSince(entry.timestamp)
            // Sleep, missed timers, unavailable metrics, and a changed volume do
            // not form a continuous ten-minute diagnostic window.
            guard gap > 0, gap <= 150, entry.availableBytes != nil else { break }
            contiguous.append(entry)
            later = entry.timestamp
        }
        guard let baseline = contiguous.max(by: { $0.availableBytes! < $1.availableBytes! }),
              let before = baseline.availableBytes else { return nil }
        let drop = before - currentAvailable
        guard drop > 3_000_000_000 else { return nil }
        let freshChanges = try changes(baselineAt: baseline.timestamp, current: sample.timestamp,
                                      volume: volume, currentObservations: directories)
        let mostRecent = try latestStoredEvent(volume: volume)
        var id = UUID()
        var startedAt = baseline.timestamp
        var largestDrop = drop
        var evidence = freshChanges
        if let mostRecent,
           sample.timestamp >= mostRecent.event.detectedAt,
           sample.timestamp.timeIntervalSince(mostRecent.event.detectedAt) <= 600,
           baseline.timestamp.timeIntervalSince(mostRecent.event.detectedAt) <= 150 {
            let recovered = contiguous.contains {
                $0.timestamp > mostRecent.event.detectedAt &&
                ($0.availableBytes ?? 0) >= max(0, mostRecent.baselineAvailable - 1_000_000_000)
            }
            if !recovered {
                id = mostRecent.event.id
                startedAt = min(startedAt, mostRecent.event.startedAt)
                largestDrop = max(drop, mostRecent.event.dropBytes)
                var merged = Dictionary(uniqueKeysWithValues: mostRecent.event.directoryChanges.map { ($0.path, $0) })
                for change in freshChanges { merged[change.path] = change }
                evidence = merged.values.sorted { $0.allocatedDeltaBytes > $1.allocatedDeltaBytes }
            }
        }
        let swapDelta = baseline.swapUsedBytes.flatMap { old in sample.swapUsedBytes.map { $0 - old } }
        var explanation = "原因待确认。"
        if !evidence.isEmpty { explanation += "同期目录变化提供排查线索，不能直接认定是哪个应用造成。" }
        else { explanation += "目前未取得可关联的目录变化线索。" }
        if let swapDelta, swapDelta > 0 { explanation += "同期交换空间增加，但这只能说明时间相关。" }
        return SpaceAnomaly(id: id, startedAt: startedAt, detectedAt: sample.timestamp,
                            dropBytes: largestDrop, memoryPressure: sample.memoryPressure,
                            swapUsedBytes: sample.swapUsedBytes, swapDeltaBytes: swapDelta,
                            directoryChanges: Array(evidence.prefix(Self.maximumDirectoriesPerSample)), explanation: explanation)
    }

    private func changes(baselineAt: Date, current: Date, volume: String,
                         currentObservations: [DirectoryObservation]) throws -> [DirectoryChange] {
        var observations: [DirectoryObservation] = try payloads(
            "SELECT payload FROM directories WHERE volume = ? AND observed >= ? AND observed <= ? ORDER BY observed DESC LIMIT ?",
            [.text(volume), .real(baselineAt.timeIntervalSince1970 - 120),
             .real(current.timeIntervalSince1970 + 5), .integer(Int64(Self.maximumObservations))])
        observations += currentObservations.filter { Self.volumeIdentity(path: $0.path) == volume }
        observations += volatileDirectories.filter { $0.volume == volume }.map(\.value)
        let grouped = Dictionary(grouping: observations, by: \.path)
        var result: [DirectoryChange] = []
        for (path, records) in grouped {
            // Evidence requires an explicitly supplied current observation.
            // An absent, dirty or incomplete current state cannot fall back to
            // an earlier complete record, even at the same measured-at time.
            guard let recent = currentObservations.first(where: { $0.path == path }),
                  recent.isComplete,
                  Self.volumeIdentity(path: recent.path) == volume,
                  current.timeIntervalSince(recent.observedAt) <= 120 else { continue }
            let baseline = records.filter { abs($0.observedAt.timeIntervalSince(baselineAt)) <= 120 }
                .min { abs($0.observedAt.timeIntervalSince(baselineAt)) < abs($1.observedAt.timeIntervalSince(baselineAt)) }
            guard let baseline, baseline.isComplete,
                  recent.observedAt > baseline.observedAt,
                  let beforeLogical = baseline.logicalBytes, let afterLogical = recent.logicalBytes,
                  let beforeAllocated = baseline.allocatedBytes, let afterAllocated = recent.allocatedBytes,
                  beforeLogical != afterLogical || beforeAllocated != afterAllocated else { continue }
            result.append(DirectoryChange(path: path, beforeAllocatedBytes: beforeAllocated, afterAllocatedBytes: afterAllocated,
                                          beforeLogicalBytes: beforeLogical, afterLogicalBytes: afterLogical,
                                          baselineAt: baseline.observedAt, currentAt: recent.observedAt))
        }
        return result.sorted { $0.allocatedDeltaBytes > $1.allocatedDeltaBytes }
    }

    private func latestStoredEvent(volume: String) throws -> StoredEvent? {
        var result: StoredEvent?
        try query("SELECT payload, baseline_available FROM events WHERE volume = ? ORDER BY stamp DESC LIMIT 1", [.text(volume)]) { statement in
            result = StoredEvent(event: try self.decode(SpaceAnomaly.self, statement: statement, column: 0),
                                 baselineAvailable: sqlite3_column_int64(statement, 1), volume: volume)
        }
        if let buffered = volatileEvents.filter({ $0.volume == volume }).max(by: { $0.event.detectedAt < $1.event.detectedAt }),
           result.map({ $0.event.detectedAt <= buffered.event.detectedAt }) ?? true { result = buffered }
        return result
    }

    private func storedEvent(id: UUID) throws -> StoredEvent? {
        var result: StoredEvent?
        try query("SELECT payload, baseline_available, volume FROM events WHERE id = ?", [.text(id.uuidString)]) { statement in
            result = StoredEvent(event: try self.decode(SpaceAnomaly.self, statement: statement, column: 0),
                                 baselineAvailable: sqlite3_column_int64(statement, 1),
                                 volume: String(cString: sqlite3_column_text(statement, 2)))
        }
        if let buffered = volatileEvents.first(where: { $0.event.id == id }),
           result.map({ $0.event.detectedAt <= buffered.event.detectedAt }) ?? true { result = buffered }
        return result
    }

    private func rememberVolatile(sample: SystemSample, directories: [DirectoryObservation],
                                  volume: String, event: SpaceAnomaly?) throws {
        if let event {
            let old = try storedEvent(id: event.id)
            let baseline = old?.baselineAvailable ?? ((sample.availableBytes ?? 0) + event.dropBytes)
            volatileEvents.removeAll { $0.event.id == event.id }
            volatileEvents.append(StoredEvent(event: event, baselineAvailable: baseline, volume: volume))
            volatileEvents = Array(volatileEvents.suffix(16))
        }
        volatileSamples.removeAll { $0.volume == volume && $0.sample.timestamp == sample.timestamp }
        volatileSamples.append((sample, volume))
        volatileSamples = Array(volatileSamples.suffix(32))
        for observation in directories {
            volatileCurrentDirectories[observation.path] = observation
            let identity = Self.volumeIdentity(path: observation.path) ?? "unconfirmed:\(observation.path)"
            // Preserve complete evidence when a later dirty state reuses its
            // measured-at timestamp; current status is the latest suffix value.
            if !volatileDirectories.contains(where: {
                $0.volume == identity && $0.value.path == observation.path &&
                $0.value.observedAt == observation.observedAt && $0.value == observation
            }) { volatileDirectories.append((observation, identity)) }
        }
        volatileDirectories = Array(volatileDirectories.suffix(512))
        if volatileCurrentDirectories.count > Self.maximumDirectoriesPerSample {
            let newest = volatileCurrentDirectories.values.sorted { $0.observedAt > $1.observedAt }.prefix(Self.maximumDirectoriesPerSample)
            volatileCurrentDirectories = Dictionary(uniqueKeysWithValues: newest.map { ($0.path, $0) })
        }
    }

    private func prune(asOf date: Date) throws {
        let oldest = date.addingTimeInterval(-14 * 24 * 60 * 60).timeIntervalSince1970
        try run("DELETE FROM samples WHERE stamp < ?", [.real(oldest)])
        try run("DELETE FROM directories WHERE observed < ?", [.real(oldest)])
        try run("DELETE FROM events WHERE stamp < ?", [.real(oldest)])
        try run("DELETE FROM current_directories WHERE recorded < ?", [.real(oldest)])
        try run("DELETE FROM samples WHERE rowid IN (SELECT rowid FROM samples ORDER BY stamp DESC LIMIT -1 OFFSET ?)", [.integer(Int64(Self.maximumSamples))])
        try run("DELETE FROM directories WHERE rowid IN (SELECT rowid FROM directories ORDER BY observed DESC LIMIT -1 OFFSET ?)", [.integer(Int64(Self.maximumObservations))])
        try run("DELETE FROM events WHERE rowid IN (SELECT rowid FROM events ORDER BY stamp DESC LIMIT -1 OFFSET ?)", [.integer(Int64(Self.maximumEvents))])
        try execute("DELETE FROM current_directories WHERE rowid IN (SELECT rowid FROM current_directories ORDER BY recorded DESC LIMIT -1 OFFSET 256)")
    }

    private func rotateIfNeeded(asOf date: Date) throws {
        let pageSize = try scalarInt("PRAGMA page_size")
        let usedPages = try scalarInt("PRAGMA page_count") - scalarInt("PRAGMA freelist_count")
        guard usedPages * pageSize >= 12 * 1_024 * 1_024 else { return }
        // Reuse freed database pages without VACUUM or creating another file.
        // The latest diagnostic window is protected; the 14-day policy is an
        // upper retention bound, never a promise to keep every sample that long.
        let protectedSince = date.addingTimeInterval(-600).timeIntervalSince1970
        for (table, timestamp) in [("samples", "stamp"), ("directories", "observed"),
                                   ("events", "stamp"), ("current_directories", "recorded")] {
            let eligible = try scalarInt("SELECT COUNT(*) FROM \(table) WHERE \(timestamp) < \(protectedSince)")
            guard eligible > 0 else { continue }
            let remove = max(1, eligible / 4)
            try run("DELETE FROM \(table) WHERE rowid IN (SELECT rowid FROM \(table) WHERE \(timestamp) < ? ORDER BY \(timestamp) ASC LIMIT ?)",
                    [.real(protectedSince), .integer(remove)])
        }
    }

    private func validate(sample: SystemSample, directories: [DirectoryObservation]) throws {
        guard sample.timestamp.timeIntervalSince1970.isFinite,
              sample.volumePath.utf8.count <= 4_096,
              sample.memoryPressure.utf8.count <= 256,
              directories.count <= Self.maximumDirectoriesPerSample else {
            throw MonitoringHistoryError("监控记录超出单次记录限制，未写入数据库。")
        }
        for value in [sample.totalBytes, sample.availableBytes, sample.usedBytes, sample.swapUsedBytes, sample.swapTotalBytes] {
            if let value, value < 0 { throw MonitoringHistoryError("监控容量数值无效，未写入数据库。") }
        }
        for record in directories {
            guard record.path.hasPrefix("/"), record.path.utf8.count <= 4_096,
                  record.observedAt.timeIntervalSince1970.isFinite,
                  record.observedAt <= sample.timestamp.addingTimeInterval(5),
                  record.reason.map({ $0.utf8.count <= 4_096 }) ?? true,
                  record.logicalBytes.map({ $0 >= 0 }) ?? true,
                  record.allocatedBytes.map({ $0 >= 0 }) ?? true else {
                throw MonitoringHistoryError("目录监控记录无效，未写入数据库。")
            }
        }
    }

    private func encode<T: Encodable>(_ value: T, maximum: Int) throws -> Data {
        let data = try encoder.encode(value)
        guard data.count <= maximum else { throw MonitoringHistoryError("单条监控记录过大，未写入数据库。") }
        return data
    }

    private enum Value { case text(String), real(Double), integer(Int64), blob(Data) }
    private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    private func execute(_ sql: String) throws {
        guard let database else { throw MonitoringHistoryError("监控数据库尚未打开。") }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw sqlError(result) }
    }

    private func configureWrites(maximumPages: Int64) throws {
        try execute("PRAGMA max_page_count = \(maximumPages)")
        guard try scalarText("PRAGMA journal_mode = DELETE").lowercased() == "delete" else {
            throw MonitoringHistoryError("无法配置监控数据库的临时日志。")
        }
        try execute("PRAGMA synchronous = FULL")
        try execute("PRAGMA journal_size_limit = 1048576")
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        try query(sql, values) { _ in }
    }

    private func query(_ sql: String, _ values: [Value] = [], row: (OpaquePointer) throws -> Void) throws {
        guard let database else { throw MonitoringHistoryError("监控数据库尚未打开。") }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw sqlError(prepared) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let bound: Int32
            switch value {
            case .text(let value): bound = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .real(let value): bound = sqlite3_bind_double(statement, index, value)
            case .integer(let value): bound = sqlite3_bind_int64(statement, index, value)
            case .blob(let value): bound = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) }
            }
            guard bound == SQLITE_OK else { throw sqlError(bound) }
        }
        while true {
            let stepped = sqlite3_step(statement)
            if stepped == SQLITE_DONE { return }
            guard stepped == SQLITE_ROW else { throw sqlError(stepped) }
            try row(statement)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        var value: Int64 = 0
        try query(sql) { value = sqlite3_column_int64($0, 0) }
        return value
    }

    private func scalarText(_ sql: String) throws -> String {
        var value = ""
        try query(sql) { statement in
            if let text = sqlite3_column_text(statement, 0) { value = String(cString: text) }
        }
        return value
    }

    private func payloads<T: Decodable>(_ sql: String, _ values: [Value] = []) throws -> [T] {
        var result: [T] = []
        try query(sql, values) { result.append(try self.decode(T.self, statement: $0, column: 0)) }
        return result
    }

    private func decode<T: Decodable>(_ type: T.Type, statement: OpaquePointer, column: Int32) throws -> T {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, count <= 262_144, let pointer = sqlite3_column_blob(statement, column) else {
            throw MonitoringHistoryError("监控数据库包含无法读取的记录，原有文件已保留。")
        }
        do { return try decoder.decode(type, from: Data(bytes: pointer, count: count)) }
        catch { throw MonitoringHistoryError("监控记录格式无法读取，原有文件已保留：\(error.localizedDescription)") }
    }

    private func sqlError(_ result: Int32) -> MonitoringHistoryError {
        if result == SQLITE_FULL { return MonitoringHistoryError("监控数据库已达到容量限制或磁盘空间不足") }
        if result == SQLITE_BUSY || result == SQLITE_LOCKED { return MonitoringHistoryError("监控数据库正被占用") }
        let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
        return MonitoringHistoryError("监控数据库读取或写入失败：\(detail)")
    }

    private static func volumeIdentity(path: String) -> String? {
        var info = statfs()
        guard path.withCString({ statfs($0, &info) }) == 0 else { return nil }
        let id = withUnsafeBytes(of: info.f_fsid) { $0.map { String(format: "%02x", $0) }.joined() }
        let mountedFrom = withUnsafePointer(to: &info.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
        }
        return "\(id):\(mountedFrom)"
    }

    private static func availableSpace(near url: URL) -> Int64? {
        var candidate = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        var info = statfs()
        guard candidate.path.withCString({ statfs($0, &info) }) == 0 else { return nil }
        let (result, overflow) = Int64(clamping: info.f_bavail).multipliedReportingOverflow(by: Int64(info.f_bsize))
        return overflow ? Int64.max : result
    }
}
