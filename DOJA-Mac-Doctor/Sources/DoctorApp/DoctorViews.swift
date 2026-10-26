import SwiftUI
import Charts
import DoctorCore

extension Color {
    static let doctorBackground = Color(red: 0.045, green: 0.055, blue: 0.074)
    static let doctorPanel = Color(red: 0.075, green: 0.09, blue: 0.115)
    static let doctorMint = Color(red: 0.35, green: 0.87, blue: 0.71)
    static let doctorRed = Color(red: 1, green: 0.39, blue: 0.43)
    static let doctorAmber = Color(red: 0.98, green: 0.73, blue: 0.32)
}

private struct Panel<Content: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Spacer()
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.doctorPanel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.055)))
    }
}

struct DoctorMainView: View {
    @EnvironmentObject private var state: DoctorState
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let notice = state.notice {
                            HStack {
                                Label(notice, systemImage: "info.circle").font(.callout).textSelection(.enabled)
                                Spacer()
                                Button { state.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                            }.padding(14).background(Color.doctorMint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        }
                        switch state.page {
                        case .dashboard: DashboardView()
                        case .scan: ScanView()
                        case .suggestions: SuggestionsView()
                        case .applications: ApplicationsView()
                        case .guide: GuideView()
                        }
                    }.padding(28)
                }
            }
        }
        .frame(minWidth: 1020, minHeight: 700)
        .background(Color.doctorBackground)
        .tint(.doctorMint)
        .sheet(item: $state.detail) { DetailView(item: $0).environmentObject(state) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 12) {
                Image(systemName: "cross.case.fill").font(.system(size: 25)).foregroundStyle(Color.doctorMint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("DOJA").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Mac Doctor").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 12)
            VStack(spacing: 7) {
                ForEach([DoctorPage.dashboard, .scan, .applications, .guide]) { page in
                    Button { state.page = page } label: {
                        Label(pageTitle(page), systemImage: page.symbol)
                            .font(.system(size: 14, weight: state.page == page ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .foregroundStyle(state.page == page ? Color.doctorMint : Color.white.opacity(0.68))
                            .background(state.page == page ? Color.doctorMint.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                Label("本机扫描 · 选择后处理", systemImage: "lock.shield").foregroundStyle(Color.doctorMint)
                Text("不上传文件内容\n不确定的文件保持原样")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(5)
            }.font(.caption).padding(.bottom, 10)
        }.padding(20).frame(width: 204).background(Color.doctorPanel.opacity(0.65))
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(pageTitle(state.page)).font(.system(size: 23, weight: .semibold))
                Text("打开即检查，勾选后处理，保护每一份作品。").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state.scanning { ProgressView().controlSize(.small); Text(state.paused ? "扫描已暂停" : "正在只读扫描").font(.caption) }
            Text("本地 · Apple Silicon").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 7).background(.white.opacity(0.04), in: Capsule())
            Button { state.refreshSample() } label: { Image(systemName: "arrow.clockwise") }.help("刷新磁盘与内存状态")
        }.padding(.horizontal, 28).padding(.vertical, 20)
    }
    private func pageTitle(_ page: DoctorPage) -> String {
        switch page {
        case .dashboard, .suggestions: return "扫描与清理"
        case .scan: return "详细扫描"
        case .applications: return "应用诊断"
        case .guide: return "使用说明"
        }
    }
}

private struct MetricCard: View {
    let label: String
    let value: String
    let footnote: String
    let symbol: String
    var accent: Color = .white
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(label).font(.caption).foregroundStyle(.secondary); Spacer(); Image(systemName: symbol).foregroundStyle(accent.opacity(0.8)) }
            Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).foregroundStyle(accent).minimumScaleFactor(0.5).lineLimit(1)
            Text(footnote).font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.doctorPanel, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct DashboardView: View {
    @EnvironmentObject private var state: DoctorState
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                MetricCard(label: "内部盘总容量", value: DoctorFormat.bytes(state.sample.totalBytes), footnote: "系统报告的磁盘容量", symbol: "internaldrive")
                MetricCard(label: "当前可用空间", value: DoctorFormat.bytes(state.sample.availableBytes), footnote: "读取当前磁盘状态", symbol: "chart.pie", accent: (state.sample.availableBytes ?? Int64.max) < 3_000_000_000 ? .doctorRed : .doctorMint)
                MetricCard(label: "内存压力", value: state.sample.memoryPressure, footnote: "内存紧张会影响交换空间", symbol: "memorychip", accent: state.sample.memoryPressure == "正常" ? .doctorMint : .doctorAmber)
                MetricCard(label: "交换空间", value: DoctorFormat.bytes(state.sample.swapUsedBytes), footnote: "系统当前使用的 Swap", symbol: "arrow.left.arrow.right")
            }
            if let free = state.sample.availableBytes, free < 3_000_000_000 {
                Label("可用空间不足 3 GB。先查看扫描结果，重要作品和用途不明的文件会保留。", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Color.doctorRed).padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Color.doctorRed.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            }
            AutomaticScanPanel()
            SpaceMonitoringPanel()
            CleaningResultsView()
            if !state.sample.errors.isEmpty { Text(state.sample.errors.joined(separator: "；")).font(.caption).foregroundStyle(Color.doctorAmber) }
        }
    }
}

private struct CapacityTrendPoint: Identifiable {
    var id: String { "\(volumePath)::\(timestamp.timeIntervalSince1970)" }
    let volumePath: String
    let timestamp: Date
    let bytes: Int64
    let segment: Int
}

