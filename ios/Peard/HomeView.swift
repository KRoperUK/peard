import OSLog
import PeardCore
import SwiftUI

/// Logging a moment, and what landed last.
///
/// Narrower than it was: the tally rows, the whole timeline and every connection
/// setting are now their own tabs. What is left is the question Home is for —
/// "what's happening with us, and what do I want to say" — which is the connection
/// rail, the latest moment, and the moments themselves.
///
/// The title and the rail are pinned at the top, the camera is pinned at the
/// bottom. Both are held outside the scrolling content rather than inside it: as
/// pinned section headers they stopped at the safe-area inset, which left the
/// status-bar band part of the scrolling viewport and let content slide up behind
/// the clock.
struct HomeView: View {
    static let diagnostic = Logger(subsystem: "com.peard.app", category: "home-render")

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: HomeModel
    @State private var showCamera = false
    /// The picture just taken, held while its moment is chosen.
    @State private var capturedPhoto: CapturedPhoto?
    @State private var showMomentSheet = false
    @State private var viewingPhoto: Post?
    @FocusState private var noteFocused: Bool

    /// Switches to the tallies tab. The breakdown strip is a summary, and its whole
    /// job is to lead somewhere fuller.
    private let onShowTallies: () -> Void

    init(model: HomeModel, onShowTallies: @escaping () -> Void = {}) {
        _model = State(initialValue: model)
        self.onShowTallies = onShowTallies
    }

    var body: some View {
        // Read here, in `body` itself, rather than inside the `safeAreaInset`
        // closure below. That closure is evaluated outside the observation scope of
        // this body, so anything it reads is not registered as a dependency: the
        // connection rail kept drawing a replaced group photo, and the muted bell
        // kept not appearing, until something *else* happened to invalidate the
        // body — in practice the 30-second poll. Verified against the server's
        // request log, which recorded no fetch of the new file until then.
        let connections = app.connections
        let isMuted = model.isMuted

        HomeView.diagnostic.notice(
            "body: connections=\(connections.count, privacy: .public) selected=\(connections.first { $0.id == model.pairID }?.avatarFilename ?? "nil", privacy: .public)"
        )

        return ScrollView {
            scrollingContent
        }
        .background(PearColor.background)
        .safeAreaInset(edge: .top, spacing: 16) {
            pinnedHeader(connections: connections, isMuted: isMuted)
        }
        // Pinned so the heaviest action is always one tap away, however long the
        // moment grid grows.
        .safeAreaInset(edge: .bottom) {
            cameraBar
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
        .fullScreenCover(item: $viewingPhoto) { post in
            PhotoViewer(
                post: post,
                serverURL: model.serverURL,
                authorLabel: model.authorLabel(for: post),
                timestamp: ElapsedTime.label(for: post.created)
            )
        }
        .pearAnimation(value: model.toast ?? "")
        .alert(item: $model.alert)
        .sheet(isPresented: $showMomentSheet) {
            MomentSheet(model: model)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                guard let image else { return }
                // Asked rather than assumed: most photos are of nothing
                // countable, and the sheet's Skip is one tap away.
                capturedPhoto = CapturedPhoto(image: image)
            }
            .ignoresSafeArea()
        }
        .sheet(item: $capturedPhoto) { photo in
            PhotoMomentSheet(image: photo.image, moments: model.moments) { moment in
                Task { await model.upload(image: photo.image, moment: moment) }
            }
        }
    }

    // MARK: Pinned header

