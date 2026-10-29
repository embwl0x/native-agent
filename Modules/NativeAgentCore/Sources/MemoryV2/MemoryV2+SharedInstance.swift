// SwiftNativeMemoryV2 owns canonical MemoryStorage at <dataRoot>/memory/memory.sqlite.
// Stored rows become MemoryRecord values only at the outward boundary.

import Foundation
import Senses
import GRDB
import NativeAgentCore
import PersistenceCore
import Synchronization
import NativeAgentShared
// Blueprint: | `MemoryV2+SharedInstance.swift` | `SwiftNativeMemoryV2` directly owns canonical `MemoryStorage`; attachment readiness, engine-closed projection hooks and unavailable-storage admission; late canonical attachment never reopens stopped projections |

// MARK: - SwiftNativeMemoryV2.shared

extension SwiftNativeMemoryV2 {
    /// True when canonical path identity matches the process-wide production store.
    public static func usesDefaultDataRoot(_ dataRoot: URL) -> Bool {
        canonicalRootIdentity(dataRoot)
            == canonicalRootIdentity(PersistenceCore.defaultDataRoot())
    }

    /// Resolve the MemoryV2 owner for an injected data root without introducing
    /// a process-wide registry.
    ///
    /// The default root always returns ``shared`` so normal app composition has
    /// one actor and one underlying `MemoryStorage`. Alternate roots remain
    /// hermetic and receive a private actor rooted exactly at the injected URL.
    /// Failure to open an alternate store returns the existing unwired,
    /// fail-closed actor; it never borrows the user's live memory.
    public static func resolvedOwner(
        dataRoot: URL,
        alternateRootEmbedder: (any EmbeddingProvider)? = nil
    ) -> SwiftNativeMemoryV2 {
        guard !usesDefaultDataRoot(dataRoot) else { return .shared }
        let root = dataRoot.standardizedFileURL
        guard let storage = try? MemoryStorage(dataRoot: root) else {
            return SwiftNativeMemoryV2()
        }
        return SwiftNativeMemoryV2(
            embedder: alternateRootEmbedder ?? ManagedEmbeddingProvider(dataRoot: root),
            storage: storage
        )
    }

    /// Resolve the concrete storage actor for operations that need canonical
    /// administrative APIs. Default-root
    /// callers receive the exact storage beneath ``shared``; alternate roots
    /// open an isolated store. An unavailable shared actor fails closed rather
    /// than quietly constructing a hookless second owner over live memory.
    public static func resolvedStorage(dataRoot: URL) async throws -> MemoryStorage {
        if usesDefaultDataRoot(dataRoot) {
            guard let storage = await SwiftNativeMemoryV2.shared.underlyingStorage() else {
                throw MemoryV2Error.storageUnavailable
            }
            return storage
        }
        return try MemoryStorage(dataRoot: dataRoot.standardizedFileURL)
    }

    /// Build and attach the USER.md projection hook to this actor's exact
    /// underlying storage. The caller gets the generator only after the hook is
    /// installed, so launch cannot regenerate through one SQLite owner and then
    /// attach mutations to another.
    public func bindUserMDGenerator(
        dataRoot: URL,
        personaRoot: URL? = nil,
        debounceInterval: TimeInterval = 30
    ) async -> UserMDGenerator? {
        guard !memoryProjectionsStopped else { return nil }
        if let canonicalDataRoot,
           Self.canonicalRootIdentity(canonicalDataRoot) != Self.canonicalRootIdentity(dataRoot) { return nil }
        userProjectionBinding = (dataRoot, personaRoot, debounceInterval)
        do { try await ensureCanonicalAttachment() }
        catch { emitDiagnostic("[MemoryV2] USER projection attachment failed: \(error)"); return nil }
        guard let underlying = storage else { return nil }
        guard !memoryProjectionsStopped else { return nil }
        let storagePath = underlying.path
        let storageDataRoot = storagePath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard Self.canonicalRootIdentity(storageDataRoot)
            == Self.canonicalRootIdentity(dataRoot) else {
            return nil
        }
        let generator = UserMDGenerator(
            storage: underlying,
            dataRoot: dataRoot,
            personaRoot: personaRoot,
            debounceInterval: debounceInterval
        )
        await underlying.attachUserMDGenerator(generator)
        guard !memoryProjectionsStopped else { return nil }
        return generator
    }

