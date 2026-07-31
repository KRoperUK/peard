import PeardCore
import SwiftUI

/// Matches the caller's own contacts against Pear'd accounts that opted into
/// discoverability, then reuses the ordinary invite-code flow to pair with
/// one — see `PeardConfig`/ContactHashing's doc comments and the privacy
/// policy for what "matches" actually means (hashed contact info, never
/// sent or stored in the clear) and what it does not guarantee (an unsalted
/// hash is not a cryptographic promise).
struct FindFriendsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case working
        case deniedAccess
        case noContactsToMatch
        case noMatches
        case results([ContactMatch])
        case failed(String)
    }

    @State private var phase: Phase = .working
    @State private var contactBook: [String: LocalMatchTarget] = [:]
    @State private var composeTarget: ComposeTarget?
    @State private var invitingID: String?

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PearColor.background)
                .navigationTitle("Find friends")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { await start() }
        .sheet(item: $composeTarget) { target in
            InviteComposeView(target: target) { composeTarget = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .working:
            VStack(spacing: 12) {
                ProgressView().tint(PearColor.accent)
                Text("Looking for friends already on Pear'd…")
                    .font(.footnote)
                    .foregroundStyle(PearColor.textSecondary)
            }
        case .deniedAccess:
            message(
                emoji: "🍐",
                title: "Contacts access is off",
                body: "Turn it on in Settings to find friends already using Pear'd.",
                action: ("Open Settings", openSystemSettings)
            )
        case .noContactsToMatch:
            message(emoji: "📇", title: "No contacts to check", body: "There's nothing in your contacts with an email or phone number yet.")
        case .noMatches:
            message(
                emoji: "🍐",
                title: "No matches yet",
                body: "Nobody in your contacts has turned on discoverability, or none of them are on Pear'd yet."
            )
        case .failed(let text):
            message(emoji: "⚠️", title: "Couldn't check", body: text)
        case .results(let matches):
            List(matches) { matchRow($0) }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
        }
    }

    private func message(emoji: String, title: String, body: String, action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 12) {
            Text(emoji).font(.system(size: 48))
            Text(title).font(.headline).foregroundStyle(PearColor.textPrimary)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(PearColor.textSecondary)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1)
                    .font(.body.bold())
                    .foregroundStyle(PearColor.accent)
                    .padding(.top, 4)
            }
        }
        .padding(32)
    }

    private func matchRow(_ match: ContactMatch) -> some View {
        HStack(spacing: 12) {
            AvatarView(
                avatar: Avatar(
                    owner: .users,
                    recordID: match.id,
                    filename: match.avatar,
                    placeholder: .make(name: match.displayName, key: match.id)
                ),
                serverURL: app.config.serverURL,
                size: 40
            )
            Text(match.displayName)
                .foregroundStyle(PearColor.textPrimary)
            Spacer()
            Button {
                Task { await invite(match) }
            } label: {
                if invitingID == match.id {
                    ProgressView()
                } else {
                    Text("Invite")
                }
            }
            .font(.footnote.bold())
            .foregroundStyle(PearColor.accent)
            .disabled(invitingID != nil)
        }
    }

    private func start() async {
        guard await ContactsAccess.requestAccess() else {
            phase = .deniedAccess
            return
        }
        do {
            let book = try ContactsReader.hashedContactBook()
            contactBook = book.byHash
            guard !book.hashes.isEmpty else {
                phase = .noContactsToMatch
                return
            }
            let matches = try await app.api.matchContacts(hashes: book.hashes)
            phase = matches.isEmpty ? .noMatches : .results(matches)
        } catch let error as APIError {
            phase = .failed(error.localizedDescription)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func invite(_ match: ContactMatch) async {
        guard let target = contactBook[match.hash] else { return }
        invitingID = match.id
        defer { invitingID = nil }
        do {
            let invite = try await app.api.createInvite()
            composeTarget = ComposeTarget(recipient: target.value, isPhone: target.isPhone, message: invite.shareMessage)
        } catch {
            // Best effort — they can still be invited from the pairing screen.
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
