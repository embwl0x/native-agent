import Foundation

public struct ConnectorRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    // FIX: non-identifying fields defaulted so one omitted key doesn't drop the
    // whole connector record (getConnectors is also lossy now). Only id required.
    public var name: String = ""
    public var kind: String = ""
    public var description: String = ""
    public var enabled: Bool = false
    public var authState: String?
    public var healthStatus: String?
    public var riskClass: String?
    public var permissions: [String]?
    public var actions: [String]?
    public var lastCheckedAt: String?
    public var updatedAt: String?
    /// Socket Mode's separately persisted runtime evidence. This is not the
    /// connector credential state: an unobserved/stale feed must remain visible
    /// without disabling otherwise valid outbound Slack credentials.
    public var runtimeStatus: String?
    public var runtimeDetail: String?
    public var runtimeUpdatedAt: String?

    // FIX-2026-05-28: synthesized Decodable throws keyNotFound on a missing
    // non-optional key even with a Swift default, so the defaults above were
    // dead for decoding. Use decodeIfPresent ?? default; keep id required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.authState = try c.decodeIfPresent(String.self, forKey: .authState)
        self.healthStatus = try c.decodeIfPresent(String.self, forKey: .healthStatus)
        self.riskClass = try c.decodeIfPresent(String.self, forKey: .riskClass)
        self.permissions = try c.decodeIfPresent([String].self, forKey: .permissions)
        self.actions = try c.decodeIfPresent([String].self, forKey: .actions)
        self.lastCheckedAt = try c.decodeIfPresent(String.self, forKey: .lastCheckedAt)
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        self.runtimeStatus = try c.decodeIfPresent(String.self, forKey: .runtimeStatus)
        self.runtimeDetail = try c.decodeIfPresent(String.self, forKey: .runtimeDetail)
        self.runtimeUpdatedAt = try c.decodeIfPresent(String.self, forKey: .runtimeUpdatedAt)
    }
}
