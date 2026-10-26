import Foundation
import Darwin
import DoctorCore

/// Uses owned, tiny, real files only. The injected Trash operation is a move
/// within this UUID fixture; it never calls the system Trash for user data.
enum CleanupSelfCheck {
    /// Integration test for the production macOS Trash API. Only this run's
    /// UUID cache is moved. The exact returned item is restored, never emptied.
    static func runSystemTrash(parent suppliedParent: URL?, allowSmallInternalFixtures: Bool) throws {
        let fm = FileManager.default
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let requested = suppliedParent ?? package.appendingPathComponent(".validation-fixtures")
        var existing = requested
        var suffix: [String] = []
        while !fm.fileExists(atPath: existing.path) && existing.path != "/" {
            suffix.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        guard let resolved = existing.path.withCString({ realpath($0, nil) }) else {
            throw CheckError("无法解析系统废纸篓自测父目录。")
        }
        let canonical = String(cString: resolved)
        free(resolved)
        let parent = suffix.reversed().reduce(URL(fileURLWithPath: canonical)) { $0.appendingPathComponent($1) }
        let internalVolume = try existing.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal != false
        guard !internalVolume || allowSmallInternalFixtures else {
            throw CheckError("系统废纸篓自测默认只写外置卷。内部 APFS 小夹具需显式 --fixture-root 与 --allow-small-internal-fixtures。")
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        let ownedRoot = parent.appendingPathComponent("doctor-system-trash-selfcheck-\(identifier)")
        var actualTrashPath: String?
        var recoveryPath: String?
        var checks = 0
        func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw CheckError(message) }
            checks += 1
            print("通过：\(message)")
        }
        do {
            let fixture = try Fixture(root: ownedRoot)
            let cache = try fixture.cache("GPUCache", names: ["data_0", "index", "f_000001"])
            let expected: [String: Data] = [
                "data_0": Data(repeating: 0x51, count: 1024),
                "index": Data(repeating: 0x51, count: 1024),
                "f_000001": Data([0x51])
            ]
            try require(try allocatedBytes(ownedRoot) <= 512 * 1024,
                        "本次系统废纸篓夹具实际分配不超过 512 KiB")
            let scan = fixture.scan()
            let finding = try fixture.finding(cache, scan: scan)
            let plan = try CleanupService().prepare(selected: [finding], scan: scan,
                                                     home: fixture.home, allowedRoots: [fixture.home])
            try require(plan.items.count == 1 && plan.items.first?.path == cache.path,
                        "系统废纸篓计划仅包含本次 UUID 夹具的缓存")
            // A fake isolated home is not the running user's Codex data. Only the
            // running-app probe is overridden; the production Trash is unchanged.
            let outcome = CleanupService().execute(plan: plan, runningApplications: { [] })
            actualTrashPath = outcome.items.first?.trashPath
            recoveryPath = outcome.items.first?.recoveryPath
            let details = outcome.items.map { "\($0.status.rawValue) · \($0.message)" }.joined(separator: "；")
            try require(outcome.trashedCount == 1 && outcome.items.count == 1 && outcome.items[0].status == .trashed,
                        "macOS 原生废纸篓成功移动本次测试缓存；实际结果：\(details)")
            guard let path = actualTrashPath, path.hasPrefix("/"), path != cache.path else {
                throw CheckError("系统未返回明确的废纸篓路径，保留现场。")
            }
            let trashed = URL(fileURLWithPath: path)
            try require(!fm.fileExists(atPath: cache.path) && fm.fileExists(atPath: trashed.path),
                        "原测试缓存路径已移走，系统返回的确切废纸篓项存在")
            print("系统实际返回的本次测试路径：\(trashed.path)")
            for (name, data) in expected.sorted(by: { $0.key < $1.key }) {
                try require(try Data(contentsOf: trashed.appendingPathComponent(name)) == data,
                            "系统废纸篓中本次测试文件 \(name) 字节完整")
            }
            guard !fm.fileExists(atPath: cache.path) else {
                throw CheckError("测试原路径被重建，不覆盖任何文件，保留现场。")
            }
            // Never enumerate or empty Trash. Restore just the exact item that
            // the native API returned for this prepared UUID fixture.
            try fm.moveItem(at: trashed, to: cache)
            try require(!fm.fileExists(atPath: trashed.path) && fm.fileExists(atPath: cache.path),
                        "仅把系统返回的本次测试项还原到 UUID 夹具原位")
            for (name, data) in expected.sorted(by: { $0.key < $1.key }) {
                try require(try Data(contentsOf: cache.appendingPathComponent(name)) == data,
                            "还原后本次测试文件 \(name) 字节完整")
            }
            try require(try allocatedBytes(ownedRoot) <= 512 * 1024,
                        "还原后的隔离夹具实际分配不超过 512 KiB")
            guard ownedRoot.lastPathComponent == "doctor-system-trash-selfcheck-\(identifier)" else {
                throw CheckError("无法核对本次夹具根目录，不执行清理。")
            }
            try fm.removeItem(at: ownedRoot)
            print("\n系统废纸篓自测完成：\(checks) 项通过。本次测试缓存已还原，随后仅移除自己创建的 UUID 夹具。")
            print("没有清空系统废纸篓、枚举用户废纸篓，或处理任何已有用户文件。")
        } catch {
            // On unknown outcomes keep every known location recoverable. No
            // permanent-delete fallback and no cleanup outside this fixture.
            let failure = (error as? CheckError)?.description ?? error.localizedDescription
            throw CheckError("系统废纸篓自测未完成：\(failure)；保留夹具：\(ownedRoot.path)；系统返回路径：\(actualTrashPath ?? "未返回")；恢复路径：\(recoveryPath ?? "未返回")。未执行失败后的删除或覆盖操作。")
        }
    }

