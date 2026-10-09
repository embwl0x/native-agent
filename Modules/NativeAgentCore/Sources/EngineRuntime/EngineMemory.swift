import Foundation
import Observation
import PersistenceCore
import MemoryV2
import KnowledgeGraph

/// `NativeAgentEngine.memory` (S10's first typed facade; the domain's
/// NativeClient seam is gone): MemoryV2 and the Knowledge Graph for one data root, in
/// core types. The kept list, the review queue, search and the graph are
/// observable state the Memories and Knowledge Graph pages render; the reads
/// and writes are nonisolated so the phone lanes use the same owner.
@MainActor
@Observable
public final class MemoryFacade {
    public nonisolated let dataRoot: URL

    /// The newest 200 active memories, written by the app's refresh paths.
    public var memories: [MemoryV2.MemoryRecord] = []
    /// Pending proposals that still pass review.
    public var proposals: [ProposalRecord] = [] {
        didSet { proposalsDidChange?() }
    }
    @ObservationIgnored public var proposalsDidChange: (@MainActor () -> Void)?

    /// Semantic search for the Memories field. nil results mean no search.
    public private(set) var searchResults: [MemoryV2.MemoryRecord]?
    public private(set) var searchError: String?
    /// Normalized query that produced `searchResults`. Views compare it
    /// before rendering an earlier response under new keystrokes.
    public private(set) var searchResultQuery: String?
    /// A semantic request is in flight for `searchResultQuery`, distinct from
    /// an empty result.
    public private(set) var searchIsLoading = false
    @ObservationIgnored private var searchGate = LatestAsyncRequestGate()

    /// The whole graph, every page, edges deduped.
    public private(set) var graphEntities: [KnowledgeGraphEntity] = []
    public private(set) var graphEdges: [KnowledgeGraphEdge] = []
    public private(set) var graphTotalEntities = 0
    public private(set) var graphTotalEdges: Int?
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

    /// Active memories: the newest `limit` (nil is every one), or the
    /// recall-eligible rows for `ids` (search resolves hits outside the
    /// bounded list).
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
            stored = try await storage.listMemories(persona: nil, status: "active", limit: limit)
        }
        return stored.map(MemoryV2.MemoryRecord.init(stored:))
    }

    /// Proposals by status. Pending rows are only the ones still awaiting
    /// review: a statement whose successor is recorded, or one that fails the
    /// current quality contract, is never offered for acceptance. History
    /// reads keep every row, including the fragments the gate let go.
    public nonisolated func proposals(status: String) async throws -> [ProposalRecord] {
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        return try await storage.listProposals(status: status)
            .filter { status != "pending" || SwiftNativeMemoryV2.awaitsReview(content: $0.content, source: $0.source, metadata: $0.metadata) }
            .map(ProposalRecord.init(stored:))
    }

    // MARK: - Writes

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

    public nonisolated func accept(proposalID: String) async throws -> MemoryV2.MemoryRecord {
        try await owner.acceptProposal(id: proposalID)
    }

    public nonisolated func reject(proposalID: String, reason: String) async throws {
        _ = try await owner.rejectProposal(id: proposalID, reason: reason.isEmpty ? nil : reason)
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
        let requestToken = searchGate.begin()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResultQuery = trimmed
        searchIsLoading = trimmed.count >= 3
        searchResults = nil
        searchError = nil
        if trimmed.count < 3 {
            searchIsLoading = false
            return
        }
        // Debounce at the request-owner boundary: the view invalidates a prior
        // result immediately, and the generation gate keeps a canceled older
        // query from landing after the newest keystroke.
        do {
            try await Task.sleep(nanoseconds: 150_000_000)
        } catch {
            if searchGate.accepts(requestToken) { searchIsLoading = false }
            return
        }
        guard !Task.isCancelled, searchGate.accepts(requestToken) else { return }
        // Semantic recall can return nothing where an obvious text match
        // exists, so text matches always ride along.
        let lower = trimmed.lowercased()
        // Only the memory's words: its layer is an internal label ("semantic"
        // on every row), and matching it put every row under "man" or "sem".
        let lexical = memories.filter { $0.text.lowercased().contains(lower) }
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
            guard !Task.isCancelled, searchGate.accepts(requestToken) else { return }
            searchResults = ordered
            searchError = nil
            searchIsLoading = false
            // Credit exactly what the semantic lane delivered. Fire-and-forget,
            // like recall's own bump: a dropped bump self-heals on next serve.
            if !deliveredIDs.isEmpty {
                Task { try? await owner.recordRecallHits(ids: deliveredIDs) }
            }
        } catch {
            guard !Task.isCancelled, searchGate.accepts(requestToken) else { return }
            searchResults = lexical
            searchError = "Semantic memory is unavailable; showing text matches only."
            searchIsLoading = false
        }
    }

    // MARK: - Knowledge Graph

    nonisolated private var graphReader: any KnowledgeGraphReader {
        makeKnowledgeGraphReader(
            graphPath: dataRoot
                .appendingPathComponent("memory", isDirectory: true)
                .appendingPathComponent("knowledge_graph.json")
        )
    }

    /// Reads every page. Termination is store-authoritative (total_entities)
    /// with an empty-page break and a hard page cap. Pages carry the edges
    /// touching their own entities, so an edge can repeat across pages and is
    /// deduped by from/to/kind. A failed read keeps what loaded before and
    /// says why in `graphLoadError`.
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
        graphLoadError = nil
        let reader = graphReader
        do {
            var all: [KnowledgeGraphEntity] = []
            var allEdges: [KnowledgeGraphEdge] = []
            var seenEdgeKeys = Set<String>()
            var total = 0
            var totalEdges: Int?
            let maxPages = 500
            var page = 0
            while page < maxPages {
                let resp = try await reader.entityPageChecked(page: page)
                if page == 0 {
                    total = resp.totalEntities
                    totalEdges = resp.totalEdges
                }
                if resp.entities.isEmpty { break }
                all.append(contentsOf: resp.entities)
                for edge in resp.edges ?? [] where seenEdgeKeys.insert(edge.id).inserted {
                    allEdges.append(edge)
                }
                if total > 0 && all.count >= total { break }
                page += 1
            }
            graphEntities = all
            graphEdges = allEdges
            graphTotalEntities = total > 0 ? total : all.count
            graphTotalEdges = totalEdges
        } catch {
            graphLoadError = error.localizedDescription
        }
    }

    /// One entity with its edges and neighbours. An unknown id throws
    /// `URLError(.resourceUnavailable)`, apart from store read errors.
    public nonisolated func neighborhood(entityID: String) async throws -> KnowledgeGraphNeighborhood {
        guard let found = try await graphReader.neighborhoodChecked(id: entityID) else {
            throw URLError(.resourceUnavailable)
        }
        return found
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
