import Foundation
import Cognition
import CognitiveSubstrate
import ContextFlow
import DeviceSync
import NativeAgentShared
import DoctorChecks
import NativeAgentCore
import PersistenceCore
import TurnTrace
import TrustCenter
// Blueprint: | `EngineDoctor+Cognition.swift` | `EngineDoctorRuntime`: cognition health and repair; APNs diagnostics name the canonical push-token store, never retained mobile_push/tokens.json |

// Doctor reads mounted owners without changing their state.
extension EngineDoctorRuntime {
    public func doctorCognitionChecks() async -> [CheckResult] {
        guard dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL else { return [] }

        var rows: [CheckResult] = []
        rows += await doctorPhoneChecks()
        if let detail = await port.doctorEngine.cognition?.doctorRead() {
            rows.append(CheckResult(source: "Cognition registration", id: "live.cognition.runtime", title: "Cognition runtime",
                                    status: "ok", detail: "Mounted cognition state is readable."))
            rows.append(doctorPersistenceCheck(detail))
            rows.append(doctorReceiptCheck(detail))
            rows.append(doctorReadoutCheck(detail))
            rows.append(doctorBodyCheck(detail))
            rows.append(doctorCapacityCheck(detail))
            rows.append(doctorAssociationCheck(detail))
        } else {
            rows.append(CheckResult(source: "Cognition registration",
                id: "live.cognition.runtime", title: "Cognition runtime", status: "unmeasured",
                detail: "The mounted cognition runtime has no ready state to read."
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
            return CheckResult(source: "cognition/cognition.sqlite", id: id, title: title, status: "off", detail: "Cognition persistence is intentionally off.")
        }
        if health.status == .restoring || health.status == .ready {
            return CheckResult(source: "cognition/cognition.sqlite", id: id, title: title, status: "unmeasured", detail: "Her saved mind has not been opened yet; writes wait for the restore.")
        }
        guard health.status == .degraded || health.writesBlocked else {
            return CheckResult(source: "cognition/cognition.sqlite", id: id, title: title, status: "ok", detail: "Persistence is \(health.status.rawValue); writes are unblocked.")
        }
        let stage = String((health.failureStage ?? "unknown").prefix(80))
        let retryableRead = doctorPersistenceReadRetryable(health)
        return CheckResult(source: "cognition/cognition.sqlite",
            id: id, title: title, status: "fail",
            detail: "Persistence is \(health.status.rawValue); writes blocked: \(health.writesBlocked); failure stage: \(stage).",
            harm: "Her inner continuity is not being saved.",
            human_action: [health.failureStage == "sqlite_read" && !retryableRead
                ? ToolFailureError.fileRepairInstruction(dataRoot.appendingPathComponent("cognition/cognition.sqlite"),
                    shape: "The SQLite database must retain its cognitive_nodes, cognitive_artifacts and cognitive_receipts tables and all other existing tables. Recover only supported saved rows and payloads; preserve continuity, identifiers and references without inventing cognition state.") : nil, health.failureStage == "store"
                ? "Check that the cognition storage volume is available and writable, then quit and reopen NativeAgent."
                : retryableRead
                    ? "Check that the cognition storage volume is available, then press Repair in Diagnostics → Health checks to retry the checked restore."
                    : "Open Trust → Advanced → Backups and review a verified backup of cognition/cognition.sqlite before choosing Restore → Restore backup for continuity recovery."].compactMap { $0 }.joined(separator: " "),
            repair_available: retryableRead, automaticRepairEligible: false, ask: health.failureStage == "store" ? .permission : nil
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
            return CheckResult(source: "cognition/cognition.sqlite: loop receipts", id: id, title: title, status: "ok", detail: "Loop receipt evidence is readable.")
        case .unavailable(.cognitionDisabled), .unavailable(.persistenceDisabled):
            return CheckResult(source: "cognition/cognition.sqlite: loop receipts", id: id, title: title, status: "off", detail: "Loop receipt evidence is intentionally off.")
        case .unavailable(let reason):
            return CheckResult(source: "cognition/cognition.sqlite: loop receipts", id: id, title: title, status: reason == .readFailed ? "fail" : "unmeasured",
                               detail: "Loop receipt evidence in cognition/cognition.sqlite is unavailable (\(reason.rawValue)).")
        }
    }

    private func doctorPhoneChecks() async -> [CheckResult] {
        let id = "live.cognition.phone_pairing"
        let title = "Phone connection"
        let pairing: CheckResult
        do {
            let count = try PairedPhoneAuthority.pairedCountChecked(at: dataRoot.appendingPathComponent("paired_phones.json"))
            if let connection = await PhoneConnectionReader.connection(dataRoot: dataRoot) {
                pairing = Self.doctorPhoneConnection(connection, id: id, title: title)
            } else {
                pairing = CheckResult(source: "paired_phones.json", id: id, title: title, status: "ok", detail: "Pairing authority is readable; \(count) paired phone(s).")
            }
        } catch {
            pairing = CheckResult(source: "paired_phones.json",
                id: id, title: title, status: "fail", detail: "paired_phones.json could not be read: \(error.localizedDescription)",
                harm: "Paired phone authority is unavailable; preserve its bytes before recovery.",
                human_action: ToolFailureError.fileRepairInstruction(dataRoot.appendingPathComponent("paired_phones.json"),
                    shape: "The file must hold a JSON array of phone records with unique id, publicKey (base64-encoded 32 bytes), and status (pending, paired or removed). Each id must be the lowercase SHA-256 hex of its decoded public key; preserve every saved pairing status and never elevate a phone."))
        }
        let pushID = "live.phone_notifications"
        let pushTitle = "Phone notification transport"
        guard FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent("config/apns.json").path) else {
            return [pairing, CheckResult(source: "config/apns.json", id: pushID, title: pushTitle, status: "not needed",
                detail: "Direct APNS is not configured for this installation.")]
        }
        do {
            let phone = try await SwiftNativeAPNSSender().notificationReadiness(dataRoot: dataRoot, strict: true)
            if phone.status == "not_checked" {
                return [pairing, CheckResult(source: "config/apns.json and mobile_push/apns_outcomes.jsonl", id: pushID, title: pushTitle, status: "unmeasured", detail: phone.detail)]
            }
            return [pairing, CheckResult(source: "config/apns.json and mobile_push/apns_outcomes.jsonl", id: pushID, title: pushTitle, status: phone.paired == 0 ? "not needed" : phone.supported ? "ok" : "warn",
                               detail: phone.detail)]
        } catch {
            let source = (error as NSError).userInfo[NSFilePathErrorKey] as? String ?? "config/apns.json, notifications/push_tokens.json or mobile_push/apns_outcomes.jsonl"
            return [pairing, CheckResult(source: source, id: pushID, title: pushTitle, status: "fail",
                               detail: "Phone notification transport could not be read: \(error.localizedDescription)")]
        }
    }

    /// The phone's pairing and last accepted exchange, as the one assessment
    /// the Connectors › iPhone tab shows; iCloud itself is the iCloud row's.
    /// A pending choice is a reading, not a fault, and wakes no one.
    static func doctorPhoneConnection(_ connection: NAPhoneConnection, id: String, title: String) -> CheckResult {
        let facts = [connection.pairing, connection.exchange]
        let broken = facts.first { $0.state == .broken }
        let recovery = broken ?? facts.first { $0.state == .waiting }
        let personOwned = broken.map { [.personOnMac, .personOnPhone, .iCloudAccount, .network].contains($0.owner) } ?? false
        return CheckResult(source: "phone connection: pairing and last exchange", id: id, title: title,
                           status: broken == nil ? "ok" : "warn",
                           detail: "Pairing: " + connection.pairing.line.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
                               + "; last exchange: " + connection.exchange.line.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) + ".",
                           harm: broken == nil ? nil : "The phone cannot exchange messages with her.",
                           repair: recovery?.lever,
                           human_action: personOwned ? recovery?.lever : nil,
                           ask: personOwned && recovery?.lever != nil ? .permission : nil,
                           owner: broken?.owner == .builder ? .builder : nil)
    }

