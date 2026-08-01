import Contacts
import PeardCore

enum ContactsAccess {
    /// Requests access if not already decided; returns the outcome either
    /// way. The picker-free, full-address-book kind of access — unlike a
    /// single-contact picker, this genuinely needs the permission, which is
    /// why "Find friends" asks in its own screen rather than silently.
    static func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            CNContactStore().requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Whether access has already been settled, without asking. Lets a screen
    /// draw an explanation and a button instead of throwing the system prompt
    /// at somebody who has only just opened it.
    static var isAuthorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    static var isDenied: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return status == .denied || status == .restricted
    }
}

/// How to reach somebody: their own phone number or email, which is what makes
/// an invite a message they receive rather than a code read out loud.
struct LocalMatchTarget: Hashable {
    let value: String
    let isPhone: Bool
}

/// One contact from the local address book.
///
/// The hashes travel to the server for matching; nothing else here ever does.
/// See `ContactHashing` and the privacy policy for what that does and does not
/// promise.
struct LocalContact: Identifiable, Hashable {
    let id: String
    let name: String
    /// Hashed emails and phone numbers, in no particular order.
    let hashes: [String]
    /// Preferred way to send this person an invite, if there is one.
    let target: LocalMatchTarget?
}

enum ContactsReader {
    /// Reads every local contact with at least one email or phone number,
    /// hashing each value with `ContactHashing` as it goes.
    ///
    /// Returns everybody, not only the people already on Pear'd. That is the
    /// point: on a fresh install nobody in your contacts is on Pear'd yet, so a
    /// list of matches is an empty list, and "find friends from your contacts"
    /// is a screen that can only ever say no. Everybody here can be invited;
    /// the ones already on Pear'd are simply worth showing first.
    static func contacts() throws -> [LocalContact] {
        let keys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactEmailAddressesKey,
            CNContactPhoneNumbersKey,
        ] as [CNKeyDescriptor]

        var contacts: [LocalContact] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try CNContactStore().enumerateContacts(with: request) { contact, _ in
            guard let local = make(from: contact) else { return }
            contacts.append(local)
        }
        return contacts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A contact with no email and no phone is dropped: it can be neither
    /// matched nor invited, so it would only be a row that does nothing.
    private static func make(from contact: CNContact) -> LocalContact? {
        var hashes: [String] = []
        // A phone first, because the invite is a short message with a code in
        // it and that conversation is usually already in Messages. Email is the
        // fallback rather than the other way round.
        var phoneTarget: LocalMatchTarget?
        var emailTarget: LocalMatchTarget?

        for phone in contact.phoneNumbers {
            let value = phone.value.stringValue
            guard let hash = ContactHashing.hashPhone(value) else { continue }
            hashes.append(hash)
            if phoneTarget == nil { phoneTarget = LocalMatchTarget(value: value, isPhone: true) }
        }
        for email in contact.emailAddresses {
            let value = String(email.value)
            guard let hash = ContactHashing.hashEmail(value) else { continue }
            hashes.append(hash)
            if emailTarget == nil { emailTarget = LocalMatchTarget(value: value, isPhone: false) }
        }
        guard !hashes.isEmpty else { return nil }

        return LocalContact(
            id: contact.identifier,
            name: displayName(for: contact),
            hashes: hashes,
            target: phoneTarget ?? emailTarget
        )
    }

    /// Falls back through the fields a nameless contact might still be
    /// identifiable by, because "A contact" repeated eleven times is a list
    /// nobody can pick from.
    private static func displayName(for contact: CNContact) -> String {
        let name = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !name.isEmpty { return name }
        if !contact.organizationName.isEmpty { return contact.organizationName }
        if let email = contact.emailAddresses.first { return String(email.value) }
        if let phone = contact.phoneNumbers.first { return phone.value.stringValue }
        return "A contact"
    }
}
