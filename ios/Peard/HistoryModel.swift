import PeardCore
import SwiftUI

/// The full shared timeline, a page at a time.
///
/// The home screen deliberately shows the hero plus three rows, so it stays
/// legible at any text size. That left the shared timeline — the thing the product
/// is actually about — with a ceiling of four moments, ever. This is where the rest
/// of it lives.
///
/// Loading is paged rather than "fetch everything": a connection of twelve people
/// tapping moments accumulates thousands of rows, and none of them need to be in
/// memory to read yesterday.
@MainActor
@Observable
final class HistoryModel {
    /// One day's moments, which is how the timeline reads: people remember "that
    /// Tuesday", not offset 40.
    struct Day: Identifiable {
        let date: Date
        let posts: [Post]
        var id: Date { date }
    }

    private let api: APIClient
    private let pairID: String
    private let signedInUserID: String
    /// Supplies member display names. `GET /api/peard/connections` is the only
    /// place they are available — the `users` view rule stops the client reading
    /// anybody else's record — so the connection is passed in rather than looked up.
    private let connection: Connection?
    private let calendar: Calendar
    /// Where to draw the "new since you last looked" line, frozen at the moment
    /// this connection was opened — see `AppModel.unreadWatermarks`.
    private let unreadWatermark: Date?
    /// This connection's sends that have not reached the server yet, read live
    /// each time the timeline is grouped so a flush or a new tap is reflected
    /// without reloading. A closure rather than a stored array because the
    /// authority is `AppModel`'s queue, which the model does not otherwise hold;
    /// defaults to none so tests and previews need not supply one (#313).
    private let pendingSends: () -> [PendingSend]
    /// Whether the device currently has no connection, read live so the pending
    /// indicator says "waiting" offline and "sending" once signal returns.
    /// Defaults to online for tests and previews (#313).
    private let isOffline: () -> Bool

    private(set) var posts: [Post] = []
    /// Replaceable so a test can see what was felt.
    var playHaptic: (Haptic) -> Void = { Haptics.play($0) }
    private(set) var customKinds: [MomentKind] = []
    private(set) var isLoadingFirstPage = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var totalItems = 0
    private(set) var error: String?

    private var nextPage = 1
    private var newestGate = RefreshGate()
    /// Bumped whenever the pages in memory stop being the answer to the
    /// question being asked — see `apply(_:)`. A page request remembers the
    /// value it started under and is dropped if it has moved on by the time the
    /// response lands, or a scroll or search from before the change would
    /// append its rows to the new results and overwrite `nextPage`, `hasMore`
    /// and `totalItems` with numbers that describe a different query.
    private var generation = 0

    // MARK: Filtering

    /// What the timeline is narrowed to.
    ///
    /// Applied in the query, not to what is loaded — see `postsPage`. Changing
    /// it starts the paging again from the top, because the pages already in
    /// memory were the answer to a different question.
    private(set) var filter: TimelineFilter = .none

    func apply(_ newFilter: TimelineFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        generation += 1
        nextPage = 1
        posts = []
        hasMore = false
        totalItems = 0
        // Reactions are keyed by post, so what is already known stays valid and
        // costs nothing to keep.
        await fetchNextPage()
    }

    /// The people who could be filtered on: everybody in the connection, the
    /// signed-in user first because "just mine" is the commonest question.
    var filterableMembers: [Connection.Member] {
        guard let connection else { return [] }
        return connection.members.sorted { lhs, _ in lhs.user == signedInUserID }
    }

    func memberLabel(_ member: Connection.Member) -> String {
        member.user == signedInUserID ? "You" : member.name
    }

    /// What the active filter is called, for the chip under the title.
    var filterSummary: String? {
        guard filter.isActive else { return nil }
        var parts: [String] = []
        if let author = filter.author {
            parts.append(Connection.authorLabel(for: author, in: connection, signedInUserID: signedInUserID))
        }
        // Both, not one or the other: a moment can carry a photo, so "Coffee ·
        // Photos" is a real narrowing rather than a contradiction.
        if let kind = filter.kind {
            parts.append(MomentCatalogue.label(for: kind, customKinds: customKinds))
        }
        if filter.photosOnly {
            parts.append("Photos")
        }
        if !filter.search.isEmpty {
            parts.append("“\(filter.search)”")
        }
        return parts.joined(separator: " · ")
    }

