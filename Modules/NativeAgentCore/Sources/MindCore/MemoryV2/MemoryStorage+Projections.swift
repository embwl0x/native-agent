import Foundation
import SenseCore
import GRDB
import NativeAgentCore
import PersistenceCore
import DeskCore
import NativeAgentShared
// Blueprint: | `MemoryStorage+Projections.swift` | `MemoryStorage`, `userPromptCore`: committed page regions, bounded Today moments, ordered derived hooks and user prompt core |

extension MemoryStorage {
    public enum PageProjection: Sendable, Hashable {
        case memories, graph, settings, moments

        var regions: [any DatabaseRegionConvertible] {
            switch self {
            case .memories:
                [SQLRequest<Row>(sql: """
                    SELECT id, content, persona_id, source, confidence, created_at, updated_at,
                           status, lifecycle, valid_from, valid_to, observed_at, evidence_json, metadata_json
                    FROM memories
                    """), SQLRequest<Row>(sql: "SELECT * FROM proposals"),
                 SQLRequest<Row>(sql: "SELECT * FROM correction_occurrences"),
                 SQLRequest<Row>(sql: "SELECT * FROM correction_proposal_occurrences"),
                 SQLRequest<Row>(sql: "SELECT * FROM correction_ledger_state")]
            case .graph:
                [SQLRequest<Row>(sql: "SELECT * FROM kg_entities"), SQLRequest<Row>(sql: "SELECT * FROM kg_relationships")]
            case .settings:
                [SQLRequest<Row>(sql: "SELECT * FROM proposals")]
            case .moments:
                [SQLRequest<Row>(sql: "SELECT id, content, created_at, metadata_json, lifecycle FROM memories")]
            }
        }
    }

    /// Observe commits touching the page's columns. Arm before the initial read; cancellation releases the subscription.
    public func observePage(_ projection: PageProjection, changed: @escaping @Sendable () async -> Void,
                            failed: @escaping @Sendable (String) async -> Void) async {
        let changes = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = DatabaseRegionObservation(tracking: projection.regions).start(in: dbPool,
            onError: { changes.continuation.finish(throwing: $0) },
            onChange: { _ in changes.continuation.yield(()) })
        defer { observation.cancel(); changes.continuation.finish() }
        changes.continuation.yield(())
        do {
            for try await _ in changes.stream {
                guard !Task.isCancelled else { return }
                await changed()
            }
        } catch {
            if !Task.isCancelled { await failed(error.localizedDescription) }
        }
    }

