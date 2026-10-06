import XCTest
@testable import AIFleet

final class ClaudeProfilesTests: XCTestCase {
    func testProfileEnvironmentCannotBorrowOtherAccountAndDoesNotRewriteSource() {
        let profile = ClaudeProfile(id: "a", name: "Work", configDirectory: "/profiles/work")
        let inherited = ["CLAUDE_CONFIG_DIR": "/profiles/other", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/profiles/other",
                         "ANTHROPIC_API_KEY": "test-api", "CLAUDE_CODE_OAUTH_TOKEN": "test-token",
                         "PATH": "/usr/bin", "LANG": "en_US.UTF-8"]
        let environment = profile.environment(inheriting: inherited)
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/profiles/work")
        XCTAssertNil(environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertEqual(environment["PATH"], inherited["PATH"])
        XCTAssertEqual(inherited["CLAUDE_CONFIG_DIR"], "/profiles/other")
        XCTAssertNil(ClaudeProfile.current.environment(inheriting: inherited)["CLAUDE_CONFIG_DIR"])
        XCTAssertNotEqual(profile.keychainService, ClaudeProfile.current.keychainService)
        XCTAssertNotEqual(profile.keychainService,
                          ClaudeProfile(id: "b", name: "Other", configDirectory: "/profiles/other").keychainService)
        let unicode = ClaudeProfile(id: "c", name: "Unicode", configDirectory: "/profiles/é")
        let decomposed = ClaudeProfile(id: "d", name: "Unicode", configDirectory: "/profiles/e\u{301}")
        XCTAssertEqual(unicode.keychainService, decomposed.keychainService)
    }

    func testSameEmailInDifferentOrganizationsHasIndependentNotificationState() {
        let first = ProviderAccountIdentity(email: "person@example.test", organizationID: "org-a",
                                          organizationName: "Company A", subscriptionType: "team")
        let second = ProviderAccountIdentity(email: "person@example.test", organizationID: "org-b",
                                           organizationName: "Company B", subscriptionType: "enterprise")
        let profile = ClaudeProfile(id: "profile", name: "Work", configDirectory: "/profiles/work")
        let quota = ClaudeQuota.unavailable("Checking")
        let statusA = profile.status(from: quota, account: first)
        let statusB = profile.status(from: quota, account: second)
        XCTAssertEqual(statusA.id, statusB.id)
        XCTAssertEqual(statusA.providerID, "claude")
        XCTAssertNotEqual(statusA.notificationScope, statusB.notificationScope)
        XCTAssertFalse(statusA.notificationScope.contains("person@example.test"))
        XCTAssertEqual(first.planLabel, "Team")
        XCTAssertTrue(first.caption.contains("Company A"))
        XCTAssertTrue(second.caption.contains("Enterprise"))
        let renamed = ClaudeProfile(id: "profile", name: "Renamed", configDirectory: "/profiles/work")
        XCTAssertEqual(statusA.notificationScope, renamed.status(from: quota, account: first).notificationScope)
    }

    func testLaunchUsesChosenProfileAndSafelyQuotesPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake ' claude")
        try "#!/bin/sh\nprintf '%s\\n' \"$CLAUDE_CONFIG_DIR\" \"$PWD\" \"$*\"\ntest -z \"$ANTHROPIC_API_KEY\"\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let maliciousPath = "/profiles/a ' $(touch unwanted) `echo bad`"
        let profile = ClaudeProfile(id: "a", name: "A", configDirectory: maliciousPath)
        let command = ClaudeProfileLaunch.command(profile: profile, executable: executable,
                                                  directory: directory, login: true)
        let result = try XCTUnwrap(LocalCommandReader.read(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                  arguments: ["-c", command], environment: ["PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "test-api"]))
        XCTAssertEqual(result.exitCode, 0)
        let lines = String(decoding: result.data, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, [maliciousPath, directory.path, "auth login"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unwanted").path))
        let script = "return " + ClaudeProfileLaunch.appleScriptString(command)
        var error: NSDictionary?
        let returned = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
        XCTAssertNil(error)
        XCTAssertEqual(returned, command)
    }

    @MainActor
    func testTwoProfilesFetchTheirOwnMetadataAndQuotasWithoutDefaultFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-claude")
        try "#!/bin/sh\ntest \"$1 $2\" = 'auth status' || exit 2\nif test -f \"$CLAUDE_CONFIG_DIR/auth-fixture.json\"; then\n/bin/cat \"$CLAUDE_CONFIG_DIR/auth-fixture.json\"\nelse\nprintf '%s' '{\"loggedIn\":false,\"authMethod\":\"none\"}'\nexit 1\nfi\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        func fixture(_ id: String, organization: String, plan: String) throws -> ClaudeProfile {
            let folder = directory.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let auth: [String: Any] = ["loggedIn": true, "authMethod": "claude.ai", "configDirectory": folder.path,
                                     "email": "person@example.test", "orgId": organization, "orgName": organization,
                                     "subscriptionType": plan]
            try JSONSerialization.data(withJSONObject: auth).write(to: folder.appendingPathComponent("auth-fixture.json"))
            let credentials: [String: Any] = ["claudeAiOauth": ["accessToken": "test-token-\(id)", "scopes": ["user:profile"]]]
            try JSONSerialization.data(withJSONObject: credentials).write(to: folder.appendingPathComponent(".credentials.json"))
            return ClaudeProfile(id: id, name: id, configDirectory: folder.path)
        }
        let a = try fixture("a", organization: "org-a", plan: "team")
        let b = try fixture("b", organization: "org-b", plan: "enterprise")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeProfileQuotaProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        async let statusA = StatusService.checkClaudeProfile(a, executableURL: executable, quotaSession: session)
        async let statusB = StatusService.checkClaudeProfile(b, executableURL: executable, quotaSession: session)
        let statuses = await (statusA, statusB)
        XCTAssertEqual(statuses.0.remainingPercent, 80)
        XCTAssertEqual(statuses.1.remainingPercent, 10)
        XCTAssertEqual(statuses.0.account?.planLabel, "Team")
        XCTAssertEqual(statuses.1.account?.planLabel, "Enterprise")
        XCTAssertNotEqual(statuses.0.notificationScope, statuses.1.notificationScope)
        let signedOut = ClaudeProfile(id: "empty", name: "Empty", configDirectory: directory.appendingPathComponent("empty").path)
        let missing = await StatusService.checkClaudeProfile(signedOut, executableURL: executable, quotaSession: session)
        XCTAssertEqual(missing.state, .noKey)
        XCTAssertNil(missing.remainingPercent)
        XCTAssertNil(missing.account)
    }
}

private final class ClaudeProfileQuotaProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Authorization")
        let body: String
        if token == "Bearer test-token-a" {
            body = #"{"five_hour":{"utilization":20},"seven_day":{"utilization":10}}"#
        } else if token == "Bearer test-token-b" {
            body = #"{"five_hour":{"utilization":90},"seven_day":{"utilization":50}}"#
        } else {
            XCTFail("Profile used an unexpected credential")
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
