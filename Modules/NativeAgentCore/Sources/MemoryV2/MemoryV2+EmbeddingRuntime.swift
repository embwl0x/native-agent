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
    /// `lowMemory` is resolved from the persisted mode at model-LOAD time and
    /// handed to the loader so the CoreML model can be constructed with
    /// `.cpuOnly` compute units (A5.4).
    public typealias Loader = @Sendable (_ lowMemory: Bool) throws -> any EmbeddingProvider
    public typealias AvailabilityProbe = @Sendable () -> Bool

    public static let coreMLBackend = "coreml-minilm"
    public static let mockBackend = "mock"
    /// Reported by `snapshot()` when the user wanted CoreML, CoreML couldn't
    /// load, AND the `NATIVE_AGENT_EMBEDDING_MOCK` developer-test env var is
    /// NOT set — so `embed()` will throw on every call. Distinct from
    /// `mockBackend`, which is the explicit user opt-in.
    public static let failClosedBackend = "fail-closed"
    public static let performanceMode = "performance"
    public static let balancedMode = "balanced"
    public static let lowMemoryMode = "low_memory"

    private struct State {
        var coreMLProvider: (any EmbeddingProvider)?
        /// The `lowMemory` selection the RESIDENT provider was loaded with.
        /// Meaningless when `coreMLProvider` is nil. Checked on every load
        /// request so a mode flip that raced a mid-flight load — or an
        /// external mode.json edit that never went through setMemoryMode —
        /// can never keep serving a stale-compute-units model (gpt-5.5
        /// BLOCKING x2, 2026-07-24).
        var coreMLProviderLowMemory = false
        var lastUsedAt: Date?
        var lastLoadedAt: Date?
        var lastUnloadedAt: Date?
        var unloadReason: String?
        var lastLoadError: String?
        var loadCount: Int = 0
        var unloadCount: Int = 0
        var generation: UInt64 = 0
    }

    private let dataRoot: URL
    private let loader: Loader
    private let availabilityProbe: AvailabilityProbe
    private let mock: MockEmbeddingProvider
    private let lock = NSLock()
    private var state = State()

    public init(
        dataRoot: URL,
        dimensions: Int = 384,
        loader: @escaping Loader = { lowMemory in
            try CoreMLEmbeddingProvider.bundled(lowMemory: lowMemory)
        },
        availabilityProbe: @escaping AvailabilityProbe = { CoreMLEmbeddingProvider.bundledResourcesAvailable() }
    ) {
        self.dataRoot = dataRoot
        self.loader = loader
        self.availabilityProbe = availabilityProbe
        self.mock = MockEmbeddingProvider(dimensions: dimensions)
    }

    public var dimensions: Int {
        lock.withLock { state.coreMLProvider?.dimensions ?? mock.dimensions }
    }

    public var modelId: String {
        let config = Self.readConfig(dataRoot: dataRoot)
        guard config.backend != Self.mockBackend else { return mock.modelId }
        return lock.withLock { state.coreMLProvider?.modelId ?? "all-MiniLM-L6-v2" }
    }

    public var embeddingEpoch: MemoryEmbeddingEpoch {
        let config = Self.readConfig(dataRoot: dataRoot)
        if config.backend == Self.mockBackend { return mock.embeddingEpoch }
        if let loaded = lock.withLock({ state.coreMLProvider }) {
            return loaded.embeddingEpoch
        }
        if ProcessInfo.processInfo.environment["NATIVE_AGENT_EMBEDDING_MOCK"] == "1",
           !availabilityProbe() {
            return mock.embeddingEpoch
        }
        return (try? CoreMLEmbeddingProvider.bundledEmbeddingEpoch())
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

    public func embedWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch {
        let config = Self.readConfig(dataRoot: dataRoot)
        guard config.backend != Self.mockBackend else {
            release(reason: "disabled by user")
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
            provider = try loadCoreMLProvider(
                lowMemory: Self.usesCPUOnlyCompute(mode: config.mode)
            )
        } catch {
            recordLoadFailure(error)
            if ProcessInfo.processInfo.environment["NATIVE_AGENT_EMBEDDING_MOCK"] == "1" {
                return try await mock.embedWithEpoch(texts)
            }
            throw NSError(
                domain: "NativeAgentMemoryV2",
                code: -100,
                userInfo: [NSLocalizedDescriptionKey:
                    "CoreML embedding model unavailable. Reinstall the app to "
                    + "restore the bundled MiniLM, or set "
                    + "NATIVE_AGENT_EMBEDDING_MOCK=1 to opt into deterministic "
                    + "test vectors. Underlying error: \(error.localizedDescription)"]
            )
        }
        noteUse()
        do {
            let batch = try await provider.embedWithEpoch(texts)
            scheduleIdleUnloadIfNeeded(mode: config.mode)
            return batch
        } catch is CancellationError {
            // Provider stays hot, but it's now idle — without this a
            // low-memory-mode model would stay resident indefinitely after
            // a cancelled embed (gpt-5.5 review nit).
            scheduleIdleUnloadIfNeeded(mode: config.mode)
            throw CancellationError()
        } catch {
            // Transient predict failure: keep the provider hot, propagate
            // the real error to the caller (fail-closed, no mock fallback —
            // the model IS installed and loaded).
            scheduleIdleUnloadIfNeeded(mode: config.mode)
            throw error
        }
    }

    public func snapshot() -> EmbeddingRuntimeSnapshot {
        let config = Self.readConfig(dataRoot: dataRoot)
        let resourcesAvailable = availabilityProbe()
        let mockEnvOptIn = ProcessInfo.processInfo.environment["NATIVE_AGENT_EMBEDDING_MOCK"] == "1"
        return lock.withLock {
            let loadedProvider = state.coreMLProvider
            let requestedCoreML = config.backend != Self.mockBackend
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
                return resourcesAvailable ? "all-MiniLM-L6-v2" : mock.modelId
            }()
            return EmbeddingRuntimeSnapshot(
                requestedBackend: config.backend,
                effectiveBackend: effectiveBackend,
                mode: config.mode,
                modelId: modelId,
                dimensions: loadedProvider?.dimensions ?? mock.dimensions,
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
                lastLoadError: state.lastLoadError,
                loadCount: state.loadCount,
                unloadCount: state.unloadCount,
                idleUnloadSeconds: Self.idleUnloadSeconds(for: config.mode)
            )
        }
    }

    public func setBackend(enabled: Bool) async throws {
        try await writeConfigValue(
            path: Self.backendPath(dataRoot: dataRoot),
            key: "backend",
            value: enabled ? Self.coreMLBackend : Self.mockBackend
        )
        if !enabled {
            release(reason: "disabled by user")
        }
    }

    /// A5.4: whether a given persisted mode should load CoreML with `.cpuOnly`
    /// compute units. Only `low_memory` does — every other mode (including
    /// unknown/absent, which normalizes to `balanced`) returns false and the
    /// model load keeps the untouched CoreML default. Pure so the selection is
    /// pinned by tests rather than inferred from a live model load.
    public static func usesCPUOnlyCompute(mode: String) -> Bool {
        normalizeMode(mode) == lowMemoryMode
    }

    public func setMemoryMode(_ mode: String) async throws {
        let previous = Self.readConfig(dataRoot: dataRoot).mode
        let normalized = Self.normalizeMode(mode)
        try await writeConfigValue(
            path: Self.modePath(dataRoot: dataRoot),
            key: "mode",
            value: normalized
        )
        // Compute units are chosen at model-LOAD time, so a mode change only
        // reaches CoreML on the next load. When the flip actually changes the
        // selection (into or out of low_memory) drop the resident model through
        // the EXISTING release path so the next embed() reloads under the right
        // units. Flips that don't change the selection (performance <-> balanced)
        // leave the model hot, exactly as before.
        let flipsComputeUnits =
            Self.usesCPUOnlyCompute(mode: previous) != Self.usesCPUOnlyCompute(mode: normalized)
        let isLoaded = lock.withLock { state.coreMLProvider != nil }
        if flipsComputeUnits && isLoaded {
            release(reason: "compute units changed for \(normalized) mode")
        }
        scheduleIdleUnloadIfNeeded(mode: normalized)
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
            state.generation &+= 1
        }
        return snapshot()
    }

    private func loadCoreMLProvider(lowMemory: Bool) throws -> any EmbeddingProvider {
        if let existing = lock.withLock({
            state.coreMLProvider != nil && state.coreMLProviderLowMemory == lowMemory
                ? state.coreMLProvider : nil
        }) {
            return existing
        }
        // Either nothing is resident, or the resident provider was loaded
        // under the OTHER compute selection (a flip raced its load, or
        // mode.json changed externally). Evict a mismatched resident before
        // loading so this request's selection is what actually serves.
        lock.withLock {
            if state.coreMLProvider != nil, state.coreMLProviderLowMemory != lowMemory {
                state.coreMLProvider = nil
                state.lastUnloadedAt = Date()
                state.unloadReason = "compute units changed (selection mismatch at load)"
                state.generation &+= 1
            }
        }
        let provider = try loader(lowMemory)
        return lock.withLock {
            if let existing = state.coreMLProvider {
                if state.coreMLProviderLowMemory == lowMemory {
                    return existing
                }
                // A concurrent load under the other selection won the install
                // race. This request's selection reflects the CURRENT mode
                // read — replace, don't adopt the stale winner.
                state.lastUnloadedAt = Date()
                state.unloadReason = "compute units changed (install race)"
            }
            state.coreMLProvider = provider
            state.coreMLProviderLowMemory = lowMemory
            state.lastLoadedAt = Date()
            state.unloadReason = nil
            state.lastLoadError = nil
            state.loadCount += 1
            state.generation &+= 1
            return provider
        }
    }

    private func noteUse() {
        lock.withLock {
            state.lastUsedAt = Date()
            state.generation &+= 1
        }
    }

    private func recordLoadFailure(_ error: Error) {
        // gpt-5.5 review-2 NEEDS_FIX: post-fail-closed wording. Previously
        // this said "using mock fallback" — that was honest when embed()
        // silently mocked on load failure. Now embed() throws unless the
        // developer-test env var opts in, so the load-failure terminal
        // state is fail-closed (or mock-if-opt-in). Reason mirrors the
        // snapshot() branch logic so UI panels and the unload reason agree.
        let mockOptIn = ProcessInfo.processInfo.environment["NATIVE_AGENT_EMBEDDING_MOCK"] == "1"
        lock.withLock {
            state.lastLoadError = String(describing: error)
            state.coreMLProvider = nil
            state.lastUnloadedAt = Date()
            state.unloadReason = mockOptIn
                ? "load failed; mock embedder active via NATIVE_AGENT_EMBEDDING_MOCK"
                : "load failed; fail-closed (embed() will throw)"
            state.generation &+= 1
        }
    }

    private func scheduleIdleUnloadIfNeeded(mode: String) {
        guard let seconds = Self.idleUnloadSeconds(for: mode) else { return }
        let generation = lock.withLock { state.generation }
        Task.detached { [weak self] in
            let nanos = UInt64(seconds) * 1_000_000_000
            try? await Task.sleep(nanoseconds: nanos)
            self?.releaseIfIdle(generation: generation, idleSeconds: seconds)
        }
    }

    private func releaseIfIdle(generation: UInt64, idleSeconds: Int) {
        lock.withLock {
            guard state.coreMLProvider != nil else { return }
            guard state.generation == generation else { return }
            if let lastUsedAt = state.lastUsedAt,
               Date().timeIntervalSince(lastUsedAt) < Double(idleSeconds) {
                return
            }
            state.coreMLProvider = nil
            state.lastUnloadedAt = Date()
            state.unloadReason = "idle timeout"
            state.unloadCount += 1
            state.generation &+= 1
        }
    }

    private func writeConfigValue(path: URL, key: String, value: String) async throws {
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            try await persistence.writeJSON(.object([key: .string(value)]), to: path)
        }
    }

    private static func readConfig(dataRoot: URL) -> (backend: String, mode: String) {
        let backend = readStringValue(from: backendPath(dataRoot: dataRoot), key: "backend")
        let mode = readStringValue(from: modePath(dataRoot: dataRoot), key: "mode")
        return (
            normalizeBackend(backend),
            normalizeMode(mode)
        )
    }

    private static func normalizeBackend(_ backend: String?) -> String {
        switch backend?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case mockBackend:
            return mockBackend
        default:
            return coreMLBackend
        }
    }

    private static func normalizeMode(_ mode: String?) -> String {
        switch mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case performanceMode:
            return performanceMode
        case lowMemoryMode:
            return lowMemoryMode
        default:
            return balancedMode
        }
    }

    private static func idleUnloadSeconds(for mode: String) -> Int? {
        switch normalizeMode(mode) {
        case performanceMode:
            return nil
        case lowMemoryMode:
            return 45
        default:
            return 300
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

    private static func modePath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("embeddings", isDirectory: true)
            .appendingPathComponent("mode.json")
    }

    private static func isoString(_ date: Date?) -> String? {
        guard let date else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }
}

private extension NSLock {
    func withLock<T>(_ work: () -> T) -> T {
        lock()
        defer { unlock() }
        return work()
    }
}
