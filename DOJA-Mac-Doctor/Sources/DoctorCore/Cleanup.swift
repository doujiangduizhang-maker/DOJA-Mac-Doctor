import Foundation
import Darwin
import AppKit

public enum CleanupDisposition: String, Codable, Sendable {
    case eligible, blocked
}

public struct CleanupAssessment: Codable, Sendable, Identifiable {
    public let id: String
    public let path: String
    public let title: String
    public let risk: RiskLevel
    public let message: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let disposition: CleanupDisposition
    public var canSelect: Bool { disposition == .eligible }

    public init(id: String, path: String, title: String, risk: RiskLevel, message: String,
                logicalBytes: Int64, allocatedBytes: Int64, disposition: CleanupDisposition) {
        self.id = id; self.path = path; self.title = title; self.risk = risk; self.message = message
        self.logicalBytes = logicalBytes; self.allocatedBytes = allocatedBytes; self.disposition = disposition
    }

    public func blocked(message: String) -> CleanupAssessment {
        CleanupAssessment(id: id, path: path, title: title, risk: risk, message: message,
                          logicalBytes: logicalBytes, allocatedBytes: allocatedBytes, disposition: .blocked)
    }
}

/// Created only by prepare. A caller cannot supply or replace the private baseline.
public struct PreparedCleanupItem: Sendable, Identifiable {
    public let id: String
    public let path: String
    public let title: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let fileCount: Int
    fileprivate let ancestors: [CleanupAncestor]
    fileprivate let manifest: CleanupManifest
}

public struct CleanupPlan: Sendable {
    public let items: [PreparedCleanupItem]
    public let allowedRoots: [String]
    public let createdAt: Date
    fileprivate let home: String

    /// Subsetting retains the baseline shown to the user; it does not rescan or
    /// adopt later changes. An unknown path never creates an executable item.
    public func selecting(paths: Set<String>) -> CleanupPlan {
        CleanupPlan(items: items.filter { paths.contains($0.path) }, allowedRoots: allowedRoots,
                    createdAt: createdAt, home: home)
    }
}

public enum CleanupItemStatus: String, Codable, Sendable {
    case trashed, blocked, failed
}

public struct CleanupItemOutcome: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let status: CleanupItemStatus
    public let message: String
    public let trashPath: String?
    /// A visible staged item is retained here if restoration would overwrite a
    /// recreated original, the parent moved, or the system Trash could not finish.
    public let recoveryPath: String?
}

public struct CleanupOutcome: Codable, Sendable {
    public let items: [CleanupItemOutcome]
    public let totalLogicalBytes: Int64
    public let totalAllocatedBytes: Int64
    /// Whole-volume observations, influenced by other apps. They are not a
    /// measured amount reclaimed by this operation; Trash is not emptied here.
    public let availableBefore: Int64?
    public let availableAfter: Int64?
    public var trashedCount: Int { items.filter { $0.status == .trashed }.count }
}

public struct CleanupSafetyError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    fileprivate init(_ message: String) { self.message = message }
}

/// Only regenerable, purpose-confirmed Codex cache leaves can be selected in
/// this release. No generic Cache/tmp/log-name rule authorizes a filesystem move.
public struct CleanupService: Sendable {
    public init() {}

    public static func runningApplicationIdentifiers() -> [String] {
        NSWorkspace.shared.runningApplications.flatMap { app in
            [app.bundleIdentifier, app.localizedName].compactMap { $0 }
        }
    }

    public func assess(findings: [DiagnosticFinding], scan: ScanResult, home: URL,
                       runningApplications: [String] = CleanupService.runningApplicationIdentifiers()) -> [CleanupAssessment] {
        findings.map { finding in
            let message: String
            let disposition: CleanupDisposition
            do {
                try validateEvidence(finding, scan: scan, home: home.path,
                                     allowedRoots: scan.roots)
                try ensureApplicationStopped(runningApplications)
                _ = try inspectedItem(finding: finding, scan: scan, home: home.path)
                message = "用途与全部文件元数据已核对：可重新生成的 Codex 缓存。勾选后移至废纸篓；重启应用时缓存会重建，首次打开可能变慢。移至废纸篓不会立即释放磁盘空间。"
                disposition = .eligible
            } catch {
                message = error.localizedDescription
                disposition = .blocked
            }
            return CleanupAssessment(id: finding.id, path: finding.path, title: finding.title,
                                     risk: finding.risk, message: message,
                                     logicalBytes: finding.logicalBytes, allocatedBytes: finding.allocatedBytes,
                                     disposition: disposition)
        }
    }

