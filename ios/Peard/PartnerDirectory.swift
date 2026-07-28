import Foundation
import PeardCore

/// Resolves the partner's display label (Requirement 11.7).
///
/// The `users` collection view rule is `id = @request.auth.id`, so a client can
/// only read its own user record and `expand=user` silently omits the partner.
/// The widget feed already returns a server-computed `partner.name` using the
/// same precedence, so that is the primary source; the expand path is kept
/// because it is correct if the rule is ever relaxed.
@MainActor
final class PartnerDirectory {
    private let api: APIClient
    private let store: SharedStore

    init(api: APIClient, store: SharedStore) {
        self.api = api
        self.store = store
    }

    func partnerLabel(pairID: String, signedInUserID: String) async -> String {
        if let expanded = await labelFromExpandedMember(pairID: pairID, signedInUserID: signedInUserID) {
            return expanded
        }
        if let fromFeed = await labelFromWidgetFeed() {
            return fromFeed
        }
        return PartnerLabel.fallback
    }

    private func labelFromExpandedMember(pairID: String, signedInUserID: String) async -> String? {
        do {
            let members = try await api.members(ofPair: pairID)
            guard
                let partner = members.first(where: { $0.user != signedInUserID }),
                let user = partner.expand?.user
            else { return nil }
            let label = PartnerLabel.resolve(user: user)
            return label == PartnerLabel.fallback ? nil : label
        } catch {
            return nil
        }
    }

    private func labelFromWidgetFeed() async -> String? {
        guard let token = store.widgetToken, !token.isEmpty else { return nil }
        do {
            let feed = try await api.widgetFeed(token: token)
            guard let name = feed.partner?.name, !name.isEmpty, name != PartnerLabel.fallback else { return nil }
            return name
        } catch {
            return nil
        }
    }
}
