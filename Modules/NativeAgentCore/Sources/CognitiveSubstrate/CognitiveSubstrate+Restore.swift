import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+Restore.swift` | `CognitiveSubstrate`: `backupPersistentStateForDoctor`, `restorePersistentState` |

extension CognitiveSubstrate {
    public func backupPersistentStateForDoctor() async throws -> URL {
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        return try await store.backupForDoctor()
    }

    public func restorePersistentState() async throws {
        guard configuration.enabled else { return }
        guard configuration.persistenceEnabled else {
            persistenceHealth = .disabled
            return
        }
        // Restore and Clear exclude each other: a restore waits for a Clear in
        // flight (and then finds her mind already read: the cleared one), and a
        // Clear waits for a restore in flight, so a bundle loaded before the
        // clear can never be reconciled into the store after it.
        await waitForLifecycleHold()
        // Restore runs once: a mind already read (or cleared) in this process
        // is the resident truth, and re-reading the disk over it would lose
        // what it has not saved yet (map risk 6).
        guard !persistenceRestored else { return }
        restoreInFlight = true
        defer {
            restoreInFlight = false
            releaseLifecycleHold()
        }
        await waitForMaintenanceTransition()

        let attemptAt = dependencies.now()
        guard let store else {
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
        persistenceHealth = CognitivePersistenceHealth(
            status: .restoring,
            writesBlocked: true,
            lastRestoreAttemptAt: attemptAt,
            lastSuccessfulRestoreAt: previousSuccessAt
        )

        var bundle: CognitiveSQLiteRestoreBundle
        let decoded: (episodes: [UUID: CognitiveEpisodeReference], proposals: [UUID: CognitiveSchemaProposal],
                      timeline: [UUID: CognitiveDevelopmentalTimelineEvent], reflections: [UUID: CognitiveReflectionReceipt],
                      cares: [UUID: CognitiveCare], migration: CognitiveCareMigration?)
        do {
            // The forgetting boundary is read with her mind: a turn admitted
            // from here on is stamped with it.
            mindEpoch = try await store.loadEpoch("mind")
            bundle = try await store.loadRestoreBundle(
                artifactFamilies: restoreArtifactFamilyLoads()
            )
            decoded = try decodeRestoreBundle(bundle)
        } catch {
            let stage = restoreFailureStage(for: error)
            let detail = bounded(String(describing: error), maxCharacters: 320)
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
        // The retired kinds are read only for their one conversion into cares:
        // never reconciled, rewritten or deleted here.
        let retiredViews = bundle.artifacts.removeValue(forKey: "standing_view") ?? []
        let retiredSeeds = bundle.artifacts.removeValue(forKey: "thought_seed") ?? []

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
                let identityField = "id"
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
        if !residentRestoreIsAuthoritative {
            episodes = decoded.episodes.merging(episodes) { _, live in live }
            schemaProposals = decoded.proposals.merging(schemaProposals) { _, live in live }
            developmentalTimeline = decoded.timeline.merging(developmentalTimeline) { _, live in live }
            reflectionReceipts = decoded.reflections.merging(reflectionReceipts) { _, live in live }
            cares = decoded.cares.merging(cares) { _, live in live }
            careMigration = careMigration ?? decoded.migration
        }
        for (id, care) in cares where care.origin == .seed { cares[id]?.open = nil }
        applyRestoreBundle(reconciled)
        residentRestoreIsAuthoritative = true
        // Commit the reconciled nodes and artifacts together, including the
        // resident removals.
        do {
            try await persistReconciledRestoreState(replacing: bundle)
        } catch {
            persistenceHealth = CognitivePersistenceHealth(
                status: .degraded, writesBlocked: true,
                lastRestoreAttemptAt: attemptAt, lastSuccessfulRestoreAt: previousSuccessAt,
                failureStage: "restore_reconciliation",
                failureDetail: bounded(String(describing: error), maxCharacters: 320)
            )
            throw error
        }
        persistenceRestored = true
        persistenceHealth = CognitivePersistenceHealth(
            status: .healthy,
            writesBlocked: false,
            lastRestoreAttemptAt: attemptAt,
            lastSuccessfulRestoreAt: dependencies.now()
        )
        publishAttentionProjection(at: dependencies.now())
        await establishCares(retiredViews: retiredViews, retiredSeeds: retiredSeeds)
        try? await store.appendReceipt(
            kind: "lifecycle.restore",
            payload: .object([
                "nodeCount": .int(Int64(field.peekNodes().count)),
                "episodeCount": .int(Int64(episodes.count)),
                "schemaProposalCount": .int(Int64(schemaProposals.count)),
                "timelineCount": .int(Int64(developmentalTimeline.count)),
                "reflectionCount": .int(Int64(reflectionReceipts.count)),
                "status": .string(previouslyDegraded ? "recovered" : "restored"),
                "writesBlocked": .bool(false),
            ]),
            at: dependencies.now()
        )
    }

    private func residentRestoreArtifacts(at now: Date) -> [String: [JSONValue]] {
        var rows: [String: [JSONValue]] = [
            "episode": episodes.values.map { $0.toJSON() },
            "schema_proposal": schemaProposals.values.map { $0.toJSON() },
            "care_retired_migration": careRetiredMigration.map { [$0] } ?? [],
            "developmental_timeline": developmentalTimeline.values.map { $0.toJSON() },
            "reflection_receipt": reflectionReceipts.values.map { $0.toJSON() },
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
        if residentRestoreIsAuthoritative || !associationSuppressions.isEmpty || dispositionUndo != nil {
            rows["mind_ledger"] = [mindLedgerArtifactPayload(at: now, undoEntry: dispositionUndo)]
        }
        return rows
    }

    private func restoreArtifactID(family: String, payload: JSONValue) -> UUID {
        guard case .object(let object) = payload else { return stableArtifactID(family) }
        return uuidValue(object["id"]) ?? stableArtifactID(family)
    }

    private func residentArtifactWrites(
        _ families: [String: [JSONValue]], bundle: CognitiveSQLiteRestoreBundle?
    ) -> (artifacts: [CognitiveArtifactWrite], retainedIDs: Set<UUID>) {
        var artifacts: [CognitiveArtifactWrite] = []
        var retainedIDs: Set<UUID> = []
        for (family, rows) in families {
            for payload in rows {
                guard case .object(let object) = payload else { continue }
                let id = restoreArtifactID(family: family, payload: payload)
                retainedIDs.insert(id)
                // Counts in this diagnostic payload live only in SQLite. A
                // matching consolidation clock does not replace that evidence.
                // Without a loaded bundle to compare (a failed Clear's whole
                // save) it is never overwritten blind.
                if family == "emotional_consolidation" {
                    guard let bundle else { continue }
                    if case .object(let persisted)? = bundle.artifacts[family]?.first,
                       object["ranAt"] == persisted["ranAt"] { continue }
                }
                var status = object["status"]?.stringValue ?? "current"
                var score = object["confidence"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? object["score"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0
                switch family {
                case "episode", "developmental_timeline": status = "recorded"; score = 0.5
                case "reflection_receipt": status = object["cancelled"] == .bool(true) ? "cancelled" : "recorded"
                case "care": status = (object["fadedAt"] ?? .null) == .null ? "live" : "faded"
                case "disposition": score = ((object["valence"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0) + 1) / 2
                case "affect": score = object["arousal"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0
                default: break
                }
                artifacts.append(CognitiveArtifactWrite(
                    kind: family, id: id, status: status, score: score, payload: payload
                ))
            }
        }
        return (artifacts, retainedIDs)
    }

    private func persistReconciledRestoreState(replacing bundle: CognitiveSQLiteRestoreBundle) async throws {
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        let now = dependencies.now()
        var families = residentRestoreArtifacts(at: now)
        families["care"] = try cares.values.map { try Self.careJSON($0) }
        families["care_migration"] = try careMigration.map { [try Self.careJSON($0)] } ?? []
        let (artifacts, retainedIDs) = residentArtifactWrites(families, bundle: bundle)
        let deletedIDs = bundle.artifacts.flatMap { family, rows in
            rows.map { restoreArtifactID(family: family, payload: $0) }
        }.filter { !retainedIDs.contains($0) }
        markDirty(at: now)
        // Ordinary writes remain blocked until this recovery transaction lands.
        try await store.commitMaintenance(
            nodes: field.snapshot(at: now, configuration: configuration),
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
            // A committed dream leaves exactly one residue across restarts.
            CognitiveArtifactFamilyLoad(key: "dream_residue", kindPrefix: "dream_residue", limit: 1),
            CognitiveArtifactFamilyLoad(
                key: "emotional_consolidation",
                kindPrefix: "emotional_consolidation",
                limit: 1
            ),
            CognitiveArtifactFamilyLoad(key: "episode", kindPrefix: "episode", limit: 120),
            CognitiveArtifactFamilyLoad(key: "schema_proposal", kindPrefix: "schema_proposal", limit: 120),
            CognitiveArtifactFamilyLoad(key: "care", kindPrefix: "care", limit: 0, whole: true),
            CognitiveArtifactFamilyLoad(key: "care_migration", kindPrefix: "care_migration", limit: 1),
            CognitiveArtifactFamilyLoad(
                key: "care_retired_migration",
                kindPrefix: "care_retired_migration",
                limit: 1
            ),
            CognitiveArtifactFamilyLoad(key: "standing_view", kindPrefix: "standing_view", limit: 0, whole: true),
            CognitiveArtifactFamilyLoad(key: "thought_seed", kindPrefix: "thought_seed", limit: 0, whole: true),
            CognitiveArtifactFamilyLoad(
                key: "developmental_timeline",
                kindPrefix: "developmental_timeline",
                limit: 160
            ),
            CognitiveArtifactFamilyLoad(
                key: "reflection_receipt",
                kindPrefix: "reflection_receipt",
                limit: reflectionReceiptCap
            ),
            CognitiveArtifactFamilyLoad(key: "mind_ledger", kindPrefix: "mind_ledger", limit: 1),
        ]
    }

    private func decodeRestoreBundle(_ bundle: CognitiveSQLiteRestoreBundle) throws -> (episodes: [UUID: CognitiveEpisodeReference], proposals: [UUID: CognitiveSchemaProposal],
                                     timeline: [UUID: CognitiveDevelopmentalTimelineEvent], reflections: [UUID: CognitiveReflectionReceipt],
                                     cares: [UUID: CognitiveCare], migration: CognitiveCareMigration?) {
        var episodes: [UUID: CognitiveEpisodeReference] = [:]
        var proposals: [UUID: CognitiveSchemaProposal] = [:]
        var timeline: [UUID: CognitiveDevelopmentalTimelineEvent] = [:]
        var reflections: [UUID: CognitiveReflectionReceipt] = [:]
        var cares: [UUID: CognitiveCare] = [:]
        var migration: CognitiveCareMigration?
        for family in restoreArtifactFamilyLoads() {
            guard let payloads = bundle.artifacts[family.key] else {
                throw CognitivePersistenceError.invalidRestoreArtifact(
                    family: family.key,
                    index: 0,
                    detail: "family was absent from the SQLite restore bundle"
                )
            }
            for (index, payload) in payloads.enumerated() {
                let valid: Bool
                switch family.key {
                case "episode":
                    let value = CognitiveEpisodeReference(payload: payload)
                    if let value { episodes[value.id] = value }
                    valid = value != nil
                case "schema_proposal":
                    let value = CognitiveSchemaProposal(payload: payload)
                    if let value { proposals[value.id] = value }
                    valid = value != nil
                case "developmental_timeline":
                    let value = CognitiveDevelopmentalTimelineEvent(payload: payload)
                    if let value { timeline[value.id] = value }
                    valid = value != nil
                case "reflection_receipt":
                    let value = CognitiveReflectionReceipt(payload: payload)
                    if let value { reflections[value.id] = value }
                    valid = value != nil
                case "care":
                    let value = Self.careDecoded(CognitiveCare.self, payload)
                    if let value { cares[value.id] = value }
                    valid = value != nil
                case "care_migration":
                    let value = Self.careDecoded(CognitiveCareMigration.self, payload)
                    if migration == nil { migration = value }
                    valid = value != nil
                default:
                    valid = validRestorePayload(payload, family: family.key)
                }
                guard valid else {
                    throw CognitivePersistenceError.invalidRestoreArtifact(
                        family: family.key,
                        index: index,
                        detail: "one or more required fields are missing or invalid"
                    )
                }
            }
        }
        return (episodes, proposals, timeline, reflections, cares, migration)
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
                && object["valence"]?.numberValue(coercingStrings: false, finiteOnly: false) != nil
        case "dream_residue":
            return dateValue(object["updatedAt"]) != nil
        case "emotional_consolidation":
            return dateValue(object["ranAt"]) != nil
        case "mind_ledger":
            return dateValue(object["updatedAt"]) != nil
        case "care_retired_migration":
            return uuidValue(object["id"]) != nil && dateValue(object["migratedAt"]) != nil
        // A retired row the conversion cannot read is dropped there, never a failed restore.
        case "standing_view", "thought_seed":
            return true
        default:
            return false
        }
    }

    private func applyRestoreBundle(_ bundle: CognitiveSQLiteRestoreBundle) {
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
        restoreDreamResidue(from: payloads("dream_residue"))
        careRetiredMigration = payloads("care_retired_migration").first
        restoreMindLedger(from: payloads("mind_ledger"))
        enforceEpisodeCap()
        enforceSchemaProposalCap()
        enforceDevelopmentalTimelineCap()
        enforceReflectionReceiptCap()
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

    /// Restore the consolidation clock; an absent artifact leaves the sweep due.
    private func restoreEmotionalConsolidation(from payloads: [JSONValue]) {
        lastEmotionalConsolidationAt = nil
        guard case .object(let object)? = payloads.first,
              let ranAt = dateValue(object["ranAt"]) else { return }
        lastEmotionalConsolidationAt = ranAt
    }

}
