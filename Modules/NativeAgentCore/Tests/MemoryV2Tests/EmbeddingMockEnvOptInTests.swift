import Foundation
import Testing
@testable import MemoryV2

/// Eval for ledger surface `env.NATIVE_AGENT_EMBEDDING_MOCK`
/// (docs/evals/ledger.json, fence core.memory).
///
/// Silent-failure class: silent substitution. Set in a shell that launches the
/// app, this env var turns real MiniLM vectors into deterministic synthetic ones
/// for the whole session. Existing coverage was one UI-copy test asserting a
/// honesty string MENTIONS the variable; nothing asserted its RUNTIME behavior.
///
/// Envelope asserted:
///  1. when the var is what forced the fallback, `snapshot().effectiveBackend`
///     reports `mock` — the opt-in can never be laundered into a CoreML-looking
///     status line;
///  2. with the var absent and CoreML unusable, the same runtime reports
///     `fail-closed` (NOT mock, NOT coreml) and `embed()` throws — so a broken
///     install is never silently mocked;
///  3. vectors produced under the opt-in carry the MOCK EPOCH, distinct from
///     the epoch a CoreML-backed provider would stamp. That is what keeps the
///     substitution recoverable in the store: `memory.sqlite` rows written
///     under the opt-in are epoch-labelled and cannot be scored against a real
///     MiniLM corpus.
///
/// The env var is process-global state, so the suite is `.serialized` and every
/// mutation window is opened and closed inside one test (repo convention — see
/// WorkshopLifecycleBoundsTests / ApprovalInboxTests). Both CoreML doors are
/// injected (`loader` throws, `availabilityProbe` returns false), so no test
/// here touches the real model bundle.
@Suite("Embedding mock env opt-in", .serialized)
struct EmbeddingMockEnvOptInTests {

    private static let key = "NATIVE_AGENT_EMBEDDING_MOCK"

    private struct UnavailableCoreML: Error {}

    private func makeTempRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memv2-mockenv-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A runtime whose CoreML side is definitively unusable: the resource probe
    /// says the bundle is absent and the loader throws. Whatever it reports is
    /// therefore attributable to the env var alone.
    private func runtimeWithoutCoreML(dataRoot: URL) -> ManagedEmbeddingProvider {
        ManagedEmbeddingProvider(
            dataRoot: dataRoot,
            dimensions: 8,
            loader: { _ in throw UnavailableCoreML() },
            availabilityProbe: { false }
        )
    }

    private func withEnvOptIn<T>(_ body: () throws -> T) rethrows -> T {
        setenv(Self.key, "1", 1)
        defer { unsetenv(Self.key) }
        return try body()
    }

    private func withEnvOptIn<T>(_ body: () async throws -> T) async rethrows -> T {
        setenv(Self.key, "1", 1)
        defer { unsetenv(Self.key) }
        return try await body()
    }

