import Foundation
import PeardCore
import SwiftUI
import UIKit

/// Timeline, tallies, moments, photo moments and reactions
/// (Requirements 11–15).
@MainActor
@Observable
final class HomeModel {
    struct AlertContent: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    enum Busy: Equatable {
        case moment(EventKind)
        case photo
        case publishingKind
    }

    // MARK: Dependencies

    private let app: AppModel
    private let api: APIClient
    let pairID: String
    // MARK: State

    private(set) var posts: [Post] = []
    private(set) var focusedPost: Post?
    private(set) var reactions: [Reaction] = []
    /// Counts as the server reported them, before locally queued sends are added.
    private(set) var serverTallies = ConnectionTallies.zero
    /// False when the counts came from the on-device fallback because the server
    /// has no tallies endpoint. Surfaced so the UI can say the numbers may be
    /// short rather than quietly lying.
    private(set) var talliesAreServerSide = true
    /// The connection's published custom moments.
    private(set) var customKinds: [MomentKind] = []

    /// The moment tapped but not yet written, with its countdown.
    private(set) var quickSend: QuickSend?
    /// Re-read on every tick so the countdown redraws.
    private(set) var quickSendCaption = ""
    private(set) var quickSendProgress: Double = 1

    var noteText = ""

    private(set) var toast: String?
    private(set) var busy: Busy?
    var alert: AlertContent?
    private(set) var banner: String?
    private(set) var isLoading = false

    private var toastTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?

    init(app: AppModel, pairID: String) {
        self.app = app
        self.api = app.api
        self.pairID = pairID
        // Seeded with the connection id, not `.zero`, whose `pair` is empty:
        // `adding(pending:)` matches queued sends on it, so an empty seed would
        // silently drop every pending moment until the first successful fetch —
        // which is precisely the offline first-launch case.
        self.serverTallies = ConnectionTallies(pair: pairID, mine: .zero, others: .zero, kinds: [])
    }

    var signedInUserID: String { app.signedInUserID }
    var serverURL: URL { app.config.serverURL }
    /// Handed to the timeline tab, which builds its own paged model against the
    /// same client rather than duplicating the session plumbing.
    var apiClient: APIClient { api }

    var connection: Connection? { app.connections.first { $0.id == pairID } }
    var isGroup: Bool { connection?.isGroup ?? false }

    /// The other person's name in a 1:1. Groups have no single partner, so the
    /// per-author name is used instead.
    var partnerName: String { connection?.partnerName ?? PartnerLabel.fallback }
    var shortPartnerName: String { PartnerLabel.short(partnerName) }

    /// The pinned header's title: the connection's name, or who is in it.
    var connectionTitle: String { connection?.title() ?? PartnerLabel.fallback }

    /// Who the second tally row belongs to. The rule lives on `Connection`, where
    /// it is pure; this only applies the row's width limit, which is a no-op on
    /// both neutral labels.
    var othersLabel: String {
        PartnerLabel.short(connection?.othersLabel ?? PartnerLabel.unknown)
    }

    // MARK: Tallies

    /// Counts including anything still queued on this device.
    private var tallies: ConnectionTallies {
        serverTallies.adding(pending: pendingSends)
    }

    var myTallies: TallyPeriods { tallies.mine }
    var partnerTallies: TallyPeriods { tallies.others }

    /// The connection's counts broken down by moment, including anything still
    /// queued on this device. What the moment breakdown draws.
    ///
    /// Handed over whole rather than pre-ranked: the breakdown re-ranks as the
    /// window changes, and a moment's position in "Today" has nothing to do with
    /// its position in "All".
    var momentTallies: ConnectionTallies { tallies }

    /// True when there is a per-moment breakdown to show. False against a server
    /// predating `GET /api/peard/tallies`, whose fallback can only produce the
    /// two side totals.
    var hasMomentBreakdown: Bool { tallies.hasKindBreakdown }

    /// The connection's most-logged moments, for the home screen's one-line
    /// summary. Capped because that line has to stay one line — the full list
    /// lives behind it, where it can be as long as the connection is inventive.
    var topMoments: [ConnectionTallies.Kind] {
        Array(tallies.rankedKinds(in: .all).prefix(4))
    }

    // MARK: Pending sends

    /// Moments logged here that the server has not accepted yet.
    var pendingSends: [PendingSend] { app.pendingSends(forConnection: pairID) }

