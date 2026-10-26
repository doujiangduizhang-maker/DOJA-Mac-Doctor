import Foundation
import Darwin
import DoctorCore

/// Deliberately synthetic capacity samples exercise thresholds; filesystem and
/// SQLite persistence checks use only newly created UUID-owned fixtures.
enum MonitoringSelfCheck {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(parent: URL?, allowSmallInternalFixtures: Bool) throws {
        guard let parent else { throw Failure(description: "监控自测需要显式 --fixture-root。") }
        var volume = statfs()
        guard parent.path.withCString({ statfs($0, &volume) }) == 0 else {
            throw Failure(description: "请先建立自测父目录。")
        }
        var internalVolume = statfs()
        _ = statfs("/", &internalVolume)
        if volume.f_fsid.val.0 == internalVolume.f_fsid.val.0 && !allowSmallInternalFixtures {
            throw Failure(description: "内部盘自测需显式 --allow-small-internal-fixtures。")
        }
        guard UInt64(volume.f_bavail) * UInt64(volume.f_bsize) > 100 * 1024 * 1024 else {
            throw Failure(description: "自测卷剩余空间不足 100 MiB，未写入夹具。")
        }
        let fixture = parent.appendingPathComponent("DOJA-monitor-self-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        var assertions = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw Failure(description: message) }
            assertions += 1
            print("通过：\(message)")
        }
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        func sample(_ offset: TimeInterval, free: Int64?, swap: Int64? = 0,
                    volume: String = "/System/Volumes/Data", pressure: String = "正常") throws -> SystemSample {
            var object: [String: Any] = ["timestamp": epoch.addingTimeInterval(offset).timeIntervalSinceReferenceDate,
                "volumePath": volume, "totalBytes": Int64(245_000_000_000),
                "memoryPressure": pressure, "errors": []]
            if let free { object["availableBytes"] = free; object["usedBytes"] = 245_000_000_000 - free }
            if let swap { object["swapUsedBytes"] = swap; object["swapTotalBytes"] = swap }
            return try JSONDecoder().decode(SystemSample.self, from: JSONSerialization.data(withJSONObject: object))
        }
        func directory(_ offset: TimeInterval, allocated: Int64, complete: Bool = true,
                       path: String? = nil) -> DirectoryObservation {
            DirectoryObservation(path: path ?? fixture.path, logicalBytes: allocated, allocatedBytes: allocated,
                                 observedAt: epoch.addingTimeInterval(offset), isComplete: complete,
                                 reason: complete ? nil : "测试：未完整覆盖")
        }
        let database = fixture.appendingPathComponent("history.sqlite")
        var store: MonitoringStore? = try MonitoringStore(url: database)
        let first = try store!.record(sample: sample(0, free: 20_000_000_000), directories: [directory(0, allocated: 1000)])
        try check(first == nil, "单次采样不生成异常")
        for minute in 1...9 {
            let event = try store!.record(sample: sample(Double(minute * 60), free: 20_000_000_000), directories: [])
            try check(event == nil, "稳定采样 \(minute) 不生成异常")
        }
        let threshold = try store!.record(sample: sample(600, free: 17_000_000_000), directories: [directory(600, allocated: 2000)])
        try check(threshold == nil, "恰好减少3GB未超过阈值")
        let anomaly = try store!.record(sample: sample(660, free: 16_900_000_000, swap: 500_000_000, pressure: "偏高"),
                                        directories: [directory(660, allocated: 3000)])
        try check(anomaly != nil, "连续10分钟内超过3GB生成事件")
        if let anomaly {
            try check(anomaly.dropBytes >= 3_100_000_000, "事件保留实际容量差")
            try check(anomaly.memoryPressure == "偏高" && anomaly.swapUsedBytes == 500_000_000, "事件保留内存与Swap证据")
            try check(anomaly.explanation.contains("原因待确认"), "同期线索不会冒充确定原因")
        }
        let duplicate = try store!.record(sample: sample(720, free: 16_900_000_000), directories: [])
        try check(duplicate == nil || duplicate?.id == anomaly?.id, "同一空间减少只更新原事件，不新增条目")
        let original = try store!.loadSnapshot(limit: 1440)
        try check(original.samples.count >= 12 && original.events.count == 1, "SQLite保留采样与事件")
        try check(store!.fileBytes <= 16 * 1024 * 1024, "数据库文件受容量上限约束")
        store = nil
        store = try MonitoringStore(url: database)
        let reopened = try store!.loadSnapshot(limit: 1440)
        try check(reopened.samples.count == original.samples.count && reopened.events.count == original.events.count,
                  "重新打开保留历史")
        let short = try store!.loadSnapshot(limit: 2)
        try check(short.samples.count == 2, "查询遵守采样数量限制")

