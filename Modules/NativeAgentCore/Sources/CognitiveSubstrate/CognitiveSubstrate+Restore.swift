import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    public func backupPersistentStateForDoctor() async throws -> URL {
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        return try await store.backupForDoctor()
    }

    public func restorePersistentState() async throws {
        guard configuration.enabled else { return }
        guard configuration.persistenceEnabled else {
            persistenceWritesBlocked = false
            persistenceHealth = .disabled
            return
        }
        guard !restoreInFlight else {
            throw CognitivePersistenceError.writesBlocked(status: .restoring, detail: nil)
        }
        restoreInFlight = true
        defer { restoreInFlight = false }
        await waitForMaintenanceTransition()

        let attemptAt = dependencies.now()
        guard let store else {
            persistenceWritesBlocked = true
            persistenceHealth = CognitivePersistenceHealth(
                status: .degraded,
                writesBlocked: true,
                lastRestoreAttemptAt: attemptAt,
                lastSuccessfulRestoreAt: persistenceHealth.lastSuccessfulRestoreAt,
                failureStage: "store",
                failureDetail: CognitivePersistenceError.storeUnavailable.description
            )
            throw CognitivePersistenceError.storeUnavailable
        }

        let previouslyDegraded = persistenceHealth.status == .degraded
        let previousSuccessAt = persistenceHealth.lastSuccessfulRestoreAt
        persistenceWritesBlocked = true
        persistenceHealth = CognitivePersistenceHealth(
            status: .restoring,
            writesBlocked: true,
            lastRestoreAttemptAt: attemptAt,
            lastSuccessfulRestoreAt: previousSuccessAt
        )

        let bundle: CognitiveSQLiteRestoreBundle
        do {
            bundle = try await store.loadRestoreBundle(
                artifactFamilies: restoreArtifactFamilyLoads()
            )
            try validateRestoreBundle(bundle)
        } catch {
            let stage = restoreFailureStage(for: error)
            let detail = bounded(String(describing: error), maxCharacters: 320)
            persistenceWritesBlocked = true
            persistenceHealth = CognitivePersistenceHealth(
                status: .degraded,
                writesBlocked: true,
                lastRestoreAttemptAt: attemptAt,
                lastSuccessfulRestoreAt: previousSuccessAt,
                failureStage: stage,
                failureDetail: detail
            )
            try? await store.appendReceipt(
                kind: "lifecycle.restore_degraded",
                payload: .object([
                    "status": .string("degraded"),
                    "failureStage": .string(stage),
                    "error": .string(detail),
                    "writesBlocked": .bool(true),
                ]),
                at: attemptAt
            )
            throw error
        }

        // Read resident state AFTER the suspended load. On recovery it is the
        // complete current family, including removals; on the first load its
        // accepted rows overlay the persisted family.
        await waitForMaintenanceTransition()
        let resident = residentRestoreArtifacts(at: dependencies.now())
        var reconciled = bundle
        for (family, rows) in resident {
            if residentRestoreIsAuthoritative {
                reconciled.artifacts[family] = rows
            } else if !rows.isEmpty {
                let identityField = family == "rumination_release" ? "seedId" : "id"
                if rows.allSatisfy({ row in
                    guard case .object(let object) = row else { return false }
                    return uuidValue(object[identityField]) != nil
                }) {
                    let residentIDs = Set(rows.compactMap { row -> UUID? in
                        guard case .object(let object) = row else { return nil }
                        return uuidValue(object[identityField])
                    })
                    reconciled.artifacts[family] = (bundle.artifacts[family] ?? []).filter { row in
                        guard case .object(let object) = row,
                              let id = uuidValue(object[identityField]) else { return false }
                        return !residentIDs.contains(id)
                    } + rows
                } else {
                    reconciled.artifacts[family] = rows
                }
            }
        }
        let clampedStandingViewIds = applyRestoreBundle(reconciled)
        residentRestoreIsAuthoritative = true
        // Commit the reconciled nodes and artifacts together, including the
        // exact bounded seed family and resident removals.
        do {
            try await persistReconciledRestoreState(replacing: bundle)
        } catch {
            persistenceWritesBlocked = true
            persistenceHealth = CognitivePersistenceHealth(
                status: .degraded, writesBlocked: true,
                lastRestoreAttemptAt: attemptAt, lastSuccessfulRestoreAt: previousSuccessAt,
                failureStage: "restore_reconciliation",
                failureDetail: bounded(String(describing: error), maxCharacters: 320)
            )
            throw error
        }
        persistenceWritesBlocked = false
        persistenceHealth = CognitivePersistenceHealth(
            status: .healthy,
            writesBlocked: false,
            lastRestoreAttemptAt: attemptAt,
            lastSuccessfulRestoreAt: dependencies.now()
        )
        await reconcileRestoredAffectWithRecentConversation(nodes: field.peekNodes())
        publishAttentionProjection(at: dependencies.now())
        // Defensive repair: a half-persisted approval (crash between the active upsert and
        // the cap deletes) could leave >cap active rows — demote LRU + heal the store.
        await repairStandingViewCapIfNeeded()
        // Persist any future-timestamp clamps so the repair survives restarts.
        await persistClampedStandingViews(ids: clampedStandingViewIds)
        try? await store.appendReceipt(
            kind: "lifecycle.restore",
            payload: .object([
                "nodeCount": .int(Int64(field.peekNodes().count)),
                "thoughtSeedCount": .int(Int64(projectedThoughtSeeds(at: dependencies.now()).count)),
                "episodeCount": .int(Int64(episodes.count)),
                "schemaProposalCount": .int(Int64(schemaProposals.count)),
                "timelineCount": .int(Int64(developmentalTimeline.count)),
                "reflectionCount": .int(Int64(reflectionReceipts.count)),
                "experimentCount": .int(Int64(experimentResults.count)),
                "status": .string(previouslyDegraded ? "recovered" : "restored"),
                "writesBlocked": .bool(false),
            ]),
            at: dependencies.now()
        )
    }

    private func residentRestoreArtifacts(at now: Date) -> [String: [JSONValue]] {
        var rows: [String: [JSONValue]] = [
            "thought_seed": thoughtSeeds.values.map { $0.toJSON() },
            "episode": episodes.values.map { $0.toJSON() },
            "schema_proposal": schemaProposals.values.map { $0.toJSON() },
            "standing_view": standingViews.values.map { $0.toJSON() },
            "developmental_timeline": developmentalTimeline.values.map { $0.toJSON() },
            "reflection_receipt": reflectionReceipts.values.map { $0.toJSON() },
            "experiment": experimentResults.values.map { $0.toJSON() },
            "rumination_release": ruminationReleasedAt.map { id, at in
                .object(["seedId": .string(id.uuidString), "releasedAt": .double(at.timeIntervalSince1970)])
            },
            "emotional_consolidation": lastEmotionalConsolidationAt.map {
                [.object(["ranAt": .double($0.timeIntervalSince1970)])]
            } ?? [],
            "affect": [], "capsule_presentation": [], "disposition": [],
            "dream_residue": [], "mind_ledger": [],
        ]
        if residentRestoreIsAuthoritative || affect != CognitiveAffectState() {
            rows["affect"] = [affect.toJSON(
                lastUserPresenceAt: lastUserPresenceAt, lastWarmPresenceAt: lastWarmPresenceAt)]
        }
        if residentRestoreIsAuthoritative || capsulePresentationDirty {
            rows["capsule_presentation"] = [capsulePresentationArtifactPayload(at: now)]
        }
        if residentRestoreIsAuthoritative || disposition != CognitiveDisposition() {
            rows["disposition"] = [dispositionArtifactPayload(at: disposition.updatedAt)]
        }
        if residentRestoreIsAuthoritative || dreamResidueClaimKey != nil || dreamResidue != nil {
            rows["dream_residue"] = [dreamResidueArtifactPayload(at: now)]
        }
        if residentRestoreIsAuthoritative || !associationSuppressions.isEmpty || !undoLedger.isEmpty {
            rows["mind_ledger"] = [mindLedgerArtifactPayload(at: now)]
        }
        return rows
    }

    private func restoreArtifactID(family: String, payload: JSONValue) -> UUID {
        guard case .object(let object) = payload else { return stableArtifactID(family) }
        if family == "rumination_release", let seedID = uuidValue(object["seedId"]) {
            return stableArtifactID("rumination_release|\(seedID.uuidString)")
        }
        return uuidValue(object["id"]) ?? stableArtifactID(family)
    }

    private func persistReconciledRestoreState(replacing bundle: CognitiveSQLiteRestoreBundle) async throws {
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        let now = dependencies.now()
        let families = residentRestoreArtifacts(at: now)
        var artifacts: [CognitiveArtifactWrite] = []
        var retainedIDs: Set<UUID> = []
        for (family, rows) in families where family != "thought_seed" {
            for payload in rows {
                guard case .object(let object) = payload else { continue }
                let id = restoreArtifactID(family: family, payload: payload)
                if family == "standing_view", stringValue(object["status"]) == "retired" { continue }
                retainedIDs.insert(id)
                // Counts in this diagnostic payload live only in SQLite. A
                // matching consolidation clock does not replace that evidence.
                if family == "emotional_consolidation",
                   case .object(let persisted)? = bundle.artifacts[family]?.first,
                   object["ranAt"] == persisted["ranAt"] { continue }
                var status = stringValue(object["status"]) ?? "current"
                var score = doubleValue(object["confidence"]) ?? doubleValue(object["score"]) ?? 0
                switch family {
                case "episode", "developmental_timeline": status = "recorded"; score = 0.5
                case "reflection_receipt": status = object["cancelled"] == .bool(true) ? "cancelled" : "recorded"
                case "experiment": status = "recorded"
                case "rumination_release": status = "released"
                case "standing_view": score = max(0, doubleValue(object["moodValenceAtFormation"]) ?? 0)
                case "disposition": score = ((doubleValue(object["valence"]) ?? 0) + 1) / 2
                case "affect": score = doubleValue(object["arousal"]) ?? 0
                default: break
                }
                artifacts.append(CognitiveArtifactWrite(
                    kind: family, id: id, status: status, score: score, payload: payload
                ))
            }
        }
        let deletedIDs = bundle.artifacts.flatMap { family, rows in
            family == "thought_seed" ? [] : rows.map { restoreArtifactID(family: family, payload: $0) }
        }.filter { !retainedIDs.contains($0) }
        markDirty(at: now)
        // Ordinary writes remain blocked until this recovery transaction lands.
        try await store.commitMaintenance(
            nodes: field.snapshot(at: now, configuration: configuration),
            thoughtSeeds: thoughtSeeds.values.map {
                CognitiveArtifactReplacement(id: $0.id, status: "open", score: $0.priority, payload: $0.toJSON())
            },
            artifacts: artifacts, deletedArtifactIDs: deletedIDs, receipts: [],
            maxNodes: configuration.maximumActiveNodes, maxArtifacts: artifactCap(configuration), at: now
        )
    }

    private func restoreArtifactFamilyLoads() -> [CognitiveArtifactFamilyLoad] {
        [
            CognitiveArtifactFamilyLoad(key: "affect", kindPrefix: "affect", limit: 1),
            CognitiveArtifactFamilyLoad(
                key: "capsule_presentation",
                kindPrefix: "capsule_presentation",
                limit: 1
            ),
            CognitiveArtifactFamilyLoad(key: "disposition", kindPrefix: "disposition", limit: 1),
            // Personality depth wave, items 6 and 7 (2026-09-02). Both are
            // at-most-once claims, so they must outlive a crash: a released nag
            // must not heal twice, and a committed dream must leave exactly one
            // residue.
            CognitiveArtifactFamilyLoad(key: "dream_residue", kindPrefix: "dream_residue", limit: 1),
            CognitiveArtifactFamilyLoad(
                key: "rumination_release",
                kindPrefix: "rumination_release",
                limit: 64
            ),
            CognitiveArtifactFamilyLoad(
                key: "emotional_consolidation",
                kindPrefix: "emotional_consolidation",
                limit: 1
            ),
            CognitiveArtifactFamilyLoad(
                key: "thought_seed",
                kindPrefix: "thought_seed",
                limit: configuration.maximumThoughtSeeds
            ),
            CognitiveArtifactFamilyLoad(key: "episode", kindPrefix: "episode", limit: 120),
            CognitiveArtifactFamilyLoad(key: "schema_proposal", kindPrefix: "schema_proposal", limit: 120),
            CognitiveArtifactFamilyLoad(key: "standing_view", kindPrefix: "standing_view", limit: 60),
            CognitiveArtifactFamilyLoad(
                key: "developmental_timeline",
                kindPrefix: "developmental_timeline",
                limit: 160
            ),
            CognitiveArtifactFamilyLoad(
                key: "reflection_receipt",
                kindPrefix: "reflection_receipt",
                limit: max(40, configuration.dailyReflectionCallBudget * 4)
            ),
            CognitiveArtifactFamilyLoad(key: "experiment", kindPrefix: "experiment", limit: 40),
            CognitiveArtifactFamilyLoad(key: "mind_ledger", kindPrefix: "mind_ledger", limit: 1),
        ]
    }

    private func validateRestoreBundle(_ bundle: CognitiveSQLiteRestoreBundle) throws {
        for family in restoreArtifactFamilyLoads() {
            guard let payloads = bundle.artifacts[family.key] else {
                throw CognitivePersistenceError.invalidRestoreArtifact(
                    family: family.key,
                    index: 0,
                    detail: "family was absent from the SQLite restore bundle"
                )
            }
            for (index, payload) in payloads.enumerated() {
                guard validRestorePayload(payload, family: family.key) else {
                    throw CognitivePersistenceError.invalidRestoreArtifact(
                        family: family.key,
                        index: index,
                        detail: "one or more required fields are missing or invalid"
                    )
                }
            }
        }
    }

    private func validRestorePayload(_ payload: JSONValue, family: String) -> Bool {
        guard case .object(let object) = payload else { return false }
        switch family {
        case "affect":
            return dateValue(object["updatedAt"]) != nil
        case "capsule_presentation":
            return dateValue(object["updatedAt"]) != nil
        case "disposition":
            return dateValue(object["updatedAt"]) != nil
                && doubleValue(object["valence"]) != nil
        case "dream_residue":
            return dateValue(object["updatedAt"]) != nil
        case "rumination_release":
            return uuidValue(object["seedId"]) != nil
                && dateValue(object["releasedAt"]) != nil
        case "emotional_consolidation":
            return dateValue(object["ranAt"]) != nil
        case "thought_seed":
            guard let kind = stringValue(object["kind"]) else { return false }
            return uuidValue(object["id"]) != nil
                && CognitiveThoughtSeedKind(rawValue: kind) != nil
                && stringValue(object["text"]) != nil
                && doubleValue(object["priority"]) != nil
                && dateValue(object["createdAt"]) != nil
                && dateValue(object["lastUpdatedAt"]) != nil
        case "episode":
            return uuidValue(object["id"]) != nil
                && stringValue(object["title"]) != nil
                && stringValue(object["summary"]) != nil
                && dateValue(object["occurredAt"]) != nil
        case "schema_proposal":
            guard let status = stringValue(object["status"]) else { return false }
            return uuidValue(object["id"]) != nil
                && stringValue(object["title"]) != nil
                && stringValue(object["body"]) != nil
                && stringValue(object["target"]) != nil
                && CognitiveSchemaProposalStatus(rawValue: status) != nil
                && dateValue(object["createdAt"]) != nil
        case "standing_view":
            guard let status = stringValue(object["status"]) else { return false }
            return uuidValue(object["id"]) != nil
                && stringValue(object["title"]) != nil
                && stringValue(object["body"]) != nil
                && CognitiveStandingView.Status(rawValue: status) != nil
                && dateValue(object["createdAt"]) != nil
                && dateValue(object["updatedAt"]) != nil
        case "developmental_timeline":
            guard let kind = stringValue(object["kind"]) else { return false }
            return uuidValue(object["id"]) != nil
                && CognitiveDevelopmentalTimelineKind(rawValue: kind) != nil
                && stringValue(object["title"]) != nil
                && stringValue(object["summary"]) != nil
                && dateValue(object["occurredAt"]) != nil
        case "reflection_receipt":
            return uuidValue(object["id"]) != nil
                && stringValue(object["reason"]) != nil
                && stringValue(object["prompt"]) != nil
                && stringValue(object["surface"]) != nil
                && stringValue(object["model"]) != nil
                && stringValue(object["requestProvider"]) != nil
                && stringValue(object["reasoningEffort"]) != nil
                && dateValue(object["requestedAt"]) != nil
                && stringValue(object["resultSummary"]) != nil
                && stringValue(object["provider"]) != nil
                && dateValue(object["createdAt"]) != nil
        case "mind_ledger":
            return dateValue(object["updatedAt"]) != nil
        case "experiment":
            guard let kind = stringValue(object["kind"]) else { return false }
            return uuidValue(object["id"]) != nil
                && CognitiveExperimentKind(rawValue: kind) != nil
                && stringValue(object["seed"]) != nil
                && stringValue(object["reproducibilityKey"]) != nil
                && dateValue(object["generatedAt"]) != nil
        default:
            return false
        }
    }

    private func applyRestoreBundle(_ bundle: CognitiveSQLiteRestoreBundle) -> [UUID] {
        // A successfully loaded (or explicitly cleared) resident field also
        // owns evictions and deletions. A disk snapshot cannot revive them.
        if !residentRestoreIsAuthoritative {
            field.mergeRestoredNodes(
                bundle.nodes,
                decayAnchorsByID: bundle.nodeDecayAnchors,
                configuration: configuration
            )
        }
        func payloads(_ family: String) -> [JSONValue] {
            bundle.artifacts[family] ?? []
        }

        verificationNodeMayExist = field.peekNodes().contains { $0.turnKind == .verification }
        restoreAffect(from: payloads("affect"))
        restoreCapsulePresentation(from: payloads("capsule_presentation"))
        restoreDisposition(from: payloads("disposition"))
        restoreEmotionalConsolidation(from: payloads("emotional_consolidation"))
        restoreThoughtSeeds(from: payloads("thought_seed"))
        restoreDreamResidue(from: payloads("dream_residue"))
        // AFTER the seed family: a release marker drops the seed it released, so
        // a seed row that outlived its own removal cannot come back and nag.
        restoreRuminationReleases(from: payloads("rumination_release"))
        restoreEpisodes(from: payloads("episode"))
        restoreSchemaProposals(from: payloads("schema_proposal"))
        let clampedStandingViewIds = restoreStandingViews(from: payloads("standing_view"))
        restoreDevelopmentalTimeline(from: payloads("developmental_timeline"))
        restoreReflectionReceipts(from: payloads("reflection_receipt"))
        restoreExperimentResults(from: payloads("experiment"))
        restoreMindLedger(from: payloads("mind_ledger"))
        enforceEpisodeCap()
        enforceSchemaProposalCap()
        enforceDevelopmentalTimelineCap()
        enforceReflectionReceiptCap()
        enforceExperimentResultCap()
        return clampedStandingViewIds
    }

    private func restoreFailureStage(for error: Error) -> String {
        if case CognitivePersistenceError.invalidRestoreArtifact(let family, _, _) = error {
            return "artifact.\(family)"
        }
        if case CognitiveSQLiteReadError.malformedRow(let table, _, _) = error {
            return table
        }
        return "sqlite_read"
    }

    private func restoreEpisodes(from payloads: [JSONValue]) {
        episodes.removeAll(keepingCapacity: true)
        for payload in payloads {
            guard case .object(let object) = payload,
                  let id = uuidValue(object["id"]),
                  let title = stringValue(object["title"]),
                  let summary = stringValue(object["summary"]),
                  let occurredAt = dateValue(object["occurredAt"]) else {
                continue
            }
            episodes[id] = CognitiveEpisodeReference(
                id: id,
                title: title,
                summary: summary,
                occurredAt: occurredAt,
                evidenceNodeIds: uuidArrayValue(object["evidenceNodeIds"]),
                externalEvidenceIds: stringArrayValue(object["externalEvidenceIds"]),
                lineageId: stringValue(object["lineageId"]) ?? ""
            )
        }
    }

    private func restoreSchemaProposals(from payloads: [JSONValue]) {
        schemaProposals.removeAll(keepingCapacity: true)
        for payload in payloads {
            guard case .object(let object) = payload,
                  let id = uuidValue(object["id"]),
                  let title = stringValue(object["title"]),
                  let body = stringValue(object["body"]),
                  let target = stringValue(object["target"]),
                  let statusRaw = stringValue(object["status"]),
                  let status = CognitiveSchemaProposalStatus(rawValue: statusRaw),
                  let createdAt = dateValue(object["createdAt"]) else {
                continue
            }
            schemaProposals[id] = CognitiveSchemaProposal(
                id: id,
                title: title,
                body: body,
                target: target,
                status: status,
                confidence: doubleValue(object["confidence"]) ?? 0,
                createdAt: createdAt,
                evidenceNodeIds: uuidArrayValue(object["evidenceNodeIds"]),
                externalEvidenceIds: stringArrayValue(object["externalEvidenceIds"]),
                lineageId: stringValue(object["lineageId"]) ?? ""
            )
        }
    }

    private func restoreDevelopmentalTimeline(from payloads: [JSONValue]) {
        developmentalTimeline.removeAll(keepingCapacity: true)
        for payload in payloads {
            guard case .object(let object) = payload,
                  let id = uuidValue(object["id"]),
                  let kindRaw = stringValue(object["kind"]),
                  let kind = CognitiveDevelopmentalTimelineKind(rawValue: kindRaw),
                  let title = stringValue(object["title"]),
                  let summary = stringValue(object["summary"]),
                  let occurredAt = dateValue(object["occurredAt"]) else {
                continue
            }
            developmentalTimeline[id] = CognitiveDevelopmentalTimelineEvent(
                id: id,
                kind: kind,
                title: title,
                summary: summary,
                occurredAt: occurredAt,
                artifactId: uuidValue(object["artifactId"]),
                lineageId: stringValue(object["lineageId"]) ?? "",
                subjectId: stringValue(object["subjectId"]) ?? "",
                instanceId: stringValue(object["instanceId"]) ?? "",
                forkMetadata: stringDictionaryValue(object["forkMetadata"]),
                externalEvidenceIds: stringArrayValue(object["externalEvidenceIds"])
            )
        }
    }

    /// Restore the Wave D overnight-consolidation cadence gate. Reads only `ranAt` from
    /// the single "emotional_consolidation" artifact. Clears the gate FIRST so a re-run
    /// of restore on a live actor with a missing/corrupt artifact behaves as never-run
    /// (sweep due) instead of keeping a stale in-memory gate (gpt-5.5 review, 2026-07-02).
    /// Mirrors `restoreAffect`.
    private func restoreEmotionalConsolidation(from payloads: [JSONValue]) {
        lastEmotionalConsolidationAt = nil
        guard case .object(let object)? = payloads.first,
              let ranAt = dateValue(object["ranAt"]) else { return }
        lastEmotionalConsolidationAt = ranAt
    }

    private func restoreExperimentResults(from payloads: [JSONValue]) {
        experimentResults.removeAll(keepingCapacity: true)
        for payload in payloads {
            guard case .object(let object) = payload,
                  let id = uuidValue(object["id"]),
                  let kindRaw = stringValue(object["kind"]),
                  let kind = CognitiveExperimentKind(rawValue: kindRaw),
                  let seed = stringValue(object["seed"]),
                  let reproducibilityKey = stringValue(object["reproducibilityKey"]),
                  let generatedAt = dateValue(object["generatedAt"]) else {
                continue
            }
            experimentResults[id] = CognitiveExperimentResult(
                id: id,
                kind: kind,
                seed: seed,
                score: doubleValue(object["score"]) ?? 0,
                metrics: doubleDictionaryValue(object["metrics"]),
                notes: stringArrayValue(object["notes"]),
                reproducibilityKey: reproducibilityKey,
                generatedAt: generatedAt
            )
        }
    }

    func stringArrayValue(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap(stringValue)
    }

    private func stringDictionaryValue(_ value: JSONValue?) -> [String: String] {
        guard case .object(let object)? = value else { return [:] }
        return object.compactMapValues(stringValue)
    }

    private func doubleDictionaryValue(_ value: JSONValue?) -> [String: Double] {
        guard case .object(let object)? = value else { return [:] }
        return object.compactMapValues(doubleValue)
    }
}
