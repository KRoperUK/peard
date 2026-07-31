import PeardCore
import SwiftUI

/// The gate in front of everything else: nothing reaches the network until this
/// screen has been agreed to.
///
/// It sits ahead of the sign-in screen rather than on it. Every sign-in method
/// the app offers — Apple, Google, email and password — sends an identifier off
/// the device before there is an account to attach it to, so a consent checkbox
/// next to the buttons would already be too late for the thing it is meant to
/// gate.
///
/// The wording summarises rather than reproduces the policy, and the full text
/// is one tap away. A screen nobody can read is not consent, and a wall of legal
/// prose is a screen nobody reads.
struct PrivacyConsentView: View {
    @Environment(AppModel.self) private var app

    @State private var isAgreeing = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    points
                    policyLink
                }
                .padding(.horizontal, 32)
                .padding(.top, 48)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            agreeButton
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PearColor.background)
    }

    // MARK: Copy

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("🍐")
                .font(.system(size: 56))
                .accessibilityHidden(true)
            Text(app.isFirstPrivacyPrompt ? "Before you sign in" : "We've updated our privacy policy")
                .font(.title.bold())
                .foregroundStyle(PearColor.textPrimary)
            Text(
                app.isFirstPrivacyPrompt
                    ? "Pear'd hasn't sent anything anywhere yet, and won't until you agree to this."
                    : "Nothing has changed about what Pear'd sends while you were away — but the policy has, so here it is again."
            )
            .font(.subheadline)
            .foregroundStyle(PearColor.textSecondary)
        }
    }

    /// The four things worth knowing before agreeing, in the order somebody
    /// would want to be told them. Deliberately including the unflattering one:
    /// signing in is itself the first thing that leaves the device.
    private var points: some View {
        VStack(alignment: .leading, spacing: 16) {
            point(
                icon: "person.crop.circle",
                title: "Signing in sends your email",
                body: "Apple, Google or your own email address identifies your account. That's the first thing to leave your device, which is why we're asking now."
            )
            point(
                icon: "lock.shield",
                title: "Only your connections see your moments",
                body: "Your name, photo and the moments you log are visible to people you've paired or grouped with, and nobody else. The server enforces that, not just the app."
            )
            point(
                icon: "person.2",
                title: "Contacts never leave in the clear",
                body: "Finding friends is opt-in, and matches on one-way hashes computed on your device. Being findable by other people is a separate switch, off by default."
            )
            point(
                icon: "trash",
                title: "You can export or delete it all",
                body: "Settings has a full export of your own data, and deleting your account from there erases it — no email to us, no waiting."
            )
        }
    }

    private func point(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(PearColor.accent)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(PearColor.textPrimary)
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(PearColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var policyLink: some View {
        Link(destination: PeardLinks.privacyPolicy) {
            HStack(spacing: 6) {
                Text("Read the full privacy policy")
                Image(systemName: "arrow.up.right.square")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PearColor.accent)
        }
        .padding(.top, 4)
        .accessibilityHint("Opens peard.kroper.uk in your browser")
    }

    // MARK: Agreement

    /// One button, no pre-ticked box. Tapping it is the agreement, and the label
    /// says what is being agreed to rather than "Continue".
    private var agreeButton: some View {
        VStack(spacing: 10) {
            Button {
                isAgreeing = true
                Task { await app.agreeToPrivacyPolicy() }
            } label: {
                ZStack {
                    if isAgreeing {
                        ProgressView().tint(.white)
                    } else {
                        Text("Agree and continue")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 24)
                .padding(.vertical, 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(PearColor.accent, in: RoundedRectangle(cornerRadius: 12))
            .disabled(isAgreeing)
            .accessibilityLabel("Agree to the privacy policy and continue")

            // Said plainly rather than hidden: there is no version of the app
            // that works without a server, so "decline" would be a button that
            // quits. Better to be honest about the choice than to fake one.
            Text("Pear'd needs a server to share anything, so there's no way to use it without agreeing.")
                .font(.caption2)
                .foregroundStyle(PearColor.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
