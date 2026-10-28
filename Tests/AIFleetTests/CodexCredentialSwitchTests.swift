import XCTest
@testable import AIFleet

final class CodexCredentialSwitchTests: XCTestCase {
    func testSwitchPreservesHistorySavesOutgoingAndCanSwitchBack() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared"), alpha = root.appendingPathComponent("alpha"), beta = root.appendingPathComponent("beta")
        for path in [shared, alpha, beta] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        func data(_ email: String) throws -> Data {
            let claims = try JSONSerialization.data(withJSONObject: ["email": email]).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": "fixture", "refresh_token": "fixture", "account_id": email, "id_token": "x.\(claims).y"]])
        }
        let a = try data("a@example.test"), b = try data("b@example.test")
        try a.write(to: shared.appendingPathComponent("auth.json"))
        try b.write(to: beta.appendingPathComponent("auth.json"))
        let history = shared.appendingPathComponent("history.jsonl")
        try Data("existing conversations".utf8).write(to: history)
        let config = shared.appendingPathComponent("config.toml")
        let state = shared.appendingPathComponent("state.sqlite")
        try Data("model = \"fixture\"".utf8).write(to: config)
        try Data("retained state".utf8).write(to: state)
        func saved(_ email: String) -> URL? { email == "a@example.test" ? alpha : beta }
        XCTAssertThrowsError(try CodexCredentialSwitch.activate(incoming: beta, expectedEmail: "b@example.test", shared: shared,
            inventory: { [123] }, savedHome: saved))
        XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("auth.json")), a)
        try CodexCredentialSwitch.activate(incoming: beta, expectedEmail: "b@example.test", shared: shared, inventory: { [] }, savedHome: saved)
        XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("auth.json")), b)
        XCTAssertEqual(try Data(contentsOf: alpha.appendingPathComponent("auth.json")), a)
        try CodexCredentialSwitch.activate(incoming: alpha, expectedEmail: "a@example.test", shared: shared, inventory: { [] }, savedHome: saved)
        XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("auth.json")), a)
        XCTAssertEqual(try String(contentsOf: history), "existing conversations")
        XCTAssertEqual(try String(contentsOf: config), "model = \"fixture\"")
        XCTAssertEqual(try String(contentsOf: state), "retained state")
        XCTAssertThrowsError(try CodexCredentialSwitch.checkpoint(shared: shared, saved: beta, expectedEmail: "wrong@example.test"))
        XCTAssertEqual(try Data(contentsOf: beta.appendingPathComponent("auth.json")), b)
        var checks = 0
        XCTAssertThrowsError(try CodexCredentialSwitch.activate(incoming: beta, expectedEmail: "b@example.test", shared: shared,
            inventory: { checks += 1; return checks == 1 ? [] : [321] }, savedHome: saved))
        XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("auth.json")), a)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: shared.appendingPathComponent("auth.json").path)[.posixPermissions] as? Int, 0o600)
        XCTAssertThrowsError(try CodexCredentialSwitch.activate(incoming: beta, expectedEmail: "wrong@example.test", shared: shared, inventory: { [] }, savedHome: saved))
        let redirected = root.appendingPathComponent("redirected")
        try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: beta)
        XCTAssertThrowsError(try CodexCredentialSwitch.activate(incoming: redirected, expectedEmail: "b@example.test", shared: shared, inventory: { [] }, savedHome: saved))
    }
}
