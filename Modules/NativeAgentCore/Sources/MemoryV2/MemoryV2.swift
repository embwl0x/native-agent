import Foundation
import NativeAgentCore
import PersistenceCore
import Synchronization

// MARK: - Subsystem #8+9: MemoryV2
//
// Swift-native memory surface. The production factory returns a shared actor
// wired to SQLite storage plus CoreML-or-mock embeddings; the bare initializer
// is retained for tests that intentionally assert missing storage fails closed.

// MARK: - MemoryRecord

/// Mirrors the daemon's on-disk memory dict losslessly. The typed fields
/// match the actual keys emitted by `Runtime.add_memory` /
/// `Runtime.update_memory` (text/layer/sourceRunId/createdAt/...) plus the
/// v2 metadata that consolidation / hygiene attach
/// (schemaVersion/memoryKind/sourceQuality/decay/correction/
/// correctionHistory/lastUsedAt). Anything else the daemon ships rides in
/// `extras` so this struct doesn't have to change every time Python adds a
/// key.
public struct MemoryRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var layer: String?
    public var memoryKind: String?
    public var personaId: String?
    public var lifecycle: String?
    public var createdAt: String
    public var updatedAt: String?
    public var sourceRunId: String?
    public var status: String?
    public var pinned: Bool?
    public var confidence: Double?
    public var importance: Double?
    public var tags: [String]?
    public var schemaVersion: Int?
    public var sourceQuality: Double?
    public var lastUsedAt: String?
    public var decay: JSONValue?
    public var correction: JSONValue?
    public var correctionHistory: JSONValue?
    public var provenance: JSONValue?
    /// Optional bitemporal/evidence semantics. These fields are descriptive
    /// canonical data with provenance; they do not grant authority or change
    /// ranking until a separately gated policy consumes them.
    public var validFrom: String?
    public var validTo: String?
    public var observedAt: String?
    public var evidence: JSONValue?
    public var extras: JSONValue?

    public init(
        id: String,
        text: String,
        layer: String? = nil,
        memoryKind: String? = nil,
        personaId: String? = nil,
        lifecycle: String? = nil,
        createdAt: String,
        updatedAt: String? = nil,
        sourceRunId: String? = nil,
        status: String? = nil,
        pinned: Bool? = nil,
        confidence: Double? = nil,
        importance: Double? = nil,
        tags: [String]? = nil,
        schemaVersion: Int? = nil,
        sourceQuality: Double? = nil,
        lastUsedAt: String? = nil,
        decay: JSONValue? = nil,
        correction: JSONValue? = nil,
        correctionHistory: JSONValue? = nil,
        provenance: JSONValue? = nil,
        validFrom: String? = nil,
        validTo: String? = nil,
        observedAt: String? = nil,
        evidence: JSONValue? = nil,
        extras: JSONValue? = nil
    ) {
        self.id = id
        self.text = text
        self.layer = layer
        self.memoryKind = memoryKind
        self.personaId = personaId
        self.lifecycle = lifecycle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceRunId = sourceRunId
        self.status = status
        self.pinned = pinned
        self.confidence = confidence
        self.importance = importance
        self.tags = tags
        self.schemaVersion = schemaVersion
        self.sourceQuality = sourceQuality
        self.lastUsedAt = lastUsedAt
        self.decay = decay
        self.correction = correction
        self.correctionHistory = correctionHistory
        self.provenance = provenance
        self.validFrom = validFrom
        self.validTo = validTo
        self.observedAt = observedAt
        self.evidence = evidence
        self.extras = extras
    }

    private static let knownKeys: Set<String> = [
        "id", "text", "layer", "memoryKind", "personaId", "lifecycle", "createdAt", "updatedAt",
        "sourceRunId", "status", "pinned", "confidence", "importance", "tags",
        "schemaVersion", "sourceQuality", "lastUsedAt", "decay", "correction",
        "correctionHistory", "provenance", "validFrom", "validTo", "observedAt", "evidence", "extras",
    ]

    private struct AnyKey: CodingKey, Hashable {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { self.stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func str(_ k: String) throws -> String? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(String.self, forKey: key)
        }
        func dbl(_ k: String) throws -> Double? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(Double.self, forKey: key)
        }
        func intV(_ k: String) throws -> Int? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(Int.self, forKey: key)
        }
        func boolV(_ k: String) throws -> Bool? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(Bool.self, forKey: key)
        }
        func arr(_ k: String) throws -> [String]? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent([String].self, forKey: key)
        }
        func jv(_ k: String) throws -> JSONValue? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(JSONValue.self, forKey: key)
        }

        self.id = (try str("id")) ?? ""
        self.text = (try str("text")) ?? ""
        self.layer = try str("layer")
        self.memoryKind = try str("memoryKind")
        self.personaId = try str("personaId")
        self.lifecycle = try str("lifecycle")
        self.createdAt = (try str("createdAt")) ?? ""
        self.updatedAt = try str("updatedAt")
        self.sourceRunId = try str("sourceRunId")
        self.status = try str("status")
        self.pinned = try boolV("pinned")
        self.confidence = try dbl("confidence")
        self.importance = try dbl("importance")
        self.tags = try arr("tags")
        self.schemaVersion = try intV("schemaVersion")
        self.sourceQuality = try dbl("sourceQuality")
        self.lastUsedAt = try str("lastUsedAt")
        self.decay = try jv("decay")
        self.correction = try jv("correction")
        self.correctionHistory = try jv("correctionHistory")
        self.provenance = try jv("provenance")
        self.validFrom = try str("validFrom")
        self.validTo = try str("validTo")
        self.observedAt = try str("observedAt")
        self.evidence = try jv("evidence")

        // Capture every unknown key into extras so forward-compat survives.
        var unknown: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let v = try? c.decode(JSONValue.self, forKey: key) {
                unknown[key.stringValue] = v
            }
        }
        if let explicit = try jv("extras") {
            if case .object(let obj) = explicit {
                for (k, v) in obj { unknown[k] = v }
            } else {
                unknown["_extras_value"] = explicit
            }
        }
        self.extras = unknown.isEmpty ? nil : .object(unknown)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(text, forKey: AnyKey("text"))
        try c.encodeIfPresent(layer, forKey: AnyKey("layer"))
        try c.encodeIfPresent(memoryKind, forKey: AnyKey("memoryKind"))
        try c.encodeIfPresent(personaId, forKey: AnyKey("personaId"))
        try c.encodeIfPresent(lifecycle, forKey: AnyKey("lifecycle"))
        try c.encode(createdAt, forKey: AnyKey("createdAt"))
        try c.encodeIfPresent(updatedAt, forKey: AnyKey("updatedAt"))
        try c.encodeIfPresent(sourceRunId, forKey: AnyKey("sourceRunId"))
        try c.encodeIfPresent(status, forKey: AnyKey("status"))
        try c.encodeIfPresent(pinned, forKey: AnyKey("pinned"))
        try c.encodeIfPresent(confidence, forKey: AnyKey("confidence"))
        try c.encodeIfPresent(importance, forKey: AnyKey("importance"))
        try c.encodeIfPresent(tags, forKey: AnyKey("tags"))
        try c.encodeIfPresent(schemaVersion, forKey: AnyKey("schemaVersion"))
        try c.encodeIfPresent(sourceQuality, forKey: AnyKey("sourceQuality"))
        try c.encodeIfPresent(lastUsedAt, forKey: AnyKey("lastUsedAt"))
        try c.encodeIfPresent(decay, forKey: AnyKey("decay"))
        try c.encodeIfPresent(correction, forKey: AnyKey("correction"))
        try c.encodeIfPresent(correctionHistory, forKey: AnyKey("correctionHistory"))
        try c.encodeIfPresent(provenance, forKey: AnyKey("provenance"))
        try c.encodeIfPresent(validFrom, forKey: AnyKey("validFrom"))
        try c.encodeIfPresent(validTo, forKey: AnyKey("validTo"))
        try c.encodeIfPresent(observedAt, forKey: AnyKey("observedAt"))
        try c.encodeIfPresent(evidence, forKey: AnyKey("evidence"))
        if case .object(let obj)? = extras {
            for (k, v) in obj where !Self.knownKeys.contains(k) {
                try c.encode(v, forKey: AnyKey(k))
            }
        }
    }
}

