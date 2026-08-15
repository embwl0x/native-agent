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

}