    /// Count this day's visible moments in SQLite; return only the six quotes Today shows, without decoding memory/embedding records.
    public func moments(on day: Date, calendar: Calendar, text: @escaping @Sendable (String, String?) -> String) async throws
        -> (rows: [(id: String, at: Double, text: String)], total: Int, firstAt: Double?, unreadable: Bool) {
        guard let interval = calendar.dateInterval(of: .day, for: day) else {
            throw MemoryStorageError.databaseUnavailable("Today's calendar interval is unavailable.")
        }
        return try await dbPool.read { db in
            // The caller supplies its exact display-text rule; count and selection cannot disagree about an empty quote.
            let words = DatabaseFunction("today_moment_text", argumentCount: 2, pure: true) { args in
                guard let content = String.fromDatabaseValue(args[0]) else {
                    throw MemoryStorageError.databaseUnavailable("A moment has no content.")
                }
                return text(content, String.fromDatabaseValue(args[1]))
            }
            let stamp = DatabaseFunction("today_moment_time", argumentCount: 1, pure: true) { args in
                String.fromDatabaseValue(args[0]).flatMap {
                    NativeTimestampFormat.parseISO8601FractionalFirst($0.trimmingCharacters(in: .whitespacesAndNewlines))
                }?.timeIntervalSince1970
            }
            let live = DatabaseFunction("today_moment_live", argumentCount: 1, pure: true) { args in
                MemoryLifecycle.isRecallEligible(String.fromDatabaseValue(args[0]))
            }
            db.add(function: words); db.add(function: stamp); db.add(function: live)
            defer { db.remove(function: words); db.remove(function: stamp); db.remove(function: live) }
            let eligible = """
                FROM memories WHERE json_extract(metadata_json, '$.kind') = ?
                  AND today_moment_live(lifecycle)
                """
            let selected = eligible + "\n" + """
                  AND today_moment_time(created_at) IS NOT NULL
                  AND julianday(created_at) >= julianday(?) AND julianday(created_at) < julianday(?)
                  AND today_moment_text(content, json_extract(metadata_json, '$.quote')) != ''
                """
            let args: StatementArguments = [MemoryMoments.kind,
                NativeTimestampFormat.fractionalZulu(interval.start), NativeTimestampFormat.fractionalZulu(interval.end)]
            let counts = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS total, MIN(today_moment_time(created_at)) AS first_at " + selected, arguments: args)
            guard let counts else { throw MemoryStorageError.databaseUnavailable("Today's moment count is unavailable.") }
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, today_moment_time(created_at) AS at, today_moment_text(content, json_extract(metadata_json, '$.quote')) AS text
                """ + "\n" + selected + " ORDER BY julianday(created_at) DESC, id DESC LIMIT 6", arguments: args)
            let unreadable = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 " + eligible + " AND today_moment_time(created_at) IS NULL)",
                                              arguments: [MemoryMoments.kind])
            guard let unreadable else { throw MemoryStorageError.databaseUnavailable("Today's moment timestamp status is unavailable.") }
            let moments: [(id: String, at: Double, text: String)] = rows.map { (id: $0["id"], at: $0["at"], text: $0["text"]) }
            return (moments, counts["total"], counts["first_at"], unreadable)
        }
    }

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

    static func publishMemoryChanges(_ ids: [String], at path: URL, removed: Bool = false, reason: String? = nil) async {
        guard let first = ids.first else { return }
        await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
            namespace: "memory-v2",
            stableID: ids.count == 1 ? first : "memory-v2",
            operation: removed ? .removed : .changed,
            canonicalLocator: path.standardizedFileURL.path,
            reason: reason ?? (removed ? "memory_projection_removed" : "memory_projection_changed"),
            touchedMemoryIDs: Set(ids)
        ))
    }

    /// A cold write awaiting admission is not projected until its vector lands.
    private static func projectionEligible(_ stored: StoredMemory) -> Bool {
        stored.status == "active" && MemoryLifecycle.isRecallEligible(stored.lifecycle)
            && !metadataFlag(stored.metadata, pendingAdmissionKey)
            && MemoryRecordDisclosurePolicy.isTemporallyEligible(validTo: stored.validTo, at: Date())
    }

    func pokeProjectionHooks(_ rows: [StoredMemory], deleted: Bool = false, regenerateUserMD: Bool = true) async {
        guard !rows.isEmpty else { return }
        invalidateRecallCache()
        if regenerateUserMD {
            for persona in Set(rows.map(\.personaId)) { pokeUserMDRegen(persona: persona) }
        }
        for row in rows {
            pokeSpotlight(row)
            pokeKnowledgeGraph(row.id)
        }
        await Self.publishMemoryChanges(rows.map(\.id), at: path,
                                        removed: deleted || rows.allSatisfy { !Self.projectionEligible($0) })
    }

    static func publishStartupBoundEvictions(
        _ evicted: [StoredMemory],
        memoryPath: URL
    ) {
        guard !evicted.isEmpty else { return }
        nativeLog("MemoryV2 bound: archived %d active overflow row(s) while opening %@",
              evicted.count, memoryPath.lastPathComponent)
        Task {
            await publishMemoryChanges(evicted.map(\.id), at: memoryPath, removed: true, reason: "memory_capacity_evicted_on_open")
        }
    }

    /// Carry pinned person facts and whether any eligible person facts exist, from one disclosure-filtered read.
    public func userPromptCore(surface: String) async throws -> (facts: [String], established: Bool) {
        let now = Date()
        return try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(Self.memoryProjectionColumns) FROM memories WHERE status = 'active' AND persona_id = ?
                    AND lifecycle NOT IN \(MemoryLifecycle.recallExcludedSQL)
                ORDER BY COALESCE(json_extract(metadata_json, '$.pinned_order'), 0), created_at, id
            """, arguments: [MemoryV2Defaults.personaID]).map(Self.decodeMemoryProjection).filter {
                MemoryRecordDisclosurePolicy.classify(MemoryRecord(stored: $0), at: now)?
                    .permits(surface: surface, personaID: nil) == true
            }
            let pinned = rows.filter { Self.metadataFlag($0.metadata, "pinned") }
            return (Array(UserMDGenerator.userFacts(dataRoot: self.dataRoot, memories: pinned, now: now)),
                    UserMDGenerator.userFacts(dataRoot: self.dataRoot, memories: rows, now: now).contains { _ in true })
        }
    }
}
