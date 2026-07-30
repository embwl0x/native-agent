import Context
import Foundation
import MemoryV2
import PersistenceCore
import Testing
@testable import NativeAgentApp

private actor ProjectionMemoryMock: NativeMemoryContextProjectionMemory {
    private var records: [NativeMemoryProjectionRecord]
    private let fingerprint: String
    private var batches: [[String]] = []

    init(records: [NativeMemoryProjectionRecord], fingerprint: String = "projection-test:3") {
        self.records = records
        self.fingerprint = fingerprint
    }

    func listContextProjectionRecords() async throws -> [NativeMemoryProjectionRecord] {
        records
    }

    func contextProjectionEmbeddingModelFingerprint() async throws -> String {
        fingerprint
    }

    func embedForDerivedContext(_ texts: [String]) async throws -> [[Float]] {
        batches.append(texts)
        return texts.map { text in
            [Float(text.utf8.count), Float(text.unicodeScalars.count), 1]
        }
    }

    func replaceRecords(_ value: [NativeMemoryProjectionRecord]) {
        records = value
    }

    func resetBatches() {
        batches = []
    }

    func observedBatches() -> [[String]] {
        batches
    }
}

@Suite("Native MemoryV2 Context projection")
struct NativeMemoryContextProjectionTests {
    @Test("emits deterministic policy, authority, ranking metadata, and provenance")
    func emitsDeterministicMetadata() async throws {
        let record = memoryRecord(
            id: "memory-1",
            text: "User prefers concise technical summaries.",
            pinned: true,
            confidence: 0.72,
            importance: 0.83,
            tags: ["Work", "privacy:public_safe", "work"],
            sourceQuality: 0.61,
            decay: .object(["factor": .double(0.44)]),
            correction: .object(["current": .bool(true)]),
            provenance: .object(["surface": .string("chat")])
        )
        let memory = ProjectionMemoryMock(records: [record])
        let projection = NativeMemoryContextProjection(memory: memory)

        let first = try await projection.compiledProjection(previousSources: [:])
        let second = try await projection.compiledProjection(previousSources: [:])
        let source = try #require(first.changedSources.first)
        let atom = try #require(source.atoms.first)

        #expect(first.changedSources.map(\.descriptor.id) == second.changedSources.map(\.descriptor.id))
        #expect(first.changedSources.map(\.atoms.first?.id) == second.changedSources.map(\.atoms.first?.id))
        #expect(source.descriptor.kind == .memory)
        #expect(source.descriptor.authority == .explicitCorrection)
        #expect(source.descriptor.privacy == .publicSafe)
        #expect(source.descriptor.permittedSurfaces == [
            .chat, .telegram, .ios, .slack, .workshop, .bridge,
        ])
        #expect(source.descriptor.injectionPolicy == .adaptive)
        #expect(atom.kind == .correction)
        #expect(atom.authority == .explicitCorrection)
        #expect(atom.injectionPolicy == .adaptive)
        #expect(atom.confidence == 0.72)
        #expect(atom.activation == 0.83)
        #expect(atom.recentUsefulness == 0.61)
        #expect(atom.decayState == 0.44)
        #expect(atom.triggers == ["privacy:public_safe", "work"])
        #expect(atom.entities.contains { $0.kind == "memory_authority" && $0.id == "correction" })
        #expect(atom.entities.contains { $0.kind == "provenance" && $0.label.contains("source_run_id=test-run") })
        #expect(atom.entities.contains { $0.kind == "provenance" && $0.label.contains("\"surface\":\"chat\"") })
        #expect(atom.embedding?.modelFingerprint == "projection-test:3")
    }

    /// Cross-vocabulary guard (2026-07-24). This is the production side of the
    /// persona-scope mismatch: the ONLY persona scope this writer can mint is a
    /// digest of the RECORD persona id (an agent name). Persona SLOT ids —
    /// "canonical" and custom persona subdirectory names, which is what the
    /// ContextFlow mirror carries into the coordinator's memory-scope gate —
    /// are never produced here. That asymmetry is exactly why a slot id is
    /// PRESENTATION-ONLY (User approved 2026-07-24) and why the coordinator
    /// admits the shared store for every slot: a slot-scoped record is
    /// unmintable, so a slot-scoped gate protects an empty set forever.
    ///
    /// If someone teaches the projection to mint slot-id scopes (a product
    /// decision, not a bug fix), this test fails AND the coordinator's
    /// vocabulary-drift alarm starts firing. Both lanes must then be
    /// re-reconciled together.
    @Test("persona scopes are minted from record persona ids, never from slot ids")
    func personaScopeUsesRecordPersonaVocabularyOnly() async throws {
        let memory = ProjectionMemoryMock(records: [
            memoryRecord(
                id: "memory-resident",
                text: "User drinks jasmine tea after lunch, reliably.",
                personaID: "ResidentAgent"
            ),
            memoryRecord(
                id: "memory-application",
                text: "The greenhouse irrigation schedule runs at dawn daily.",
                personaID: "NativeAgent"
            ),
        ])
        let projection = NativeMemoryContextProjection(memory: memory)

        let compiled = try await projection.compiledProjection(previousSources: [:])
        let locators = Set(compiled.changedSources.map(\.descriptor.canonicalLocator))

        // Agent-name scopes: exactly what the live store yields.
        #expect(locators.contains { $0.hasPrefix(
            "memory-v2/personas/\(ContextStableID.digest(parts: ["residentagent"]))/"
        ) })
        #expect(locators.contains { $0.hasPrefix(
            "memory-v2/personas/\(ContextStableID.digest(parts: ["nativeagent"]))/"
        ) })

        // Slot-id scopes: never minted. "canonical" is the resident slot id;
        // "CustomPersona" stands in for any custom persona subdirectory name.
        for slotID in ["canonical", "custompersona"] {
            let slotPrefix = "memory-v2/personas/\(ContextStableID.digest(parts: [slotID]))/"
            #expect(!locators.contains { $0.hasPrefix(slotPrefix) })
        }
    }

    @Test("reuses unchanged compiled records and removes inactive or absent memory sources")
    func reusesAndRemoves() async throws {
        let kept = memoryRecord(id: "keep", text: "Keep this stable memory.")
        let removed = memoryRecord(id: "remove", text: "This memory will be archived.")
        let memory = ProjectionMemoryMock(records: [removed, kept])
        let projection = NativeMemoryContextProjection(memory: memory)
        let initial = try await projection.compiledProjection(previousSources: [:])
        let previous = Dictionary(uniqueKeysWithValues: initial.changedSources.map {
            ($0.descriptor.id, $0)
        })
        let removedID = try #require(
            initial.changedSources.first { $0.atoms.first?.body.contains("archived") == true }
        ).descriptor.id

        var inactive = removed
        inactive.status = "archived"
        await memory.replaceRecords([kept, inactive])
        await memory.resetBatches()

        let rebuilt = try await projection.compiledProjection(previousSources: previous)

        #expect(rebuilt.changedSources.isEmpty)
        #expect(rebuilt.removedSourceIDs == [removedID])
        #expect(await memory.observedBatches().isEmpty)
    }

    @Test("bounds records and embedding batches after rejecting malformed or secret-like text")
    func boundsAndRejects() async throws {
        let records = [
            memoryRecord(id: "d", text: "four"),
            memoryRecord(id: "b", text: "two"),
            memoryRecord(
                id: "secret",
                text: ["api_key = ", "sk-", "123456789012345678901234"].joined()
            ),
            memoryRecord(id: "empty", text: "  \n"),
            memoryRecord(id: "a", text: "one"),
            memoryRecord(id: "c", text: "three"),
        ]
        let memory = ProjectionMemoryMock(records: records)
        let projection = NativeMemoryContextProjection(
            memory: memory,
            limits: NativeMemoryContextProjectionLimits(
                maximumRecords: 3,
                maximumTextUTF8Bytes: 32,
                maximumEmbeddingBatchSize: 2
            )
        )

        let result = try await projection.compiledProjection(previousSources: [:])
        let batches = await memory.observedBatches()

        #expect(result.changedSources.count == 3)
        #expect(result.changedSources.flatMap(\.atoms).map(\.body) == ["one", "two", "three"])
        #expect(batches.map(\.count) == [2, 1])
        #expect(batches.flatMap { $0 }.allSatisfy { !$0.contains("sk-") })
    }

    @Test("pinned records are canonical but remain adaptive and private by default")
    func pinnedAuthorityAndPrivatePolicy() async throws {
        let record = memoryRecord(
            id: "pinned",
            text: "A deliberately pinned preference.",
            pinned: true,
            tags: ["surface:chat", "surface:telegram"]
        )
        let result = try await NativeMemoryContextProjection(
            memory: ProjectionMemoryMock(records: [record])
        ).compiledProjection(previousSources: [:])
        let source = try #require(result.changedSources.first)
        let atom = try #require(source.atoms.first)

        #expect(source.descriptor.authority == .canonical)
        #expect(source.descriptor.privacy == .localPrivate)
        #expect(source.descriptor.permittedSurfaces == [.chat, .telegram])
        #expect(source.descriptor.injectionPolicy == .adaptive)
        #expect(atom.entities.contains { $0.kind == "memory_authority" && $0.id == "pinned" })
    }

    @Test("persona scope enters disclosure locator without changing record atom identity")
    func personaScopedLocatorKeepsStableAtomIdentity() async throws {
        let recordID = "persona-scoped"
        let scoped = try await NativeMemoryContextProjection(
            memory: ProjectionMemoryMock(records: [memoryRecord(
                id: recordID,
                text: "User prefers concise technical summaries.",
                personaID: "Agent"
            )])
        ).compiledProjection(previousSources: [:])
        let source = try #require(scoped.changedSources.first)
        let atom = try #require(source.atoms.first)
        let expectedScope = ContextStableID.digest(parts: ["agent"])

        #expect(source.descriptor.canonicalLocator.hasPrefix(
            "memory-v2/personas/\(expectedScope)/records/"
        ))
        #expect(atom.id == NativeContextFlowRuntime.memoryRecordAtomID(forRecordID: recordID))
    }

    @Test("quarantines non-durable automatic memories before Fluid Context")
    func rejectsAutomaticMemoryVapor() async throws {
        let bad = memoryRecord(
            id: "bad-auto-memory",
            text: "user wants actually gone",
            kind: "goal",
            sourceRunId: "adaptive-promoter:telegram-session"
        )
        let good = memoryRecord(
            id: "good-memory",
            text: "User prefers concise technical summaries.",
            kind: "preference",
            sourceRunId: "chat.commit_memory"
        )

        let result = try await NativeMemoryContextProjection(
            memory: ProjectionMemoryMock(records: [bad, good])
        ).compiledProjection(previousSources: [:])

        #expect(result.changedSources.flatMap(\.atoms).map(\.body) == [
            "User prefers concise technical summaries."
        ])
    }
}

