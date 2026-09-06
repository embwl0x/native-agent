#!/usr/bin/env swift
// Read-only checks for feed contracts that have concrete canonical schemas.
// Missing, malformed, and unbounded feeds remain distinct; this intentionally
// does not try to infer health from a generic reachability walk.
import Foundation
import Darwin

enum FeedCoverageError: Error, CustomStringConvertible {
    case usage(String), refusedOutput(String)
    var description: String {
        switch self { case .usage(let text), .refusedOutput(let text): return text }
    }
}

enum FeedState: String { case active = "ACTIVE", dormant = "DORMANT", absent = "ABSENT", unreadable = "UNREADABLE", unbounded = "UNBOUNDED", fossil = "FOSSIL" }
struct Result { let id: String; let state: FeedState; let rows: Int; let newest: Date?; let evidence: String }
struct FossilDirectory { let name: String; let bytes: Int64; let newest: Date? }

let fm = FileManager.default
var root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true).appendingPathComponent("data", isDirectory: true)
var out: URL?
var days = 7.0
var fossilDays = 30.0
var index = 1
let argv = CommandLine.arguments
while index < argv.count {
    switch argv[index] {
    case "--data-root": index += 1; guard index < argv.count else { throw FeedCoverageError.usage("--data-root needs a path") }; root = URL(fileURLWithPath: argv[index])
    case "--out": index += 1; guard index < argv.count else { throw FeedCoverageError.usage("--out needs a path") }; out = URL(fileURLWithPath: argv[index])
    case "--days": index += 1; guard index < argv.count, let value = Double(argv[index]), value > 0 else { throw FeedCoverageError.usage("--days needs a positive number") }; days = value
    case "--fossil-days": index += 1; guard index < argv.count, let value = Double(argv[index]), value > 0 else { throw FeedCoverageError.usage("--fossil-days needs a positive number") }; fossilDays = value
    case "-h", "--help": print("usage: feed_coverage_eval.swift [--data-root PATH] [--days N] [--out PATH]"); exit(0)
    default: throw FeedCoverageError.usage("unknown argument: \(argv[index])")
    }
    index += 1
}
// The report normally does not exist yet. Resolve its nearest existing
// ancestor with the same kernel spelling as the data root (including macOS
// /var -> /private/var), then append the missing path components.
func canonicalLocation(_ url: URL) -> String {
    var ancestor = url.path
    var missing: [String] = []
    while true {
        if let resolved = realpath(ancestor, nil) {
            defer { free(resolved) }
            return missing.reversed().reduce(String(cString: resolved)) {
                ($0 as NSString).appendingPathComponent($1)
            }
        }
        let parent = (ancestor as NSString).deletingLastPathComponent
        guard parent != ancestor, !parent.isEmpty else { return url.standardizedFileURL.path }
        missing.append((ancestor as NSString).lastPathComponent)
        ancestor = parent
    }
}
let canonicalRoot = URL(fileURLWithPath: canonicalLocation(root), isDirectory: true)
if let out {
    let outputPath = canonicalLocation(out)
    let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
    if outputPath == canonicalRoot.path || outputPath.hasPrefix(rootPrefix) {
        throw FeedCoverageError.refusedOutput("REFUSED: --out must not be inside the data root")
    }
}

func modification(_ file: URL) -> Date? { (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil }
func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
func object(_ file: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: file), let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return value as? [String: Any]
}
func array(_ file: URL) -> [[String: Any]]? {
    guard let data = try? Data(contentsOf: file), let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
    if let rows = value as? [[String: Any]] { return rows }
    if let value = value as? [String: Any] { return value["runs"] as? [[String: Any]] }
    return nil
}
func jsonLines(_ file: URL) -> [[String: Any]]? {
    guard let data = try? Data(contentsOf: file) else { return nil }
    var rows: [[String: Any]] = []
    for line in data.split(separator: 10) {
        guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
        rows.append(row)
    }
    return rows
}
func date(_ value: Any?) -> Date? {
    guard let raw = value as? String else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
}
func freshness(_ stamp: Date, now: Date) -> FeedState { now.timeIntervalSince(stamp) > days * 86_400 ? .dormant : .active }

