import XCTest
@testable import PeardCore

/// Connection titles decide what the switcher and the pinned header say, and
/// they have to stay sensible when the server cannot tell the client who the
/// other members are (the `users` view rule hides them).
final class ConnectionTests: XCTestCase {
    private func connection(
        name: String? = nil,
        otherNames: [String] = ["Sam"],
        role: MemberRole = .member,
        created: TimeInterval = 0
    ) -> Connection {
        var members = [Connection.Member(user: "me", name: "Me", role: role, isYou: true)]
        for (index, other) in otherNames.enumerated() {
            members.append(Connection.Member(user: "u\(index)", name: other))
        }
        return Connection(
            pair: "pair-\(otherNames.count)-\(name ?? "unnamed")",
            name: name,
            created: Date(timeIntervalSince1970: 1_700_000_000 + created),
            role: role,
            members: members
        )
    }

    func testTwoMembersIsNotAGroupAndMoreThanTwoIs() {
        XCTAssertFalse(connection(otherNames: ["Sam"]).isGroup)
        XCTAssertTrue(connection(otherNames: ["Sam", "Ari"]).isGroup)
        XCTAssertEqual(connection(otherNames: ["Sam"]).subtitle, "Just the two of you")
        XCTAssertEqual(connection(otherNames: ["Sam", "Ari", "Bo", "Cy"]).subtitle, "5 people")
    }

    func testAnExplicitNameWinsOverEverythingElse() {
        XCTAssertEqual(connection(name: "Flatmates", otherNames: ["Sam", "Ari", "Bo"]).title(), "Flatmates")
        XCTAssertEqual(connection(name: "Flatmates", otherNames: ["Sam"]).title(), "Flatmates")
    }

    func testAnUnnamedOneToOneUsesThePartnerName() {
        XCTAssertEqual(connection(otherNames: ["Sam"]).title(), "Sam")
        XCTAssertEqual(connection(otherNames: ["Sam"]).partnerName, "Sam")
    }

    /// This is why the server resolves member names: without them every unnamed
    /// connection would title identically and the switcher could not be used.
    ///
    /// `memberCount: 2` is the load-bearing part of the fixture. It says there is
    /// somebody else even though their name did not arrive, which is what makes
    /// "Partner" the right guess — as opposed to a connection whose count is one,
    /// where there is genuinely nobody to name.
    func testAConnectionWithUnresolvedMembersFallsBack() {
        let unresolved = Connection(pair: "pair1", memberCount: 2, members: [])
        XCTAssertEqual(unresolved.title(), PartnerLabel.fallback)
        XCTAssertNil(unresolved.partnerName)
        XCTAssertFalse(unresolved.isJustYou)
    }

    /// The decoder's default when the server omits the count. One, because the
    /// signed-in user always counts — and with no other members that reads as a
    /// connection holding only you.
    func testMemberCountDefaultsToCountingYou() {
        let bare = Connection(pair: "pair1", members: [])
        XCTAssertEqual(bare.memberCount, 1, "the signed-in user always counts")
        XCTAssertTrue(bare.isJustYou)
        XCTAssertEqual(bare.title(), "Just you")
    }

    func testAnUnnamedGroupListsItsMembers() {
        XCTAssertEqual(connection(otherNames: ["Sam", "Ari"]).title(), "Sam & Ari")
        XCTAssertEqual(connection(otherNames: ["Sam", "Ari", "Bo"]).title(), "Sam +2")
        XCTAssertNil(connection(otherNames: ["Sam", "Ari"]).partnerName, "a group has no single partner")
    }

    func testMembersExcludeYouAndResolveByID() {
        let group = connection(otherNames: ["Sam", "Ari"])
        XCTAssertEqual(group.others.map(\.name), ["Sam", "Ari"])
        XCTAssertEqual(group.name(forUser: "u1"), "Ari")
        XCTAssertEqual(group.name(forUser: "me"), "Me")
        XCTAssertNil(group.name(forUser: "nobody"))
    }

