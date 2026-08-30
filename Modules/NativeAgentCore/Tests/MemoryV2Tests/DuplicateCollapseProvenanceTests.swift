import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore
import PersistenceCore

// BYTE-IDENTICAL COLLAPSE KEEPS BOTH IDENTITIES (gpt-5.5 review A3, 2026-08-02).
//
// `store()` collapses a byte-identical write onto the existing row and bumps
// `recall_count` — deliberate, and kept: for a lane that writes one prose row
// per event (Workshop executions), a repeat that reads the same is EVIDENCE, not
// clutter.
//
// The defect was what the collapse threw away. It patched `recall_count` and
// nothing else, so two genuinely different executions that produced the same
// summary left the row pointing only at the FIRST one — the second run had no
// recoverable identity anywhere in the store. These tests pin the provenance
// that now accumulates: source lineage, per-occurrence identity fields, and the
// newest observation time.
//
// Run against the REAL SQLite store as well as the in-memory fixture, because
// the metadata merge has to survive the bridge's passthrough allowlist — the
// exact place the `recall_count` bump was silently dropped in 2026-07.

@Suite("DuplicateCollapseProvenance")
struct DuplicateCollapseProvenanceTests {

    @Test func duplicateObservationCompletesProjectionWithoutReembeddingOrRecreating() async throws {
        let root = try makeTempRoot("observation-completion")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        let original = StoredMemory(
            id: "orchard-observation", content: "The orchard gate opens at dusk.",
            source: "fixture:first", createdAt: "2026-08-01T00:00:00Z",
            observedAt: "2026-08-02T00:00:00Z"
        )
        _ = try await storage.insertMemory(original)
        let recorder = DuplicateObservationProjectionRecorder()
        await storage.attachKnowledgeGraphHook { row, deleted in
            if !deleted { await recorder.record(row.observedAt) }
        }
        // Any accidental embedding call fails this save. The duplicate
        // branch must remain independent of provider readiness.
        let memory = SwiftNativeMemoryV2(
            embedder: FailClosedEmbeddingProvider(), storage: MemoryStorageBridge(storage: storage)
        )
        let updated = try await memory.store(
            content: original.content, source: "fixture:repeat",
            metadata: .object(["observed_at": .string("2026-08-03T00:00:00Z")])
        )
        #expect(updated.id == original.id)
        #expect(updated.createdAt == original.createdAt)
        #expect(updated.observedAt == "2026-08-03T00:00:00Z")
        #expect(await recorder.observations == ["2026-08-03T00:00:00Z"])
        #expect(try await storage.listMemories().count == 1)
        #expect(strings(extras(updated)["source_history"]) == ["fixture:first", "fixture:repeat"])
    }

    @Test(arguments: [
        ("2026-08-09T09:00:00Z", "2026-08-09T10:00:00+02:00", false),
        ("2026-08-09T10:00:00+02:00", "2026-08-09T09:30:00Z", true),
        ("2026-08-09T09:00:00Z", "2026-08-09T09:00:00.500Z", true),
        ("2026-08-09T09:00:00.500Z", "2026-08-09T09:00:00Z", false),
        ("2026-08-09T09:00:00Z", "2026-08-09T11:00:00+02:00", false),
        ("2026-08-09T09:00:00Z", "not-a-timestamp", false),
    ])
    func observationOrderingUsesInstants(scenario: (String, String, Bool)) {
        let (existingDate, incomingDate, shouldAdvance) = scenario
        let existing = MemoryRecord(
            id: "observation", text: "The studio opens at nine.",
            createdAt: "2026-08-01T00:00:00Z", observedAt: existingDate
        )
        let patch = SwiftNativeMemoryV2.duplicateProvenancePatch(
            existing: existing, newSource: "fixture:repeat",
            newMetadata: .object(["observed_at": .string(incomingDate)])
        )
        #expect(patch["observed_at"] == (shouldAdvance ? .string(incomingDate) : nil))
    }

