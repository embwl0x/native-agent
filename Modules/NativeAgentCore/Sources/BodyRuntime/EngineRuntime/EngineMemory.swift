import Foundation
import NativeAgentCore
import Observation
import Synchronization
import PersistenceCore
import MindCore
import DeskCore
import NativeAgentShared
// Blueprint: | `EngineMemory.swift` | Canonical memory projections; committed column-region observations and checked graph reads through LatestRead |

/// Share MemoryV2 and Knowledge Graph owners per root across observable pages and phone reads.
@MainActor
@Observable
public final class MemoryFacade {
    public nonisolated let dataRoot: URL
    private typealias EmbeddingSource = (owner: SwiftNativeMemoryV2, runtime: ManagedEmbeddingProvider)
    private nonisolated let source = Mutex<EmbeddingSource?>(nil)
    private nonisolated var embeddingSource: EmbeddingSource? {
        get {
            access(keyPath: \.embeddingSource)
            return source.withLock { $0 }
        }
        set {
            withMutation(keyPath: \.embeddingSource) { source.withLock { $0 = newValue } }
        }
    }
    @ObservationIgnored private var embeddingChanges: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let embeddingsRead = LatestRead()
    public private(set) var embeddingsError: String?
    /// The runtime snapshot checks saved configuration and installed models. Observe its source and runtime where each is owned, off main for disk work.
    @concurrent public nonisolated func embeddingSnapshots() async -> Observations<EmbeddingRuntimeSnapshot?, Never> {
        if embeddingSource == nil { await loadEmbeddings() }
        return Observations { [weak self] in self?.embeddingSource?.runtime.snapshot() }
    }

    public func readEmbeddingSnapshot(onChange: (@Sendable () -> Void)? = nil) async -> EmbeddingRuntimeSnapshot? {
        guard let onChange else {
            if embeddingSource == nil { await loadEmbeddings() }
            let runtime = embeddingSource?.runtime
            return await Task.detached(priority: .userInitiated) { runtime?.snapshot() }.value
        }
        var readings = await embeddingSnapshots().makeAsyncIterator()
        let snapshot = await readings.next()
        if !Task.isCancelled {
            let id = UUID()
            embeddingChanges[id] = Task { [weak self] in
                defer { self?.embeddingChanges.removeValue(forKey: id) }
                if await readings.next() != nil, !Task.isCancelled { onChange() }
            }
        }
        return snapshot ?? nil
    }

    deinit { for change in embeddingChanges.values { change.cancel() } }

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

    public func teachAssistantName(_ profile: PersonalityProfile?) {
        let name = profile?.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !name.isEmpty { AdaptiveCandidateHygiene.insertAssistantName(name) }
    }

    public private(set) var status: MemoryV2Status?
    public private(set) var statusRefresh: PanelRefreshStatus?
    public private(set) var statusReadError: String?
    @ObservationIgnored private let statusesRead = LatestRead()
    @ObservationIgnored private let proposalsRead = LatestRead()

    @discardableResult
    public func refreshMemories() async throws -> [MindCore.MemoryRecord] {
        try await activeMemories()
    }
    public var totalCount: Int? { status?.counts?.active }
    public private(set) var diagnostics: MemoryV2NativeStackSnapshot = .empty
    public private(set) var diagnosticsCheckedAt: Date?
    public private(set) var proposals: [ProposalRecord] = [] {
        didSet { proposalsDidChange?() }
    }
    @ObservationIgnored public var proposalsDidChange: (@MainActor () -> Void)?

    public private(set) var rejectedProposals: [ProposalRecord] = []
    public private(set) var rejectedHistoryError: String?
    @ObservationIgnored private lazy var rejectedHistoryRead = LatestRead()
    @ObservationIgnored private lazy var diagnosticsRead = LatestRead()
    @ObservationIgnored private lazy var graphSnapshotRead = LatestRead()
    private var pageObservationIssues: [MemoryStorage.PageProjection: String] = [:]

    /// Each surface owns its query, admitted rows and publication gate; nil rows remain unavailable evidence.
    private struct SearchState {
        var query: String?
        var results: [MindCore.MemoryRecord]?
        var error: String?
        var resultQuery: String?
        var loading = false
        let read = LatestRead()
        var lastSuccessful: (query: String, records: [MindCore.MemoryRecord])?
    }
    private var searchesByPhoneSurface: [Bool: SearchState] = [:]
    private func searchState(surface: String?) -> SearchState {
        if let state = searchesByPhoneSurface[surface == "ios"] { return state }
        let state = SearchState()
        searchesByPhoneSurface[surface == "ios"] = state
        return state
    }
    public func searchSnapshot(surface: String?) -> (query: String?, results: [MindCore.MemoryRecord]?, error: String?,
                                                     resultQuery: String?, loading: Bool) {
        let state = searchState(surface: surface)
        return (state.query, state.results, state.error, state.resultQuery, state.loading)
    }

    /// Share one checked whole-graph snapshot across graph and Capabilities pages.
    public private(set) var graphSnapshot: CanonicalAgentGraphReadout?
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

    /// Resolve search hits by id even outside the bounded newest-memory list.
    @concurrent public nonisolated func activeMemories(ids: [String]? = nil, limit: Int? = 200) async throws -> [MindCore.MemoryRecord] {
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
        let now = Date()
        return stored.filter { MemoryRecallScoring.hasStarted(validFrom: $0.validFrom, at: now) }
            .map(MindCore.MemoryRecord.init(stored:))
    }

    /// Pending review excludes superseded or inadmissible statements; history retains all rows.
    public func proposals(status: String,
        publish: @MainActor @Sendable (_ change: () -> Void) -> Void = { $0() }
    ) async throws -> [ProposalRecord] {
        guard status == "pending" else { return try await readProposals(status: status) }
        return try await proposalsRead.read({
            try await readProposals(status: status)
        }, publish: { records in
            if proposals != records { publish { proposals = records } }
            else { proposalsDidChange?() }
        })
    }

    @concurrent private nonisolated func readProposals(status: String) async throws -> [ProposalRecord] {
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        return try await storage.listProposals(status: status)
            .filter { status != "pending" || SwiftNativeMemoryV2.awaitsReview(content: $0.content, metadata: $0.metadata) }
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

    public nonisolated func delete(id: String) async throws {
        guard try await resolveOwner().deleteMemoryIfPresent(id: id) else { throw Self.notFound(id) }
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
        let reading = await selected.read.read { () -> (String?, [MindCore.MemoryRecord]?, String?, [String]) in
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

    /// Keep the prior snapshot with its error on failure. Share one graph read across mounts; joining refreshes get a fresh trailing read so captured bytes
    /// cannot predate the change.
    public func loadGraph() async {
        graphReadRequested = true
        if graphRead == nil {
            graphRead = Task {
                while graphReadRequested {
                    graphReadRequested = false
                    await readGraph()
                }
                graphRead = nil
            }
        }
        await graphRead?.value
    }

    private func readGraph() async {
        _ = await graphSnapshotRead.read {
            do { return Result<CanonicalAgentGraphReadout, Error>.success(try await AgentGraphReads.canonicalAgentGraphProjection(
                graphPath: DataRootPaths.memoryDatabase(in: dataRoot), timestamp: SwiftNativeManifestSigner.isoTimestamp
            )) } catch { return .failure(error) }
        } publish: { result in
            switch result {
            case .success(let snapshot): graphSnapshot = snapshot; graphLoadError = nil
            case .failure(let error): graphLoadError = error.localizedDescription
            }
        }
    }
}