        let gapStore = try MonitoringStore(url: fixture.appendingPathComponent("gap.sqlite"))
        _ = try gapStore.record(sample: sample(0, free: 20_000_000_000), directories: [])
        let gap = try gapStore.record(sample: sample(300, free: 10_000_000_000), directories: [])
        try check(gap == nil, "超过150秒的记录断点不归因为连续骤降")
        let otherVolume = try gapStore.record(sample: sample(360, free: 5_000_000_000, volume: "/different-volume"), directories: [])
        try check(otherVolume == nil, "不同卷容量不可互相比")
        let missing = try gapStore.record(sample: sample(420, free: nil, volume: "/different-volume"), directories: [])
        try check(missing == nil, "容量读取失败不当成零空间")

        let partialStore = try MonitoringStore(url: fixture.appendingPathComponent("partial.sqlite"))
        _ = try partialStore.record(sample: sample(0, free: 20_000_000_000), directories: [directory(0, allocated: 1000, complete: false)])
        let partial = try partialStore.record(sample: sample(60, free: 16_000_000_000), directories: [directory(60, allocated: 5000)])
        try check(partial?.directoryChanges.isEmpty == true, "不完整目录不能生成占用差证据")

        let alignedStore = try MonitoringStore(url: fixture.appendingPathComponent("aligned.sqlite"))
        _ = try alignedStore.record(sample: sample(0, free: 20_000_000_000, swap: 100), directories: [directory(0, allocated: 1000)])
        let aligned = try alignedStore.record(sample: sample(60, free: 16_000_000_000, swap: 500), directories: [directory(60, allocated: 5000)])
        try check(aligned?.directoryChanges.first?.beforeAllocatedBytes == 1000 && aligned?.directoryChanges.first?.afterAllocatedBytes == 5000,
                  "完整且同期目录保留前后实测量")
        try check(aligned?.swapDeltaBytes == 400, "Swap变化量来自同一事件窗口")
        let dirtyStore = try MonitoringStore(url: fixture.appendingPathComponent("dirty.sqlite"))
        _ = try dirtyStore.record(sample: sample(0, free: 20_000_000_000), directories: [directory(0, allocated: 1000)])
        _ = try dirtyStore.record(sample: sample(60, free: 19_000_000_000), directories: [directory(60, allocated: 5000)])
        let dirtyEvent = try dirtyStore.record(sample: sample(90, free: 16_000_000_000),
                                              directories: [directory(60, allocated: 5000, complete: false)])
        try check(dirtyEvent?.directoryChanges.isEmpty == true, "当前待核对状态优先于同时间的历史完整值")
        let verifiedEvent = try dirtyStore.record(sample: sample(120, free: 15_000_000_000),
                                                 directories: [directory(120, allocated: 8000)])
        try check(verifiedEvent?.directoryChanges.isEmpty == false, "重新核对后可使用未被改写的历史基线")
        let staleStore = try MonitoringStore(url: fixture.appendingPathComponent("stale.sqlite"))
        _ = try staleStore.record(sample: sample(0, free: 20_000_000_000), directories: [directory(-600, allocated: 1000)])
        let stale = try staleStore.record(sample: sample(60, free: 16_000_000_000), directories: [directory(60, allocated: 5000)])
        try check(stale?.directoryChanges.isEmpty == true, "陈旧目录基线不作为同期变化证据")

        let beforeLow = try Data(contentsOf: database)
        _ = try store!.record(sample: sample(780, free: 50_000_000), directories: [])
        let afterLow = try store!.loadSnapshot(limit: 1440)
        let afterLowBytes = try Data(contentsOf: database)
        try check(beforeLow == afterLowBytes, "低空间数据库逐字节不变，避免扩大占用")
        try check(afterLow.status != nil, "低空间暂停具有明确状态")

        let urgentURL = fixture.appendingPathComponent("urgent.sqlite")
        let urgentStore = try MonitoringStore(url: urgentURL)
        _ = try urgentStore.record(sample: sample(0, free: 20_000_000_000), directories: [])
        let urgentBefore = try Data(contentsOf: urgentURL)
        let urgent = try urgentStore.record(sample: sample(60, free: 50_000_000, pressure: "紧张"), directories: [])
        let urgentAfter = try Data(contentsOf: urgentURL)
        try check(urgent?.dropBytes == 19_950_000_000, "骤降至低空间仍在内存中生成真实差值事件")
        let urgentSnapshot = try urgentStore.loadSnapshot()
        try check(urgentSnapshot.events.count == 1 && urgentSnapshot.status != nil, "未保存的低空间异常仍可显示且说明暂存")
        try check(urgentBefore == urgentAfter, "低空间异常不写入数据库")