private struct SpaceMonitoringPanel: View {
    @EnvironmentObject private var state: DoctorState
    private var trend: [CapacityTrendPoint] {
        var result: [CapacityTrendPoint] = []
        var previous: Date?
        var previousVolume: String?
        var segment = 0
        for sample in state.samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let bytes = sample.availableBytes else {
                previous = nil
                segment += 1
                continue
            }
            if let previous, sample.timestamp.timeIntervalSince(previous) > 150 { segment += 1 }
            if let previousVolume, previousVolume != sample.volumePath { segment += 1 }
            result.append(CapacityTrendPoint(volumePath: sample.volumePath, timestamp: sample.timestamp, bytes: bytes, segment: segment))
            previous = sample.timestamp
            previousVolume = sample.volumePath
        }
        return result
    }
    private var recentEvents: [SpaceAnomaly] {
        Array(state.monitorEvents.sorted { $0.detectedAt > $1.detectedAt }.prefix(5))
    }
    var body: some View {
        Panel(title: "空间变化记录", subtitle: "每分钟采样 · 本机保存") {
            Text(state.monitoringStatus).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let points = trend
            if points.count >= 2 {
                Chart(points) { point in
                    LineMark(x: .value("时间", point.timestamp), y: .value("剩余 GB", Double(point.bytes) / 1_000_000_000), series: .value("采样区间", point.segment))
                        .foregroundStyle(Color.doctorMint)
                    PointMark(x: .value("时间", point.timestamp), y: .value("剩余 GB", Double(point.bytes) / 1_000_000_000))
                        .foregroundStyle(Color.doctorMint).symbolSize(5)
                }.chartYAxisLabel("剩余 GB").chartLegend(.hidden)
                    .chartYScale(domain: .automatic(includesZero: false)).frame(height: 125)
                Text("只连接相邻真实读数；缺失读数或较长采样间断处断开，不补造历史。当前显示最近 \(points.count) 次有效采样。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 26)).foregroundStyle(Color.doctorMint.opacity(0.7))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("等待下一次真实容量采样").font(.callout)
                        Text("至少取得两次读数后显示趋势；不会根据当前空间推测历史。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.vertical, 15)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("最近异常事件").font(.callout).bold()
                    Spacer()
                    Text("10 分钟内减少超过 3 GB").font(.caption).foregroundStyle(.secondary)
                }
                if recentEvents.isEmpty {
                    Text("已记录的真实采样中，暂未检测到达到阈值的骤降。没有历史记录的时段，原因仍待确认。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(recentEvents) { event in SpaceAnomalyRow(event: event) }
                    if state.monitorEvents.count > 5 {
                        Text("首页显示最近 5 个事件，本机仍保留有容量限制的历史记录。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !state.monitoredDirectories.isEmpty {
                DisclosureGroup("重点目录 · \(state.monitoredDirectories.count) 个检查位置") {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.monitoredDirectories.sorted { $0.path < $1.path }) { observation in
                            MonitoredDirectoryRow(observation: observation)
                        }
                    }.padding(.top, 10)
                    Text("目录大小只反映核实到的文件属性，不等于可释放空间。未完整检查的位置不会当成 0 或空目录。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("重点目录尚无可核实的记录；取得真实目录读数后会显示变化线索。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("查看大文件与目录变化") { state.page = .scan }
                Button(state.checkingSnapshots ? "读取快照中…" : "查看磁盘快照") { state.checkSnapshots() }.disabled(state.checkingSnapshots)
                Spacer()
            }
            if let text = state.snapshotText {
                DisclosureGroup("磁盘快照信息") { Text(text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 10) }
            }
        }
    }
}

private struct SpaceAnomalyRow: View {
    @EnvironmentObject private var state: DoctorState
    let event: SpaceAnomaly
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Label("可用空间减少 \(DoctorFormat.bytes(event.dropBytes))", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Color.doctorAmber)
                Spacer()
                Text("原因待确认").font(.caption).foregroundStyle(Color.doctorAmber)
            }
            Text("\(event.startedAt.formatted(date: .abbreviated, time: .shortened)) → \(event.detectedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("查看内存情况与目录线索") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("当时内存压力：\(event.memoryPressure) · 交换空间：\(DoctorFormat.bytes(event.swapUsedBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("交换空间变化：\(event.swapDeltaBytes.map(signedSpaceChange) ?? "未取得可比较读数")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(event.explanation).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("以下是同一时段的目录变化线索，可能包含其他工作的影响，不能据此认定某个应用造成骤降。目录有父子关系时也不能把变化量相加。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if event.directoryChanges.isEmpty {
                        Text("本次未取得可关联的目录增长线索，原因待确认。")
                            .font(.caption).foregroundStyle(Color.doctorAmber)
                    } else {
                        ForEach(Array(event.directoryChanges.prefix(8))) { change in
                            DirectoryChangeRow(change: change)
                        }
                        if event.directoryChanges.count > 8 {
                            Text("此处显示前 8 条目录线索。").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.top, 10)
            }.font(.caption)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.doctorAmber.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DirectoryChangeRow: View {
    @EnvironmentObject private var state: DoctorState
    let change: DirectoryChange
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 12) {
                Text(change.path).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Finder") { state.reveal(change.path) }.controlSize(.small)
            }
            Text("文件大小：\(DoctorFormat.bytes(change.beforeLogicalBytes)) → \(DoctorFormat.bytes(change.afterLogicalBytes)) · \(difference(before: change.beforeLogicalBytes, after: change.afterLogicalBytes))")
                .font(.caption2).foregroundStyle(.secondary)
            Text("分配空间：\(DoctorFormat.bytes(change.beforeAllocatedBytes)) → \(DoctorFormat.bytes(change.afterAllocatedBytes)) · \(difference(before: change.beforeAllocatedBytes, after: change.afterAllocatedBytes))")
                .font(.caption2).foregroundStyle(.secondary)
            Text("目录核对时间：\(change.baselineAt.formatted(date: .abbreviated, time: .shortened)) → \(change.currentAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
        Divider().opacity(0.35)
    }
    private func difference(before: Int64, after: Int64) -> String {
        let (value, overflow) = after.subtractingReportingOverflow(before)
        return overflow ? "变化量待确认" : signedSpaceChange(value)
    }
}

private struct MonitoredDirectoryRow: View {
    @EnvironmentObject private var state: DoctorState
    let observation: DirectoryObservation
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Text(observation.path).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(observation.isComplete ? "已完整检查" : "待核实")
                    .font(.caption2).foregroundStyle(observation.isComplete ? Color.doctorMint : .doctorAmber)
                Button("Finder") { state.reveal(observation.path) }.controlSize(.small)
            }
            Text(observation.isComplete
                 ? "文件大小 \(DoctorFormat.bytes(observation.logicalBytes)) · 分配空间 \(DoctorFormat.bytes(observation.allocatedBytes))"
                 : "总占用未核实，不能按 0 或空目录计算。")
                .font(.caption).foregroundStyle(.secondary)
            Text("最近核对：" + observation.observedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary)
            if let reason = observation.reason, !reason.isEmpty {
                Text(reason).font(.caption).foregroundStyle(observation.isComplete ? Color.secondary : .doctorAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 12)
        Divider().opacity(0.35)
    }
}

private func signedSpaceChange(_ value: Int64) -> String {
    if value == 0 { return "无变化" }
    return (value > 0 ? "+" : "") + DoctorFormat.bytes(value)
}

private struct AutomaticScanPanel: View {
    @EnvironmentObject private var state: DoctorState
    var body: some View {
        Panel(title: "自动检查", subtitle: "只读取文件属性，不读取内容") {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: state.scanning ? "magnifyingglass" : "checkmark.shield")
                    .font(.system(size: 28)).foregroundStyle(Color.doctorMint)
                VStack(alignment: .leading, spacing: 7) {
                    Text(state.autoScanStatus).font(.headline)
                    Text("自动检查本机常见目录和已授权目录。无权限的位置明确标为未扫描。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                if state.scanning {
                    Button(state.paused ? "继续扫描" : "暂停") { state.togglePause() }
                    Button("取消") { state.cancel() }
                } else {
                    Button("重新扫描") { state.rescanAutomatic() }
                        .disabled(state.cleaning || state.cleanupPreparation)
                }
            }
            if state.scanning {
                ProgressView().progressViewStyle(.linear)
                Text(state.progress.map { "已检查 \($0.visitedFiles) 个文件 · 文件大小 \(DoctorFormat.bytes($0.logicalBytes))" } ?? "正在准备扫描…")
                    .font(.caption).foregroundStyle(.secondary)
                if let path = state.progress?.currentPath { Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            if let result = state.result, !state.scanning {
                HStack {
                    Text("\(result.fileCount) 个文件 · \(state.scanInventory?.totalCoverageIssues ?? result.issues.count) 条未扫描或覆盖问题")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("查看占用详情") { state.page = .scan }
                    Button("增加检查目录…") { state.chooseDirectory() }.disabled(state.cleaning || state.cleanupPreparation)
                }
                if result.status != .completed {
                    Label("扫描未完成，清理建议仅来自已完整检查的部分。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Color.doctorAmber)
                }
                if !result.issues.isEmpty {
                    Text("受 macOS 隐私保护的目录可能需要你授权。未扫描不等于没有占用；可在“详细扫描”中查看。")
                        .font(.caption).foregroundStyle(Color.doctorAmber)
                }
            }
        }
    }
}

private enum ScanTab: String, CaseIterable { case directories = "最大目录 20", files = "最大文件 50", recent = "近期大文件", types = "文件类型", issues = "未扫描项", changes = "目录变化" }

private struct ScanView: View {
    @EnvironmentObject private var state: DoctorState
    @State private var tab: ScanTab = .directories
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Panel(title: "扫描范围", subtitle: "自动检查常见目录 · 可添加更多范围") {
                if state.grants.isEmpty {
                    Text("首页会自动检查常见目录。需要排查外置素材盘、开发项目或其他目录时，再添加检查范围。系统拒绝访问的位置会单独标出。")
                        .foregroundStyle(.secondary).font(.callout)
                }
                ForEach(state.grants) { grant in
                    HStack(spacing: 12) {
                        Image(systemName: grant.isProject ? "folder.badge.gearshape" : "folder").foregroundStyle(Color.doctorMint)
                        Text(grant.url.path).font(.callout).textSelection(.enabled)
                        if grant.isProject { Text("开发项目").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button { state.removeGrant(grant) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).disabled(state.scanning || state.cleaning || state.cleanupPreparation).help("移除扫描范围，不删除目录")
                    }
                }
                HStack(spacing: 12) {
                    Button("添加目录…") { state.chooseDirectory() }.disabled(state.scanning || state.cleaning || state.cleanupPreparation)
                    Button("添加开发项目…") { state.chooseDirectory(project: true) }.disabled(state.scanning || state.cleaning || state.cleanupPreparation)
                    Spacer()
                    if state.scanning {
                        Button(state.paused ? "继续" : "暂停") { state.togglePause() }
                        Button("取消扫描") { state.cancel() }
                    } else {
                        Button("重新自动扫描") { state.rescanAutomatic() }.buttonStyle(.borderedProminent).disabled(state.cleaning || state.cleanupPreparation)
                    }
                }
                if state.scanning {
                    ProgressView().progressViewStyle(.linear)
                    Text(state.progress.map { "已检查 \($0.visitedFiles) 个文件 · \(DoctorFormat.bytes($0.logicalBytes))" } ?? "正在准备目录…").font(.caption)
                    if let path = state.progress?.currentPath { Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
            }
            if let result = state.result {
                HStack {
                    Label(result.status == .completed ? "扫描结束" : "已取消 · 部分结果", systemImage: result.status == .completed ? "checkmark.circle" : "stop.circle").foregroundStyle(Color.doctorMint)
                    Text("\(result.fileCount) 个文件 · \(state.scanInventory?.totalCoverageIssues ?? result.issues.count) 条覆盖问题").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("导出报告…") { state.exportReport() }.disabled(state.scanning || state.cleaning || state.cleanupPreparation)
                }
                Picker("结果", selection: $tab) { ForEach(ScanTab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                TextField("筛选路径或文件名", text: $search).textFieldStyle(.roundedBorder)
                Text("文件大小表示内容长度；分配空间来自文件系统，并按硬链接去重。目录包含子目录，榜单数值不能相加。APFS 克隆、快照与不可访问区域使实际可回收空间仍待确认。")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                resultPanel(result)
            } else if !state.scanning {
                EmptyCard(symbol: "internaldrive", title: "还没有扫描结果", message: "首页会自动检查常见目录。首次真实扫描完成后，这里会显示空间占用榜单。")
            }
        }
    }
    private func matches(_ path: String) -> Bool { search.isEmpty || path.localizedCaseInsensitiveContains(search) }
    @ViewBuilder private func resultPanel(_ result: ScanResult) -> some View {
        switch tab {
        case .directories:
            Panel(title: "占用最大的目录", subtitle: "按文件大小排序 · 包含子目录") {
                Text("扫描共记录 \(state.scanInventory?.totalDirectoryRecords ?? result.directories.count) 个目录；完成分析后保留最大的 2000 个目录及扫描根目录，这里展示最大的 20 个。未保留的较小目录不代表没有占用，汇总数值仍来自全部扫描。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                let rows = Array(result.directories.sorted { $0.logicalBytes > $1.logicalBytes }.prefix(20)).filter { matches($0.path) }
                if rows.isEmpty { Text("没有符合筛选条件的目录。").foregroundStyle(.secondary) }
                ForEach(rows) { row in PathRow(item: InspectionItem(directory: row), label: row.isComplete ? nil : "未完整扫描") }
            }
        case .files:
            Panel(title: "占用最大的文件", subtitle: "最多 50 个") {
                ForEach(result.largestFiles.filter { matches($0.path) }) { row in PathRow(item: InspectionItem(file: row), label: row.kind) }
                if result.largestFiles.isEmpty { Text("本次扫描范围内未读取到常规文件。").foregroundStyle(.secondary) }
            }
        case .recent:
            Panel(title: "最近 7 天新增或修改的大型文件", subtitle: "≥ 100 MiB · 最多 50 个") {
                Text("以文件系统创建或修改时间判断。复制、解压与时间戳变更也会影响结果，不能直接认定这些文件造成了空间骤降。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(result.recentLargeFiles.filter { matches($0.path) }) { row in PathRow(item: InspectionItem(file: row), label: row.modifiedAt.formatted(date: .abbreviated, time: .shortened)) }
                if result.recentLargeFiles.isEmpty { Text("本次扫描未发现达到阈值的近期文件。").foregroundStyle(.secondary) }
            }
        case .types:
            Panel(title: "文件类型分布", subtitle: "按扩展名分类") {
                ForEach(result.categories.filter { matches($0.name) }) { category in
                    HStack {
                        Text(category.name).font(.headline).frame(width: 90, alignment: .leading)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 4).fill(Color.doctorMint.opacity(0.65))
                                .frame(width: max(2, geo.size.width * Double(category.logicalBytes) / Double(max(1, result.logicalBytes))), height: 7).frame(height: 25)
                        }.frame(height: 25)
                        Text(DoctorFormat.bytes(category.logicalBytes)).monospacedDigit().frame(width: 95, alignment: .trailing)
                        Text("\(category.count) 个").font(.caption).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
                    }
                }
                Text("类型分布统计文件大小；它不能用于判断哪些媒体或工程可以删除。").font(.caption).foregroundStyle(.secondary)
            }
        case .issues:
            Panel(title: "未扫描与覆盖问题", subtitle: "共 \(state.scanInventory?.totalCoverageIssues ?? result.issues.count) 条 · 保留 \(result.issues.count) 条") {
                Text("详细问题记录最多保留 1000 条，当前保留 \(result.issues.count) 条；界面每次最多展示 500 条，搜索只覆盖这些保留记录。扫描问题总数为 \(state.scanInventory?.totalCoverageIssues ?? result.issues.count) 条，未保留的记录不表示对应位置为空或已完整扫描。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(result.issues.filter { matches($0.path) }.prefix(500))) { issue in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(issue.path).font(.callout).textSelection(.enabled); Spacer(); Button("Finder") { state.reveal(issue.path) } }
                        Text(issue.reason).font(.caption).foregroundStyle(Color.doctorAmber)
                    }.padding(.vertical, 7)
                    Divider().opacity(0.4)
                }
                Text("跳过符号链接：\(result.skippedSymlinks) 个。权限不足、跨卷目录、云端占位文件、扫描中变化和取消都会影响覆盖；缺失区域不视为空目录。")
                    .font(.caption).foregroundStyle(.secondary)
                if result.issues.count > 500 { Text("可搜索保留记录中的路径；导出报告会明确标出扫描总数和记录保留数量。").font(.caption).foregroundStyle(.secondary) }
            }
        case .changes:
            Panel(title: "与上一次扫描比较", subtitle: "双方保留且完整的目录") {
                Text("重复扫描只比较相同范围中双方均保留且完整扫描的目录，不覆盖全部较小目录；未列出不表示没有增长。受硬链接归属影响，分配空间变化仅作为线索；目录包含子目录，不可累计。这不是历史异常事件记录。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(state.growth.filter { matches($0.path) }) { row in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(row.path).textSelection(.enabled); Spacer(); Text((row.logicalDelta >= 0 ? "+" : "") + DoctorFormat.bytes(row.logicalDelta)).foregroundStyle(Color.doctorAmber); Button("Finder") { state.reveal(row.path) } }
                        Text("分配空间变化：" + (row.allocatedDelta >= 0 ? "+" : "") + DoctorFormat.bytes(row.allocatedDelta)).font(.caption).foregroundStyle(.secondary)
                        Text(row.reason).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                if state.growth.isEmpty { Text("双方保留且完整的目录中，尚无可验证的增长线索。对相同范围完成第二次扫描可比较保留记录；未保留、未完整或不同范围的目录不用于归因。").foregroundStyle(.secondary) }
            }
        }
    }
}

private struct PathRow: View {
    @EnvironmentObject private var state: DoctorState
    let item: InspectionItem
    var label: String?
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(Color.doctorMint.opacity(0.75)).frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text(item.title).font(.callout).lineLimit(1); if let label { Text(label).font(.caption2).foregroundStyle(item.complete ? Color.secondary : .doctorAmber).lineLimit(1) } }
                Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Text(!item.complete && item.logicalBytes == 0 ? "未取得" : DoctorFormat.bytes(item.logicalBytes)).font(.callout).monospacedDigit()
                Text("分配 " + (!item.complete && item.allocatedBytes == 0 ? "未取得" : DoctorFormat.bytes(item.allocatedBytes))).font(.caption2).foregroundStyle(.secondary)
            }.frame(width: 125, alignment: .trailing)
            Button("详情") { state.detail = item }.controlSize(.small)
            Button { state.reveal(item.path) } label: { Image(systemName: "folder") }.help("在 Finder 中定位").controlSize(.small)
        }.padding(.vertical, 8)
        .contextMenu {
            Button("查看完整路径与用途") { state.detail = item }
            Button("复制完整路径") { state.copy(item.path) }
            Button("在 Finder 中定位") { state.reveal(item.path) }
        }
        Divider().opacity(0.35)
    }
}

private func riskName(_ risk: RiskLevel) -> String {
    switch risk { case .green: return "临时数据 · 暂不处理"; case .yellow: return "用途需确认"; case .red: return "重要数据 · 保留" }
}
private func riskColor(_ risk: RiskLevel) -> Color {
    switch risk { case .green: return .doctorMint; case .yellow: return .doctorAmber; case .red: return .doctorRed }
}

private struct SuggestionsView: View {
    var body: some View { CleaningResultsView() }
}

private struct CleaningResultsView: View {
    @EnvironmentObject private var state: DoctorState
    @State private var search = ""
    private var eligible: [CleanupAssessment] { state.cleanupAssessments.filter(\.canSelect) }
    private var retained: [CleanupAssessment] { state.cleanupAssessments.filter { !$0.canSelect } }
    private var runningCodexCacheCount: Int {
        retained.filter { $0.message.contains("Codex 正在运行") }.count
    }
    private var eligibleSubtitle: String {
        if state.scanning { return "扫描中" }
        if state.cleanupPreparation { return "正在核实" }
        return eligible.isEmpty ? "0 项可勾选" : "\(eligible.count) 项 · 需你勾选"
    }
    private var emptyEligibleMessage: String {
        if state.scanning { return "正在扫描，请稍候；完成后会核实哪些项目可处理。" }
        if state.cleanupPreparation { return "正在核实，请稍候。" }
        if runningCodexCacheCount > 0 {
            return "本次暂无可直接处理项目。已识别 \(runningCodexCacheCount) 项 Codex 缓存，但 Codex 正在运行，因此保留。退出 Codex 后重新扫描，再核实能否处理。重要数据和不确定的文件继续保留。"
        }
        return "本次暂无可直接处理项目。重要数据和不确定的文件继续保留；这不表示磁盘没有占用，可查看占用详情和下方保留原因。"
    }
    private var controlsDisabled: Bool { state.scanning || state.cleaning || state.cleanupPreparation }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !state.cleanupReceipts.isEmpty || !state.recoveryPaths.isEmpty {
                CleanupReceiptPanel()
            }
            if state.result == nil {
                EmptyCard(symbol: "magnifyingglass", title: state.scanning ? "正在查找可处理的临时文件" : "等待真实扫描结果", message: "扫描结束后显示用途、风险和完整路径。不会自动勾选，也不会自动清理。")
            } else {
                if state.cleanupPreparation {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("正在核实文件身份、目录用途和应用运行状态…").font(.callout)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.doctorMint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                if let notice = state.cleanupNotice {
                    Label(notice, systemImage: "info.circle")
                        .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.doctorMint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                }
                CleanupSelectionBar()
                HStack {
                    Text("检查结果").font(.title3).bold()
                    Spacer()
                    TextField("搜索名称或路径", text: $search).textFieldStyle(.roundedBorder).frame(width: 280)
                }
                Panel(title: "可放心处理", subtitle: eligibleSubtitle) {
                    Text("这里只包含用途明确、可重新生成且已通过安全核实的临时文件。处理前还会再次检查；默认一项都不选。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if eligible.isEmpty {
                        Text(emptyEligibleMessage)
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Button("选择全部可处理项（\(eligible.count)）") { state.selectAllEligible() }.disabled(controlsDisabled)
                            Button("取消选择") { state.clearCleanupSelection() }.disabled(controlsDisabled || state.selectedCleanupCount == 0)
                            Spacer()
                        }
                        assessmentRows(eligible)
                    }
                }
                if !retained.isEmpty {
                    Panel(title: "需要确认 · 暂不处理", subtitle: "\(retained.count) 项 · 已保留") {
                        Text("重要项目、媒体、会话记录以及尚未核实的缓存不会进入清理。即使看起来像临时文件，应用仍在使用或目录未完整扫描时也会保留。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        assessmentRows(retained)
                    }
                }
                if !eligible.isEmpty { CleanupSelectionBar() }
                if state.cleanupAssessments.isEmpty && !state.cleanupPreparation {
                    EmptyCard(symbol: "shield", title: "没有明确的清理建议", message: "这不表示磁盘没有占用。可在“详细扫描”查看最大的目录和文件；未知用途的文件不会被处理。")
                }
            }
        }
    }
    @ViewBuilder private func assessmentRows(_ assessments: [CleanupAssessment]) -> some View {
        let matching = assessments.filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search) }
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matching.prefix(200))) { item in
                CleanupAssessmentRow(item: item)
            }
        }
        if matching.isEmpty { Text("没有符合搜索条件的项目。").font(.caption).foregroundStyle(.secondary) }
        if matching.count > 200 {
            Text("当前显示前 200 项，共 \(matching.count) 项；可搜索完整路径。全选只选择通过安全核实的项目。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CleanupReceiptPanel: View {
    @EnvironmentObject private var state: DoctorState
    @State private var expanded: Bool?
    @State private var search = ""
    private var needsAttention: Bool {
        !state.recoveryPaths.isEmpty || state.cleanupReceipts.contains { $0.item.status != .trashed }
    }
    private var matchingReceipts: [CleanupReceipt] {
        state.cleanupReceipts.filter { receipt in
            search.isEmpty || matches(receipt.item.path) || matches(receipt.item.message)
                || receipt.item.trashPath.map(matches) == true || receipt.item.recoveryPath.map(matches) == true
        }.sorted { $0.recordedAt > $1.recordedAt }
    }
    private var matchingRecoveries: [String] { state.recoveryPaths.filter { search.isEmpty || matches($0) } }
    var body: some View {
        Panel(title: "处理记录与恢复位置", subtitle: "\(state.cleanupReceipts.count) 条处理记录") {
            DisclosureGroup(needsAttention ? "有保留或未完成的项目，请核对记录" : "查看已移至废纸篓的记录", isExpanded: Binding(
                get: { expanded ?? needsAttention },
                set: { expanded = $0 }
            )) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("记录包含原路径和系统返回的处理结果，重新扫描后仍可查看。这里只查看和定位文件，不会再次移动或删除。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextField("搜索原路径、恢复路径或处理说明", text: $search).textFieldStyle(.roundedBorder)
                    if !state.recoveryPaths.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("发现可能的未完成移动目录", systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(Color.doctorAmber)
                            Text("这些目录来自真实扫描，用途待确认，已保留。请核对处理记录、原路径和内容；此处不提供清理。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(matchingRecoveries.prefix(200)), id: \.self) { path in
                                    RecoveryPathRow(path: path)
                                }
                            }
                            if matchingRecoveries.count > 200 {
                                Text("显示前 200 个位置，共 \(matchingRecoveries.count) 个；可搜索完整路径。").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.doctorAmber.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(matchingReceipts.prefix(200))) { receipt in
                            CleanupReceiptRow(receipt: receipt)
                        }
                    }
                    if matchingReceipts.count > 200 {
                        Text("显示最近 200 条符合条件的记录，共 \(matchingReceipts.count) 条；可搜索完整路径查找较早的记录。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if matchingReceipts.isEmpty && matchingRecoveries.isEmpty {
                        Text("没有符合搜索条件的记录。").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 14)
            }
        }
        .onChange(of: state.cleanupReceipts.count) { _, _ in if needsAttention { expanded = true } }
        .onChange(of: state.recoveryPaths.count) { _, _ in if needsAttention { expanded = true } }
    }
    private func matches(_ text: String) -> Bool { text.localizedCaseInsensitiveContains(search) }
}

private struct RecoveryPathRow: View {
    @EnvironmentObject private var state: DoctorState
    let path: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("已保留 · 用途待确认").font(.caption).foregroundStyle(Color.doctorAmber)
                Text(path).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("复制路径") { state.copy(path) }.controlSize(.small)
            Button("Finder 中查看") { state.reveal(path) }.controlSize(.small)
        }
    }
}

private struct CleanupReceiptRow: View {
    @EnvironmentObject private var state: DoctorState
    let receipt: CleanupReceipt
    private var accent: Color {
        switch receipt.item.status { case .trashed: return .doctorMint; case .blocked: return .doctorAmber; case .failed: return .doctorRed }
    }
    private var status: String {
        switch receipt.item.status { case .trashed: return "已移至废纸篓"; case .blocked: return "已保留"; case .failed: return "未完成 · 请核对" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(status, systemImage: receipt.item.status == .trashed ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(accent)
                Spacer()
                Text(receipt.recordedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Text("原完整路径：" + receipt.item.path).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(receipt.item.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if receipt.item.status == .trashed {
                Text("废纸篓可能显示“DOJA Mac Doctor Recovery …”这个临时名称。Finder 恢复后，需核对上方原完整路径，并改回原缓存目录名；不会自动恢复原名称。Codex 也可自行重建缓存。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let path = receipt.item.trashPath { receiptPath("系统返回的废纸篓位置", path: path) }
            if let path = receipt.item.recoveryPath { receiptPath("记录中的恢复位置", path: path) }
            HStack {
                Button("复制原路径") { state.copy(receipt.item.path) }.controlSize(.small)
                if receipt.item.status != .trashed && receipt.item.recoveryPath == nil {
                    Button("查看原位置") { state.reveal(receipt.item.path) }.controlSize(.small)
                }
                Spacer()
            }
        }.padding(.vertical, 15)
        Divider().opacity(0.35)
    }
    private func receiptPath(_ title: String, path: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption2).foregroundStyle(accent)
                Text(path).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("复制") { state.copy(path) }.controlSize(.small)
            Button("Finder 中查看") { state.reveal(path) }.controlSize(.small)
        }
    }
}

private struct CleanupSelectionBar: View {
    @EnvironmentObject private var state: DoctorState
    private var hasEligibleItems: Bool { state.cleanupAssessments.contains(where: \.canSelect) }
    private var selectionTitle: String {
        if state.cleaning { return "正在处理已勾选的项目" }
        if state.scanning || state.cleanupPreparation { return "正在检查可处理项目" }
        if state.selectedCleanupCount > 0 {
            return "已选 \(state.selectedCleanupCount) 项 · 文件大小 \(DoctorFormat.bytes(state.selectedLogicalBytes))"
        }
        return hasEligibleItems ? "勾选想要处理的项目" : "本次暂无可处理项目"
    }
    private var selectionNote: String {
        if state.cleaning { return "仅处理这次确认的项目；发生变化或无法核实的文件会保留。" }
        if state.scanning || state.cleanupPreparation { return "完成核实后再提供选择，不会自动勾选或清理。" }
        if state.selectedCleanupCount > 0 {
            return "清空废纸篓后预计释放：0 ～ \(DoctorFormat.bytes(state.selectedAllocatedUpperBound))（上限估算）"
        }
        return hasEligibleItems ? "只允许选择已通过安全核实的临时文件。" : "重要数据与用途不明的项目已保留，详见下方原因。"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(selectionTitle)
                        .font(.headline)
                    Text(selectionNote)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Button {
                    state.cleanSelected()
                } label: {
                    HStack(spacing: 8) {
                        if state.cleaning { ProgressView().controlSize(.small) }
                        Image(systemName: "trash")
                        Text(state.cleaning ? "正在移至废纸篓…" : "一键移至废纸篓")
                    }.padding(.horizontal, 8).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent)
                    .disabled(state.selectedCleanupCount == 0 || state.scanning || state.cleanupPreparation || state.cleaning)
                    .help("仅处理你勾选的项目；不清空废纸篓")
            }
            Text("点击后仅把勾选项目移至系统废纸篓。你可以恢复；移入废纸篓通常不会立即释放空间。硬链接、克隆和快照可能让实际释放量低于估算。")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.doctorMint.opacity(0.075), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.doctorMint.opacity(0.16)))
    }
}

private struct CleanupAssessmentRow: View {
    @EnvironmentObject private var state: DoctorState
    let item: CleanupAssessment
    private var finding: DiagnosticFinding? { state.findings.first { $0.path == item.path } }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if item.canSelect {
                Toggle("选择 " + item.title, isOn: Binding(
                    get: { state.selectedCleanupPaths.contains(item.path) },
                    set: { selected in
                        if selected != state.selectedCleanupPaths.contains(item.path) { state.toggleCleanupSelection(path: item.path) }
                    }
                )).labelsHidden().toggleStyle(.checkbox)
                    .disabled(state.scanning || state.cleanupPreparation || state.cleaning)
                    .padding(.top, 3)
            } else {
                Image(systemName: "lock.fill").foregroundStyle(riskColor(item.risk)).frame(width: 16).padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text(item.title).font(.system(size: 14, weight: .semibold))
                    Text(item.canSelect ? "可重新生成" : riskName(item.risk))
                        .font(.caption2).foregroundStyle(riskColor(item.risk))
                }
                Text(item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let finding {
                    Text(finding.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(item.message).font(.caption).foregroundStyle(item.canSelect ? Color.secondary : riskColor(item.risk))
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 7) {
                Text(DoctorFormat.bytes(item.logicalBytes)).font(.callout).monospacedDigit().bold()
                Text("分配 " + DoctorFormat.bytes(item.allocatedBytes)).font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    if let finding { Button("详情") { state.detail = InspectionItem(finding: finding) }.controlSize(.small) }
                    Button { state.reveal(item.path) } label: { Image(systemName: "folder") }.controlSize(.small).help("在 Finder 中定位")
                }
            }.frame(width: 145, alignment: .trailing)
        }.padding(.vertical, 15)
        .contextMenu {
            Button("复制完整路径") { state.copy(item.path) }
            Button("在 Finder 中定位") { state.reveal(item.path) }
        }
        Divider().opacity(0.35)
    }
}

private struct FindingCard: View {
    @EnvironmentObject private var state: DoctorState
    let finding: DiagnosticFinding
    var body: some View {
        Panel(title: finding.title, subtitle: finding.domain) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(riskName(finding.risk)).font(.caption).foregroundStyle(riskColor(finding.risk))
                    Text(finding.path).font(.callout).textSelection(.enabled)
                    Text(finding.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(finding.advice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let modified = finding.lastModified { Text("目录最后修改：" + modified.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
                    if !finding.isComplete { Label("未完整扫描，大小只是已读取部分", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.doctorAmber) }
                }
                Spacer(minLength: 20)
                VStack(alignment: .trailing, spacing: 10) {
                    Text(!finding.isComplete && finding.logicalBytes == 0 ? "未取得" : DoctorFormat.bytes(finding.logicalBytes)).font(.title2).bold()
                    Text("分配 " + (!finding.isComplete && finding.allocatedBytes == 0 ? "未取得" : DoctorFormat.bytes(finding.allocatedBytes))).font(.caption).foregroundStyle(.secondary)
                    Text(finding.estimatedReclaimUpperBound.map { "估算 0 ～ " + DoctorFormat.bytes($0) } ?? "可回收量待确认").font(.caption).foregroundStyle(riskColor(finding.risk))
                    Button("查看完整说明") { state.detail = InspectionItem(finding: finding) }
                    Button("在 Finder 中定位") { state.reveal(finding.path) }
                }.frame(minWidth: 170)
            }
        }
    }
}

private struct ApplicationsView: View {
    @EnvironmentObject private var state: DoctorState
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Panel(title: "Codex 与影视后期", subtitle: "发现实际目录 · 保留重要数据") {
                Text("自动扫描会检查可访问的常见应用目录，并按实际目录识别不同版本的工作数据。自定义缓存盘、开发项目和媒体目录可按需添加；整个应用数据目录不会作为一项清理。")
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(5)
                HStack { Button("添加应用数据或媒体目录…") { state.chooseDirectory() }; Button("添加开发项目…") { state.chooseDirectory(project: true) } }.disabled(state.scanning || state.cleaning || state.cleanupPreparation)
            }
            Panel(title: "专项检查位置", subtitle: "只读取可访问目录的文件属性") {
                ForEach(state.discovered) { candidate in
                    HStack(alignment: .center, spacing: 15) {
                        Image(systemName: "folder.badge.questionmark").foregroundStyle(Color.doctorMint)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(candidate.title).font(.callout)
                            Text(candidate.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(discoveryLabel(candidate.status)).font(.caption).foregroundStyle(.secondary)
                        Button("选择并授权…") { state.chooseDirectory(initial: URL(fileURLWithPath: candidate.path)) }.disabled(state.scanning || state.cleaning || state.cleanupPreparation)
                    }.padding(.vertical, 6)
                    Divider().opacity(0.35)
                }
            }
            if state.result != nil {
                Text("以下结论来自真实扫描。新增检查目录后请重新扫描；可处理项集中在首页。").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(state.findings.filter { $0.domain != "通用" }.prefix(200))) { finding in FindingCard(finding: finding) }
            }
        }
    }
    private func discoveryLabel(_ status: String) -> String {
        switch status {
        case "available": return "发现目录"
        case "notAuthorized": return "待授权核实"
        case "missing": return "路径不存在"
        case "denied": return "无权限核实"
        case "symbolicLink": return "符号链接 · 跳过"
        default: return "暂未核实"
        }
    }
}

