import Foundation
import PersistenceCore   // SwiftNativePersistenceCore + readJSONL (timeline scan)

// MARK: - Execution outcome scoreboard (MEASURE leg of the north-star, 2026-06-15)
//
// The north star is "Agent runs a real multi-step job unattended and gets
// MEASURABLY better week over week." Nothing in the system produced that
// number: the self-improvement machinery (ImprovementRun) records only the
// compile/test/promote LIFECYCLE of a code change, never the OUTCOME of the
// real jobs Agent actually runs. So there was no scoreboard — no way to say
// "her completion rate went up" or "she's solving jobs in fewer steps."
//
// This is that scoreboard, built the simplest way that produces the number: a
// PURE READ-SIDE aggregator over the execution records ALREADY persisted to
// mission.json (read via SwiftNativeWorkshopRunner.listAll()). Completed
// executions persist (only the submit-error path deletes an execution dir; there is
// no terminal cleanup), so the full history is on disk. Zero write-path, zero
// executor change, zero per-turn latency — it just reads what's there and
// buckets it by ISO week.
//
// v1 metrics come entirely from WorkshopExecutionRecord (status, createdAt, updatedAt,
// plan, stepsCompleted, rerunCount). `fromStub` (planner-fallback / plan
// quality) lives in timeline.jsonl, not the record, so stub-rate is a
// documented v2 follow-up. A golden-jobs RUNNER that fires fixed jobs on a
// schedule (denser, controlled signal) is a later refinement that feeds the
// SAME samples into this same aggregator.

/// One Workshop execution distilled to the fields the scoreboard scores. Dates are
/// pre-parsed so the aggregator core stays PURE and timezone-deterministic
/// (string parsing is confined to the scanner below).
public struct WorkshopOutcomeSample: Sendable, Equatable {
    public var id: String
    /// Stable Workshop identity. New directed-task samples are keyed by their
    /// Desk handle; daemon-era history falls back to the execution id.
    public var deskHandle: String
    public var createdAt: Date
    public var updatedAt: Date
    public var status: String
    public var totalSteps: Int
    public var completedSteps: Int
    public var rerunCount: Int
    /// `trigger_source` of the Workshop execution ("manual" / "trigger:<name>" /
    /// "golden_eval" / …). Lets the scoreboard segment a CONTROLLED cohort
    /// (the golden-eval jobs) from organic user Workshop executions for a clean
    /// week-over-week signal.
    public var triggerSource: String
    /// The planner FAILED for this execution (threw / returned non-JSON / 0 valid
    /// steps) and fell back to a deterministic stub plan — a PLAN-QUALITY signal.
    /// Derived from the `planner_fallback` timeline event (`fromStub` isn't on
    /// WorkshopExecutionRecord). NOTE (gpt-5.5): this is the planner-FAILURE rate, NOT
    /// every stub plan — the autonomy-disabled path also stubs but emits no
    /// `planner_fallback` event, and that's a deliberate disable, not a quality
    /// failure, so excluding it is correct. A rising rate = the planner is
    /// degrading (multi-step jobs quietly collapsing to trivial stubs).
    public var wasStub: Bool

    public init(
        id: String, deskHandle: String? = nil, createdAt: Date, updatedAt: Date, status: String,
        totalSteps: Int, completedSteps: Int, rerunCount: Int,
        triggerSource: String = "manual", wasStub: Bool = false
    ) {
        self.id = id
        self.deskHandle = deskHandle ?? id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.totalSteps = totalSteps
        self.completedSteps = completedSteps
        self.rerunCount = rerunCount
        self.triggerSource = triggerSource
        self.wasStub = wasStub
    }

    public var isTerminal: Bool { WorkshopOutcomeScoreboard.terminalStatuses.contains(status.lowercased()) }
    public var isCompleted: Bool { WorkshopOutcomeScoreboard.completedStatuses.contains(status.lowercased()) }

    /// Wall time from creation to the LAST mission.json write (createdAt →
    /// updatedAt). For the common case (an execution not edited after it finishes)
    /// the last write IS the terminal transition, so this ≈ end-to-end
    /// execution time. CAVEAT (gpt-5.5 review): `updateWorkshopExecution` bumps
    /// `updatedAt` on ANY later patch with no terminal-status guard, so a
    /// execution edited post-terminal would overstate this — it's an UPPER BOUND
    /// on execution time, a useful trend signal, not an exact duration. Exact
    /// terminal duration needs a dedicated terminal timestamp / timeline parse
    /// (v2). Clamped at 0 (a clock skew / out-of-order write can't go negative).
    public var wallSeconds: Double { max(0, updatedAt.timeIntervalSince(createdAt)) }
}

