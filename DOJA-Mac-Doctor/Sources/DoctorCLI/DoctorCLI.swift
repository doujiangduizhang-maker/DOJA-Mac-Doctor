import Foundation
import Darwin
import DoctorCore

private struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Arguments {
    var roots: [URL] = []
    var projects: [String] = []
    var output: URL?
    var previous: URL?
    var threshold: Int64 = 100 * 1024 * 1024
    var selfCheck = false
    var cleanupSelfCheck = false
    var systemTrashSelfCheck = false
    var monitorSelfCheck = false
    var fixtureRoot: URL?
    var allowSmallInternalFixtures = false
    var help = false

    init(_ values: [String]) throws {
        var index = 0
        while index < values.count {
            let value = values[index]
            func parameter() throws -> String {
                guard index + 1 < values.count else { throw CLIError("\(value) 缺少参数。") }
                index += 1
                return values[index]
            }
            switch value {
            case "--help", "-h": help = true
            case "--self-check": selfCheck = true
            case "--cleanup-self-check": cleanupSelfCheck = true
            case "--system-trash-self-check": systemTrashSelfCheck = true
            case "--monitor-self-check": monitorSelfCheck = true
            case "--fixture-root": fixtureRoot = try Self.absoluteURL(parameter())
            case "--allow-small-internal-fixtures": allowSmallInternalFixtures = true
            case "--output": output = try Self.absoluteURL(parameter())
            case "--compare": previous = try Self.absoluteURL(parameter())
            case "--project": projects.append(try Self.absoluteURL(parameter()).path)
            case "--threshold-mb":
                let raw = try parameter()
                guard let megabytes = Int64(raw), megabytes > 0,
                      megabytes <= Int64.max / (1024 * 1024) else {
                    throw CLIError("--threshold-mb 必须是正整数。")
                }
                threshold = megabytes * 1024 * 1024
            case "--":
                for path in values.dropFirst(index + 1) { roots.append(try Self.absoluteURL(path)) }
                index = values.count
                continue
            default:
                guard !value.hasPrefix("-") else { throw CLIError("未知选项：\(value)") }
                roots.append(try Self.absoluteURL(value))
            }
            index += 1
        }
        guard [selfCheck, cleanupSelfCheck, systemTrashSelfCheck, monitorSelfCheck].filter({ $0 }).count <= 1 else { throw CLIError("请分别运行每种独立自测。") }
        let isValidation = selfCheck || cleanupSelfCheck || systemTrashSelfCheck || monitorSelfCheck
        if isValidation && (!roots.isEmpty || !projects.isEmpty || output != nil || previous != nil) {
            throw CLIError("自测与目录扫描、报告输出和历史比较分开运行。")
        }
        if fixtureRoot != nil && !isValidation { throw CLIError("--fixture-root 仅用于独立自测。") }
        if allowSmallInternalFixtures && (!isValidation || fixtureRoot == nil) {
            throw CLIError("--allow-small-internal-fixtures 必须与独立自测和显式 --fixture-root 一起使用。")
        }
        if !help && !isValidation && roots.isEmpty {
            throw CLIError("请指定至少一个获授权的目录完整路径，或使用 --help。")
        }
    }

    static func absoluteURL(_ value: String) throws -> URL {
        guard value.hasPrefix("/"), !value.contains("\0") else {
            throw CLIError("请使用完整的绝对路径：\(value)")
        }
        return URL(fileURLWithPath: value)
    }
}

private struct ScanReport: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let system: SystemSample
    let scan: ScanResult
    let findings: [DiagnosticFinding]
    let growth: [GrowthFinding]
    let comparisonNote: String?
    let accountingNote: String
    var exportInventory: ExportInventory? = nil

    func boundedForExport() -> ScanReport {
        let limited = scan.boundedForExport()
        var result = ScanReport(schemaVersion: schemaVersion, generatedAt: generatedAt, system: system,
                                scan: limited, findings: Array(findings.prefix(500)), growth: growth,
                                comparisonNote: comparisonNote, accountingNote: accountingNote)
        result.exportInventory = ExportInventory(full: scan, exported: limited)
        return result
    }
}

