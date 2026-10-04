import Foundation
import Cognition
import NativeAgentCore
import ProviderRouting
import CognitiveSubstrate
import Context
import ContextFlow
import PersistenceCore
import Procedures
import PersonaEngine

/// App-owned preferences and transport activity, plus the existing runtime owners.
/// Core chooses state fields; the app encodes and writes the resulting payload.
public protocol ClaudeBridgeStatePort: Sendable {
    var startedAt: Date { get }
    var preferredPersona: String? { get }
    var preferredSessionID: String? { get }
    var cognition: NativeCognitionRuntime { get }
    var contextFlow: NativeContextFlowRuntime { get }
    func recentEventPayloads() -> [[String: Any]]
}

/// Semantic bridge state projection shared with the Core conversation owner.
public enum ClaudeBridgeStateProjection {
    static func procedureStatusJSON(_ status: ProcedureArtifactStatusSnapshot) -> [String: Any] {
        [
            "schema": "compiled.procedure.status.v1",
            "artifacts": status.artifactCount,
            "corruptArtifacts": status.corruptArtifactCount,
            "corruptInvocations": status.corruptInvocationCount,
            "invocations": status.invocationCount,
            "verifiedInvocations": status.verifiedInvocationCount,
            "lastInvocationStatus": status.lastInvocationStatus.map { $0.rawValue as Any }
                ?? NSNull(),
            // There is deliberately no automatic selection path. Local
            // ApprovalInbox review plus an explicit manual invocation remain
            // required even when an artifact exists.
            "automaticSelectionEnabled": status.automaticSelectionEnabled,
            "payloadFree": status.payloadFree,
        ]
    }