private struct EmptyCard: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(Color.doctorMint.opacity(0.6))
            Text(title).font(.title3).bold()
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 550)
        }.padding(40).frame(maxWidth: .infinity).background(Color.doctorPanel, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct DetailView: View {
    @EnvironmentObject private var state: DoctorState
    @Environment(\.dismiss) private var dismiss
    let item: InspectionItem
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text(item.title).font(.title2).bold(); Spacer(); Button("完成") { dismiss() } }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    detail("完整路径", item.path)
                    HStack(spacing: 40) { detail("文件大小", !item.complete && item.logicalBytes == 0 ? "未取得" : DoctorFormat.bytes(item.logicalBytes)); detail("分配空间", !item.complete && item.allocatedBytes == 0 ? "未取得" : DoctorFormat.bytes(item.allocatedBytes)) }
                    detail("最后修改", item.modified?.formatted(date: .abbreviated, time: .standard) ?? "未取得")
                    detail("文件用途与判断依据", item.purpose)
                    detail("处理风险", item.risk)
                    detail("预计可释放空间", item.reclaim)
                    if !item.complete { Text("此目录没有完整扫描；已显示的数字只是已读取部分。").foregroundStyle(Color.doctorAmber) }
                    Text("目录包括子目录。硬链接按首次路径分配空间归属；文件明细显示该文件自己的分配值。APFS 克隆与快照的共享磁盘块尚未核实。移至废纸篓与实际释放磁盘空间是两个不同步骤。")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                }.textSelection(.enabled)
            }
            HStack { Button("复制完整路径") { state.copy(item.path) }; Button("在 Finder 中定位") { state.reveal(item.path) }; Spacer(); Label("查看文件说明", systemImage: "lock.shield").foregroundStyle(Color.doctorMint) }
        }.padding(28).frame(width: 700, height: 620).background(Color.doctorBackground).preferredColorScheme(.dark)
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.callout).fixedSize(horizontal: false, vertical: true) }
    }
}

