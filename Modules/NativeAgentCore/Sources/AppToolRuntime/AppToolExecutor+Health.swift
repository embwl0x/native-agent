import Foundation
import ChatTurnContracts
import ChatToolRuntime
import DoctorChecks
import NativeAgentCore
import PersistenceCore
import Privacy
import ProviderRouting
import ToolRegistry
// Blueprint: | `AppToolExecutor+Health.swift` | `AppToolExecutor`: `doctorStatus`, `boundedDoctorDetail`, `doctorStatusEnvelope` |

/// Live health observations supplied by the host; envelope policy belongs to Core.
public protocol AppToolDoctorReport {
    var status: String { get }
    var repaired: Bool { get }
    var checks: [CheckResult] { get }
}

public protocol AppToolTelegramDiagnosticEvent {
    var at: String { get }
}

public protocol AppToolTelegramDiagnosticVoice {
    var enabled: Bool { get }
    var backend: String { get }
    var model: String { get }
}

public protocol AppToolTelegramDiagnosticStatus {
    associatedtype Event: AppToolTelegramDiagnosticEvent
    associatedtype BlockedEvent: AppToolTelegramDiagnosticEvent
    associatedtype Voice: AppToolTelegramDiagnosticVoice
    var enabled: Bool { get }
    var tokenConfigured: Bool { get }
    var pollerEnabled: Bool { get }
    var requireMention: Bool { get }
    var allowedChatIds: [String] { get }
    var allowedUserIds: [String] { get }
    var receiptCount: Int { get }
    var blocked: [BlockedEvent] { get }
    var errors: [Event] { get }
    var actionableError: String? { get }
    var isOperational: Bool { get }
    var isTransientPollInterruption: Bool { get }
    var pollBackoffFailures: Int? { get }
    var model: String? { get }
    var reasoningEffort: String? { get }
    var lastSeenAt: String? { get }
    var lastReplyAt: String? { get }
    var lastPollAt: String? { get }
    var lastError: String? { get }
    var voiceTranscription: Voice? { get }
}

/// One account as ProviderRouting publishes it: the receipt's state word and
/// whether it may dispatch.
public struct AppToolProviderHealth: Sendable {
    public let providerID: String
    public let authState: String
    public let eligible: Bool

    public init(providerID: String, authState: String, eligible: Bool) {
        self.providerID = providerID
        self.authState = authState
        self.eligible = eligible
    }
}

extension AppToolExecutor {
    public static func doctorStatus(
        report: some AppToolDoctorReport,
        completedAt: Date?,
        runningSince: Date?,
        providerHealth: @Sendable (URL) async throws -> [AppToolProviderHealth]
    ) async throws -> JSONValue {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let surface = ChatTurnRuntimeContext.current?.surface ?? "chat"
        let router = SwiftNativeProviderRouting(
            dataRoot: dataRoot,
            surfacesPathOverride: dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("surfaces.json"),
            activeProviderPathOverride: dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("active.json")
        )
        let configuredProviderID = try? await router.checkedRoutingSnapshot().activeProviders
        let activeProviderID = ChatTurnRuntimeContext.current?.providerID
            ?? configuredProviderID.flatMap { ProviderRoutingSurfaceLookup.value($0, surface) }
        let providers = try? await providerHealth(dataRoot)
        let activeProvider = activeProviderID.flatMap { providerID in
            providers?.first(where: { $0.providerID == providerID })
        }
        return doctorStatusEnvelope(
            report: report,
            completedAt: completedAt,
            runningSince: runningSince,
            activeProviderID: activeProviderID,
            activeProvider: activeProvider
        )
    }

