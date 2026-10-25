import ToolRegistry
import ChatTurnRuntime
import ChatToolRuntime
import ChatSessionWork
import ChatToolParsing
import MacIntegration
import ChromeControl
import ApprovalTransactions
import DoctorChecks
import AppToolRuntime
import TrustCenter
import Foundation
import NativeAgentShared
import TelegramBot
import PersistenceCore
import ProviderRouting
import NativeAgentCore
import AuthoredCapabilities
import ToolExecution
import Senses
import Observation
// Blueprint: | `EnginePresentationModels.swift` | Root-scoped `PresentationFaces` feeds L0's pure `presentation-copy.js` cache outside rendering; page subtitles and tool phrases are removed from Swift, while sanitized tool facts, classification and identity grammar stay native. `TelegramPresentationSnapshot`, shared route vocabulary, `SidebarItem.shellFirstTab`, `SidebarItem.shellHome`, `UserDisplayFormatters`, temporal/receipt values and shared inline card presentation remain |

/// Root-scoped authored copy. Native read owners and view tasks feed frozen
/// inputs; rendering reads L0 snapshots, including canonical unavailable status.
@MainActor @Observable
public final class PresentationFaces {
    private let dataRoot: URL
    private var faces: [String:PartFaces] = [:]
    @ObservationIgnored private var inputs: [String:JSONValue] = [:]
    @ObservationIgnored private var epochs: [String:UInt64] = [:]
    public nonisolated init(dataRoot: URL) { self.dataRoot=dataRoot }

    public func words(_ key: String) -> String? {
        if let snapshot=faces[key]?.snapshots["presentation-copy"] {
            if snapshot.status == .ready { return snapshot.face?.sections.first?.rows.first?.title }
            return "Readout "+snapshot.status.rawValue+": "+(snapshot.error?.message ?? snapshot.status.rawValue)
        }
        return nil
    }

    @discardableResult
    public func prepare(_ key: String, input: JSONValue) async -> String {
        let snapshot = await prepareSnapshot(key,input:input)
        if snapshot.status == .ready, let text=snapshot.face?.sections.first?.rows.first?.title { return text }
        return "Readout "+snapshot.status.rawValue+": "+(snapshot.error?.message ?? snapshot.status.rawValue)
    }

