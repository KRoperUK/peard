import Foundation
import PeardCore
import SwiftUI
import UIKit

extension AppModel {
    // MARK: Send queue

    /// Reads the queue into observable state and starts watching the network, so a
    /// moment logged with no signal leaves as soon as there is one.
    ///
    /// Internal rather than private so the app-target tests can drive the real
    /// path instead of a test-only hook.
    func attachSendQueue() async {
        await refreshPendingSends()
        isOnline = reachability.isOnline
        isNetworkConstrained = reachability.isConstrained
        reachability.onConstrainedChange { [weak self] constrained in
            Task { @MainActor in self?.isNetworkConstrained = constrained }
        }
        reachability.onChange { [weak self] online in
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = online
                // Only on the way back up: going offline has nothing to send.
                if online { self.flushSendQueue() }
            }
        }
        reachability.start()
    }

    /// Copies the queue's contents into `pendingSends`.
    ///
    /// Called after every operation that can change the queue rather than through a
    /// callback registered at startup. The callback version meant the UI showed
    /// nothing at all if the registration had not happened yet — an ordering
    /// dependency with no visible symptom, which is the worst kind.
    func refreshPendingSends() async {
        pendingSends = await sendQueue.pending
    }

    /// Adds a moment to the queue. The queue persists it before anything is sent,
    /// so the moment survives the app being killed mid-request.
    func enqueue(_ send: PendingSend) async {
        await sendQueue.enqueue(send)
        await refreshPendingSends()
    }

    /// Answers a photo from the photo viewer (issue #304): words, or a photo
    /// of your own captioned with them. Here rather than on a screen's model
    /// because the viewer opens from both Home and the timeline, and the queue
    /// is the app's either way.
    ///
    /// Queued, then flushed, like any moment. Returns false only when nothing
    /// was queued — no words and no photo, or a photo that could not be kept
    /// to send; a reply that is merely waiting for signal has worked.
    @discardableResult
    func reply(to photo: Post, note: String, image: UIImage? = nil) async -> Bool {
        let data = image?.jpegData(compressionQuality: PhotoSquare.jpegQuality)
        if image != nil, data?.isEmpty ?? true { return false }
        guard let send = PendingSend.reply(to: photo, authorID: signedInUserID, note: note, withPhoto: data != nil),
              !send.authorID.isEmpty
        else { return false }
        if let data {
            do {
                try pendingPhotos.save(data, for: send.id)
            } catch {
                return false
            }
        }
        await enqueue(send)
        await flushSendQueueAndWait()
        return true
    }

    /// "Me too" or a reply from a moment's notification (issue #154): queued,
    /// then sent. Awaited rather than left to a background flush, because iOS
    /// may suspend the app again as soon as the action's handler returns.
    ///
    /// Not sent while the privacy gate is up; the queue holds it until the
    /// launch that follows agreement flushes.
    func answerFromNotification(_ moment: InboxedMoment) async {
        guard let send = moment.pendingSend(authorID: signedInUserID, fallbackPairID: nil),
              !send.authorID.isEmpty
        else { return }
        await enqueue(send)
        guard hasAgreedToPrivacyPolicy else { return }
        await flushSendQueueAndWait()
    }

    /// Kicks off a flush, coalescing with one already in flight. Non-blocking so
    /// callers on the main actor (a tap, a foreground) are never held up by it.
    ///
    /// Coalescing means returning while one is running, not cancelling it and
    /// starting again: bootstrap, reachability and foregrounding can all fire at
    /// once, and each cancel withdrew a request mid-flight while the replacement
    /// found the queue still flushing and did nothing (issue #58). The running
    /// flush picks up anything enqueued behind it, since it walks the queue
    /// rather than a copy.
    func flushSendQueue() {
        guard sessionStore.hasSession, flushTask == nil else { return }
        flushTask = Task { [weak self] in
            await self?.performFlush()
            self?.flushTask = nil
        }
    }

    #if DEBUG
    /// Awaits any in-flight flush and settles until none is pending, so a test
    /// can let the flush kicked by `reachability.start()` finish before it drives
    /// its own transitions — otherwise that startup flush races the one under
    /// test, and `flushSendQueue`'s `flushTask == nil` guard silently drops the
    /// second (the #384 flake).
    ///
    /// The reachability handler schedules the flush on a detached
    /// `Task { @MainActor in … }`, so `flushTask` is not set the instant a path
    /// update fires. Yield first to let that task run and set it, then await; a
    /// flush can chain another, so loop until the queue has been quiet across a
    /// couple of yields.
    func quiesceFlushForTesting() async {
        var quietRuns = 0
        for _ in 0..<400 {
            if let task = flushTask {
                quietRuns = 0
                await task.value
            } else {
                quietRuns += 1
                if quietRuns >= 3 { return }
                await Task.yield()
            }
        }
    }
    #endif

    /// Awaits a flush. Used where the caller wants the result before redrawing.
    ///
    /// `refreshingHome: false` is for a caller about to re-read the home
    /// screen itself. A flush that delivers something asks for a full home
    /// refresh, and a caller that then did its own fetched everything twice —
    /// the pull-to-refresh, the poll and the silent push all did, every time a
    /// queued moment went out with them (issue #302's audit).
    @discardableResult
    func flushSendQueueAndWait(refreshingHome: Bool = true) async -> FlushResult {
        guard sessionStore.hasSession else { return FlushResult() }
        return await performFlush(refreshingHome: refreshingHome)
    }

    @discardableResult
    func performFlush(refreshingHome: Bool = true) async -> FlushResult {
        await absorbMomentInbox()
        let api = self.api
        let photos = self.pendingPhotos
        let result = await sendQueue.flush { send in
            guard send.hasPhoto else {
                let _: Post = try await api.create("posts", fields: send.postFields)
                return
            }
            // A 400, so the queue treats it as permanent: no retry can bring
            // back a file that is gone, and retrying forever would hide it.
            guard let data = photos.load(for: send.id) else {
                throw APIError.server(status: 400, message: MissingPendingPhoto().errorDescription)
            }
            let _: Post = try await api.createMultipart(
                "posts",
                fields: send.postFields,
                file: MultipartFile(field: "media", filename: "pear.jpg", mimeType: "image/jpeg", data: data)
            )
        }
        await refreshPendingSends()
        prunePendingPhotos()

        // Reactions tapped from a notification that could not reach the server
        // then are drained here too (#366), so a Lock-Screen tap made offline
        // goes out on the next launch or foreground alongside queued moments.
        let reactionsDelivered = await push.flushPendingReactions()

        if result.didChangeAnything || reactionsDelivered {
            // A send that landed changes the timeline, the tallies and the widget.
            if refreshingHome { await onHomeRefreshRequested?() }
            widgetSync.reloadTimelines()
        }
        return result
    }

    /// Takes what the extensions could not send into the queue.
    ///
    /// Done at the top of every flush rather than only at launch and on
    /// foreground, which are the two that matter: those both flush, and so do
    /// the network coming back and a background push — each a moment the
    /// extensions' leftovers could go out too. A moment that named no
    /// connection goes to the one the app last showed, which survives an
    /// offline launch where the connection list does not. Photos from the
    /// share extension move into `pendingPhotos` on the way, so the flush that
    /// follows uploads them like any photo shared in the app.
    func absorbMomentInbox() async {
        guard let userID = sessionStore.userID else { return }
        let added = await sendQueue.absorb(
            momentInbox,
            authorID: userID,
            fallbackPairID: sharedStore.selectedConnectionID,
            photos: pendingPhotos
        )
        if added > 0 { await refreshPendingSends() }
    }

    /// Clears the failure history of abandoned sends so they are tried again.
    func retryStalledSends() async {
        await sendQueue.reviveStalled()
        await refreshPendingSends()
        await flushSendQueueAndWait()
    }

    /// Discards one connection's queued sends. Offered when a send has given up,
    /// because the alternative — a moment that can never be delivered sitting
    /// there forever — is worse than losing it deliberately. Scoped to the
    /// connection whose Settings offers it: other connections' moments and
    /// photos survive, and the prune below keeps their files for the same
    /// reason it drops this connection's.
    func discardPendingSends(forConnection pairID: String) async {
        await sendQueue.removeAll(forPair: pairID)
        await refreshPendingSends()
        prunePendingPhotos()
    }

    /// Changes what a queued send says before it goes: its note and, for a
    /// moment, which one it is (#313).
    ///
    /// Done against the queue, not the server — a queued send has no server
    /// record yet, so `HistoryModel.edit` would be asking the API to change a
    /// `pending:` id that does not exist. The emoji and label follow the kind
    /// so the pending row, which draws from them without consulting the
    /// catalogue, stays truthful; a send whose kind did not change keeps its
    /// own, which for a photo or a reply is deliberately blank.
    ///
    /// A send that had given up is revived: somebody who edits it is plainly
    /// not done with it, and leaving it stalled would make the fix pointless.
    /// One still retrying keeps its place and its backoff history is cleared
    /// too, since the thing that failed is no longer the thing being sent.
    func editPendingSend(id: String, note: String, kind: EventKind) async {
        guard let send = pendingSends.first(where: { $0.id == id }) else { return }
        let note = PostNote.normalised(note)
        var emoji = send.emoji
        var label = send.label
        if kind != send.kind {
            let customKinds = sharedStore.cachedMomentKinds(forConnection: send.pairID)
            emoji = MomentCatalogue.emoji(for: kind, customKinds: customKinds)
            label = MomentCatalogue.label(for: kind, customKinds: customKinds)
        }
        await sendQueue.update(id: id) {
            $0.edited(note: note, kind: kind, emoji: emoji, label: label).revived
        }
        await refreshPendingSends()
        await flushSendQueueAndWait()
    }

    /// Removes one queued send, and its photo if it has one. The send never
    /// reached the server, so there is nothing to delete there (#313).
    func deletePendingSend(id: String) async {
        await sendQueue.remove(id: id)
        await refreshPendingSends()
        prunePendingPhotos()
    }

    /// Deletes the photo files of sends that are no longer queued — sent,
    /// dropped as undeliverable, aged out, or discarded.
    func prunePendingPhotos() {
        pendingPhotos.removeAll(except: Set(pendingSends.map(\.id)))
    }

    /// Pending sends for one connection, newest last.
    func pendingSends(forConnection pairID: String) -> [PendingSend] {
        pendingSends.filter { $0.pairID == pairID }
    }

}
