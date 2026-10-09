import PeardCore
import SwiftUI

/// Says low data is shaping what the app does (issue #302), because otherwise
/// it just looks worse: softer photos, and a home screen that no longer updates
/// by itself.
///
/// Styled like the send queue's line rather than as an error — nothing is
/// wrong. Dismissed for the session; changed in Settings.
struct LowDataNotice: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.dotted")
                .foregroundStyle(PearColor.textSecondary)
                .accessibilityHidden(true)

            // Which switch did it, so somebody knows where to undo it.
            Text(app.lowData == .on
                ? String(localized: "Low data is on: smaller photos, no background refresh.")
                : String(localized: "Low Data Mode is on: smaller photos, no background refresh."))
                .font(.footnote.bold())
                .foregroundStyle(PearColor.textSecondary)

            Spacer(minLength: 4)

            Button {
                app.lowDataNoticeDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.bold())
                    .foregroundStyle(PearColor.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

/// Low data: follow iOS, or decide here.
///
/// Three states rather than a switch, because "off" has to be able to mean
/// "even when iOS says otherwise" — a toggle defaulting to whatever iOS reports
/// could not say that, and one that ignored iOS by default would override a
/// choice somebody already made for every app at once.
struct LowDataSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            Picker("Low data", selection: Binding(
                get: { app.lowData },
                set: { app.lowData = $0 }
            )) {
                ForEach(LowDataPreference.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Low data")
        } header: {
            Text("Low data")
        } footer: {
            Text(footer)
        }
    }

    /// The choice's meaning, plus what iOS is saying right now when that is
    /// what decides — "Automatic" alone does not tell anybody which way it went.
    private var footer: String {
        guard app.lowData == .automatic else { return app.lowData.subtitle }
        let now = app.isNetworkConstrained ? String(localized: "On now.") : String(localized: "Off now.")
        return String(localized: "\(app.lowData.subtitle) \(now)")
    }
}
