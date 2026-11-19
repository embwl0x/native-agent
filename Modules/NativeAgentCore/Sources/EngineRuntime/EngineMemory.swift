import Foundation
import NativeAgentCore
import Observation
import PersistenceCore
import MemoryV2
import TrustCenter
import NativeAgentShared
import DeviceSync
// Blueprint: | `EngineMemory.swift` | Canonical memory projections; committed column-region observations and checked graph reads through LatestRead |

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
    private var pageObservationIssues: [MemoryStorage.PageProjection: String] = [:]

    /// Each surface owns its query, admitted rows and publication gate; nil rows remain unavailable evidence.
    private struct SearchState {
        var query: String?
        var results: [MemoryV2.MemoryRecord]?
        var error: String?
        var resultQuery: String?
        var loading = false
        let read = LatestRead()
        var lastSuccessful: (query: String, records: [MemoryV2.MemoryRecord])?
    }
    private var searchesByPhoneSurface: [Bool: SearchState] = [:]
    private func searchState(surface: String?) -> SearchState {
        if let state = searchesByPhoneSurface[surface == "ios"] { return state }
        let state = SearchState()
        searchesByPhoneSurface[surface == "ios"] = state
        return state
    }
    public func searchSnapshot(surface: String?) -> (query: String?, results: [MemoryV2.MemoryRecord]?, error: String?,
                                                     resultQuery: String?, loading: Bool) {
        let state = searchState(surface: surface)
        return (state.query, state.results, state.error, state.resultQuery, state.loading)
    }

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

    public func checkPageObservation(_ projection: MemoryStorage.PageProjection) throws {
        if let issue = pageObservationIssues[projection] { throw MemoryStorageError.databaseUnavailable(issue) }
    }

    @concurrent public nonisolated func observePage(_ projection: MemoryStorage.PageProjection,
                                                   changed: @escaping @Sendable () async -> Void) async {
        do {
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            await storage.observePage(projection, changed: changed) { issue in
                await self.pageObservationFailed(projection, issue: issue)
                await changed()
            }
        } catch {
            guard !Task.isCancelled else { return }
            await pageObservationFailed(projection, issue: error.localizedDescription)
            await changed()
        }
    }

    private func pageObservationFailed(_ projection: MemoryStorage.PageProjection, issue: String) {
        pageObservationIssues[projection] = issue
        if projection == .graph { graphObservationError = issue }
    }

    @concurrent public nonisolated func todayMoments(_ day: Date, calendar: Calendar) async throws
        -> (rows: [(id: String, at: Double, text: String)], total: Int, firstAt: Double?, unreadable: Bool) {
        try await checkPageObservation(.moments)
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        return try await storage.moments(on: day, calendar: calendar) { content, quote in
            let quote = TodayWords.plain(quote ?? "")
            return quote.isEmpty ? TodayWords.plain(content) : quote
        }
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
            let newest = try await storage.listMemories(persona: nil, status: "active", limit: limit, keepingGraduated: true)
            // A bounded list keeps every pin, older than its newest rows or not.
            let pinned = try await limit == nil ? [] : storage.listMemories(persona: nil, status: "active", keepingGraduated: true, pinnedOnly: true)
            let shown = Set(newest.map(\.id))
            stored = newest + pinned.filter { !shown.contains($0.id) }
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
    public func search(query: String, recordingUsage: Bool = true, surface: String? = nil) async -> MemorySearchReading {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var state = searchState(surface: surface)
        state.read.write {
            state.query = trimmed
            state.resultQuery = nil
            state.loading = trimmed.count >= 3
            state.results = nil
            state.error = nil
            searchesByPhoneSurface[surface == "ios"] = state
        }
        guard let reading = await readSearch(recordingUsage: recordingUsage, surface: surface) else {
            return MemorySearchReading(query: trimmed, records: nil, issue: nil)
        }
        return reading
    }

    /// Re-rank the owner's current query without setting it again or crediting another use. Query selection and read admission share main.
    public func refreshSearch(surface: String? = nil) async {
        _ = await readSearch(recordingUsage: false, surface: surface)
    }

    private func readSearch(recordingUsage: Bool, surface: String?) async -> MemorySearchReading? {
        let selected = searchState(surface: surface)
        guard let trimmed = selected.query, trimmed.count >= 3 else { return nil }
        let prior = selected.lastSuccessful
        // Failed reads retain proven rows with their actual query, never a substitute search.
        let reading = await selected.read.read { () -> (String?, [MemoryV2.MemoryRecord]?, String?, [String]) in
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
            var state = searchState(surface: surface)
            state.resultQuery = query
            state.results = records
            state.error = error
            state.loading = false
            if error == nil, let query, let records { state.lastSuccessful = (query, records) }
            searchesByPhoneSurface[surface == "ios"] = state
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
