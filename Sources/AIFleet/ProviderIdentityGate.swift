import Foundation

/// Recheck the credential home at command launch, not just when Switch was clicked.
enum ProviderIdentityGate {
    static func validate(_ profile: ProviderLaunchProfile, directory: URL, executable: URL,
                         environment: [String: String]) throws {
        guard !profile.email.isEmpty else { throw ProviderTerminalLaunch.Failure.identityUnverified }
        let observed: String?
        if profile.providerID == "claude" {
            let result = LocalCommandReader.read(executableURL: executable, arguments: ["auth", "status"], timeout: 10, environment: environment)
            let object = result.flatMap { $0.exitCode == 0 ? (try? JSONSerialization.jsonObject(with: $0.data) as? [String: Any]) : nil }
            observed = object?["email"] as? String
        } else if profile.providerID == "kimi" || profile.providerID == "gemini" {
            let file = directory.appendingPathComponent(profile.providerID == "kimi" ? "credentials/kimi-code.json" : "oauth_creds.json")
            try CodexTerminalLaunch.checkPath(file)
            let object = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let token = object?["access_token"] as? String ?? object?["accessToken"] as? String
            observed = token.flatMap { email(token: $0, providerID: profile.providerID) }
        } else {
            // Qwen's local token reader does not establish an email identity.
            throw ProviderTerminalLaunch.Failure.identityUnsupported
        }
        guard AccountIdentityMatch.assess(expected: profile.email, observed: observed) == .verified else {
            throw ProviderTerminalLaunch.Failure.identityUnverified
        }
    }

    private final class ResultBox: @unchecked Sendable {
        var email: String?
    }
    private static func email(token: String, providerID: String) -> String? {
        let url = providerID == "kimi" ? "https://api.kimi.com/coding/v1/me" : "https://www.googleapis.com/oauth2/v2/userinfo"
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral, delegate: ProviderLoginRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let semaphore = DispatchSemaphore(value: 0), box = ResultBox()
        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            box.email = object["email"] as? String
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 12) == .success else { task.cancel(); return nil }
        return box.email
    }
}
