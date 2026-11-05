import Foundation
import NativeAgentCore
import Observation
import PersistenceCore
import MemoryV2
import TrustCenter
import NativeAgentShared
import DeviceSync
// Blueprint: | `EngineMemory.swift` | `refreshStatuses`, `proposals(status:)`, `graphSnapshot`, `ProposalRecord`; Canonical memory projections |

/// Share MemoryV2 and Knowledge Graph owners per root across observable pages and phone reads.
@MainActor
@Observable
public final class MemoryFacade {
    public nonisolated let dataRoot: URL
    private var embeddingSource: (owner: SwiftNativeMemoryV2, runtime: ManagedEmbeddingProvider)?
    @ObservationIgnored private let embeddingsRead = LatestRead()
    public private(set) var embeddingsError: String?
    public var embeddingSnapshot: EmbeddingRuntimeSnapshot? {
        embeddingSource?.runtime.snapshot()
    }

    public func loadEmbeddings() async {
        _ = await embeddingsRead.read { () async -> Result<(owner: SwiftNativeMemoryV2, runtime: ManagedEmbeddingProvider), Error> in
            do { return .success(try await Task.detached {
                let owner = self.owner
                return (owner, try await owner.managedEmbeddingRuntime())
            }.value) }
            catch { return Result<(owner: SwiftNativeMemoryV2, runtime: ManagedEmbeddingProvider), Error>.failure(error) }
        } publish: { result in
            switch result {
            case .success(let source): embeddingSource = source; embeddingsError = nil
            case .failure(let error): embeddingSource = nil; embeddingsError = error.localizedDescription
            }
        }
    }
    public func toggleEmbeddings(_ enabled: Bool) async throws {
        guard let embeddingSource else { throw MemoryV2Error.storageUnavailable }
        try await embeddingSource.owner.configureEmbeddingBackendAndReindex(enabled: enabled)
    }

    public private(set) var cachedAgentDisplayName = UserDefaults.standard.string(forKey: "cachedAgentDisplayName")

    public func teachAssistantName(_ profile: PersonalityProfile?) {
        if let profile {
            cachedAgentDisplayName = profile.name
            UserDefaults.standard.set(profile.name, forKey: "cachedAgentDisplayName")
        }
        let name = profile?.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !name.isEmpty { AdaptiveCandidateHygiene.insertAssistantName(name) }
    }

    public private(set) var status: MemoryV2Status?
    public private(set) var statusRefresh: PanelRefreshStatus?
    public private(set) var statusReadError: String?
    @ObservationIgnored private let statusesRead = LatestRead()
    @ObservationIgnored private let proposalsRead = LatestRead()

    public var memories: [MemoryV2.MemoryRecord] = []
    public private(set) var memoriesReadError: String?
    public private(set) var hasLoadedMemories = false
    @ObservationIgnored private let memoriesRead = LatestRead()

