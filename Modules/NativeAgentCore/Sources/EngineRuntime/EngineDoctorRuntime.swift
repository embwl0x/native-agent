import Foundation
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import BackgroundWork
import Synchronization
import NativeAgentShared
// Blueprint: | `EngineDoctorRuntime.swift` | EngineDoctorRuntime and EngineDoctorPlatformPort retain live check orchestration, frozen repair admission, cancellation, rechecks and repair-obligation publication |

/// Platform observations and callbacks; Doctor owns interpretation and repair admission.
public protocol EngineDoctorPlatformPort: Sendable {
    var doctorEngine: NativeAgentEngine { get }
    var doctorManager: BackgroundLoops.BackgroundLoopLifetimes { get }
    func doctorRestartLoop(id: String) async -> LoopRestartOutcome
    func doctorRepairPhoneSync() async -> DoctorRepairAttempt?
    func doctorStartBridge(name: String) async
    func doctorInspectorRepair(for check: CheckResult) async -> DoctorExecutableRepair?
    func doctorBridgeSnapshots() async -> [DoctorBridgeSnapshot]
    func doctorInspectorCheck() async -> CheckResult
}

private let doctorRepairInFlight = Mutex(false)

/// Live health and repair policy for the engine's mounted owners.
public struct EngineDoctorRuntime<Port: EngineDoctorPlatformPort>: Sendable {
    let port: Port
    public let dataRoot: URL

    public init(dataRoot: URL, port: Port) {
        self.dataRoot = dataRoot
        self.port = port
    }

