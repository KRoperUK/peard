import Foundation
import PeardCore
import SwiftUI
import UIKit

/// Timeline, tallies, photo moments and reactions (Requirements 11–15).
@MainActor
@Observable
final class HomeModel {
    struct AlertContent: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    enum Busy: Equatable {
        case tally(EventKind)
        case photo
    }

    // MARK: Dependencies

    private let app: AppModel
    private let api: APIClient
    let pairID: String

    // MARK: State

    private(set) var posts: [Post] = []
    private(set) var focusedPost: Post?
    private(set) var reactions: [Reaction] = []
    private(set) var partnerName = PartnerLabel.fallback
    private(set) var myTallies = TallyPeriods.zero
    private(set) var partnerTallies = TallyPeriods.zero

    var pendingKind: EventKind?
    var noteText = ""
    private(set) var toast: String?
    private(set) var busy: Busy?
    var alert: AlertContent?
    private(set) var banner: String?
    private(set) var isLoading = false

    private var toastTask: Task<Void, Never>?

    init(app: AppModel, pairID: String) {
        self.app = app
        self.api = app.api
        self.pairID = pairID
    }

    var signedInUserID: String { app.signedInUserID }
    var serverURL: URL { app.config.serverURL }
    var shortPartnerName: String { PartnerLabel.short(partnerName) }

    /// The post shown in the card: the notification-focused one when there is
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

    /// Requirement 14.1 — reactions are offered on the partner's posts only.
    var canReactToDisplayedPost: Bool {
        guard let displayedPost else { return false }
        return displayedPost.author != signedInUserID
    }

    var isBusy: Bool { busy != nil }

    func authorLabel(for post: Post) -> String {
        post.author == signedInUserID ? "You" : shortPartnerName
    }

    // MARK: Loading

    func load() async {
        isLoading = true
        app.onHomeRefreshRequested = { [weak self] in
            await self?.refreshAll()
        }
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
            partnerName = await app.partners.partnerLabel(pairID: pairID, signedInUserID: signedInUserID)
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

    func refreshAll() async {
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

    // MARK: Tallies

    /// Requirement 12.2 — open the optional note field.
    func startTally(kind: EventKind) {
        pendingKind = kind
        noteText = ""
    }

    /// Requirement 12.6 — dismissing discards the text and creates nothing.
    func cancelTally() {
        pendingKind = nil
        noteText = ""
    }

    /// Requirement 12.3 – 12.5, 12.7.
    func submitTally() async {
        guard let kind = pendingKind else { return }
        let note = noteText
        pendingKind = nil
        noteText = ""
        busy = .tally(kind)
        defer { busy = nil }

        do {
            let _: Post = try await api.create("posts", fields: [
                "pair": pairID,
                "author": signedInUserID,
                "type": PostType.event.rawValue,
                "event_kind": kind.rawValue,
                "note": note,
            ])
        } catch {
            if await app.handleIfUnauthorized(error) { return }
            alert = AlertContent(title: "Couldn't log it", message: message(for: error))
            return
        }

        // Only on success (clarification Q3).
        showToast("\(EventKindCatalogue.emoji(for: kind)) logged!")
        await refresh()
        await refreshTallies()
        app.widgetSync.reloadTimelines()
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

    /// Requirement 15.2, 15.3.
    func leavePair() async {
        do {
            try await api.leavePair()
            await app.resolveMembership()
        } catch {
            if await app.handleIfUnauthorized(error) { return }
            await app.resolveMembership()
            app.banner = message(for: error)
        }
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