    /// Retire projection resources without closing the canonical write store.
    public func shutdownProjections() async {
        memoryProjectionsStopped = true
        if let storage { await storage.shutdownProjections() }
        await canonicalAttachmentReady?.value
    }

    /// Reconcile the rebuildable Knowledge Graph projection from the exact
    /// canonical MemoryV2 database owned by this actor. This is the launch and
    /// post-migration convergence seam; it does not create a second fact owner.
    @discardableResult
    public func reconcileKnowledgeGraphProjection() async throws -> KnowledgeGraphMemoryRebuildReport {
        try await ensureCanonicalAttachment()
        guard let underlying = storage else {
            throw MemoryV2Error.storageUnavailable
        }
        let sqlitePath = underlying.path
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
        return try await indexer.rebuildMemoryDerivedGraphFromCanonicalStore(
            producing: MemoryPolicyGate.knowledgeGraphEnabled(
                dataRoot: sqlitePath.deletingLastPathComponent().deletingLastPathComponent()
            )
        )
    }

    private static func canonicalRootIdentity(_ root: URL) -> String {
        root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Unfiltered exact-ID authority lookup; never a recall path.
    public func authorityRecord(id: String) async throws -> MemoryRecord? {
        try await ensureCanonicalAttachment()
        guard let underlying = storage else { throw MemoryV2Error.storageUnavailable }
        return try await underlying.memory(id: id).map(MemoryRecord.init(stored:))
    }

    /// Uses disclosure-filtered user facts until a pinned core is chosen.
    public func userPromptCore(surface: String) async throws -> [String]? {
        try await ensureCanonicalAttachment()
        guard let underlying = storage else { throw MemoryV2Error.storageUnavailable }
        return try await underlying.userPromptCore(surface: surface)
    }

    /// Process-wide instance rooted at the default data root. Uses the same
    /// SQLite store the rest of MemoryV2 writes through. Uses the
    /// `ManagedEmbeddingProvider` which loads CoreML bge-large-en-v1.5
    /// from the data root or Resources/embedding; if the model fails to load it
    /// **fails closed** (embed() throws) unless the user explicitly opted
    /// into mock vectors via config (`config/embeddings.json::backend = "mock"`)
    /// or the developer-test env var `NATIVE_AGENT_EMBEDDING_MOCK=1`.
    /// Also installs a Spotlight indexing hook on the underlying
    /// MemoryStorage so insert/update/delete/acceptProposal all reflect into
    /// the system index.
    public static let shared = SwiftNativeMemoryV2(canonicalDataRoot: PersistenceCore.defaultDataRoot())

    /// Retry attachment on the same actor and canonical path. Failed opens never
    /// install substitute storage; the next read or Doctor repair can retry.
    internal func ensureCanonicalAttachment() async throws {
        if let ready = canonicalAttachmentReady {
            await ready.value
            return
        }
        guard storage == nil, let dataRoot = canonicalDataRoot else { return }
        do {
            let (storage, ready) = try Self.sharedBackingStore(dataRoot: dataRoot, userProjectionBinding: userProjectionBinding,
                                                            projectionsEnabled: !memoryProjectionsStopped)
            self.storage = storage
            canonicalAttachmentReady = ready
            Self.sharedOpenFailureSlot.withLock { $0 = nil }
            await ready.value
        } catch {
            Self.sharedOpenFailureSlot.withLock {
                $0 = "\(dataRoot.appendingPathComponent("memory/memory.sqlite").path): \(error)"
            }
            throw error
        }
    }

    public func repairCanonicalAttachment() async throws {
        try await ensureCanonicalAttachment()
        guard let underlying = storage else { throw MemoryV2Error.storageUnavailable }
        _ = try await underlying.listMemories(persona: nil, status: nil, limit: 1)
        guard try await underlying.quickCheck() == ["ok"] else {
            throw MemoryV2Error.underlying("Canonical memory integrity check failed; the store was retained without rebuilding its graph.")
        }
        _ = try await reconcileKnowledgeGraphProjection()
        Self.graphProjectionFailureSlot.withLock { $0 = nil }
    }

    private static func sharedBackingStore(
        dataRoot: URL,
        userProjectionBinding: (dataRoot: URL, personaRoot: URL?, debounceInterval: TimeInterval)?,
        projectionsEnabled: Bool
    ) throws -> (MemoryStorage, Task<Void, Never>) {
        let storage = try MemoryStorage(dataRoot: dataRoot)
        guard projectionsEnabled else { return (storage, Task {}) }
        // Spotlight indexing hook: every memory mutation (insert/update/
        // delete/acceptProposal) reflects into the Spotlight index so the
        // system surfaces them. Built lazily to avoid retaining the indexer
        // when CoreSpotlight is unavailable (Linux).
        #if canImport(CoreSpotlight) && !os(Linux)
        let spotClient: any SpotlightIndexClient = SystemSpotlightIndexClient()
        #else
        let spotClient: any SpotlightIndexClient = MockSpotlightIndexClient()
        #endif
        let indexer = SwiftNativeMemoryIndexer(client: spotClient)
        let kgIndexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: storage.path)
        SensesHub.shared.installMemoryProvenanceSink(storage)
        let ready = Task {
            if let binding = userProjectionBinding {
                await storage.attachUserMDGenerator(UserMDGenerator(
                    storage: storage, dataRoot: binding.dataRoot, personaRoot: binding.personaRoot,
                    debounceInterval: binding.debounceInterval
                ))
            }
            await storage.attachSpotlightHook { stored, deleted in
                do {
                    if deleted {
                        try await indexer.remove(id: stored.id)
                    } else {
                        try await indexer.indexRecord(id: stored.id, text: stored.content, kind: stored.status)
                    }
                } catch {
                    await SwiftNativeMemoryIndexer.recordProjectionFailure(
                        "Canonical memory change committed; Spotlight \(deleted ? "removal" : "indexing") failed for \(stored.id): \(error)",
                        dataRoot: dataRoot, storage: storage)
                }
            }
            do {
                await storage.attachKnowledgeGraphHook { id in
                    // Read production policy per mutation; off retires the
                    // memory-derived graph, including rewritten or forgotten facts.
                    let producing = MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot)
                    do {
                        try await kgIndexer.reconcileProjectionIfNeeded(producing: producing)
                        graphProjectionFailureSlot.withLock { $0 = nil }
                        try await kgIndexer.indexMemory(id, producing: producing)
                    } catch {
                        await kgIndexer.markProjectionDirty()
                        graphProjectionFailureSlot.withLock { $0 = String(describing: error) }
                        nativeLog("[MemoryV2] Knowledge Graph projection pending repair: %@", String(describing: error))
                    }
                }
            }
            await storage.enqueueKnowledgeGraphProjection {
                // Settings ▸ "Knowledge graph": the startup backfill is graph
                // production too — off means it does not run.
                if MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot) {
                    do {
                        try await kgIndexer.reconcileProjectionIfNeeded(producing: true)
                        graphProjectionFailureSlot.withLock { $0 = nil }
                    } catch {
                        await kgIndexer.markProjectionDirty()
                        graphProjectionFailureSlot.withLock { $0 = String(describing: error) }
                        nativeLog("[MemoryV2] Knowledge Graph startup reconciliation pending repair: %@", String(describing: error))
                    }
                }
            }
        }
        return (storage, ready)
    }

    /// Last canonical attachment failure for Launch and Doctor, or nil after a successful open.
    public static var sharedOpenFailure: String? {
        _ = shared
        return sharedOpenFailureSlot.withLock { $0 }
    }
    private static let sharedOpenFailureSlot = Mutex<String?>(nil)
    private static let graphProjectionFailureSlot = Mutex<String?>(nil)

    public static var graphProjectionFailure: String? {
        graphProjectionFailureSlot.withLock { $0 }
    }

    /// The exact canonical owner, after attachment readiness has settled.
    public func underlyingStorage() async -> MemoryStorage? {
        do { try await ensureCanonicalAttachment() }
        catch { emitDiagnostic("[MemoryV2] Canonical attachment failed: \(error)") }
        return storage
    }
}

