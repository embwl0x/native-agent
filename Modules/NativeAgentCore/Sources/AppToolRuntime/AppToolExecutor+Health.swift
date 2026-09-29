import Foundation
import ChatOrchestration
import DoctorChecks
import NativeAgentCore
import PersistenceCore
import Privacy
import ProviderRouting
import ToolRegistry

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

public struct AppToolProviderHealth: Sendable {
    public let providerID: String
    public let authState: String

    public init(providerID: String, authState: String) {
        self.providerID = providerID
        self.authState = authState
    }
}

extension AppToolExecutor {
    public static func doctorStatus(
        report: some AppToolDoctorReport,
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
        let activeProviderReady = activeProviderID.flatMap { providerID in
            providers?
                .first(where: { $0.providerID == providerID })
                .map { $0.authState.lowercased() == "ready" }
        }
        return doctorStatusEnvelope(
            report: report,
            activeProviderID: activeProviderID,
            activeProviderReady: activeProviderReady
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

    public static func doctorStatusEnvelope(
        report: some AppToolDoctorReport,
        activeProviderID: String?,
        activeProviderReady: Bool?
    ) -> JSONValue {
        let repairHandlers = Set(SwiftNativeDoctorChecks.defaultChecks.compactMap { check in
            check is any RepairingDoctorCheck ? check.id : nil
        })
        let executableRepairs = Set(DoctorSafeRepairPolicy.checkIDs(for: report.checks))
            .intersection(repairHandlers)
        let checks = report.checks.map { check in
            let repairAvailable = executableRepairs.contains(check.id)
                || (check.id.hasPrefix("live.") && check.repair_available == true
                    && DoctorSafeRepairPolicy.isAdverse(check.status))
            var row: [String: JSONValue] = [
                "id": .string(check.id),
                "title": .string(check.title),
                "status": .string(check.status),
                "detail": .string(NativeAppSecretRedactor.redactText(boundedDoctorDetail(check.detail))),
                "repair_available": .bool(repairAvailable),
            ]
            if let action = check.recoveryAction(repairAvailable: repairAvailable) {
                row["human_action"] = .string(NativeAppSecretRedactor.redactText(boundedDoctorDetail(action)))
            }
            if let receipt = check.receipt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !receipt.isEmpty {
                row["receipt"] = .string(NativeAppSecretRedactor.redactText(boundedDoctorDetail(receipt)))
            }
            return JSONValue.object(row)
        }
        let maintenanceIDs = Set(["oauth_token_expiry"])
        let activeProviderIsReady = activeProviderReady == true
        let maintenanceChecks = report.checks.filter { check in
            if maintenanceIDs.contains(check.id) { return true }
            return check.id == "live.providers"
                && check.status.lowercased() == "warn"
                && activeProviderIsReady
        }
        let maintenanceCheckIDs = Set(maintenanceChecks.map(\.id))
        let activeChecks = report.checks.filter { !maintenanceCheckIDs.contains($0.id) }
        let activePathStatus = doctorRollup(activeChecks.map(\.status))
        let maintenanceStatus = doctorRollup(maintenanceChecks.map(\.status))
        let providerStatus: String = switch activeProviderReady {
        case true: "ready"
        case false: "not_ready"
        case nil: "unknown"
        }
        var envelope: [String: JSONValue] = [
            "status": .string(report.status),
            "active_path_status": .string(activePathStatus),
            "maintenance_status": .string(maintenanceStatus),
            "active_provider_id": activeProviderID.map(JSONValue.string) ?? .null,
            "active_provider_status": .string(providerStatus),
            "status_scope_note": .string("status is the global Doctor rollup; active_path_status is the independently classified path serving this surface; maintenance warnings remain visible in checks"),
            "repaired": .bool(report.repaired),
            "check_count": .int(Int64(checks.count)),
            "active_path_check_count": .int(Int64(activeChecks.count)),
            "maintenance_check_count": .int(Int64(maintenanceChecks.count)),
            "maintenance_check_ids": .array(maintenanceChecks.map { .string($0.id) }),
            "checks": .array(checks),
        ]
        if activeProviderReady == false, let activeProviderID {
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
            .string(NativeAppSecretRedactor.redactText(String($0.prefix(600))))
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
