import SwiftUI
import AppKit
import DoctorCore

enum DoctorPage: String, CaseIterable, Identifiable {
    case dashboard = "扫描与清理", scan = "详细扫描", suggestions = "清理建议", applications = "应用诊断", guide = "使用说明"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .scan: return "internaldrive"
        case .suggestions: return "checkmark.shield"
        case .applications: return "app.badge"
        case .guide: return "info.circle"
        }
    }
}

struct GrantedDirectory: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let bookmark: Data
    let isProject: Bool
}

struct SavedGrant: Codable {
    let bookmark: Data
    let isProject: Bool
}

struct CleanupReceipt: Identifiable, Codable, Sendable {
    let id: UUID
    let recordedAt: Date
    let item: CleanupItemOutcome
}

@MainActor
final class DoctorState: ObservableObject {
    @Published var page: DoctorPage = .dashboard
    @Published var sample = SystemMetrics.sample(volume: URL(fileURLWithPath: "/System/Volumes/Data"))
    @Published var samples: [SystemSample] = []
    @Published var monitorEvents: [SpaceAnomaly] = []
    @Published var monitoredDirectories: [DirectoryObservation] = []
    @Published var monitoringStatus = "正在准备本机空间记录…"
    @Published var grants: [GrantedDirectory] = []
    @Published var result: ScanResult?
    @Published var scanInventory: ExportInventory?
    @Published var findings: [DiagnosticFinding] = []
    @Published var growth: [GrowthFinding] = []
    @Published var discovered: [DiscoveredPath] = []
    @Published var scanning = false
    @Published var paused = false
    @Published var progress: ScanProgress?
    @Published var notice: String?
    @Published var snapshotText: String?
    @Published var checkingSnapshots = false
    @Published var detail: InspectionItem?
    @Published var hasAutoStarted = false
    @Published var autoScanStatus = "打开后自动检查，稍候即可查看结果。"
    @Published var cleanupAssessments: [CleanupAssessment] = []
    @Published var selectedCleanupPaths: Set<String> = []
    @Published var cleaning = false
    @Published var cleanupPreparation = false
    @Published var cleanupOutcome: CleanupOutcome?
    @Published var cleanupReceipts: [CleanupReceipt] = []
    @Published var recoveryPaths: [String] = []
    @Published var cleanupNotice: String?
    private var control: ScanControl?
    private var preparedCleanupPlans: [String: CleanupPlan] = [:]
    private var timer: Timer?
    private var historyStore: MonitoringStore?
    private let directoryMonitor = DirectoryMonitor()
    private var monitoredScopes: [(URL, Bool)] = []
    private var writingHistory = false
    private var preparingHistory = false
    private var lastHistoryAttempt = Date.distantPast
    private var lastMonitorRecord: Date?
    private var receiptSaveWarning: String?
    private let grantsKey = "DOJAMacDoctor.readOnlyBookmarks.v1"
    private let receiptsKey = "DOJAMacDoctor.cleanupReceipts.v1"