    static func microcycleTelemetryJSON(_ telemetry: CognitiveMicrocycleTelemetry) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "schema": "cognition.microcycle.telemetry.v1",
            "runtimeInstanceId": telemetry.runtimeInstanceId,
            "processIdentifier": Int(telemetry.processIdentifier),
            "runtimeInitializedAt": iso.string(from: telemetry.runtimeInitializedAt),
            "scheduledSignals": telemetry.scheduledSignalCount,
            "coalescedReplacements": telemetry.coalescedReplacementCount,
            "executed": telemetry.executedCount,
            "completed": telemetry.completedCount,
            "skipped": telemetry.skippedCount,
            "failed": telemetry.failedCount,
            "lastScheduledAt": telemetry.lastScheduledAt.map { iso.string(from: $0) } ?? NSNull(),
            "lastStartedAt": telemetry.lastStartedAt.map { iso.string(from: $0) } ?? NSNull(),
            "lastFinishedAt": telemetry.lastFinishedAt.map { iso.string(from: $0) } ?? NSNull(),
            "lastReason": telemetry.lastReason ?? NSNull(),
            "lastOutcome": telemetry.lastOutcome ?? NSNull(),
            "lastDurationMilliseconds": telemetry.lastDurationMilliseconds ?? NSNull(),
            "controlAuthority": false,
        ]
    }

    static func contextFlowHealthJSON(
        mode: ContextFlowMode,
        health: ContextFlowCoordinatorHealth?
    ) -> [String: Any] {
        guard let health else {
            return [
                "mode": mode.rawValue,
                "started": false,
                "storeGeneration": NSNull(),
                "arenaGeneration": NSNull(),
                "registeredSources": 0,
                "degradedSources": 0,
                "residentBytes": 0,
                "activeLeases": 0,
                "pressure": NSNull(),
                "prewarmingAllowed": false,
                "pendingPrewarmHints": 0,
                "prewarmUsefulnessReceipts": 0,
                "lastReconciledAt": NSNull(),
                "lastError": NSNull(),
            ]
        }
        let iso = ISO8601DateFormatter()
        return [
            "mode": health.mode.rawValue,
            "started": health.started,
            "storeGeneration": health.activeStoreGenerationID.map { $0 as Any } ?? NSNull(),
            "arenaGeneration": health.activeArenaGenerationID.map { $0 as Any } ?? NSNull(),
            "registeredSources": health.registeredSourceCount,
            "degradedSources": health.degradedSourceCount,
            "residentBytes": health.arenaMetrics.residentLogicalBytes,
            "activeLeases": health.arenaMetrics.activeLeaseCount,
            "pressure": health.arenaMetrics.pressure.rawValue,
            "prewarmingAllowed": health.arenaMetrics.prewarmingAllowed,
            "pendingPrewarmHints": health.pendingPrewarmHints,
            "prewarmUsefulnessReceipts": health.prewarmUsefulnessReceipts,
            "lastReconciledAt": health.lastReconciledAt.map { iso.string(from: $0) as Any }
                ?? NSNull(),
            "lastError": health.lastError.map { $0 as Any } ?? NSNull(),
        ]
    }

    public static func organismSnapshotJSON(_ snapshot: OrganismSnapshot) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let lastSignalAt: Any = snapshot.lastSignalAt.map { iso.string(from: $0) } ?? NSNull()
        return [
            "generatedAt": iso.string(from: snapshot.generatedAt),
            "enabled": snapshot.enabled,
            "promptVisibleBodyLine": snapshot.projectedBodyLine ?? NSNull(),
            "hasPromptVisibleBodyLine": snapshot.projectedBodyLine != nil,
            "signalCount": snapshot.signalCount,
            "lastSignalAt": lastSignalAt,
            "bodySchema": Self.organismBodySchemaJSON(snapshot.bodySchema, iso: iso),
            "chemicalState": [
                "warmth": snapshot.chemicalState.warmth,
                "vigilance": snapshot.chemicalState.vigilance,
                "curiosity": snapshot.chemicalState.curiosity,
                "fatigue": snapshot.chemicalState.fatigue,
                "coherence": snapshot.chemicalState.coherence,
                "agency": snapshot.chemicalState.agency,
                "tenderness": snapshot.chemicalState.tenderness,
                "confidence": snapshot.chemicalState.confidence,
                "novelty": snapshot.chemicalState.novelty,
                "urgency": snapshot.chemicalState.urgency,
            ],
            "field": [
                "nodeCount": snapshot.fieldSummary.nodeCount,
                "edgeCount": snapshot.fieldSummary.edgeCount,
                "strongestEdgeWeight": snapshot.fieldSummary.strongestEdgeWeight,
                "highestActivation": snapshot.fieldSummary.highestActivation,
                "totalCharge": snapshot.fieldSummary.totalCharge,
                "averageUncertainty": snapshot.fieldSummary.averageUncertainty,
            ],
            "prediction": Self.predictionSummaryJSON(snapshot.predictionSummary),
            "dreamRepair": Self.dreamRepairSummaryJSON(snapshot.dreamRepairSummary),
            "residualRepair": [
                "pressure": snapshot.residualRepairOpportunity.pressure,
                "predictionResidual": snapshot.residualRepairOpportunity.predictionResidual,
                "fieldChargeResidual": snapshot.residualRepairOpportunity.fieldChargeResidual,
                "fieldUncertaintyResidual": snapshot.residualRepairOpportunity.fieldUncertaintyResidual,
                "evidenceCount": snapshot.residualRepairOpportunity.evidenceCount,
                "chargedTargetCount": snapshot.residualRepairOpportunity.chargedNodeIDs.count,
                "noisyTargetCount": snapshot.residualRepairOpportunity.noisyEdgeIDs.count,
                "ready": snapshot.residualRepairOpportunity.ready,
                "quietUntil": snapshot.residualRepairOpportunity.quietUntil.map { iso.string(from: $0) } ?? NSNull(),
                "nextRepairAt": snapshot.residualRepairOpportunity.nextRepairAt.map { iso.string(from: $0) } ?? NSNull(),
            ],
            "capabilityBeliefs": snapshot.capabilityBeliefs.map { belief in
                [
                    "kind": belief.kind.rawValue,
                    "successLikelihood": belief.successLikelihood,
                    "uncertainty": belief.uncertainty,
                    "evidenceCount": belief.evidenceCount,
                    "resolvedEvidenceCount": belief.resolvedEvidenceCount,
                    "expiredEvidenceCount": belief.expiredEvidenceCount,
                    "freshness": belief.freshness,
                    "lastEvidenceAt": belief.lastEvidenceAt.map { iso.string(from: $0) } ?? NSNull(),
                    "evidenceBasis": belief.evidenceBasis.rawValue,
                ] as [String: Any]
            },
            "behavior": Self.organismBehaviorJSON(OrganismBehaviorPosture.from(snapshot: snapshot)),
        ]
    }

    static func organismBodySchemaJSON(
        _ body: BodySchema,
        iso: ISO8601DateFormatter = ISO8601DateFormatter()
    ) -> [String: Any] {
        [
            "macAwake": body.macAwake,
            "iPhoneReachable": body.iPhoneReachable,
            "providersAvailable": body.providersAvailable,
            "providersHealthy": body.providersHealthy,
            "providerPathBelief": body.providerPathBelief.map { belief -> Any in
                [
                    "estimate": belief.estimate,
                    "freshness": belief.freshness,
                    "uncertainty": belief.uncertainty,
                    "evidenceCount": belief.evidenceCount,
                    "newestEvidenceAt": belief.newestEvidenceAt.map { iso.string(from: $0) } ?? NSNull(),
                    "state": belief.state.rawValue,
                ] as [String: Any]
            } ?? NSNull(),
            "peerPresenceBelief": body.peerPresenceBelief.map { belief -> Any in
                Self.bodyBeliefJSON(
                    category: belief.category.rawValue,
                    metrics: belief.metrics,
                    iso: iso
                )
            } ?? NSNull(),
            "notificationDeliveryBelief": body.notificationDeliveryBelief.map { belief -> Any in
                Self.bodyBeliefJSON(
                    category: belief.category.rawValue,
                    metrics: belief.metrics,
                    iso: iso,
                    details: [
                        "transportConfigured": belief.transportConfigured,
                        "transportAccepted": belief.transportAccepted,
                        "deviceReceived": belief.deviceReceived,
                        "displayed": belief.displayed,
                        "userSeen": belief.userSeen,
                        "transportFailed": belief.transportFailed,
                    ]
                )
            } ?? NSNull(),
            "memoryIntegrityReading": body.memoryIntegrityReading.map { reading -> Any in
                Self.bodyBeliefJSON(
                    category: reading.category.rawValue,
                    metrics: reading.metrics,
                    iso: iso
                )
            } ?? NSNull(),
            "dreamIntegrityReading": body.dreamIntegrityReading.map { reading -> Any in
                Self.bodyBeliefJSON(
                    category: reading.category.rawValue,
                    metrics: reading.metrics,
                    iso: iso,
                    details: ["storeAvailable": reading.storeAvailable]
                )
            } ?? NSNull(),
            "toolCapabilityReading": body.toolCapabilityReading.map { reading -> Any in
                Self.bodyBeliefJSON(
                    category: reading.category.rawValue,
                    metrics: reading.metrics,
                    iso: iso,
                    details: [
                        "configured": reading.configured,
                        "liveCapabilityObserved": reading.liveCapabilityObserved,
                    ]
                )
            } ?? NSNull(),
            "approvalPathReading": body.approvalPathReading.map { reading -> Any in
                Self.bodyBeliefJSON(
                    category: reading.category.rawValue,
                    metrics: reading.metrics,
                    iso: iso,
                    details: ["writable": reading.writable]
                )
            } ?? NSNull(),
            "resourcePressureReading": body.resourcePressureReading.map { reading -> Any in
                Self.bodyBeliefJSON(
                    category: reading.category.rawValue,
                    metrics: reading.metrics,
                    iso: iso,
                    details: [
                        "thermalPressure": reading.thermalPressure.rawValue,
                        "lowPowerMode": reading.lowPowerMode,
                    ]
                )
            } ?? NSNull(),
            "memoryHealthy": body.memoryHealthy,
            "dreamHealthy": body.dreamHealthy,
            "toolHandsAvailable": body.toolHandsAvailable,
            "approvalChannelsOpen": body.approvalChannelsOpen,
            "notificationPathHealthy": body.notificationPathHealthy,
            "resourcePressure": body.resourcePressure.rawValue,
        ]
    }

    private static func bodyBeliefJSON(
        category: String,
        metrics: BodyBeliefMetrics,
        iso: ISO8601DateFormatter,
        details: [String: Any] = [:]
    ) -> [String: Any] {
        var result: [String: Any] = [
            "category": category,
            "estimate": metrics.estimate,
            "uncertainty": metrics.uncertainty,
            "freshness": metrics.freshness,
            "evidenceCount": metrics.evidence.count,
            "evidenceClasses": Array(Set(metrics.evidence.map { $0.evidenceClass.rawValue })).sorted(),
            "observedAt": metrics.observedAt.map { iso.string(from: $0) } ?? NSNull(),
            "receivedAt": metrics.receivedAt.map { iso.string(from: $0) } ?? NSNull(),
            "nextMeaningfulExpiry": metrics.nextMeaningfulExpiry.map { iso.string(from: $0) } ?? NSNull(),
        ]
        for (key, value) in details { result[key] = value }
        return result
    }

    static func organismBehaviorJSON(_ posture: OrganismBehaviorPosture?) -> Any {
        guard let posture else { return NSNull() }
        return [
            "posture": posture.posture,
            "toolClaims": posture.claimDiscipline.rawValue,
            "toolStrategy": posture.toolStrategy.rawValue,
            "loopBudget": posture.loopBudget.rawValue,
            "notificationRequiresReceipt": posture.notificationRequiresReceipt,
            "directives": posture.directives,
            "reviewSignals": posture.reviewSignals,
        ]
    }

    private static func predictionSummaryJSON(_ summary: OrganismPredictionSummary) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "pendingCount": summary.pendingCount,
            "satisfiedCount": summary.satisfiedCount,
            "violatedCount": summary.violatedCount,
            "expiredCount": summary.expiredCount,
            "averagePendingConfidence": summary.averagePendingConfidence,
            "averagePendingUncertainty": summary.averagePendingUncertainty,
            "peripheralUncertainty": summary.peripheralUncertainty,
            "strategyCaution": summary.strategyCaution,
            "lastViolationAt": summary.lastViolationAt.map { iso.string(from: $0) } ?? NSNull(),
            "bodyConfidence": [
                "providerPath": summary.bodyConfidence.providerPath,
                "toolPath": summary.bodyConfidence.toolPath,
                "phonePath": summary.bodyConfidence.phonePath,
                "approvalPath": summary.bodyConfidence.approvalPath,
                "workflowPath": summary.bodyConfidence.workflowPath,
            ],
        ]
    }

    private static func dreamRepairSummaryJSON(_ summary: OrganismDreamRepairSummary) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "receiptCount": summary.receiptCount,
            "lastRepairAt": summary.lastRepairAt.map { iso.string(from: $0) } ?? NSNull(),
            "lastReason": summary.lastReason ?? NSNull(),
            "lastOperationCount": summary.lastOperationCount,
            "softenedNodes": summary.softenedNodes,
            "strengthenedEdges": summary.strengthenedEdges,
            "weakenedEdges": summary.weakenedEdges,
            "flaggedContradictions": summary.flaggedContradictions,
            "proposedStandingViews": summary.proposedStandingViews,
            "feltDaySummaryCharacters": summary.feltDaySummaryCharacters,
            "latestEvidence": summary.latestEvidence.map { evidence in
                [
                    "id": evidence.id,
                    "label": evidence.label,
                    "summary": evidence.summary,
                ]
            },
            "standingViewProposals": summary.standingViewProposals.map { proposal in
                [
                    "id": proposal.id,
                    "title": proposal.title,
                    "rationale": proposal.rationale,
                    "evidenceIDs": proposal.evidenceIDs,
                    "reviewRequired": proposal.reviewRequired,
                ]
            },
        ]
    }
}

