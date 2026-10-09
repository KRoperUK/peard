import PeardCore
import SwiftUI

/// The devices and widgets that can still read this account, each revocable.
///
/// A widget token is a bearer credential sitting in the App Group container, and
/// until now the only way to cancel one was to sign out of the phone holding it.
/// A lost iPad, or a widget on a phone somebody no longer uses, had no answer
/// short of waiting out the 30-day expiry. This is the answer (#367).
///
/// The server sends ids, labels and dates — never the secrets — so a row is
/// revoked by id. The row that is this phone's own token is marked, because
/// revoking it is allowed but cuts off the widget in your hand until the app next
/// syncs and mints a fresh one.
struct DevicesWidgetsSection: View {
    @State private var tokens: [WidgetTokenInfo] = []
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var pendingRevocation: WidgetTokenInfo?
    @State private var revokeError: String?

    let api: APIClient
    let store: SharedStore

    var body: some View {
        Section {
            content
        } header: {
            Text("Signed-in devices & widgets")
        } footer: {
            Text(
                "Each entry can read your widget feed and log moments from a widget. Revoke any you don't recognise; "
                    + "a device you still use will quietly sign itself back in the next time the app opens."
            )
        }
        .task { await load() }
        .confirmationDialog(
            revocationPrompt,
            isPresented: Binding(
                get: { pendingRevocation != nil },
                set: { if !$0 { pendingRevocation = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRevocation
        ) { token in
            Button("Revoke", role: .destructive) {
                Task { await revoke(token) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { token in
            if token.isCurrentDevice {
                Text("This is the widget on this device. It stops updating until you next open the app.")
            }
        }
        .alert(
            "Couldn't revoke",
            isPresented: Binding(get: { revokeError != nil }, set: { if !$0 { revokeError = nil } }),
            presenting: revokeError
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var content: some View {
        if isLoading && tokens.isEmpty {
            HStack {
                Text("Loading…").foregroundStyle(PearColor.textSecondary)
                Spacer()
                ProgressView()
            }
        } else if loadFailed && tokens.isEmpty {
            Text("Couldn't load your devices.")
                .foregroundStyle(PearColor.textSecondary)
        } else if tokens.isEmpty {
            Text("No devices or widgets are signed in.")
                .foregroundStyle(PearColor.textSecondary)
        } else {
            ForEach(tokens) { token in
                row(token)
            }
        }
    }

    private func row(_ token: WidgetTokenInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title(for: token))
                        .foregroundStyle(PearColor.textPrimary)
                    if token.isCurrentDevice {
                        Text("This device")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(PearColor.textSecondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(PearColor.textSecondary)
                    }
                }
                Text(detail(for: token))
                    .font(.footnote)
                    .foregroundStyle(PearColor.textSecondary)
            }
            Spacer()
            Button("Revoke", role: .destructive) {
                pendingRevocation = token
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Revoke \(title(for: token))")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Wording

    /// The label the minting client chose, which today is the same for every
    /// phone; a blank one is still a row somebody may want gone.
    private func title(for token: WidgetTokenInfo) -> String {
        token.label.isEmpty ? "Widget" : token.label
    }

    private func detail(for token: WidgetTokenInfo) -> String {
        var parts: [String] = []
        if let created = token.created {
            parts.append("Signed in \(created.formatted(date: .abbreviated, time: .omitted))")
        }
        if let expires = token.expires {
            parts.append("expires \(expires.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.isEmpty ? "No dates recorded" : parts.joined(separator: " · ")
    }

    private var revocationPrompt: String {
        guard let pendingRevocation else { return "Revoke access?" }
        return "Revoke \(title(for: pendingRevocation))?"
    }

    // MARK: Actions

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            tokens = try await api.widgetTokens(currentTokenID: store.widgetTokenID)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    /// Drops the row only once the server has confirmed. Revoke is idempotent
    /// server-side, so a retry after a lost response is harmless.
    private func revoke(_ token: WidgetTokenInfo) async {
        do {
            try await api.revokeWidgetToken(id: token.id)
            tokens.removeAll { $0.id == token.id }
        } catch {
            revokeError = "Check your connection and try again."
        }
    }
}
