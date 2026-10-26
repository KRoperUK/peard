import XCTest
@testable import Peard
import PeardCore

/// Session teardown must take the extensions' leftovers with it (#432).
///
/// A Control Centre tap or a share-sheet photo waits in the extension inbox
/// with no author attached; the app supplies that when it absorbs it. If a
/// sign-out left the inbox behind, the next sign-in would absorb it and post
/// the previous account's moment as the new account's.
@MainActor
final class SessionTeardownTests: XCTestCase {
    private var app: AppModel!
    private var queue: SendQueue!
    private var inbox: MomentInbox!
    private var inboxURL: URL!
    private var storeURL: URL!
    private var suiteName: String!
    private var shared: SharedStore!
    private var sessionStore: KeychainSessionStore!

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03])

    override func setUp() async throws {
        try await super.setUp()
        storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-teardown-queue-\(UUID().uuidString).json")
        inboxURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-teardown-inbox-\(UUID().uuidString).json")
        queue = SendQueue(store: FilePendingSendStore(url: storeURL))
        inbox = MomentInbox(url: inboxURL)
        suiteName = "peard-teardown-\(UUID().uuidString)"
        shared = SharedStore(defaults: UserDefaults(suiteName: suiteName))
        shared.recordPrivacyConsent()
        sessionStore = KeychainSessionStore(service: "peard-teardown-test-\(UUID().uuidString)")
        sessionStore.clear()
        try sessionStore.save(token: "token", userID: "me")
        app = AppModel(
            sessionStore: sessionStore,
            sharedStore: shared,
            sendQueue: queue,
            momentInbox: inbox,
            session: TeardownStubProtocol.makeSession()
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
        try? FileManager.default.removeItem(at: inboxURL)
        try? FileManager.default.removeItem(at: inbox.photoDirectory)
        UserDefaults().removePersistentDomain(forName: suiteName)
        sessionStore?.clear()
        sessionStore = nil
        shared = nil
        suiteName = nil
        queue = nil
        inbox = nil
        app = nil
        try await super.tearDown()
    }

    /// Account A's inboxed moment — with a share-sheet photo — must be gone
    /// after A signs out, so B's sign-in cannot absorb and post it.
    func testSignOutClearsTheExtensionInbox() async {
        seedInbox()

        await app.signOut()

        XCTAssertTrue(inbox.load().isEmpty)
        XCTAssertNil(inbox.loadPhoto(for: "inboxed"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: inbox.photoDirectory.path),
            "no inbox photo for the old account remains on disk"
        )
        let absorbed = await queue.absorb(inbox, authorID: "somebody-else", fallbackPairID: "p1")
        XCTAssertEqual(absorbed, 0, "nothing left to post as the next account")
    }

    /// Account deletion takes the inbox with it, photos and all.
    func testDeleteAccountClearsTheExtensionInbox() async {
        seedInbox()

        let deleted = await app.deleteAccount()

        XCTAssertTrue(deleted)
        XCTAssertTrue(inbox.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.photoDirectory.path))
    }

    private func seedInbox() {
        let moment = InboxedMoment(
            id: "inboxed", pairID: "p1", kind: .beer, emoji: "🍺", label: "Beer",
            queuedAt: Date(timeIntervalSince1970: 1_790_000_000), hasPhoto: true
        )
        XCTAssertTrue(inbox.append(moment, photo: jpeg))
    }
}

/// Every request succeeds: teardown paths only need the server to say yes.
final class TeardownStubProtocol: URLProtocol {
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeardownStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
