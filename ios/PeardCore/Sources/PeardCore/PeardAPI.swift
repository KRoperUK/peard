import Foundation

/// The endpoint surface shared by the app and the widget.
public extension APIClient {
    // MARK: Peard routes

    /// `GET /api/peard/widget/feed?token=…` — no PocketBase session required.
    func widgetFeed(token: String) async throws -> WidgetFeed {
        let data = try await data(path: "/api/peard/widget/feed", query: ["token": token])
        do {
            return try JSONDecoder.peard.decode(WidgetFeed.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// `POST /api/peard/widget/token` (Requirement 16.1).
    func issueWidgetToken() async throws -> WidgetTokenIssue {
        try await post(path: "/api/peard/widget/token")
    }

    /// `POST /api/peard/pairs/invite` (Requirement 10.1).
    func createInvite() async throws -> PairInvite {
        try await post(path: "/api/peard/pairs/invite")
    }

    /// `POST /api/peard/pairs/accept` (Requirement 10.5).
    func acceptInvite(code: String) async throws -> PairAcceptance {
        try await post(path: "/api/peard/pairs/accept", fields: ["code": code])
    }

    /// `POST /api/peard/pairs/leave` (Requirement 15.2).
    func leavePair() async throws {
        try await postIgnoringResponse(path: "/api/peard/pairs/leave")
    }

    // MARK: Collections

    /// The pair membership of a user, most recent first (Requirement 9.3).
    func membership(forUser userID: String) async throws -> PairMember? {
        try await first(
            "pair_members",
            of: PairMember.self,
            filter: PeardFilter.equals("user", userID),
            expand: "user"
        )
    }

    /// Every member of a pair, with the user record expanded when the server's
    /// rules permit reading it.
    func members(ofPair pairID: String) async throws -> [PairMember] {
        try await list(
            "pair_members",
            of: PairMember.self,
            filter: PeardFilter.equals("pair", pairID),
            sort: nil,
            perPage: 50,
            expand: "user"
        )
    }

    /// The most recent posts of a pair (Requirement 11.1).
    func recentPosts(pairID: String, limit: Int = 5) async throws -> [Post] {
        try await list(
            "posts",
            of: Post.self,
            filter: PeardFilter.equals("pair", pairID),
            sort: "-created",
            perPage: limit
        )
    }

    /// Every `event` post of a pair, used for the tallies (Requirement 12.8).
    func eventPosts(pairID: String) async throws -> [Post] {
        try await list(
            "posts",
            of: Post.self,
            filter: PeardFilter.and(
                PeardFilter.equals("pair", pairID),
                PeardFilter.equals("type", PostType.event.rawValue)
            ),
            sort: "-created",
            perPage: 500
        )
    }

    /// Reactions recorded against a post (Requirement 14.3).
    func reactions(postID: String) async throws -> [Reaction] {
        try await list(
            "reactions",
            of: Reaction.self,
            filter: PeardFilter.equals("post", postID),
            sort: nil,
            perPage: 100
        )
    }

    // MARK: Health

    /// `GET /api/health` — used by the Debug launch probe (Requirement 21.5).
    func healthCode() async throws -> Int {
        let data = try await data(path: "/api/health")
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let code = object["code"] as? Int
        else {
            throw APIError.decoding("health response had no code")
        }
        return code
    }

    // MARK: Absolute URLs

    /// Fetches an absolute URL (the widget feed's `media_url` is already
    /// absolute, so it does not go through `baseURL`).
    static func data(from url: URL, session: URLSession? = nil) async throws -> Data {
        let session = session ?? APIClient.makeSession()
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw APIError.server(status: http.statusCode, message: nil)
            }
            return data
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }
}