    /// Read-only preparation binds every entry to the displayed scan. Do this
    /// when showing suggestions, then subset the resulting plan after selection.
    public func prepare(selected: [DiagnosticFinding], scan: ScanResult, home: URL,
                        allowedRoots: [URL]) throws -> CleanupPlan {
        let roots = try allowedRoots.map { try canonicalPath($0.path) }
        let homePath = try canonicalPath(home.path)
        var items: [PreparedCleanupItem] = []
        var seen = Set<String>()
        var preparedEntryCount = 0
        for finding in selected {
            try validateEvidence(finding, scan: scan, home: homePath, allowedRoots: roots)
            guard seen.insert(finding.path).inserted else { continue }
            guard !items.contains(where: { CleanupPath.overlaps($0.path, finding.path) }) else {
                throw CleanupSafetyError("处理范围有父子目录重叠，请重新扫描后选择。")
            }
            let item = try inspectedItem(finding: finding, scan: scan, home: homePath)
            preparedEntryCount += item.manifest.entries.count
            guard preparedEntryCount <= 200_000 else {
                throw CleanupSafetyError("本次建议的文件数量过多，无法轻量保存安全清单：请减少处理范围。")
            }
            items.append(item)
        }
        return CleanupPlan(items: items, allowedRoots: roots, createdAt: Date(), home: homePath)
    }

    /// `trash` is injectable only for isolated tests. The production default uses
    /// the macOS Trash API, never removeItem, shell commands, or administrator access.
    public func execute(plan: CleanupPlan,
                        runningApplications: @Sendable () -> [String] = { CleanupService.runningApplicationIdentifiers() },
                        trash: @Sendable (URL) throws -> URL? = { url in try CleanupService.systemTrash(url) }) -> CleanupOutcome {
        let before = SystemMetrics.sample().availableBytes
        var results: [CleanupItemOutcome] = []
        var logical: Int64 = 0
        var allocated: Int64 = 0
        for item in plan.items {
            let result: CleanupItemOutcome
            if Date().timeIntervalSince(plan.createdAt) > 15 * 60 || plan.createdAt > Date() {
                result = CleanupItemOutcome(path: item.path, status: .blocked,
                                            message: "建议已超过 15 分钟，请重新扫描后勾选。", trashPath: nil, recoveryPath: nil)
            } else {
                result = executeItem(item, home: plan.home, roots: plan.allowedRoots,
                                     runningApplications: runningApplications, trash: trash)
            }
            results.append(result)
            if result.status == .trashed {
                logical = cleanupAdding(logical, item.logicalBytes)
                allocated = cleanupAdding(allocated, item.allocatedBytes)
            }
        }
        return CleanupOutcome(items: results, totalLogicalBytes: logical, totalAllocatedBytes: allocated,
                              availableBefore: before, availableAfter: SystemMetrics.sample().availableBytes)
    }

