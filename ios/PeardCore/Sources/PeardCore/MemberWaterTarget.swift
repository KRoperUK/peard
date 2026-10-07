import Foundation

/// One member's stored daily water target (#335), as the recap route reports it.
///
/// A target belongs to a person in a connection, and everybody in the connection
/// reads everybody's. The server stores whole millilitres and answers zero for
/// "none stored", which is not the same as a target of zero: `isSet` is the
/// question to ask, and a member who has not set one is measured against the
/// built-in amounts by whoever is drawing them.
///
/// Decoding never fails on a missing number — an unset field reads as zero — so
/// a server that grows or loses fields cannot take the recap down with it.
public struct MemberWaterTarget: Codable, Hashable, Sendable, Identifiable {
    public let user: String
    public let minimum: Int
    public let recommended: Int

    public var id: String { user }

    /// Whether this member chose a target. Their goal is what matters: a minimum
    /// with no goal is not a target the app can draw a bar toward.
    public var isSet: Bool { recommended > 0 }

    public init(user: String, minimum: Int = 0, recommended: Int = 0) {
        self.user = user
        self.minimum = max(minimum, 0)
        self.recommended = max(recommended, 0)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try container.decode(String.self, forKey: .user)
        minimum = max(try container.decodeIfPresent(Int.self, forKey: .minimum) ?? 0, 0)
        recommended = max(try container.decodeIfPresent(Int.self, forKey: .recommended) ?? 0, 0)
    }

    private enum CodingKeys: String, CodingKey {
        case user, minimum, recommended
    }
}

extension MomentRecap {
    /// The stored target of one member, or `nil` when they have not set one — or
    /// when the server predates targets, which is the same thing to a screen.
    public func waterTarget(forUser userID: String) -> MemberWaterTarget? {
        waterTargets?.first { $0.user == userID && $0.isSet }
    }

    /// Everybody's stored target except `userID`'s, in the server's order.
    public func otherWaterTargets(excluding userID: String) -> [MemberWaterTarget] {
        (waterTargets ?? []).filter { $0.user != userID && $0.isSet }
    }
}
