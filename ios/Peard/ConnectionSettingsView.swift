import PeardCore
import SwiftUI

/// Everything about one connection that is not a moment: who is in it, what it is
/// called, whether it makes a noise, and how to leave it. Plus the signed-in
/// user's own name, which is what everybody else sees them as.
///
/// This exists because those controls had nowhere to live. Renaming was buried in
/// the header menu, there was no member list at all, no way to remove somebody, and
/// nothing anywhere could set a display name — so a group of four read as a list of
/// email prefixes.
struct ConnectionSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let model: HomeModel

    @State private var nameText = ""
    @State private var displayNameText = ""
    @State private var isSavingName = false
    @State private var isSavingDisplayName = false
    @State private var memberPendingRemoval: Connection.Member?
    @State private var showLeaveConfirmation = false
    @State private var showInviteSheet = false

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                membersSection
                notificationsSection
                pendingSection
                yourNameSection
                leaveSection
            }
            .scrollContentBackground(.hidden)
            .background(PearColor.background)
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                nameText = model.connection?.displayName ?? ""
                await app.loadProfile()
                displayNameText = app.profile?.displayName ?? ""
            }
            .sheet(isPresented: $showInviteSheet) {
                InviteSheet(pairID: model.pairID, connectionTitle: model.connectionTitle)
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
                model.isGroup ? "Leave this group?" : "Un-pear?",
                isPresented: $showLeaveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Leave", role: .destructive) {
                    Task {
                        await model.leaveConnection()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    model.isGroup
                        ? "You'll lose this group's shared timeline."
                        : "You'll both lose the shared timeline."
                )
            }
        }
    }

    private var removalPrompt: String {
        memberPendingRemoval.map { "Remove \($0.name)?" } ?? "Remove them?"
    }

    // MARK: Name

    private var nameSection: some View {
        Section {
            TextField("Flatmates", text: $nameText)
                .textInputAutocapitalization(.words)
                .accessibilityLabel("Connection name")
            Button {
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

    @ViewBuilder
    private func memberRow(_ member: Connection.Member) -> some View {
        HStack {
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
            TextField(placeholderName, text: $displayNameText)
                .textInputAutocapitalization(.words)
                .accessibilityLabel("Your display name")
            Button {
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
            Text("Your name")
        } footer: {
            Text("How you appear to everyone you're connected with. Without one, they see \(placeholderName).")
        }
    }

    /// What other members currently see, which is the honest placeholder: the
    /// server falls back to the local part of the email.
    private var placeholderName: String {
        app.profile?.effectiveName ?? PartnerLabel.fallback
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
