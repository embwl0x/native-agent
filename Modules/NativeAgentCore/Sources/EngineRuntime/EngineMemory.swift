import Foundation
import NativeAgentCore
import Observation
import PersistenceCore
import MemoryV2
import TrustCenter
import NativeAgentShared
import DeviceSync
// Blueprint: | `EngineMemory.swift` | Canonical memory projections; lifecycle-bound SQLite/WAL graph observation through the shared LatestRead snapshot |

/// Share MemoryV2 and Knowledge Graph owners per root across observable pages and phone reads.
@MainActor
@Observable
public final class MemoryFacade {
    public nonisolated let dataRoot: URL
    private var embeddingSource: (owner: SwiftNativeMemoryV2, runtime: ManagedEmbeddingProvider)?
    @ObservationIgnored private let embeddingsRead = LatestRead()
    public private(set) var embeddingsError: String?
    /// The runtime snapshot checks saved configuration and installed models. Observe its source and runtime where each is owned, off main for disk work.
    public func readEmbeddingSnapshot(onChange: (@Sendable () -> Void)? = nil) async -> EmbeddingRuntimeSnapshot? {
        if embeddingSource == nil { await loadEmbeddings() }
        let runtime: ManagedEmbeddingProvider?
        if let onChange {
            runtime = withObservationTracking { embeddingSource?.runtime } onChange: { onChange() }
        } else { runtime = embeddingSource?.runtime }
        guard let runtime else { return nil }
        return await Task.detached(priority: .userInitiated) {
            if let onChange {
                return withObservationTracking { runtime.snapshot() } onChange: { onChange() }
            }
            return runtime.snapshot()
        }.value
    }

    private func loadEmbeddings() async {
        _ = await embeddingsRead.read { () async -> Result<(owner: SwiftNativeMemoryV2, runtime: ManagedEmbeddingProvider), Error> in
            do {
                let owner = await resolveOwner()
                return .success((owner, try await owner.managedEmbeddingRuntime()))
            }
            catch { return Result<(owner: SwiftNativeMemoryV2, runtime: ManagedEmbeddingProvider), Error>.failure(error) }
        } publish: { result in
            switch result {
            case .success(let source): embeddingSource = source; embeddingsError = nil
            case .failure(let error): embeddingSource = nil; embeddingsError = error.localizedDescription
            }
        }
    }
    public func toggleEmbeddings(_ enabled: Bool) async throws {
        if embeddingSource == nil { await loadEmbeddings() }
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
    public private(set) var diagnosticsObservationIssue: String?
    public func setDiagnosticsObservationIssue(_ issue: String?) { diagnosticsObservationIssue = issue }
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
    public private(set) var graphObservationError: String?
    @ObservationIgnored private var graphRead: Task<Void, Never>?
    @ObservationIgnored private var graphReadRequested = false

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    /// Canonical-root resolution reads symlinks and may open storage; every facade caller suspends main first.
    /// Default roots share the canonical writer; override roots keep their existing isolation.
    @concurrent private nonisolated func resolveOwner() async -> SwiftNativeMemoryV2 {
        SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
    }

    // MARK: - Reads

    /// Keep kind reads on the memory owner's list policy, including its full result set and errors.
    public nonisolated func listMemory(kind: String?) async throws -> [MemoryV2.MemoryRecord] {
        try await resolveOwner().listMemory(kind: kind)
    }

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
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { changes.continuation.finish() }
        var iterator = changes.stream.makeAsyncIterator()
        while !Task.isCancelled {
            guard let runtime = await readEmbeddingSnapshot(onChange: { changes.continuation.yield(()) }) else { return }
            _ = await diagnosticsRead.read {
                var snapshot = diagnostics
                snapshot.applyEmbeddingRuntime(runtime)
                return snapshot
            } publish: { diagnostics = $0 }
            guard await iterator.next() != nil else { return }
        }
    }

