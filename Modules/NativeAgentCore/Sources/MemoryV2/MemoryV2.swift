import Foundation
import NativeAgentCore
import PersistenceCore
import Synchronization
import NativeAgentShared
// Blueprint: | `MemoryV2.swift` | `SwiftNativeMemoryV2` actor; `emitDiagnostic` |

// MARK: - Subsystem #8+9: MemoryV2
//
// Swift-native memory surface. The production factory returns a shared actor
// wired to SQLite storage plus CoreML-or-mock embeddings; the bare initializer
// is retained for tests that intentionally assert missing storage fails closed.

// MARK: - MemoryRecord

/// Preserve on-disk memory keys losslessly, including unknown fields in `extras`.
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        func str(_ k: String) throws -> String? {
            return try c.decodeIfPresent(String.self, forKey: JSONKey(k))
        }
        func dbl(_ k: String) throws -> Double? {
            return try c.decodeIfPresent(Double.self, forKey: JSONKey(k))
        }
        func intV(_ k: String) throws -> Int? {
            return try c.decodeIfPresent(Int.self, forKey: JSONKey(k))
        }
        func boolV(_ k: String) throws -> Bool? {
            return try c.decodeIfPresent(Bool.self, forKey: JSONKey(k))
        }
        func arr(_ k: String) throws -> [String]? {
            return try c.decodeIfPresent([String].self, forKey: JSONKey(k))
        }
        func jv(_ k: String) throws -> JSONValue? {
            return try c.decodeIfPresent(JSONValue.self, forKey: JSONKey(k))
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
        var unknown = c.unknownFields(excluding: Self.knownKeys)
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
        var c = encoder.container(keyedBy: JSONKey.self)
        try c.encode(id, forKey: JSONKey("id"))
        try c.encode(text, forKey: JSONKey("text"))
        try c.encodeIfPresent(layer, forKey: JSONKey("layer"))
        try c.encodeIfPresent(memoryKind, forKey: JSONKey("memoryKind"))
        try c.encodeIfPresent(personaId, forKey: JSONKey("personaId"))
        try c.encodeIfPresent(lifecycle, forKey: JSONKey("lifecycle"))
        try c.encode(createdAt, forKey: JSONKey("createdAt"))
        try c.encodeIfPresent(updatedAt, forKey: JSONKey("updatedAt"))
        try c.encodeIfPresent(sourceRunId, forKey: JSONKey("sourceRunId"))
        try c.encodeIfPresent(status, forKey: JSONKey("status"))
        try c.encodeIfPresent(pinned, forKey: JSONKey("pinned"))
        try c.encodeIfPresent(confidence, forKey: JSONKey("confidence"))
        try c.encodeIfPresent(importance, forKey: JSONKey("importance"))
        try c.encodeIfPresent(tags, forKey: JSONKey("tags"))
        try c.encodeIfPresent(schemaVersion, forKey: JSONKey("schemaVersion"))
        try c.encodeIfPresent(sourceQuality, forKey: JSONKey("sourceQuality"))
        try c.encodeIfPresent(lastUsedAt, forKey: JSONKey("lastUsedAt"))
        try c.encodeIfPresent(decay, forKey: JSONKey("decay"))
        try c.encodeIfPresent(correction, forKey: JSONKey("correction"))
        try c.encodeIfPresent(correctionHistory, forKey: JSONKey("correctionHistory"))
        try c.encodeIfPresent(provenance, forKey: JSONKey("provenance"))
        try c.encodeIfPresent(validFrom, forKey: JSONKey("validFrom"))
        try c.encodeIfPresent(validTo, forKey: JSONKey("validTo"))
        try c.encodeIfPresent(observedAt, forKey: JSONKey("observedAt"))
        try c.encodeIfPresent(evidence, forKey: JSONKey("evidence"))
        try c.encodeUnknownFields(extras, excluding: Self.knownKeys)
    }
}

/// A recall search-result row; unknown keys are preserved in `extras`.
public struct MemoryRecallHit: Sendable, Codable, Equatable {
    public var score: Double
    public var sessionId: String?
    public var role: String?
    public var ts: String?
    public var preview: String
    /// Sentence-safe capped full memory text; nil when the producer supplies only a preview.
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
    case storageUnavailable
    case underlying(String)

    static func rejectedCandidate(_ reason: String, effects: ToolFailureError.Effects = .none) -> ToolFailureError {
        ToolFailureError("Not durable memory: \(reason)", effects: effects,
            code: "memory_candidate_rejected", status: .refused,
            instruction: "Keep only a durable fact, preference, decision or experience; do not resubmit this rejected candidate.", recovery: .terminal)
    }

