import Foundation
import Darwin

/// Performs metadata-only, read-only scanning. Call on a background thread.
/// No file contents are opened, symlinks followed, or cloud objects hydrated.
public struct DiskScanner: Sendable {
    public init() {}

    public func scan(options: ScanOptions, control: ScanControl,
                     progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) -> ScanResult {
        // Swift tasks can outlive a synchronous scan. Drain temporary bridged
        // Foundation metadata objects before returning the retained value report.
        autoreleasepool { ScanEngine(options: options, control: control, progress: progress).run() }
    }
}

private struct InodeKey: Hashable {
    let device: dev_t
    let inode: ino_t

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
    }
}

private struct RootCandidate {
    let path: String
    let metadata: stat?
    let canCoverNestedRoots: Bool
    let ancestorIdentities: Set<InodeKey>
}

private final class DirectoryFrame {
    let path: String
    let directory: UnsafeMutablePointer<DIR>
    let metadata: stat
    let volume: dev_t
    var logicalBytes: Int64 = 0
    var allocatedBytes: Int64
    var fileCount: Int = 0
    var isComplete = true
    var containsProtectedFiles = false

    init(path: String, directory: UnsafeMutablePointer<DIR>, metadata: stat,
         volume: dev_t, allocatedBytes: Int64) {
        self.path = path
        self.directory = directory
        self.metadata = metadata
        self.volume = volume
        self.allocatedBytes = allocatedBytes
    }

    deinit { closedir(directory) }
}

private final class ScanEngine {
    let options: ScanOptions
    let control: ScanControl
    let progress: @Sendable (ScanProgress) -> Void
    let startedAt = Date()
    let startedUptime = ProcessInfo.processInfo.systemUptime
    var lastProgress = ProcessInfo.processInfo.systemUptime
    var directories: [DirectoryRecord] = []
    var largestFiles: [FileRecord] = []
    var recentFiles: [FileRecord] = []
    var categories: [String: CategorySummary] = [:]
    var issues: [ScanIssue] = []
    var issueIDs = Set<String>()
    var allocatedInodes = Set<InodeKey>()
    var logicalBytes: Int64 = 0
    var allocatedBytes: Int64 = 0
    var fileCount = 0
    var skippedSymlinks = 0
    var budgetLimited = false
    let recentCutoff: Date

    init(options: ScanOptions, control: ScanControl, progress: @escaping @Sendable (ScanProgress) -> Void) {
        self.options = options
        self.control = control
        self.progress = progress
        self.recentCutoff = Date().addingTimeInterval(-TimeInterval(options.recentDays) * 86_400)
    }

    func run() -> ScanResult {
        let roots = prepareRoots()
        for (index, root) in roots.enumerated() {
            guard control.waitUntilRunnable() else {
                for unscanned in roots[index...] {
                    recordUnscanned(path: unscanned.path, metadata: unscanned.metadata,
                                    reason: "扫描已取消，此目录未扫描")
                }
                break
            }
            if reachedBudget() {
                for unscanned in roots[index...] {
                    recordUnscanned(path: unscanned.path, metadata: unscanned.metadata,
                                    reason: "已达到扫描资源预算，此目录未完整扫描")
                }
                break
            }
            scanRoot(root)
        }
        emitProgress(path: roots.last?.path ?? "", force: true)
        return ScanResult(roots: roots.map(\.path), startedAt: startedAt, finishedAt: Date(),
                          status: control.isCancelled ? .cancelled : (budgetLimited ? .limited : .completed),
                          directories: directories.sorted { ($0.logicalBytes, $0.path) > ($1.logicalBytes, $1.path) },
                          largestFiles: largestFiles, recentLargeFiles: recentFiles,
                          categories: categories.values.sorted { $0.logicalBytes > $1.logicalBytes },
                          issues: issues, fileCount: fileCount, logicalBytes: logicalBytes,
                          allocatedBytes: allocatedBytes, skippedSymlinks: skippedSymlinks)
    }

    func reachedBudget() -> Bool {
        if let maximum = options.maxFiles, fileCount >= maximum { budgetLimited = true }
        if let seconds = options.maxDuration,
           ProcessInfo.processInfo.systemUptime - startedUptime >= seconds { budgetLimited = true }
        return budgetLimited
    }

