import XCTest
@testable import PeardCore

/// Cancellation is not a failure, and the client has to say so.
///
/// Reported from a real device: pulling to refresh the timeline emptied it and
/// captioned the empty state "cancelled". SwiftUI cancels the task behind
/// `.refreshable` the moment the control retracts, URLSession reports that as an
/// error like any other, and it was folded in with genuine transport failures —
/// so a request that had simply stopped mattering was shown to the user as
/// though the server had said it.
final class CancellationTests: XCTestCase {
    private var client: APIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        client = APIClient(
            baseURL: URL(string: "http://127.0.0.1:8090")!,
            tokenProvider: StubTokenProvider(token: "test-token"),
            session: StubURLProtocol.makeSession()
        )
    }

    override func tearDown() {
        StubURLProtocol.reset()
        client = nil
        super.tearDown()
    }

    func testACancelledRequestIsItsOwnKindOfError() async {
        StubURLProtocol.failWith(URLError(.cancelled))

        do {
            _ = try await client.list("posts", of: Post.self)
            XCTFail("expected a failure")
        } catch let error as APIError {
            XCTAssertTrue(error.isCancellation)
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("expected an APIError, got \(error)")
        }
    }

    /// The distinction that matters: a real network failure is still a failure,
    /// and must not be silenced along with cancellations.
    func testATransportFailureIsNotACancellation() async {
        StubURLProtocol.failWith(URLError(.notConnectedToInternet))

        do {
            _ = try await client.list("posts", of: Post.self)
            XCTFail("expected a failure")
        } catch let error as APIError {
            XCTAssertFalse(error.isCancellation)
        } catch {
            XCTFail("expected an APIError, got \(error)")
        }
    }

    func testOnlyCancellationReportsItself() {
        XCTAssertTrue(APIError.cancelled.isCancellation)
        for other: APIError in [
            .invalidURL,
            .unauthorized(message: nil),
            .server(status: 500, message: nil),
            .transport("offline"),
            .decoding("bad json"),
        ] {
            XCTAssertFalse(other.isCancellation, "\(other) is not a cancellation")
        }
    }

    /// Nothing should render this, but if something does it must not be the bare
    /// word that appeared under "Nothing here yet".
    func testItStillHasAnHonestDescription() {
        let description = APIError.cancelled.localizedDescription

        XCTAssertFalse(description.isEmpty)
        XCTAssertNotEqual(description.lowercased(), "cancelled")
    }

    /// A cancelled send is retryable. The moment may or may not have been
    /// written, `client_id` makes the write idempotent so a retry cannot
    /// duplicate it, and the alternative is losing something somebody logged.
    func testACancelledSendIsRetriedRatherThanDiscarded() {
        let failure = SendFailure.classify(APIError.cancelled)

        switch failure {
        case .retryable:
            break
        case .permanent(let message):
            XCTFail("a cancelled send must not be discarded (\(message))")
        }
    }
}
