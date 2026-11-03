import Foundation
import AgentWorkspace
import Desk
import NativeAgentShared
import PersistenceCore
import TriggerScheduler
// Blueprint: | `EngineIntentionMigration.swift` | NativeAgentEngine one-time launch retirement of enabled turn/notify/workshop jobs into MY QUEUE; durable byte-exact backup, disabled definitions retained with disposition, precise clockStart timing and first-migration identity; completed roots only stop restored rows with one Desk notice, never remigrate; cancellation deadlines transfer to until, ambiguous effects stay stopped; body rhythms stay scheduler-owned |

extension NativeAgentEngine {
    /// Before the resident clock starts, her scheduled work takes the one form
    /// she carries, once. Later restored jobs need her decision, never a reimport.
    static func migrateScheduledIntentionsAtLaunch(dataRoot: URL) async throws {
        let marker = dataRoot.appendingPathComponent("scheduler/.intentions-migrated")
        let finished = MyQueue.scheduledMigrationMarker(dataRoot: dataRoot)
        try await SwiftNativePersistenceCore.withFileLock(marker) {
            let scheduler = SwiftNativeTriggerScheduler(root: dataRoot)
            try await SwiftNativePersistenceCore.withFileLock(scheduler.jobsPath) {
                // The job lock spans backup, filing and retirement. No other
                // writer can change a definition between its read and commit.
                // Completion is permanent, including the earlier empty flag.
                // A restore cannot identify steps made by the old migrator.
                if FileManager.default.fileExists(atPath: finished.path) {
                    _ = try Data(contentsOf: finished)
                    try await scheduler.stopRestoredIntentionJobs()
                    return
                }
                guard FileManager.default.fileExists(atPath: scheduler.jobsPath.path) else { return }
                let jobs = try SwiftNativeTriggerScheduler.readJobsChecked(at: scheduler.jobsPath)
                if jobs.contains(where: { row in
                    guard let job = row.objectValue else { return false }
                    return ScheduledIntention.isLegacy(job)
                }) {
                    let backup = dataRoot.appendingPathComponent("scheduler/pre-intentions-finish-\(UUID().uuidString.lowercased()).jobs.json")
                    let snapshot = try Data(contentsOf: scheduler.jobsPath)
                    try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(snapshot, to: backup)
                    guard case .array(let savedRows) = try JSONValue.parse(snapshot) else {
                        throw ScheduledIntentionError(reason: "Scheduled jobs must be an array; source bytes preserved.")
                    }
                    let now = Date()
                    // Invalid live work blocks bring-up with its cause, never silently
                    // retained as a second execution path or treated as completed.
                    var intentions = try jobs.compactMap { try ScheduledIntention($0, now: now, backup: backup) }
                    guard Set(intentions.map(\.id)).count == intentions.count else {
                        throw ScheduledIntentionError(reason: "Enabled scheduled intentions have duplicate job ids; repair the source before migration.")
                    }
                    var dropped: Set<String> = []
                    for canceller in intentions {
                        guard canceller.step.status != "stopped",
                              let target = try canceller.cancellationTarget(in: intentions),
                              case .at(let deadline)? = MyQueue.When(canceller.step.when) else { continue }
                        let existing = MyQueue.Until(intentions[target].step.until).endsAt
                        intentions[target].step.until = "at " + NativeTimestampFormat.microsecondUTCOffset(min(existing ?? deadline, deadline), rounding: .up)
                        dropped.insert(canceller.id)
                    }
                    let store = SwiftNativeDeskStore(dataRoot: dataRoot)
                    var details: [String: String] = [:]
                    for job in intentions {
                        try Task.checkCancellation()
                        if dropped.contains(job.id) {
                            details[job.id] = "its intention ends itself"
                        } else {
                            let filed = try await MyQueue.add(job.step, store: store)
                            details[job.id] = "became intention " + filed.entry.name
                        }
                    }
                    // All Desk writes precede one scheduler commit. An interruption
                    // before it reuses job identity; after it, all live jobs are disabled.
                    // In particular a cancel job cannot outlive its target's conversion.
                    try Task.checkCancellation()
                    let completed = details
                    // File locks are task-reentrant; updateJobRows remains the
                    // canonical single writer, under the lock held since the read.
                    try await scheduler.updateJobRows { rows in
                        // The checked reader drops retired zone selectors. Keep
                        // untouched definitions exactly as saved, including them.
                        rows = savedRows
                        for index in rows.indices {
                            guard case .object(var row) = rows[index], ScheduledIntention.isLegacy(row) else { continue }
                            if !SchedulerJobRuntime.bool(row["enabled"], default: true) {
                                // Preserve paused words/timing and distinguish these
                                // saved definitions from a later restored backup.
                                if row["intentionMigration"] == nil {
                                    let prior = row["lastRunDetail"]?.stringValue ?? ""
                                    row["intentionMigration"] = .string(prior.hasPrefix("became intention ") || prior == "its intention ends itself"
                                        ? prior : "kept disabled at first migration")
                                }
                                rows[index] = .object(row)
                                continue
                            }
                            guard let id = row["id"]?.stringValue, let detail = completed[id] else { continue }
                            row["enabled"] = .bool(false)
                            row["lastRunDetail"] = .string(detail)
                            row["intentionMigration"] = .string(detail)
                            rows[index] = .object(row)
                        }
                    }
                }
                // The durable completion ends migration for this data root.
                // Partial first attempts remain held until this write succeeds.
                try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(Data(), to: marker)
                try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(Data(), to: finished)
            }
            StoreChangeBus.shared.emit(StoreChange(store: .desk, path: SwiftNativeDeskStore(dataRoot: dataRoot).opsPath))
        }
    }
}