    /// The moments in this timeline the signed-in user may change.
    ///
    /// Author only, and the server says the same: editing somebody else's
    /// account of their own evening is not something being in a group entitles
    /// you to. Checked here as well so the app does not offer a button that can
    /// only fail.
    ///
    /// A moment still queued on this device has no server record to edit or
    /// delete, so it offers neither here — editing and deleting it act on the
    /// queue instead, through `pendingSend(for:)` and `QueuedSendEditSheet`
    /// (#313).
    func canEdit(_ post: Post) -> Bool { post.author == signedInUserID && !isPending(post) }

    /// Everything this connection can log, which is what a moment may be
    /// changed *to*. The same list the home screen offers, so "the wrong one"
    /// and "the right one" are always both on it.
    var moments: [Moment] { MomentCatalogue.available(customKinds: customKinds) }

    // MARK: Reactions

    /// Reactions to the loaded posts, keyed by post.
    ///
    /// Reacting was only ever possible to the single most recent moment, on the
    /// home screen's hero. Come back after a day away and the five things that
    /// happened while you were gone could be read and not answered — which for
    /// an app whose whole subject is small acknowledgements between people is
    /// the wrong way round.
    private(set) var reactionsByPost: [String: [Reaction]] = [:]

    /// The distinct kinds somebody has used on a post, in the order they were
    /// first used, so the row reads the same on every redraw.
    func reactionKinds(for post: Post) -> [ReactionKind] {
        var seen: [ReactionKind] = []
        for reaction in reactionsByPost[post.id] ?? [] where !seen.contains(reaction.kind) {
            seen.append(reaction.kind)
        }
        return seen
    }

    /// Who reacted with what, for VoiceOver — the row draws the emoji alone,
    /// which says nothing about who they came from.
    func spokenReactions(for post: Post) -> String? {
        Self.spokenReactions(reactionsByPost[post.id] ?? []) { user in
            if user == signedInUserID { return "you" }
            // The full name rather than the row's shortened one: the ellipsis
            // is there to fit the width, and is meaningless read aloud.
            return connection?.name(forUser: user) ?? PartnerLabel.unknown
        }
    }

    /// "Reactions: Heart from Sam and you; Cheers from Alex", grouped by kind in
    /// the order the kinds were first used, as the row draws them.
    static func spokenReactions(_ reactions: [Reaction], name: (String) -> String) -> String? {
        var kinds: [ReactionKind] = []
        var people: [String: [String]] = [:]
        for reaction in reactions {
            if people[reaction.kind.rawValue] == nil { kinds.append(reaction.kind) }
            let who = name(reaction.user)
            if people[reaction.kind.rawValue]?.contains(who) != true {
                people[reaction.kind.rawValue, default: []].append(who)
            }
        }
        guard !kinds.isEmpty else { return nil }
        let phrases = kinds.map { kind in
            "\(kind.accessibilityLabel) from \((people[kind.rawValue] ?? []).formatted(.list(type: .and)))"
        }
        return "Reactions: " + phrases.joined(separator: "; ")
    }

    /// Requirement 14.1 — reactions are offered on other people's moments only.
    func canReact(to post: Post) -> Bool { post.author != signedInUserID }

    /// Whether the signed-in user has already used this kind here, which is what
    /// makes the control a toggle rather than a one-way door.
    func hasReacted(to post: Post, kind: ReactionKind) -> Bool {
        myReaction(to: post.id, kind: kind) != nil
    }

    private func myReaction(to postID: String, kind: ReactionKind) -> Reaction? {
        (reactionsByPost[postID] ?? []).first { $0.user == signedInUserID && $0.kind == kind }
    }

    /// Adds the reaction, or takes it back if it is already there.
    ///
    /// A reaction is a small thing said quickly, which is exactly why it needs
    /// an undo: tapping the wrong one of three emoji is easy, and until now the
    /// only way out was to leave it. The same control does both, because
    /// "cheers" and "un-cheers" are the same thought.
    func toggleReaction(to post: Post, kind: ReactionKind) async {
        playHaptic(.reacted)
        if myReaction(to: post.id, kind: kind) != nil {
            await removeReaction(from: post, kind: kind)
        } else {
            await addReaction(to: post, kind: kind)
        }
    }

