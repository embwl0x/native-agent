import Privacy
import Foundation
import MemoryV2
import NativeAgentCore
import NativeAgentShared
import BackgroundLoops
import PersistenceCore
import DoctorChecks
import BackgroundWork
import Cognition
import ProviderRouting
import MacControl
import Research
import AgentConversations
import AgentWorkspace
import Synchronization
import Experiences
import TelegramBot
// Blueprint: | `EngineDoctorRuntime.swift` | EngineDoctorRuntime and EngineDoctorPlatformPort own live health interpretation, repair admission, Support Snapshot reuse and pending-transition wake; one manager/receipt read supplies both the loop check and DoctorFacade verdicts. |

/// Platform observations and callbacks; Doctor owns interpretation and repair admission.
public protocol EngineDoctorPlatformPort: Sendable {
    var doctorEngine: NativeAgentEngine { get }
    var doctorManager: BackgroundLoops.BackgroundLoopsManager { get }
    func doctorRestartLoop(id: String) async -> LoopRestartOutcome
    func doctorRepairPhoneSync() async -> DoctorRepairAttempt?
    func doctorStartBridge(name: String) async
    func doctorInspectorRepair(for check: CheckResult) async -> DoctorExecutableRepair?
    func doctorBridgeSnapshots() async -> [DoctorBridgeSnapshot]
    func doctorInspectorCheck() async -> CheckResult
}

/// Live health and repair policy for the engine's mounted owners.
public struct EngineDoctorRuntime<Port: EngineDoctorPlatformPort>: DoctorActionPort {
    let port: Port
    public let dataRoot: URL

    public init(dataRoot: URL, port: Port) {
        self.dataRoot = dataRoot
        self.port = port
    }

    private var doctorActions: DoctorActionRuntime<EngineDoctorRuntime<Port>> {
        DoctorActionRuntime(port: self)
    }

    /// Every Doctor run ends here — the automatic one, Run, Repair — so each
    /// adverse row takes its owner's route and healed rows resolve.
    public func runDoctor(repair: Bool = false, repairScope: DoctorRepairScope = .automatic,
                   checks: (any DoctorChecksProtocol)? = nil, checkID: String? = nil) async throws -> DoctorReport {
        let result = try await doctorActions.runDoctor(repair: repair, repairScope: repairScope, checks: checks ?? makeDoctorChecks(root: dataRoot), checkID: checkID)
        await DoctorStatusProjection.recordReadings(result.checks, dataRoot: dataRoot)
        let rows = await DoctorStatusProjection.repairProjection(result.checks, dataRoot: dataRoot)
        if !rows.contains(where: { $0.id == "doctor.repair_store" }) {
            _ = await MaintenanceBackgroundWork(port: EngineBackgroundWorkPort())
                .fileDoctorAsk(dataRoot: dataRoot, rows: rows)
        }
        return DoctorReport(status: result.status, repaired: result.repaired, checks: result.checks)
    }

    public func liveDoctorCoverageChecks() async -> [CheckResult] {
        let rows = await doctorActions.liveDoctorCoverageChecks()
        await DoctorStatusProjection.recordReadings(rows, dataRoot: dataRoot)
        return rows
    }

    public static func safeDetail(_ value: String) -> String {
        DoctorActionRuntime<EngineDoctorRuntime<Port>>.safeDetail(value, redact: NativeAppSecretRedactor.redactText)
    }

    public static func mergeReport(_ current: DoctorReport, liveChecks: [CheckResult]) -> DoctorReport {
        let result = DoctorActionRuntime<EngineDoctorRuntime<Port>>.mergeReport(
            currentChecks: current.checks, liveChecks: liveChecks
        )
        return DoctorReport(status: result.status, repaired: current.repaired, checks: result.checks)
    }
}

extension EngineDoctorRuntime {
    public static var supportSnapshotDoctorReuseTTL: TimeInterval { 90 }

    public func doctorEmbeddingDownloadCheck() async -> CheckResult {
        await DoctorEmbeddingDownloadCheck.read(dataRoot: dataRoot)
    }

    public func doctorProviderAuthStates() async throws -> [(state: String, eligible: Bool)] {
        try await ProvidersFacade(dataRoot: dataRoot)
            .list().map { ($0.auth_status.state, $0.auth_status.eligible) }
    }

