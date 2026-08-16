import Foundation
import KnowledgeGraph
import MemoryV2
import PersistenceCore

extension KnowledgeGraphView {
    func loadGraph() async {
        loading = true; defer { loading = false }
        // ui-honesty 2026-06-10: clear the previous error at the start of
        // every load — a stale failure message used to persist over a
        // subsequent successful refresh.
        errorMsg = nil
        do {
            // PATCH-2026-05-15: paginate through ALL pages. Previously only
            // page 0 was fetched, so the sidebar capped at one page (~100)
            // while the footer showed the true total (e.g. 887) and the
            // rest were unreachable. Termination is server-authoritative
            // (total_entities) with an empty-page break + hard page cap so
            // it can never loop forever regardless of server page size.
            var all: [KGEntity] = []
            var allEdges: [KGEdge] = []
            var seenEdgeKeys = Set<String>()
            var total = 0
            var totEdges: Int? = nil
            let maxPages = 500  // hard safety bound
            var page = 0
            while page < maxPages {
                let resp = try await api.getKnowledgeGraph(page: page)
                if page == 0 {
                    total = resp.totalEntities
                    totEdges = resp.totalEdges
                }
                if resp.entities.isEmpty { break }
                all.append(contentsOf: resp.entities)
                // F3: pages return scoped edges (touching only that page's entities),
                // so the same edge can appear on multiple pages — dedupe by from/to/kind.
                for edge in resp.edges ?? [] where seenEdgeKeys.insert(edge.id).inserted {
                    allEdges.append(edge)
                }
                if total > 0 && all.count >= total { break }
                page += 1
            }
            entities = all
            edges = allEdges
            totalEntities = total > 0 ? total : all.count
            totalEdges = totEdges
            lastLoadFailed = false
        } catch {
            // U5 W-C fix-round: keep whatever loaded previously (the banner
            // marks it stale) — but the error is rendered FIRST, never under
            // a fabricated healthy empty state.
            errorMsg = error.localizedDescription
            lastLoadFailed = true
        }
    }

    func enableKnowledgeGraph() async {
        guard !isEnablingGraph else { return }
        isEnablingGraph = true
        defer { isEnablingGraph = false }
        errorMsg = nil
        await appModel.patchMemoryPolicy(knowledgeGraphEnabled: true)
        await loadGraph()
    }

    // U5 W-C: GC sweep — dry-run preview, then user-confirmed apply.

    /// Build the live-memory fact list the GC reconciles against, from the
    /// same memory.sqlite MemoryV2 writes through.
    func listGCFacts(_ storage: MemoryStorage) async throws -> [KnowledgeGraphMemoryFact] {
        let mems = try await storage.listMemories(persona: nil, status: nil, limit: nil)
        return mems.map {
            KnowledgeGraphMemoryFact(
                id: $0.id,
                content: $0.content,
                source: $0.source,
                status: $0.status,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                metadata: $0.projectionMetadata
            )
        }
    }

    func previewGCSweep() async {
        guard !gcRunning else { return }
        gcRunning = true
        defer { gcRunning = false }
        gcStatus = nil
        do {
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(
                dataRoot: PersistenceCore.defaultDataRoot()
            )
            let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: await storage.path)
            let facts = try await listGCFacts(storage)
            let report = try await indexer.collectGarbage(liveFacts: facts, apply: false)
            if report.candidates.isEmpty {
                // U5 W-C fix-round (gpt-5.5 NIT): clear residue from any
                // previous preview — a stale candidate list must not survive
                // an empty dry-run (the confirmation dialog reads its count).
                gcCandidates = []
                gcStatus = "No orphaned entities."
            } else {
                gcCandidates = report.candidates
                showGCConfirm = true
            }
        } catch {
            errorMsg = "Orphan sweep failed: \(error.localizedDescription)"
        }
    }

    func applyGCSweep() async {
        guard !gcRunning else { return }
        gcRunning = true
        defer { gcRunning = false }
        do {
            // Re-list immediately before applying so the live set is fresh;
            // the GC re-scans inside its write transaction as well.
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(
                dataRoot: PersistenceCore.defaultDataRoot()
            )
            let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: await storage.path)
            let facts = try await listGCFacts(storage)
            // The confirmation dialog the user just clicked IS the approval —
            // that is the only path that sets approvedOverThreshold.
            let report = try await indexer.collectGarbage(
                liveFacts: facts,
                apply: true,
                approvedOverThreshold: true
            )
            gcStatus = "Removed \(report.entitiesDeleted) entities · \(report.edgesDeleted) edges."
            gcCandidates = []
            await loadGraph()
        } catch {
            errorMsg = "Orphan sweep failed: \(error.localizedDescription)"
        }
    }
}
