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

    private(set) var posts: [Post] = []
    private(set) var customKinds: [MomentKind] = []
    private(set) var isLoadingFirstPage = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var totalItems = 0
    private(set) var error: String?

    private var nextPage = 1

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
        member.user == signedInUserID ? "You" : PartnerLabel.short(member.name)
    }

    /// What the active filter is called, for the chip under the title.
    var filterSummary: String? {
        guard filter.isActive else { return nil }
        var parts: [String] = []
        if let author = filter.author {
            let member = connection?.members.first { $0.user == author }
            parts.append(member.map(memberLabel) ?? PartnerLabel.unknown)
        }
        // Both, not one or the other: a moment can carry a photo, so "Coffee ·
        // Photos" is a real narrowing rather than a contradiction.
        if let kind = filter.kind {
            parts.append(MomentCatalogue.label(for: kind, customKinds: customKinds))
        }
        if filter.photosOnly {
            parts.append("Photos")
        }
        return parts.joined(separator: " · ")
    }

    /// The moments in this timeline the signed-in user may change.
    ///
    /// Author only, and the server says the same: editing somebody else's
    /// account of their own evening is not something being in a group entitles
    /// you to. Checked here as well so the app does not offer a button that can
    /// only fail.
    func canEdit(_ post: Post) -> Bool { post.author == signedInUserID }

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
            self.error = (error as? APIError)?.localizedDescription ?? error.localizedDescription
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
            self.error = (error as? APIError)?.localizedDescription ?? error.localizedDescription
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
        unreadWatermark: Date? = nil
    ) {
        self.api = api
        self.pairID = pairID
        self.signedInUserID = signedInUserID
        self.customKinds = customKinds
        self.connection = connection
        self.calendar = calendar
        self.unreadWatermark = unreadWatermark
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
    var firstNewPostID: String? {
        posts.last(where: isNew)?.id
    }

    /// Moments grouped by day, newest day first.
    ///
    /// Posts with no timestamp (records predating the server's `created` field)
    /// decode as `distantPast`, which would otherwise open a section captioned with
    /// a date in year 1. They are collected under their own heading instead.
    var days: [Day] {
        var order: [Date] = []
        var grouped: [Date: [Post]] = [:]
        for post in posts {
            let key = post.hasTimestamp ? calendar.startOfDay(for: post.created) : Date.distantPast
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(post)
        }
        return order.map { Day(date: $0, posts: grouped[$0] ?? []) }
    }

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
        if post.author == signedInUserID { return "You" }
        if let name = connection?.name(forUser: post.author) {
            return PartnerLabel.short(name)
        }
        // Not a current member: they have left, but their moments stay in the
        // shared timeline. "Partner" would be wrong in a group.
        return PartnerLabel.unknown
    }

    func emoji(for post: Post) -> String {
        MomentCatalogue.emoji(for: post, customKinds: customKinds)
    }

    /// The author's photo, or their initials. A former member is not in the list
    /// any more, so there is nothing to draw but initials — consistent with
    /// `authorLabel` naming them "Someone".
    func avatar(forAuthor userID: String) -> Avatar {
        if let member = connection?.members.first(where: { $0.user == userID }) {
            return member.avatar
        }
        return Avatar(
            owner: .users,
            recordID: userID,
            filename: nil,
            placeholder: .make(name: PartnerLabel.unknown, key: userID)
        )
    }

    func detail(for post: Post) -> String {
        if let note = post.displayNote { return note }
        switch post.type {
        case .photo: return "photo"
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
        return formatter.string(from: post.created)
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
    func edit(_ post: Post, note: String, kind: EventKind?) async -> Bool {
        let trimmedNote = PostNote.normalised(note)
        let newKind = kind ?? post.eventKind
        // Only send what changed. A no-op edit would still move `updated` and
        // put an "edited" label on a moment nobody edited.
        let noteChanged = trimmedNote != (post.note ?? "")
        let kindChanged = newKind != post.eventKind
        guard noteChanged || kindChanged else { return true }

        do {
            try await api.editMoment(
                postID: post.id,
                note: noteChanged ? .some(trimmedNote) : nil,
                kind: kindChanged ? newKind : nil
            )
        } catch let error as APIError where error.status == 404 {
            // The route is missing, which means this app is talking to a server
            // older than the feature. An installed app cannot assume the server
            // has caught up with it — that assumption is what shipped account
            // deletion against a server that could not do it — and "Not found"
            // tells somebody trying to fix a typo nothing at all.
            self.error = "This server can't edit moments yet. Deleting and logging it again works."
            return false
        } catch {
            self.error = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            return false
        }

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
                updated: Date()
            )
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
            self.error = (error as? APIError)?.localizedDescription ?? error.localizedDescription
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
    }

    /// Fetches one page, or returns nil having decided what the failure means.
    ///
    /// A cancellation is not a failure and leaves `error` alone: the request
    /// stopped mattering, which is nothing the person using the app did or needs
    /// to know. Anything else is worth saying.
    private func fetchPage(_ page: Int) async -> PostPage? {
        do {
            let result = try await api.postsPage(pairID: pairID, page: page, perPage: Self.pageSize, filter: filter)
            error = nil
            return result
        } catch let error as APIError where error.isCancellation {
            return nil
        } catch {
            self.error = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            return nil
        }
    }
}

