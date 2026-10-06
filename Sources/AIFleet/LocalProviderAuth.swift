import Foundation
import Darwin

enum LocalProviderAuth: Equatable {
    case signedIn
    case signedOut
    case unknown

    func status(for provider: ProviderDefinition) -> ProviderStatus {
        let state: ProviderStatus.State
        let detail: String
        switch self {
        case .signedIn:
            state = .ok
            detail = "Quota unsupported"
        case .signedOut:
            state = .noKey
            detail = "Sign in required"
        case .unknown:
            state = .offline
            detail = "Auth status unknown"
        }
        return ProviderStatus(id: provider.id, name: provider.name, state: state,
                              detail: detail, lastUpdated: Date())
    }
}

struct ClaudeAuthReader {
    let executableURL: URL?
    var timeout: TimeInterval = 10

    func read() -> LocalProviderAuth {
        guard let executableURL else { return .unknown }
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = ["auth", "status"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .unknown
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.2) != .success {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            return .unknown
        }
        return Self.decode(output.fileHandleForReading.readDataToEndOfFile(),
                           exitCode: process.terminationStatus)
    }

    static func decode(_ data: Data, exitCode: Int32) -> LocalProviderAuth {
        struct Response: Decodable { let loggedIn: Bool }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return .unknown
        }
        switch (response.loggedIn, exitCode) {
        case (true, 0): return .signedIn
        case (false, 1): return .signedOut
        default: return .unknown
        }
    }
}

enum QwenAuthReader {
    // Local credentials indicate a configured OAuth login, not server-verified access.
    static func read(urls: [URL], now: Date = Date()) -> LocalProviderAuth {
        var result = LocalProviderAuth.signedOut
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else {
                result = .unknown
                continue
            }
            switch decode(data, now: now) {
            case .signedIn: return .signedIn
            case .unknown: result = .unknown
            case .signedOut: break
            }
        }
        return result
    }

    static func decode(_ data: Data, now: Date) -> LocalProviderAuth {
        struct Credentials: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expiry_date: Double?
        }
        guard let credentials = try? JSONDecoder().decode(Credentials.self, from: data) else {
            return .unknown
        }
        func nonempty(_ value: String?) -> Bool {
            !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        if nonempty(credentials.refresh_token) { return .signedIn }
        guard nonempty(credentials.access_token) else { return .signedOut }
        if let expiry = credentials.expiry_date, expiry <= now.timeIntervalSince1970 * 1000 {
            return .signedOut
        }
        return .signedIn
    }
}