extension ClaudeBridgeStateProjection {
    public static func statePayload(dataRoot: URL, port: any ClaudeBridgeStatePort) async -> [String: Any] {
        let readErrors = BridgeReadErrors()
        let routing: ProviderRoutingSnapshot?
        do { routing = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedRoutingSnapshot() }
        catch {
            routing = nil
            readErrors.note(dataRoot.appendingPathComponent("providers"), error.localizedDescription)
        }
        let activeModel = routing?.preferences["chat"]?.model
        let activeProvider = routing?.activeProviders["chat"]
        let activePersona = readActivePersona(dataRoot: dataRoot, preferred: port.preferredPersona)
        let (activeSessionId, _) = readBridgeActiveSession(dataRoot: dataRoot, preferred: { port.preferredSessionID }, errors: readErrors)
        let recentInbox = readRecentInbox(dataRoot: dataRoot, limit: 10, errors: readErrors)

        let uptime = Int(Date().timeIntervalSince(port.startedAt))
        let buildIdentity = NativeAgentBuildIdentity.current

        // Phase 3b: recentToolCalls now wired from the bridge's own ring buffer.
        // Surfaces the last N /claude/tool dispatches + /claude/message turns
        // so Claude can see what the configured agent has just been doing
        // having to subscribe to the SSE stream. The full live feed is at
        // GET /claude/events.
        let recentToolCallsJSON = port.recentEventPayloads()

        var payload: [String: Any] = [
            "activeSessionId": activeSessionId ?? NSNull(),
            "activePersona": activePersona ?? NSNull(),
            "activeModel": activeModel ?? NSNull(),
            "activeProvider": activeProvider ?? NSNull(),
            "chatReady": routing != nil && routing?.unusablePickNotice(for: "chat") == nil
                && !(activeModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && !(activeProvider?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            // Empty when every state file was readable OR legitimately absent.
            // A non-empty row means a file exists but could not be read or
            // decoded — the empty payload above is a failure, not "nothing yet".
            "readErrors": readErrors.messages,
            "recentInbox": recentInbox,
            "recentToolCalls": recentToolCallsJSON,
            "buildVersion": buildIdentity.version,
            "buildIdentity": buildIdentity.bridgePayload,
            "uptimeSeconds": uptime,
        ]
        let organism = await port.cognition.organismSnapshot()
        payload["organism"] = Self.organismSnapshotJSON(organism)
        let contextFlowMode = await port.contextFlow.contextFlowMode()
        let contextFlowHealth = await port.contextFlow.health()
        payload["contextFlow"] = Self.contextFlowHealthJSON(
            mode: contextFlowMode,
            health: contextFlowHealth
        )
        let capsule = await port.cognition.lastInjectedCapsuleBridgeSummary()
        let microcycle = await port.cognition.microcycleTelemetrySnapshot()
        payload["cognition"] = [
            "lastInjectedCapsule": Self.capsuleSummaryJSON(capsule),
            "microcycle": Self.microcycleTelemetryJSON(microcycle),
        ]
        let procedureStatus = await ProcedureArtifactStore(dataRoot: dataRoot).statusSnapshot()
        payload["compiledProcedure"] = Self.procedureStatusJSON(procedureStatus)
        return payload
    }

    private static func capsuleSummaryJSON(_ summary: CognitiveBridgeCapsuleSummary) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "source": summary.source,
            "generatedAt": summary.generatedAt.map { iso.string(from: $0) } ?? NSNull(),
            "hasBodyLine": summary.hasBodyLine,
            "bodyLine": summary.bodyLine ?? NSNull(),
            "dynamicContextCharacters": summary.dynamicContextCharacters,
            "truncated": summary.truncated ?? NSNull(),
        ]
    }

