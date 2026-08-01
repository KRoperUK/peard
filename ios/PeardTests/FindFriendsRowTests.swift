import XCTest
@testable import Peard
import PeardCore

/// The contacts list's two decisions: what order people come in, and what a
/// search leaves behind.
///
/// Both are pure functions on purpose. The screen around them needs an address
/// book and a server; these do not, so the rules can be checked without either.
@MainActor
final class FindFriendsRowTests: XCTestCase {
    // MARK: Ordering

    /// Everybody in the address book is listed, not only the accounts that
    /// matched. A new user has no matches by definition, and a list that can
    /// only be empty is what made adding somebody from your contacts impossible
    /// in the first place.
    func testEveryoneIsListedWhetherOrNotTheyAreOnPeard() {
        let rows = FindFriendsModel.rows(
            from: [contact("1", "Ada"), contact("2", "Bo"), contact("3", "Cai")],
            matchesByHash: [:]
        )

        XCTAssertEqual(rows.map(\.name), ["Ada", "Bo", "Cai"])
        XCTAssertTrue(rows.allSatisfy { !$0.isOnPeard })
    }

    /// Matching still earns its keep: the people already here go to the top,
    /// because an invite they can act on today is worth more than one that
    /// waits for them to install the app.
    func testPeopleAlreadyOnPeardComeFirst() {
        let rows = FindFriendsModel.rows(
            from: [contact("1", "Ada"), contact("2", "Bo"), contact("3", "Cai")],
            matchesByHash: ["hash-2": match(hash: "hash-2", name: "Bo B")]
        )

        XCTAssertEqual(rows.map(\.name), ["Bo", "Ada", "Cai"])
        XCTAssertTrue(rows[0].isOnPeard)
    }

    /// Alphabetical within each group. The reader sorts, and the partition has
    /// to be stable or the unmatched majority would come back shuffled.
    func testOrderIsPreservedWithinEachGroup() {
        let rows = FindFriendsModel.rows(
            from: [contact("1", "Ada"), contact("2", "Bo"), contact("3", "Cai"), contact("4", "Dee")],
            matchesByHash: [
                "hash-3": match(hash: "hash-3", name: "Cai C"),
                "hash-1": match(hash: "hash-1", name: "Ada A"),
            ]
        )

        XCTAssertEqual(rows.map(\.name), ["Ada", "Cai", "Bo", "Dee"])
    }

    /// A contact with several numbers and addresses submits several hashes, and
    /// any one of them coming back is the same person.
    func testAMatchOnASecondHashStillCounts() {
        let contact = LocalContact(
            id: "1",
            name: "Ada",
            hashes: ["hash-a", "hash-b"],
            target: LocalMatchTarget(value: "+441234567890", isPhone: true)
        )

        let rows = FindFriendsModel.rows(
            from: [contact],
            matchesByHash: ["hash-b": match(hash: "hash-b", name: "Ada A")]
        )

        XCTAssertTrue(rows[0].isOnPeard)
    }

    // MARK: Search

    func testAnEmptyQueryKeepsEverybody() {
        let rows = FindFriendsModel.rows(from: [contact("1", "Ada"), contact("2", "Bo")], matchesByHash: [:])

        XCTAssertEqual(FindFriendsModel.rows(rows, matching: "").count, 2)
        XCTAssertEqual(FindFriendsModel.rows(rows, matching: "   ").count, 2)
    }

    func testSearchIgnoresCaseAndAccents() {
        let rows = FindFriendsModel.rows(from: [contact("1", "René"), contact("2", "Bo")], matchesByHash: [:])

        XCTAssertEqual(FindFriendsModel.rows(rows, matching: "rene").map(\.name), ["René"])
        XCTAssertEqual(FindFriendsModel.rows(rows, matching: "BO").map(\.name), ["Bo"])
    }

    /// Two people with the same name is the case a name-only search cannot
    /// resolve, so the number or address the invite would go to is searchable
    /// too.
    func testSearchAlsoMatchesTheInviteTarget() {
        let rows = FindFriendsModel.rows(
            from: [
                LocalContact(id: "1", name: "Sarah", hashes: ["h1"], target: LocalMatchTarget(value: "+447700900123", isPhone: true)),
                LocalContact(id: "2", name: "Sarah", hashes: ["h2"], target: LocalMatchTarget(value: "sarah@work.example", isPhone: false)),
            ],
            matchesByHash: [:]
        )

        XCTAssertEqual(FindFriendsModel.rows(rows, matching: "work.example").map(\.id), ["2"])
        XCTAssertEqual(FindFriendsModel.rows(rows, matching: "900123").map(\.id), ["1"])
    }

    func testASearchThatMatchesNobodyReturnsNothing() {
        let rows = FindFriendsModel.rows(from: [contact("1", "Ada")], matchesByHash: [:])

        XCTAssertTrue(FindFriendsModel.rows(rows, matching: "zzz").isEmpty)
    }

    // MARK: Invitability

    /// The reader drops contacts with nothing to reach them by, but a row that
    /// somehow has none must not offer a button that cannot do anything.
    func testAContactWithNoPhoneOrEmailCannotBeInvited() {
        let rows = FindFriendsModel.rows(
            from: [LocalContact(id: "1", name: "Ada", hashes: ["h1"], target: nil)],
            matchesByHash: [:]
        )

        XCTAssertFalse(rows[0].canInvite)
    }

    // MARK: Helpers

    private func contact(_ id: String, _ name: String) -> LocalContact {
        LocalContact(
            id: id,
            name: name,
            hashes: ["hash-\(id)"],
            target: LocalMatchTarget(value: "\(name.lowercased())@example.com", isPhone: false)
        )
    }

    private func match(hash: String, name: String) -> ContactMatch {
        ContactMatch(id: "user-\(hash)", displayName: name, hash: hash)
    }
}
