import Foundation
import Testing
@testable import MemoryV2

/// Evals for ledger surfaces `memory.embedding.derivedContextEmbed` and
/// `memory.embedding.warmUp` (docs/evals/ledger.json, fence core.memory).
///
/// `embedForDerivedContext` / `embedForDerivedContextWithEpoch` are the
/// embedder's door for the fluid-context / cognition subsystem — the per-turn
/// context-selection query vector goes through them. Nothing at any tier named
/// either method.
///
/// Silent-failure class: silent zero in a lane outside memory. Under the
/// fail-closed contract these throw when the CoreML resources are missing, so a
/// caller that `try?`s them degrades context selection to no-signal without a
/// symptom: the turn still assembles, just without the memory the mind asked
/// for. The epoch variant exists precisely so those query vectors are comparable
/// to STORED vectors — a derived-context vector from a different vector space
/// scores as garbage against the corpus, which is exactly what the epoch
/// machinery is there to prevent.
///
/// Envelope asserted (no exact vectors, no exact epoch string):
///  - the epoch the door hands back EQUALS the store's active epoch, and the
///    vector width equals the stored corpus width;
///  - the vectors are the same ones the memory lane itself would produce for
///    that text — the door is a projection, not a second embedder;
///  - a fail-closed embedder makes the door THROW; it never returns [] or a
///    zero vector that a `try?` would launder into "no memory signal".
@Suite("MemoryV2 derived-context embedding door")
struct DerivedContextEmbeddingDoorTests {

    private final class DriftingEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
        let storage: MemoryStorage
        let dimensions = 8
        let lock = NSLock()
        private var inputs: [String] = []
        private var batches = 0
        private var model = "retry-test"
        var modelId: String { lock.withLock { model } }
        var calls: [String] { lock.withLock { inputs } }
        func changeEpoch() { lock.withLock { model = "retry-test-next" } }

        init(storage: MemoryStorage) { self.storage = storage }

