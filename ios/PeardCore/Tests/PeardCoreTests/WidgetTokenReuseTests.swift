import XCTest
@testable import PeardCore

final class WidgetTokenReuseTests: XCTestCase {
    /// A fake service that records calls and plays back scripted results, so the
    /// reuse decision is exercised without a live APIClient (#381).
    private final class FakeService: WidgetTokenService, @unchecked Sendable {
        var liveIDs: [String] = []
        var listError: Error?
        var mintResult = WidgetTokenIssue(id: "new-id", token: "new-secret")
        var mintError: Error?

        private(set) var mintCalls = 0
        private(set) var listCalls = 0
        private(set) var mintedLabel: String??

        func issueWidgetToken(label: String?) async throws -> WidgetTokenIssue {
            mintCalls += 1
            mintedLabel = label
            if let mintError { throw mintError }
            return mintResult
        }

        func widgetTokens(currentTokenID _: String?) async throws -> [WidgetTokenInfo] {
            listCalls += 1
            if let listError { throw listError }
            return liveIDs.map { WidgetTokenInfo(id: $0) }
        }
    }

    private struct DummyError: Error {}

    func testHeldAndLiveTokenIsReusedWithoutMinting() async throws {
        let service = FakeService()
        service.liveIDs = ["held-id", "someone-else"]

        let outcome = try await WidgetTokenReuse.resolve(
            heldToken: "held-secret", heldID: "held-id", service: service
        )

        XCTAssertEqual(outcome, .reused)
        XCTAssertEqual(service.mintCalls, 0, "a live held token must not mint")
        XCTAssertEqual(service.listCalls, 1)
    }

    func testHeldButGoneTokenMints() async throws {
        let service = FakeService()
        service.liveIDs = ["a-different-live-id"] // held-id is absent -> revoked/expired

        let outcome = try await WidgetTokenReuse.resolve(
            heldToken: "held-secret", heldID: "held-id", service: service
        )

        XCTAssertEqual(outcome, .minted(id: "new-id", token: "new-secret"))
        XCTAssertEqual(service.mintCalls, 1)
    }

    func testNothingHeldMints() async throws {
        let service = FakeService()

        let outcome = try await WidgetTokenReuse.resolve(
            heldToken: nil, heldID: nil, service: service
        )

        XCTAssertEqual(outcome, .minted(id: "new-id", token: "new-secret"))
        XCTAssertEqual(service.mintCalls, 1)
        XCTAssertEqual(service.listCalls, 0, "no held id means no liveness check")
    }

    // The device label (#379) is threaded to the mint, so a fresh row is named.
    func testDeviceLabelIsPassedToTheMint() async throws {
        let service = FakeService()

        _ = try await WidgetTokenReuse.resolve(
            heldToken: nil, heldID: nil, label: "iPad", service: service
        )

        XCTAssertEqual(service.mintedLabel, "iPad")
    }

    func testEmptyStringsCountAsNothingHeld() async throws {
        let service = FakeService()

        let outcome = try await WidgetTokenReuse.resolve(
            heldToken: "", heldID: "", service: service
        )

        XCTAssertEqual(outcome, .minted(id: "new-id", token: "new-secret"))
        XCTAssertEqual(service.listCalls, 0)
    }

    func testLivenessCheckFailureReusesHeldToken() async throws {
        let service = FakeService()
        service.listError = DummyError() // transient network blip

        let outcome = try await WidgetTokenReuse.resolve(
            heldToken: "held-secret", heldID: "held-id", service: service
        )

        XCTAssertEqual(outcome, .reused, "a transient list failure must not mint a redundant row")
        XCTAssertEqual(service.mintCalls, 0)
    }

    func testMintFailureRethrows() async {
        let service = FakeService()
        service.mintError = DummyError()

        do {
            _ = try await WidgetTokenReuse.resolve(heldToken: nil, heldID: nil, service: service)
            XCTFail("a mint failure should propagate to the opportunistic caller")
        } catch {
            // expected
        }
    }
}