    public func doctorProviderRuntimeReading() async -> DoctorProviderRuntimeReading {
        await DoctorProviderPathReading.read(dataRoot: dataRoot)
    }

    public func doctorDataRootCheck() -> CheckResult {
        let marker = dataRoot.appendingPathComponent("install").appendingPathComponent(InstallPaths.publicReleaseDataMarker)
        do {
            let data = try Data(contentsOf: marker)
            guard let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reason = saved["reason"] as? String,
                  ["public_release_blank_slate_first_run", "public_release_marker_written_in_place"].contains(reason),
                  reason != "public_release_blank_slate_first_run" || (saved["backupPath"] as? String)?.isEmpty == false else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            if reason == "public_release_blank_slate_first_run", let backup = saved["backupPath"] as? String,
               FileManager.default.fileExists(atPath: backup) {
                return CheckResult(source: marker.path,
                    id: "install.data_root", title: "Data root", status: "ok",
                    detail: "An earlier launch moved saved data to the recorded backup location: \(backup).")
            }
        } catch CocoaError.fileReadNoSuchFile {
            return CheckResult(source: marker.path, id: "install.data_root", title: "Data root", status: "ok",
                detail: "No earlier data-root move marker exists at \(marker.path).")
        } catch {
            return CheckResult(source: marker.path,
                id: "install.data_root", title: "Data root", status: "fail",
                detail: "The data-root move marker is unreadable or malformed: \(marker.path).",
                human_action: ToolFailureError.fileRepairInstruction(marker,
                    shape: "This JSON object records installation history, including its reason and any earlier data-root move's backupPath. Preserve the original history and backup location; never invent a move or backup."))
        }
        return CheckResult(source: marker.path,id: "install.data_root", title: "Data root", status: "ok",
                           detail: "No existing backup from an earlier data-root move was found.")
    }

    public func doctorTelegramSnapshot() async throws -> DoctorTelegramSnapshot {
        let manager = port.doctorManager
        let status = try await TelegramFacade(
            dataRoot: dataRoot
        ).load(manager: manager)
        let now = Date()
        let uptime = await manager.uptimeSeconds(now: now)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let pollDate = status.lastPollAt.flatMap {
            formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
        }
        // A normal poll holds up to 25 seconds, then waits for the next tick.
        // Require both current-manager-lifecycle evidence and a bounded age.
        let fresh = pollDate.map {
            let age = now.timeIntervalSince($0)
            return age >= 0 && age <= 35 && age < uptime
        } ?? false
        let starting = status.pollerEnabled && uptime > 0 && uptime <= 35 && !fresh
        return (status.enabled, status.tokenConfigured, status.isTransientPollInterruption, status.actionableError, status.pollerEnabled, fresh, starting)
    }

    public func doctorSearchURL() async throws -> String? {
        try SwiftNativeResearchClient.checkedSearxngBaseURL(root: dataRoot)
    }

    public func doctorProbeSearch(base: String) async -> Bool {
        await SwiftNativeResearchClient(dataRoot: dataRoot)
            .checkSearXNG(base: base, answering: true)
    }

    /// Doctor state: the local SearXNG URL for which Docker was checked and
    /// holds no SearXNG container. Automatic runs leave Docker Desktop closed
    /// until the URL changes or Repair is pressed.
    private var searchBackendAbsentPath: URL {
        dataRoot
            .appendingPathComponent("doctor/search_backend_absent.json")
    }

