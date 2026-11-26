import AppKit
import Foundation

@MainActor
final class FleetIntegrations {
    enum Integration: String, CaseIterable {
        case lens = "Lens"
        case grist = "Grist"

        var executable: URL? {
            executable(in: FileManager.default.homeDirectoryForCurrentUser,
                       search: ProviderInstallDetector.executableURL(named:))
        }

        func executable(in home: URL, search: ([String]) -> URL?) -> URL? {
            let name = rawValue.lowercased()
            let installed = home.appendingPathComponent(".toolbelt/\(name)/bin/\(name)")
            if FileManager.default.isExecutableFile(atPath: installed.path) { return installed }
            return search([name])
        }
    }

    private struct LaunchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let shared = FleetIntegrations()
    private let gristPage = URL(string: "http://127.0.0.1:4680/")!
    private var gristProcess: Process?

    func open(_ integration: Integration) async throws {
        switch integration {
        case .lens:
            guard let executable = integration.executable else { throw LaunchError(message: "Lens is not installed.") }
            try await Self.openLens(executable)
        case .grist:
            if !(await gristIsReady()) { try await startGrist() }
            guard NSWorkspace.shared.open(gristPage) else {
                throw LaunchError(message: "The browser could not open Grist.")
            }
        }
    }

    private static func openLens(_ executable: URL) async throws {
        let workspace = NSWorkspace.shared
        guard let terminal = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw LaunchError(message: "Terminal is not available.")
        }

        let files = FileManager.default
        let command = files.temporaryDirectory.appendingPathComponent("AI Fleet Lens-\(UUID().uuidString).command")
        let path = executable.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        /bin/rm -f -- "$0"
        cd "$HOME" || exit 1
        unset NO_COLOR
        exec '\(path)'
        """ + "\n"
        do {
            try Data(script.utf8).write(to: command, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await workspace.open([command], withApplicationAt: terminal, configuration: configuration)
        } catch {
            try? files.removeItem(at: command)
            throw LaunchError(message: "Lens could not open in Terminal.")
        }
    }

    private func gristIsReady() async -> Bool {
        let url = gristPage.appendingPathComponent("api")
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 0.5)
        guard let (body, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, response.url == url else { return false }
        return body.starts(with: "Grist: the user's list of tasks in work".utf8)
    }

    private func startGrist() async throws {
        if gristProcess?.isRunning != true {
            guard let executable = Integration.grist.executable else {
                throw LaunchError(message: "Grist is not installed.")
            }
            let process = Process()
            process.executableURL = executable
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            gristProcess = process
        }
        for _ in 0..<20 {
            if await gristIsReady() { return }
            if gristProcess?.isRunning != true { break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw LaunchError(message: "Grist could not start on port 4680.")
    }
}