    public static func systemTrash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    private func validateEvidence(_ finding: DiagnosticFinding, scan: ScanResult, home: String,
                                  allowedRoots: [String]) throws {
        let path = try canonicalPath(finding.path)
        let homePath = try canonicalPath(home)
        guard scan.status == .completed, finding.isComplete else {
            throw CleanupSafetyError("扫描未完成或已取消：保留此项，完整重扫前不可勾选。")
        }
        guard finding.risk == .green else {
            throw CleanupSafetyError(finding.risk == .red
                ? "重要工作或受保护文件：保留，不提供自动处理。"
                : "用途或删除风险仍需判断：保留，此版本不处理黄色项目。")
        }
        guard recognizedLeaf(path, home: homePath) else {
            throw CleanupSafetyError("不是已核实用途的缓存处理单元：保留。不会整体处理 Application Support、应用数据、开发项目或未知临时目录。")
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard allowedRoots.contains(where: { CleanupPath.contains(parent: $0, child: parent) }),
              scan.roots.contains(where: { CleanupPath.contains(parent: $0, child: parent) }) else {
            throw CleanupSafetyError("此目录或其父目录不在已授权扫描范围内：保留。")
        }
        guard let record = scan.directories.first(where: { $0.path == path }),
              record.isComplete, !record.containsProtectedFiles,
              record.logicalBytes == finding.logicalBytes,
              record.allocatedBytes == finding.allocatedBytes else {
            throw CleanupSafetyError("缺少完整、相符且不含工作文件的扫描记录：保留，请重新扫描。")
        }
        guard !scan.issues.contains(where: { CleanupPath.overlaps($0.path, path) }) else {
            throw CleanupSafetyError("此范围有未扫描或异常项目：保留，解决问题后重新扫描。")
        }
    }

    private func inspectedItem(finding: DiagnosticFinding, scan: ScanResult, home: String) throws -> PreparedCleanupItem {
        let context = try CleanupPathContext(path: finding.path)
        defer { context.closeDescriptors() }
        try context.requireHomeOwnership(home)
        guard faccessat(context.parentDescriptor, ".", W_OK | X_OK, 0) == 0 else {
            throw CleanupSafetyError("父目录没有移动文件所需的权限：保留，不申请管理员权限。")
        }
        let manifest = try CleanupManifest.inspect(parentDescriptor: context.parentDescriptor,
                                                   name: context.name, originalPath: finding.path)
        guard let record = scan.directories.first(where: { $0.path == finding.path }),
              manifest.logicalBytes == record.logicalBytes,
              manifest.allocatedBytes == record.allocatedBytes,
              manifest.fileCount == record.fileCount,
              record.lastModified == manifest.root.modifiedDate,
              finding.lastModified == record.lastModified else {
            throw CleanupSafetyError("扫描之后目录内容或大小发生变化：保留，请重新扫描。")
        }
        try context.verifyCurrentPath()
        return PreparedCleanupItem(id: finding.id, path: finding.path, title: finding.title,
                                   logicalBytes: manifest.logicalBytes, allocatedBytes: manifest.allocatedBytes,
                                   fileCount: manifest.fileCount, ancestors: context.ancestors, manifest: manifest)
    }

    private func executeItem(_ item: PreparedCleanupItem, home: String, roots: [String],
                             runningApplications: @Sendable () -> [String],
                             trash: @Sendable (URL) throws -> URL?) -> CleanupItemOutcome {
        var context: CleanupPathContext?
        var stagedName: String?
        var expectedStagedIdentity: CleanupEntry?
        var returnedTrashPath: String?
        defer { context?.closeDescriptors() }
        do {
            guard recognizedLeaf(item.path, home: home),
                  roots.contains(where: { CleanupPath.contains(parent: $0, child: URL(fileURLWithPath: item.path).deletingLastPathComponent().path) }) else {
                throw CleanupSafetyError("处理范围已经失效：保留。")
            }
            try ensureApplicationStopped(runningApplications())
            let opened = try CleanupPathContext(path: item.path)
            context = opened
            try opened.requireHomeOwnership(home)
            guard opened.ancestors == item.ancestors else {
                throw CleanupSafetyError("扫描之后路径或父目录被替换：保留，请重新扫描。")
            }
            guard faccessat(opened.parentDescriptor, ".", W_OK | X_OK, 0) == 0 else {
                throw CleanupSafetyError("父目录没有移动文件所需的权限：保留，不申请管理员权限。")
            }
            try opened.verifyCurrentPath()
            let current = try CleanupManifest.inspect(parentDescriptor: opened.parentDescriptor,
                                                      name: opened.name, originalPath: item.path)
            guard current == item.manifest else {
                throw CleanupSafetyError("扫描之后有文件新增、修改或替换：保留，请重新扫描。")
            }
            try ensureApplicationStopped(runningApplications())
            try opened.verifyCurrentPath()
            guard try entryAt(opened.parentDescriptor, opened.name) == item.manifest.root else {
                throw CleanupSafetyError("执行前目录状态已改变：保留。")
            }
            // A visible, unpredictable sibling preserves recoverability if the
            // process crashes. Exclusive descriptor rename never overwrites an item.
            let stageName = "DOJA Mac Doctor Recovery " + opened.name + " " + UUID().uuidString
            let stagePath = opened.parentPath + "/" + stageName
            guard exclusiveRename(parent: opened.parentDescriptor, from: opened.name, to: stageName) == 0 else {
                throw CleanupSafetyError("无法安全移动到待处理位置：保留。" + cleanupErrno())
            }
            stagedName = stageName
            let staged = try entryAt(opened.parentDescriptor, stageName)
            expectedStagedIdentity = staged
            guard staged.matchesRenamedRoot(item.manifest.root) else {
                throw CleanupSafetyError("安全移动时发现目录已被替换，已停止处理。")
            }
            try opened.verifyCurrentPath()
            let stagedManifest = try CleanupManifest.inspect(parentDescriptor: opened.parentDescriptor,
                                                             name: stageName, originalPath: item.path)
            guard stagedManifest.matchesAfterRootRename(item.manifest) else {
                throw CleanupSafetyError("待处理目录中有文件变化，已停止处理。")
            }
            let stageURL = URL(fileURLWithPath: stagePath)
            var coordinationError: NSError?
            var actionError: Error?
            var moved = false
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: stageURL, options: .forMoving,
                                                             error: &coordinationError) { coordinatedURL in
                do {
                    guard coordinatedURL.path == stageURL.path else {
                        throw CleanupSafetyError("系统协调的路径发生变化，已停止处理。")
                    }
                    try ensureApplicationStopped(runningApplications())
                    try opened.verifyCurrentPath()
                    let last = try CleanupManifest.inspect(parentDescriptor: opened.parentDescriptor,
                                                           name: stageName, originalPath: item.path)
                    guard last.matchesAfterRootRename(item.manifest),
                          try entryAt(opened.parentDescriptor, stageName) == last.root else {
                        throw CleanupSafetyError("移至废纸篓前文件发生变化，已停止处理。")
                    }
                    returnedTrashPath = try trash(coordinatedURL)?.path
                    guard entryAbsent(opened.parentDescriptor, stageName) else {
                        throw CleanupSafetyError("系统未完成移至废纸篓，缓存将尝试恢复到原位置。")
                    }
                    moved = true
                } catch { actionError = error }
            }
            if let coordinationError { throw coordinationError }
            if let actionError { throw actionError }
            guard moved else { throw CleanupSafetyError("系统未完成移至废纸篓。") }
            return CleanupItemOutcome(path: item.path, status: .trashed,
                                      message: "已移至系统废纸篓，可在 Finder 中恢复。废纸篓未清空；此操作不保证立即释放空间。",
                                      trashPath: returnedTrashPath, recoveryPath: nil)
        } catch {
            guard let opened = context, let stageName = stagedName else {
                return CleanupItemOutcome(path: item.path, status: .blocked,
                                          message: error.localizedDescription, trashPath: nil, recoveryPath: nil)
            }
            // Re-open the pathname, compare every ancestor identity, then restore
            // exclusively. Keep the original descriptors for locating a retained
            // staged object when its parent has moved to a different pathname.
            do {
                let recovery = try CleanupPathContext(path: item.path)
                defer { recovery.closeDescriptors() }
                guard recovery.ancestors == opened.ancestors,
                      let expected = expectedStagedIdentity,
                      try entryAt(recovery.parentDescriptor, stageName).sameObject(as: expected) else {
                    throw CleanupSafetyError("待恢复缓存或父目录已发生变化，未覆盖任何文件。")
                }
                try recovery.verifyCurrentPath()
                guard exclusiveRename(parent: recovery.parentDescriptor, from: stageName, to: recovery.name) == 0 else {
                    throw CleanupSafetyError("原位置已有文件或无法恢复；没有覆盖它。")
                }
                return CleanupItemOutcome(path: item.path, status: .failed,
                                          message: error.localizedDescription + " 已恢复原位置，请重扫。",
                                          trashPath: returnedTrashPath, recoveryPath: nil)
            } catch let recoveryError {
                let reachable = verifiedRecoveryPath(context: opened, stagedName: stageName,
                                                     expected: expectedStagedIdentity, trashPath: returnedTrashPath)
                return CleanupItemOutcome(path: item.path, status: .failed,
                                          message: error.localizedDescription + " " + recoveryError.localizedDescription +
                                            (reachable == nil ? " 最终位置待确认，请在 Finder 中检查原目录与废纸篓。" : " 请查看已核对的恢复路径。"),
                                          trashPath: returnedTrashPath, recoveryPath: reachable)
            }
        }
    }
}