@main
private enum DoctorCLI {
    static func main() {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            if arguments.help { print(help); return }
            if arguments.selfCheck {
                try SelfCheck.run(parent: arguments.fixtureRoot, allowSmallInternalFixtures: arguments.allowSmallInternalFixtures)
                return
            }
            if arguments.cleanupSelfCheck {
                try CleanupSelfCheck.run(parent: arguments.fixtureRoot, allowSmallInternalFixtures: arguments.allowSmallInternalFixtures)
                return
            }
            if arguments.systemTrashSelfCheck {
                try CleanupSelfCheck.runSystemTrash(parent: arguments.fixtureRoot, allowSmallInternalFixtures: arguments.allowSmallInternalFixtures)
                return
            }
            if arguments.monitorSelfCheck {
                try MonitoringSelfCheck.run(parent: arguments.fixtureRoot, allowSmallInternalFixtures: arguments.allowSmallInternalFixtures)
                return
            }
            let result = DiskScanner().scan(options: ScanOptions(roots: arguments.roots,
                                                                 largeFileThreshold: arguments.threshold),
                                            control: ScanControl())
            let engine = DiagnosisEngine()
            let findings = engine.findings(for: result, projectRoots: arguments.projects)
            var growth: [GrowthFinding] = []
            var comparisonNote: String?
            if let previousURL = arguments.previous {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .millisecondsSince1970
                let previous = try decoder.decode(ScanReport.self, from: Data(contentsOf: previousURL))
                guard previous.schemaVersion == 1 else { throw CLIError("历史报告版本不兼容。") }
                growth = engine.growth(previous: previous.scan, current: result)
                comparisonNote = comparisonExplanation(previous: previous.scan, current: result, growth: growth)
            }
            let report = ScanReport(schemaVersion: 1, generatedAt: Date(), system: SystemMetrics.sample(),
                                    scan: result, findings: findings, growth: growth,
                                    comparisonNote: comparisonNote,
                                    accountingNote: "逻辑大小按文件路径累计；已分配大小按文件身份去重并包含目录元数据。APFS 克隆、快照及扫描范围外的硬链接可能共享或保留磁盘块；这些值不能证明删除可释放的空间。第一阶段只读，不删除或移动文件。")
            printReport(report)
            if let output = arguments.output {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .millisecondsSince1970
                let data = try encoder.encode(report.boundedForExport())
                guard data.count <= 8 * 1024 * 1024 else { throw CLIError("报告超过 8 MB，未写入；请缩小扫描范围。") }
                try data.write(to: output, options: .atomic)
                print("\n已保存真实扫描报告：\(output.path)")
            }
        } catch {
            FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
            exit(1)
        }
    }

    private static var help: String {
        """
        DOJA Mac Doctor · 只读扫描与安全自测

        用法：doctor-scan [选项] /完整/目录路径 [/其他/目录]
          --threshold-mb N       最近 7 天大文件阈值，默认 100 MiB
          --project /完整/路径   将目录作为用户开发项目分析，可重复指定
          --output /完整/报告.json  保存真实扫描报告，替换该指定文件
          --compare /完整/旧报告.json  比较相同扫描范围的历史报告
          --self-check           用隔离的真实文件检查扫描、安全和诊断规则
          --cleanup-self-check   用隔离缓存与注入式废纸篓检查确认处理安全，不处理用户数据
          --system-trash-self-check  仅将本次创建的隔离缓存移入系统废纸篓并立即完整恢复
          --monitor-self-check   用隔离数据库、明确的测试采样与真实目录事件检查监控
          --fixture-root /完整/目录  自测文件的父目录，默认要求外置卷
          --allow-small-internal-fixtures  显式允许内部卷隔离小夹具，仅用于自测
          --help                 显示说明

        扫描遇到无权限会记录“未扫描”。符号链接不会跟随。扫描只读；
        逻辑大小与已分配大小均不等于 APFS 实际可回收空间。
        单次扫描没有异常发生前的记录，因此不能确认过去突然减小的原因。
        """
    }

    private static func comparisonExplanation(previous: ScanResult, current: ScanResult,
                                              growth: [GrowthFinding]) -> String {
        guard previous.status == .completed, current.status == .completed else {
            return "至少一次扫描已取消，不能作为完整增长基线。"
        }
        guard Set(previous.roots) == Set(current.roots) else { return "扫描范围不同，不能比较。" }
        guard previous.startedAt < current.startedAt else { return "历史报告时间不早于本次，不能比较。" }
        if !previous.issues.isEmpty || !current.issues.isEmpty {
            return "部分目录未完整扫描；仅比较两次都完整的相同目录。原因待确认。"
        }
        return growth.isEmpty ? "未发现可比较目录的正增长；单次或局部扫描无法解释卷上所有空间变化。"
            : "发现目录增长。这只是两次扫描之间的变化证据，无法直接证明具体应用或原因。"
    }

    private static func printReport(_ report: ScanReport) {
        let scan = report.scan
        print("DOJA Mac Doctor · 真实数据 · 只读扫描")
        print("内部卷总容量：\(DoctorFormat.bytes(report.system.totalBytes))  剩余：\(DoctorFormat.bytes(report.system.availableBytes))")
        print("内存压力：\(report.system.memoryPressure)  Swap：\(DoctorFormat.bytes(report.system.swapUsedBytes))")
        print("扫描文件：\(scan.fileCount)  逻辑总量：\(DoctorFormat.bytes(scan.logicalBytes))  已分配：\(DoctorFormat.bytes(scan.allocatedBytes))")
        print("未扫描/读取问题：\(scan.issues.count)  已跳过符号链接：\(scan.skippedSymlinks)")
        print("\n占用最大的 20 个目录（目录存在包含关系，请勿相加）：")
        for record in scan.directories.sorted(by: { $0.logicalBytes > $1.logicalBytes }).prefix(20) {
            print("\(DoctorFormat.bytes(record.logicalBytes)) | 已分配 \(DoctorFormat.bytes(record.allocatedBytes)) | \(record.isComplete ? "完整" : "未完整扫描") | \(record.path)")
        }
        print("\n占用最大的 50 个文件：")
        for record in scan.largestFiles.prefix(50) {
            print("\(DoctorFormat.bytes(record.logicalBytes)) | 已分配 \(DoctorFormat.bytes(record.allocatedBytes)) | \(record.path)")
        }
        print("\n最近 7 天新增或修改的大文件（最多列出 50 条）：\(scan.recentLargeFiles.count) 条")
        for record in scan.recentLargeFiles.prefix(50) {
            print("\(DoctorFormat.bytes(record.logicalBytes)) | \(record.path)")
        }
        print("\n专项诊断与建议：")
        if report.findings.isEmpty { print("当前授权扫描范围内未命中专项诊断规则。") }
        for item in report.findings.prefix(100) {
            let level = item.risk == .green ? "绿色" : item.risk == .yellow ? "黄色" : "红色"
            print("[\(level)] \(item.title) | \(DoctorFormat.bytes(item.logicalBytes)) | \(item.path)")
            print("  \(item.advice)")
        }
        for issue in scan.issues.prefix(100) { print("未扫描：\(issue.path) · \(issue.reason)") }
        if let note = report.comparisonNote { print("\n历史比较：\(note)") }
        for change in report.growth.prefix(20) {
            print("增长 \(DoctorFormat.bytes(change.logicalDelta)) | 已分配变化 \(DoctorFormat.bytes(change.allocatedDelta)) | \(change.path)")
        }
        if report.comparisonNote == nil {
            print("\n过去空间突减的原因：原因待确认。尚无异常前的可比较扫描或监控记录。")
        }
        print("\n\(report.accountingNote)")
    }
}

