import XCTest
@testable import PeardCore

/// Requirement 5 — request shapes, error mapping, escaping at the call sites.
final class APIClientTests: XCTestCase {
    private var client: APIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        client = APIClient(
            baseURL: URL(string: "http://127.0.0.1:8090")!,
            tokenProvider: StubTokenProvider(token: "test-token"),
            session: StubURLProtocol.makeSession(),
            boundaryFactory: { "TestBoundary" }
        )
    }

    override func tearDown() {
        StubURLProtocol.reset()
        client = nil
        super.tearDown()
    }

    // MARK: Requests

    func testListSendsFilterSortAndPerPage() async throws {
        StubURLProtocol.respond(json: #"{"page":1,"perPage":5,"totalItems":0,"totalPages":0,"items":[]}"#)

        _ = try await client.list("posts", of: Post.self, filter: #"pair = "p1""#, sort: "-created", perPage: 5)

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.path, "/api/collections/posts/records")
        XCTAssertEqual(items["filter"], #"pair = "p1""#)
        XCTAssertEqual(items["sort"], "-created")
        XCTAssertEqual(items["perPage"], "5")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "test-token")
    }

    func testFirstRequestsOnePageSortedByCreatedDescending() async throws {
        StubURLProtocol.respond(json: #"{"items":[]}"#)

        let member = try await client.first("pair_members", of: PairMember.self, filter: #"user = "u1""#)

        XCTAssertNil(member)
        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(StubURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false
        ))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["perPage"], "1")
        XCTAssertEqual(items["sort"], "-created")
    }

    func testCreateSendsJSONContentType() async throws {
        StubURLProtocol.respond(json: #"""
        {"id":"p1","pair":"pair1","author":"u1","type":"event","event_kind":"beer","note":"",
         "media":"","created":"2026-07-28 21:30:15.250Z"}
        """#)

        let post: Post = try await client.create("posts", fields: [
            "pair": "pair1", "author": "u1", "type": "event", "event_kind": "beer", "note": "hi",
        ])

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(post.id, "p1")

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(decoded["pair"], "pair1")
        XCTAssertEqual(decoded["note"], "hi")
    }

    func testMultipartBodyCarriesFieldsAndFile() throws {
        let body = APIClient.multipartBody(
            fields: ["pair": "pair1", "author": "u1", "type": "photo"],
            file: MultipartFile(field: "media", filename: "pear.jpg", mimeType: "image/jpeg", data: Data([0xFF, 0xD8])),
            boundary: "TestBoundary"
        )
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("--TestBoundary\r\n"))
        XCTAssertTrue(text.contains(#"Content-Disposition: form-data; name="pair""#))
        XCTAssertTrue(text.contains(#"Content-Disposition: form-data; name="author""#))
        XCTAssertTrue(text.contains(#"Content-Disposition: form-data; name="type""#))
        XCTAssertTrue(text.contains(#"name="media"; filename="pear.jpg""#))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(text.hasSuffix("\r\n--TestBoundary--\r\n"))
    }

    func testCreateMultipartSetsBoundaryHeader() async throws {
        StubURLProtocol.respond(json: #"""
        {"id":"p1","pair":"pair1","author":"u1","type":"photo","event_kind":"","note":"",
         "media":"pear.jpg","created":"2026-07-28 21:30:15.250Z"}
        """#)

        let post: Post = try await client.createMultipart(
            "posts",
            fields: ["pair": "pair1", "author": "u1", "type": "photo"],
            file: MultipartFile(field: "media", filename: "pear.jpg", mimeType: "image/jpeg", data: Data([0xFF]))
        )

        XCTAssertEqual(
            StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type"),
            "multipart/form-data; boundary=TestBoundary"
        )
        XCTAssertTrue(post.hasMedia)
    }

    func testDeleteUsesDeleteMethod() async throws {
        StubURLProtocol.respond(json: "", status: 204)
        try await client.delete("devices", id: "d1")

        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/collections/devices/records/d1")
    }

    func testUpdateUsesPatchMethod() async throws {
        StubURLProtocol.respond(json: #"{"id":"d1","user":"u1","platform":"ios","push_token":"abc"}"#)
        let _: Device = try await client.update("devices", id: "d1", fields: ["push_token": "abc"])

        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "PATCH")
    }

    func testRequestTimeoutIsThirtySeconds() async throws {
        StubURLProtocol.respond(json: #"{"items":[]}"#)
        _ = try await client.list("posts", of: Post.self)

        XCTAssertEqual(StubURLProtocol.lastRequest?.timeoutInterval, 30)
        XCTAssertEqual(APIClient.timeout, 30)
    }

    func testNoAuthorizationHeaderWithoutAToken() async throws {
        let anonymous = APIClient(
            baseURL: URL(string: "http://127.0.0.1:8090")!,
            tokenProvider: nil,
            session: StubURLProtocol.makeSession()
        )
        StubURLProtocol.respond(json: #"{"state":"unpaired"}"#)

        _ = try await anonymous.widgetFeed(token: "widget-token")

        XCTAssertNil(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(StubURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false
        ))
        XCTAssertEqual(components.path, "/api/peard/widget/feed")
        XCTAssertEqual(components.queryItems?.first { $0.name == "token" }?.value, "widget-token")
    }

    // MARK: Errors

    func testServerErrorPrefersMessageField() async throws {
        StubURLProtocol.respond(json: #"{"code":400,"message":"already pear'd","data":{}}"#, status: 400)

        do {
            _ = try await client.acceptInvite(code: "ABC123")
            XCTFail("expected failure")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.serverMessage, "already pear'd")
            XCTAssertEqual(error.errorDescription, "already pear'd")
        }
    }

    func testServerErrorFallsBackToStatusCode() async throws {
        StubURLProtocol.respond(json: #"{"code":500}"#, status: 500)

        do {
            _ = try await client.createInvite()
            XCTFail("expected failure")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 500)
            XCTAssertNil(error.serverMessage)
            XCTAssertEqual(error.errorDescription, "Request failed (500).")
        }
    }

    func testUnauthorizedIsDistinguishable() async throws {
        StubURLProtocol.respond(json: #"{"code":401,"message":"The request requires valid record authorization token."}"#, status: 401)

        do {
            _ = try await client.recentPosts(pairID: "p1")
            XCTFail("expected failure")
        } catch let error as APIError {
            guard case .unauthorized = error else {
                return XCTFail("expected .unauthorized, got \(error)")
            }
            XCTAssertEqual(error.status, 401)
        }
    }

    func testTransportFailureIsReported() async throws {
        StubURLProtocol.failWith(URLError(.cannotConnectToHost))

        do {
            _ = try await client.recentPosts(pairID: "p1")
            XCTFail("expected failure")
        } catch let error as APIError {
            guard case .transport = error else {
                return XCTFail("expected .transport, got \(error)")
            }
        }
    }

    func testUndecodableSuccessBodyIsADecodingError() async throws {
        StubURLProtocol.respond(json: #"{"unexpected":true}"#)

        do {
            _ = try await client.createInvite()
            XCTFail("expected failure")
        } catch let error as APIError {
            guard case .decoding = error else {
                return XCTFail("expected .decoding, got \(error)")
            }
        }
    }

    // MARK: Call-site escaping

    func testEventPostsFilterEscapesThePairIdentifier() async throws {
        StubURLProtocol.respond(json: #"{"items":[]}"#)

        _ = try await client.eventPosts(pairID: #"p1" || type = ""#)

        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(StubURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false
        ))
        let filter = try XCTUnwrap(components.queryItems?.first { $0.name == "filter" }?.value)
        XCTAssertEqual(filter, #"pair = "p1\" || type = \"" && type = "event""#)
    }

    func testMembershipRequestsExpandedUser() async throws {
        StubURLProtocol.respond(json: #"{"items":[]}"#)

        _ = try await client.membership(forUser: "u1")

        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(StubURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false
        ))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["expand"], "user")
        XCTAssertEqual(items["filter"], #"user = "u1""#)
    }

    func testHealthCodeIsParsed() async throws {
        StubURLProtocol.respond(json: #"{"code":200,"message":"API is healthy."}"#)
        let code = try await client.healthCode()
        XCTAssertEqual(code, 200)
    }
}

// MARK: - Test doubles

// Shared with the other suites that need a client, like `StubURLProtocol`
// beneath it. Private here meant every new suite either reached for a different
// double or copied this one.
final class StubTokenProvider: AuthTokenProviding, @unchecked Sendable {
    let authToken: String?
    init(token: String?) { self.authToken = token }
}

final class StubURLProtocol: URLProtocol {
    private struct Stub {
        var status: Int
        var body: Data
        var error: Error?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stub = Stub(status: 200, body: Data(), error: nil)
    nonisolated(unsafe) private static var capturedRequest: URLRequest?
    nonisolated(unsafe) private static var capturedBody: Data?
    /// How many requests have been served since the last reset. Needed by
    /// anything that batches: "the filter looked right" says nothing about
    /// whether it was sent once or thirty times.
    nonisolated(unsafe) private static var served = 0

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.timeoutIntervalForRequest = APIClient.timeout
        return URLSession(configuration: configuration)
    }

    static func respond(json: String, status: Int = 200) {
        lock.lock()
        stub = Stub(status: status, body: Data(json.utf8), error: nil)
        lock.unlock()
    }

    static func failWith(_ error: Error) {
        lock.lock()
        stub = Stub(status: 0, body: Data(), error: error)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        stub = Stub(status: 200, body: Data(), error: nil)
        capturedRequest = nil
        capturedBody = nil
        served = 0
        lock.unlock()
    }

    static var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequest
    }

    static var lastBody: Data? {
        lock.lock()
        defer { lock.unlock() }
        return capturedBody
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return served
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.served += 1
        Self.capturedRequest = request
        // URLSession strips httpBody from the protocol's request, so read the
        // stream when present.
        Self.capturedBody = request.httpBody ?? request.httpBodyStream.map(Self.drain)
        let stub = Self.stub
        Self.lock.unlock()

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