private func recognizedLeaf(_ path: String, home: String) -> Bool {
    let leaves = ["GPUCache", "Code Cache", "ShaderCache", "DawnCache", "GrShaderCache"]
    let parents = ["Library/Application Support/Codex", "Library/Application Support/com.openai.codex",
                   "Library/Caches/Codex", "Library/Caches/com.openai.codex"]
    return parents.contains { parent in leaves.contains { path == home + "/" + parent + "/" + $0 } }
}

private func ensureApplicationStopped(_ identifiers: [String]) throws {
    let running = identifiers.contains {
        let value = $0.lowercased()
        return value == "codex" || value == "com.openai.codex" || value.hasPrefix("com.openai.codex.")
    }
    guard !running else {
        throw CleanupSafetyError("Codex 正在运行：保留正在使用的缓存。退出 Codex 后重新扫描即可勾选；不会结束应用进程。")
    }
}

private func canonicalPath(_ path: String) throws -> String {
    guard path.hasPrefix("/"), !path.utf8.contains(0),
          path == CleanupPath.normalized(path), path != "/" else {
        throw CleanupSafetyError("路径不是规范的绝对目录：保留。")
    }
    return path
}

private enum CleanupPath {
    // Keep /private/tmp lexical. Foundation standardization can rewrite it to
    // the /tmp symlink, which descriptor traversal deliberately rejects.
    static func normalized(_ path: String) -> String {
        var components: [Substring] = []
        for value in path.split(separator: "/") {
            if value == "." { continue }
            if value == ".." {
                if !components.isEmpty { components.removeLast() }
            } else { components.append(value) }
        }
        return "/" + components.joined(separator: "/")
    }
    static func contains(parent: String, child: String) -> Bool {
        let parent = normalized(parent), child = normalized(child)
        return child == parent || parent == "/" || child.hasPrefix(parent + "/")
    }
    static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        contains(parent: lhs, child: rhs) || contains(parent: rhs, child: lhs)
    }
}

