import PeardCore
import SwiftUI

/// One person from the address book, and whether they already have a Pear'd
/// account.
struct ContactRow: Identifiable, Hashable {
    let contact: LocalContact
    /// Set when one of this contact's hashed emails or numbers matched an
    /// account that opted into discoverability.
    let match: ContactMatch?

    var id: String { contact.id }
    var name: String { contact.name }
    var isOnPeard: Bool { match != nil }
    var canInvite: Bool { contact.target != nil }
}

/// The contacts half of adding somebody: read the address book, ask the server
/// which of those hashes it recognises, and send an invite to whichever one is
/// picked.
///
/// Everybody in the address book is listed, not only the accounts that matched.
/// A brand-new user has no matches by definition — nobody they know is on Pear'd
/// yet — and a screen that can only say "no matches" is a screen that makes
/// adding somebody from your contacts impossible at exactly the moment it is the
/// only thing you want to do. Matching still earns its keep: it puts the people
/// who are already here at the top, and labels them, so the invite you send them
/// is one they can act on immediately.
@MainActor
@Observable
final class FindFriendsModel {
    enum Status: Equatable {
        /// Contacts have not been read yet, and no permission prompt has been
        /// shown. The screen offers a button rather than prompting on sight.
        case idle
        case loading
        case denied
        /// Access granted, but nothing in the address book has an email or a
        /// phone number to invite.
        case noContacts
        case ready
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// Everybody, on-Pear'd first, alphabetical within each group.
    private(set) var rows: [ContactRow] = []
    private(set) var invitingID: String?
    var query = ""
    var errorMessage: String?

    private let api: APIClient
    private let readContacts: () throws -> [LocalContact]
    private let requestAccess: () async -> Bool

    init(
        api: APIClient,
        readContacts: @escaping () throws -> [LocalContact] = ContactsReader.contacts,
        requestAccess: @escaping () async -> Bool = ContactsAccess.requestAccess
    ) {
        self.api = api
        self.readContacts = readContacts
        self.requestAccess = requestAccess
    }

    var visibleRows: [ContactRow] { Self.rows(rows, matching: query) }

    /// True once there is something to search, so the search field is only
    /// offered when it has something to search through.
    var hasContacts: Bool { !rows.isEmpty }

    // MARK: Loading

    /// Asks for contacts if needed, reads them, and matches them against the
    /// server. Safe to call repeatedly; a load already in flight wins.
    func load() async {
        guard status != .loading else { return }
        status = .loading

        guard await requestAccess() else {
            status = .denied
            return
        }

        let contacts: [LocalContact]
        do {
            contacts = try readContacts()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        guard !contacts.isEmpty else {
            status = .noContacts
            return
        }

        // A matching failure is not a dead end. The list is still useful — every
        // one of these people can be sent an invite — so the rows go up either
        // way and only the "already on Pear'd" labels are missing.
        var matchesByHash: [String: ContactMatch] = [:]
        do {
            let hashes = contacts.flatMap(\.hashes)
            for match in try await api.matchContacts(hashes: hashes) {
                matchesByHash[match.hash] = match
            }
        } catch {
            errorMessage = (error as? APIError)?.localizedDescription ?? error.localizedDescription
        }

        rows = Self.rows(from: contacts, matchesByHash: matchesByHash)
        status = .ready
    }

    /// Builds the rows: everybody already on Pear'd first, then everybody else,
    /// alphabetical within each group because `contacts` arrives sorted and this
    /// partition is stable.
    static func rows(from contacts: [LocalContact], matchesByHash: [String: ContactMatch]) -> [ContactRow] {
        let all = contacts.map { contact in
            ContactRow(
                contact: contact,
                match: contact.hashes.compactMap { matchesByHash[$0] }.first
            )
        }
        return all.filter(\.isOnPeard) + all.filter { !$0.isOnPeard }
    }

    /// Filters by name, or by the email or number the invite would go to —
    /// which is how you tell two Sarahs apart.
    ///
    /// Case- and diacritic-insensitive, so "rene" finds "René".
    static func rows(_ rows: [ContactRow], matching query: String) -> [ContactRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            matches(row.name, needle) || matches(row.contact.target?.value ?? "", needle)
        }
    }

    private static func matches(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // MARK: Inviting

    /// Creates a fresh invite code and returns who to send it to.
    ///
    /// A message rather than a direct add, even for somebody already on Pear'd:
    /// a connection is something both people opt into, and the code is what the
    /// other person uses to do that. It also means the same button works for
    /// everybody in the list, whether or not they have the app yet.
    func invite(_ row: ContactRow) async -> ComposeTarget? {
        guard let target = row.contact.target else { return nil }
        invitingID = row.id
        errorMessage = nil
        defer { invitingID = nil }
        do {
            let invite = try await api.createInvite()
            return ComposeTarget(recipient: target.value, isPhone: target.isPhone, message: invite.shareMessage)
        } catch {
            errorMessage = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            return nil
        }
    }
}
