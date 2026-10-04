import Foundation
import Cognition
import CognitiveSubstrate
import ContextFlow
import DeviceSync
import DoctorChecks
import PersistenceCore
import TurnTrace

// Doctor reads mounted owners without starting Observatory refresh work.
extension NativeClient {
    func doctorCognitionChecks() async -> [CheckResult] {
        guard (dataRootOverride ?? PersistenceCore.defaultDataRoot()).standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL else { return [] }

        var rows: [CheckResult] = []
        rows.append(doctorPhonePairingCheck())
        if let detail = await NativeAgentEngine.live.cognition?.doctorRead() {
            rows.append(CheckResult(id: "live.cognition.runtime", title: "Cognition runtime",
                                    status: "ok", detail: "Mounted cognition state is readable."))
            rows.append(doctorPersistenceCheck(detail))
            rows.append(doctorReceiptCheck(detail))
            rows.append(doctorReadoutCheck(detail))
            rows.append(doctorBodyCheck(detail))
            rows.append(doctorWelfareCheck(detail))
            rows.append(doctorCapacityCheck(detail))
            rows.append(doctorAssociationCheck(detail))
        } else {
            rows.append(CheckResult(
                id: "live.cognition.runtime", title: "Cognition runtime", status: "fail",
                detail: "The mounted cognition runtime has no ready state to read.",
                human_action: "Quit and reopen NativeAgent, then open Diagnostics → Doctor and run Check again."
            ))
        }
        rows.append(await doctorContextFlowCheck())
        return rows
    }

    private func doctorPersistenceCheck(_ detail: CognitiveDoctorRead) -> CheckResult {
        let health = detail.substrate.persistenceHealth
        let id = "live.cognition.persistence"
        let title = "Cognition persistence"
        guard detail.configuration.enabled, detail.configuration.persistenceEnabled else {
            return CheckResult(id: id, title: title, status: "ok", detail: "Cognition persistence is intentionally off.")
        }
        if health.status == .restoring {
            return CheckResult(id: id, title: title, status: "ok", detail: "Cognition persistence restore is in progress.")
        }
        guard health.status == .degraded || health.writesBlocked else {
            return CheckResult(id: id, title: title, status: "ok", detail: "Persistence is \(health.status.rawValue); writes are unblocked.")
        }
        let stage = String((health.failureStage ?? "unknown").prefix(80))
        let retryableRead = doctorPersistenceReadRetryable(health)
        return CheckResult(
            id: id, title: title, status: "fail",
            detail: "Persistence is \(health.status.rawValue); writes blocked: \(health.writesBlocked); failure stage: \(stage).",
            human_action: health.failureStage == "store"
                ? "Check that the cognition storage volume is available and writable, then quit and reopen NativeAgent."
                : retryableRead
                    ? "Check that the cognition storage volume is available, then open Diagnostics → Doctor and press Repair to retry the checked restore."
                    : "Keep the cognition continuity store unchanged. Open Diagnostics → Cognition and arrange a backup review before any loss-aware recovery.",
            repair_available: retryableRead
        )
    }

    private func doctorPersistenceReadRetryable(_ health: CognitivePersistenceHealth) -> Bool {
        guard health.status == .degraded, health.writesBlocked else { return false }
        guard health.failureStage == "sqlite_read" else { return false }
        let detail = (health.failureDetail ?? "").lowercased()
        return !["malformed", "corrupt", "not a database"].contains(where: detail.contains)
    }

    private func doctorReceiptCheck(_ detail: CognitiveDoctorRead) -> CheckResult {
        let id = "live.cognition.receipts"
        let title = "Cognition loop receipts"
        switch detail.receiptRead {
        case .available:
            return CheckResult(id: id, title: title, status: "ok", detail: "Loop receipt evidence is readable.")
        case .unavailable(.cognitionDisabled), .unavailable(.persistenceDisabled):
            return CheckResult(id: id, title: title, status: "ok", detail: "Loop receipt evidence is intentionally off.")
        case .unavailable(let reason):
            return CheckResult(id: id, title: title, status: "warn",
                               detail: "Loop receipt evidence is unavailable (\(reason.rawValue)).",
                               human_action: "Open Diagnostics → Cognition, refresh once, then inspect the persistence warning if receipts remain unavailable.")
        }
    }

    private func doctorPhonePairingCheck() -> CheckResult {
        let id = "live.cognition.phone_pairing"
        let title = "Phone pairing store"
        do {
            let paired = try PairedPhoneStore.pairedCountChecked(
                at: PersistenceCore.defaultDataRoot().appendingPathComponent("paired_phones.json")
            ) > 0
            return CheckResult(id: id, title: title, status: "ok",
                               detail: paired ? "Paired phone state is readable." : "No phone is paired.")
        } catch {
            return CheckResult(id: id, title: title, status: "fail",
                               detail: "Phone pairing state is unreadable or corrupt.",
                               human_action: "Open Connectors → iPhone to inspect paired devices, then request a pairing-store review with paired_phones.json unchanged before re-pairing.")
        }
    }