    func prepareRoots() -> [RootCandidate] {
        var candidates: [RootCandidate] = []
        var paths = Set<String>()
        for url in options.roots {
            // Foundation resolves fileURLWithPath("relative") at construction.
            // Relative URL references and non-file schemes can still be rejected.
            guard url.isFileURL, url.baseURL == nil, url.path.hasPrefix("/") else {
                issue(path: url.absoluteString, reason: "必须选择绝对路径的本地目录，此路径未扫描")
                continue
            }
            guard !url.path.split(separator: "/").contains("..") else {
                issue(path: url.path, reason: "路径含有上级目录跳转，未扫描；请直接选择实际目录")
                continue
            }
            // standardizedFileURL rewrites /private/tmp into /tmp on macOS.
            // That would introduce a symlink into a previously safe selection.
            // Normalize lexical separators and '.' only, preserving actual names.
            let components = url.path.split(separator: "/").filter { $0 != "." }
            let path = "/" + components.joined(separator: "/")
            guard paths.insert(path).inserted else { continue }
            var metadata = stat()
            let valid = path.withCString { lstat($0, &metadata) } == 0
            let failure = valid ? nil : errno
            if let failure { issue(path: path, reason: failureReason(failure)) }
            // A readable parent can cover an overlapping selected child. A
            // denied parent cannot: that child may still be independently
            // accessible (for example an execute-only ancestor directory).
            var canCoverNestedRoots = false
            if valid, isDirectory(metadata), !isDataless(metadata) {
                let descriptor = path.withCString {
                    // Darwin rejects O_NOFOLLOW combined with O_NOFOLLOW_ANY.
                    // The latter already protects every component, including last.
                    open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
                }
                if descriptor >= 0 {
                    var opened = stat()
                    canCoverNestedRoots = fstat(descriptor, &opened) == 0 &&
                        opened.st_dev == metadata.st_dev && opened.st_ino == metadata.st_ino &&
                        !isDataless(opened)
                    close(descriptor)
                }
            }
            candidates.append(RootCandidate(path: path, metadata: valid ? metadata : nil,
                                            canCoverNestedRoots: canCoverNestedRoots,
                                            ancestorIdentities: canCoverNestedRoots ? ancestorIdentities(of: path) : []))
        }
        candidates.sort { ($0.path.count, $0.path) < ($1.path.count, $1.path) }
        var accepted: [RootCandidate] = []
        for candidate in candidates {
            // An explicitly selected mount point remains a separate root even if
            // its pathname is nested, because traversal never crosses volumes.
            let nested = accepted.contains { parent in
                guard parent.canCoverNestedRoots, let p = parent.metadata, let c = candidate.metadata,
                      isDirectory(p), p.st_dev == c.st_dev else { return false }
                return InodeKey(p) == InodeKey(c) ||
                    candidate.ancestorIdentities.contains(InodeKey(p)) ||
                    candidate.path == parent.path ||
                    candidate.path.hasPrefix(parent.path == "/" ? "/" : parent.path + "/")
            }
            if !nested { accepted.append(candidate) }
        }
        return accepted
    }

    /// Resolves case aliases by identity, not lowercasing (which would incorrectly
    /// merge separate directories on case-sensitive volumes). Called only after
    /// O_NOFOLLOW_ANY successfully opened the full selected path.
    func ancestorIdentities(of path: String) -> Set<InodeKey> {
        var result = Set<InodeKey>()
        var ancestor = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while !ancestor.isEmpty {
            var metadata = stat()
            if ancestor.withCString({ lstat($0, &metadata) }) == 0, isDirectory(metadata) {
                result.insert(InodeKey(metadata))
            }
            if ancestor == "/" { break }
            let next = URL(fileURLWithPath: ancestor).deletingLastPathComponent().path
            if next == ancestor { break }
            ancestor = next
        }
        return result
    }

