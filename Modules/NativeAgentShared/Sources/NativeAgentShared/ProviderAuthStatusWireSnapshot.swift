import Foundation

/// Provider-auth snapshot compatibility; providers retain credentials, refresh and routing authority.
/// Platform models retain construction and encoding. Metadata projection is intentionally lossy.
public struct ProviderAuthStatusWireSnapshot: Decodable, Sendable {
    public let provider_id: String
    public let state: String
    public let detail: String
    public let user_info: [String: String]?
    public let last_checked_at: String?

    private enum CodingKeys: String, CodingKey {
        case provider_id, state, detail, user_info, last_checked_at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.provider_id = try c.decode(String.self, forKey: .provider_id)
        self.state       = try c.decode(String.self, forKey: .state)
        self.detail      = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        self.last_checked_at = try c.decodeIfPresent(String.self, forKey: .last_checked_at)
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
