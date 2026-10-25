import Foundation
import NativeAgentCore
import Experiences
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+Persistence.swift` | `CognitiveSubstrate`: `persistSnapshot`, `recordReceipt` |

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
        do { try await store.appendReceipt(kind: kind, payload: payload, at: dependencies.now()) } catch {
            // A log line has no resident state to reconcile: it stays an owed
            // repair until its owner lets it go, without blocking health.
            oweUnsaved("receipt.\(kind)", error, store: store)
        }
    }

    /// The writes whose callers do not take the failure. A failure marks
    /// persistence degraded under its stage and files one repair naming it;
    /// the next write of that stage persists the current resident state (the
    /// truth), which settles the repair and clears the stage. No replay.
    func notingPersistence(_ stage: String, _ write: () async throws -> Void) async {
        guard let store else { return }
        do {
            try await write()
            guard unsavedStages.remove(stage) != nil else { return }
            RepairOwed.settle(Self.dataRoot(of: store), operation: "cognition.persist:" + stage,
                              evidence: .init(source: "cognition/cognition.sqlite", id: stage))
            guard unsavedStages.isEmpty, persistenceHealth.failureStage == "unsaved", !persistenceWritesBlocked else { return }
            persistenceHealth = CognitivePersistenceHealth(
                status: .healthy, writesBlocked: false,
                lastRestoreAttemptAt: persistenceHealth.lastRestoreAttemptAt,
                lastSuccessfulRestoreAt: persistenceHealth.lastSuccessfulRestoreAt)
        } catch {
            oweUnsaved(stage, error, store: store)
            guard !stage.hasPrefix("receipt."), !persistenceWritesBlocked else { return }
            unsavedStages.insert(stage)
            persistenceHealth = CognitivePersistenceHealth(
                status: .degraded, writesBlocked: false,
                lastRestoreAttemptAt: persistenceHealth.lastRestoreAttemptAt,
                lastSuccessfulRestoreAt: persistenceHealth.lastSuccessfulRestoreAt,
                failureStage: "unsaved",
                failureDetail: bounded("unsaved: \(unsavedStages.sorted().joined(separator: ", ")); last cause: \(error)",
                                       maxCharacters: 320))
        }
    }

    private func oweUnsaved(_ stage: String, _ error: Error, store: CognitiveSQLiteStore) {
        RepairOwed.owe(Self.dataRoot(of: store), id: "cognition-persist:" + UUID().uuidString.lowercased(), kind: .run,
                       operation: "cognition.persist:" + stage, owner: "cognition",
                       words: "Her \(stage) was not saved: \(error.localizedDescription)")
    }

    private static func dataRoot(of store: CognitiveSQLiteStore) -> URL {
        store.databaseURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Observational surfaces preserve unavailable receipt evidence explicitly.
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

    func persistArtifact(kind: String, id: UUID, status: String, score: Double, payload: JSONValue) async {
        await notingPersistence("artifact.\(kind).\(id.uuidString)") {
            try await persistArtifactChecked(kind: kind, id: id, status: status, score: score, payload: payload)
        }
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

    func persistArtifactTransition(
        artifacts: [CognitiveArtifactWrite],
        deletedArtifactIDs: [UUID],
        at now: Date
    ) async throws {
        guard configuration.persistenceEnabled else { return }
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        guard !persistenceWritesBlocked else {
            throw CognitivePersistenceError.writesBlocked(
                status: persistenceHealth.status, detail: persistenceHealth.failureDetail)
        }
        try await store.commitArtifactTransition(
            artifacts: artifacts, deletedArtifactIDs: deletedArtifactIDs, at: now)
    }

    func persistMaintenanceTransition(
        nodes: [CognitiveNode],
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
            artifacts: artifacts,
            deletedArtifactIDs: deletedArtifactIDs,
            receipts: receipts,
            maxNodes: configuration.maximumActiveNodes,
            maxArtifacts: artifactCap(configuration),
            at: now
        )
    }

    func artifactCap(_ configuration: CognitiveConfiguration) -> Int {
        max(
            64,
            configuration.maximumActiveNodes
                + configuration.dailyReflectionCallBudget * 14
                + 64
        )
    }

}

// MARK: - In-memory artifact caps (G-M2)

extension CognitiveSubstrate {
    // Each artifact family is disk-capped and restart-capped, but the in-process
    // dict grew without bound over a days-long run so `.values` scans went O(N).
    // Evict the oldest by timestamp at each record tail, retained-N matched to
    // the family's
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