    func scanRoot(_ root: RootCandidate) {
        guard let metadata = root.metadata else {
            recordUnscanned(path: root.path, metadata: nil, reason: nil)
            return
        }
        if isSymlink(metadata) {
            skippedSymlinks += 1
            recordUnscanned(path: root.path, metadata: metadata, reason: "符号链接未扫描，不跟随其目标")
            return
        }
        guard isDirectory(metadata) else {
            recordUnscanned(path: root.path, metadata: metadata, reason: "所选路径不是目录，未扫描")
            return
        }
        guard !isDataless(metadata) else {
            recordUnscanned(path: root.path, metadata: metadata, reason: "云端占位目录未扫描，以免触发下载")
            return
        }
        let descriptor = root.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            recordUnscanned(path: root.path, metadata: metadata, reason: failureReason(errno))
            return
        }
        guard let frame = openFrame(descriptor: descriptor, path: root.path,
                                    expected: metadata, volume: metadata.st_dev) else { return }
        var stack: [DirectoryFrame] = [frame]
        while let current = stack.last {
            guard control.waitUntilRunnable() else {
                while let pending = stack.popLast() {
                    pending.isComplete = false
                    issue(path: pending.path, reason: "扫描已取消，此目录统计未完成")
                    finish(pending, parent: stack.last, checkForChanges: false)
                }
                break
            }
            if reachedBudget() {
                while let pending = stack.popLast() {
                    pending.isComplete = false
                    issue(path: pending.path, reason: "已达到扫描资源预算，统计不完整；已读取部分不能当作目录完整大小")
                    finish(pending, parent: stack.last, checkForChanges: false)
                }
                break
            }
            emitProgress(path: current.path)
            errno = 0
            guard let entry = readdir(current.directory) else {
                let failure = errno
                if failure != 0 {
                    current.isComplete = false
                    issue(path: current.path, reason: "目录读取未完成：" + failureReason(failure))
                }
                stack.removeLast()
                finish(current, parent: stack.last, checkForChanges: true)
                continue
            }
            let nameLength = Int(entry.pointee.d_namlen)
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: nameLength + 1) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else {
                current.isComplete = false
                issue(path: current.path, reason: "目录包含无法表示为文本的文件名，该项未扫描")
                continue
            }
            if name == "." || name == ".." { continue }
            let path = current.path == "/" ? "/" + name : current.path + "/" + name
            var metadata = stat()
            let parentDescriptor = dirfd(current.directory)
            let valid = name.withCString { fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW) } == 0
            guard valid else {
                current.isComplete = false
                issue(path: path, reason: failureReason(errno))
                continue
            }
            if isSymlink(metadata) {
                skippedSymlinks += 1
                current.isComplete = false
                issue(path: path, reason: "符号链接未扫描，不跟随其目标")
                continue
            }
            guard metadata.st_dev == current.volume else {
                current.isComplete = false
                recordUnscanned(path: path, metadata: metadata, reason: "其他磁盘卷的挂载点未扫描；可单独授权并选择")
                continue
            }
            if isDataless(metadata) {
                current.isComplete = false
                if isDirectory(metadata) {
                    recordUnscanned(path: path, metadata: metadata, reason: "云端占位目录未扫描，以免触发下载")
                } else {
                    issue(path: path, reason: "云端占位文件未扫描，以免触发下载")
                }
                continue
            }
            if isDirectory(metadata) {
                let descriptor = name.withCString {
                    openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard descriptor >= 0 else {
                    current.isComplete = false
                    recordUnscanned(path: path, metadata: metadata, reason: failureReason(errno))
                    continue
                }
                if let child = openFrame(descriptor: descriptor, path: path, expected: metadata, volume: current.volume) {
                    stack.append(child)
                } else {
                    current.isComplete = false
                }
            } else if isRegular(metadata) {
                // Recheck without opening contents; discard raced/mutating items
                // instead of presenting contradictory sizes as complete data.
                var checked = stat()
                let rechecked = name.withCString { fstatat(parentDescriptor, $0, &checked, AT_SYMLINK_NOFOLLOW) } == 0
                guard rechecked else {
                    current.isComplete = false
                    issue(path: path, reason: failureReason(errno))
                    continue
                }
                guard sameFileVersion(metadata, checked) else {
                    current.isComplete = false
                    issue(path: path, reason: "扫描期间文件发生变化，该项未计入统计；可稍后重扫")
                    continue
                }
                consumeFile(path: path, metadata: checked, parent: current)
            } else {
                current.isComplete = false
                issue(path: path, reason: "套接字、设备或其他特殊文件未扫描")
            }
        }
    }

    func openFrame(descriptor: Int32, path: String, expected: stat, volume: dev_t) -> DirectoryFrame? {
        var actual = stat()
        guard fstat(descriptor, &actual) == 0 else {
            let failure = errno
            close(descriptor)
            recordUnscanned(path: path, metadata: expected, reason: failureReason(failure))
            return nil
        }
        guard actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino,
              actual.st_dev == volume, isDirectory(actual), !isDataless(actual) else {
            close(descriptor)
            recordUnscanned(path: path, metadata: expected, reason: "扫描期间目录发生变化，此目录未扫描")
            return nil
        }
        guard let directory = fdopendir(descriptor) else {
            let failure = errno
            close(descriptor)
            recordUnscanned(path: path, metadata: expected, reason: failureReason(failure))
            return nil
        }
        let allocation = uniqueAllocation(actual)
        allocatedBytes = adding(allocatedBytes, allocation)
        return DirectoryFrame(path: path, directory: directory, metadata: actual,
                              volume: volume, allocatedBytes: allocation)
    }

    func consumeFile(path: String, metadata: stat, parent: DirectoryFrame) {
        // Protection must cover every file, including small configuration/media
        // files that do not appear in the bounded largest/recent lists.
        let requiresPreservation = MetadataProtection.requiresPreservation(path: path)
        parent.containsProtectedFiles = parent.containsProtectedFiles || requiresPreservation
        let logical = max(0, Int64(metadata.st_size))
        let rawAllocated = reportedAllocation(metadata)
        let uniqueAllocated = uniqueAllocation(metadata)
        let modifiedAt = date(metadata.st_mtimespec)
        let createdAt = metadata.st_birthtimespec.tv_sec > 0 ? date(metadata.st_birthtimespec) : nil
        let kind = fileKind(path)
        let record = FileRecord(path: path, logicalBytes: logical, allocatedBytes: rawAllocated,
                                modifiedAt: modifiedAt, createdAt: createdAt,
                                linkCount: Int(metadata.st_nlink), kind: kind)
        parent.logicalBytes = adding(parent.logicalBytes, logical)
        parent.allocatedBytes = adding(parent.allocatedBytes, uniqueAllocated)
        parent.fileCount += 1
        logicalBytes = adding(logicalBytes, logical)
        allocatedBytes = adding(allocatedBytes, uniqueAllocated)
        fileCount += 1
        let previous = categories[kind]
        categories[kind] = CategorySummary(name: kind,
                                           logicalBytes: adding(previous?.logicalBytes ?? 0, logical),
                                           allocatedBytes: adding(previous?.allocatedBytes ?? 0, uniqueAllocated),
                                           count: (previous?.count ?? 0) + 1)
        keepTop(record, in: &largestFiles)
        if logical >= options.largeFileThreshold,
           modifiedAt >= recentCutoff || (createdAt.map { $0 >= recentCutoff } ?? false) {
            keepTop(record, in: &recentFiles)
        }
        emitProgress(path: path)
    }

    func finish(_ frame: DirectoryFrame, parent: DirectoryFrame?, checkForChanges: Bool) {
        if checkForChanges {
            var current = stat()
            if fstat(dirfd(frame.directory), &current) != 0 {
                frame.isComplete = false
                issue(path: frame.path, reason: "无法复核目录状态：" + failureReason(errno))
            } else if current.st_mtimespec.tv_sec != frame.metadata.st_mtimespec.tv_sec ||
                        current.st_mtimespec.tv_nsec != frame.metadata.st_mtimespec.tv_nsec ||
                        current.st_ctimespec.tv_sec != frame.metadata.st_ctimespec.tv_sec ||
                        current.st_ctimespec.tv_nsec != frame.metadata.st_ctimespec.tv_nsec {
                frame.isComplete = false
                issue(path: frame.path, reason: "扫描期间目录内容发生变化，统计可能不完整；可稍后重扫")
            }
        }
        directories.append(DirectoryRecord(path: frame.path, logicalBytes: frame.logicalBytes,
                                            allocatedBytes: frame.allocatedBytes, fileCount: frame.fileCount,
                                            lastModified: date(frame.metadata.st_mtimespec),
                                            isComplete: frame.isComplete,
                                            containsProtectedFiles: frame.containsProtectedFiles))
        if let parent {
            parent.logicalBytes = adding(parent.logicalBytes, frame.logicalBytes)
            parent.allocatedBytes = adding(parent.allocatedBytes, frame.allocatedBytes)
            parent.fileCount += frame.fileCount
            parent.isComplete = parent.isComplete && frame.isComplete
            parent.containsProtectedFiles = parent.containsProtectedFiles || frame.containsProtectedFiles
        }
    }

    func recordUnscanned(path: String, metadata: stat?, reason: String?) {
        if let reason { issue(path: path, reason: reason) }
        directories.append(DirectoryRecord(path: path, logicalBytes: 0, allocatedBytes: 0,
                                            fileCount: 0, lastModified: metadata.map { date($0.st_mtimespec) },
                                            isComplete: false))
    }

    func uniqueAllocation(_ metadata: stat) -> Int64 {
        // Directory hard links are prohibited on supported macOS volumes and
        // normalized roots prevent repeat traversal. Only multiply linked regular
        // files need an identity set, keeping ordinary million-file scans smaller.
        if !isRegular(metadata) || metadata.st_nlink <= 1 { return reportedAllocation(metadata) }
        return allocatedInodes.insert(InodeKey(metadata)).inserted ? reportedAllocation(metadata) : 0
    }

    func issue(path: String, reason: String) {
        let value = ScanIssue(path: path, reason: reason)
        if issueIDs.insert(value.id).inserted { issues.append(value) }
    }

    func emitProgress(path: String, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if force || now - lastProgress >= 0.2 {
            lastProgress = now
            progress(ScanProgress(visitedFiles: fileCount, currentPath: path, logicalBytes: logicalBytes))
        }
    }
}

