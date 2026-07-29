import PeardCore
import SwiftUI

/// The full shared timeline, a page at a time.
///
/// The home screen deliberately shows the hero plus three rows, so it stays
/// legible at any text size. That left the shared timeline — the thing the product
/// is actually about — with a ceiling of four moments, ever. This is where the rest
/// of it lives.
///
/// Loading is paged rather than "fetch everything": a connection of twelve people
/// tapping moments accumulates thousands of rows, and none of them need to be in
/// memory to read yesterday.
@MainActor
@Observable
final class HistoryModel {
    /// One day's moments, which is how the timeline reads: people remember "that
    /// Tuesday", not offset 40.
    struct Day: Identifiable {
        let date: Date
        let posts: [Post]
        var id: Date { date }
    }

    private let api: APIClient
    private let pairID: String
    private let signedInUserID: String
    /// Supplies member display names. `GET /api/peard/connections` is the only
    /// place they are available — the `users` view rule stops the client reading
    /// anybody else's record — so the connection is passed in rather than looked up.
    private let connection: Connection?
    private let calendar: Calendar

    private(set) var posts: [Post] = []
    private(set) var customKinds: [MomentKind] = []
    private(set) var isLoadingFirstPage = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var totalItems = 0
    private(set) var error: String?

    private var nextPage = 1

    /// Chosen so the first screenful arrives quickly while a scroll rarely has to
    /// wait: three screens' worth at a typical text size.
    static let pageSize = 30

    init(
        api: APIClient,
        pairID: String,
        signedInUserID: String,
        customKinds: [MomentKind],
        connection: Connection?,
        calendar: Calendar = .peardTally
    ) {
        self.api = api
        self.pairID = pairID
        self.signedInUserID = signedInUserID
        self.customKinds = customKinds
        self.connection = connection
        self.calendar = calendar
    }

    /// Moments grouped by day, newest day first.
    ///
    /// Posts with no timestamp (records predating the server's `created` field)
    /// decode as `distantPast`, which would otherwise open a section captioned with
    /// a date in year 1. They are collected under their own heading instead.
    var days: [Day] {
        var order: [Date] = []
        var grouped: [Date: [Post]] = [:]
        for post in posts {
            let key = post.hasTimestamp ? calendar.startOfDay(for: post.created) : Date.distantPast
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(post)
        }
        return order.map { Day(date: $0, posts: grouped[$0] ?? []) }
    }

    func heading(for day: Day) -> String {
        guard day.date != .distantPast else { return "Undated" }
        if calendar.isDateInToday(day.date) { return "Today" }
        if calendar.isDateInYesterday(day.date) { return "Yesterday" }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        // Drop the year for the current one: "12 March" reads better than
        // "12 March 2026" when there is only one 12 March in view.
        let sameYear = calendar.component(.year, from: day.date) == calendar.component(.year, from: Date())
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEE d MMMM" : "d MMMM yyyy")
        return formatter.string(from: day.date)
    }

    func authorLabel(for post: Post) -> String {
        if post.author == signedInUserID { return "You" }
        if let name = connection?.name(forUser: post.author) {
            return PartnerLabel.short(name)
        }
        // Not a current member: they have left, but their moments stay in the
        // shared timeline. "Partner" would be wrong in a group.
        return PartnerLabel.unknown
    }

    func emoji(for post: Post) -> String {
        MomentCatalogue.emoji(for: post, customKinds: customKinds)
    }

    /// The author's photo, or their initials. A former member is not in the list
    /// any more, so there is nothing to draw but initials — consistent with
    /// `authorLabel` naming them "Someone".
    func avatar(forAuthor userID: String) -> Avatar {
        if let member = connection?.members.first(where: { $0.user == userID }) {
            return member.avatar
        }
        return Avatar(
            owner: .users,
            recordID: userID,
            filename: nil,
            placeholder: .make(name: PartnerLabel.unknown, key: userID)
        )
    }

    func detail(for post: Post) -> String {
        if let note = post.displayNote { return note }
        switch post.type {
        case .photo: return "photo"
        case .event: return MomentCatalogue.label(for: post.eventKind, customKinds: customKinds)
        case .unknown: return "shared a moment"
        }
    }

