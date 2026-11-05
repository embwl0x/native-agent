import Foundation
import MemoryV2
import NativeAgentShared
// Blueprint: | `MemoriesFace.swift` | Memories face and actions over canonical MemoryFacade reads and writes |

extension NativeAgentEngine {
    @MainActor func memoriesFace() async throws -> (PartFace, UInt64) {
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        var sections: [PartFace.Section] = []
        var kept: [MemoryV2.MemoryRecord]?
        var waiting: [ProposalRecord]?
        do { kept = try await memory.refreshMemories() }
        catch is CancellationError { throw CancellationError() }
        catch { sections.append(MemoriesFaceText.issue("kept", title: "Saved memories unavailable", error: error)) }
        do { waiting = try await memory.proposals(status: "pending") }
        catch is CancellationError { throw CancellationError() }
        catch { sections.append(MemoriesFaceText.issue("waiting", title: "Proposals unavailable", error: error)) }
        await memory.refreshRejectedHistory()
        let statusFailures = await memory.refreshStatuses()
        try Task.checkCancellation()

        if let waiting, !waiting.isEmpty {
            // The waiting style draws words only; list rows keep both decisions reachable.
            sections.append(.init(id: "waiting", title: "Waiting for you", style: .list, rows: waiting.map { proposal in
                .init(id: "proposal:" + proposal.id, title: proposal.content,
                      detail: MemoriesFaceText.proposalKind(proposal), at: proposal.createdAt, tone: .attention,
                      actions: [.init(id: "accept", label: "Keep", role: .primary),
                                .init(id: "reject", label: "Don't keep", role: .destructive)])
            }))
        }

        let query = memory.searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The page's own search: what the person types is searched on return, as the Mac's search field always did.
        sections.append(.init(id: "find", style: .list, rows: [
            .init(id: "search-field", title: "Search what I've kept", control: .field(query ?? "", placeholder: "At least three letters")),
        ]))
        if let query, query.count >= 3 {
            // Re-rank the current store, including older/new matches and recovery from a failed query. Publication never credits recall usage.
            await memory.search(query: query, recordingUsage: false)
            try Task.checkCancellation()
            var rows: [PartFace.Row] = []
            if let results = memory.searchResults {
                do { rows = try await memory.activeMemories(ids: results.map(\.id)).map { MemoriesFaceText.memoryRow($0, root: dataRoot) } }
                catch is CancellationError { throw CancellationError() }
                catch { rows.append(.init(id: "search-records-error", title: "Search records unavailable",
                                         detail: error.localizedDescription, tone: .failed)) }
            }
            if let error = memory.searchError {
                rows.insert(.init(id: "search-error", title: "Search unavailable", detail: error, tone: .failed), at: 0)
            } else if memory.searchIsLoading || memory.searchResults == nil {
                rows.append(.init(id: "search-unread", title: "Search results have not arrived.", tone: .quiet))
            } else if rows.isEmpty {
                rows.append(.init(id: "search-empty", title: "Nothing I've kept matches that.", tone: .quiet))
            }
            sections.append(.init(id: "search", title: "What I found", style: .list,
                                  footer: memory.searchResultQuery.map { "Results for ‘" + $0 + "’." }, rows: rows))
            sections.append(.init(id: "search-query", style: .list, rows: [
                .init(id: "search", title: "Search: “" + query + "”", actions: [.init(id: "clear", label: "Show all memories")])
            ]))
        } else if let kept {
            let ordered = MemoriesFaceText.ordered(kept)
            let pinned = ordered.filter { $0.pinned == true }
            let recent = ordered.filter { $0.pinned != true }
            if !pinned.isEmpty {
                sections.append(.init(id: "pinned", title: "Pinned", style: .list, rows: pinned.map { MemoriesFaceText.memoryRow($0, root: dataRoot) }))
            }
            if !recent.isEmpty {
                sections.append(.init(id: "recent", title: "What I've kept", style: .list, rows: recent.map { MemoriesFaceText.memoryRow($0, root: dataRoot) }))
            } else if kept.isEmpty {
                sections.append(.init(id: "empty", style: .note, rows: [.init(id: "empty", title: "It fills up as we talk.")]))
            }
        }

        if let error = memory.rejectedHistoryError {
            sections.append(.init(id: "rejected-error", style: .list, rows: [
                .init(id: "rejected-error", title: "Rejected history unavailable", detail: error, tone: .failed)
            ]))
        } else if !memory.rejectedProposals.isEmpty {
            sections.append(.init(id: "rejected", title: "Things I let go", style: .list, rows: memory.rejectedProposals.map { proposal in
                .init(id: "rejected:" + proposal.id, title: TodayWords.line(proposal.content, limit: 96),
                      detail: "I didn't keep this", at: proposal.createdAt, tone: .quiet,
                      open: MemoriesFaceTarget.rejected(proposal.id).link)
            }))
        }
        for failure in statusFailures {
            sections.append(MemoriesFaceText.issue("status-" + failure.endpoint, title: failure.label, error: failure.error))
        }
        sections.append(.init(id: "details", title: "Upkeep and details", style: .list, rows: [
            .init(id: "graph", title: "Knowledge graph", symbol: "circle.hexagonpath", open: MemoriesFaceTarget.graph.link),
            .init(id: "upkeep", title: "Memory status and Spotlight", detail: "Search model, saved-memory status and reindexing.",
                  symbol: "brain", open: MemoriesFaceTarget.upkeep.link),
            .init(id: "refresh", title: "Read my memories again", actions: [.init(id: "refresh", label: "Check again")])
        ]))
        let line: String
        if let kept {
            let total = statusFailures.isEmpty ? memory.totalCount.map { " of \($0) saved" } ?? " · total unavailable" : " · total unavailable"
            line = "\(kept.count) memories loaded" + total + "."
        } else { line = "Saved memories could not be read." }
        return (.init(title: "Memories", line: line, sections: sections), epoch)
    }

