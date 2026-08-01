import PeardCore
import SwiftUI

/// What this build is, and what it is talking to.
///
/// Written for TestFlight. A tester who says "the delete button didn't work"
/// cannot currently say which build they were on or which server answered — and
/// this session proved how much that matters: the app shipped features whose
/// routes did not exist yet on the server, and the only symptom was a request
/// failing for no stated reason.
///
/// Both halves are shown because either can be the stale one. The app version
/// comes from the bundle; the server's comes from `GET /api/peard/status`, which
/// needs no auth and so answers even when the session is the thing that is
/// broken.
struct AboutSection: View {
    @State private var status: ServerStatus?
    @State private var statusError: String?
    @State private var isLoading = false

    let api: APIClient
    let serverURL: URL

    var body: some View {
        Section {
            row("App", value: appVersion)
            row("Server", value: serverURL.host ?? serverURL.absoluteString)
            serverBuildRow

            Button {
                UIPasteboard.general.string = diagnosticsSummary
            } label: {
                Label("Copy diagnostics", systemImage: "doc.on.doc")
            }
            .foregroundStyle(PearColor.textPrimary)
            .disabled(isLoading)
        } header: {
            Text("About")
        } footer: {
            Text("Paste this into a bug report and we'll know exactly which build and server you saw it on.")
        }
        .task { await load() }
    }

    // MARK: Rows

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(PearColor.textPrimary)
            Spacer()
            Text(value)
                .font(.footnote.monospaced())
                .foregroundStyle(PearColor.textSecondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    @ViewBuilder
    private var serverBuildRow: some View {
        if isLoading {
            HStack {
                Text("Server build").foregroundStyle(PearColor.textPrimary)
                Spacer()
                ProgressView()
            }
        } else if let status {
            row("Server build", value: serverBuildLabel(status))
        } else if let statusError {
            row("Server build", value: statusError)
        }
    }

    /// The commit when the build supplied one, else the build time — which is
    /// always stamped, and is enough on its own to tell two deploys apart. Shown
    /// rather than hidden when it says "unknown", because "unknown" is itself
    /// information about how that server was built.
    private func serverBuildLabel(_ status: ServerStatus) -> String {
        if status.commit != "unknown", !status.commit.isEmpty {
            return status.commit
        }
        return status.builtAt
    }

    // MARK: Values

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// One line per fact, because it is going into a message somebody types on a
    /// phone and every extra character is one they might trim.
    private var diagnosticsSummary: String {
        var lines = ["Pear'd \(appVersion)", "iOS \(UIDevice.current.systemVersion)"]
        lines.append("server \(serverURL.host ?? serverURL.absoluteString)")
        if let status {
            lines.append("server build \(serverBuildLabel(status))")
        } else if let statusError {
            lines.append("server build unavailable (\(statusError))")
        }
        return lines.joined(separator: "\n")
    }

    private func load() async {
        guard status == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            status = try await api.serverStatus()
        } catch let error as APIError where error.status == 404 {
            // A server predating the status route. Saying so is more useful than
            // an error, and is itself a version signal: anything without this
            // route is older than 1 August 2026.
            statusError = "older than this app"
        } catch {
            statusError = "unavailable"
        }
    }
}
