import PeardCore
import SwiftUI

/// Shared timeline, tallies, moments, photo capture and reactions
/// (Requirements 11–15).
///
/// The title, the connection switcher and the latest-moment hero are pinned:
/// they are the answer to "what is happening with us right now", so they stay on
/// screen while the tallies and history scroll underneath.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: HomeModel
    @State private var showCamera = false
    @State private var showLeaveConfirmation = false
    @State private var showMomentSheet = false
    @State private var showInviteSheet = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showBreakdown = false
    @FocusState private var noteFocused: Bool

    init(model: HomeModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            scrollingContent
        }
        .background(PearColor.background)
        // The title, switcher and hero are held outside the scrolling content
        // rather than pinned inside it. As a pinned section header they stopped
        // at the safe-area inset, which left the status-bar band part of the
        // scrolling viewport and let the tallies slide up behind the clock. As a
        // safe-area inset the header owns that band, and its background extends
        // through it.
        .safeAreaInset(edge: .top, spacing: 20) {
            pinnedHeader
        }
        .refreshable { await model.refreshAll() }
        .task { await model.load() }
        .task(id: app.focusedPostID) { await model.focus(postID: app.focusedPostID) }
        .task { await pollWhileVisible() }
        .onChange(of: scenePhase) { _, phase in
            // Requirement 11.13.
            guard phase == .active else { return }
            Task { await model.refreshAll() }
        }
        .onChange(of: model.quickSend?.moment.kind) { _, kind in
            noteFocused = kind != nil
        }
        .onChange(of: model.noteText) { _, _ in
            model.noteDidChange()
        }
        .pearAnimation(value: model.toast ?? "")
        .alert(item: $model.alert)
        .confirmationDialog(
            model.isGroup ? "Leave this group?" : "Un-pear?",
            isPresented: $showLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive) {
                Task { await model.leaveConnection() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                model.isGroup
                    ? "You'll lose this group's shared timeline."
                    : "You'll both lose the shared timeline."
            )
        }
        .sheet(isPresented: $showMomentSheet) {
            MomentSheet(model: model)
        }
        .sheet(isPresented: $showInviteSheet) {
            InviteSheet(pairID: model.pairID, connectionTitle: model.connectionTitle)
        }
        .sheet(isPresented: $showSettings) {
            ConnectionSettingsView(model: model)
                .environment(app)
        }
        .sheet(isPresented: $showBreakdown) {
            MomentBreakdownSheet(
                tallies: model.momentTallies,
                connectionTitle: model.connectionTitle,
                mineLabel: "You",
                othersLabel: model.othersLabel,
                isServerSide: model.talliesAreServerSide
            )
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(
                model: HistoryModel(
                    api: app.api,
                    pairID: model.pairID,
                    signedInUserID: model.signedInUserID,
                    customKinds: model.customKinds,
                    connection: model.connection
                ),
                serverURL: model.serverURL,
                title: model.connectionTitle
            )
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                guard let image else { return }
                Task { await model.upload(image: image) }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Pinned header

    private var pinnedHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pear'd 🍐")
                    .font(.title2.bold())
                    .foregroundStyle(PearColor.textPrimary)
                Spacer(minLength: 8)
                connectionMenu
            }
            heroCard
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        // Held above the scrolling content, so it must be opaque — and the fill
        // has to reach through the top safe area, or the status-bar band shows
        // whatever is scrolling underneath.
        .background(PearColor.background.ignoresSafeArea(edges: .top))
    }

    private var connectionMenu: some View {
        Menu {
            if app.connections.count > 1 {
                Section("Connections") {
                    ForEach(app.connections) { connection in
                        Button {
                            app.select(connectionID: connection.id)
                        } label: {
                            if connection.id == model.pairID {
                                Label(connection.title(), systemImage: "checkmark")
                            } else {
                                Text(connection.title())
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    showSettings = true
                } label: {
                    Label("Connection settings", systemImage: "gearshape")
                }
                Button {
                    showHistory = true
                } label: {
                    Label("All moments", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    showBreakdown = true
                } label: {
                    Label("Moment breakdown", systemImage: "chart.bar.xaxis")
                }
                Button {
                    showInviteSheet = true
                } label: {
                    Label(model.isGroup ? "Invite to this group" : "Add someone here", systemImage: "person.badge.plus")
                }
                Button {
                    app.startAddingConnection()
                } label: {
                    Label("New connection", systemImage: "plus.circle")
                }
            }

            Section {
                Button(role: .destructive) {
                    showLeaveConfirmation = true
                } label: {
                    Label(model.isGroup ? "Leave group" : "Un-pear", systemImage: "person.badge.minus")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.connectionTitle)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                if model.isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.caption2)
                        .accessibilityLabel("Muted")
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.bold())
            }
            .foregroundStyle(PearColor.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(PearColor.surface, in: Capsule())
        }
        .accessibilityLabel("Connection: \(model.connectionTitle)")
        .accessibilityHint("Switch connection, invite someone, or leave")
    }

    private func title(for connection: Connection) -> String {
        connection.title()
    }

    /// The hero: whatever landed most recently, kept compact enough to stay
    /// pinned without crowding out the content below it.
    private var heroCard: some View {
        HStack(spacing: 14) {
            if let post = model.displayedPost {
                heroThumbnail(for: post)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.authorLabel(for: post)) · \(model.caption(for: post))")
                        .font(.subheadline.bold())
                        .foregroundStyle(PearColor.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(ElapsedTime.label(for: post.created))
                            .font(.caption)
                            .foregroundStyle(PearColor.textTertiary)
                        // A moment that has not reached the server says so, rather
                        // than looking identical to one that has.
                        if model.displayedPostIsPending {
                            Label(
                                model.isOffline ? "waiting" : "sending",
                                systemImage: model.isOffline ? "wifi.slash" : "arrow.up.circle"
                            )
                            .font(.caption2)
                            .foregroundStyle(PearColor.textTertiary)
                        }
                    }

                    if let note = post.displayNote {
                        Text(note)
                            .font(.callout.italic())
                            .foregroundStyle(PearColor.textSecondary)
                            .lineLimit(2)
                    }

                    reactionRow
                }
                Spacer(minLength: 0)
            } else {
                Text("🍐").font(.system(size: 44)).accessibilityHidden(true)
                Text("No moments yet — send a pear!")
                    .font(.subheadline)
                    .foregroundStyle(PearColor.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func heroThumbnail(for post: Post) -> some View {
        if post.type == .photo, let path = post.mediaThumbnailPath() {
            AsyncImage(url: URL(string: model.serverURL.absoluteString + path)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Text("📷").font(.system(size: 32)).accessibilityHidden(true)
                default:
                    ProgressView()
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Photo from \(model.authorLabel(for: post))")
        } else {
            Text(model.emoji(for: post))
                .font(.system(size: 44))
                .frame(width: 72, height: 72)
                .accessibilityLabel(model.label(for: post.eventKind))
        }
    }

    @ViewBuilder
    private var reactionRow: some View {
        if model.canReactToDisplayedPost || !model.displayedReactionKinds.isEmpty {
            HStack(spacing: 8) {
                if model.canReactToDisplayedPost {
                    ForEach(ReactionKind.allCases, id: \.rawValue) { kind in
                        Button {
                            Task { await model.react(kind: kind) }
                        } label: {
                            Text(kind.emoji)
                                .font(.footnote)
                                .padding(6)
                                .background(PearColor.background, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("React with \(kind.accessibilityLabel)")
                    }
                }

                if !model.displayedReactionKinds.isEmpty {
                    if model.canReactToDisplayedPost {
                        Divider().frame(height: 16)
                    }
                    HStack(spacing: 2) {
                        ForEach(model.displayedReactionKinds, id: \.rawValue) { kind in
                            Text(kind.emoji)
                                .font(.caption2)
                                .accessibilityLabel("\(kind.accessibilityLabel) recorded")
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: Scrolling content

    private var scrollingContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            momentStrip

            if model.quickSend != nil {
                quickSendRow.pearTransition()
            }

            if let summary = model.pendingSummary {
                pendingBanner(summary)
            }

            tallyRows

            if !model.historyPosts.isEmpty {
                historyList
            }

            if model.hasMoreHistory || !model.historyPosts.isEmpty {
                allMomentsButton
            }

            if let toast = model.toast {
                Text(toast)
                    .font(.headline)
                    .foregroundStyle(PearColor.accent)
                    .frame(maxWidth: .infinity)
                    .pearTransition()
            }

            if let banner = model.banner {
                Text(banner)
                    .font(.footnote)
                    .foregroundStyle(PearColor.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            cameraButton
            footer
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    /// The queue's state, in one line. Nothing is shown when it is empty, so the
    /// common case stays quiet.
    private func pendingBanner(_ summary: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: model.stalledSends.isEmpty
                ? (model.isOffline ? "wifi.slash" : "arrow.up.circle")
                : "exclamationmark.triangle.fill")
                .foregroundStyle(model.stalledSends.isEmpty ? PearColor.textSecondary : PearColor.error)

            Text(summary)
                .font(.footnote.bold())
                .foregroundStyle(model.stalledSends.isEmpty ? PearColor.textSecondary : PearColor.error)

            Spacer(minLength: 4)

            if !model.stalledSends.isEmpty {
                Button("Retry") {
                    Task { await model.retryPendingSends() }
                }
                .font(.footnote.bold())
                .foregroundStyle(PearColor.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary)
    }

    private var allMomentsButton: some View {
        Button {
            showHistory = true
        } label: {
            HStack {
                Text("All moments")
                    .font(.subheadline.bold())
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
            }
            .foregroundStyle(PearColor.accent)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the whole shared timeline")
    }

    // MARK: Moments

    /// One tap logs a moment; the strip scrolls once a connection has invented
    /// enough of its own.
    ///
    /// The "More" button is pinned outside the scroll view rather than sitting at
    /// the end of the strip: four tiles already overflow the screen, so as the
    /// last scroll item it started off-screen with nothing to hint at it, which
    /// hid the only way to invent a moment.
    private var momentStrip: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.moments) { moment in
                        Button {
                            model.tap(moment: moment)
                        } label: {
                            VStack(spacing: 4) {
                                Text(moment.emoji).font(.largeTitle)
                                Text(moment.label)
                                    .font(.caption.bold())
                                    .foregroundStyle(PearColor.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 88)
                            .padding(.vertical, 14)
                            .background(
                                model.quickSend?.moment.kind == moment.kind
                                    ? PearColor.accent.opacity(0.18)
                                    : PearColor.surface,
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                        }
                        .buttonStyle(.plain)
                        // Requirement 12.10.
                        .disabled(model.isBusy)
                        .accessibilityLabel("Log \(moment.label)")
                        .accessibilityHint("Sends in \(Int(QuickSend.delay)) seconds unless you add a note")
                    }
                }
            }

            Button {
                showMomentSheet = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.title.bold())
                        .foregroundStyle(PearColor.accent)
                    Text("More")
                        .font(.caption.bold())
                        .foregroundStyle(PearColor.textSecondary)
                }
                .frame(width: 60)
                .padding(.vertical, 14)
                .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(PearColor.divider, style: StrokeStyle(lineWidth: 1, dash: [4]))
                )
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .accessibilityLabel("More moments")
        }
        .opacity(model.isBusy ? 0.6 : 1)
    }

    /// The undo/annotate window. It says what is about to happen and by when, so
    /// the automatic send is never a surprise.
    private var quickSendRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let send = model.quickSend {
                    ZStack {
                        Circle()
                            .strokeBorder(PearColor.divider, lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: model.quickSendProgress)
                            .stroke(PearColor.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(send.moment.emoji).font(.footnote)
                    }
                    .frame(width: 28, height: 28)
                    .animation(.linear(duration: 0.1), value: model.quickSendProgress)
                    .accessibilityHidden(true)

                    Text(model.quickSendCaption)
                        .font(.footnote.bold())
                        .foregroundStyle(PearColor.textSecondary)
                        .accessibilityLabel("\(send.moment.label): \(model.quickSendCaption)")
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                TextField("", text: $model.noteText, prompt: Text("Add a note (optional)…"))
                    .focused($noteFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await model.sendNow() } }
                    .padding(12)
                    .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Moment note")

                Button("Send") {
                    Task { await model.sendNow() }
                }
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(PearColor.accent, in: RoundedRectangle(cornerRadius: 12))
                .buttonStyle(.plain)

                Button {
                    model.cancelQuickSend()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(PearColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel this moment")
            }
        }
        .padding(12)
        .background(PearColor.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Tallies

    private var tallyRows: some View {
        VStack(spacing: 6) {
            tallyRow(label: "You", tallies: model.myTallies)
            tallyRow(label: model.othersLabel, tallies: model.partnerTallies)
            if model.hasMomentBreakdown {
                breakdownStrip
            }
        }
    }

    /// The tally rows say how many; this says of what. One line, because the home
    /// screen is meant to fit without scrolling — the full breakdown is a tap away
    /// rather than inline, since a connection with a dozen invented moments would
    /// be a dozen rows.
    private var breakdownStrip: some View {
        Button {
            showBreakdown = true
        } label: {
            HStack(spacing: 12) {
                ForEach(model.topMoments) { kind in
                    HStack(spacing: 3) {
                        Text(kind.emoji)
                            .font(.caption)
                        Text("\(kind.total)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PearColor.textPrimary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(PearColor.accent)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(breakdownAccessibilityLabel)
        .accessibilityHint("Opens the breakdown by moment")
    }

    private var breakdownAccessibilityLabel: String {
        let parts = model.topMoments.map { "\($0.label) \($0.total)" }
        return parts.isEmpty ? "Moment breakdown" : "Most logged: " + parts.joined(separator: ", ")
    }

    private func tallyRow(label: String, tallies: TallyPeriods) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(PearColor.accent)
                .frame(width: 60, alignment: .leading)
            Group {
                Text("T \(tallies.day)")
                Text("W \(tallies.week)")
                Text("M \(tallies.month)")
                Text("All \(tallies.all)")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(PearColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(label): \(tallies.day) today, \(tallies.week) this week, \(tallies.month) this month, \(tallies.all) all time"
        )
    }

    // MARK: History

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.historyPosts) { post in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(model.authorLabel(for: post)) · \(model.emoji(for: post))")
                    Text(historyDetail(for: post))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if model.pendingSend(for: post) != nil {
                        Image(systemName: model.isOffline ? "wifi.slash" : "arrow.up.circle")
                            .font(.caption2)
                            .foregroundStyle(PearColor.textTertiary)
                            .accessibilityLabel("not sent yet")
                    }
                    Text(ElapsedTime.label(for: post.created))
                        .font(.caption2)
                        .foregroundStyle(PearColor.textTertiary)
                }
                .font(.footnote)
                .foregroundStyle(PearColor.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func historyDetail(for post: Post) -> String {
        if let note = post.displayNote { return note }
        return model.caption(for: post)
    }

    // MARK: Actions

    private var cameraButton: some View {
        Button {
            Task { await requestCamera() }
        } label: {
            ZStack {
                if model.busy == .photo {
                    ProgressView().tint(.white)
                } else {
                    Text("📸 Share a moment")
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
        .disabled(model.isBusy)
        .accessibilityLabel("Share a photo moment")
    }

    private var footer: some View {
        HStack {
            Button("Sign out") {
                Task { await app.signOut() }
            }
            .foregroundStyle(PearColor.textSecondary)

            Spacer()

            Button(model.isGroup ? "Leave group" : "Un-pear") {
                showLeaveConfirmation = true
            }
            .foregroundStyle(PearColor.error)
        }
        .font(.subheadline)
        .padding(.top, 8)
    }

    /// Requirement 13.1, 13.2.
    private func requestCamera() async {
        switch await CameraAuthorization.request() {
        case .granted:
            showCamera = true
        case .denied:
            model.alert = HomeModel.AlertContent(
                title: "Camera access needed",
                message: "Enable camera access in Settings to share a moment."
            )
        }
    }

    /// Requirement 11.12 — refresh every 30 seconds while in the foreground.
    private func pollWhileVisible() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, scenePhase == .active else { continue }
            await model.refreshAll()
        }
    }
}

private extension View {
    /// Presents a `HomeModel.AlertContent` as a single-button alert.
    func alert(item: Binding<HomeModel.AlertContent?>) -> some View {
        alert(
            item.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            presenting: item.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) { item.wrappedValue = nil }
        } message: { content in
            Text(content.message)
        }
    }
}