fileprivate struct CleanupAncestor: Sendable, Equatable {
    let path: String
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let flags: UInt32
    let user: uid_t
    let group: gid_t

    init(path: String, metadata: stat) {
        self.path = path; device = metadata.st_dev; inode = metadata.st_ino
        mode = metadata.st_mode; flags = metadata.st_flags
        user = metadata.st_uid; group = metadata.st_gid
    }
}

/// Ancestors are opened component by component, retaining descriptor identities.
/// No symlink component, including a selected root's ancestors, is followed.
private final class CleanupPathContext {
    let parentDescriptor: Int32
    let parentPath: String
    let name: String
    let ancestors: [CleanupAncestor]
    private var descriptors: [Int32]

    init(path: String) throws {
        _ = try canonicalPath(path)
        let pieces = path.split(separator: "/").map(String.init)
        guard let last = pieces.last else { throw CleanupSafetyError("无法处理根目录。") }
        name = last
        parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard root >= 0 else { throw CleanupSafetyError("无法复核目录祖先：" + cleanupErrno()) }
        var held = [root]
        var identities: [CleanupAncestor] = []
        do {
            var rootInfo = stat()
            guard fstat(root, &rootInfo) == 0 else { throw CleanupSafetyError("无法复核根目录。") }
            identities.append(CleanupAncestor(path: "/", metadata: rootInfo))
            var accumulated = ""
            for part in pieces.dropLast() {
                accumulated += "/" + part
                let parent = held[held.count - 1]
                let before = try entryAt(parent, part)
                guard before.isDirectory, !before.isDataless else {
                    throw CleanupSafetyError("父路径包含符号链接、云端占位项或非目录：保留。")
                }
                let child = part.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                guard child >= 0 else { throw CleanupSafetyError("父目录无法完整读取：" + cleanupErrno()) }
                held.append(child)
                var opened = stat()
                guard fstat(child, &opened) == 0, before.sameObject(as: CleanupEntry(relativePath: "", metadata: opened)) else {
                    throw CleanupSafetyError("父目录被替换：保留。")
                }
                identities.append(CleanupAncestor(path: accumulated, metadata: opened))
            }
            parentDescriptor = held[held.count - 1]
            descriptors = held
            ancestors = identities
        } catch {
            for descriptor in held.reversed() { close(descriptor) }
            throw error
        }
    }

    deinit { closeDescriptors() }

    func closeDescriptors() {
        for descriptor in descriptors.reversed() { close(descriptor) }
        descriptors.removeAll()
    }

    func requireHomeOwnership(_ home: String) throws {
        guard let identity = ancestors.first(where: { $0.path == home }), identity.user == geteuid() else {
            throw CleanupSafetyError("用户目录身份或所有者无法核对：保留。")
        }
    }

