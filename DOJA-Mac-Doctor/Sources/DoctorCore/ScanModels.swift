import Foundation

public struct ScanOptions: Codable, Sendable {
    public let roots: [URL]
    public let largeFileThreshold: Int64
    public let recentDays: Int
    /// Optional metadata-work bounds. Reaching a bound produces `.limited`,
    /// never a completed scan or a user-cancelled scan.
    public let maxFiles: Int?
    public let maxDuration: TimeInterval?

    public init(roots: [URL], largeFileThreshold: Int64 = 104_857_600, recentDays: Int = 7,
                maxFiles: Int? = nil, maxDuration: TimeInterval? = nil) {
        self.roots = roots
        self.largeFileThreshold = max(0, largeFileThreshold)
        self.recentDays = max(0, recentDays)
        self.maxFiles = maxFiles.map { max(0, $0) }
        self.maxDuration = maxDuration.map { $0.isFinite ? max(0, $0) : 0 }
    }
}

/// A control object belongs to one scan. Cancellation is permanent for that object.
public final class ScanControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false

    public init() {}

    public var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    public var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    public func pause() {
        condition.lock()
        if !cancelled { paused = true }
        condition.unlock()
    }

    public func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    public func cancel() {
        condition.lock()
        cancelled = true
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilRunnable() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while paused && !cancelled { condition.wait() }
        return !cancelled
    }
}

public enum ScanStatus: String, Codable, Sendable {
    case completed
    case cancelled
    case limited
}

public struct ScanProgress: Codable, Sendable {
    public let visitedFiles: Int
    public let currentPath: String
    public let logicalBytes: Int64

    public init(visitedFiles: Int, currentPath: String, logicalBytes: Int64) {
        self.visitedFiles = visitedFiles
        self.currentPath = currentPath
        self.logicalBytes = logicalBytes
    }
}

/// Logical size counts directory entries. Allocated size counts reported blocks,
/// with hard links deduplicated by volume and inode across all selected roots.
/// APFS shared extents and snapshots cannot be resolved by this metadata scan:
/// allocatedBytes is NOT an estimate of reclaimable disk space.
public struct ScanResult: Codable, Sendable {
    public let roots: [String]
    public let startedAt: Date
    public let finishedAt: Date
    public let status: ScanStatus
    public let directories: [DirectoryRecord]
    public let largestFiles: [FileRecord]
    public let recentLargeFiles: [FileRecord]
    public let categories: [CategorySummary]
    public let issues: [ScanIssue]
    public let fileCount: Int
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let skippedSymlinks: Int

    public init(roots: [String], startedAt: Date, finishedAt: Date, status: ScanStatus,
                directories: [DirectoryRecord], largestFiles: [FileRecord],
                recentLargeFiles: [FileRecord], categories: [CategorySummary],
                issues: [ScanIssue], fileCount: Int, logicalBytes: Int64,
                allocatedBytes: Int64, skippedSymlinks: Int) {
        self.roots = roots
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.directories = directories
        self.largestFiles = largestFiles
        self.recentLargeFiles = recentLargeFiles
        self.categories = categories
        self.issues = issues
        self.fileCount = fileCount
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.skippedSymlinks = skippedSymlinks
    }
}

/// Totals include descendants and must not be added to one another.
/// A hard link's blocks belong to the first path encountered during traversal;
/// its other paths still contribute logical bytes and file counts.
public struct DirectoryRecord: Codable, Sendable, Identifiable {
    public let id: String
    public let path: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let fileCount: Int
    public let lastModified: Date?
    public let isComplete: Bool
    public let containsProtectedFiles: Bool

    public init(path: String, logicalBytes: Int64, allocatedBytes: Int64,
                fileCount: Int, lastModified: Date?, isComplete: Bool,
                containsProtectedFiles: Bool = false) {
        self.id = path
        self.path = path
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.lastModified = lastModified
        self.isComplete = isComplete
        self.containsProtectedFiles = containsProtectedFiles
    }
}

/// Per-path allocatedBytes is the file's raw reported allocation, before the
/// global hard-link deduplication used for directory/result totals.
public struct FileRecord: Codable, Sendable, Identifiable {
    public let id: String
    public let path: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let modifiedAt: Date
    public let createdAt: Date?
    public let linkCount: Int
    public let kind: String

    public init(path: String, logicalBytes: Int64, allocatedBytes: Int64,
                modifiedAt: Date, createdAt: Date?, linkCount: Int, kind: String) {
        self.id = path
        self.path = path
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.linkCount = linkCount
        self.kind = kind
    }
}

public struct CategorySummary: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let count: Int

    public init(name: String, logicalBytes: Int64, allocatedBytes: Int64, count: Int) {
        self.id = name
        self.name = name
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.count = count
    }
}

public struct ScanIssue: Codable, Sendable, Identifiable {
    public let id: String
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.id = path + "::" + reason
        self.path = path
        self.reason = reason
    }
}
