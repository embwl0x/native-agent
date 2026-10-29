import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
import Observation
import NativeAgentShared
// Blueprint: | `MemoryV2+EmbeddingRuntime.swift` | `EmbeddingRuntimeSnapshot`; canonical runtime embedding backend with performance residency and the query form (bge queries carry its retrieval instruction, stored text never); durable action-index updates at warm-up and inventory changes, with serialized missing-text fills and background epoch rebuilds; engine termination closes admission, removes passive observations and cancels/drains both convergence flights through actual exit |

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
}

/// config/embeddings.json owns the backend selection; excluded from local
/// backup/export and phone sync, listed in PrivacyMap as Embedding Settings.
@Observable
/// embeddings.json: excluded from local backup/export and phone sync;
/// off-disk includes it; PrivacyMap lists config/embeddings.json.
public final class ManagedEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public static let coreMLBackend = "coreml-bge"
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

    public var dimensions: Int {
        guard Self.readBackend(dataRoot: dataRoot) != Self.mockBackend else { return mock.dimensions }
        if let loaded = lock.withLock({ state.coreMLProvider?.dimensions }) { return loaded }
        // Not resident yet: report the model that WOULD load, not the mock's
        // width, so status surfaces do not read "384d" beside a 1024-d model.
        return CoreMLEmbeddingProvider.bundledDimensions
    }

    public var modelId: String {
        let config = Self.readBackend(dataRoot: dataRoot)
        guard config != Self.mockBackend else { return mock.modelId }
        return lock.withLock { state.coreMLProvider?.modelId ?? CoreMLEmbeddingProvider.bundledModelID }
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
            ?? FailClosedEmbeddingProvider().embeddingEpoch
    }

    /// The loaded model's space, or the mock's; never a hash or a load.
    var residentEmbeddingEpoch: MemoryEmbeddingEpoch? {
        if Self.readBackend(dataRoot: dataRoot) == Self.mockBackend { return mock.embeddingEpoch }
        return lock.withLock { state.coreMLProvider?.embeddingEpoch }
    }

    /// Embed `texts` via the CoreML bge backend.
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

    /// Embed with a resident, matching, non-mock model without loading or taking `loadLock`; otherwise return nil.
    public func embedIfResident(_ texts: [String], requireFullText: Bool = false) async -> [[Float]]? {
        let config = Self.readBackend(dataRoot: dataRoot)
        guard config != Self.mockBackend, !texts.isEmpty else { return nil }
        guard let provider = lock.withLock({ state.coreMLProvider }) else { return nil }
        noteUse()
        if requireFullText {
            return try? await (provider as? CoreMLEmbeddingProvider)?.embedCompleteTexts(texts)
        }
        return try? await provider.embed(texts)
    }

    func coversCompleteTextsIfResident(_ texts: [String]) -> Bool? {
        guard let provider = lock.withLock({ state.coreMLProvider }) as? CoreMLEmbeddingProvider else { return nil }
        return provider.coversCompleteTexts(texts)
    }

    public func embedWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch {
        try await embedWithEpoch(texts, asQueries: false)
    }

    /// BGE v1.5 is trained asymmetric: a search query carries this
    /// instruction, the stored passages it is scored against do not. The
    /// explicit mock embeds a query like any text.
    static func queryInstruction(forModel modelID: String) -> String? {
        modelID.lowercased().contains("bge") ? "Represent this sentence for searching relevant passages: " : nil
    }

    public func embedQueriesWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch {
        try await embedWithEpoch(texts, asQueries: true)
    }

    private func embedWithEpoch(_ texts: [String], asQueries: Bool) async throws -> MemoryEmbeddingBatch {
        let config = Self.readBackend(dataRoot: dataRoot)
        guard config != Self.mockBackend else {
            return try await mock.embedWithEpoch(texts)
        }

        // Only load failures unload the provider and stamp lastLoadError; prediction failures preserve the loaded model.
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
                    "CoreML memory search model \(CoreMLEmbeddingProvider.bundledModelID) did not load: "
                    + "\(error.localizedDescription)"]
            )
        }
        noteUse()
        // Prediction failures and cancellation retain the resident model.
        let instruction = asQueries ? Self.queryInstruction(forModel: provider.modelId) : nil
        return try await provider.embedWithEpoch(instruction.map { prefix in texts.map { prefix + $0 } } ?? texts)
    }

    public func snapshot() -> EmbeddingRuntimeSnapshot {
        let config = Self.readBackend(dataRoot: dataRoot)
        let mockEnvOptIn = ProcessInfo.processInfo.environment["NATIVE_AGENT_EMBEDDING_MOCK"] == "1"
        // A broken installed model is named before the first embed() tries it,
        // so status never shows a plain "missing" for a model that is there
        // but unusable.
        let installedModelProblem: String?
        let resourcesAvailable: Bool
        do {
            _ = try CoreMLEmbeddingProvider.installedExtrasModel(root: dataRoot)
            installedModelProblem = nil
            resourcesAvailable = true
        } catch {
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
                // Missing CoreML resources report fail-closed before the first embed call.
                effectiveBackend = Self.failClosedBackend
            }
            let modelId: String = {
                if effectiveBackend == Self.mockBackend { return mock.modelId }
                if let loadedProvider { return loadedProvider.modelId }
                return CoreMLEmbeddingProvider.bundledModelID
            }()
            return EmbeddingRuntimeSnapshot(
                requestedBackend: config,
                effectiveBackend: effectiveBackend,
                mode: Self.performanceMode,
                modelId: modelId,
                dimensions: effectiveBackend == Self.mockBackend
                    ? mock.dimensions : loadedProvider?.dimensions ?? CoreMLEmbeddingProvider.bundledDimensions,
                embeddingEpoch: effectiveBackend == Self.mockBackend
                    ? mock.embeddingEpoch.rawValue
                    : loadedProvider?.embeddingEpoch.rawValue,
                coreMLResourcesAvailable: resourcesAvailable,
                coreMLLoaded: loaded,
                modelLoadable: resourcesAvailable && state.lastLoadError == nil,
                lastUsedAt: Self.isoString(state.lastUsedAt),
                lastLoadedAt: Self.isoString(state.lastLoadedAt),
                lastUnloadedAt: Self.isoString(state.lastUnloadedAt),
                unloadReason: state.unloadReason,
                lastLoadError: state.lastLoadError ?? installedModelProblem,
                loadCount: state.loadCount,
                unloadCount: state.unloadCount
            )
        }
    }

    /// Load the requested space while the current selection continues serving.
    func prepareBackend(enabled: Bool) throws -> any EmbeddingProvider {
        if !enabled { return mock }
        return try loadCoreMLProvider(config: Self.readBackend(dataRoot: dataRoot))
    }

    func setBackend(enabled: Bool) async throws {
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
                  Self.readBackend(dataRoot: dataRoot) == config else { throw CancellationError() }
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
        // Match snapshot status: load failure is fail-closed unless mock use is explicitly enabled.
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
        try await SwiftNativePersistenceCore.withFileLock(path) {
            try await SwiftNativePersistenceCore.writeJSON(.object([key: .string(value)]), to: path)
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

extension SwiftNativeMemoryV2 {
    public func installActionIndex(paths: [URL], notifications: [Notification.Name],
                                   source: @escaping @Sendable () async throws -> [String]) {
        guard !embeddingConvergenceStopped, actionIndexSource == nil else { return }
        actionIndexSource = source
        actionIndexWatcher = FileChangeWatcher(paths: paths) { [weak self] _ in
            Task { await self?.requestActionIndexUpdate() }
        }
        actionIndexObservers = ObservationNotifications(names: notifications) { [weak self] in
            Task { await self?.requestActionIndexUpdate() }
        }
        requestActionIndexUpdate()
    }

    /// Coalesce owner changes, including changes arriving while a batch embeds.
    /// No request waits for an epoch rebuild and no timer drives this work.
    public func requestActionIndexUpdate() {
        guard !embeddingConvergenceStopped, actionIndexSource != nil else { return }
        actionIndexDirty = true
        guard actionIndexUpdate == nil else { return }
        actionIndexUpdate = Task(priority: .utility) {
            defer { actionIndexUpdate = nil }
            while !embeddingConvergenceStopped, !Task.isCancelled, actionIndexDirty {
                actionIndexDirty = false
                do {
                    guard let source = actionIndexSource else { return }
                    let texts = try await source()
                    try checkEmbeddingConvergence()
                    try await fillActionIndex(texts)
                    try checkEmbeddingConvergence()
                    actionIndexFailure = nil
                } catch {
                    guard !embeddingConvergenceStopped, !Task.isCancelled else { return }
                    actionIndexFailure = error.localizedDescription
                    nativeLog("[action-index] update failed: %@", error.localizedDescription)
                }
            }
        }
    }

    /// Close admission and passive observation before draining. The flight
    /// handles remain owned until their bodies (including detached fills) exit;
    /// the engine's existing bounded termination wait never releases them early.
    public func shutdownEmbeddingConvergence() async {
        embeddingConvergenceStopped = true
        actionIndexSource = nil
        actionIndexDirty = false
        embeddingEpochDirty = false
        actionIndexWatcher?.cancel()
        actionIndexWatcher = nil
        actionIndexObservers?.cancel()
        actionIndexObservers = nil
        actionIndexUpdate?.cancel()
        embeddingEpochReconcile?.cancel()
        await actionIndexUpdate?.value
        _ = await embeddingEpochReconcile?.value
    }

    func checkEmbeddingConvergence() throws {
        try Task.checkCancellation()
        guard !embeddingConvergenceStopped else { throw CancellationError() }
    }

    private static func actionTextHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A find's own actions the catalog index never holds (the verbs of the
    /// page a sense just served her, a turn's own parts) are embedded with
    /// her ask; only a fill that is behind leaves more than this missing.
    public static let actionIndexMissesEmbeddedWithAsk = 16

    /// The published index, one entry per text: its vector, or nil where the
    /// index lacks it, for the caller to embed with the ask. Any miss requests
    /// a fill, never awaited. More misses than the ask carries, or no resident
    /// model, fail: that find ranks by words and is told so.
    public func indexedActionVectors(_ texts: [String]) async throws -> (epoch: MemoryEmbeddingEpoch, vectors: [[Float]?]) {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        guard let epoch = residentEmbeddingEpoch() else {
            requestActionIndexUpdate()
            throw MemoryV2Error.underlying(actionIndexFailure ?? "Action search awaits the memory search model; an index update was requested.")
        }
        let indexed = try await storage.actionEmbeddings(epoch: epoch)
        let dimensions = embedder?.dimensions
        let vectors = texts.map { indexed[Self.actionTextHash($0)].flatMap { $0.count == dimensions ? $0 : nil } }
        let misses = vectors.filter { $0 == nil }.count
        if misses > 0 { requestActionIndexUpdate() }
        guard misses > Self.actionIndexMissesEmbeddedWithAsk else { return (epoch, vectors) }
        if let actionIndexFailure {
            throw MemoryV2Error.underlying("Action search index could not be built: \(actionIndexFailure)\nEpoch evidence: \(epoch.rawValue)")
        }
        throw MemoryV2Error.underlying("Action search index is incomplete (\(misses) of \(texts.count) actions not yet indexed); an update was requested.\nEpoch evidence: \(epoch.rawValue)")
    }

    /// Only the background updater fills, in bounded chunks on a detached
    /// task, so prediction never occupies this actor; vectors live in SQLite.
    private func fillActionIndex(_ texts: [String]) async throws {
        try await ensureCanonicalAttachment()
        try checkEmbeddingConvergence()
        guard let storage, let embedder else { throw MemoryV2Error.storageUnavailable }
        let disk = storage
        try checkEmbeddingConvergence()
        let fill = Task.detached(priority: .utility) {
            let epoch = embedder.embeddingEpoch
            let byHash = Dictionary(texts.map { (Self.actionTextHash($0), $0) }, uniquingKeysWith: { first, _ in first })
            let dimensions = embedder.dimensions
            let indexed = try await disk.actionEmbeddings(epoch: epoch).filter { $0.value.count == dimensions }
            try await self.checkEmbeddingConvergence()
            let missing = byHash.keys.filter { indexed[$0] == nil }.sorted()
            for start in stride(from: 0, to: missing.count, by: 8) {
                let hashes = Array(missing[start..<min(start + 8, missing.count)])
                let texts = try hashes.map { hash in
                    guard let text = byHash[hash] else {
                        throw MemoryV2Error.underlying("An action index source is missing for \(hash).")
                    }
                    return text
                }
                let batch = try await embedder.embedWithEpoch(texts)
                try await self.checkEmbeddingConvergence()
                guard batch.epoch == epoch, embedder.embeddingEpoch == epoch else {
                    await self.requestActionIndexUpdate()
                    throw MemoryV2Error.underlying("The MemoryV2 action index changed epoch while updating.")
                }
                guard batch.vectors.count == hashes.count,
                      batch.vectors.allSatisfy({ !$0.isEmpty && $0.count == dimensions && $0.allSatisfy(\.isFinite) && $0.contains(where: { $0 != 0 }) }) else {
                    throw MemoryV2Error.underlying("Action search received unusable vectors from the memory search model.")
                }
                // Each chunk lands as it finishes, so an interrupted fill keeps its progress.
                try await disk.writeActionEmbeddings(Dictionary(uniqueKeysWithValues: zip(hashes, batch.vectors)), epoch: epoch)
                try await self.checkEmbeddingConvergence()
            }
            // Vectors are content-addressed: keep every one this epoch embedded, so a
            // find whose action set differs from this pass's (a turn's own parts,
            // a lane coming up) never loses the vectors it needs. Only other
            // epochs are retired.
            try await disk.writeActionEmbeddings([:], epoch: epoch, retaining: Set(indexed.keys).union(byHash.keys))
        }
        try await withTaskCancellationHandler {
            try await fill.value
        } onCancel: {
            fill.cancel()
        }
    }

    public func warmUpEmbeddingsAtLaunch() async {
        defer { requestActionIndexUpdate() }
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
            nativeLog("[embedding-warmup] SUCCESS: bge-large-en-v1.5 eagerly warmed for Fast mode")
            OrganPulse.record("embedding_warmup", .worked, note: "embedder loaded")
            let after = embeddingRuntimeSnapshot()
            nativeLog("[embedding-warmup] post-load snapshot: coreMLLoaded=\(after?.coreMLLoaded ?? false) effectiveBackend=\(after?.effectiveBackend ?? "nil")")
        } catch {
            nativeLog("[embedding-warmup] FAILED: \(error.localizedDescription)")
        }
    }

    public func configureEmbeddingBackendAndReindex(enabled: Bool) async throws {
        try await ensureCanonicalAttachment()
        guard let managed = embedder as? ManagedEmbeddingProvider else {
            throw MemoryV2Error.underlying("embedding runtime is not configurable")
        }
        let candidate = try managed.prepareBackend(enabled: enabled)
        _ = try await reindexMemoryEmbeddings(using: candidate)
        // The epoch owner has committed a complete space. Publish selection
        // only now; a failed build never writes configuration to undo later.
        try await managed.setBackend(enabled: enabled)
        requestActionIndexUpdate()
    }
}