    public func doctorSearchBackendAbsent(base: String) -> Bool {
        guard let data = try? Data(contentsOf: searchBackendAbsentPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["base"] as? String == base
    }

    public func doctorRecordRepair(checkID: String, receipt: String, status: String) async throws {
        let path = dataRoot
            .appendingPathComponent("doctor/repair_receipts.jsonl")
        try await SwiftNativePersistenceCore().appendJSONL(.object([
            "at": .string(ISO8601DateFormatter().string(from: Date())),
            "check_id": .string(checkID), "receipt": .string(receipt), "status": .string(status),
        ]), to: path)
    }

    public func doctorLiveRepair(for check: CheckResult, scope: DoctorRepairScope) async -> DoctorExecutableRepair? {
        guard check.ask == nil else { return nil }
        let requestedRoot = dataRoot
        guard requestedRoot.resolvingSymlinksInPath().standardizedFileURL
            == PersistenceCore.defaultDataRoot().resolvingSymlinksInPath().standardizedFileURL else { return nil }
        switch check.id {
        case "icloud_bridge_state":
            guard check.owner != .builder else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                await port.doctorRepairPhoneSync() ?? .unverified("Phone sync has no mounted transport; repair remains owed.")
            }
        case "live.memory":
            guard !check.detail.hasPrefix("quick_check on ") else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                try await SwiftNativeMemoryV2.shared.repairCanonicalAttachment()
                return .completed("Completed: attached the canonical memory store and reconciled its knowledge graph.")
            }
        case "live.providers":
            let pendingPath = requestedRoot.appendingPathComponent("providers/pending-surface-configuration.json")
            let pendingSelection = FileManager.default.fileExists(atPath: pendingPath.path)
            let needsProbe: Bool
            switch await doctorProviderRuntimeReading() {
            case .healthy(.stale), .healthy(.failed): needsProbe = true
            default: needsProbe = false
            }
            guard pendingSelection || needsProbe else { return nil }
            if !pendingSelection {
                guard let snapshot = try? await SwiftNativeProviderRouting(dataRoot: requestedRoot)
                    .checkedRoutingSnapshotReadOnly(),
                    ProviderRoutingSurfaceLookup.value(snapshot.activeProviders, "chat") != nil else { return nil }
            }
            return DoctorExecutableRepair(checkID: check.id) {
                do {
                    let routing = SwiftNativeProviderRouting(dataRoot: requestedRoot)
                    let snapshot = try await (FileManager.default.fileExists(atPath: pendingPath.path)
                        ? routing.checkedRoutingSnapshot()
                        : routing.checkedRoutingSnapshotReadOnly())
                    guard let providerID = ProviderRoutingSurfaceLookup.value(snapshot.activeProviders, "chat") else {
                        let row = await doctorActions.providerDoctorCoverageCheck()
                        return .unverified("Repair could not test the active provider: \(row.detail)")
                    }
                    let test = try await ProvidersFacade(dataRoot: requestedRoot).testProvider(providerID)
                    // Same verdict the Providers page uses for Test Connection.
                    guard test.tested && test.status == "ok" else {
                        return .unverified("Repair attempted: the \(providerID) connection test did not pass: \(Self.safeDetail(test.detail ?? test.error ?? test.status))")
                    }
                    let row = await doctorActions.providerDoctorCoverageCheck()
                    return row.status == "ok"
                        ? .completed("Completed: recovered provider selection if needed and checked the active provider connection.")
                        : .unverified("Repair attempted: \(row.detail)")
                } catch {
                    let row = await doctorActions.providerDoctorCoverageCheck()
                    return .unverified("Repair could not finish: \(Self.safeDetail(error.localizedDescription)) \(row.detail)")
                }
            }
        case "live.inspector_feed":
            return await port.doctorInspectorRepair(for: check)
        case DoctorEmbeddingDownloadCheck.id:
            return await DoctorEmbeddingDownloadCheck.repair(dataRoot: requestedRoot, scope: scope)
        case "live.search":
            guard let base = (try? await doctorSearchURL())?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !base.isEmpty else { return nil }
            let mayOpenDockerDesktop = scope == .button || !doctorSearchBackendAbsent(base: base)
            let absentPath = searchBackendAbsentPath
            return DoctorExecutableRepair(checkID: check.id) {
                let research = SwiftNativeResearchClient(dataRoot: requestedRoot)
                // A SearXNG already answering (common port or running
                // container) becomes the search URL.
                let found = try await research.autodetectSearXNG()
                if found.found, let url = found.baseURL {
                    try? FileManager.default.removeItem(at: absentPath)
                    return .completed("Completed: SearXNG answers at \(url); search now uses it.")
                }
                // Otherwise start the stopped local container behind the configured URL.
                let container: String
                do {
                    container = try await SystemDockerPSExecutor()
                        .startLocalSearXNG(base: base, mayOpenDockerDesktop: mayOpenDockerDesktop)
                } catch let error as SearXNGStartError where error.noBackend {
                    try await SwiftNativePersistenceCore().writeJSON(.object([
                        "base": .string(base), "at": .string(ISO8601DateFormatter().string(from: Date())),
                    ]), to: absentPath)
                    return .unverified("No search backend: nothing answers at \(base). \(error.message)")
                } catch {
                    return .unverified("Web search is down: nothing answers at \(base). \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: absentPath)
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                repeat {
                    try await Task.sleep(for: .seconds(2))
                    if await research.checkSearXNG(base: base) {
                        return .completed("Completed: started the local SearXNG container \(container.prefix(12)); search answers at \(base).")
                    }
                } while ContinuousClock.now < deadline
                return .unverified("Started the local SearXNG container \(container.prefix(12)), but \(base) did not answer within 30 seconds.")
            }
        case "live.background_loops":
            return nil
        case "live.telegram":
            guard let state = try? await doctorTelegramSnapshot(), state.enabled,
                  state.tokenConfigured, !state.pollerEnabled else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                let facade = TelegramFacade(dataRoot: dataRoot)
                let manager = port.doctorManager
                // The poll notice and the state file it then clears both wake the check.
                let events = EventDeadlinePhysiology.storeAndFileEvents(
                    paths: [dataRoot.appendingPathComponent("telegram/state.json")],
                    notifications: [TelegramLongPollSession.successfulPoll])
                let before = try await facade.load(manager: manager)
                try Task.checkCancellation()
                guard before.enabled, before.tokenConfigured else {
                    return .unverified("Repair skipped: Telegram configuration changed.")
                }
                let registered = await manager.registered()
                try Task.checkCancellation()
                if !registered.contains("telegram_poll") {
                    let outcome = await port.doctorRestartLoop(id: "telegram_poll")
                    try Task.checkCancellation()
                    guard outcome.didRestart else {
                        return .unverified("Repair failed: \(outcome.surfaceMessage ?? "Telegram poller could not restart.")")
                    }
                }
                _ = await manager.start()
                try Task.checkCancellation()
                // Observe the owner's ordinary bounded long poll, never send
                // a second getUpdates request or force a duplicate tick.
                let result = await raceAgainstTimeout(seconds: 35) {
                    var iterator = events.makeAsyncIterator()
                    repeat {
                        try Task.checkCancellation()
                        let after = try await facade.load(manager: manager)
                        try Task.checkCancellation()
                        if after.lastPollAt != nil, after.lastPollAt != before.lastPollAt,
                           after.pollerEnabled, after.actionableError == nil { return true }
                    } while await iterator.next() != nil
                    return false
                }
                if case .value(true) = result {
                    return .completed("Completed: restarted Telegram's poller and confirmed a successful poll.")
                }
                if case .failure(let detail) = result { throw TelegramBotError.underlying(detail) }
                if case .cancelled = result { throw CancellationError() }
                return .unverified("Repair attempted: Telegram's poller was started, but no successful poll was confirmed within 35 seconds.")
            }
        case "live.bridges":
            let names = await doctorBridgeSnapshots().filter {
                $0.expected && $0.health.boundPort == nil && !$0.health.isActive
            }.map(\.name)
            guard !names.isEmpty else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                // The bridges publish their descriptors from their ready callbacks.
                // Watch those existing transitions, then read authoritative listener health.
                let changes = FileChangeEvents(paths: [
                    AgentHostDirectory.bridgeDiscoveryDirectory(dataRoot: dataRoot).appendingPathComponent("bridge.json"),
                    dataRoot.appendingPathComponent("browser_ipc.json"),
                ])
                defer { changes.cancel() }
                await changes.waitUntilArmed()
                try Task.checkCancellation()
                // Start methods retain their own gates, callbacks and tokens.
                for name in names {
                    try Task.checkCancellation()
                    await port.doctorStartBridge(name: name)
                }
                try Task.checkCancellation()
                let result = await raceAgainstTimeout(seconds: 3) {
                    var iterator = changes.stream.makeAsyncIterator()
                    repeat {
                        try Task.checkCancellation()
                        let rows = await doctorBridgeSnapshots().filter { names.contains($0.name) }
                        try Task.checkCancellation()
                        if rows.allSatisfy({ $0.health.boundPort != nil }) { return true }
                    } while await iterator.next() != nil
                    return false
                }
                if case .value(true) = result {
                    return .completed("Completed: rebound \(names.joined(separator: ", ")) and verified the listening ports.")
                }
                if case .cancelled = result { throw CancellationError() }
                return .unverified("Repair attempted: \(names.joined(separator: ", ")) did not confirm a bound port within 3 seconds.")
            }
        case DoctorLoopHealth.doctorCheckID:
            return await DoctorLoopHealth.safeRepair(manager: port.doctorManager)
        case let id where id.hasPrefix(DoctorLoopRecovery.checkPrefix):
            return await DoctorLoopRecovery.repair(
                checkID: check.id,
                manager: port.doctorManager,
                dataRoot: requestedRoot,
                restart: { await port.doctorRestartLoop(id: $0) }
            )
        default: return await doctorCognitionRepair(for: check)
        }
    }

    public func doctorToolSnapshots() async throws -> [DoctorToolSnapshot] {
        try await ToolsFacade(dataRoot: dataRoot).listAuthored().map { ($0.status, $0.name) }
    }

    public func doctorAutonomySnapshot() async throws -> DoctorAutonomySnapshot {
        let root = dataRoot
        let status = try await RuntimeReadProjection.getAutonomyKernel(
            dataRoot: root)
        return (status.enabled, status.disabledReason, status.status, status.mode, status.runningImprovements)
    }

    public func doctorBridgeSnapshots() async -> [DoctorBridgeSnapshot] {
        await port.doctorBridgeSnapshots()
    }

    public func doctorAgentConnectionsCheck() async -> CheckResult {
        let root = dataRoot
        await AgentContactHealth.shared.refresh(dataRoot: root)
        var source = "agents/peers.json"
        do {
            let peers = try AgentPeerStore(dataRoot: root).list()
            source = "agents/conversations.json"
            _ = try AgentConversationStore(dataRoot: root).recordsUnlocked()
            source = "agents/local-health.json"
            _ = try AgentLocalHealth.checkedRead(root)
            var problems: [String] = AgentContactHealth.read(dataRoot: root).sorted { $0.key < $1.key }.compactMap { agent, health in
                guard health.isBroken else { return nil }
                return health.problem.map { (peers.first { "peer:" + $0.id == agent }?.name ?? agent) + ": " + $0 }
            }
            // A message waiting for its recipient's session is owed, not damage; only
            // an agent connection that owes repair is a problem here. This row measures;
            // each owed obligation projects its own remedy, so none is copied here.
            source = "experiences/experiences.sqlite"
            for owed in try await ExperienceStore.at(root).projection() where owed.owes["repair"]?.phase.isSettled == false
                && owed.claims.contains(where: { $0.claim.hasPrefix("operation: peer.") || $0.claim.hasPrefix("operation: agent.") }) {
                let operation = owed.claims.first { $0.claim.hasPrefix("operation: ") }?.claim ?? "agent connection"
                problems.append("\(operation) still owes repair (\(owed.id))")
            }
            return CheckResult(source: "agents/peers.json, agents/local-health.json and experiences/experiences.sqlite",
                id: "live.agent_connections", title: "Agent connections", status: problems.isEmpty ? "ok" : "fail",
                detail: problems.isEmpty ? "No broken reply path is recorded; setup alone does not prove a reply."
                    : "Agent connection evidence: " + problems.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) }.joined(separator: "; ") + ".")
        } catch {
            return CheckResult(source: source,
                id: "live.agent_connections", title: "Agent connections", status: "fail",
                detail: "Agent connection evidence is unavailable: \(Self.safeDetail(error.localizedDescription))",
                harm: "Her saved helper contacts and conversations cannot be read.", repair: nil,
                human_action: ToolFailureError.fileRepairInstruction(root.appendingPathComponent(source),
                    shape: source == "experiences/experiences.sqlite"
                        ? "This SQLite experience store retains original experiences, claims, evidence and obligation phases. Preserve their identities and settlement history."
                        : "Retain the saved peer contacts, conversations or local-health observations in this file, with their original identities and recorded states. Preserve credentials, admission and elevation choices exactly; never grant authority or invent a reply."))
        }
    }

    public func doctorBackgroundLoopsCheck() async -> CheckResult {
        let observations = await port.doctorManager.status()
        let receipts = DoctorLoopHealth.recentFailureDates(
            receiptsFile: dataRoot.appendingPathComponent("logs/background_loop_failures.jsonl"))
        let now = Date()
        await MainActor.run {
            port.doctorEngine.doctor.loopVerdicts = DoctorLoopHealth.evaluate(
                observations: observations, recentFailureDates: receipts, now: now)
        }
        return DoctorLoopHealth.doctorCheck(
            observations: observations, recentFailureDates: receipts, now: now)
    }

    public func doctorBackgroundLoopChecks() async -> [CheckResult] {
        await DoctorLoopRecovery.checks(
            manager: port.doctorManager,
            dataRoot: dataRoot,
            friendlyLoopName: DoctorPlainCopy.friendlyLoopName
        )
    }

    /// Each organ's last pulse, overdue by `OrganPulse.isOverdue` since this launch.
    public func doctorOrganPulsesCheck() async -> CheckResult {
        let now = Date()
        let manager = port.doctorManager
        let launchedAt = now.addingTimeInterval(-(await manager.uptimeSeconds(now: now)))
        let rows = await manager.organPulses().map { pulse in
            if pulse.isOff { return (false, "\(pulse.organ): off (\(pulse.note.dropFirst(OrganPulse.offPrefix.count)))", pulse.organ) }
            let age = now.timeIntervalSince(pulse.at)
            let overdue = pulse.isOverdue(now: now, launchedAt: launchedAt)
            return (overdue, "\(pulse.organ): \(pulse.outcome.rawValue) \(DoctorLoopHealth.describeAge(age)) ago"
                + (pulse.note.isEmpty ? "" : " (\(pulse.note))")
                + (pulse.cadence.map { ", every \(DoctorLoopHealth.describeAge($0))" } ?? "") + (overdue ? " — overdue" : ""), pulse.organ)
        }.sorted { ($0.0 ? 0 : 1, $0.1) < ($1.0 ? 0 : 1, $1.1) }
        return CheckResult(source: "Organ pulse registrations",id: "live.pulses", title: "Organ pulses", status: rows.isEmpty ? "unmeasured" : rows.contains(where: \.0) ? "warn" : "ok",
                           detail: rows.isEmpty ? "No organ has pulsed yet." : rows.map(\.1).joined(separator: "; ") + ".")
    }

    public func doctorInspectorCheck() async -> CheckResult {
        await port.doctorInspectorCheck()
    }

    public func redactDoctorDetail(_ value: String) -> String {
        NativeAppSecretRedactor.redactText(value)
    }
}

