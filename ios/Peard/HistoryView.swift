import PeardCore
import SwiftUI

/// The timeline screen. A tab rather than a sheet, so reading back through the
/// shared timeline does not have to be dismissed to log anything.
struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @State private var model: HistoryModel
    @State private var editing: Post?
    @State private var deleting: Post?
    @State private var viewing: Post?
    /// A moment still waiting to send that is being edited or deleted. Kept apart
    /// from `editing` and `deleting`: those act on a server record through the
    /// API, and a queued send has none (#313).
    @State private var editingQueued: PendingSend?
    @State private var deletingQueued: PendingSend?
    /// What is typed in the search field; applied to the filter after a pause
    /// in typing rather than on every keystroke (issue #9).
    @State private var searchText = ""
    private let serverURL: URL
    private let title: String
    /// Changes whenever the timeline may be out of date; see `refreshNewest`.
    private let refreshKey: String

    init(model: HistoryModel, serverURL: URL, title: String, refreshKey: String = "") {
        _model = State(initialValue: model)
        self.serverURL = serverURL
        self.title = title
        self.refreshKey = refreshKey
    }

    var body: some View {
        NavigationStack {
            content
                .background(PearColor.background)
                .navigationTitle("Timeline")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ConnectionToolbarTitle(
                            title: "Timeline",
                            subtitle: model.filterSummary ?? title
                        )
                    }
                    ToolbarItem(placement: .primaryAction) {
                        filterMenu
                    }
                }
                .refreshable { await model.reload() }
                // Runs on first appearance, on a return to the tab that has
                // been away a while, and whenever Home's newest moments change,
                // which is how a moment logged on Home, by a widget or Siri, or
                // by somebody else gets here without a pull to refresh
                // (issue #113).
                .task(id: refreshKey) { await model.refreshNewestIfDue(key: refreshKey) }
                // Searched on the server, so it finds a note from last spring,
                // not only what has been scrolled into memory.
                .searchable(text: $searchText, prompt: "Notes, captions, moments")
                .task(id: searchText) {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await model.apply(model.filter.searching(searchText, catalogue: model.moments))
                }
        }
        .sheet(item: $editing) { post in
            MomentEditSheet(post: post, moments: model.moments, model: model)
        }
        .sheet(item: $editingQueued) { send in
            QueuedSendEditSheet(send: send, moments: model.moments)
        }
        // Full screen rather than a sheet: a sheet leaves the timeline showing
        // above it, and the whole point is the photo.
        .fullScreenCover(item: $viewing) { post in
            PhotoViewer(
                post: post,
                serverURL: serverURL,
                authorLabel: model.authorLabel(for: post),
                timestamp: model.time(for: post)
            )
        }
        // A swipe is easy to do by accident on a list you are scrolling, and this
        // one cannot be undone, so it asks. The sheet has its own confirmation
        // for the same reason.
        //
        // An alert, centred, rather than a confirmation dialog, which an iPhone
        // shows as a sheet along the bottom of the screen — far from the row
        // being deleted, and easy to read as belonging to the whole timeline
        // (issue #296).
        .alert(
            "Delete this moment?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let post = deleting {
                    deleting = nil
                    Task { await model.delete(post) }
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("It goes from the shared timeline and stops counting towards the tallies.")
        }
        // The same alert for a moment that has not been sent: centred, and
        // worded for what is true of it — nobody else has seen it, so nothing
        // leaves a shared timeline or a tally.
        .alert(
            "Delete this moment?",
            isPresented: Binding(get: { deletingQueued != nil }, set: { if !$0 { deletingQueued = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let send = deletingQueued {
                    deletingQueued = nil
                    Task { await app.deletePendingSend(id: send.id) }
                }
            }
            Button("Cancel", role: .cancel) { deletingQueued = nil }
        } message: {
            Text("It hasn't been sent yet, so it is removed from this phone and will not be sent. This cannot be undone.")
        }
    }

    /// Who and what, in one control.
    ///
    /// A menu rather than a row of chips: the timeline is already dense, the
    /// filter is off almost all the time, and a connection of twelve people
    /// with a dozen moments would need a scrolling bar of its own. The active
    /// filter shows in the subtitle instead, where the connection name usually
    /// is — so the screen always says what it is showing.
    private var filterMenu: some View {
        Menu {
            if model.filter.isActive {
                Button {
                    searchText = ""
                    Task { await model.apply(.none) }
                } label: {
                    Label("Show everything", systemImage: "xmark.circle")
                }
            }

            Section("Who") {
                pick("Everyone", isOn: model.filter.author == nil) {
                    model.filter.choosing(author: nil)
                }
                ForEach(model.filterableMembers) { member in
                    pick(model.memberLabel(member), isOn: model.filter.author == member.user) {
                        model.filter.choosing(author: member.user)
                    }
                }
            }

            Section("What") {
                pick("Anything", isOn: model.filter.kind == nil && !model.filter.photosOnly) {
                    // Clears both, which is what "anything" has to mean now
                    // that they are two dimensions rather than one choice.
                    model.filter.choosing(kind: nil).choosingPhotos(false)
                }
                // A toggle, not a choice: a moment can carry a photo, so
                // "photos" narrows whatever else is selected rather than
                // replacing it. "Coffee · Photos" is a real question.
                pick("📷 Has a photo", isOn: model.filter.photosOnly) {
                    model.filter.choosingPhotos(!model.filter.photosOnly)
                }
                ForEach(model.moments) { moment in
                    pick("\(moment.emoji) \(moment.label)", isOn: model.filter.kind == moment.kind) {
                        // Tapping the selected moment clears it, so the only way
                        // back is not always through "Anything" — which would
                        // also throw away the photo filter.
                        model.filter.choosing(kind: model.filter.kind == moment.kind ? nil : moment.kind)
                    }
                }
            }
        } label: {
            Image(systemName: model.filter.isActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .foregroundStyle(PearColor.accent)
        }
        .accessibilityLabel(model.filter.isActive ? "Filtering by \(model.filterSummary ?? "")" : "Filter")
    }

    private func pick(_ label: String, isOn: Bool, to next: @escaping () -> TimelineFilter) -> some View {
        Button {
            Task { await model.apply(next()) }
        } label: {
            if isOn {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoadingFirstPage && model.posts.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.posts.isEmpty {
            emptyState
        } else {
            timeline
        }
    }

    /// Empty because nothing has happened, or empty because of the filter —
    /// two different facts, and the second one has something you can do about
    /// it. Telling somebody "nothing here yet" when they have just narrowed to
    /// one person's photos would be plainly untrue.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("🍐").font(.system(size: 48)).accessibilityHidden(true)
            Text(model.filter.isActive ? "Nothing matches that" : "Nothing here yet")
                .font(.headline)
                .foregroundStyle(PearColor.textPrimary)
            Text(model.filter.isActive
                ? "No moments for \(model.filterSummary ?? "that filter") in this connection."
                : "Moments you and everyone else log will build up here.")
                .font(.subheadline)
                .foregroundStyle(PearColor.textSecondary)
                .multilineTextAlignment(.center)
            if model.filter.isActive {
                Button("Show everything") {
                    searchText = ""
                    Task { await model.apply(.none) }
                }
                .font(.footnote.bold())
                .foregroundStyle(PearColor.accent)
            }
            if let error = model.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(PearColor.error)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timeline: some View {
        List {
            ForEach(model.days) { day in
                Section {
                    ForEach(day.posts) { post in
                        // Above the oldest new moment, so the line separates
                        // "seen" from "new" the way it reads on screen: the
                        // timeline is newest-first, so everything above it is
                        // what arrived while you were away.
                        if post.id == model.firstNewPostID {
                            newMomentsDivider
                        }
                        row(for: post)
                    }
                } header: {
                    Text(model.heading(for: day))
                        .font(.footnote.bold())
                        .foregroundStyle(PearColor.accent)
                }
            }

            // The footer rows are not moments, so they draw no separators of
            // their own, like the "New" divider. Left on, the list aligned each
            // one to the row's text, which put a half-width line under the
            // centred count.
            if model.hasMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .task { await model.loadMoreIfNeeded() }
            } else if model.totalItems > 0 {
                Text(model.totalItems == 1 ? "1 moment" : "\(model.totalItems) moments")
                    .font(.footnote)
                    .foregroundStyle(PearColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let error = model.error, !model.posts.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(PearColor.error)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// A labelled rule rather than a coloured dot per row: the useful thing is
    /// one boundary you can scroll to, not a repeated badge that leaves you
    /// counting.
    private var newMomentsDivider: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(PearColor.accent)
                .frame(height: 1)
            Text("New")
                .font(.caption2.bold())
                .foregroundStyle(PearColor.accent)
                .textCase(.uppercase)
            Rectangle()
                .fill(PearColor.accent)
                .frame(height: 1)
        }
        .padding(.vertical, 2)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement()
        .accessibilityLabel("New since you last looked")
    }

    private func row(for post: Post) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Only the thumbnail opens the photo, not the whole row: the row is
            // also the swipe and long-press target, and a tap that opened a
            // full-screen view from anywhere on it would fire every time
            // somebody meant to start a swipe.
            thumbnail(for: post)
                .onTapGesture {
                    if post.hasMedia { viewing = post }
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    AvatarView(avatar: model.avatar(forAuthor: post.author), serverURL: serverURL, size: 16)
                        .accessibilityHidden(true)
                    Text(model.authorLabel(for: post))
                        .font(.subheadline.bold())
                        .foregroundStyle(PearColor.textPrimary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(model.detail(for: post))
                        .font(.footnote)
                        .foregroundStyle(PearColor.textSecondary)
                    // Marked rather than hidden: a shared timeline is a record
                    // several people rely on, and a line that quietly changed
                    // under them is worse than one that says it changed.
                    if post.isEdited {
                        EditedChip()
                    }
                    if post.rewound {
                        RewoundChip(loggedAt: post.created)
                    }
                    // A moment queued on this device that the server has not
                    // accepted yet says so, rather than looking identical to one
                    // that has — the same marker the home screen's hero uses.
                    if model.isPending(post) {
                        QueuedChip(offline: model.pendingIndicatorIsOffline)
                    }
                }

                if post.replyTo != nil {
                    ReplyChip(
                        original: model.original(for: post),
                        title: model.replyTitle(for: post),
                        serverURL: serverURL
                    ) { viewing = $0 }
                    .padding(.top, 1)
                }

                let kinds = model.reactionKinds(for: post)
                if !kinds.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(kinds, id: \.rawValue) { kind in
                            Text(kind.emoji).font(.caption2)
                        }
                    }
                    .padding(.top, 1)
                }
            }

            Spacer(minLength: 4)

            timeLabel(for: post)
        }
        .padding(.vertical, 4)
        .listRowBackground(PearColor.background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: post))
        // The combined element swallows the thumbnail's own tap target, so
        // VoiceOver gets the photo as a named action instead of losing it.
        .accessibilityActions {
            if post.hasMedia {
                Button("Open photo") { viewing = post }
            }
            if let original = model.original(for: post), original.hasMedia {
                Button("Open the photo it replies to") { viewing = original }
            }
        }
        .modifier(MomentActions(
            post: post,
            canEdit: model.canEdit(post),
            canReact: model.canReact(to: post),
            mine: Set(ReactionKind.allCases.filter { model.hasReacted(to: post, kind: $0) }.map(\.rawValue)),
            onEdit: { editing = post },
            onDelete: { deleting = post },
            onReact: { kind in Task { await model.toggleReaction(to: post, kind: kind) } }
        ))
        .modifier(QueuedSendActions(
            send: model.pendingSend(for: post),
            onEdit: { editingQueued = $0 },
            onDelete: { deletingQueued = $0 }
        ))
    }

    private func timeLabel(for post: Post) -> some View {
        HStack(spacing: 4) {
            if model.strayNewPostIDs.contains(post.id) {
                Circle()
                    .fill(PearColor.accent)
                    .frame(width: 6, height: 6)
            }
            Text(model.time(for: post))
                .font(.caption2)
                .foregroundStyle(PearColor.textTertiary)
                .monospacedDigit()
        }
    }

    private func accessibilityLabel(for post: Post) -> String {
        var parts = [model.authorLabel(for: post), model.detail(for: post)]
        if post.hasMedia { parts.append("photo") }
        if post.replyTo != nil { parts.append(model.replyTitle(for: post)) }
        if post.isEdited { parts.append("edited") }
        if model.isPending(post) {
            parts.append(model.pendingIndicatorIsOffline ? "waiting to send" : "sending")
        }
        if model.strayNewPostIDs.contains(post.id) { parts.append("new") }
        if post.rewound { parts.append(RewoundChip.accessibilityLabel(loggedAt: post.created)) }
        let time = model.time(for: post)
        if !time.isEmpty { parts.append(time) }
        if let reactions = model.spokenReactions(for: post) { parts.append(reactions) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func thumbnail(for post: Post) -> some View {
        // `hasMedia` rather than `type == .photo`: a moment can carry a photo
        // now, and keying on the type would draw its emoji and hide the picture.
        if post.hasMedia, let path = post.mediaThumbnailPath(app.listPhotoThumb) {
            ProtectedImage(serverURL: serverURL, path: path) {
                ProgressView()
            } failure: {
                Text("📷").font(.title3)
            }
            .scaledToFill()
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Text(model.emoji(for: post))
                .font(.title3)
                .frame(width: 36, height: 36)
        }
    }
}

/// What you can do with a moment, which depends on whose it is.
///
/// Yours: edit or delete, by swipe *and* by long press. Both, because neither
/// alone is discoverable — a swipe is the iOS convention for a list row and is
/// what a practised thumb reaches for, and a context menu is what somebody
/// finds when they press the thing they want to change and wait.
///
/// Somebody else's: react to it. That used to be possible only on the home
/// screen's hero, so only ever to the single most recent moment — come back
/// after a day away and the things that happened while you were gone could be
/// read and not answered.
private struct MomentActions: ViewModifier {
    let post: Post
    let canEdit: Bool
    let canReact: Bool
    /// Raw values of the kinds the signed-in user has already used here, so the
    /// same control can offer to take one back. Raw values rather than the enum
    /// because `ReactionKind` carries an associated value and is not Hashable
    /// into a Set as cheaply.
    let mine: Set<String>
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onReact: (ReactionKind) -> Void

    func body(content: Content) -> some View {
        if canEdit {
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(PearColor.accent)
                }
                .contextMenu {
                    Button(action: onEdit) {
                        Label("Edit moment", systemImage: "pencil")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete moment", systemImage: "trash")
                    }
                }
        } else if canReact {
            content
                // Leading edge, so reacting and deleting are never the same
                // flick in the same direction on adjacent rows.
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    ForEach(ReactionKind.allCases, id: \.rawValue) { kind in
                        Button { onReact(kind) } label: {
                            Text(kind.emoji)
                        }
                        // The ones already used are filled in, so a swipe shows
                        // at a glance which of the three would be taken back.
                        .tint(mine.contains(kind.rawValue)
                            ? PearColor.accent.opacity(0.6)
                            : PearColor.accent.opacity(0.2))
                    }
                }
                .contextMenu {
                    ForEach(ReactionKind.allCases, id: \.rawValue) { kind in
                        Button { onReact(kind) } label: {
                            if mine.contains(kind.rawValue) {
                                Label("\(kind.emoji)  \(kind.accessibilityLabel)", systemImage: "checkmark")
                            } else {
                                Text("\(kind.emoji)  \(kind.accessibilityLabel)")
                            }
                        }
                    }
                }
        } else {
            content
        }
    }
}

