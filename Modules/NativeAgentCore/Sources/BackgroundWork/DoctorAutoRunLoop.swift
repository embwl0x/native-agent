import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import ChatSessionWork
import Context
import DoctorChecks
import PersistenceCore
import TurnTrace
import ApprovalInbox
import NotificationInbox
import MemoryV2
import DreamREMCycle
import AgentWorkspace
import Desk
import AttentionRouting
import Privacy
import ProviderRouting
import Experiences
import ToolRegistry
import Cognition
// Blueprint: | `DoctorAutoRunLoop.swift` | `DoctorAutoRunLoop` and configured factory; native Doctor ask eligibility and sticky cards with maintenance-assistance prose; Doctor and loop failures owe repair through DoctorReadout; config-bound loop restarts and honest outcomes |

extension MaintenanceBackgroundWork {
    /// Fresh measurements rebuild the memoizing behavioural checks.
    /// Event-driven measurements pass true; periodic sweeps retain the memo.
    public func makeAutoDoctorLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval? = nil,
        freshMeasurement: Bool = false
    ) -> some LoopRunner {
        let config = DoctorReadout.readAutoDoctorConfig(dataRoot: dataRoot)
        let configuredInterval = config.intervalSeconds
            .map(TimeInterval.init)
            .flatMap { $0.isFinite && $0 >= 3600 ? $0 : nil }
        let interval = intervalSeconds ?? configuredInterval ?? (7 * 24 * 60 * 60)
        let checks = makeDoctorChecks(root: dataRoot, freshMeasurement: freshMeasurement)
        return DoctorAutoRunLoop(
            interval: interval,
            configuration: config,
            runChecks: { try await port.runAutoDoctor(checks: checks, dataRoot: dataRoot) },
            storage: { dataRoot.appendingPathComponent("doctor", isDirectory: true) }
        )
    }

    /// What Doctor could not repair itself — sign-ins and permissions — goes
    /// to User as ONE inbox card listing every step. The card updates in place,
    /// keeps his read/dismiss status while the list is unchanged, and is
    /// archived and marked cleared once nothing is left to ask.
    public func fileDoctorAsk(dataRoot: URL, rows: [CheckResult]) async -> Bool {
        let cardID = "doctor-ask"
        let inbox = LiveNotificationInbox.live(dataRoot: dataRoot)
        let asks: [JSONValue] = rows.filter(DoctorSafeRepairPolicy.isUserAsk).compactMap { row in
            row.human_action.map { .object(["title": .string(row.title), "action": .string($0)]) }
        }
        do {
            guard !asks.isEmpty else {
                // Cleared whatever User did with the card (read, archived or
                // dismissed), so a recurrence surfaces fresh.
                let uncleared = try await inbox.rows().contains { row in
                    guard case .object(let card) = row, card["id"] == .string(cardID) else { return false }
                    return card["resolved_reason"] != .string("doctor_clear")
                }
                if uncleared {
                    try await inbox.updateStatus(id: cardID, status: "archived", readAt: nil,
                                                 metadata: ["resolved_reason": .string("doctor_clear")])
                }
                return true
            }
            let content = try await port.assistanceCard(dataRoot: dataRoot,
                input: .object(["kind": .string("doctor"), "asks": .array(asks)]))
            let detail = content.detail
            let now = ISO8601DateFormatter().string(from: Date())
            let title = content.title
            let newOccurrence = try await inbox.upsert(id: cardID) { existing in
                var card: [String: JSONValue] = [
                    "id": .string(cardID),
                    "created_at": .string(now),
                    "source": .string("doctor_ask"),
                    "severity": .string("actionable"),
                    "title": .string(title),
                    "summary": .string(content.summary),
                    "detail": .string(detail),
                    "related_mission_id": .null,
                    "related_approval_id": .null,
                    "related_paths": .array([]),
                    "related_groups": .array([]),
                    "actions": .array([
                        .object(["id": .string("archive"), "label": .string("Archive"),
                                 "description": .string("Archive this card")]),
                        .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                                 "description": .string("Dismiss this card")]),
                    ]),
                    "status": .string("unread"),
                    "read_at": .null,
                ]
                // Same list User already saw: keep his status, no resurfacing.
                if case .object(let previous)? = existing, previous["detail"] == .string(detail),
                   previous["resolved_reason"] != .string("doctor_clear") {
                    for key in ["status", "read_at", "created_at"] {
                        if let value = previous[key] { card[key] = value }
                    }
                    return (.object(card), false)
                }
                return (.object(card), true)
            }
            // Card filing acknowledges Doctor's transition independently of
            // transport acceptance. Unread failed sends remain eligible.
            do {
                guard let value = try await inbox.rows().first(where: {
                    if case .object(let card) = $0 { return card["id"] == .string(cardID) }
                    return false
                }), case .object(let card) = value, card["detail"] == .string(detail),
                    newOccurrence || card["status"] == .string("unread"),
                    case .string(let createdAt)? = card["created_at"] else { return true }
                let eventID = "\(cardID):\(createdAt):\(AttentionRouter.stableDigest(detail))"
                try await port.routeDoctorAsk(eventID: eventID, title: title, detail: detail)
            } catch {
                nativeLog("[Doctor] sign-in ask push failed: %@", error.localizedDescription)
            }
            return true
        } catch {
            nativeLog("[Doctor] sign-in ask card write failed: %@", error.localizedDescription)
            return false
        }
    }
}

