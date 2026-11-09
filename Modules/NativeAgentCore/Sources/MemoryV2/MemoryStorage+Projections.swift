import Foundation
import Experiences
import GRDB
import NativeAgentCore
import PersistenceCore
import Transcripts
import TrustCenter
import CognitiveSubstrate
import ChatTurnContracts
import TurnTrace
import NativeAgentShared
// Blueprint: | `MemoryStorage+Projections.swift` | `MemoryStorage`, `userPromptCore`: ordered derived hooks and user prompt core |

extension MemoryStorage {
    /// Project canonical mutations through one USER.md owner.
    public func attachUserMDGenerator(_ generator: UserMDGenerator) async {
        guard !projectionsClosed else { await generator.shutdown(); return }
        guard userMDGenerator !== generator else { return }
        let previous = self.userMDGenerator
        self.userMDGenerator = generator
        // Join every accepted write before releasing the replaced generator.
        if let previous {
            let retirement = enqueueUserMDProjection { await previous.shutdown() }
            await retirement?.value
        }
        guard !projectionsClosed, self.userMDGenerator === generator else { return }
        if !replayedStartupUserProjection {
            replayedStartupUserProjection = true
            for persona in Set(startupBoundEvictions.map(\.personaId)) {
                pokeUserMDRegen(persona: persona)
            }
        }
    }

    /// Notify Spotlight for every canonical mutation using final row eligibility to derive deletion.
    public func attachSpotlightHook(
        _ hook: @escaping @Sendable (StoredMemory, Bool) async -> Void
    ) {
        guard !projectionsClosed else { return }
        self.spotlightHook = hook
        if !replayedStartupSpotlightProjection {
            replayedStartupSpotlightProjection = true
            for evicted in startupBoundEvictions { pokeSpotlight(evicted) }
        }
    }

    /// Wake graph indexing by identity; its transaction reads canonical eligibility.
    public func attachKnowledgeGraphHook(
        _ hook: @escaping @Sendable (String) async -> Void
    ) {
        guard !projectionsClosed else { return }
        self.knowledgeGraphHook = hook
        if !replayedStartupKnowledgeGraphProjection {
            replayedStartupKnowledgeGraphProjection = true
            for evicted in startupBoundEvictions { pokeKnowledgeGraph(evicted.id) }
        }
    }

    func pokeUserMDRegen(persona: String) {
        guard !projectionsClosed, let gen = userMDGenerator else { return }
        _ = enqueueUserMDProjection {
            do { try await gen.requestRegeneration(persona: persona) }
            catch { await self.recordUserProjectionFailure(error, persona: persona) }
        }
    }

    private func recordUserProjectionFailure(_ error: Error, persona: String) {
        let dataRoot = path.deletingLastPathComponent().deletingLastPathComponent()
        RepairOwed.owe(dataRoot, id: "user-projection:" + UUID().uuidString, kind: .act, operation: "memory.user_projection",
            owner: "USER.md", words: "USER.md projection request failed for \(persona): \(error)")
    }

    private func enqueueUserMDProjection(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        guard !projectionsClosed else { return nil }
        let prior = userMDProjectionTail
        let id = UUID()
        userMDProjectionID = id
        let task = Task {
            defer {
                if userMDProjectionID == id { userMDProjectionTail = nil; userMDProjectionID = nil }
            }
            await prior?.value
            await operation()
        }
        userMDProjectionTail = task
        return task
    }

    func pokeSpotlight(_ stored: StoredMemory) {
        guard let hook = spotlightHook else { return }
        _ = enqueueSpotlightProjection {
            guard let (current, removed) = await self.currentProjection(stored) else { return }
            await hook(current, removed)
        }
    }

