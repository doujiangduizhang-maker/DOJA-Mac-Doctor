import XCTest
import Foundation
import Darwin
@testable import DoctorCore

final class CleanupTests: XCTestCase {
    private let service = CleanupService()

    private func fixture() throws -> URL {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard try package.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal == false else {
            throw XCTSkip("默认测试夹具仅写外置卷；内部 APFS 用 CLI 显式小夹具选项验证。")
        }
        let root = package.appendingPathComponent(".validation-fixtures/cleanup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func cache(_ home: URL, name: String = "GPUCache", files: [String] = ["data_0", "index"]) throws -> URL {
        let path = home.appendingPathComponent("Library/Application Support/Codex/\(name)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        for item in files { try Data(repeating: 0x51, count: item.hasPrefix("f_") ? 1 : 1024).write(to: path.appendingPathComponent(item)) }
        return path
    }

    private func scan(_ home: URL) -> ScanResult {
        DiskScanner().scan(options: ScanOptions(roots: [home], largeFileThreshold: 16 * 1024), control: ScanControl())
    }

    private func finding(_ path: URL, scan: ScanResult, risk: RiskLevel? = nil, complete: Bool? = nil) throws -> DiagnosticFinding {
        let record = try XCTUnwrap(scan.directories.first { $0.path == path.path })
        let diagnosis = DiagnosisEngine().findings(for: scan).first { $0.path == path.path }
        return DiagnosticFinding(id: path.path, path: path.path, title: diagnosis?.title ?? "隔离夹具选择", domain: "Codex",
                                 reason: "真实扫描数据", advice: "仅供隔离测试", risk: risk ?? diagnosis?.risk ?? .green,
                                 logicalBytes: record.logicalBytes, allocatedBytes: record.allocatedBytes,
                                 lastModified: record.lastModified, isComplete: complete ?? record.isComplete,
                                 estimatedReclaimUpperBound: nil)
    }

    /// Native Trash is deliberately not called: this closure moves only inside
    /// the owned UUID fixture and leaves payload bytes available for restoration.
    private func simulatedTrash(_ root: URL) -> @Sendable (URL) throws -> URL? {
        { source in
            guard source.path.hasPrefix(root.path + "/") else { throw TestError.outsideFixture }
            let destination = root.appendingPathComponent("test-trash/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
    }

    func testConfirmedSelectionMovesOnlyKnownCacheAndPayloadIsRestorable() throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let chosen = try cache(home, files: ["data_0", "index", "f_000001"])
        let unselected = try cache(home, name: "ShaderCache")
        let scanned = scan(home)
        let selected = try finding(chosen, scan: scanned)
        XCTAssertTrue(service.assess(findings: [selected], scan: scanned, home: home, runningApplications: []).first?.canSelect == true)
        let plan = try service.prepare(selected: [selected], scan: scanned, home: home, allowedRoots: [home])
        XCTAssertTrue(FileManager.default.fileExists(atPath: chosen.path))
        let outcome = service.execute(plan: plan, runningApplications: { [] }, trash: simulatedTrash(root))
        XCTAssertEqual(outcome.trashedCount, 1)
        XCTAssertEqual(outcome.items.first?.status, .trashed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chosen.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unselected.path))
        let destination = URL(fileURLWithPath: try XCTUnwrap(outcome.items.first?.trashPath))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("data_0")), Data(repeating: 0x51, count: 1024))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("f_000001")), Data([0x51]))
        try FileManager.default.moveItem(at: destination, to: chosen)
        XCTAssertEqual(try Data(contentsOf: chosen.appendingPathComponent("data_0")), Data(repeating: 0x51, count: 1024))
    }

    func testYellowRedUnknownAndIncompleteAreBlockedEvenIfSelected() throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let known = try cache(home)
        let unknown = try cache(home, name: "ShaderCache", files: ["payload.bin"])
        let scanned = scan(home)
        for risk in [RiskLevel.yellow, .red] {
            let item = try finding(known, scan: scanned, risk: risk)
            XCTAssertFalse(service.assess(findings: [item], scan: scanned, home: home, runningApplications: []).contains { $0.canSelect })
            XCTAssertThrowsError(try service.prepare(selected: [item], scan: scanned, home: home, allowedRoots: [home]))
        }
        XCTAssertThrowsError(try service.prepare(selected: [finding(known, scan: scanned, complete: false)], scan: scanned,
                                                 home: home, allowedRoots: [home]))
        XCTAssertThrowsError(try service.prepare(selected: [finding(unknown, scan: scanned, risk: .green)], scan: scanned,
                                                 home: home, allowedRoots: [home]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: known.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
    }

    func testScopeEscapeAndBroadApplicationSupportCannotBeProcessed() throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let known = try cache(home)
        let scanned = scan(home)
        let outside = root.appendingPathComponent("unrelated-grant")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        XCTAssertThrowsError(try service.prepare(selected: [finding(known, scan: scanned)], scan: scanned, home: home, allowedRoots: [outside]))
        let broad = home.appendingPathComponent("Library/Application Support/Codex")
        XCTAssertThrowsError(try service.prepare(selected: [finding(broad, scan: scanned, risk: .green)], scan: scanned,
                                                 home: home, allowedRoots: [home]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: known.path))
    }

    func testSameSizeAndTimestampReplacementInvalidatesPreparedIdentity() throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let known = try cache(home)
        let scanned = scan(home)
        let plan = try service.prepare(selected: [finding(known, scan: scanned)], scan: scanned, home: home, allowedRoots: [home])
        let payload = known.appendingPathComponent("data_0")
        let timestamp = try FileManager.default.attributesOfItem(atPath: payload.path)[.modificationDate]
        let replacement = root.appendingPathComponent("replacement")
        try Data(repeating: 0x72, count: 1024).write(to: replacement)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.moveItem(at: replacement, to: payload)
        if let timestamp { try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: payload.path) }
        let outcome = service.execute(plan: plan, runningApplications: { [] }, trash: simulatedTrash(root))
        XCTAssertEqual(outcome.trashedCount, 0)
        XCTAssertEqual(outcome.items.first?.status, .blocked)
        XCTAssertEqual(try Data(contentsOf: payload), Data(repeating: 0x72, count: 1024))
    }

    func testTinyHiddenProtectedFileInsertedAfterConfirmationIsPreserved() throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let known = try cache(home, files: ["data_0", "f_000001"])
        let scanned = scan(home)
        let plan = try service.prepare(selected: [finding(known, scan: scanned)], scan: scanned, home: home, allowedRoots: [home])
        let hiddenCode = known.appendingPathComponent(".my-project.swift")
        try Data([0x63]).write(to: hiddenCode)
        let outcome = service.execute(plan: plan, runningApplications: { [] }, trash: simulatedTrash(root))
        XCTAssertEqual(outcome.trashedCount, 0)
        XCTAssertEqual(try Data(contentsOf: hiddenCode), Data([0x63]))
    }

    func testApplicationIsCheckedAgainAtExecution() throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let known = try cache(home)
        let scanned = scan(home)
        let item = try finding(known, scan: scanned)
        XCTAssertFalse(service.assess(findings: [item], scan: scanned, home: home, runningApplications: ["com.openai.codex"]).contains { $0.canSelect })
        let plan = try service.prepare(selected: [item], scan: scanned, home: home, allowedRoots: [home])
        let outcome = service.execute(plan: plan, runningApplications: { ["com.openai.codex"] }, trash: simulatedTrash(root))
        XCTAssertEqual(outcome.trashedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: known.path))
    }

    func testTrashFailureRestoresAndCollisionNeverOverwritesNewData() throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let known = try cache(home)
        let scanned = scan(home)
        let plan = try service.prepare(selected: [finding(known, scan: scanned)], scan: scanned, home: home, allowedRoots: [home])
        let failed = service.execute(plan: plan, runningApplications: { [] }) { _ in throw TestError.simulatedFailure }
        XCTAssertEqual(failed.trashedCount, 0)
        XCTAssertEqual(failed.items.first?.status, .failed)
        XCTAssertEqual(try Data(contentsOf: known.appendingPathComponent("data_0")), Data(repeating: 0x51, count: 1024))
        let rescan = scan(home)
        let newPlan = try service.prepare(selected: [finding(known, scan: rescan)], scan: rescan, home: home, allowedRoots: [home])
        let collision = service.execute(plan: newPlan, runningApplications: { [] }) { _ in
            try FileManager.default.createDirectory(at: known, withIntermediateDirectories: false)
            try Data([0x63]).write(to: known.appendingPathComponent("new.swift"))
            throw TestError.simulatedFailure
        }
        XCTAssertEqual(collision.trashedCount, 0)
        XCTAssertEqual(collision.items.first?.status, .failed)
        XCTAssertEqual(try Data(contentsOf: known.appendingPathComponent("new.swift")), Data([0x63]))
        let recovery = URL(fileURLWithPath: try XCTUnwrap(collision.items.first?.recoveryPath))
        XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent("data_0")), Data(repeating: 0x51, count: 1024))
    }

    func testHardLinkOutsideCacheAndSymlinkAncestorAreBlocked() throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let known = try cache(home)
        let alias = root.appendingPathComponent("alias")
        guard home.path.withCString({ source in alias.path.withCString { symlink(source, $0) } }) == 0 else {
            throw XCTSkip("当前外置卷不支持符号链接；在 APFS CLI 自测验证。")
        }
        let scanned = scan(home)
        XCTAssertThrowsError(try service.prepare(selected: [finding(known, scan: scanned)], scan: scanned, home: alias, allowedRoots: [alias]))
        let linked = root.appendingPathComponent("external-link")
        guard known.appendingPathComponent("data_0").path.withCString({ source in linked.path.withCString { Darwin.link(source, $0) } }) == 0 else {
            throw XCTSkip("当前外置卷不支持硬链接；在 APFS CLI 自测验证。")
        }
        let afterLink = scan(home)
        XCTAssertThrowsError(try service.prepare(selected: [finding(known, scan: afterLink)], scan: afterLink, home: home, allowedRoots: [home]))
        XCTAssertEqual(try Data(contentsOf: linked), Data(repeating: 0x51, count: 1024))
    }

    private enum TestError: Error { case outsideFixture, simulatedFailure }
}
