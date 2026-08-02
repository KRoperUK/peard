import PeardCore
import SwiftUI

/// The signed-in, paired shell.
///
/// Everything used to be one screen. That screen carried the title, the connection
/// switcher, the hero, the moment strip, both tally rows, a breakdown summary,
/// three timeline rows, a camera button and a sign-out link — with the whole shared
/// timeline, the per-moment breakdown and every connection setting behind sheets
/// reached from a menu. The consequence was that the home screen had to keep
/// shrinking to fit, which is why the timeline was capped at three rows and the
/// breakdown was one line.
///
/// Splitting it into tabs gives each of those its own screenful and lets Home be
/// about the one thing it is for: logging a moment. The tab bar also means the
/// timeline and the tallies are reachable in one tap rather than two, and neither
/// is a modal that has to be dismissed to log anything.
struct MainTabView: View {
    @Environment(AppModel.self) private var app

    @State private var model: HomeModel
    @State private var selection: Tab = .home

    enum Tab: Hashable {
        case home, timeline, tallies, settings
    }

    init(model: HomeModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        TabView(selection: $selection) {
            HomeView(model: model, onShowTallies: { selection = .tallies })
                .tag(Tab.home)
                .tabItem { Label("Home", systemImage: "house.fill") }

            TimelineTab(model: model)
                .tag(Tab.timeline)
                .tabItem { Label("Timeline", systemImage: "clock.arrow.circlepath") }

            TalliesTab(model: model)
                .tag(Tab.tallies)
                .tabItem { Label("Tallies", systemImage: "chart.bar.fill") }

            ConnectionSettingsView(model: model)
                .tag(Tab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(PearColor.accent)
        // A notification tap points at a specific moment, and the hero is where
        // that moment is shown — so it has to bring Home forward, or the tap would
        // appear to do nothing while the app sat on Settings.
        .onChange(of: app.focusedPostID) { _, postID in
            if postID != nil { selection = .home }
        }
    }
}

/// The whole shared timeline, as a tab rather than a sheet.
///
/// The model is rebuilt when the connection's member list or custom moments change:
/// `HistoryModel` resolves author names and emoji from those, and it is handed them
/// at init because the `users` view rule means member names are only available from
/// `GET /api/peard/connections`.
private struct TimelineTab: View {
    @Environment(AppModel.self) private var app

    let model: HomeModel

    var body: some View {
        HistoryView(
            model: HistoryModel(
                api: model.apiClient,
                pairID: model.pairID,
                signedInUserID: model.signedInUserID,
                customKinds: model.customKinds,
                connection: model.connection,
                unreadWatermark: app.unreadWatermark(forConnection: model.pairID)
            ),
            serverURL: model.serverURL,
            title: model.connectionTitle
        )
        .id(historyIdentity)
    }

    /// Rebuilds the paged model when what it renders with changes, and only then:
    /// keying on the connection alone would keep stale names after somebody joins,
    /// and keying on everything would throw away the loaded pages on every refresh.
    ///
    /// The watermark is in here because it is captured by the home screen's load,
    /// which may not have run by the time this tab's body is first evaluated.
    /// Without it, whether the "New" line appeared would depend on which of the
    /// two happened first — an ordering dependency with no visible symptom, and
    /// the divider silently missing on exactly the launch it is for. It changes
    /// at most once per connection per session, so it costs no reloads.
    ///
    /// The catalogue is fingerprinted by content rather than counted. It used to
    /// be `customKinds.count`, which is blind to the one change that does not
    /// alter it: renaming a moment, or giving it a different emoji. The timeline
    /// went on drawing "Dog walk" after it had been renamed everywhere else,
    /// because nothing told this model to rebuild.
    private var historyIdentity: String {
        let members = model.connection?.members.map(\.user).sorted().joined(separator: ",") ?? ""
        let watermark = app.unreadWatermark(forConnection: model.pairID)?.timeIntervalSince1970 ?? 0
        let catalogue = model.customKinds
            .map { "\($0.slug):\($0.emoji):\($0.label)" }
            .sorted()
            .joined(separator: ",")
        return "\(model.pairID)|\(members)|\(catalogue)|\(watermark)"
    }
}

/// How many, and of what.
///
/// The two tally rows and the per-moment breakdown were a one-line summary plus a
/// sheet, because the home screen had no room. Here they are the whole screen, so
/// the breakdown is inline and the window picker is at the top where it belongs.
private struct TalliesTab: View {
    let model: HomeModel

    /// All time by default: it is the only window guaranteed to have something in
    /// it, so the screen does not open on "nothing logged today yet".
    @State private var window: TallyWindow = .all

    var body: some View {
        NavigationStack {
            Form {
                // First, because it is the only part of this screen that reads
                // as news rather than as arithmetic.
                if let recap = model.recap {
                    RecapSection(recap: recap, mineLabel: "You", othersLabel: model.othersLabel)
                }

                Section {
                    tallyRow(label: "You", tallies: model.myTallies)
                    tallyRow(label: model.othersLabel, tallies: model.partnerTallies)
                } header: {
                    Text("Totals")
                } footer: {
                    if !model.talliesAreServerSide {
                        Text("This server counts on the device, so totals past 500 moments may be short.")
                    }
                }

                MomentBreakdownSection(
                    tallies: model.momentTallies,
                    mineLabel: "You",
                    othersLabel: model.othersLabel,
                    isServerSide: model.talliesAreServerSide,
                    window: $window
                )
            }
            .scrollContentBackground(.hidden)
            .background(PearColor.background)
            .navigationTitle("Tallies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ConnectionToolbarTitle(title: "Tallies", subtitle: model.connectionTitle)
                }
            }
            .refreshable {
                await model.refreshTallies()
                await model.refreshRecap()
            }
        }
    }

    private func tallyRow(label: String, tallies: TallyPeriods) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline.bold())
                .foregroundStyle(PearColor.accent)
                .frame(width: 70, alignment: .leading)
                .lineLimit(1)
            Spacer(minLength: 4)
            Group {
                period("T", tallies.day)
                period("W", tallies.week)
                period("M", tallies.month)
                period("All", tallies.all)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(label): \(tallies.day) today, \(tallies.week) this week, \(tallies.month) this month, \(tallies.all) all time"
        )
    }

    private func period(_ caption: String, _ value: Int) -> some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PearColor.textPrimary)
                .monospacedDigit()
            Text(caption)
                .font(.caption2)
                .foregroundStyle(PearColor.textTertiary)
        }
        .frame(minWidth: 34)
    }
}

/// A two-line navigation title: what the screen is, and which connection it is
/// about. Every tab except Home needs it, because the rail — which is the only
/// other thing that says which connection is on screen — lives on Home.
struct ConnectionToolbarTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.headline)
                .foregroundStyle(PearColor.textPrimary)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(PearColor.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
    }
}
