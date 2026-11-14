import Darwin
import Foundation
import XCTest
@testable import AIFleet

final class CodexProcessesTests: XCTestCase {
    func testRuntimePackagesAndRewrittenTitlesRemainRecognizableAfterUpdates() {
        let packages = [("codex", "@openai/codex"), ("claude", "@anthropic-ai/claude-code"),
                        ("kimi", "@moonshot-ai/kimi-code"), ("qwen", "@qwen-code/qwen-code"),
                        ("gemini", "@google/gemini-cli"), ("grok", "@vibe-kit/grok-cli")]
        for (provider, package) in packages {
            XCTAssertEqual(CodexProcessControl.provider(executable: "/old/node", script: "/old/node_modules/\(package)/cli.js"), provider)
            XCTAssertEqual(CodexProcessControl.provider(executable: "/old/node", script: nil, processName: provider), provider)
        }
        XCTAssertEqual(CodexProcessControl.provider(executable: "/bin/node", script: nil, processName: "kimi-code"), "kimi")
        XCTAssertEqual(CodexProcessControl.provider(executable: "/old/python3.12", script: "/venv/bin/kimi"), "kimi")
        XCTAssertNil(CodexProcessControl.provider(executable: "/bin/vim", script: nil, processName: "codex"))
        XCTAssertNil(CodexProcessControl.provider(executable: "/bin/node", script: "/unrelated/gemini.js"))
        for error in [EPERM, EACCES, ESRCH] {
            XCTAssertNil(CodexProcessControl.executablePath(live: nil, error: error, launch: "/old/codex"))
        }
        XCTAssertNil(CodexProcessControl.executablePath(live: nil, error: ENOENT, launch: "codex"))
    }

    func testKernelLaunchDecoderDoesNotReadEnvironmentAsArguments() {
        let bytes = [UInt8](arrayLiteral: 1, 0, 0, 0) + Array("/old/node\0\0kimi-code\0SECRET_ENV=fixture\0".utf8)
        let launch = CodexProcessControl.decodeLaunchInfo(bytes)
        XCTAssertEqual(launch?.executable, "/old/node")
        XCTAssertEqual(launch?.name, "kimi-code")
        XCTAssertNil(launch?.entry)
        XCTAssertNil(CodexProcessControl.decodeLaunchInfo([1, 0, 0, 0, 47]))
        XCTAssertNil(CodexProcessControl.decodeLaunchInfo([0, 0, 0, 0]))
    }

    func testUnlinkedRunningExecutablesRemainVisibleForEveryProvider() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.c"), binary = root.appendingPathComponent("fixture")
        try "#include <unistd.h>\nint main(void) { write(1, \"R\", 1); for (;;) pause(); }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", binary.path]
        try compiler.run(); compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        for name in ["codex", "claude", "kimi", "qwen", "gemini", "grok"] {
            let executable = root.appendingPathComponent(name)
            try FileManager.default.copyItem(at: binary, to: executable)
            let process = Process(), output = Pipe()
            process.executableURL = executable; process.standardOutput = output
            try process.run()
            defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
            XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data("R".utf8))
            let before = try XCTUnwrap(CodexProcessControl.allInventory().first { $0.pid == process.processIdentifier })
            try FileManager.default.removeItem(at: executable)
            let after = try XCTUnwrap(CodexProcessControl.allInventory().first { $0.pid == process.processIdentifier })
            XCTAssertEqual(after.providerID, name)
            XCTAssertEqual(after.started, before.started)
            XCTAssertEqual(after.uid, before.uid)
            XCTAssertTrue(process.isRunning)
            try CodexProcessControl.stop(after, force: false, read: CodexProcessControl.allInventory)
            process.waitUntilExit()
            XCTAssertFalse(try CodexProcessControl.allInventory().contains(after))
        }
    }

    func testProviderExecutablesAreRecognizedByName() {
        XCTAssertEqual(CodexProcessControl.provider(executable: "/opt/bin/kimi", script: nil), "kimi")
        XCTAssertEqual(CodexProcessControl.provider(executable: "/opt/bin/grok", script: nil), "grok")
        XCTAssertEqual(CodexProcessControl.provider(executable: "/opt/bin/claude", script: nil), "claude")
        XCTAssertNil(CodexProcessControl.provider(executable: "/opt/bin/vim", script: nil))
    }

    func testReplacedPidOrOtherOwnerNeverReceivesSignal() throws {
        let current = CodexProcess(pid: 12345, uid: getuid(), terminal: "??", started: "original", executable: "/bin/codex")
        let replacement = CodexProcess(pid: current.pid, uid: getuid(), terminal: "??", started: "replacement", executable: current.executable)
        var sent = false
        XCTAssertThrowsError(try CodexProcessControl.stop(current, force: true, read: { [replacement] }, signal: { _, _ in sent = true; return 0 }))
        XCTAssertFalse(sent)
        let other = CodexProcess(pid: current.pid, uid: getuid() + 1, terminal: "??", started: current.started, executable: current.executable)
        XCTAssertThrowsError(try CodexProcessControl.stop(other, force: false, read: { [other] }, signal: { _, _ in sent = true; return 0 }))
        XCTAssertFalse(sent)
        var observed: Int32?
        try CodexProcessControl.stop(current, force: false, read: { [current] }, signal: { pid, signal in
            XCTAssertEqual(pid, current.pid); observed = signal; return 0
        })
        XCTAssertEqual(observed, SIGTERM)
        try CodexProcessControl.stop(current, force: true, read: { [current] }, signal: { _, signal in observed = signal; return 0 })
        XCTAssertEqual(observed, SIGKILL)
    }

    func testTerminationAndForceQuitOnlyStopOwnedFixtureProcess() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        let source = root.appendingPathComponent("fixture.c")
        try "#include <unistd.h>\nint main(void) { write(1, \"R\", 1); for (;;) pause(); }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", executable.path]
        try compiler.run(); compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        for force in [false, true] {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable; process.standardOutput = output
            try process.run()
            defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
            XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data("R".utf8))
            let row = try XCTUnwrap(CodexProcessControl.inventory().first { $0.pid == process.processIdentifier })
            try CodexProcessControl.stop(row, force: force)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationReason, .uncaughtSignal)
            XCTAssertEqual(process.terminationStatus, force ? SIGKILL : SIGTERM)
            XCTAssertFalse(try CodexProcessControl.inventory().contains(row))
            XCTAssertThrowsError(try CodexProcessControl.stop(row, force: true))
        }
    }
}
