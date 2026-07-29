import XCTest
@testable import Peard
import PeardCore
import UIKit

/// The avatar work that cannot live in PeardCore.
///
/// Deriving initials, colours and paths is pure and covered by `AvatarTests` there.
/// What needs the app target is the two places a photo is resolved from live model
/// state — the timeline's per-author lookup and the home screen's fallbacks — and
/// the resize, which is UIKit.
@MainActor
final class AvatarResolutionTests: XCTestCase {
    private let serverURL = URL(string: "http://127.0.0.1:8090")!

    // MARK: Timeline authors

    private func historyModel(connection: Connection?) -> HistoryModel {
        HistoryModel(
            api: APIClient(baseURL: serverURL),
            pairID: "pair1",
            signedInUserID: "me",
            customKinds: [],
            connection: connection
        )
    }

    private var connection: Connection {
        Connection(
            pair: "pair1",
            name: "Flatmates",
            memberCount: 3,
            members: [
                .init(user: "me", name: "Me", role: .owner, isYou: true),
                .init(user: "ari", name: "Ari Bloom", avatarFilename: "ari.jpg"),
                .init(user: "bo", name: "Bo"),
            ]
        )
    }

    func testAuthorAvatarComesFromTheMemberList() {
        let model = historyModel(connection: connection)
        let avatar = model.avatar(forAuthor: "ari")
        XCTAssertEqual(avatar.path(), "/api/files/users/ari/ari.jpg?thumb=128x128")
    }

    func testMemberWithoutAPhotoDrawsTheirInitials() {
        let model = historyModel(connection: connection)
        let avatar = model.avatar(forAuthor: "bo")
        XCTAssertFalse(avatar.hasImage)
        XCTAssertEqual(avatar.placeholder.initials, "B")
    }

    /// A post by somebody who has left stays in the shared timeline, and they are no
    /// longer in the member list — so there is no photo to find. It has to fall back
    /// rather than build a path to a file that will 404, and the initials must match
    /// the neutral name `authorLabel` gives them.
    func testFormerMemberFallsBackToTheNeutralPlaceholder() {
        let model = historyModel(connection: connection)
        let avatar = model.avatar(forAuthor: "departed")
        XCTAssertFalse(avatar.hasImage)
        XCTAssertNil(avatar.path())
        XCTAssertEqual(avatar.placeholder.initials, AvatarInitials.derive(from: PartnerLabel.unknown))
        XCTAssertEqual(model.authorLabel(for: post(by: "departed")), PartnerLabel.unknown)
    }

    /// Reached before the connection list has loaded, which is the first frame of a
    /// cold launch.
    func testAuthorAvatarWithNoConnectionAtAllIsStillDrawable() {
        let model = historyModel(connection: nil)
        let avatar = model.avatar(forAuthor: "ari")
        XCTAssertFalse(avatar.hasImage)
        XCTAssertFalse(avatar.placeholder.initials.isEmpty)
    }

    private func post(by author: String) -> Post {
        Post(id: "p1", pair: "pair1", author: author, type: .event, eventKind: .beer, created: Date())
    }

    // MARK: Home screen fallbacks

    /// `HomeModel` resolves its connection out of `AppModel`, which is empty until
    /// the list loads. The rail and the settings screen both draw an avatar on that
    /// first frame, so the fallback has to be a real placeholder rather than a path
    /// built from an empty filename.
    func testConnectionAvatarBeforeTheListLoads() async {
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peard-avatar-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let app = AppModel(sendQueue: SendQueue(store: FilePendingSendStore(url: storeURL)))
        let model = HomeModel(app: app, pairID: "pair1")

        XCTAssertNil(model.connection)
        XCTAssertFalse(model.connectionAvatar.hasImage)
        XCTAssertNil(model.connectionAvatar.path())
        XCTAssertEqual(model.connectionAvatar.owner, .pairs)
        XCTAssertEqual(model.connectionAvatar.recordID, "pair1")
        XCTAssertFalse(
            model.connectionHasOwnAvatar,
            "removal must not be offered for a photo that is not known to exist"
        )
        XCTAssertFalse(model.avatar(forAuthor: "someone").hasImage)
    }

    // MARK: Resizing

    func testResizeProducesASquareAtTheDeclaredThumbSize() {
        let wide = image(width: 1600, height: 900)
        let cropped = AvatarImage.squareCropped(wide)
        XCTAssertEqual(cropped.size.width, AvatarImage.maxDimension)
        XCTAssertEqual(cropped.size.height, AvatarImage.maxDimension)
    }

    /// The point of resizing is the byte count: the route's ceiling is 8 MB and a
    /// phone photo is comfortably several. A 4000×3000 source has to come out small
    /// enough that the upload cannot be rejected for size.
    func testResizeBringsAPhoneSizedPhotoWellUnderTheUploadLimit() throws {
        let large = image(width: 4000, height: 3000)
        let data = try XCTUnwrap(AvatarImage.jpegData(from: large))
        XCTAssertLessThan(data.count, 1 << 20, "512-point JPEG came out at \(data.count) bytes")
        XCTAssertFalse(data.isEmpty)

        let decoded = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(decoded.size.width, AvatarImage.maxDimension)
        XCTAssertEqual(decoded.size.height, AvatarImage.maxDimension)
    }

    func testResizeUpscalesASmallSourceRatherThanLeavingItTiny() {
        // A 64-point avatar drawn into a 512-point thumb would be blurry either way,
        // but the stored image has to be the size the thumb expects or PocketBase
        // serves the original for one subject and a thumb for another.
        let small = image(width: 64, height: 64)
        XCTAssertEqual(AvatarImage.squareCropped(small).size.width, AvatarImage.maxDimension)
    }

    private func image(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}