/// Writes bounded Doctor results to `doctor/latest.json` through DoctorReadout.
///
/// tick() remains non-throwing, but doctor or storage failure is a typed failed
/// outcome. A transient error may recover next tick; hiding it as success would
/// make the health owner lie about the body it is meant to inspect.
public struct DoctorAutoRunLoop: LoopRunner {
    public let loopId: String = "doctor_auto_run"
    public let interval: TimeInterval
    private let configuration: AutoDoctorConfig
    private let runChecks: @Sendable () async throws -> [CheckResult]
    private let storage: @Sendable () async throws -> URL

    /// `storage` returns the directory that will hold `latest.json`. Default
    /// resolves to `<defaultDataRoot()>/doctor`. The closure is async/throws
    /// so callers can plug in env-derived roots or mkdir-on-demand logic
    /// without forcing the work onto every callsite.
    public init(
        interval: TimeInterval,
        configuration: AutoDoctorConfig = .init(),
        runChecks: @escaping @Sendable () async throws -> [CheckResult],
        storage: @escaping @Sendable () async throws -> URL = { defaultDoctorStorageDir() }
    ) {
        self.interval = interval
        self.configuration = configuration
        self.runChecks = runChecks
        self.storage = storage
    }

    public func tickOutcome() async -> LoopTickOutcome {
        if let error = configuration.readError { return .failed(error: error) }
        guard configuration.enabled != false else { return .off("auto doctor disabled") }
        do {
            // Measurement age starts before checks; runAt remains the snapshot write time.
            let measuredAt = Date()
            let results = try await runChecks()
            // No checks ran ⇒ nothing was inspected. Persisting `{"checks":[]}`
            // would be worse than useless: every reader derives "healthy" from
            // "no check has status fail", so an empty snapshot reads as a clean
            // bill of health for a body nobody examined.
            guard !results.isEmpty else {
                return .skipped(reason: "no Doctor checks ran: none produced a result, or another Doctor run was in flight")
            }
            let dir = try await storage()
            // Two clocks, never one: `runAt` is when this file was written,
            // `measuredAt` when the checks were asked — the age of the findings.
            let formatter = ISO8601DateFormatter()
            try await DoctorReadout.persistDoctorSnapshot(
                results, to: dir.appendingPathComponent("latest.json"),
                runAt: formatter.string(from: Date()), measuredAt: formatter.string(from: measuredAt))
            return .completed(result: "doctor snapshot persisted (\(results.count) check(s))")
        } catch {
            FileHandle.standardError.write(Data("DoctorAutoRunLoop: tick failed: \(error)\n".utf8))
            return .failed(error: String(describing: error))
        }
    }
}

/// Default storage directory for DoctorAutoRunLoop's latest.json output.
public func defaultDoctorStorageDir() -> URL {
    defaultDataRoot().appendingPathComponent("doctor", isDirectory: true)
}

public extension MaintenanceBackgroundWork {
    static let hotReloadableLoopIDs: Set<String> = [
        "telegram_poll", "slack_socket_mode", "doctor_auto_run",
    ]

    /// Rebuild only config-bound registrations; a relaunch-bound loop cannot
    /// report a restart without changing its captured configuration.
    @discardableResult
    static func restartLoop(
        id: String,
        manager: BackgroundLoops.BackgroundLoopLifetimes,
        replacementLoop: @escaping @Sendable (String) -> LoopRegistration?
    ) async -> LoopRestartOutcome {
        let registered = await manager.registered().contains(id)
        guard hotReloadableLoopIDs.contains(id) else {
            return registered ? .requiresRelaunch(loopId: id) : .unknown(loopId: id)
        }
        await manager.restartLoop(id: id) { replacementLoop(id) }
        return await manager.registered().contains(id)
            ? .restarted(loopId: id)
            : .unknown(loopId: id)
    }

    /// A failed run alone is an observation, not a durable fault to repair.
    static func fileLoopFailureNotice(dataRoot: URL, loopId: String, error: String) async {
        let fix = loopSettingFix(loopId: loopId, error: error)
        await DoctorReadout.recordReadings([CheckResult(source: fix?.step ?? "Background loop registration: " + loopId,
            id: DoctorLoopRecovery.checkPrefix + loopId, title: "Background loop: " + loopId,
            status: fix?.ask == nil ? "unmeasured" : "fail", detail: loopFailureCause(error),
            human_action: fix?.step, ask: fix?.ask, owner: nil)], dataRoot: dataRoot)
    }