/// Directory-only reach audit for historical data trees that have no canonical
/// reader above. It never opens file contents or follows links: this is a
/// dated inventory, not a secret scanner and not a cleanup operation.
func fossilDirectories(now: Date) -> (retired: [FossilDirectory], live: [FossilDirectory]) {
    let canonicalDirectories: Set<String> = [
        "connectors", "context", "dream_diary", "evals", "logs", "native_power",
        "research", "self_improvement", "traces", "turn_traces", "work_journal",
        "workshop",
    ]
    guard let roots = try? fm.contentsOfDirectory(
        at: canonicalRoot,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
    ) else { return ([], []) }

    var retired: [FossilDirectory] = []
    var live: [FossilDirectory] = []
    for directory in roots.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let name = directory.lastPathComponent
        guard !canonicalDirectories.contains(name),
              let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true
        else { continue }

        var bytes: Int64 = 0
        var newest: Date?
        let walker = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        )
        while let file = walker?.nextObject() as? URL {
            guard let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            ), values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            bytes += Int64(values.fileSize ?? 0)
            if let modified = values.contentModificationDate {
                newest = max(newest ?? modified, modified)
            }
        }
        let record = FossilDirectory(name: name, bytes: bytes, newest: newest)
        if newest.map({ now.timeIntervalSince($0) <= fossilDays * 86_400 }) == true {
            live.append(record)
        } else {
            retired.append(record)
        }
    }
    return (retired, live)
}

func fossilDirectoryReport(now: Date) -> (result: Result, retired: [FossilDirectory], live: [FossilDirectory]) {
    let audit = fossilDirectories(now: now)
    let rows = audit.retired.count + audit.live.count
    let newest = (audit.retired + audit.live).compactMap(\.newest).max()
    let state: FeedState = audit.retired.isEmpty ? (audit.live.isEmpty ? .absent : .active) : .fossil
    let evidence = "RETIRED/FOSSIL: \(audit.retired.count) top-level directory/directories with no file write in \(Int(fossilDays))d; uncovered but live: \(audit.live.count); byte counts are inventory-only"
    return (.init(id: "feeds.fossil.dormant_directories", state: state, rows: rows, newest: newest, evidence: evidence), audit.retired, audit.live)
}

private struct ConnectorCounts {
    var successes = 0
    var failures = 0
    var dryRuns = 0
    var unknowns = 0
}

let connectorFailureRatioMinimumFailures = 3

func connectorReportLabel(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let scalars = value.unicodeScalars
    guard !scalars.isEmpty, scalars.count <= 80, scalars.allSatisfy({ allowed.contains($0) }) else {
        return "redacted-connector"
    }
    return value
}

func connectorReceipts(now: Date) -> Result {
    let file = canonicalRoot.appendingPathComponent("connectors/actions/receipts.jsonl")
    guard fm.fileExists(atPath: file.path) else { return .init(id: "feeds.connectors.uncovered", state: .absent, rows: 0, newest: nil, evidence: "source absent — not a zero") }
    guard let rows = jsonLines(file) else { return .init(id: "feeds.connectors.uncovered", state: .unreadable, rows: 0, newest: modification(file), evidence: "canonical connector receipt JSONL is malformed") }
    var byConnector: [String: ConnectorCounts] = [:]
    var newest: Date?
    for row in rows {
        guard let id = row["id"] as? String,
              UUID(uuidString: id)?.uuidString.lowercased() == id,
              let actionID = row["actionId"] as? String, !actionID.isEmpty,
              let connectorID = row["connectorId"] as? String, !connectorID.isEmpty,
              let rawStatus = row["status"] as? String,
              !rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let dryRun = row["dryRun"] as? Bool,
              let createdAt = date(row["createdAt"])
        else { return .init(id: "feeds.connectors.uncovered", state: .unreadable, rows: rows.count, newest: modification(file), evidence: "connector receipt violates the canonical id/status/dryRun/timestamp contract") }
        newest = max(newest ?? createdAt, createdAt)
        var counts = byConnector[connectorID] ?? .init()
        if dryRun {
            counts.dryRuns += 1
        } else {
            // The writer intentionally accepts a provider's nonempty status
            // verbatim. Only its two stable terminal spellings carry ratio
            // semantics; every other status remains visible as unknown.
            switch rawStatus {
            case "completed": counts.successes += 1
            case "failed": counts.failures += 1
            default: counts.unknowns += 1
            }
        }
        byConnector[connectorID] = counts
    }
    let summaries = byConnector.keys.sorted().map { connectorID -> String in
        let counts = byConnector[connectorID]!
        let terminals = counts.successes + counts.failures
        let ratio = terminals == 0 ? "no explicit terminal outcome" : "\(counts.failures)/\(terminals) failed"
        return "\(connectorReportLabel(connectorID)): \(ratio), \(counts.dryRuns) dry-run, \(counts.unknowns) unknown status"
    }
    let leads = byConnector.keys.sorted().flatMap { connectorID -> [String] in
        let counts = byConnector[connectorID]!
        let terminals = counts.successes + counts.failures
        let label = connectorReportLabel(connectorID)
        var result: [String] = []
        if counts.failures >= connectorFailureRatioMinimumFailures, counts.failures > counts.successes {
            result.append("RANKED LEAD rank 8: \(label) crossed the named failure-ratio bound (≥\(connectorFailureRatioMinimumFailures) explicit failures and more failures than successes)")
        }
        if terminals > 0, counts.successes == 0 {
            result.append("RANKED LEAD rank 8: \(label) has 0 explicit successes across \(terminals) terminal attempt(s)")
        }
        return result
    }
    // appendConnectorActionReceipt is append-only; no canonical retention owner
    // exists for this ledger. Name that gap rather than a false healthy history.
    let evidence = "retention is unbounded; failure-ratio bound is ≥\(connectorFailureRatioMinimumFailures) explicit failures and more failures than successes; "
        + summaries.joined(separator: "; ")
        + (leads.isEmpty ? "" : "; " + leads.joined(separator: "; "))
    return .init(id: "feeds.connectors.uncovered", state: .unbounded, rows: rows.count, newest: newest, evidence: evidence)
}