/// Aggregated outcome stats for one ISO week (Monday 00:00 UTC start).
public struct WeeklyOutcomeStats: Sendable, Equatable {
    public var weekStart: Date
    public var total: Int          // all Workshop executions created that week (any status)
    public var terminal: Int       // reached a terminal status
    public var completed: Int
    public var failed: Int
    public var cancelled: Int
    /// completed / terminal (0 when no terminal Workshop executions that week). Excludes
    /// still-running/queued from the denominator so the rate isn't dragged
    /// down by jobs that simply haven't finished yet.
    public var completionRate: Double
    public var medianTotalSteps: Double
    public var medianCompletedSteps: Double
    /// Median wall time (createdAt → last write) over TERMINAL Workshop executions only.
    /// An UPPER BOUND on execution time — see `WorkshopOutcomeSample.wallSeconds`
    /// for the post-terminal-edit caveat. Trend signal, not exact duration.
    public var medianWallSeconds: Double
    public var medianRerunCount: Double
    /// Fraction of the week's Workshop executions whose planner FAILED and fell back to a
    /// stub plan (the `planner_fallback` rate) — a PLAN-QUALITY signal: rising =
    /// the planner is degrading. NOT every stub (excludes the autonomy-disabled
    /// path, which is a deliberate disable, not a failure). 0 when total == 0.
    public var stubRate: Double

    public init(
        weekStart: Date, total: Int, terminal: Int, completed: Int, failed: Int,
        cancelled: Int, completionRate: Double, medianTotalSteps: Double,
        medianCompletedSteps: Double, medianWallSeconds: Double, medianRerunCount: Double,
        stubRate: Double = 0
    ) {
        self.weekStart = weekStart
        self.total = total
        self.terminal = terminal
        self.completed = completed
        self.failed = failed
        self.cancelled = cancelled
        self.completionRate = completionRate
        self.medianTotalSteps = medianTotalSteps
        self.medianCompletedSteps = medianCompletedSteps
        self.medianWallSeconds = medianWallSeconds
        self.medianRerunCount = medianRerunCount
        self.stubRate = stubRate
    }
}

public enum WorkshopOutcomeScoreboard {
    // Status sets mirror the runner's terminal set (WorkshopExecution.swift ~L1379).
    public static let completedStatuses: Set<String> = ["completed", "done", "succeeded"]
    public static let failedStatuses: Set<String> = ["failed"]
    public static let cancelledStatuses: Set<String> = ["cancelled", "canceled"]
    public static let terminalStatuses: Set<String> =
        completedStatuses.union(failedStatuses).union(cancelledStatuses)

    /// UTC ISO-8601 calendar — deterministic week bucketing regardless of host
    /// timezone (the host TZ must NOT shift which week a Workshop execution lands in).
    static var isoCalendar: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Start of the ISO week (Monday 00:00 UTC) containing `date`.
    public static func weekStart(of date: Date) -> Date {
        let cal = isoCalendar
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? date
    }

    /// Median of a list of values; 0 for an empty list. Even count → mean of
    /// the two middle values.
    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// PURE aggregator core: samples → weekly stats, ascending by weekStart.
    /// THE scoreboard number. Deterministic, no I/O, no clock reads — fully
    /// unit-testable.
    /// `onlyTriggerSource` (when non-nil) restricts the aggregate to Workshop executions
    /// whose `triggerSource` matches — e.g. "golden_eval" for the CONTROLLED
    /// golden-jobs cohort, isolating its trend from organic user Workshop executions.
    public static func weekly(
        from samples: [WorkshopOutcomeSample], onlyTriggerSource: String? = nil
    ) -> [WeeklyOutcomeStats] {
        let scoped = onlyTriggerSource.map { src in
            samples.filter { $0.triggerSource == src }
        } ?? samples
        guard !scoped.isEmpty else { return [] }
        var buckets: [Date: [WorkshopOutcomeSample]] = [:]
        for s in scoped {
            buckets[weekStart(of: s.createdAt), default: []].append(s)
        }
        return buckets.keys.sorted().map { wk in
            let group = buckets[wk]!
            let terminal = group.filter { $0.isTerminal }
            let completed = group.filter { $0.isCompleted }.count
            let failed = group.filter { failedStatuses.contains($0.status.lowercased()) }.count
            let cancelled = group.filter { cancelledStatuses.contains($0.status.lowercased()) }.count
            let completionRate = terminal.isEmpty ? 0 : Double(completed) / Double(terminal.count)
            let stubs = group.filter { $0.wasStub }.count
            let stubRate = group.isEmpty ? 0 : Double(stubs) / Double(group.count)
            return WeeklyOutcomeStats(
                weekStart: wk,
                total: group.count,
                terminal: terminal.count,
                completed: completed,
                failed: failed,
                cancelled: cancelled,
                completionRate: completionRate,
                medianTotalSteps: median(group.map { Double($0.totalSteps) }),
                medianCompletedSteps: median(group.map { Double($0.completedSteps) }),
                medianWallSeconds: median(terminal.map { $0.wallSeconds }),
                medianRerunCount: median(group.map { Double($0.rerunCount) }),
                stubRate: stubRate
            )
        }
    }

