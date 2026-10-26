import Foundation
import Darwin

public enum RiskLevel: String, Codable, Sendable {
    case green, yellow, red

    public var label: String {
        switch self {
        case .green: return "绿色 · 可重新生成"
        case .yellow: return "黄色 · 需要判断"
        case .red: return "红色 · 需要保留"
        }
    }
}

public struct DiagnosticFinding: Codable, Identifiable, Sendable {
    public let id: String
    public let path: String
    public let title: String
    public let domain: String
    public let reason: String
    public let advice: String
    public let risk: RiskLevel
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let lastModified: Date?
    public let isComplete: Bool
    /// A range of 0...this value; nil means no defensible estimate is available.
    /// This is never a promise of free space and must not be summed with parent findings.
    public let estimatedReclaimUpperBound: Int64?

    public init(id: String, path: String, title: String, domain: String, reason: String,
                advice: String, risk: RiskLevel, logicalBytes: Int64, allocatedBytes: Int64,
                lastModified: Date?, isComplete: Bool, estimatedReclaimUpperBound: Int64?) {
        self.id = id; self.path = path; self.title = title; self.domain = domain
        self.reason = reason; self.advice = advice; self.risk = risk
        self.logicalBytes = logicalBytes; self.allocatedBytes = allocatedBytes
        self.lastModified = lastModified; self.isComplete = isComplete
        self.estimatedReclaimUpperBound = estimatedReclaimUpperBound
    }
}

public struct GrowthFinding: Codable, Identifiable, Sendable {
    public let id: String
    public let path: String
    public let logicalDelta: Int64
    public let allocatedDelta: Int64
    public let reason: String
}

private struct DiagnosticRule {
    let title: String
    let domain: String
    let risk: RiskLevel
    let reason: String
    let advice: String
}

public struct DiagnosisEngine: Sendable {
    public init() {}

    /// Rules use only the supplied scan metadata. No files are opened or changed here.
    public func findings(for scan: ScanResult, projectRoots: [String] = []) -> [DiagnosticFinding] {
        let projects = projectRoots.map(DoctorPath.normalized)
        let files = uniqueFiles(scan.largestFiles + scan.recentLargeFiles)
        var matches: [DiagnosticFinding] = []
        for record in scan.directories {
            // A missing/denied root with no visited files is an issue, not evidence
            // of a real cache to remove. It stays visible in the scan issue list.
            guard record.isComplete || record.fileCount > 0 else { continue }
            guard var rule = rule(for: record.path, isDirectory: true, projectRoots: projects) else { continue }
            // A broad cache folder is not a cleanup unit. Preserve fixed known
            // leaf suggestions rather than hiding them under an aggregate root.
            if rule.risk == .green, !record.containsProtectedFiles,
               record.path.hasSuffix("/Library/Caches/Codex") || record.path.hasSuffix("/Library/Caches/com.openai.codex"),
               scan.directories.contains(where: {
                   URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == record.path
                       && ["GPUCache", "Code Cache", "ShaderCache", "DawnCache", "GrShaderCache"].contains(URL(fileURLWithPath: $0.path).lastPathComponent)
               }) { continue }
            if rule.risk != .red && record.containsProtectedFiles {
                rule = protected("混有需保留文件", domain: rule.domain,
                                 reason: "逐文件元数据检查发现代码、配置、会话、媒体或工程等受保护文件。不能把整个缓存或临时目录作为处理单位。")
            }
            if rule.risk == .green && !record.isComplete {
                rule = DiagnosticRule(title: "缓存用途与覆盖待确认", domain: rule.domain, risk: .yellow,
                                      reason: "目录仅被部分读取，不能确认整个范围都是可重新生成的缓存。",
                                      advice: "先查看未扫描项目并按需要授权完整范围；覆盖确认前不提供处理建议。")
            }
            matches.append(finding(path: record.path, rule: rule, logical: record.logicalBytes,
                                   allocated: record.allocatedBytes, modified: record.lastModified,
                                   complete: record.isComplete, hardLinked: false))
        }
        for record in files {
            guard let rule = rule(for: record.path, isDirectory: false, projectRoots: projects) else { continue }
            matches.append(finding(path: record.path, rule: rule, logical: record.logicalBytes,
                                   allocated: record.allocatedBytes, modified: record.modifiedAt,
                                   complete: scan.status == .completed,
                                   hardLinked: record.linkCount > 1))
        }

        // Explicitly protected descendants win over cache-name hints. Such a parent
        // cannot be presented as a removable unit, even if it is called "Cache".
        let protectedPaths = matches.filter { $0.risk == .red }.map(\.path)
        matches = matches.filter { candidate in
            candidate.risk == .red || !protectedPaths.contains {
                $0 != candidate.path && DoctorPath.contains(parent: candidate.path, child: $0)
            }
        }

        // Pick shallower semantic units first, then suppress every contained child.
        // These findings are disjoint paths; raw directory rankings remain separate.
        matches.sort {
            let lhsDepth = DoctorPath.components($0.path).count
            let rhsDepth = DoctorPath.components($1.path).count
            return lhsDepth == rhsDepth ? $0.path < $1.path : lhsDepth < rhsDepth
        }
        var selected: [DiagnosticFinding] = []
        for candidate in matches where !selected.contains(where: { DoctorPath.overlaps($0.path, candidate.path) }) {
            selected.append(candidate)
        }
        return selected.sorted {
            $0.allocatedBytes == $1.allocatedBytes ? $0.path < $1.path : $0.allocatedBytes > $1.allocatedBytes
        }
    }