func workJournal(now: Date) -> Result {
    let directory = canonicalRoot.appendingPathComponent("work_journal", isDirectory: true)
    let latest = directory.appendingPathComponent("latest.json")
    // Sweep item 21 (2026-09-01): `codex_daily.jsonl` is RETIRED. The writer
    // appended the full 11.2 KB snapshot to it, uncapped, and no production
    // reader ever opened it — this evaluator was the only consumer of the
    // pairing, and a check is not a consumer. `latest.json` alone is the feed;
    // the old daily rows stay on disk as history and are not re-read.
    guard fm.fileExists(atPath: latest.path) else { return .init(id: "feeds.work_journal", state: .absent, rows: 0, newest: nil, evidence: "source absent — not a zero") }
    guard let latestRow = object(latest), let latestID = latestRow["id"] as? String,
          latestID.hasPrefix("codex-work-"),
          latestRow["status"] as? String == "completed",
          let latestAt = date(latestRow["generatedAt"])
    else { return .init(id: "feeds.work_journal", state: .unreadable, rows: 0, newest: modification(latest), evidence: "ledger contract revision: latest.json must be a completed codex-work snapshot carrying a parseable generatedAt") }
    return .init(id: "feeds.work_journal", state: freshness(latestAt, now: now), rows: 1, newest: latestAt, evidence: "ledger contract revision: latest.json is the whole production feed; the codex_daily.jsonl append was retired 2026-09-01 (no reader) and residual rows are history, not a pair; cursor and codex_notes are not part of this feed")
}

func researchRuns(id: String, path: String, configuredPath: String?, now: Date) -> Result {
    let file = canonicalRoot.appendingPathComponent(path)
    guard fm.fileExists(atPath: file.path) else {
        if let configuredPath, fm.fileExists(atPath: canonicalRoot.appendingPathComponent(configuredPath).path) { return .init(id: id, state: .unreadable, rows: 0, newest: nil, evidence: "connector configured but no readable run history") }
        return .init(id: id, state: .absent, rows: 0, newest: nil, evidence: "source absent — not a zero")
    }
    guard let rows = array(file) else { return .init(id: id, state: .unreadable, rows: 0, newest: modification(file), evidence: "present but run history is not a JSON array") }
    let stranded = rows.filter { row in
        guard let status = row["status"] as? String, ["running", "waiting_approval"].contains(status), let stamp = date(row["updatedAt"]) ?? date(row["createdAt"]) else { return false }
        return now.timeIntervalSince(stamp) > 3_600
    }
    return .init(id: id, state: .active, rows: rows.count, newest: modification(file), evidence: stranded.isEmpty ? "read-only run-state reader" : "ALERT: \(stranded.count) running/waiting operation(s) older than 1h")
}

func dreamDiary(now: Date) -> Result {
    let directory = canonicalRoot.appendingPathComponent("dream_diary", isDirectory: true)
    guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]), !files.isEmpty else { return .init(id: "feeds.dream_diary.integrity", state: .absent, rows: 0, newest: nil, evidence: "source absent — not a zero") }
    let entries = files.filter { $0.pathExtension == "md" }
    let empty = entries.filter { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) == 0 }
    let markers = files.filter { $0.lastPathComponent.hasPrefix(".mood_integrated_") }
    let evidence = !empty.isEmpty ? "ALERT: \(empty.count) zero-byte diary entr\(empty.count == 1 ? "y" : "ies")" : markers.count > 14 ? "ALERT: \(markers.count) mood-integrated marker files (retention bound 14)" : "content reader: \(entries.count) non-empty diary entr\(entries.count == 1 ? "y" : "ies"), \(markers.count) markers"
    return .init(id: "feeds.dream_diary.integrity", state: empty.isEmpty ? .active : .unreadable, rows: entries.count, newest: files.compactMap(modification).max(), evidence: evidence)
}

