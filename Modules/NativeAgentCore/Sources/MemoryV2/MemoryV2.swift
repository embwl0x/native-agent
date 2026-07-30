import Foundation
import NativeAgentCore
import PersistenceCore

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
public struct MemoryRecord: Sendable, Codable, Equatable {
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

// MARK: - MemoryRecallQuery / MemoryRecallHit / MemoryRecallResult

/// Recall query. `kinds` and `tagsFilter` are reserved for a future filtered
/// recall pass. Today's recall honors `q` and `k`; client code can still pass
/// the reserved fields so the wire shape does not change when filtering lights
/// up. `surface` (2026-07-21 audit fix) names the calling surface so the
/// disclosure policy actually gates this lane — leave nil ONLY for genuinely
/// surfaceless internal callers (permits() treats nil as allow-all).
public struct MemoryRecallQuery: Sendable, Codable, Equatable {
    public var query: String
    public var k: Int
    public var kinds: [String]?
    public var tagsFilter: [String]?
    public var surface: String?

    public init(
        query: String,
        k: Int = 10,
        kinds: [String]? = nil,
        tagsFilter: [String]? = nil,
        surface: String? = nil
    ) {
        self.query = query
        self.k = k
        self.kinds = kinds
        self.tagsFilter = tagsFilter
        self.surface = surface
    }

    enum CodingKeys: String, CodingKey {
        case query
        case k
        case kinds
        case tagsFilter = "tags_filter"
        case surface
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.query = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
        self.k = try c.decodeIfPresent(Int.self, forKey: .k) ?? 10
        self.kinds = try c.decodeIfPresent([String].self, forKey: .kinds)
        self.tagsFilter = try c.decodeIfPresent([String].self, forKey: .tagsFilter)
        self.surface = try c.decodeIfPresent(String.self, forKey: .surface)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(query, forKey: .query)
        try c.encode(k, forKey: .k)
        try c.encodeIfPresent(kinds, forKey: .kinds)
        try c.encodeIfPresent(tagsFilter, forKey: .tagsFilter)
        try c.encodeIfPresent(surface, forKey: .surface)
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

/// Recall response. `hits` is the daemon's actual return shape; `records`
/// stays optional because some recall paths (Phase B and beyond) may also
/// carry full durable MemoryRecord dicts alongside the search hits.
/// `rawResponse` keeps the entire body for forward-compat (query echo,
/// scoring metadata, ranking_signals, ...).
public struct MemoryRecallResult: Sendable, Codable, Equatable {
    public var hits: [MemoryRecallHit]
    public var records: [MemoryRecord]?
    public var rawResponse: JSONValue

    public init(
        hits: [MemoryRecallHit],
        records: [MemoryRecord]? = nil,
        rawResponse: JSONValue
    ) {
        self.hits = hits
        self.records = records
        self.rawResponse = rawResponse
    }

    enum CodingKeys: String, CodingKey {
        case hits
        case records
        case rawResponse = "raw_response"
    }
}

// MARK: - DeleteMemoryResult

/// Envelope returned by `deleteMemory(id:)`. Mirrors the daemon's two-shape
/// reply at `/v1/memory/delete`:
///   - 200 `{"status":"ok", ...}` → `.ok` (file removed, tombstone written)
///   - 202 `{"status":"pending_approval","approval_id":"..."}` → `.pendingApproval`
///
/// The daemon's gate (the retired daemon
/// `execute_or_queue_memory_admin_action`) is HTTP-caller-context based,
/// NOT per-memory origin/tag based: only `caller_is_loopback && !via_icloud`
/// executes directly; every other path queues an approval. SwiftNative
/// preserves this by parsing whichever envelope the daemon returns —
/// approval policy stays in one place (Python) and the Swift layer doesn't
/// fork its own gate.
public struct DeleteMemoryResult: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case ok
        case pendingApproval = "pending_approval"
    }

    public var status: Status
    /// Set when `status == .pendingApproval`. Matches the daemon's
    /// `approval_id` field so callers can correlate against
    /// ApprovalInbox records.
    public var approvalId: String?
    /// Human-readable message from the daemon ("Memory admin changes
    /// require approval ..."). Optional on the .ok path.
    public var message: String?

    public init(status: Status, approvalId: String? = nil, message: String? = nil) {
        self.status = status
        self.approvalId = approvalId
        self.message = message
    }

