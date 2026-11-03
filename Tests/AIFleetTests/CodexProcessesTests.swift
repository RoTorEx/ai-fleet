import Darwin
import Foundation
import XCTest
@testable import AIFleet

final class CodexProcessesTests: XCTestCase {
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
