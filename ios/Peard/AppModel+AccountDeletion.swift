import Foundation
import PeardCore
import SwiftUI
import UIKit

extension AppModel {
    // MARK: Account deletion

    /// Erases the account on the server, then tears the session down locally.
    ///
    /// The order matters: the delete needs the token, so the local cleanup can
    /// only follow it. A failure leaves the session intact and reports itself,
    /// because the alternative — signing somebody out of an account that still
    /// exists while telling them it is gone — is worse than an error message.
    ///
    /// Push and Live Activities are only torn down once the server has said
    /// yes. Doing it first meant a delete that failed — offline, a 500 — left
    /// somebody signed in to an account that still exists and silently no
    /// longer notified. The `devices` row goes with the account server-side,
    /// so all that is left to do here is forget the token locally; asking the
    /// server to delete it again would be a request made with the credentials
    /// of an account that no longer exists.
    ///
    /// Returns true when the account is gone, so the caller knows whether to
    /// dismiss its confirmation.
    @discardableResult
    func deleteAccount() async -> Bool {
        do {
            try await api.deleteAccount()
        } catch let error as APIError where error.status == 404 {
            // The route is missing, which means the app is talking to a server
            // older than this feature. Worth its own message: "Not found" tells
            // somebody trying to delete their account nothing at all, and the
            // fallback the privacy policy still documents — emailing us — does
            // work. An installed app cannot assume the server has caught up
            // with it, and this is the one request where failing opaquely is
            // least acceptable.
            banner = String(localized: "This server can't delete accounts in-app yet. Email \(PeardLinks.supportEmail) and we'll do it for you.")
            return false
        } catch {
            banner = APIError.userMessage(for: error)
            return false
        }
        // Deliberately not `signOut()`: that deletes the push registration again
        // against an account that no longer exists, which just produces a 404.
        await liveActivities.endAll()
        push.forgetRegistration()
        await sendQueue.removeAll()
        await refreshPendingSends()
        // The queue is empty now, so this removes every queued photo: they were
        // the deleted account's, and leaving them in the App Group container is
        // exactly what deleting an account is meant to prevent. Immediate —
        // the grace period is for a flush that finished mid-queueing, not for
        // a session that is over.
        pendingPhotos.removeAll(except: [], gracePeriod: 0)
        // And whatever the extensions left waiting goes with it, or the next
        // account to use the device would absorb and post it as their own.
        momentInbox.clear()
        sessionStore.clear()
        widgetSync.clear()
        forgetCachedConnections()
        connections = []
        profile = nil
        sharedStore.selectedConnectionID = nil
        focusedPostID = nil
        hasRequestedPushThisSession = false
        unreadWatermarks.removeAll()
        phase = .auth
        return true
    }

    /// Requirement 8.4 — a 401 clears the session and forces re-authentication.
    func clearSessionAndReturnToAuth() async {
        sessionStore.clear()
        widgetSync.clear()
        forgetCachedConnections()
        connections = []
        sharedStore.selectedConnectionID = nil
        focusedPostID = nil
        hasRequestedPushThisSession = false
        unreadWatermarks.removeAll()
        phase = .auth
    }

    /// Central 401 handling for callers that surface their own messages.
    /// Returns true when the error was a 401 and the session was cleared.
    @discardableResult
    func handleIfUnauthorized(_ error: Error) async -> Bool {
        guard let apiError = error as? APIError, case .unauthorized = apiError else { return false }
        await clearSessionAndReturnToAuth()
        return true
    }

    /// Requirement 15.4 and clarification Q17: local cleanup is authoritative
    /// and always completes; the remote device-registration delete is best
    /// effort and its failure is reported rather than blocking sign-out.
    func signOut() async {
        await liveActivities.endAll()
        await push.deleteRegistration()
        // Queued moments are discarded here but deliberately *not* in
        // clearSessionAndReturnToAuth: a 401 can just be an expired token, and
        // the same person will sign back in and still want their moments. Signing
        // out is a decision, and a queued send carries an author id that the next
        // account cannot post under anyway.
        await sendQueue.removeAll()
        await refreshPendingSends()
        // Immediate, not the pruner: nothing of this session's is left for a
        // later flush to clean up.
        pendingPhotos.removeAll(except: [], gracePeriod: 0)
        // The extensions' leftovers belong to this session too: without this,
        // the next sign-in absorbs them and posts them as the new account's.
        momentInbox.clear()
        sessionStore.clear()
        widgetSync.clear()
        forgetCachedConnections()
        connections = []
        profile = nil
        sharedStore.selectedConnectionID = nil
        focusedPostID = nil
        hasRequestedPushThisSession = false
        unreadWatermarks.removeAll()
        phase = .auth
    }

}
