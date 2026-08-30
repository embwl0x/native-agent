import Foundation
import Testing

@Suite("feed coverage evaluator", .serialized)
struct FeedCoverageEvaluatorTests {
    private let repo = ScriptFenceEval.repo

    private func root(_ label: String) throws -> URL {
        try ScriptFenceEval.makeTempDir("feed-coverage-\(label)")
            .appendingPathComponent("data", isDirectory: true)
    }

    private func write(_ text: String, _ path: String, under root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func report(_ root: URL, output: URL? = nil) throws -> ScriptFenceEval.RunResult {
        var args = [repo.appendingPathComponent("script/feed_coverage_eval.swift").path,
                    "--data-root", root.path, "--days", "7"]
        if let output { args += ["--out", output.path] }
        return try ScriptFenceEval.run("/usr/bin/env", ["swift"] + args, cwd: repo,
                                       environment: ScriptFenceEval.environment(stubDir: nil), timeout: 45)
    }

    @Test func connectorReceiptsPreserveOpenWriterStatusesAndNameUnboundedRetention() throws {
        let data = try root("connectors")
        defer { try? FileManager.default.removeItem(at: data.deletingLastPathComponent()) }
        let now = ISO8601DateFormatter().string(from: Date())
        try write("""
        {"id":"\(UUID().uuidString.lowercased())","actionId":"github.status","connectorId":"github","status":"completed","dryRun":false,"ok":true,"createdAt":"\(now)"}
        {"id":"\(UUID().uuidString.lowercased())","actionId":"github.status","connectorId":"github","status":"failed","dryRun":false,"ok":false,"createdAt":"\(now)"}
        {"id":"\(UUID().uuidString.lowercased())","actionId":"github.status","connectorId":"github","status":"preview_from_provider","dryRun":true,"ok":true,"createdAt":"\(now)"}
        {"id":"\(UUID().uuidString.lowercased())","actionId":"github.status","connectorId":"github","status":"succeeded","dryRun":false,"createdAt":"\(now)"}
        {"id":"\(UUID().uuidString.lowercased())","actionId":"github.status","connectorId":"github","status":"error","dryRun":false,"ok":false,"createdAt":"\(now)"}
        {"id":"\(UUID().uuidString.lowercased())","actionId":"slack.post_message","connectorId":"slack","status":"pending_approval","dryRun":false,"ok":true,"createdAt":"\(now)"}
        {"id":"\(UUID().uuidString.lowercased())","actionId":"slack.post_message","connectorId":"slack","status":"waiting_approval","dryRun":false,"createdAt":"\(now)"}
        {"id":"\(UUID().uuidString.lowercased())","actionId":"slack.post_message","connectorId":"slack","status":"future_writer_status","dryRun":false,"createdAt":"\(now)"}
        {"id":"\(UUID().uuidString.lowercased())","actionId":"broken.write","connectorId":"broken","status":"failed","dryRun":false,"createdAt":"\(now)"}
        {"id":"\(UUID().uuidString.lowercased())","actionId":"broken.write","connectorId":"broken","status":"failed","dryRun":false,"createdAt":"\(now)"}
        {"id":"\(UUID().uuidString.lowercased())","actionId":"broken.write","connectorId":"broken","status":"failed","dryRun":false,"createdAt":"\(now)"}
        {"id":"\(UUID().uuidString.lowercased())","actionId":"redaction.probe","connectorId":"credential:NEVER_PRINT","status":"failed","dryRun":false,"createdAt":"\(now)"}
        """, "connectors/actions/receipts.jsonl", under: data)

        let run = try report(data)
        #expect(run.status == 0, Comment(rawValue: run.combined))
        let line = run.stdout.components(separatedBy: "\n").first { $0.contains("`feeds.connectors.uncovered`") } ?? ""
        #expect(line.contains("**UNBOUNDED** | 12"))
        #expect(line.contains("github: 1/2 failed, 1 dry-run, 2 unknown status"))
        #expect(line.contains("slack: no explicit terminal outcome, 0 dry-run, 3 unknown status"))
        #expect(line.contains("retention is unbounded"))
        #expect(line.contains("broken crossed the named failure-ratio bound"))
        #expect(line.contains("broken has 0 explicit successes across 3 terminal attempt(s)"))
        #expect(line.contains("redacted-connector has 0 explicit successes across 1 terminal attempt(s)"))
        #expect(!line.contains("credential:NEVER_PRINT"))

        try write("{\"id\":\"\(UUID().uuidString.lowercased())\",\"actionId\":\"github.status\",\"connectorId\":\"github\",\"status\":\"completed\",\"dryRun\":\"false\",\"createdAt\":\"\(now)\"}\n", "connectors/actions/receipts.jsonl", under: data)
        let corrupt = try report(data)
        #expect(corrupt.stdout.contains("`feeds.connectors.uncovered` | **UNREADABLE**"))
        #expect(corrupt.stdout.contains("canonical id/status/dryRun/timestamp contract"))
    }

    @Test func workJournalPairsTheSnapshotWithItsJSONLTail() throws {
        let data = try root("work-journal")
        defer { try? FileManager.default.removeItem(at: data.deletingLastPathComponent()) }
        let generated = ISO8601DateFormatter().string(from: Date())
        let id = "codex-work-\(UUID().uuidString.lowercased())"
        try write("{\"id\":\"\(id)\",\"status\":\"completed\",\"generatedAt\":\"\(generated)\"}", "work_journal/latest.json", under: data)
        try write("{\"id\":\"codex-work-older\",\"status\":\"completed\",\"generatedAt\":\"2026-01-01T00:00:00Z\"}\n{\"id\":\"\(id)\",\"status\":\"completed\",\"generatedAt\":\"\(generated)\"}\n", "work_journal/codex_daily.jsonl", under: data)

        let healthy = try report(data)
        #expect(healthy.stdout.contains("`feeds.work_journal` | **ACTIVE** | 2"))
        #expect(healthy.stdout.contains("writer appends codex_daily.jsonl then writes matching latest.json"))

        try write("{\"id\":\"wrong\",\"status\":\"completed\",\"generatedAt\":\"\(generated)\"}\n", "work_journal/codex_daily.jsonl", under: data)
        let mismatch = try report(data)
        #expect(mismatch.stdout.contains("`feeds.work_journal` | **UNREADABLE**"))
        #expect(mismatch.stdout.contains("ledger contract revision"))
    }

    @Test func researchReadersNameStrandedOperationsAndConfiguredEmptyHistory() throws {
        let data = try root("research")
        defer { try? FileManager.default.removeItem(at: data.deletingLastPathComponent()) }
        let old = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -7_200))
        try write("[{\"status\":\"running\",\"updatedAt\":\"\(old)\"},{\"status\":\"completed\",\"updatedAt\":\"\(old)\"}]", "native_power/browser/runs.json", under: data)
        try write("{}", "research/lab/config.json", under: data)
        let missing = try report(data)
        #expect(missing.stdout.contains("`feeds.research.browser_runs` | **ACTIVE** | 2"))
        #expect(missing.stdout.contains("ALERT: 1 running/waiting operation(s) older than 1h"))
        #expect(missing.stdout.contains("`feeds.research.lab_runs` | **UNREADABLE** | 0"))
    }

    @Test func dreamTraceAndPreloadReadersKeepTheirExistingContracts() throws {
        let data = try root("existing")
        defer { try? FileManager.default.removeItem(at: data.deletingLastPathComponent()) }
        try write("a real dream", "dream_diary/2026-08-20.md", under: data)
        try write("", "dream_diary/2026-08-21.md", under: data)
        for index in 0..<15 { try write("", "dream_diary/.mood_integrated_\(index)", under: data) }
        try write("{}\n", "turn_traces/2020-01-01.jsonl", under: data)
        try write("", "turn_traces/2020-01-02.jsonl.lock", under: data)
        try write("{\"kind\":\"tool.preload\",\"payload\":{\"tools\":[]}}\n", "traces/events.jsonl", under: data)
        let run = try report(data)
        #expect(run.status == 0, Comment(rawValue: run.combined))
        #expect(run.stdout.contains("`feeds.dream_diary.integrity` | **UNREADABLE** | 2"))
        #expect(run.stdout.contains("ALERT: 2 expired trace file(s), 1 orphan lock(s)"))
        #expect(run.stdout.contains("ALERT: 1 preload row(s) selected zero or ≥80 tools"))
    }

    @Test func maintenanceSweepHarnessReconcilesArtifactRowsToPassSummaries() throws {
        let data = try root("maintenance-sweep")
        defer { try? FileManager.default.removeItem(at: data.deletingLastPathComponent()) }
        let recent = ISO8601DateFormatter().string(from: Date())
        try write("""
        {"event":"maintenance_sweep.removed","source":"turn_trace_retention","path":"turn_traces/2026-01-01.jsonl","completedAt":"\(recent)"}
        {"event":"maintenance_sweep.removed","source":"file_lock_sidecar_lifecycle","path":"abandoned-receipt.json.lock","completedAt":"\(recent)"}
        {"event":"maintenance_sweep.completed","source":"turn_trace_retention","completedAt":"\(recent)","removed":2,"turnTraceDaysRemoved":1,"turnTraceLocksRemoved":0,"orphanLockSidecarsReaped":1,"orphanLockSidecarsDeferred":0,"orphanLockSidecarFailures":0}
        """, "logs/maintenance_sweep.jsonl", under: data)

        let healthy = try report(data)
        #expect(healthy.status == 0, Comment(rawValue: healthy.combined))
        #expect(healthy.stdout.contains("`feeds.logs.maintenance_sweep` | **ACTIVE** | 3"))
        #expect(healthy.stdout.contains("audit reader: 1 completed pass(es), 2 root-relative artifact removal row(s)"))

        let old = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -8 * 86_400))
        try write("""
        {"event":"maintenance_sweep.completed","source":"turn_trace_retention","completedAt":"\(old)","removed":0,"turnTraceDaysRemoved":0,"turnTraceLocksRemoved":0,"orphanLockSidecarsReaped":0,"orphanLockSidecarsDeferred":0,"orphanLockSidecarFailures":0}
        """, "logs/maintenance_sweep.jsonl", under: data)
        let dormant = try report(data)
        #expect(dormant.stdout.contains("`feeds.logs.maintenance_sweep` | **DORMANT** | 1"))

        try write("""
        {"event":"maintenance_sweep.removed","source":"turn_trace_retention","path":"/private/absolute.jsonl","completedAt":"\(recent)"}
        {"event":"maintenance_sweep.completed","source":"turn_trace_retention","completedAt":"\(recent)","removed":1,"turnTraceDaysRemoved":1,"turnTraceLocksRemoved":0,"orphanLockSidecarsReaped":0,"orphanLockSidecarsDeferred":0,"orphanLockSidecarFailures":0}
        """, "logs/maintenance_sweep.jsonl", under: data)
        let corrupt = try report(data)
        #expect(corrupt.stdout.contains("`feeds.logs.maintenance_sweep` | **UNREADABLE** | 2"))
        #expect(corrupt.stdout.contains("source/root-relative-path contract"))
    }

    @Test func evalLaneRequiresBothLedgersAndReportsNewestRunFreshness() throws {
        let data = try root("eval-lane")
        defer { try? FileManager.default.removeItem(at: data.deletingLastPathComponent()) }
        let recent = ISO8601DateFormatter().string(from: Date())
        let old = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -8 * 86_400))
        try write("[{\"id\":\"app-recent\",\"createdAt\":\"\(recent)\"}]", "evals/runs.json", under: data)
        try write("[{\"id\":\"context-old\",\"createdAt\":\"\(old)\"}]", "context/evals/runs.json", under: data)
        try write("{\"queries\":[\"current conversation\"]}", "evals/selection_ab_queries.json", under: data)

        let healthy = try report(data)
        #expect(healthy.status == 0, Comment(rawValue: healthy.combined))
        #expect(healthy.stdout.contains("`feeds.evals.uncovered_rest` | **ACTIVE** | 2"))
        #expect(healthy.stdout.contains("newest app/context eval run must be within 7 days"))
        #expect(healthy.stdout.contains("selection corpus has 1 query/queries"))

        try write("[{\"id\":\"app-old\",\"createdAt\":\"\(old)\"}]", "evals/runs.json", under: data)
        let stale = try report(data)
        #expect(stale.stdout.contains("`feeds.evals.uncovered_rest` | **DORMANT** | 2"))
        #expect(stale.stdout.contains("newest app/context eval run must be within 7 days"))

        try write("[]", "context/evals/runs.json", under: data)
        try write("[]", "evals/runs.json", under: data)
        let empty = try report(data)
        #expect(empty.stdout.contains("`feeds.evals.uncovered_rest` | **DORMANT** | 0"))
        #expect(empty.stdout.contains("no eval run stamp across either ledger"))

        try write("{\"queries\":[]}", "evals/selection_ab_queries.json", under: data)
        let malformed = try report(data)
        #expect(malformed.stdout.contains("`feeds.evals.uncovered_rest` | **UNREADABLE** | 0"))
        #expect(malformed.stdout.contains("both run ledgers and a non-empty selection query corpus"))
    }

    @Test func selfImprovementPairsTheWeeklyMarkerWithItsUTCDateDigest() throws {
        let data = try root("self-improvement")
        defer { try? FileManager.default.removeItem(at: data.deletingLastPathComponent()) }
        let recentDate = Date()
        let oldDate = Date(timeIntervalSinceNow: -8 * 86_400)
        let iso = ISO8601DateFormatter()
        let recent = iso.string(from: recentDate)
        let old = iso.string(from: oldDate)
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let recentDay = dayFormatter.string(from: recentDate)
        let oldDay = dayFormatter.string(from: oldDate)
        try write("\(recent)\n", "self_improvement/last_weekly_run", under: data)
        try write("# Self-Improvement Digest — \(recentDay)\n\nA real finding.", "self_improvement/digests/\(recentDay).md", under: data)

        let healthy = try report(data)
        #expect(healthy.status == 0, Comment(rawValue: healthy.combined))
        #expect(healthy.stdout.contains("`feeds.self_improvement` | **ACTIVE** | 1"))
        #expect(healthy.stdout.contains("weekly marker and same-UTC-day digest are paired"))

        try write("\(old)\n", "self_improvement/last_weekly_run", under: data)
        try write("# Self-Improvement Digest — \(oldDay)\n\nOlder finding.", "self_improvement/digests/\(oldDay).md", under: data)
        let stale = try report(data)
        #expect(stale.stdout.contains("`feeds.self_improvement` | **DORMANT** | 2"))
        #expect(stale.stdout.contains("newest committed pass must be within 7 days"))

        try write("not a digest", "self_improvement/digests/\(oldDay).md", under: data)
        let mismatched = try report(data)
        #expect(mismatched.stdout.contains("`feeds.self_improvement` | **UNREADABLE** | 2"))
        #expect(mismatched.stdout.contains("has no matching non-empty canonical digest"))
    }

    @Test func workshopNotesAndFindingsStayHandleScopedAndReadable() throws {
        let data = try root("workshop-notes")
        defer { try? FileManager.default.removeItem(at: data.deletingLastPathComponent()) }
        try write("A durable observation.", "workshop/desk_alpha/notes/day-one.md", under: data)
        try write("A durable conclusion.", "workshop/desk_alpha/findings.md", under: data)

        let healthy = try report(data)
        #expect(healthy.status == 0, Comment(rawValue: healthy.combined))
        #expect(healthy.stdout.contains("`feeds.workshop.notes_and_findings` | **ACTIVE** | 2"))
        #expect(healthy.stdout.contains("handle-scoped note/finding Markdown artifacts"))

        try write("", "workshop/desk_alpha/notes/day-one.md", under: data)
        let empty = try report(data)
        #expect(empty.stdout.contains("`feeds.workshop.notes_and_findings` | **UNREADABLE**"))
        #expect(empty.stdout.contains("non-empty UTF-8 Markdown file"))

        try write("Restored note.", "workshop/desk_alpha/notes/day-one.md", under: data)
        let finding = data.appendingPathComponent("workshop/desk_alpha/findings.md")
        let outside = data.deletingLastPathComponent().appendingPathComponent("outside-finding.md")
        try FileManager.default.removeItem(at: finding)
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: finding, withDestinationURL: outside)
        let symlinked = try report(data)
        #expect(symlinked.stdout.contains("`feeds.workshop.notes_and_findings` | **UNREADABLE**"))
        #expect(symlinked.stdout.contains("must not be a symlink"))
    }

    @Test func preScrubBackupEventsAreEnvelopeCheckedWithoutPrintingPayloads() throws {
        let data = try root("pre-scrub-backup")
        defer { try? FileManager.default.removeItem(at: data.deletingLastPathComponent()) }
        let now = ISO8601DateFormatter().string(from: Date())
        let id = UUID().uuidString.lowercased()
        try write("{\"id\":\"\(id)\",\"createdAt\":\"\(now)\",\"kind\":\"tool.dispatch\",\"status\":\"ok\",\"title\":\"safe title\",\"payload\":{\"private\":\"DO-NOT-PRINT\"}}\n", "backups/events-pre-fixture-scrub-20260824T120000Z.jsonl", under: data)

        let healthy = try report(data)
        #expect(healthy.status == 0, Comment(rawValue: healthy.combined))
        #expect(healthy.stdout.contains("`feeds.backups.events_pre_scrub` | **UNBOUNDED** | 1"))
        #expect(healthy.stdout.contains("no bounded retention owner"))
        #expect(!healthy.stdout.contains("DO-NOT-PRINT"))

        try write("{\"id\":\"not-a-uuid\",\"createdAt\":\"\(now)\",\"kind\":\"tool.dispatch\",\"status\":\"ok\",\"title\":\"safe title\",\"payload\":{}}\n", "backups/events-pre-fixture-scrub-20260824T120000Z.jsonl", under: data)
        let malformed = try report(data)
        #expect(malformed.stdout.contains("`feeds.backups.events_pre_scrub` | **UNREADABLE**"))
        #expect(malformed.stdout.contains("canonical id/timestamp/kind/status/title/payload envelope"))
    }

    @Test func refusesAnOutputPathInsideTheObservedRoot() throws {
        let data = try root("refusal")
        defer { try? FileManager.default.removeItem(at: data.deletingLastPathComponent()) }
        let fm = FileManager.default
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        let bad = data.appendingPathComponent("must-not-write.md")
        let alias = data.deletingLastPathComponent().appendingPathComponent("data-alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: data)
        let existing = data.appendingPathComponent("existing.md")
        try "preserve observed bytes".write(to: existing, atomically: true, encoding: .utf8)
        let fileAlias = data.deletingLastPathComponent().appendingPathComponent("file-alias.md")
        try fm.createSymbolicLink(at: fileAlias, withDestinationURL: existing)
        for (observed, output) in [
            (data, bad),
            (data, alias.appendingPathComponent("must-not-write.md")),
            (alias, bad),
            (data, alias.appendingPathComponent("missing-parent/report.md")),
            (data, fileAlias),
        ] {
            let run = try report(observed, output: output)
            #expect(run.status != 0, Comment(rawValue: run.combined))
            #expect(run.combined.contains("REFUSED"))
        }
        #expect(!fm.fileExists(atPath: bad.path))
        #expect(!fm.fileExists(atPath: data.appendingPathComponent("missing-parent").path))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "preserve observed bytes")

        let outside = data.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideAlias = data.deletingLastPathComponent().appendingPathComponent("outside-alias")
        try fm.createSymbolicLink(at: outsideAlias, withDestinationURL: outside)
        let allowed = try report(alias, output: outsideAlias.appendingPathComponent("report.md"))
        #expect(allowed.status == 0, Comment(rawValue: allowed.combined))
        #expect(fm.fileExists(atPath: outside.appendingPathComponent("report.md").path))
    }
}
