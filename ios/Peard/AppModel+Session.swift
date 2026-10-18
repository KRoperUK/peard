import Foundation
import PeardCore
import SwiftUI
import UIKit

extension AppModel {
    // MARK: Session

    /// Persists a session and routes from the resulting membership
    /// (Requirement 9.7). Throws when the session cannot be persisted, so the
    /// caller can show the failure (clarification Q2).
    func establish(_ session: Session) async throws {
        try sessionStore.save(token: session.token, userID: session.userID)
        await widgetSync.sync()
        await resolveMembership()
        applyPendingPairCode()
    }

    /// Requirement 9.3 – 9.6. A user may belong to several connections, so this
    /// loads all of them and lands on the remembered one.
    func resolveMembership() async {
        guard sessionStore.hasSession, sessionStore.userID != nil else {
            phase = .auth
            return
        }
        membershipFailed = false
        do {
            connections = try await api.connections()
            rememberConnections()
            guard let selected = resolvedSelection() else {
                phase = .connections
                return
            }
            sharedStore.selectedConnectionID = selected.id
            phase = .home(pairID: selected.id)
            await requestPushIfFirstHomeOfSession()
        } catch let error as APIError {
            if case .unauthorized = error {
                await clearSessionAndReturnToAuth()
                return
            }
            // Transport or server failure: land on the connections screen with
            // a retry control (Requirement 9.6).
            landAfterFailedMembership(error)
        } catch {
            landAfterFailedMembership(error)
        }
    }

    /// Where a launch goes when the connection list could not be fetched.
    ///
    /// The offline case is the one that matters: the tester in #300 was in
    /// airplane mode, and the app told them they had no connections. It has not
    /// asked anybody; it has failed to ask the server. So fall back to the list
    /// we last knew, land on the connection that was last on screen, and let
    /// `connectionsFromCache` and `connectionsUpdatedAt` say how old it is.
    /// With no remembered connection it stays on the list rather than guessing.
    func landAfterFailedMembership(_ error: Error) {
        membershipFailed = true
        banner = error.localizedDescription
        if restoreCachedConnections(),
           let remembered = sharedStore.selectedConnectionID,
           connections.contains(where: { $0.id == remembered }) {
            phase = .home(pairID: remembered)
            return
        }
        phase = .connections
    }

    /// Records a freshly fetched list as the one to fall back on, and marks it
    /// as current rather than cached.
    func rememberConnections() {
        let now = Date()
        connectionsUpdatedAt = now
        connectionsFromCache = false
        connectionCache.saveConnections(connections, at: now)
    }

    /// Fills an empty list from the cache. Returns whether anything was restored,
    /// and leaves the list alone when it already has something: an in-memory list
    /// fetched a minute ago beats a file written yesterday.
    @discardableResult
    func restoreCachedConnections() -> Bool {
        guard connections.isEmpty,
              let cached = connectionCache.loadConnections(),
              !cached.connections.isEmpty else { return false }
        connections = cached.connections
        connectionsUpdatedAt = cached.savedAt
        connectionsFromCache = true
        return true
    }

    /// Forgets the cached list, on sign-out and account deletion. Leaving it
    /// behind would show the next person to use the device the last person's
    /// connections.
    func forgetCachedConnections() {
        connectionCache.clear()
        connectionsUpdatedAt = nil
        connectionsFromCache = false
    }

    /// The connection the home screen should show: the remembered one while it
    /// still exists, otherwise the first.
    func resolvedSelection() -> Connection? {
        if let remembered = sharedStore.selectedConnectionID,
           let match = connections.first(where: { $0.id == remembered }) {
            return match
        }
        return connections.first
    }

    /// The connection currently on screen.
    var selectedConnection: Connection? {
        guard case .home(let pairID) = phase else { return nil }
        return connections.first { $0.id == pairID }
    }

    /// Switches the home screen to another connection and remembers it.
    func select(connectionID: String) {
        guard connections.contains(where: { $0.id == connectionID }) else { return }
        sharedStore.selectedConnectionID = connectionID
        focusedPostID = nil
        banner = nil
        phase = .home(pairID: connectionID)
    }

    /// Opens the connections screen to add another one — contacts first, with
    /// codes a tap further on for the people not in your address book.
    func startAddingConnection() {
        banner = nil
        phase = .connections
    }

    /// Opens the invite-code screen, which is now something somebody chooses
    /// rather than the wall they land against.
    func startPairing() {
        banner = nil
        phase = .pair(prefilledCode: nil)
    }

    /// Back out of the code screen to the connections list.
    func showConnections() {
        banner = nil
        phase = .connections
    }

    /// True when the pairing screen was reached from an existing connection, so
    /// it can offer a way back.
    var canReturnHome: Bool { !connections.isEmpty }

    /// Returns to the last selected connection after adding was abandoned.
    func returnHome() {
        guard let selected = resolvedSelection() else { return }
        phase = .home(pairID: selected.id)
    }

    /// Re-reads the connection list without changing which one is on screen,
    /// unless the current one has gone.
    func refreshConnections() async {
        guard let userID = sessionStore.userID, !userID.isEmpty else { return }
        do {
            connections = try await api.connections()
            rememberConnections()
        } catch {
            if await handleIfUnauthorized(error) { return }
            // Offline, or the server is down: keep what we have, and fall back to
            // the cache if a cold start left us with nothing.
            restoreCachedConnections()
            return
        }
        if case .home(let pairID) = phase, connections.contains(where: { $0.id == pairID }) {
            return
        }
        if let selected = resolvedSelection() {
            sharedStore.selectedConnectionID = selected.id
            phase = .home(pairID: selected.id)
        } else {
            sharedStore.selectedConnectionID = nil
            // Not while they are typing a code in. This runs on every return to
            // the foreground, and "you still have no connections" is not news
            // worth taking somebody off the screen they are using to fix it —
            // least of all with a half-entered code in the field.
            if case .pair = phase { return }
            phase = .connections
        }
    }

    /// Requirement 15.2, 15.3 — leaves one connection, keeping the others.
    ///
    /// `deletingMoments` is the leave-time choice: off, the shared timeline keeps
    /// what the caller logged; on, their own moments in this one connection go
    /// with them. Scoped to this connection only — erasing everything everywhere
    /// is account deletion, which is a different button in a different place.
    func leave(connectionID: String, deletingMoments: Bool = false) async {
        do {
            try await api.leave(pairID: connectionID, deleteMoments: deletingMoments)
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = APIError.userMessage(for: error)
        }
        if sharedStore.selectedConnectionID == connectionID {
            sharedStore.selectedConnectionID = nil
        }
        await refreshConnections()
        await widgetSync.sync()
    }

}