    /// Resolve search hits by id even outside the bounded newest-memory list.
    @concurrent public nonisolated func activeMemories(ids: [String]? = nil, limit: Int? = 200) async throws -> [MemoryV2.MemoryRecord] {
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

    @concurrent private nonisolated func readProposals(status: String) async throws -> [ProposalRecord] {
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
        _ = try await resolveOwner().store(content: content, source: source, metadata: metadata,
            context: MemoryWriteContext(turn: nil, senseReads: nil, telling: MemoryDataProvenance.toldByPerson(dataRoot: dataRoot)))
    }

    /// Merge only `pinned` within the canonical transaction.
    public nonisolated func setPinned(_ pinned: Bool, id: String) async throws {
        do {
            _ = try await resolveOwner().updateMemory(id: id, update: .object(["pinned": .bool(pinned)]),
                context: MemoryWriteContext(turn: nil, senseReads: nil, telling: nil))
        } catch MemoryV2Error.recordNotFound {
            throw Self.notFound(id)
        }
    }

    public nonisolated func delete(id: String) async throws {
        guard try await resolveOwner().deleteMemoryIfPresent(id: id) else { throw Self.notFound(id) }
    }

    public func accept(proposalID: String,
        publish: @MainActor @Sendable (_ change: () -> Void) -> Void = { $0() }
    ) async throws -> MemoryV2.MemoryRecord {
        let accepted = try await resolveOwner().acceptProposal(id: proposalID, context: MemoryWriteContext(turn: nil, senseReads: nil, telling: nil))
        proposalsRead.write { publish { proposals.removeAll { $0.id == proposalID } } }
        return accepted
    }

    public func reject(proposalID: String, reason: String,
        publish: @MainActor @Sendable (_ change: () -> Void) -> Void = { $0() }
    ) async throws {
        _ = try await resolveOwner().rejectProposal(id: proposalID, reason: reason.isEmpty ? nil : reason)
        proposalsRead.write { publish { proposals.removeAll { $0.id == proposalID } } }
    }

    nonisolated private static func notFound(_ id: String) -> NSError {
        NSError(domain: "NativeAgent", code: 404, userInfo: [
            NSLocalizedDescriptionKey: "memory id not found: \(id)"
        ])
    }

    // MARK: - Search

    /// Clear recall for queries under three characters; resolve kept records through canonical ids. A face refresh re-ranks without recording another use.
    @discardableResult
    public func search(query: String, recordingUsage: Bool = true) async -> MemorySearchReading {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchRead.write {
            searchQuery = trimmed
            searchResultQuery = nil
            searchIsLoading = trimmed.count >= 3
            searchResults = nil
            searchError = nil
        }
        guard let reading = await readSearch(recordingUsage: recordingUsage) else {
            return MemorySearchReading(query: trimmed, records: nil, issue: nil)
        }
        return reading
    }

    /// Re-rank the owner's current query without setting it again or crediting another use. Query selection and read admission share main.
    public func refreshSearch() async {
        _ = await readSearch(recordingUsage: false)
    }

    private func readSearch(recordingUsage: Bool) async -> MemorySearchReading? {
        guard let trimmed = searchQuery, trimmed.count >= 3 else { return nil }
        let prior = lastSuccessfulSearch
        // Failed reads retain proven rows with their actual query, never a substitute search.
        let reading = await searchRead.read { () -> (String?, [MemoryV2.MemoryRecord]?, String?, [String]) in
            do {
                // Credit usage only after accepted publication, never retrieval.
                let response = try await recallForSearch(trimmed)
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
                Task { await recordSearchHits(ids: deliveredIDs) }
            }
        }
        return MemorySearchReading(query: trimmed, records: reading.2 == nil ? reading.1 : nil, issue: reading.2)
    }

    private nonisolated func recallForSearch(_ query: String) async throws -> MemoryV2RecallResponse {
        try await resolveOwner().recall(MemoryV2RecallRequest(text: query, topK: 50, persona: nil), recordingUsage: false)
    }

    private nonisolated func recordSearchHits(ids: [String]) async {
        do { try await resolveOwner().recordRecallHits(ids: ids) }
        catch { nativeLog("Memory search: delivered-hit usage could not be recorded (%@)", error.localizedDescription) }
    }

    // MARK: - Knowledge Graph

    /// A mounted graph owns its subscription, not another copy of the graph. Watch SQLite and its live WAL before reading.
    @concurrent public nonisolated func watchGraphChanges() async {
        let changes = FileChangeEvents(paths: [graphPath, URL(fileURLWithPath: graphPath.path + "-wal")], emitInitial: false)
        await withTaskCancellationHandler {
            let armed = await changes.waitUntilArmed()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                graphObservationError = armed ? nil : "Knowledge graph live updates could not be observed. Reopen the graph to check again."
            }
            await loadGraph()
            guard !Task.isCancelled else { return }
            if await graphLoadError == nil { await refreshDiagnostics() }
            for await _ in changes.stream {
                guard !Task.isCancelled else { break }
                await loadGraph()
            }
            if !Task.isCancelled, armed {
                await MainActor.run {
                    graphObservationError = "Knowledge graph live observation stopped. Reopen the graph to check again; the displayed snapshot is retained."
                }
            }
        } onCancel: {
            Task.detached(priority: .utility) { changes.cancel() }
        }
        changes.cancel()
    }

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
        graphReadRequested = true
        if graphRead == nil {
            graphRead = Task {
                graphLoading = true
                while graphReadRequested {
                    graphReadRequested = false
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