    public func prepareSnapshot(_ key: String, input: JSONValue) async -> PartFaceSnapshot {
        if inputs[key] != input { inputs[key]=input; epochs[key,default:0] += 1 }
        if faces[key] == nil {
            let root=dataRoot
            faces[key]=PartFaces(dataRoot:root) { id,input,version in
                let host=AppToolExecutor.authoredProgramHost(dataRoot:root) { _,_ in nil }
                return await OwnedProgramInvocation.$host.withValue(host) {
                    await Parts(root:root).face(id:id,input:input,version:version)
                }
            }
        }
        return await faces[key]!.sourceChanged(id:"presentation-copy",epoch:epochs[key] ?? 0,input:input)
    }
}

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

    public var pollStatusMessage: String? {
        guard let error = normalizedLastError else { return nil }
        return TurnPresentationReducer.sanitized(isTransientPollInterruption
            ? "The poller is active and retrying after a transient interruption. \(error)"
            : error)
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
    /// for a refresh that never reached the network.
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

// 2026-06-07 ui-taste-sweep: shared formatters for human-readable display.
//
// Common ux_lies patterns the taste sweep found across multiple tabs:
//   - Raw ISO-8601 timestamps with fractional seconds + timezone offset
//     ("2026-05-02T18:02:25.245005+00:00") exposed to users
//   - the user's home directory leaked in path strings
//     ("/Users/example/Library/Application Support/NativeAgent")
//   - Raw enum identifiers shown as user-facing labels
//     ("scheduled_proactive_scan" → "SCHEDULED_PROA")
//
// One place per class so every tab gets the same treatment + the fix
// applies uniformly when we improve it.


public typealias UserDisplayFormatters = NativeAgentShared.UserDisplayFormatters

extension UserDisplayFormatters {
    // MARK: - Paths

    /// Hide the user's home directory in displayed paths. "/Users/foo/x" →
    /// "~/x". Keep the trailing portion so power users still see where the
    /// file lives. Path is treated as a hint, not a clickable; we don't
    /// resolve symlinks or check existence.
    public static func tildifyPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Receipts

    /// Output of `humanizeReceipt(name:detail:)`. The receipt rendering
    /// pattern is: a short human-readable title + a one-line subtitle,
    /// with the raw key/value pairs preserved for an inspector / disclosure
    /// disclosure group so power users can still see the full payload.
    public struct HumanizedReceipt {
        /// Short title — verb form ("Archived", "Completed", "Failed").
        /// Always non-empty; falls back to the caller-supplied fallback.
        public var title: String
        /// One-line human subtitle, e.g. "stale duplicate · 5 days ago".
        /// Empty when there's nothing useful to summarize beyond the title.
        public var subtitle: String
        /// Parsed key/value pairs in the order they appeared in `detail`.
        /// Empty when the detail string didn't match the comma-separated
        /// `key: value` shape — in that case `subtitle` carries the raw
        /// detail string instead.
        public var rawPairs: [(String, String)]
    }

    /// Humanize a NextGen-style receipt for UI rendering.
    ///
    /// The daemon emits receipt detail strings in two shapes:
    ///   1. `"<verb>: <key>: <value>, <key>: <value>, ..."` — verb embedded
    ///   2. `"<key>: <value>, <key>: <value>, ..."` — verb in `name` field
    ///
    /// Both collapse into the same `HumanizedReceipt` shape:
    ///   - title  = verb in title case ("Archived", "Completed")
    ///   - subtitle = `<reason> · <relative createdAt>` when those keys
    ///                are present; otherwise the most descriptive remaining
    ///                key, then the raw detail as last-resort fallback
    ///   - rawPairs = every parsed pair, in original order
    ///
    /// Example:
    ///   name="archived", detail="id: x, reason: stale_duplicate,
    ///                            createdAt: 2026-05-26T01:32:52.022696+00:00"
    ///   → title="Archived"
    ///   → subtitle="stale duplicate · 5 days ago"
    ///   → rawPairs=[("id","x"), ("reason","stale_duplicate"),
    ///               ("createdAt","2026-05-26T01:32:52.022696+00:00")]
    ///
    /// On total parse failure: title = `fallbackTitle`, subtitle = raw
    /// detail (so we never silently drop information).
    public static func humanizeReceipt(
        name: String?,
        detail: String?,
        fallbackTitle: String = "Receipt"
    ) -> HumanizedReceipt {
        let trimmedDetail = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to pull a leading verb out of the detail if name doesn't
        // carry one. The detail shape "<verb>: <kv pairs>" — verb has no
        // comma before it and the REST starts with another "key: value"
        // pair. Critical: the rest-must-start-with-kv-pair gate stops
        // "id: x, reason: y" from being mis-read as verb="Id", payload="x,
        // reason: y" when the daemon omits the verb entirely (caught in
        // gpt-5.5 review pass — that input shape exists in the wild).
        var verb = trimmedName
        var payload = trimmedDetail
        if verb.isEmpty, let firstColon = trimmedDetail.firstIndex(of: ":") {
            let possibleVerb = String(trimmedDetail[..<firstColon])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = String(trimmedDetail[trimmedDetail.index(after: firstColon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !possibleVerb.isEmpty,
               !possibleVerb.contains(","),
               !possibleVerb.contains(":"),
               possibleVerb.count <= 40,
               startsWithKeyValueDump(rest) {
                verb = possibleVerb
                payload = rest
            }
        }

        let pairs = parseKeyValueDump(payload)
        let title = humanizeVerb(verb).isEmpty ? fallbackTitle : humanizeVerb(verb)

        // Build subtitle: prefer "<reason> · <createdAt>". Fall back to any
        // descriptive key. Last-resort: the raw payload itself.
        var subtitleParts: [String] = []
        if let reason = lookup(pairs, ["reason", "cause", "why"]) {
            subtitleParts.append(humanizeSnakeCaseValue(reason))
        }
        if let createdAt = lookup(pairs, ["createdAt", "created_at", "timestamp", "ts", "at"]) {
            let rel = humanizeISOTimestamp(createdAt)
            if !rel.isEmpty, rel != createdAt {
                subtitleParts.append(rel)
            }
        }
        if subtitleParts.isEmpty {
            // Try one of the more descriptive keys before falling back raw.
            for key in ["source", "kind", "type", "target", "name", "id"] {
                if let v = lookup(pairs, [key]), !v.isEmpty {
                    subtitleParts.append("\(key): \(humanizeSnakeCaseValue(v))")
                    break
                }
            }
        }
        if subtitleParts.isEmpty {
            // Nothing parsed — show the raw payload so we never silently
            // hide information. Trim to a single line.
            let collapsed = payload
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return HumanizedReceipt(title: title, subtitle: collapsed, rawPairs: pairs)
        }
        return HumanizedReceipt(
            title: title,
            subtitle: subtitleParts.joined(separator: " · "),
            rawPairs: pairs
        )
    }

    /// Parse a "key: value, key: value, ..." string into ordered pairs.
    /// Empty values are kept ("records: " → ("records", "")) so the
    /// inspector reflects the daemon's actual payload. On total parse
    /// failure returns []; caller decides how to fall back.
    ///
    /// Known limitation: values containing literal ", " (prose, comma-
    /// separated lists) will split mid-value. The daemon's NextGen
    /// receipts don't emit such values today; if that changes, swap the
    /// split for a real scanner that respects quoting.
    private static func parseKeyValueDump(_ s: String) -> [(String, String)] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var pairs: [(String, String)] = []
        // Split on ", " (no nested-comma support — see doc note above).
        let chunks = trimmed.components(separatedBy: ", ")
        for chunk in chunks {
            // Split on FIRST ":" — note: ":" not ": " so we also catch
            // trailing-empty cases like "records:" where the daemon
            // omitted both the value and the trailing space. Values may
            // contain colons (ISO timestamps) — that's fine because we
            // only split once.
            if let colon = chunk.firstIndex(of: ":") {
                let key = String(chunk[..<colon])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(chunk[chunk.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    pairs.append((key, value))
                }
            }
        }
        return pairs
    }

    /// True when `s` looks like the start of a `key: value` dump — i.e. the
    /// first comma-separated chunk contains ": ". Used by the verb-prefix
    /// extractor to avoid mis-reading a leading key as a verb.
    private static func startsWithKeyValueDump(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstChunk = trimmed.firstIndex(of: ",").map { String(trimmed[..<$0]) } ?? trimmed
        return firstChunk.range(of: ": ") != nil
    }

    private static func lookup(_ pairs: [(String, String)], _ keys: [String]) -> String? {
        for key in keys {
            if let pair = pairs.first(where: { $0.0.caseInsensitiveCompare(key) == .orderedSame }) {
                let v = pair.1.trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    /// "archived" → "Archived", "auto_promote" → "Auto Promote".
    private static func humanizeVerb(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    /// "stale_duplicate" → "stale duplicate" (lowercase — used inside a
    /// sentence). Leaves UUIDs / IDs alone (no underscore → no change).
    private static func humanizeSnakeCaseValue(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("_") else { return trimmed }
        return trimmed.replacingOccurrences(of: "_", with: " ")
    }
}

extension String {
    /// Truncate a display string, appending `suffix` when (and only when) the
    /// string is longer than `limit` — a string of exactly `limit` chars is
    /// returned whole. Some call sites cap the *trigger* threshold and the
    /// *retained* prefix independently (e.g. "trip at >80 but keep 77"); pass
    /// `keeping` for those, otherwise the retained prefix uses `limit`.
    public func truncated(to limit: Int, keeping: Int? = nil, suffix: String = "…") -> String {
        guard count > limit else { return self }
        return String(prefix(keeping ?? limit)) + suffix
    }
}

public enum SkillsToolsSection: String, CaseIterable, Identifiable, Sendable {
    case skills = "Skills"
    case tools = "Tools"

    public var id: String { rawValue }
}

// PATCH-2026-05-19: ui-pull-together — keep the primary Mac sidebar compact:
// Chat, Activity, Memories, Skills & Tools, Desk, Providers, Trust, Mac Integration, Settings. Feature-specific
// control rooms stay in Advanced and the command palette instead of competing
// as always-visible tabs.
// Legacy cases (memory, settingsHub, approvals, work, skillLifecycle) stay
// defined as routing aliases so existing @SceneStorage state restores cleanly
// to the new tabs via `.normalized`.
public enum SidebarItem: String, CaseIterable, Identifiable, Sendable {
    // ── Primary (compact, always visible) ─────────────────────────────────
    case chat = "Chat"
    case bots = "Bots" // Default-on since 0.4.10 (the rail injects it; see BotsShelfPreference); not in the unflagged destination lists.
    case activity = "Activity"           // approvals + inbox + proposals
    case memories = "Memories"           // was: memory (hub); now: just the memory list
    case skills = "Skills"               // displayed as Skills & Tools; owns both subpages
    case desk = "Desk"                   // the agent's canonical planning and work surface
    case trust = "Trust"                 // policy, autonomy, Mac control
    case providers = "Providers"
    case macIntegration = "Mac Integration" // per-integration READ/WRITE permission toggles (Calendar, Mail, Messages, ...)
    case settings = "Settings"           // slim: voice + appearance + pairing + about

    // ── Advanced (disclosure-toggle reveal) ───────────────────────────────
    // personality + connectors are Advanced (set-once tabs) — they live in
    // `advancedItems`, not the rail; keep the case lines here to match.
    case personality = "Personality"     // agent identity and voice
    case connectors = "Connectors"
    case command = "Command Center"
    case capabilities = "Capabilities"
    case autoImprovement = "Self-Improvement"
    case knowledge = "Knowledge Graph"
    case dreams = "Dreams"               // dream diary + REM consolidation controls (identity-adjacent)
    case cognition = "Cognition"
    case diagnostics = "Diagnostics"     // Doctor + Status + Runs Log
    case inboxPolicy = "Inbox Policy"
    case panels = "Panels"
    case inspector = "Inspector"         // Turn Inspector: live per-turn readout + replay (W3)

    // ── Routed child surfaces (not listed as sidebar rows) ────────────────
    case telegram = "Telegram"           // Settings child + command route
    case tools = "Tools"                 // Skills & Tools child page + command route

    // ── Legacy aliases (still parseable from saved state) ─────────────────
    case memory = "Memory"               // alias → .memories
    case settingsHub = "Settings (Hub)"  // alias → .settings
    case approvals = "Approvals"         // alias → .activity
    case workshop = "Workshop"           // retired presentation alias → .desk
    case legacyWorkshop = "Executions"   // compatibility route alias → .desk
    case work = "Work"                   // alias → .desk
    case skillLifecycle = "Skill Lifecycle" // alias → .skills
    // Retired tabs (2026-07-03 dead-weight sweep) — cases kept so saved
    // selections and command routes still parse:
    //   Self-Improvement folded into Activity (its drill-in was already there);
    //   Panels' dynamic layer could never work on the Swift build.

    public var id: String { rawValue }

    /// Map legacy aliases to their current home so saved state still routes correctly.
    public var normalized: SidebarItem {
        switch self {
        case .memory: .memories
        case .settingsHub: .settings
        case .approvals: .activity
        case .workshop, .legacyWorkshop, .work: .desk
        case .skillLifecycle, .tools: .skills
        case .autoImprovement: .activity   // tab retired 2026-07-03; SI lives in Activity
        case .panels: .diagnostics         // tab retired 2026-07-03; dynamic layer was dead
        case .command: .desk               // Command Center retired 2026-07-23 → its one
                                           // real control (Create Task) now lives on the Desk
        default: self
        }
    }

    // 2026-06-06: Executions promoted to primary (daily-use, was buried in
    // Advanced causing sidebar auto-scroll to pull it to top on click).
    // Personality + Connectors stay Advanced — set-once tabs.
    // 2026-07-22: Trust promoted to primary between Providers and Mac
    // Integration — it's one of the first pages a new user should see.
    // ui-simplify 2026-09-02 (Lane A): five places, not nine. Four of the old
    // nine primaries were SETUP, not use — they moved behind Settings ▸
    // Advanced, where a person goes once.
    // User, 2026-09-04: Advanced emptied onto the rail. Memories, Personality,
    // Trust, Connectors and Diagnostics carry tabs (ShellRailPages.swift);
    // Providers, Capabilities and Notifications stand alone. Settings stays
    // last, at the bottom (the rail's seed, `SurfaceLayout.vocabulary`).
    /// The first tab of a rail page that carries tabs; nil for a plain page.
    public static func shellFirstTab(for item: SidebarItem) -> String? {
        switch item.normalized {
        case .memories: "memories"
        case .personality: "personality"
        case .trust: "trust"
        case .connectors: "connectors"
        case .diagnostics: "Doctor"
        default: nil
        }
    }

    /// Where a former Advanced page lives in the new shell when it became a
    /// tab: the rail page that hosts it and the tab's persisted key.
    public static func shellHome(for item: SidebarItem) -> (parent: SidebarItem, tab: String)? {
        switch item.normalized {
        case .knowledge: (.memories, "knowledge")
        case .dreams: (.personality, "dreams")
        case .macIntegration: (.trust, "mac")
        case .telegram: (.connectors, "telegram")
        case .cognition: (.diagnostics, "Cognition")
        case .inspector: (.diagnostics, "Inspector")
        case .skills: (.diagnostics, "skills")
        default: nil
        }
    }

    // The pages that are tabs now. Still listed so the palette and deep links
    // reach them; each lands on its rail page with that tab open.
    public static let advancedItems: [SidebarItem] = [
        .skills, .macIntegration, .knowledge, .dreams, .cognition, .inspector,
    ]

    public var systemImage: String {
        switch self {
        // Primary
        case .chat: "bubble.left.and.bubble.right"
        case .bots: "books.vertical"
        case .activity: "tray.full"
        case .memories: "brain"
        case .skills: "puzzlepiece.extension"
        case .desk: "checklist"
        case .personality: "person.crop.circle"
        case .connectors: "point.3.connected.trianglepath.dotted"
        case .trust: "lock.shield"
        case .providers: "server.rack"
        case .macIntegration: "gearshape.2"
        case .settings: "gearshape"
        // Advanced
        case .command: "rectangle.3.group"
        case .capabilities: "shippingbox"
        case .autoImprovement: "wand.and.stars"
        case .knowledge: "circle.hexagonpath"
        case .dreams: "moon.stars"
        case .cognition: "brain.head.profile"
        case .diagnostics: "stethoscope"
        case .telegram: "paperplane"
        case .inboxPolicy: "tray.and.arrow.down"
        case .panels: "rectangle.grid.2x2"
        case .tools: "wrench.and.screwdriver"
        case .inspector: "waveform.path.ecg"
        // Legacy aliases — use the normalized icon
        case .memory: "brain"
        case .settingsHub: "gearshape"
        case .approvals: "tray.full"
        case .workshop: "hammer"
        case .legacyWorkshop: "target"
        case .work: "hammer"
        case .skillLifecycle: "puzzlepiece.extension"
        }
    }

    public var displayName: String {
        switch normalized {
        case .skills: "Skills & Tools"
        // User, 2026-09-04: they are notifications, everywhere they are named.
        case .inboxPolicy: "Notifications"
        // The page calls them helpers; the route id stays "Bots".
        case .bots: "Helpers"
        default: rawValue
        }
    }

    /// One plain sentence under a rail page's title, in the agent's own voice —
    /// the same line Today, Memories and the Desk carry. Nil means the page
    /// writes its own (or needs none).
    // ui-simplify 2026-09-02: the rail is icon-over-word, so it carries the
    // word a person would use rather than the internal tab name. Activity is
    // "Today" on the rail; the destination and every route are unchanged (Lane
    // C replaces the view behind it later). `displayName` stays as-is so the
    // command palette and deep links keep their existing vocabulary.
    public var shellRailTitle: String {
        switch normalized {
        case .activity: "Today"
        case .skills: "Skills"
        // User, 2026-09-04: they are notifications, and more controls will join them.
        case .inboxPolicy: "Notifications"
        case .bots: "Helpers"
        default: rawValue
        }
    }

}

// ActivityEvent moved to NativeAgentShared.

extension ModelCatalogItem: QuietComposerModel {}
extension ReasoningEffortOption: QuietComposerEffort {}


public enum ChatShellToolSummary {
    public static let detailLimit = 4

    public typealias Status = ChatToolOutcome.FoldStatus

    /// The same metadata precedence as the expanded tool receipt.
    public static func status(
        kind: String?, ok: Bool?, resultSummary: String?, resultStatus: String? = nil,
        interactionState: String? = nil
    ) -> Status {
        ChatToolOutcome.projection(kind: kind, ok: ok, resultSummary: resultSummary,
            resultStatus: resultStatus, interactionState: interactionState).status
    }

    public static func headlineInput(count: Int, failed: Int = 0, needsYou: Int = 0) -> JSONValue {
        let failed = max(0,min(failed,count))
        return .object(["kind":.string("headline"),"count":.int(Int64(count)),"failed":.int(Int64(failed)),
            "needsYou":.int(Int64(max(0,min(needsYou,count-failed))))])
    }

    /// The file a tool call touched, when its input names one. Returns the last
    /// path component only — the room is not a place for absolute paths.
    public static func touchedFile(inputJSON: String?) -> String? {
        guard let inputJSON,
              let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["path", "file", "file_path", "filename", "target"] {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (value as NSString).lastPathComponent
            }
        }
        return nil
    }

    /// One readable line per tool call: "Read a file · SidebarModels.swift".
    /// `ok` is the call's recorded outcome; only a recorded FALSE says the
    /// call failed, since most rows record nothing (2026-09-06).
    public static func detailInput(toolName: String?, inputJSON: String?, status: Status = .plain) -> JSONValue {
        let call=toolName.map { ToolNameAliases.shown($0,inputJSON:inputJSON) }
        let name=(call?.name ?? toolName ?? "").trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        let state: String = switch status {
        case .failed: "failed"
        case .needsYou: "needsYou"
        case .asked: "asked"
        case .plain: "plain"
        }
        let title=ToolActivityPresentation.title(name)
        let lower=title.prefix(1).lowercased()+title.dropFirst()
        return .object(["kind":.string("tool"),"tool":.string(name),"status":.string(state),
            "nameCharacters":.array(title.map { .string(String($0)) }),
            "lowerCharacters":.array(lower.map { .string(String($0)) }),
            "file":touchedFile(inputJSON:call?.inputJSON ?? inputJSON).map(JSONValue.string) ?? .null,
            "subject":.string(AgentVoice.live.subject),"remember":.string(AgentVoice.live.verb("remember")),
            "possessive":.string(AgentVoice.live.possessive)])
    }

    /// A persona write reads as a RECEIPT, not as a line inside a collapsed
    /// fold.
    ///
    /// Everything else a turn touches is traffic, and the quiet row is the
    /// right shape for traffic. A line the agent wrote into its own SOUL or
    /// VOICE is not traffic: the person said something about who they want the
    /// agent to be, and the exact sentence that went into the file is shown
    /// under the answer that produced it (Agent, 2026-09-15 — a receipt lands
    /// where the answer happened). Hiding that behind "Show" would make the one
    /// visible consequence of the first conversation the one thing a person has
    /// to go looking for.
    ///
    /// Returns nil for anything that is not a settled, successful
    /// `persona_append_section` — a failed write keeps its ordinary row, and a
    /// row that asked keeps its card.
    public static func personaReceipt(
        toolName: String?, inputJSON: String?, status: Status, requiredTitle: String
    ) -> (outcome: String, meta: String)? {
        guard toolName == "persona_append_section" || toolName == "app", status == .plain else { return nil }
        guard let inputJSON,
              let data = inputJSON.data(using: .utf8),
              let call = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              // Through the app door the write is persona.append, its input under args.
              let object = toolName == "app"
                ? (call["action"] as? String == "persona.append" ? call["args"] as? [String: Any] : nil) : call,
              let kind = (object["kind"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let title = (object["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let content = (object["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, !content.isEmpty
        else { return nil }
        // Only the first conversation's own write, matched on the exact title
        // the exemption was armed with (Sol P2-10).
        guard title == requiredTitle else { return nil }
        guard let document = personaDocumentName(forKind: kind) else { return nil }
        // The receipt is a QUOTE of the line that was written, never a summary
        // of it — so the first line of the content is shown verbatim.
        let line = content.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? content
        return (line, "Written to \(document) · \(title)")
    }

    /// Only the documents the persona writers actually accept. USER.md is
    /// memory-owned and the writers refuse `kind: "user"`, so a receipt naming
    /// it would be a lie the first time someone opened the file.
    public static func personaDocumentName(forKind kind: String) -> String? {
        switch kind {
        case "soul": return "SOUL.md"
        case "voice": return "VOICE.md"
        case "growth": return "GROWTH.md"
        case "agents": return "AGENTS.md"
        default: return nil
        }
    }

    /// The trailer under a clipped detail list, or nil when nothing is hidden.
    public static func overflowLine(total: Int, shown: Int) -> String? {
        guard total > shown else { return nil }
        return "and \(total - shown) more"
    }
}

/// 658.14 — session provenance at the render boundary.
///
/// The problem this solves: a message injected by the claude/codex bridge
/// (a wake payload, an automated follow-up) used to land in the transcript
/// byte-identical to something User typed. The only marking was an in-band
/// `[from: claude, via bridge]` text prefix, which the human can type
/// verbatim and which an untrusted payload can counterfeit inside its own
/// body. Six hours later a reader could not tell the two apart.
///
/// Provenance now travels out-of-band on the message record and is projected
/// here into a fixed, closed set of display labels.
///
/// SECURITY POSTURE — why this is an allowlist and not a sanitizer.
/// A trust indicator that renders attacker-influenced text is not a trust
/// indicator. Recorded origin strings pass through
/// `ChatOrchestrationClient.messageSource(for:)`, whose `default:` branch
/// returns the caller's string unchanged, so the recorded value is not a
/// closed vocabulary. Rendering it raw would admit the whole spoofing class:
/// Unicode bidi overrides (U+202E) that visually reverse a label, newlines and
/// control characters that break out of the badge's line, homoglyphs, and
/// unbounded length. Rather than trying to enumerate and strip those, an
/// unrecognized origin renders as the fixed word "Automated" and its raw text
/// is never shown. Refusing to render is the only reliably safe option here,
/// and it fails in the honest direction: unknown reads as machine-authored,
/// never as the human.
public struct MacChatMessageProvenance: Sendable, Equatable {
    /// Fixed display text. Always a compile-time constant from this file —
    /// never interpolated from a recorded value.
    public let label: String
    /// SF Symbol name. Also always a constant from this file.
    public let symbol: String
    /// True for automated/non-human ingress. This drives the stronger visual
    /// treatment; it is not a cryptographic claim about a named process.
    public let isAutomated: Bool

    public static func make(role: String, source: String?, origin: ChatMessageOriginMetadata?) -> MacChatMessageProvenance? {
        guard let provenance = SessionMessageProvenance.make(
            role: role, source: source, hasOrigin: origin != nil,
            surface: origin?.surface, agent: origin?.agent
        ) else { return nil }
        switch provenance {
        case .claude: return .init(label: "Claude - bridge", symbol: "arrow.triangle.branch", isAutomated: true)
        case .codex: return .init(label: "Codex - bridge", symbol: "arrow.triangle.branch", isAutomated: true)
        case .telegram: return .init(label: "Telegram", symbol: "paperplane", isAutomated: false)
        case .slack: return .init(label: "Slack", symbol: "bubble.left.and.bubble.right", isAutomated: false)
        case .iPhone: return .init(label: "iPhone", symbol: "iphone", isAutomated: false)
        case .scheduled: return .init(label: "Scheduled", symbol: "clock.arrow.circlepath", isAutomated: true)
        case .automated: return .init(label: "Automated", symbol: "gearshape.arrow.triangle.2.circlepath", isAutomated: true)
        }
    }
}

extension InlineCardProjection {
    @MainActor
    public static func cardsByRow(
        _ pairs: [(rowID: String, interaction: InlineInteraction)], messages: [ChatMessage],
        sessionID: String, dataRoot: URL
    ) async -> (cardsByRow: [String: [ChatTranscriptProjection.Card]], heading: String) {
        var built: [String: [ChatTranscriptProjection.Card]] = [:]
        var collapsed = InlineInteractionResolver.collapsedCards(pairs)
        var origins = collapsed.pairs.map { (rowID: $0.rowID, interaction: $0.interaction, sessionID: sessionID) }
        for message in messages {
            if let mirror = message.metadata?.interactionMirror,
               let interaction = await InlineInteractionResolver.interaction(
                id: mirror.interactionID, sessionID: mirror.sessionID, dataRoot: dataRoot) {
                origins.append((message.id, interaction, mirror.sessionID))
            }
        }
        for pair in origins {
            let interaction = await InlineInteractionResolver.liveProjection(pair.interaction, dataRoot: dataRoot)
            let descriptor = InlineInteractionResolver.descriptor(for: interaction, dataRoot: dataRoot)
            var model = InlineCardProjection.model(interaction, descriptor: descriptor,
                repeatCount: collapsed.counts[interaction.id] ?? 1)
            model.sessionID = pair.sessionID
            built[pair.rowID, default: []].append(
                .init(interaction: interaction, descriptor: descriptor, sessionID: pair.sessionID,
                       model: model, repeatCount: collapsed.counts[interaction.id] ?? 1)
            )
        }
        collapsed.pairs = origins.map { ($0.rowID, $0.interaction) }
        return (built, collapsed.heading)
    }
}

/// User, 2026-09-03: the UI must never hard-code a gender for the agent. Where a
/// name fits, the sentence says the agent's NAME; where it doesn't, it says
/// "the agent". There is no pronoun setting and nothing to pick — the name IS
/// the voice. A name is always third-person singular, so the verb helpers are
/// fixed and every templated sentence still agrees.
///
/// 2026-09-23: on the settings-family pages (Trust, Settings, Connectors,
/// Providers, Personality, Bots) the app describes the agent AS the agent —
/// "I", "my". The name appears only as a title or label there; sentences no
/// longer go through `subject`/`verb`. Never "it" or "the agent".
public struct AgentVoice: Equatable {
    public let name: String

    public init(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? "The agent" : trimmed
    }

    public static func current(name: String) -> AgentVoice { AgentVoice(name: name) }

    // MARK: words
    //
    // Every slot is the name. The helpers stay so the call sites keep reading
    // as sentences rather than as string concatenation.

    /// "Agent"
    public var subject: String { name }
    /// "Agent" — a name needs no sentence-start capitalization.
    public var Subject: String { name }
    /// "Agent"
    public var object: String { name }
    /// "Agent's"
    public var possessive: String { name + "'s" }
    public var Possessive: String { possessive }
    /// Third-person present for a base verb: feel → feels, carry → carries,
    /// go → goes, watch → watches.
    public func verb(_ base: String) -> String {
        let lower = base.lowercased()
        if lower == "have" { return "has" }
        if lower == "be" { return "is" }
        if lower.hasSuffix("y"), let before = lower.dropLast().last, !"aeiou".contains(before) {
            return String(lower.dropLast()) + "ies"
        }
        for tail in ["s", "x", "z", "ch", "sh", "o"] where lower.hasSuffix(tail) {
            return lower + "es"
        }
        return lower + "s"
    }
}

extension AgentVoice {
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var _live = AgentVoice(name: "The agent")

    /// The voice the app is currently speaking in, for copy built outside a
    /// view (status phrases, approval cards, tool rows). Set whenever the
    /// persona name changes.
    public static var live: AgentVoice {
        get { liveLock.lock(); defer { liveLock.unlock() }; return _live }
        set { liveLock.lock(); _live = newValue; liveLock.unlock() }
    }
}

/// What the card is for. Selects the symbol and which content appears —
/// never a separate visual style.
public enum InlineCardKind: String, Sendable, Equatable, CaseIterable {
    case needsConnector
    case needsPermission
    case needsModelChoice
    case needsAPIKey
    case needsCapability
    case choose
    case confirm
    /// Work the app is doing on its own behalf: the working card and its receipt.
    case work


}

/// Where an interaction stands. Presentation only — derived from whatever owns
/// the real lifecycle, never stored here.
public enum InlineCardState: String, Sendable, Equatable, CaseIterable {
    case pending
    case running
    case settled
    case declined
    case failed
    case stopped
    /// Terminal and honest about not knowing: neither done nor declined.
    case unknown
    /// A newer, identical ask replaced this one before anybody answered it.
    /// One quiet line, "Asked earlier" — Agent's one-live-card-per-ask rule.
    case superseded

    public var isTerminal: Bool {
        switch self {
        case .pending, .running: return false
        case .settled, .declined, .failed, .stopped, .unknown, .superseded: return true
        }
    }
}

public struct InlineCardChoice: Identifiable, Sendable, Equatable {
    public let id: String
    public var title: String
    /// The consequence that belongs to this row — "billed separately",
    /// "needs an API key" — not a footnote at the bottom of the card.
    public var note: String?
    /// What the PRIMARY says once this row is picked: "Use GPT-5.6 Sol".
    /// Agent, 2026-09-13 — the button names the outcome, and with a list on
    /// the card the outcome is the row the person chose. nil keeps the card's
    /// own label, which is what the one row that is not a model needs.
    public var actionLabel: String?

    public init(id: String, title: String, note: String? = nil, actionLabel: String? = nil) {
        self.id = id
        self.title = title
        self.note = note
        self.actionLabel = actionLabel
    }
}

/// One value the card collects. Secrets never become transcript content.
public struct InlineCardField: Sendable, Equatable {
    public var label: String
    public var placeholder: String
    public var helper: String?
    public var isSecret: Bool
    /// The key the value travels under when a card collects several.
    public var id: String
    /// An optional field never holds the primary back.
    public var isOptional: Bool

    public init(label: String, placeholder: String, helper: String? = nil, isSecret: Bool = true,
         id: String = "value", isOptional: Bool = false) {
        self.label = label
        self.placeholder = placeholder
        self.helper = helper
        self.isSecret = isSecret
        self.id = id
        self.isOptional = isOptional
    }
}

/// The display value. Every field the seven uses need, and nothing about how
/// the interaction resolves.
public struct InlineCardModel: Identifiable, Sendable, Equatable {
    /// Bound to the originating request, not to the last message: a second
    /// observation of the same blocked request updates this card.
    public let id: String
    public var sessionID = ""
    public var kind: InlineCardKind
    /// What the interaction is about: "GitHub", "Desktop", "Work".
    public var target: String
    public var systemPermissions: [SystemPermissionCapability]
    public var title: String
    /// One sentence. A writing constraint, not a line limit — it wraps.
    public var why: String
    public var primaryLabel: String
    public var secondaryLabel: String
    /// Required on every card: what taking the quiet option costs.
    public var consequence: String
    public var state: InlineCardState
    /// "Stays on until you turn it off in Trust." — required on permissions.
    public var persistenceNote: String?
    /// What the card collects, in order. Values never become transcript content.
    public var fields: [InlineCardField]
    public var field: InlineCardField? { fields.first }
    /// "Sign in with ChatGPT": what the primary does while every field is
    /// empty. Typing into a field turns the primary back into the paste.
    public var signInLabel: String?
    /// A quiet link to the full setup sheet, for what the card can't express.
    public var fullSetupLabel: String?
    public var choices: [InlineCardChoice]
    /// Scope, paths, recipients — the consequential detail, on the face of the
    /// card rather than behind the fold.
    public var scopeLines: [String]
    /// A monospaced identifier the card is about: a path, an address, a key id.
    public var identifier: String?
    public var detailsLabel: String?
    public var detailsBody: String?
    /// What the primary button says while the work is in flight.
    public var busyLabel: String?
    /// The honest note beside the spinner: "12 pages", "Usually about 20 seconds".
    public var busyNote: String?
    /// The settled/declined/failed one-liner and its metadata.
    public var outcome: String?
    public var outcomeMeta: String?
    /// Whether the running state still offers Stop.
    public var canStop: Bool
    /// Whether a failure is safe to retry.
    public var canRetry: Bool

    /// A retryable failure still needs the person's answer.
    public var needsAttention: Bool {
        !state.isTerminal || (state == .failed && canRetry)
    }

    public init(
        id: String,
        kind: InlineCardKind,
        target: String = "",
        systemPermissions: [SystemPermissionCapability] = [],
        title: String,
        why: String,
        primaryLabel: String,
        secondaryLabel: String = "Not now",
        consequence: String,
        state: InlineCardState = .pending,
        persistenceNote: String? = nil,
        field: InlineCardField? = nil,
        fields: [InlineCardField] = [],
        signInLabel: String? = nil,
        fullSetupLabel: String? = nil,
        choices: [InlineCardChoice] = [],
        scopeLines: [String] = [],
        identifier: String? = nil,
        detailsLabel: String? = nil,
        detailsBody: String? = nil,
        busyLabel: String? = nil,
        busyNote: String? = nil,
        outcome: String? = nil,
        outcomeMeta: String? = nil,
        canStop: Bool = false,
        canRetry: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.systemPermissions = systemPermissions
        self.title = title
        self.why = why
        self.primaryLabel = primaryLabel
        self.secondaryLabel = secondaryLabel
        self.consequence = consequence
        self.state = state
        self.persistenceNote = persistenceNote
        self.fields = fields.isEmpty ? (field.map { [$0] } ?? []) : fields
        self.signInLabel = signInLabel
        self.fullSetupLabel = fullSetupLabel
        self.choices = choices
        self.scopeLines = scopeLines
        self.identifier = identifier
        self.detailsLabel = detailsLabel
        self.detailsBody = detailsBody
        self.busyLabel = busyLabel
        self.busyNote = busyNote
        self.outcome = outcome
        self.outcomeMeta = outcomeMeta
        self.canStop = canStop
        self.canRetry = canRetry
    }


}

/// The join between the two halves.
///
/// The mechanism owns a durable `InlineInteraction` and the registry that says
/// WHICH existing control resolves it (`InlineInteractionDescriptor`). The view
/// half owns `InlineCardModel` and knows nothing about connectors, Trust or
/// Providers. This is the only place the two meet, and it is a pure function:
/// no store, no dispatch, no resolution.
///
/// Two rules it enforces, both of which exist so a card never lies:
///
///  * **A descriptor with no control never renders a button.** The card becomes
///    a terminal "unknown" wearing the yellow mark and saying why, rather than
///    a primary action that does nothing when tapped.
///  * **The secondary is always the decline.** `secondaryActionLabel` on a
///    scoped model choice is a second AFFIRMATIVE ("For future Work tasks
///    too"), and the view grammar has exactly one quiet command, which the
///    action handler wires to `decline`. Binding that label to a decline would
///    make the card do the opposite of what it says, so the alternative is
///    stated as a scope line and the quiet command stays "Not now".
public enum InlineCardProjection {

    // MARK: - Kind and state, 1:1

    public static func kind(_ kind: InlineInteraction.Kind) -> InlineCardKind {
        switch kind {
        case .connector: return .needsConnector
        case .permission: return .needsPermission
        case .modelChoice: return .needsModelChoice
        case .apiKey: return .needsAPIKey
        case .capability: return .needsCapability
        // An unknown kind is a question this build cannot answer; it renders
        // in the neutral "choose" shell and is forced terminal below.
        case .choose, .unknown: return .choose
        }
    }

    public static func state(_ state: InlineInteraction.State) -> InlineCardState {
        switch state {
        case .pending: return .pending
        case .running: return .running
        case .settled: return .settled
        case .declined: return .declined
        case .failed: return .failed
        case .stopped: return .stopped
        case .unknown: return .unknown
        case .superseded: return .superseded
        }
    }

    // MARK: - The projection

    public static func model(
        _ interaction: InlineInteraction,
        descriptor: InlineInteractionDescriptor,
        repeatCount: Int = 1
    ) -> InlineCardModel {
        // A live need whose control does not exist on this build is terminal
        // and honest about it: the yellow question mark, the reason, no button.
        let deadControl = !descriptor.isActionable && interaction.state.isOpen
        let cardState = deadControl ? .unknown : state(interaction.state)

        return InlineCardModel(
            id: interaction.id,
            kind: kind(interaction.kind),
            target: descriptor.displayName,
            systemPermissions: [.permission, .capability].contains(interaction.kind)
                ? interaction.allTargets.compactMap(SystemPermissionPreflight.cardSettingsCapability) : [],
            title: interaction.title,
            why: interaction.why,
            primaryLabel: primaryLabel(interaction, descriptor),
            // The quiet command is the decline, on every card. See the type
            // comment: the scoped model choice's own second label is an
            // affirmative and is surfaced in `scopeLines` instead.
            secondaryLabel: "Not now",
            // Something to connect says what skipping costs in one plain line,
            // whatever words the ask arrived with.
            consequence: [.connector, .apiKey].contains(interaction.kind) && interaction.secret?.remove != true
                ? "If you skip, \(descriptor.displayName) stays off."
                : interaction.declineConsequence,
            state: cardState,
            persistenceNote: interaction.persistenceNote,
            fields: fields(interaction, descriptor),
            signInLabel: InlineInteractionRegistry.providerSignIn(for: descriptor.target)
                .flatMap { descriptor.control == .providerAPIKey ? "Sign in with \($0.displayShort)" : nil }
                ?? (interaction.secret?.signIn == nil ? nil : "Sign in"),
            // Slack's mention rule, Telegram's users list and the like live on
            // the full page; the card never pretends to hold them.
            fullSetupLabel: descriptor.control == .connectorManualToken ? "Open full setup" : nil,
            choices: interaction.options.map {
                InlineCardChoice(
                    id: $0.id, title: $0.label, note: $0.detail,
                    // The primary names the outcome, so with a list on the
                    // card it names the row. The one row that is not a model -
                    // "save this for the whole group" - keeps the card's own
                    // label, because "Use Save for every Work task" is not a
                    // sentence.
                    actionLabel: $0.id == InlineInteractionRegistry.persistentChoiceOptionID
                        ? nil : "Use \($0.label)"
                )
            },
            scopeLines: scopeLines(interaction, descriptor),
            // "What happens" describes what tapping the primary WILL do, so it
            // belongs only to a card that still has one. On a receipt it would
            // promise a future that already happened, and it would put a
            // disclosure on the one line Agent's grammar reserves for the mark
            // and the outcome.
            detailsLabel: rendersAsReceipt(cardState)
                ? nil : details(interaction, descriptor)?.label,
            detailsBody: rendersAsReceipt(cardState)
                ? nil : details(interaction, descriptor)?.body,
            busyLabel: busyLabel(interaction.kind),
            busyNote: busyNote(interaction, descriptor.control),
            outcome: outcome(interaction, deadControl: deadControl, repeatCount: repeatCount, name: descriptor.displayName).text,
            outcomeMeta: outcome(interaction, deadControl: deadControl, repeatCount: repeatCount, name: descriptor.displayName).meta
                ?? (deadControl ? descriptor.unavailableReason : nil),
            // The working card owns Stop; a need is waiting on a person, and
            // there is nothing running to stop.
            canStop: false,
            canRetry: descriptor.isActionable
        )
    }

    /// Which states the view draws as the one-line receipt rather than as a
    /// card with controls. A failure is deliberately NOT one of them: it keeps
    /// its card, its explanation and its retry.
    private static func rendersAsReceipt(_ state: InlineCardState) -> Bool {
        switch state {
        case .settled, .declined, .unknown, .superseded: return true
        case .pending, .running, .failed, .stopped: return false
        }
    }

    // MARK: - Parts

    /// The interaction writes the label, with one exception the descriptor
    /// forces: a model choice that arrived with no options cannot honestly say
    /// "Just this image", because the card has nothing to pick from. It sends
    /// the person to the control that does have the list.
    private static func primaryLabel(
        _ interaction: InlineInteraction,
        _ descriptor: InlineInteractionDescriptor
    ) -> String {
        if interaction.kind == .modelChoice, interaction.options.isEmpty {
            return "Choose in Providers"
        }
        // A posture card grants nothing; the only true label is the page.
        if descriptor.control == .trustPostureRequired {
            return "Open Trust"
        }
        // Agent, 2026-09-13: the primary says the OUTCOME, never the mechanics
        // of getting there. "Paste a token" is how one of the two connector
        // setups happens to work; what the person is buying is Notion,
        // connected. This is a RENDERING rule, so it governs the cards already
        // sitting in scrollback with the old wording on them, not just the
        // ones raised from here on. Derived from the descriptor, so it stays
        // free of per-service copy.
        switch interaction.kind {
        case .apiKey where interaction.secret?.remove == true:
            return interaction.primaryActionLabel
        case .connector, .apiKey:
            return "Connect \(descriptor.displayName)"
        case .permission:
            let names = interaction.allTargets.map(
                InlineInteractionRegistry.macCapabilityDisplayName
            )
            let phrase = InlineInteractionRegistry.englishList(names)
            return phrase.isEmpty ? interaction.primaryActionLabel : "Allow \(phrase)"
        case .capability:
            return "Turn on \(descriptor.displayName.lowercased())"
        case .modelChoice, .choose, .unknown:
            return interaction.primaryActionLabel
        }
    }

    /// The values a card collects itself: a provider's key (or Claude's setup
    /// token), and a manual-token connector's own setup fields. Each is
    /// written through its owner's own save and then VERIFIED with that owner,
    /// so a field is a real control, not a decoration.
    private static func fields(_ interaction: InlineInteraction, _ descriptor: InlineInteractionDescriptor) -> [InlineCardField] {
        switch descriptor.control {
        case .keyring:
            // A removal takes nothing; a sign-in fetches the value itself and
            // the card holds only the client secret a service may have issued.
            if interaction.secret?.remove == true { return [] }
            guard interaction.secret?.signIn == nil else {
                let basic = interaction.secret?.signIn?.clientAuth == "basic"
                return [InlineCardField(label: "Client secret", placeholder: basic ? "The secret the service issued" : "Only if the service issued one",
                                        helper: "Kept in this Mac's Keychain with the sign-in. The chat and the agent never see it.",
                                        isSecret: true, isOptional: !basic)]
            }
            return [InlineCardField(label: "\(descriptor.displayName) key", placeholder: "Paste the key",
                                    helper: "Kept in this Mac's Keychain. The chat and the agent never see it.", isSecret: true)]
        case .connectorManualToken:
            return connectorFields(for: descriptor.target)
        case .providerAPIKey:
            let signIn = InlineInteractionRegistry.providerSignIn(for: descriptor.target)
            // Signing in is the only way into this one: no field at all.
            if signIn != nil, signIn?.pasteLabel == nil { return [] }
            return [InlineCardField(
                label: signIn?.pasteLabel ?? "\(descriptor.displayName) API key",
                placeholder: "Paste the key",
                helper: "Your key stays on this Mac. It never goes into the chat.",
                isSecret: true
            )]
        default:
            return []
        }
    }

    /// The consequential detail, on the face of the card: exactly what a grant
    /// covers, and how far a resolution reaches.
    private static func scopeLines(
        _ interaction: InlineInteraction,
        _ descriptor: InlineInteractionDescriptor
    ) -> [String] {
        var lines: [String] = []

        if interaction.kind == .permission {
            for capability in interaction.allTargets {
                let name = InlineInteractionRegistry.macCapabilityDisplayName(capability)
                lines.append("\(name) — \(axes(capability, mode: interaction.mode))")
            }
            if descriptor.control == .trustPostureRequired {
                // The posture is the person's, and a card never moves it. Say
                // that on the face of the card rather than letting a button
                // imply otherwise.
                lines.append(
                    "Your Trust posture doesn't allow this at all — it can only be changed in Trust."
                )
            }
        }

        if [.permission, .capability].contains(interaction.kind) {
            lines += SystemPermissionPreflight.cardSettingsInstructions(interaction.allTargets)
        }

        // A secret's grant is where it may go, and nowhere else.
        if let ask = interaction.secret, ask.remove != true {
            lines.append("Goes only to \(ask.line)")
            if let stops = ask.stops { lines.append("Stops going to \(stops.joined(separator: ", "))") }
            // Where the sign-in, and a client secret typed here, go: the hosts the flow uses.
            if let signIn = ask.signIn {
                let host = { (address: String?) in address.flatMap(URL.init(string:))?.host ?? "" }
                lines.append("Signs in at \(host(signIn.authorize ?? signIn.device)); token from \(host(signIn.token))")
            }
        }

        // How far the resolution reaches — said only where it is TRUE. A
        // this-request-only scope is a promise the card can keep just when it
        // has the models to pick from; with no options the choice is made in
        // Providers, which saves it, and claiming otherwise would be a lie the
        // person discovers afterwards.
        if interaction.kind == .modelChoice {
            if interaction.options.isEmpty {
                lines.append("Saved for every \(descriptor.displayName) task.")
            } else if interaction.primaryScope == .thisRequestOnly {
                // The permanent alternative is the last row of the list, so the
                // scope line says which rows this promise covers rather than
                // claiming it of the whole card.
                lines.append("Picking a model applies to this request only — nothing is saved.")
            } else {
                lines.append("Saved for every \(descriptor.displayName) task.")
            }
        }
        return lines
    }

    /// What a Mac grant actually turns on.
    ///
    /// The need carries the axis the blocked call wanted, and where the owner
    /// has two axes to write, that is exactly what is granted and exactly what
    /// this line says. Trust's Mac Control categories are ONE switch each — no
    /// read/write split exists to narrow — so those say what the switch really
    /// covers rather than a narrower promise the store could not keep.
    private static func axes(_ capability: String, mode: InlineInteraction.AccessMode?) -> String {
        if capability.hasPrefix("applescript:") { return "macOS Automation consent for this app" }
        if InlineInteractionRegistry.isMacControlCategory(capability) {
            guard let mode else { return "one switch in Trust, covering reading and changing" }
            return "needed for \(mode == .write ? "changing" : "reading")"
                + "; the one Trust switch covers reading and changing"
        }
        let read = MacIntegrationID.supportsRead(capability) && (mode?.wantsRead ?? true)
        let write = MacIntegrationID.supportsWrite(capability) && (mode?.wantsWrite ?? true)
        switch (read, write) {
        case (true, true): return "read and write"
        case (true, false): return "read only"
        case (false, true): return "write only"
        case (false, false): return "no access on this build"
        }
    }

    /// What tapping the primary will actually open. The control decides this,
    /// which is how the card stays free of per-service copy.
    private static func details(
        _ interaction: InlineInteraction,
        _ descriptor: InlineInteractionDescriptor
    ) -> (label: String, body: String)? {
        let name = descriptor.displayName
        // A choice the card itself holds is made HERE. Saying Providers opens
        // would describe the one row that does open it as if it were the card.
        if interaction.kind == .modelChoice, !interaction.options.isEmpty {
            var body = "The model you pick makes this one picture and nothing is saved."
            if interaction.options.contains(where: { $0.id == InlineInteractionRegistry.persistentChoiceOptionID }) {
                body += " The last row is the other choice: it opens Providers, "
                    + "the only place the \(name) group's saved model changes."
            }
            return ("What happens", body)
        }
        switch descriptor.control {
        case .internetAccounts:
            return ("What happens", "Internet Accounts opens so you can add and enable a Mail account.")
        case .chromeSetup:
            return ("What happens",
                    "Chrome control is switched on in Trust. " + chromeSteps)
        case .pairDevice:
            return ("What happens",
                    "The pairing page opens. Open NativeAgent on your iPhone, then choose Pair "
                    + "here when the codes match.")
        case .connectorManualToken:
            return ("What happens",
                    "What you paste is checked with \(name) and saved by Connectors, the same "
                    + "as its setup page does. The chat never sees it.")
        case .macPermissionGrant where interaction.allTargets.contains(where: { $0.hasPrefix("applescript:") }):
            return ("What happens",
                    "macOS asks for Automation consent for each requested app; the card reports whether you allowed it.")
        case .macPermissionGrant where interaction.allTargets.contains(where: { SystemPermissionPreflight.cardSettingsCapability($0) != nil }):
            return ("What happens",
                    "macOS controls this permission. You can turn it off in System Settings.")
        case .macPermissionGrant:
            return ("What happens",
                    "The permission is turned on here and listed in Trust, "
                    + "where you can turn it off again at any time.")
        case .trustPostureRequired:
            return ("What happens",
                    "Trust opens. Your posture is yours to set — nothing here changes it, "
                    + "and \(name) stays off until you do.")
        case .providerGroupModel:
            return ("What happens",
                    "Providers opens on the \(name) group so you can pick the model there.")
        case .providerAPIKey:
            if InlineInteractionRegistry.providerSignIn(for: descriptor.target) != nil {
                return ("What happens",
                        "Signing in opens your browser, the same sign-in as onboarding. "
                        + "Nothing counts as done until \(name) is ready in Providers.")
            }
            return ("What happens",
                    "The key is checked with \(name), then saved in Providers. "
                    + "A key \(name) rejects is not saved and does not count as done.")
        case .capabilityFlag:
            return ("What happens",
                    "\(name) is switched on in Trust, the same switch as the one on that page.")
        case .keyring where interaction.secret?.remove == true:
            return ("What happens", "\(name) is deleted from this Mac's Keychain. Abilities that use it stop until you grant it again.")
        case .keyring:
            return ("What happens",
                    (interaction.secret?.signIn == nil ? "What you paste is kept in this Mac's Keychain. "
                        : "Your browser opens to sign in; what the service returns is kept in this Mac's Keychain. ")
                    + "It goes only to \(interaction.secret?.line ?? "where this card says"), and the agent uses it by name without ever seeing it.")
        case .inlineChoice, .unavailable, .unknown:
            return nil
        }
    }

    /// The one thing to click, for a card that waits on the person
    /// somewhere else and settles by itself when the owner says done.
    public static let chromeSteps = "I'll load my extension in Chrome and check the connection. Allow Mac access if asked."

    private static func busyNote(_ interaction: InlineInteraction, _ control: InlineInteractionDescriptor.Control) -> String? {
        switch control {
        case .keyring: return Keyring.signInNote(String(interaction.target.dropFirst("secret:".count)))
        case .internetAccounts: return "Add and turn on a Mail account in Internet Accounts."
        case .chromeSetup: return chromeSteps
        case .pairDevice: return "Open NativeAgent on your iPhone, then choose Pair when the codes match."
        case .macPermissionGrant, .capabilityFlag:
            return "If System Settings opened, turn NativeAgent on there."
        default: return nil
        }
    }

    private static func busyLabel(_ kind: InlineInteraction.Kind) -> String {
        switch kind {
        case .connector: return "Connecting…"
        case .permission: return "Allowing…"
        case .modelChoice: return "Switching…"
        case .apiKey: return "Connecting…"
        case .capability: return "Turning on…"
        case .choose, .unknown: return "Working…"
        }
    }

    /// The one-line receipt and its metadata. A settled card says what the
    /// OWNER confirmed; a declined one keeps the promise the card made about
    /// declining; a failure carries its reason into the card that stays.
    private static func outcome(
        _ interaction: InlineInteraction,
        deadControl: Bool,
        repeatCount: Int = 1,
        name: String = ""
    ) -> (text: String?, meta: String?) {
        // The same ask, answered the same way, several times in a row is ONE
        // thing that happened — not five. The count rides on the receipt line
        // itself so the glass and the quiet page read say it identically
        // (Agent, 2026-09-14: ten Connect Notion cards in one conversation).
        func counted(_ text: String) -> String {
            repeatCount > 1 ? text + " (×\(repeatCount))" : text
        }
        if deadControl { return (counted(interaction.title), nil) }
        switch interaction.state {
        case .stopped(let reason):
            return ("Stopped", reason)
        case .settled(let settled):
            return (counted(settled.summary.isEmpty ? interaction.title : settled.summary),
                    settled.scope == .thisRequestOnly ? "This request only" : nil)
        case .declined where [.connector, .apiKey].contains(interaction.kind) && !name.isEmpty:
            // Something to connect, skipped: the account's name, one word.
            return (counted("\(name) skipped"), nil)
        case .declined:
            // ONE gray line: the mark, "Not now", and what that cost. NEVER
            // the title - "Connect Notion" beside a cross reads as a thing
            // that happened (Agent, 2026-09-13). The consequence is the card's
            // own promise, kept where the person can still see it.
            let consequence = InlineInteraction.lowercasedLead(
                interaction.declineConsequence.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return (counted(consequence.isEmpty ? "Not now" : "Not now \u{2014} " + consequence), nil)
        case .superseded:
            // The view draws one quiet line of its own; nothing to say here.
            return (nil, nil)
        case .failed(let reason):
            // THE FAILURE IS THE OUTCOME. `interaction.title` is the ask's own
            // headline — "Connect Notion" — so a failed card projected
            // "Outcome: Connect Notion", the primary button's words standing in
            // for what happened, with the actual reason demoted to metadata
            // (Agent, 2026-09-14).
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return (counted(trimmed.isEmpty ? "It didn't go through." : trimmed), nil)
        case .unknown:
            return (counted(interaction.title), "Outcome unknown.")
        case .pending, .running:
            return (nil, nil)
        }
    }
    public static func connectorFields(for connector: String) -> [InlineCardField] {
        let stays = "Your key stays on this Mac. It never goes into the chat."
        switch InlineInteractionRegistry.canonicalConnectorID(connector) {
        case "telegram":
            return [
                InlineCardField(label: "Bot token", placeholder: "123456789:ABC… from @BotFather",
                                helper: stays, id: "token"),
                InlineCardField(label: "Allowed chat ID", placeholder: "Numeric chat ID",
                                helper: "Send your bot a message, then open Telegram setup and use Check sender to find your ID. Only a recipient you admit can reach the agent.",
                                isSecret: false, id: "allowed_chat_id"),
            ]
        case "slack":
            return [
                InlineCardField(label: "Slack bot token", placeholder: "xoxb-...", helper: stays, id: "token"),
                InlineCardField(label: "Socket Mode app token (optional)", placeholder: "xapp-...",
                                helper: "Slack chat needs it; it can be added later.",
                                id: "app_token", isOptional: true),
                InlineCardField(label: "Allowed channel IDs", placeholder: "C0123, C0456",
                                isSecret: false, id: "allowed_channels", isOptional: true),
                InlineCardField(label: "Allowed user IDs", placeholder: "U0123",
                                helper: "Add at least one channel or user.",
                                isSecret: false, id: "allowed_users", isOptional: true),
            ]
        default:
            return []
        }
    }

}