    /// Parse an execution ISO timestamp. Swift-written records use
    /// `[.withInternetDateTime, .withFractionalSeconds]` with a `+00:00`
    /// offset (WorkshopExecution.isoTimestamp). But DAEMON-ERA records on disk carry
    /// MICROSECOND fractions (`2026-05-07T10:12:54.380610+00:00`), and
    /// `ISO8601DateFormatter.withFractionalSeconds` only accepts 3-digit
    /// fractions — so those fail the first two attempts and, without the
    /// microsecond fallback below, would be silently dropped by the scanner's
    /// compactMap (the scoreboard would then ignore most of the real history —
    /// gpt-5.5 review caught this; 19/21 live queue records are microsecond).
    /// Truncate an over-long fraction to milliseconds and retry. Mirrors
    /// DreamCycleRunner.parseDaemonISO; kept local to avoid a DreamREMCycle
    /// module dependency from WorkshopExecution.
    static func parseTimestamp(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: trimmed) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: trimmed) { return d }
        if let ms = truncateFractionToMillis(trimmed) {
            if let d = frac.date(from: ms) { return d }
            if let d = plain.date(from: ms) { return d }
        }
        return nil
    }

    /// Shorten a fractional-seconds component longer than 3 digits to exactly
    /// 3, preserving the timezone suffix (`.380610+00:00` → `.380+00:00`).
    /// Returns nil when there is no over-long fraction to shorten (the caller
    /// already tried the raw string).
    static func truncateFractionToMillis(_ s: String) -> String? {
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let firstFrac = s.index(after: dot)
        var i = firstFrac
        var digits = 0
        while i < s.endIndex, s[i].isNumber {
            digits += 1
            i = s.index(after: i)
        }
        guard digits > 3 else { return nil }
        let keepEnd = s.index(firstFrac, offsetBy: 3)  // head + ".###"
        return String(s[..<keepEnd]) + String(s[i...]) // ...### + tz suffix
    }

    /// Build a sample from a persisted record, or nil if its createdAt is
    /// unparseable (a record with no usable creation time can't be bucketed).
    public static func sample(from record: WorkshopExecutionRecord) -> WorkshopOutcomeSample? {
        guard let created = parseTimestamp(record.createdAt) else { return nil }
        let updated = parseTimestamp(record.updatedAt) ?? created
        return WorkshopOutcomeSample(
            id: record.id,
            deskHandle: record.deskHandle,
            createdAt: created,
            updatedAt: updated,
            status: record.status,
            totalSteps: record.plan.count,
            completedSteps: record.stepsCompleted.count,
            rerunCount: record.rerunCount,
            triggerSource: record.triggerSource
        )
    }

    /// Build the same aggregate sample from the canonical Workshop receipt
    /// feed. Directed-task terminal outcomes use this path; the legacy record
    /// scanner remains only as migration fallback and for live/non-terminal work.
    public static func sample(from receipt: WorkshopDirectedTaskReceipt) -> WorkshopOutcomeSample? {
        guard let created = parseTimestamp(receipt.createdAt) else { return nil }
        let completed = parseTimestamp(receipt.completedAt) ?? created
        return WorkshopOutcomeSample(
            id: receipt.executionId,
            deskHandle: receipt.handle,
            createdAt: created,
            updatedAt: completed,
            status: receipt.status,
            totalSteps: receipt.totalSteps,
            completedSteps: receipt.completedSteps,
            rerunCount: receipt.rerunCount,
            triggerSource: receipt.triggerSource,
            wasStub: receipt.wasStub
        )
    }
}

/// Fixed, READ-ONLY "golden" executions — the CONTROLLED cohort for MEASURE v2
/// (north-star). Organic single-user execution volume is too sparse for a stable
/// week-over-week trend; submitting the SAME jobs on a cadence gives the
/// scoreboard comparable data points. They exercise the real plan→step path
/// (planner + recall + synthesis) with innocuous, side-effect-free objectives,
/// and are tagged `triggerSource` so `weeklyOutcomeStats(onlyTriggerSource:)`
/// can isolate their trend. Submitted ONLY when the golden-eval loop is
/// explicitly enabled (it costs planner/step tokens — off by default).
public enum GoldenEvalJobs {
    public static let triggerSource = "golden_eval"