/// The timeline screen. A tab rather than a sheet, so reading back through the
/// shared timeline does not have to be dismissed to log anything.
struct HistoryView: View {
    @State private var model: HistoryModel
    @State private var editing: Post?
    @State private var deleting: Post?
    @State private var viewing: Post?
    private let serverURL: URL
    private let title: String

    init(model: HistoryModel, serverURL: URL, title: String) {
        _model = State(initialValue: model)
        self.serverURL = serverURL
        self.title = title
    }

    var body: some View {
        NavigationStack {
            content
                .background(PearColor.background)
                .navigationTitle("Timeline")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ConnectionToolbarTitle(
                            title: "Timeline",
                            subtitle: model.filterSummary ?? title
                        )
                    }
                    ToolbarItem(placement: .primaryAction) {
                        filterMenu
                    }
                }
                .refreshable { await model.reload() }
                .task { await model.loadFirstPage() }
        }
        .sheet(item: $editing) { post in
            MomentEditSheet(post: post, moments: model.moments, model: model)
        }
        // Full screen rather than a sheet: a sheet leaves the timeline showing
        // above it, and the whole point is the photo.
        .fullScreenCover(item: $viewing) { post in
            PhotoViewer(
                post: post,
                serverURL: serverURL,
                authorLabel: model.authorLabel(for: post),
                timestamp: model.time(for: post)
            )
        }
        // A swipe is easy to do by accident on a list you are scrolling, and this
        // one cannot be undone, so it asks. The sheet has its own confirmation
        // for the same reason.
        .confirmationDialog(
            "Delete this moment?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let post = deleting {
                    deleting = nil
                    Task { await model.delete(post) }
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("It goes from the shared timeline and stops counting towards the tallies.")
        }
    }

    /// Who and what, in one control.
    ///
    /// A menu rather than a row of chips: the timeline is already dense, the
    /// filter is off almost all the time, and a connection of twelve people
    /// with a dozen moments would need a scrolling bar of its own. The active
    /// filter shows in the subtitle instead, where the connection name usually
    /// is — so the screen always says what it is showing.
    private var filterMenu: some View {
        Menu {
            if model.filter.isActive {
                Button {
                    Task { await model.apply(.none) }
                } label: {
                    Label("Show everything", systemImage: "xmark.circle")
                }
            }

            Section("Who") {
                pick("Everyone", isOn: model.filter.author == nil) {
                    model.filter.choosing(author: nil)
                }
                ForEach(model.filterableMembers) { member in
                    pick(model.memberLabel(member), isOn: model.filter.author == member.user) {
                        model.filter.choosing(author: member.user)
                    }
                }
            }

            Section("What") {
                pick("Anything", isOn: model.filter.kind == nil && !model.filter.photosOnly) {
                    // Clears both, which is what "anything" has to mean now
                    // that they are two dimensions rather than one choice.
                    model.filter.choosing(kind: nil).choosingPhotos(false)
                }
                // A toggle, not a choice: a moment can carry a photo, so
                // "photos" narrows whatever else is selected rather than
                // replacing it. "Coffee · Photos" is a real question.
                pick("📷 Has a photo", isOn: model.filter.photosOnly) {
                    model.filter.choosingPhotos(!model.filter.photosOnly)
                }
                ForEach(model.moments) { moment in
                    pick("\(moment.emoji) \(moment.label)", isOn: model.filter.kind == moment.kind) {
                        // Tapping the selected moment clears it, so the only way
                        // back is not always through "Anything" — which would
                        // also throw away the photo filter.
                        model.filter.choosing(kind: model.filter.kind == moment.kind ? nil : moment.kind)
                    }
                }
            }
        } label: {
            Image(systemName: model.filter.isActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .foregroundStyle(PearColor.accent)
        }
        .accessibilityLabel(model.filter.isActive ? "Filtering by \(model.filterSummary ?? "")" : "Filter")
    }

    private func pick(_ label: String, isOn: Bool, to next: @escaping () -> TimelineFilter) -> some View {
        Button {
            Task { await model.apply(next()) }
        } label: {
            if isOn {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoadingFirstPage && model.posts.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.posts.isEmpty {
            emptyState
        } else {
            timeline
        }
    }

    /// Empty because nothing has happened, or empty because of the filter —
    /// two different facts, and the second one has something you can do about
    /// it. Telling somebody "nothing here yet" when they have just narrowed to
    /// one person's photos would be plainly untrue.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("🍐").font(.system(size: 48))
            Text(model.filter.isActive ? "Nothing matches that" : "Nothing here yet")
                .font(.headline)
                .foregroundStyle(PearColor.textPrimary)
            Text(model.filter.isActive
                ? "No moments for \(model.filterSummary ?? "that filter") in this connection."
                : "Moments you and everyone else log will build up here.")
                .font(.subheadline)
                .foregroundStyle(PearColor.textSecondary)
                .multilineTextAlignment(.center)
            if model.filter.isActive {
                Button("Show everything") {
                    Task { await model.apply(.none) }
                }
                .font(.footnote.bold())
                .foregroundStyle(PearColor.accent)
            }
            if let error = model.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(PearColor.error)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timeline: some View {
        List {
            ForEach(model.days) { day in
                Section {
                    ForEach(day.posts) { post in
                        // Above the oldest new moment, so the line separates
                        // "seen" from "new" the way it reads on screen: the
                        // timeline is newest-first, so everything above it is
                        // what arrived while you were away.
                        if post.id == model.firstNewPostID {
                            newMomentsDivider
                        }
                        row(for: post)
                    }
                } header: {
                    Text(model.heading(for: day))
                        .font(.footnote.bold())
                        .foregroundStyle(PearColor.accent)
                }
            }

            if model.hasMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .task { await model.loadMoreIfNeeded() }
            } else if model.totalItems > 0 {
                Text(model.totalItems == 1 ? "1 moment" : "\(model.totalItems) moments")
                    .font(.footnote)
                    .foregroundStyle(PearColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }

            if let error = model.error, !model.posts.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(PearColor.error)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// A labelled rule rather than a coloured dot per row: the useful thing is
    /// one boundary you can scroll to, not a repeated badge that leaves you
    /// counting.
    private var newMomentsDivider: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(PearColor.accent)
                .frame(height: 1)
            Text("New")
                .font(.caption2.bold())
                .foregroundStyle(PearColor.accent)
                .textCase(.uppercase)
            Rectangle()
                .fill(PearColor.accent)
                .frame(height: 1)
        }
        .padding(.vertical, 2)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement()
        .accessibilityLabel("New since you last looked")
    }

    private func row(for post: Post) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Only the thumbnail opens the photo, not the whole row: the row is
            // also the swipe and long-press target, and a tap that opened a
            // full-screen view from anywhere on it would fire every time
            // somebody meant to start a swipe.
            thumbnail(for: post)
                .onTapGesture {
                    if post.hasMedia { viewing = post }
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    AvatarView(avatar: model.avatar(forAuthor: post.author), serverURL: serverURL, size: 16)
                        .accessibilityHidden(true)
                    Text(model.authorLabel(for: post))
                        .font(.subheadline.bold())
                        .foregroundStyle(PearColor.textPrimary)
                }
                HStack(spacing: 4) {
                    Text(model.detail(for: post))
                        .font(.footnote)
                        .foregroundStyle(PearColor.textSecondary)
                    // Marked rather than hidden: a shared timeline is a record
                    // several people rely on, and a line that quietly changed
                    // under them is worse than one that says it changed.
                    if post.isEdited {
                        Text("· edited")
                            .font(.caption2)
                            .foregroundStyle(PearColor.textTertiary)
                    }
                }

                let kinds = model.reactionKinds(for: post)
                if !kinds.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(kinds, id: \.rawValue) { kind in
                            Text(kind.emoji).font(.caption2)
                        }
                    }
                    .padding(.top, 1)
                }
            }

            Spacer(minLength: 4)

            Text(model.time(for: post))
                .font(.caption2)
                .foregroundStyle(PearColor.textTertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .listRowBackground(PearColor.background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: post))
        // The combined element swallows the thumbnail's own tap target, so
        // VoiceOver gets the photo as a named action instead of losing it.
        .accessibilityAction(named: "Open photo") {
            if post.hasMedia { viewing = post }
        }
        .modifier(MomentActions(
            post: post,
            canEdit: model.canEdit(post),
            canReact: model.canReact(to: post),
            mine: Set(ReactionKind.allCases.filter { model.hasReacted(to: post, kind: $0) }.map(\.rawValue)),
            onEdit: { editing = post },
            onDelete: { deleting = post },
            onReact: { kind in Task { await model.toggleReaction(to: post, kind: kind) } }
        ))
    }

    private func accessibilityLabel(for post: Post) -> String {
        var parts = [model.authorLabel(for: post), model.detail(for: post)]
        if post.hasMedia { parts.append("photo") }
        if post.isEdited { parts.append("edited") }
        let time = model.time(for: post)
        if !time.isEmpty { parts.append(time) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func thumbnail(for post: Post) -> some View {
        // `hasMedia` rather than `type == .photo`: a moment can carry a photo
        // now, and keying on the type would draw its emoji and hide the picture.
        if post.hasMedia, let path = post.mediaThumbnailPath() {
            ProtectedImage(serverURL: serverURL, path: path) {
                ProgressView()
            } failure: {
                Text("📷").font(.title3)
            }
            .scaledToFill()
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Text(model.emoji(for: post))
                .font(.title3)
                .frame(width: 36, height: 36)
        }
    }
}

/// What you can do with a moment, which depends on whose it is.
///
/// Yours: edit or delete, by swipe *and* by long press. Both, because neither
/// alone is discoverable — a swipe is the iOS convention for a list row and is
/// what a practised thumb reaches for, and a context menu is what somebody
/// finds when they press the thing they want to change and wait.
///
/// Somebody else's: react to it. That used to be possible only on the home
/// screen's hero, so only ever to the single most recent moment — come back
/// after a day away and the things that happened while you were gone could be
/// read and not answered.
private struct MomentActions: ViewModifier {
    let post: Post
    let canEdit: Bool
    let canReact: Bool
    /// Raw values of the kinds the signed-in user has already used here, so the
    /// same control can offer to take one back. Raw values rather than the enum
    /// because `ReactionKind` carries an associated value and is not Hashable
    /// into a Set as cheaply.
    let mine: Set<String>
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onReact: (ReactionKind) -> Void

    func body(content: Content) -> some View {
        if canEdit {
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(PearColor.accent)
                }
                .contextMenu {
                    Button(action: onEdit) {
                        Label("Edit moment", systemImage: "pencil")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete moment", systemImage: "trash")
                    }
                }
        } else if canReact {
            content
                // Leading edge, so reacting and deleting are never the same
                // flick in the same direction on adjacent rows.
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    ForEach(ReactionKind.allCases, id: \.rawValue) { kind in
                        Button { onReact(kind) } label: {
                            Text(kind.emoji)
                        }
                        // The ones already used are filled in, so a swipe shows
                        // at a glance which of the three would be taken back.
                        .tint(mine.contains(kind.rawValue)
                            ? PearColor.accent.opacity(0.6)
                            : PearColor.accent.opacity(0.2))
                    }
                }
                .contextMenu {
                    ForEach(ReactionKind.allCases, id: \.rawValue) { kind in
                        Button { onReact(kind) } label: {
                            if mine.contains(kind.rawValue) {
                                Label("\(kind.emoji)  \(kind.accessibilityLabel)", systemImage: "checkmark")
                            } else {
                                Text("\(kind.emoji)  \(kind.accessibilityLabel)")
                            }
                        }
                    }
                }
        } else {
            content
        }
    }
}
