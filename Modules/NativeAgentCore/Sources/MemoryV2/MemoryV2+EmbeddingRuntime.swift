import Foundation
import NativeAgentCore
import PersistenceCore

public struct EmbeddingRuntimeSnapshot: Sendable, Equatable {
    public var requestedBackend: String
    public var effectiveBackend: String
    public var mode: String
    public var modelId: String
    public var dimensions: Int
    /// Exact vector-space identity when this snapshot describes a backend that
    /// can serve an embedding immediately. Keeping it on the same snapshot
    /// prevents turn preparation from rereading embedding configuration merely
    /// to bind a query vector to its epoch.
    public var embeddingEpoch: String?
    public var coreMLResourcesAvailable: Bool
    public var coreMLLoaded: Bool
    public var modelLoadable: Bool
    public var lastUsedAt: String?
    public var lastLoadedAt: String?
    public var lastUnloadedAt: String?
    public var unloadReason: String?
    public var lastLoadError: String?
    public var loadCount: Int
    public var unloadCount: Int
    public var idleUnloadSeconds: Int?
}

public final class ManagedEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public static let coreMLBackend = "coreml-minilm"
    public static let mockBackend = "mock"
    /// Reported by `snapshot()` when the user wanted CoreML, CoreML couldn't
    /// load, AND the `NATIVE_AGENT_EMBEDDING_MOCK` developer-test env var is
    /// NOT set — so `embed()` will throw on every call. Distinct from
    /// `mockBackend`, which is the explicit user opt-in.
    public static let failClosedBackend = "fail-closed"
    public static let performanceMode = "performance"

    private struct State {
        var coreMLProvider: (any EmbeddingProvider)?
        var lastUsedAt: Date?
        var lastLoadedAt: Date?
        var lastUnloadedAt: Date?
        var unloadReason: String?
        var lastLoadError: String?
        var loadCount: Int = 0
        var unloadCount: Int = 0
        /// Activity and idle scheduling must not invalidate a cold load.
        var loadGeneration: UInt64 = 0
    }

    private let dataRoot: URL
    private let mock: MockEmbeddingProvider
    private let lock = NSLock()
    private let loadLock = NSLock()
    private var state = State()

    public init(dataRoot: URL, dimensions: Int = 384) {
        self.dataRoot = dataRoot
        self.mock = MockEmbeddingProvider(dimensions: dimensions)
    }

    /// The id of the CoreML model that would load: the installed extras model
    /// when present, else the bundled one.
    private var resolvedModelID: String {
        (try? CoreMLEmbeddingProvider.installedExtrasModel(root: dataRoot))?.modelID
            ?? CoreMLEmbeddingProvider.bundledModelID
    }

    public var dimensions: Int {
        guard Self.readBackend(dataRoot: dataRoot) != Self.mockBackend else { return mock.dimensions }
        if let loaded = lock.withLock({ state.coreMLProvider?.dimensions }) { return loaded }
        // Not resident yet: report the model that WOULD load, not the mock's
        // width, so status surfaces do not read "384d" beside a 1024-d model.
        return resolvedModelDimensions
    }

    private var resolvedModelDimensions: Int {
        if let installed = try? CoreMLEmbeddingProvider.installedExtrasModel(root: dataRoot) {
            return installed.dimensions
        }
        return 384
    }

    public var modelId: String {
        let config = Self.readBackend(dataRoot: dataRoot)
        guard config != Self.mockBackend else { return mock.modelId }
        return lock.withLock { state.coreMLProvider?.modelId ?? resolvedModelID }
    }

    public var embeddingEpoch: MemoryEmbeddingEpoch {
        let config = Self.readBackend(dataRoot: dataRoot)
        if config == Self.mockBackend { return mock.embeddingEpoch }
        if let loaded = lock.withLock({ state.coreMLProvider }) {
            return loaded.embeddingEpoch
        }
        if ProcessInfo.processInfo.environment["NATIVE_AGENT_EMBEDDING_MOCK"] == "1",
           !CoreMLEmbeddingProvider.bundledResourcesAvailable(extrasRoot: dataRoot) {
            return mock.embeddingEpoch
        }
        return (try? CoreMLEmbeddingProvider.bundledEmbeddingEpoch(extrasRoot: dataRoot))
            ?? FailClosedEmbeddingProvider(dimensions: mock.dimensions).embeddingEpoch
    }

    /// Embed `texts` via the CoreML MiniLM backend.
    ///
    /// FAIL-CLOSED CONTRACT: when CoreML is unavailable (resources missing,
    /// model load throws, runtime mismatch) we THROW. Earlier versions of
    /// this method silently fell back to `MockEmbeddingProvider`, which
    /// returns random vectors. Memory recall and proposal-deduplication
    /// scoring then run against noise instead of failing visibly, so the
    /// system looked "up" while quietly producing garbage retrieval results.
    /// the user's KG / GROWTH-eviction pipeline depends on these vectors carrying
    /// real semantic signal — a silent mock fallback is worse than an error.
    ///
    /// The mock backend is still reachable for two well-defined cases:
    ///   1. The user explicitly disabled embeddings via the config file
    ///      (`config/embeddings.json` → `backend: "mock"`). That's an opt-in
    ///      choice, not a hidden fallback.
    ///   2. The developer test env var `NATIVE_AGENT_EMBEDDING_MOCK=1` is set.
    ///      Used by unit tests and synthetic harness runs. Never set in
    ///      production.
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        try await embedWithEpoch(texts).vectors
    }

    /// Residency is independent of whether semantic search is selected.
    public func warmUp() async throws {
        if lock.withLock({ state.coreMLProvider != nil }) { return }
        let provider = try loadCoreMLProvider(config: Self.readBackend(dataRoot: dataRoot))
        _ = try await provider.embed(["warmup"])
    }

    /// Phase 5 D: embed ONLY on the model already resident — never load it,
    /// never take `loadLock`. Nil when cold, mismatched or mock; the caller
    /// falls back to what it can do without vectors.
    public func embedIfResident(_ texts: [String]) async -> [[Float]]? {
        let config = Self.readBackend(dataRoot: dataRoot)
        guard config != Self.mockBackend, !texts.isEmpty else { return nil }
        guard let provider = lock.withLock({ state.coreMLProvider }) else { return nil }
        noteUse()
        return try? await provider.embed(texts)
    }

    public func embedWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch {
        let config = Self.readBackend(dataRoot: dataRoot)
        guard config != Self.mockBackend else {
            return try await mock.embedWithEpoch(texts)
        }

        // Split load from predict: recordLoadFailure unloads the provider
        // and stamps lastLoadError (status panel reports the install as
        // broken, next embed pays the full reload). That treatment is right
        // for LOAD failures only — a cancelled or transient PREDICTION
        // failure was evicting a healthy model and lying about the install
        // (audit 2026-06-09).
        let provider: any EmbeddingProvider
        do {
            provider = try loadCoreMLProvider(config: config)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if ProcessInfo.processInfo.environment["NATIVE_AGENT_EMBEDDING_MOCK"] == "1" {
                return try await mock.embedWithEpoch(texts)
            }
            throw NSError(
                domain: "NativeAgentMemoryV2",
                code: -100,
                userInfo: [NSLocalizedDescriptionKey:
                    "CoreML embedding model \(resolvedModelID) did not load: "
                    + "\(error.localizedDescription)"]
            )
        }
        noteUse()
        // Prediction failures and cancellation retain the resident model.
        return try await provider.embedWithEpoch(texts)
    }

    public func snapshot() -> EmbeddingRuntimeSnapshot {
        let config = Self.readBackend(dataRoot: dataRoot)
        let mockEnvOptIn = ProcessInfo.processInfo.environment["NATIVE_AGENT_EMBEDDING_MOCK"] == "1"
        // A broken installed model is named before the first embed() tries it,
        // so status never shows a plain "missing" for a model that is there
        // but unusable.
        let installedModel: CoreMLEmbeddingProvider.InstalledExtrasModel?
        let installedModelProblem: String?
        let resourcesAvailable: Bool
        do {
            installedModel = try CoreMLEmbeddingProvider.installedExtrasModel(root: dataRoot)
            installedModelProblem = nil
            resourcesAvailable = installedModel != nil || CoreMLEmbeddingProvider.bundledFloorResourcesAvailable()
        } catch {
            installedModel = nil
            installedModelProblem = config == Self.mockBackend ? nil : error.localizedDescription
            resourcesAvailable = false
        }
        return lock.withLock {
            let loadedProvider = state.coreMLProvider
            let requestedCoreML = config != Self.mockBackend
            let loaded = loadedProvider != nil
            let effectiveBackend: String
            if !requestedCoreML {
                // User explicitly opted out via config — honest mock.
                effectiveBackend = Self.mockBackend
            } else if loaded {
                // Provider is hot in memory — real CoreML.
                effectiveBackend = Self.coreMLBackend
            } else if state.lastLoadError == nil && resourcesAvailable {
                // Never attempted load yet AND model bundle is on disk:
                // first embed() call is expected to succeed.
                effectiveBackend = Self.coreMLBackend
            } else if mockEnvOptIn {
                // CoreML unusable AND developer test env var set: embed() will
                // return deterministic mock vectors. Report mock honestly.
                effectiveBackend = Self.mockBackend
            } else {
                // gpt-5.5 review MEDIUM: report fail-closed even BEFORE the
                // first embed() call when CoreML resources aren't on disk.
                // Previously this branch returned `coreMLBackend` whenever
                // `lastLoadError == nil`, hiding a broken install behind a
                // green status panel until the first recall actually fired.
                effectiveBackend = Self.failClosedBackend
            }
            let modelId: String = {
                if !requestedCoreML { return mock.modelId }
                if let loadedProvider { return loadedProvider.modelId }
                return resourcesAvailable
                    ? installedModel?.modelID ?? CoreMLEmbeddingProvider.bundledModelID
                    : mock.modelId
            }()
            return EmbeddingRuntimeSnapshot(
                requestedBackend: config,
                effectiveBackend: effectiveBackend,
                mode: Self.performanceMode,
                modelId: modelId,
                dimensions: effectiveBackend == Self.mockBackend
                    ? mock.dimensions : loadedProvider?.dimensions ?? installedModel?.dimensions ?? 384,
                embeddingEpoch: loadedProvider?.embeddingEpoch.rawValue
                    ?? (effectiveBackend == Self.mockBackend
                        ? mock.embeddingEpoch.rawValue
                        : nil),
                coreMLResourcesAvailable: resourcesAvailable,
                coreMLLoaded: loaded,
                modelLoadable: resourcesAvailable && state.lastLoadError == nil,
                lastUsedAt: Self.isoString(state.lastUsedAt),
                lastLoadedAt: Self.isoString(state.lastLoadedAt),
                lastUnloadedAt: Self.isoString(state.lastUnloadedAt),
                unloadReason: state.unloadReason,
                lastLoadError: state.lastLoadError ?? installedModelProblem,
                loadCount: state.loadCount,
                unloadCount: state.unloadCount,
                idleUnloadSeconds: nil
            )
        }
    }

    public func setBackend(enabled: Bool) async throws {
        let previous = Self.readBackend(dataRoot: dataRoot)
        try await writeConfigValue(
            path: Self.backendPath(dataRoot: dataRoot),
            key: "backend",
            value: enabled ? Self.coreMLBackend : Self.mockBackend
        )
        if previous != (enabled ? Self.coreMLBackend : Self.mockBackend) {
            lock.withLock { state.loadGeneration &+= 1 }
        }
    }

    @discardableResult
    public func release(reason: String = "manual release") -> EmbeddingRuntimeSnapshot {
        lock.withLock {
            if state.coreMLProvider != nil {
                state.unloadCount += 1
            }
            state.coreMLProvider = nil
            state.lastUnloadedAt = Date()
            state.unloadReason = reason
            state.loadGeneration &+= 1
        }
        return snapshot()
    }

    private func loadCoreMLProvider(config: String) throws -> any EmbeddingProvider {
        // Cold requests must share the resident model instead of compiling and
        // allocating a full model each before choosing a winner. Keep status
        // and release independent of the expensive synchronous loader.
        loadLock.lock()
        defer { loadLock.unlock() }
        let (existing, generation) = try lock.withLock {
            guard Self.readBackend(dataRoot: dataRoot) == config else { throw CancellationError() }
            return (state.coreMLProvider, state.loadGeneration)
        }
        if let existing { return existing }
        let modelID = resolvedModelID
        let provider: any EmbeddingProvider
        do {
            provider = try CoreMLEmbeddingProvider.bundled(extrasRoot: dataRoot)
        } catch {
            // Record failure before admitting another load, so an older
            // failure cannot evict a newer successful model.
            recordLoadFailure(error, generation: generation)
            throw error
        }
        return try lock.withLock {
            guard state.loadGeneration == generation,
                  Self.readBackend(dataRoot: dataRoot) == config,
                  resolvedModelID == modelID else { throw CancellationError() }
            state.coreMLProvider = provider
            state.lastLoadedAt = Date()
            state.unloadReason = nil
            state.lastLoadError = nil
            state.loadCount += 1
            return provider
        }
    }

    private func noteUse() {
        lock.withLock {
            state.lastUsedAt = Date()
        }
    }

    private func recordLoadFailure(_ error: Error, generation: UInt64) {
        // gpt-5.5 review-2 NEEDS_FIX: post-fail-closed wording. Previously
        // this said "using mock fallback" — that was honest when embed()
        // silently mocked on load failure. Now embed() throws unless the
        // developer-test env var opts in, so the load-failure terminal
        // state is fail-closed (or mock-if-opt-in). Reason mirrors the
        // snapshot() branch logic so UI panels and the unload reason agree.
        let mockOptIn = ProcessInfo.processInfo.environment["NATIVE_AGENT_EMBEDDING_MOCK"] == "1"
        lock.withLock {
            guard state.loadGeneration == generation else { return }
            state.lastLoadError = String(describing: error)
            state.coreMLProvider = nil
            state.lastUnloadedAt = Date()
            state.unloadReason = mockOptIn
                ? "load failed; mock embedder active via NATIVE_AGENT_EMBEDDING_MOCK"
                : "load failed; fail-closed (embed() will throw)"
        }
    }

    private func writeConfigValue(path: URL, key: String, value: String) async throws {
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            try await persistence.writeJSON(.object([key: .string(value)]), to: path)
        }
    }

    private static func readBackend(dataRoot: URL) -> String {
        normalizeBackend(readStringValue(from: backendPath(dataRoot: dataRoot), key: "backend"))
    }

    private static func normalizeBackend(_ backend: String?) -> String {
        switch backend?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case mockBackend:
            return mockBackend
        default:
            return coreMLBackend
        }
    }

    private static func readStringValue(from path: URL, key: String) -> String? {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj[key] as? String
    }

    private static func backendPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("embeddings.json")
    }

    private static func isoString(_ date: Date?) -> String? {
        guard let date else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }
}

