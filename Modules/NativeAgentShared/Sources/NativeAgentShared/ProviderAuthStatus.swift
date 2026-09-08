import Foundation

public struct ProviderAuthStatus: Codable, Hashable, Sendable {
    public var provider_id: String
    public var state: String           // "ready" | "needs_key" | "needs_oauth" | "error"
    public var detail: String
    /// Free-form metadata projected by the shared compatibility decoder.
    public var user_info: [String: String]?
    public var last_checked_at: String?

    private enum CodingKeys: String, CodingKey {
        case provider_id, state, detail, user_info, last_checked_at
    }

    public init(
        provider_id: String,
        state: String,
        detail: String,
        user_info: [String: String]?,
        last_checked_at: String?
    ) {
        self.provider_id = provider_id
        self.state = state
        self.detail = detail
        self.user_info = user_info
        self.last_checked_at = last_checked_at
    }

    public init(from decoder: Decoder) throws {
        let snapshot = try ProviderAuthStatusWireSnapshot(from: decoder)
        self.provider_id = snapshot.provider_id
        self.state = snapshot.state
        self.detail = snapshot.detail
        self.last_checked_at = snapshot.last_checked_at
        self.user_info = snapshot.user_info
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider_id, forKey: .provider_id)
        try c.encode(state, forKey: .state)
        try c.encode(detail, forKey: .detail)
        try c.encodeIfPresent(last_checked_at, forKey: .last_checked_at)
        try c.encodeIfPresent(user_info, forKey: .user_info)
    }
}