    public static let jobs: [WorkshopExecutionSpec] = [
        WorkshopExecutionSpec(
            title: "Golden eval: self-summary",
            objective: "Summarize what you currently know about the user in 3 concise "
                + "bullet points. This is a read-only self-check — do not modify, send, "
                + "or create anything.",
            triggerSource: triggerSource,
            trustRequired: "none"
        ),
        WorkshopExecutionSpec(
            title: "Golden eval: proactive ideas",
            objective: "Propose 3 things you could proactively help the user with today "
                + "based on recent context. Read-only — list the ideas, do not take any "
                + "action on them.",
            triggerSource: triggerSource,
            trustRequired: "none"
        ),
    ]
}

extension WorkshopOutcomeScoreboard {
    /// Compact, LLM-readable rendering of the recent weeks for the weekly
    /// self-improvement pass — so the improvement brain reasons over the REAL
    /// outcome trend ("is she completing more jobs, in fewer steps?"), not just
    /// chat/error/doctor proxies. Returns "" when there's no history (the
    /// caller then omits the signal entirely). Shows the last `maxWeeks` weeks
    /// plus a week-over-week completion-rate trend headline.
    public static func formatForPrompt(_ weeks: [WeeklyOutcomeStats], maxWeeks: Int = 8) -> String {
        // Clamp maxWeeks >= 0 — `Array.suffix` traps on a negative length, and a
        // 0 window has nothing to show (gpt-5.5 LOW). Empty either way → "".
        let window = max(0, maxWeeks)
        guard !weeks.isEmpty, window > 0 else { return "" }
        let recent = Array(weeks.suffix(window))
        let df = DateFormatter()
        df.calendar = isoCalendar
        df.timeZone = TimeZone(identifier: "UTC")!
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"

        let lines = recent.map { w -> String in
            let rate = Int((w.completionRate * 100).rounded())
            let wall = w.medianWallSeconds >= 60
                ? "\(Int((w.medianWallSeconds / 60).rounded()))m"
                : "\(Int(w.medianWallSeconds.rounded()))s"
            return "- week of \(df.string(from: w.weekStart)): "
                + "\(w.total) job(s), \(w.completed)/\(w.terminal) completed (\(rate)%), "
                + "median \(Int(w.medianTotalSteps.rounded())) steps, ~\(wall) wall, "
                + "\(String(format: "%.1f", w.medianRerunCount)) reruns, "
                + "\(Int((w.stubRate * 100).rounded()))% planner-fallback"
        }

        var trend = ""
        if recent.count >= 2 {
            let delta = (recent[recent.count - 1].completionRate
                - recent[recent.count - 2].completionRate) * 100
            let dir = delta > 0.5 ? "UP" : (delta < -0.5 ? "DOWN" : "flat")
            trend = "\nTrend: completion rate \(dir) "
                + "\(String(format: "%+.0f", delta)) pts week-over-week."
        }

        return """
        ## Workshop outcomes (week-over-week - is the assistant completing real multi-step jobs better?)
        \(lines.joined(separator: "\n"))\(trend)
        """
    }
}

extension SwiftNativeWorkshopRunner {
    /// Weekly outcome aggregate over the handle-keyed Workshop receipt feed.
    /// During staged migration, live tasks and daemon-era history without a
    /// directed-task receipt fall back to the compatibility execution records.
    /// `onlyTriggerSource` (e.g. "golden_eval") restricts to one cohort.
    public func weeklyOutcomeStats(
        onlyTriggerSource: String? = nil
    ) async -> [WeeklyOutcomeStats] {
        let persistence = SwiftNativePersistenceCore()
        let receiptPath = executionRecordsRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
        let directedReceipts = ((try? await persistence.readJSONL(receiptPath)) ?? [])
            .compactMap(WorkshopDirectedTaskReceipt.fromJSON)
        var receiptByExecution: [String: WorkshopDirectedTaskReceipt] = [:]
        for receipt in directedReceipts {
            receiptByExecution[receipt.executionId] = receipt
        }

        var samples: [WorkshopOutcomeSample] = []
        for record in await listAll() {
            if let receipt = receiptByExecution[record.id],
               let sample = WorkshopOutcomeScoreboard.sample(from: receipt) {
                samples.append(sample)
                continue
            }
            guard var sample = WorkshopOutcomeScoreboard.sample(from: record) else { continue }
            // `fromStub` isn't on WorkshopExecutionRecord, so migration-fallback samples
            // still derive plan quality from their compatibility timeline.
            let rows = (try? await persistence.readJSONL(timelinePath(record.id))) ?? []
            sample.wasStub = rows.contains { row in
                if case .object(let o) = row, case .string("planner_fallback")? = o["event"] { return true }
                return false
            }
            samples.append(sample)
        }
        return WorkshopOutcomeScoreboard.weekly(from: samples, onlyTriggerSource: onlyTriggerSource)
    }
}