    private func doctorBodyCheck(_ detail: CognitiveDoctorRead) -> CheckResult {
        let id = "live.cognition.body"
        let title = "Body attention"
        let organism = detail.organism
        guard organism.enabled else {
            return CheckResult(source: "cognition/organism_state.json: residual repair", id: id, title: title, status: "off", detail: "Organism is intentionally off.")
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
            return CheckResult(source: "cognition/organism_state.json: residual repair", id: id, title: title, status: "ok",
                               detail: "No body dependency needs attention; ordinary affect is not damage.")
        }
        return CheckResult(source: "cognition/organism_state.json: residual repair",
            id: id, title: title, status: organism.residualRepairOpportunity.ready ? "warn" : "ok",
            detail: "Body observations: \(causes.joined(separator: ", ")).",
            harm: organism.residualRepairOpportunity.ready ? "A due residual repair remains unfinished." : nil,
            human_action: organism.residualRepairOpportunity.ready
                ? "Press Repair in Diagnostics → Health checks to run the due bounded residual repair; inspect any other named dependency in Status."
                : nil,
            repair_available: organism.residualRepairOpportunity.ready
        )
    }

    private func doctorCognitionReadoutFailures(_ detail: CognitiveDoctorRead) -> [String] {
        var failures: [String] = []
        let configuration = detail.configuration
        if configuration.enabled {
            if !detail.affect.observatoryValuesAreValid {
                failures.append("mood: Affect snapshot contains an invalid value and is withheld")
            }
        }
        let snapshot = detail.organism
        if snapshot.enabled {
            if !snapshot.observatorySampleIsCurrent(now: Date(), maximumSampleAge: 5 * 60) {
                failures.append("body: The last organism body sample is stale or has an invalid timestamp and is withheld")
            } else if !snapshot.observatoryValuesAreValid {
                failures.append("body: The organism body sample contains an invalid value and is withheld")
            }
        }
        return failures
    }