private func isDirectory(_ value: stat) -> Bool { value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
private func isRegular(_ value: stat) -> Bool { value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
private func isSymlink(_ value: stat) -> Bool { value.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) }
private func isDataless(_ value: stat) -> Bool { value.st_flags & UInt32(SF_DATALESS) != 0 }
private func date(_ value: timespec) -> Date {
    Date(timeIntervalSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000)
}

private func reportedAllocation(_ metadata: stat) -> Int64 {
    let blocks = max(0, Int64(metadata.st_blocks))
    let (value, overflow) = blocks.multipliedReportingOverflow(by: 512)
    return overflow ? Int64.max : value
}

private func adding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int64.max : value
}

private func sameFileVersion(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode &&
    lhs.st_size == rhs.st_size && lhs.st_blocks == rhs.st_blocks && lhs.st_flags == rhs.st_flags &&
    lhs.st_nlink == rhs.st_nlink &&
    lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
    lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
}

private func keepTop(_ record: FileRecord, in records: inout [FileRecord]) {
    if records.count == 50, let last = records.last,
       (last.logicalBytes > record.logicalBytes || (last.logicalBytes == record.logicalBytes && last.path <= record.path)) {
        return
    }
    let position = records.firstIndex {
        record.logicalBytes > $0.logicalBytes || (record.logicalBytes == $0.logicalBytes && record.path < $0.path)
    } ?? records.endIndex
    records.insert(record, at: position)
    if records.count > 50 { records.removeLast() }
}