    private func pinnedHeader(connections: [Connection], isMuted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pear'd 🍐")
                    .font(.title2.bold())
                    .foregroundStyle(PearColor.textPrimary)
                Spacer(minLength: 8)
                if isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.footnote)
                        .foregroundStyle(PearColor.textTertiary)
                        .accessibilityLabel("\(model.connectionTitle) is muted")
                }
            }

            ConnectionRail(
                connections: connections,
                selectedID: model.pairID,
                serverURL: model.serverURL,
                onSelect: { app.select(connectionID: $0) },
                onAdd: { app.startAddingConnection() }
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 10)
        // Held above the scrolling content, so it must be opaque — and the fill
        // has to reach through the top safe area, or the status-bar band shows
        // whatever is scrolling underneath.
        .background(PearColor.background.ignoresSafeArea(edges: .top))
    }

    // MARK: Scrolling content

    private var scrollingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroCard

            if model.quickSend != nil {
                quickSendRow.pearTransition()
            }

            if let summary = model.pendingSummary {
                pendingBanner(summary)
            }

            MomentGrid(
                moments: model.moments,
                pendingKind: model.quickSend?.moment.kind,
                isBusy: model.isBusy,
                onTap: { model.tap(moment: $0) },
                onMore: { showMomentSheet = true }
            )

            if model.hasMomentBreakdown {
                breakdownStrip
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
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    /// The hero: whatever landed most recently.
    private var heroCard: some View {
        HStack(spacing: 14) {
            if let post = model.displayedPost {
                heroThumbnail(for: post)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        AvatarView(
                            avatar: model.avatar(forAuthor: post.author),
                            serverURL: model.serverURL,
                            size: 18
                        )
                        .accessibilityHidden(true)
                        Text("\(model.authorLabel(for: post)) · \(model.caption(for: post))")
                            .font(.subheadline.bold())
                            .foregroundStyle(PearColor.textPrimary)
                            .lineLimit(1)
                    }

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
        // `hasMedia` rather than `type == .photo`: a moment can carry a photo
        // now, and keying on the type would draw its emoji and hide the picture.
        if post.hasMedia, let path = post.mediaThumbnailPath() {
            ProtectedImage(serverURL: model.serverURL, path: path) {
                ProgressView()
            } failure: {
                Text("📷").font(.system(size: 32)).accessibilityHidden(true)
            }
            .scaledToFill()
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            // The hero is the most recent thing that landed, and if it is a
            // photo, the thumbnail is the smallest part of the screen and the
            // one people actually want to see.
            .onTapGesture { viewingPhoto = post }
            .accessibilityLabel("Photo from \(model.authorLabel(for: post))")
            .accessibilityHint("Opens the photo full screen")
            .accessibilityAddTraits(.isButton)
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
                        let isMine = model.hasReacted(kind: kind)
                        Button {
                            Task { await model.toggleReaction(kind: kind) }
                        } label: {
                            Text(kind.emoji)
                                .font(.footnote)
                                .padding(6)
                                // Ringed rather than recoloured: the emoji is
                                // the content, and tinting it would change what
                                // the reaction looks like as well as saying it
                                // is yours.
                                .background(PearColor.background, in: Circle())
                                .overlay(
                                    Circle().strokeBorder(isMine ? PearColor.accent : .clear, lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            isMine
                                ? "Take back your \(kind.accessibilityLabel)"
                                : "React with \(kind.accessibilityLabel)"
                        )
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

    /// What this connection logs most, in one line, leading to the tallies tab.
    private var breakdownStrip: some View {
        Button(action: onShowTallies) {
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
                // Beside the counts rather than on its own row: the strip is
                // already the "how are we doing" line, and a streak is the same
                // question answered in days instead of moments.
                if let streak = model.recap?.streak {
                    StreakBadge(streak: streak)
                }
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
        .accessibilityHint("Opens the tallies")
    }

    private var breakdownAccessibilityLabel: String {
        let parts = model.topMoments.map { "\($0.label) \($0.total)" }
        return parts.isEmpty ? "Moment breakdown" : "Most logged: " + parts.joined(separator: ", ")
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
                .foregroundStyle(PearColor.onAccent)
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

    // MARK: Camera

    private var cameraBar: some View {
        Button {
            Task { await requestCamera() }
        } label: {
            ZStack {
                if model.busy == .photo {
                    ProgressView().tint(.white)
                } else {
                    Label("Share a photo", systemImage: "camera.fill")
                        .font(.body.bold())
                        .foregroundStyle(PearColor.onAccent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.vertical, 14)
            .background(PearColor.accent, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .accessibilityLabel("Share a photo moment")
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
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

extension View {
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