    @Test(arguments: ["observed_at", "observedAt"])
    func bothObservationAliasesAdvanceCanonicalSQLiteTime(key: String) async throws {
        let root = try makeTempRoot("observation-alias")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = try sqliteMemory(root: root)
        let text = "The studio opens at nine."
        let first = try await memory.store(
            content: text, source: "fixture:first",
            metadata: .object([key: .string("2026-08-09T10:00:00+02:00")])
        )
        let second = try await memory.store(
            content: text, source: "fixture:repeat",
            metadata: .object([key: .string("2026-08-09T09:30:00Z")])
        )
        #expect(second.id == first.id)
        #expect(second.observedAt == "2026-08-09T09:30:00Z")
        #expect(second.validFrom == nil)
        #expect(second.validTo == nil)
        #expect(strings(extras(second)["source_history"]) == ["fixture:first", "fixture:repeat"])
        let stored = try #require(try await memory.listMemory(kind: nil).first)
        #expect(stored.observedAt == "2026-08-09T09:30:00Z")
    }

    @Test func malformedPreferredObservationAliasDoesNotOverwriteCanonicalTime() {
        let existing = MemoryRecord(
            id: "observation", text: "The studio opens at nine.",
            createdAt: "2026-08-01T00:00:00Z", observedAt: "2026-08-09T09:00:00Z"
        )
        let patch = SwiftNativeMemoryV2.duplicateProvenancePatch(
            existing: existing, newSource: "fixture:repeat",
            newMetadata: .object([
                "observed_at": .string("2026-08-09T10:00:00Z"),
                "observedAt": .string("not-a-timestamp"),
            ])
        )
        #expect(patch["observed_at"] == nil)
    }

    private func makeTempRoot(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateCollapseProvenance-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sqliteMemory(root: URL) throws -> SwiftNativeMemoryV2 {
        SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(),
            storage: MemoryStorageBridge(storage: try MemoryStorage(dataRoot: root))
        )
    }

    /// The execution-memory metadata shape: identity fields plus policy fields.
    private func executionMetadata(
        executionID: String,
        status: String = "completed",
        observedAt: String
    ) -> JSONValue {
        .object([
            "kind": .string("operational"),
            "tags": .array([.string("workshop"), .string("mission")]),
            "workshop_execution_id": .string(executionID),
            "workshop_status": .string(status),
            "observed_at": .string(observedAt),
        ])
    }

    private let narrative = """
        Workshop execution "Sweep the stale release artifacts" completed. \
        2 of 2 planned steps succeeded. It was started by the nightly schedule.
        """

    private func extras(_ record: MemoryRecord) -> [String: JSONValue] {
        if case .object(let m)? = record.extras { return m }
        return [:]
    }