    private func doctorReadoutCheck(_ detail: CognitiveDoctorRead) -> CheckResult {
        let id = "live.cognition.readouts"
        let title = "Cognition body and mood readouts"
        let failures = doctorCognitionReadoutFailures(detail)
        guard !failures.isEmpty else {
            return CheckResult(source: "cognition/organism_state.json", id: id, title: title, status: "ok", detail: "Enabled body and mood readouts are available; disabled readouts are intentional.")
        }
        return CheckResult(source: "cognition/organism_state.json", id: id, title: title, status: "fail",
                           detail: failures.joined(separator: "; ") + ".")
    }

    private func doctorCapacityCheck(_ detail: CognitiveDoctorRead) -> CheckResult {
        let id = "live.cognition.capacity"
        let title = "Cognition capacity"
        guard detail.configuration.enabled else {
            return CheckResult(source: "cognition configuration: capacity", id: id, title: title, status: "off", detail: "Cognition is intentionally off.")
        }
        let counts = [
            ("nodes", detail.substrate.nodeCount, detail.configuration.maximumActiveNodes),
            ("workspace items", detail.workspace.items.count, detail.configuration.maximumWorkspaceItems),
        ]
        let overflow = counts.filter { $0.1 > $0.2 }
        guard !overflow.isEmpty else {
            return CheckResult(source: "cognition configuration: capacity", id: id, title: title, status: "ok", detail: "Nodes and workspace are within their configured caps.")
        }
        // The substrate enforces these caps; a measured overflow is the build's to fix.
        return CheckResult(source: "cognition configuration: capacity", id: id, title: title, status: "warn",
                           detail: "Over cap: \(overflow.map { "\($0.0) \($0.1)/\($0.2)" }.joined(separator: ", ")).",
                           harm: "Her inner workspace can grow beyond its configured memory limits.",
                           owner: .builder)
    }

    private func doctorAssociationCheck(_ detail: CognitiveDoctorRead) -> CheckResult {
        let id = "live.cognition.associations"
        let title = "Cognition association endpoints"
        guard detail.configuration.enabled else {
            return CheckResult(source: "cognition/cognition.sqlite: associations", id: id, title: title, status: "off", detail: "Cognition associations are intentionally off.")
        }
        guard !detail.associations.isEmpty else {
            return CheckResult(source: "cognition/cognition.sqlite: associations", id: id, title: title, status: "ok", detail: "No unresolved association graph is displayed.")
        }
        let nodeIDs = Set(detail.substrate.nodes.map(\.id))
        let allMissing = detail.associations.allSatisfy {
            !nodeIDs.contains($0.fromNodeId) && !nodeIDs.contains($0.toNodeId)
        }
        guard allMissing else {
            return CheckResult(source: "cognition/cognition.sqlite: associations", id: id, title: title, status: "ok", detail: "At least one association endpoint resolves in the current snapshot.")
        }
        return CheckResult(source: "cognition/cognition.sqlite: associations", id: id, title: title, status: "warn",
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
            return CheckResult(source: "Context Flow source registrations", id: id, title: title, status: "off", detail: "Context Flow is intentionally off.")
        case .unavailable:
            return CheckResult(source: "Context Flow source registrations", id: id, title: title, status: "unmeasured",
                               detail: "Configured Context Flow health is unavailable from its owner.")
        case .health(let state):
            if state.mode == .off {
                return CheckResult(source: "Context Flow source registrations", id: id, title: title, status: "off", detail: "Context Flow is intentionally off.")
            }
            var causes: [String] = []
            if !state.started { causes.append("not started") }
            if state.degradedSourceCount > 0 { causes.append("\(state.degradedSourceCount) degraded source(s)") }
            if state.lastError != nil { causes.append("owner error") }
            if state.arenaMetrics.pressure != .normal { causes.append("arena pressure: \(state.arenaMetrics.pressure.rawValue)") }
            guard !causes.isEmpty else {
                return CheckResult(source: "Context Flow source registrations", id: id, title: title, status: "ok", detail: "Context Flow is started and its sources are healthy.")
            }
            let canReconcile = !state.started || state.degradedSourceCount > 0 || state.lastError != nil
            return CheckResult(source: "Context Flow source registrations", id: id, title: title, status: "warn",
                               detail: "Context Flow: \(causes.joined(separator: ", ")).",
                               harm: canReconcile ? "The conversation may miss current context from her enabled sources." : nil,
                               human_action: canReconcile
                                   ? "Press Repair in Diagnostics → Health checks to reconcile the derived Context flow sources once."
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