private func failureReason(_ code: Int32) -> String {
    switch code {
    case EACCES, EPERM: return "无权限，未扫描：" + String(cString: strerror(code))
    case ENOENT: return "扫描期间路径已消失，未扫描"
    case ELOOP: return "路径包含符号链接，未扫描"
    case EMFILE, ENFILE: return "打开目录数量达到系统限制，未扫描"
    default: return "读取失败，未扫描：" + String(cString: strerror(code))
    }
}

private func fileKind(_ path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    switch ext {
    case "mov", "mp4", "m4v", "mkv", "avi", "webm", "mxf", "mts", "m2ts", "r3d", "braw": return "视频与原始素材"
    case "wav", "aif", "aiff", "mp3", "m4a", "flac", "aac", "ogg": return "音频"
    case "jpg", "jpeg", "png", "heic", "webp", "gif", "tif", "tiff", "exr", "dpx", "raw", "psd": return "图像与图像工程"
    case "drp", "dra", "prproj", "aep", "fcpxml", "veg", "blend", "c4d", "resolve", "db", "sqlite", "sqlite3": return "工程与数据库"
    case "log", "dmp", "crash", "ips": return "日志与崩溃报告"
    case "tmp", "temp", "cache": return "临时与缓存（用途需确认）"
    case "swift", "m", "mm", "h", "c", "cpp", "rs", "py", "js", "jsx", "ts", "tsx", "json", "yaml", "yml", "toml", "sh", "html", "css": return "代码与配置"
    case "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "dmg", "pkg": return "压缩包与安装包"
    case "safetensors", "gguf", "onnx", "pt", "pth", "ckpt", "bin": return "AI 模型与二进制数据"
    default: return "其他文件"
    }
}