func traceRetention(now: Date) -> Result {
    let directory = canonicalRoot.appendingPathComponent("turn_traces", isDirectory: true)
    guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]), !files.isEmpty else { return .init(id: "feeds.turn_traces.retention", state: .absent, rows: 0, newest: nil, evidence: "source absent — not a zero") }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
    let cutoff = Calendar.current.date(byAdding: .day, value: -13, to: Calendar.current.startOfDay(for: now))!
    let expired = files.filter { formatter.date(from: $0.lastPathComponent.replacingOccurrences(of: ".jsonl.lock", with: "").replacingOccurrences(of: ".jsonl", with: "")).map { $0 < cutoff } ?? false }
    let orphanLocks = files.filter { $0.lastPathComponent.hasSuffix(".jsonl.lock") && !fm.fileExists(atPath: $0.deletingPathExtension().path) }
    return .init(id: "feeds.turn_traces.retention", state: .active, rows: files.count, newest: files.compactMap(modification).max(), evidence: expired.isEmpty && orphanLocks.isEmpty ? "retention reader: no expired trace day or orphan lock" : "ALERT: \(expired.count) expired trace file(s), \(orphanLocks.count) orphan lock(s)")
}

func mcpReceipts(now: Date) -> Result {
    let file = canonicalRoot.appendingPathComponent("activity/events.jsonl")
    guard fm.fileExists(atPath: file.path) else {
        return .init(id: "feeds.mcp", state: .absent, rows: 0, newest: nil, evidence: "source absent — not a zero")
    }
    guard let allRows = jsonLines(file) else {
        return .init(id: "feeds.mcp", state: .unreadable, rows: 0, newest: modification(file), evidence: "Activity JSONL is malformed, so MCP receipt history is unreadable")
    }
    let rows = allRows.filter { $0["kind"] as? String == "mcp_tool" }
    guard !rows.isEmpty else {
        return .init(id: "feeds.mcp", state: .dormant, rows: 0, newest: modification(file), evidence: "no durable MCP receipt in the bounded Activity feed")
    }

    func unreadable(_ evidence: String) -> Result {
        .init(id: "feeds.mcp", state: .unreadable, rows: rows.count, newest: modification(file), evidence: evidence)
    }
    func nonnegativeCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              number.doubleValue.isFinite,
              number.doubleValue >= 0,
              number.doubleValue <= Double(Int.max),
              number.doubleValue.rounded() == number.doubleValue
        else { return nil }
        return number.intValue
    }
    func isSHA256(_ value: String) -> Bool {
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return value.count == 64 && value.unicodeScalars.allSatisfy(hexadecimal.contains)
    }

    var newest: Date?
    var successes = 0
    var errors = 0
    var otherStatuses = 0
    for row in rows {
        guard let id = row["id"] as? String, !id.isEmpty,
              let createdAt = date(row["createdAt"]),
              let displayStatus = row["status"] as? String,
              let payload = row["payload"] as? [String: Any],
              let callID = payload["callId"] as? String, !callID.isEmpty,
              let serverID = payload["serverId"] as? String, !serverID.isEmpty,
              let toolName = payload["toolName"] as? String, !toolName.isEmpty,
              let toolStatus = payload["toolStatus"] as? String, !toolStatus.isEmpty,
              let transport = payload["transportOutcome"] as? String,
              ["response_received", "remote_reported_error"].contains(transport),
              let duration = payload["durationSeconds"] as? NSNumber,
              duration.doubleValue.isFinite,
              duration.doubleValue >= 0,
              payload["result"] != nil,
              let originalBytes = nonnegativeCount(payload["resultByteCount"]),
              let redactedBytes = nonnegativeCount(payload["redactedByteCount"]),
              redactedBytes <= originalBytes,
              payload["resultTruncated"] is Bool,
              let digest = payload["resultDigest"] as? String,
              isSHA256(digest)
        else { return unreadable("MCP receipt violates the durable Activity envelope or redaction metadata contract") }

        let normalized = toolStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expectedDisplay = ["error", "failed"].contains(normalized) ? "warn" : "ok"
        guard displayStatus == expectedDisplay else {
            return unreadable("MCP receipt display status disagrees with its tool outcome")
        }
        switch normalized {
        case "ok": successes += 1
        case "error", "failed": errors += 1
        default: otherStatuses += 1
        }
        newest = max(newest ?? createdAt, createdAt)
    }
    guard let newest else {
        return unreadable("MCP receipt history has no valid freshness timestamp")
    }
    return .init(
        id: "feeds.mcp",
        state: freshness(newest, now: now),
        rows: rows.count,
        newest: newest,
        evidence: "receipt reader: \(rows.count) durable MCP receipt(s), \(successes) ok, \(errors) error, \(otherStatuses) other status"
    )
}

