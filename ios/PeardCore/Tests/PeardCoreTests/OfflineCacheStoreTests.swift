import XCTest
@testable import PeardCore

/// The on-device cache of moment definitions and avatar bytes, kept so the Home
/// tab draws its custom moments and faces with no signal (#313).
///
/// Worth its own suite for the same reason the connection cache has one: a cache
/// that never writes looks exactly like one that is never read, and the only
/// person who notices is somebody with no connectivity.
final class OfflineCacheStoreTests: XCTestCase {
    private var suiteName: String!
    private var store: SharedStore!

    override func setUp() {
        super.setUp()
        suiteName = "offline-cache-\(UUID().uuidString)"
        store = SharedStore(defaults: UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        store = nil
        suiteName = nil
        super.tearDown()
    }

    private func kind(_ slug: String, pair: String = "p1") -> MomentKind {
        MomentKind(
            id: "id-\(slug)",
            pair: pair,
            slug: EventKind(rawValue: slug),
            emoji: "🫶",
            label: slug.capitalized,
            createdBy: "me",
            created: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: Moment definitions

    func testWhatWasCachedIsWhatComesBack() {
        store.setCachedMomentKinds([kind("coffee"), kind("walk")], forConnection: "p1")

        let cached = store.cachedMomentKinds(forConnection: "p1")
        XCTAssertEqual(cached.map { $0.slug.rawValue }, ["coffee", "walk"])
        XCTAssertEqual(cached.map(\.label), ["Coffee", "Walk"])
    }

    func testNothingCachedIsAnEmptyList() {
        XCTAssertTrue(store.cachedMomentKinds(forConnection: "p1").isEmpty)
    }

    /// Each connection's moments are its own: a group's custom moments are not a
    /// pair's, so one must not be served for the other.
    func testCachedMomentsAreKeptPerConnection() {
        store.setCachedMomentKinds([kind("coffee", pair: "p1")], forConnection: "p1")
        store.setCachedMomentKinds([kind("gym", pair: "p2")], forConnection: "p2")

        XCTAssertEqual(store.cachedMomentKinds(forConnection: "p1").map { $0.slug.rawValue }, ["coffee"])
        XCTAssertEqual(store.cachedMomentKinds(forConnection: "p2").map { $0.slug.rawValue }, ["gym"])
    }

    /// A connection whose custom moments were all removed should stop offering
    /// them offline, rather than resurrecting a stale list.
    func testCachingAnEmptyListForgetsRatherThanRemembers() {
        store.setCachedMomentKinds([kind("coffee")], forConnection: "p1")

        store.setCachedMomentKinds([], forConnection: "p1")

        XCTAssertTrue(store.cachedMomentKinds(forConnection: "p1").isEmpty)
    }

    func testCachingAgainReplacesTheList() {
        store.setCachedMomentKinds([kind("coffee"), kind("walk")], forConnection: "p1")

        store.setCachedMomentKinds([kind("walk")], forConnection: "p1")

        XCTAssertEqual(store.cachedMomentKinds(forConnection: "p1").map { $0.slug.rawValue }, ["walk"])
    }

    // MARK: Avatars

    func testCachedAvatarBytesRoundTrip() {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])

        store.setCachedAvatar(bytes, forKey: "users/u1?thumb=128x128")

        XCTAssertEqual(store.cachedAvatar(forKey: "users/u1?thumb=128x128"), bytes)
    }

    func testAMissingAvatarIsNil() {
        XCTAssertNil(store.cachedAvatar(forKey: "users/u1?thumb=128x128"))
    }

    /// The thumb size is part of the key: the rail asks for a 128 and the
    /// settings circle a 512, and one must not be served where the other was
    /// asked for.
    func testAvatarsAreKeptPerKey() {
        store.setCachedAvatar(Data([0xAA]), forKey: "users/u1?thumb=128x128")
        store.setCachedAvatar(Data([0xBB]), forKey: "users/u1?thumb=512x512")

        XCTAssertEqual(store.cachedAvatar(forKey: "users/u1?thumb=128x128"), Data([0xAA]))
        XCTAssertEqual(store.cachedAvatar(forKey: "users/u1?thumb=512x512"), Data([0xBB]))
    }

    /// A replaced photo overwrites the entry for that face rather than leaving the
    /// old bytes behind it.
    func testCachingAnAvatarAgainReplacesTheBytes() {
        store.setCachedAvatar(Data([0xAA]), forKey: "users/u1?thumb=128x128")

        store.setCachedAvatar(Data([0xBB]), forKey: "users/u1?thumb=128x128")

        XCTAssertEqual(store.cachedAvatar(forKey: "users/u1?thumb=128x128"), Data([0xBB]))
    }
}