    static func forgottenContent(_ reason: String, effects: ToolFailureError.Effects = .none) -> ToolFailureError {
        ToolFailureError(reason, effects: effects, code: "memory_tombstoned", status: .refused,
            instruction: "Leave forgotten content forgotten; do not resubmit it or a paraphrase.", recovery: .terminal)
    }

    static func staleSupersession(_ reason: String) -> ToolFailureError {
        ToolFailureError(reason, effects: .none,
            nextCall: ToolFailureError.call("app", ["action": .string("memory.list")]),
            code: "memory_supersession_stale", status: .refused,
            instruction: "Read current memories and stage a newly reviewed replacement; do not resubmit the stale proposal.", recovery: .inspect)
    }

    public var failure: ToolFailureError {
        switch self {
        case .invalidQuery:
            return ToolFailureError("Memory text or query is empty.", argumentPath: "text / query", accepted: "nonempty text",
                effects: .none, nextCall: ToolFailureError.call("app", ["find": .string("memory")]), code: "memory_text_empty", status: .refused,
                instruction: "Supply nonempty text in the original call.", recovery: .correctArguments)
        case .recordNotFound:
            return ToolFailureError("The requested memory record or proposal is unavailable.", effects: .none,
                nextCall: ToolFailureError.call("app", ["page": .string("memories")]),
                code: "memory_record_unavailable", instruction: "Read current memories and pending proposals before choosing an id.", recovery: .inspect)
        case .storageUnavailable:
            return Self.storeFailure("The memory store is unavailable.", code: "memory_store_unavailable")
        case .underlying(let m):
            return ToolFailureError(m, effects: .unknown,
                nextCall: ToolFailureError.call("app", ["page": .string("memories")]),
                code: "memory_operation_failed", instruction: "Inspect the reported cause before repeating this memory operation.", recovery: .inspect)
        }
    }

    static func storeFailure(_ detail: String, code: String) -> ToolFailureError {
        ToolFailureError(detail, effects: .unknown, owner: "memory store",
            nextCall: ToolFailureError.call("app", ["page": .string("memories")]), code: code,
            instruction: "Read memory diagnostics; repair the reported cause without deleting saved memories.")
    }

    /// Non-tool readers receive the same cause, fix and lever as tool readers.
    static func describe(_ failure: ToolFailureError) -> String {
        [failure.code, failure.message, failure.instruction,
         failure.nextCall.map { "Call: \($0)" } ?? failure.tap.map { "Control: \($0)" }
            ?? failure.argumentPath.map { "Argument: \($0)" }]
            .compactMap { $0 }.joined(separator: " ")
    }

    public var errorDescription: String? { Self.describe(failure) }
}

// MARK: - SwiftNative impl

