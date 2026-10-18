import Foundation
import PeardCore
import SwiftUI
import UIKit

extension AppModel {
    // MARK: Profile

    /// Loads the caller's own record. Its `display_name` is what every other
    /// member sees in the switcher, the timeline and the push copy.
    func loadProfile() async {
        do {
            profile = try await api.profile()
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = APIError.userMessage(for: error)
        }
    }

    /// Sets the name other members see. An empty name is a deliberate reset back
    /// to the email-local-part fallback, not an error.
    func updateDisplayName(_ name: String) async {
        do {
            profile = try await api.updateDisplayName(name)
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = APIError.userMessage(for: error)
            return
        }
        // Every connection carries the caller's own name in its member list.
        await refreshConnections()
        await widgetSync.sync()
    }

    /// Opts in or out of contact search — see
    /// `APIClient.updateDiscoverability(discoverable:phone:)`. Searching your
    /// own contacts needs none of this; it only governs whether this account
    /// can appear in someone *else's* results.
    func updateDiscoverability(discoverable: Bool, phone: String, contactEmail: String = "") async {
        do {
            let status = try await api.updateDiscoverability(
                discoverable: discoverable,
                phone: phone,
                contactEmail: contactEmail
            )
            profile = profile.map {
                UserProfile(
                    id: $0.id,
                    displayName: $0.displayName,
                    email: $0.email,
                    avatarFilename: $0.avatarFilename,
                    discoverable: status.discoverable,
                    phone: status.phone,
                    // The server normalises what it stores, so the echo is
                    // taken rather than what was typed — otherwise the "has
                    // changes" check compares a trimmed value against an
                    // untrimmed one and the Save button never goes quiet.
                    contactEmail: status.contactEmail,
                    emailIsRelay: $0.emailIsRelay
                )
            }
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = APIError.userMessage(for: error)
        }
    }

    /// Sets the caller's own photo. Everybody they share a connection with sees
    /// it, so the connection list is re-read: it carries each member's avatar,
    /// including the caller's own.
    func updateProfileAvatar(jpeg data: Data) async {
        do {
            profile = try await api.uploadProfileAvatar(jpeg: data)
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = APIError.userMessage(for: error)
            return
        }
        await refreshConnections()
    }

    /// Removes the caller's own photo, back to initials.
    func removeProfileAvatar() async {
        do {
            profile = try await api.removeProfileAvatar()
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = APIError.userMessage(for: error)
            return
        }
        await refreshConnections()
    }

    /// Sets a connection's photo. Any member may, exactly as any member may
    /// rename it.
    func updateConnectionAvatar(connectionID: String, jpeg data: Data) async {
        do {
            _ = try await api.uploadConnectionAvatar(pairID: connectionID, jpeg: data)
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = APIError.userMessage(for: error)
            return
        }
        await refreshConnections()
    }

    /// Removes a connection's photo. A 1:1 falls back to the other person's, a
    /// group to its initials.
    func removeConnectionAvatar(connectionID: String) async {
        do {
            _ = try await api.removeConnectionAvatar(pairID: connectionID)
        } catch {
            if await handleIfUnauthorized(error) { return }
            banner = APIError.userMessage(for: error)
            return
        }
        await refreshConnections()
    }

}