    /// Collector for `/claude/state` read failures. The state helpers all fail
    /// soft (an absent file is a legitimate "nothing here yet"), which used to
    /// make "no providers / no session / no inbox" indistinguishable from a
    /// permissions error or a half-written JSON file. Absent stays silent;
    /// unreadable or undecodable gets a row here and is published as
    /// `readErrors` so the caller can tell the two apart.
    final class BridgeReadErrors {
        private(set) var messages: [String] = []
        func note(_ url: URL, _ reason: String) {
            messages.append("\(url.path): \(reason)")
        }
    }

    /// Returns nil for BOTH absent (silent) and unreadable (noted).
    private static func readStateFile(_ url: URL, errors: BridgeReadErrors?) -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as NSError {
            let absent = error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
            if !absent { errors?.note(url, "read failed: \(error.localizedDescription)") }
            return nil
        }
    }

    public static func readActivePersona(dataRoot: URL, preferred: String?) -> String? {
        if let s = preferred, !s.isEmpty { return s }
        let root = PersonaRootResolver.resolve(dataRootProvider: { dataRoot })
        return try? PersonaCompiler.selectedPersonaID(root: root, personaOverride: nil)
    }

    public static func readBridgeActiveSession(
        dataRoot: URL,
        preferred: () -> String?
    ) -> (id: String?, updatedAt: String?) {
        readBridgeActiveSession(dataRoot: dataRoot, preferred: preferred, errors: nil)
    }

    private static func readBridgeActiveSession(
        dataRoot: URL,
        preferred: () -> String?,
        errors: BridgeReadErrors?
    ) -> (id: String?, updatedAt: String?) {
        let url = dataRoot.appendingPathComponent("chat/sessions.json")
        guard let data = readStateFile(url, errors: errors) else { return (nil, nil) }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            errors?.note(url, "decode failed: not a JSON array of objects")
            return (nil, nil)
        }
        return Self.bridgeActiveSession(
            preferred: preferred(),
            rows: arr
        )
    }

    static func bridgeActiveSession(
        preferred: String?,
        rows: [[String: Any]]
    ) -> (id: String?, updatedAt: String?) {
        let live = rows.filter { ($0["archived"] as? Bool) != true }
        let preferred = preferred?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !preferred.isEmpty,
           let selected = live.first(where: { ($0["id"] as? String) == preferred }) {
            return (selected["id"] as? String, selected["updatedAt"] as? String)
        }
        let sorted = live.sorted { (a, b) in
            let ta = (a["updatedAt"] as? String) ?? ""
            let tb = (b["updatedAt"] as? String) ?? ""
            return ta > tb
        }
        guard let top = sorted.first else { return (nil, nil) }
        return (top["id"] as? String, top["updatedAt"] as? String)
    }

    private static func readRecentInbox(
        dataRoot: URL,
        limit: Int,
        errors: BridgeReadErrors? = nil
    ) -> [[String: Any]] {
        // A5.2 (2026-07-23): read the LIVE inbox the UI/getInboxItems/iOS read,
        // not the retired `inbox/items.jsonl` silo (last written Jun 12, dead).
        let url = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        guard let data = readStateFile(url, errors: errors) else { return [] }
        guard let raw = String(data: data, encoding: .utf8) else {
            errors?.note(url, "decode failed: not UTF-8")
            return []
        }
        var items: [[String: Any]] = []
        var malformedLines = 0
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.suffix(limit * 2) {
            guard let lineData = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                malformedLines += 1
                continue
            }
            items.append([
                "id": obj["id"] ?? NSNull(),
                "kind": obj["source"] ?? NSNull(),
                "title": obj["title"] ?? NSNull(),
                "body": obj["summary"] ?? NSNull(),
                "createdAt": obj["created_at"] ?? NSNull(),
            ])
        }
        if malformedLines > 0 {
            errors?.note(url, "decode failed: \(malformedLines) undecodable JSONL line(s)")
        }
        return Array(items.suffix(limit))
    }
}
