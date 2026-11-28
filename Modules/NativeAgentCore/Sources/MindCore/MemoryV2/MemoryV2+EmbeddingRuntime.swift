import Synchronization
import Foundation
import NativeAgentCore
import PersistenceCore
import Observation
import NativeAgentShared
// Blueprint: | `MemoryV2+EmbeddingRuntime.swift` | `EmbeddingRuntimeSnapshot`: serving backend, action index and owned convergence |

public struct EmbeddingRuntimeSnapshot: Sendable, Equatable {
    public var requestedBackend: String
    public var effectiveBackend: String
    public var mode: String
    public var modelId: String
    public var dimensions: Int
    /// Carry serving vector identity on the same snapshot so turn preparation cannot bind query vectors to reread configuration.
    public var embeddingEpoch: String?
    public var coreMLResourcesAvailable: Bool
    public var coreMLLoaded: Bool
    public var modelLoadable: Bool
    public var lastLoadedAt: String?
    public var lastLoadError: String?
    public var loadCount: Int
    public var unloadCount: Int
}

/// config/embeddings.json owns backend selection; PrivacyMap excludes it from local backup, export and phone sync.
@Observable
/// Off-disk backup includes config/embeddings.json.
public final class ManagedEmbeddingProvider: EmbeddingProvider {
    public static let coreMLBackend = "coreml-bge"
    public static let mockBackend = "mock"
    /// Reported when selected CoreML cannot load; embed() retains that failure.
    public static let failClosedBackend = "fail-closed"
    public static let performanceMode = "performance"

    private struct State {
        var coreMLProvider: CoreMLEmbeddingProvider?
        var lastLoadedAt: Date?
        var lastLoadError: String?
        var loadCount: Int = 0
        var unloadCount: Int = 0
        /// Activity and idle scheduling must not invalidate a cold load.
        var loadGeneration: UInt64 = 0
    }

    private let dataRoot: URL
    private let mock: MockEmbeddingProvider
    private let loadLock = Mutex(())
    private let state = Mutex<State>(State())

    public init(dataRoot: URL, dimensions: Int = 384) {
        self.dataRoot = dataRoot
        self.mock = MockEmbeddingProvider(dimensions: dimensions)
    }

    public var dimensions: Int {
        guard Self.readBackend(dataRoot: dataRoot) != Self.mockBackend else { return mock.dimensions }
        if let loaded = state.withLock({ $0.coreMLProvider?.dimensions }) { return loaded }
        // Cold status reports the model's real dimensions rather than the mock width.
        return CoreMLEmbeddingProvider.bundledDimensions
    }

    public var modelId: String {
        let config = Self.readBackend(dataRoot: dataRoot)
        guard config != Self.mockBackend else { return mock.modelId }
        return state.withLock { $0.coreMLProvider?.modelId ?? CoreMLEmbeddingProvider.bundledModelID }
    }

    public var embeddingEpoch: MemoryEmbeddingEpoch {
        get throws {
            let (loaded, generation) = state.withLock { ($0.coreMLProvider, $0.loadGeneration) }
            do {
                let config = try Self.readBackendChecked(dataRoot: dataRoot)
                if config == Self.mockBackend { return mock.embeddingEpoch }
                if let loaded { return loaded.embeddingEpoch }
                return try CoreMLEmbeddingProvider.bundledEmbeddingEpoch(extrasRoot: dataRoot)
            } catch {
                let failure = String(describing: error)
                guard state.withLock({
                    $0.loadGeneration == generation && $0.coreMLProvider == nil && $0.lastLoadError != failure
                }) else { throw error }
                withMutation(keyPath: \.runtimeSnapshot) {
                    state.withLock { state in
                        // A cold probe cannot invalidate a provider loaded while it was reading.
                        guard state.loadGeneration == generation, state.coreMLProvider == nil,
                              state.lastLoadError != failure else { return }
                        state.lastLoadError = failure
                    }
                }
                throw error
            }
        }
    }

