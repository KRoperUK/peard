import PeardCore
import SwiftUI

/// Invites somebody into an existing connection, which is how a 1:1 becomes a
/// group and how a group grows. The code is scoped to this connection, so
/// accepting it joins here rather than starting something new.
struct InviteSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let pairID: String
    let connectionTitle: String

    @State private var invite: PairInvite?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Anyone who enters this code joins \(connectionTitle).")
                    .font(.subheadline)
                    .foregroundStyle(PearColor.textSecondary)
                    .multilineTextAlignment(.center)

                if let invite {
                    Text(invite.code)
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .tracking(8)
                        .foregroundStyle(PearColor.accent)
                        .accessibilityLabel(
                            "Invite code \(invite.code.map(String.init).joined(separator: " "))"
                        )

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

                    Text("Expires in 7 days.")
                        .font(.caption)
                        .foregroundStyle(PearColor.textTertiary)
                } else {
                    Button {
                        Task { await createInvite() }
                    } label: {
                        ZStack {
                            if isWorking {
                                ProgressView().tint(.white)
                            } else {
                                Text("Create invite code")
                                    .font(.body.bold())
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .padding(.vertical, 14)
                        .background(PearColor.accent, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(PearColor.error)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(PearColor.background)
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func createInvite() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            invite = try await app.api.createInvite(pairID: pairID)
        } catch {
            if await app.handleIfUnauthorized(error) { return }
            errorMessage = (error as? APIError)?.localizedDescription ?? error.localizedDescription
        }
    }
}