    /// An on-demand comparison, not a background monitor or a causation claim.
    public func growth(previous: ScanResult, current: ScanResult) -> [GrowthFinding] {
        guard previous.status == .completed, current.status == .completed,
              previous.finishedAt <= current.startedAt,
              Set(previous.roots.map(DoctorPath.normalized)) == Set(current.roots.map(DoctorPath.normalized))
        else { return [] }
        var before: [String: DirectoryRecord] = [:]
        for record in previous.directories where record.isComplete {
            before[DoctorPath.normalized(record.path)] = record
        }
        var changes: [GrowthFinding] = []
        for record in current.directories where record.isComplete {
            let path = DoctorPath.normalized(record.path)
            guard let old = before[path], old.id == record.id else { continue }
            let logical = record.logicalBytes - old.logicalBytes
            let allocated = record.allocatedBytes - old.allocatedBytes
            guard logical > 0 || allocated > 0 else { continue }
            changes.append(GrowthFinding(id: path, path: path, logicalDelta: logical,
                                         allocatedDelta: allocated,
                                         reason: "相同授权范围内两次完整扫描的目录占用增加。扫描期间文件仍可能变化；目录变化不能证明某个应用造成磁盘骤减，原因待确认。"))
        }
        // Semantic paths explain more than the encompassing home/project root.
        // Parent and child cannot both enter this result, so callers cannot double count.
        changes.sort {
            let lhsKnown = rule(for: $0.path, isDirectory: true, projectRoots: []) != nil
            let rhsKnown = rule(for: $1.path, isDirectory: true, projectRoots: []) != nil
            if lhsKnown != rhsKnown { return lhsKnown }
            let lhs = max($0.logicalDelta, $0.allocatedDelta)
            let rhs = max($1.logicalDelta, $1.allocatedDelta)
            return lhs == rhs ? $0.path < $1.path : lhs > rhs
        }
        var selected: [GrowthFinding] = []
        for change in changes where !selected.contains(where: { DoctorPath.overlaps($0.path, change.path) }) {
            selected.append(change)
            if selected.count == 20 { break }
        }
        return selected
    }

    private func uniqueFiles(_ files: [FileRecord]) -> [FileRecord] {
        var seen: Set<String> = []
        return files.filter { seen.insert(DoctorPath.normalized($0.path)).inserted }
    }

