import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    public func persistSnapshot() async throws {
        guard configuration.enabled, configuration.persistenceEnabled else { return }
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        guard !persistenceWritesBlocked else {
            throw CognitivePersistenceError.writesBlocked(
                status: persistenceHealth.status,
                detail: persistenceHealth.failureDetail
            )
        }
        let now = dependencies.now()
        let nodes = field.snapshot(at: now, configuration: configuration)
        try await store.saveNodes(nodes, at: now)
        try await store.prune(
            maxNodes: configuration.maximumActiveNodes,
            maxArtifacts: artifactCap(configuration)
        )
    }

    public func recordReceipt(kind: String, payload: JSONValue = .object([:])) async {
        guard configuration.enabled, configuration.persistenceEnabled, let store else { return }
        try? await store.appendReceipt(kind: kind, payload: payload, at: dependencies.now())
    }

    /// Strict receipt write for a mutation whose durable outcome depends on the
    /// receipt itself. Unlike best-effort diagnostics, a disabled or missing
    /// persistence lane is a refusal rather than a quiet no-op.
    public func recordReceiptChecked(
        kind: String,
        payload: JSONValue = .object([:]),
        id: UUID? = nil
    ) async throws {
        guard configuration.enabled, configuration.persistenceEnabled else {
            throw CognitivePersistenceError.storeUnavailable
        }
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        guard !persistenceWritesBlocked else {
            throw CognitivePersistenceError.writesBlocked(
                status: persistenceHealth.status,
                detail: persistenceHealth.failureDetail
            )
        }
        try await store.appendReceipt(
            kind: kind,
            payload: payload,
            at: dependencies.now(),
            id: id ?? UUID()
        )
    }

    /// The honest receipt read used by observational surfaces.  Existing
    /// callers that only need best-effort diagnostics may continue to use
    /// `receiptSnapshot`; a UI must preserve this outcome state instead.
    public func receiptReadSnapshot(limit: Int = 40) async -> CognitiveReceiptRead {
        guard configuration.enabled else { return .unavailable(.cognitionDisabled) }
        guard configuration.persistenceEnabled else { return .unavailable(.persistenceDisabled) }
        guard let store else { return .unavailable(.storeUnavailable) }
        do {
            return .available(try await store.loadReceiptRecords(limit: limit))
        } catch {
            return .unavailable(.readFailed)
        }
    }

    /// Compatibility best-effort projection for non-UI callers.  New
    /// observability surfaces must use `receiptReadSnapshot` so an unavailable
    /// store cannot be mistaken for an idle cognition loop.
    public func receiptSnapshot(limit: Int = 40) async -> [CognitiveReceiptRecord] {
        let read = await receiptReadSnapshot(limit: limit)
        return read.receipts
    }

    func persistArtifact(kind: String, id: UUID, status: String, score: Double, payload: JSONValue) async {
        try? await persistArtifactChecked(
            kind: kind, id: id, status: status, score: score, payload: payload
        )
    }

    func persistArtifactChecked(
        kind: String,
        id: UUID,
        status: String,
        score: Double,
        payload: JSONValue
    ) async throws {
        guard configuration.persistenceEnabled else { return }
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        guard !persistenceWritesBlocked else {
            throw CognitivePersistenceError.writesBlocked(
                status: persistenceHealth.status,
                detail: persistenceHealth.failureDetail
            )
        }
        try await store.upsertArtifact(
            kind: kind,
            id: id,
            status: status,
            score: score,
            payload: payload,
            at: dependencies.now()
        )
    }

    /// Persist the complete current thought-seed family as one exact SQLite
    /// transition. Callers own in-memory rollback when this throws.
    func persistThoughtSeedFamily() async throws {
        guard configuration.persistenceEnabled else { return }
        guard !persistenceWritesBlocked else {
            throw CognitivePersistenceError.writesBlocked(
                status: persistenceHealth.status,
                detail: persistenceHealth.failureDetail
            )
        }
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        let rows = thoughtSeeds.values.map { seed in
            CognitiveArtifactReplacement(
                id: seed.id,
                status: "open",
                score: seed.priority,
                payload: seed.toJSON()
            )
        }
        do {
            try await store.replaceArtifactFamily(
                kind: "thought_seed",
                records: rows,
                at: dependencies.now(),
                maxArtifacts: artifactCap(configuration)
            )
            if persistenceHealth.status == .degraded,
               persistenceHealth.failureStage == "artifact.thought_seed" {
                persistenceHealth = CognitivePersistenceHealth(
                    status: .healthy,
                    writesBlocked: false,
                    lastRestoreAttemptAt: persistenceHealth.lastRestoreAttemptAt,
                    lastSuccessfulRestoreAt: persistenceHealth.lastSuccessfulRestoreAt
                )
            }
        } catch {
            let detail = bounded(String(describing: error), maxCharacters: 320)
            persistenceHealth = CognitivePersistenceHealth(
                status: .degraded,
                writesBlocked: false,
                lastRestoreAttemptAt: persistenceHealth.lastRestoreAttemptAt,
                lastSuccessfulRestoreAt: persistenceHealth.lastSuccessfulRestoreAt,
                failureStage: "artifact.thought_seed",
                failureDetail: detail
            )
            throw CognitivePersistenceError.artifactWriteFailed(
                family: "thought_seed",
                detail: detail
            )
        }
    }

    func persistMaintenanceTransition(
        nodes: [CognitiveNode],
        thoughtSeeds: [CognitiveArtifactReplacement]?,
        artifacts: [CognitiveArtifactWrite],
        deletedArtifactIDs: [UUID],
        receipts: [CognitiveReceiptWrite],
        at now: Date
    ) async throws {
        guard configuration.persistenceEnabled else { return }
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        guard !persistenceWritesBlocked else {
            throw CognitivePersistenceError.writesBlocked(
                status: persistenceHealth.status,
                detail: persistenceHealth.failureDetail
            )
        }
        try await store.commitMaintenance(
            nodes: nodes,
            thoughtSeeds: thoughtSeeds,
            artifacts: artifacts,
            deletedArtifactIDs: deletedArtifactIDs,
            receipts: receipts,
            maxNodes: configuration.maximumActiveNodes,
            maxArtifacts: artifactCap(configuration),
            at: now
        )
    }

    /// Remove a persisted artifact row (Wave E: retired standing views delete their
    /// artifact — the timeline carries the history — so bounded restores and the global
    /// prune can never crowd out live state with retired rows).
    func deleteArtifactRecord(id: UUID) async {
        try? await deleteArtifactRecordChecked(id: id)
    }

    /// Same delete, but a caller that has already changed in-memory state on
    /// the strength of it can SEE the failure (2026-09-06): silently swallowing
    /// it let a retirement report success while the artifact stayed in the
    /// store, so the view came back on the next restore.
    func deleteArtifactRecordChecked(id: UUID) async throws {
        guard configuration.persistenceEnabled else { return }
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        guard !persistenceWritesBlocked else {
            throw CognitivePersistenceError.writesBlocked(
                status: persistenceHealth.status,
                detail: persistenceHealth.failureDetail
            )
        }
        try await store.deleteArtifact(id: id)
    }

    func artifactCap(_ configuration: CognitiveConfiguration) -> Int {
        max(
            64,
            configuration.maximumThoughtSeeds
                + configuration.maximumActiveNodes
                + configuration.maximumThoughtSeeds
                + configuration.dailyReflectionCallBudget * 14
                + 64
        )
    }

}