private struct GuideView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Panel(title: "打开 → 查看 → 勾选 → 处理") {
                Text("打开软件后会自动检查本机常见目录和已有授权目录，无需先配置扫描流程。扫描支持暂停、继续和取消。\n\n“可放心处理”只显示用途明确、能够重新生成且通过安全核实的临时文件。默认不勾选任何文件；你勾选后，点击“一键移至废纸篓”即可处理。\n\n有风险、不确定用途、应用正在使用、身份已变化或未完整扫描的项目会保留，并给出原因。原始素材、媒体、工程、项目数据库、用户作品、配置和会话记录不会直接进入清理。")
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(6)
            }
            Panel(title: "移至废纸篓不等于释放空间") {
                Text("本应用只把你勾选且再次通过安全检查的项目移至系统废纸篓，不替你清空废纸篓。需要时可通过 Finder 恢复。文件身份发生变化或移动失败时会跳过并明确提示。\n\n文件大小是内容长度；分配空间是文件系统报告的磁盘占用。目录包含子目录，目录榜单不能相加。APFS 克隆、硬链接和快照可能共享磁盘块，因此只能显示可释放空间的上限估算，实际释放可能为零。")
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(6)
            }
            Panel(title: "看清占用与异常") {
                Text("“详细扫描”显示最大的 20 个目录、最大的 50 个文件、近七天大型文件、文件类型和未扫描项。分析完成后保留最大的 2000 个目录及扫描根目录、最多 1000 条覆盖问题；界面每次显示最多 500 条问题，搜索只覆盖保留记录。扫描汇总及问题总数来自全部真实扫描，未保留的记录不表示没有占用。重复扫描仅比较双方保留且完整的目录。“应用诊断”说明 Codex 与影视后期目录的用途和风险；自定义缓存盘或项目目录可按需添加。\n\n首页每分钟记录实际剩余容量、内存压力和交换空间，并在本机保存有容量上限的历史数据。十分钟内可用空间减少超过 3 GB 时生成异常事件；重点目录仅作轻量检查，不持续扫描整个硬盘。相同且完整的目录读数可提供增长线索，但不能直接认定某个应用造成骤降。没有足够证据时，始终标为“原因待确认”；软件未运行或无法采样的时段不补造历史。")
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(6)
            }
            Panel(title: "权限与隐私") {
                Text("所有扫描和分析都在本机，不上传文件内容，不依赖云服务器，不默认请求管理员权限，也不要求关闭系统保护。扫描读取路径和文件属性；授权书签、容量历史与有容量限制的处理记录保存在本机，便于核对原路径和恢复位置。\n\nmacOS 可能阻止访问部分目录。应用会明确显示未扫描，绝不会把无权限目录当成空目录；需要时再选择目录授权。导出的诊断报告包含完整路径，由你决定保存和分享。")
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(6)
            }
        }
    }
}