    init() {
        restoreGrants()
        restoreCleanupReceipts()
        refreshDiscovery()
        samples = [sample]
        startHistory()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSample() }
        }
    }

    func refreshSample() {
        sample = SystemMetrics.sample(volume: URL(fileURLWithPath: "/System/Volumes/Data"))
        samples.append(sample)
        if samples.count > 1440 { samples.removeFirst(samples.count - 1440) }
        persistMonitorSample()
        if historyStore == nil, !preparingHistory,
           Date().timeIntervalSince(lastHistoryAttempt) >= 300,
           (sample.availableBytes ?? 0) >= MonitoringStore.minimumWriteFreeBytes {
            startHistory()
        }
    }

    private func startHistory() {
        guard historyStore == nil, !preparingHistory else { return }
        preparingHistory = true
        lastHistoryAttempt = Date()
        let database = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/DOJA Mac Doctor/space-history.sqlite")
        Task {
            do {
                let prepared = try await Task.detached(priority: .utility) {
                    let store = try MonitoringStore(url: database)
                    return (store, try store.loadSnapshot(limit: 1440))
                }.value
                historyStore = prepared.0
                var seen = Set<String>()
                samples = (prepared.1.samples + samples + [sample]).filter {
                    seen.insert("\($0.volumePath)::\($0.timestamp.timeIntervalSince1970)").inserted
                }.sorted { $0.timestamp < $1.timestamp }
                if samples.count > 1440 { samples.removeFirst(samples.count - 1440) }
                monitorEvents = prepared.1.events
                monitoringStatus = prepared.1.status ?? "每分钟记录容量、内存压力和交换空间；历史仅保存在本机。"
                persistMonitorSample()
            } catch {
                monitoringStatus = "历史记录暂不可用：\(error.localizedDescription)。当前容量仍可查看。"
            }
            preparingHistory = false
        }
    }

    private func persistMonitorSample() {
        let observations = directoryMonitor.observations()
        monitoredDirectories = observations
        guard let store = historyStore, !writingHistory else { return }
        // Manual refreshes update the UI without filling history with many
        // subminute samples or shortening the ten-minute comparison window.
        if let lastMonitorRecord, sample.timestamp >= lastMonitorRecord,
           sample.timestamp.timeIntervalSince(lastMonitorRecord) < 55 { return }
        lastMonitorRecord = sample.timestamp
        writingHistory = true
        let measured = sample
        Task {
            do {
                let saved = try await Task.detached(priority: .utility) {
                    let event = try store.record(sample: measured, directories: observations)
                    return (event, try store.loadSnapshot(limit: 1440))
                }.value
                monitorEvents = saved.1.events
                if let status = saved.1.status { monitoringStatus = status }
                else { monitoringStatus = "每分钟记录容量、内存压力和交换空间；重点目录变动后才限量核对。" }
                // Never replace the live sample with older history. Memory also
                // keeps the current actual reading when low space pauses writes.
                if saved.0 != nil { directoryMonitor.requestRefresh() }
            } catch {
                monitoringStatus = "历史写入已暂停：\(error.localizedDescription)。不会覆盖已有记录。"
            }
            writingHistory = false
        }
    }

    private func updateMonitoredDirectories(from scan: ScanResult) {
        // Prefer explicitly chosen work directories, then actual application
        // paths found by this scan. Nested choices are not summed for attribution.
        let preferred = grants.map { $0.url.path } + findings.filter {
            let path = $0.path.lowercased()
            return path.contains("crashpad/pending") || path.contains("/.codex/sessions") ||
                path.contains("/logs/com.openai.codex") || path.contains("/codex/gpucache") ||
                path.contains("/codex/code cache") || path.contains("/cacheclip") ||
                path.hasSuffix("/node_modules") || path.hasSuffix("/.next")
        }.map(\.path)
        let knownDirectories = Set(scan.directories.map(\.path))
        var unique = Set<String>()
        let paths = preferred.filter { knownDirectories.contains($0) && unique.insert($0).inserted }
        for (url, started) in monitoredScopes where started { url.stopAccessingSecurityScopedResource() }
        monitoredScopes = grants.filter { paths.prefix(8).contains($0.url.path) }.map {
            ($0.url, $0.url.startAccessingSecurityScopedResource())
        }
        directoryMonitor.start(paths: Array(paths.prefix(8)), baseline: scan)
        directoryMonitor.setSuspended(scanning || cleaning)
        monitoredDirectories = directoryMonitor.observations()
    }

    func chooseDirectory(project: Bool = false, initial: URL? = nil) {
        guard !scanning, !cleaning, !cleanupPreparation else { return }
        let panel = NSOpenPanel()
        panel.title = project ? "选择开发项目目录" : "选择授权扫描的目录"
        panel.prompt = "添加检查目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = initial ?? URL(fileURLWithPath: NSHomeDirectory())
        panel.message = "扫描只读取文件属性。只有勾选明确可处理项并点击移至废纸篓后才处理；重要或用途不明的文件保留。"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard !grants.contains(where: { $0.url == url }) else { continue }
            guard grants.count < 32 else { notice = "最多保留 32 个授权目录，请先移除不用的目录。"; break }
            do {
                let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                grants.append(GrantedDirectory(url: url, bookmark: bookmark, isProject: project))
            } catch {
                notice = "目录授权未保存：\(error.localizedDescription)"
            }
        }
        persistGrants()
        refreshDiscovery()
        page = .dashboard
        rescanAutomatic()
    }

    func removeGrant(_ grant: GrantedDirectory) {
        guard !scanning, !cleaning, !cleanupPreparation else { return }
        grants.removeAll { $0.id == grant.id }
        persistGrants()
        refreshDiscovery()
        rescanAutomatic()
    }

    /// Startup is automatic and read-only. User selection is required for every move.
    func startAutomaticallyIfNeeded() {
        guard !hasAutoStarted else { return }
        hasAutoStarted = true
        rescanAutomatic()
    }

    func rescanAutomatic() { runScan(preserveCleanupNotice: false) }
    func scan() { rescanAutomatic() }

    private var automaticRoots: [URL] {
        // The local development app is not sandboxed. Ordinary filesystem access
        // is still controlled by macOS; privacy-protected areas remain unscanned.
        // Never grant new privileges or resolve links to escape these locations.
        [URL(fileURLWithPath: NSHomeDirectory()), URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Library")]
    }

    private func runScan(preserveCleanupNotice: Bool) {
        guard !scanning, !cleaning, !cleanupPreparation else { return }
        let selected = grants
        let roots = automaticRoots + selected.map(\.url)
        let previous = result
        let scanControl = ScanControl()
        control = scanControl
        scanning = true
        directoryMonitor.setSuspended(true)
        paused = false
        progress = nil
        if !preserveCleanupNotice { notice = nil }
        autoScanStatus = "正在自动检查本机目录…"
        selectedCleanupPaths.removeAll()
        cleanupAssessments.removeAll()
        preparedCleanupPlans.removeAll()
        if !preserveCleanupNotice { cleanupNotice = nil; cleanupOutcome = nil }
        let projectPaths = selected.filter(\.isProject).map { $0.url.path }
        Task {
            let diagnosis = await Task.detached(priority: .utility) { [self] in
                let accessed = selected.map { ($0.url, $0.url.startAccessingSecurityScopedResource()) }
                defer { for (url, started) in accessed where started { url.stopAccessingSecurityScopedResource() } }
                let outcome = DiskScanner().scan(options: ScanOptions(roots: roots), control: scanControl) { value in
                    Task { @MainActor in self.progress = value }
                }
                let found = DiagnosisEngine().findings(for: outcome, projectRoots: projectPaths)
                let changes = previous.map { DiagnosisEngine().growth(previous: $0, current: outcome) } ?? []
                return (outcome, found, changes)
            }.value
            scanInventory = nil
            result = diagnosis.0
            findings = diagnosis.1
            growth = diagnosis.2
            recoveryPaths = diagnosis.0.directories.filter {
                URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix("DOJA Mac Doctor Recovery ")
            }.map(\.path)
            scanning = false
            paused = false
            control = nil
            refreshSample()
            refreshDiscovery()
            updateMonitoredDirectories(from: diagnosis.0)
            autoScanStatus = diagnosis.0.status == .completed ? "自动检查完成，正在核对可处理项。" : "扫描未完成；本次结果不允许处理文件。"
            await prepareCleanupOptions(scan: diagnosis.0, found: diagnosis.1)
            // Diagnosis, protection, monitoring baselines, and cleanup manifests
            // use the full scan. Retain only the display/report inventory after
            // those checks, while keeping truthful aggregate coverage counts.
            let retained = diagnosis.0.boundedForExport()
            scanInventory = ExportInventory(full: diagnosis.0, exported: retained)
            let retainedPaths = Set(retained.directories.map(\.path))
            growth = diagnosis.2.filter { retainedPaths.contains($0.path) }
            result = retained
        }
    }

    private func prepareCleanupOptions(scan: ScanResult, found: [DiagnosticFinding]) async {
        cleanupPreparation = true
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let activeIDs = Self.runningApplicationIDs()
        let selectedGrants = grants
        let prepared = await Task.detached(priority: .utility) {
            let accessed = selectedGrants.map { ($0.url, $0.url.startAccessingSecurityScopedResource()) }
            defer { for (url, started) in accessed where started { url.stopAccessingSecurityScopedResource() } }
            var assessments = CleanupService().assess(findings: found, scan: scan, home: home, runningApplications: activeIDs)
            var plans: [String: CleanupPlan] = [:]
            let byPath = Dictionary(uniqueKeysWithValues: found.map { ($0.path, $0) })
            var eligibleCount = 0
            var preparedFileCount = 0
            for index in assessments.indices where assessments[index].canSelect {
                guard eligibleCount < 200 else {
                    assessments[index] = assessments[index].blocked(message: "待处理项目较多，请缩小到具体缓存目录后重新检查。")
                    continue
                }
                eligibleCount += 1
                guard let finding = byPath[assessments[index].path] else { continue }
                do {
                    let plan = try CleanupService().prepare(selected: [finding], scan: scan, home: home,
                                                            allowedRoots: scan.roots.map { URL(fileURLWithPath: $0) })
                    let count = plan.items.reduce(0) { $0 + $1.fileCount }
                    guard preparedFileCount + count <= 200_000 else {
                        assessments[index] = assessments[index].blocked(message: "缓存条目过多，未准备处理；请先缩小检查范围。")
                        continue
                    }
                    preparedFileCount += count
                    plans[finding.path] = plan
                } catch {
                    assessments[index] = assessments[index].blocked(message: "暂不处理：\(error.localizedDescription)")
                }
            }
            return (assessments, plans)
        }.value
        cleanupAssessments = prepared.0
        preparedCleanupPlans = prepared.1
        cleanupPreparation = false
        autoScanStatus = scan.status == .completed ? "检查完成：\(prepared.1.count) 项可勾选，其余保留并说明原因。" : "扫描未完成；重要和未确认文件保留。"
    }

    var selectedCleanupCount: Int { selectedCleanupPaths.intersection(Set(preparedCleanupPlans.keys)).count }
    var selectedLogicalBytes: Int64 {
        cleanupAssessments.filter { selectedCleanupPaths.contains($0.path) && $0.canSelect }.reduce(0) { $0 + $1.logicalBytes }
    }
    var selectedAllocatedUpperBound: Int64 {
        cleanupAssessments.filter { selectedCleanupPaths.contains($0.path) && $0.canSelect }.reduce(0) { $0 + $1.allocatedBytes }
    }

    func toggleCleanupSelection(path: String) {
        guard !scanning, !cleaning, !cleanupPreparation, preparedCleanupPlans[path] != nil,
              cleanupAssessments.contains(where: { $0.path == path && $0.canSelect }) else { return }
        if selectedCleanupPaths.contains(path) { selectedCleanupPaths.remove(path) } else { selectedCleanupPaths.insert(path) }
    }
    func selectAllEligible() {
        guard !scanning, !cleaning, !cleanupPreparation else { return }
        selectedCleanupPaths = Set(cleanupAssessments.filter { $0.canSelect && preparedCleanupPlans[$0.path] != nil }.map(\.path))
    }
    func clearCleanupSelection() {
        guard !cleaning else { return }
        selectedCleanupPaths.removeAll()
    }

    func cleanSelected() {
        guard !scanning, !cleaning, !cleanupPreparation, selectedCleanupCount > 0 else { return }
        let paths = selectedCleanupPaths
        let plans = paths.sorted().compactMap { preparedCleanupPlans[$0]?.selecting(paths: [$0]) }
        guard plans.count == paths.count else { cleanupNotice = "选择已失效，正在重新检查。"; rescanAutomatic(); return }
        let selectedGrants = grants
        cleaning = true
        directoryMonitor.setSuspended(true)
        cleanupNotice = "正在复核已勾选的 \(paths.count) 项，并移至系统废纸篓…"
        selectedCleanupPaths.removeAll()
        Task {
            let outcomes = await Task.detached(priority: .utility) {
                let accessed = selectedGrants.map { ($0.url, $0.url.startAccessingSecurityScopedResource()) }
                defer { for (url, started) in accessed where started { url.stopAccessingSecurityScopedResource() } }
                return plans.map { CleanupService().execute(plan: $0, runningApplications: { Self.runningApplicationIDs() }) }
            }.value
            cleaning = false
            cleanupOutcome = outcomes.last
            retainCleanupReceipts(outcomes.flatMap(\.items))
            refreshSample()
            // Detailed outcome summary is added using the core's verified receipt.
            cleanupNotice = Self.cleanupSummary(outcomes)
            if let warning = receiptSaveWarning { cleanupNotice = (cleanupNotice ?? "") + "\n" + warning }
            preparedCleanupPlans.removeAll()
            runScan(preserveCleanupNotice: true)
        }
    }

    nonisolated private static func runningApplicationIDs() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    }

    private static func cleanupSummary(_ outcomes: [CleanupOutcome]) -> String {
        // Keep successful moves distinct from actual free-space changes.
        let items = outcomes.flatMap(\.items)
        let moved = items.filter { $0.status == .trashed }
        let retained = items.filter { $0.status != .trashed }
        let logical = outcomes.reduce(Int64(0)) { $0 + $1.totalLogicalBytes }
        var lines = ["已移至系统废纸篓 \(moved.count) 项（文件大小 \(DoctorFormat.bytes(logical))）。保留或未成功处理 \(retained.count) 项。"]
        lines.append("移入废纸篓不等于释放空间，没有自动清空。完整处理结果与恢复位置保留在下方记录中。")
        for item in retained.prefix(5) {
            lines.append("\(item.path)：\(item.message)")
            if let path = item.recoveryPath { lines.append("文件仍保存在：\(path)") }
        }
        if retained.count > 5 { lines.append("其他未处理项与所有恢复位置请查看处理记录。") }
        return lines.joined(separator: "\n")
    }

    private func retainCleanupReceipts(_ items: [CleanupItemOutcome]) {
        let recent = items.map { CleanupReceipt(id: UUID(), recordedAt: Date(), item: $0) }
        let combined = (cleanupReceipts + recent).sorted { $0.recordedAt < $1.recordedAt }
        // Prioritize recovery receipts over routine successes; the current batch
        // contains at most 200 items and is always fully retained.
        let recoveries = combined.filter { $0.item.recoveryPath != nil || ($0.item.status == .failed && $0.item.trashPath == nil) }
        let recentIDs = Set(recent.map(\.id))
        let recoveryIDs = Set(recoveries.map(\.id))
        let ordinary = combined.filter { !recentIDs.contains($0.id) && !recoveryIDs.contains($0.id) }
        cleanupReceipts = (Array(recoveries.suffix(600)) + Array(ordinary.suffix(200)) + recent)
            .reduce(into: [CleanupReceipt]()) { result, receipt in
                if !result.contains(where: { $0.id == receipt.id }) { result.append(receipt) }
            }.sorted { $0.recordedAt > $1.recordedAt }
        if let data = try? JSONEncoder().encode(cleanupReceipts), data.count <= 2 * 1024 * 1024 {
            UserDefaults.standard.set(data, forKey: receiptsKey)
            receiptSaveWarning = nil
        } else {
            receiptSaveWarning = "处理记录已保留在本次窗口中，但无法保存。请复制需要恢复的完整路径后再退出。"
        }
    }

    private func restoreCleanupReceipts() {
        guard let data = UserDefaults.standard.data(forKey: receiptsKey), data.count <= 2 * 1024 * 1024,
              let saved = try? JSONDecoder().decode([CleanupReceipt].self, from: data) else { return }
        cleanupReceipts = Array(saved.prefix(1000))
    }

    func togglePause() {
        guard scanning, !cleaning else { return }
        if paused { control?.resume() } else { control?.pause() }
        paused.toggle()
    }

    func cancel() { control?.cancel(); paused = false }

    func refreshDiscovery() {
        let accessed = grants.map { ($0.url, $0.url.startAccessingSecurityScopedResource()) }
        defer { for (url, started) in accessed where started { url.stopAccessingSecurityScopedResource() } }
        discovered = DiagnosticDiscovery.candidates(home: URL(fileURLWithPath: NSHomeDirectory()), authorizedRoots: automaticRoots + grants.map(\.url))
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copy(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func exportReport() {
        guard let result, !scanning, !cleaning, !cleanupPreparation else { return }
        let panel = NSSavePanel()
        panel.title = "导出本次诊断报告"
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "DOJA-Mac-Doctor-\(dateFormatter.string(from: Date())).json"
        panel.message = "报告包含完整文件路径和大小，请自行决定分享范围。建议保存在外置盘。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        struct Report: Encodable {
            let version = 1
            let system: SystemSample
            let scan: ScanResult
            let suggestions: [DiagnosticFinding]
            let comparison: [GrowthFinding]
            let exportInventory: ExportInventory
            let processingEligibility: [CleanupAssessment]
            let processingReceipts: [CleanupReceipt]
            let monitoringEvents: [SpaceAnomaly]
            let monitoringDirectories: [DirectoryObservation]
            let explanation = "目录含子目录，不能相加；分配空间已按硬链接去重，无法去重 APFS 克隆或快照。可回收量只有估算上限，实际可能为零。"
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let exported = result.boundedForExport()
            let data = try encoder.encode(Report(system: sample, scan: exported, suggestions: Array(findings.prefix(500)), comparison: growth,
                                                exportInventory: scanInventory ?? ExportInventory(full: result, exported: exported),
                                                processingEligibility: Array(cleanupAssessments.prefix(500)), processingReceipts: cleanupReceipts,
                                                monitoringEvents: Array(monitorEvents.prefix(100)), monitoringDirectories: monitoredDirectories))
            // Keep exported reports bounded; never create a very large low-space log.
            guard data.count <= 8 * 1024 * 1024 else { notice = "报告超过 8 MB，暂不导出，请缩小扫描范围。"; return }
            try data.write(to: url, options: .atomic)
            notice = "已导出报告：\(url.path)"
        } catch { notice = "导出失败：\(error.localizedDescription)" }
    }

    func checkSnapshots() {
        guard !checkingSnapshots else { return }
        checkingSnapshots = true
        snapshotText = "正在读取 APFS 快照元数据…"
        Task {
            let text = await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                process.arguments = ["apfs", "listSnapshots", "/System/Volumes/Data", "-plist"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    watchdog.cancel()
                    guard data.count < 1024 * 1024 else { return "快照列表过大，未显示。快照占用与可回收大小仍待确认。" }
                    guard process.terminationStatus == 0 else {
                        return "无法读取快照（未申请管理员权限）：\n" + String(decoding: data.prefix(2000), as: UTF8.self)
                    }
                    guard let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                        return "快照元数据格式无法识别，未将其视为没有快照。"
                    }
                    guard let snapshots = object["Snapshots"] as? [[String: Any]] else {
                        return "系统返回了快照元数据，但列表字段未能识别；快照数量与空间待确认。"
                    }
                    let names = snapshots.compactMap { $0["Name"] as? String }
                    return "系统数据卷：\(snapshots.count) 个快照\n" + names.prefix(30).joined(separator: "\n") + "\n\n快照大小、独占块与可回收量未取得。此处只查看，不修改快照。"
                } catch { return "快照读取失败：\(error.localizedDescription)" }
            }.value
            snapshotText = text
            checkingSnapshots = false
        }
    }

    private func persistGrants() {
        if let data = try? JSONEncoder().encode(grants.map { SavedGrant(bookmark: $0.bookmark, isProject: $0.isProject) }) {
            UserDefaults.standard.set(data, forKey: grantsKey)
        }
    }

    private func restoreGrants() {
        guard let data = UserDefaults.standard.data(forKey: grantsKey), let saved = try? JSONDecoder().decode([SavedGrant].self, from: data) else { return }
        for value in saved.prefix(32) {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: value.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                let started = url.startAccessingSecurityScopedResource()
                defer { if started { url.stopAccessingSecurityScopedResource() } }
                let bookmark = stale ? try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) : value.bookmark
                grants.append(GrantedDirectory(url: url, bookmark: bookmark, isProject: value.isProject))
            } catch { notice = "部分目录授权已失效，请重新选择。" }
        }
    }
}

