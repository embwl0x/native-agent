import Foundation
import NativeAgentCore
import Observation
import PersistenceCore
import MemoryV2
import TrustCenter
import NativeAgentShared
import DeviceSync
// Blueprint: | `EngineMemory.swift` | Memory v2 status and read availability publish through `refreshStatuses`; pending proposals publish checked rows and failure together through `proposals(status:)`, retaining checked rows on failure and leaving decision animation to the Mac; memory reads/search/writes and durable review-reminder crossing; one checked `graphSnapshot` shared by Knowledge Graph and Capabilities; `ProposalRecord` evidence; LatestRead orders pending proposals and memory status; committed proposal decisions use write() with the Mac's existing animation transaction. |

/// `NativeAgentEngine.memory` (S10's first typed facade): MemoryV2 and the
/// Knowledge Graph for one data root, in
/// core types. The kept list, the review queue, search and the graph are
/// observable state the Memories and Knowledge Graph pages render; phone
/// lanes use the same owner.
@MainActor
@Observable
public final class MemoryFacade {
    public nonisolated let dataRoot: URL
    private var embeddingSource: (owner: SwiftNativeMemoryV2, runtime: ManagedEmbeddingProvider)?
    @ObservationIgnored private let embeddingsRead = LatestRead()
    public private(set) var embeddingsError: String?
    public var embeddingsStatus: EmbeddingsStatus? {
        embeddingSource.map { MemoryStatusProjection.embeddingsStatus(from: $0.runtime.snapshot()) }
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
    @ObservationIgnored private let statusesRead = LatestRead()
    @ObservationIgnored private let proposalsRead = LatestRead()

    /// The newest 200 active memories, written by the app's refresh paths.
    public var memories: [MemoryV2.MemoryRecord] = []
    @ObservationIgnored private let memoriesRead = LatestRead()

    @discardableResult
    public func refreshMemories() async throws -> [MemoryV2.MemoryRecord] {
        try await memoriesRead.read({ try await activeMemories() }, publish: { memories = $0 })
    }
    public var totalCount: Int? { status?.counts?.active }
    public private(set) var diagnostics: MemoryV2NativeStackSnapshot = .empty
    public private(set) var diagnosticsCheckedAt: Date?
    /// Pending proposals that still pass review.
    public private(set) var proposals: [ProposalRecord] = [] {
        didSet { proposalsDidChange?() }
    }
    @ObservationIgnored public var proposalsDidChange: (@MainActor () -> Void)?

    public private(set) var proposalsReadFailed = false
    public private(set) var rejectedProposals: [ProposalRecord] = []
    public private(set) var rejectedHistoryError: String?
    @ObservationIgnored private lazy var rejectedHistoryRead = LatestRead()
    @ObservationIgnored private lazy var diagnosticsRead = LatestRead()
    @ObservationIgnored private lazy var graphSnapshotRead = LatestRead()

    /// Semantic search for the Memories field. nil results mean no search.
    public private(set) var searchResults: [MemoryV2.MemoryRecord]?
    public private(set) var searchError: String?
    /// Normalized query that produced `searchResults`. Views compare it
    /// before rendering an earlier response under new keystrokes.
    public private(set) var searchResultQuery: String?
    /// A semantic request is in flight for `searchResultQuery`, distinct from
    /// an empty result.
    public private(set) var searchIsLoading = false
    @ObservationIgnored private lazy var searchRead = LatestRead()

    /// One checked whole-graph snapshot for the graph page and Capabilities.
    public private(set) var graphSnapshot: CanonicalAgentGraphProjection?
    public var graphEntities: [KnowledgeGraphEntity] { graphSnapshot?.canvasEntities ?? [] }
    public var graphEdges: [KnowledgeGraphEdge] { graphSnapshot?.canvasEdges ?? [] }
    public var graphTotalEntities: Int { graphEntities.count }
    public var graphTotalEdges: Int? { graphSnapshot?.canvasEdges.count }
    public private(set) var graphLoading = false
    /// Why the last whole-graph read failed; nil after a good read.
    public private(set) var graphLoadError: String?
    @ObservationIgnored private var graphRead: Task<Void, Never>?
    @ObservationIgnored private var graphReadsRequested = 0

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    /// The canonical writer for this root: `.shared` for the default root,
    /// an isolated actor for an override, so a listing and its buttons act on
    /// the same store.
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

    /// Active memories: the newest `limit` (nil is every one), graduated
    /// lessons among them as history, or the recall-eligible rows for `ids`
    /// (search resolves hits outside the bounded list).
    public nonisolated func activeMemories(ids: [String]? = nil, limit: Int? = 200) async throws -> [MemoryV2.MemoryRecord] {
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        let stored: [StoredMemory]
        if let ids {
            var matches: [StoredMemory] = []
            for id in ids {
                if let memory = try await storage.memory(id: id), memory.status == "active",
                   !MemoryLifecycle.recallExcluded.contains(memory.lifecycle) {
                    matches.append(memory)
                }
            }
            stored = matches
        } else {
            stored = try await storage.listMemories(persona: nil, status: "active", limit: limit, keepingGraduated: true)
        }
        return stored.map(MemoryV2.MemoryRecord.init(stored:))
    }

    /// Proposals by status. Pending rows are only the ones still awaiting
    /// review: a statement whose successor is recorded, or one that fails the
    /// current quality contract, is never offered for acceptance. History
    /// reads keep every row, including the fragments the gate let go.
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
                proposalsReadFailed = false
                if proposals != records { publish { proposals = records } }
            case .failure: proposalsReadFailed = true
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
            do { memory = try await MemoryStatusProjection.getMemoryV2Status(dataRoot: dataRoot) }
            catch { failures.append(("memory v2 status", "getMemoryV2Status", error)) }
            return (memory, failures)
        }, publish: { read in
            if let value = read.0 { status = value }
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

    /// One new memory in this root's store. Resolving the owner may open and
    /// migrate the store, so this never runs on the caller's actor.
    public nonisolated func store(content: String, source: String, metadata: JSONValue?) async throws {
        _ = try await owner.store(content: content, source: source, metadata: metadata)
    }

    /// Merges only `pinned` inside the canonical transaction.
    public nonisolated func setPinned(_ pinned: Bool, id: String) async throws {
        do {
            _ = try await owner.updateMemory(id: id, update: .object(["pinned": .bool(pinned)]))
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
        let accepted = try await owner.acceptProposal(id: proposalID)
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

    /// Semantic recall over this root, projected onto kept records by id and
    /// unioned with text matches. Queries under three characters clear it.
    public func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchRead.write {
            searchResultQuery = trimmed
            searchIsLoading = trimmed.count >= 3
            searchResults = nil
            searchError = nil
        }
        if trimmed.count < 3 {
            searchIsLoading = false
            return
        }
        // The query clears its old result immediately; LatestRead owns publication.
        _ = await searchRead.read { () -> (String, [MemoryV2.MemoryRecord]?, String?, [String]) in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return (trimmed, nil, nil, [])
            }
            // Semantic recall can return nothing where an obvious text match
            // exists, so text matches always ride along.
            let lower = trimmed.lowercased()
            // Only the memory's words: its layer is an internal label ("semantic"
            // on every row), and matching it put every row under "man" or "sem".
            let memories = memories
            let lexical = await Task.detached {
                memories.filter { $0.text.lowercased().contains(lower) }
            }.value
            let owner = owner
            do {
                // User, 2026-09-06: retrieve WITHOUT crediting use_count. This runs
                // on every keystroke pause and asks for 50 rows, most of which
                // never reach the list; the rows actually shown are credited below.
                let response = try await owner.recall(
                    MemoryV2RecallRequest(text: trimmed, topK: 50, persona: nil),
                    recordingUsage: false
                )
                let hitIDs = response.hits.compactMap { hit -> String? in
                    guard case .object(let obj)? = hit.extras,
                          case .string(let id)? = obj["id"] else { return nil }
                    return id
                }
                // A matching older memory must not disappear because it is
                // outside the newest 200 rows.
                let records = try await activeMemories(ids: hitIDs)
                var seen = Set<String>()
                var ordered: [MemoryV2.MemoryRecord] = []
                var deliveredIDs: [String] = []
                for id in hitIDs where !seen.contains(id) {
                    guard let record = records.first(where: { $0.id == id }) else { continue }
                    seen.insert(id)
                    ordered.append(record)
                    deliveredIDs.append(id)
                }
                for record in lexical where !seen.contains(record.id) {
                    seen.insert(record.id)
                    ordered.append(record)
                }
                return (trimmed, ordered, nil, deliveredIDs)
            } catch {
                return (trimmed, lexical, "Semantic memory is unavailable; showing text matches only.", [])
            }
        } publish: { query, records, error, deliveredIDs in
            searchResultQuery = query
            searchResults = records
            searchError = error
            searchIsLoading = false
            // Credit exactly what the semantic lane delivered. Fire-and-forget,
            // like recall's own bump: a dropped bump self-heals on next serve.
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
            .appendingPathComponent("knowledge_graph.json")
    }

    public nonisolated func searchGraph(query: String) async throws -> GraphSearchResponse {
        try await KnowledgeGraphReadProjection.searchGraph(query: query, graphPath: graphPath)
    }

    /// Reads one complete checked snapshot. A failed read keeps the prior
    /// snapshot and says why in `graphLoadError`.
    ///
    /// One read at a time for every mounted graph page, and a page going away
    /// does not stop the read another page is showing. A call while a read is
    /// in flight is served by a fresh read after it (a reload after a sweep
    /// must not publish the pre-sweep pages); calls made meanwhile share it.
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
            do { return Result<CanonicalAgentGraphProjection, Error>.success(try await KnowledgeGraphReadProjection.canonicalAgentGraphProjection(
                graphPath: graphPath, timestamp: SwiftNativeManifestSigner.isoTimestamp
            )) } catch { return .failure(error) }
        } publish: { result in
            switch result {
            case .success(let snapshot): graphSnapshot = snapshot; graphLoadError = nil
            case .failure(let error): graphLoadError = error.localizedDescription
            }
        }
    }