    private func finding(path: String, rule: DiagnosticRule, logical: Int64, allocated: Int64,
                         modified: Date?, complete: Bool, hardLinked: Bool) -> DiagnosticFinding {
        let physicalCaution = "分配大小只作为估算上限；APFS 克隆、快照、硬链接及打开的文件会影响实际释放量，最低可能为 0。移至废纸篓也不会立即释放空间。"
        let completeness = complete ? "" : " 此目录未完整扫描，大小是已读取部分，无法估算回收空间。"
        let linkCaution = hardLinked ? " 检测到多个硬链接，单独处理此路径可能不释放数据块。" : ""
        let normalized = DoctorPath.normalized(path)
        let risk = !complete && rule.risk == .green ? RiskLevel.yellow : rule.risk
        let title = !complete && rule.risk == .green ? "缓存用途与覆盖待确认" : rule.title
        return DiagnosticFinding(id: normalized, path: normalized, title: title,
                                 domain: rule.domain, reason: rule.reason + completeness,
                                 advice: rule.advice + " " + physicalCaution + linkCaution,
                                 risk: risk, logicalBytes: logical, allocatedBytes: allocated,
                                 lastModified: modified, isComplete: complete,
                                 estimatedReclaimUpperBound: complete && !hardLinked && risk != .red ? max(0, allocated) : nil)
    }