    public static let ok = DeleteMemoryResult(status: .ok)
}

// MARK: - UpdateMemoryResult

/// Envelope returned by `updateMemoryAdmin(id:update:)`. Mirrors the daemon's
/// two-shape reply at `/v1/memory/update`, which runs through the SAME
/// `execute_or_queue_memory_admin_action` gate as `/v1/memory/delete`
///:
///   - 200 `{"status":"ok", ...}` → `.ok`
///   - 202 `{"status":"pending_approval","approval_id":"..."}` → `.pendingApproval`
///
/// This is DISTINCT from `MemoryV2Protocol.updateMemory(id:update:)`, which
/// returns a fully-decoded `MemoryRecord` and is used by the replay/embedding
/// paths that expect the daemon to echo back the mutated record. The admin
/// path (pin/unpin/correct from the Mac UI) needs the approval envelope
/// instead, because the gate may queue the change for approval rather than
/// apply it — and a 202 envelope has NO `record` field to decode. Keeping the
/// two methods separate means the SwiftNative gate preserves the daemon's
/// approval policy verbatim (policy stays in Python) without the UI path
/// silently throwing on a queued-for-approval response.
public struct UpdateMemoryResult: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case ok
        case pendingApproval = "pending_approval"
    }

    public var status: Status
    /// Set when `status == .pendingApproval`. Matches the daemon's
    /// `approval_id` field so callers can correlate against ApprovalInbox.
    public var approvalId: String?
    /// Human-readable message from the daemon, when present.
    public var message: String?
    /// The full daemon envelope, kept for forward-compat so callers that
    /// want the echoed record (when the gate applied the change directly)
    /// can reach it without a second method.
    public var rawResponse: JSONValue

    public init(
        status: Status,
        approvalId: String? = nil,
        message: String? = nil,
        rawResponse: JSONValue = .null
    ) {
        self.status = status
        self.approvalId = approvalId
        self.message = message
        self.rawResponse = rawResponse
    }

    public static let ok = UpdateMemoryResult(status: .ok)
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

// MARK: - Protocol

/// MemoryV2 surface. SwiftNative reads and writes the SQLite memory store and
/// performs recall through the configured embedding provider. There is no
/// daemon fallback.
public protocol MemoryV2Protocol: Sendable {
    func listMemory(kind: String?) async throws -> [MemoryRecord]
    func recallMemory(_ query: MemoryRecallQuery) async throws -> MemoryRecallResult
    func updateMemory(id: String, update: JSONValue) async throws -> MemoryRecord
    /// Admin-gated update that preserves the daemon's ok / pending_approval
    /// envelope (used by the Mac UI pin/unpin/correct path). See
    /// ``UpdateMemoryResult`` for why this is distinct from `updateMemory`.
    func updateMemoryAdmin(id: String, update: JSONValue) async throws -> UpdateMemoryResult
    func deleteMemory(id: String) async throws -> DeleteMemoryResult
    func v2Status() async throws -> JSONValue
}

// MARK: - SwiftNative impl

