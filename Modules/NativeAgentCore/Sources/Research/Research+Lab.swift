import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftNativeResearchClient {
    // MARK: research lab (wave 30 W17)

    public func researchLabRuns() async throws -> [JSONValue] {
        // Pure lock-free read. The daemon writes runs.json atomically (tmp +
        // os.replace), so a reader never observes a torn file even while the
        // Python writer or the Swift R-M-W is mid-flight — only the
        // read-modify-WRITE side needs the flock (see runResearchLab below).
        // Kept lock-free deliberately so the R-M-W in runResearchLab can call
        // this inner reader WHILE holding withFileLock(labRunsPath) without a
        // flock self-deadlock.
        return try await readLabRunsSorted()
    }

    /// Lock-free read of `runs.json` sorted newest-first. Callers that already
    /// hold `withFileLock(labRunsPath)` use this directly so they do not
    /// re-acquire the lock (flock LOCK_EX is not recursive across fds within a
    /// process — re-acquiring would self-deadlock). Mirrors the daemon's
    /// `_catalog_sources_unlocked` lock-free-inner precedent.
    private func readLabRunsSorted() async throws -> [JSONValue] {
        let raw = await persistence.readJSON(labRunsPath, defaultValue: .array([]))
        guard case .array(let rows) = raw else { return [] }
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

    public func runResearchLab(objective rawObjective: String, maxResults rawMax: Int) async throws -> ResearchLabRun {
        // Mirror Python: objective = (objective or query).strip(); empty ->
        // ValueError("Research objective is required").
        let objective = rawObjective.trimmingCharacters(in: .whitespacesAndNewlines)
        if objective.isEmpty {
            throw ResearchClientError.malformedResponse("Research objective is required")
        }
        // Python: max(1, min(8, int(maxResults or 5))) — note `maxResults or 5`
        // treats 0 (and negatives via the falsy-int path? no: only 0/None are
        // falsy) as missing -> 5. Mirror: 0 -> 5, then clamp to [1, 8].
        let effectiveMax = (rawMax == 0) ? 5 : rawMax
        let maxResults = max(1, min(8, effectiveMax))

        var results: [ResearchSearchResult] = []
        var searchError = ""
        do {
            let resp = try await search(query: objective)
            results = Array(resp.results.prefix(maxResults))
        } catch {
            // Python catches all exceptions and records the string form.
            // ResearchClientError.notConfigured mirrors the daemon's
            // ValueError("SearXNG base URL is not configured").
            switch error {
            case ResearchClientError.notConfigured:
                searchError = "SearXNG base URL is not configured"
            default:
                searchError = String(describing: error)
            }
        }

        let connector: String
        let cfg = await persistence.readJSON(configPath, defaultValue: .object([:]))
        if case .object(let obj) = cfg,
           case .string(let base) = obj["searxng_base_url"] ?? .null, !base.isEmpty {
            connector = "searxng"
        } else {
            connector = "none"
        }

        let run = ResearchLabRun(
            id: receiptIDFactory(),
            objective: objective,
            status: searchError.isEmpty ? "completed" : "needs_connector",
            query: objective,
            sources: results,
            brief: Self.buildResearchBrief(objective: objective, results: results, error: searchError),
            createdAt: Self.isoTimestamp(now()),
            connector: connector,
            error: searchError.isEmpty ? nil : searchError
        )

        // Persist newest-first, capped at 100 (Python `runs.insert(0, run);
        // write_json(path, runs[:100])`). Read the EXISTING rows first so we
        // preserve prior runs; sort matches researchLabRuns() (createdAt desc)
        // so the freshly-inserted run lands first.
        //
        // The WHOLE read-insert-write is wrapped in withFileLock(labRunsPath)
        // so multiple Swift callers cannot lose updates. The inner read uses
        // lock-free readLabRunsSorted() (NOT public researchLabRuns(), which is
        // identical but kept separate to document the no-re-acquire contract)
        // so there is no flock self-deadlock.
        let labRunsPath = self.labRunsPath
        let writeBack: @Sendable () async throws -> Void = {
            var existing = try await self.readLabRunsSorted()
            existing.insert(run.toJSON(), at: 0)
            let capped = Array(existing.prefix(100))
            try await self.persistence.writeJSON(.array(capped), to: labRunsPath)
        }
        if let p = persistence as? SwiftNativePersistenceCore {
            try await p.withFileLock(labRunsPath, writeBack)
        } else {
            try await writeBack()
        }

        // Emit activity and trace side effects so the Mac activity feed and
        // trace ledger stay complete for in-process research runs.
        let activityStatus = searchError.isEmpty ? "ok" : "warn"
        let detail = Self.pythonCodepointPrefix(objective, 120)
        let activityPayload: JSONValue = .object([
            "researchRunId": .string(run.id),
            "sourceCount": .int(Int64(results.count)),
        ])
        try await recordActivity(
            kind: "research",
            title: "Research lab run",
            detail: detail,
            status: activityStatus,
            payload: activityPayload
        )

        // Python: record_trace("research.run", objective[:120],
        //   {"researchRunId": run["id"], "status": run["status"],
        //    "sourceCount": len(results)}). The trace envelope's `status` field
        // is derived from payload["status"] (record_trace at L8557), so it is
        // run.status ("completed" | "needs_connector"), NOT the activity
        // "ok"/"warn" mapping — preserved deliberately.
        let tracePayload: JSONValue = .object([
            "researchRunId": .string(run.id),
            "status": .string(run.status),
            "sourceCount": .int(Int64(results.count)),
        ])
        try await recordTrace(
            kind: "research.run",
            title: detail,
            payload: tracePayload
        )

        return run
    }


    /// Mirror `Daemon.build_research_brief`.
    static func buildResearchBrief(objective: String, results: [ResearchSearchResult], error: String) -> String {
        if !error.isEmpty {
            return "Research connector needs setup before this can run fully: \(error)"
        }
        if results.isEmpty {
            return "No sources returned. Configure SearXNG or broaden the query."
        }
        // Python: titles = [(title or url or "Source").strip() for r in results[:3]].
        let titles = results.prefix(3).map { row -> String in
            let t = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
            let u = row.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !u.isEmpty { return u }
            return "Source"
        }
        return "Captured \(results.count) source(s) for: \(objective). Top sources: " + titles.joined(separator: "; ")
    }
}