    fileprivate func rule(for path: String, isDirectory: Bool, projectRoots: [String]) -> DiagnosticRule? {
        let normalized = DoctorPath.normalized(path)
        let components = DoctorPath.components(normalized).map { $0.lowercased() }
        guard let name = components.last else { return nil }
        let parent = components.dropLast().last ?? ""
        let inCodexHome = components.contains(".codex") || MetadataProtection.configuredCodexHome.map {
            DoctorPath.contains(parent: $0, child: normalized)
        } == true
        let codex = inCodexHome || components.contains("codex") || components.contains("com.openai.codex")
        let mediaApp = components.contains { $0.contains("davinci resolve") || $0 == "blackmagic design"
            || $0 == "jianyingpro" || $0 == "capcut" || $0.hasPrefix("com.lemon.") || $0.contains("剪映") }
        let project = projectRoots.contains { DoctorPath.contains(parent: $0, child: normalized) }
        let mediaCacheNames: Set<String> = ["cacheclip", "proxymedia", "proxy media", "proxies", "optimizedmedia", "optimized media", "rendercache", "render cache", "渲染缓存", "代理媒体", "优化媒体"]
        let inMediaCache = components.contains { mediaCacheNames.contains($0) }

        if DoctorPath.contains(parent: "/System", child: normalized)
            || DoctorPath.contains(parent: "/private/var/vm", child: normalized)
            || DoctorPath.contains(parent: "/private/var/db", child: normalized) {
            return protected("系统保护数据", domain: "系统", reason: "系统文件、交换空间或系统数据库由 macOS 管理。")
        }
        if codex, components.contains(where: {
            ["sessions", "archived_sessions", "worktrees", "memories", "skills", "plugins", "automations", "rules", "environments", "backups"].contains($0)
        }) {
            return protected("Codex 会话、配置与工作文件", domain: "Codex", reason: "这些目录可能保存聊天记录、未提交代码、技能、用户配置或可恢复的工作。不能归为垃圾。")
        }
        if components.contains(".git") {
            return protected("项目版本历史", domain: "开发项目", reason: "Git 数据保存版本历史和工作树关联信息。")
        }
        let protectedMediaNames: Set<String> = ["raw", "raw footage", "originals", "original media", "原始素材", "原始视频", "素材", "拍摄素材", "exports", "export", "outputs", "output", "导出", "成片", "作品", "drafts", "com.lveditor.draft", "resolve projects", "resolve disk database", "project database", ".gallery"]
        if components.contains(where: { protectedMediaNames.contains($0) }) || (mediaApp && components.contains("projects")) {
            return protected("工程、原始素材或作品文件", domain: mediaApp || inMediaCache ? "影视后期" : "用户文件",
                             reason: "路径显示可能包含工程数据库、原始素材、草稿、画廊或作品输出。默认保留；不能仅因占用较大而建议删除。")
        }
        let extensionName = URL(fileURLWithPath: normalized).pathExtension.lowercased()
        let projectExtensions: Set<String> = ["drp", "dra", "db", "sqlite", "sqlite3", "resolve", "prproj", "aep", "fcpbundle", "fcpxml", "otio", "veg", "blend", "psd"]
        let codexLogDB = inCodexHome && name.hasPrefix("logs_")
            && (name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite-wal") || name.hasSuffix(".sqlite-shm"))
        if !isDirectory && projectExtensions.contains(extensionName) && !codexLogDB {
            return protected("工程或数据库文件", domain: codex ? "Codex" : "用户文件", reason: "此扩展名可能保存工程或数据库；文件内容与用途未读取，默认保留。")
        }
        if codex, !isDirectory,
           ["config.toml", "auth.json", "history.jsonl", "session_index.jsonl", "agents.md"].contains(name) {
            return protected("Codex 用户配置或历史", domain: "Codex", reason: "该文件保存用户设置、身份信息或会话索引，默认保留。")
        }
        let mediaExtensions: Set<String> = ["mov", "mp4", "m4v", "mkv", "avi", "webm", "mxf", "r3d", "braw", "crm", "mts", "m2ts", "wav", "aif", "aiff", "mp3", "m4a", "flac", "aac", "ogg", "exr", "dpx", "dng", "raw"]
        if !isDirectory && mediaExtensions.contains(extensionName) && !inMediaCache {
            return protected("视频、音频或拍摄素材", domain: "影视后期", reason: "媒体用途未确认，可能是原始素材或用户作品，默认保留。")
        }
        let sourceExtensions: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "c", "cpp", "h", "html", "css", "sh"]
        if !isDirectory && sourceExtensions.contains(extensionName) && !components.contains("node_modules") {
            return protected("项目代码或脚本", domain: "开发项目", reason: "代码和脚本属于用户工作文件；不因体积或修改时间而归为垃圾。")
        }
        let configurationExtensions: Set<String> = ["toml", "yaml", "yml", "ini", "conf", "plist"]
        if !isDirectory && configurationExtensions.contains(extensionName) && !components.contains("node_modules") {
            return protected("用户或应用配置文件", domain: codex ? "Codex" : "用户文件", reason: "配置文件可能保存用户设置或工作流程，默认保留。")
        }
        let inPendingReports = components.indices.contains { index in
            index + 1 < components.count && components[index] == "crashpad" && components[index + 1] == "pending"
        }
        if codex && ((parent == "crashpad" && name == "pending") || (!isDirectory && inPendingReports && extensionName == "dmp")) {
            return DiagnosticRule(title: "Codex 待处理崩溃报告", domain: "Codex", risk: .yellow,
                                  reason: "实际目录名称为 Crashpad/pending。它用于崩溃诊断，不能由单次大小判断是否异常。",
                                  advice: "先保留最近问题所需的报告，确认不再排查且应用已退出后再判断历史报告。用途与保留需求尚未确认，不提供处理入口。")
        }
        let inKnownLogDirectory = (inCodexHome && components.contains(where: { ["log", "logs"].contains($0) }))
            || (components.contains("logs") && components.contains("com.openai.codex"))
            || (parent == "logs" && ["codex", "com.openai.codex"].contains(name))
        let isCodexLogs = codex && (codexLogDB || (inKnownLogDirectory && (isDirectory || ["log", "jsonl"].contains(extensionName))))
        if isCodexLogs {
            return DiagnosticRule(title: "Codex 运行日志", domain: "Codex", risk: .yellow,
                                  reason: "路径和文件名符合 Codex 日志位置，日志可用于故障排查；大小本身不证明异常。",
                                  advice: "观察同一范围的后续增长，保存近期故障证据。日志数据库及其 WAL/SHM 必须作为整体考虑，运行期间不能直接删除。")
        }
        let isLibraryAppPath = components.indices.contains { index in
            guard index + 2 < components.count else { return false }
            return components[index] == "library" && ["application support", "caches"].contains(components[index + 1])
                && ["codex", "com.openai.codex"].contains(components[index + 2])
        }
        let codexCache = isLibraryAppPath && ((parent == "caches" && ["codex", "com.openai.codex"].contains(name))
            || ["gpucache", "code cache", "shadercache", "dawncache", "grshadercache"].contains(name)
            || (components.contains("application support") && ["cache", "cache_data"].contains(name)))
        if codexCache {
            return DiagnosticRule(title: "Codex 可再生成的应用缓存", domain: "Codex", risk: .green,
                                  reason: "路径属于已识别的应用缓存位置。它是缓存线索，不代表当前正在使用的文件可以立即处理。",
                                  advice: "应用退出后可考虑重建缓存，之后首次打开或渲染可能变慢。只有全部条目均核实为已知缓存格式、没有混入个人文件且扫描结果仍相符时，才可勾选并移至废纸篓。")
        }
        if isDirectory && mediaCacheNames.contains(name) {
            return DiagnosticRule(title: "渲染缓存、代理或优化媒体（需确认）", domain: "影视后期", risk: .yellow,
                                  reason: "实际目录名符合常见影视缓存名称。工作目录可按版本和工程自定义，名称无法证明它就是某个工程的缓存。",
                                  advice: "在相应剪辑软件的工程设置中核对真实缓存位置，并确认原始素材可用、工程可重新生成。代理或优化媒体可能用于离线剪辑与交付，优先由软件管理。")
        }
        if isDirectory && mediaApp && ["cache", "caches", "temp", "tmp", "logs", "log"].contains(name) {
            return DiagnosticRule(title: "影视软件缓存或日志（需确认）", domain: "影视后期", risk: .yellow,
                                  reason: "目录位于实际匹配的影视应用路径，名称提示缓存、日志或临时用途；未读取配置内容确认工程关联。",
                                  advice: "在应用内核对目录用途和正在使用的工程。临时输出可能尚未完成，历史缓存也可能仍被工程引用；确认后再处理。")
        }
        if isDirectory && name == "node_modules" && (project || codex) {
            return DiagnosticRule(title: "开发依赖 node_modules", domain: "开发项目", risk: .yellow,
                                  reason: "此目录通常存放安装的开发依赖，但可能含本地修改、离线依赖或无法恢复的包。",
                                  advice: "确认依赖清单、锁定文件及安装来源可用，检查是否有本地修改。仅建议；不处理项目代码或相关工作树。")
        }
        if isDirectory && (project || codex) && [".build", ".next", ".turbo", ".parcel-cache", ".vite", ".cache", "deriveddata"].contains(name) {
            return DiagnosticRule(title: "开发构建缓存（需确认）", domain: "开发项目", risk: .yellow,
                                  reason: "目录名提示构建或工具缓存，但仅凭名称不能证明全部内容可重新生成。",
                                  advice: "确认构建流程和工具配置，结束正在运行的构建后再判断。不得把整个项目、dist、build 或工作树当成垃圾。")
        }
        if codex && isDirectory && ["tmp", "temp", "temporary"].contains(name) {
            return DiagnosticRule(title: "Codex 临时工作目录（需确认）", domain: "Codex", risk: .yellow,
                                  reason: "路径提示临时用途，内容可能是未完成构建或仍在使用的工作文件。",
                                  advice: "核对是否仍有会话、构建或工具引用该目录，不能仅凭临时目录名称清理。")
        }
        if isDirectory && !isLibraryAppPath && !inCodexHome
            && (normalized.hasPrefix("/private/var/folders/") || normalized.hasPrefix("/private/tmp/") || normalized.hasPrefix("/tmp/")),
           name.contains("codex") || name.contains("codesign") || name.contains("code-sign") {
            return DiagnosticRule(title: "临时构建或签名副本（归属待确认）", domain: "开发临时文件", risk: .yellow,
                                  reason: "系统临时位置与目录名提供构建或签名线索，未证实由 Codex 创建或可重新生成。",
                                  advice: "确认创建工具、源项目、最后修改时间以及是否仍被使用。单次扫描不能归因，不能直接删除整个系统临时目录。")
        }
        if codex && inCodexHome && !isDirectory {
            return protected("Codex 数据（用途待确认）", domain: "Codex", reason: "Codex 数据目录中的文件用途未确认，可能关联配置、会话或开发工作。")
        }
        return nil
    }