    @MainActor func memoriesAct(row: String, action: String, value: String?) async throws -> String? {
        if row == "search-field", action == "set" {
            let words = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard words.isEmpty || words.count >= 3 else {
                throw PartCallError(code: "short_query", message: "Search needs at least three letters; nothing was searched.")
            }
            await memory.search(query: words)
            return nil
        }
        guard value == nil else { throw PartCallError(code: "bad_value", message: "This memory action takes no value.") }
        if row == "refresh", action == "refresh" { return nil }
        if row == "search", action == "clear" {
            await memory.search(query: "")
            return nil
        }
        if row.hasPrefix("proposal:") {
            let id = String(row.dropFirst("proposal:".count))
            guard try await memory.proposals(status: "pending").contains(where: { $0.id == id }) else {
                throw PartCallError(code: "stale_proposal", message: "This proposal is no longer waiting for review; nothing changed.")
            }
            switch action {
            case "accept": _ = try await memory.accept(proposalID: id)
            case "reject": try await memory.reject(proposalID: id, reason: "")
            default: throw PartCallError(code: "no_action", message: "That proposal has no action called \(action).")
            }
            await approvals.refresh()
            await refreshMemoriesSearch()
            return action == "accept" ? "Kept it." : "Left it."
        }
        if row.hasPrefix("memory:") {
            let id = String(row.dropFirst("memory:".count))
            // Saved destinations include graduated rows; do not resolve them through recall eligibility.
            guard try await memory.activeMemories(limit: nil).contains(where: { $0.id == id }) else {
                throw PartCallError(code: "stale_memory", message: "This memory is unavailable in the current store; nothing changed.")
            }
            let message: String
            switch action {
            case "pin", "unpin":
                try await memory.setPinned(action == "pin", id: id)
                message = action == "pin" ? "Memory pinned" : "Memory unpinned"
            case "forget":
                try await memory.delete(id: id)
                message = "Forgotten."
            default: throw PartCallError(code: "no_action", message: "That memory has no action called \(action).")
            }
            await refreshMemoriesSearch()
            return message
        }
        throw PartCallError(code: "no_action", message: "This row has no action called \(action).")
    }

    @MainActor private func refreshMemoriesSearch() async {
        if let query = memory.searchQuery, query.count >= 3 { await memory.search(query: query) }
    }
}
