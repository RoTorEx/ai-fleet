import Darwin
import Foundation
import XCTest
@testable import AIFleet

final class SwitchRecoveryTests: XCTestCase {
    func testOnlyBoundCurrentAccountIsAutomaticAndUnknownBlocks() throws {
        let one = CodexProcess(pid: 20, uid: getuid(), terminal: "??", started: "1", executable: "/fixture/codex")
        let two = CodexProcess(pid: 21, uid: getuid(), terminal: "??", started: "2", executable: "/fixture/codex")
        let claude = CodexProcess(pid: 22, uid: getuid(), terminal: "??", started: "3", executable: "/fixture/claude")
        let owner: (CodexProcess) -> FleetSessionOwner? = {
            FleetSessionOwner(providerID: $0.providerID, accountID: $0.pid == 20 ? "alpha" : "beta",
                              profileID: "profile", pid: $0.pid, started: $0.started)
        }
        XCTAssertEqual(try SwitchRecovery.targets([one, two, claude], providerID: "codex", accountID: "alpha", owner: owner), [one])
        XCTAssertThrowsError(try SwitchRecovery.targets([one], providerID: "codex", accountID: nil, owner: owner))
        XCTAssertThrowsError(try SwitchRecovery.targets([one, two], providerID: "codex", accountID: "alpha", owner: { $0.pid == 20 ? owner($0) : nil }))
    }

    func testOwnershipSidecarRequiresExactStartAndUnambiguousBinding() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let row = CodexProcess(pid: 20, uid: getuid(), terminal: "??", started: "new", executable: "/fixture/codex")
        let stale = FleetSessionOwner(providerID: "codex", accountID: "alpha", profileID: "p", pid: 20, started: "old")
        let live = FleetSessionOwner(providerID: "codex", accountID: "beta", profileID: "p", pid: 20, started: "new")
        try JSONEncoder().encode(stale).write(to: root.appendingPathComponent("old.owner"))
        XCTAssertNil(SwitchRecovery.owner(of: row, roots: [root]))
        try JSONEncoder().encode(live).write(to: root.appendingPathComponent("new.owner"))
        XCTAssertEqual(SwitchRecovery.owner(of: row, roots: [root]), live)
        try JSONEncoder().encode(live).write(to: root.appendingPathComponent("duplicate.owner"))
        XCTAssertNil(SwitchRecovery.owner(of: row, roots: [root]))
    }

    func testTransitionLockExcludesLaunchAndOtherSwitchButReleasesAfterFailure() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let lock = try ProviderTransitionLock(provider: "codex", home: root, exclusive: true)
            XCTAssertThrowsError(try ProviderTransitionLock(provider: "codex", home: root, exclusive: false))
            XCTAssertThrowsError(try ProviderTransitionLock(provider: "codex", home: root, exclusive: true))
            XCTAssertNoThrow(try ProviderTransitionLock(provider: "claude", home: root, exclusive: true))
            withExtendedLifetime(lock) {}
        }
        XCTAssertNoThrow(try ProviderTransitionLock(provider: "codex", home: root, exclusive: false))
    }

    func testExitRequiresTwoFreshEmptyScansAndInventoryFailurePropagates() async throws {
        let row = CodexProcess(pid: 20, uid: getuid(), terminal: "??", started: "new", executable: "/fixture/codex")
        var scans = 0
        try await SwitchRecovery.waitForExit(timeout: 1, read: {
            scans += 1
            return scans == 2 ? [row] : []
        }, sleep: { _ in })
        XCTAssertEqual(scans, 4, "A respawn between empty checks must reset stability")
        do {
            try await SwitchRecovery.waitForExit(timeout: 1, read: { throw CodexProcessControl.Failure.inventory }, sleep: { _ in })
            XCTFail("An unreadable inventory must not establish exit")
        } catch { XCTAssertTrue(error is CodexProcessControl.Failure) }
    }

    func testInventoryRecognizesVersionedClaudeButNeverArbitraryNode() {
        let version = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/claude/versions/2.1.fixture").path
        XCTAssertEqual(CodexProcessControl.provider(executable: version, script: nil), "claude")
        XCTAssertNil(CodexProcessControl.provider(executable: "/usr/bin/node", script: "/unrelated/claude-project/server.js"))
        XCTAssertNil(CodexProcessControl.provider(executable: "/bin/sleep", script: nil))
    }

    func testCancellationDoesNotBecomeSuccessfulExit() async throws {
        let task = Task {
            try await SwitchRecovery.waitForExit(timeout: 60, read: { [] })
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled wait completed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

@MainActor
final class SwitchTransactionTests: XCTestCase {
    func testInvalidTargetNeverStopsOrCommits() async {
        do {
            try await SwitchRecovery.transition(policy: .force, validate: { throw SwitchRecoveryError.identity },
                read: { XCTFail("Inventory after invalid target"); return [] }, confirm: { _, _ in XCTFail(); return true },
                stop: { _, _ in XCTFail() }, wait: { _, _ in XCTFail() }, commit: { XCTFail() })
            XCTFail("Invalid target accepted")
        } catch { XCTAssertTrue(error is SwitchRecoveryError) }
    }

    func testPoliciesUseOnlyExplicitForceAndCommitAfterExit() async throws {
        for policy in SwitchPolicy.allCases {
            let row = CodexProcess(pid: 20, uid: getuid(), terminal: "??", started: "new", executable: "/fixture/codex")
            var running = true, signals: [Bool] = [], validated = 0, committed = false
            try await SwitchRecovery.transition(policy: policy, validate: { validated += 1 },
                read: { running ? [row] : [] }, confirm: { _, force in XCTAssertEqual(force, policy == .force); return true },
                stop: { _, force in signals.append(force) }, wait: { timeout, _ in
                    XCTAssertEqual(timeout, policy == .wait ? 60 : policy == .force ? 3 : 10)
                    running = false
                }, commit: { committed = true })
            XCTAssertTrue(committed)
            XCTAssertEqual(validated, 2)
            XCTAssertEqual(signals, policy == .force ? [true] : policy == .graceful ? [false] : [])
            XCTAssertEqual(running, policy == .nextLaunch)
        }
    }

    func testRespawnAfterRevalidationPreventsCommit() async {
        let row = CodexProcess(pid: 20, uid: getuid(), terminal: "??", started: "new", executable: "/fixture/codex")
        var validations = 0
        do {
            try await SwitchRecovery.transition(policy: .graceful, validate: { validations += 1 },
                read: { validations == 2 ? [row] : [] }, confirm: { _, _ in true }, stop: { _, _ in XCTFail() },
                wait: { _, _ in }, commit: { XCTFail("Respawn committed") })
            XCTFail("Respawn was ignored")
        } catch { XCTAssertTrue(error is SwitchRecoveryError) }
    }

    func testStopFailureAndDeclinedConfirmationLeaveSelectionUnchanged() async {
        let row = CodexProcess(pid: 20, uid: getuid(), terminal: "??", started: "new", executable: "/fixture/codex")
        for confirmed in [true, false] {
            do {
                try await SwitchRecovery.transition(policy: .force, validate: {}, read: { [row] },
                    confirm: { _, _ in confirmed }, stop: { _, _ in throw CodexProcessControl.Failure.signal(EPERM) },
                    wait: { _, _ in XCTFail() }, commit: { XCTFail("Failed stop committed") })
                XCTFail("Failed stop accepted")
            } catch { }
        }
    }
}
