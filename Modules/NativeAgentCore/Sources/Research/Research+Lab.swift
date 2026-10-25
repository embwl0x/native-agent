import Foundation
import NativeAgentCore
import PersistenceCore
import Privacy
// Blueprint: | `Research+Lab.swift` | `SwiftNativeResearchClient`: `researchLabRuns`, `runResearchLab`; SearXNG evidence explicitly distinguishes unavailable from empty, an injected L0 part call selects sources and composes the brief, native validation binds selected sources to that search, and settlement commits locked capped history plus activity/trace receipts with native status/error truth; source selection, brief wording and `buildResearchBrief` moved to `Resources/abilities/research-lab.js` |

/// Authored content only. Identity, source evidence and publication remain native.
public struct ResearchLabProposal: Codable, Sendable {
    public let sources: [ResearchSearchResult]
    public let brief: String
}

extension SwiftNativeResearchClient {
    // MARK: research lab (wave 30 W17)

    /// Lock-free so the read-modify-write below can hold the file lock.
    public func researchLabRuns() async throws -> [JSONValue] {
        let raw = try await persistence.readJSON(labRunsPath, ifMissing: .array([]))
        guard case .array(let rows) = raw else {
            throw PersistenceCoreError.ioFailure(
                "Saved research runs must be an array. Original contents have been preserved."
            )
        }
        // Python: sorted(runs, key=createdAt, reverse=True). Stable sort with
        // empty-string default for missing createdAt (matches Python's
        // `str(item.get("createdAt") or "")`).
        let decorated = rows.enumerated().map { (idx, row) -> (Int, String, JSONValue) in
            var created = ""
            if case .object(let obj) = row, case .string(let s) = obj["createdAt"] ?? .null {
                created = s
            }
            return (idx, created, row)
        }
        let sorted = decorated.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }   // createdAt descending
            return a.0 < b.0                      // stable: preserve input order on ties
        }
        return sorted.map { $0.2 }
    }

    public func runResearchLab(objective rawObjective: String, maxResults rawMax: Int,
        compose: @Sendable (JSONValue) async throws -> ResearchLabProposal) async throws -> ResearchLabRun {
        // Mirror Python: objective = (objective or query).strip(); empty ->
        // ValueError("Research objective is required").
        let objective = rawObjective.trimmingCharacters(in: .whitespacesAndNewlines)
        if objective.isEmpty {
            throw ResearchClientError.malformedResponse("Research objective is required")
        }
        var results: [ResearchSearchResult] = []
        var searchError = ""
        var failure: String?
        var engines: [String] = []
        do {
            let resp = try await search(query: objective)
            results = resp.results
            engines = resp.unresponsiveEngines
            if results.isEmpty, !engines.isEmpty {
                failure = "engines_failed"
                searchError = "Search engines returned no sources: " + engines.joined(separator: "; ")
            }
        } catch where Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
        } catch {
            switch error {
            case ResearchClientError.notConfigured:
                failure = "not_configured"
                searchError = "SearXNG base URL is not configured"
            default:
                failure = "search_failed"
                searchError = error.localizedDescription
            }
        }

        try Task.checkCancellation()
        let connector = try Self.checkedSearxngBaseURL(root: receiptsDir.deletingLastPathComponent())?.isEmpty == false
            ? "searxng" : "none"
        let proposed = try await compose(.object([
            "objective": .string(objective), "maxResults": .int(Int64(rawMax)),
            "search": .object([
                "availability": .string(failure == nil ? "available" : "unavailable"),
                "reason": failure.map(JSONValue.string) ?? .null, "error": .string(searchError),
                "results": .array(results.map { $0.toJSON() }),
                "unresponsiveEngines": .array(engines.map(JSONValue.string)),
            ]),
        ]))
        // A part authors the run, never its source evidence or native identity.
        guard proposed.sources.allSatisfy({ results.contains($0) }) else {
            throw ResearchClientError.malformedResponse("Research Lab part selected sources outside this search")
        }
        let run = ResearchLabRun(
            id: UUID().uuidString.lowercased(),
            objective: objective,
            status: failure == "not_configured" ? "needs_connector" : (failure == nil ? "completed" : "failed"),
            query: objective,
            sources: proposed.sources,
            brief: proposed.brief,
            createdAt: Self.isoTimestamp(Date()),
            connector: connector,
            error: searchError.isEmpty ? nil : searchError
        )
        // Once accepted, save the run and its feed/trace settlement even if Stop arrives.
        let result: Result<ResearchLabRun, Error> = await settle {
            do { try await self.commitResearchLab(run); return .success(run) }
            catch { return .failure(error) }
        }
        return try result.get()
    }

    private func commitResearchLab(_ run: ResearchLabRun) async throws {
        // Read/insert/cap/write stays one native transaction; no part runs under the lock.
        let labRunsPath = self.labRunsPath
        let writeBack: @Sendable () async throws -> Void = {
            var existing = try await self.researchLabRuns()
            existing.insert(run.toJSON(), at: 0)
            let capped = Array(existing.prefix(100))
            try await self.persistence.writeJSON(.array(capped), to: labRunsPath)
        }
        try await persistence.withFileLock(labRunsPath, writeBack)

        // Emit activity and trace side effects so the Mac activity feed and
        // trace ledger stay complete for in-process research runs.
        let activityStatus = run.error == nil ? "ok" : "warn"
        let detail = Self.pythonCodepointPrefix(NativeAgentSecretRedactor.redactText(run.objective), 120)
        let activityPayload: JSONValue = .object([
            "researchRunId": .string(run.id),
            "sourceCount": .int(Int64(run.sources.count)),
        ])
        try await recordActivity(
            kind: "research",
            title: "Research lab run",
            detail: detail,
            status: activityStatus,
            payload: activityPayload
        )

        // Trace uses the run's status; the activity feed uses ok/warn.
        let tracePayload: JSONValue = .object([
            "researchRunId": .string(run.id),
            "status": .string(run.status),
            "sourceCount": .int(Int64(run.sources.count)),
        ])
        try await recordTrace(
            kind: "research.run",
            title: detail,
            payload: tracePayload
        )
    }
}