    /// Sends that have exhausted their retries and need the user to decide.
    var stalledSends: [PendingSend] { pendingSends.filter(\.hasGivenUp) }

    var isOffline: Bool { !app.isOnline }

    /// What to say about the queue, or nothing when it is empty.
    var pendingSummary: String? {
        let count = pendingSends.count
        guard count > 0 else { return nil }
        if !stalledSends.isEmpty {
            return stalledSends.count == 1
                ? "1 moment couldn't be sent"
                : "\(stalledSends.count) moments couldn't be sent"
        }
        let noun = count == 1 ? "moment" : "moments"
        return isOffline ? "\(count) \(noun) waiting for signal" : "Sending \(count) \(noun)…"
    }

    /// The moments offered on the home screen.
    var moments: [Moment] { MomentCatalogue.available(customKinds: customKinds) }

    /// When each moment last happened here, keyed by kind.
    ///
    /// From the tallies rather than the loaded timeline: the home screen holds
    /// a page, so a moment nobody has logged for a month is exactly the one the
    /// page would not contain — and it is the one worth saying "5w" about.
    ///
    /// A queued send counts. It has not reached the server, but it happened,
    /// and a tile reading "3w" a second after being tapped would be wrong in
    /// the way people notice.
    var lastLoggedByKind: [String: Date] {
        var result: [String: Date] = [:]
        for kind in serverTallies.kinds {
            if let lastAt = kind.lastAt {
                result[kind.kind.rawValue] = lastAt
            }
        }
        for send in pendingSends {
            let slug = send.kind.rawValue
            if result[slug].map({ send.queuedAt > $0 }) ?? true {
                result[slug] = send.queuedAt
            }
        }
        return result
    }

    /// The recommended moments this connection has not published yet.
    var suggestedMoments: [Moment] { MomentCatalogue.unusedPresets(customKinds: customKinds) }

    /// The timeline as the user sees it: queued moments first (they are the most
    /// recent by definition), then what the server has.
    ///
    /// A queued moment appears here the instant it is tapped. Without that, logging
    /// something offline would look like it did nothing at all.
    var timeline: [Post] {
        pendingSends
            .sorted { $0.queuedAt > $1.queuedAt }
            .map(\.optimisticPost) + posts
    }

    /// The post shown in the hero: the notification-focused one when there is
    /// one, otherwise the most recent (Requirement 11.2, 18.7).
    var displayedPost: Post? {
        if let focusedPost { return focusedPost }
        return timeline.first
    }

    /// True when the hero is showing a moment that has not reached the server.
    var displayedPostIsPending: Bool {
        displayedPost.map { $0.id.hasPrefix("pending:") } ?? false
    }

    /// The three posts after the most recent one (Requirement 11.9).
    var historyPosts: [Post] {
        guard timeline.count > 1 else { return [] }
        return Array(timeline.dropFirst().prefix(3))
    }

    /// True when there is more timeline than the home screen shows, so the
    /// history screen is worth offering.
    var hasMoreHistory: Bool { timeline.count > 4 }

    /// Requirement 14.1 — reactions are offered on other people's posts only.
    var canReactToDisplayedPost: Bool {
        guard let displayedPost else { return false }
        return displayedPost.author != signedInUserID
    }

    var isBusy: Bool { busy != nil }

    /// Names the post's author. In a group this is the individual, not "Others",
    /// so a shared timeline reads as a conversation.
    func authorLabel(for post: Post) -> String {
        if post.author == signedInUserID { return "You" }
        if let name = connection?.name(forUser: post.author) {
            return PartnerLabel.short(name)
        }
        // Not a current member: they have left, but their moments stay. Naming
        // them "Partner" is only right when there is exactly one other person.
        if let partnerName = connection?.partnerName {
            return PartnerLabel.short(partnerName)
        }
        return PartnerLabel.unknown
    }

    func emoji(for post: Post) -> String {
        // A queued send carries its own emoji and label, which matters when the
        // moment is a custom one that has not been published yet: the connection's
        // catalogue does not know it, so the catalogue lookup would draw a pear.
        if let pending = pendingSend(for: post) { return pending.emoji }
        return MomentCatalogue.emoji(for: post, customKinds: customKinds)
    }

    func label(for kind: EventKind?) -> String {
        MomentCatalogue.label(for: kind, customKinds: customKinds)
    }

