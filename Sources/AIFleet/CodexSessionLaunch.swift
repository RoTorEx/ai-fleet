import AppKit
import Darwin
import Foundation

enum CodexSessionLaunch {
    enum Failure: LocalizedError {
        case missingLogin, wrongAccount, activeSessions, terminalUnavailable
        var errorDescription: String? {
            switch self {
            case .missingLogin: return "This account has no separate login. Connect it once before starting account-isolated sessions."
            case .wrongAccount: return "The saved login belongs to another account. Choose the matching account."
            case .activeSessions: return "This account has running Fleet sessions. Finish them before changing its login. Other accounts remain available."
            case .terminalUnavailable: return "Could not open a new terminal. Check Automation permission for AI Fleet."
            }
        }
    }

    static func command(home: URL, executable: URL, workspaceID: String? = nil) -> String {
        let quote = ClaudeProfileLaunch.shellQuote
        let unset = ProviderConnection.global("codex").overrideKeys.map { "-u " + quote($0) }.joined(separator: " ")
        let workspace = workspaceID.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { " -c " + quote("forced_chatgpt_workspace_id=" + $0) } ?? ""
        return "/usr/bin/env \(unset) \(quote("CODEX_HOME=" + home.path)) \(quote(executable.path)) -c 'cli_auth_credentials_store=\"file\"' --no-daemon\(workspace)"
    }

    /// A private wrapper registers its own PID, never reads other processes' environment.
    static func script(home: URL, executable: URL, project: URL?, marker: URL, workspaceID: String? = nil,
                       reusable: Bool = false) -> String {
        let quote = ClaudeProfileLaunch.shellQuote
        return """
        #!/bin/zsh
        umask 077
        \(project.map { "cd " + quote($0.path) + " || exit 1" } ?? "")
        fleetSessionMarker=\(quote(marker.path)).$$.pid
        print -r -- $$ > "$fleetSessionMarker" || exit 1
        fleetWrapperPath="$0"
        cleanup() { /bin/rm -f -- "$fleetSessionMarker"\(reusable ? "" : " \"$fleetWrapperPath\""); }
        trap cleanup EXIT
        test -s \(quote(home.appendingPathComponent("auth.json").path)) || { print -u2 'This account is no longer connected. Open AI Fleet to reconnect it.'; exit 1; }
        \(command(home: home, executable: executable, workspaceID: workspaceID))
        result=$?
        exit "$result"

        """
    }

    static func hasRunningSessions(home: URL, isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) throws -> Bool {
        let directory = home.appendingPathComponent("FleetSessions", isDirectory: true)
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { throw ProviderLogout.Failure.unsafePath }
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "pid" {
            guard file.resolvingSymlinksInPath().path == file.standardizedFileURL.path else { throw ProviderLogout.Failure.unsafePath }
            guard let pid = Int32(try String(contentsOf: file).trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
                throw Failure.activeSessions
            }
            if isAlive(pid) { return true }
        }
        return false
    }

    @MainActor
    @discardableResult
    static func open(home: URL, executable: URL, project: URL) throws -> String? {
        let file = try prepareScript(home: home, executable: executable, project: project)
        let command = "/bin/zsh " + ClaudeProfileLaunch.shellQuote(file.path)
        let appleScript: String
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil {
            appleScript = """
            tell application "iTerm2"
                activate
                set fleetWindow to (create window with default profile)
                tell current session of fleetWindow to write text \(ClaudeProfileLaunch.appleScriptString(command))
                return id of fleetWindow
            end tell
            """
        } else {
            appleScript = "tell application \"Terminal\"\nactivate\ndo script \(ClaudeProfileLaunch.appleScriptString(command))\nend tell"
        }
        var error: NSDictionary?
        guard let script = NSAppleScript(source: appleScript) else { throw Failure.terminalUnavailable }
        let opened = script.executeAndReturnError(&error)
        if error != nil { try? FileManager.default.removeItem(at: file); throw Failure.terminalUnavailable }
        return opened.stringValue
    }

    static func prepareScript(home: URL, executable: URL, project: URL?, reusable: Bool = false) throws -> URL {
        let directory = home.appendingPathComponent("FleetSessions", isDirectory: true)
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { throw ProviderLogout.Failure.unsafePath }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let id = reusable ? "launch" : UUID().uuidString
        let file = directory.appendingPathComponent(id + ".command")
        guard file.resolvingSymlinksInPath().path == file.standardizedFileURL.path else { throw ProviderLogout.Failure.unsafePath }
        let marker = directory.appendingPathComponent(id + ".pid")
        let authData = try Data(contentsOf: home.appendingPathComponent("auth.json"))
        let auth = try JSONSerialization.jsonObject(with: authData) as? [String: Any]
        let tokens = auth?["tokens"] as? [String: Any]
        let workspaceID = tokens?["account_id"] as? String ?? auth?["account_id"] as? String
        try script(home: home, executable: executable, project: project, marker: marker, workspaceID: workspaceID, reusable: reusable)
            .write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}
