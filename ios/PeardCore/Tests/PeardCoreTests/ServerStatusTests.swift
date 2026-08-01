import XCTest
@testable import PeardCore

/// `GET /api/peard/status`, whose whole job is to work when something else is
/// wrong. A decoder that threw on a surprising shape would hide the answer
/// behind a generic error at exactly the moment somebody needed it.
final class ServerStatusTests: XCTestCase {
    private func decode(_ json: String) throws -> ServerStatus {
        try JSONDecoder.peard.decode(ServerStatus.self, from: Data(json.utf8))
    }

    func testDecodesAFullResponse() throws {
        let status = try decode(#"{"ok":true,"commit":"c1269ef","built_at":"2026-07-31T23:37:10Z","go":"go1.26.4"}"#)

        XCTAssertEqual(status.commit, "c1269ef")
        XCTAssertEqual(status.builtAt, "2026-07-31T23:37:10Z")
        XCTAssertEqual(status.go, "go1.26.4")
    }

    /// A build that supplied no commit says so rather than sending nothing, but
    /// the client must survive either.
    func testMissingFieldsReadAsUnknownRatherThanFailing() throws {
        let status = try decode(#"{"ok":true}"#)

        XCTAssertEqual(status.commit, "unknown")
        XCTAssertEqual(status.builtAt, "unknown")
        XCTAssertEqual(status.go, "unknown")
    }

    /// Extra fields are the expected direction of change for this route, and
    /// must not break a client that predates them.
    func testUnknownFieldsAreIgnored() throws {
        let status = try decode(#"{"commit":"abc1234","built_at":"x","go":"y","uptime_seconds":42}"#)

        XCTAssertEqual(status.commit, "abc1234")
    }

    func testRoundTrips() throws {
        let original = ServerStatus(commit: "deadbee", builtAt: "2026-08-01T00:00:00Z", go: "go1.26.4")

        let decoded = try JSONDecoder.peard.decode(ServerStatus.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
    }
}
