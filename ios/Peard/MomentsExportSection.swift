import PeardCore
import SwiftUI

/// "Export moments": this connection's timeline as a CSV, handed to the share
/// sheet (issue #164).
///
/// Its own view, with its own state, rather than more of
/// `ConnectionSettingsView`, which is long enough already. The share sheet is
/// `ActivityView` rather than `ShareLink` for the reason that type gives: the
/// file does not exist until every page has been fetched, and `ShareLink` wants
/// its item the moment it is drawn.
struct MomentsExportSection: View {
    let model: HomeModel

    @State private var isExporting = false
    @State private var fileURL: URL?
    @State private var error: String?

    /// Bigger than the timeline's 30: nobody is reading these as they arrive,
    /// so fewer round trips is all that matters, and PocketBase accepts up to
    /// 500.
    private static let pageSize = 200

    var body: some View {
        Section {
            Button {
                Task { await export() }
            } label: {
                HStack {
                    Text("Export moments")
                    if isExporting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .foregroundStyle(PearColor.textPrimary)
            .disabled(isExporting)
        } footer: {
            Text("Every moment in \(model.connectionTitle) as a spreadsheet: when, who, what, and any note.")
        }
        .sheet(isPresented: Binding(get: { fileURL != nil }, set: { if !$0 { fileURL = nil } })) {
            if let fileURL {
                ActivityView(activityItems: [fileURL])
            }
        }
        .alert(
            "Export failed",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }),
            presenting: error
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    private func export() async {
        isExporting = true
        defer { isExporting = false }
        let api = model.apiClient
        let pairID = model.pairID
        do {
            let posts = try await MomentsCSV.collectPosts { page in
                try await api.postsPage(pairID: pairID, page: page, perPage: Self.pageSize)
            }
            let csv = MomentsCSV.make(posts: posts, customKinds: model.customKinds) { author in
                Connection.authorLabel(for: author, in: model.connection, signedInUserID: model.signedInUserID)
            }
            // A directory per export, so the file can carry a readable name
            // without two exports of the same connection colliding.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(MomentsCSV.fileName(connectionTitle: model.connectionTitle))
            try Data(csv.utf8).write(to: url, options: .atomic)
            fileURL = url
        } catch let error as APIError where error.isCancellation {
            // Settings was closed mid-export. Nobody is waiting for an answer.
        } catch {
            self.error = APIError.userMessage(for: error)
        }
    }
}