    @discardableResult
    public func refreshMemories() async throws -> [MemoryV2.MemoryRecord] {
        let result: Result<[MemoryV2.MemoryRecord], Error> = await memoriesRead.read({
            do { return .success(try await activeMemories()) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let rows): memories = rows; hasLoadedMemories = true; memoriesReadError = nil
            case .failure(let error): memoriesReadError = error.localizedDescription
            }
        })
        return try result.get()
    }
    public var totalCount: Int? { status?.counts?.active }
    public private(set) var diagnostics: MemoryV2NativeStackSnapshot = .empty
    public private(set) var diagnosticsCheckedAt: Date?
    public private(set) var proposals: [ProposalRecord] = [] {
        didSet { proposalsDidChange?() }
    }
    @ObservationIgnored public var proposalsDidChange: (@MainActor () -> Void)?

    public var proposalsReadFailed: Bool { proposalsReadError != nil }
    public private(set) var proposalsReadError: String?
    public private(set) var hasLoadedProposals = false
    public private(set) var rejectedProposals: [ProposalRecord] = []
    public private(set) var rejectedHistoryError: String?
    @ObservationIgnored private lazy var rejectedHistoryRead = LatestRead()
    @ObservationIgnored private lazy var diagnosticsRead = LatestRead()
    @ObservationIgnored private lazy var graphSnapshotRead = LatestRead()

    /// Nil recall rows mean evidence is unavailable, never an empty successful recall.
    public private(set) var searchResults: [MemoryV2.MemoryRecord]?
    public private(set) var searchError: String?
    public private(set) var searchQuery: String?
    /// Retain the query that actually produced displayed results.
    public private(set) var searchResultQuery: String?
    /// Distinguish in-flight recall from an empty result.
    public private(set) var searchIsLoading = false
    @ObservationIgnored private lazy var searchRead = LatestRead()
    @ObservationIgnored private var lastSuccessfulSearch: (query: String, records: [MemoryV2.MemoryRecord])?

    /// Share one checked whole-graph snapshot across graph and Capabilities pages.
    public private(set) var graphSnapshot: CanonicalAgentGraphReadout?
    public var graphEntities: [KnowledgeGraphEntity] { graphSnapshot?.canvasEntities ?? [] }
    public var graphEdges: [KnowledgeGraphEdge] { graphSnapshot?.canvasEdges ?? [] }
    public var graphTotalEntities: Int { graphEntities.count }
    public var graphTotalEdges: Int? { graphSnapshot?.canvasEdges.count }
    public private(set) var graphLoading = false
    public private(set) var graphLoadError: String?
    @ObservationIgnored private var graphRead: Task<Void, Never>?
    @ObservationIgnored private var graphReadsRequested = 0

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    /// Default roots share the canonical writer; override roots isolate it so reads and buttons still address one store.
    nonisolated private var owner: SwiftNativeMemoryV2 {
        SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
    }

    // MARK: - Reads

    public func refreshDiagnostics() async {
        _ = await diagnosticsRead.read {
            await MemoryV2NativeStackSnapshot.load(dataRoot: dataRoot)
        } publish: {
            diagnostics = $0
            diagnosticsCheckedAt = Date()
        }
    }

    public func refreshEmbeddingDiagnostics() async {
        await refreshDiagnostics()
        for _ in 0..<10 where diagnostics.shouldPollEmbeddingStartup {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            _ = await diagnosticsRead.read {
                var snapshot = diagnostics
                snapshot.applyEmbeddingRuntime(await owner.embeddingRuntimeSnapshot())
                return snapshot
            } publish: { diagnostics = $0 }
        }
    }

    /// Resolve search hits by id even outside the bounded newest-memory list.
    public nonisolated func activeMemories(ids: [String]? = nil, limit: Int? = 200) async throws -> [MemoryV2.MemoryRecord] {
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        let stored: [StoredMemory]
        if let ids {
            let rows = try await storage.memories(ids: ids)
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            stored = ids.compactMap { byID[$0] }.filter {
                $0.status == "active" && !MemoryLifecycle.recallExcluded.contains($0.lifecycle)
            }
        } else {
            stored = try await storage.listMemories(persona: nil, status: "active", limit: limit, keepingGraduated: true)
        }
        return stored.map(MemoryV2.MemoryRecord.init(stored:))
    }

    /// Pending review excludes superseded or inadmissible statements; history retains all rows.
    public func proposals(status: String,
        publish: @MainActor @Sendable (_ change: () -> Void) -> Void = { $0() }
    ) async throws -> [ProposalRecord] {
        guard status == "pending" else { return try await readProposals(status: status) }
        let result: Result<[ProposalRecord], Error> = await proposalsRead.read({
            do { return .success(try await readProposals(status: status)) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let records):
                proposalsReadError = nil
                hasLoadedProposals = true
                if proposals != records { publish { proposals = records } }
                else { proposalsDidChange?() }
            case .failure(let error): proposalsReadError = error.localizedDescription
            }
        })
        return try result.get()
    }

    private nonisolated func readProposals(status: String) async throws -> [ProposalRecord] {
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        return try await storage.listProposals(status: status)
            .filter { status != "pending" || SwiftNativeMemoryV2.awaitsReview(content: $0.content, source: $0.source, metadata: $0.metadata) }
            .map(ProposalRecord.init(stored:))
    }

    public func refreshStatuses() async -> [(endpoint: String, label: String, error: Error)] {
        let read = await statusesRead.read({
            var memory: MemoryV2Status?
            var failures: [(endpoint: String, label: String, error: Error)] = []
            do {
                let status = try await MemoryRecoveryReadout.getMemoryV2Status(dataRoot: dataRoot)
                memory = status
                if let failure = status.storageFailure {
                    failures.append(("memory v2 status", "getMemoryV2Status", MemoryV2Error.underlying(failure)))
                }
            }
            catch { failures.append(("memory v2 status", "getMemoryV2Status", error)) }
            return (memory, failures)
        }, publish: { read in
            if let value = read.0 { status = value }
            statusReadError = read.1.first?.error.localizedDescription
            statusRefresh = PanelRefreshStatus(lastAttemptAt: Date(),
                lastSuccessAt: read.1.isEmpty ? Date() : statusRefresh?.lastSuccessAt, failedEndpoints: read.1.map { $0.endpoint })
        })
        return read.1
    }

    public func refreshRejectedHistory() async {
        _ = await rejectedHistoryRead.read {
            do { return Result<[ProposalRecord], Error>.success(try await proposals(status: "rejected")) }
            catch { return .failure(error) }
        } publish: { result in
            switch result {
            case .success(let records):
                rejectedProposals = records
                rejectedHistoryError = nil
            case .failure:
                rejectedHistoryError = "Could not reload rejected memory history."
            }
        }
    }

    // MARK: - Writes

    /// Resolve and open the memory store off the caller’s actor because it may migrate.
    /// These page mutations have no chat turn or sense-read ledger.
    public nonisolated func store(content: String, source: String, metadata: JSONValue?) async throws {
        _ = try await owner.store(content: content, source: source, metadata: metadata,
            context: MemoryWriteContext(turn: nil, senseReads: nil))
    }

    /// Merge only `pinned` within the canonical transaction.
    public nonisolated func setPinned(_ pinned: Bool, id: String) async throws {
        do {
            _ = try await owner.updateMemory(id: id, update: .object(["pinned": .bool(pinned)]),
                context: MemoryWriteContext(turn: nil, senseReads: nil))
        } catch MemoryV2Error.recordNotFound {
            throw Self.notFound(id)
        }
    }

    public nonisolated func delete(id: String) async throws {
        guard try await owner.deleteMemoryIfPresent(id: id) else { throw Self.notFound(id) }
    }

    public func accept(proposalID: String,
        publish: @MainActor @Sendable (_ change: () -> Void) -> Void = { $0() }
    ) async throws -> MemoryV2.MemoryRecord {
        let accepted = try await owner.acceptProposal(id: proposalID, context: MemoryWriteContext(turn: nil, senseReads: nil))
        proposalsRead.write { publish { proposals.removeAll { $0.id == proposalID } } }
        return accepted
    }

    public func reject(proposalID: String, reason: String,
        publish: @MainActor @Sendable (_ change: () -> Void) -> Void = { $0() }
    ) async throws {
        _ = try await owner.rejectProposal(id: proposalID, reason: reason.isEmpty ? nil : reason)
        proposalsRead.write { publish { proposals.removeAll { $0.id == proposalID } } }
    }

    nonisolated private static func notFound(_ id: String) -> NSError {
        NSError(domain: "NativeAgent", code: 404, userInfo: [
            NSLocalizedDescriptionKey: "memory id not found: \(id)"
        ])
    }

    // MARK: - Search

    /// Clear recall for queries under three characters; resolve kept records through canonical ids. A face refresh re-ranks without recording another use.
    public func search(query: String, recordingUsage: Bool = true) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let prior = lastSuccessfulSearch
        searchRead.write {
            searchQuery = trimmed
            searchResultQuery = nil
            searchIsLoading = trimmed.count >= 3
            searchResults = nil
            searchError = nil
        }
        if trimmed.count < 3 {
            searchIsLoading = false
            return
        }
        // Failed reads retain proven rows with their actual query, never a substitute search.
        _ = await searchRead.read { () -> (String?, [MemoryV2.MemoryRecord]?, String?, [String]) in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return (nil, nil, nil, [])
            }
            let owner = owner
            do {
                // Credit usage only after accepted publication, never retrieval.
                let response = try await owner.recall(
                    MemoryV2RecallRequest(text: trimmed, topK: 50, persona: nil),
                    recordingUsage: false
                )
                var seen = Set<String>()
                let hitIDs = response.hits.compactMap { hit -> String? in
                    guard case .object(let obj)? = hit.extras,
                          case .string(let id)? = obj["id"], seen.insert(id).inserted else { return nil }
                    return id
                }
                // Matching older memories remain visible outside the newest-200 list.
                let records = try await activeMemories(ids: hitIDs)
                return (trimmed, records, nil, recordingUsage ? records.map(\.id) : [])
            } catch {
                let retained = prior.map { " Previous results for ‘\($0.query)’ are retained." } ?? ""
                return (prior?.query, prior?.records, "Memory search for ‘\(trimmed)’ failed: \(error.localizedDescription)." + retained, [])
            }
        } publish: { query, records, error, deliveredIDs in
            guard records != nil || error != nil else { return }
            searchResultQuery = query
            searchResults = records
            searchError = error
            searchIsLoading = false
            if error == nil, let query, let records { lastSuccessfulSearch = (query, records) }
            // Credit exactly the delivered recall rows; the next serve repairs a dropped asynchronous usage bump.
            if !Task.isCancelled, !deliveredIDs.isEmpty {
                let owner = owner
                Task { try? await owner.recordRecallHits(ids: deliveredIDs) }
            }
        }
    }

    // MARK: - Knowledge Graph

    nonisolated private var graphPath: URL {
        dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
    }

    public nonisolated func searchGraph(query: String) async throws -> GraphSearchResponse {
        try await AgentGraphReads.searchGraph(query: query, graphPath: graphPath)
    }

    /// Keep the prior snapshot with its error on failure. Share one graph read across mounts; joining refreshes get a fresh trailing read so captured bytes
    /// cannot predate the change.
    public func loadGraph() async {
        graphReadsRequested += 1
        if graphRead == nil {
            graphRead = Task {
                graphLoading = true
                var served = 0
                while served < graphReadsRequested {
                    served = graphReadsRequested
                    await readGraph()
                }
                graphLoading = false
                graphRead = nil
            }
        }
        await graphRead?.value
    }

    private func readGraph() async {
        _ = await graphSnapshotRead.read {
            do { return Result<CanonicalAgentGraphReadout, Error>.success(try await AgentGraphReads.canonicalAgentGraphProjection(
                graphPath: graphPath, timestamp: SwiftNativeManifestSigner.isoTimestamp
            )) } catch { return .failure(error) }
        } publish: { result in
            switch result {
            case .success(let snapshot): graphSnapshot = snapshot; graphLoadError = nil
            case .failure(let error): graphLoadError = error.localizedDescription
            }
        }
    }

    /// Derive detail from the exact whole-graph revision displayed beside it.
    public func neighborhood(entityID: String) -> KnowledgeGraphNeighborhood? {
        graphSnapshot?.neighborhood(entityID: entityID)
    }
}