func maintenanceSweep(now: Date) -> Result {
    let file = canonicalRoot.appendingPathComponent("logs/maintenance_sweep.jsonl")
    guard fm.fileExists(atPath: file.path) else {
        return .init(id: "feeds.logs.maintenance_sweep", state: .absent, rows: 0, newest: nil, evidence: "source absent — not a zero")
    }
    guard let rows = jsonLines(file) else {
        return .init(id: "feeds.logs.maintenance_sweep", state: .unreadable, rows: 0, newest: modification(file), evidence: "maintenance sweep audit JSONL is malformed")
    }

    func unreadable(_ evidence: String) -> Result {
        .init(id: "feeds.logs.maintenance_sweep", state: .unreadable, rows: rows.count, newest: modification(file), evidence: evidence)
    }
    func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              number.doubleValue.isFinite,
              number.doubleValue >= 0,
              number.doubleValue <= Double(Int.max),
              number.doubleValue.rounded() == number.doubleValue
        else { return nil }
        return number.intValue
    }
    func sum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }
    func isRootRelativeArtifact(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("/")
            && !value.split(separator: "/").contains("..")
    }

    var summaries = 0
    var removalsSinceSummary = 0
    var removalRows = 0
    var newestSummary: Date?
    for row in rows {
        guard let event = row["event"] as? String,
              let completedAt = date(row["completedAt"])
        else { return unreadable("maintenance sweep row lacks the canonical event/completedAt fields") }
        switch event {
        case "maintenance_sweep.removed":
            guard let source = row["source"] as? String,
                  ["turn_trace_retention", "file_lock_sidecar_lifecycle"].contains(source),
                  let artifact = row["path"] as? String,
                  isRootRelativeArtifact(artifact)
            else { return unreadable("maintenance removal row violates the source/root-relative-path contract") }
            removalsSinceSummary += 1
            removalRows += 1
        case "maintenance_sweep.completed":
            guard row["source"] as? String == "turn_trace_retention",
                  let removed = count(row["removed"]),
                  let days = count(row["turnTraceDaysRemoved"]),
                  let locks = count(row["turnTraceLocksRemoved"]),
                  let reaped = count(row["orphanLockSidecarsReaped"]),
                  count(row["orphanLockSidecarsDeferred"]) != nil,
                  count(row["orphanLockSidecarFailures"]) != nil,
                  let expectedRemoved = sum([days, locks, reaped]),
                  removed == expectedRemoved,
                  removed == removalsSinceSummary
            else { return unreadable("maintenance summary must reconcile its per-artifact rows and removal counters") }
            summaries += 1
            removalsSinceSummary = 0
            newestSummary = max(newestSummary ?? completedAt, completedAt)
        default:
            return unreadable("maintenance sweep audit contains an unknown event")
        }
    }
    guard summaries > 0, let newestSummary else {
        return unreadable("maintenance sweep audit has no completed pass summary")
    }
    guard removalsSinceSummary == 0 else {
        return unreadable("maintenance sweep audit ends with removals lacking a completed pass summary")
    }
    return .init(
        id: "feeds.logs.maintenance_sweep",
        state: freshness(newestSummary, now: now),
        rows: rows.count,
        newest: newestSummary,
        evidence: "audit reader: \(summaries) completed pass(es), \(removalRows) root-relative artifact removal row(s)"
    )
}