    static func run(parent suppliedParent: URL?, allowSmallInternalFixtures: Bool) throws {
        let fm = FileManager.default
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let requested = suppliedParent ?? package.appendingPathComponent(".validation-fixtures")
        var existing = requested
        var suffix: [String] = []
        while !fm.fileExists(atPath: existing.path) && existing.path != "/" {
            suffix.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        guard let resolved = existing.path.withCString({ realpath($0, nil) }) else {
            throw CheckError("无法解析清理自测父目录。")
        }
        let canonical = String(cString: resolved)
        free(resolved)
        let parent = suffix.reversed().reduce(URL(fileURLWithPath: canonical)) { $0.appendingPathComponent($1) }
        let internalVolume = try existing.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal != false
        guard !internalVolume || allowSmallInternalFixtures else {
            throw CheckError("清理自测默认只写外置卷。内部 APFS 小夹具需显式 --fixture-root 与 --allow-small-internal-fixtures。")
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let suiteRoot = parent.appendingPathComponent("doctor-cleanup-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: suiteRoot, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: suiteRoot) }
        var checks = 0
        var skips: [String] = []
        func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw CheckError("清理自测失败：\(message)；隔离目录：\(suiteRoot.path)") }
            checks += 1
            print("通过：\(message)")
        }
        func scenario(_ name: String, _ body: (Fixture) throws -> Void) throws {
            let fixture = try Fixture(root: suiteRoot.appendingPathComponent(name))
            defer {
                fixture.restorePermissions()
                try? fm.removeItem(at: fixture.root)
            }
            try body(fixture)
            if internalVolume {
                try require(try allocatedBytes(fixture.root) <= 512 * 1024,
                            "\(name)：内部 APFS 夹具实际分配不超过 512 KiB")
            }
        }
        let service = CleanupService()

        try scenario("selected-only") { f in
            let cache = try f.cache("GPUCache", names: ["index", "data_0", "f_000001"])
            let untouched = try f.cache("ShaderCache", names: ["index", "data_0"])
            let payload = try Data(contentsOf: cache.appendingPathComponent("data_0"))
            let scan = f.scan()
            let finding = try f.finding(cache, scan: scan)
            let assessment = service.assess(findings: [finding], scan: scan, home: f.home, runningApplications: [])
            try require(assessment.count == 1 && assessment[0].canSelect,
                        "完整扫描的已知 Codex 可重建缓存可以勾选")
            let baseline = try service.prepare(selected: [finding, f.finding(untouched, scan: scan)], scan: scan,
                                               home: f.home, allowedRoots: [f.home])
            let plan = baseline.selecting(paths: [cache.path, f.root.appendingPathComponent("unknown-selection").path])
            try require(plan.items.count == 1 && plan.items.first?.path == cache.path,
                        "勾选只保留原计划中存在的目录，不引入未知路径")
            try require(fm.fileExists(atPath: cache.path), "生成计划保持只读")
            let outcome = service.execute(plan: plan, runningApplications: { [] }, trash: { url in try f.moveToFixtureTrash(url) })
            let actualOutcome = outcome.items.map {
                "\($0.status.rawValue) · \($0.message) · recovery=\($0.recoveryPath ?? "无")"
            }.joined(separator: "；")
            try require(outcome.trashedCount == 1 && outcome.items.first?.status == .trashed,
                        "只处理用户选择的缓存；实际结果：\(actualOutcome)")
            try require(!fm.fileExists(atPath: cache.path) && fm.fileExists(atPath: untouched.path),
                        "已勾选源路径移走，未勾选目录保持原样")
            guard let movedPath = outcome.items.first?.trashPath else { throw CheckError("未返回移至废纸篓的位置。") }
            let moved = URL(fileURLWithPath: movedPath)
            try require(try Data(contentsOf: moved.appendingPathComponent("data_0")) == payload,
                        "移走后缓存数据完整可恢复")
            try fm.moveItem(at: moved, to: cache)
            try require(try Data(contentsOf: cache.appendingPathComponent("data_0")) == payload,
                        "隔离模拟废纸篓的缓存可完整还原")
        }

        try scenario("blocked-risk") { f in
            let cache = try f.cache("GPUCache", names: ["data_0"])
            let scan = f.scan()
            let good = try f.finding(cache, scan: scan)
            for risk in [RiskLevel.yellow, .red] {
                let bad = replacing(good, risk: risk)
                try require(!service.assess(findings: [bad], scan: scan, home: f.home, runningApplications: []).contains { $0.canSelect },
                            "\(risk.rawValue) 风险即使被传入选择仍不可处理")
                try require(rejects { _ = try service.prepare(selected: [bad], scan: scan, home: f.home, allowedRoots: [f.home]) },
                            "计划拒绝 \(risk.rawValue) 风险")
            }
            let incomplete = replacing(good, isComplete: false)
            try require(rejects { _ = try service.prepare(selected: [incomplete], scan: scan, home: f.home, allowedRoots: [f.home]) },
                        "未完整扫描的缓存拒绝处理")
            let cancellation = ScanControl()
            cancellation.cancel()
            let cancelled = DiskScanner().scan(options: ScanOptions(roots: [f.home]), control: cancellation)
            try require(rejects { _ = try service.prepare(selected: [good], scan: cancelled, home: f.home, allowedRoots: [f.home]) },
                        "取消的扫描无法生成处理计划")
            try require(fm.fileExists(atPath: cache.appendingPathComponent("data_0").path),
                        "所有风险拒绝保持真实文件原样")
        }

        try scenario("unknown-and-protected") { f in
            let unknown = try f.cache("GPUCache", names: ["payload.bin"])
            let unknownScan = f.scan()
            let unknownFinding = try f.finding(unknown, scan: unknownScan)
            try require(rejects { _ = try service.prepare(selected: [replacing(unknownFinding, risk: .green)], scan: unknownScan, home: f.home, allowedRoots: [f.home]) },
                        "普通未知文件即使伪造绿色建议也不会移走")
            let media = try f.cache("ShaderCache", names: ["original.mov"])
            let session = try f.file(f.home.appendingPathComponent(".codex/sessions/history.jsonl"), bytes: 21)
            let project = try f.file(f.home.appendingPathComponent("project/main.swift"), bytes: 31)
            let scan = f.scan()
            let finding = try f.finding(media, scan: scan)
            try require(rejects { _ = try service.prepare(selected: [replacing(finding, risk: .green)], scan: scan, home: f.home, allowedRoots: [f.home]) },
                        "保护文件不能因位于缓存目录或伪造绿色建议而处理")
            try require([media.appendingPathComponent("original.mov"), session, project].allSatisfy { fm.fileExists(atPath: $0.path) },
                        "媒体、会话与项目文件均保留")
        }

        try scenario("scope-and-overlap") { f in
            let cache = try f.cache("GPUCache", names: ["data_0"])
            let scan = f.scan()
            let finding = try f.finding(cache, scan: scan)
            let outside = f.root.appendingPathComponent("other-authorization")
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try require(rejects { _ = try service.prepare(selected: [finding], scan: scan, home: f.home, allowedRoots: [outside]) },
                        "选择的路径必须处于当前授权范围")
            let broad = f.home.appendingPathComponent("Library/Application Support/Codex")
            let broadFinding = try f.finding(broad, scan: scan)
            try require(rejects { _ = try service.prepare(selected: [replacing(broadFinding, risk: .green)], scan: scan, home: f.home, allowedRoots: [f.home]) },
                        "不能整目录处理 Codex Application Support")
            let aliasHome = f.root.appendingPathComponent("HOME")
            if fm.fileExists(atPath: aliasHome.path) {
                let aliasPath = aliasHome.appendingPathComponent("Library/Application Support/Codex/GPUCache")
                let aliasFinding = replacing(finding, path: aliasPath.path)
                try require(rejects { _ = try service.prepare(selected: [aliasFinding], scan: scan, home: aliasHome, allowedRoots: [f.home, aliasHome]) },
                            "大小写别名不能绕过原始扫描证据与范围核对")
            } else { skips.append("当前卷区分大小写，大小写别名绕过检查不适用") }
            do {
                let plan = try service.prepare(selected: [finding, finding], scan: scan, home: f.home, allowedRoots: [f.home, cache, f.home])
                let result = service.execute(plan: plan, runningApplications: { [] }, trash: { url in try f.moveToFixtureTrash(url) })
                try require(result.trashedCount == 1, "重复建议与重叠授权不会重复处理")
            } catch {
                try require(fm.fileExists(atPath: cache.path), "重复建议被拒绝后原目录仍完整")
            }
        }

        try scenario("stale-manifest") { f in
            let cache = try f.cache("GPUCache", names: ["data_0", "f_000001"])
            let scan = f.scan()
            let finding = try f.finding(cache, scan: scan)
            let plan = try service.prepare(selected: [finding], scan: scan, home: f.home, allowedRoots: [f.home])
            let payload = cache.appendingPathComponent("data_0")
            let old = try fm.attributesOfItem(atPath: payload.path)[.modificationDate] as? Date
            let replacement = try f.file(f.root.appendingPathComponent("replacement"), bytes: 1024, value: 0x72)
            try fm.removeItem(at: payload)
            try fm.moveItem(at: replacement, to: payload)
            if let old { try fm.setAttributes([.modificationDate: old], ofItemAtPath: payload.path) }
            let result = service.execute(plan: plan, runningApplications: { [] }, trash: { url in try f.moveToFixtureTrash(url) })
            try require(result.trashedCount == 0 && result.items.first?.status == .blocked,
                        "同大小同修改时间但文件身份变化会阻止过期计划")
            try require(try Data(contentsOf: payload) == Data(repeating: 0x72, count: 1024),
                        "计划失效后新文件内容不受影响")
        }

        try scenario("hidden-protected-insertion") { f in
            let cache = try f.cache("GPUCache", names: ["data_0", "f_000001"])
            let scan = f.scan()
            let plan = try service.prepare(selected: [f.finding(cache, scan: scan)], scan: scan, home: f.home, allowedRoots: [f.home])
            let secret = try f.file(cache.appendingPathComponent(".personal.swift"), bytes: 1)
            let result = service.execute(plan: plan, runningApplications: { [] }, trash: { url in try f.moveToFixtureTrash(url) })
            try require(result.trashedCount == 0 && fm.fileExists(atPath: secret.path),
                        "确认后新增的微小隐藏代码会让计划失效并保留")
            let tinyCache = try f.cache("ShaderCache", names: ["data_0", "f_000002"])
            let tinyScan = f.scan()
            let tinyPlan = try service.prepare(selected: [f.finding(tinyCache, scan: tinyScan)], scan: tinyScan, home: f.home, allowedRoots: [f.home])
            let tiny = tinyCache.appendingPathComponent("f_000002")
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: tiny.path)
            try require(service.execute(plan: tinyPlan, runningApplications: { [] }, trash: { url in try f.moveToFixtureTrash(url) }).trashedCount == 0,
                        "完整清单也检查小型缓存条目的变化")
        }

        try scenario("full-manifest-hidden-file") { f in
            let cache = try f.cache("GPUCache", names: ["data_0"])
            for index in 0..<55 {
                _ = try f.file(cache.appendingPathComponent(String(format: "f_%06x", index)), bytes: 64)
            }
            let tinyProtected = try f.file(cache.appendingPathComponent(".private-project.swift"), bytes: 1)
            let scan = f.scan()
            try require(!scan.largestFiles.contains { $0.path == tinyProtected.path },
                        "微小隐藏文件确实不在前 50 大文件排名")
            let forged = replacing(try f.finding(cache, scan: scan), risk: .green)
            try require(rejects { _ = try service.prepare(selected: [forged], scan: scan, home: f.home, allowedRoots: [f.home]) },
                        "完整清单仍保护前 50 排名之外的微小隐藏代码")
            try require(try Data(contentsOf: tinyProtected) == Data([0x51]),
                        "排名之外的微小隐藏代码内容保持完整")
        }

        try scenario("application-recheck") { f in
            let cache = try f.cache("GPUCache", names: ["data_0"])
            let scan = f.scan()
            let finding = try f.finding(cache, scan: scan)
            try require(!service.assess(findings: [finding], scan: scan, home: f.home, runningApplications: ["com.openai.codex"]).contains { $0.canSelect },
                        "Codex 运行中不允许处理其缓存")
            let plan = try service.prepare(selected: [finding], scan: scan, home: f.home, allowedRoots: [f.home])
            let result = service.execute(plan: plan, runningApplications: { ["com.openai.codex"] }, trash: { url in try f.moveToFixtureTrash(url) })
            try require(result.trashedCount == 0 && fm.fileExists(atPath: cache.path),
                        "确认后应用重新运行也会阻止处理")
        }

        try scenario("apfs-clone") { f in
            let cache = try f.cache("GPUCache", names: ["data_0"])
            let source = cache.appendingPathComponent("data_0")
            let clone = f.root.appendingPathComponent("retained-clone")
            let cloned = source.path.withCString { original in
                clone.path.withCString { destination in Darwin.clonefile(original, destination, 0) }
            }
            if cloned == 0 {
                let scan = f.scan()
                let plan = try service.prepare(selected: [f.finding(cache, scan: scan)], scan: scan, home: f.home, allowedRoots: [f.home])
                let result = service.execute(plan: plan, runningApplications: { [] }, trash: { url in try f.moveToFixtureTrash(url) })
                try require(result.trashedCount == 1 && fm.fileExists(atPath: clone.path),
                            "APFS 克隆只移动已选路径，其他共享副本保留")
                try require(try Data(contentsOf: clone) == Data(repeating: 0x51, count: 1024),
                            "APFS 克隆共享数据保持完整")
                try require(result.items.first?.message.contains("不保证立即释放") == true,
                            "APFS 克隆与废纸篓处理结果不承诺立即释放空间")
            } else if errno == ENOTSUP || errno == EXDEV || errno == EINVAL {
                skips.append("当前文件系统不支持 APFS 克隆，克隆共享数据检查未执行")
            } else { throw CheckError("无法建立隔离 APFS 克隆：\(String(cString: strerror(errno)))") }
        }

        try scenario("individual-failure") { f in
            let failedCache = try f.cache("GPUCache", names: ["data_0"])
            let goodCache = try f.cache("ShaderCache", names: ["data_0"])
            _ = try f.file(goodCache.appendingPathComponent("data_0"), bytes: 1024, value: 0x62)
            let scan = f.scan()
            let plan = try service.prepare(selected: [f.finding(failedCache, scan: scan), f.finding(goodCache, scan: scan)],
                                           scan: scan, home: f.home, allowedRoots: [f.home])
            let result = service.execute(plan: plan, runningApplications: { [] }) { source in
                if try Data(contentsOf: source.appendingPathComponent("data_0")).first == 0x51 { throw CheckError("隔离模拟废纸篓失败") }
                return try f.moveToFixtureTrash(source)
            }
            try require(result.items.count == 2, "每个勾选项均有独立执行结果")
            if result.trashedCount == 1 {
                try require(fm.fileExists(atPath: failedCache.path) && !fm.fileExists(atPath: goodCache.path),
                            "一个目录失败会恢复，其他成功目录保留独立结果")
            } else { throw CheckError("逐项失败模拟未命中缓存来源；应有一个成功和一个失败。") }
        }

        try scenario("failed-trash-restores") { f in
            let cache = try f.cache("GPUCache", names: ["data_0"])
            let scan = f.scan()
            let plan = try service.prepare(selected: [f.finding(cache, scan: scan)], scan: scan, home: f.home, allowedRoots: [f.home])
            let result = service.execute(plan: plan, runningApplications: { [] }) { _ in throw CheckError("模拟移至废纸篓失败") }
            try require(result.trashedCount == 0 && result.items.first?.status == .failed,
                        "废纸篓失败会报告失败")
            try require(try Data(contentsOf: cache.appendingPathComponent("data_0")) == Data(repeating: 0x51, count: 1024),
                        "废纸篓失败后真实缓存恢复原位且内容完整")
        }

        try scenario("restore-collision") { f in
            let cache = try f.cache("GPUCache", names: ["data_0"])
            let scan = f.scan()
            let plan = try service.prepare(selected: [f.finding(cache, scan: scan)], scan: scan, home: f.home, allowedRoots: [f.home])
            let result = service.execute(plan: plan, runningApplications: { [] }) { _ in
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
                try Data([0x73]).write(to: cache.appendingPathComponent("new-sentinel.swift"))
                throw CheckError("模拟原路径被其他进程重建后移至废纸篓失败")
            }
            try require(result.trashedCount == 0 && result.items.first?.status == .failed,
                        "恢复冲突会明确报告失败")
            try require(try Data(contentsOf: cache.appendingPathComponent("new-sentinel.swift")) == Data([0x73]),
                        "恢复过程绝不覆盖其他进程新建的文件")
            guard let recovery = result.items.first?.recoveryPath else { throw CheckError("恢复冲突未提供可找回路径。") }
            try require(try Data(contentsOf: URL(fileURLWithPath: recovery).appendingPathComponent("data_0")) == Data(repeating: 0x51, count: 1024),
                        "恢复冲突保留原数据并提供可找回路径")
        }

        try scenario("links-and-readonly") { f in
            let cache = try f.cache("GPUCache", names: ["data_0"])
            let link = f.root.appendingPathComponent("aliased-home")
            if f.home.path.withCString({ source in link.path.withCString { symlink(source, $0) } }) == 0 {
                let scan = f.scan()
                let finding = try f.finding(cache, scan: scan)
                try require(rejects { _ = try service.prepare(selected: [finding], scan: scan, home: link, allowedRoots: [link]) },
                            "符号链接祖先不能伪装授权范围")
                let aliasCache = link.appendingPathComponent("Library/Application Support/Codex/GPUCache")
                let alias = replacing(finding, path: aliasCache.path)
                try require(rejects { _ = try service.prepare(selected: [alias], scan: scan, home: link, allowedRoots: [f.home, link]) },
                            "带符号链接祖先的缓存路径拒绝处理")
            } else { skips.append("当前文件系统不支持符号链接，链接祖先检查未执行") }
            let hardLink = f.root.appendingPathComponent("hardlinked-outside-cache")
            if cache.appendingPathComponent("data_0").path.withCString({ source in hardLink.path.withCString { Darwin.link(source, $0) } }) == 0 {
                let scan = f.scan()
                let finding = try f.finding(cache, scan: scan)
                try require(rejects { _ = try service.prepare(selected: [finding], scan: scan, home: f.home, allowedRoots: [f.home]) },
                            "跨缓存边界的硬链接无法被当作可释放空间处理")
                try require(try Data(contentsOf: hardLink) == Data(repeating: 0x51, count: 1024),
                            "硬链接指向的真实数据不变")
                try fm.removeItem(at: hardLink)
            } else { skips.append("当前文件系统不支持硬链接，硬链接拒绝检查未执行") }
            let deniedDirectory = cache.appendingPathComponent("index-dir")
            _ = try f.file(deniedDirectory.appendingPathComponent("the-real-index"), bytes: 1)
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0)], ofItemAtPath: deniedDirectory.path)
            defer { try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: deniedDirectory.path) }
            let incompleteScan = f.scan()
            if incompleteScan.issues.contains(where: { $0.path == deniedDirectory.path }) {
                let incompleteFinding = try f.finding(cache, scan: incompleteScan)
                try require(rejects { _ = try service.prepare(selected: [replacing(incompleteFinding, risk: .green)], scan: incompleteScan,
                                                              home: f.home, allowedRoots: [f.home]) },
                            "真实无权限子目录使整个缓存范围无法处理")
            } else { skips.append("当前文件系统或进程未执行 POSIX 读权限限制，真实不完整扫描拒绝检查未执行") }
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: deniedDirectory.path)
            let parent = cache.deletingLastPathComponent()
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o500)], ofItemAtPath: parent.path)
            if parent.path.withCString({ access($0, W_OK) }) != 0 {
                let scan = f.scan()
                let finding = try f.finding(cache, scan: scan)
                try require(rejects { _ = try service.prepare(selected: [finding], scan: scan, home: f.home, allowedRoots: [f.home]) },
                            "只读父目录不提供处理计划")
            } else { skips.append("当前文件系统或进程未执行 POSIX 写权限限制，只读拒绝检查未执行") }
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: parent.path)
        }

        for skip in skips { print("未执行：\(skip)") }
        print("\n清理自测完成：\(checks) 项通过，\(skips.count) 项受文件系统能力限制。")
        print("全部结果来自真实隔离文件；仅在本次 UUID 夹具内模拟移至废纸篓并核对恢复。未移动用户文件或写入用户废纸篓。")
    }

    private struct CheckError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Setup mutates the byte budget synchronously before execution; injected
    /// execute callbacks read immutable URLs and move within this owned fixture.
    private final class Fixture: @unchecked Sendable {
        let root: URL
        let home: URL
        private var written = 0
        init(root: URL) throws {
            self.root = root
            home = root.appendingPathComponent("home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        func file(_ url: URL, bytes: Int, value: UInt8 = 0x51) throws -> URL {
            guard bytes >= 0, written + bytes <= 256 * 1024 else { throw CheckError("夹具内容超过 256 KiB。") }
            written += bytes
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: value, count: bytes).write(to: url)
            return url
        }
        func cache(_ name: String, names: [String]) throws -> URL {
            let directory = home.appendingPathComponent("Library/Application Support/Codex/\(name)")
            for item in names { _ = try file(directory.appendingPathComponent(item), bytes: item.hasPrefix("f_") ? 1 : 1024) }
            return directory
        }
        func scan() -> ScanResult {
            DiskScanner().scan(options: ScanOptions(roots: [home], largeFileThreshold: 16 * 1024), control: ScanControl())
        }
        func finding(_ path: URL, scan: ScanResult) throws -> DiagnosticFinding {
            if let found = DiagnosisEngine().findings(for: scan).first(where: { $0.path == path.path }) { return found }
            guard let record = scan.directories.first(where: { $0.path == path.path }) else {
                throw CheckError("真实扫描没有目录记录：\(path.path)")
            }
            return DiagnosticFinding(id: path.path, path: path.path, title: "隔离测试选择", domain: "Codex", reason: "仅用于验证拒绝规则",
                                     advice: "只在本次夹具内使用", risk: .green, logicalBytes: record.logicalBytes,
                                     allocatedBytes: record.allocatedBytes, lastModified: record.lastModified,
                                     isComplete: record.isComplete, estimatedReclaimUpperBound: nil)
        }
        func moveToFixtureTrash(_ source: URL) throws -> URL? {
            guard source.path.hasPrefix(root.path + "/") else { throw CheckError("模拟废纸篓不能移走夹具外路径。") }
            let destination = root.appendingPathComponent("simulated-trash/\(UUID().uuidString)/\(source.lastPathComponent)")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        func restorePermissions() {
            let parent = home.appendingPathComponent("Library/Application Support/Codex")
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: parent.path)
        }
    }

    private static func rejects(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }

    private static func replacing(_ original: DiagnosticFinding, risk: RiskLevel? = nil,
                                  isComplete: Bool? = nil, path: String? = nil) -> DiagnosticFinding {
        DiagnosticFinding(id: path ?? original.id, path: path ?? original.path, title: original.title, domain: original.domain,
                          reason: original.reason, advice: original.advice, risk: risk ?? original.risk,
                          logicalBytes: original.logicalBytes, allocatedBytes: original.allocatedBytes,
                          lastModified: original.lastModified, isComplete: isComplete ?? original.isComplete,
                          estimatedReclaimUpperBound: original.estimatedReclaimUpperBound)
    }

    private static func allocatedBytes(_ root: URL) throws -> Int64 {
        var seen: Set<String> = []
        var total: Int64 = 0
        func add(_ url: URL) throws {
            var value = stat()
            guard url.path.withCString({ lstat($0, &value) }) == 0 else { throw CheckError("无法核对夹具实际分配大小。") }
            let key = "\(value.st_dev):\(value.st_ino)"
            if seen.insert(key).inserted { total += Int64(value.st_blocks) * 512 }
        }
        try add(root)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { throw CheckError("无法核对夹具分配大小。") }
        for case let url as URL in enumerator { try add(url) }
        return total
    }
}
