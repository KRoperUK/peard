import XCTest
@testable import PeardCore

/// The last-known connection list, kept so an offline launch has something to
/// show (#300).
///
/// Worth its own file because the failure mode is silent in both directions: a
/// cache that never writes looks exactly like one that is never read, and the
/// only person who notices is somebody standing in a lift with no signal.
final class ConnectionCacheTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-connections-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        url = nil
        super.tearDown()
    }

    private func connection(_ pair: String, name: String? = nil) -> Connection {
        Connection(
            pair: pair,
            name: name,
            created: Date(timeIntervalSince1970: 1_700_000_000),
            role: .member,
            members: [
                Connection.Member(user: "me", name: "Me", role: .member, isYou: true),
                Connection.Member(user: "u1", name: "Sam"),
            ]
        )
    }

    // MARK: Round trip

    func testWhatWasSavedIsWhatComesBack() {
        let cache = FileConnectionCache(url: url)
        let saved = Date(timeIntervalSince1970: 1_700_000_500)

        cache.saveConnections([connection("p1"), connection("p2", name: "Flatmates")], at: saved)

        guard let cached = cache.loadConnections() else { return XCTFail("nothing came back") }
        XCTAssertEqual(cached.connections.map(\.pair), ["p1", "p2"])
        XCTAssertEqual(cached.connections.map { $0.title() }, ["Sam", "Flatmates"])
        XCTAssertEqual(cached.savedAt.timeIntervalSince1970, saved.timeIntervalSince1970, accuracy: 1)
    }

    /// The timestamp is the whole of "last updated", so it has to survive the
    /// file rather than being replaced by the time of the read.
    func testTheTimestampSurvivesTheFile() {
        let cache = FileConnectionCache(url: url)
        let older = Date(timeIntervalSince1970: 1_600_000_000)

        cache.saveConnections([connection("p1")], at: older)

        XCTAssertEqual(cache.loadConnections()?.savedAt.timeIntervalSince1970 ?? 0, older.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: Misses

    func testNothingSavedIsACacheMiss() {
        XCTAssertNil(FileConnectionCache(url: url).loadConnections())
    }

    /// A truncated or hand-edited file is a miss, not a crash: the caller already
    /// knows how to carry on without a cache.
    func testAnUnreadableFileIsACacheMiss() throws {
        try Data("not json at all".utf8).write(to: url)

        XCTAssertNil(FileConnectionCache(url: url).loadConnections())
    }

    // MARK: Clearing

    /// Remembering "you have no connections" would be worse than remembering
    /// nothing: it would bring back a connection somebody has since left, and
    /// its own file would outlive the sign-out that removed the real list.
    func testSavingAnEmptyListForgetsRatherThanRemembers() {
        let cache = FileConnectionCache(url: url)
        cache.saveConnections([connection("p1")], at: Date())

        cache.saveConnections([], at: Date())

        XCTAssertNil(cache.loadConnections())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testClearRemovesTheFile() {
        let cache = FileConnectionCache(url: url)
        cache.saveConnections([connection("p1")], at: Date())

        cache.clear()

        XCTAssertNil(cache.loadConnections())
    }

    /// A second save replaces rather than appends, or leaving a connection would
    /// leave it in the offline list too.
    func testSavingAgainReplacesTheList() {
        let cache = FileConnectionCache(url: url)
        cache.saveConnections([connection("p1"), connection("p2")], at: Date())

        cache.saveConnections([connection("p2")], at: Date())

        XCTAssertEqual(cache.loadConnections()?.connections.map(\.pair), ["p2"])
    }
}