extension MemoryStorage {
    /// Doctor's live-store probe: `PRAGMA quick_check` on the pool the running
    /// app reads and writes through. Returns SQLite's rows ("ok" when clean).
    public func quickCheck() async throws -> [String] {
        try await dbPool.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check") }
    }
}

// MARK: - MemoryRecalling adapter

/// Disclosure-aware recall and delivered-hit credit against the same memory owner.
public struct SwiftNativeMemoryV2Recaller: Sendable {
    private let memory: SwiftNativeMemoryV2
    public init(memory: SwiftNativeMemoryV2 = .shared) {
        self.memory = memory
    }
    /// Retrieve without credit; the accepted context credits only delivered IDs.
    public func recall(
        _ query: String,
        k: Int,
        persona: String? = nil,
        surface: String? = nil
    ) async throws -> [MemoryRecallHit] {
        let request = MemoryV2RecallRequest(
            text: query,
            topK: k,
            persona: persona,
            surface: surface
        )
        let response = try await memory.recall(request, recordingUsage: false)
        return await annotatedWithRelatedEntities(response, query: request)
    }

    /// Credit only the hits the accepted context delivered; report write failures.
    public func recordServedContextHits(ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            try await memory.recordRecallHits(ids: ids)
        } catch {
            FileHandle.standardError.write(
                Data("MemoryV2: context-serve bump failed for \(ids.count) ids: \(error)\n".utf8)
            )
        }
    }

    /// Add one-hop entities from this memory owner's SQLite graph to `extras["kg_related"]`.
    /// Seed only records that classify and permit this surface/persona under `MemoryRecordDisclosurePolicy`.
    /// Recall's `extras["id"]` ties each hit to entities extracted from its own memory text.
    /// The prompt renderer presents entity names as one `related:` line.
    /// Unavailable storage or graph enrichment failure leaves recall hits unchanged.
    private func annotatedWithRelatedEntities(
        _ response: MemoryV2RecallResponse,
        query: MemoryV2RecallRequest
    ) async -> [MemoryRecallHit] {
        // Settings ▸ "Knowledge graph": off means the graph is not USED either
        // — recall gets no one-hop entity enrichment. Read fresh per recall.
        guard MemoryPolicyGate.knowledgeGraphEnabled() else { return response.hits }
        guard !response.hits.isEmpty else { return response.hits }
        let disclosedIDs: Set<String> = Set(
            response.scored.compactMap { scoredRecord in
                guard let classification =
                        MemoryRecordDisclosurePolicy.classify(scoredRecord.record),
                      classification.permits(
                        surface: query.surface, personaID: query.persona
                      ) else { return nil }
                return scoredRecord.record.id
            }
        )
        guard !disclosedIDs.isEmpty else { return response.hits }
        guard let storage = await memory.underlyingStorage() else { return response.hits }
        let related: [String: [String]]
        do {
            let sqlitePath = storage.path
            let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
            related = try await indexer.relatedEntityNames(
                forMemoryIDs: Array(disclosedIDs)
            )
        } catch {
            return response.hits
        }
        guard !related.isEmpty else { return response.hits }
        return response.hits.map { hit in
            // Recall stamps the record id into `extras["id"]`; that is the only
            // link back from a hit to the memory it came from.
            guard case .object(var extras)? = hit.extras,
                  case .string(let id)? = extras["id"],
                  disclosedIDs.contains(id),
                  let names = related[id], !names.isEmpty else { return hit }
            var annotated = hit
            extras["kg_related"] = .array(names.map { .string($0) })
            annotated.extras = .object(extras)
            return annotated
        }
    }
}