    private func protected(_ title: String, domain: String, reason: String) -> DiagnosticRule {
        DiagnosticRule(title: title, domain: domain, risk: .red, reason: reason,
                       advice: "默认保留，不提供勾选处理。需要变更时先确认用途与备份，不能按目录整体清理。")
    }
}

/// This rule runs for every file visited, before ranking truncates the inventory.
/// It uses names and paths only; file contents are never needed or opened.
public enum MetadataProtection {
    fileprivate static let configuredCodexHome: String? = {
        guard let value = ProcessInfo.processInfo.environment["CODEX_HOME"], value.hasPrefix("/") else { return nil }
        return DoctorPath.normalized(value)
    }()

    public static func requiresPreservation(path: String) -> Bool {
        DiagnosisEngine().rule(for: path, isDirectory: false, projectRoots: [])?.risk == .red
    }
}

public struct DiscoveredPath: Codable, Identifiable, Sendable {
    public let id: String
    public let path: String
    public let title: String
    public let domain: String
    /// available / notAuthorized / missing / denied / unavailable / symbolicLink
    public let status: String
}

public enum DiagnosticDiscovery {
    /// Candidate paths are hints, not assumed storage locations or scan results.
    /// Only explicitly covered paths are inspected; discovery never reads file contents.
    public static func candidates(home: URL, authorizedRoots: [URL]) -> [DiscoveredPath] {
        let roots = authorizedRoots.map { DoctorPath.normalized($0.path) }
        let homePath = DoctorPath.normalized(home.path)
        var suggestions: [(String, String, String)] = [
            (".codex", "Codex 本地数据（包含需要保留的会话与工作）", "Codex"),
            ("Library/Application Support/Codex", "Codex 应用数据（按实际存在核对）", "Codex"),
            ("Library/Application Support/Codex/Crashpad/pending", "Codex 待处理崩溃报告（按实际存在核对）", "Codex"),
            ("Library/Logs/com.openai.codex", "Codex 应用日志", "Codex"),
            ("Library/Caches/com.openai.codex", "Codex 应用缓存（按实际存在核对）", "Codex"),
            ("Library/Caches/Codex", "Codex 应用缓存（按实际存在核对）", "Codex"),
            ("Library/Application Support/Blackmagic Design/DaVinci Resolve", "DaVinci Resolve 应用与工程数据（默认保留）", "影视后期"),
            ("Library/Application Support/JianyingPro", "剪映应用数据（按实际存在核对）", "影视后期"),
            ("Movies/JianyingPro", "剪映工程与媒体（默认保留）", "影视后期"),
            ("Library/Application Support/CapCut", "CapCut 应用数据（按实际存在核对）", "影视后期"),
            ("Movies/CapCut", "CapCut 工程与媒体（默认保留）", "影视后期")
        ].map { (URL(fileURLWithPath: homePath).appendingPathComponent($0.0).path, $0.1, $0.2) }
        // The environment may supply a custom CODEX_HOME. It remains a candidate,
        // never an implicit access grant and never an environment value we modify.
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], configured.hasPrefix("/") {
            suggestions.append((configured, "自定义 Codex 本地数据（默认保留）", "Codex"))
        }
        suggestions.append((NSTemporaryDirectory(), "当前用户临时目录（用途需确认）", "开发临时文件"))