    /// The queue entry a timeline row came from, when it came from one.
    func pendingSend(for post: Post) -> PendingSend? {
        guard post.id.hasPrefix("pending:") else { return nil }
        let id = String(post.id.dropFirst("pending:".count))
        return pendingSends.first { $0.id == id }
    }

    /// Describes a moment for the timeline, preferring the queue entry's own label.
    func caption(for post: Post) -> String {
        if let pending = pendingSend(for: post) { return pending.label }
        switch post.type {
        case .event:
            return label(for: post.eventKind)
        case .photo:
            return "shared a moment"
        case .unknown(let value):
            return value
        }
    }

    // MARK: Loading

    func load() async {
        isLoading = true
        app.onHomeRefreshRequested = { [weak self] in
            await self?.refreshAll()
        }
        await refreshCustomKinds()
        await refresh()
        await refreshTallies()
        await refreshRecap()
        isLoading = false
        // After the posts are in, not before: the stamp means "you have seen up
        // to here", and claiming it while the request that fetches them could
        // still fail would clear a badge for moments never actually shown.
        await app.markSelectedConnectionSeen()
    }

    /// Requirement 11.1, 11.11 – 11.13.
    func refresh() async {
        do {
            posts = try await api.recentPosts(pairID: pairID, limit: 5)
            await resolveFocusedPost()
            await loadReactions()
            banner = nil
        } catch {
            await report(error)
        }
    }

    /// Requirement 12.8, 12.9 — counted server-side.
    ///
    /// One aggregate request replaces fetching up to 500 event posts and counting
    /// them on the device. That fetch also capped out: past 500 event posts the
    /// all-time tally silently undercounted, which a busy group reaches in weeks.
    ///
    /// Locally queued sends are merged in on top, so a moment logged with no signal
    /// moves the number the moment it is tapped rather than when it is delivered.
    /// The last week, and how long the connection has kept going.
    ///
    /// Nil until it arrives, and left alone when it cannot be fetched: a recap
    /// is a summary of what the rest of the screen already shows, so a failure
    /// hides one card rather than reporting anything. Absent entirely against a
    /// server predating the route, which an installed app cannot assume has
    /// caught up with it.
    private(set) var recap: MomentRecap?

    func refreshRecap() async {
        do {
            recap = try await api.recap(pairID: pairID)
        } catch let error as APIError where error.status == 404 || error.isCancellation {
            // Older server, or a refresh that was replaced by the next one.
            // Neither is worth a word on screen.
        } catch {
            // Deliberately not `report`: see above.
        }
    }

    func refreshTallies() async {
        do {
            serverTallies = try await api.tallies(pairID: pairID)
            talliesAreServerSide = true
            banner = nil
        } catch let error as APIError where error.status == 404 {
            // A server that predates GET /api/peard/tallies. Fall back to counting
            // on the device rather than showing nothing.
            await refreshTalliesLocally()
        } catch {
            await report(error)
        }
    }

    /// The pre-endpoint path, kept for older servers only. Inaccurate past 500
    /// event posts, which is exactly why the endpoint exists.
    private func refreshTalliesLocally() async {
        do {
            let events = try await api.eventPosts(pairID: pairID)
            let split = TallyPeriods.split(posts: events, signedInUserID: signedInUserID)
            serverTallies = ConnectionTallies(
                pair: pairID,
                mine: split.mine,
                others: split.partner,
                kinds: []
            )
            talliesAreServerSide = false
        } catch {
            await report(error)
        }
    }

    /// The connection's custom moments. A failure here is not worth a banner:
    /// the built-in moments still work, so it degrades rather than blocks.
    func refreshCustomKinds() async {
        do {
            customKinds = try await api.momentKinds(pairID: pairID)
        } catch {
            await app.handleIfUnauthorized(error)
        }
    }

    func refreshAll() async {
        // The connection list is part of what the header shows, and it changes
        // from outside this screen: somebody renames the group, a member joins,
        // another connection is added on another device.
        await app.refreshConnections()
        // Also drain the queue. Reachability covers the network coming back and
        // foregrounding covers everything that changed while the app was away, but
        // neither fires when the *server* is briefly unreachable with the app open —
        // the path is fine, so nothing changes. Without this a queued moment would
        // sit there until the app was backgrounded and reopened.
        await app.flushSendQueueAndWait()
        await refreshCustomKinds()
        await refresh()
        await refreshTallies()
        await refreshRecap()
    }

