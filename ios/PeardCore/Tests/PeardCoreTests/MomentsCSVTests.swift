import XCTest
@testable import PeardCore

/// Exporting a connection's moments as CSV (issue #164).
final class MomentsCSVTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let loggedAt = Date(timeIntervalSince1970: 1_773_342_245) // 2026-03-12T19:04:05Z

    private func post(
        _ id: String = "p1",
        author: String = "sam",
        type: PostType = .event,
        kind: EventKind? = .coffee,
        note: String? = nil,
        media: String? = nil,
        happenedAt: Date? = nil,
        rewound: Bool? = nil
    ) -> Post {
        Post(
            id: id, pair: "pair1", author: author, type: type, eventKind: kind,
            note: note, media: media, created: loggedAt, happenedAt: happenedAt, rewound: rewound
        )
    }

    private func csv(_ posts: [Post], customKinds: [MomentKind] = [], timeZone: TimeZone? = nil) -> String {
        MomentsCSV.make(
            posts: posts,
            customKinds: customKinds,
            authorLabel: { $0 == "me" ? "You" : "Sam, Rivers" },
            timeZone: timeZone ?? utc
        )
    }

    /// The rows after the byte-order mark, split on the RFC's CRLF.
    private func lines(_ text: String) -> [String] {
        XCTAssertTrue(text.hasPrefix("\u{FEFF}"))
        return text.dropFirst().components(separatedBy: "\r\n")
    }

    // MARK: Shape

    func testTheHeaderNamesEveryColumn() {
        XCTAssertEqual(lines(csv([])), ["date,who,moment,note,has_photo,rewound", ""])
    }

    func testAnOrdinaryMomentIsOneUnquotedRow() {
        let rows = lines(csv([post(author: "me")]))
        XCTAssertEqual(rows[1], "2026-03-12T19:04:05Z,You,☕ Coffee,,no,no")
        XCTAssertEqual(rows.count, 3, "header, one row, and the empty string after the final CRLF")
    }

    /// Local time with its offset, so a chart by hour reads the hour it was
    /// where it happened.
    func testTheDateIsISO8601InTheGivenTimeZone() {
        let london = TimeZone(identifier: "Europe/London")!
        let summer = Date(timeIntervalSince1970: 1_783_710_245) // 2026-07-10T19:04:05Z
        let rows = lines(csv([post(author: "me", happenedAt: summer)], timeZone: london))
        XCTAssertTrue(rows[1].hasPrefix("2026-07-10T20:04:05+01:00,"), rows[1])
    }

    /// When it happened, not when it was logged — the same time the timeline
    /// sorts by — and the rewound flag says which of the two it was.
    func testARewoundMomentUsesItsChosenTimeAndSaysSo() {
        let earlier = loggedAt.addingTimeInterval(-3 * 3600)
        let rows = lines(csv([post(author: "me", happenedAt: earlier, rewound: true)]))
        XCTAssertEqual(rows[1], "2026-03-12T16:04:05Z,You,☕ Coffee,,no,yes")
    }

    func testAPhotoIsMarked() {
        let rows = lines(csv([post(author: "me", type: .photo, kind: nil, media: "pear.jpg")]))
        XCTAssertEqual(rows[1], "2026-03-12T19:04:05Z,You,📸 Photo,,yes,no")
    }

    func testACustomMomentUsesTheConnectionsOwnEmojiAndLabel() {
        let dogWalk = MomentKind(id: "k1", pair: "pair1", slug: "dog-walk", emoji: "🐕", label: "Dog walk")
        let rows = lines(csv([post(author: "me", kind: "dog-walk")], customKinds: [dogWalk]))
        XCTAssertEqual(rows[1], "2026-03-12T19:04:05Z,You,🐕 Dog walk,,no,no")
    }

    /// Records from before the server stamped `created` have no time at all;
    /// an empty cell is honest where 0001-01-01 would be a lie.
    func testAnUndatedMomentHasAnEmptyDate() {
        let undated = Post(id: "old", pair: "pair1", author: "me", type: .event, eventKind: .beer, created: .distantPast)
        XCTAssertEqual(lines(csv([undated]))[1], ",You,🍺 Beer,,no,no")
    }

    // MARK: RFC 4180 quoting

    func testACommaIsQuoted() {
        // The author label in `csv` is "Sam, Rivers" for anybody but "me".
        XCTAssertEqual(lines(csv([post()]))[1], "2026-03-12T19:04:05Z,\"Sam, Rivers\",☕ Coffee,,no,no")
    }

    func testAQuoteIsDoubledAndTheFieldQuoted() {
        XCTAssertEqual(MomentsCSV.field("the \"good\" one"), "\"the \"\"good\"\" one\"")
    }

    func testALineBreakStaysInsideOneQuotedField() {
        let text = csv([post(author: "me", note: "first line\nsecond line")])
        XCTAssertTrue(text.contains(",\"first line\nsecond line\",no,no\r\n"), text)
    }

    /// "\r\n" is a single `Character` in Swift, so a check for "\n" alone would
    /// miss it and let a Windows line break split the row.
    func testACarriageReturnLineFeedIsQuotedToo() {
        XCTAssertEqual(MomentsCSV.field("a\r\nb"), "\"a\r\nb\"")
        XCTAssertEqual(MomentsCSV.field("a\rb"), "\"a\rb\"")
    }

    func testEmojiNeedNoQuoting() {
        XCTAssertEqual(MomentsCSV.field("🍐👩‍👩‍👧 café"), "🍐👩‍👩‍👧 café")
    }

    func testAPlainFieldIsLeftAlone() {
        XCTAssertEqual(MomentsCSV.field("Coffee"), "Coffee")
        XCTAssertEqual(MomentsCSV.field(""), "")
    }

    // MARK: File name

    func testTheFileNameCarriesTheConnectionsTitle() {
        XCTAssertEqual(MomentsCSV.fileName(connectionTitle: "Sam"), "Pear'd moments - Sam.csv")
    }

    func testCharactersAFilesystemRejectsAreReplaced() {
        XCTAssertEqual(MomentsCSV.fileName(connectionTitle: "Ari / Bo: 2026"), "Pear'd moments - Ari - Bo- 2026.csv")
        XCTAssertEqual(MomentsCSV.fileName(connectionTitle: "  "), "Pear'd moments.csv")
    }

    // MARK: Paging

    private func page(_ ids: [String], _ number: Int, of total: Int) -> PostPage {
        PostPage(posts: ids.map { post($0) }, page: number, totalPages: total, totalItems: 0)
    }

    func testEveryPageIsFetchedInOrder() async throws {
        var asked: [Int] = []
        let posts = try await MomentsCSV.collectPosts { number in
            asked.append(number)
            return [self.page(["a", "b"], 1, of: 3), self.page(["c", "d"], 2, of: 3), self.page(["e"], 3, of: 3)][number - 1]
        }
        XCTAssertEqual(asked, [1, 2, 3])
        XCTAssertEqual(posts.map(\.id), ["a", "b", "c", "d", "e"])
    }

    /// A moment logged mid-export shifts everything down a place, so the last row
    /// of one page comes back as the first of the next.
    func testARowRepeatedAcrossAPageBoundaryIsKeptOnce() async throws {
        let posts = try await MomentsCSV.collectPosts { number in
            number == 1 ? self.page(["a", "b"], 1, of: 2) : self.page(["b", "c"], 2, of: 2)
        }
        XCTAssertEqual(posts.map(\.id), ["a", "b", "c"])
    }

    func testAnEmptyPageStopsEvenIfTheTotalsSayOtherwise() async throws {
        var asked = 0
        let posts = try await MomentsCSV.collectPosts { number in
            asked += 1
            return self.page([], number, of: 99)
        }
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(posts.isEmpty)
    }

    func testAFailedPageFailsTheExport() async {
        do {
            _ = try await MomentsCSV.collectPosts { number in
                if number == 2 { throw APIError.transport("offline") }
                return self.page(["a"], 1, of: 2)
            }
            XCTFail("a partial export must not look like a whole one")
        } catch {
            XCTAssertEqual(error as? APIError, .transport("offline"))
        }
    }
}