    /// Agent, 2026-09-06: a doctor detail was cut with a bare `prefix(600)`, so
    /// Prompt Prefix Cache ended at "so the rate i" and Subconscious Vitals at
    /// "so earlier turns" — mid-word, with nothing saying anything was missing.
    /// Same 600-character cap; the cut lands on a word boundary and says so.
    public static func boundedDoctorDetail(_ detail: String, limit: Int = 600) -> String {
        guard detail.count > limit else { return detail }
        let ellipsis = "…"
        let head = detail.prefix(limit - ellipsis.count)
        // Only honour a boundary in the last part of the budget — one very long
        // unbroken token must not shrink the detail to a few words.
        if let boundary = head.lastIndex(where: { $0 == " " || $0.isNewline }),
           head.distance(from: head.startIndex, to: boundary) > head.count / 2 {
            let trimmed = head[..<boundary]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed + ellipsis }
        }
        return String(head) + ellipsis
    }

    /// The page names the run it shows, and a run in flight says so rather
    /// than passing the report from before it off as current.
    public static func doctorStatusEnvelope(
        report: some AppToolDoctorReport,
        completedAt: Date?,
        runningSince: Date?,
        activeProviderID: String?,
        activeProvider: AppToolProviderHealth?
    ) -> JSONValue {
        let executableRepairs = DoctorSafeRepairPolicy.executableCoreIDs(for: report.checks)
        let checks = report.checks.map { check in
            let repairAvailable = executableRepairs.contains(check.id)
                || (check.repair_available == true
                    && DoctorSafeRepairPolicy.isAdverse(check.status))
            var row: [String: JSONValue] = [
                "id": .string(check.id),
                "check_id": .string(check.checkID),
                "title": .string(check.title),
                "status": .string(check.status),
                "detail": .string(NativeAppSecretRedactor.redactText(boundedDoctorDetail(check.detail))),
                "repair_available": .bool(repairAvailable),
                "remedy": check.remedy ?? .null,
                "repair_face": .string(NativeAppSecretRedactor.redactText(check.repairFace)),
            ]
            if let harm = check.harm {
                row["harm"] = .string(NativeAppSecretRedactor.redactText(boundedDoctorDetail(harm)))
            }
            if check.remedy != nil {
                row["owner"] = check.repairOwner.map(JSONValue.string) ?? .null
            }
            if let action = check.recoveryAction(repairAvailable: repairAvailable) {
                row["human_action"] = .string(NativeAppSecretRedactor.redactText(boundedDoctorDetail(action)))
            }
            if let receipt = check.receipt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !receipt.isEmpty {
                row["receipt"] = .string(NativeAppSecretRedactor.redactText(boundedDoctorDetail(receipt)))
            }
            return JSONValue.object(row)
        }
        // The path is what a chat turn on this surface waits on: the provider
        // that answers it (live.providers), the memory store it recalls from
        // (live.memory), the prompt prefix it is sent with
        // (prompt_prefix_health) and the local bridges a bridge turn arrives
        // through (live.bridges). Every other row is real but serves something
        // else (a connector, a loop, a backup), so it shows in `status` and in
        // its row, never as a broken path. Credential eligibility alone cannot
        // prove a provider warning concerns another account or a working model.
        let pathIDs: Set<String> = ["live.providers", "live.memory", "prompt_prefix_health", "live.bridges"]
        let pathChecks = report.checks.filter { check in
            guard pathIDs.contains(check.checkID) else { return false }
            // Only the credential-owner reading names exactly which accounts
            // its warning concerns; active-model and probe warnings lack this
            // evidence and must stay on the path even with eligible credentials.
            if check.checkID == "live.providers", check.status.lowercased() == "warn",
               activeProvider?.eligible == true, let activeProviderID,
               let source = check.source, source.hasPrefix("Providers accounts: ") {
                let accounts = source.dropFirst("Providers accounts: ".count)
                    .components(separatedBy: ", ").filter { !$0.isEmpty }
                if !accounts.isEmpty, !accounts.contains(activeProviderID) { return false }
            }
            return true
        }
        var envelope: [String: JSONValue] = [
            "status": .string(report.status),
            "report_completed_at": completedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "active_path_status": .string(doctorRollup(pathChecks.map(\.status))),
            "active_path_check_ids": .array(pathChecks.map { .string($0.id) }),
            "active_provider_id": activeProviderID.map(JSONValue.string) ?? .null,
            // The receipt's own word (ready, saved, failed, rejected, needs_*).
            "active_provider_status": .string(activeProvider?.authState ?? "unknown"),
            "status_scope_note": .string("status rolls up every check; active_path_status rolls up only the checks a chat turn here depends on (active_path_check_ids); off, not needed and unmeasured rows never fail either"),
            "repaired": .bool(report.repaired),
            "check_count": .int(Int64(checks.count)),
            "checks": .array(checks),
        ]
        if let runningSince {
            envelope["run_in_progress"] = .string("A Doctor run started at \(ISO8601DateFormatter().string(from: runningSince)) is in progress; this report is from before it and is not current until it finishes.")
        }
        if activeProvider?.eligible == false, let activeProviderID {
            let target = InlineInteractionRegistry.canonicalProviderID(activeProviderID)
            envelope["next"] = .string("raise request_interaction kind=api_key target=\(target)")
        }
        return .object(envelope)
    }

    public static func telegramStatusEnvelope(status: some AppToolTelegramDiagnosticStatus, now: Date) -> JSONValue {
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
            "recent_receipt_ledger_entries": .int(Int64(status.receiptCount)),
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

    private static func telegramDiagnosticDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(raw)
    }

    public static func doctorRollup(_ statuses: [String]) -> String {
        DoctorStatusProjection.doctorRollup(statuses)
    }
}
