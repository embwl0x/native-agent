import Foundation
import Network
import NativeAgentCore
import ProviderRouting
import CognitiveSubstrate
import Context
import PersistenceCore

/// Pure bridge JSON projections of typed runtime snapshots.
extension ClaudeBridge {
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

    /// HTTP is only the immediate operator feedback. The telemetry record is
    /// emitted first and remains the audit surface even when this response is
    /// not delivered before the bridge deadline.
    static func organismReflexReviewHTTPStatus(for status: OrganismReflexReviewApplyStatus) -> Int {
        switch status {
        case .applied:
            // An `applied` outcome without its required receipt is an internal
            // consistency failure, not a successful review.
            return 500
        case .organismDisabled, .persistenceFailed:
            return 503
        case .candidateNotFound:
            return 404
        case .reviewInFlight, .notAwaitingReview:
            return 409
        case .approvalRequiresLowRisk:
            return 422
        }
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

    static func organismSnapshotJSON(_ snapshot: OrganismSnapshot) -> [String: Any] {
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
            "reflex": Self.reflexSummaryJSON(
                snapshot.reflexSummary,
                candidates: snapshot.reflexCandidates,
                receipts: snapshot.reflexReviewReceipts
            ),
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
            "approvedReflexBiases": posture.approvedReflexBiases,
            "reviewRequiredReflexCount": posture.reviewRequiredReflexCount ?? 0,
            "approvedLowRiskReflexTotalCount": max(
                posture.approvedReflexBiasSampleCount,
                posture.approvedLowRiskReflexTotalCount ?? posture.approvedReflexBiasSampleCount
            ),
            "approvedReflexBiasSampleCount": posture.approvedReflexBiasSampleCount,
            "approvedReflexBiasesAreSampled": posture.approvedReflexBiasesAreSampled,
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

    private static func reflexSummaryJSON(
        _ summary: OrganismReflexSummary,
        candidates: [OrganismReflexCandidate] = [],
        receipts: [OrganismReflexReviewReceipt] = []
    ) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "candidateCount": summary.candidateCount,
            "reviewRequiredCount": summary.reviewRequiredCount,
            "lowRiskCount": summary.lowRiskCount,
            "approvedLowRiskCount": summary.approvedLowRiskCount,
            "confirmRequiredCount": summary.confirmRequiredCount,
            "highRiskCount": summary.highRiskCount,
            "reviewReceiptCount": summary.reviewReceiptCount,
            "highestConfidence": summary.highestConfidence,
            "lastCandidatePattern": summary.lastCandidatePattern ?? NSNull(),
            "lastUpdatedAt": summary.lastUpdatedAt.map { iso.string(from: $0) } ?? NSNull(),
            "candidates": candidates.map { Self.reflexCandidateJSON($0, iso: iso) },
            "reviewReceipts": receipts.map { Self.reflexReviewReceiptJSON($0, iso: iso) },
        ]
    }

    private static func reflexCandidateJSON(_ candidate: OrganismReflexCandidate, iso: ISO8601DateFormatter) -> [String: Any] {
        [
            "id": candidate.id,
            "pattern": candidate.pattern,
            "trustClass": candidate.trustClass.rawValue,
            "evidenceCount": candidate.evidenceCount,
            "successCount": candidate.successCount,
            "failureCount": candidate.failureCount,
            "confidence": candidate.confidence,
            "reviewRequired": candidate.reviewRequired,
            "autoActivationAllowed": candidate.autoActivationAllowed,
            "approvedAt": candidate.approvedAt.map { iso.string(from: $0) } ?? NSNull(),
            "retiredAt": candidate.retiredAt.map { iso.string(from: $0) } ?? NSNull(),
            "rejectedAt": candidate.rejectedAt.map { iso.string(from: $0) } ?? NSNull(),
            "permanentlyDeliberate": candidate.isPermanentlyDeliberate,
            "lastReviewDecision": candidate.lastReviewDecision?.rawValue ?? NSNull(),
            "lastReviewedAt": candidate.lastReviewedAt.map { iso.string(from: $0) } ?? NSNull(),
            "lastReviewedBy": candidate.lastReviewedBy ?? NSNull(),
            "reviewNote": candidate.reviewNote ?? NSNull(),
            "firstSeenAt": iso.string(from: candidate.firstSeenAt),
            "lastUpdatedAt": iso.string(from: candidate.lastUpdatedAt),
        ]
    }

    private static func reflexReviewReceiptJSON(
        _ receipt: OrganismReflexReviewReceipt,
        iso: ISO8601DateFormatter
    ) -> [String: Any] {
        [
            "id": receipt.id,
            "candidateId": receipt.candidateID,
            "pattern": receipt.pattern,
            "trustClass": receipt.trustClass.rawValue,
            "decision": receipt.decision.rawValue,
            "reviewedAt": iso.string(from: receipt.reviewedAt),
            "reviewedBy": receipt.reviewedBy,
            "source": receipt.source,
            "note": receipt.note ?? NSNull(),
            "evidenceCount": receipt.evidenceCount,
            "successCount": receipt.successCount,
            "failureCount": receipt.failureCount,
            "confidence": receipt.confidence,
            "autoActivationAllowed": receipt.autoActivationAllowed,
            "permanentlyDeliberate": receipt.permanentlyDeliberate,
        ]
    }

}

// State route and disk readers share the bridge snapshot projection owner.
extension ClaudeBridge {
    // MARK: - /claude/state

