import PeardCore
import SwiftUI

/// Shared timeline, tallies, photo capture and reactions
/// (Requirements 11–15).
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: HomeModel
    @State private var showCamera = false
    @State private var showLeaveConfirmation = false
    @FocusState private var noteFocused: Bool

    init(model: HomeModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Pear'd 🍐")
                    .font(.title2.bold())
                    .foregroundStyle(PearColor.textPrimary)

                latestCard
                tallyButtons

                if model.pendingKind != nil {
                    noteRow.pearTransition()
                }

                tallyRows

                if !model.historyPosts.isEmpty {
                    historyList
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
            .padding(20)
            .padding(.top, 32)
        }
        .background(PearColor.background)
        .refreshable { await model.refreshAll() }
        .task { await model.load() }
        .task(id: app.focusedPostID) { await model.focus(postID: app.focusedPostID) }
        .task { await pollWhileVisible() }
        .onChange(of: scenePhase) { _, phase in
            // Requirement 11.13.
            guard phase == .active else { return }
            Task { await model.refreshAll() }
        }
        .onChange(of: model.pendingKind) { _, kind in
            noteFocused = kind != nil
        }
        .pearAnimation(value: model.toast ?? "")
        .alert(item: $model.alert)
        .confirmationDialog(
            "Un-pear?",
            isPresented: $showLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive) {
                Task { await model.leavePair() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll both lose the shared timeline.")
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

    // MARK: Latest card

    private var latestCard: some View {
        VStack(spacing: 12) {
            if let post = model.displayedPost {
                if post.type == .photo, let path = post.mediaThumbnailPath() {
                    AsyncImage(url: URL(string: model.serverURL.absoluteString + path)) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Text("📷").font(.system(size: 64)).accessibilityHidden(true)
                        default:
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Photo from \(model.authorLabel(for: post))")
                } else {
                    Text(EventKindCatalogue.emoji(for: post.eventKind))
                        .font(.system(size: 72))
                        .padding(.vertical, 24)
                        .accessibilityLabel(EventKindCatalogue.label(for: post.eventKind))
                }

                Text("\(model.authorLabel(for: post)) · \(caption(for: post))")
                    .font(.subheadline)
                    .foregroundStyle(PearColor.textSecondary)

                if let note = post.displayNote {
                    Text(note)
                        .font(.callout.italic())
                        .foregroundStyle(PearColor.textPrimary)
                        .multilineTextAlignment(.center)
                }

                reactionRow
            } else {
                Text("🍐").font(.system(size: 72)).accessibilityHidden(true)
                Text("No moments yet — send a pear!")
                    .font(.subheadline)
                    .foregroundStyle(PearColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func caption(for post: Post) -> String {
        switch post.type {
        case .event:
            return EventKindCatalogue.label(for: post.eventKind)
        case .photo:
            return "shared a moment"
        case .unknown(let value):
            return value
        }
    }

    @ViewBuilder
    private var reactionRow: some View {
        if model.canReactToDisplayedPost || !model.displayedReactionKinds.isEmpty {
            HStack(spacing: 12) {
                if model.canReactToDisplayedPost {
                    ForEach(ReactionKind.allCases, id: \.rawValue) { kind in
                        Button {
                            Task { await model.react(kind: kind) }
                        } label: {
                            Text(kind.emoji)
                                .font(.title3)
                                .padding(8)
                                .background(PearColor.background, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("React with \(kind.accessibilityLabel)")
                    }
                }

                if !model.displayedReactionKinds.isEmpty {
                    Divider().frame(height: 20)
                    HStack(spacing: 4) {
                        ForEach(model.displayedReactionKinds, id: \.rawValue) { kind in
                            Text(kind.emoji)
                                .font(.footnote)
                                .accessibilityLabel("\(kind.accessibilityLabel) recorded")
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Tallies

    private var tallyButtons: some View {
        HStack(spacing: 8) {
            ForEach(EventKindCatalogue.all) { descriptor in
                Button {
                    model.startTally(kind: descriptor.kind)
                } label: {
                    VStack(spacing: 4) {
                        Text(descriptor.emoji).font(.largeTitle)
                        Text(descriptor.label)
                            .font(.caption.bold())
                            .foregroundStyle(PearColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                // Requirement 12.10.
                .disabled(model.isBusy)
                .accessibilityLabel("Log \(descriptor.label)")
            }
        }
        .opacity(model.isBusy ? 0.6 : 1)
    }

    private var noteRow: some View {
        HStack(spacing: 8) {
            TextField("", text: $model.noteText, prompt: Text("Add a note (optional)…"))
                .focused($noteFocused)
                .submitLabel(.send)
                .onSubmit { Task { await model.submitTally() } }
                .padding(12)
                .background(PearColor.surface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Tally note")

            Button("Send") {
                Task { await model.submitTally() }
            }
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(PearColor.accent, in: RoundedRectangle(cornerRadius: 12))
            .buttonStyle(.plain)

            Button {
                model.cancelTally()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(PearColor.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard note")
        }
    }

    private var tallyRows: some View {
        VStack(spacing: 6) {
            tallyRow(label: "You", tallies: model.myTallies)
            tallyRow(label: model.shortPartnerName, tallies: model.partnerTallies)
        }
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
                    Text("\(model.authorLabel(for: post)) · \(EventKindCatalogue.emoji(for: post))")
                    Text(historyDetail(for: post))
                        .lineLimit(1)
                    Spacer(minLength: 4)
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
        switch post.type {
        case .photo: return "photo"
        case .event: return EventKindCatalogue.label(for: post.eventKind)
        case .unknown: return "shared a moment"
        }
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

            Button("Un-pear") {
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
