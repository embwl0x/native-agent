import Testing
import Foundation
#if canImport(CoreML) && !os(Linux)
import CoreML
#endif
@testable import MemoryV2
import NativeAgentCore
import NativeAgentTestSupport

@Suite("MemoryV2 Embedding framework (Phase B)")
struct EmbeddingTests {

    struct FakeCoreMLEmbedder: EmbeddingProvider {
        let dimensions: Int = 3
        let modelId: String = "fake-coreml"

        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { text in
                let n = Float(text.count)
                return [n, n + 1, n + 2]
            }
        }
    }

    // MARK: MockEmbeddingProvider

    @Test("mockEmbedder_returns_deterministic_vectors_for_same_text")
    func mockEmbedder_returns_deterministic_vectors_for_same_text() async throws {
        let m = MockEmbeddingProvider()
        let a = try await m.embed(["hello claude"])
        let b = try await m.embed(["hello claude"])
        #expect(a == b)
    }

    @Test("mockEmbedder_dimensions_is_384")
    func mockEmbedder_dimensions_is_384() async throws {
        let m = MockEmbeddingProvider()
        #expect(m.dimensions == 384)
        let v = try await m.embed(["x"])
        #expect(v.first?.count == 384)
    }

    @Test("mockEmbedder_different_texts_produce_different_vectors")
    func mockEmbedder_different_texts_produce_different_vectors() async throws {
        let m = MockEmbeddingProvider()
        let vecs = try await m.embed(["alpha", "beta"])
        #expect(vecs.count == 2)
        #expect(vecs[0] != vecs[1])
    }

    // MARK: CoreMLEmbeddingProvider

    @Test("coreMLEmbedder_init_throws_for_missing_modelURL")
    func coreMLEmbedder_init_throws_for_missing_modelURL() async throws {
        let bogus = URL(fileURLWithPath: "/tmp/does_not_exist_\(UUID().uuidString).mlpackage")
        #expect(throws: EmbeddingError.self) {
            _ = try CoreMLEmbeddingProvider(modelURL: bogus)
        }
    }

    @Test("coreMLEmbedder_init_throws_for_invalid_extension")
    func coreMLEmbedder_init_throws_for_invalid_extension() async throws {
        let bogus = URL(fileURLWithPath: "/tmp/whatever_\(UUID().uuidString).txt")
        #expect(throws: EmbeddingError.self) {
            _ = try CoreMLEmbeddingProvider(modelURL: bogus)
        }
    }

    @Test("coreMLEmbedder_init_throws_for_non_file_url")
    func coreMLEmbedder_init_throws_for_non_file_url() async throws {
        let remote = URL(string: "https://example.com/model.mlpackage")!
        #expect(throws: EmbeddingError.self) {
            _ = try CoreMLEmbeddingProvider(modelURL: remote)
        }
    }

    // MARK: ManagedEmbeddingProvider

    private func tempDataRoot() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("managed-embedder-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("managedEmbedder_backend_off_uses_mock_without_loading_coreml")
    func managedEmbedder_backend_off_uses_mock_without_loading_coreml() async throws {
        let provider = ManagedEmbeddingProvider(
            dataRoot: tempDataRoot(),
            loader: { _ in throw EmbeddingError.modelNotFound(path: "should not load") },
            availabilityProbe: { true }
        )

        try await provider.setBackend(enabled: false)
        let vecs = try await provider.embed(["off mode"])
        let snap = provider.snapshot()

        #expect(vecs.first?.count == 384)
        #expect(snap.requestedBackend == ManagedEmbeddingProvider.mockBackend)
        #expect(snap.effectiveBackend == ManagedEmbeddingProvider.mockBackend)
        #expect(snap.embeddingEpoch == MockEmbeddingProvider().embeddingEpoch.rawValue)
        #expect(snap.coreMLLoaded == false)
        #expect(snap.loadCount == 0)
    }

    @Test("managedEmbedder_release_drops_loaded_coreml_provider")
    func managedEmbedder_release_drops_loaded_coreml_provider() async throws {
        let provider = ManagedEmbeddingProvider(
            dataRoot: tempDataRoot(),
            loader: { _ in FakeCoreMLEmbedder() },
            availabilityProbe: { true }
        )

        let vecs = try await provider.embed(["hello"])
        let loaded = provider.snapshot()
        _ = provider.release(reason: "test release")
        let released = provider.snapshot()

        #expect(vecs == [[5, 6, 7]])
        #expect(loaded.coreMLLoaded == true)
        #expect(loaded.modelId == "fake-coreml")
        #expect(loaded.embeddingEpoch == FakeCoreMLEmbedder().embeddingEpoch.rawValue)
        #expect(loaded.loadCount == 1)
        #expect(released.coreMLLoaded == false)
        #expect(released.embeddingEpoch == nil)
        #expect(released.unloadReason == "test release")
        #expect(released.unloadCount == 1)
    }

    @Test("managedEmbedder_low_memory_mode_reports_short_idle_unload")
    func managedEmbedder_low_memory_mode_reports_short_idle_unload() async throws {
        let provider = ManagedEmbeddingProvider(
            dataRoot: tempDataRoot(),
            loader: { _ in FakeCoreMLEmbedder() },
            availabilityProbe: { true }
        )

        try await provider.setMemoryMode(ManagedEmbeddingProvider.lowMemoryMode)
        let snap = provider.snapshot()

        #expect(snap.mode == ManagedEmbeddingProvider.lowMemoryMode)
        #expect(snap.idleUnloadSeconds == 45)
    }

    // MARK: A5.4 — .cpuOnly compute path for low-memory mode

    /// Records what `lowMemory` value the load path actually handed the loader.
    private final class LoaderSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [Bool] = []

        func record(_ lowMemory: Bool) {
            lock.lock()
            defer { lock.unlock() }
            calls.append(lowMemory)
        }

        var recorded: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    @Test("embeddingComputeUnits_cpuOnly_only_for_low_memory_mode")
    func embeddingComputeUnits_cpuOnly_only_for_low_memory_mode() async throws {
        #expect(ManagedEmbeddingProvider.usesCPUOnlyCompute(mode: ManagedEmbeddingProvider.lowMemoryMode))
        #expect(ManagedEmbeddingProvider.usesCPUOnlyCompute(mode: "  LOW_MEMORY "))
        #expect(!ManagedEmbeddingProvider.usesCPUOnlyCompute(mode: ManagedEmbeddingProvider.performanceMode))
        #expect(!ManagedEmbeddingProvider.usesCPUOnlyCompute(mode: ManagedEmbeddingProvider.balancedMode))
        // Unknown / empty normalize to balanced — never a silent .cpuOnly.
        #expect(!ManagedEmbeddingProvider.usesCPUOnlyCompute(mode: "wat"))
        #expect(!ManagedEmbeddingProvider.usesCPUOnlyCompute(mode: ""))
    }

    #if canImport(CoreML) && !os(Linux)
    @Test("coreMLEmbedder_modelConfiguration_pins_cpuOnly_for_low_memory")
    func coreMLEmbedder_modelConfiguration_pins_cpuOnly_for_low_memory() async throws {
        let lowMemory = CoreMLEmbeddingProvider.modelConfiguration(lowMemory: true)
        #expect(lowMemory?.computeUnits == .cpuOnly)
        // nil == "no configuration argument at all" — the untouched default load.
        #expect(CoreMLEmbeddingProvider.modelConfiguration(lowMemory: false) == nil)
    }
    #endif

    @Test("managedEmbedder_passes_low_memory_flag_to_loader_at_load_time")
    func managedEmbedder_passes_low_memory_flag_to_loader_at_load_time() async throws {
        let spy = LoaderSpy()
        let provider = ManagedEmbeddingProvider(
            dataRoot: tempDataRoot(),
            loader: { lowMemory in
                spy.record(lowMemory)
                return FakeCoreMLEmbedder()
            },
            availabilityProbe: { true }
        )

        _ = try await provider.embed(["default mode"])
        #expect(spy.recorded == [false])

        // Flipping into low_memory drops the resident model, so the next embed
        // reloads — this time with cpuOnly requested.
        try await provider.setMemoryMode(ManagedEmbeddingProvider.lowMemoryMode)
        #expect(provider.snapshot().coreMLLoaded == false)
        _ = try await provider.embed(["low memory mode"])
        #expect(spy.recorded == [false, true])
    }

    @Test("managedEmbedder_external_mode_edit_evicts_stale_compute_units")
    func managedEmbedder_external_mode_edit_evicts_stale_compute_units() async throws {
        // gpt-5.5 BLOCKING pin (2026-07-24): a mode.json write that BYPASSES
        // setMemoryMode (iOS sync, another process) must still evict the
        // resident provider on the next embed — the per-embed mode read and
        // the resident provider's loaded selection must never disagree.
        let root = tempDataRoot()
        let spy = LoaderSpy()
        let provider = ManagedEmbeddingProvider(
            dataRoot: root,
            loader: { lowMemory in
                spy.record(lowMemory)
                return FakeCoreMLEmbedder()
            },
            availabilityProbe: { true }
        )

        _ = try await provider.embed(["default"])
        #expect(spy.recorded == [false])

        // External edit: write mode.json directly, no setMemoryMode call.
        let modeURL = root
            .appendingPathComponent("embeddings", isDirectory: true)
            .appendingPathComponent("mode.json")
        try FileManager.default.createDirectory(
            at: modeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"mode\":\"low_memory\"}".utf8).write(to: modeURL)

        _ = try await provider.embed(["after external edit"])
        #expect(spy.recorded == [false, true])

        // And back again — reverse direction must evict too.
        try Data("{\"mode\":\"balanced\"}".utf8).write(to: modeURL)
        _ = try await provider.embed(["back to balanced"])
        #expect(spy.recorded == [false, true, false])
    }

    @Test("managedEmbedder_mode_change_without_compute_flip_keeps_model_hot")
    func managedEmbedder_mode_change_without_compute_flip_keeps_model_hot() async throws {
        let provider = ManagedEmbeddingProvider(
            dataRoot: tempDataRoot(),
            loader: { _ in FakeCoreMLEmbedder() },
            availabilityProbe: { true }
        )

        _ = try await provider.embed(["hot"])
        try await provider.setMemoryMode(ManagedEmbeddingProvider.performanceMode)
        let snap = provider.snapshot()

        // performance <-> balanced don't change compute units: no reload tax.
        #expect(snap.coreMLLoaded == true)
        #expect(snap.loadCount == 1)
        #expect(snap.unloadCount == 0)
    }

    // MARK: REAL CoreML MiniLM end-to-end
    //
    // 2026-06-07 the user asked "test it make sure it's working, nothing has
    // been embedded on swift." Every other test in this file mocks
    // the embedder or fakes it. These four tests actually load the
    // bundled `minilm.mlpackage`, run `embed(...)` through CoreML +
    // ANE, and verify the produced vectors carry real semantic signal.
    // If any of these fail, the runtime is broken.
    //
    // Skipped (with a clear reason) if the bundled resource isn't
    // present in the test bundle — keeps CI green on builds that
    // intentionally exclude the model.

    @Test("RealMiniLM_loads_from_bundled_resource_when_available")
    func realMiniLM_loads_from_bundled_resource_when_available() async throws {
        guard CoreMLEmbeddingProvider.bundledResourcesAvailable() else {
            print("[real-minilm] SKIP: bundled minilm.mlpackage not present in test bundle")
            return
        }
        let provider = try CoreMLEmbeddingProvider.bundled()
        #expect(provider.dimensions == 384)
        #expect(provider.modelId == "all-MiniLM-L6-v2")
    }

    @Test("RealMiniLM_produces_384d_vector_for_arbitrary_input")
    func realMiniLM_produces_384d_vector_for_arbitrary_input() async throws {
        guard CoreMLEmbeddingProvider.bundledResourcesAvailable() else {
            print("[real-minilm] SKIP: bundled minilm.mlpackage not present in test bundle")
            return
        }
        let provider = try CoreMLEmbeddingProvider.bundled()
        let vecs = try await provider.embed(["hello world"])
        #expect(vecs.count == 1)
        #expect(vecs[0].count == 384)
        // Output is real floats — should NOT be all zeros (mock vector sign).
        let absSum = vecs[0].reduce(Float(0)) { $0 + abs($1) }
        #expect(absSum > 0.0)
    }

    /// A5.4: the .cpuOnly escape hatch must actually LOAD and RUN the real
    /// model, not just compile. Also pins parity — moving MiniLM off the ANE
    /// is a footprint decision, so it must not change the vector space.
    @Test("RealMiniLM_cpuOnly_low_memory_load_matches_default_vectors")
    func realMiniLM_cpuOnly_low_memory_load_matches_default_vectors() async throws {
        guard CoreMLEmbeddingProvider.bundledResourcesAvailable() else {
            print("[real-minilm] SKIP: bundled minilm.mlpackage not present in test bundle")
            return
        }
        let lowMemory = try CoreMLEmbeddingProvider.bundled(lowMemory: true)
        let vecs = try await lowMemory.embed(["hello world"])
        #expect(vecs.count == 1)
        #expect(vecs[0].count == 384)
        #expect(vecs[0].reduce(Float(0)) { $0 + abs($1) } > 0.0)

        let defaultUnits = try CoreMLEmbeddingProvider.bundled()
        let baseline = try await defaultUnits.embed(["hello world"])
        // Same vector space: cosine ~1 (CPU vs ANE differ only in float noise).
        let dot = zip(vecs[0], baseline[0]).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        #expect(dot > 0.99)
        #expect(lowMemory.embeddingEpoch == defaultUnits.embeddingEpoch)
    }

    @Test("RealMiniLM_different_texts_produce_distinct_vectors")
    func realMiniLM_different_texts_produce_distinct_vectors() async throws {
        guard CoreMLEmbeddingProvider.bundledResourcesAvailable() else {
            print("[real-minilm] SKIP: bundled minilm.mlpackage not present in test bundle")
            return
        }
        let provider = try CoreMLEmbeddingProvider.bundled()
        let vecs = try await provider.embed([
            "the cat sat on the mat",
            "quantum entanglement explains EPR pairs"
        ])
        #expect(vecs.count == 2)
        #expect(vecs[0] != vecs[1])
        // Cosine similarity between two unrelated sentences should be
        // moderate — not 1.0 (identical) and not -1.0 (orthogonal-opposite).
        let cos = cosineSimilarity(vecs[0], vecs[1])
        #expect(cos < 0.95)  // not identical
        #expect(cos > -0.95) // not antipodal
    }

    @Test("RealMiniLM_semantic_signal_similar_texts_score_higher")
    func realMiniLM_semantic_signal_similar_texts_score_higher() async throws {
        guard CoreMLEmbeddingProvider.bundledResourcesAvailable() else {
            print("[real-minilm] SKIP: bundled minilm.mlpackage not present in test bundle")
            return
        }
        let provider = try CoreMLEmbeddingProvider.bundled()
        let vecs = try await provider.embed([
            "the cat sat on the mat",        // [0] anchor
            "a feline rested on the carpet", // [1] semantically near
            "quantum entanglement explains EPR pairs" // [2] semantically far
        ])
        let near = cosineSimilarity(vecs[0], vecs[1])
        let far = cosineSimilarity(vecs[0], vecs[2])
        // The whole point of semantic embeddings: similar meaning → higher
        // cosine. If this fails, the model is producing noise or our
        // tokenization/pooling is wrong.
        #expect(near > far)
        print("[real-minilm] near=\(near) far=\(far) delta=\(near - far)")
    }

    @Test("RealMiniLM_tombstone_threshold_calibration")
    func realMiniLM_tombstone_threshold_calibration() async throws {
        // Wave1 T4 (for Agent): measure REAL MiniLM cosines for the paraphrase
        // vs contradiction cases so the 0.95 tombstone default is tuned on
        // data, not vibes. Canon requires: paraphrase ≥ threshold (blocks),
        // contradiction < threshold (admitted as new information).
        guard CoreMLEmbeddingProvider.bundledResourcesAvailable() else {
            print("[real-minilm] SKIP: bundled minilm.mlpackage not present in test bundle")
            return
        }
        let provider = try CoreMLEmbeddingProvider.bundled()
        let vecs = try await provider.embed([
            "the user likes tea",          // [0] tombstoned claim
            "the user enjoys tea",         // [1] paraphrase — must block
            "the user likes green tea",    // [2] narrower claim — Agent: new info?
            "the user hates tea",          // [3] contradiction — must walk in
        ])
        let paraphrase = cosineSimilarity(vecs[0], vecs[1])
        let narrower = cosineSimilarity(vecs[0], vecs[2])
        let contradiction = cosineSimilarity(vecs[0], vecs[3])
        print("[tombstone-calibration] paraphrase=\(paraphrase) narrower=\(narrower) contradiction=\(contradiction) threshold=\(memoryTombstoneMatchThreshold)")
        // The structural requirement (not exact values): a paraphrase must
        // score strictly higher than a contradiction, or no threshold exists.
        #expect(paraphrase > contradiction)
        // Pin the configured threshold against Agent's canon ON REAL VECTORS:
        // paraphrase blocks; contradiction and narrower claims walk in. If the
        // model or threshold drifts out of the measured gap, this screams.
        #expect(Double(paraphrase) >= memoryTombstoneMatchThreshold)
        #expect(Double(contradiction) < memoryTombstoneMatchThreshold)
        #expect(Double(narrower) < memoryTombstoneMatchThreshold)
    }

    /// Cosine similarity helper for the real-MiniLM tests.
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot()) * (nb.squareRoot())
        return denom == 0 ? 0 : dot / denom
    }

    // MARK: JSONLEmbeddingStore

    private func tempURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("embstore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.jsonl")
    }

    @Test("jsonlStore_upsert_then_get_roundtrips")
    func jsonlStore_upsert_then_get_roundtrips() async throws {
        let store = JSONLEmbeddingStore(path: tempURL())
        try await store.upsert(id: "a", embedding: [1, 0, 0], text: "hello")
        let got = try await store.get(id: "a")
        #expect(got?.text == "hello")
        #expect(got?.embedding == [1, 0, 0])
    }

    @Test("jsonlStore_upsert_overwrites_same_id")
    func jsonlStore_upsert_overwrites_same_id() async throws {
        let store = JSONLEmbeddingStore(path: tempURL())
        try await store.upsert(id: "a", embedding: [1, 0], text: "first")
        try await store.upsert(id: "a", embedding: [0, 1], text: "second")
        let got = try await store.get(id: "a")
        #expect(got?.text == "second")
        #expect(got?.embedding == [0, 1])
    }

    @Test("jsonlStore_delete_removes_record")
    func jsonlStore_delete_removes_record() async throws {
        let store = JSONLEmbeddingStore(path: tempURL())
        try await store.upsert(id: "a", embedding: [1], text: "x")
        try await store.delete(id: "a")
        let got = try await store.get(id: "a")
        #expect(got == nil)
    }

    @Test("jsonlStore_search_returns_topK_by_cosine_similarity")
    func jsonlStore_search_returns_topK_by_cosine_similarity() async throws {
        let store = JSONLEmbeddingStore(path: tempURL())
        try await store.upsert(id: "match", embedding: [1, 0, 0], text: "match")
        try await store.upsert(id: "orth", embedding: [0, 1, 0], text: "orth")
        try await store.upsert(id: "anti", embedding: [-1, 0, 0], text: "anti")
        let hits = try await store.search(query: [1, 0, 0], topK: 2)
        #expect(hits.count == 2)
        #expect(hits[0].id == "match")
        #expect(hits[0].score > hits[1].score)
    }

    @Test("jsonlStore_search_handles_empty_store")
    func jsonlStore_search_handles_empty_store() async throws {
        let store = JSONLEmbeddingStore(path: tempURL())
        let hits = try await store.search(query: [1, 0, 0], topK: 5)
        #expect(hits.isEmpty)
    }

    @Test("jsonlStore_persists_across_actor_instances")
    func jsonlStore_persists_across_actor_instances() async throws {
        let url = tempURL()
        let writer = JSONLEmbeddingStore(path: url)
        try await writer.upsert(id: "a", embedding: [1, 0, 0], text: "alpha")
        try await writer.upsert(id: "b", embedding: [0, 1, 0], text: "beta")

        let reader = JSONLEmbeddingStore(path: url)
        let a = try await reader.get(id: "a")
        let b = try await reader.get(id: "b")
        #expect(a?.text == "alpha")
        #expect(b?.text == "beta")
    }

    @Test("jsonlStore_search_throws_on_dimension_mismatch")
    func jsonlStore_search_throws_on_dimension_mismatch() async throws {
        let store = JSONLEmbeddingStore(path: tempURL())
        try await store.upsert(id: "a", embedding: [1, 0, 0], text: "three-d")
        await #expect(throws: EmbeddingError.self) {
            _ = try await store.search(query: [1, 0, 0, 0, 0], topK: 5)
        }
    }

    // gpt-5.5 round-3 finding (Wave 6): a single-actor concurrent-upsert
    // test proves nothing about the SHARED LOCK because actor isolation
    // alone already serializes within one instance. The contract we need
    // to pin is "two SEPARATE JSONLEmbeddingStore instances pointing at
    // the same file serialize through PathLockRegistry + flock so neither
    // flush race truncates the other's records." The two tests below cover
    // that contract at 2-instance and 4-instance scale, with an explicit
    // on-disk JSONL line-count check that catches a flush race that an
    // in-memory get() lookup would mask.
    //
    // The prior 20-op 2-instance test and 10-op single-actor test were
    // subsumed by these (single-actor case is trivially covered by actor
    // isolation; 20 ops is below the threshold where a broken lock would
    // reliably lose records).

    @Test("jsonlStore_two_instances_200_concurrent_upserts_all_lines_persisted")
    func jsonlStore_two_instances_200_concurrent_upserts_all_lines_persisted() async throws {
        // Two SEPARATE JSONLEmbeddingStore instances pointing at the same
        // file. With a broken cross-instance lock, the two actors would
        // each load a stale snapshot, mutate independently, and the loser
        // of the flush race would silently overwrite the winner's records
        // with a smaller buffer — on-disk line count would drop below 200.
        let url = tempURL()
        let storeA = JSONLEmbeddingStore(path: url)
        let storeB = JSONLEmbeddingStore(path: url)
        let perInstance = 100

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<perInstance {
                    try? await storeA.upsert(id: "A-\(i)", embedding: [Float(i)], text: "a-\(i)")
                }
            }
            group.addTask {
                for i in 0..<perInstance {
                    try? await storeB.upsert(id: "B-\(i)", embedding: [Float(i)], text: "b-\(i)")
                }
            }
        }

        // (a) every record present via the store API (force-reread under lock).
        let reader = JSONLEmbeddingStore(path: url)
        let all = try await reader.allRecords()
        #expect(all.count == 2 * perInstance,
                "store.allRecords() returned \(all.count), expected \(2 * perInstance) — cross-instance lock failed")

        // (c) every id appears EXACTLY once (no duplicates, no missing).
        var seenA = Set<Int>(), seenB = Set<Int>()
        for rec in all {
            if rec.id.hasPrefix("A-"), let i = Int(rec.id.dropFirst(2)) { seenA.insert(i) }
            else if rec.id.hasPrefix("B-"), let i = Int(rec.id.dropFirst(2)) { seenB.insert(i) }
        }
        #expect(seenA.count == perInstance, "missing A ids: have \(seenA.count) of \(perInstance)")
        #expect(seenB.count == perInstance, "missing B ids: have \(seenB.count) of \(perInstance)")
        for i in 0..<perInstance {
            #expect(seenA.contains(i), "missing A-\(i)")
            #expect(seenB.contains(i), "missing B-\(i)")
        }

        // (b) on-disk JSONL line count == 200 — proves no flush race
        // overwrote partial state. With a broken lock, the last writer's
        // flush would write a snapshot missing the other writer's records.
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lineCount = raw.split(separator: "\n").filter { !$0.isEmpty }.count
        #expect(lineCount == 2 * perInstance,
                "on-disk JSONL line count \(lineCount) != \(2 * perInstance) — concurrent flushes lost lines")
    }

    @Test("jsonlStore_four_instances_500_concurrent_upserts_all_lines_persisted")
    func jsonlStore_four_instances_500_concurrent_upserts_all_lines_persisted() async throws {
        // Scaling proof: 4 separate instances, 125 ops each, disjoint id
        // ranges. If the lock only happens to work for 2 contenders but
        // breaks under broader contention, this surfaces it.
        let url = tempURL()
        let stores = (0..<4).map { _ in JSONLEmbeddingStore(path: url) }
        let perInstance = 125
        let instanceCount = stores.count
        let total = perInstance * instanceCount

        await withTaskGroup(of: Void.self) { group in
            for (idx, store) in stores.enumerated() {
                group.addTask {
                    let prefix = ["A", "B", "C", "D"][idx]
                    for i in 0..<perInstance {
                        try? await store.upsert(id: "\(prefix)-\(i)", embedding: [Float(i)], text: "\(prefix.lowercased())-\(i)")
                    }
                }
            }
        }

        // (a) every record present via the store API.
        let reader = JSONLEmbeddingStore(path: url)
        let all = try await reader.allRecords()
        #expect(all.count == total,
                "store.allRecords() returned \(all.count), expected \(total) — 4-way lock contention dropped records")

        // (c) every id appears EXACTLY once.
        let prefixes = ["A", "B", "C", "D"]
        var seen: [String: Set<Int>] = [:]
        for p in prefixes { seen[p] = [] }
        for rec in all {
            guard let dash = rec.id.firstIndex(of: "-") else { continue }
            let p = String(rec.id[..<dash])
            let suffix = rec.id[rec.id.index(after: dash)...]
            if let i = Int(suffix) { seen[p]?.insert(i) }
        }
        for p in prefixes {
            let s = seen[p] ?? []
            #expect(s.count == perInstance, "prefix \(p): have \(s.count) of \(perInstance)")
            for i in 0..<perInstance {
                #expect(s.contains(i), "missing \(p)-\(i)")
            }
        }

        // (b) on-disk JSONL line count == total.
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lineCount = raw.split(separator: "\n").filter { !$0.isEmpty }.count
        #expect(lineCount == total,
                "on-disk JSONL line count \(lineCount) != \(total) — 4-way concurrent flushes lost lines")
    }

    // MARK: SwiftNativeMemoryRecaller

    @Test("swiftNativeMemoryRecaller_recall_returns_hits_sorted_by_score")
    func swiftNativeMemoryRecaller_recall_returns_hits_sorted_by_score() async throws {
        let recaller = SwiftNativeMemoryRecaller(
            embedder: MockEmbeddingProvider(),
            store: JSONLEmbeddingStore(path: tempURL())
        )
        try await recaller.index(id: "1", text: "alpha")
        try await recaller.index(id: "2", text: "beta")
        try await recaller.index(id: "3", text: "gamma")
        let hits = try await recaller.recall("alpha", k: 3)
        #expect(hits.count == 3)
        // Deterministic mock: same text → same vector, so "alpha" query matches "alpha" record at score ~1.
        #expect(hits[0].preview == "alpha")
        #expect(hits[0].score >= hits[1].score)
        #expect(hits[1].score >= hits[2].score)
        #expect(hits[0].source == "swift-native")
    }

    @Test("swiftNativeMemoryRecaller_index_then_recall_finds_it")
    func swiftNativeMemoryRecaller_index_then_recall_finds_it() async throws {
        let recaller = SwiftNativeMemoryRecaller(
            embedder: MockEmbeddingProvider(),
            store: JSONLEmbeddingStore(path: tempURL())
        )
        try await recaller.index(id: "x", text: "needle in a haystack")
        let hits = try await recaller.recall("needle in a haystack", k: 5)
        #expect(!hits.isEmpty)
        #expect(hits.first?.preview == "needle in a haystack")
    }

    @Test("swiftNativeMemoryRecaller_remove_then_recall_does_not_find_it")
    func swiftNativeMemoryRecaller_remove_then_recall_does_not_find_it() async throws {
        let recaller = SwiftNativeMemoryRecaller(
            embedder: MockEmbeddingProvider(),
            store: JSONLEmbeddingStore(path: tempURL())
        )
        try await recaller.index(id: "x", text: "ephemeral")
        try await recaller.remove(id: "x")
        let hits = try await recaller.recall("ephemeral", k: 5)
        #expect(hits.isEmpty)
    }

    @Test("swiftNativeMemoryRecaller_uses_mock_embedder_in_tests")
    func swiftNativeMemoryRecaller_uses_mock_embedder_in_tests() async throws {
        let embedder = MockEmbeddingProvider()
        #expect(embedder.modelId == "mock")
        let recaller = SwiftNativeMemoryRecaller(
            embedder: embedder,
            store: JSONLEmbeddingStore(path: tempURL())
        )
        try await recaller.index(id: "a", text: "test")
        let hits = try await recaller.recall("test", k: 1)
        #expect(hits.first?.source == "swift-native")
    }

    // MARK: - gpt-5.5 round-3 strengthening: prove blocking + ordering for
    // memory_embeddings.jsonl across processes, and serialization between
    // two in-process Swift writers.
    //
    // The existing `jsonlStore_concurrent_upserts_across_instances_no_lost_updates`
    // proves no-loss when 20 actors race within ONE process; it does not
    // prove the cross-process flock fires, nor that two writers actually
    // serialize (a non-blocking last-writer-wins impl could still happen
    // to win the race in every iteration if the records don't share keys).
    // These two tests pin the contract.

    @Test("jsonlStore_upsert_blocks_until_foreign_helper_releases_flock")
    func jsonlStore_upsert_blocks_until_foreign_helper_releases_flock() async throws {
        let storeURL = tempURL()  // <dir>/store.jsonl
        let storeDir = storeURL.deletingLastPathComponent()
        let acquiredMarker = storeDir.appendingPathComponent("helper_acquired.txt")
        let releasedMarker = storeDir.appendingPathComponent("helper_released.txt")
        let releaseRequest = storeDir.appendingPathComponent("helper_release_request.txt")
        let swiftStartedMarker = storeDir.appendingPathComponent("swift_started.txt")
        let swiftFinishedMarker = storeDir.appendingPathComponent("swift_finished.txt")

        let helper = try NativeAgentFlockChild.hold(
            lockPath: storeURL.path + ".lock",
            acquiredMarker: acquiredMarker,
            releasedMarker: releasedMarker,
            releaseRequest: releaseRequest
        )
        defer {
            try? Data("release".utf8).write(to: releaseRequest)
            helper.terminate()
        }

        // Wait for the helper to actually hold the lock — poll the marker
        // file rather than guessing with a flat sleep. On failure, reap the
        // helper and bail with its stderr instead of limping into the
        // ordering assertions.
        if !NativeAgentFlockChild.waitForFile(acquiredMarker, timeout: 10.0) {
            _ = helper.wait(timeout: 0)
            Issue.record("flock helper failed to acquire <store.jsonl>.lock within 10s")
            return
        }

        // Start the Swift upsert while the helper is still holding the
        // flock, then explicitly release the helper. This avoids measuring a
        // fixed sleep window that full-suite scheduler load can eat.
        let store = JSONLEmbeddingStore(path: storeURL)
        let swiftTask = Task {
            try Data("started".utf8).write(to: swiftStartedMarker)
            try await store.upsert(id: "blocked", embedding: [1, 0, 0], text: "post-release")
            try Data("finished".utf8).write(to: swiftFinishedMarker)
        }
        let swiftStartDeadline = Date().addingTimeInterval(3.0)
        while !FileManager.default.fileExists(atPath: swiftStartedMarker.path) {
            if Date() > swiftStartDeadline { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: swiftStartedMarker.path),
                "Swift upsert task failed to start within deadline")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!FileManager.default.fileExists(atPath: swiftFinishedMarker.path),
                "Swift upsert finished before the foreign flock was released")

        try Data("release".utf8).write(to: releaseRequest)

        // Bounded await on the upsert: JSONLEmbeddingStore's flock wait is a
        // cancellable poll loop (PersistenceCore+FileLock), so if the helper
        // wedges while holding the lock, cancelling the task unblocks it.
        // Cancel-only — killing by raw pid from the watchdog risks hitting a
        // reused pid if the helper already exited; the catch path below
        // terminates the helper through the Process object instead.
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            swiftTask.cancel()
        }
        do {
            try await swiftTask.value
            watchdog.cancel()
        } catch {
            watchdog.cancel()
            helper.terminate()
            Issue.record("Swift upsert did not complete within 60s of the release request — helper likely wedged holding the flock (error: \(error))")
            return
        }

        let helperStatus = helper.wait(timeout: 60)
        if helperStatus == nil {
            helper.terminate()
            Issue.record("flock helper did not exit within 60s of releasing — killed")
            return
        }
        #expect(helperStatus == 0,
                "flock helper failed: status \(String(describing: helperStatus))")

        let releasedRaw = try String(contentsOf: releasedMarker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let helperReleased = try #require(TimeInterval(releasedRaw))
        let swiftFinishedAt = try FileManager.default
            .attributesOfItem(atPath: swiftFinishedMarker.path)[.modificationDate] as? Date
        let swiftEndUnix = try #require(swiftFinishedAt?.timeIntervalSince1970)
        #expect(swiftEndUnix >= helperReleased,
                "Swift upsert finished at \(swiftEndUnix) before helper released at \(helperReleased) — flock ordering violated")

        // Sanity: the record landed.
        let got = try await store.get(id: "blocked")
        #expect(got?.text == "post-release")
    }

    // DELETED (2026-05-31, gpt-5.5 round-3 finding LOW/MEDIUM):
    // `jsonlStore_inprocess_writers_serialize_with_ordering` fired 50 ops
    // across two tasks on ONE actor instance. Actor isolation alone
    // serializes calls to the same actor — that test passed without ever
    // exercising the cross-instance PathLockRegistry+flock path. The new
    // `jsonlStore_two_instances_200_concurrent_upserts_all_lines_persisted`
    // (200 ops across two SEPARATE actor instances on the same file, same
    // line-count assertion) subsumes it and actually exercises the shared
    // lock. The 4-instance/500-op test extends the proof to broader
    // contention.
}
