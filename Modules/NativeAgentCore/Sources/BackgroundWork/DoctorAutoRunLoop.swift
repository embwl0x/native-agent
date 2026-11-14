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
// Blueprint: | `DoctorAutoRunLoop.swift` | Doctor asks are episodes in ForPerson; measured source checks clear them |

extension MaintenanceBackgroundWork {
    /// Event-driven measurements rebuild memoized checks; the Doctor's rhythm retains the memo.
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

    /// One episode groups the steps the person must take; a measured clear ends it before any later recurrence.
    public func fileDoctorAsk(dataRoot: URL, rows: [CheckResult]) async -> Bool {
        // No measurements cannot prove the previous condition cleared.
        guard !rows.isEmpty else { nativeLog("[Doctor] ask clearance unavailable: no checks measured"); return false }
        do {
            let previous = try await ForPerson.at(dataRoot).matters().first { $0.face?.from == "doctor_ask" }
            if let previous, previous.progress != "resolved", previous.outcome?.domain != "doctor_ask" {
                let watched = previous.evidence.filter { $0.source == "doctor/latest.json" }.map(\.id)
                guard !watched.isEmpty, watched.allSatisfy({ id in
                    rows.contains { $0.id == id && ["healthy", "warning", "failing"].contains(DoctorPlainCopy.bucket(for: $0.status)) }
                }) else {
                    nativeLog("[Doctor] ask episode kept: its source checks are missing or unmeasured")
                    return false
                }
            }
            let requested = rows.filter(DoctorSafeRepairPolicy.isUserAsk).sorted { $0.id < $1.id }
            let asks: [JSONValue] = try requested.map { row in
                guard let action = row.human_action, !action.isEmpty else { throw JSONRow.Malformed.field("human_action") }
                return .object(["title": .string(row.title), "action": .string(action)])
            }
            guard !asks.isEmpty else {
                if let previous, previous.outcome?.domain != "doctor_ask", previous.progress != "resolved" {
                    let watched = previous.evidence.filter { $0.source == "doctor/latest.json" }.map(\.id)
                    guard watched.allSatisfy({ id in rows.contains { $0.id == id && DoctorPlainCopy.bucket(for: $0.status) == "healthy" } })
                    else {
                        nativeLog("[Doctor] ask episode kept: its source checks have not measured recovery")
                        return false
                    }
                }
                try await BodyNotice.resolve(key: "doctor-ask", from: "doctor_ask", dataRoot: dataRoot)
                return true
            }
            let content = try await port.assistanceCard(dataRoot: dataRoot,
                input: .object(["kind": .string("doctor"), "asks": .array(asks)]))
            try await BodyNotice.tell(key: "doctor-ask", from: "doctor_ask",
                finding: try JSONValue.array(requested.map { .string($0.id) } + asks).serialize(pretty: false), dataRoot: dataRoot) { id in
                try await port.tell(Matter(id: id, form: .ask, from: "doctor_ask",
                    title: content.title, summary: content.summary, words: content.detail,
                    open: "page:doctor", choices: [.init(id: "archive", label: "Archive"), .init(id: "dismiss", label: "Dismiss")],
                    evidence: requested.map { .init(source: "doctor/latest.json", id: $0.id) }),
                    dataRoot: dataRoot, reach: .person(from: nil), turn: nil)
            }
            return true
        } catch {
            nativeLog("[Doctor] sign-in ask could not be told: %@", error.localizedDescription)
            return false
        }
    }
}

/// Doctor or storage failure must return a failed outcome; hiding it as success would falsify health.
public struct DoctorAutoRunLoop: LoopRunner {
    public let loopId: String = "doctor_auto_run"
    public let wake: OrganWake
    /// Its readings judge the agent's persona, memory and profile and file asks for it; with no agent yet there is nothing to judge.
    public var needsAgent: Bool { true }
    private let configuration: AutoDoctorConfig
    private let runChecks: @Sendable () async throws -> [CheckResult]
    private let storage: @Sendable () async throws -> URL

    /// Async throwing storage resolution supports lazy root creation without forcing it onto every caller.
    public init(
        interval: TimeInterval,
        configuration: AutoDoctorConfig = .init(),
        runChecks: @escaping @Sendable () async throws -> [CheckResult],
        storage: @escaping @Sendable () async throws -> URL = { defaultDoctorStorageDir() }
    ) {
        self.wake = .every(interval)
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
            // Readers derive health from checks; an empty unmeasured snapshot would falsely appear healthy.
            guard !results.isEmpty else {
                return .skipped(reason: "no Doctor checks ran: none produced a result, or another Doctor run was in flight")
            }
            let dir = try await storage()
            // Snapshot publication time and measurement age are distinct clocks.
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

    /// Redact the first plain error clause so NSError metadata cannot leak through the card.
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

    /// Shared recovery wording keeps the failure card and Doctor row consistent; unknown remedies remain nil.
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
            let operation = "doctor.check:" + DoctorLoopRecovery.checkPrefix + loopId
            let owed = try await ExperienceStore.at(dataRoot).projection().filter {
                $0.owes["repair"]?.phase.isSettled == false && RepairDebt($0).operation == operation
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

/// Only restarted proves current configuration is running. Relaunch-required retains captured configuration;
/// unknown registration proves neither a live loop nor its absence.
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

    /// A successful restart needs no user-facing warning.
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