    func testWhitespaceOnlyNamesAreTreatedAsUnnamed() {
        XCTAssertNil(connection(name: "   ", otherNames: ["Sam"]).displayName)
        XCTAssertNil(connection(name: "", otherNames: ["Sam"]).displayName)
        XCTAssertEqual(connection(name: "  ", otherNames: ["Sam"]).title(), "Sam")
        XCTAssertEqual(connection(name: "Flat", otherNames: ["Sam"]).displayName, "Flat")
    }

    func testConnectionListDecodesFromTheRoutePayload() throws {
        let json = Data("""
        {"connections":[
          {"pair":"pair1","name":"Flatmates","created":"2026-07-28 10:00:00.000Z","role":"owner",
           "member_count":3,"is_group":true,
           "members":[{"user":"me","name":"Me","role":"owner","is_you":true},
                      {"user":"u1","name":"Ari","role":"member","is_you":false},
                      {"user":"u2","name":"Bo","role":"member","is_you":false}]},
          {"pair":"pair2","name":"","role":"member","member_count":2,
           "members":[{"user":"me","name":"Me","role":"member","is_you":true},
                      {"user":"u3","name":"Sam","role":"owner","is_you":false}]}
        ]}
        """.utf8)

        let list = try JSONDecoder.peard.decode(ConnectionList.self, from: json)

        XCTAssertEqual(list.connections.count, 2)
        let group = list.connections[0]
        XCTAssertEqual(group.title(), "Flatmates")
        XCTAssertTrue(group.isGroup)
        XCTAssertEqual(group.role, .owner)
        XCTAssertEqual(group.others.map(\.name), ["Ari", "Bo"])
        XCTAssertNotEqual(group.created, .distantPast)

        let pair = list.connections[1]
        XCTAssertEqual(pair.title(), "Sam", "an unnamed 1:1 is titled by the other person")
        XCTAssertFalse(pair.isGroup)
        XCTAssertEqual(pair.created, .distantPast, "no timestamp is tolerated")
    }