        func embed(_ texts: [String]) async throws -> [[Float]] {
            let batch = lock.withLock {
                inputs += texts
                batches += 1
                return batches
            }
            if batch == 1 {
                _ = try await storage.insertMemory(StoredMemory(id: "new", content: "new text"))
            } else if batch == 2 {
                _ = try await storage.updateMemory(id: "change", patch: MemoryPatch(content: "changed text"))
                _ = try await storage.deleteMemory(id: "remove")
            }
            return try await MockEmbeddingProvider(dimensions: dimensions).embed(texts)
        }
    }

    @Test("drift retries reuse unchanged vectors and keep atomic activation", arguments: [false, true])
    func migrationRetriesReuseCandidates(changeEpoch: Bool) async throws {
        let storage = try MemoryStorage()
        for id in ["keep", "change", "remove"] {
            _ = try await storage.insertMemory(StoredMemory(id: id, content: "\(id) text"))
        }
        let provider = DriftingEmbeddingProvider(storage: storage)
        let memory = SwiftNativeMemoryV2(
            embedder: provider, storage: MemoryStorageBridge(storage: storage)
        )
        for attempt in 1...2 {
            do {
                _ = try await memory.reindexAllMemoryEmbeddingsForCurrentProvider()
                Issue.record("expected corpus drift on attempt \(attempt)")
            } catch let error as MemoryStorageError {
                guard case .embeddingActivationInvalid(.corpusDrift, _) = error else { throw error }
            }
            #expect(try await storage.embeddingEpochState().activeEpoch == nil)
            if attempt == 1, changeEpoch { provider.changeEpoch() }
        }
        let report = try await memory.reindexAllMemoryEmbeddingsForCurrentProvider()
        #expect(report.memories == 3)
        #expect(report.tombstones == 1)
        #expect(report.epoch == provider.embeddingEpoch.rawValue)
        // Deleted memory text must be embedded again under its NEW tombstone
        // identity; it must not borrow the removed memory's candidate.
        #expect(provider.calls.count == (changeEpoch ? 9 : 6))
        #expect(provider.calls.filter { $0 == "keep text" }.count == (changeEpoch ? 2 : 1))
        #expect(provider.calls.filter { $0 == "changed text" }.count == 1)
        // Success releases the retry map: a later explicit reindex is fresh.
        _ = try await memory.reindexAllMemoryEmbeddingsForCurrentProvider()
        #expect(provider.calls.count == (changeEpoch ? 13 : 10))
    }

    // MARK: - probes

    /// Counts calls so warm-up can be proven to actually issue an embed.
    private final class CountingEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
        private let inner = MockEmbeddingProvider(dimensions: 8)
        private let lock = NSLock()
        private var _calls: [[String]] = []

        var calls: [[String]] { lock.withLock { _calls } }
        var dimensions: Int { inner.dimensions }
        var modelId: String { inner.modelId }
        var embeddingEpoch: MemoryEmbeddingEpoch { inner.embeddingEpoch }

        func embed(_ texts: [String]) async throws -> [[Float]] {
            lock.withLock { _calls.append(texts) }
            return try await inner.embed(texts)
        }

        func embedWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch {
            lock.withLock { _calls.append(texts) }
            return try await inner.embedWithEpoch(texts)
        }
    }

    private func makeTempRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memv2-derived-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeMemory(
        root: URL,
        embedder: any EmbeddingProvider
    ) throws -> (memory: SwiftNativeMemoryV2, storage: MemoryStorage) {
        let storage = try MemoryStorage(dataRoot: root)
        let memory = SwiftNativeMemoryV2(
            embedder: embedder,
            storage: MemoryStorageBridge(storage: storage)
        )
        return (memory, storage)
    }

    // MARK: - derivedContextEmbed

    @Test("the derived-context door returns the store's ACTIVE epoch and corpus width")
    func derivedContextEpochMatchesActiveCorpusEpoch() async throws {
        let root = try makeTempRoot("epoch")
        defer { try? FileManager.default.removeItem(at: root) }
        let embedder = MockEmbeddingProvider(dimensions: 8)
        let (memory, storage) = try makeMemory(root: root, embedder: embedder)

        _ = try await storage.insertMemory(StoredMemory(
            id: "corpus-1", content: "User sequences the tracks; I work inside one"
        ))
        _ = try await storage.insertMemory(StoredMemory(
            id: "corpus-2", content: "a worker returns finished, build-tested work"
        ))

        // Bring the corpus into a real vector space the way production does.
        let report = try await memory.reindexAllMemoryEmbeddingsForCurrentProvider()
        #expect(report.memories == 2)
        let activeEpoch = try #require(try await memory.memoryEmbeddingEpochState().activeEpoch)

        let batch = try await memory.embedForDerivedContextWithEpoch([
            "what did User say about sequencing tracks",
            "how big is a finished worker deliverable",
        ])

        // THE property: a context-selection query vector is comparable to the
        // stored corpus. Same vector space, same width.
        #expect(batch.epoch.rawValue == activeEpoch,
                "the derived-context door handed back a vector from a different epoch than the corpus")
        #expect(batch.vectors.count == 2)
        let storedWidth = try #require(try await storage.memory(id: "corpus-1")?.embedding?.count)
        for vector in batch.vectors {
            #expect(vector.count == storedWidth,
                    "derived-context vector width \(vector.count) != stored corpus width \(storedWidth)")
            #expect(vector.contains { $0 != 0 }, "derived-context vector is all zeros")
        }

        // A query embedded through the door is actually usable against the
        // store under that epoch — the guard is not vacuous.
        let epoch = MemoryEmbeddingEpoch(rawValue: activeEpoch)
        let hits = try await storage.recall(
            embedding: batch.vectors[0], embeddingEpoch: epoch, topK: 5
        )
        #expect(!hits.isEmpty, "a door-embedded query matched nothing under the corpus's own epoch")
    }

    @Test("the door is a projection of the memory embedder, not a second one")
    func doorVectorsMatchTheMemoryLaneEmbedder() async throws {
        let root = try makeTempRoot("projection")
        defer { try? FileManager.default.removeItem(at: root) }
        let embedder = MockEmbeddingProvider(dimensions: 8)
        let (memory, _) = try makeMemory(root: root, embedder: embedder)

        let text = "context selection asked memory for a vector"
        let viaDoor = try await memory.embedForDerivedContext([text])
        let viaEmbedder = try await embedder.embed([text])
        #expect(viaDoor == viaEmbedder,
                "the derived-context door produced different vectors than the memory embedder")

        // Contract on the empty case: no vectors, no embedder call, still the
        // provider's epoch (so a caller can bind an empty batch to a space).
        let empty = try await memory.embedForDerivedContextWithEpoch([])
        #expect(empty.vectors.isEmpty)
        #expect(empty.epoch == embedder.embeddingEpoch)
        #expect(try await memory.embedForDerivedContext([]).isEmpty)
    }

    @Test("a fail-closed embedder makes the door throw, never return a silent zero")
    func doorFailsClosedRatherThanReturningNoSignal() async throws {
        let root = try makeTempRoot("failclosed")
        defer { try? FileManager.default.removeItem(at: root) }
        let (memory, _) = try makeMemory(
            root: root, embedder: FailClosedEmbeddingProvider(dimensions: 8)
        )

        await #expect(throws: (any Error).self) {
            _ = try await memory.embedForDerivedContext(["a per-turn context query"])
        }
        await #expect(throws: (any Error).self) {
            _ = try await memory.embedForDerivedContextWithEpoch(["a per-turn context query"])
        }

        // And with NO embedder wired at all the door must still refuse rather
        // than hand back an empty result that reads as "nothing relevant".
        let unwired = SwiftNativeMemoryV2()
        await #expect(throws: MemoryV2Error.self) {
            _ = try await unwired.embedForDerivedContext(["a per-turn context query"])
        }
        await #expect(throws: MemoryV2Error.self) {
            _ = try await unwired.embedForDerivedContextWithEpoch(["a per-turn context query"])
        }
    }

    // MARK: - warmUpEmbedder

    /// `memory.embedding.warmUp` — slowdown, invisible. Warm-up is what keeps
    /// the first recall of a session off a cold CoreML compile+load. If it
    /// stops issuing an embed, nothing fails; every session's first memory
    /// recall just pays seconds of model load and the only symptom is "she felt
    /// slow at first".
    ///
    /// The RECEIPT-freshness half of the proposed eval (is
    /// data/memory/embedding_epoch_receipt.json newer than the running process)
    /// is instrument-tier and lives outside this fence — see the BUILD report.
    /// What is provable here is that the call actually reaches the provider.
    @Test("warm-up actually issues an embed against the wired provider")
    func warmUpIssuesAnEmbed() async throws {
        let root = try makeTempRoot("warmup")
        defer { try? FileManager.default.removeItem(at: root) }
        let counting = CountingEmbeddingProvider()
        let (memory, _) = try makeMemory(root: root, embedder: counting)

        #expect(counting.calls.isEmpty)
        try await memory.warmUpEmbedder()
        #expect(counting.calls.count == 1,
                "warmUpEmbedder did not reach the provider — the model is still cold at first recall")
        #expect(counting.calls[0].count == 1,
                "warm-up should embed a single trivial text, not a batch")
    }

    @Test("warm-up propagates the fail-closed error instead of reporting a warm model")
    func warmUpPropagatesFailClosed() async throws {
        let root = try makeTempRoot("warmup-failclosed")
        defer { try? FileManager.default.removeItem(at: root) }
        let (memory, _) = try makeMemory(
            root: root, embedder: FailClosedEmbeddingProvider(dimensions: 8)
        )
        await #expect(throws: (any Error).self) {
            try await memory.warmUpEmbedder()
        }

        // With no embedder wired, warm-up is a documented no-op — it must not
        // throw, or launch would surface a spurious failure.
        let unwired = SwiftNativeMemoryV2()
        try await unwired.warmUpEmbedder()
    }
}
