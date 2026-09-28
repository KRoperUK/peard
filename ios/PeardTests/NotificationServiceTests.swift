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
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(ImageStub.self)
        ImageStub.status = 200
    }

    override func tearDown() {
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

    func testAMomentWithoutAPhotoPassesStraightThrough() {
        let content = deliver(request(mediaURL: nil))

        XCTAssertEqual(content?.attachments.count, 0)
        XCTAssertEqual(content?.body, "🍐 Fresh pear from Ada")
    }
}

/// Serves a small JPEG for the stub host, or a bare status code.
private final class ImageStub: URLProtocol {
    nonisolated(unsafe) static var status = 200

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.peard.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
