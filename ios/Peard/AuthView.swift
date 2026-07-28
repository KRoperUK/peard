import AuthenticationServices
import PeardCore
import SwiftUI

/// Sign-in screen (Requirement 6, 7, 21.1).
struct AuthView: View {
    @Environment(AppModel.self) private var app

    private enum Provider: String, Identifiable {
        case apple, google, test
        var id: String { rawValue }
    }

    @State private var busy: Provider?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Text("🍐")
                .font(.system(size: 72))
                .accessibilityHidden(true)
            Text("Pear'd")
                .font(.largeTitle.bold())
                .foregroundStyle(PearColor.textPrimary)
            Text("Moments & tallies, shared with your favourite people.")
                .font(.subheadline)
                .foregroundStyle(PearColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 28)

            appleButton
            googleButton

            #if DEBUG
            testUserButton
            #endif

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(PearColor.error)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .pearTransition()
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PearColor.background)
        .pearAnimation(value: errorMessage ?? "")
    }

    // MARK: Buttons

    private var appleButton: some View {
        Button {
            signIn(.apple) { try await coordinator.signInWithApple() }
        } label: {
            label(for: .apple, title: " Sign in with Apple", tint: .white)
        }
        .buttonStyle(.plain)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
        .disabled(busy != nil)
        .accessibilityLabel("Sign in with Apple")
    }

    private var googleButton: some View {
        Button {
            signIn(.google) {
                try await coordinator.signInWithGoogle(presentationAnchor: PresentationAnchor.current())
            }
        } label: {
            label(for: .google, title: "G   Continue with Google", tint: Color(rgb: 0x333333))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white)
                .strokeBorder(Color(rgb: 0xDDDDDD))
        )
        .disabled(busy != nil)
        .accessibilityLabel("Continue with Google")
    }

    #if DEBUG
    private var testUserButton: some View {
        Button {
            signIn(.test) { try await DebugSupport.signInAsTestUser(api: app.api) }
        } label: {
            label(for: .test, title: "🔧 Login Test User", tint: PearColor.accent)
                .font(.footnote.bold())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(PearColor.accent, style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
        .disabled(busy != nil)
    }
    #endif

    private func label(for provider: Provider, title: String, tint: Color) -> some View {
        ZStack {
            if busy == provider {
                ProgressView().tint(tint)
            } else {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    // MARK: Actions

    private var coordinator: AuthCoordinator {
        AuthCoordinator(api: app.api, config: app.config)
    }

    private func signIn(_ provider: Provider, action: @escaping () async throws -> Session) {
        busy = provider
        errorMessage = nil
        Task {
            defer { busy = nil }
            do {
                let session = try await action()
                try await app.establish(session)
            } catch let error as AuthError {
                // A cancellation returns to sign-in with no message
                // (Requirement 6.7, 7.6).
                errorMessage = error.errorDescription
            } catch {
                // Includes a Keychain failure while establishing the session
                // (clarification Q2).
                errorMessage = error.localizedDescription
            }
        }
    }
}