    /// The error as one plain clause: the human text out of an NSError dump
    /// (`Error Domain=X Code=N "text" UserInfo={…}`, quotes escaped or not),
    /// first line, redacted.
    static func loopFailureCause(_ error: String) -> String {
        if isTelegramTokenRejected(error) { return "Telegram rejected the bot token" }
        var text = NativeAppSecretRedactor.redactText(error)
        if let match = text.range(of: #"Code=-?\d+ \\?"[^"\\]+"#, options: .regularExpression),
           let quote = text[match].firstIndex(of: "\"") {
            text = String(text[text.index(after: quote)..<match.upperBound])
        }
        text = text.components(separatedBy: " UserInfo=")[0]
            .components(separatedBy: .newlines)[0]
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if text.hasPrefix("timeout after ") {
            return "a run did not finish within its \(text.dropFirst("timeout after ".count)) limit"
        }
        return text.isEmpty ? "it reported no reason" : String(text.prefix(160))
    }

    /// Telegram answers a bad bot token with 401, which the poll reports as
    /// `TelegramBotError.notConfigured` ("Telegram long poll: notConfigured").
    static func isTelegramTokenRejected(_ error: String) -> Bool {
        error.lowercased().contains("telegram") && error.contains("notConfigured")
    }

    /// The recovery step for a loop's failure, and whether it is a sign-in or
    /// a permission; nil when no specific step is known. The failure card and Doctor's
    /// loop row both read it, so they never disagree.
    static func loopSettingFix(loopId: String, error: String) -> (step: String, ask: DoctorAskKind?)? {
        let e = error.lowercased()
        if loopId == "offdisk_backup", e.contains("backup-cadence part failed (") { return (backupCadenceRepairStep, nil) }
        if loopId == "offdisk_backup", e.contains("icloud drive") { return (DoctorLoopHealth.iCloudDriveStep, .permission) }
        if loopId == "telegram_poll", isTelegramTokenRejected(error) || e.contains("unauthoriz") || e.contains("token") {
            return ("Telegram → Bot token → Bot token, then Save.", .signIn)
        }
        if loopId == "slack_socket_mode", e.contains("auth") || e.contains("token") {
            return ("Connectors → Slack → Bot or user token and App token, to chat with me in Slack → Save token.", .signIn)
        }
        if e.contains("no space left") { return ("System Settings → General → Storage: review files and choose what to remove.", .permission) }
        if e.contains("permission denied") || e.contains("not permitted") {
            return ("Give this user read and write access to NativeAgent's data folder in Finder → Get Info → Sharing & Permissions.", .permission)
        }
        return nil
    }

    @discardableResult
    static func resolveLoopFailureNotice(
        dataRoot: URL, loopId: String, healthyAt: Date
    ) async -> Bool {
        do {
            let operation = "operation: doctor.check:" + DoctorLoopRecovery.checkPrefix + loopId
            let owed = try await ExperienceStore.at(dataRoot).projection().filter {
                $0.owes["repair"]?.phase.isSettled == false && $0.claims.contains { $0.claim == operation }
            }
            guard owed.allSatisfy({
                guard let at = NativeTimestampFormat.parseISO8601FractionalFirst($0.at) else { return false }
                return healthyAt > at
            }) else { return false }
        } catch { return false }
        await DoctorReadout.recordReadings([CheckResult(
            id: DoctorLoopRecovery.checkPrefix + loopId, title: "Background loop: " + loopId,
            status: "ok", detail: "Successful work at " + ISO8601DateFormatter().string(from: healthyAt))], dataRoot: dataRoot)
        return true
    }
}

/// Honest result of `BackgroundLoopLifetimes.restartLoop(id:)`.
///
/// `.restarted` is the only outcome that means the running loop now reflects
/// the config on disk. `.requiresRelaunch` means the loop is alive but still
/// running its launch-time configuration. `.unknown` means this manager has no
/// such loop registered (or the rebuild left it unregistered) — nothing can be
/// promised about it either way.
public enum LoopRestartOutcome: Sendable, Equatable {
    case restarted(loopId: String)
    case requiresRelaunch(loopId: String)
    case unknown(loopId: String)

    public var didRestart: Bool {
        if case .restarted = self { return true }
        return false
    }

    public var loopId: String {
        switch self {
        case .restarted(let id), .requiresRelaunch(let id), .unknown(let id):
            return id
        }
    }

    /// User-facing sentence for a surface that just asked for a restart.
    /// `nil` when the restart actually happened and there is nothing to say.
    public var surfaceMessage: String? {
        switch self {
        case .restarted:
            return nil
        case .requiresRelaunch(let id):
            return "The \(id) loop keeps its launch-time settings until you relaunch NativeAgent."
        case .unknown(let id):
            return "No running \(id) loop to reconfigure — relaunch NativeAgent to pick up the change."
        }
    }
}