// MARK: - Stored rows as records

public extension MemoryRecord {
    /// A canonical SQLite row as the typed record: the metadata-carried fields
    /// surface back into their typed slots (the reverse of insert's fold).
    init(stored s: StoredMemory) {
        var kind: String? = nil
        var tags: [String]? = nil
        var importance: Double? = nil
        var pinned: Bool? = nil
        if case .object(let m)? = s.metadata {
            if case .string(let k)? = m["kind"] { kind = k }
            if case .array(let arr)? = m["tags"] {
                let strs = arr.compactMap { v -> String? in
                    if case .string(let t) = v { return t } else { return nil }
                }
                if !strs.isEmpty { tags = strs }
            }
            if case .double(let i)? = m["importance"] { importance = i }
            if case .int(let i)? = m["importance"] { importance = Double(i) }
            if case .bool(let b)? = m["pinned"] { pinned = b }
        }
        self.init(
            id: s.id,
            text: s.content,
            layer: "semantic",
            memoryKind: kind,
            personaId: s.personaId,
            lifecycle: s.lifecycle,
            createdAt: s.createdAt,
            updatedAt: s.updatedAt,
            sourceRunId: s.source,
            status: s.status,
            pinned: pinned,
            confidence: s.confidence,
            importance: importance,
            tags: tags,
            validFrom: s.validFrom,
            validTo: s.validTo,
            observedAt: s.observedAt,
            evidence: s.evidence,
            extras: s.metadata
        )
    }
}

