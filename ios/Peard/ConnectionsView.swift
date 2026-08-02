import PeardCore
import SwiftUI

/// Who you are sharing with, and how to add somebody.
///
/// This replaces the pairing screen as the place a signed-in user with no
/// connections lands. That screen asked for a decision before it would show
/// anything: create a code and get it to somebody, or type in one you had
/// already been given. Somebody who had just made an account had neither, and
/// the only route through their own contacts was a button that listed the people
/// already on Pear'd — which, on a new account, is nobody. So the answer to
/// "add a friend from my contacts" was, in practice, that you could not.
///
/// An empty list is a better first screen than a locked door. Contacts are right
/// here and searchable, everybody in them can be invited whether or not they
/// have the app, and the invite code is still there for the people who are not
/// in your address book — one tap away, rather than in the way.
struct ConnectionsView: View {
    @Environment(AppModel.self) private var app

    @State private var friends: FindFriendsModel
    @State private var composeTarget: ComposeTarget?
    @State private var showSignOutConfirmation = false

    init(api: APIClient) {
        _friends = State(initialValue: FindFriendsModel(api: api))
    }

    var body: some View {
        NavigationStack {
            searchable
                .scrollContentBackground(.hidden)
                .background(PearColor.background)
                .navigationTitle("Connections")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .sheet(item: $composeTarget) { target in
            InviteComposeView(target: target) { composeTarget = nil }
        }
        .confirmationDialog(
            "Sign out?",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                Task { await app.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anything still waiting to send is discarded.")
        }
    }

    /// The search field only appears once there is something to search. Offering
    /// it before contacts have been read would be a control that does nothing.
    @ViewBuilder
    private var searchable: some View {
        if friends.hasContacts {
            list.searchable(text: $friends.query, prompt: "Search your contacts")
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if app.connections.isEmpty {
                emptyStateSection
            } else {
                connectionsSection
            }
            if app.membershipFailed {
                retrySection
            }
            contactsSection
            codeSection
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if app.canReturnHome {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { app.returnHome() }
                    .foregroundStyle(PearColor.accent)
            }
        } else {
            // The only way out of a signed-in app with nothing in it. It used to
            // live at the bottom of the pairing screen; it belongs wherever that
            // dead end now is.
            ToolbarItem(placement: .primaryAction) {
                Button("Sign out") { showSignOutConfirmation = true }
                    .foregroundStyle(PearColor.textSecondary)
            }
        }
    }

    // MARK: Sections

    private var emptyStateSection: some View {
        Section {
            VStack(spacing: 10) {
                Text("🍐")
                    .font(.system(size: 48))
                Text("No connections yet")
                    .font(.headline)
                    .foregroundStyle(PearColor.textPrimary)
                Text("Invite somebody from your contacts, or share a code with them.")
                    .font(.subheadline)
                    .foregroundStyle(PearColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .listRowBackground(Color.clear)
        }
    }

    private var connectionsSection: some View {
        Section("Your connections") {
            ForEach(app.connections) { connection in
                Button {
                    app.select(connectionID: connection.id)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(avatar: connection.avatar, serverURL: app.config.serverURL, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connection.title())
                                .foregroundStyle(PearColor.textPrimary)
                            Text(connection.subtitle)
                                .font(.caption)
                                .foregroundStyle(PearColor.textSecondary)
                        }
                        Spacer()
                        if connection.hasUnread {
                            Text("\(connection.unreadCount)")
                                .font(.caption.bold())
                                .monospacedDigit()
                                .foregroundStyle(PearColor.onAccent)
                                .padding(.horizontal, 6)
                                .frame(minHeight: 18)
                                .background(PearColor.accent, in: Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var retrySection: some View {
        Section {
            Button("Try again") {
                Task { await app.resolveMembership() }
            }
            .foregroundStyle(PearColor.accent)
        } footer: {
            Text("Your connections couldn't be loaded.")
        }
    }

    @ViewBuilder
    private var contactsSection: some View {
        Section {
            contactsContent
        } header: {
            Text("From your contacts")
        } footer: {
            // Said here rather than only in the privacy policy: this is the
            // moment somebody decides whether to hand over their address book.
            Text("Your contacts are hashed on this device before anything is sent, and never stored on the server.")
        }
    }

    @ViewBuilder
    private var contactsContent: some View {
        switch friends.status {
        case .idle:
            Button {
                Task { await friends.load() }
            } label: {
                Label("Find friends from your contacts", systemImage: "person.crop.circle.badge.plus")
            }
            .foregroundStyle(PearColor.accent)

        case .loading:
            HStack(spacing: 10) {
                ProgressView().tint(PearColor.accent)
                Text("Reading your contacts…")
                    .font(.footnote)
                    .foregroundStyle(PearColor.textSecondary)
            }

        case .denied:
            note("Contacts access is off. Turn it on in Settings to invite people you already know.")
            Button("Open Settings", action: openSystemSettings)
                .foregroundStyle(PearColor.accent)

        case .noContacts:
            note("There's nothing in your contacts with an email address or phone number to invite.")

        case .failed(let text):
            note(text)
            Button("Try again") { Task { await friends.load() } }
                .foregroundStyle(PearColor.accent)

        case .ready:
            if friends.visibleRows.isEmpty {
                note("Nobody in your contacts matches “\(friends.query)”.")
            } else {
                ForEach(friends.visibleRows) { row in
                    contactRow(row)
                }
            }
        }

        if let errorMessage = friends.errorMessage {
            note(errorMessage, isError: true)
        }
    }

    private var codeSection: some View {
        Section {
            Button {
                app.startPairing()
            } label: {
                Label("Use an invite code", systemImage: "number")
            }
            .foregroundStyle(PearColor.accent)
        } footer: {
            Text("For anybody who isn't in your contacts — share a code, or enter theirs.")
        }
    }

    // MARK: Rows

    private func contactRow(_ row: ContactRow) -> some View {
        HStack(spacing: 12) {
            AvatarView(
                avatar: Avatar(
                    owner: .users,
                    recordID: row.match?.id ?? row.id,
                    filename: row.match?.avatar,
                    placeholder: .make(name: row.name, key: row.id)
                ),
                serverURL: app.config.serverURL,
                size: 40
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .foregroundStyle(PearColor.textPrimary)
                    .lineLimit(1)
                // Only for the people already here. Saying "not on Pear'd" under
                // everybody else would turn a list of friends into a list of
                // absences.
                if row.isOnPeard {
                    Text("Already on Pear'd")
                        .font(.caption)
                        .foregroundStyle(PearColor.accent)
                }
            }
            Spacer(minLength: 8)
            Button {
                Task { composeTarget = await friends.invite(row) }
            } label: {
                if friends.invitingID == row.id {
                    ProgressView()
                } else {
                    Text("Invite")
                }
            }
            .font(.footnote.bold())
            .foregroundStyle(PearColor.accent)
            .buttonStyle(.plain)
            .disabled(friends.invitingID != nil || !row.canInvite)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.isOnPeard ? "\(row.name), already on Pear'd" : row.name)
    }

    private func note(_ text: String, isError: Bool = false) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(isError ? PearColor.error : PearColor.textSecondary)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
