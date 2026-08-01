import Foundation

/// The endpoint surface shared by the app and the widget.
public extension APIClient {
    // MARK: Peard routes

    /// `GET /api/peard/widget/feed?token=…` — no PocketBase session required.
    ///
    /// `pairID` pins the feed to one connection, which is what a configured widget
    /// asks for. Omitting it lets the server pick the liveliest.
    func widgetFeed(token: String, pairID: String? = nil) async throws -> WidgetFeed {
        var query = ["token": token]
        if let pairID, !pairID.isEmpty { query["pair"] = pairID }
        let data = try await data(path: "/api/peard/widget/feed", query: query)
        do {
            return try JSONDecoder.peard.decode(WidgetFeed.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// `GET /api/peard/widget/connections?token=…` — the choices a configurable
    /// widget offers.
    func widgetConnections(token: String) async throws -> [WidgetConnection] {
        let list: WidgetConnectionList = try await get(
            path: "/api/peard/widget/connections",
            query: ["token": token]
        )
        return list.connections
    }

    /// `POST /api/peard/widget/moment` — logs a moment straight from the widget.
    ///
    /// Authenticated with the widget token rather than the session, because the
    /// extension has no access to the Keychain. `clientID` makes the write
    /// idempotent, so a tap whose response is lost cannot double-log.
    @discardableResult
    func logWidgetMoment(
        token: String,
        kind: EventKind,
        pairID: String? = nil,
        clientID: String = UUID().uuidString
    ) async throws -> WidgetMomentResult {
        var fields = [
            "token": token,
            "kind": kind.rawValue,
            "client_id": clientID,
        ]
        if let pairID, !pairID.isEmpty { fields["pair"] = pairID }
        return try await post(path: "/api/peard/widget/moment", fields: fields)
    }

    /// `POST /api/peard/widget/token` (Requirement 16.1).
    func issueWidgetToken() async throws -> WidgetTokenIssue {
        try await post(path: "/api/peard/widget/token")
    }

    /// `POST /api/peard/pairs/invite` (Requirement 10.1). Passing `pairID`
    /// makes the invite add the accepting user to that existing connection,
    /// which is how a group grows; omitting it creates a new connection.
    func createInvite(pairID: String? = nil) async throws -> PairInvite {
        if let pairID, !pairID.isEmpty {
            return try await post(path: "/api/peard/pairs/invite", fields: ["pair": pairID])
        }
        return try await post(path: "/api/peard/pairs/invite")
    }

    /// `POST /api/peard/pairs/accept` (Requirement 10.5).
    func acceptInvite(code: String) async throws -> PairAcceptance {
        try await post(path: "/api/peard/pairs/accept", fields: ["code": code])
    }

    /// `POST /api/peard/pairs/leave` (Requirement 15.2). The connection has to
    /// be named once a user can be in several.
    ///
    /// `deleteMoments` takes the caller's own moments out of that connection's
    /// timeline on the way out. It defaults to false because leaving has always
    /// meant "my membership goes, the shared history stays" — the moments were
    /// part of somebody else's record of what happened too, and silently
    /// rewriting it would be the surprising choice. `delete_moments` goes out as
    /// a real JSON boolean: the server binds it to a Go `bool`, which rejects a
    /// quoted `"true"`.
    func leave(pairID: String, deleteMoments: Bool = false) async throws {
        try await postIgnoringResponse(
            path: "/api/peard/pairs/leave",
            typedFields: ["pair": .string(pairID), "delete_moments": .bool(deleteMoments)]
        )
    }

    /// `DELETE /api/peard/account` — erases the caller's account and everything
    /// that cascades from it.
    ///
    /// The self-serve half of the privacy policy's deletion promise, next to
    /// `/api/peard/export`. Nothing is returned worth reading: either it
    /// succeeded, or it threw.
    func deleteAccount() async throws {
        try await deleteIgnoringResponse(path: "/api/peard/account")
    }

    /// `POST /api/peard/pairs/remove` — takes somebody else out of a connection.
    ///
    /// Separate from `leave` because it needs owner authority. The `pair_members`
    /// DeleteRule is `user = @request.auth.id`, so the collection API can only
    /// ever delete your own membership.
    func removeMember(pairID: String, userID: String) async throws {
        try await postIgnoringResponse(
            path: "/api/peard/pairs/remove",
            fields: ["pair": pairID, "user": userID]
        )
    }

    /// `POST /api/peard/connections/mute` — silences one connection's pushes.
    ///
    /// `muted` goes out as a real JSON boolean: the server binds it to a Go `bool`,
    /// and a quoted `"true"` is rejected with `400 Invalid request body`.
    func setMuted(pairID: String, muted: Bool) async throws {
        try await postIgnoringResponse(
            path: "/api/peard/connections/mute",
            typedFields: ["pair": .string(pairID), "muted": .bool(muted)]
        )
    }

    /// `POST /api/peard/connections/seen` — marks this connection read up to now.
    ///
    /// The server stamps its own clock rather than accepting one from here: the
    /// stamp is compared against `posts.created`, which the server also writes,
    /// so a device clock running fast would otherwise mark moments read before
    /// they were posted.
    ///
    /// Idempotent, and called on every visit to a connection, so it is cheap by
    /// design and its failure is not worth reporting — the count simply stays up
    /// until the next visit.
    func markSeen(pairID: String) async throws {
        try await postIgnoringResponse(path: "/api/peard/connections/seen", fields: ["pair": pairID])
    }

    /// `POST /api/peard/posts/edit` — change a moment after logging it.
    ///
    /// A route rather than a record update because a PocketBase rule cannot say
    /// *which* fields may change: an UpdateRule on `posts` would also let an
    /// author move a moment into another connection or hand it to somebody who
    /// never logged it. The server writes the note and the kind, and nothing
    /// else.
    ///
    /// `nil` means "leave it alone", which is why the note is doubly optional:
    /// `.some("")` clears it, and clearing a note is a real thing to want.
    func editMoment(postID: String, note: String?? = nil, kind: EventKind? = nil) async throws {
        var fields: [String: JSONField] = ["post": .string(postID)]
        if let note { fields["note"] = .string(note ?? "") }
        if let kind { fields["event_kind"] = .string(kind.rawValue) }
        try await postIgnoringResponse(path: "/api/peard/posts/edit", typedFields: fields)
    }

    /// Deletes one of the caller's own moments.
    ///
    /// The ordinary collection endpoint, not a Pear'd route: `posts.DeleteRule`
    /// is already `author = @request.auth.id`, and a second door onto the same
    /// act would be a second place for that rule to drift. Reactions go with it
    /// — `reactions.post` cascades — and so does an attached photo.
    func deleteMoment(postID: String) async throws {
        try await delete("posts", id: postID)
    }

    /// `GET /api/peard/recap` — the last few days, and the connection's streak.
    ///
    /// The window boundary and the UTC offset are both sent, for the same reason
    /// the tallies route takes its windows from the caller: the server has no
    /// business guessing a device's time zone, and a streak is nothing but a
    /// sequence of days. A phone in Sydney and a server in London would
    /// otherwise disagree about which days those were.
    func recap(pairID: String, days: Int = 7, calendar: Calendar = .peardTally, now: Date = Date()) async throws -> MomentRecap {
        let startOfToday = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: startOfToday) ?? startOfToday
        let offsetMinutes = TimeZone.current.secondsFromGMT(for: now) / 60
        return try await get(
            path: "/api/peard/recap",
            query: [
                "pair": pairID,
                "from": ISO8601DateFormatter().string(from: from),
                "tz": String(offsetMinutes),
            ]
        )
    }

    /// `GET /api/peard/status` — which build of the server is running.
    ///
    /// Unauthenticated, so it answers before sign-in and while a session is
    /// broken — which is when somebody most wants to know what they are talking
    /// to.
    func serverStatus() async throws -> ServerStatus {
        try await get(path: "/api/peard/status")
    }

    /// `GET /api/peard/profile` — the caller's own record.
    func profile() async throws -> UserProfile {
        try await get(path: "/api/peard/profile")
    }

    /// `POST /api/peard/profile` — sets the name other members see.
    @discardableResult
    func updateDisplayName(_ name: String) async throws -> UserProfile {
        try await post(path: "/api/peard/profile", fields: ["display_name": name])
    }

    /// `POST /api/peard/contacts/match` — Pear'd accounts, among the given
    /// contact hashes, that opted into discoverability. The hashes are all
    /// this ever sends; `ContactHashing` is what produces them.
    func matchContacts(hashes: [String]) async throws -> [ContactMatch] {
        let list: ContactMatchList = try await post(
            path: "/api/peard/contacts/match",
            typedFields: ["hashes": .stringArray(hashes)]
        )
        return list.matches
    }

    /// `POST /api/peard/contacts/settings` — opts in or out of being found by
    /// contact search, optionally adding a phone number to match against
    /// too. `phone` is never required: leaving it empty still lets email
    /// matching work.
    @discardableResult
    func updateDiscoverability(discoverable: Bool, phone: String) async throws -> DiscoverabilityStatus {
        try await post(
            path: "/api/peard/contacts/settings",
            typedFields: ["discoverable": .bool(discoverable), "phone": .string(phone)]
        )
    }

    /// `POST /api/peard/profile/avatar` — sets the caller's own photo.
    ///
    /// JPEG rather than the original HEIC: the server accepts both, but a JPEG
    /// re-encode is a fraction of the bytes and every platform can decode it, and
    /// an avatar is displayed at 128 points.
    @discardableResult
    func uploadProfileAvatar(jpeg data: Data) async throws -> UserProfile {
        try await postMultipart(
            path: "/api/peard/profile/avatar",
            file: MultipartFile(
                field: "avatar",
                filename: "avatar.jpg",
                mimeType: "image/jpeg",
                data: data
            )
        )
    }

    /// `DELETE /api/peard/profile/avatar` — back to initials.
    @discardableResult
    func removeProfileAvatar() async throws -> UserProfile {
        try await delete(path: "/api/peard/profile/avatar")
    }

    /// `POST /api/peard/connections/avatar` — sets a connection's photo.
    ///
    /// Any member may, exactly as any member may rename it: the name and the face
    /// are shared property, and a group whose owner has left would otherwise be
    /// stuck with whatever picture it had.
    @discardableResult
    func uploadConnectionAvatar(pairID: String, jpeg data: Data) async throws -> ConnectionAvatar {
        try await postMultipart(
            path: "/api/peard/connections/avatar",
            fields: ["pair": pairID],
            file: MultipartFile(
                field: "avatar",
                filename: "avatar.jpg",
                mimeType: "image/jpeg",
                data: data
            )
        )
    }

    /// `DELETE /api/peard/connections/avatar?pair=…` — removes a connection's photo.
    @discardableResult
    func removeConnectionAvatar(pairID: String) async throws -> ConnectionAvatar {
        try await delete(path: "/api/peard/connections/avatar", query: ["pair": pairID])
    }

    /// `GET /api/peard/tallies?pair=…` — the connection's counts, computed
    /// server-side.
    ///
    /// The window boundaries go up with the request because they are the device's:
    /// local midnight and a Monday-start week. Letting the server assume its own
    /// would make a phone in Sydney disagree with a server in London about what
    /// "today" is.
    func tallies(
        pairID: String,
        now: Date = Date(),
        calendar: Calendar = .peardTally
    ) async throws -> ConnectionTallies {
        let dayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? dayStart
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? dayStart
        let formatter = ISO8601DateFormatter()

        return try await get(path: "/api/peard/tallies", query: [
            "pair": pairID,
            "day": formatter.string(from: dayStart),
            "week": formatter.string(from: weekStart),
            "month": formatter.string(from: monthStart),
        ])
    }

    // MARK: Collections

    /// Every connection the user belongs to, oldest first, with each one's name,
    /// role, member count and the other members' display names.
    ///
    /// `GET /api/peard/connections` — one request, and the only place member
    /// names are available: the `users` view rule stops the client reading
    /// anybody else's record directly.
    func connections() async throws -> [Connection] {
        let list: ConnectionList = try await get(path: "/api/peard/connections")
        return list.connections
    }

    /// Every membership of a user (Requirement 9.3).
    func memberships(forUser userID: String) async throws -> [PairMember] {
        try await list(
            "pair_members",
            of: PairMember.self,
            filter: PeardFilter.equals("user", userID),
            sort: nil,
            perPage: 50,
            expand: "user"
        )
    }

    /// The user's first membership, kept for callers that only need to know
    /// whether the user is in anything at all.
    func membership(forUser userID: String) async throws -> PairMember? {
        try await first(
            "pair_members",
            of: PairMember.self,
            filter: PeardFilter.equals("user", userID),
            expand: "user"
        )
    }

    /// Renames a connection. The `pairs` UpdateRule admits any member.
    @discardableResult
    func renameConnection(pairID: String, name: String) async throws -> PairRecord {
        try await update("pairs", id: pairID, of: PairRecord.self, fields: ["name": name])
    }

    /// The custom moments published to a connection.
    func momentKinds(pairID: String) async throws -> [MomentKind] {
        try await list(
            "moment_kinds",
            of: MomentKind.self,
            filter: PeardFilter.equals("pair", pairID),
            sort: "created",
            perPage: 200
        )
    }

    /// Publishes a custom moment so every member of the connection can draw it.
    @discardableResult
    func createMomentKind(
        pairID: String,
        slug: String,
        emoji: String,
        label: String,
        createdBy: String
    ) async throws -> MomentKind {
        try await create("moment_kinds", of: MomentKind.self, fields: [
            "pair": pairID,
            "slug": slug,
            "emoji": emoji,
            "label": label,
            "created_by": createdBy,
        ])
    }

    /// Removes a custom moment. Only whoever added it may.
    func deleteMomentKind(id: String) async throws {
        try await delete("moment_kinds", id: id)
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

    /// One page of a connection's timeline, newest first, with the paging
    /// metadata the history screen needs to know whether to keep going.
    ///
    /// The home screen deliberately shows only the latest few moments. This is
    /// how the rest of the shared timeline — the thing the product is actually
    /// about — becomes reachable, without ever loading it all at once.
    /// `filter` narrows it to one person, one kind of moment, or photos only.
    ///
    /// Applied in the query rather than to the loaded page, which is the whole
    /// point: the timeline is paged, so filtering what happens to be in memory
    /// would mean scrolling through a year to find last March's coffees. The
    /// `posts` list rule still scopes everything to the caller's connections,
    /// so this can only ever narrow what was already visible.
    func postsPage(
        pairID: String,
        page: Int,
        perPage: Int = 30,
        filter: TimelineFilter = .none
    ) async throws -> PostPage {
        let list: RecordList<Post> = try await get(
            path: "/api/collections/posts/records",
            query: [
                "filter": PeardFilter.and([PeardFilter.equals("pair", pairID)] + filter.clauses),
                "sort": "-created",
                "page": String(max(1, page)),
                "perPage": String(perPage),
            ]
        )
        return PostPage(
            posts: list.items,
            page: list.page ?? page,
            totalPages: list.totalPages ?? 1,
            totalItems: list.totalItems ?? list.items.count
        )
    }

    /// Every `event` post of a pair.
    ///
    /// Superseded by `tallies(pairID:)` for counting, and kept only as the
    /// fallback for a server that predates `GET /api/peard/tallies`. It cannot be
    /// used to count reliably: `perPage` caps at 500, so a connection past that
    /// many event posts silently undercounts.
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

    /// Takes back one of your own reactions.
    ///
    /// The ordinary collection endpoint: `reactions.DeleteRule` is already
    /// `user = @request.auth.id`, so the rule that decides this lives in one
    /// place and a route would only be a second one.
    func removeReaction(id: String) async throws {
        try await delete("reactions", id: id)
    }

    /// Reactions to several posts at once, for a screen showing a page of them.
    ///
    /// Chunked at ten posts a request, which is not arbitrary: PocketBase caps
    /// `perPage` at 500, and ten posts in a connection of the maximum twelve
    /// members, each having used all three reaction kinds, is 360 — comfortably
    /// under it. A single request for a whole 30-post page could reach 1080 and
    /// would silently return the first 500, which looks exactly like "nobody
    /// reacted to the older ones".
    func reactions(postIDs: [String]) async throws -> [Reaction] {
        var all: [Reaction] = []
        for chunk in stride(from: 0, to: postIDs.count, by: 10).map({
            Array(postIDs[$0..<min($0 + 10, postIDs.count)])
        }) {
            all += try await list(
                "reactions",
                of: Reaction.self,
                filter: PeardFilter.anyEquals("post", chunk),
                sort: nil,
                perPage: 500
            )
        }
        return all
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