func preload(now: Date) -> Result {
    let file = canonicalRoot.appendingPathComponent("traces/events.jsonl")
    guard fm.fileExists(atPath: file.path) else { return .init(id: "feeds.trace.kind.tool.preload", state: .absent, rows: 0, newest: nil, evidence: "source absent — not a zero") }
    guard let all = jsonLines(file) else { return .init(id: "feeds.trace.kind.tool.preload", state: .unreadable, rows: 0, newest: modification(file), evidence: "present but includes malformed JSONL") }
    let rows = all.filter { $0["kind"] as? String == "tool.preload" }
    guard rows.allSatisfy({ ($0["payload"] as? [String: Any])?["tools"] is [Any] }) else { return .init(id: "feeds.trace.kind.tool.preload", state: .unreadable, rows: rows.count, newest: modification(file), evidence: "tool.preload row has no tools array") }
    let counts = rows.map { (($0["payload"] as! [String: Any])["tools"] as! [Any]).count }
    let suspicious = counts.filter { $0 == 0 || $0 >= 80 }
    let evidence = !suspicious.isEmpty ? "ALERT: \(suspicious.count) preload row(s) selected zero or ≥80 tools" : rows.isEmpty ? "0 preload rows — no per-turn preload evidence in this feed" : "envelope reader: \(rows.count) row(s), tool count \(counts.min() ?? 0)…\(counts.max() ?? 0)"
    return .init(id: "feeds.trace.kind.tool.preload", state: .active, rows: rows.count, newest: modification(file), evidence: evidence)
}

func evalLane(now: Date) -> Result {
    let appRuns = canonicalRoot.appendingPathComponent("evals/runs.json")
    let contextRuns = canonicalRoot.appendingPathComponent("context/evals/runs.json")
    let selectionQueries = canonicalRoot.appendingPathComponent("evals/selection_ab_queries.json")
    let files = [appRuns, contextRuns, selectionQueries]
    let observed = files.filter { fm.fileExists(atPath: $0.path) }
    guard !observed.isEmpty else {
        return .init(id: "feeds.evals.uncovered_rest", state: .absent, rows: 0, newest: nil, evidence: "source absent — not a zero")
    }
    guard observed.count == files.count,
          let appRows = array(appRuns),
          let contextRows = array(contextRuns),
          let selection = object(selectionQueries),
          let queries = selection["queries"] as? [String],
          !queries.isEmpty,
          queries.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else {
        return .init(id: "feeds.evals.uncovered_rest", state: .unreadable, rows: 0, newest: observed.compactMap(modification).max(), evidence: "eval-lane contract requires both run ledgers and a non-empty selection query corpus")
    }
    let runs = appRows + contextRows
    let stamps = runs.compactMap { row -> Date? in
        guard let id = row["id"] as? String, !id.isEmpty,
              let createdAt = date(row["createdAt"])
        else { return nil }
        return createdAt
    }
    guard stamps.count == runs.count else {
        return .init(id: "feeds.evals.uncovered_rest", state: .unreadable, rows: runs.count, newest: observed.compactMap(modification).max(), evidence: "eval run record lacks the canonical id/createdAt freshness stamp")
    }
    guard let newest = stamps.max() else {
        return .init(id: "feeds.evals.uncovered_rest", state: .dormant, rows: 0, newest: nil, evidence: "no eval run stamp across either ledger; selection corpus has \(queries.count) query/queries")
    }
    let corpusFormatter = ISO8601DateFormatter()
    let corpusStamp = modification(selectionQueries).map { corpusFormatter.string(from: $0) } ?? "unknown"
    return .init(
        id: "feeds.evals.uncovered_rest",
        state: freshness(newest, now: now),
        rows: runs.count,
        newest: newest,
        evidence: "newest app/context eval run must be within \(Int(days)) days; selection corpus has \(queries.count) query/queries and was modified \(corpusStamp)"
    )
}