private enum SelfCheck {
    static func run(parent suppliedParent: URL?, allowSmallInternalFixtures: Bool) throws {
        let fm = FileManager.default
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let requestedParent = suppliedParent ?? package.appendingPathComponent(".validation-fixtures")
        var existing = requestedParent
        var suffix: [String] = []
        while !fm.fileExists(atPath: existing.path) && existing.path != "/" {
            suffix.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        guard let resolved = existing.path.withCString({ realpath($0, nil) }) else {
            throw CLIError("无法解析自测父目录：\(String(cString: strerror(errno)))")
        }
        let existingPath = String(cString: resolved)
        free(resolved)
        let parent = suffix.reversed().reduce(URL(fileURLWithPath: existingPath)) {
            $0.appendingPathComponent($1)
        }
        let volume = try existing.resourceValues(forKeys: [.volumeIsInternalKey])
        guard volume.volumeIsInternal == false || allowSmallInternalFixtures else {
            throw CLIError("自测会创建少量真实文件。请使用 --fixture-root 指定外置卷目录，避免占用紧张的内部磁盘。")
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let fixture = parent.appendingPathComponent("doctor-selfcheck-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
        let denied = fixture.appendingPathComponent("unreadable", isDirectory: true)
        defer {
            try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: denied.path)
            // The only removal is the isolated UUID directory created by this self-check.
            try? fm.removeItem(at: fixture)
        }
        var checks = 0
        var skips: [String] = []
        var fixtureFileBytes = 0
        let largeThreshold: Int64 = 16 * 1024
        func require(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw CLIError("自测失败：\(label)；隔离目录：\(fixture.path)") }
            checks += 1
            print("通过：\(label)")
        }
        func makeFile(_ relative: String, bytes: Int) throws -> URL {
            guard bytes >= 0, fixtureFileBytes + bytes <= 256 * 1024 else {
                throw CLIError("自测常规文件夹具超过 256 KiB 上限。")
            }
            fixtureFileBytes += bytes
            let url = fixture.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x31, count: bytes).write(to: url)
            return url
        }
        @Sendable func scan(_ roots: [URL], control: ScanControl = ScanControl()) -> ScanResult {
            DiskScanner().scan(options: ScanOptions(roots: roots, largeFileThreshold: largeThreshold), control: control)
        }
        let recent = try makeFile("recent-large.bin", bytes: Int(largeThreshold) + 17)
        let small = try makeFile("project/main.swift", bytes: 4096)
        let protectedMedia = try makeFile("project/footage.mov", bytes: 4096)
        let session = try makeFile(".codex/sessions/session.jsonl", bytes: 4096)
        let crash = try makeFile("Library/Application Support/Codex/Crashpad/pending/crash.dmp", bytes: 4096)
        let codexLog = try makeFile(".codex/log/codex-tui.log", bytes: 1024)
        let configuration = try makeFile(".codex/config.toml", bytes: 128)
        let projectCache = try makeFile("project/node_modules/example/index.js", bytes: 4096)
        let old = try makeFile("old-large.bin", bytes: Int(largeThreshold) + 19)
        let oldDate = Date().addingTimeInterval(-12 * 24 * 60 * 60)
        try fm.setAttributes([.modificationDate: oldDate, .creationDate: oldDate], ofItemAtPath: old.path)

        let baseline = scan([fixture])
        try require(baseline.status == .completed, "真实目录扫描完成")
        try require(baseline.issues.isEmpty,
                    "自测目录可完整读取：\(baseline.issues.map { $0.path + " · " + $0.reason }.joined(separator: "；"))")
        try require(baseline.largestFiles.contains { $0.path == recent.path && $0.logicalBytes == largeThreshold + 17 }, "真实文件逻辑大小准确")
        try require(baseline.recentLargeFiles.contains { $0.path == recent.path }, "最近 7 天大文件检测")
        try require(!baseline.recentLargeFiles.contains { $0.path == small.path }, "大文件阈值不会包括小文件")
        if let oldRecord = baseline.largestFiles.first(where: { $0.path == old.path }),
           oldRecord.modifiedAt < Date().addingTimeInterval(-7 * 24 * 60 * 60),
           (oldRecord.createdAt ?? oldRecord.modifiedAt) < Date().addingTimeInterval(-7 * 24 * 60 * 60) {
            try require(!baseline.recentLargeFiles.contains { $0.path == old.path }, "旧文件不误报为最近新增或修改")
        } else { skips.append("外置文件系统不支持设置创建日期；旧文件排除检查未执行") }

        let overlap = scan([fixture, fixture.appendingPathComponent("project"), fixture])
        try require(overlap.logicalBytes == baseline.logicalBytes && overlap.fileCount == baseline.fileCount,
                    "重复与重叠扫描范围不会重复计数")
        let caseAlias = fixture.deletingLastPathComponent().appendingPathComponent(fixture.lastPathComponent.uppercased())
        if fm.fileExists(atPath: caseAlias.path) {
            let aliased = scan([fixture, caseAlias, caseAlias.appendingPathComponent("PROJECT")])
            try require(aliased.logicalBytes == baseline.logicalBytes && aliased.fileCount == baseline.fileCount,
                        "大小写不敏感卷的重复及嵌套路径别名不重复计数")
        } else { skips.append("当前卷区分大小写；大小写别名检查不适用") }

        let symlink = fixture.appendingPathComponent("outside-link")
        if symlink.path.withCString({ Darwin.symlink("/Users", $0) }) == 0 {
            let noFollow = scan([fixture])
            // exFAT may create a real AppleDouble metadata sidecar for this link.
            // Verify no target subtree was visited rather than assuming zero metadata growth.
            try require(noFollow.skippedSymlinks >= 1 && !noFollow.directories.contains { $0.path.hasPrefix(symlink.path + "/") },
                        "目录中的符号链接不会跟随")
            let rootLink = scan([symlink])
            try require(rootLink.fileCount == 0 && !rootLink.issues.isEmpty, "符号链接作为扫描根会被拒绝并报告")
            let ancestorLink = scan([symlink.appendingPathComponent(NSUserName())])
            try require(ancestorLink.fileCount == 0 && !ancestorLink.issues.isEmpty,
                        "扫描路径祖先中的符号链接也会被拒绝")
            guard symlink.path.withCString({ unlink($0) }) == 0 else {
                throw CLIError("无法移除本次自测创建的符号链接夹具。")
            }
        } else if errno == ENOTSUP || errno == EPERM {
            skips.append("外置文件系统不支持符号链接：\(String(cString: strerror(errno)))")
        } else {
            throw CLIError("无法创建隔离符号链接：\(String(cString: strerror(errno)))")
        }

        let sparse = fixture.appendingPathComponent("sparse.bin")
        let descriptor = sparse.path.withCString { open($0, O_CREAT | O_EXCL | O_RDWR, 0o600) }
        guard descriptor >= 0 else { throw CLIError("无法创建隔离稀疏文件：\(String(cString: strerror(errno)))") }
        let truncateResult = ftruncate(descriptor, 8 * 1024 * 1024)
        close(descriptor)
        guard truncateResult == 0 else { throw CLIError("无法设置隔离文件大小。") }
        let sparseScan = scan([fixture])
        let sparseRecord = sparseScan.largestFiles.first { $0.path == sparse.path }
        try require(sparseRecord?.logicalBytes == 8 * 1024 * 1024, "稀疏文件逻辑大小与文件系统一致")
        if let record = sparseRecord, record.allocatedBytes < record.logicalBytes {
            try require(record.allocatedBytes < record.logicalBytes, "稀疏文件显示独立的实际已分配大小")
        } else { skips.append("外置文件系统未稀疏分配；不伪造物理大小差异") }
        if volume.volumeIsInternal != false {
            try require((sparseRecord?.allocatedBytes ?? Int64.max) <= 64 * 1024,
                        "内部卷稀疏夹具实际分配不超过 64 KiB")
        }

        let hardLink = fixture.appendingPathComponent("recent-hardlink.bin")
        let beforeLink = scan([fixture])
        let beforeDirectoryAllocation = try directoryAllocation(fixture)
        if recent.path.withCString({ source in hardLink.path.withCString { target in link(source, target) } }) == 0 {
            let afterLink = scan([fixture])
            let directoryDelta = try directoryAllocation(fixture) - beforeDirectoryAllocation
            try require(afterLink.logicalBytes - beforeLink.logicalBytes == largeThreshold + 17,
                        "硬链接按路径显示逻辑大小")
            try require(afterLink.allocatedBytes - beforeLink.allocatedBytes == directoryDelta,
                        "硬链接物理统计按文件身份去重")
            try require(afterLink.largestFiles.first { $0.path == hardLink.path }?.linkCount == 2,
                        "硬链接数量读取准确")
        } else { skips.append("外置文件系统不支持硬链接：\(String(cString: strerror(errno)))") }

        try fm.createDirectory(at: denied, withIntermediateDirectories: false)
        _ = try makeFile("unreadable/private.bin", bytes: 2048)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0)], ofItemAtPath: denied.path)
        let incomplete = scan([fixture])
        if incomplete.issues.contains(where: { $0.path == denied.path }) {
            try require(incomplete.directories.contains { $0.path == fixture.path && !$0.isComplete },
                        "无权限目录明确记为未扫描并传播到父目录")
        } else { skips.append("当前进程或外置卷未执行 POSIX 权限限制；无权限实测未执行") }
        let missing = fixture.appendingPathComponent("not-created")
        let missingScan = scan([missing])
        try require(!missingScan.issues.isEmpty && missingScan.fileCount == 0, "不存在目录报告未扫描")
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: denied.path)

        let engine = DiagnosisEngine()
        let findings = engine.findings(for: baseline, projectRoots: [fixture.appendingPathComponent("project").path])
        try require(findings.contains { $0.path.hasSuffix("Crashpad/pending") && $0.risk == .yellow },
                    "Codex 崩溃记录仅提供需判断建议")
        try require(findings.contains { $0.path.contains(".codex/sessions") && $0.risk == .red && $0.estimatedReclaimUpperBound == nil },
                    "Codex 会话记录受保护且不计入清理估计")
        try require(findings.contains { $0.path.hasSuffix("node_modules") && $0.risk == .yellow },
                    "开发依赖需用户判断，不自动删除")
        try require(findings.contains { $0.path == codexLog.deletingLastPathComponent().path && $0.risk == .yellow },
                    "真实 Codex 日志提供保留故障证据的建议")
        try require(findings.contains { $0.path == configuration.path && $0.risk == .red && $0.estimatedReclaimUpperBound == nil },
                    "Codex 用户配置默认保留")
        try require(!findings.contains { ($0.path == small.path || $0.path == protectedMedia.path) && $0.risk != .red },
                    "项目代码和原始媒体不会获得自动清理建议")
        try require(fm.fileExists(atPath: crash.path) && fm.fileExists(atPath: session.path)
                    && fm.fileExists(atPath: projectCache.path), "诊断完成后所有真实用户文件仍存在")

        let mixedCache = fixture.appendingPathComponent("Library/Application Support/Codex/GPUCache")
        for index in 0..<55 {
            _ = try makeFile("Library/Application Support/Codex/GPUCache/cache-\(index).bin", bytes: 1536)
        }
        let tinyCode = try makeFile("Library/Application Support/Codex/GPUCache/personal.swift", bytes: 7)
        let mixedScan = scan([fixture])
        try require(!mixedScan.largestFiles.contains { $0.path == tinyCode.path },
                    "保护回归夹具的小文件确实位于排名前 50 之外")
        let mixedFindings = engine.findings(for: mixedScan)
        try require(!mixedFindings.contains { $0.path == mixedCache.path && $0.risk != .red },
                    "缓存混有排名外的微小用户代码时不得建议整体清理")

        let cancelledControl = ScanControl()
        cancelledControl.cancel()
        let cancelled = scan([fixture], control: cancelledControl)
        try require(cancelled.status == .cancelled, "取消扫描会明确记录取消状态")
        let pauseControl = ScanControl()
        pauseControl.pause()
        let done = DispatchSemaphore(value: 0)
        let start = Date()
        DispatchQueue.global(qos: .utility).async {
            _ = scan([fixture], control: pauseControl)
            done.signal()
        }
        try require(done.wait(timeout: .now() + 0.1) == .timedOut && pauseControl.isPaused,
                    "暂停会阻止后台扫描推进")
        pauseControl.cancel()
        try require(done.wait(timeout: .now() + 2) == .success && Date().timeIntervalSince(start) < 2.5,
                    "暂停中的扫描能快速响应取消")
        let resumeControl = ScanControl()
        resumeControl.pause()
        resumeControl.resume()
        try require(!resumeControl.isPaused && scan([fixture], control: resumeControl).status == .completed,
                    "恢复后可正常完成扫描")

        let beforeGrowth = scan([fixture])
        _ = try makeFile("new-growth.bin", bytes: 16384)
        let afterGrowth = scan([fixture])
        if volume.volumeIsInternal != false {
            try require(afterGrowth.allocatedBytes <= 512 * 1024,
                        "内部卷整组夹具实际统计分配不超过 512 KiB")
        }
        let growth = engine.growth(previous: beforeGrowth, current: afterGrowth)
        let addedSidecar = fixture.appendingPathComponent("._new-growth.bin")
        var sidecarMetadata = stat()
        let addedMetadataBytes: Int64 = addedSidecar.path.withCString { lstat($0, &sidecarMetadata) } == 0 ? Int64(sidecarMetadata.st_size) : 0
        try require(growth.contains { $0.path == fixture.path && $0.logicalDelta == 16384 + addedMetadataBytes },
                    "两次真实扫描能识别新增文件引起的目录增长（含实际元数据侧文件）；实际增量 \(afterGrowth.logicalBytes - beforeGrowth.logicalBytes)，预期 \(16384 + addedMetadataBytes)，完整性 \(beforeGrowth.directories.first { $0.path == fixture.path }?.isComplete ?? false)/\(afterGrowth.directories.first { $0.path == fixture.path }?.isComplete ?? false)")
        try require(engine.growth(previous: cancelled, current: afterGrowth).isEmpty,
                    "取消的扫描不能作为增长基线")
        try require(engine.growth(previous: afterGrowth, current: beforeGrowth).isEmpty,
                    "反向时间顺序不能作为增长证据")
        try require(engine.growth(previous: baseline, current: scan([fixture.appendingPathComponent("project")])).isEmpty,
                    "不同扫描范围不会被强行比较")
        if incomplete.issues.contains(where: { $0.path == denied.path }) {
            try require(!engine.growth(previous: incomplete, current: afterGrowth).contains { $0.path == fixture.path },
                        "不完整目录不会被用作该目录的增长基线")
        }
        for skip in skips { print("未执行：\(skip)") }
        print("\n自测完成：\(checks) 项通过，\(skips.count) 项受文件系统或权限能力限制。")
        print("测试文件仅位于明确选择的隔离目录；常规内容不超过 256 KiB，结束后只清理本次夹具。应用扫描始终只读。")
    }

    private static func directoryAllocation(_ url: URL) throws -> Int64 {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            throw CLIError("无法读取测试目录分配大小。")
        }
        return Int64(status.st_blocks) * 512
    }
}