    func handleState(conn: NWConnection) {
        // Same WorkLatch + asyncAfter bound as handleMessage/handleTool: exactly
        // one of the work Task and the deadline writes the response.
        let workLatch = WorkLatch()
        let workTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let payload = await self.statePayload()
            guard workLatch.claim() else { return }
            self.writeJSON(conn, status: 200, obj: payload)
        }
        workLatch.arm(afterSeconds: Self.readWorkDeadlineSeconds) { [weak self] in
            guard let self, workLatch.claim() else { return }
            workTask.cancel()
            self.writeJSON(conn, status: 504, obj: [
                "error": "work_timeout",
                "path": "/claude/state",
                "seconds": Self.readWorkDeadlineSeconds,
            ])
        }
    }

    private func statePayload() async -> [String: Any] {
        let dataRoot = NativeAgentPaths.dataRoot
        let readErrors = BridgeReadErrors()
        let surfaces = readSurfaces(dataRoot: dataRoot, errors: readErrors)
        let chatSurface = surfaces["chat"] ?? [:]
        let activeModel = chatSurface["model"] as? String
        // Provider is not persisted per-surface in surfaces.json; infer from
        // model prefix as a best-effort signal.
        let activeProvider = inferProvider(model: activeModel)
        let activePersona = readActivePersona(dataRoot: dataRoot)
        let (activeSessionId, _) = readBridgeActiveSession(dataRoot: dataRoot, errors: readErrors)
        let recentInbox = readRecentInbox(dataRoot: dataRoot, limit: 10, errors: readErrors)

        let uptime = Int(Date().timeIntervalSince(startedAt))
        let buildIdentity = NativeAgentBuildIdentity.current

        // Phase 3b: recentToolCalls now wired from the bridge's own ring buffer.
        // Surfaces the last N /claude/tool dispatches + /claude/message turns
        // so Claude can see what the configured agent has just been doing
        // having to subscribe to the SSE stream. The full live feed is at
        // GET /claude/events.
        let recentToolCallsJSON = recentEventPayloads()

        var payload: [String: Any] = [
            "activeSessionId": activeSessionId ?? NSNull(),
            "activePersona": activePersona ?? NSNull(),
            "activeModel": activeModel ?? NSNull(),
            "activeProvider": activeProvider ?? NSNull(),
            "chatReady": true,
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
        let organism = await NativeCognitionRuntime.shared.organismSnapshot()
        payload["organism"] = Self.organismSnapshotJSON(organism)
        let contextFlowMode = await NativeContextFlowRuntime.shared.contextFlowMode()
        let contextFlowHealth = await NativeContextFlowRuntime.shared.health()
        payload["contextFlow"] = Self.contextFlowHealthJSON(
            mode: contextFlowMode,
            health: contextFlowHealth
        )
        let capsule = await NativeCognitionRuntime.shared.lastInjectedCapsuleBridgeSummary()
        let microcycle = await NativeCognitionRuntime.shared.microcycleTelemetrySnapshot()
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
    private func readStateFile(_ url: URL, errors: BridgeReadErrors?) -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as NSError {
            let absent = error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
            if !absent { errors?.note(url, "read failed: \(error.localizedDescription)") }
            return nil
        }
    }

    private func readSurfaces(dataRoot: URL, errors: BridgeReadErrors? = nil) -> [String: [String: Any]] {
        let url = dataRoot.appendingPathComponent("providers/surfaces.json")
        guard let data = readStateFile(url, errors: errors) else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            errors?.note(url, "decode failed: not a JSON object")
            return [:]
        }
        var out: [String: [String: Any]] = [:]
        for (k, v) in json {
            if let dict = v as? [String: Any] { out[k] = dict }
        }
        return out
    }

    private func inferProvider(model: String?) -> String? {
        guard let m = model?.lowercased() else { return nil }
        // Kimi Code exact ids BEFORE the kimi- prefix → moonshot branch, same
        // ordering as the three ProviderRouting classifiers (gpt-5.5 review
        // LOW: this local status classifier had drifted).
        if FirstPartyModelCatalog.kimiCodeModelIDSet.contains(m) { return "kimi-code" }
        if m.hasPrefix("claude") || m.hasPrefix("anthropic/") { return "anthropic" }
        if m.hasPrefix("gpt") || m.hasPrefix("openai/") || m.hasPrefix("o1") || m.hasPrefix("o3") { return "openai" }
        if m.hasPrefix("kimi-") || m.hasPrefix("moonshot-") { return "moonshot" }
        if m.contains("/") { return "openrouter" }
        return nil
    }

    func readActivePersona(dataRoot: URL) -> String? {
        // Persona is selected via UserDefaults "chatPersona" in Mac UI; the
        // compiled persona profile is the source-of-truth. Read the default.
        let key = "chatPersona"
        if let s = UserDefaults.standard.string(forKey: key), !s.isEmpty { return s }
        let personaDir = dataRoot.deletingLastPathComponent().appendingPathComponent("persona", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: personaDir.path) {
            return entries.sorted().first { !$0.hasPrefix(".") }
        }
        return nil
    }

    func readBridgeActiveSession(
        dataRoot: URL,
        errors: BridgeReadErrors? = nil
    ) -> (id: String?, updatedAt: String?) {
        let url = dataRoot.appendingPathComponent("chat/sessions.json")
        guard let data = readStateFile(url, errors: errors) else { return (nil, nil) }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            errors?.note(url, "decode failed: not a JSON array of objects")
            return (nil, nil)
        }
        return Self.bridgeActiveSession(
            preferred: UserDefaults.standard.string(forKey: "activeChatSessionId"),
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

    private func readRecentInbox(
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