    public func runDoctor(repair: Bool = false, repairScope: DoctorRepairScope = .automatic,
                          checks suppliedChecks: SwiftNativeDoctorChecks? = nil, checkID: String? = nil) async throws -> DoctorReport {
        let impl = suppliedChecks ?? makeDoctorChecks(root: dataRoot)
        // Concurrent status readers do not queue another repair pass.
        let ownsRepair = repair && doctorRepairInFlight.withLock { running in
            guard !running else { return false }
            running = true
            return true
        }
        defer { if ownsRepair { doctorRepairInFlight.withLock { $0 = false } } }
        var checks = await impl.runAll()
        checks += await liveDoctorCoverageReadings(probeSearch: true, includeCognition: true)
        if let checkID, checkID != "status.desk_attention", !checks.contains(where: { $0.id == checkID }) {
            throw ToolFailureError("No Doctor check has id \(checkID). Nothing was repaired.",
                argumentPath: "check_id", accepted: "A check id from doctor.run.", effects: .none)
        }
        var liveRepairs: [String: DoctorExecutableRepair] = [:]
        for check in checks where (check.id.hasPrefix("live.") || check.id == "icloud_bridge_state") && DoctorSafeRepairPolicy.isAdverse(check.status)
            && (ownsRepair || !check.id.hasPrefix("live.cognition.")) {
            if let action = await self.doctorLiveRepair(for: check, scope: ownsRepair ? repairScope : .button),
               action.checkID == check.id {
                liveRepairs[check.id] = action
            }
        }
        var repairReceipts: [CheckResult] = []
        if ownsRepair {
            let coreIDs = DoctorSafeRepairPolicy.executableCoreIDs(for: checks)
            await DoctorReadout.recordReadings(checks.filter { DoctorSafeRepairPolicy.isAdverse($0.status) }.map {
                $0.settled(liveAvailable: liveRepairs[$0.id] != nil, coreAvailable: coreIDs.contains($0.id))
            }, dataRoot: self.dataRoot)
            // Freeze admission before executing; each check gets one attempt.
            for id in DoctorSafeRepairPolicy.checkIDs(for: checks, executableLiveIDs: Set(liveRepairs.keys), scope: repairScope)
                where checkID == nil || checkID == id {
                try Task.checkCancellation()
                guard let index = checks.firstIndex(where: { $0.id == id }) else { continue }
                let before = checks[index]
                var receipt: String
                var actionCompleted = true
                do {
                    if let action = liveRepairs[id] {
                        if id == "icloud_bridge_state" {
                            _ = await impl.runCheck(id: id, repair: true, scope: repairScope)
                        }
                        let attempt = try await action.run()
                        receipt = attempt.detail
                        actionCompleted = attempt.completed
                    } else if let result = await impl.runCheck(id: id, repair: true, scope: repairScope) {
                        actionCompleted = result.repairApplied == true
                        receipt = result.receipt ?? (id == "oauth_token_expiry"
                            ? result.detail : result.repair ?? "Repair attempted; no completion receipt returned.")
                        // The OAuth result carries the exchange verdict. A
                        // disk-only reread cannot distinguish rejected from untried.
                        if id == "oauth_token_expiry" {
                            checks[index] = result
                        } else {
                            checks[index] = await impl.runCheck(id: id, repair: false, scope: repairScope) ?? result
                        }
                    } else {
                        continue
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    receipt = "Repair failed: \(safeDoctorDetail(error.localizedDescription))"
                    actionCompleted = false
                }
                if liveRepairs[id] != nil {
                    if id == "icloud_bridge_state" {
                        if let verified = await impl.runCheck(id: id, repair: false, scope: repairScope) { checks[index] = verified }
                    } else if let verified = await liveDoctorCheck(id: id) { checks[index] = verified }
                    if id == "live.telegram", !actionCompleted, checks[index].status == "ok" {
                        checks[index].status = "unmeasured"
                    }
                }
                let verified = checks[index]
                var text = safeDoctorDetail(receipt)
                nativeLog("[Doctor repair] %@: %@; recheck=%@", id, text, verified.status)
                do {
                    try await self.doctorRecordRepair(checkID: id, receipt: text, status: verified.status)
                } catch {
                    let failure = "Repair receipt could not be saved: \(safeDoctorDetail(error.localizedDescription))"
                    nativeLog("[Doctor repair] %@", failure)
                    text += " " + failure
                }
                checks[index].receipt = text
                checks[index].repairApplied = actionCompleted
                var repairReceipt = checks[index]
                repairReceipt.title = before.title
                repairReceipt.detail = text
                repairReceipt.repair = nil
                repairReceipts.append(repairReceipt)
            }
        }
        let rollup = DoctorReadout.doctorRollup(checks.map(\.status))
        let repaired = DoctorSafeRepairPolicy.appliedRepairCount(in: repairReceipts) > 0
        let executable = DoctorSafeRepairPolicy.executableCoreIDs(for: checks)
        for index in checks.indices {
            let row = checks[index]
            var liveAvailable = false
            if row.id.hasPrefix("live.") || row.id == "icloud_bridge_state", DoctorSafeRepairPolicy.isAdverse(row.status) {
                if ownsRepair {
                    liveAvailable = await self.doctorLiveRepair(for: row, scope: .button)?.checkID == row.id
                } else {
                    liveAvailable = liveRepairs[row.id] != nil || row.repair_available == true
                }
            }
            checks[index] = row.settled(liveAvailable: liveAvailable, coreAvailable: executable.contains(row.id))
        }
        await DoctorReadout.recordReadings(checks, dataRoot: dataRoot)
        let rows = await DoctorReadout.repairProjection(checks, dataRoot: dataRoot)
        if !rows.contains(where: { $0.id == "doctor.repair_store" }) {
            _ = await MaintenanceBackgroundWork(port: EngineBackgroundWorkPort())
                .fileDoctorAsk(dataRoot: dataRoot, rows: rows)
        }
        return DoctorReport(status: rollup, repaired: repaired, checks: checks)
    }

    private func liveDoctorCheck(id: String) async -> CheckResult? {
        if id.hasPrefix("live.cognition.") {
            return await self.doctorCognitionChecks().first { $0.id == id }
        }
        switch id {
        case "live.providers": return await providerDoctorCoverageCheck()
        case "live.search": return await searchDoctorCoverageCheck(probe: true)
        case "live.telegram": return await telegramDoctorCoverageCheck()
        case "live.background_loops": return await self.doctorBackgroundLoopsCheck()
        case "live.bridges": return await bridgesDoctorCoverageCheck()
        case "live.agent_connections": return await self.doctorAgentConnectionsCheck()
        case "live.memory": return await memoryDoctorCoverageCheck()
        case "live.inspector_feed": return await self.doctorInspectorCheck()
        case "live.embedding_download": return await self.doctorEmbeddingDownloadCheck()
        default:
            if id.hasPrefix("live.background_loop.") {
                return await self.doctorBackgroundLoopChecks().first { $0.id == id }
            }
            return nil
        }
    }

    public func liveDoctorCoverageChecks() async -> [CheckResult] {
        var checks = await liveDoctorCoverageReadings(probeSearch: false, includeCognition: false)
        for index in checks.indices where DoctorSafeRepairPolicy.isAdverse(checks[index].status) {
            let row = checks[index]
            let available = await self.doctorLiveRepair(for: row, scope: .button)?.checkID == row.id
            checks[index].repair = available ? "Press Repair in Diagnostics → Health checks to retry this live service." : nil
            checks[index].human_action = row.recoveryAction(repairAvailable: available)
            checks[index].repair_available = available
            checks[index].owner = DoctorOwner.of(row, repairAvailable: available)
        }
        await DoctorReadout.recordReadings(checks, dataRoot: dataRoot)
        return checks
    }

    private func liveDoctorCoverageReadings(probeSearch: Bool, includeCognition: Bool) async -> [CheckResult] {
        async let providers = providerDoctorCoverageCheck()
        async let telegram = telegramDoctorCoverageCheck()
        async let search = searchDoctorCoverageCheck(probe: probeSearch)
        async let tools = toolsDoctorCoverageCheck()
        async let autonomy = autonomyDoctorCoverageCheck()
        // Loop-health verdicts feed the live Doctor report.
        async let loops = self.doctorBackgroundLoopsCheck()
        async let loopDetails = self.doctorBackgroundLoopChecks()
        async let memory = memoryDoctorCoverageCheck()
        async let bridges = bridgesDoctorCoverageCheck()
        async let agents = self.doctorAgentConnectionsCheck()
        async let inspector = self.doctorInspectorCheck()
        async let embedding = self.doctorEmbeddingDownloadCheck()
        async let pulses = self.doctorOrganPulsesCheck()
        let common = await [providers, telegram, search, tools, autonomy, loops, memory, bridges, agents, inspector, embedding, pulses] + (await loopDetails) + [self.doctorDataRootCheck()]
        return includeCognition ? common + (await self.doctorCognitionChecks()) : common
    }
}