    private func addReaction(to post: Post, kind: ReactionKind) async {
        do {
            let _: Reaction = try await api.create("reactions", fields: [
                "post": post.id,
                "user": signedInUserID,
                "kind": kind.rawValue,
            ])
        } catch let error as APIError where error.status == 400 {
            // The unique (post, user, kind) index rejected a duplicate. Not an
            // error worth showing: the reaction the person wanted is already
            // there, and saying so would read as a failure (Requirement 14.4).
        } catch {
            self.error = APIError.userMessage(for: error)
            return
        }

        // Shown straight away rather than waiting for the round trip. The
        // reconciliation below is the authority, but it can be cancelled — a
        // reaction that appears only sometimes is worse than one drawn a moment
        // early from a write the server has already accepted.
        addLocally(kind: kind, to: post.id)
        error = nil
        await loadReactions(for: [post.id])
    }

    private func removeReaction(from post: Post, kind: ReactionKind) async {
        guard var mine = myReaction(to: post.id, kind: kind) else { return }

        // The optimistic add leaves a placeholder id, and the reconciliation
        // that would have replaced it with the server's can be cancelled. Undo
        // must still work in that window, so the real one is fetched rather than
        // a made-up id being sent to the server.
        if mine.id.hasPrefix(Self.localReactionPrefix) {
            await loadReactions(for: [post.id])
            guard let real = myReaction(to: post.id, kind: kind),
                  !real.id.hasPrefix(Self.localReactionPrefix) else { return }
            mine = real
        }

        do {
            try await api.removeReaction(id: mine.id)
        } catch let error as APIError where error.status == 404 {
            // Already gone — somebody's other device, or a retry. The local
            // removal below is then simply catching up.
        } catch {
            self.error = APIError.userMessage(for: error)
            return
        }

        reactionsByPost[post.id] = (reactionsByPost[post.id] ?? []).filter { $0.id != mine.id }
        error = nil
    }

    /// Marks a locally-added reaction so it can be told from one the server has
    /// confirmed — see `removeReaction`.
    private static let localReactionPrefix = "local-"

    private func addLocally(kind: ReactionKind, to postID: String) {
        var existing = reactionsByPost[postID] ?? []
        guard !existing.contains(where: { $0.user == signedInUserID && $0.kind == kind }) else { return }
        existing.append(Reaction(
            id: "\(Self.localReactionPrefix)\(postID)-\(kind.rawValue)",
            post: postID,
            user: signedInUserID,
            kind: kind
        ))
        reactionsByPost[postID] = existing
    }

    /// Replaces what is known about the given posts' reactions, and only on
    /// success.
    ///
    /// Nothing is cleared up front, which is the whole point. This runs inside
    /// pull-to-refresh's task, and that task is cancelled the moment the refresh
    /// control retracts — the posts request finishes first, this one does not,
    /// and a version of this that emptied the map before fetching left every
    /// reaction missing until the next launch. A cancelled or failed load now
    /// leaves what is already on screen exactly where it was.
    ///
    /// Quiet on failure for the same reason: reactions are decoration on a
    /// timeline that reads perfectly without them, and an error across the whole
    /// screen because one secondary request was cancelled is worse than a row
    /// briefly missing a heart.
    private func loadReactions(for postIDs: [String]) async {
        guard !postIDs.isEmpty else { return }
        guard let fetched = try? await api.reactions(postIDs: postIDs) else { return }

        var replacement: [String: [Reaction]] = [:]
        for reaction in fetched {
            replacement[reaction.post, default: []].append(reaction)
        }
        // Assigned per requested post, so a post that genuinely has no
        // reactions any more loses them, without touching posts this call was
        // not asked about.
        for id in postIDs {
            reactionsByPost[id] = replacement[id] ?? []
        }
    }

    // MARK: Replies

    /// Photos answered by loaded posts that are not themselves loaded — a
    /// comment today on a photo from last week — keyed by id.
    private(set) var originalsByID: [String: Post] = [:]

    /// The photo a post answers, when it is to hand.
    func original(for post: Post) -> Post? {
        guard let id = post.replyTo else { return nil }
        return posts.first { $0.id == id } ?? originalsByID[id]
    }

