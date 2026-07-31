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
}

/// One local contact's info, before anything is hashed.
private struct LocalContact {
    let name: String
    let emails: [String]
    let phones: [String]
}

/// What a match's echoed-back hash resolves to: enough to actually reach
/// that person, since the server never learns which local contact it was.
struct LocalMatchTarget {
    let name: String
    let value: String
    let isPhone: Bool
}

enum ContactsReader {
    /// Reads every local contact with at least one email or phone, hashes
    /// each value with `ContactHashing`, and returns both the flat hash list
    /// to send for matching and the reverse lookup needed afterward.
    static func hashedContactBook() throws -> (hashes: [String], byHash: [String: LocalMatchTarget]) {
        let keys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactEmailAddressesKey,
            CNContactPhoneNumbersKey,
        ] as [CNKeyDescriptor]

        var byHash: [String: LocalMatchTarget] = [:]
        let request = CNContactFetchRequest(keysToFetch: keys)
        try CNContactStore().enumerateContacts(with: request) { contact, _ in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let displayName = name.isEmpty ? "A contact" : name

            for email in contact.emailAddresses {
                let value = String(email.value)
                if let hash = ContactHashing.hashEmail(value) {
                    byHash[hash] = LocalMatchTarget(name: displayName, value: value, isPhone: false)
                }
            }
            for phone in contact.phoneNumbers {
                let value = phone.value.stringValue
                if let hash = ContactHashing.hashPhone(value) {
                    byHash[hash] = LocalMatchTarget(name: displayName, value: value, isPhone: true)
                }
            }
        }
        return (Array(byHash.keys), byHash)
    }
}