func selfImprovement(now: Date) -> Result {
    let directory = canonicalRoot.appendingPathComponent("self_improvement", isDirectory: true)
    let marker = directory.appendingPathComponent("last_weekly_run")
    let digestDirectory = directory.appendingPathComponent("digests", isDirectory: true)
    let markerExists = fm.fileExists(atPath: marker.path)
    let digestDirectoryExists = fm.fileExists(atPath: digestDirectory.path)
    guard markerExists || digestDirectoryExists else {
        return .init(id: "feeds.self_improvement", state: .absent, rows: 0, newest: nil, evidence: "source absent — not a zero")
    }
    guard markerExists,
          digestDirectoryExists,
          let markerText = try? String(contentsOf: marker, encoding: .utf8),
          let stamp = date(markerText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let files = try? fm.contentsOfDirectory(at: digestDirectory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
    else {
        return .init(id: "feeds.self_improvement", state: .unreadable, rows: 0, newest: modification(marker), evidence: "weekly self-improvement contract requires an ISO marker and readable digest directory")
    }
    let digests = files.filter { $0.pathExtension == "md" }
    let dayFormatter = DateFormatter()
    dayFormatter.calendar = Calendar(identifier: .gregorian)
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.timeZone = TimeZone(identifier: "UTC")
    dayFormatter.dateFormat = "yyyy-MM-dd"
    let day = dayFormatter.string(from: stamp)
    let expected = digestDirectory.appendingPathComponent("\(day).md")
    guard let digest = try? String(contentsOf: expected, encoding: .utf8),
          !digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          digest.hasPrefix("# Self-Improvement Digest — \(day)")
    else {
        return .init(id: "feeds.self_improvement", state: .unreadable, rows: digests.count, newest: stamp, evidence: "weekly marker \(day) has no matching non-empty canonical digest")
    }
    return .init(
        id: "feeds.self_improvement",
        state: freshness(stamp, now: now),
        rows: digests.count,
        newest: stamp,
        evidence: "weekly marker and same-UTC-day digest are paired; newest committed pass must be within \(Int(days)) days"
    )
}

func workshopNotesAndFindings(now: Date) -> Result {
    let workshop = canonicalRoot.appendingPathComponent("workshop", isDirectory: true)
    guard fm.fileExists(atPath: workshop.path) else {
        return .init(id: "feeds.workshop.notes_and_findings", state: .absent, rows: 0, newest: nil, evidence: "source absent — not a zero")
    }
    guard let roots = try? fm.contentsOfDirectory(at: workshop, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
        return .init(id: "feeds.workshop.notes_and_findings", state: .unreadable, rows: 0, newest: modification(workshop), evidence: "workshop artifact root cannot be enumerated")
    }
    var handleRoots: [URL] = []
    for root in roots where root.lastPathComponent.hasPrefix("desk_") {
        let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            return .init(id: "feeds.workshop.notes_and_findings", state: .unreadable, rows: 0, newest: modification(workshop), evidence: "workshop desk-handle artifact root must be a real directory")
        }
        handleRoots.append(root)
    }
    var artifacts: [URL] = []
    for handleRoot in handleRoots {
        guard let enumerator = fm.enumerator(
            at: handleRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .init(id: "feeds.workshop.notes_and_findings", state: .unreadable, rows: artifacts.count, newest: artifacts.compactMap(modification).max(), evidence: "workshop handle artifact root cannot be enumerated")
        }
        for case let file as URL in enumerator {
            let relative = file.path.replacingOccurrences(of: handleRoot.path + "/", with: "")
            let parts = relative.split(separator: "/").map(String.init)
            let isNamedArtifact = file.lastPathComponent == "findings.md" || parts.contains("notes") || parts.contains("findings")
            guard isNamedArtifact else { continue }
            let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true {
                return .init(id: "feeds.workshop.notes_and_findings", state: .unreadable, rows: artifacts.count + 1, newest: artifacts.compactMap(modification).max(), evidence: "workshop note/finding must not be a symlink")
            }
            guard values?.isDirectory != true else { continue }
            guard values?.isRegularFile == true, file.pathExtension == "md", (values?.fileSize ?? 0) > 0,
                  let content = try? String(contentsOf: file, encoding: .utf8),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .init(id: "feeds.workshop.notes_and_findings", state: .unreadable, rows: artifacts.count + 1, newest: artifacts.compactMap(modification).max(), evidence: "workshop note/finding must be a non-empty UTF-8 Markdown file")
            }
            artifacts.append(file)
        }
    }
    guard !artifacts.isEmpty else {
        return .init(id: "feeds.workshop.notes_and_findings", state: .absent, rows: 0, newest: nil, evidence: "no note/finding artifacts under workshop desk handles — not a zero")
    }
    return .init(id: "feeds.workshop.notes_and_findings", state: .active, rows: artifacts.count, newest: artifacts.compactMap(modification).max(), evidence: "read-only integrity check of handle-scoped note/finding Markdown artifacts")
}