    func enqueueSpotlightProjection<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) -> Task<Result, Error> {
        guard !projectionsClosed else { return Task { throw CancellationError() } }
        let prior = spotlightProjectionTail
        let id = UUID()
        spotlightProjectionID = id
        let task = Task {
            await prior?.value
            return try await operation()
        }
        spotlightProjectionTail = Task {
            defer {
                if spotlightProjectionID == id { spotlightProjectionTail = nil; spotlightProjectionID = nil }
            }
            _ = try? await task.value
        }
        return task
    }

    func pokeKnowledgeGraph(_ id: String) {
        guard let hook = knowledgeGraphHook else { return }
        enqueueKnowledgeGraphProjection {
            await hook(id)
        }
    }

    private func currentProjection(_ hint: StoredMemory) -> (StoredMemory, Bool)? {
        do {
            let current = try dbPool.read { db in
                try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [hint.id])
                    .map(Self.decodeMemory)
            }
            return current.map { ($0, !Self.projectionEligible($0)) } ?? (hint, true)
        } catch {
            nativeLog("[memory] projection read failed for \(hint.id): \(error)")
            return nil
        }
    }

    func enqueueKnowledgeGraphProjection(_ operation: @escaping @Sendable () async -> Void) {
        guard !projectionsClosed else { return }
        let prior = knowledgeGraphProjectionTail
        let id = UUID()
        knowledgeGraphProjectionID = id
        knowledgeGraphProjectionTail = Task {
            defer {
                if knowledgeGraphProjectionID == id { knowledgeGraphProjectionTail = nil; knowledgeGraphProjectionID = nil }
            }
            await prior?.value
            await operation()
        }
    }

    /// Close only derived-work admission. Canonical writes remain accepted; already-enqueued projections drain in order without blanket cancellation. Writes
    /// arriving after closure are reconciled from SQLite at next launch.
    public func shutdownProjections() async {
        projectionsClosed = true
        spotlightHook = nil
        knowledgeGraphHook = nil
        await userMDProjectionTail?.value
        await userMDGenerator?.shutdown()
        userMDGenerator = nil
        await spotlightProjectionTail?.value
        await knowledgeGraphProjectionTail?.value
    }

    func pokeDerivedState(_ stored: StoredMemory, deleted: Bool) async {
        let change = DerivedSourceChange(
            namespace: "memory-v2",
            stableID: stored.id,
            operation: deleted ? .removed : .changed,
            canonicalLocator: path.standardizedFileURL.path,
            reason: deleted ? "memory_projection_removed" : "memory_projection_changed"
        )
        await DerivedStateInvalidationCenter.shared.publish(change)
    }

    /// A cold write awaiting admission is not projected until its vector lands.
    private static func projectionEligible(_ stored: StoredMemory) -> Bool {
        stored.status == "active" && MemoryLifecycle.isRecallEligible(stored.lifecycle)
            && !metadataFlag(stored.metadata, pendingAdmissionKey)
            && MemoryRecordDisclosurePolicy.isTemporallyEligible(validTo: stored.validTo, at: Date())
    }

    func pokeProjectionHooks(_ stored: StoredMemory) async {
        let deleted = !Self.projectionEligible(stored)
        pokeSpotlight(stored)
        pokeKnowledgeGraph(stored.id)
        await pokeDerivedState(stored, deleted: deleted)
    }

    /// Re-read and enqueue the complete batch without an actor suspension. A deleted row must not be reinserted by an older captured warning update.
    func refreshProjectionHooks(ids: [String]) async throws {
        let current = try enqueueCurrentProjectionHooks(ids: ids)
        for row in current {
            await pokeDerivedState(row, deleted: !Self.projectionEligible(row))
        }
    }

    private func enqueueCurrentProjectionHooks(ids: [String]) throws -> [StoredMemory] {
        let current = try dbPool.read { db in
            try ids.compactMap { id in
                try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id]).map(Self.decodeMemory)
            }
        }
        for row in current {
            pokeSpotlight(row)
            pokeKnowledgeGraph(row.id)
        }
        return current
    }

    static func publishStartupBoundEvictions(
        _ evicted: [StoredMemory],
        memoryPath: URL
    ) {
        guard !evicted.isEmpty else { return }
        nativeLog("MemoryV2 bound: pruned %d overflow row(s) while opening %@",
              evicted.count, memoryPath.lastPathComponent)
        Task {
            for memory in evicted {
                await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
                    namespace: "memory-v2",
                    stableID: memory.id,
                    operation: .removed,
                    canonicalLocator: memoryPath.standardizedFileURL.path,
                    reason: "memory_capacity_evicted_on_open"
                ))
            }
        }
    }

    /// Carry disclosure-filtered person facts with pins first in pinned order, then the remaining facts newest first.
    public func userPromptCore(surface: String) async throws -> [String] {
        let now = Date()
        let dataRoot = path.deletingLastPathComponent().deletingLastPathComponent()
        return try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM memories WHERE status = 'active' AND persona_id = ?
                    AND lifecycle NOT IN \(MemoryLifecycle.recallExcludedSQL)
                ORDER BY CASE WHEN json_extract(metadata_json, '$.pinned') = 1 THEN 0 ELSE 1 END,
                    CASE WHEN json_extract(metadata_json, '$.pinned') = 1
                        THEN COALESCE(json_extract(metadata_json, '$.pinned_order'), 0) END,
                    CASE WHEN json_extract(metadata_json, '$.pinned') = 1 THEN created_at END,
                    CASE WHEN json_extract(metadata_json, '$.pinned') = 1 THEN id END,
                    created_at DESC
            """, arguments: [MemoryV2Defaults.personaID]).map(Self.decodeMemory).filter {
                MemoryRecordDisclosurePolicy.classify(MemoryRecord(stored: $0), at: now)?
                    .permits(surface: surface, personaID: nil) == true
            }
            return Array(UserMDGenerator.userFacts(memories: rows, now: now, dataRoot: dataRoot))
        }
    }
}
