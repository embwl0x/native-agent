import Foundation
// Blueprint: | `ProviderCatalogFaceValues.swift` | Shared provider catalog display values |

public struct ModelCatalogItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var description: String?
    public var defaultReasoningEffort: String?
    public var supportedReasoningEfforts: [String]?
    public var supportsFast: Bool?
    public var priority: Int?
    public init(
        id: String,
        displayName: String,
        description: String? = nil,
        defaultReasoningEffort: String? = nil,
        supportedReasoningEfforts: [String]? = nil,
        supportsFast: Bool? = nil,
        priority: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportsFast = supportsFast
        self.priority = priority
    }
}

public struct ModelCatalogResponse: Codable, Hashable, Sendable {
    public var status: String
    public var source: String?
    public var models: [ModelCatalogItem]
    public var reasoningEfforts: [ReasoningEffortOption]
    public var updatedAt: String?
    /// Retain whether discovered rows are live, cached, stale or unavailable.
    public var catalogFreshness: String?
    /// Keep failure cause and last-known age; nil means the provider’s current answer.
    public var catalogNote: String? = nil
    public init(
        status: String,
        source: String? = nil,
        models: [ModelCatalogItem],
        reasoningEfforts: [ReasoningEffortOption],
        updatedAt: String? = nil,
        catalogFreshness: String? = nil,
        catalogNote: String? = nil
    ) {
        self.status = status
        self.source = source
        self.models = models
        self.reasoningEfforts = reasoningEfforts
        self.updatedAt = updatedAt
        self.catalogFreshness = catalogFreshness
        self.catalogNote = catalogNote
    }

}
