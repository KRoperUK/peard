import AppIntents
import Foundation

/// A connection, as a picker sees it — the widget's configuration sheet and the
/// Shortcuts app both.
///
/// Moved here from the widget extension so there is one of these rather than
/// two. The type name is unchanged on purpose: App Intents identifies a stored
/// entity by its type, and a widget somebody has already pinned to a connection
/// resolves through that name. PeardCore is linked into both targets, so the
/// name a configuration was written with is the name it is read back with.
public struct ConnectionEntity: AppEntity, Identifiable, Hashable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Connection"
    public static var defaultQuery = ConnectionQuery()

    public let id: String
    public let title: String
    public let subtitle: String

    public init(id: String, title: String, subtitle: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }

    public init(_ connection: WidgetConnection) {
        self.init(id: connection.id, title: connection.title, subtitle: connection.subtitle)
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
}

/// Supplies the picker's connections from the server, using the widget token.
///
/// The token rather than the signed-in session because this runs in the widget
/// extension as well as the app, and the extension has no PocketBase session —
/// one code path for both beats two that can disagree.
public struct ConnectionQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [ConnectionEntity] {
        let all = try await suggestedEntities()
        // Preserve the order the caller asked in, and silently drop a connection
        // that has gone — a widget configured for a group the user has left must
        // fall back to Automatic rather than fail to render.
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    public func suggestedEntities() async throws -> [ConnectionEntity] {
        try await MomentIntentSource.connections().map(ConnectionEntity.init)
    }
}

/// Where the pickers get their data.
///
/// Separated from the queries so the shapes they produce can be tested without a
/// network: an `EntityQuery` is awkward to exercise directly, and the part worth
/// covering is which options are offered, not how they are fetched.
///
/// Public because the Shortcuts moment picker lives in the app target rather
/// than here — see `MomentShortcuts.swift`, and the reason it had to move.
public enum MomentIntentSource {
    public static func connections(
        withMoments: Bool = false,
        store: SharedStore = .shared
    ) async throws -> [WidgetConnection] {
        guard
            let token = store.widgetToken, !token.isEmpty,
            let baseURL = store.apiBaseURL
        else { return [] }
        return try await APIClient(baseURL: baseURL).widgetConnections(token: token, withMoments: withMoments)
    }
}