    private func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let arr)? = value else { return [] }
        return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    /// THE FIX, on the real store. Two different executions, identical prose:
    /// one row, count 2 — and BOTH executions recoverable from it.
    @Test func aRepeatIsTraceableToBothRunsOnSQLite() async throws {
        let root = try makeTempRoot("both-runs")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = try sqliteMemory(root: root)

        let first = try await memory.store(
            content: narrative,
            source: "workshop:wsx-alpha",
            metadata: executionMetadata(executionID: "wsx-alpha", observedAt: "2026-08-02T10:00:00Z")
        )
        let second = try await memory.store(
            content: narrative,
            source: "workshop:wsx-beta",
            metadata: executionMetadata(executionID: "wsx-beta", observedAt: "2026-08-09T11:30:00Z")
        )

        // The collapse itself is intact: same row, counted.
        #expect(second.id == first.id)
        let rows = try await memory.listMemory(kind: "operational")
            .filter { ($0.status ?? "active") == "active" }
        #expect(rows.count == 1, "byte-identical prose stays ONE row")
        let meta = extras(second)
        #expect(meta["recall_count"] == .int(1))

        // …and the second run is no longer anonymous.
        #expect(strings(meta["source_history"]) == ["workshop:wsx-alpha", "workshop:wsx-beta"])
        let occurrences: [JSONValue] = {
            if case .array(let arr)? = meta["duplicate_occurrences"] { return arr }
            return []
        }()
        #expect(occurrences.count == 1, "run #1 is the row itself; run #2 is the occurrence")
        guard case .object(let occurrence)? = occurrences.first else {
            Issue.record("no occurrence recorded for the second run")
            return
        }
        #expect(occurrence["workshop_execution_id"] == .string("wsx-beta"))
        #expect(occurrence["source"] == .string("workshop:wsx-beta"))
        // Observation time moved to the LATER run — this is when it was last true.
        #expect(second.observedAt == "2026-08-09T11:30:00Z")
        // The row still names run #1 as its origin.
        #expect(second.sourceRunId == "workshop:wsx-alpha")
    }

    /// The same claim through the in-memory fixture, which now honours the same
    /// unknown-key → metadata contract the SQLite bridge does.
    @Test func aRepeatIsTraceableToBothRunsInMemory() async throws {
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(), storage: InMemoryMemoryStorage())
        _ = try await memory.store(
            content: narrative, source: "workshop:wsx-alpha",
            metadata: executionMetadata(executionID: "wsx-alpha", observedAt: "2026-08-02T10:00:00Z"))
        let second = try await memory.store(
            content: narrative, source: "workshop:wsx-beta",
            metadata: executionMetadata(executionID: "wsx-beta", observedAt: "2026-08-09T11:30:00Z"))

        let meta = extras(second)
        #expect(strings(meta["source_history"]) == ["workshop:wsx-alpha", "workshop:wsx-beta"])
        #expect(meta["recall_count"] == .int(1))
    }

    /// Bounded: a lane that repeats forever must not grow one row's metadata
    /// forever. `recall_count` keeps counting past the provenance cap.
    @Test func provenanceIsBoundedWhileTheCountKeepsCounting() async throws {
        let root = try makeTempRoot("bounded")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = try sqliteMemory(root: root)

        let runs = SwiftNativeMemoryV2.duplicateProvenanceCap + 7
        var last: MemoryRecord?
        for index in 0..<runs {
            last = try await memory.store(
                content: narrative,
                source: "workshop:execution-\(index)",
                metadata: executionMetadata(
                    executionID: "execution-\(index)",
                    observedAt: String(format: "2026-08-%02dT10:00:00Z", (index % 27) + 1)
                )
            )
        }
        let record = try #require(last)
        let meta = extras(record)
        #expect(strings(meta["source_history"]).count == SwiftNativeMemoryV2.duplicateProvenanceCap)
        if case .array(let occurrences)? = meta["duplicate_occurrences"] {
            #expect(occurrences.count <= SwiftNativeMemoryV2.duplicateProvenanceCap)
        } else {
            Issue.record("occurrences missing")
        }
        // The newest runs are the ones kept.
        #expect(strings(meta["source_history"]).last == "workshop:execution-\(runs - 1)")
        #expect(meta["recall_count"] == .int(Int64(runs - 1)), "every repeat is still counted")
    }

    /// A literal RETRY — the identical write, same source, same ids — is a
    /// count, not a second identity. Otherwise a retry loop would fabricate
    /// provenance for runs that never happened.
    @Test func anIdenticalRetryIsCountedNotListedTwice() async throws {
        let root = try makeTempRoot("retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = try sqliteMemory(root: root)
        let meta = executionMetadata(executionID: "wsx-alpha", observedAt: "2026-08-02T10:00:00Z")

        _ = try await memory.store(content: narrative, source: "workshop:wsx-alpha", metadata: meta)
        _ = try await memory.store(content: narrative, source: "workshop:wsx-alpha", metadata: meta)
        let third = try await memory.store(
            content: narrative, source: "workshop:wsx-alpha", metadata: meta)

        let extrasThird = extras(third)
        #expect(strings(extrasThird["source_history"]) == ["workshop:wsx-alpha"])
        if case .array(let occurrences)? = extrasThird["duplicate_occurrences"] {
            #expect(occurrences.count == 0 || occurrences.count == 1,
                    "a retry of the same run adds at most one identity entry")
        }
        #expect(extrasThird["recall_count"] == .int(2))
        // Observation time does not drift on a retry.
        #expect(third.observedAt == "2026-08-02T10:00:00Z")
    }

    /// Observation time only ever moves FORWARD: an out-of-order write of an
    /// OLDER occurrence must not make the row look stale.
    @Test func observationTimeNeverMovesBackward() async throws {
        let root = try makeTempRoot("observed-monotonic")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = try sqliteMemory(root: root)

        _ = try await memory.store(
            content: narrative, source: "workshop:execution-new",
            metadata: executionMetadata(executionID: "execution-new", observedAt: "2026-08-09T11:30:00Z"))
        let older = try await memory.store(
            content: narrative, source: "workshop:wsx-old",
            metadata: executionMetadata(executionID: "wsx-old", observedAt: "2026-07-01T08:00:00Z"))

        #expect(older.observedAt == "2026-08-09T11:30:00Z")
        // …but the older run is still traceable.
        #expect(strings(extras(older)["source_history"]).contains("workshop:wsx-old"))
    }
}

private actor DuplicateObservationProjectionRecorder {
    private(set) var observations: [String] = []
    func record(_ value: String?) {
        if let value { observations.append(value) }
    }
}
