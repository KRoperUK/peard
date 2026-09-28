import PeardCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What the share sheet knows: the photo, squared as it will be sent, and the
/// connection, moment and caption it goes with.
///
/// It never uploads. The squared JPEG and the choices go into the App Group's
/// `MomentInbox`, and the app's send queue uploads them the next time it runs
/// — retrying, surviving no signal, exactly as for a photo shared in the app.
/// A share extension is given a small memory budget and is ended the moment the
/// sheet closes, which is no place to start an upload that has to finish.
@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading
        /// No widget token in the App Group: the app has never been signed in.
        case signedOut
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    /// The square exactly as it will be sent.
    private(set) var preview: UIImage?
    private(set) var connections: [WidgetConnection] = []
    /// True when the connection list could not be fetched. The photo can still
    /// be shared: it goes to the connection the app last had open, which is the
    /// same fallback a Control Centre log takes.
    private(set) var isOffline = false
    private(set) var isSending = false

    var selectedID: String? {
        didSet {
            // A connection's own moment means nothing in another one, and the
            // server would refuse it.
            if let moment, !moments.contains(moment) { self.moment = nil }
        }
    }
    /// nil for "just the photo".
    var moment: WidgetFeed.AvailableMoment?
    var caption = ""

    private var jpeg: Data?
    private let store: SharedStore
    private let inbox: MomentInbox

    /// Long enough that the square, which is `PhotoSquare.side` on each edge,
    /// is never drawn from fewer pixels than it has — a 4:3 photo keeps 1620 on
    /// its short side — and small enough to decode well inside the extension's
    /// memory.
    nonisolated static let maxPixelSize = Int(PhotoSquare.side * 2)

    init(store: SharedStore = .shared, inbox: MomentInbox = .appGroup()) {
        self.store = store
        self.inbox = inbox
    }

    var selectedConnection: WidgetConnection? {
        connections.first { $0.id == selectedID }
    }

    /// The chosen connection's catalogue, else the three every connection has.
    var moments: [WidgetFeed.AvailableMoment] {
        let published = selectedConnection?.moments ?? []
        guard published.isEmpty else { return published }
        return MomentCatalogue.builtin.map { .init(kind: $0.kind, emoji: $0.emoji, label: $0.label) }
    }

    var canSend: Bool { phase == .ready && jpeg != nil && !isSending }

    // MARK: Loading

    func load(from attachments: [NSItemProvider]) async {
        guard let token = store.widgetToken, !token.isEmpty, store.apiBaseURL != nil else {
            phase = .signedOut
            return
        }
        async let square = Self.square(from: attachments)
        async let fetched = try? MomentIntentSource.connections(withMoments: true, store: store)

        if let fetched = await fetched {
            connections = fetched
        } else {
            isOffline = true
        }
        // The app's current connection first, as the Messages tray does; the
        // picker is there for when that is not the one.
        selectedID = connections.first { $0.id == store.selectedConnectionID }?.id ?? connections.first?.id

        guard let (image, data) = await square else {
            phase = .failed("Couldn't open that photo.")
            return
        }
        preview = image
        jpeg = data
        phase = connections.isEmpty && !isOffline ? .failed("Pear up with somebody first.") : .ready
    }

    /// The first image among the attachments, squared and encoded the way the
    /// app encodes one — off the main thread, since the render takes a moment.
    private static func square(from attachments: [NSItemProvider]) async -> (UIImage, Data)? {
        guard
            let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }),
            let image = await loadImage(from: provider)
        else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let square = PhotoSquare.render(image, edit: PhotoEdit())
            guard let data = square.jpegData(compressionQuality: PhotoSquare.jpegQuality) else { return nil }
            return (square, data)
        }.value
    }

    /// The photo, decoded no larger than it will be sent.
    ///
    /// As a file where the sharing app offers one, so ImageIO can decode
    /// straight to the smaller size (see `SharedPhoto`). Some apps — the
    /// screenshot editor, for one — only hand over an image object, which is
    /// already decoded and is used as it is.
    private static func loadImage(from provider: NSItemProvider) async -> UIImage? {
        let fromFile: UIImage? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                // The file is only guaranteed to exist until this returns.
                let image = url.flatMap { SharedPhoto.downsampled(at: $0, maxPixelSize: maxPixelSize) }
                continuation.resume(returning: image.map { UIImage(cgImage: $0) })
            }
        }
        if let fromFile { return fromFile }
        guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    // MARK: Sending

    /// Hands the photo to the app. True when it is safely in the inbox.
    func send() -> Bool {
        guard canSend, let jpeg else { return false }
        isSending = true
        defer { isSending = false }
        let entry = InboxedMoment.sharedPhoto(
            // Offline, nil: the app sends it to the connection it has open.
            pairID: isOffline ? nil : selectedID,
            moment: moment,
            caption: caption
        )
        guard inbox.append(entry, photo: jpeg) else {
            phase = .failed("Couldn't save the photo to send.")
            return false
        }
        return true
    }
}