    /// Detail is derived from the exact whole-graph revision beside it.
    public func neighborhood(entityID: String) -> KnowledgeGraphNeighborhood? {
        graphSnapshot?.neighborhood(entityID: entityID)
    }
}

extension ProposalRecord {
    /// Supporting sessions and recurrence, from the extractor's metadata or,
    /// for an adaptive-promoter row, its source session.
    public var evidence: (sessionIDs: [String], recurrenceCount: Int) {
        var sessionIDs: [String] = []
        var recurrenceCount: Int?
        if case .object(let object)? = metadata {
            if case .array(let values)? = object["supporting_session_ids"] {
                sessionIDs = values.compactMap { value in
                    guard case .string(let raw) = value else { return nil }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
            }
            switch object["recurrence_count"] {
            case .int(let value)?: recurrenceCount = Int(value)
            case .double(let value)?: recurrenceCount = Int(exactly: value.rounded(.towardZero))
            case .string(let value)?: recurrenceCount = Int(value)
            default: break
            }
        }
        if sessionIDs.isEmpty,
           let source,
           source.lowercased().hasPrefix("adaptive-promoter:") {
            let sessionID = String(source.dropFirst("adaptive-promoter:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sessionID.isEmpty { sessionIDs = [sessionID] }
        }
        sessionIDs = Array(Set(sessionIDs)).sorted()
        return (sessionIDs, max(1, recurrenceCount ?? 1))
    }

    public var evidenceSummary: String {
        let (sessionIDs, recurrence) = evidence
        let sessions = sessionIDs.count
        if sessions == 0 {
            return recurrence == 1
                ? "Observed once; session evidence unavailable"
                : "Observed \(recurrence)x; session evidence unavailable"
        }
        return "Observed \(recurrence)x in \(sessions) session\(sessions == 1 ? "" : "s")"
    }
}

extension MemoryFacade {
    private static let reviewReminderThreshold = 10
    private static let reviewReminderArmedKey = "memoryReviewReminder.belowThreshold"

    public func reviewReminder(pending: Int, agentName: String) -> (title: String, body: String)? {
        let defaults = UserDefaults.standard
        // Absent key reads as armed, so a first crossing on an existing pile fires.
        let armed = defaults.object(forKey: Self.reviewReminderArmedKey) as? Bool ?? true
        if pending < Self.reviewReminderThreshold {
            if !armed { defaults.set(true, forKey: Self.reviewReminderArmedKey) }
            return nil
        }
        guard armed else { return nil }
        defaults.set(false, forKey: Self.reviewReminderArmedKey)
        return (
            title: "Memories to look over",
            body: "\(DeskPageWords.spelled(pending)) things \(agentName) wants to keep are waiting for your yes or no on the Memories page."
        )
    }
}
