import PeardCore
import SwiftUI

/// Everything about one connection that is not a moment: who is in it, what it is
/// called, what it looks like, whether it makes a noise, and how to leave it. Plus
/// the signed-in user's own name and photo, which are what everybody else sees them
/// as, and signing out.
///
/// This exists because those controls had nowhere to live. Renaming was buried in
/// the header menu, there was no member list at all, no way to remove somebody, and
/// nothing anywhere could set a display name — so a group of four read as a list of
/// email prefixes. It is now a tab rather than a sheet, so nothing has to be
/// dismissed to get back to logging a moment.
struct ConnectionSettingsView: View {
    @Environment(AppModel.self) private var app

    let model: HomeModel

    @State private var nameText = ""
    @State private var displayNameText = ""
    @State private var isSavingName = false
    @State private var isSavingDisplayName = false
    @State private var memberPendingRemoval: Connection.Member?
    @State private var showLeaveConfirmation = false
    @State private var showSignOutConfirmation = false
    @State private var showDeleteAccountConfirmation = false
    @State private var isDeletingAccount = false
    @State private var showInviteSheet = false
    @State private var isExporting = false
    @State private var exportFileURL: URL?
    @State private var exportError: String?
    @State private var discoverable = false
    @State private var phoneText = ""
    @State private var contactEmailText = ""
    @State private var isSavingDiscoverability = false
    @FocusState private var nameFieldFocused: Bool
    @FocusState private var displayNameFieldFocused: Bool
    @FocusState private var phoneFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                nameSection
                membersSection
                notificationsSection
                pendingSection
                yourNameSection
                discoverabilitySection
                appearanceSection
                accountSection
                AboutSection(api: app.api, serverURL: model.serverURL)
                leaveSection
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(PearColor.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ConnectionToolbarTitle(title: "Settings", subtitle: model.connectionTitle)
                }
            }
            .task {
                nameText = model.connection?.displayName ?? ""
                await app.loadProfile()
                displayNameText = app.profile?.displayName ?? ""
                discoverable = app.profile?.discoverable ?? false
                phoneText = app.profile?.phone ?? ""
                contactEmailText = app.profile?.contactEmail ?? ""
            }
            // The name fields are seeded from state that changes from elsewhere:
            // another member renames the group, or the display name is saved and
            // the server normalises it. Without this the field would keep showing
            // what was typed before the switch.
            .onChange(of: model.connection?.displayName) { _, name in
                nameText = name ?? ""
            }
            .onChange(of: app.profile?.displayName) { _, name in
                displayNameText = name ?? ""
            }
            .sheet(isPresented: $showInviteSheet) {
                InviteSheet(pairID: model.pairID, connectionTitle: model.connectionTitle)
            }
            .sheet(isPresented: Binding(
                get: { exportFileURL != nil },
                set: { if !$0 { exportFileURL = nil } }
            )) {
                if let exportFileURL {
                    ActivityView(activityItems: [exportFileURL])
                }
            }
            .alert(
                "Export failed",
                isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } }),
                presenting: exportError
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
            .confirmationDialog(
                removalPrompt,
                isPresented: Binding(
                    get: { memberPendingRemoval != nil },
                    set: { if !$0 { memberPendingRemoval = nil } }
                ),
                titleVisibility: .visible,
                presenting: memberPendingRemoval
            ) { member in
                Button("Remove", role: .destructive) {
                    Task {
                        await model.remove(member: member)
                        memberPendingRemoval = nil
                    }
                }
                Button("Cancel", role: .cancel) { memberPendingRemoval = nil }
            } message: { _ in
                Text("Their moments stay in the shared timeline.")
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
            // Two ways out rather than one, because "leave" has always meant the
            // membership goes and the shared history stays — which is right for
            // a group carrying on without you, and wrong for somebody who wants
            // their own moments gone. Offering both makes the default explicit
            // instead of leaving people to guess which one it is.
            .confirmationDialog(
                model.isGroup ? "Leave this group?" : "Un-pear?",
                isPresented: $showLeaveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Leave, keep my moments", role: .destructive) {
                    Task { await model.leaveConnection() }
                }
                Button("Leave and delete my moments", role: .destructive) {
                    Task { await model.leaveConnection(deletingMoments: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    model.isGroup
                        ? "You'll lose this group's shared timeline. Your own moments in it stay unless you delete them."
                        : "You'll both lose the shared timeline. Your own moments in it stay unless you delete them."
                )
            }
            .confirmationDialog(
                "Delete your account?",
                isPresented: $showDeleteAccountConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete my account", role: .destructive) {
                    Task {
                        isDeletingAccount = true
                        await app.deleteAccount()
                        isDeletingAccount = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This erases your profile, your moments and every connection you're in, right now and for good. "
                        + "Export your data first if you want a copy. This can't be undone."
                )
            }
        }
    }

    private var removalPrompt: String {
        memberPendingRemoval.map { "Remove \($0.name)?" } ?? "Remove them?"
    }

    // MARK: Photo

    /// The connection's face. Any member may set it, exactly as any member may
    /// rename it: the name and the picture are shared property, and a group whose
    /// only owner has left would otherwise be stuck with whatever it had.
    private var identitySection: some View {
        Section {
            AvatarPickerRow(
                avatar: model.connectionAvatar,
                serverURL: model.serverURL,
                title: model.connectionTitle,
                subtitle: photoSubtitle,
                onRemove: model.connectionHasOwnAvatar ? { await model.removeConnectionAvatar() } : nil,
                onPick: { await model.updateConnectionAvatar(jpeg: $0) }
            )
        } header: {
            Text("Photo")
        } footer: {
            Text("Everyone in the connection sees this. Anyone here can change it.")
        }
    }

    private var photoSubtitle: String {
        if model.connectionHasOwnAvatar { return model.connection?.subtitle ?? "" }
        if !model.isGroup, model.connectionAvatar.hasImage {
            return "Using \(model.shortPartnerName)'s photo"
        }
        return model.connection?.subtitle ?? ""
    }

    // MARK: Name

    private var nameSection: some View {
        Section {
            TextField("Flatmates", text: $nameText)
                .textInputAutocapitalization(.words)
                .focused($nameFieldFocused)
                .submitLabel(.done)
                .onSubmit { nameFieldFocused = false }
                .accessibilityLabel("Connection name")
            Button {
                nameFieldFocused = false
                Task {
                    isSavingName = true
                    await model.rename(to: nameText)
                    isSavingName = false
                }
            } label: {
                if isSavingName {
                    ProgressView()
                } else {
                    Text("Save name")
                }
            }
            .disabled(isSavingName || nameText == (model.connection?.displayName ?? ""))
        } header: {
            Text("Name")
        } footer: {
            Text("Everyone in the connection sees this. Leave it empty to go by who's in it.")
        }
    }

    // MARK: Members

    private var membersSection: some View {
        Section {
            if let me = model.connection?.members.first(where: \.isYou) {
                memberRow(me)
            }
            ForEach(model.otherMembers) { member in
                memberRow(member)
            }
            Button {
                showInviteSheet = true
            } label: {
                Label(model.isGroup ? "Invite someone else" : "Add someone", systemImage: "person.badge.plus")
            }
        } header: {
            Text(model.isGroup ? "\(model.connection?.memberCount ?? 0) people" : "Members")
        } footer: {
            if model.canRemoveMembers && !model.otherMembers.isEmpty {
                Text("Swipe a member to remove them. Only you can, because you started this connection.")
            }
        }
    }

    /// Light, dark, or follow the phone.
    ///
    /// The palette has had both variants since it was built, so this is not new
    /// capability — it is the ability to disagree with the phone. That is a real
    /// preference: light sensitivity often means wanting a dark app inside an
    /// otherwise light system, and reading in bed is the same wish in reverse.
    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: Binding(
                get: { app.appearance },
                set: { app.appearance = $0 }
            )) {
                ForEach(AppearancePreference.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Appearance")
        } header: {
            Text("Appearance")
        } footer: {
            // Says what the current choice means rather than describing all
            // three: "System" is the only one that needs explaining, and it is
            // the default, so most people read this once and never again.
            Text(app.appearance.subtitle)
        }
    }

    @ViewBuilder
    private func memberRow(_ member: Connection.Member) -> some View {
        HStack(spacing: 12) {
            AvatarView(avatar: member.avatar, serverURL: model.serverURL, size: 32)
                .accessibilityHidden(true)
            Text(member.name)
                .foregroundStyle(PearColor.textPrimary)
            if member.isYou {
                Text("you")
                    .font(.caption)
                    .foregroundStyle(PearColor.textTertiary)
            }
            Spacer()
            if member.role == .owner {
                Text("owner")
                    .font(.caption)
                    .foregroundStyle(PearColor.accent)
            }
        }
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .trailing) {
            // Removing yourself is leaving, which tidies up an emptied connection
            // and needs no ownership — so it is the button at the bottom, not this.
            if model.canRemoveMembers && !member.isYou {
                Button("Remove", role: .destructive) {
                    memberPendingRemoval = member
                }
            }
        }
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        Section {
            Toggle(
                "Mute this connection",
                isOn: Binding(
                    get: { model.isMuted },
                    set: { muted in Task { await model.setMuted(muted) } }
                )
            )
        } header: {
            Text("Notifications")
        } footer: {
            Text(
                model.isGroup
                    ? "Muted groups still appear here and in the widget — they just stop making a noise."
                    : "Muting stops the alerts. Moments still arrive."
            )
        }
    }

    // MARK: Pending sends

    @ViewBuilder
    private var pendingSection: some View {
        if !model.pendingSends.isEmpty {
            Section {
                ForEach(model.pendingSends) { send in
                    HStack {
                        Text(send.emoji)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(send.label)
                                .foregroundStyle(PearColor.textPrimary)
                            Text(statusText(for: send))
                                .font(.caption)
                                .foregroundStyle(send.hasGivenUp ? PearColor.error : PearColor.textTertiary)
                        }
                        Spacer()
                        Text(ElapsedTime.label(for: send.queuedAt))
                            .font(.caption2)
                            .foregroundStyle(PearColor.textTertiary)
                    }
                }

                if !model.stalledSends.isEmpty {
                    Button("Try again") {
                        Task { await model.retryPendingSends() }
                    }
                    Button("Discard them", role: .destructive) {
                        Task { await model.discardPendingSends() }
                    }
                }
            } header: {
                Text("Waiting to send")
            } footer: {
                Text("Moments are kept on this device until the server accepts them, so nothing is lost when there's no signal.")
            }
        }
    }

    private func statusText(for send: PendingSend) -> String {
        if send.hasGivenUp {
            return send.lastError ?? "Couldn't send"
        }
        if send.attempts > 0 {
            return "Retrying — attempt \(send.attempts + 1)"
        }
        return model.isOffline ? "Waiting for signal" : "Sending…"
    }

    // MARK: Your name

    private var yourNameSection: some View {
        Section {
            if let profile = app.profile {
                AvatarPickerRow(
                    avatar: profile.avatar,
                    serverURL: model.serverURL,
                    title: profile.effectiveName,
                    subtitle: profile.hasAvatar
                        ? "Everyone you're connected with sees this"
                        : "They see your initials until you add one",
                    onRemove: profile.hasAvatar ? { await app.removeProfileAvatar() } : nil,
                    onPick: { await app.updateProfileAvatar(jpeg: $0) }
                )
            }

            TextField(placeholderName, text: $displayNameText)
                .textInputAutocapitalization(.words)
                .focused($displayNameFieldFocused)
                .submitLabel(.done)
                .onSubmit { displayNameFieldFocused = false }
                .accessibilityLabel("Your display name")
            Button {
                displayNameFieldFocused = false
                Task {
                    isSavingDisplayName = true
                    await app.updateDisplayName(displayNameText)
                    displayNameText = app.profile?.displayName ?? ""
                    isSavingDisplayName = false
                }
            } label: {
                if isSavingDisplayName {
                    ProgressView()
                } else {
                    Text("Save your name")
                }
            }
            .disabled(isSavingDisplayName || displayNameText == (app.profile?.displayName ?? ""))
        } header: {
            Text("You")
        } footer: {
            Text("How you appear to everyone you're connected with. Without a name, they see \(placeholderName).")
        }
    }

    /// What other members currently see, which is the honest placeholder: the
    /// server falls back to the local part of the email.
    private var placeholderName: String {
        app.profile?.effectiveName ?? PartnerLabel.fallback
    }

    // MARK: Discoverability

    /// Searching your own contacts (PairView's "Find friends") needs none of
    /// this — this section only governs whether *this* account can turn up
    /// in someone else's search.
    private var discoverabilitySection: some View {
        Section {
            Toggle("Let people who have you in their contacts find you", isOn: $discoverable)
                .tint(PearColor.accent)
                .onChange(of: discoverable) { _, newValue in
                    Task { await saveDiscoverability(discoverable: newValue) }
                }

            if discoverable, app.profile?.emailIsRelay == true {
                // Only for the accounts this can help. Sign in with Apple's
                // relay address is generated per app, per account, so it has
                // never been anybody's address — matching on it cannot succeed,
                // and until this field existed those accounts could turn the
                // toggle on and simply never be found.
                TextField("Email people have for you", text: $contactEmailText)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Email people have for you")
                    .accessibilityHint("Used only to match your contacts, never shown to anybody")
            }

            if discoverable {
                TextField("Phone number (optional)", text: $phoneText)
                    .keyboardType(.phonePad)
                    .focused($phoneFieldFocused)
                    .submitLabel(.done)
                    .onSubmit { saveDiscoverabilityIfChanged() }
                    .accessibilityLabel("Your phone number")
                Button {
                    phoneFieldFocused = false
                    saveDiscoverabilityIfChanged()
                } label: {
                    if isSavingDiscoverability {
                        ProgressView()
                    } else {
                        Text(app.profile?.emailIsRelay == true ? "Save" : "Save phone number")
                    }
                }
                .disabled(isSavingDiscoverability || !discoverabilityHasChanges)
            }
        } header: {
            Text("Discoverable")
        } footer: {
            Text(discoverabilityFooter)
        }
    }

    /// The footer explains the mechanism, and for a relay account it has to
    /// explain one more thing: why the email box is there at all. Somebody who
    /// hid their address chose to, and being asked for one without a reason
    /// reads as the app going back on that.
    private var discoverabilityFooter: String {
        let base = "Pear'd compares one-way hashes of contact info, never raw emails or phone numbers, "
            + "and only for people who've turned this on."
        guard app.profile?.emailIsRelay == true else {
            return base + " Your email is always included; adding a phone number lets people who "
                + "only have that find you too."
        }
        return base + " You signed in with Apple and hid your email, so the address we have for you "
            + "is a private relay one that nobody else has — matching on it can never find you. "
            + "Give an address people actually have, and we'll match on that instead. It's hashed "
            + "like everything else and never shown to anyone."
    }

    /// True when either field differs from what the server last returned.
    private var discoverabilityHasChanges: Bool {
        phoneText != (app.profile?.phone ?? "")
            || contactEmailText != (app.profile?.contactEmail ?? "")
    }

    private func saveDiscoverabilityIfChanged() {
        guard discoverabilityHasChanges else { return }
        Task { await saveDiscoverability(discoverable: discoverable) }
    }

    private func saveDiscoverability(discoverable: Bool) async {
        isSavingDiscoverability = true
        await app.updateDiscoverability(
            discoverable: discoverable,
            phone: phoneText,
            contactEmail: contactEmailText
        )
        phoneText = app.profile?.phone ?? phoneText
        isSavingDiscoverability = false
    }

    // MARK: Account

    /// Signing out lived at the bottom of the home screen, next to "Un-pear", which
    /// put the two most destructive actions in the app side by side under a moment
    /// grid. It belongs here.
    private var accountSection: some View {
        Section {
            Button {
                Task { await exportData() }
            } label: {
                HStack {
                    Text("Export your data")
                    if isExporting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .foregroundStyle(PearColor.textPrimary)
            .disabled(isExporting)

            Button("Sign out") {
                showSignOutConfirmation = true
            }
            .foregroundStyle(PearColor.textPrimary)

            // The other half of the privacy policy's deletion promise, which
            // until now read "email us and we'll action it within 30 days". A
            // person should not have to ask somebody else to stop holding their
            // data, so this does it in one tap and no waiting.
            Button(role: .destructive) {
                showDeleteAccountConfirmation = true
            } label: {
                HStack {
                    Text("Delete account")
                    if isDeletingAccount {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isDeletingAccount)

            Link("Privacy policy", destination: PeardLinks.privacyPolicy)
                .foregroundStyle(PearColor.textPrimary)
        } footer: {
            if let email = app.profile?.email, !email.isEmpty {
                Text("Signed in as \(email). Deleting your account erases everything above immediately.")
            } else {
                Text("Deleting your account erases everything above immediately.")
            }
        }
    }

    /// Downloads a JSON snapshot of the profile, connections and moments this
    /// account owns, then hands it to the system share sheet — save to Files,
    /// AirDrop, email, whatever the person wants to do with their own data.
    private func exportData() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let data = try await app.api.data(path: "/api/peard/export")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("peard-export-\(Int(Date().timeIntervalSince1970))")
                .appendingPathExtension("json")
            try data.write(to: url, options: .atomic)
            exportFileURL = url
        } catch {
            exportError = (error as? APIError)?.localizedDescription ?? error.localizedDescription
        }
    }

    // MARK: Leave

    private var leaveSection: some View {
        Section {
            Button(model.isGroup ? "Leave group" : "Un-pear", role: .destructive) {
                showLeaveConfirmation = true
            }
        } footer: {
            if model.isGroup {
                Text("The group carries on without you. If you're the last one out, it's deleted.")
            } else {
                Text("This deletes the shared timeline for both of you.")
            }
        }
    }
}
