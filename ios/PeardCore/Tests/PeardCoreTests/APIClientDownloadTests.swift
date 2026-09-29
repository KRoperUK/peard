import XCTest
@testable import PeardCore

/// `APIClient.download`, which the export with photos goes through.
final class APIClientDownloadTests: XCTestCase {
    private var client: APIClient!
    private var destination: URL!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        client = APIClient(
            baseURL: URL(string: "http://127.0.0.1:8090")!,
            tokenProvider: StubTokenProvider(token: "test-token"),
            session: StubURLProtocol.makeSession()
        )
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("peard-download-\(UUID().uuidString).zip")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: destination)
        StubURLProtocol.reset()
        client = nil
        super.tearDown()
    }

    func testTheBodyLandsAtTheDestination() async throws {
        StubURLProtocol.respond(json: "PK-not-really-a-zip")

        try await client.download(path: "/api/peard/export", query: ["media": "zip"], to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("PK-not-really-a-zip".utf8))
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/peard/export")
        XCTAssertEqual(request.url?.query, "media=zip")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "test-token")
    }

    func testAnExistingFileAtTheDestinationIsReplaced() async throws {
        try Data("old".utf8).write(to: destination)
        StubURLProtocol.respond(json: "new")

        try await client.download(path: "/api/peard/export", to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
    }

    func testErrorsMapLikeAnyOtherRequest() async {
        StubURLProtocol.respond(json: #"{"message":"Too many requests."}"#, status: 429)
        do {
            try await client.download(path: "/api/peard/export", to: destination)
            XCTFail("expected a server error")
        } catch let error as APIError {
            guard case .server(status: 429, message: "Too many requests.") = error else {
                return XCTFail("got \(error)")
            }
        } catch {
            XCTFail("got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a failed download leaves nothing behind")

        StubURLProtocol.respond(json: "{}", status: 401)
        do {
            try await client.download(path: "/api/peard/export", to: destination)
            XCTFail("expected unauthorized")
        } catch let error as APIError {
            guard case .unauthorized = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("got \(error)")
        }
    }
}