// MARK: - In-memory artifact caps (G-M2)

extension CognitiveSubstrate {
    // Each artifact family is disk-capped and restart-capped, but the in-process
    // dict grew without bound over a days-long run so `.values` scans went O(N).
    // These caps mirror `enforceThoughtSeedCap` (+ThoughtSeeds.swift): evict the
    // oldest by timestamp at each record tail, retained-N matched to the family's
    // restore limit in `restoreArtifactFamilyLoads()`. The disk copy survives, so
    // eviction is safe — restart reloads up to the same N.

    private func evictOldest<Value>(
        from dict: inout [UUID: Value],
        cap: Int,
        timestamp: (Value) -> Date
    ) {
        guard cap >= 0, dict.count > cap else { return }
        let victims = dict
            .sorted { lhs, rhs in
                let lt = timestamp(lhs.value)
                let rt = timestamp(rhs.value)
                if lt != rt { return lt < rt }
                return lhs.key.uuidString < rhs.key.uuidString
            }
            .prefix(dict.count - cap)
            .map(\.key)
        for victim in victims { dict.removeValue(forKey: victim) }
    }

    func enforceEpisodeCap() {
        evictOldest(from: &episodes, cap: 120) { $0.occurredAt }
    }

    func enforceSchemaProposalCap() {
        evictOldest(from: &schemaProposals, cap: 120) { $0.createdAt }
    }

    func enforceDevelopmentalTimelineCap() {
        evictOldest(from: &developmentalTimeline, cap: 160) { $0.occurredAt }
    }

    func enforceReflectionReceiptCap() {
        evictOldest(
            from: &reflectionReceipts,
            cap: max(40, configuration.dailyReflectionCallBudget * 4)
        ) { $0.createdAt }
    }

    func enforceExperimentResultCap() {
        evictOldest(from: &experimentResults, cap: 40) { $0.generatedAt }
    }

    // `replayEvidenceIds` is a dedup guard with no per-entry timestamp and no disk
    // restore (it is cleared on restore). Bound it in lockstep with `episodes`:
    // when it exceeds the episode cap, drop ids no longer referenced by any live
    // episode. A dropped id's episode survives on disk, so a re-dream simply
    // re-creates it — pruning unreferenced ids is safe.
    func enforceReplayEvidenceCap() {
        let cap = 120
        guard replayEvidenceIds.count > cap else { return }
        let referenced = Set(episodes.values.flatMap(\.externalEvidenceIds))
        replayEvidenceIds = replayEvidenceIds.filter { referenced.contains($0) }
    }
}