    func focus(postID: String?) async {
        guard let postID else {
            focusedPost = nil
            await loadReactions()
            return
        }
        if let match = posts.first(where: { $0.id == postID }) {
            focusedPost = match
        } else {
            focusedPost = try? await api.first("posts", of: Post.self, filter: PeardFilter.equals("id", postID))
        }
        await loadReactions()
    }

    private func resolveFocusedPost() async {
        guard let focusedID = focusedPost?.id else { return }
        if let match = posts.first(where: { $0.id == focusedID }) {
            focusedPost = match
        }
    }

    /// Requirement 14.3.
    private func loadReactions() async {
        guard let post = displayedPost else {
            reactions = []
            return
        }
        do {
            reactions = try await api.reactions(postID: post.id)
        } catch {
            reactions = []
        }
    }

    var displayedReactionKinds: [ReactionKind] {
        var seen: [ReactionKind] = []
        for reaction in reactions where !seen.contains(reaction.kind) {
            seen.append(reaction.kind)
        }
        return seen
    }

    // MARK: Quick send

    /// Tapping a moment commits it: the countdown exists only so a note can be
    /// added or the send undone. Tapping the same moment again sends at once;
    /// tapping a different one commits what was pending and starts over, so
    /// moments can be logged back to back.
    func tap(moment: Moment) {
        if let pending = quickSend {
            if pending.moment.kind == moment.kind {
                Task { await commitQuickSend() }
                return
            }
            Task {
                await commitQuickSend()
                begin(moment: moment)
            }
            return
        }
        begin(moment: moment)
    }