    func replyTitle(for post: Post) -> String {
        ReplyChip.title(for: original(for: post), signedInUserID: signedInUserID) { authorLabel(for: $0) }
    }

    /// Fetches the photos a page's replies answer, when they are not already
    /// here. Quiet on failure like the reactions: the chip still reads
    /// "replying to a photo" without one.
    private func loadOriginals(for page: [Post]) async {
        let known = Set(posts.map(\.id)).union(originalsByID.keys)
        let missing = Set(page.compactMap(\.replyTo)).subtracting(known)
        guard !missing.isEmpty, let fetched = try? await api.posts(ids: Array(missing)) else { return }
        for post in fetched { originalsByID[post.id] = post }
    }

    /// Chosen so the first screenful arrives quickly while a scroll rarely has to
    /// wait: three screens' worth at a typical text size.
    static let pageSize = 30

    init(
        api: APIClient,
        pairID: String,
        signedInUserID: String,
        customKinds: [MomentKind],
        connection: Connection?,
        calendar: Calendar = .peardTally,
        unreadWatermark: Date? = nil,
        pendingSends: @escaping () -> [PendingSend] = { [] },
        isOffline: @escaping () -> Bool = { false }
    ) {
        self.api = api
        self.pairID = pairID
        self.signedInUserID = signedInUserID
        self.customKinds = customKinds
        self.connection = connection
        self.calendar = calendar
        self.unreadWatermark = unreadWatermark
        self.pendingSends = pendingSends
        self.isOffline = isOffline
    }

    /// True for a moment somebody else posted after the watermark — the ones
    /// that were waiting when this connection was opened.
    ///
    /// Your own moments are excluded for the same reason they never count
    /// towards `unread`: you were there when you logged them.
    func isNew(_ post: Post) -> Bool {
        guard let unreadWatermark, post.author != signedInUserID else { return false }
        return post.created > unreadWatermark
    }

    /// The oldest moment that still counts as new, which is where the line goes.
    ///
    /// Identified rather than drawn per-row so the timeline gets one divider
    /// instead of a marker on every new moment: the question is "where did I get
    /// to", and the answer is a single place.
    ///
    /// The end of the unbroken run of new moments at the top, rather than the
    /// oldest new moment anywhere. The timeline sorts by when moments happened,
    /// and a moment rewound to yesterday can arrive unread below ones already
    /// seen; putting the line under it would mark everything above as new.
    /// Your own moments do not break the run — they were never unread.
    var firstNewPostID: String? {
        var oldestInRun: String?
        for post in posts {
            if isNew(post) {
                oldestInRun = post.id
            } else if post.author != signedInUserID {
                break
            }
        }
        return oldestInRun
    }

    /// New moments that sit below the line because they were rewound, which
    /// get a dot of their own instead.
    var strayNewPostIDs: Set<String> {
        guard let firstNewPostID,
              let index = posts.firstIndex(where: { $0.id == firstNewPostID }) else {
            return Set(posts.filter(isNew).map(\.id))
        }
        return Set(posts[(index + 1)...].filter(isNew).map(\.id))
    }

    /// Moments grouped by day, newest day first.
    ///
    /// Posts with no timestamp (records predating the server's `created` field)
    /// decode as `distantPast`, which would otherwise open a section captioned with
    /// a date in year 1. They are collected under their own heading instead.
    var days: [Day] {
        var order: [Date] = []
        var grouped: [Date: [Post]] = [:]
        for post in timelinePosts {
            let key = post.hasTimestamp ? calendar.startOfDay(for: post.happenedAt) : Date.distantPast
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(post)
        }
        return order.map { Day(date: $0, posts: grouped[$0] ?? []) }
    }