    /// `renameConnection` decodes the patched `pairs` row.
    func testPairRecordDecodesWithoutATimestamp() throws {
        let json = Data(#"{"id":"pair1","name":"Flat"}"#.utf8)
        let pair = try JSONDecoder.peard.decode(PairRecord.self, from: json)

        XCTAssertEqual(pair.id, "pair1")
        XCTAssertEqual(pair.displayName, "Flat")
        XCTAssertEqual(pair.created, .distantPast)
        XCTAssertNil(PairRecord(id: "p1", name: "  ").displayName)
    }

    func testMomentKindDecodesFromTheCollectionShape() throws {
        let json = Data("""
        {"id":"mk1","pair":"pair1","slug":"dog_walk","emoji":"🐕","label":"Dog walk",
         "created_by":"user1","created":"2026-07-28 10:00:00.000Z"}
        """.utf8)
        let kind = try JSONDecoder.peard.decode(MomentKind.self, from: json)

        XCTAssertEqual(kind.slug, EventKind(rawValue: "dog_walk"))
        XCTAssertEqual(kind.moment.emoji, "🐕")
        XCTAssertEqual(kind.moment.label, "Dog walk")
        XCTAssertEqual(kind.moment.origin, .custom(recordID: "mk1"))
        XCTAssertNotEqual(kind.created, .distantPast)
    }

    // MARK: Filters

    func testOthersLabelNamesTheOtherPersonInAOneToOne() {
        XCTAssertEqual(connection(otherNames: ["Sam"]).othersLabel, "Sam")
    }

    func testOthersLabelIsCollectiveInAGroup() {
        XCTAssertEqual(connection(otherNames: ["Sam", "Ari"]).othersLabel, "Others")
        XCTAssertEqual(connection(otherNames: ["Sam", "Ari", "Bo"]).othersLabel, "Others")
    }

    /// The case that produced the bug: everybody else has left, but their moments
    /// are still in the timeline and still counted. "Partner" would be wrong twice
    /// — there is no partner, and `HistoryModel.authorLabel` already calls that
    /// same author `PartnerLabel.unknown`. The two screens have to agree.
    func testOthersLabelIsNeutralWhenNobodyElseIsLeft() {
        let alone = connection(otherNames: [])
        XCTAssertTrue(alone.others.isEmpty)
        XCTAssertFalse(alone.isGroup)
        XCTAssertNil(alone.partnerName)
        XCTAssertEqual(alone.othersLabel, PartnerLabel.unknown)
        XCTAssertNotEqual(alone.othersLabel, PartnerLabel.fallback)
    }

    /// Both neutral labels have to survive the tally row's truncation unchanged,
    /// or the fix would read as "Someone…" / "Others…".
    func testNeutralLabelsAreShortEnoughForTheTallyRow() {
        XCTAssertEqual(PartnerLabel.short(PartnerLabel.unknown), PartnerLabel.unknown)
        XCTAssertEqual(PartnerLabel.short("Others"), "Others")
    }

    /// The other half of the same wrong assumption: "not a group" was taken to mean
    /// two people, so a connection holding only you claimed "Just the two of you".
    func testAConnectionHoldingOnlyYouSaysSo() {
        let alone = connection(otherNames: [])
        XCTAssertTrue(alone.isJustYou)
        XCTAssertEqual(alone.subtitle, "Just you")
        XCTAssertNotEqual(alone.subtitle, "Just the two of you")
        // Unnamed, so the title falls through to the size description rather than
        // guessing at a partner who is not there.
        XCTAssertEqual(alone.title(), "Just you")
        XCTAssertNotEqual(alone.title(), PartnerLabel.fallback)
    }

    /// A named one is still called by its name — the fix must not override that.
    func testANamedConnectionHoldingOnlyYouKeepsItsName() {
        let named = connection(name: "Curl Crew", otherNames: [])
        XCTAssertTrue(named.isJustYou)
        XCTAssertEqual(named.title(), "Curl Crew")
        XCTAssertEqual(named.subtitle, "Just you")
    }

    /// And a real pair whose member names the server could not resolve still gets
    /// "Partner": there *is* somebody, they are just unnamed. Distinguishing these
    /// two is the whole point of `isJustYou`.
    func testAnUnresolvedPairStillSaysPartner() {
        let unresolved = Connection(pair: "p", memberCount: 2, members: [
            .init(user: "me", name: "Me", role: .owner, isYou: true),
        ])
        XCTAssertFalse(unresolved.isJustYou)
        XCTAssertEqual(unresolved.title(), PartnerLabel.fallback)
        XCTAssertEqual(unresolved.subtitle, "Just the two of you")
    }


    func testAnyEqualsBuildsAParenthesisedOrGroup() {
        XCTAssertEqual(
            PeardFilter.anyEquals("pair", ["a", "b"]),
            #"(pair = "a" || pair = "b")"#
        )
    }

    func testASingleValueNeedsNoGroup() {
        XCTAssertEqual(PeardFilter.anyEquals("pair", ["a"]), #"pair = "a""#)
        XCTAssertEqual(PeardFilter.anyEquals("pair", []), "")
    }

    func testAnOrGroupSurvivesBeingCombinedWithAnd() {
        let filter = PeardFilter.and(
            PeardFilter.anyEquals("pair", ["a", "b"]),
            PeardFilter.equals("type", "event")
        )
        XCTAssertEqual(filter, #"(pair = "a" || pair = "b") && type = "event""#)
    }

    func testOrEscapesItsValuesLikeEqualsDoes() {
        // The injected quote is escaped, so it cannot close the literal and turn
        // the tail into expression syntax.
        XCTAssertEqual(
            PeardFilter.anyEquals("pair", [#"a" || 1=1 --"#, "b"]),
            #"(pair = "a\" || 1=1 --" || pair = "b")"#
        )
    }
}
