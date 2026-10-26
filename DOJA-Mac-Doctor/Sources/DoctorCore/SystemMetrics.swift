import Foundation
import Darwin

public struct SystemSample: Codable, Sendable, Identifiable {
    public var id: Date { timestamp }
    public let timestamp: Date
    public let volumePath: String
    public let totalBytes: Int64?
    public let availableBytes: Int64?
    public let usedBytes: Int64?
    public let swapUsedBytes: Int64?
    public let swapTotalBytes: Int64?
    public let memoryPressure: String
    public let errors: [String]
}

public enum SystemMetrics {
    // statfs available space excludes the system's potentially purgeable estimate.
    // APFS volumes share their container; used capacity is not a directory sum.
    public static func sample(volume: URL = URL(fileURLWithPath: "/")) -> SystemSample {
        var info = statfs()
        let valid = volume.path.withCString { statfs($0, &info) } == 0
        var errors: [String] = []
        if !valid { errors.append("磁盘容量读取失败：\(String(cString: strerror(errno)))") }
        let total = valid ? Int64(clamping: info.f_blocks) * Int64(info.f_bsize) : nil
        let available = valid ? Int64(clamping: info.f_bavail) * Int64(info.f_bsize) : nil
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapValid = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        if !swapValid { errors.append("交换空间读取失败") }
        var pressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        let pressureValid = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0
        let label: String
        switch pressureValid ? pressure : 0 {
        case 1: label = "正常"
        case 2: label = "偏高"
        case 4: label = "紧张"
        default: label = "未知"
        }
        return SystemSample(timestamp: Date(), volumePath: volume.path,
                            totalBytes: total, availableBytes: available,
                            usedBytes: total.flatMap { t in available.map { max(0, t - $0) } },
                            swapUsedBytes: swapValid ? Int64(clamping: swap.xsu_used) : nil,
                            swapTotalBytes: swapValid ? Int64(clamping: swap.xsu_total) : nil,
                            memoryPressure: label, errors: errors)
    }
}

public enum DoctorFormat {
    public static func bytes(_ value: Int64?) -> String {
        guard let value else { return "未取得" }
        if value == 0 { return "0 B" }
        if value > -1_000, value < 1_000 { return "\(value) B" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesActualByteCount = false
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: value)
    }
}