private func memoryRecord(
    id: String,
    text: String,
    kind: String = "preference",
    sourceRunId: String = "test-run",
    pinned: Bool? = nil,
    confidence: Double? = 0.9,
    importance: Double? = 0.5,
    tags: [String]? = nil,
    sourceQuality: Double? = nil,
    decay: JSONValue? = nil,
    correction: JSONValue? = nil,
    provenance: JSONValue? = nil,
    personaID: String? = nil
) -> NativeMemoryProjectionRecord {
    NativeMemoryProjectionRecord(
        id: id,
        text: text,
        layer: "semantic",
        memoryKind: kind,
        createdAt: "2026-07-09T12:00:00Z",
        updatedAt: "2026-07-09T12:01:00Z",
        sourceRunId: sourceRunId,
        status: "active",
        pinned: pinned,
        confidence: confidence,
        importance: importance,
        tags: tags,
        sourceQuality: sourceQuality,
        decay: decay,
        correction: correction,
        provenance: provenance,
        extras: nil,
        personaId: personaID
    )
}

// MARK: - Packet provenance reverse index (2026-07-11)

@Suite("Memory atom record provenance index")
struct MemoryAtomRecordIndexTests {

    @Test("compile fills the index with atomID → recordID for the published set")
    func compileFillsIndex() async throws {
        let index = MemoryAtomRecordIndex()
        let mock = ProjectionMemoryMock(records: [
            memoryRecord(id: "rec-a", text: "User prefers matcha over coffee in the mornings"),
            memoryRecord(id: "rec-b", text: "The greenhouse irrigation schedule runs at dawn daily"),
        ])
        let projection = NativeMemoryContextProjection(
            memory: mock,
            limits: .standard,
            provenanceIndex: index
        )
        let result = try await projection.compiledProjection(previousSources: [:])
        #expect(index.count == 2)

        // The index answer must be EXACTLY the projection's own minted atom
        // IDs — provenance is only honest if it round-trips the real hashes.
        let atomIDs = result.changedSources.flatMap { $0.atoms.map(\.id) }
        let resolved = Set(index.recordIDs(for: atomIDs))
        #expect(resolved == ["rec-a", "rec-b"])

        // Unknown atoms (another owner's hashes) are benign misses.
        let foreign = ContextStableID.atom(
            sourceID: ContextStableID.source(owner: "other.owner", locator: "x"),
            kind: .memory, headingPath: [], blockAnchor: "memory-record"
        )
        #expect(index.recordIDs(for: [foreign]).isEmpty)
    }

    @Test("a projection that publishes zero records clears stale identity")
    func emptyCompileClearsIndex() async throws {
        let index = MemoryAtomRecordIndex()
        let mock = ProjectionMemoryMock(records: [
            memoryRecord(id: "rec-a", text: "User prefers matcha over coffee in the mornings"),
        ])
        let projection = NativeMemoryContextProjection(
            memory: mock,
            limits: .standard,
            provenanceIndex: index
        )
        _ = try await projection.compiledProjection(previousSources: [:])
        #expect(index.count == 1)

        await mock.replaceRecords([])
        _ = try await projection.compiledProjection(previousSources: [:])
        #expect(index.count == 0, "stale identity must not outlive its records")
    }
}
