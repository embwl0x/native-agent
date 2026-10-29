import AppToolRuntime
import NativeAgentShared
import ProviderRouting
// Blueprint: | `ProviderChoices.swift` | Provider model catalogs, shared first-party descriptor conversion, Codex auth readout and quiet-composer conformances; reasoning values come from NativeAgentShared |

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

    public init(_ model: FirstPartyModelDescriptor, priority: Int) {
        self.init(
            id: model.id,
            displayName: model.name,
            defaultReasoningEffort: model.defaultReasoningEffort,
            supportedReasoningEfforts: model.supportedReasoningEfforts,
            supportsFast: model.supportsFast,
            priority: priority
        )
    }
}

public struct ModelCatalogResponse: Codable, Hashable, Sendable {
    public var status: String
    public var source: String?
    public var models: [ModelCatalogItem]
    public var reasoningEfforts: [ReasoningEffortOption]
    public var updatedAt: String?
    /// Where the discovered rows came from: live, cached, stale or unavailable.
    public var catalogFreshness: String?
    /// Why the provider's list could not be loaded, and how old a
    /// last-known list is — nil when the rows are the provider's current answer.
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

public struct CodexAuthStatus: Codable, Hashable, Sendable {
    public var active: String
    public var appOwnedLoggedIn: Bool
    public var sharedLoggedIn: Bool
    public var codexHome: String
    public var detail: String
    public init(active: String, appOwnedLoggedIn: Bool, sharedLoggedIn: Bool, codexHome: String, detail: String) {
        self.active = active
        self.appOwnedLoggedIn = appOwnedLoggedIn
        self.sharedLoggedIn = sharedLoggedIn
        self.codexHome = codexHome
        self.detail = detail
    }

}

extension ModelCatalogItem: QuietComposerModel {}
extension ReasoningEffortOption: QuietComposerEffort {}