struct InspectionItem: Identifiable {
    var id: String { path }
    let path: String
    let title: String
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let modified: Date?
    let purpose: String
    let risk: String
    let reclaim: String
    let complete: Bool
    init(directory: DirectoryRecord) {
        path = directory.path; title = URL(fileURLWithPath: path).lastPathComponent
        logicalBytes = directory.logicalBytes; allocatedBytes = directory.allocatedBytes; modified = directory.lastModified
        purpose = "目录汇总，包含子目录。榜单中的父目录与子目录不能相加。"
        risk = "尚未确认用途；目录大小不代表可以清理。"
        reclaim = "未确认，实际可释放空间可能为零。"
        complete = directory.isComplete
    }
    init(file: FileRecord) {
        path = file.path; title = URL(fileURLWithPath: path).lastPathComponent
        logicalBytes = file.logicalBytes; allocatedBytes = file.allocatedBytes; modified = file.modifiedAt
        purpose = "文件分类：\(file.kind)；硬链接数：\(file.linkCount)。分类不能单独决定文件用途。"
        risk = "未确认用途的文件应保留；大文件和新文件不等于垃圾。"
        reclaim = "未确认。APFS 克隆、快照或其他硬链接可能保留磁盘块。"
        complete = true
    }
    init(finding: DiagnosticFinding) {
        path = finding.path; title = finding.title
        logicalBytes = finding.logicalBytes; allocatedBytes = finding.allocatedBytes; modified = finding.lastModified
        purpose = finding.reason; risk = finding.advice
        reclaim = finding.estimatedReclaimUpperBound.map { "0 ～ \(DoctorFormat.bytes($0))（估算范围，未验证共享磁盘块）" } ?? "用途或扫描覆盖尚未确认，无法估算。"
        complete = finding.isComplete
    }
}