    private func doctorBodyCheck(_ detail: CognitiveDoctorRead) -> CheckResult {
        let id = "live.cognition.body"
        let title = "Body attention"
        let organism = detail.organism
        guard organism.enabled else {
            return CheckResult(id: id, title: title, status: "ok", detail: "Organism is intentionally off.")
        }
        let body = organism.bodySchema
        var causes: [String] = []
        if !body.providersHealthy { causes.append("provider health") }
        if !body.toolHandsAvailable { causes.append("tool availability") }
        if !body.memoryHealthy { causes.append("memory health") }
        if !body.dreamHealthy { causes.append("dream health") }
        if !body.approvalChannelsOpen { causes.append("approval channel") }
        if body.resourcePressure != .nominal { causes.append("resource pressure: \(body.resourcePressure.rawValue)") }
        if organism.residualRepairOpportunity.ready { causes.append("due residual pressure") }
        if causes.isEmpty {
            return CheckResult(id: id, title: title, status: "ok",
                               detail: "No body dependency needs attention; ordinary affect is not damage.")
        }
        return CheckResult(
            id: id, title: title, status: "warn", detail: "Body attention: \(causes.joined(separator: ", ")).",
            human_action: organism.residualRepairOpportunity.ready
                ? "Open Diagnostics → Doctor and press Repair to run the due bounded residual repair; inspect any other named dependency in Status."
                : "Open Diagnostics → Status and inspect the named body dependency; use its owner control or decision there.",
            repair_available: organism.residualRepairOpportunity.ready
        )
    }

    private func doctorReadoutCheck(_ detail: CognitiveDoctorRead) -> CheckResult {
        let id = "live.cognition.readouts"
        let title = "Cognition body and mood readouts"
        let mood = CognitionObservatoryAffectPresentation(
            configuration: detail.configuration,
            affect: detail.affect,
            capsulePreviewInfo: detail.capsulePreviewInfo
        )
        let body = CognitionObservatoryOrganismPresentation(snapshot: detail.organism)
        var failures: [String] = []
        switch mood.state {
        case .absent(let reason), .unavailable(let reason):
            if detail.configuration.enabled && detail.configuration.observatoryEnabled && detail.configuration.affectEnabled {
                failures.append("mood: \(reason)")
            }
        default: break
        }
        switch body.state {
        case .absent(let reason), .unavailable(let reason):
            if detail.organism.enabled { failures.append("body: \(reason)") }
        default: break
        }
        guard !failures.isEmpty else {
            return CheckResult(id: id, title: title, status: "ok", detail: "Enabled body and mood readouts are available; disabled readouts are intentional.")
        }
        return CheckResult(id: id, title: title, status: "warn",
                           detail: "\(failures.joined(separator: " "))",
                           human_action: "Open Diagnostics → Cognition and refresh the affected readout once; if it remains unavailable, capture its displayed reason for the cognition owner.")
    }

    private func doctorWelfareCheck(_ detail: CognitiveDoctorRead) -> CheckResult {
        let id = "live.cognition.welfare"
        let title = "Cognition welfare bounds"
        guard detail.configuration.enabled else {
            return CheckResult(id: id, title: title, status: "ok", detail: "Cognition is intentionally off.")
        }
        guard !detail.welfareBounds.withinBounds else {
            return CheckResult(id: id, title: title, status: "ok", detail: "Welfare readings are within bounds.")
        }
        return CheckResult(id: id, title: title, status: "warn",
                           detail: "Welfare bounds report attention; max affect \(detail.welfareBounds.maxAffectValue), reflection pressure \(detail.welfareBounds.reflectionBudgetPressure).",
                           human_action: "Open Diagnostics → Cognition → Welfare bounds and review the current reading before changing reflection controls.")
    }

    private func doctorCapacityCheck(_ detail: CognitiveDoctorRead) -> CheckResult {
        let id = "live.cognition.capacity"
        let title = "Cognition capacity"
        guard detail.configuration.enabled else {
            return CheckResult(id: id, title: title, status: "ok", detail: "Cognition is intentionally off.")
        }
        let counts = [
            ("nodes", detail.substrate.nodeCount, detail.configuration.maximumActiveNodes),
            ("workspace items", detail.workspace.items.count, detail.configuration.maximumWorkspaceItems),
            ("thought seeds", detail.thoughtSeeds.count, detail.configuration.maximumThoughtSeeds),
        ]
        let overflow = counts.filter { $0.1 > $0.2 }
        guard !overflow.isEmpty else {
            return CheckResult(id: id, title: title, status: "ok", detail: "Nodes, workspace, and thought seeds are within their configured caps.")
        }
        return CheckResult(id: id, title: title, status: "warn",
                           detail: "Over cap: \(overflow.map { "\($0.0) \($0.1)/\($0.2)" }.joined(separator: ", ")).",
                           human_action: "Open Diagnostics → Cognition → Tensions & Pruning and capture the over-cap counts for a cognition owner review.")
    }

