import Foundation

// MARK: - Errors

public enum APIError: Error, LocalizedError, Hashable {
    /// The base URL and path could not be combined into a valid URL.
    case invalidURL
    /// Status 401 — the caller should clear the session (Requirement 8.4).
    case unauthorized(message: String?)
    /// Any other non-2xx status (Requirement 5.6).
    case server(status: Int, message: String?)
    /// The request never produced a response (Requirement 5.7).
    case transport(String)
    /// A 2xx response whose body could not be decoded.
    case decoding(String)

    public var status: Int? {
        switch self {
        case .unauthorized: return 401
        case .server(let status, _): return status
        default: return nil
        }
    }

    /// Server-reported message when there was one.
    public var serverMessage: String? {
        switch self {
        case .unauthorized(let message), .server(_, let message): return message
        default: return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The server URL is not valid."
        case .unauthorized(let message):
            return message ?? "Your session has expired."
        case .server(let status, let message):
            return message ?? "Request failed (\(status))."
        case .transport(let description):
            return description
        case .decoding(let description):
            return "Unexpected response from the server. \(description)"
        }
    }
}

// MARK: - Typed request fields

/// A JSON value in a request body.
///
/// Exists because the client could originally only encode `[String: String]`, so a
/// boolean field went out as `"muted": "true"` — a JSON *string* — and any route
/// that binds it to a Go `bool` answered `400 Invalid request body`. The
/// collection API is forgiving about that; the custom `/api/peard/*` routes are
/// not, and the failure was silent from the UI's point of view.
public enum JSONField: Hashable, Sendable, Encodable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case stringArray([String])
    case null

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .stringArray(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONField: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
}

// MARK: - Token provider

/// Supplies the PocketBase auth token for authenticated requests.
public protocol AuthTokenProviding: AnyObject, Sendable {
    var authToken: String? { get }
}

// MARK: - Multipart