private extension NSLock {
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}

extension SwiftNativeMemoryV2 {
    public func warmUpEmbeddingsAtLaunch() async {
        guard let snapshot = embeddingRuntimeSnapshot() else {
            nativeLog("[embedding-warmup] SKIP: embeddingRuntimeSnapshot() returned nil — memoryV2 actor not initialized yet?")
            OrganPulse.record("embedding_warmup", .skipped, note: "memory store not attached")
            return
        }
        nativeLog("[embedding-warmup] snapshot: mode=\(snapshot.mode) backend=requested:\(snapshot.requestedBackend)/effective:\(snapshot.effectiveBackend) coreMLLoaded=\(snapshot.coreMLLoaded) modelLoadable=\(snapshot.modelLoadable) resourcesAvailable=\(snapshot.coreMLResourcesAvailable) modelId=\(snapshot.modelId)")
        if snapshot.coreMLLoaded {
            nativeLog("[embedding-warmup] SKIP: already loaded by another path")
            OrganPulse.record("embedding_warmup", .nothing, note: "already loaded")
            return
        }
        // Intentionally NOT gating on modelLoadable. If resources aren't on
        // disk we'll catch the failure below; better to ATTEMPT and surface
        // a real error than to defer to a probe that was wrong about my
        // staging path the first time.
        nativeLog("[embedding-warmup] attempting load — modelLoadable=\(snapshot.modelLoadable)")
        do {
            try await warmUpEmbedder()
            nativeLog("[embedding-warmup] SUCCESS: MiniLM eagerly warmed for Fast mode")
            OrganPulse.record("embedding_warmup", .worked, note: "embedder loaded")
            let after = embeddingRuntimeSnapshot()
            nativeLog("[embedding-warmup] post-load snapshot: coreMLLoaded=\(after?.coreMLLoaded ?? false) effectiveBackend=\(after?.effectiveBackend ?? "nil")")
        } catch {
            nativeLog("[embedding-warmup] FAILED: \(error.localizedDescription)")
        }
    }

    public static func configureEmbeddingBackendAndReindex(enabled: Bool, dataRoot: URL) async throws -> (report: MemoryEmbeddingEpochActivationReport, runtime: EmbeddingRuntimeSnapshot) {
        let memory = resolvedOwner(dataRoot: dataRoot)
        let before = await memory.embeddingRuntimeSnapshot()
        do {
            try await memory.configureEmbeddingBackend(enabled: enabled)
            let report = try await memory.reindexAllMemoryEmbeddingsForCurrentProvider()
            let runtime = try await MemoryStatusProjection.embeddingRuntime(dataRoot: dataRoot)
            return (report, runtime)
        } catch {
            // A backend is not allowed to change while canonical vectors stay
            // in the prior space. Restore the requested backend so recall
            // immediately returns to the previously active epoch.
            let wasEnabled = before?.requestedBackend != ManagedEmbeddingProvider.mockBackend
            try? await memory.configureEmbeddingBackend(enabled: wasEnabled)
            throw error
        }
    }
}
