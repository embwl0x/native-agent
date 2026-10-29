import Foundation
import NativeAgentCore
import Experiences
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+Persistence.swift` | `CognitiveSubstrate`: `persistAffectAndNodes`, `recordReceipt` |

extension CognitiveSubstrate {
    /// Affect, consumed residue and node watermarks become durable together.
    public func persistAffectAndNodes() async throws {
        guard configuration.enabled, configuration.persistenceEnabled else { return }
        guard store != nil else { throw CognitivePersistenceError.storeUnavailable }
        // Reject before capturing a snapshot: capture decays and caps the field.
        if forgettingInFlight {
            forgettingDiscarded.append((kind: "snapshot", id: UUID()))
            forgettingDiscarded.append(contentsOf: affectCheckpoint(at: dependencies.now()).map { (kind: $0.kind, id: $0.id) })
            throw CognitiveWriteDiscarded()
        }
        guard !persistenceHealth.writesBlocked else {
            throw CognitivePersistenceError.writesBlocked(
                status: persistenceHealth.status, detail: persistenceHealth.failureDetail)
        }
        let now = dependencies.now()
        try await persistMaintenanceTransition(
            nodes: field.snapshot(at: now, configuration: configuration),
            artifacts: affectCheckpoint(at: now), deletedArtifactIDs: [], receipts: [], at: now
        )
    }

    func affectCheckpoint(at now: Date) -> [CognitiveArtifactWrite] {
        [CognitiveArtifactWrite(
            kind: "affect", id: stableArtifactID("affect"), status: "current",
            score: affect.arousal, payload: affect.toJSON(
                lastUserPresenceAt: lastUserPresenceAt, lastWarmPresenceAt: lastWarmPresenceAt)
        ), CognitiveArtifactWrite(
            kind: "dream_residue", id: stableArtifactID("dream_residue"), status: "current",
            score: 0, payload: dreamResidueArtifactPayload(at: now)
        )]
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
            guard unsavedStages.isEmpty, persistenceHealth.failureStage == "unsaved", !persistenceHealth.writesBlocked else { return }
            persistenceHealth = CognitivePersistenceHealth(
                status: .healthy, writesBlocked: false,
                lastRestoreAttemptAt: persistenceHealth.lastRestoreAttemptAt,
                lastSuccessfulRestoreAt: persistenceHealth.lastSuccessfulRestoreAt)
        } catch {
            // A write refused because writes are blocked (her mind not yet read,
            // or a failed restore) is not a failed save: health already says
            // writes are blocked, and no repair is owed for it.
            if let refusal = error as? CognitivePersistenceError, case .writesBlocked = refusal { return }
            // A write Clear's hold discarded is not durable and not a failure
            // of its own: the failed Clear's one repair names it, and nothing
            // it was saving is settled.
            if error is CognitiveWriteDiscarded { return }
            oweUnsaved(stage, error, store: store)
            guard !stage.hasPrefix("receipt."), !persistenceHealth.writesBlocked else { return }
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

    /// A failed Clear owes ONE repair, stage `clear`, naming the writes its hold
    /// discarded (bounded). Nothing is written for them now: they land on
    /// their next change.
    func oweFailedClear(_ discarded: [(kind: String, id: UUID)], error: Error) {
        guard let store, !discarded.isEmpty else { return }
        var seen = Set<String>()
        let names = discarded.compactMap { piece -> String? in
            let name = piece.kind == "snapshot" ? "nodes" : "\(piece.kind) \(piece.id.uuidString.prefix(8))"
            return seen.insert(name).inserted ? name : nil
        }
        let listed = names.prefix(12).joined(separator: ", ")
            + (names.count > 12 ? " and \(names.count - 12) more" : "")
        RepairOwed.owe(Self.dataRoot(of: store), id: "cognition-persist:" + UUID().uuidString.lowercased(), kind: .run,
                       operation: "cognition.persist:clear", owner: "cognition",
                       words: "A Clear failed (\(error.localizedDescription)); these writes made during it were not"
                           + " saved and land on their next change: \(listed)")
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

    func persistArtifact(kind: String, id: UUID, status: String, score: Double, payload: JSONValue,
                         mindEpoch expectedMindEpoch: UInt64? = nil) async {
        await notingPersistence("artifact.\(kind).\(id.uuidString)") {
            try await persistArtifactChecked(kind: kind, id: id, status: status, score: score, payload: payload,
                                             mindEpoch: expectedMindEpoch)
        }
    }

    func persistArtifactChecked(
        kind: String,
        id: UUID,
        status: String,
        score: Double,
        payload: JSONValue,
        mindEpoch expectedMindEpoch: UInt64? = nil
    ) async throws {
        if let expectedMindEpoch, expectedMindEpoch != mindEpoch { throw CognitiveWriteDiscarded() }
        try await persistArtifactTransition(
            artifacts: [CognitiveArtifactWrite(kind: kind, id: id, status: status, score: score, payload: payload)],
            deletedArtifactIDs: [],
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
        // Clear holds the store under logical exclusion: a snapshot captured
        // before it is discarded, never written after it (`forgetMind`), and
        // the caller learns it is NOT durable.
        if forgettingInFlight {
            forgettingDiscarded.append(contentsOf: artifacts.map { (kind: $0.kind, id: $0.id) })
            forgettingDiscarded.append(contentsOf: deletedArtifactIDs.map { (kind: "deleted", id: $0) })
            throw CognitiveWriteDiscarded()
        }
        guard !persistenceHealth.writesBlocked else {
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
        // Clear holds the store under logical exclusion: a snapshot captured
        // before it is discarded, never written after it (`forgetMind`), and
        // the caller learns it is NOT durable.
        if forgettingInFlight {
            forgettingDiscarded.append((kind: "snapshot", id: UUID()))
            forgettingDiscarded.append(contentsOf: artifacts.map { (kind: $0.kind, id: $0.id) })
            forgettingDiscarded.append(contentsOf: deletedArtifactIDs.map { (kind: "deleted", id: $0) })
            throw CognitiveWriteDiscarded()
        }
        guard !persistenceHealth.writesBlocked else {
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
        let nodes = max(0, configuration.maximumActiveNodes)
        guard nodes <= Int.max - 64 else { return Int.max }
        let budget = max(0, configuration.dailyReflectionCallBudget)
        guard budget <= (Int.max - 64 - nodes) / 14 else { return Int.max }
        return nodes + budget * 14 + 64
    }

    var reflectionReceiptCap: Int {
        let budget = max(0, configuration.dailyReflectionCallBudget)
        return budget > Int.max / 4 ? Int.max : max(40, budget * 4)
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
            cap: reflectionReceiptCap
        ) { $0.createdAt }
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

/// A write Clear's hold discarded: not durable. Never a silent success, so a
/// lived moment's part that hit one stays owed.
public struct CognitiveWriteDiscarded: Error, CustomStringConvertible {
    public var description: String { "the write was discarded by a Clear in progress and is not saved" }
}
