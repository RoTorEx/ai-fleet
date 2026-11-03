import Foundation

/// Kimi's device authorization flow, matching the installed native CLI contract.
@MainActor
struct KimiAccountLogin {
    enum Failure: LocalizedError {
        case unavailable, denied, expired, wrongAccount, identityUnavailable
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Kimi sign-in could not complete. Retry browser sign-in."
            case .denied: return "Kimi sign-in was declined. Existing logins are unchanged."
            case .expired: return "Kimi sign-in expired. Start again."
            case .wrongAccount: return "The signed-in Kimi email does not match this account. No credentials were saved."
            case .identityUnavailable: return "Kimi did not confirm the account email. No credentials were saved."
            }
        }
    }
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

    static func authenticate(expectedEmail: String, session: URLSession, headers: [String: String],
                             authorize: (URL, String) -> Void,
                             sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) async throws -> KimiCodeAuth {
        let device = try await post("device_authorization", fields: ["client_id": clientID], headers: headers, session: session)
        guard device.0 == 200, let code = device.1["device_code"] as? String, !code.isEmpty,
              let userCode = device.1["user_code"] as? String,
              let uri = device.1["verification_uri_complete"] as? String, let url = URL(string: uri),
              url.scheme == "https", ["auth.kimi.com", "kimi.com", "www.kimi.com"].contains(url.host ?? "") else { throw Failure.unavailable }
        authorize(url, userCode)
        var interval = max(1, min(60, device.1["interval"] as? Int ?? 5))
        let deadline = Date().addingTimeInterval(Double(max(1, min(900, device.1["expires_in"] as? Int ?? 600))))
        while Date() < deadline {
            try Task.checkCancellation()
            try await sleep(UInt64(interval) * 1_000_000_000)
            let result = try await post("token", fields: ["client_id": clientID, "device_code": code,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"], headers: headers, session: session)
            if result.0 == 200, let token = result.1["access_token"] as? String, !token.isEmpty {
                var request = URLRequest(url: URL(string: "https://api.kimi.com/coding/v1/me")!)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 15
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let email = object["email"] as? String, !email.isEmpty else { throw Failure.identityUnavailable }
                guard AccountIdentityMatch.assess(expected: expectedEmail, observed: email) == .verified else { throw Failure.wrongAccount }
                let expires = result.1["expires_in"] as? Int ?? 3600
                return KimiCodeAuth(accessToken: token, refreshToken: result.1["refresh_token"] as? String,
                    expiresAt: Date().timeIntervalSince1970 + Double(expires), expiresIn: expires,
                    scope: result.1["scope"] as? String, tokenType: result.1["token_type"] as? String ?? "Bearer")
            }
            switch result.1["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval = min(60, interval + 5)
            case "access_denied": throw Failure.denied
            case "expired_token": throw Failure.expired
            default: throw Failure.unavailable
            }
        }
        throw Failure.expired
    }

    private static func post(_ route: String, fields: [String: String], headers: [String: String],
                             session: URLSession) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "https://auth.kimi.com/api/oauth/\(route)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        var form = URLComponents()
        form.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unavailable }
        return (http.statusCode, object)
    }
}

final class ProviderLoginRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