        let ageStore = try MonitoringStore(url: fixture.appendingPathComponent("age.sqlite"))
        _ = try ageStore.record(sample: sample(0, free: 20_000_000_000), directories: [])
        _ = try ageStore.record(sample: sample(15 * 86400, free: 20_000_000_000), directories: [])
        let aged = try ageStore.loadSnapshot()
        try check(aged.samples.count == 1, "超过14天的旧采样轮换移除")

        let linkSource = fixture.appendingPathComponent("link-source.sqlite")
        do { _ = try MonitoringStore(url: linkSource) }
        let linkAlias = fixture.appendingPathComponent("link-alias.sqlite")
        let linkCreated = linkSource.path.withCString { source in linkAlias.path.withCString { link(source, $0) } } == 0
        guard linkCreated else { throw Failure(description: "硬链接夹具建立失败。") }
        let linkedBefore = try Data(contentsOf: linkSource)
        var linkedRejected = false
        do { _ = try MonitoringStore(url: linkAlias) } catch { linkedRejected = true }
        try check(linkedRejected, "历史数据库硬链接拒绝打开写入")
        let linkedAfter = try Data(contentsOf: linkSource)
        try check(linkedBefore == linkedAfter, "拒绝硬链接不修改原数据库")

        let stressURL = fixture.appendingPathComponent("quota.sqlite")
        let stressStore = try MonitoringStore(url: stressURL)
        let stressPaths = (0..<8).map { fixture.appendingPathComponent("stress-\($0)") }
        for path in stressPaths { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
        let stressReason = String(repeating: "x", count: 4096)
        for index in 0..<420 {
            let offset = Double(index * 60)
            let observations = stressPaths.map { path in
                DirectoryObservation(path: path.path, logicalBytes: 1024, allocatedBytes: 4096,
                    observedAt: epoch.addingTimeInterval(offset), isComplete: true, reason: stressReason)
            }
            _ = try stressStore.record(sample: sample(offset, free: 20_000_000_000), directories: observations)
        }
        let stressSnapshot = try stressStore.loadSnapshot()
        try check(stressStore.fileBytes <= MonitoringStore.maximumDatabaseBytes, "大记录压力测试遵守16MiB主库上限")
        try check(stressSnapshot.samples.count < 420, "容量压力确实轮换旧记录而非无限累积")
        try check(stressSnapshot.samples.last?.timestamp == epoch.addingTimeInterval(419 * 60), "容量轮换后仍可写入最新采样")
        try check(stressSnapshot.directories.count == 8, "轮换保留重点目录最新状态")

        let corrupt = fixture.appendingPathComponent("corrupt.sqlite")
        let marker = Data("DOJA-owned-corrupt-fixture".utf8)
        try marker.write(to: corrupt)
        var rejected = false
        do { _ = try MonitoringStore(url: corrupt) } catch { rejected = true }
        try check(rejected, "损坏数据库拒绝使用")
        let preserved = try Data(contentsOf: corrupt)
        try check(preserved == marker, "损坏数据库不被静默覆盖")

        let tree = fixture.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        for index in 0..<8 { try Data(repeating: UInt8(index), count: 1024).write(to: tree.appendingPathComponent("entry-\(index).bin")) }
        let scanner = DiskScanner()
        let limited = scanner.scan(options: ScanOptions(roots: [tree], maxFiles: 2), control: ScanControl())
        try check(limited.status != .completed && limited.fileCount <= 2, "监控扫描遵守文件数预算且标未完成")
        try check(limited.directories.contains { $0.path == tree.path && !$0.isComplete }, "预算部分统计不当成完整目录")
        let baseline = scanner.scan(options: ScanOptions(roots: [tree]), control: ScanControl())
        let monitor = DirectoryMonitor()
        defer { monitor.stop() }
        monitor.start(paths: [tree.path], baseline: baseline)
        let readyDeadline = Date().addingTimeInterval(5)
        while monitor.observations().first?.isComplete != true && Date() < readyDeadline { Thread.sleep(forTimeInterval: 0.05) }
        try check(monitor.observations().first?.logicalBytes == 8 * 1024, "重点目录以真实扫描建立基线")
        try Data(repeating: 42, count: 4096).write(to: tree.appendingPathComponent("entry-0.bin"))
        let eventDeadline = Date().addingTimeInterval(8)
        while monitor.observations().first?.isComplete != false && Date() < eventDeadline { Thread.sleep(forTimeInterval: 0.1) }
        try check(monitor.observations().first?.isComplete == false, "真实系统目录事件标记变化待核对")
        try check(monitor.observations().first?.logicalBytes != 0, "待核对目录保留旧测量但不作为零占用")
        monitor.setSuspended(true)
        monitor.requestRefresh()
        try check(monitor.observations().first?.isComplete != true, "深度扫描暂停监控核对不伪造新测量")
        print("\n监控独立自测：\(assertions) 项通过。容量与目录数值明确用于测试；SQLite、预算与目录事件使用自建真实夹具。没有生产扫描结果被伪造。")
    }
}