    @Test("the opt-in is reported as mock, never as CoreML")
    func optInReportsMockBackend() async throws {
        let root = try makeTempRoot("optin")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = runtimeWithoutCoreML(dataRoot: root)

        // Force a load attempt so the runtime is in its terminal state.
        try await withEnvOptIn {
            _ = try await runtime.embed(["prime the load-failure state"])
        }

        let optIn = withEnvOptIn { runtime.snapshot() }
        #expect(optIn.effectiveBackend == ManagedEmbeddingProvider.mockBackend,
                "the env opt-in was laundered into '\(optIn.effectiveBackend)'")
        #expect(optIn.effectiveBackend != ManagedEmbeddingProvider.coreMLBackend)
        #expect(optIn.requestedBackend == ManagedEmbeddingProvider.coreMLBackend,
                "the REQUESTED backend must stay coreml — the opt-in is a fallback, not a config change")
        #expect(optIn.coreMLLoaded == false)
        #expect(optIn.coreMLResourcesAvailable == false)
        #expect(optIn.lastLoadError != nil,
                "a mock-serving runtime must still carry the load error that made it fall back")
    }

    @Test("without the opt-in the same runtime is fail-closed, not mock")
    func withoutOptInRuntimeFailsClosed() async throws {
        let root = try makeTempRoot("nooptin")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = runtimeWithoutCoreML(dataRoot: root)

        unsetenv(Self.key)
        await #expect(throws: (any Error).self) {
            _ = try await runtime.embed(["a real recall query"])
        }
        let snapshot = runtime.snapshot()
        #expect(snapshot.effectiveBackend == ManagedEmbeddingProvider.failClosedBackend,
                "a broken CoreML install with no opt-in reported '\(snapshot.effectiveBackend)'")
        #expect(snapshot.effectiveBackend != ManagedEmbeddingProvider.mockBackend)
        #expect(snapshot.effectiveBackend != ManagedEmbeddingProvider.coreMLBackend)
    }

    @Test("vectors served under the opt-in carry the mock epoch, not a MiniLM one")
    func optInVectorsAreEpochLabelled() async throws {
        let root = try makeTempRoot("epoch")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = runtimeWithoutCoreML(dataRoot: root)

        let batch = try await withEnvOptIn {
            try await runtime.embedWithEpoch(["a fact written while the opt-in was set"])
        }
        #expect(batch.vectors.count == 1)
        #expect(batch.vectors[0].count == 8)

        // The epoch is the mock provider's own — so a row persisted while the
        // var was set is distinguishable from a real-MiniLM row forever after,
        // and epoch-gated recall refuses to mix them.
        let mockEpoch = MockEmbeddingProvider(dimensions: 8).embeddingEpoch
        #expect(batch.epoch == mockEpoch,
                "opt-in vectors were stamped with an epoch that is not the mock's")
        #expect(batch.epoch != FailClosedEmbeddingProvider(dimensions: 8).embeddingEpoch)

        // Proof the label survives the write: a row persisted while the opt-in
        // was set carries the mock epoch in memory.sqlite, so a later audit can
        // tell an opt-in vector from a real MiniLM one. (Whether recall REFUSES
        // to mix spaces is the store's epoch gate, covered by
        // MemoryEmbeddingEpochAndDisclosureTests; what belongs to this surface
        // is that the label is written at all.)
        let storeRoot = try makeTempRoot("epoch-store")
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let storage = try MemoryStorage(dataRoot: storeRoot)
        _ = try await storage.insertMemory(StoredMemory(
            id: "written-under-opt-in",
            content: "a fact written while the opt-in was set",
            embedding: batch.vectors[0],
            embeddingEpoch: batch.epoch.rawValue
        ))
        let persisted = try #require(try await storage.memory(id: "written-under-opt-in"))
        #expect(persisted.embeddingEpoch == mockEpoch.rawValue,
                "the opt-in vector landed in the store without its mock epoch label")
    }

    /// The gate is an exact `== "1"` comparison in every reader. A looser gate
    /// (any non-empty value) would let an unrelated `NATIVE_AGENT_EMBEDDING_MOCK=0`
    /// or `=true` in a launch shell silently swap the whole session's vectors —
    /// the widest version of this surface's silent-substitution mode.
    @Test("only the exact value 1 enables the fallback")
    func onlyTheExactValueOneOptsIn() async throws {
        let root = try makeTempRoot("exactvalue")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = runtimeWithoutCoreML(dataRoot: root)

        // The exact string "1" is the contract — any other value must NOT
        // enable the fallback.
        setenv(Self.key, "true", 1)
        let notOptedIn = runtime.snapshot().effectiveBackend
        unsetenv(Self.key)
        #expect(notOptedIn == ManagedEmbeddingProvider.failClosedBackend,
                "a non-'1' value enabled the mock fallback — the opt-in is looser than documented")

        let optedIn = withEnvOptIn { runtime.snapshot().effectiveBackend }
        #expect(optedIn == ManagedEmbeddingProvider.mockBackend)
    }
}
