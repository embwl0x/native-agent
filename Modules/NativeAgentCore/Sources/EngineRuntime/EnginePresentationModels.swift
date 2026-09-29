import DoctorChecks
import AppToolRuntime
import TrustCenter
import Foundation
import NativeAgentShared
import TelegramBot
import PersistenceCore
/// UI diagnostics around the canonical transport/configuration values.
public struct TelegramPresentationSnapshot: Equatable, Sendable {
    public var transport: TelegramBot.TelegramStatus
    public let configuration: TelegramConfigurationSummary
    public var enabled: Bool { transport.enabled ?? false }
    public var tokenConfigured: Bool { transport.tokenConfigured ?? false }
    public var pollerEnabled: Bool { transport.pollerEnabled ?? false }
    public var lastSeenUpdateId: Int? { transport.lastSeenUpdateId }
    public var lastSeenAt: String? { transport.lastSeenAt }
    public var lastReplyAt: String? { transport.lastReplyAt }
    public var lastError: String? { transport.lastError }
    public var allowedChatIds: [String] { configuration.allowedChatIds }
    public var allowedUserIds: [String] { configuration.allowedUserIds }
    public var requireMention: Bool { configuration.requireMention }
    public var model: String? { configuration.model }
    public var reasoningEffort: String? { configuration.reasoningEffort }
    public var pollBackoffFailures: Int?
    public var lastPollAt: String?
    public var lastDiagnosticsClearedAt: String?
    public var voiceTranscription: TelegramVoiceTranscriptionStatus?
    public var receipts: [TelegramReceipt]
    public var blocked: [TelegramBlockedEvent]
    public var errors: [TelegramErrorEvent]
    /// Existing diagnostic bytes that cannot be decoded are unavailable, not an
    /// empty feed. The settings page renders these separately from empty state.
    public var receiptsIssue: String? = nil
    public var blockedIssue: String? = nil
    public var errorsIssue: String? = nil
    public init(
        transport: TelegramBot.TelegramStatus,
        configuration: TelegramConfigurationSummary,
        pollBackoffFailures: Int? = nil,
        lastPollAt: String? = nil,
        lastDiagnosticsClearedAt: String? = nil,
        voiceTranscription: TelegramVoiceTranscriptionStatus? = nil,
        receipts: [TelegramReceipt],
        blocked: [TelegramBlockedEvent],
        errors: [TelegramErrorEvent],
        receiptsIssue: String? = nil,
        blockedIssue: String? = nil,
        errorsIssue: String? = nil
    ) {
        self.transport = transport
        self.configuration = configuration
        self.pollBackoffFailures = pollBackoffFailures
        self.lastPollAt = lastPollAt
        self.lastDiagnosticsClearedAt = lastDiagnosticsClearedAt
        self.voiceTranscription = voiceTranscription
        self.receipts = receipts
        self.blocked = blocked
        self.errors = errors
        self.receiptsIssue = receiptsIssue
        self.blockedIssue = blockedIssue
        self.errorsIssue = errorsIssue
    }

}

extension TelegramPresentationSnapshot {
    public var normalizedLastError: String? {
        guard let value = lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// Telegram long polling is a retrying transport. One or two consecutive
    /// interruptions while the canonical poller is still running are
    /// observations, not an outage. The third consecutive failure becomes
    /// actionable so a genuinely unreachable bot still surfaces promptly.
    public var isTransientPollInterruption: Bool {
        guard pollerEnabled,
              let error = normalizedLastError,
              error.lowercased().hasPrefix("poll:") else { return false }
        return (pollBackoffFailures ?? 0) < 3
    }

    public var actionableError: String? {
        isTransientPollInterruption ? nil : normalizedLastError
    }

    public var isOperational: Bool {
        enabled && tokenConfigured && pollerEnabled && actionableError == nil
    }
}

public struct TelegramVoiceTranscriptionStatus: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var backend: String
    public var model: String
    public var maxBytes: Int
    public init(enabled: Bool, backend: String, model: String, maxBytes: Int) {
        self.enabled = enabled
        self.backend = backend
        self.model = model
        self.maxBytes = maxBytes
    }

}

public struct TelegramReceipt: Identifiable, Codable, Hashable, Sendable {
    public var eventId: String?
    public var at: String
    public var kind: String?
    public var chatId: String?
    public var userId: String?
    public var updateId: Int?
    public var messageId: Int?
    public var textPreview: String?
    public var replyPreview: String?
    public var model: String?
    public var reasoningEffort: String?

    public var id: String { eventId ?? "\(at)-\(chatId ?? "")-\(messageId ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case eventId = "id"
        case at
        case kind
        case chatId
        case userId
        case updateId
        case messageId
        case textPreview
        case replyPreview
        case model
        case reasoningEffort
    }
    public init(
        eventId: String? = nil,
        at: String,
        kind: String? = nil,
        chatId: String? = nil,
        userId: String? = nil,
        updateId: Int? = nil,
        messageId: Int? = nil,
        textPreview: String? = nil,
        replyPreview: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil
    ) {
        self.eventId = eventId
        self.at = at
        self.kind = kind
        self.chatId = chatId
        self.userId = userId
        self.updateId = updateId
        self.messageId = messageId
        self.textPreview = textPreview
        self.replyPreview = replyPreview
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

}

public struct ReasoningEffortOption: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var description: String?
    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }

}

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