/// One hit from `/v1/memory/recall`. Daemon emits search-result rows
/// (score / session_id / role / ts / preview / source / rankingSignals), NOT
/// full MemoryRecord dicts. Unknown keys land in `extras`.
public struct MemoryRecallHit: Sendable, Codable, Equatable {
    public var score: Double
    public var sessionId: String?
    public var role: String?
    public var ts: String?
    public var preview: String
    /// U3 wave-1 item 1: the (sentence-safe capped) FULL memory text. The
    /// felt "memory truncation" was read-side — recall surfaced only the
    /// 200-char preview. `preview` stays for compactness; consumers that
    /// want the real content read this. nil on producers that don't carry
    /// full text (e.g. KG fallback rows).
    public var content: String?
    public var source: String?
    public var rankingSignals: JSONValue?
    public var extras: JSONValue?

    public init(
        score: Double,
        sessionId: String? = nil,
        role: String? = nil,
        ts: String? = nil,
        preview: String,
        content: String? = nil,
        source: String? = nil,
        rankingSignals: JSONValue? = nil,
        extras: JSONValue? = nil
    ) {
        self.score = score
        self.sessionId = sessionId
        self.role = role
        self.ts = ts
        self.preview = preview
        self.content = content
        self.source = source
        self.rankingSignals = rankingSignals
        self.extras = extras
    }