    func verifyCurrentPath() throws {
        for (index, identity) in ancestors.enumerated() {
            var current = stat()
            let code: Int32
            if index == 0 { code = fstat(descriptors[index], &current) }
            else {
                let component = URL(fileURLWithPath: identity.path).lastPathComponent
                code = component.withCString { fstatat(descriptors[index - 1], $0, &current, AT_SYMLINK_NOFOLLOW) }
            }
            guard code == 0, CleanupAncestor(path: identity.path, metadata: current) == identity else {
                throw CleanupSafetyError("路径祖先发生变化或无权限复核：保留。")
            }
        }
    }
}

fileprivate struct CleanupEntry: Sendable, Equatable {
    let relativePath: String
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let flags: UInt32
    let user: uid_t
    let group: gid_t
    let links: nlink_t
    let bytes: off_t
    let blocks: blkcnt_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(relativePath: String, metadata: stat) {
        self.relativePath = relativePath; device = metadata.st_dev; inode = metadata.st_ino
        mode = metadata.st_mode; flags = metadata.st_flags; user = metadata.st_uid; group = metadata.st_gid
        links = metadata.st_nlink; bytes = metadata.st_size; blocks = metadata.st_blocks
        modifiedSeconds = metadata.st_mtimespec.tv_sec; modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
        changedSeconds = metadata.st_ctimespec.tv_sec; changedNanoseconds = metadata.st_ctimespec.tv_nsec
    }

    var isDirectory: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
    var isRegular: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
    var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }
    var allocatedBytes: Int64 {
        let (value, overflow) = max(0, Int64(blocks)).multipliedReportingOverflow(by: 512)
        return overflow ? Int64.max : value
    }
    var modifiedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(modifiedSeconds) + TimeInterval(modifiedNanoseconds) / 1_000_000_000)
    }
    func sameObject(as other: CleanupEntry) -> Bool { device == other.device && inode == other.inode && mode == other.mode }
    func matchesRenamedRoot(_ other: CleanupEntry) -> Bool {
        // A rename may update ctime; every other field remains bound to baseline.
        relativePath == other.relativePath && sameObject(as: other) && flags == other.flags &&
        user == other.user && group == other.group && links == other.links && bytes == other.bytes &&
        blocks == other.blocks && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
    }
}