public struct ModelSurfacePreference: Codable, Hashable, Sendable {
    public var surface: String?
    public var model: String
    public var reasoningEffort: String
    public var serviceTier: String? = nil
    public var source: String?
    public var modelKnown: Bool?
    public init(
        surface: String? = nil,
        model: String,
        reasoningEffort: String,
        serviceTier: String? = nil,
        source: String? = nil,
        modelKnown: Bool? = nil
    ) {
        self.surface = surface
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.source = source
        self.modelKnown = modelKnown
    }

}

public struct ModelRoutingCurrent: Codable, Hashable, Sendable {
    public var chat: ModelSurfacePreference
    public var telegram: ModelSurfacePreference
    // FIX: the other 6 routing surfaces silently dropped on decode because they
    // were never declared. Optional so they don't break existing chat/telegram.
    public var ios: ModelSurfacePreference?
    public var executions: ModelSurfacePreference?
    public var autonomy: ModelSurfacePreference?
    public var swarms: ModelSurfacePreference?
    public var dream: ModelSurfacePreference?
    public var training: ModelSurfacePreference?

    enum CodingKeys: String, CodingKey {
        case chat, telegram, ios, autonomy, swarms, dream, training
        case executions = "workshop"
        // P2-3: the routing-config surface key was `missions` through 0.3.7.
        // The runtime emits `workshop` now, but a cached/older routing payload
        // (or an iOS build a version behind) can still carry the old key, so
        // `executions` decodes new-then-old and encodes only the new one.
        case legacyExecutions = "missions"
    }

    // Restated because the custom `init(from:)` below suppresses synthesis.
    public init(
        chat: ModelSurfacePreference,
        telegram: ModelSurfacePreference,
        ios: ModelSurfacePreference? = nil,
        executions: ModelSurfacePreference? = nil,
        autonomy: ModelSurfacePreference? = nil,
        swarms: ModelSurfacePreference? = nil,
        dream: ModelSurfacePreference? = nil,
        training: ModelSurfacePreference? = nil
    ) {
        self.chat = chat
        self.telegram = telegram
        self.ios = ios
        self.executions = executions
        self.autonomy = autonomy
        self.swarms = swarms
        self.dream = dream
        self.training = training
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chat = try c.decode(ModelSurfacePreference.self, forKey: .chat)
        telegram = try c.decode(ModelSurfacePreference.self, forKey: .telegram)
        ios = try c.decodeIfPresent(ModelSurfacePreference.self, forKey: .ios)
        executions = try c.decodeIfPresent(ModelSurfacePreference.self, forKey: .executions)
            ?? c.decodeIfPresent(ModelSurfacePreference.self, forKey: .legacyExecutions)
        autonomy = try c.decodeIfPresent(ModelSurfacePreference.self, forKey: .autonomy)
        swarms = try c.decodeIfPresent(ModelSurfacePreference.self, forKey: .swarms)
        dream = try c.decodeIfPresent(ModelSurfacePreference.self, forKey: .dream)
        training = try c.decodeIfPresent(ModelSurfacePreference.self, forKey: .training)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chat, forKey: .chat)
        try c.encode(telegram, forKey: .telegram)
        try c.encodeIfPresent(ios, forKey: .ios)
        try c.encodeIfPresent(executions, forKey: .executions)
        try c.encodeIfPresent(autonomy, forKey: .autonomy)
        try c.encodeIfPresent(swarms, forKey: .swarms)
        try c.encodeIfPresent(dream, forKey: .dream)
        try c.encodeIfPresent(training, forKey: .training)
    }
}

public struct ModelRoutingConfig: Codable, Hashable, Sendable {
    public var status: String?
    public var defaultModel: String?
    public var fallbackModels: [String]?
    public var reasoningEfforts: [ReasoningEffortOption]?
    public var current: ModelRoutingCurrent
    public init(
        status: String? = nil,
        defaultModel: String? = nil,
        fallbackModels: [String]? = nil,
        reasoningEfforts: [ReasoningEffortOption]? = nil,
        current: ModelRoutingCurrent
    ) {
        self.status = status
        self.defaultModel = defaultModel
        self.fallbackModels = fallbackModels
        self.reasoningEfforts = reasoningEfforts
        self.current = current
    }

}

