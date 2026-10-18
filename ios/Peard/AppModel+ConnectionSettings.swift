import Foundation
import PeardCore
import SwiftUI
import UIKit

extension AppModel {
    // MARK: Connection settings

    /// Silences or unsilences one connection's notifications.
    ///
    /// Per connection rather than per user: with 20 connections of up to 12 people
    /// each, the useful control is "this group is too noisy", not "stop
    /// notifying me".
    func setMuted(connectionID: String, muted: Bool) async {
        do {
            try await api.setMuted(pairID: connectionID, muted: muted)
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = APIError.userMessage(for: error)
            return
        }
        await refreshConnections()
    }

    /// Removes somebody else from a connection. Owners only, enforced server-side.
    func removeMember(connectionID: String, userID: String) async {
        do {
            try await api.removeMember(pairID: connectionID, userID: userID)
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = APIError.userMessage(for: error)
            return
        }
        await refreshConnections()
        await widgetSync.sync()
    }

}
