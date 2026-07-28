import XCTest
@testable import PeardCore

/// Requirement 24.6 — signs in against a local Peard'd server and creates one
/// `event` post.
///
/// Skipped unless `PEARD_TEST_SERVER_URL` is set, so the default `swift test`
/// run needs no server:
///
///     cd server && go run . serve --http=127.0.0.1:8090
///     PEARD_TEST_SERVER_URL=http://127.0.0.1:8090 \
///     PEARD_TEST_SUPERUSER_IDENTITY=admin@peard.app \
///     PEARD_TEST_SUPERUSER_PASSWORD='Password123!' \
///     swift test --filter LocalServerIntegrationTests
///
/// The superuser credentials are needed only to seed the fixture: `pairs`,
/// `pair_members` and `users` creation is closed to ordinary users.
final class LocalServerIntegrationTests: XCTestCase {
    private struct Identified: Codable, Hashable, Sendable { let id: String }

    private var baseURL: URL!
    private var superuserIdentity: String!
    private var superuserPassword: String!

    private let userEmail = "integration-user@peard.local"
    private let partnerEmail = "integration-partner@peard.local"
    private let password = "test1234"

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["PEARD_TEST_SERVER_URL"], let url = URL(string: raw) else {
            throw XCTSkip("Set PEARD_TEST_SERVER_URL to run the integration test.")
        }
        guard
            let identity = environment["PEARD_TEST_SUPERUSER_IDENTITY"],
            let password = environment["PEARD_TEST_SUPERUSER_PASSWORD"]
        else {
            throw XCTSkip("Set PEARD_TEST_SUPERUSER_IDENTITY and PEARD_TEST_SUPERUSER_PASSWORD.")
        }
        baseURL = url
        superuserIdentity = identity
        superuserPassword = password
    }

    func testSignsInAndCreatesAnEventPost() async throws {
        let anonymous = APIClient(baseURL: baseURL)

        // The server must be up before anything else is attempted.
        let health = try await anonymous.healthCode()
        XCTAssertEqual(health, 200)

        // Seed: users, a pair and both memberships, as superuser.
        let superuserToken = TokenBox()
        let admin = APIClient(baseURL: baseURL, tokenProvider: superuserToken)
        let adminAuth: AuthResponse = try await anonymous.post(
            path: "/api/collections/_superusers/auth-with-password",
            fields: ["identity": superuserIdentity, "password": superuserPassword]
        )
        superuserToken.set(adminAuth.token)

        let userID = try await findOrCreateUser(admin, email: userEmail, displayName: "Integration User")
        let partnerID = try await findOrCreateUser(admin, email: partnerEmail, displayName: "Integration Partner")
        let pairID = try await pair(admin, userID: userID, partnerID: partnerID)

        // Sign in as the ordinary user.
        let auth: AuthResponse = try await anonymous.post(
            path: "/api/collections/users/auth-with-password",
            fields: ["identity": userEmail, "password": password]
        )
        XCTAssertEqual(auth.record.id, userID)
        XCTAssertFalse(auth.token.isEmpty)

        let session = TokenBox(token: auth.token)
        let client = APIClient(baseURL: baseURL, tokenProvider: session)

        // Membership resolves for the signed-in user (Requirement 9.3).
        let membership = try await client.membership(forUser: userID)
        XCTAssertEqual(membership?.pair, pairID)

        // Create one event post as that user (Requirement 12.3).
        let note = "integration \(UUID().uuidString.prefix(8))"
        let created: Post = try await client.create("posts", fields: [
            "pair": pairID,
            "author": userID,
            "type": PostType.event.rawValue,
            "event_kind": EventKind.beer.rawValue,
            "note": note,
        ])

        XCTAssertEqual(created.type, .event)
        XCTAssertEqual(created.eventKind, .beer)
        XCTAssertEqual(created.author, userID)
        XCTAssertEqual(created.pair, pairID)
        XCTAssertEqual(created.displayNote, note)

        // It comes back through the read path the app uses.
        let recent = try await client.recentPosts(pairID: pairID, limit: 5)
        XCTAssertTrue(recent.contains { $0.id == created.id })

        let events = try await client.eventPosts(pairID: pairID)
        XCTAssertTrue(events.contains { $0.id == created.id })

        let tallies = TallyPeriods.split(posts: events, signedInUserID: userID)
        XCTAssertGreaterThanOrEqual(tallies.mine.day, 1)

        // Clean up so repeated runs stay independent.
        try? await admin.delete("posts", id: created.id)
        try? await admin.delete("pairs", id: pairID)
    }

    // MARK: Fixture helpers

    private func findOrCreateUser(_ admin: APIClient, email: String, displayName: String) async throws -> String {
        if let existing: Identified = try await admin.first(
            "users",
            of: Identified.self,
            filter: PeardFilter.equals("email", email)
        ) {
            return existing.id
        }
        let created: Identified = try await admin.create("users", fields: [
            "email": email,
            "password": password,
            "passwordConfirm": password,
            "display_name": displayName,
            "verified": "true",
        ])
        return created.id
    }

    /// Removes any existing membership (the server enforces one pair per user)
    /// and creates a fresh pair with both members.
    private func pair(_ admin: APIClient, userID: String, partnerID: String) async throws -> String {
        for id in [userID, partnerID] {
            let memberships: [PairMember] = try await admin.list(
                "pair_members",
                of: PairMember.self,
                filter: PeardFilter.equals("user", id),
                sort: nil,
                perPage: 50
            )
            for membership in memberships {
                try? await admin.delete("pair_members", id: membership.id)
            }
        }

        let pair: Identified = try await admin.create("pairs", of: Identified.self, fields: [:])
        let _: Identified = try await admin.create("pair_members", fields: [
            "pair": pair.id, "user": userID, "role": MemberRole.owner.rawValue,
        ])
        let _: Identified = try await admin.create("pair_members", fields: [
            "pair": pair.id, "user": partnerID, "role": MemberRole.member.rawValue,
        ])
        return pair.id
    }
}
