import Foundation

public struct ExportInventory: Codable, Sendable {
    public let totalDirectoryRecords: Int
    public let exportedDirectoryRecords: Int
    public let totalCoverageIssues: Int
    public let exportedCoverageIssues: Int
    public let note: String

    public init(full: ScanResult, exported: ScanResult) {
        totalDirectoryRecords = full.directories.count
        exportedDirectoryRecords = exported.directories.count
        totalCoverageIssues = full.issues.count
        exportedCoverageIssues = exported.issues.count
        note = "导出最多保留 2000 个最大目录及扫描根目录、1000 条覆盖问题；汇总大小和完整性仍来自全部扫描数据。未导出的条目不视为不存在。两次导出报告比较仅覆盖双方保留的完整目录。"
    }
}

extension ScanResult {
    /// Bounded presentation/export inventory; preserve full aggregate counts
    /// with ExportInventory. Apply only after full diagnosis and safety checks.
    public func boundedForExport() -> ScanResult {
        let selected = Array(directories.prefix(2000))
        let selectedPaths = Set(selected.map(\.path))
        let missingRoots = directories.filter { roots.contains($0.path) && !selectedPaths.contains($0.path) }
        return ScanResult(roots: roots, startedAt: startedAt, finishedAt: finishedAt, status: status,
                          directories: selected + missingRoots, largestFiles: largestFiles,
                          recentLargeFiles: recentLargeFiles, categories: categories,
                          issues: Array(issues.prefix(1000)), fileCount: fileCount,
                          logicalBytes: logicalBytes, allocatedBytes: allocatedBytes,
                          skippedSymlinks: skippedSymlinks)
    }
}
