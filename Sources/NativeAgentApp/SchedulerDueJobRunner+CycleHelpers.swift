import Foundation
import NativeAgentCore
import PersistenceCore
import TelegramBot
import TriggerScheduler

extension SchedulerDueJobRunner {
    static func upsertDefaultCycleJob(
        rows: inout [JSONValue],
        id: String,
        legacyNames: Set<String>,
        name: String,
        kind: String,
        intervalSeconds: Int,
        schedule: [String: JSONValue],
        objective: String,
        extraPayload: [String: JSONValue],
        nextRunEpoch: Double,
        now: Date,
        reactivateCancelled: Bool = false
    ) -> Bool {
        let matchIndex = rows.firstIndex { row in
            guard case .object(let obj) = row else { return false }
            let rowID = SchedulerJobRuntime.string(obj["id"]) ?? ""
            if rowID == id { return true }
            let rowKind = (SchedulerJobRuntime.string(obj["kind"]) ?? "").lowercased()
            let rowName = (SchedulerJobRuntime.string(obj["name"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return rowKind == kind && legacyNames.contains(rowName)
        }

        var existing: [String: JSONValue] = [:]
        if let matchIndex, case .object(let obj) = rows[matchIndex] {
            existing = obj
        }

        // 2026-07-21 audit fix: a user-cancelled default job STAYS cancelled.
        // cancelJob() stamps enabled=false + cancelledAt; before this guard the
        // upsert below forced enabled=true, silently resurrecting the job on
        // the next due-job pass.
        //
        // 2026-07-23 audit fix (F3-M1): the PASSIVE bootstrap pass must honor
        // that tombstone, but an EXPLICIT user re-enable action (createDreamJob
        // → ensureDefaultCycleJobs(reactivateCancelled: true)) must be able to
        // clear it — otherwise, once cancelled, the job could never be
        // re-created because cancelledAt is never stripped anywhere. Only the
        // explicit path passes reactivateCancelled; the passive due-job pass
        // keeps it false and still no-ops on a cancelled row.
        let isCancelledTombstone = existing["cancelledAt"] != nil
            && existing["enabled"] == .bool(false)
        if isCancelledTombstone, !reactivateCancelled {
            return false
        }

        // 2026-07-21 audit fix: preserve an EARLIER existing nextRunAt (e.g. a
        // 15-minute retryAfterSeconds retry stamped by update(job:), or an
        // overdue catch-up) instead of stomping it with the recomputed
        // schedule — previously the very next ensureDefaultCycleJobs pass
        // rewrote a pending dream retry to tomorrow 03:30 and the "retry
        // scheduled in 15 minutes" receipt was a lie. A LATER existing stamp
        // still yields to the freshly computed schedule.
        //
        // 2026-07-23 FIX 1 (A4.1): a PENDING retry stamp is a FLOOR, not a
        // candidate for the min() below. During a provider outage the failed
        // run stamps a backoff retry (retryPendingUntilEpoch); the catch-up
        // path recomputes nextRunEpoch ≈ now (a failed run does not count as
        // "ran today", so dreamCatchUp stays armed). Under the bare min() rule
        // that ≈now candidate would BEAT the retry stamp and pull the job back
        // to now — collapsing the 15/30/60-minute backoff into a ~60s all-day
        // retry loop (1440 provider calls/day + receipt-cap poisoning). Honor
        // the retry stamp instead: catch-up may never pull earlier than it.
        let effectiveNextRunEpoch: Double = {
            if let pendingRetry = SchedulerJobRuntime.epoch(from: existing["retryPendingUntilEpoch"]),
               pendingRetry.isFinite,
               pendingRetry > now.timeIntervalSince1970 {
                return pendingRetry
            }
            guard let existingEpoch = SchedulerJobRuntime.epoch(from: existing["nextRunAtEpoch"] ?? existing["nextRunAt"]) else {
                return nextRunEpoch
            }
            return min(existingEpoch, nextRunEpoch)
        }()

        var next = existing
        // Explicit reactivation strips the cancellation tombstone; the upsert
        // already forces enabled=true below, so re-enable + un-cancel land
        // together. (cancelJob stamps only enabled=false + cancelledAt.)
        if isCancelledTombstone, reactivateCancelled {
            next.removeValue(forKey: "cancelledAt")
        }
        next["id"] = .string(id)
        next["name"] = .string(name)
        next["kind"] = .string(kind)
        next["intervalSeconds"] = .int(Int64(intervalSeconds))
        next["enabled"] = .bool(true)
        next["oneShot"] = .bool(false)
        next["schedule"] = .object(schedule)
        var payload = extraPayload
        payload["objective"] = .string(objective)
        next["payload"] = .object(payload)
        next["createdBy"] = existing["createdBy"] ?? .string("nativeagent_bootstrap")
        next["createdAt"] = existing["createdAt"] ?? .string(iso(now))
        next["nextRunAt"] = .string(SchedulerJobRuntime.floatString(effectiveNextRunEpoch))
        next["nextRunAtEpoch"] = .int(Int64(effectiveNextRunEpoch))
        next["nextRunAtISO"] = .string(SchedulerJobRuntime.decorationISO(epoch: effectiveNextRunEpoch))
        if existing["lastRunAt"] == nil { next["lastRunAt"] = .null }

        let nextValue = JSONValue.object(next)
        if let matchIndex {
            if rows[matchIndex] == nextValue { return false }
            rows[matchIndex] = nextValue
        } else {
            rows.append(nextValue)
        }
        return true
    }

    // MARK: - FIX 3 (A4.5): completed oneShot pruning.

    /// A completed oneShot row is retained this long after `completedAt` before
    /// it is pruned, so recent history stays visible without unbounded growth.
    static let oneShotRetentionSeconds: Double = 7 * 86_400

    /// Drop completed oneShot rows older than the retention window. A oneShot
    /// (`oneShot == true`) with a parseable `completedAt` past the window is
    /// removed; every other row (recurring jobs, recently-completed oneShots,
    /// oneShots with no completion stamp) is kept untouched. Pure so the test
    /// net drives it directly.
    static func pruneCompletedOneShotRows(
        _ rows: [JSONValue],
        now: Date,
        retentionSeconds: Double = oneShotRetentionSeconds
    ) -> (rows: [JSONValue], removed: Int) {
        var kept: [JSONValue] = []
        kept.reserveCapacity(rows.count)
        var removed = 0
        for row in rows {
            guard case .object(let obj) = row,
                  SchedulerJobRuntime.bool(obj["oneShot"], default: false),
                  let raw = SchedulerJobRuntime.string(obj["completedAt"]),
                  let completed = parseISODate(raw),
                  now.timeIntervalSince(completed) > retentionSeconds else {
                kept.append(row)
                continue
            }
            removed += 1
        }
        return (kept, removed)
    }

    static func nextEpoch(
        schedule: [String: JSONValue],
        now: Date,
        fallbackInterval: TimeInterval
    ) throws -> Double {
        let job: JSONValue = .object([
            "oneShot": .bool(false),
            "schedule": .object(schedule),
        ])
        return try SchedulerJobRuntime.nextRunEpoch(
            for: job,
            afterEpoch: now.timeIntervalSince1970,
            now: { now }
        ) ?? now.addingTimeInterval(fallbackInterval).timeIntervalSince1970
    }

    static func containsLastRunToday(rows: [JSONValue], kind: String, dateKey: String) -> Bool {
        rows.contains { row in
            guard case .object(let obj) = row else { return false }
            let rowKind = (SchedulerJobRuntime.string(obj["kind"]) ?? "").lowercased()
            guard rowKind == kind else { return false }
            // A FAILED run must not count as "ran today" — it disarmed the
            // catch-up for the whole day (2026-07-20/21 live: two nights of
            // "connection refused: api.kimi.com" at 03:31, and the failed
            // attempt itself then blocked the daytime catch-up that would
            // have recovered the dream once the network was back).
            let status = (SchedulerJobRuntime.string(obj["lastRunStatus"]) ?? "").lowercased()
            guard status != "error" else { return false }
            guard let raw = SchedulerJobRuntime.string(obj["lastRunAt"]),
                  let date = parseISODate(raw) else { return false }
            return NativeAgentDreamCycleSchedule.runDateKey(date) == dateKey
        }
    }

    static func notificationRowReferencesDate(_ obj: [String: JSONValue], dateKey: String) -> Bool {
        if let id = SchedulerJobRuntime.string(obj["id"]),
           id.contains("dream-cycle-\(dateKey)") {
            return true
        }
        guard case .array(let paths)? = obj["related_paths"] else {
            return false
        }
        for pathValue in paths {
            guard let path = SchedulerJobRuntime.string(pathValue) else { continue }
            let name = (path as NSString).lastPathComponent
            if name == "\(dateKey).md" || (name.hasPrefix("\(dateKey)_") && name.hasSuffix(".md")) {
                return true
            }
        }
        return false
    }

    static func hasDreamEntry(dataRoot: URL, dateKey: String) -> Bool {
        let dir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return names.contains { name in
            name == "\(dateKey).md" || (name.hasPrefix("\(dateKey)_") && name.hasSuffix(".md"))
        }
    }

    static func dreamEntriesForToday(dataRoot: URL, dateKey: String) -> [DreamDiarySnippet] {
        let dir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let urls = names
            .filter { $0 == "\(dateKey).md" || ($0.hasPrefix("\(dateKey)_") && $0.hasSuffix(".md")) }
            .map { dir.appendingPathComponent($0) }
            .sorted { lhs, rhs in
                modificationDate(lhs) > modificationDate(rhs)
            }
        return urls.prefix(5).map { url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let extracted = extractDreamTitleAndSummary(text)
            return DreamDiarySnippet(path: url.path, title: extracted.title, summary: extracted.summary)
        }
    }

    static func modificationDate(_ url: URL) -> Date {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else {
            return .distantPast
        }
        return date
    }

    static func extractDreamTitleAndSummary(_ text: String) -> (title: String, summary: String) {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var title = ""
        var summary = ""
        for line in lines {
            if line.hasPrefix("#") { continue }
            if title.isEmpty, line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
                title = String(line.dropFirst(2).dropLast(2))
                continue
            }
            if line.hasPrefix("**") || line.hasPrefix("_Mood:") || line.hasPrefix("- ") {
                continue
            }
            if summary.isEmpty {
                summary = line
                break
            }
        }
        return (title, summary)
    }

    static func dreamInboxMessage(
        entriesWritten: Int,
        sessionsProcessed: Int,
        errors: [String],
        entries: [DreamDiarySnippet]
    ) -> String {
        var lines: [String] = []
        if entriesWritten <= 0, !errors.isEmpty {
            lines.append("Dream cycle hit a provider or runtime error before writing a diary entry.")
            if dreamErrorsAreRetryable(errors) {
                lines.append("No dream file was created. NativeAgent will retry automatically.")
            } else {
                lines.append("No dream file was created. This needs attention before the next scheduled dream.")
            }
            if sessionsProcessed > 0 {
                lines.append("Recent sessions scanned: \(sessionsProcessed).")
            }
        } else if entriesWritten > 0 {
            lines.append("Dream cycle wrote \(entriesWritten) entr\(entriesWritten == 1 ? "y" : "ies") across \(sessionsProcessed) recent session\(sessionsProcessed == 1 ? "" : "s").")
        } else {
            lines.append("Dream cycle ran, but there were no new dream entries to write.")
            if sessionsProcessed > 0 {
                lines.append("Recent sessions scanned: \(sessionsProcessed).")
            }
        }
        for entry in entries.prefix(3) {
            if !entry.title.isEmpty {
                lines.append(entry.title)
            }
            if !entry.summary.isEmpty {
                lines.append(entry.summary)
            }
        }
        if !errors.isEmpty {
            lines.append("Errors: \(errors.prefix(3).joined(separator: "; "))")
        }
        return lines.joined(separator: "\n\n")
    }

    static func dreamErrorsAreRetryable(_ errors: [String]) -> Bool {
        let text = errors.joined(separator: "\n").lowercased()
        if text.isEmpty { return false }
        if text.contains("notconfigured")
            || text.contains("not configured")
            || text.contains("unauthorized")
            || text.contains("forbidden")
            || text.contains("401")
            || text.contains("403") {
            return false
        }
        return text.contains("transient")
            || text.contains("network")
            || text.contains("connection")
            || text.contains("timed out")
            || text.contains("timeout")
            || text.contains("rate limited")
            || text.contains("unparseable llm response")
    }

    static func retryEpoch(from output: JSONValue, runDate: Date) -> Double? {
        guard case .object(let obj) = output else { return nil }
        if let explicit = SchedulerJobRuntime.epoch(from: obj["retryAtEpoch"] ?? obj["retry_at_epoch"]) {
            return max(explicit, runDate.addingTimeInterval(60).timeIntervalSince1970)
        }
        let after = SchedulerJobRuntime.int(
            obj["retryAfterSeconds"] ?? obj["retry_after_seconds"],
            default: 0
        )
        guard after > 0 else { return nil }
        return runDate.addingTimeInterval(Double(max(60, after))).timeIntervalSince1970
    }

    // MARK: - FIX 2 (A4.4): retry count + exponential backoff + daily cap.

    /// Consecutive retryable failures a job may accrue in a single day before
    /// it is PARKED (stops retrying, reschedules to its next natural run, and
    /// leaves a receipt) instead of retrying forever at the 60s due-floor.
    static let maxRetryAttemptsPerDay = 6

    /// Exponential backoff carried by the retry stamp: 15m → 30m → 60m (cap).
    /// The stamp itself is the backoff carrier — FIX 1's floor keeps the
    /// catch-up path from collapsing it.
    static func retryBackoffSeconds(attempt: Int) -> Int {
        switch attempt {
        case ..<2: return 15 * 60
        case 2: return 30 * 60
        default: return 60 * 60
        }
    }

    /// A default cycle job parked (retry cap reached) on `dateKey`. While
    /// parked for the day the catch-up path must stay disarmed even though the
    /// failed run does not count as "ran today".
    static func containsRetryParkedToday(rows: [JSONValue], kind: String, dateKey: String) -> Bool {
        rows.contains { row in
            guard case .object(let obj) = row else { return false }
            let rowKind = (SchedulerJobRuntime.string(obj["kind"]) ?? "").lowercased()
            guard rowKind == kind else { return false }
            return SchedulerJobRuntime.string(obj["retryParkedDateKey"]) == dateKey
        }
    }

    /// Stamp the canonical next-run trio on a job row.
    static func stampNextRun(_ obj: inout [String: JSONValue], epoch: Double) {
        obj["nextRunAt"] = .string(SchedulerJobRuntime.floatString(epoch))
        obj["nextRunAtEpoch"] = .int(Int64(epoch))
        obj["nextRunAtISO"] = .string(SchedulerJobRuntime.decorationISO(epoch: epoch))
    }

    /// Clear all retry/park bookkeeping — called on any successful or normally
    /// rescheduled run so the backoff self-heals once the outage clears.
    static func clearRetryState(_ obj: inout [String: JSONValue]) {
        obj.removeValue(forKey: "retryCount")
        obj.removeValue(forKey: "retryDayKey")
        obj.removeValue(forKey: "retryPendingUntilEpoch")
        obj.removeValue(forKey: "retryParkedDateKey")
    }

    static func remInboxMessage(
        proposalsGenerated: Int,
        archivedEntries: Int,
        tombstoneSkips: Int,
        growthMDEvicted: Bool
    ) -> String {
        var parts: [String] = [
            "Weekly REM consolidation generated \(proposalsGenerated) proposal\(proposalsGenerated == 1 ? "" : "s").",
        ]
        if tombstoneSkips > 0 {
            parts.append("\(tombstoneSkips) tombstoned proposal\(tombstoneSkips == 1 ? "" : "s") skipped.")
        }
        if archivedEntries > 0 {
            parts.append("\(archivedEntries) old dream entr\(archivedEntries == 1 ? "y" : "ies") archived.")
        }
        if growthMDEvicted {
            parts.append("GROWTH.md was compacted before new proposals.")
        }
        return parts.joined(separator: " ")
    }

    static func remRelatedPaths(dataRoot: URL) -> [String] {
        // Canonical REM stores (2026-06-10 cutover): proposals + pins live at
        // the dataRoot root; harness/rem_proposals.jsonl is import-only.
        [
            dataRoot.appendingPathComponent("rem_proposals.jsonl").path,
            dataRoot.appendingPathComponent("rem_pins.json").path,
            PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot).appendingPathComponent("GROWTH.md").path,
        ].filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func notificationBody(_ message: String) -> String {
        let flattened = message.replacingOccurrences(of: "\n\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flattened.prefix(220))
    }

    static func parseISODate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let withoutFraction = ISO8601DateFormatter()
        withoutFraction.formatOptions = [.withInternetDateTime]
        if let date = withoutFraction.date(from: raw) { return date }
        return nil
    }

    static func anyInt(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let int64 = value as? Int64 { return Int(int64) }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let int = Int(string) { return int }
        return 0
    }

    static func anyBool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["1", "true", "yes", "y"].contains(string.lowercased())
        }
        return false
    }

    static func anyStringArray(_ value: Any?) -> [String] {
        if let strings = value as? [String] { return strings }
        if let values = value as? [Any] { return values.map { String(describing: $0) } }
        return []
    }

    static func jsonValue(from dictionary: [String: Any]) -> JSONValue {
        guard JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let parsed = try? JSONValue.parse(data) else {
            return .object([:])
        }
        return parsed
    }

    static func object(_ value: JSONValue) -> [String: JSONValue] {
        if case .object(let obj) = value { return obj }
        return [:]
    }
}