        var searchHubs = roots
        for suffix in ["Library/Application Support", "Library/Caches", "Library/Logs", "Library/Containers", "Movies"] {
            let hub = URL(fileURLWithPath: homePath).appendingPathComponent(suffix).path
            if roots.contains(where: { DoctorPath.contains(parent: $0, child: hub) }) { searchHubs.append(hub) }
        }
        var visited: Set<String> = []
        for hub in searchHubs where visited.insert(DoctorPath.normalized(hub)).inserted {
            guard status(of: hub, roots: roots) == "available" else { continue }
            for child in shallowChildren(hub, limit: 512) {
                let name = URL(fileURLWithPath: child).lastPathComponent.lowercased()
                guard let domain = domainForName(name) else { continue }
                suggestions.append((child, "发现实际名称：\(URL(fileURLWithPath: child).lastPathComponent)（用途需确认）", domain))
                if name == "blackmagic design", status(of: child, roots: roots) == "available" {
                    for nested in shallowChildren(child, limit: 64) where URL(fileURLWithPath: nested).lastPathComponent.lowercased().contains("resolve") {
                        suggestions.append((nested, "发现 Resolve 实际应用数据（默认保留）", "影视后期"))
                    }
                }
            }
        }
        var seen: Set<String> = []
        return suggestions.compactMap { path, title, domain in
            let normalized = DoctorPath.normalized(path)
            guard seen.insert(normalized).inserted else { return nil }
            return DiscoveredPath(id: normalized, path: normalized, title: title, domain: domain,
                                  status: status(of: normalized, roots: roots))
        }
    }

    private static func domainForName(_ name: String) -> String? {
        if name == ".codex" || name == "codex" || name.hasPrefix("com.openai.codex") || name.contains("codex-") { return "Codex" }
        if name.contains("resolve") || name.contains("blackmagic") || name.contains("jianying") || name.contains("capcut")
            || name.contains("剪映") || name.hasPrefix("com.lemon.") { return "影视后期" }
        if ["cacheclip", "proxymedia", "optimizedmedia"].contains(name) { return "影视后期" }
        if name.contains("codesign") || name.contains("code-sign") { return "开发临时文件" }
        return nil
    }

    private static func status(of path: String, roots: [String]) -> String {
        let normalized = DoctorPath.normalized(path)
        guard let root = roots.filter({ DoctorPath.contains(parent: $0, child: normalized) }).max(by: { $0.count < $1.count })
        else { return "notAuthorized" }
        // Reject links in the root's ancestors as well as its final component.
        // Relative fstatat/openat then prevents an intermediate link or rename race
        // from making discovery inspect another location outside this grant.
        var descriptor = root.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return statusForError(errno) }
        defer { close(descriptor) }
        let suffix = String(normalized.dropFirst(root.count)).split(separator: "/").map(String.init)
        for (index, component) in suffix.enumerated() {
            var info = stat()
            let code = component.withCString { fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }
            guard code == 0 else { return statusForError(errno) }
            if info.st_mode & S_IFMT == S_IFLNK { return "symbolicLink" }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                return index == suffix.count - 1 ? "available" : "missing"
            }
            let child = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard child >= 0 else { return statusForError(errno) }
            var opened = stat()
            guard fstat(child, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
                close(child)
                return "unavailable"
            }
            close(descriptor)
            descriptor = child
        }
        return "available"
    }

    private static func statusForError(_ code: Int32) -> String {
        switch code {
        case ENOENT, ENOTDIR: return "missing"
        case EACCES, EPERM: return "denied"
        case ELOOP: return "symbolicLink"
        default: return "unavailable"
        }
    }

    private static func shallowChildren(_ path: String, limit: Int) -> [String] {
        let descriptor = path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return [] }
        guard let directory = fdopendir(descriptor) else { close(descriptor); return [] }
        defer { closedir(directory) }
        var children: [String] = []
        var inspected = 0
        while inspected < limit, let pointer = readdir(directory) {
            let name = withUnsafePointer(to: &pointer.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != "..", !name.hasPrefix("._") else { continue }
            inspected += 1
            children.append(URL(fileURLWithPath: path).appendingPathComponent(name).path)
        }
        return children
    }
}

private enum DoctorPath {
    // Foundation standardization can rewrite /private/tmp to the symlink /tmp.
    // Scope comparisons must be lexical; actual link checks happen at openat.
    static func normalized(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        var parts: [Substring] = []
        for component in absolute.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(component)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
    static func components(_ path: String) -> [String] { normalized(path).split(separator: "/").map(String.init) }
    static func contains(parent: String, child: String) -> Bool {
        let parent = normalized(parent), child = normalized(child)
        return parent == child || parent == "/" || child.hasPrefix(parent + "/")
    }
    static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        contains(parent: lhs, child: rhs) || contains(parent: rhs, child: lhs)
    }
}