public struct MultipartFile: Hashable, Sendable {
    public let field: String
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(field: String, filename: String, mimeType: String, data: Data) {
        self.field = field
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

// MARK: - Client

/// Typed access to PocketBase collections and the custom `/api/peard/*` routes.
public final class APIClient: Sendable {
    public static let timeout: TimeInterval = 30

    public let baseURL: URL
    private let session: URLSession
    private let tokenProvider: AuthTokenProviding?
    private let boundaryFactory: @Sendable () -> String

    public init(
        baseURL: URL,
        tokenProvider: AuthTokenProviding? = nil,
        session: URLSession? = nil,
        boundaryFactory: (@Sendable () -> String)? = nil
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session ?? APIClient.makeSession()
        self.boundaryFactory = boundaryFactory ?? { "PeardBoundary-\(UUID().uuidString)" }
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    // MARK: Records

    /// `GET /api/collections/{collection}/records` (Requirement 5.2).
    public func list<Item: Codable & Hashable & Sendable>(
        _ collection: String,
        of _: Item.Type = Item.self,
        filter: String? = nil,
        sort: String? = "-created",
        perPage: Int = 100,
        expand: String? = nil
    ) async throws -> [Item] {
        var query: [String: String] = ["perPage": String(perPage)]
        if let filter, !filter.isEmpty { query["filter"] = filter }
        if let sort, !sort.isEmpty { query["sort"] = sort }
        if let expand, !expand.isEmpty { query["expand"] = expand }

        let list: RecordList<Item> = try await send(
            method: "GET",
            path: "/api/collections/\(collection)/records",
            query: query
        )
        return list.items
    }

    /// The single most recent matching record, or `nil` (Requirement 5.3).
    public func first<Item: Codable & Hashable & Sendable>(
        _ collection: String,
        of type: Item.Type = Item.self,
        filter: String? = nil,
        expand: String? = nil
    ) async throws -> Item? {
        try await list(collection, of: type, filter: filter, sort: "-created", perPage: 1, expand: expand).first
    }

    /// `POST /api/collections/{collection}/records` with a JSON body
    /// (Requirement 5.4).
    @discardableResult
    public func create<Item: Codable & Hashable & Sendable>(
        _ collection: String,
        of _: Item.Type = Item.self,
        fields: [String: String]
    ) async throws -> Item {
        try await send(
            method: "POST",
            path: "/api/collections/\(collection)/records",
            body: .json(fields)
        )
    }

    /// `PATCH /api/collections/{collection}/records/{id}`.
    @discardableResult
    public func update<Item: Codable & Hashable & Sendable>(
        _ collection: String,
        id: String,
        of _: Item.Type = Item.self,
        fields: [String: String]
    ) async throws -> Item {
        try await send(
            method: "PATCH",
            path: "/api/collections/\(collection)/records/\(id)",
            body: .json(fields)
        )
    }

    /// `POST /api/collections/posts/records` as multipart (Requirement 5.5).
    @discardableResult
    public func createMultipart<Item: Codable & Hashable & Sendable>(
        _ collection: String,
        of _: Item.Type = Item.self,
        fields: [String: String],
        file: MultipartFile
    ) async throws -> Item {
        try await send(
            method: "POST",
            path: "/api/collections/\(collection)/records",
            body: .multipart(fields: fields, file: file)
        )
    }

    /// `DELETE /api/collections/{collection}/records/{id}`.
    public func delete(_ collection: String, id: String) async throws {
        _ = try await sendReturningData(
            method: "DELETE",
            path: "/api/collections/\(collection)/records/\(id)",
            query: [:],
            body: nil
        )
    }

    // MARK: Custom routes

    /// `GET` an arbitrary path (the `/api/peard/*` routes).
    public func get<Item: Codable & Hashable & Sendable>(
        path: String,
        of _: Item.Type = Item.self,
        query: [String: String] = [:]
    ) async throws -> Item {
        try await send(method: "GET", path: path, query: query)
    }

    /// `POST` to an arbitrary path (the `/api/peard/*` routes).
    @discardableResult
    public func post<Item: Codable & Hashable & Sendable>(
        path: String,
        of _: Item.Type = Item.self,
        fields: [String: String]? = nil
    ) async throws -> Item {
        try await send(method: "POST", path: path, body: fields.map { .json($0) })
    }

    /// `POST` to an arbitrary path, discarding the response body.
    public func postIgnoringResponse(path: String, fields: [String: String]? = nil) async throws {
        _ = try await sendReturningData(
            method: "POST",
            path: path,
            query: [:],
            body: fields.map { .json($0) }
        )
    }

    /// `POST` with real JSON types, for routes that bind a boolean or a number.
    @discardableResult
    public func post<Item: Codable & Hashable & Sendable>(
        path: String,
        of _: Item.Type = Item.self,
        typedFields: [String: JSONField]
    ) async throws -> Item {
        try await send(method: "POST", path: path, body: .typedJSON(typedFields))
    }

    /// `POST` with real JSON types, discarding the response body.
    public func postIgnoringResponse(path: String, typedFields: [String: JSONField]) async throws {
        _ = try await sendReturningData(
            method: "POST",
            path: path,
            query: [:],
            body: .typedJSON(typedFields)
        )
    }

    /// `POST` multipart to an arbitrary path (the `/api/peard/*` routes).
    ///
    /// Distinct from `createMultipart`, which targets a collection. The avatar
    /// routes need this because a file cannot travel in a JSON body and the
    /// collection API is not the write path for either `users` or `pairs`.
    @discardableResult
    public func postMultipart<Item: Codable & Hashable & Sendable>(
        path: String,
        of _: Item.Type = Item.self,
        fields: [String: String] = [:],
        file: MultipartFile
    ) async throws -> Item {
        try await send(method: "POST", path: path, body: .multipart(fields: fields, file: file))
    }

    /// `DELETE` an arbitrary path, decoding the response.
    ///
    /// A DELETE carries no body, so anything it needs to name goes in the query.
    @discardableResult
    public func delete<Item: Codable & Hashable & Sendable>(
        path: String,
        of _: Item.Type = Item.self,
        query: [String: String] = [:]
    ) async throws -> Item {
        try await send(method: "DELETE", path: path, query: query)
    }

    /// `DELETE` an arbitrary path, discarding the response body.
    public func deleteIgnoringResponse(path: String, query: [String: String] = [:]) async throws {
        _ = try await sendReturningData(method: "DELETE", path: path, query: query, body: nil)
    }

    /// Raw `GET`, used for the widget feed image and the debug health probe.
    public func data(path: String, query: [String: String] = [:]) async throws -> Data {
        try await sendReturningData(method: "GET", path: path, query: query, body: nil)
    }

    // MARK: Plumbing

    private enum Body {
        case json([String: String])
        /// A body with real JSON types, for routes that bind booleans or numbers.
        case typedJSON([String: JSONField])
        case multipart(fields: [String: String], file: MultipartFile)
    }

    private func send<Response: Decodable>(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: Body? = nil
    ) async throws -> Response {
        let data = try await sendReturningData(method: method, path: path, query: query, body: body)
        if data.isEmpty, let empty = EmptyResponse() as? Response { return empty }
        do {
            return try JSONDecoder.peard.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    private func sendReturningData(
        method: String,
        path: String,
        query: [String: String],
        body: Body?
    ) async throws -> Data {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = APIClient.timeout
        if let token = tokenProvider?.authToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }

        switch body {
        case .json(let fields):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(fields)
        case .typedJSON(let fields):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(fields)
        case .multipart(let fields, let file):
            let boundary = boundaryFactory()
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = APIClient.multipartBody(fields: fields, file: file, boundary: boundary)
        case nil:
            break
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.transport(error.localizedDescription)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("The server sent a response that was not HTTP.")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = APIClient.errorMessage(in: data)
            if http.statusCode == 401 {
                throw APIError.unauthorized(message: message)
            }
            throw APIError.server(status: http.statusCode, message: message)
        }
        return data
    }

    /// Extracts PocketBase's `message` field when present (Requirement 5.6),
    /// preferring its per-field detail when there is any.
    ///
    /// A rejected write answers with a generic top-level message and the actual
    /// reason underneath it:
    ///
    ///     { "message": "Failed to create record.",
    ///       "data": { "email": { "message": "Value must be unique." } } }
    ///
    /// Only the top-level string used to survive, so every validation failure in
    /// the app read "Failed to create record." — which names neither the field
    /// nor the problem, and is the same sentence whether the address was taken
    /// or the password too short. The field detail is what the caller can act
    /// on, so it wins; the field name is kept with it because "Value must be
    /// unique." alone does not say which value.
    static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let message = (object["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let detail = fieldErrorDetail(in: object) else { return message }
        return detail
    }

    /// "email: Value must be unique." for the first field PocketBase complained
    /// about, sorted so the same failure always reads the same way.
    private static func fieldErrorDetail(in object: [String: Any]) -> String? {
        guard let data = object["data"] as? [String: Any], !data.isEmpty else { return nil }
        for field in data.keys.sorted() {
            guard
                let entry = data[field] as? [String: Any],
                let message = entry["message"] as? String,
                !message.isEmpty
            else { continue }
            return "\(field): \(message)"
        }
        return nil
    }

    static func multipartBody(fields: [String: String], file: MultipartFile, boundary: String) -> Data {
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }
        for key in fields.keys.sorted() {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(fields[key] ?? "")\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.filename)\"\r\n")
        append("Content-Type: \(file.mimeType)\r\n\r\n")
        body.append(file.data)
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}

/// Placeholder for endpoints that answer with an empty body.
public struct EmptyResponse: Codable, Hashable, Sendable {
    public init() {}
}