    /// The loaded server posts with this device's not-yet-sent moments merged
    /// in, newest first — so a moment logged offline shows in the timeline
    /// beside the ones that have landed, rather than vanishing until signal
    /// comes back (#313).
    ///
    /// Pending moments are drawn as their `optimisticPost`, whose id is prefixed
    /// `pending:` so it never collides with a real row in a `ForEach`. There is
    /// no id-based de-duplication because none is needed: `SendQueue` drops a
    /// send the instant the server accepts it, and the same flush bumps the
    /// refresh fingerprint that pulls the real row in — the swap the home
    /// screen's hero already relies on.
    private var timelinePosts: [Post] {
        let pending = matchingPendingPosts
        guard !pending.isEmpty else { return posts }
        // Newest-first, matching the server order the pages arrive in. A queued
        // moment and a sent one share a `happenedAt` ordering, so a tap made now
        // sits at the top where it was just logged.
        return (posts + pending).sorted { $0.happenedAt > $1.happenedAt }
    }

    /// This device's queued sends as timeline rows, narrowed by the active
    /// filter the same way the server narrows the loaded pages. The filter runs
    /// here rather than on the server because these have never reached it.
    private var matchingPendingPosts: [Post] {
        pendingSends().compactMap { send in
            if let author = filter.author, !author.isEmpty, send.authorID != author { return nil }
            if let kind = filter.kind, !kind.rawValue.isEmpty, send.kind != kind { return nil }
            if filter.photosOnly, !send.hasPhoto { return nil }
            if !filter.search.isEmpty, !pendingMatchesSearch(send) { return nil }
            return send.optimisticPost
        }
    }