    private func doctorAssociationCheck(_ detail: CognitiveDoctorRead) -> CheckResult {
        let id = "live.cognition.associations"
        let title = "Cognition association endpoints"
        guard detail.configuration.enabled, !detail.associations.isEmpty else {
            return CheckResult(id: id, title: title, status: "ok", detail: "No unresolved association graph is displayed.")
        }
        let nodeIDs = Set(detail.substrate.nodes.map(\.id))
        let allMissing = detail.associations.allSatisfy {
            !nodeIDs.contains($0.fromNodeId) && !nodeIDs.contains($0.toNodeId)
        }
        guard allMissing else {
            return CheckResult(id: id, title: title, status: "ok", detail: "At least one association endpoint resolves in the current snapshot.")
        }
        return CheckResult(id: id, title: title, status: "warn",
                           detail: "Neither endpoint resolves for any of \(detail.associations.count) association links in this snapshot.",
                           human_action: "Open Diagnostics → Cognition → Association graph and request a cognition owner review of the unresolved links; preserve the graph evidence.")
    }

    private func doctorContextFlowCheck() async -> CheckResult {
        let id = "live.cognition.context_flow"
        let title = "Context Flow"
        let owner = NativeAgentEngine.live.contextFlow
        let health = await owner.observatoryHealthState()
        switch health {
        case .off:
            return CheckResult(id: id, title: title, status: "ok", detail: "Context Flow is intentionally off.")
        case .unavailable:
            return CheckResult(id: id, title: title, status: "fail",
                               detail: "Configured Context Flow health is unavailable from its owner.",
                               human_action: "Open Diagnostics → Cognition → Context flow, refresh once, then reopen NativeAgent if health remains unavailable.")
        case .health(let state):
            if state.mode == .off {
                return CheckResult(id: id, title: title, status: "ok", detail: "Context Flow is intentionally off.")
            }
            var causes: [String] = []
            if !state.started { causes.append("not started") }
            if state.degradedSourceCount > 0 { causes.append("\(state.degradedSourceCount) degraded source(s)") }
            if state.lastError != nil { causes.append("owner error") }
            if state.arenaMetrics.pressure != .normal { causes.append("arena pressure: \(state.arenaMetrics.pressure.rawValue)") }
            guard !causes.isEmpty else {
                return CheckResult(id: id, title: title, status: "ok", detail: "Context Flow is started and its sources are healthy.")
            }
            let canReconcile = !state.started || state.degradedSourceCount > 0 || state.lastError != nil
            return CheckResult(id: id, title: title, status: "warn",
                               detail: "Context Flow: \(causes.joined(separator: ", ")).",
                               human_action: canReconcile
                                   ? "Open Diagnostics → Cognition → Context flow and inspect the source error; press Repair to reconcile the derived sources once."
                                   : "Open Diagnostics → Cognition → Context flow and inspect the arena pressure.",
                               repair_available: canReconcile)
        }
    }

    func doctorCognitionRepair(for check: CheckResult) async -> DoctorExecutableRepair? {
        guard (dataRootOverride ?? PersistenceCore.defaultDataRoot()).standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL else { return nil }
        switch check.id {
        case "live.cognition.body":
            guard let runtime = NativeAgentEngine.live.cognition,
                  await runtime.organismKernel.residualRepairOpportunity().ready else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                guard await runtime.repairDueResidualForDoctor() else {
                    return .unverified("Repair attempted: the due residual opportunity changed or did not settle.")
                }
                return .completed("Completed: the organism owner ran one due bounded residual repair pass.")
            }
        case "live.cognition.persistence":
            guard let runtime = NativeAgentEngine.live.cognition else { return nil }
            let health = await runtime.substrate.snapshot().persistenceHealth
            guard doctorPersistenceReadRetryable(health) else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                let before = await runtime.substrate.snapshot().persistenceHealth
                guard doctorPersistenceReadRetryable(before) else {
                    return .unverified("Repair skipped: persistence state changed before the checked restore.")
                }
                do {
                    _ = try await runtime.substrate.backupPersistentStateForDoctor()
                } catch {
                    return .unverified("Repair skipped: the cognition store could not be backed up.")
                }
                try await runtime.substrate.restorePersistentState()
                let after = await runtime.substrate.snapshot().persistenceHealth
                return !after.writesBlocked && after.status != .degraded
                    ? .completed("Completed: cognition continuity restored through its owner; writes are unblocked.")
                    : .unverified("Repair attempted: cognition persistence still blocks writes.")
            }
        case "live.cognition.context_flow":
            let owner = NativeAgentEngine.live.contextFlow
            guard case .health(let state) = await owner.observatoryHealthState(),
                  state.mode != .off, (!state.started || state.degradedSourceCount > 0 || state.lastError != nil) else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                await owner.reconcileAfterWake()
                guard case .health(let after) = await owner.observatoryHealthState(),
                      after.started, after.degradedSourceCount == 0, after.lastError == nil else {
                    return .unverified("Repair attempted: Context Flow reconciliation did not clear the owner fault.")
                }
                return .completed("Completed: Context Flow reconciled its derived sources through the owner.")
            }
        default: return nil
        }
    }
}
