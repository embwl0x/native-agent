import Foundation

// Blueprint: | `ProviderAuthStatus.swift` | `ProviderAuthStatus`: credential-proof presentation, compatibility decoder and bounded metadata projection; providers retain dispatch eligibility authority |

public struct ProviderAuthStatus: Codable, Hashable, Sendable {
    public var provider_id: String
    /// How far the credential is proven: ready, saved, failed, rejected or a
    /// needs_* state. Never read for eligibility; `eligible` is that answer.
    public var state: String
    public var detail: String
    /// Free-form metadata projected by the shared compatibility decoder.
    public var user_info: [String: String]?
    public var last_checked_at: String?

    /// May dispatch, as ProviderRouting publishes it (the provider's
    /// `configured`). An older Mac's wire has none; there "ready" meant it.
    public var eligible: Bool

    private enum CodingKeys: String, CodingKey {
        case provider_id, state, detail, user_info, last_checked_at, eligible
    }

    public init(
        provider_id: String,
        state: String,
        detail: String,
        user_info: [String: String]?,
        last_checked_at: String?,
        eligible: Bool
    ) {
        self.provider_id = provider_id
        self.state = state
        self.detail = detail
        self.user_info = user_info
        self.last_checked_at = last_checked_at
        self.eligible = eligible
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.provider_id = try c.decode(String.self, forKey: .provider_id)
        self.state       = try c.decode(String.self, forKey: .state)
        self.detail      = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        self.last_checked_at = try c.decodeIfPresent(String.self, forKey: .last_checked_at)
        // A Mac from before `eligible` was published meant exactly "ready" by eligible.
        self.eligible = try c.decodeIfPresent(Bool.self, forKey: .eligible) ?? (self.state == "ready")
        // Coerce any nested JSON value into a string. Drop nulls.
        if c.contains(.user_info), try !c.decodeNil(forKey: .user_info) {
            let nested = try? c.decode([String: AnyJSONValue].self, forKey: .user_info)
            self.user_info = nested?.compactMapValues { $0.asString }
        } else {
            self.user_info = nil
        }
    }
}

/// Arrays join projected values; objects expose sorted keys, never serialized JSON.
private struct AnyJSONValue: Decodable {
    let asString: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                                  { self.asString = nil }
        else if let s = try? c.decode(String.self)        { self.asString = s }
        else if let b = try? c.decode(Bool.self)          { self.asString = String(b) }
        else if let i = try? c.decode(Int.self)           { self.asString = String(i) }
        else if let d = try? c.decode(Double.self)        { self.asString = String(d) }
        else if let arr = try? c.decode([AnyJSONValue].self) {
            self.asString = arr.compactMap { $0.asString }.joined(separator: ",")
        }
        else if let dict = try? c.decode([String: AnyJSONValue].self) {
            self.asString = dict.keys.sorted().joined(separator: ",")
        }
        else { self.asString = nil }
    }
}