// MARK: - Health card

extension EngineDoctorRuntime {
    public func getHealthCard() async throws -> HealthCard {
        // Refresh live owners on every read; the projection alone owns the
        // short cache for offline checks and writes its compatible snapshot.
        let now = ISO8601DateFormatter().string(from: Date())
        let liveChecks = await liveDoctorCoverageChecks()
        let card = await DoctorStatusProjection.makeHealthCard(
            now: now,
            cachePath: dataRoot.appendingPathComponent("doctor/latest.json"),
            liveChecks: liveChecks,
            safeDetail: Self.safeDetail,
            runCoreChecks: { try await makeDoctorChecks(root: dataRoot).runAll() }
        )
        let rows = await DoctorStatusProjection.repairProjection(card.subsystems.map { subsystem in
            liveChecks.first { $0.id == subsystem.id }
                ?? CheckResult(id: subsystem.id, title: subsystem.label, status: subsystem.status, detail: subsystem.detail)
        }, dataRoot: dataRoot)
        // A cached core row keeps the lever it was measured with.
        let measured = Dictionary(card.subsystems.map { ($0.id, $0.fixAction) }, uniquingKeysWith: { first, _ in first })
        return HealthCard(overall: DoctorStatusProjection.doctorRollup(rows.map(\.status)), subsystems: rows.map {
            HealthCardSubsystem(id: $0.id, label: $0.title, status: $0.status, detail: $0.repairFace,
                                fixAction: $0.repairCall ?? $0.repairTap ?? measured[$0.id] ?? nil)
        }, createdAt: card.createdAt)
    }

}

extension EngineDoctorRuntime {
    public static func reusableSupportReport(
        report: DoctorReport?, completedAt: Date?, now: Date = Date()
    ) -> DoctorReport? {
        guard let report, let completedAt else { return nil }
        let age = now.timeIntervalSince(completedAt)
        return age >= 0 && age < supportSnapshotDoctorReuseTTL ? report : nil
    }
}