func backupEventsPreScrub(now: Date) -> Result {
    let directory = canonicalRoot.appendingPathComponent("backups", isDirectory: true)
    guard fm.fileExists(atPath: directory.path) else {
        return .init(id: "feeds.backups.events_pre_scrub", state: .absent, rows: 0, newest: nil, evidence: "source absent — not a zero")
    }
    guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
        return .init(id: "feeds.backups.events_pre_scrub", state: .unreadable, rows: 0, newest: modification(directory), evidence: "pre-scrub backup directory cannot be enumerated")
    }
    let candidates = entries.filter {
        $0.lastPathComponent.hasPrefix("events-pre-") && $0.lastPathComponent.contains("-scrub-")
    }
    guard !candidates.isEmpty else {
        return .init(id: "feeds.backups.events_pre_scrub", state: .absent, rows: 0, newest: nil, evidence: "no pre-scrub event snapshots — not a zero")
    }
    func snapshotStamp(_ name: String) -> Date? {
        guard name.hasPrefix("events-pre-"), name.hasSuffix(".jsonl") else { return nil }
        let body = String(name.dropFirst("events-pre-".count).dropLast(".jsonl".count))
        guard let split = body.range(of: "-scrub-", options: .backwards) else { return nil }
        let reason = String(body[..<split.lowerBound])
        let rawStamp = String(body[split.upperBound...])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !reason.isEmpty, reason.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = rawStamp.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss"
        return formatter.date(from: rawStamp)
    }
    var rows = 0
    var newest: Date?
    for file in candidates {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              let stamp = snapshotStamp(file.lastPathComponent),
              let events = jsonLines(file)
        else {
            return .init(id: "feeds.backups.events_pre_scrub", state: .unreadable, rows: rows, newest: newest ?? modification(file), evidence: "pre-scrub backup name or JSONL is malformed")
        }
        for event in events {
            guard let id = event["id"] as? String,
                  UUID(uuidString: id)?.uuidString.lowercased() == id,
                  date(event["createdAt"]) != nil,
                  let kind = event["kind"] as? String, !kind.isEmpty,
                  let status = event["status"] as? String, !status.isEmpty,
                  let title = event["title"] as? String, !title.isEmpty,
                  event["payload"] is [String: Any]
            else {
                return .init(id: "feeds.backups.events_pre_scrub", state: .unreadable, rows: rows, newest: newest ?? modification(file), evidence: "pre-scrub event violates the canonical id/timestamp/kind/status/title/payload envelope")
            }
        }
        rows += events.count
        newest = max(newest ?? stamp, stamp)
    }
    return .init(id: "feeds.backups.events_pre_scrub", state: .unbounded, rows: rows, newest: newest, evidence: "pre-scrub event snapshots have no bounded retention owner; payload bodies are intentionally not reported")
}

let now = Date()
let formatter = ISO8601DateFormatter()
let fossilAudit = fossilDirectoryReport(now: now)
let results = [connectorReceipts(now: now), workJournal(now: now), researchRuns(id: "feeds.research.browser_runs", path: "native_power/browser/runs.json", configuredPath: nil, now: now), researchRuns(id: "feeds.research.lab_runs", path: "research/lab/runs.json", configuredPath: "research/lab/config.json", now: now), dreamDiary(now: now), traceRetention(now: now), mcpReceipts(now: now), maintenanceSweep(now: now), preload(now: now), evalLane(now: now), selfImprovement(now: now), workshopNotesAndFindings(now: now), backupEventsPreScrub(now: now), fossilAudit.result]
var report = "# Feed coverage report\n\n"
report += "Read-only evaluation of canonical feed contracts with production-owned schemas. Generic reachability rows are intentionally excluded.\n\n"
report += "| feed | state | rows | newest | evidence |\n|---|---|---:|---|---|\n"
for result in results { report += "| `\(result.id)` | **\(result.state.rawValue)** | \(result.rows) | \(result.newest.map(formatter.string) ?? "—") | \(cell(result.evidence)) |\n" }
let summary = Dictionary(grouping: results, by: \.state).map { "\($0.key.rawValue): \($0.value.count)" }.sorted().joined(separator: ", ")
report += "\n**Summary:** \(summary).\n"
func byteLabel(_ bytes: Int64) -> String { "\(bytes) B" }
func fossilRows(_ directories: [FossilDirectory]) -> String {
    directories.map { "| `\($0.name)/` | \(byteLabel($0.bytes)) | \($0.newest.map(formatter.string) ?? "no files") |" }.joined(separator: "\n")
}
report += "\n## RETIRED/FOSSIL top-level directories\n\n"
report += "No file write in the last \(Int(fossilDays)) days. These paths are dated inventory, not active feed blind spots.\n\n"
report += fossilAudit.retired.isEmpty
    ? "None.\n"
    : "| directory | bytes | newest file write |\n|---|---:|---|\n\(fossilRows(fossilAudit.retired))\n"
report += "\n## UNCOVERED BUT LIVE top-level directories\n\n"
report += "File writes occurred inside the last \(Int(fossilDays)) days; these remain live observation candidates.\n\n"
report += fossilAudit.live.isEmpty
    ? "None.\n"
    : "| directory | bytes | newest file write |\n|---|---:|---|\n\(fossilRows(fossilAudit.live))\n"
if let out { try report.write(to: out, atomically: true, encoding: .utf8) } else { print(report, terminator: "") }