    /// Whether a queued send matches the text search: in its note, or in the
    /// label of the moment it is — mirroring the server's note/kind match so a
    /// search for "coffee" finds a queued coffee as it would a sent one.
    private func pendingMatchesSearch(_ send: PendingSend) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if send.note.range(of: filter.search, options: options) != nil { return true }
        if filter.searchKinds.contains(send.kind.rawValue) { return true }
        let label = MomentCatalogue.label(for: send.kind, customKinds: customKinds)
        return label.range(of: filter.search, options: options) != nil
    }

    /// True for a timeline row that is a moment queued on this device, not yet
    /// accepted by the server — the `pending:` id prefix its `optimisticPost`
    /// carries. Drives the "waiting"/"sending" indicator on the row (#313).
    func isPending(_ post: Post) -> Bool { post.id.hasPrefix(Self.pendingPrefix) }

    private static let pendingPrefix = "pending:"

    /// The queued send behind a pending timeline row, for editing or deleting it
    /// against the queue. `nil` when the row is not a pending one, or when the
    /// send has gone (sent, or discarded) since the row was drawn.
    func pendingSend(for post: Post) -> PendingSend? {
        guard isPending(post) else { return nil }
        let id = String(post.id.dropFirst(Self.pendingPrefix.count))
        return pendingSends().first { $0.id == id }
    }

    /// What the pending indicator should say: offline moments are waiting for
    /// signal, online ones are on their way up. Matches the home screen's hero.
    var pendingIndicatorIsOffline: Bool { isOffline() }

    func heading(for day: Day) -> String {
        guard day.date != .distantPast else { return "Undated" }
        if calendar.isDateInToday(day.date) { return "Today" }
        if calendar.isDateInYesterday(day.date) { return "Yesterday" }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        // Drop the year for the current one: "12 March" reads better than
        // "12 March 2026" when there is only one 12 March in view.
        let sameYear = calendar.component(.year, from: day.date) == calendar.component(.year, from: Date())
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEE d MMMM" : "d MMMM yyyy")
        return formatter.string(from: day.date)
    }

    func authorLabel(for post: Post) -> String {
        Connection.authorLabel(for: post.author, in: connection, signedInUserID: signedInUserID)
    }

    func emoji(for post: Post) -> String {
        MomentCatalogue.emoji(for: post, customKinds: customKinds)
    }

    /// The author's photo, or their initials — see `Connection.authorAvatar`.
    func avatar(forAuthor userID: String) -> Avatar {
        Connection.authorAvatar(for: userID, in: connection)
    }

    func detail(for post: Post) -> String {
        if let note = post.displayNote { return note }
        switch post.type {
        case .photo: return "photo"
        case .note: return "replied"
        case .event: return MomentCatalogue.label(for: post.eventKind, customKinds: customKinds)
        case .unknown: return "shared a moment"
        }
    }

    func time(for post: Post) -> String {
        guard post.hasTimestamp else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter.string(from: post.happenedAt)
    }

    // MARK: Loading

    func loadFirstPage() async {
        guard posts.isEmpty, !isLoadingFirstPage else { return }
        isLoadingFirstPage = true
        defer { isLoadingFirstPage = false }
        nextPage = 1
        posts = []
        await fetchNextPage()
    }

    /// Re-reads the timeline from the top.
    ///
    /// Nothing is thrown away up front. Pull-to-refresh runs this inside a task
    /// SwiftUI cancels the moment the control retracts, and a version that
    /// emptied `posts` first left a real device showing "Nothing here yet" over
    /// the word "cancelled" — a screenful of moments replaced by an empty state
    /// and an error, for a request that had simply stopped mattering. What is on
    /// screen now stays there until a page arrives to replace it.
    func reload() async {
        guard let page = await fetchPage(1) else { return }
        posts = page.posts
        totalItems = page.totalItems
        hasMore = page.hasMore
        nextPage = page.nextPage
        // Reactions for the replacement set. Their own failure is already quiet
        // — see `loadReactions`.
        await loadReactions(for: page.posts.map(\.id))
        await loadOriginals(for: page.posts)
    }

    /// Brings the top of the timeline up to date without losing what has been
    /// scrolled into (issue #113).
    ///
    /// The tab stays alive while somebody is on Home, so the page it loaded first
    /// was all it ever showed: a moment logged a second ago was missing until a
    /// pull to refresh. This runs whenever Home's recent moments change and each
    /// time the tab appears. A timeline no longer than a page is simply re-read.
    /// A longer one keeps its older pages: the fresh first page replaces
    /// everything down to the old position of that page's last moment, and the
    /// rest stays. If more has landed than a page holds, that position is gone
    /// and it starts again from the top.
    func refreshNewest() async {
        guard !posts.isEmpty else {
            await loadFirstPage()
            return
        }
        guard posts.count > Self.pageSize else {
            await reload()
            return
        }
        guard let page = await fetchPage(1) else { return }
        guard let boundary = page.posts.last,
              let cut = posts.firstIndex(where: { $0.id == boundary.id }) else {
            posts = page.posts
            totalItems = page.totalItems
            hasMore = page.hasMore
            nextPage = page.nextPage
            await loadReactions(for: page.posts.map(\.id))
            await loadOriginals(for: page.posts)
            return
        }
        let fresh = Set(page.posts.map(\.id))
        posts = page.posts + posts[(cut + 1)...].filter { !fresh.contains($0.id) }
        totalItems = page.totalItems
        await loadReactions(for: page.posts.map(\.id))
        await loadOriginals(for: page.posts)
    }

    /// `refreshNewest`, unless it has just run for the same reason.
    ///
    /// The tab's `.task` runs on every return to it, so flicking between Home
    /// and Timeline re-read the first page and its reactions each time
    /// (issue #302's audit). A changed `key` — Home's newest moments — always
    /// fetches; an unchanged one waits out `RefreshGate`'s window.
    func refreshNewestIfDue(key: String) async {
        guard newestGate.isDue(key: key) else { return }
        newestGate.record(key: key)
        await refreshNewest()
    }

    /// Called as the last row appears. Guarded against re-entry so a fast scroll
    /// cannot fire several requests for the same page.
    func loadMoreIfNeeded() async {
        guard hasMore, !isLoadingMore, !isLoadingFirstPage else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await fetchNextPage()
    }

    // MARK: Editing

    /// Applies an edit and rewrites the row in place.
    ///
    /// In place rather than reloading the timeline: a reload throws away every
    /// page loaded so far and scrolls back to today, which is a heavy price for
    /// changing one word. The server is the authority on what was saved, so what
    /// is written here is what was sent, once it has been accepted.
    ///
    /// Returns whether it worked, so the sheet knows whether to close.
    @discardableResult
    func edit(_ post: Post, note: String, kind: EventKind?, happenedAt: Date? = nil) async -> Bool {
        let trimmedNote = PostNote.normalised(note)
        let newKind = kind ?? post.eventKind
        // A time too close to when it was logged is not a rewind; it goes back
        // to exactly then, which is what the server would make of it too.
        let requested = happenedAt ?? post.happenedAt
        let newRewound = Rewind.isRewound(requested, loggedAt: post.created)
        let newHappenedAt = newRewound ? requested : post.created
        // Only send what changed. A no-op edit would still move `updated` and
        // put an "edited" label on a moment nobody edited.
        let noteChanged = trimmedNote != (post.note ?? "")
        let kindChanged = newKind != post.eventKind
        let timeChanged = abs(newHappenedAt.timeIntervalSince(post.happenedAt)) >= 1
        guard noteChanged || kindChanged || timeChanged else { return true }

        do {
            try await api.editMoment(
                postID: post.id,
                note: noteChanged ? .some(trimmedNote) : nil,
                kind: kindChanged ? newKind : nil,
                happenedAt: timeChanged ? .some(newRewound ? newHappenedAt : nil) : nil
            )
        } catch let error as APIError where error.status == 404 {
            // The route is missing, which means this app is talking to a server
            // older than the feature. An installed app cannot assume the server
            // has caught up with it — that assumption is what shipped account
            // deletion against a server that could not do it — and "Not found"
            // tells somebody trying to fix a typo nothing at all.
            self.error = "This server can't edit moments yet. Deleting and logging it again works."
            playHaptic(.failed)
            return false
        } catch {
            self.error = APIError.userMessage(for: error)
            playHaptic(.failed)
            return false
        }
        if timeChanged && newRewound { playHaptic(.rewound) }

        replace(post.id) { old in
            Post(
                id: old.id,
                pair: old.pair,
                author: old.author,
                type: old.type,
                eventKind: newKind,
                note: trimmedNote,
                media: old.media,
                created: old.created,
                // Enough to cross `isEdited`'s tolerance, so the label appears
                // now rather than on the next load. The server has written its
                // own stamp; this only has to agree about *whether* it moved.
                updated: Date(),
                happenedAt: newHappenedAt,
                rewound: newRewound,
                replyTo: old.replyTo
            )
        }
        if timeChanged {
            // Moved to where it now belongs among what is loaded.
            posts.sort { $0.happenedAt > $1.happenedAt }
        }
        error = nil
        return true
    }

    /// Deletes a moment and drops it from the timeline.
    @discardableResult
    func delete(_ post: Post) async -> Bool {
        do {
            try await api.deleteMoment(postID: post.id)
        } catch {
            self.error = APIError.userMessage(for: error)
            return false
        }
        posts.removeAll { $0.id == post.id }
        reactionsByPost[post.id] = nil
        // Kept honest for the "N moments" footer, which would otherwise count
        // something that is no longer there.
        totalItems = max(0, totalItems - 1)
        error = nil
        return true
    }

    private func replace(_ id: String, with transform: (Post) -> Post) {
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        posts[index] = transform(posts[index])
    }

    // MARK: Loading

    private func fetchNextPage() async {
        guard let page = await fetchPage(nextPage) else { return }
        // Guard against a duplicate arriving from a page boundary shifting
        // under us as new moments land: appending blindly would double a row.
        let known = Set(posts.map(\.id))
        let fresh = page.posts.filter { !known.contains($0.id) }
        posts.append(contentsOf: fresh)
        totalItems = page.totalItems
        hasMore = page.hasMore
        nextPage = page.nextPage
        // Only the posts this page added, so scrolling does not re-fetch
        // reactions for everything above.
        await loadReactions(for: fresh.map(\.id))
        await loadOriginals(for: fresh)
    }

    /// Fetches one page, or returns nil having decided what the failure means.
    ///
    /// A cancellation is not a failure and leaves `error` alone: the request
    /// stopped mattering, which is nothing the person using the app did or needs
    /// to know. Anything else is worth saying.
    ///
    /// A response for a filter that has since been replaced is treated the same
    /// way, as nil with `error` untouched: whatever it says, success or failure,
    /// is about a query nobody is looking at any more.
    private func fetchPage(_ page: Int) async -> PostPage? {
        let requestedGeneration = generation
        do {
            let result = try await api.postsPage(pairID: pairID, page: page, perPage: Self.pageSize, filter: filter)
            guard generation == requestedGeneration else { return nil }
            error = nil
            return result
        } catch let error as APIError where error.isCancellation {
            return nil
        } catch {
            guard generation == requestedGeneration else { return nil }
            self.error = APIError.userMessage(for: error)
            return nil
        }
    }
}