fileprivate struct CleanupManifest: Sendable, Equatable {
    let entries: [CleanupEntry]
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let fileCount: Int
    var root: CleanupEntry { entries[0] }

    func matchesAfterRootRename(_ other: CleanupManifest) -> Bool {
        entries.count == other.entries.count && root.matchesRenamedRoot(other.root) &&
        Array(entries.dropFirst()) == Array(other.entries.dropFirst()) &&
        logicalBytes == other.logicalBytes && allocatedBytes == other.allocatedBytes && fileCount == other.fileCount
    }

    static func inspect(parentDescriptor: Int32, name: String, originalPath: String) throws -> CleanupManifest {
        let root = try entryAt(parentDescriptor, name)
        guard root.isDirectory else { throw CleanupSafetyError("缓存目录被替换或不是目录：保留。") }
        var parentMetadata = stat()
        guard fstat(parentDescriptor, &parentMetadata) == 0, root.device == parentMetadata.st_dev else {
            throw CleanupSafetyError("缓存是其他磁盘卷的挂载点：保留。")
        }
        var values: [CleanupEntry] = []
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var count = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 60

        func visit(parent: Int32, name: String, relative: String, depth: Int) throws {
            guard values.count < 100_000, depth <= 96, ProcessInfo.processInfo.systemUptime <= deadline else {
                throw CleanupSafetyError("缓存太大或层级过深，无法在限定资源内安全复核：保留。")
            }
            let raw = try entryAt(parent, name, relative: relative)
            let path = relative.isEmpty ? originalPath : originalPath + "/" + relative
            guard raw.device == root.device, !raw.isDataless,
                  raw.user == geteuid(), raw.flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0,
                  raw.isRegular || raw.isDirectory else {
                throw CleanupSafetyError("目录包含链接、其他磁盘、云端占位项、特殊文件或受保护项：保留。")
            }
            guard !raw.isRegular || raw.links == 1 else {
                throw CleanupSafetyError("发现硬链接，不能确定处理范围与实际释放空间：保留。")
            }
            guard !MetadataProtection.requiresPreservation(path: path) else {
                throw CleanupSafetyError("逐文件核对发现代码、配置、会话、媒体或工程文件：保留整个项目。")
            }
            guard relative.isEmpty || recognizedCacheEntry(name: name, directory: raw.isDirectory) else {
                throw CleanupSafetyError("缓存中包含用途未确认的文件或子目录：保留，不会按目录名擅自处理。")
            }
            values.append(raw)
            allocated = cleanupAdding(allocated, raw.allocatedBytes)
            if raw.isRegular {
                logical = cleanupAdding(logical, max(0, Int64(raw.bytes)))
                count += 1
                guard try entryAt(parent, name, relative: relative) == raw else {
                    throw CleanupSafetyError("复核期间文件发生变化：保留。")
                }
                return
            }
            let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard descriptor >= 0 else { throw CleanupSafetyError("缓存无法完整读取：" + cleanupErrno()) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, CleanupEntry(relativePath: relative, metadata: opened) == raw else {
                close(descriptor)
                throw CleanupSafetyError("缓存目录在复核时发生变化：保留。")
            }
            guard let stream = fdopendir(descriptor) else {
                close(descriptor)
                throw CleanupSafetyError("缓存目录无法完整列举：保留。")
            }
            defer { closedir(stream) }
            var names: [String] = []
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw CleanupSafetyError("目录未完整读取：保留。") }
                    break
                }
                let length = Int(entry.pointee.d_namlen)
                let childName: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: length + 1) { String(validatingUTF8: $0) }
                }
                guard let childName else { throw CleanupSafetyError("文件名无法安全表示：保留。") }
                if childName == "." || childName == ".." { continue }
                names.append(childName)
                guard names.count + values.count <= 100_000 else { throw CleanupSafetyError("缓存文件数量过多：保留。") }
            }
            for childName in names.sorted() {
                try visit(parent: dirfd(stream), name: childName,
                          relative: relative.isEmpty ? childName : relative + "/" + childName, depth: depth + 1)
            }
            var after = stat()
            guard fstat(dirfd(stream), &after) == 0,
                  CleanupEntry(relativePath: relative, metadata: after) == raw,
                  try entryAt(parent, name, relative: relative) == raw else {
                throw CleanupSafetyError("复核期间目录内容发生变化：保留。")
            }
        }
        try visit(parent: parentDescriptor, name: name, relative: "", depth: 0)
        return CleanupManifest(entries: values, logicalBytes: logical, allocatedBytes: allocated, fileCount: count)
    }
}

private func recognizedCacheEntry(name: String, directory: Bool) -> Bool {
    if directory { return ["js", "wasm", "index-dir"].contains(name) }
    if ["index", "the-real-index", "data_0", "data_1", "data_2", "data_3"].contains(name) { return true }
    let pattern = "^(f_[0-9a-fA-F]{6,16}|[0-9a-fA-F]{8,64}(_[0-9]+)?)$"
    return name.range(of: pattern, options: .regularExpression) != nil
}

private func entryAt(_ descriptor: Int32, _ name: String, relative: String = "") throws -> CleanupEntry {
    var metadata = stat()
    guard name.withCString({ fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW) }) == 0 else {
        throw CleanupSafetyError("文件无法复核或已消失：" + cleanupErrno())
    }
    return CleanupEntry(relativePath: relative, metadata: metadata)
}

private func entryAbsent(_ descriptor: Int32, _ name: String) -> Bool {
    var metadata = stat()
    let code = name.withCString { fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW) }
    return code != 0 && errno == ENOENT
}

private func verifiedRecoveryPath(context: CleanupPathContext, stagedName: String,
                                  expected: CleanupEntry?, trashPath: String?) -> String? {
    guard let expected else { return nil }
    if let staged = try? entryAt(context.parentDescriptor, stagedName), staged.sameObject(as: expected) {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = bytes.withUnsafeMutableBufferPointer { fcntl(context.parentDescriptor, F_GETPATH, $0.baseAddress!) }
        if result == 0 { return String(cString: bytes) + "/" + stagedName }
    }
    if let trashPath {
        var metadata = stat()
        if trashPath.withCString({ lstat($0, &metadata) }) == 0,
           CleanupEntry(relativePath: "", metadata: metadata).sameObject(as: expected) { return trashPath }
    }
    return nil
}

private func exclusiveRename(parent: Int32, from: String, to: String) -> Int32 {
    from.withCString { source in to.withCString { destination in
        renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
    } }
}

private func cleanupErrno() -> String { String(cString: strerror(errno)) }

private func cleanupAdding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int64.max : value
}