    enum CodingKeys: String, CodingKey {
        case score
        case sessionId = "session_id"
        case role
        case ts
        case preview
        case content
        case source
        case rankingSignals
        case extras
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        self.sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        self.role = try c.decodeIfPresent(String.self, forKey: .role)
        self.ts = try c.decodeIfPresent(String.self, forKey: .ts)
        self.preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        self.content = try c.decodeIfPresent(String.self, forKey: .content)
        self.source = try c.decodeIfPresent(String.self, forKey: .source)
        self.rankingSignals = try c.decodeIfPresent(JSONValue.self, forKey: .rankingSignals)
        self.extras = try c.decodeIfPresent(JSONValue.self, forKey: .extras)
    }
}

// MARK: - Errors

public enum MemoryV2Error: Error, LocalizedError {
    case invalidQuery
    case recordNotFound
    case invalidResponse(status: Int)
    case storageUnavailable
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "memory: invalid query"
        case .recordNotFound:
            return "memory: record not found"
        case .invalidResponse(let status):
            return "memory: native implementation returned unexpected status \(status)"
        case .storageUnavailable:
            return "memory: storage unavailable"
        case .underlying(let m):
            return "memory: \(m)"
        }
    }
}

// MARK: - SwiftNative impl

/// SwiftNative MemoryV2 actor. Use ``SwiftNativeMemoryV2.shared``
/// for production so storage/embedder are wired.
public actor SwiftNativeMemoryV2 {
    // Embedder (Core ML MiniLM in production, MockEmbeddingProvider in tests)
    // plus SQLite-backed MemoryStorage. Optional so tests can construct an
    // unwired actor and assert it fails closed.
    internal var embedder: (any EmbeddingProvider)?
    internal var storage: MemoryStorageBridge?
    internal var canonicalDataRoot: URL?
    internal var canonicalAttachmentReady: Task<Void, Never>?
    internal var userProjectionBinding: (dataRoot: URL, personaRoot: URL?, debounceInterval: TimeInterval)?
    var actionIndexSource: (@Sendable () async throws -> [String])?
    var actionIndexWatcher: FileChangeWatcher?
    let actionIndexObservers = Mutex<[NSObjectProtocol]>([])
    var actionIndexUpdate: Task<Void, Never>?
    var actionIndexDirty = false
    var actionIndexFailure: String?
    private struct EmbeddingRetryKey: Hashable {
        let epoch: String
        let kind: String
        let id: String
        let contentHash: String

        init(epoch: MemoryEmbeddingEpoch, row: MemoryEmbeddingCorpusRow) {
            self.epoch = epoch.rawValue
            kind = row.kind.rawValue
            id = row.id
            contentHash = row.contentHash
        }
    }
    // Reuse candidates only while their provider epoch and canonical content match.
    private var embeddingRetryVectors: [EmbeddingRetryKey: [Float]] = [:]
    private var embeddingReindexID: UUID?
    var embeddingEpochReconcile: Task<Bool, Never>?
    var embeddingEpochDirty = false

    internal func emitDiagnostic(_ message: String) {
        nativeLog("%@", message)
    }

    public init() {
        self.embedder = nil
        self.storage = nil
    }

    deinit {
        actionIndexObservers.withLock { $0.forEach { NotificationCenter.default.removeObserver($0) } }
        actionIndexWatcher?.cancel()
    }

    internal init(canonicalDataRoot: URL) {
        self.canonicalDataRoot = canonicalDataRoot
        self.embedder = ManagedEmbeddingProvider(dataRoot: canonicalDataRoot)
        self.storage = nil
    }

    public init(
        embedder: any EmbeddingProvider,
        storage: MemoryStorageBridge
    ) {
        self.embedder = embedder
        self.storage = storage
    }

    public func listMemory(kind: String?) async throws -> [MemoryRecord] {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        return try await storage.listMemory(kind: kind)
    }

    /// The rows behind a turn's chosen atoms, by id, so the turn never speaks
    /// one the store retired or narrowed after it was compiled.
    public func memoryRecords(ids: [String]) async throws -> [MemoryRecord] {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        return try await storage.lookupMemoryRecords(ids: ids)
    }


    public func updateMemory(id: String, update: JSONValue) async throws -> MemoryRecord {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        let existingKind: String?
        if case .object(let patch) = update, Self.patchKind(patch) == nil,
           patch["text"] != nil || patch["content"] != nil {
            guard let existing = try await storage.lookupMemoryRecord(id: id) else {
                throw MemoryV2Error.recordNotFound
            }
            existingKind = existing.memoryKind ?? MemoryRecallScoring.kind(of: existing.extras)
        } else {
            existingKind = nil
        }
        let update = Self.sanitizedMemoryUpdate(update, existingKind: existingKind)
        let newText = Self.patchText(update)
        var newEmbedding: (vector: [Float], epoch: MemoryEmbeddingEpoch)?
        if let newText { newEmbedding = try await residentWriteEmbedding(newText) }
        try await gateUpdatedContentAgainstTombstones(update: update, embedding: newEmbedding, storage: storage)
        let updated = try await storage.updateMemory(
            id: id,
            patch: update,
            newEmbedding: newEmbedding?.vector,
            embeddingEpoch: newEmbedding?.epoch
        )
        return newText != nil && newEmbedding == nil ? owedVector(updated) : updated
    }

    /// Edits go through the same denylist gates as inserts: without this, a
    /// "correction" could rewrite an existing memory INTO a deleted/rejected
    /// fact (gpt-5.5 wave1 finding 2). Only fires when the patch changes
    /// text/content (embedding non-nil — reuses the vector already computed).
    private func gateUpdatedContentAgainstTombstones(
        update: JSONValue,
        embedding: (vector: [Float], epoch: MemoryEmbeddingEpoch)?,
        storage: MemoryStorageBridge
    ) async throws {
        guard let embedding, case .object(let obj) = update else { return }
        let newText: String? = {
            if case .string(let s)? = obj["text"] { return s }
            if case .string(let s)? = obj["content"] { return s }
            return nil
        }()
        if let newText, try await storage.isTombstoned(content: newText) {
            throw MemoryV2Error.underlying("tombstoned: updated content matches a rejection denylist entry")
        }
        if try await storage.matchesTombstone(
            embedding: embedding.vector,
            embeddingEpoch: embedding.epoch
        ) {
            throw MemoryV2Error.underlying("tombstoned: updated content is a paraphrase of a rejected claim")
        }
    }

    /// Foreground callers that distinguish a missing row use the atomic
    /// deletion result. Derived indexes catch up on their own; a turn leaves
    /// a retired memory out of published context.
    public func deleteMemoryIfPresent(id: String) async throws -> Bool {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        let deleted = try await storage.deleteMemory(id: id)
        return deleted
    }

    /// Embedder vector dimensionality, when wired.
    public func embedderDimensions() -> Int? { embedder?.dimensions }

    public func embeddingEpoch() -> MemoryEmbeddingEpoch? { embedder?.embeddingEpoch }

    /// A write's vector from the resident model only: a cold model is never
    /// loaded on a write. Nil means the row lands with its vector owed and the
    /// write's record says so (`owedVector`).
    func residentWriteEmbedding(_ text: String) async throws -> (vector: [Float], epoch: MemoryEmbeddingEpoch)? {
        guard residentEmbeddingEpoch() != nil else { return nil }
        return try await embedOneWithEpoch(text)
    }

    /// Called once the vector-less row has committed, so the fill finds it.
    func owedVector(_ record: MemoryRecord) -> MemoryRecord {
        requestEmbeddingEpochReconcile()
        var record = record
        var extras: [String: JSONValue] = [:]
        if case .object(let current)? = record.extras { extras = current }
        extras["vector_pending"] = .string("Saved; its search vector is owed until the memory-search model is resident, then MemoryV2 fills it. Until then semantic recall cannot find it.")
        record.extras = .object(extras)
        return record
    }

    /// The vector space a turn can query now. Nil while the managed model is
    /// cold: a read names that instead of loading the model itself.
    func residentEmbeddingEpoch() -> MemoryEmbeddingEpoch? {
        guard let managed = embedder as? ManagedEmbeddingProvider else { return embedder?.embeddingEpoch }
        return managed.residentEmbeddingEpoch
    }

    /// Phase 5 D: vectors from the already-resident model, or nil. Never loads.
    public func embedIfWarm(_ texts: [String]) async -> [[Float]]? {
        guard let managed = embedder as? ManagedEmbeddingProvider else { return nil }
        return await managed.embedIfResident(texts)
    }

    public func embeddingRuntimeSnapshot() -> EmbeddingRuntimeSnapshot? {
        guard let embedder else { return nil }
        if let managed = embedder as? ManagedEmbeddingProvider {
            return managed.snapshot()
        }
        // 2026-07-21 audit fix: a fail-closed embedder (modelId "fail-closed"
        // — CoreML requested but unloadable, mock not opted in) used to fall
        // into the non-mock branch below and report coreMLLoaded=true /
        // effectiveBackend=coreml while every embed() throws. Report it
        // honestly as not-loaded.
        let isMock = embedder.modelId == "mock"
        let isFailClosed = embedder.modelId == ManagedEmbeddingProvider.failClosedBackend
        let coreMLUp = !isMock && !isFailClosed
        return EmbeddingRuntimeSnapshot(
            requestedBackend: isMock ? ManagedEmbeddingProvider.mockBackend : ManagedEmbeddingProvider.coreMLBackend,
            effectiveBackend: isMock
                ? ManagedEmbeddingProvider.mockBackend
                : (isFailClosed ? ManagedEmbeddingProvider.failClosedBackend : ManagedEmbeddingProvider.coreMLBackend),
            mode: ManagedEmbeddingProvider.performanceMode,
            modelId: embedder.modelId,
            dimensions: embedder.dimensions,
            embeddingEpoch: embedder.embeddingEpoch.rawValue,
            coreMLResourcesAvailable: coreMLUp,
            coreMLLoaded: coreMLUp,
            modelLoadable: coreMLUp,
            lastUsedAt: nil,
            lastLoadedAt: nil,
            lastUnloadedAt: nil,
            unloadReason: nil,
            lastLoadError: nil,
            loadCount: coreMLUp ? 1 : 0,
            unloadCount: 0,
            idleUnloadSeconds: nil
        )
    }

    public func configureEmbeddingBackend(enabled: Bool) async throws {
        guard let managed = embedder as? ManagedEmbeddingProvider else {
            throw MemoryV2Error.underlying("embedding runtime is not configurable")
        }
        try await managed.setBackend(enabled: enabled)
        requestActionIndexUpdate()
    }

    /// 2026-06-07 task #88: force-load the embedder by issuing a trivial
    /// embed call. Used by app launch when the user has Fast mode selected
    /// — without this, Fast mode only kicked in AFTER first use, so the
    /// first chat turn paid the ~6-12s warm-up tax.
    ///
    /// Returns silently if no embedder is wired. If the model is already
    /// resident, the underlying provider's lock-protected fast path still
    /// runs the embed (cheap when warm). Throws through the embedder's
    /// normal fail-closed contract — callers should fail-silent on launch
    /// (the first real use will surface the same error with better
    /// context).
    public func warmUpEmbedder() async throws {
        guard let embedder else { throw MemoryV2Error.storageUnavailable }
        if let managed = embedder as? ManagedEmbeddingProvider {
            try await managed.warmUp()
        } else {
            _ = try await embedder.embed(["warmup"])
        }
    }

    /// Bounded public projection for derived local indexes such as ContextFlow.
    /// MemoryV2 remains the embedding-runtime owner; callers receive vectors
    /// only and cannot mutate memory records or replace the active provider.
    public func embedForDerivedContext(_ texts: [String]) async throws -> [[Float]] {
        guard let embedder else { throw MemoryV2Error.storageUnavailable }
        guard !texts.isEmpty else { return [] }
        return try await embedder.embed(texts)
    }

    public func embedForDerivedContextWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch {
        guard let embedder else { throw MemoryV2Error.storageUnavailable }
        guard !texts.isEmpty else {
            return MemoryEmbeddingBatch(epoch: embedder.embeddingEpoch, vectors: [])
        }
        return try await embedder.embedWithEpoch(texts)
    }

    @discardableResult
    public func releaseEmbeddingMemory(reason: String = "manual release") -> EmbeddingRuntimeSnapshot? {
        guard let managed = embedder as? ManagedEmbeddingProvider else {
            return embeddingRuntimeSnapshot()
        }
        return managed.release(reason: reason)
    }

    public func memoryEmbeddingEpochState() async throws -> MemoryEmbeddingEpochState {
        try await ensureCanonicalAttachment()
        guard let bridge = storage else {
            throw MemoryV2Error.storageUnavailable
        }
        return try await bridge.underlyingStorage().embeddingEpochState()
    }

    /// Embeds every canonical memory/proposal/tombstone in bounded
    /// batches, off the chat path, then switches the entire corpus in one
    /// transaction. Any content drift or provider-epoch drift aborts before
    /// canonical vectors change.
    public func reindexAllMemoryEmbeddingsForCurrentProvider(
        batchSize: Int = 64
    ) async throws -> MemoryEmbeddingEpochActivationReport {
        try await ensureCanonicalAttachment()
        guard let embedder,
              let bridge = storage else {
            throw MemoryV2Error.storageUnavailable
        }
        let invocation = UUID()
        embeddingReindexID = invocation
        var reusable = embeddingRetryVectors
        embeddingRetryVectors = [:]
        let concreteStorage = await bridge.underlyingStorage()
        let corpus = try await concreteStorage.embeddingCorpusSnapshot()
        guard corpus.count <= 50_000 else {
            throw MemoryV2Error.underlying("embedding corpus exceeds bounded activation limit")
        }
        let boundedBatch = min(256, max(1, batchSize))
        var staged: [MemoryEmbeddingStagedRow] = []
        staged.reserveCapacity(corpus.count)
        var candidateEpoch: MemoryEmbeddingEpoch?
        let providerEpoch = embedder.embeddingEpoch
        let liveKeys = Set(corpus.map { EmbeddingRetryKey(epoch: providerEpoch, row: $0) })
        reusable = reusable.filter { liveKeys.contains($0.key) }

        if corpus.isEmpty {
            let probe = try await embedder.embedWithEpoch(["NativeAgent embedding epoch activation"])
            candidateEpoch = probe.epoch
        } else {
            let missing = corpus.filter {
                reusable[EmbeddingRetryKey(epoch: providerEpoch, row: $0)] == nil
            }
            var vectors = reusable
            candidateEpoch = providerEpoch
            for start in stride(from: 0, to: missing.count, by: boundedBatch) {
                try Task.checkCancellation()
                let end = min(missing.count, start + boundedBatch)
                let rows = Array(missing[start..<end])
                let batch = try await embedder.embedWithEpoch(rows.map(\.content))
                guard batch.vectors.count == rows.count else {
                    throw MemoryV2Error.underlying(
                        "embedder returned \(batch.vectors.count)/\(rows.count) candidate vectors"
                    )
                }
                if let candidateEpoch, candidateEpoch != batch.epoch {
                    throw MemoryV2Error.underlying("embedding provider epoch changed during candidate build")
                }
                candidateEpoch = batch.epoch
                for (row, vector) in zip(rows, batch.vectors) {
                    vectors[EmbeddingRetryKey(epoch: batch.epoch, row: row)] = vector
                }
            }
            staged = corpus.map { row in
                MemoryEmbeddingStagedRow(
                    row: row, vector: vectors[EmbeddingRetryKey(epoch: providerEpoch, row: row)]!
                )
            }
        }
        guard let candidateEpoch else {
            throw MemoryV2Error.underlying("embedding provider did not identify its vector space")
        }
        try Task.checkCancellation()
        guard embedder.embeddingEpoch == candidateEpoch else {
            throw MemoryV2Error.underlying("embedding provider epoch changed during candidate build")
        }
        do {
            return try await concreteStorage.activateEmbeddingEpoch(candidateEpoch, staged: staged)
        } catch let error as MemoryStorageError {
            if case .embeddingActivationInvalid(.corpusDrift, _) = error,
               embeddingReindexID == invocation, !Task.isCancelled {
                embeddingRetryVectors = Dictionary(uniqueKeysWithValues: staged.map {
                    (EmbeddingRetryKey(epoch: candidateEpoch, row: $0.row), $0.vector)
                })
            }
            throw error
        }
    }

    // MARK: - internal helpers used by extension methods

    internal func embedOneWithEpoch(
        _ text: String
    ) async throws -> (vector: [Float], epoch: MemoryEmbeddingEpoch) {
        guard let embedder else { throw MemoryV2Error.storageUnavailable }
        let batch = try await embedder.embedWithEpoch([text])
        guard let vector = batch.vectors.first else {
            throw MemoryV2Error.underlying("embedder returned no vectors")
        }
        return (vector, batch.epoch)
    }

    /// Only a patch carrying new `text`/`content` needs a vector; otherwise
    /// the existing embedding stays valid.
    private static func patchText(_ update: JSONValue) -> String? {
        guard case .object(let obj) = update else { return nil }
        if case .string(let s)? = obj["text"] { return s }
        if case .string(let s)? = obj["content"] { return s }
        return nil
    }

    private static func sanitizedMemoryUpdate(_ update: JSONValue, existingKind: String?) -> JSONValue {
        guard case .object(var obj) = update else { return update }
        let kind = patchKind(obj) ?? existingKind
        if case .string(let s)? = obj["text"] {
            obj["text"] = .string(MemoryTextClip.memoryDisplayText(s, kind: kind))
        }
        if case .string(let s)? = obj["content"] {
            obj["content"] = .string(MemoryTextClip.memoryDisplayText(s, kind: kind))
        }
        return .object(obj)
    }

    private static func patchKind(_ obj: [String: JSONValue]) -> String? {
        if case .string(let kind)? = obj["kind"] { return trimmedKind(kind) }
        if case .string(let kind)? = obj["memoryKind"] { return trimmedKind(kind) }
        guard case .object(let meta)? = obj["metadata"],
              case .string(let kind)? = meta["kind"] else {
            return nil
        }
        return trimmedKind(kind)
    }

    private static func trimmedKind(_ kind: String) -> String? {
        let trimmed = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
