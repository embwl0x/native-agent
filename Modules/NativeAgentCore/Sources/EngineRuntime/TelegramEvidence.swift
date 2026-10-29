import NativeAgentShared
import ChatTurnContracts
import ChatToolRuntime
import DoctorChecks
import PersistenceCore
import Privacy
import ProviderRouting
import ToolRegistry
import AppToolRuntime
import Foundation
import NativeAgentCore
import TelegramBot
// Blueprint: | `TelegramEvidence.swift` | TelegramPresentationSnapshot, transport health, receipt/blocked/error Codable records and concrete tool health receipt |

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

extension TelegramPresentationSnapshot {
    func toolStatusEnvelope(now: Date) -> JSONValue {
        let status = self
        let lastSuccessfulPoll = telegramDiagnosticDate(status.lastPollAt)
        let datedErrors = status.errors.compactMap { event in
            telegramDiagnosticDate(event.at).map { (event.at, $0) }
        }
        let datedBlocked = status.blocked.compactMap { event in
            telegramDiagnosticDate(event.at).map { (event.at, $0) }
        }
        let errorsAfterLastSuccessfulPoll = lastSuccessfulPoll.map { pollAt in
            datedErrors.filter { $0.1 > pollAt }.count
        }
        let latestError = datedErrors.max(by: { $0.1 < $1.1 })
        let latestBlocked = datedBlocked.max(by: { $0.1 < $1.1 })
        let errorHistoryStatus: String
        if status.actionableError != nil {
            errorHistoryStatus = "active_error"
        } else if let errorsAfterLastSuccessfulPoll, errorsAfterLastSuccessfulPoll > 0 {
            errorHistoryStatus = "newer_than_last_successful_poll"
        } else if status.errors.isEmpty {
            errorHistoryStatus = "empty"
        } else {
            errorHistoryStatus = "recovered_history"
        }
        var object: [String: JSONValue] = [
            "status": .string(status.isOperational ? "ok" : "attention"),
            "enabled": .bool(status.enabled),
            "token_configured": .bool(status.tokenConfigured),
            "poller_running": .bool(status.pollerEnabled),
            "require_mention": .bool(status.requireMention),
            "allowed_chat_count": .int(Int64(status.allowedChatIds.count)),
            "allowed_user_count": .int(Int64(status.allowedUserIds.count)),
            "recent_receipt_ledger_entries": .int(Int64(status.receipts.count)),
            "recent_blocked_ledger_entries": .int(Int64(status.blocked.count)),
            "recent_error_ledger_entries": .int(Int64(status.errors.count)),
            "error_history_status": .string(errorHistoryStatus),
            "error_entries_since_last_successful_poll": errorsAfterLastSuccessfulPoll
                .map { .int(Int64($0)) } ?? .null,
            "error_entries_with_unreadable_timestamp": .int(Int64(status.errors.count - datedErrors.count)),
            "blocked_history_status": .string(status.blocked.isEmpty ? "empty" : "historical_policy_events"),
            "blocked_entries_with_unreadable_timestamp": .int(Int64(status.blocked.count - datedBlocked.count)),
            "ledger_scope_note": .string("error and blocked ledger counts are bounded history, not current failure counts; active_error and errors since the last successful poll carry current-health meaning; blocked rows are policy decisions, not transport failures"),
            "active_error": .bool(status.actionableError != nil),
            "poll_retry_transient": .bool(status.isTransientPollInterruption),
            "consecutive_poll_failures": .int(Int64(status.pollBackoffFailures ?? 0)),
        ]
        if !status.tokenConfigured {
            object["next"] = .string("raise request_interaction kind=connector target=telegram")
        }
        object["model"] = status.model.map { .string($0) } ?? .null
        object["reasoning_effort"] = status.reasoningEffort.map { .string($0) } ?? .null
        object["last_seen_at"] = status.lastSeenAt.map { .string($0) } ?? .null
        object["last_reply_at"] = status.lastReplyAt.map { .string($0) } ?? .null
        object["last_successful_poll_at"] = status.lastPollAt.map { .string($0) } ?? .null
        object["latest_error_at"] = latestError.map { .string($0.0) } ?? .null
        object["latest_error_age_seconds"] = latestError.map {
            .int(Int64(max(0, now.timeIntervalSince($0.1))))
        } ?? .null
        object["latest_blocked_at"] = latestBlocked.map { .string($0.0) } ?? .null
        object["latest_blocked_age_seconds"] = latestBlocked.map {
            .int(Int64(max(0, now.timeIntervalSince($0.1))))
        } ?? .null
        object["last_error"] = status.lastError.map {
            .string(String(NativeAppSecretRedactor.redactText($0).prefix(600)))
        } ?? .null
        if let voice = status.voiceTranscription {
            object["voice_transcription"] = .object([
                "enabled": .bool(voice.enabled),
                "backend": .string(voice.backend),
                "model": .string(voice.model),
            ])
        }
        return .object(object)
    }

    private func telegramDiagnosticDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(raw)
    }
}