/// SwiftNative MemoryV2 actor. Use ``makeMemoryV2`` or ``SwiftNativeMemoryV2.shared``
/// for production so storage/embedder are wired.
public actor SwiftNativeMemoryV2: MemoryV2Protocol {
    // Embedder (Core ML MiniLM in production, MockEmbeddingProvider in tests)
    // plus SQLite-backed MemoryStorage. Optional so tests can construct an
    // unwired actor and assert it fails closed.
    internal let embedder: (any EmbeddingProvider)?
    internal let storage: (any MemoryStorageProtocol)?
    /// Error-level diagnostic sink (defaults to NSLog). Actor-isolated and
    /// per-instance on purpose: a global sink would leak between concurrently
    /// running tests. Set it to prove the persona-recall dead-lane alarm fires.
    internal var diagnosticSink: (@Sendable (String) -> Void)?
    /// (persona|surface) signatures whose persona-recall starvation has already
    /// been reported. The alarm fires on the zero-hit path, which a tool loop
    /// re-enters on every call: unbounded, it spams one error AND pays for one
    /// extra store probe per call. Same bound as
    /// `ContextFlowCoordinator.PrecoverageFailureReporter` — one line per
    /// distinct failure, memoized per instance so tests never leak into
    /// each other.
    internal var reportedStarvationSignatures: Set<String> = []

    public func setDiagnosticSink(_ sink: (@Sendable (String) -> Void)?) {
        diagnosticSink = sink
    }

    internal func emitDiagnostic(_ message: String) {
        if let diagnosticSink {
            diagnosticSink(message)
        } else {
            NSLog("%@", message)
        }
    }

    public init() {
        self.embedder = nil
        self.storage = nil
    }

    public init(
        embedder: any EmbeddingProvider,
        storage: any MemoryStorageProtocol
    ) {
        self.embedder = embedder
        self.storage = storage
    }

    public func listMemory(kind: String?) async throws -> [MemoryRecord] {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        return try await storage.listMemory(kind: kind)
    }

    public func recallMemory(_ query: MemoryRecallQuery) async throws -> MemoryRecallResult {
        // 2026-07-21 audit fix: thread the caller's surface into recall so
        // the disclosure policy actually gates this lane. nil stays the
        // allow-all escape hatch for genuinely surfaceless internal callers
        // (e.g. the cognitive substrate's ambient reads) — never for a lane
        // whose caller knows its surface.
        let result = try await recall(
            MemoryV2RecallRequest(text: query.query, topK: query.k, persona: nil, surface: query.surface)
        )
        return MemoryRecallResult(
            hits: result.hits,
            records: nil,
            rawResponse: .object([
                "query": .string(query.query),
                "k": .int(Int64(query.k)),
                "hits": .array(result.hits.map { hit in
                    .object([
                        "score": .double(hit.score),
                        "preview": .string(hit.preview),
                    ])
                }),
            ])
        )
    }

    public func updateMemory(id: String, update: JSONValue) async throws -> MemoryRecord {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        let update = Self.sanitizedMemoryUpdate(update)
        let newEmbedding = try await reembedIfContentChanged(update: update)
        try await gateUpdatedContentAgainstTombstones(update: update, embedding: newEmbedding, storage: storage)
        let updated = try await storage.updateMemory(
            id: id,
            patch: update,
            newEmbedding: newEmbedding?.vector,
            embeddingEpoch: newEmbedding?.epoch
        )
        await flushDerivedMemoryChanges()
        return updated
    }

    public func updateMemoryAdmin(id: String, update: JSONValue) async throws -> UpdateMemoryResult {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        let update = Self.sanitizedMemoryUpdate(update)
        let newEmbedding = try await reembedIfContentChanged(update: update)
        try await gateUpdatedContentAgainstTombstones(update: update, embedding: newEmbedding, storage: storage)
        _ = try await storage.updateMemory(
            id: id,
            patch: update,
            newEmbedding: newEmbedding?.vector,
            embeddingEpoch: newEmbedding?.epoch
        )
        await flushDerivedMemoryChanges()
        return .ok
    }

    /// Edits go through the same denylist gates as inserts: without this, a
    /// "correction" could rewrite an existing memory INTO a deleted/rejected
    /// fact (gpt-5.5 wave1 finding 2). Only fires when the patch changes
    /// text/content (embedding non-nil — reuses the vector already computed).
    private func gateUpdatedContentAgainstTombstones(
        update: JSONValue,
        embedding: (vector: [Float], epoch: MemoryEmbeddingEpoch)?,
        storage: any MemoryStorageProtocol
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

    public func deleteMemory(id: String) async throws -> DeleteMemoryResult {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        _ = try await storage.deleteMemory(id: id)
        await flushDerivedMemoryChanges()
        return .ok
    }

    public func v2Status() async throws -> JSONValue {
        guard let embedder, storage != nil else { throw MemoryV2Error.storageUnavailable }
        return .object([
            "phase": .string("B"),
            "backend": .string("swift-native"),
            "embedder": .string(embedder.modelId),
            "dimensions": .int(Int64(embedder.dimensions)),
        ])
    }

    /// Model id of the active embedder, if wired. `nil` when storage is
    /// unconfigured. "mock" indicates the deterministic stand-in is active.
    ///
    /// WARNING: a non-"mock" value (e.g. "all-MiniLM-L6-v2") does NOT prove
    /// real CoreML embeddings are running — under the fail-closed contract
    /// `ManagedEmbeddingProvider.modelId` returns the CoreML name whenever
    /// CoreML is requested, even when resources are missing and `embed()`
    /// will throw. Use `embeddingRuntimeSnapshot().effectiveBackend` for the
    /// terminal-state check (coreMLBackend / mockBackend / failClosedBackend).
    public func embedderModelId() -> String? { embedder?.modelId }

    /// Embedder vector dimensionality, when wired.
    public func embedderDimensions() -> Int? { embedder?.dimensions }

    public func embeddingEpoch() -> MemoryEmbeddingEpoch? { embedder?.embeddingEpoch }

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
            mode: ManagedEmbeddingProvider.balancedMode,
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
            idleUnloadSeconds: 300
        )
    }

    public func configureEmbeddingBackend(enabled: Bool) async throws {
        guard let managed = embedder as? ManagedEmbeddingProvider else {
            throw MemoryV2Error.underlying("embedding runtime is not configurable")
        }
        try await managed.setBackend(enabled: enabled)
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
        guard let embedder else { return }
        _ = try await embedder.embed(["warmup"])
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

    func flushDerivedMemoryChanges() async {
        await DerivedStateInvalidationCenter.shared.flush()
    }

    public func configureEmbeddingMemoryMode(_ mode: String) async throws {
        guard let managed = embedder as? ManagedEmbeddingProvider else {
            throw MemoryV2Error.underlying("embedding runtime is not configurable")
        }
        try await managed.setMemoryMode(mode)
    }

    @discardableResult
    public func releaseEmbeddingMemory(reason: String = "manual release") -> EmbeddingRuntimeSnapshot? {
        guard let managed = embedder as? ManagedEmbeddingProvider else {
            return embeddingRuntimeSnapshot()
        }
        return managed.release(reason: reason)
    }

    public func reembedActiveMemoriesForCurrentProvider(limit: Int? = nil) async throws -> Int {
        guard limit == nil else {
            throw MemoryV2Error.underlying(
                "partial re-embedding is unsafe; embedding epochs require a full-corpus atomic switch"
            )
        }
        return try await reindexAllMemoryEmbeddingsForCurrentProvider().memories
    }

    public func memoryEmbeddingEpochState() async throws -> MemoryEmbeddingEpochState {
        guard let bridge = storage as? MemoryStorageBridge else {
            throw MemoryV2Error.storageUnavailable
        }
        return try await bridge.underlyingStorage().embeddingEpochState()
    }

    /// Freshly embeds every canonical memory/proposal/tombstone in bounded
    /// batches, off the chat path, then switches the entire corpus in one
    /// transaction. Any content drift or provider-epoch drift aborts before
    /// canonical vectors change.
    public func reindexAllMemoryEmbeddingsForCurrentProvider(
        batchSize: Int = 64
    ) async throws -> MemoryEmbeddingEpochActivationReport {
        guard let embedder,
              let bridge = storage as? MemoryStorageBridge else {
            throw MemoryV2Error.storageUnavailable
        }
        let concreteStorage = await bridge.underlyingStorage()
        let corpus = try await concreteStorage.embeddingCorpusSnapshot()
        guard corpus.count <= 50_000 else {
            throw MemoryV2Error.underlying("embedding corpus exceeds bounded activation limit")
        }
        let boundedBatch = min(256, max(1, batchSize))
        var staged: [MemoryEmbeddingStagedRow] = []
        staged.reserveCapacity(corpus.count)
        var candidateEpoch: MemoryEmbeddingEpoch?

        if corpus.isEmpty {
            let probe = try await embedder.embedWithEpoch(["NativeAgent embedding epoch activation"])
            candidateEpoch = probe.epoch
        } else {
            for start in stride(from: 0, to: corpus.count, by: boundedBatch) {
                try Task.checkCancellation()
                let end = min(corpus.count, start + boundedBatch)
                let rows = Array(corpus[start..<end])
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
                staged += zip(rows, batch.vectors).map {
                    MemoryEmbeddingStagedRow(row: $0.0, vector: $0.1)
                }
            }
        }
        guard let candidateEpoch else {
            throw MemoryV2Error.underlying("embedding provider did not identify its vector space")
        }
        return try await concreteStorage.activateEmbeddingEpoch(candidateEpoch, staged: staged)
    }

    public func rollbackMemoryEmbeddingEpochActivation() async throws -> MemoryEmbeddingEpochState {
        guard let bridge = storage as? MemoryStorageBridge else {
            throw MemoryV2Error.storageUnavailable
        }
        return try await bridge.underlyingStorage().rollbackEmbeddingEpochActivation()
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

    private func reembedIfContentChanged(
        update: JSONValue
    ) async throws -> (vector: [Float], epoch: MemoryEmbeddingEpoch)? {
        guard case .object(let obj) = update else { return nil }
        // Only re-embed if the patch carries a new `text`/`content` field; otherwise
        // the existing embedding stays valid and we skip the (expensive) Neural Engine
        // round-trip.
        if case .string(let s)? = obj["text"] { return try await embedOneWithEpoch(s) }
        if case .string(let s)? = obj["content"] { return try await embedOneWithEpoch(s) }
        return nil
    }

    private static func sanitizedMemoryUpdate(_ update: JSONValue) -> JSONValue {
        guard case .object(var obj) = update else { return update }
        let kind = patchKind(obj)
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


// MARK: - Factory

public func makeMemoryV2() -> any MemoryV2Protocol {
    // Hand back the wired singleton (real SQLite storage, CoreML-or-Mock
    // embedder, Spotlight hook installed) instead of an unconfigured actor
    // that throws storageUnavailable on every call.
    return SwiftNativeMemoryV2.shared
}