    func time(for post: Post) -> String {
        guard post.hasTimestamp else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter.string(from: post.created)
    }

    // MARK: Loading

    func loadFirstPage() async {
        guard posts.isEmpty, !isLoadingFirstPage else { return }
        isLoadingFirstPage = true
        defer { isLoadingFirstPage = false }
        nextPage = 1
        posts = []
        await fetchNextPage()
    }

    func reload() async {
        nextPage = 1
        posts = []
        hasMore = false
        await fetchNextPage()
    }

    /// Called as the last row appears. Guarded against re-entry so a fast scroll
    /// cannot fire several requests for the same page.
    func loadMoreIfNeeded() async {
        guard hasMore, !isLoadingMore, !isLoadingFirstPage else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await fetchNextPage()
    }

    private func fetchNextPage() async {
        do {
            let page = try await api.postsPage(pairID: pairID, page: nextPage, perPage: Self.pageSize)
            // Guard against a duplicate arriving from a page boundary shifting
            // under us as new moments land: appending blindly would double a row.
            let known = Set(posts.map(\.id))
            posts.append(contentsOf: page.posts.filter { !known.contains($0.id) })
            totalItems = page.totalItems
            hasMore = page.hasMore
            nextPage = page.nextPage
            error = nil
        } catch {
            self.error = (error as? APIError)?.localizedDescription ?? error.localizedDescription
        }
    }
}

/// The timeline screen. A tab rather than a sheet, so reading back through the
/// shared timeline does not have to be dismissed to log anything.
struct HistoryView: View {
    @State private var model: HistoryModel
    private let serverURL: URL
    private let title: String

    init(model: HistoryModel, serverURL: URL, title: String) {
        _model = State(initialValue: model)
        self.serverURL = serverURL
        self.title = title
    }

    var body: some View {
        NavigationStack {
            content
                .background(PearColor.background)
                .navigationTitle("Timeline")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ConnectionToolbarTitle(title: "Timeline", subtitle: title)
                    }
                }
                .refreshable { await model.reload() }
                .task { await model.loadFirstPage() }
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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("🍐").font(.system(size: 48))
            Text("Nothing here yet")
                .font(.headline)
                .foregroundStyle(PearColor.textPrimary)
            Text("Moments you and everyone else log will build up here.")
                .font(.subheadline)
                .foregroundStyle(PearColor.textSecondary)
                .multilineTextAlignment(.center)
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
                        row(for: post)
                    }
                } header: {
                    Text(model.heading(for: day))
                        .font(.footnote.bold())
                        .foregroundStyle(PearColor.accent)
                }
            }

            if model.hasMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .task { await model.loadMoreIfNeeded() }
            } else if model.totalItems > 0 {
                Text(model.totalItems == 1 ? "1 moment" : "\(model.totalItems) moments")
                    .font(.footnote)
                    .foregroundStyle(PearColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }

            if let error = model.error, !model.posts.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(PearColor.error)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func row(for post: Post) -> some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail(for: post)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    AvatarView(avatar: model.avatar(forAuthor: post.author), serverURL: serverURL, size: 16)
                        .accessibilityHidden(true)
                    Text(model.authorLabel(for: post))
                        .font(.subheadline.bold())
                        .foregroundStyle(PearColor.textPrimary)
                }
                Text(model.detail(for: post))
                    .font(.footnote)
                    .foregroundStyle(PearColor.textSecondary)
            }

            Spacer(minLength: 4)

            Text(model.time(for: post))
                .font(.caption2)
                .foregroundStyle(PearColor.textTertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .listRowBackground(PearColor.background)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func thumbnail(for post: Post) -> some View {
        if post.type == .photo, let path = post.mediaThumbnailPath() {
            AsyncImage(url: URL(string: serverURL.absoluteString + path)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Text("📷").font(.title3)
                default:
                    ProgressView()
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Text(model.emoji(for: post))
                .font(.title3)
                .frame(width: 36, height: 36)
        }
    }
}
