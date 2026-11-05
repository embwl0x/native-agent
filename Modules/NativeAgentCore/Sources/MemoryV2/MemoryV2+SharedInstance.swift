// Keep canonical storage under SwiftNativeMemoryV2; construct MemoryRecord values only at the outward boundary.

import Foundation
import Senses
import GRDB
import NativeAgentCore
import PersistenceCore
import Synchronization
import NativeAgentShared
// Blueprint: | `MemoryV2+SharedInstance.swift` | `SwiftNativeMemoryV2`, `MemoryStorage`: canonical owner, attachment and projections |

// MARK: - SwiftNativeMemoryV2.shared

extension SwiftNativeMemoryV2 {
    public static func usesDefaultDataRoot(_ dataRoot: URL) -> Bool {
        canonicalRootIdentity(dataRoot)
            == canonicalRootIdentity(PersistenceCore.defaultDataRoot())
    }

    /// Return shared for the default root so production has one actor and store. Injected roots remain isolated; failed opens stay fail-closed and never borrow
    /// live user memory.
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

    /// Administrative access must use the exact canonical actor; unavailable shared storage cannot create a hookless second owner.
    public static func resolvedStorage(dataRoot: URL) async throws -> MemoryStorage {
        if usesDefaultDataRoot(dataRoot) {
            guard let storage = await SwiftNativeMemoryV2.shared.underlyingStorage() else {
                throw MemoryV2Error.storageUnavailable
            }
            return storage
        }
        return try MemoryStorage(dataRoot: dataRoot.standardizedFileURL)
    }

    /// Attach USER.md to this actor's exact storage before returning its generator so launch and mutation hooks cannot split owners.
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

    /// Reconcile the graph from this actor's canonical database without creating a second fact owner.
    @discardableResult
    public func reconcileKnowledgeGraphProjection() async throws -> KnowledgeGraphMemoryRebuildReport {
        try await ensureCanonicalAttachment()
        guard let underlying = storage else {
            throw MemoryV2Error.storageUnavailable
        }
        let sqlitePath = underlying.path
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
        return try await indexer.rebuildMemoryDerivedGraphFromCanonicalStore(
            producing: try MemoryPolicyGate.knowledgeGraphEnabled(
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
    public func userPromptCore(surface: String, preview: Bool = false) async throws -> [String]? {
        try await ensureCanonicalAttachment(preview: preview)
        guard let underlying = storage else { throw MemoryV2Error.storageUnavailable }
        return try await underlying.userPromptCore(surface: surface)
    }

    /// The process-wide actor shares canonical SQLite and managed embeddings; failed real inference throws unless mock is explicitly configured. Attach
    /// Spotlight hooks to the same storage for all mutations.
    public static let shared = SwiftNativeMemoryV2(canonicalDataRoot: PersistenceCore.defaultDataRoot())

    /// Retry attachment on the same actor and canonical path. Failed opens never install substitute storage; the next read or Doctor repair can retry.
    internal func ensureCanonicalAttachment(preview: Bool = false) async throws {
        // Reading for a mind preview cannot initialize storage, migrations or projection hooks. An already attached owner remains the one reader.
        if preview, storage == nil { throw MemoryV2Error.storageUnavailable }
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
        // Create Spotlight hooks lazily only where CoreSpotlight is available.
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
                        try await indexer.indexRecord(id: stored.id, text: stored.content, kind: stored.status, validTo: stored.validTo)
                    }
                } catch {
                    await SwiftNativeMemoryIndexer.recordProjectionFailure(
                        "Canonical memory change committed; Spotlight \(deleted ? "removal" : "indexing") failed for \(stored.id): \(error)",
                        dataRoot: dataRoot, storage: storage)
                }
            }
            do {
                await storage.attachKnowledgeGraphHook { id in
                    // Read production policy per mutation; off retires the memory-derived graph, including rewritten or forgotten facts.
                    do {
                        let producing = try MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot)
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
                // The graph production switch also gates startup backfill.
                do {
                    if try MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot) {
                        try await kgIndexer.reconcileProjectionIfNeeded(producing: true)
                        graphProjectionFailureSlot.withLock { $0 = nil }
                    }
                } catch {
                    await kgIndexer.markProjectionDirty()
                    graphProjectionFailureSlot.withLock { $0 = String(describing: error) }
                    nativeLog("[MemoryV2] Knowledge Graph startup reconciliation pending repair: %@", String(describing: error))
                }
            }
        }
        return (storage, ready)
    }

    /// Retain the attachment failure until the canonical store opens successfully.
    public static var sharedOpenFailure: String? {
        _ = shared
        return sharedOpenFailureSlot.withLock { $0 }
    }
    private static let sharedOpenFailureSlot = Mutex<String?>(nil)
    private static let graphProjectionFailureSlot = Mutex<String?>(nil)

    public static var graphProjectionFailure: String? {
        graphProjectionFailureSlot.withLock { $0 }
    }

    public func underlyingStorage() async -> MemoryStorage? {
        do { try await ensureCanonicalAttachment() }
        catch { emitDiagnostic("[MemoryV2] Canonical attachment failed: \(error)") }
        return storage
    }
}

extension MemoryStorage {
    /// Probe quick_check on the exact pool the running app reads and writes.
    public func quickCheck() async throws -> [String] {
        try await dbPool.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check") }
    }
}

// MARK: - MemoryRecalling adapter

/// Keep disclosure-aware recall and delivered-hit credit on the same owner.
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
        return try await annotatedWithRelatedEntities(response, query: request)
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

    /// Seed graph enrichment only with disclosed hits under this owner; bind entities through each hit's exact memory ID so related names retain source
    /// disclosure.
    private func annotatedWithRelatedEntities(
        _ response: MemoryV2RecallResponse,
        query: MemoryV2RecallRequest
    ) async throws -> [MemoryRecallHit] {
        // Read graph policy on each recall; disabled production also withholds graph enrichment.
        guard try MemoryPolicyGate.knowledgeGraphEnabled() else { return response.hits }
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
        guard let storage = await memory.underlyingStorage() else { throw MemoryV2Error.storageUnavailable }
        let related: [String: [String]]
        let sqlitePath = storage.path
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
        related = try await indexer.relatedEntityNames(forMemoryIDs: Array(disclosedIDs))
        guard !related.isEmpty else { return response.hits }
        return response.hits.map { hit in
            // Use recall's extras ID as the sole link back to the canonical memory.
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
    /// Restore metadata-carried fields to their typed slots at the outward boundary.
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
    /// Background thought uses chat's own prompt core; unavailable required context fails the work.
    public static func userCoreForBackground(dataRoot: URL) async throws -> [String]? {
        try await resolvedOwner(dataRoot: dataRoot).userPromptCore(surface: "chat")
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
        validFrom = object["valid_from"]?.stringValue
        validTo = object["valid_to"]?.stringValue
        observedAt = object["observed_at"]?.stringValue
        evidence = object["evidence"]
        let passthrough = object.filter { MemoryPatchContract.untypedPassthroughKeys.contains($0.key) }
        if !passthrough.isEmpty { metadataMerge = passthrough }
    }
}