public extension ProposalRecord {
    init(stored p: StoredProposal) {
        self.init(
            id: p.id,
            content: p.content,
            personaId: p.personaId,
            source: p.source,
            status: p.status,
            createdAt: p.stagedAt,
            resolvedAt: p.resolvedAt,
            rejectionReason: p.rejectionReason,
            metadata: p.metadata
        )
    }
}

extension SwiftNativeMemoryV2 {
    /// Her prompt core for her own background work and reflection: the same
    /// core chat carries (read as chat sees it, since this is her own thinking,
    /// not a door). A read failure degrades to the preamble only, as chat
    /// does, and never fails the background job.
    public static func userCoreForBackground(dataRoot: URL) async -> [String]? {
        do {
            return try await resolvedOwner(dataRoot: dataRoot).userPromptCore(surface: "chat")
        } catch {
            return []
        }
    }
}

extension MemoryPatch {
    init(update: JSONValue, embedding: [Float]?, epoch: MemoryEmbeddingEpoch?) {
        self.init(embedding: embedding, embeddingEpoch: epoch?.rawValue)
        guard case .object(let object) = update else { return }
        content = SwiftNativeMemoryV2.patchText(update)
        status = object["status"]?.stringValue
        lifecycle = object["lifecycle"]?.stringValue
        confidence = object["confidence"]?.numberValue(coercingStrings: false, finiteOnly: false)
        validFrom = object["valid_from"]?.stringValue ?? object["validFrom"]?.stringValue
        validTo = object["valid_to"]?.stringValue ?? object["validTo"]?.stringValue
        observedAt = object["observed_at"]?.stringValue ?? object["observedAt"]?.stringValue
        evidence = object["evidence"]
        let passthrough = object.filter { MemoryPatchContract.untypedPassthroughKeys.contains($0.key) }
        if !passthrough.isEmpty { metadataMerge = passthrough }
    }
}
