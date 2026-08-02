import PeardCore
import SwiftUI

/// Invite-code screen (Requirement 10, 21.2, 21.3).
///
/// Reached from `ConnectionsView` rather than landed on. It used to be the first
/// thing a signed-in user with no connections saw, which made a code the price
/// of entry — see that view for why contacts come first now. Codes still matter:
/// they are how you pear up with somebody who is not in your address book, and
/// how a group grows.
struct PairView: View {
    @Environment(AppModel.self) private var app

    let prefilledCode: String?

    @State private var invite: PairInvite?
    @State private var code = ""
    @State private var busy: Busy?
    @State private var errorMessage: String?

    private enum Busy: Equatable { case invite, accept }

    private var canAccept: Bool { code.count == 6 && busy == nil }

    var body: some View {
        // Scrollable for the same reason the sign-in screen is: this is a tall
        // screen — back, title, invite code, share button, divider, code field,
        // accept button and an error row — and entering a code raises the
        // keyboard over the bottom half of it. A fixed VStack simply clipped,
        // with nothing to indicate the accept button was below the fold.
        ScrollView {
            content
                .padding(32)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PearColor.background)
        .pearAnimation(value: invite?.code ?? "")
        .onAppear {
            if let prefilledCode, code.isEmpty {
                code = prefilledCode.uppercased()
            }
        }
        .onChange(of: prefilledCode) { _, newValue in
            if let newValue { code = newValue.uppercased() }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Always present now. This screen is somewhere you chose to go, so
            // there is always somewhere to go back to — before, with no
            // connections, the only way off it was to sign out.
            HStack {
                Button("Back") { app.showConnections() }
                    .font(.subheadline.bold())
                    .foregroundStyle(PearColor.accent)
                Spacer()
            }
            .padding(.bottom, 16)

            Text(app.canReturnHome ? "Another connection 🍐" : "Pear up 🍐")
                .font(.title.bold())
                .foregroundStyle(PearColor.textPrimary)
            Text(
                app.canReturnHome
                    ? "Start a second connection, or join a friend's group with their code."
                    : "Share a code with your partner, or enter theirs."
            )
                .font(.subheadline)
                .foregroundStyle(PearColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.bottom, 32)

            inviteSection

            Divider()
                .background(PearColor.divider)
                .padding(.vertical, 28)

            codeEntrySection

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(PearColor.error)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                    .pearTransition()
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var inviteSection: some View {
        if let invite {
            Text(invite.code)
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .tracking(8)
                .foregroundStyle(PearColor.accent)
                .padding(.bottom, 16)
                .accessibilityLabel("Your invite code is \(invite.code.map(String.init).joined(separator: " "))")

            ShareLink(item: invite.shareMessage) {
                Text("Share code")
                    .font(.body.bold())
                    .foregroundStyle(PearColor.accent)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(PearColor.accent)
                    )
            }
        } else {
            Button {
                createInvite()
            } label: {
                primaryLabel(title: "Create invite code", isBusy: busy == .invite)
            }
            .buttonStyle(.plain)
            .disabled(busy != nil)
        }
    }

    private var codeEntrySection: some View {
        VStack(spacing: 12) {
            TextField("", text: $code, prompt: Text("ENTER CODE").foregroundStyle(PearColor.textTertiary))
                .font(.title3)
                .tracking(6)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .foregroundStyle(PearColor.textPrimary)
                .padding(14)
                .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PearColor.divider))
                .accessibilityLabel("Pairing code")
                .onChange(of: code) { _, newValue in
                    // Requirement 10.3 — exactly six upper-case characters.
                    let filtered = newValue.uppercased().filter { $0.isLetter || $0.isNumber }
                    code = String(filtered.prefix(6))
                }

            #if DEBUG
            Text("💡 Dev: AAAAAA seeds a pair, BBBBBB seeds a group")
                .font(.caption2)
                .foregroundStyle(PearColor.textTertiary)
            #endif

            Button {
                accept()
            } label: {
                primaryLabel(title: app.canReturnHome ? "Accept & join" : "Accept & pear up", isBusy: busy == .accept)
            }
            .buttonStyle(.plain)
            .disabled(!canAccept)
            .opacity(canAccept ? 1 : 0.5)
        }
    }

    private func primaryLabel(title: String, isBusy: Bool) -> some View {
        ZStack {
            if isBusy {
                ProgressView().tint(.white)
            } else {
                Text(title)
                    .font(.body.bold())
                    .foregroundStyle(PearColor.onAccent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24)
        .padding(.vertical, 14)
        .background(PearColor.accent, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    // MARK: Actions

    private func createInvite() {
        busy = .invite
        errorMessage = nil
        Task {
            defer { busy = nil }
            do {
                invite = try await app.api.createInvite()
            } catch {
                if await app.handleIfUnauthorized(error) { return }
                errorMessage = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            }
        }
    }

    private func accept() {
        busy = .accept
        errorMessage = nil
        Task {
            defer { busy = nil }
            do {
                #if DEBUG
                if code == DebugSupport.fakePairCode {
                    try await DebugSupport.createFakePair(app: app)
                    await app.resolveMembership()
                    return
                }
                if code == DebugSupport.fakeGroupCode {
                    try await DebugSupport.createFakeGroup(app: app)
                    await app.refreshConnections()
                    return
                }
                #endif
                _ = try await app.api.acceptInvite(code: code)
                // Requirement 10.6 and clarification Q12: the phase is resolved
                // from membership independently of the accept call.
                await app.resolveMembership()
            } catch {
                if await app.handleIfUnauthorized(error) { return }
                errorMessage = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            }
        }
    }
}
