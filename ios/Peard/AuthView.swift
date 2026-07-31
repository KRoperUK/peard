import AuthenticationServices
import PeardCore
import SwiftUI

/// Sign-in screen (Requirement 6, 7, 21.1).
struct AuthView: View {
    @Environment(AppModel.self) private var app

    private enum Provider: String, Identifiable {
        case apple, google, password, test
        var id: String { rawValue }
    }

    /// Whether the email and password fields sign in or create an account.
    ///
    /// A mode rather than a second screen: the two differ by one button and one
    /// line of copy, and a separate screen would mean somebody who guessed wrong
    /// had to go back and retype what they had already entered.
    private enum EmailMode: String, CaseIterable, Identifiable {
        case signIn, signUp
        var id: String { rawValue }
        var title: String { self == .signIn ? "Sign in" : "Create account" }
    }

    @State private var busy: Provider?
    @State private var errorMessage: String?
    @State private var email = ""
    @State private var password = ""
    @State private var emailMode: EmailMode = .signIn

    var body: some View {
        // Scrollable, because this screen is now taller than a small phone with
        // the keyboard up. It used to rely on two Spacers absorbing the
        // difference, which stops working once the content exceeds the space:
        // the password field and the button it needs were simply unreachable on
        // an SE, with no indication anything was below the fold.
        ScrollView {
            VStack(spacing: 12) {
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

                #if DEBUG
                googleButton
                #else
                if app.config.hasGoogleClientID {
                    googleButton
                }
                #endif

                Divider()
                    .background(PearColor.divider)
                    .padding(.vertical, 12)

                modePicker
                emailFields
                emailSubmitButton

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

                Link("Privacy Policy", destination: PeardLinks.privacyPolicy)
                    .font(.footnote)
                    .foregroundStyle(PearColor.textSecondary)
                    .padding(.top, 24)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PearColor.background)
        .pearAnimation(value: errorMessage ?? "")
    }

    /// Switching modes clears the error: "that email and password don't match an
    /// account" is stale advice the moment somebody acts on it by switching to
    /// Create account, and leaving it up makes the new screen look broken.
    private var modePicker: some View {
        Picker("", selection: $emailMode) {
            ForEach(EmailMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(busy != nil)
        .onChange(of: emailMode) { _, _ in errorMessage = nil }
        .accessibilityLabel("Email and password mode")
    }

    // MARK: Buttons

    private var appleButton: some View {
        Button {
            signIn(.apple) { try await coordinator.signInWithApple() }
        } label: {
            ZStack {
                if busy == .apple {
                    ProgressView().tint(.white)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "apple.logo")
                        Text("Sign in with Apple")
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
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

    private var emailFields: some View {
        VStack(spacing: 8) {
            TextField("", text: $email, prompt: Text("Email").foregroundStyle(PearColor.textTertiary))
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(PearColor.textPrimary)
                .padding(14)
                .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PearColor.divider))

            SecureField("", text: $password, prompt: Text("Password").foregroundStyle(PearColor.textTertiary))
                // `.newPassword` on sign-up so the keychain offers to generate
                // and save one rather than searching for an existing entry that
                // by definition does not exist yet.
                .textContentType(emailMode == .signUp ? .newPassword : .password)
                .foregroundStyle(PearColor.textPrimary)
                .padding(14)
                .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PearColor.divider))

            if emailMode == .signUp {
                // Stated up front rather than discovered by being rejected:
                // PocketBase enforces eight, and finding that out by submitting
                // is a wasted round trip and a needless error message.
                Text("At least 8 characters.")
                    .font(.caption2)
                    .foregroundStyle(PearColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pearTransition()
            }
        }
        .padding(.bottom, 8)
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }

    /// Sign-in accepts any non-empty password, because an existing account may
    /// predate the eight-character minimum and refusing to *submit* it would
    /// lock somebody out of their own account.
    private var canSubmitEmail: Bool {
        guard !trimmedEmail.isEmpty, busy == nil else { return false }
        return emailMode == .signUp ? password.count >= 8 : !password.isEmpty
    }

    private var emailSubmitButton: some View {
        Button {
            let identity = trimmedEmail
            let submitted = password
            let mode = emailMode
            signIn(.password) {
                mode == .signUp
                    ? try await coordinator.signUpWithPassword(email: identity, password: submitted)
                    : try await coordinator.signInWithPassword(identity: identity, password: submitted)
            }
        } label: {
            label(for: .password, title: emailMode == .signUp ? "Create account" : "Continue", tint: .white)
        }
        .buttonStyle(.plain)
        .background(PearColor.accent, in: RoundedRectangle(cornerRadius: 12))
        .disabled(!canSubmitEmail)
        .opacity(canSubmitEmail ? 1 : 0.5)
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
