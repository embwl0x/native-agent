import Foundation
import NativeAgentCore
import PersistenceCore

/// Weekly submission of the fixed GOLDEN-EVAL executions (MEASURE leg v2 of the
/// north-star). Submitting the SAME jobs on a cadence gives the outcome
/// scoreboard a CONTROLLED, comparable week-over-week cohort — organic
/// single-user execution volume is too sparse for a stable trend, so the
/// scoreboard's completion-rate signal needs a fixed denominator to move
/// against. The jobs are tagged `GoldenEvalJobs.triggerSource` so the
/// scoreboard can isolate them (`weeklyOutcomeStats(onlyTriggerSource:)`).
///
/// OFF BY DEFAULT (opt-in via `isEnabled`): golden jobs submit REAL executions
/// that EXECUTE — the planner runs and steps dispatch, which costs tokens. A
/// fresh install must NEVER spend tokens on a hidden weekly eval; the user
/// turns it on deliberately (the same gate philosophy as every other
/// autonomous loop). When disabled, `tick()` is a silent no-op.
///
/// Dependency-clean: the actual submission is an injected closure (the assembly
/// wires it to the execution runner + `GoldenEvalJobs.jobs`), so BackgroundLoops
/// gains no Executions dependency — the same pattern as WeeklySelfImprovementLoop's
/// stageProposal / workshopOutcomes closures.
public struct GoldenEvalLoop: LoopRunner {
    public let loopId: String = "golden_eval"
    public let interval: TimeInterval
    /// A golden tick submits Workshop executions whose planner LLM call can run long; the
    /// scheduler's 300s default would cancel a slow submit mid-call.
    public var tickTimeoutOverride: TimeInterval? { 1800 }

    private let dataRoot: URL
    private let clock: @Sendable () -> Date
    /// The on/off switch — OFF by default (the assembly wires it to a
    /// `goldenEvalEnabled` preference). No spend until the user opts in.
    private let isEnabled: @Sendable () async -> Bool
    /// Submits the golden jobs and returns how many were submitted (for the
    /// log). Receives the loop's `now` so the submitter can stamp each execution's
    /// `createdAt` from the SAME instant the week-marker is keyed on — otherwise
    /// a batch straddling Monday 00:00 UTC could mark week N while an execution
    /// record lands in week N+1's scoreboard bucket (gpt-5.5 re-review HIGH).
    /// Injected so this module needs no Executions / WorkshopExecutionSpec dependency.
    private let submitGoldenJobs: @Sendable (Date) async -> Int

    public init(
        interval: TimeInterval = 7 * 24 * 60 * 60,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() },
        isEnabled: @escaping @Sendable () async -> Bool,
        submitGoldenJobs: @escaping @Sendable (Date) async -> Int
    ) {
        self.interval = interval
        self.dataRoot = dataRoot
        self.clock = clock
        self.isEnabled = isEnabled
        self.submitGoldenJobs = submitGoldenJobs
    }

    public func tickOutcome() async -> LoopTickOutcome {
        guard await isEnabled() else {
            return .skipped(reason: "golden eval disabled")
        }
        let now = clock()
        // Weekly idempotency: both the BGTask and the in-app scheduler can drive
        // this loop; without a marker a same-week double-tick double-submits the
        // golden set (wasting planner/step tokens). Check-and-stamp under the
        // cross-process file lock BEFORE submitting; restore the prior stamp on
        // failure so a failed submit retries next tick. (Mirrors
        // WeeklySelfImprovementLoop's once-per-period guard.)
        let marker = dataRoot.appendingPathComponent("golden_eval", isDirectory: true)
            .appendingPathComponent("last_run")
        do {
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failed(error: "golden marker directory: \(error)")
        }
        // Key dedup by ISO WEEK, not a rolling cooldown: the scoreboard buckets
        // by ISO week (Mon 00:00 UTC), so the golden cohort must land exactly
        // ONCE per ISO-week bucket for a clean controlled denominator — a 6-day
        // cooldown could put two batches in one ISO week or split across the
        // boundary (gpt-5.5 review HIGH, 2026-06-15). Store the current
        // ISO-week-start; skip if we already submitted for this week. The
        // check-and-stamp runs under the cross-process lock via the shared
        // once-per-period reservation.
        let weekKey = ISO8601DateFormatter().string(from: Self.isoWeekStart(now))
        let rollback: @Sendable () async -> Void
        switch await reserveOncePerPeriod(key: weekKey, at: marker) {
        case .alreadyReserved:
            return .skipped(reason: "golden cohort already submitted")
        case .failed(let error):
            return .failed(error: "golden marker reservation: \(error)")
        case .reserved(_, let rb):
            rollback = rb
        }

        let submitted = await submitGoldenJobs(now)
        // Restore the marker if NOTHING submitted (infra down) so next tick
        // retries; a partial/full success keeps the stamp (don't re-submit
        // this week's cohort).
        if submitted == 0 { await rollback() }
        FileHandle.standardError.write(Data(
            "GoldenEvalLoop: submitted \(submitted) golden job(s)\n".utf8))
        if submitted == 0 {
            return .failed(error: "golden submission produced no jobs")
        }
        return .completed(result: "submitted \(submitted) golden job(s)")
    }

    /// Start of the ISO week (Monday 00:00 UTC) containing `d`. Mirrors
    /// WorkshopOutcomeScoreboard.weekStart — duplicated locally because
    /// BackgroundLoops must not depend on Workshop (dependency-clean rule); both
    /// MUST stay in sync so a golden batch keys to the same bucket the
    /// scoreboard counts it in.
    static func isoWeekStart(_ d: Date) -> Date {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        let comps = c.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return c.date(from: comps) ?? d
    }
}
