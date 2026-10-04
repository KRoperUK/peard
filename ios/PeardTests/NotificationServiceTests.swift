import PeardCore
import UIKit
import UserNotifications
import XCTest
@testable import Peard

/// The notification service extension's download-and-attach, run in-process.
///
/// `simctl push` hands a notification straight to SpringBoard without running
/// service extensions, so a simulator can never show this working end to end;
/// only a real push to a device does. What can be pinned here is everything the
/// extension itself decides.
final class NotificationServiceTests: XCTestCase {
    /// The low-data preference the service reads, kept out of the real App
    /// Group so the simulator's own setting cannot decide these tests.
    private var suiteName: String!
    private var preferences: UserDefaults!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(ImageStub.self)
        ImageStub.status = 200
        ImageStub.requests = 0
        suiteName = "peard-nse-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        URLProtocol.unregisterClass(ImageStub.self)
        // didReceive also caches for the Live Activity; leave the app's real
        // App Group as it was.
        if let cached = PhotoDropCache.url(forPost: "p1") { try? FileManager.default.removeItem(at: cached) }
        super.tearDown()
    }

    private func request(mediaURL: String?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Ada"
        content.body = "🍐 Fresh pear from Ada"
        if let mediaURL { content.userInfo = ["media_url": mediaURL, "post_id": "p1"] }
        return UNNotificationRequest(identifier: "n1", content: content, trigger: nil)
    }

    private func deliver(_ request: UNNotificationRequest) -> UNNotificationContent? {
        let service = NotificationService()
        service.preferences = preferences
        let delivered = expectation(description: "delivered")
        var result: UNNotificationContent?
        var calls = 0
        service.didReceive(request) { content in
            calls += 1
            result = content
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(calls, 1, "the content handler must be called exactly once")
        return result
    }

    func testAPhotoIsAttached() {
        let content = deliver(request(mediaURL: "https://stub.peard.test/api/files/posts/p1/pear.jpg?thumb=512x512&token=t"))

        XCTAssertEqual(content?.attachments.count, 1)
        XCTAssertEqual(content?.attachments.first?.identifier, "photo")
        XCTAssertEqual(content?.body, "🍐 Fresh pear from Ada", "the text is untouched")
    }

    /// An expired token or a deleted photo: the notification still arrives.
    func testAFailedDownloadStillDeliversTheText() {
        ImageStub.status = 403
        let content = deliver(request(mediaURL: "https://stub.peard.test/api/files/posts/p1/pear.jpg"))

        XCTAssertEqual(content?.attachments.count, 0)
        XCTAssertEqual(content?.title, "Ada")
    }

    // MARK: Low data (issue #302)

    /// "On" means no download at all: the alert arrives as text, and nothing
    /// is fetched for a picture nobody has asked to see.
    func testLowDataOnSkipsTheDownload() {
        SharedStore(defaults: preferences).lowData = .on

        let content = deliver(request(mediaURL: "https://stub.peard.test/api/files/posts/p1/pear.jpg?thumb=512x512&token=t"))

        XCTAssertEqual(content?.attachments.count, 0)
        XCTAssertEqual(content?.body, "🍐 Fresh pear from Ada")
        XCTAssertEqual(ImageStub.requests, 0, "not a byte spent on the photo")
    }

    /// "Off" and automatic still attach — automatic only refuses on a
    /// constrained network, which a test host is not on.
    func testLowDataOffAndAutomaticStillAttach() {
        SharedStore(defaults: preferences).lowData = .off
        XCTAssertEqual(deliver(request(mediaURL: "https://stub.peard.test/a.jpg"))?.attachments.count, 1)

        SharedStore(defaults: preferences).lowData = .automatic
        XCTAssertEqual(deliver(request(mediaURL: "https://stub.peard.test/b.jpg"))?.attachments.count, 1)
    }

    /// The extension spells the key and values out itself, having no
    /// PeardCore; these are what keep it reading the app's setting.
    func testTheExtensionReadsTheAppsSetting() {
        XCTAssertEqual(NotificationService.lowDataKey, SharedStore.Key.lowData)
        for preference in LowDataPreference.allCases {
            SharedStore(defaults: preferences).lowData = preference
            XCTAssertEqual(NotificationService.lowDataPreference(defaults: preferences), preference.rawValue)
        }
    }

    func testAMomentWithoutAPhotoPassesStraightThrough() {
        let content = deliver(request(mediaURL: nil))

        XCTAssertEqual(content?.attachments.count, 0)
        XCTAssertEqual(content?.body, "🍐 Fresh pear from Ada")
    }
}

/// Serves a small JPEG for the stub host, or a bare status code.
private final class ImageStub: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.peard.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        let status = Self.status
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "image/jpeg"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status == 200 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                UIColor.green.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            client?.urlProtocol(self, didLoad: image.jpegData(compressionQuality: 0.8)!)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
