import Foundation
import Cognition
import CognitiveSubstrate
import ContextFlow
import DeviceSync
import DoctorChecks
import PersistenceCore
import TurnTrace

// Doctor reads mounted owners without starting Observatory refresh work.
extension EngineDoctorRuntime {
    public func doctorCognitionChecks() async -> [CheckResult] {
        guard dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL else { return [] }

        var rows: [CheckResult] = []
        rows.append(await doctorPhonePairingCheck())
        if let detail = await port.doctorEngine.cognition?.doctorRead() {
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
                harm: "Her inner state is unavailable to the conversation.",
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
            harm: "Her inner continuity is not being saved.",
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
                               harm: "Her recent inner work cannot be verified.",
                               human_action: "Open Diagnostics → Cognition, refresh once, then inspect the persistence warning if receipts remain unavailable.")
        }
    }

    private func doctorPhonePairingCheck() async -> CheckResult {
        let id = "live.cognition.phone_pairing"
        let title = "Phone pairing store"
        do {
            let phone = try await SwiftNativeAPNSSender().notificationReadiness(dataRoot: dataRoot)
            if phone.status == "not_checked" {
                return CheckResult(id: id, title: title, status: "unmeasured", detail: phone.detail)
            }
            return CheckResult(id: id, title: title, status: phone.paired == 0 || phone.supported ? "ok" : "warn",
                               detail: phone.detail, harm: phone.paired > 0 && !phone.supported ? "Phone notifications are not proven available." : nil,
                               human_action: phone.paired > 0 && !phone.supported ? "Open the paired phone app and check its notification permission, then send a requested notification." : nil)
        } catch {
            return CheckResult(id: id, title: title, status: "fail",
                               detail: "Phone notification state could not be read: \(error.localizedDescription)",
                               harm: "Phone notifications cannot be verified.",
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
            harm: "Her attention or ability to act is limited by the named body dependency.",
            human_action: organism.residualRepairOpportunity.ready
                ? "Open Diagnostics → Doctor and press Repair to run the due bounded residual repair; inspect any other named dependency in Status."
                : "Open Diagnostics → Status and inspect the named body dependency; use its owner control or decision there.",
            repair_available: organism.residualRepairOpportunity.ready
        )
    }

    private func doctorCognitionReadoutFailures(_ detail: CognitiveDoctorRead) -> [String] {
        var failures: [String] = []
        let configuration = detail.configuration
        if configuration.enabled && configuration.observatoryEnabled && configuration.affectEnabled {
            let affect = detail.affect
            if ![affect.arousal, affect.uncertainty, affect.taskPressure, affect.socialWarmth]
                .allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
                failures.append("mood: Affect snapshot contains an invalid value and is withheld.")
            }
        }
        let snapshot = detail.organism
        if snapshot.enabled {
            let now = Date()
            let age = now.timeIntervalSince(snapshot.generatedAt)
            if !snapshot.generatedAt.timeIntervalSinceReferenceDate.isFinite
                || !now.timeIntervalSinceReferenceDate.isFinite || age < -60 || age > 5 * 60 {
                failures.append("body: The last organism body sample is stale or has an invalid timestamp; refresh it before reading these values.")
            } else if ![
                snapshot.chemicalState.warmth,
                snapshot.chemicalState.vigilance,
                snapshot.chemicalState.coherence,
                snapshot.chemicalState.confidence,
                snapshot.chemicalState.fatigue,
                snapshot.chemicalState.agency,
                snapshot.fieldSummary.strongestEdgeWeight,
                snapshot.fieldSummary.totalCharge,
                snapshot.fieldSummary.averageUncertainty,
                snapshot.predictionSummary.peripheralUncertainty,
                snapshot.predictionSummary.strategyCaution,
                snapshot.predictionSummary.bodyConfidence.toolPath,
                snapshot.predictionSummary.bodyConfidence.providerPath,
                snapshot.predictionSummary.bodyConfidence.phonePath,
                snapshot.residualRepairOpportunity.pressure,
            ].allSatisfy(\.isFinite) {
                failures.append("body: The organism body sample contains an invalid value and is withheld.")
            }
        }
        return failures
    }

    private func doctorReadoutCheck(_ detail: CognitiveDoctorRead) -> CheckResult {
        let id = "live.cognition.readouts"
        let title = "Cognition body and mood readouts"
        let failures = doctorCognitionReadoutFailures(detail)
        guard !failures.isEmpty else {
            return CheckResult(id: id, title: title, status: "ok", detail: "Enabled body and mood readouts are available; disabled readouts are intentional.")
        }
        return CheckResult(id: id, title: title, status: "warn",
                           detail: "\(failures.joined(separator: " "))",
                           harm: "Her current body or mood cannot be seen in Cognition.",
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
        return CheckResult(id: id, title: title, status: "unmeasured",
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
                           harm: "Her inner workspace can grow beyond its configured memory limits.",
                           owner: .builder)
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
                           harm: "The displayed associations no longer connect to her current thoughts.",
                           human_action: "Preserve the association graph evidence.", owner: .builder)
    }

    private func doctorContextFlowCheck() async -> CheckResult {
        let id = "live.cognition.context_flow"
        let title = "Context Flow"
        let owner = port.doctorEngine.contextFlow
        let health = await owner.observatoryHealthState()
        switch health {
        case .off:
            return CheckResult(id: id, title: title, status: "ok", detail: "Context Flow is intentionally off.")
        case .unavailable:
            return CheckResult(id: id, title: title, status: "fail",
                               detail: "Configured Context Flow health is unavailable from its owner.",
                               harm: "The conversation may miss current context from her enabled sources.",
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
            return CheckResult(id: id, title: title, status: canReconcile ? "warn" : "unmeasured",
                               detail: "Context Flow: \(causes.joined(separator: ", ")).",
                               harm: canReconcile ? "The conversation may miss current context from her enabled sources." : nil,
                               human_action: canReconcile
                                   ? "Open Diagnostics → Cognition → Context flow and inspect the source error; press Repair to reconcile the derived sources once."
                                   : "Open Diagnostics → Cognition → Context flow and inspect the arena pressure.",
                               repair_available: canReconcile)
        }
    }

    public func doctorCognitionRepair(for check: CheckResult) async -> DoctorExecutableRepair? {
        guard dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL else { return nil }
        switch check.id {
        case "live.cognition.body":
            guard let runtime = port.doctorEngine.cognition,
                  await runtime.organismKernel.residualRepairOpportunity().ready else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                guard await runtime.repairDueResidualForDoctor() else {
                    return .unverified("Repair attempted: the due residual opportunity changed or did not settle.")
                }
                return .completed("Completed: the organism owner ran one due bounded residual repair pass.")
            }
        case "live.cognition.persistence":
            guard let runtime = port.doctorEngine.cognition else { return nil }
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
            let owner = port.doctorEngine.contextFlow
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
