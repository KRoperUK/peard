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
    private(set) var myTallies = TallyPeriods.zero
    private(set) var partnerTallies = TallyPeriods.zero
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
    }

    var signedInUserID: String { app.signedInUserID }
    var serverURL: URL { app.config.serverURL }

    var connection: Connection? { app.connections.first { $0.id == pairID } }
    var isGroup: Bool { connection?.isGroup ?? false }

    /// The other person's name in a 1:1. Groups have no single partner, so the
    /// per-author name is used instead.
    var partnerName: String { connection?.partnerName ?? PartnerLabel.fallback }
    var shortPartnerName: String { PartnerLabel.short(partnerName) }

    /// The pinned header's title: the connection's name, or who is in it.
    var connectionTitle: String { connection?.title() ?? PartnerLabel.fallback }

    /// Who the second tally row belongs to. A group has no single partner.
    var othersLabel: String { isGroup ? "Others" : shortPartnerName }

    /// The moments offered on the home screen.
    var moments: [Moment] { MomentCatalogue.available(customKinds: customKinds) }

    /// The recommended moments this connection has not published yet.
    var suggestedMoments: [Moment] { MomentCatalogue.unusedPresets(customKinds: customKinds) }

    /// The post shown in the hero: the notification-focused one when there is
    /// one, otherwise the most recent (Requirement 11.2, 18.7).
    var displayedPost: Post? {
        if let focusedPost { return focusedPost }
        return posts.first
    }

    /// The three posts after the most recent one (Requirement 11.9).
    var historyPosts: [Post] {
        guard posts.count > 1 else { return [] }
        return Array(posts.dropFirst().prefix(3))
    }

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
        MomentCatalogue.emoji(for: post, customKinds: customKinds)
    }

    func label(for kind: EventKind?) -> String {
        MomentCatalogue.label(for: kind, customKinds: customKinds)
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
        isLoading = false
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

    /// Requirement 12.8, 12.9.
    func refreshTallies() async {
        do {
            let events = try await api.eventPosts(pairID: pairID)
            let split = TallyPeriods.split(posts: events, signedInUserID: signedInUserID)
            myTallies = split.mine
            partnerTallies = split.partner
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
        await refreshCustomKinds()
        await refresh()
        await refreshTallies()
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
        if moment.needsPublishing {
            guard await publish(moment: moment) else { return }
        }

        do {
            let _: Post = try await api.create("posts", fields: [
                "pair": pairID,
                "author": signedInUserID,
                "type": PostType.event.rawValue,
                "event_kind": moment.kind.rawValue,
                "note": note,
            ])
        } catch {
            if await app.handleIfUnauthorized(error) { return }
            alert = AlertContent(title: "Couldn't log it", message: message(for: error))
            return
        }

        // Only on success (clarification Q3).
        showToast("\(moment.emoji) logged!")
        await refresh()
        await refreshTallies()
        app.widgetSync.reloadTimelines()
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
    func upload(image: UIImage) async {
        guard let data = image.jpegData(compressionQuality: 0.6), !data.isEmpty else {
            alert = AlertContent(title: "Upload failed", message: "The photo couldn't be prepared for upload.")
            return
        }
        busy = .photo
        defer { busy = nil }

        do {
            let _: Post = try await api.createMultipart(
                "posts",
                fields: [
                    "pair": pairID,
                    "author": signedInUserID,
                    "type": PostType.photo.rawValue,
                ],
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
            // Any other failure hides the reactions (clarification Q15).
            reactions = []
            banner = error.localizedDescription
        } catch {
            reactions = []
            banner = message(for: error)
        }
    }

    // MARK: Leaving

    /// Requirement 15.2, 15.3 — leaves this connection only.
    func leaveConnection() async {
        await app.leave(connectionID: pairID)
    }

    // MARK: Errors

    private func report(_ error: Error) async {
        if await app.handleIfUnauthorized(error) { return }
        banner = message(for: error)
    }

    private func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.localizedDescription
        }
        return error.localizedDescription
    }
}
