import XCTest
import Foundation
import Darwin
@testable import DoctorCore

final class DoctorCoreTests: XCTestCase {
    private func fixture() throws -> URL {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard try package.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal == false else {
            throw XCTSkip("测试夹具仅写入外置卷，避免占用内部磁盘。")
        }
        let root = package.appendingPathComponent(".validation-fixtures/test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func file(_ root: URL, _ name: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x51, count: bytes).write(to: url)
        return url
    }

    private func scan(_ roots: [URL], threshold: Int64 = 1024) -> ScanResult {
        DiskScanner().scan(options: ScanOptions(roots: roots, largeFileThreshold: threshold), control: ScanControl())
    }

    func testRealSizesThresholdAndOverlappingRoots() throws {
        let root = try fixture()
        let small = try file(root, "project/main.swift", bytes: 100)
        let large = try file(root, "large.bin", bytes: 5000)
        let result = scan([root])
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.largestFiles.first { $0.path == large.path }?.logicalBytes, 5000)
        XCTAssertTrue(result.recentLargeFiles.contains { $0.path == large.path })
        XCTAssertFalse(result.recentLargeFiles.contains { $0.path == small.path })
        let overlapping = scan([root, root.appendingPathComponent("project"), root])
        XCTAssertEqual(overlapping.logicalBytes, result.logicalBytes)
        XCTAssertEqual(overlapping.allocatedBytes, result.allocatedBytes)
        XCTAssertEqual(overlapping.fileCount, result.fileCount)
        let alias = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent.uppercased())
        if FileManager.default.fileExists(atPath: alias.path) {
            let aliased = scan([root, alias, alias.appendingPathComponent("PROJECT")])
            XCTAssertEqual(aliased.logicalBytes, result.logicalBytes)
            XCTAssertEqual(aliased.fileCount, result.fileCount)
        }
    }

    func testSymlinksCannotEscapeScanAuthorization() throws {
        let root = try fixture()
        _ = try file(root, "authorized.bin", bytes: 4096)
        let baseline = scan([root])
        let symlink = root.appendingPathComponent("outside")
        guard symlink.path.withCString({ Darwin.symlink("/Users", $0) }) == 0 else {
            if errno == ENOTSUP || errno == EPERM { throw XCTSkip("外置文件系统不支持符号链接。") }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let result = scan([root])
        XCTAssertEqual(result.logicalBytes, baseline.logicalBytes)
        XCTAssertGreaterThanOrEqual(result.skippedSymlinks, 1)
        let rootLink = scan([symlink])
        XCTAssertEqual(rootLink.fileCount, 0)
        XCTAssertFalse(rootLink.issues.isEmpty)
        let ancestorLink = scan([symlink.appendingPathComponent(NSUserName())])
        XCTAssertEqual(ancestorLink.fileCount, 0)
        XCTAssertFalse(ancestorLink.issues.isEmpty)
    }

    func testHardLinksAreDeduplicatedOnlyForAllocatedBytes() throws {
        let root = try fixture()
        let source = try file(root, "source.bin", bytes: 8192)
        let before = scan([root])
        var beforeStatus = stat()
        XCTAssertEqual(root.path.withCString { lstat($0, &beforeStatus) }, 0)
        let destination = root.appendingPathComponent("linked.bin")
        guard source.path.withCString({ source in destination.path.withCString { link(source, $0) } }) == 0 else {
            throw XCTSkip("外置文件系统不支持硬链接。")
        }
        let after = scan([root])
        var afterStatus = stat()
        XCTAssertEqual(root.path.withCString { lstat($0, &afterStatus) }, 0)
        XCTAssertEqual(after.logicalBytes - before.logicalBytes, 8192)
        XCTAssertEqual(after.allocatedBytes - before.allocatedBytes,
                       Int64(afterStatus.st_blocks - beforeStatus.st_blocks) * 512)
        XCTAssertEqual(after.largestFiles.first { $0.path == destination.path }?.linkCount, 2)
    }

    func testSparseFileDistinguishesLogicalAndAllocatedSizes() throws {
        let root = try fixture()
        let url = root.appendingPathComponent("sparse.bin")
        let descriptor = url.path.withCString { open($0, O_CREAT | O_EXCL | O_RDWR, 0o600) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        XCTAssertEqual(ftruncate(descriptor, 8 * 1024 * 1024), 0)
        var status = stat()
        XCTAssertEqual(fstat(descriptor, &status), 0)
        let record = scan([root]).largestFiles.first { $0.path == url.path }
        XCTAssertEqual(record?.logicalBytes, Int64(status.st_size))
        XCTAssertEqual(record?.allocatedBytes, Int64(status.st_blocks) * 512)
    }

    func testMissingAndDeniedDirectoriesAreNeverReportedAsComplete() throws {
        let root = try fixture()
        XCTAssertFalse(scan([root.appendingPathComponent("missing")]).issues.isEmpty)
        let denied = root.appendingPathComponent("denied")
        _ = try file(root, "denied/secret.bin", bytes: 1024)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0)], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: denied.path) }
        let result = scan([root])
        guard result.issues.contains(where: { $0.path == denied.path }) else {
            throw XCTSkip("当前进程或外置文件系统未执行 POSIX 权限限制。")
        }
        XCTAssertFalse(try XCTUnwrap(result.directories.first { $0.path == root.path }).isComplete)
    }

    func testProtectedCodexSessionAndMediaAreNotCleanupCandidates() throws {
        let root = try fixture()
        let session = try file(root, ".codex/sessions/session.jsonl", bytes: 1024)
        let code = try file(root, "project/main.swift", bytes: 1024)
        let media = try file(root, "project/original.mov", bytes: 1024)
        let configuration = try file(root, ".codex/config.toml", bytes: 128)
        _ = try file(root, ".codex/log/codex-tui.log", bytes: 1024)
        _ = try file(root, "project/node_modules/pkg/index.js", bytes: 1024)
        _ = try file(root, "Library/Application Support/Codex/Crashpad/pending/crash.dmp", bytes: 1024)
        let findings = DiagnosisEngine().findings(for: scan([root]), projectRoots: [root.appendingPathComponent("project").path])
        XCTAssertTrue(findings.contains { $0.path.contains(".codex/sessions") && $0.risk == .red && $0.estimatedReclaimUpperBound == nil })
        XCTAssertTrue(findings.contains { $0.path.hasSuffix("Crashpad/pending") && $0.risk == .yellow })
        XCTAssertTrue(findings.contains { $0.path.hasSuffix("node_modules") && $0.risk == .yellow })
        XCTAssertTrue(findings.contains { $0.path == configuration.path && $0.risk == .red && $0.estimatedReclaimUpperBound == nil })
        XCTAssertTrue(findings.contains { $0.path.hasSuffix(".codex/log") && $0.risk == .yellow })
        XCTAssertFalse(findings.contains { [session.path, code.path, media.path].contains($0.path) && $0.risk != .red })
        for url in [session, code, media] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
    }

    func testGrowthRequiresSameCoverageAndChronologicalCompletedScans() throws {
        let root = try fixture()
        _ = try file(root, "project/initial.bin", bytes: 1024)
        let previous = scan([root])
        _ = try file(root, "project/grown.bin", bytes: 4096)
        let current = scan([root])
        let engine = DiagnosisEngine()
        XCTAssertTrue(engine.growth(previous: previous, current: current).contains { $0.path == root.path && $0.logicalDelta == 4096 })
        XCTAssertTrue(engine.growth(previous: current, current: previous).isEmpty)
        XCTAssertTrue(engine.growth(previous: previous, current: scan([root.appendingPathComponent("project")])).isEmpty)
        let cancelled = ScanControl()
        cancelled.cancel()
        let invalid = DiskScanner().scan(options: ScanOptions(roots: [root]), control: cancelled)
        XCTAssertEqual(invalid.status, .cancelled)
        XCTAssertTrue(engine.growth(previous: invalid, current: current).isEmpty)
    }

    func testCacheContainingProtectedFileOutsideTop50IsNotRemovableAsUnit() throws {
        let root = try fixture()
        let cache = root.appendingPathComponent("Library/Application Support/Codex/GPUCache")
        for index in 0..<55 {
            _ = try file(root, "Library/Application Support/Codex/GPUCache/entry-\(index).bin", bytes: 1024)
        }
        let personalCode = try file(root, "Library/Application Support/Codex/GPUCache/personal.swift", bytes: 3)
        let result = scan([root])
        XCTAssertFalse(result.largestFiles.contains { $0.path == personalCode.path })
        let findings = DiagnosisEngine().findings(for: result)
        XCTAssertFalse(findings.contains { $0.path == cache.path && $0.risk != .red })
        XCTAssertTrue(FileManager.default.fileExists(atPath: personalCode.path))
    }

    func testPausedScanRespondsToCancelWithoutResuming() throws {
        let root = try fixture()
        _ = try file(root, "data.bin", bytes: 1024)
        let control = ScanControl()
        control.pause()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            _ = DiskScanner().scan(options: ScanOptions(roots: [root]), control: control)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 0.1), .timedOut)
        XCTAssertTrue(control.isPaused)
        control.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
    }
}
