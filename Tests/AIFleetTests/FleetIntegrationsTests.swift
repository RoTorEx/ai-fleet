import XCTest
@testable import AIFleet

final class FleetIntegrationsTests: XCTestCase {
    func testEachIntegrationRequiresItsOwnExecutable() throws {
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        let lens = home.appendingPathComponent(".toolbelt/lens/bin/lens")
        try files.createDirectory(at: lens.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: lens)
        let missingFromPath: ([String]) -> URL? = { _ in nil }

        XCTAssertNil(FleetIntegrations.Integration.lens.executable(in: home, search: missingFromPath))
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lens.path)
        XCTAssertEqual(FleetIntegrations.Integration.lens.executable(in: home, search: missingFromPath), lens)
        XCTAssertNil(FleetIntegrations.Integration.grist.executable(in: home, search: missingFromPath))

        let grist = home.appendingPathComponent("bin/grist")
        XCTAssertEqual(FleetIntegrations.Integration.grist.executable(in: home, search: { names in
            XCTAssertEqual(names, ["grist"])
            return grist
        }), grist)
    }
}