private struct ScheduledIntention {
    let id: String
    let name: String
    let kind: String
    let prompt: String
    let oneShot: Bool
    var step: DeskStep

    static func isLegacy(_ job: [String: JSONValue]) -> Bool {
        ["turn", "notify", "workshop"].contains(SchedulerJobRuntime.string(job["kind"])?.lowercased() ?? "notify")
    }

    init?(_ value: JSONValue, now: Date, backup: URL) throws {
        guard case .object(let job) = value, SchedulerJobRuntime.bool(job["enabled"], default: true),
              Self.isLegacy(job) else { return nil }
        let kind = SchedulerJobRuntime.string(job["kind"])?.lowercased() ?? "notify"
        guard let id = job["id"]?.stringValue, !id.isEmpty else {
            throw ScheduledIntentionError(reason: "An enabled scheduled intention has no job id.")
        }
        self.id = id
        self.kind = kind
        name = job["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let payload = job["payload"]?.objectValue ?? [:]
        let text: String?
        switch kind {
        case "turn": text = payload["prompt"]?.stringValue
        case "notify": text = payload["message"]?.stringValue ?? payload["body"]?.stringValue
        default: text = payload["objective"]?.stringValue
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScheduledIntentionError(reason: "Scheduled job \(id) has no \(kind) words to carry.")
        }
        prompt = text
        let words = name.isEmpty || text.range(of: name, options: .caseInsensitive) != nil
            ? text : name + ": " + text
        let schedule = job["schedule"]?.objectValue
        let type = (schedule?["type"]?.stringValue ?? schedule?["kind"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        oneShot = SchedulerJobNormalizer.isOneShot(job) || type == "at"
        var due = SchedulerJobRuntime.scheduledEpoch(for: job).map { Date(timeIntervalSince1970: $0) }
        var uncertain = job["activeOccurrence"] != nil
            || ["unknown", "stopped"].contains(job["lastRunStatus"]?.stringValue ?? "")
        if let at = due, let consumed = job["lastOccurrenceKey"]?.stringValue {
            let occurrence = try SwiftNativeTriggerScheduler.DueJob(id: id, name: name, kind: kind,
                payload: payload, row: value, dueEpoch: at.timeIntervalSince1970)
            if occurrence.occurrenceKey == consumed {
                if oneShot { uncertain = true }
                else {
                    due = try SchedulerJobRuntime.nextRunEpochAfterNow(for: value, beyond: at.timeIntervalSince1970, now: { now })
                        .map { Date(timeIntervalSince1970: $0) }
                }
            }
        }
        if oneShot {
            if let date = due {
                step = DeskStep(words: words, when: "at " + NativeTimestampFormat.microsecondUTCOffset(date, rounding: .up),
                                origin: "self", say: kind == "notify" ? text : nil)
            } else if kind == "turn", text.range(of: #"\bcancel\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                // No deadline can be transferred. Carry the failure for her
                // judgment; never silently execute a cancellation early.
                step = DeskStep(words: words + "\nThe scheduled run time for job \(id) is unreadable. Reconcile its intended time before carrying out these instructions.",
                                when: "own_turn", origin: "self")
            } else {
                throw ScheduledIntentionError(reason: "Scheduled job \(id) has no readable nextRunAt.")
            }
        } else {
            let raw: JSONValue
            if let schedule {
                raw = .object(schedule)
            } else if let seconds = job["intervalSeconds"], seconds != .null {
                raw = .object(["type": .string("every"), "seconds": seconds])
            } else {
                throw ScheduledIntentionError(reason: "Scheduled job \(id) has no rhythm.")
            }
            guard let rhythm = SchedulerJobNormalizer.rhythm(raw) else {
                throw ScheduledIntentionError(reason: "Scheduled job \(id) has an unreadable rhythm.")
            }
            guard let due else {
                throw ScheduledIntentionError(reason: "Scheduled job \(id) has no readable next occurrence; its timing must be repaired before migration.")
            }
            let until = try Self.endOfPinnedDay(rhythm, now: now)
            step = DeskStep(words: words, when: "every", origin: "self", rhythm: rhythm,
                            until: until.map { "at " + ISO8601DateFormatter().string(from: $0) } ?? "standing",
                            say: kind == "notify" ? text : nil)
            step.clockStart = IntentionClock.importedStart(at: due, rhythm: rhythm)
        }
        step.scheduledJobID = id
        if uncertain {
            step.status = "stopped"
            step.reason = "Prior scheduled effects are unconfirmed. Reconcile job \(id) in \(backup.path) and its receipts before refiling any work; never repeat it blindly."
            // No deadline may turn unresolved effects into a completed step.
            step.until = nil
        }
    }

    func cancellationTarget(in jobs: [ScheduledIntention]) throws -> Int? {
        guard kind == "turn", oneShot else { return nil }
        // Consume the whole prompt. Extra instructions must keep their own turn.
        let regex = try NSRegularExpression(pattern: #"^\s*(?:please\s+)?cancel\s+(?:the\s+)?(?:scheduled\s+)?(?:job\s+)?(?:(?:named|called)\s+|(?:with\s+)?(id(?:\s+starts(?:\s+with)?)?)\s*[:=]?\s+)?[\x22'`(]?(.+?)[\x22'`)]?[.!]?\s*$"#, options: .caseInsensitive)
        guard let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
              let range = Range(match.range(at: 2), in: prompt) else { return nil }
        let target = String(prompt[range]).lowercased()
        let explicitID = match.range(at: 1).location != NSNotFound
        let matches = jobs.indices.filter { index in
            let other = jobs[index]
            guard other.id != id, other.step.rhythm != nil, other.step.status != "stopped" else { return false }
            if !explicitID, !other.name.isEmpty, other.name.lowercased() == target { return true }
            return other.id.lowercased() == target
                || ((explicitID || target.count >= 8) && other.id.lowercased().hasPrefix(target)
                    && jobs.filter { $0.id.lowercased().hasPrefix(target) }.count == 1)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// A single day and month have one intended year, rather than rolling
    /// around forever. Keep this day's end even after its final clock moment.
    private static func endOfPinnedDay(_ rhythm: JSONValue, now: Date) throws -> Date? {
        guard let schedule = rhythm.objectValue,
              (schedule["type"]?.stringValue ?? schedule["kind"]?.stringValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cron",
              let expression = schedule["expression"]?.stringValue ?? schedule["cron"]?.stringValue else { return nil }
        let fields = expression.split(whereSeparator: \.isWhitespace)
        guard fields.count == 5, let day = Int(fields[2]), let month = Int(fields[3]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        func end(in year: Int) -> Date? {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 23, minute: 59))
        }
        if let date = end(in: calendar.component(.year, from: now)), date >= now { return date }
        guard let next = SchedulerJobNormalizer.nextOccurrence(rhythm, after: now),
              let date = end(in: calendar.component(.year, from: next)) else {
            throw ScheduledIntentionError(reason: "Could not find the end of the pinned cron day: \(expression).")
        }
        return date
    }
}

private struct ScheduledIntentionError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}
