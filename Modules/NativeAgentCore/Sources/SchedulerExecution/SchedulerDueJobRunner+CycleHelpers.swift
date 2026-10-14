import Foundation
import NativeAgentCore
import PersistenceCore
import TelegramBot
import TriggerScheduler

extension SchedulerDueJobRunner {
    /// Keep recent one-shot completion and unknown-outcome history for review.
    static let oneShotRetentionSeconds: Double = 7 * 86_400

    static func pruneRetiredRows(
        _ rows: [JSONValue],
        now: Date
    ) -> (rows: [JSONValue], retired: [JSONValue]) {
        var kept: [JSONValue] = []
        kept.reserveCapacity(rows.count)
        var retired: [JSONValue] = []
        let nowEpoch = now.timeIntervalSince1970
        for row in rows {
            guard case .object(let obj) = row,
                  let id = SchedulerJobRuntime.string(obj["id"]), !id.isEmpty else {
                kept.append(row)
                continue
            }
            let kind = (SchedulerJobRuntime.string(obj["kind"]) ?? "notify").lowercased()
            let enabled = SchedulerJobRuntime.bool(obj["enabled"], default: true)
            let lastRun = SchedulerJobRuntime.string(obj["lastRunAt"]).flatMap(parseISODate)
            var why: String?
            if JobKind(rawValue: kind) == nil {
                why = "job kind is no longer executed"
            } else if SchedulerJobRuntime.bool(obj["oneShot"], default: false) {
                if let completed = SchedulerJobRuntime.string(obj["completedAt"]).flatMap(parseISODate) {
                    if now.timeIntervalSince(completed) > oneShotRetentionSeconds {
                        why = "completed one-shot past 7-day retention"
                    }
                } else if !enabled || SchedulerJobRuntime.string(obj["cancelledAt"]) != nil,
                          SchedulerJobRuntime.string(obj["pausedAt"]) == nil,
                          let due = SchedulerJobRuntime.epoch(from: obj["nextRunAt"])
                            ?? SchedulerJobRuntime.epoch(from: obj["nextRunAtEpoch"]), due < nowEpoch {
                    if SchedulerJobRuntime.string(obj["lastRunStatus"]) == "unknown" {
                        if nowEpoch - max(due, lastRun?.timeIntervalSince1970 ?? due) > oneShotRetentionSeconds {
                            why = "unknown one-shot outcome past 7-day review window"
                        }
                    } else {
                        why = "disabled or cancelled one-shot past its scheduled time"
                    }
                }
            } else if !enabled,
                      SchedulerJobRuntime.string(obj["pausedAt"]) == nil,
                      SchedulerJobRuntime.string(obj["cancelledAt"]) == nil,
                      (SchedulerJobRuntime.string(obj["disabledReason"]) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let lastActivity = lastRun
                        ?? SchedulerJobRuntime.string(obj["createdAt"]).flatMap(parseISODate),
                      now.timeIntervalSince(lastActivity) > 90 * 86_400 {
                why = "disabled recurring job with no run in 90 days and no owner reason"
            }
            if let why {
                retired.append(.object(["id": .string(id), "kind": .string(kind), "why": .string(why),
                                        "at": .string(NativeTimestampFormat.fractionalZulu(now))]))
            } else {
                kept.append(row)
            }
        }
        return (kept, retired)
    }

    static func nextEpoch(
        schedule: [String: JSONValue],
        now: Date
    ) throws -> Double {
        let job: JSONValue = .object([
            "oneShot": .bool(false),
            "schedule": .object(schedule),
        ])
        return try SchedulerJobRuntime.nextRunEpoch(
            for: job,
            afterEpoch: now.timeIntervalSince1970,
            now: { now }
        )!
    }

    static func containsLastRunToday(rows: [JSONValue], kind: String, dateKey: String, includingFailed: Bool = false) -> Bool {
        rows.contains { row in
            guard case .object(let obj) = row else { return false }
            let rowKind = (SchedulerJobRuntime.string(obj["kind"]) ?? "").lowercased()
            guard rowKind == kind else { return false }
            let status = (SchedulerJobRuntime.string(obj["lastRunStatus"]) ?? "").lowercased()
            guard includingFailed || status != "error" else { return false }
            guard let raw = SchedulerJobRuntime.string(obj["lastRunAt"]),
                  let date = parseISODate(raw) else { return false }
            return NativeAgentDreamCycleSchedule.runDateKey(date) == dateKey
        }
    }

    static func notificationRowDiaryDateKeys(_ obj: [String: JSONValue]) -> Set<String> {
        var dates: Set<String> = []
        if let id = SchedulerJobRuntime.string(obj["id"]),
           id.hasPrefix("dream-cycle-") {
            let dateKey = String(id.dropFirst("dream-cycle-".count).prefix(10))
            if dateKey.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                dates.insert(dateKey)
            }
        }
        guard case .array(let paths)? = obj["related_paths"] else {
            return dates
        }
        for pathValue in paths {
            guard let path = SchedulerJobRuntime.string(pathValue) else { continue }
            let name = (path as NSString).lastPathComponent
            let dateKey = String(name.prefix(10))
            guard dateKey.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { continue }
            if name == "\(dateKey).md" || (name.hasPrefix("\(dateKey)_") && name.hasSuffix(".md")) {
                dates.insert(dateKey)
            }
        }
        return dates
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
            // User, 2026-09-13 (a 0.4.11 install): the generic sentence plus the
            // trailing "Errors:" block read as "something went wrong" in the
            // notification, while the actual cause was one sentence the backend
            // had already said ("The 'gpt-5.4-mini' model is not supported when
            // using Codex with a ChatGPT account"). Put the real line second so
            // it survives into the notification body.
            if let detail = firstErrorDetailLine(errors) {
                lines.append(detail)
            }
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

    /// The first non-empty line of the first error that carries one, trimmed to
    /// 160 characters so a long provider payload cannot swamp the notice.
    static func firstErrorDetailLine(_ errors: [String], limit: Int = 160) -> String? {
        for error in errors {
            for raw in error.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                if line.count <= limit { return line }
                return String(line.prefix(limit - 1)) + "…"
            }
        }
        return nil
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

    /// A default cycle job parked (retry cap reached) on `dateKey`. While
    /// parked for the day the catch-up path must stay disarmed.
    static func containsRetryParkedToday(rows: [JSONValue], kind: String, dateKey: String) -> Bool {
        rows.contains { row in
            guard case .object(let obj) = row else { return false }
            let rowKind = (SchedulerJobRuntime.string(obj["kind"]) ?? "").lowercased()
            guard rowKind == kind else { return false }
            return SchedulerJobRuntime.string(obj["retryParkedDateKey"]) == dateKey
        }
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
        NativeTimestampFormat.parseISO8601FractionalFirst(raw)
    }

    static func anyInt(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let int64 = value as? Int64 { return Int(int64) }
        if let double = value as? Double { return Int(exactly: double.rounded(.towardZero)) ?? 0 }
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