/// What you can do with a moment still waiting to send: edit or delete it, by
/// swipe and by long press, as for a sent one — but against the queue, not the
/// server (#313). Separate from `MomentActions`, which is for server records and
/// offers nothing for a pending row (`HistoryModel.canEdit` is false for it).
private struct QueuedSendActions: ViewModifier {
    let send: PendingSend?
    let onEdit: (PendingSend) -> Void
    let onDelete: (PendingSend) -> Void

    func body(content: Content) -> some View {
        if let send {
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { onDelete(send) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button { onEdit(send) } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(PearColor.accent)
                }
                .contextMenu {
                    Button { onEdit(send) } label: {
                        Label("Edit moment", systemImage: "pencil")
                    }
                    Button(role: .destructive) { onDelete(send) } label: {
                        Label("Delete moment", systemImage: "trash")
                    }
                }
        } else {
            content
        }
    }
}

/// Marks a moment queued on this device that the server has not accepted yet —
/// "waiting" with no signal, "sending" once it is on its way. The same marker
/// the home screen's hero uses, so a queued moment reads the same wherever it
/// is seen (#313).
private struct QueuedChip: View {
    let offline: Bool

    var body: some View {
        Label(
            offline ? "waiting" : "sending",
            systemImage: offline ? "wifi.slash" : "arrow.up.circle"
        )
        .font(.caption2)
        .foregroundStyle(PearColor.textTertiary)
    }
}
