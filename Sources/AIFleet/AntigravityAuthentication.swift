import Darwin
import Foundation

/// Runs the CLI's browser authentication over ACP without opening an agent session.
final class AntigravityAuthentication: @unchecked Sendable {
    enum Failure: LocalizedError {
        case unavailable, failed, timedOut, cancelled

        var errorDescription: String? {
            switch self {
            case .unavailable: return "This CLI does not offer browser sign-in. Run agy in your terminal."
            case .failed: return "Antigravity sign-in did not complete. Check the Google sign-in page and retry."
            case .timedOut: return "Antigravity sign-in timed out. Retry and finish Google sign-in."
            case .cancelled: return nil
            }
        }
    }

    private let lock = NSLock()
    private var cancelled = false
    private var child: Process?

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let child, child.isRunning { child.terminate() }
    }

    func run(executable: URL, timeout: TimeInterval = 600) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let outgoing = input.fileHandleForWriting
        let incoming = output.fileHandleForReading
        process.executableURL = executable
        process.arguments = ["acp"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        // An old CLI may close stdin before accepting the request.
        _ = fcntl(outgoing.fileDescriptor, F_SETNOSIGPIPE, 1)

        lock.lock()
        if cancelled { lock.unlock(); throw Failure.cancelled }
        do { try process.run() } catch { lock.unlock(); throw Failure.unavailable }
        child = process
        lock.unlock()
        defer {
            try? outgoing.close()
            lock.lock()
            child = nil
            if process.isRunning { process.terminate() }
            lock.unlock()
            if exited.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }

        let deadline = DispatchTime.now() + timeout
        let loginMethod = "oauth-personal"
        var buffer = Data()
        do {
            try Self.send(id: 1, method: "initialize", params: ["protocolVersion": 1, "clientCapabilities": [:]], to: outgoing)
            let initialized = try reply(id: 1, from: incoming, buffer: &buffer, deadline: min(deadline, .now() + 10))
            let methods = initialized["authMethods"] as? [[String: Any]] ?? []
            guard initialized["protocolVersion"] as? Int == 1,
                  methods.contains(where: { $0["id"] as? String == loginMethod }) else { throw Failure.unavailable }
            try Self.send(id: 2, method: "authenticate", params: ["methodId": loginMethod], to: outgoing)
            _ = try reply(id: 2, from: incoming, buffer: &buffer, deadline: deadline)
            try checkCancellation()
        } catch {
            try checkCancellation()
            throw error as? Failure ?? Failure.failed
        }
    }

    private func checkCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw Failure.cancelled }
    }

    private static func send(id: Int, method: String, params: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func reply(id: Int, from handle: FileHandle, buffer: inout Data, deadline: DispatchTime) throws -> [String: Any] {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            try checkCancellation()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { throw Failure.timedOut }
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: end)
                buffer.removeSubrange(...end)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      message["id"] as? Int == id else { continue }
                guard message["jsonrpc"] as? String == "2.0", message["error"] == nil,
                      let result = message["result"] as? [String: Any] else { throw Failure.failed }
                return result
            }
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remaining = (deadline.uptimeNanoseconds - now) / 1_000_000
            let ready = poll(&descriptor, 1, Int32(min(remaining + 1, 250)))
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw Failure.failed }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor.fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.failed }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= 1_048_576 else { throw Failure.failed }
        }
    }
}