/// SwiftNative MemoryV2 actor. Use ``SwiftNativeMemoryV2.shared``
/// for production so storage/embedder are wired.
public actor SwiftNativeMemoryV2 {
    // Embedder (Core ML bge-large-en-v1.5 in production, explicit mock for development)
    // plus SQLite-backed MemoryStorage. Optional so tests can construct an
    // unwired actor and assert it fails closed.
    internal var embedder: (any EmbeddingProvider)?
    internal var storage: MemoryStorage?
    internal var canonicalDataRoot: URL?
    internal var canonicalAttachmentReady: Task<Void, Never>?
    internal var userProjectionBinding: (dataRoot: URL, personaRoot: URL?, debounceInterval: TimeInterval)?
    internal var memoryProjectionsStopped = false
    var actionIndexSource: (@Sendable () async throws -> [String])?
    var actionIndexWatcher: FileChangeWatcher?
    var actionIndexObservers: ObservationNotifications?
    var actionIndexUpdate: Task<Void, Never>?
    var actionIndexDirty = false
    var actionIndexFailure: String?
    /// Terminal engine lifecycle gate, shared by both convergence flights.
    var embeddingConvergenceStopped = false
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
        actionIndexWatcher?.cancel()
        actionIndexUpdate?.cancel()
        embeddingEpochReconcile?.cancel()
    }

    internal init(canonicalDataRoot: URL) {
        self.canonicalDataRoot = canonicalDataRoot
        self.embedder = ManagedEmbeddingProvider(dataRoot: canonicalDataRoot)
        self.storage = nil
    }

    public init(
        embedder: any EmbeddingProvider,
        storage: MemoryStorage
    ) {
        self.embedder = embedder
        self.storage = storage
    }

    public func listMemory(kind: String?) async throws -> [MemoryRecord] {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        return try await storage.listMemories(persona: nil, status: nil, limit: nil)
            .filter { MemoryLifecycle.isRecallEligible($0.lifecycle)
                && (kind == nil || MemoryRecallScoring.kind(of: $0.metadata) == kind) }
            .map(MemoryRecord.init(stored:))
    }

    /// The rows behind a turn's chosen atoms, by id, so the turn never speaks
    /// one the store retired or narrowed after it was compiled.
    public func memoryRecords(ids: [String]) async throws -> [MemoryRecord] {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        return try await storage.memories(ids: ids).map(MemoryRecord.init(stored:))
    }


    public func updateMemory(id: String, update: JSONValue) async throws -> MemoryRecord {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        var existing: MemoryRecord?
        if case .object(let patch) = update, patch["text"] != nil || patch["content"] != nil {
            guard let row = try await storage.memory(id: id) else {
                throw MemoryV2Error.recordNotFound
            }
            existing = MemoryRecord(stored: row)
        }
        let update = Self.sanitizedMemoryUpdate(
            update, existingKind: existing.flatMap { $0.memoryKind ?? MemoryRecallScoring.kind(of: $0.extras) })
        let newText = Self.patchText(update)
        var newEmbedding: (vector: [Float], epoch: MemoryEmbeddingEpoch)?
        if let newText { newEmbedding = try await residentWriteEmbedding(newText) }
        // New words are checked against what was forgotten by their vector
        // before they replace the old ones; with the model cold they would
        // replace them unchecked and a late match would archive both. The old
        // words stay until the vector can be had.
        if let newText, newEmbedding == nil, newText != existing?.text {
            requestEmbeddingEpochReconcile()
            throw MemoryStorageError.searchFailure("Memory unchanged: the memory search model is not loaded to check new wording against forgotten content.",
                code: "memory_search_model_not_loaded", instruction: "Read Doctor and repair any reported model load error before rewriting.")
        }
        guard let updated = try await storage.updateMemory(
            id: id,
            patch: MemoryPatch(update: update, embedding: newEmbedding?.vector, epoch: newEmbedding?.epoch)
        ) else { throw MemoryV2Error.recordNotFound }
        return MemoryRecord(stored: updated)
    }

    /// Foreground callers that distinguish a missing row use the atomic
    /// deletion result. Derived indexes catch up on their own; a turn leaves
    /// a retired memory out of published context.
    public func deleteMemoryIfPresent(id: String) async throws -> Bool {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        let deleted = try await storage.deleteMemory(id: id)
        if deleted { requestEmbeddingEpochReconcile() }
        return deleted
    }

    /// Embedder vector dimensionality, when wired.
    public func embedderDimensions() -> Int? { embedder?.dimensions }

    public func embeddingEpoch() -> MemoryEmbeddingEpoch? { embedder?.embeddingEpoch }

    /// A write's vector from the resident model only: a cold model is never
    /// loaded on a write Nil means the row lands with its vector owed and the
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
        extras["vector_pending"] = .string("Saved; memory search cannot find it until the memory search model supplies its vector and admission checks finish.")
        record.extras = .object(extras)
        return record
    }

    /// The vector space a turn can query now. Nil while the managed model is
    /// cold: a read names that instead of loading the model itself.
    func residentEmbeddingEpoch() -> MemoryEmbeddingEpoch? {
        guard let managed = embedder as? ManagedEmbeddingProvider else { return embedder?.embeddingEpoch }
        return managed.residentEmbeddingEpoch
    }

    /// The resident vector space's identity, or nil while cold. Vectors kept
    /// outside memory (her habits' examples) are valid only within it.
    public func warmEmbeddingEpoch() -> String? {
        residentEmbeddingEpoch()?.rawValue
    }

    /// Vectors from the already-resident model, or nil; never loads.
    public func embedIfWarm(_ texts: [String], requireFullText: Bool = false) async -> [[Float]]? {
        guard let managed = embedder as? ManagedEmbeddingProvider else { return nil }
        return await managed.embedIfResident(texts, requireFullText: requireFullText)
    }

    func coversCompleteTextsIfWarm(_ texts: [String]) -> Bool? {
        (embedder as? ManagedEmbeddingProvider)?.coversCompleteTextsIfResident(texts)
    }

    public func managedEmbeddingRuntime() async throws -> ManagedEmbeddingProvider {
        guard let managed = embedder as? ManagedEmbeddingProvider else { throw MemoryV2Error.storageUnavailable }
        return managed
    }

    public func embeddingRuntimeSnapshot() -> EmbeddingRuntimeSnapshot? {
        guard let embedder else { return nil }
        if let managed = embedder as? ManagedEmbeddingProvider {
            return managed.snapshot()
        }
        // A fail-closed embedder reports not loaded.
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
            unloadCount: 0
        )
    }

    /// Warm the embedder at launch with a trivial embed call when Fast mode is selected.
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

    /// A turn's message (and its other voice) as a search query: the model's
    /// query form, scored against vectors from `embedForDerivedContextWithEpoch`.
    public func embedQueriesWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch {
        guard let embedder else { throw MemoryV2Error.storageUnavailable }
        guard !texts.isEmpty else {
            return MemoryEmbeddingBatch(epoch: embedder.embeddingEpoch, vectors: [])
        }
        return try await embedder.embedQueriesWithEpoch(texts)
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
        guard let storage else {
            throw MemoryV2Error.storageUnavailable
        }
        return try await storage.embeddingEpochState()
    }

    /// Embeds every canonical memory/proposal/tombstone in bounded
    /// batches, off the chat path, then switches the entire corpus in one
    /// transaction. Any content drift or provider-epoch drift aborts before
    /// canonical vectors change.
    public func reindexAllMemoryEmbeddingsForCurrentProvider(
        batchSize: Int = 64
    ) async throws -> MemoryEmbeddingEpochActivationReport {
        guard let embedder else { throw MemoryV2Error.storageUnavailable }
        return try await reindexMemoryEmbeddings(using: embedder, batchSize: batchSize)
    }

    /// A prepared provider can build its space without publishing a selection.
    func reindexMemoryEmbeddings(
        using embedder: any EmbeddingProvider, batchSize: Int = 64
    ) async throws -> MemoryEmbeddingEpochActivationReport {
        try await ensureCanonicalAttachment()
        try Task.checkCancellation()
        guard let concreteStorage = storage else {
            throw MemoryV2Error.storageUnavailable
        }
        let invocation = UUID()
        embeddingReindexID = invocation
        var reusable = embeddingRetryVectors
        embeddingRetryVectors = [:]
        try Task.checkCancellation()
        let corpus = try await concreteStorage.embeddingCorpusSnapshot()
        try Task.checkCancellation()
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
            try Task.checkCancellation()
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
                try Task.checkCancellation()
                guard batch.vectors.count == rows.count else {
                    throw MemoryV2Error.underlying(
                        "The memory search model returned \(batch.vectors.count)/\(rows.count) candidate vectors."
                    )
                }
                if let candidateEpoch, candidateEpoch != batch.epoch {
                    throw MemoryV2Error.underlying("The memory search model changed vector spaces while building the index.")
                }
                candidateEpoch = batch.epoch
                for (row, vector) in zip(rows, batch.vectors) {
                    vectors[EmbeddingRetryKey(epoch: batch.epoch, row: row)] = vector
                }
            }
            staged = try corpus.map { row in
                guard let vector = vectors[EmbeddingRetryKey(epoch: providerEpoch, row: row)] else {
                    throw MemoryV2Error.underlying("A staged memory embedding is missing for \(row.id).")
                }
                return MemoryEmbeddingStagedRow(row: row, vector: vector)
            }
        }
        guard let candidateEpoch else {
            throw MemoryV2Error.underlying("The memory search model did not identify its vector space.")
        }
        try Task.checkCancellation()
        guard embedder.embeddingEpoch == candidateEpoch else {
            throw MemoryV2Error.underlying("The memory search model changed vector spaces while building the index.")
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
        guard let embedder else {
            throw MemoryStorageError.searchFailure("No memory search model is attached.",
                code: "memory_search_model_unavailable", instruction: "Inspect Doctor's memory search model findings before searching again.")
        }
        let batch = try await embedder.embedWithEpoch([text])
        guard let vector = batch.vectors.first else {
            throw MemoryStorageError.searchFailure("The memory search model returned no vectors.",
                code: "memory_search_vectors_missing", instruction: "Inspect Doctor's model findings; repair the missing vectors before writing memory again.")
        }
        return (vector, batch.epoch)
    }

    /// Only a patch carrying new `text`/`content` needs a vector; otherwise
    /// the existing embedding stays valid.
    static func patchText(_ update: JSONValue) -> String? {
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