public struct ModelCatalogResponse: Codable, Hashable, Sendable {
    public var status: String
    public var source: String?
    public var defaultModel: String
    public var fallbackModels: [String]
    public var models: [ModelCatalogItem]
    public var reasoningEfforts: [ReasoningEffortOption]
    public var current: ModelRoutingCurrent
    public var updatedAt: String?
    /// User, 2026-09-06: where the discovered provider rows in this response
    /// actually came from — `live`, `live_incomplete`, `cached`, `stale`,
    /// `unavailable`. A failed refresh used to be indistinguishable from a
    /// successful one, so the Providers UI reported "Model catalog refreshed"
    /// for a refresh that never reached the network. Additive and optional:
    /// a persisted `models.json` written before this decodes exactly as before.
    public var catalogFreshness: String?
    /// S12a: why the provider's list could not be loaded, and how old a
    /// last-known list is — nil when the rows are the provider's current answer.
    public var catalogNote: String? = nil
    public init(
        status: String,
        source: String? = nil,
        defaultModel: String,
        fallbackModels: [String],
        models: [ModelCatalogItem],
        reasoningEfforts: [ReasoningEffortOption],
        current: ModelRoutingCurrent,
        updatedAt: String? = nil,
        catalogFreshness: String? = nil,
        catalogNote: String? = nil
    ) {
        self.status = status
        self.source = source
        self.defaultModel = defaultModel
        self.fallbackModels = fallbackModels
        self.models = models
        self.reasoningEfforts = reasoningEfforts
        self.current = current
        self.updatedAt = updatedAt
        self.catalogFreshness = catalogFreshness
        self.catalogNote = catalogNote
    }

}

public struct TelegramBlockedEvent: Identifiable, Codable, Hashable, Sendable {
    public var eventId: String?
    public var at: String
    public var reason: String?
    public var chatId: String?
    public var userId: String?
    public var updateId: Int?
    public var textPreview: String?

    public var id: String { eventId ?? "\(at)-\(chatId ?? "")-\(userId ?? "")-\(reason ?? "")" }

    enum CodingKeys: String, CodingKey {
        case eventId = "id"
        case at
        case reason
        case chatId
        case userId
        case updateId
        case textPreview
    }
    public init(
        eventId: String? = nil,
        at: String,
        reason: String? = nil,
        chatId: String? = nil,
        userId: String? = nil,
        updateId: Int? = nil,
        textPreview: String? = nil
    ) {
        self.eventId = eventId
        self.at = at
        self.reason = reason
        self.chatId = chatId
        self.userId = userId
        self.updateId = updateId
        self.textPreview = textPreview
    }

}

public struct TelegramErrorEvent: Identifiable, Codable, Hashable, Sendable {
    public var eventId: String?
    public var at: String
    public var context: String?
    public var error: String

    public var id: String { eventId ?? "\(at)-\(context ?? "")-\(error)" }

    enum CodingKeys: String, CodingKey {
        case eventId = "id"
        case at
        case context
        case error
    }
    public init(eventId: String? = nil, at: String, context: String? = nil, error: String) {
        self.eventId = eventId
        self.at = at
        self.context = context
        self.error = error
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

public struct ProviderInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String { provider_id }
    public var provider_id: String
    public var display_name: String
    public var auth_modes: [String]
    public var auth_status: ProviderAuthStatus
    public var models: [ProviderModelInfo]
    public var auth_mode: String?
    public var default_model: String?
    /// S12a: for a fetched catalog (OpenRouter, Moonshot), why `models` could
    /// not be loaded or is last-known; nil when it is the provider's answer.
    public var models_note: String? = nil
    public init(
        provider_id: String,
        display_name: String,
        auth_modes: [String],
        auth_status: ProviderAuthStatus,
        models: [ProviderModelInfo],
        auth_mode: String? = nil,
        default_model: String? = nil,
        models_note: String? = nil
    ) {
        self.provider_id = provider_id
        self.display_name = display_name
        self.auth_modes = auth_modes
        self.auth_status = auth_status
        self.models = models
        self.auth_mode = auth_mode
        self.default_model = default_model
        self.models_note = models_note
    }

}

public typealias HealthCardSubsystem = DoctorChecks.HealthCardSubsystem

public typealias HealthCard = DoctorChecks.HealthCard

public struct CapabilityCounts: Codable, Hashable, Sendable {
    public var total: Int
    public var active: Int
    public var review: Int
    public var autoloaded: Int
    public var byKind: [String: Int]?
    public init(total: Int, active: Int, review: Int, autoloaded: Int, byKind: [String: Int]? = nil) {
        self.total = total
        self.active = active
        self.review = review
        self.autoloaded = autoloaded
        self.byKind = byKind
    }

}

public struct CapabilitySummaryResponse: Codable, Hashable, Sendable {
    public var records: [CapabilityRecord]
    public var summary: CapabilityCounts
    public var createdAt: String?
    public init(records: [CapabilityRecord], summary: CapabilityCounts, createdAt: String? = nil) {
        self.records = records
        self.summary = summary
        self.createdAt = createdAt
    }

}

extension DoctorReport: AppToolDoctorReport {}
extension TelegramErrorEvent: AppToolTelegramDiagnosticEvent {}
extension TelegramBlockedEvent: AppToolTelegramDiagnosticEvent {}
extension TelegramVoiceTranscriptionStatus: AppToolTelegramDiagnosticVoice {}
extension TelegramPresentationSnapshot: AppToolTelegramDiagnosticStatus {
    public var receiptCount: Int { receipts.count }
}