    private func begin(moment: Moment) {
        noteText = ""
        let send = QuickSend(moment: moment)
        quickSend = send
        quickSendCaption = send.caption()
        quickSendProgress = 1
        startCountdown()
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                guard let self, let send = self.quickSend else { return }
                let now = Date()
                self.quickSendCaption = send.caption(now: now)
                self.quickSendProgress = send.progressRemaining(now: now)
                if send.shouldSend(now: now) {
                    // Commit from a fresh task, not this one: commitQuickSend
                    // cancels the countdown, and a task that cancels itself
                    // cancels its own in-flight request with it — which showed
                    // up as "Couldn't log it: cancelled".
                    Task { await self.commitQuickSend() }
                    return
                }
            }
        }
    }

    /// Typing a note holds the send: somebody mid-sentence has not finished
    /// saying what they meant. It stays held once engaged, so the text cannot be
    /// sent out from under them by clearing the field. Called by the view on
    /// every edit rather than from a `didSet`, because `@Observable` rewrites
    /// stored properties into accessors and property observers on them are not
    /// a contract worth relying on.
    func noteDidChange() {
        guard var send = quickSend, !send.isHeld, !noteText.isEmpty else { return }
        send.isHeld = true
        quickSend = send
        quickSendCaption = send.caption()
        quickSendProgress = 1
        countdownTask?.cancel()
        countdownTask = nil
    }

    /// Requirement 12.6 — dismissing discards the text and creates nothing.
    func cancelQuickSend() {
        countdownTask?.cancel()
        countdownTask = nil
        quickSend = nil
        noteText = ""
    }

    func sendNow() async {
        await commitQuickSend()
    }

    /// Requirement 12.3 – 12.5, 12.7.
    ///
    /// The moment goes onto the durable queue first, then the queue is flushed.
    /// That ordering is the whole point: the previous version posted directly and
    /// showed "Couldn't log it" on failure, throwing away a moment somebody had
    /// deliberately logged — and the moments this app is for happen in pub
    /// basements and on trains.
    private func commitQuickSend() async {
        guard let send = quickSend else { return }
        countdownTask?.cancel()
        countdownTask = nil
        let moment = send.moment
        let note = noteText
        quickSend = nil
        noteText = ""
        busy = .moment(moment.kind)
        defer { busy = nil }

        // A preset only exists locally until it is published, and a moment
        // nobody else can name is not worth logging, so publishing comes first.
        // Publishing needs the network; when it is unavailable the moment is still
        // queued, and the kind is published on the next successful attempt.
        if moment.needsPublishing, !isOffline {
            guard await publish(moment: moment) else { return }
        }

        await app.enqueue(PendingSend(
            pairID: pairID,
            authorID: signedInUserID,
            kind: moment.kind,
            emoji: moment.emoji,
            label: moment.label,
            note: note
        ))

        // The moment is recorded on the device now, so the confirmation is honest
        // whether or not the request gets through.
        showToast(isOffline ? "\(moment.emoji) saved — will send" : "\(moment.emoji) logged!")

        let result = await app.flushSendQueueAndWait()
        if result.sent > 0 {
            await refresh()
            await refreshTallies()
        }
    }

    /// Retries sends that have given up, after the user asks.
    func retryPendingSends() async {
        await app.retryStalledSends()
        await refresh()
        await refreshTallies()
    }

    /// Discards the queue after the user decides the moments are no longer worth
    /// sending.
    func discardPendingSends() async {
        await app.discardPendingSends()
    }

    // MARK: Custom moments

    /// Publishes a moment to the connection so every member draws it the same
    /// way. Returns false only when the moment could not be published at all.
    @discardableResult
    func publish(moment: Moment) async -> Bool {
        do {
            let created = try await api.createMomentKind(
                pairID: pairID,
                slug: moment.kind.rawValue,
                emoji: moment.emoji,
                label: moment.label,
                createdBy: signedInUserID
            )
            customKinds.append(created)
            return true
        } catch let error as APIError {
            if case .unauthorized = error {
                await app.clearSessionAndReturnToAuth()
                return false
            }
            // 400 is the unique index rejecting a slug somebody else published
            // first, which is the outcome we wanted anyway.
            if error.status == 400 {
                await refreshCustomKinds()
                return customKinds.contains { $0.slug == moment.kind }
            }
            alert = AlertContent(title: "Couldn't add that moment", message: error.localizedDescription)
            return false
        } catch {
            alert = AlertContent(title: "Couldn't add that moment", message: message(for: error))
            return false
        }
    }

    /// Adds a moment typed into the custom sheet, then starts its countdown so
    /// creating one also logs it.
    func addCustomMoment(label: String, emoji: String) async {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else { return }
        let slug = MomentSlug.make(from: trimmedLabel)

        // An existing slug needs no second row; just log it.
        if let existing = MomentCatalogue.descriptor(for: EventKind(rawValue: slug), customKinds: customKinds),
           !existing.needsPublishing {
            tap(moment: existing)
            return
        }

        busy = .publishingKind
        let moment = Moment(
            kind: EventKind(rawValue: slug),
            emoji: MomentEmoji.first(in: emoji) ?? MomentCatalogue.fallbackEmoji,
            label: String(trimmedLabel.prefix(MomentSlug.maxLength)),
            origin: .preset
        )
        let published = await publish(moment: moment)
        busy = nil
        guard published else { return }

        if let stored = MomentCatalogue.descriptor(for: moment.kind, customKinds: customKinds) {
            tap(moment: stored)
        }
    }

    /// Adds a recommended moment and logs it in the same gesture.
    func addSuggested(moment: Moment) async {
        busy = .publishingKind
        let published = await publish(moment: moment)
        busy = nil
        guard published, let stored = MomentCatalogue.descriptor(for: moment.kind, customKinds: customKinds) else {
            return
        }
        tap(moment: stored)
    }

    /// Renames a published moment, or changes its emoji.
    ///
    /// The slug never moves. It is what every post already logged stores in
    /// `event_kind`, so editing it would orphan the history — a year of dog
    /// walks would stop resolving and start drawing as bare slugs. Which means
    /// a rename relabels the past as well as the future, and that is the point:
    /// somebody editing "Dog wlak" wants the typo gone everywhere, not a second
    /// moment that splits the tallies in two.
    ///
    /// Any member may do this, matching the server's UpdateRule. The moment
    /// belongs to the connection rather than to whoever typed it first —
    /// unlike removal, which stays with its author.
    func editCustom(moment: Moment, label: String, emoji: String) async {
        guard case .custom(let recordID) = moment.origin, let recordID else { return }
        let trimmedLabel = String(
            label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(MomentSlug.maxLength)
        )
        let chosenEmoji = MomentEmoji.first(in: emoji) ?? moment.emoji
        guard !trimmedLabel.isEmpty else { return }
        // Nothing to send, and a no-op write would still bump `updated` and
        // repaint every member's catalogue.
        guard trimmedLabel != moment.label || chosenEmoji != moment.emoji else { return }

        busy = .publishingKind
        defer { busy = nil }
        do {
            let updated = try await api.updateMomentKind(id: recordID, emoji: chosenEmoji, label: trimmedLabel)
            if let index = customKinds.firstIndex(where: { $0.id == recordID }) {
                customKinds[index] = updated
            }
            // Every other surface draws this moment through the catalogue, and
            // the widget keeps its own copy of the feed.
            app.widgetSync.reloadTimelines()
        } catch {
            if await app.handleIfUnauthorized(error) { return }
            alert = AlertContent(
                title: "Couldn't save that",
                message: "The moment is unchanged. Check your connection and try again."
            )
        }
    }

    /// Removes a published moment. Existing posts keep their kind, so past
    /// tallies are unaffected; the moment just stops being offered.
    func removeCustom(moment: Moment) async {
        guard case .custom(let recordID) = moment.origin, let recordID else { return }
        do {
            try await api.deleteMomentKind(id: recordID)
            customKinds.removeAll { $0.id == recordID }
        } catch {
            if await app.handleIfUnauthorized(error) { return }
            alert = AlertContent(
                title: "Couldn't remove it",
                message: "Only whoever added a moment can remove it."
            )
        }
    }

    // MARK: Connection

    /// Names the connection, which is what makes a group identifiable in the
    /// switcher and in push copy.
    func rename(to name: String) async {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        do {
            _ = try await api.renameConnection(pairID: pairID, name: trimmed)
            await app.refreshConnections()
        } catch {
            if await app.handleIfUnauthorized(error) { return }
            banner = message(for: error)
        }
    }

    /// True when this connection's notifications are silenced.
    var isMuted: Bool { connection?.isMuted ?? false }

    /// True when the signed-in user may remove other members.
    var canRemoveMembers: Bool { connection?.isOwnedByMe ?? false }

    /// Everybody else in the connection.
    var otherMembers: [Connection.Member] { connection?.others ?? [] }

    /// Silences or unsilences this connection.
    func setMuted(_ muted: Bool) async {
        await app.setMuted(connectionID: pairID, muted: muted)
    }

    /// The connection's photo, or what to draw instead.
    var connectionAvatar: Avatar {
        connection?.avatar ?? Avatar(
            owner: .pairs,
            recordID: pairID,
            filename: nil,
            placeholder: .make(name: connectionTitle, key: pairID, isGroup: isGroup)
        )
    }

    /// True when somebody has set a photo on the connection itself, as opposed to
    /// a 1:1 borrowing the other person's — so "Remove" is only offered when there
    /// is something to remove.
    var connectionHasOwnAvatar: Bool { connection?.hasOwnAvatar ?? false }

    /// Sets the connection's photo. Any member may, as with renaming.
    func updateConnectionAvatar(jpeg data: Data) async {
        await app.updateConnectionAvatar(connectionID: pairID, jpeg: data)
    }

    func removeConnectionAvatar() async {
        await app.removeConnectionAvatar(connectionID: pairID)
    }

    /// The avatar for a post's author, for the timeline rows.
    ///
    /// A former member is not in the list any more, so there is nothing to draw
    /// but initials — which is consistent with `authorLabel` naming them "Someone".
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

    /// Removes somebody from this connection. Their moments stay in the shared
    /// timeline and are attributed to "Someone" from then on.
    func remove(member: Connection.Member) async {
        await app.removeMember(connectionID: pairID, userID: member.user)
        await refresh()
        await refreshTallies()
    }

    /// Requirement 12.4 — 1.5 seconds, then removed.
    private func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Photo moments

    /// Requirement 13.4 – 13.6, 13.8. A photo post is never created without
    /// image data (clarification Q13).
    /// Shares a photo, optionally as part of a moment.
    ///
    /// With a moment the post is an `event` that happens to carry an image,
    /// not a `photo` — which is what makes it count in the tallies, the recap
    /// and the streak. That is the whole point of attaching one: "coffee, and
    /// here it is" is one coffee, not a coffee and a separate picture that the
    /// counters ignore.
    ///
    /// Without one it stays a `photo`, exactly as before: a picture with
    /// nothing to count.
    ///
    /// The caption is the same `note` a moment carries — a photo's note has
    /// always been displayed and editable as a caption, so this only adds the
    /// point at which it can first be written.
    func upload(image: UIImage, moment: Moment? = nil, caption: String = "") async {
        guard let data = image.jpegData(compressionQuality: 0.6), !data.isEmpty else {
            alert = AlertContent(title: "Upload failed", message: "The photo couldn't be prepared for upload.")
            return
        }
        busy = .photo
        defer { busy = nil }

        var fields = [
            "pair": pairID,
            "author": signedInUserID,
            "type": PostType.photo.rawValue,
        ]
        if let moment {
            fields["type"] = PostType.event.rawValue
            fields["event_kind"] = moment.kind.rawValue
        }
        // The sheet normalises this already; doing it again here means no other
        // caller can hand the server something it will reject with a 400.
        let note = PostNote.normalised(caption)
        if !note.isEmpty {
            fields["note"] = note
        }

        do {
            let _: Post = try await api.createMultipart(
                "posts",
                fields: fields,
                file: MultipartFile(
                    field: "media",
                    filename: "pear.jpg",
                    mimeType: "image/jpeg",
                    data: data
                )
            )
        } catch {
            if await app.handleIfUnauthorized(error) { return }
            alert = AlertContent(title: "Upload failed", message: message(for: error))
            return
        }

        await refresh()
        app.widgetSync.reloadTimelines()
    }

    // MARK: Reactions

    /// Whether the signed-in user has already used this kind on the hero, which
    /// is what makes the button a toggle rather than a one-way door.
    func hasReacted(kind: ReactionKind) -> Bool {
        myReaction(kind: kind) != nil
    }

    private func myReaction(kind: ReactionKind) -> Reaction? {
        reactions.first { $0.user == signedInUserID && $0.kind == kind }
    }

    /// Adds the reaction, or takes it back if it is already there.
    ///
    /// Same control for both, because "cheers" and "un-cheers" are the same
    /// thought — and tapping the wrong one of three emoji is easy enough that
    /// add-only left people stuck with it.
    func toggleReaction(kind: ReactionKind) async {
        if myReaction(kind: kind) != nil {
            await unreact(kind: kind)
        } else {
            await react(kind: kind)
        }
    }

    private func unreact(kind: ReactionKind) async {
        // `reactions` only ever holds the displayed post's, so finding one of
        // mine is enough — there is nothing else it could belong to.
        guard let mine = myReaction(kind: kind) else { return }
        do {
            try await api.removeReaction(id: mine.id)
        } catch let error as APIError where error.status == 404 {
            // Already gone — another device, or a retry. Reloading below simply
            // catches this one up.
        } catch let error as APIError {
            if case .unauthorized = error {
                await app.clearSessionAndReturnToAuth()
                return
            }
            guard isWorthReporting(error) else { return }
            banner = error.localizedDescription
            return
        } catch {
            guard isWorthReporting(error) else { return }
            banner = message(for: error)
            return
        }
        await loadReactions()
        banner = nil
    }

    /// Requirement 14.2, 14.4, 14.5.
    func react(kind: ReactionKind) async {
        guard let post = displayedPost else { return }
        do {
            let _: Reaction = try await api.create("reactions", fields: [
                "post": post.id,
                "user": signedInUserID,
                "kind": kind.rawValue,
            ])
            await loadReactions()
            banner = nil
        } catch let error as APIError {
            if case .unauthorized = error {
                await app.clearSessionAndReturnToAuth()
                return
            }
            if error.status == 400 {
                // The unique index rejected a duplicate: surface the existing
                // reaction and no error (Requirement 14.4).
                await loadReactions()
                banner = nil
                return
            }
            // Any other failure hides the reactions (clarification Q15) —
            // except a cancellation, which is not a failure and must not take
            // the reactions down with it.
            guard isWorthReporting(error) else { return }
            reactions = []
            banner = error.localizedDescription
        } catch {
            guard isWorthReporting(error) else { return }
            reactions = []
            banner = message(for: error)
        }
    }

    // MARK: Leaving

    /// Requirement 15.2, 15.3 — leaves this connection only, optionally taking
    /// the caller's own moments in it out of the shared timeline.
    func leaveConnection(deletingMoments: Bool = false) async {
        await app.leave(connectionID: pairID, deletingMoments: deletingMoments)
    }

    // MARK: Errors

    private func report(_ error: Error) async {
        if await app.handleIfUnauthorized(error) { return }
        guard isWorthReporting(error) else { return }
        banner = message(for: error)
    }

    private func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.localizedDescription
        }
        return error.localizedDescription
    }

    /// Whether this error is worth putting in front of somebody.
    ///
    /// A cancellation is not: the home screen refreshes on foreground, on a
    /// timer and on pull, and any of those can be cancelled by the next one
    /// starting. Reporting them turned ordinary churn into a banner.
    private func isWorthReporting(_ error: Error) -> Bool {
        !((error as? APIError)?.isCancellation ?? false)
    }
}
