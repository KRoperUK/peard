import XCTest
@testable import PeardCore

/// Low data: who decides, and what it changes about the photos (issue #302).
final class LowDataTests: XCTestCase {
    // MARK: The decision

    /// Automatic is iOS's answer, whichever way it goes.
    func testAutomaticFollowsTheSystem() {
        XCTAssertTrue(LowDataPreference.automatic.isActive(systemConstrained: true))
        XCTAssertFalse(LowDataPreference.automatic.isActive(systemConstrained: false))
    }

    /// The two overrides exist to disagree with iOS, so they must, both ways.
    func testTheOverridesIgnoreTheSystem() {
        XCTAssertTrue(LowDataPreference.on.isActive(systemConstrained: false))
        XCTAssertTrue(LowDataPreference.on.isActive(systemConstrained: true))
        XCTAssertFalse(LowDataPreference.off.isActive(systemConstrained: true))
        XCTAssertFalse(LowDataPreference.off.isActive(systemConstrained: false))
    }

    /// Nothing stored, or something a later build wrote, is automatic: an app
    /// should not decide on first launch to ignore a setting made in iOS.
    func testAnUnknownOrMissingValueIsAutomatic() {
        XCTAssertEqual(LowDataPreference(storedValue: nil), .automatic)
        XCTAssertEqual(LowDataPreference(storedValue: "sometimes"), .automatic)
        XCTAssertEqual(LowDataPreference(storedValue: "on"), .on)
        XCTAssertEqual(LowDataPreference(storedValue: "off"), .off)
    }

    /// The notification service extension reads these strings without
    /// PeardCore, so they are a wire format.
    func testRawValuesAreWhatTheExtensionReads() {
        XCTAssertEqual(LowDataPreference.allCases.map(\.rawValue), ["automatic", "on", "off"])
    }

    func testTheSettingRoundTripsThroughTheAppGroup() {
        let suite = "peard-lowdata-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = SharedStore(defaults: UserDefaults(suiteName: suite))

        XCTAssertEqual(store.lowData, .automatic)
        store.lowData = .on
        XCTAssertEqual(SharedStore(defaults: UserDefaults(suiteName: suite)).lowData, .on)
    }

    // MARK: Photo sizes

    /// Unconstrained is unchanged: lists keep the 512 they always had, and the
    /// viewer the original.
    func testNormalBehaviourIsUnchanged() {
        XCTAssertEqual(PhotoThumb.list(lowData: false), .medium)
        XCTAssertNil(PhotoThumb.viewer(lowData: false))
        XCTAssertEqual(photo.mediaThumbnailPath(), "/api/files/posts/p1/beach.jpg?thumb=512x512")
    }

    func testLowDataAsksForSmallerPhotos() {
        XCTAssertEqual(PhotoThumb.list(lowData: true), .small)
        XCTAssertEqual(PhotoThumb.viewer(lowData: true), .large)
        XCTAssertEqual(photo.mediaThumbnailPath(.small), "/api/files/posts/p1/beach.jpg?thumb=256x256")
        XCTAssertEqual(photo.mediaThumbnailPath(.large), "/api/files/posts/p1/beach.jpg?thumb=1024x1024")
    }

    /// Only sizes the `posts.media` field declares exist; any other makes the
    /// server send the original, the opposite of what low data is for.
    func testOnlyDeclaredSizesAreEverRequested() {
        XCTAssertEqual(Set(PhotoThumb.allCases.map(\.rawValue)), ["256x256", "512x512", "1024x1024"])
    }

    private var photo: Post {
        Post(id: "p1", pair: "pair1", author: "u1", type: .photo, media: "beach.jpg", created: Date())
    }
}