    /// Read the serving space without hashing or loading.
    var residentEmbeddingEpoch: MemoryEmbeddingEpoch? {
        get throws {
            let backend = try Self.readBackendChecked(dataRoot: dataRoot)
            if backend == Self.mockBackend { return mock.embeddingEpoch }
            return state.withLock { $0.coreMLProvider?.embeddingEpoch }
        }
    }

    /// CoreML failures throw: synthetic vectors would corrupt semantic retrieval and deduplication. Only explicit config/embeddings.json `mock` selection
    /// permits synthetic vectors; environment variables cannot change failed inference.
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        try await embedWithEpoch(texts).vectors
    }

    /// Residency is independent of whether semantic search is selected.
    @concurrent public func warmUp() async throws {
        let config = try Self.readBackendChecked(dataRoot: dataRoot)
        guard config != Self.mockBackend else { return }
        if state.withLock({ $0.coreMLProvider != nil }) { return }
        let provider = try loadCoreMLProvider(config: config)
        _ = try await provider.embed(["warmup"])
    }

    /// Retain vectors and identity from one provider across suspension; cold or mock state returns nil without loading or taking loadLock.
    @concurrent public func embedIfResidentWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch? {
        let config = try Self.readBackendChecked(dataRoot: dataRoot)
        guard config != Self.mockBackend, !texts.isEmpty else { return nil }
        guard let provider = state.withLock({ $0.coreMLProvider }) else { return nil }
        return try await provider.embedWithEpoch(texts)
    }

    public func embedWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch {
        try await embedWithEpoch(texts, asQueries: false)
    }

    /// BGE queries need the trained asymmetric instruction; stored passages do not. Mock queries use ordinary embedding.
    static func queryInstruction(forModel modelID: String) -> String? {
        modelID.lowercased().contains("bge") ? "Represent this sentence for searching relevant passages: " : nil
    }

    public func embedQueriesWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch {
        try await embedWithEpoch(texts, asQueries: true)
    }

    @concurrent private func embedWithEpoch(_ texts: [String], asQueries: Bool) async throws -> MemoryEmbeddingBatch {
        let provider = try predictionProvider()
        let instruction = asQueries ? Self.queryInstruction(forModel: provider.modelId) : nil
        return try await provider.embedWithEpoch(instruction.map { prefix in texts.map { prefix + $0 } } ?? texts)
    }

    @concurrent public func embedItemsWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingItemBatch {
        let provider = try predictionProvider()
        return try await provider.embedItemsWithEpoch(texts)
    }

    private func predictionProvider() throws -> any EmbeddingProvider {
        let config = try Self.readBackendChecked(dataRoot: dataRoot)
        guard config != Self.mockBackend else {
            return mock
        }

        // Prediction failures preserve the loaded model; loading owns its failure record.
        let provider: any EmbeddingProvider
        do {
            provider = try loadCoreMLProvider(config: config)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NSError(
                domain: "NativeAgentMemoryV2",
                code: -100,
                userInfo: [NSLocalizedDescriptionKey:
                    "CoreML memory search model \(CoreMLEmbeddingProvider.bundledModelID) did not load: "
                    + "\(error.localizedDescription)"]
            )
        }
        // Prediction failures and cancellation retain the resident model.
        return provider
    }

    public func snapshot() -> EmbeddingRuntimeSnapshot {
        access(keyPath: \.runtimeSnapshot)
        return runtimeSnapshot
    }

    private var runtimeSnapshot: EmbeddingRuntimeSnapshot {
        let config: String
        let configurationError: String?
        do { config = try Self.readBackendChecked(dataRoot: dataRoot); configurationError = nil }
        catch { config = Self.failClosedBackend; configurationError = error.localizedDescription }
        // Name broken installed models before first inference so status cannot misreport them as missing.
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
        return state.withLock { state in
            let loadedProvider = state.coreMLProvider
            let requestedCoreML = config != Self.mockBackend
            let loaded = loadedProvider != nil
            let effectiveBackend: String
            if configurationError != nil {
                effectiveBackend = Self.failClosedBackend
            } else if !requestedCoreML {
                // Synthetic vectors require explicit configuration.
                effectiveBackend = Self.mockBackend
            } else if loaded {
                effectiveBackend = Self.coreMLBackend
            } else if state.lastLoadError == nil && resourcesAvailable {
                effectiveBackend = Self.coreMLBackend
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
                embeddingEpoch: effectiveBackend == Self.failClosedBackend ? nil : effectiveBackend == Self.mockBackend
                    ? mock.embeddingEpoch.rawValue
                    : loadedProvider?.embeddingEpoch.rawValue,
                coreMLResourcesAvailable: resourcesAvailable,
                coreMLLoaded: loaded,
                modelLoadable: configurationError == nil && resourcesAvailable && state.lastLoadError == nil,
                lastLoadedAt: state.lastLoadedAt.map(NativeTimestampFormat.plainZulu),
                lastLoadError: configurationError ?? state.lastLoadError ?? installedModelProblem,
                loadCount: state.loadCount,
                unloadCount: state.unloadCount
            )
        }
    }

    /// Prepare the requested space while the current selection keeps serving.
    func prepareBackend(enabled: Bool) throws -> any EmbeddingProvider {
        if !enabled { return mock }
        return try loadCoreMLProvider(config: Self.readBackendChecked(dataRoot: dataRoot))
    }

    func setBackend(enabled: Bool) async throws {
        let previous = Self.readBackend(dataRoot: dataRoot)
        try await writeConfigValue(
            path: Self.backendPath(dataRoot: dataRoot),
            key: "backend",
            value: enabled ? Self.coreMLBackend : Self.mockBackend
        )
        if previous != (enabled ? Self.coreMLBackend : Self.mockBackend) {
            withMutation(keyPath: \.runtimeSnapshot) {
                state.withLock { $0.loadGeneration &+= 1 }
            }
        }
    }

    public func release() {
        withMutation(keyPath: \.runtimeSnapshot) {
            state.withLock { state in
                if state.coreMLProvider != nil {
                    state.unloadCount += 1
                }
                state.coreMLProvider = nil
                state.loadGeneration &+= 1
            }
        }
    }

    private func loadCoreMLProvider(config: String) throws -> any EmbeddingProvider {
        // Coalesce cold loads before compiling or allocating a model; keep status and release independent of synchronous loading.
        return try loadLock.withLock { _ in
            let (existing, generation) = try state.withLock { state in
                guard try Self.readBackendChecked(dataRoot: dataRoot) == config else { throw CancellationError() }
                return (state.coreMLProvider, state.loadGeneration)
            }
            if let existing { return existing }
            let provider: CoreMLEmbeddingProvider
            do {
                provider = try CoreMLEmbeddingProvider.bundled(extrasRoot: dataRoot)
            } catch {
                recordLoadFailure(error, generation: generation)
                throw error
            }
            let installed: Result<Bool, Error> = withMutation(keyPath: \.runtimeSnapshot) {
                state.withLock { state in
                    Result {
                        guard state.loadGeneration == generation,
                              try Self.readBackendChecked(dataRoot: dataRoot) == config else { return false }
                        state.coreMLProvider = provider
                        state.lastLoadedAt = Date()
                        state.lastLoadError = nil
                        state.loadCount += 1
                        return true
                    }
                }
            }
            guard try installed.get() else { throw CancellationError() }
            return provider
        }
    }

    private func recordLoadFailure(_ error: Error, generation: UInt64) {
        withMutation(keyPath: \.runtimeSnapshot) {
            state.withLock { state in
                guard state.loadGeneration == generation else { return }
                state.lastLoadError = String(describing: error)
                state.coreMLProvider = nil
            }
        }
    }

    private func writeConfigValue(path: URL, key: String, value: String) async throws {
        try await SwiftNativePersistenceCore.withFileLock(path) {
            try await SwiftNativePersistenceCore.writeJSON(.object([key: .string(value)]), to: path)
        }
    }

    private static func readBackend(dataRoot: URL) -> String {
        do { return try readBackendChecked(dataRoot: dataRoot) }
        catch { return failClosedBackend }
    }

    private static func readBackendChecked(dataRoot: URL) throws -> String {
        let path = backendPath(dataRoot: dataRoot)
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return coreMLBackend }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backend = object["backend"] as? String,
              [coreMLBackend, mockBackend].contains(backend) else {
            throw MemoryStorageError.databaseUnavailable("""
                \(path.path) must name backend coreml-bge or mock. Repair Embedding Settings before using the memory model.
                """)
        }
        return backend
    }

    private static func backendPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("embeddings.json")
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

    /// Coalesce owner changes, including changes arriving while a batch embeds. No request waits for an epoch rebuild and no timer drives this work.
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

    /// Close admission and passive observation before draining. The flight handles remain owned until their bodies (including detached fills) exit; the
    /// engine's existing bounded termination wait never releases them early.
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

    /// Cache by exact action text because discovery repeatedly hashes the same corpus.
    private static func actionTextHash(_ text: String) -> String {
        actionHashes.withLock { actionHashes in
            if let known = actionHashes[text] { return known }
            let hash = SHA256Hex.of(Data(text.utf8))
            if actionHashes.count >= 4096 { actionHashes.removeAll(keepingCapacity: true) }
            actionHashes[text] = hash
            return hash
        }
    }
    private static let actionHashes = Mutex<[String: String]>([:])

    /// Embed ask-local actions with the query because the catalog index does not own them.
    public static let actionIndexMissesEmbeddedWithAsk = 16

    /// Request unresolved fills without awaiting them; return named per-text failures. Refuse incomplete search when misses exceed the ask's allowance or the
    /// model is not resident.
    public func indexedActionVectors(_ texts: [String], turn: Turn?) async throws -> (epoch: MemoryEmbeddingEpoch, vectors: [[Float]?], unembeddable: [Int: String]) {
        try await ensureCanonicalAttachment(preview: turn?.doorPreview != nil)
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        guard let epoch = try residentEmbeddingEpoch() else {
            if turn?.doorPreview == nil { requestActionIndexUpdate() }
            throw MemoryV2Error.underlying(actionIndexFailure ?? "Action search awaits the memory search model.")
        }
        let index = try await storage.actionEmbeddingIndex(epoch: epoch)
        let dimensions = embedder?.dimensions
        let vectors = texts.map { index.vectors[Self.actionTextHash($0)].flatMap { $0.count == dimensions ? $0 : nil } }
        let unembeddable = Dictionary(uniqueKeysWithValues: texts.indices.compactMap { offset -> (Int, String)? in
            guard let reason = index.failures[Self.actionTextHash(texts[offset])] else { return nil }
            return (offset, reason)
        })
        let misses = vectors.indices.filter { vectors[$0] == nil && unembeddable[$0] == nil }.count
        if misses > 0, turn?.doorPreview == nil { requestActionIndexUpdate() }
        guard misses > Self.actionIndexMissesEmbeddedWithAsk else { return (epoch, vectors, unembeddable) }
        if let actionIndexFailure {
            throw MemoryV2Error.underlying("Action search index could not be built: \(actionIndexFailure)\nEpoch evidence: \(epoch.rawValue)")
        }
        throw MemoryV2Error.underlying("""
            Action search index is incomplete (\(misses) of \(texts.count) actions not yet indexed).\nEpoch evidence: \
            \(epoch.rawValue)
            """)
    }

    /// Only the background updater fills, in bounded chunks on a detached task, so prediction never occupies this actor; vectors live in SQLite.
    private func fillActionIndex(_ texts: [String]) async throws {
        try await ensureCanonicalAttachment()
        try checkEmbeddingConvergence()
        guard let storage, let embedder else { throw MemoryV2Error.storageUnavailable }
        let disk = storage
        try checkEmbeddingConvergence()
        let fill = Task.detached(priority: .utility) {
            let epoch = try embedder.embeddingEpoch
            let byHash = Dictionary(texts.map { (Self.actionTextHash($0), $0) }, uniquingKeysWith: { first, _ in first })
            let dimensions = embedder.dimensions
            let index = try await disk.actionEmbeddingIndex(epoch: epoch)
            let indexed = index.vectors.filter { $0.value.count == dimensions }
            let failures = index.failures
            try await self.checkEmbeddingConvergence()
            let missing = byHash.keys.filter { indexed[$0] == nil && failures[$0] == nil }.sorted()
            for start in stride(from: 0, to: missing.count, by: 8) {
                let hashes = Array(missing[start..<min(start + 8, missing.count)])
                let texts = try hashes.map { hash in
                    guard let text = byHash[hash] else {
                        throw MemoryV2Error.underlying("An action index source is missing for \(hash).")
                    }
                    return text
                }
                let batch = try await embedder.embedItemsWithEpoch(texts)
                try await self.checkEmbeddingConvergence()
                guard batch.epoch == epoch, try embedder.embeddingEpoch == epoch else {
                    await self.requestActionIndexUpdate()
                    throw MemoryV2Error.underlying("The MemoryV2 action index changed epoch while updating.")
                }
                guard batch.items.count == hashes.count else {
                    throw MemoryV2Error.underlying("Action search received unusable vectors from the memory search model.")
                }
                for (hash, item) in zip(hashes, batch.items) {
                    switch item {
                    case .vector(let vector): try VectorMath.requireUsable(vector, dimensions: dimensions)
                    case .unembeddable(let reason): nativeLog("[action-index] unembeddable %@: %@", hash, reason)
                    }
                }
                // Each chunk lands as it finishes, so an interrupted fill keeps its progress.
                try await disk.writeActionEmbeddings(Dictionary(uniqueKeysWithValues: zip(hashes, batch.items)), epoch: epoch)
                try await self.checkEmbeddingConvergence()
            }
            // Keep all content-addressed vectors in the active epoch so changing action sets cannot discard needed vectors; retire only other epochs.
            try await disk.writeActionEmbeddings([:], epoch: epoch, retaining: Set(indexed.keys).union(failures.keys).union(byHash.keys))
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
            OrganPulse.record("embedding_warmup", .held, note: "memory store not attached")
            return
        }
        nativeLog("""
            [embedding-warmup] snapshot: mode=\(snapshot.mode) backend=requested:\(snapshot.requestedBackend)/effective:\(snapshot.effectiveBackend) \
            coreMLLoaded=\(snapshot.coreMLLoaded) modelLoadable=\(snapshot.modelLoadable) resourcesAvailable=\(snapshot.coreMLResourcesAvailable) \
            modelId=\(snapshot.modelId)
            """)
        if snapshot.coreMLLoaded {
            nativeLog("[embedding-warmup] SKIP: already loaded by another path")
            OrganPulse.record("embedding_warmup", .nothing, note: "already loaded")
            return
        }
        // Attempt the actual load rather than treating a disk probe as authority; surface its named failure.
        nativeLog("[embedding-warmup] attempting load — modelLoadable=\(snapshot.modelLoadable)")
        do {
            try await warmUpEmbedder()
            nativeLog("[embedding-warmup] SUCCESS: bge-large-en-v1.5 eagerly warmed for Fast mode")
            OrganPulse.record("embedding_warmup", .worked, note: "embedder loaded")
            let after = embeddingRuntimeSnapshot()
            nativeLog("""
                [embedding-warmup] post-load snapshot: coreMLLoaded=\(after?.coreMLLoaded ?? false) effectiveBackend=\(after?.effectiveBackend ?? "nil")
                """)
        } catch {
            nativeLog("[embedding-warmup] FAILED: \(error.localizedDescription)")
            OrganPulse.record("embedding_warmup", error is CancellationError ? .stopped : .failed, note: error.localizedDescription)
        }
    }

    public func configureEmbeddingBackendAndReindex(enabled: Bool) async throws {
        try await ensureCanonicalAttachment()
        guard let managed = embedder as? ManagedEmbeddingProvider else {
            throw MemoryV2Error.underlying("embedding runtime is not configurable")
        }
        let candidate = try managed.prepareBackend(enabled: enabled)
        _ = try await reindexMemoryEmbeddings(using: candidate)
        // The epoch owner has committed a complete space. Publish selection only now; a failed build never writes configuration to undo later.
        try await managed.setBackend(enabled: enabled)
        requestActionIndexUpdate()
    }
}
