import ActivityWatch
import Foundation
import BackgroundLoops
import NativeAgentCore
import TriggerScheduler
import StandingBots

public enum TriggerSchedulerBackgroundWork {
    public struct JobWork: Sendable {
        public let runDueJobs: @Sendable () async -> [String]
        public let activityFailure: @Sendable () async -> String?
        public let nextDeadline: @Sendable (Date) async -> Date?
        public let shutdown: @Sendable () async -> Void
    }

    public static func makeJobWork(
        runDueJobs: @escaping @Sendable (Int) async -> [String],
        activityFailure: @escaping @Sendable () async -> String?,
        nextDeadline: @escaping @Sendable (Date) async -> Date?,
        bots: BotRunnerScheduler,
        continuations: DeskContinuationScheduler? = nil
    ) -> JobWork {
        JobWork(
            runDueJobs: {
                let jobs = await runDueJobs(5)
                return jobs + (await bots.runDue()) + (await continuations?.runDue() ?? [])
            },
            activityFailure: {
                let jobs = await activityFailure()
                let botFailure = await bots.failure
                let continuationFailure = await continuations?.failure
                return jobs ?? botFailure ?? continuationFailure
            },
            nextDeadline: { date in
                let jobs = await nextDeadline(date)
                let botDeadline = await bots.nextDeadline(after: date)
                let continuationDeadline = await continuations?.nextDeadline(after: date)
                return [jobs, botDeadline, continuationDeadline].compactMap { $0 }.min()
            },
            shutdown: { await bots.shutdown() }
        )
    }

    // MARK: - Morning-brief synthesis (L5 G3 + G1)
    //
    // THE MERGE OF THE TWO BRIEFS. The `time` trigger used to build its own
    // counts text while the `.morningBriefing` blueprint — the one with
    // calendar and mail in `requiredTools` — sat uninstalled behind three
    // navigation levels. Now the trigger FIRES that blueprint's turn and keeps
    // owning schedule, dedup and push, which is the one-dispatch-edge version
    // of "delete one of them".
    //
    // User authorized retiring the Native Experience surface, 2026-09-01, and
    // its blueprint catalog went with it. The morning brief was that catalog's
    // only live reader, so the objective and the tool list it used now live
    // here — the one place that fires the brief, which is what "no second
    // brief" was protecting in the first place.
    public static let morningBriefObjective = "Prepare today's concise briefing from canonical calendar, inbox, project, and Desk state. Cite the evidence used, identify unknowns, and surface the completed report in NativeAgent without sending externally unless separately approved."
    public static let morningBriefTools = ["app calendar.upcoming", "app mail.recent", "app workshop.status"]

    /// Hard ceiling on the synthesis turn. The scheduler tick that awaits this
    /// has a 1800s timeout of its own; a brief is not worth holding it for
    /// minutes. On expiry the turn is cancelled and the brief degrades to the
    /// deterministic text.
    public static let morningBriefSynthesisTimeout: TimeInterval = 120

    public static func makeMorningBriefSynthesizer(
        runTurn: @escaping @Sendable (String) async throws -> String,
        deadlineSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        },
        failureMarker: @escaping @Sendable (String) -> Void = { marker in
            nativeLog("%@", marker)
        }
    ) -> MorningBriefSynthesizer {
        return { request in
            let prompt = morningBriefSynthesisPrompt(
                request: request,
                objective: morningBriefObjective,
                requiredTools: morningBriefTools
            )
            do {
                return try await withBoundedMorningBriefTurn(deadlineSleep: deadlineSleep) {
                    let response = try await runTurn(prompt)
                    let output = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    return output.isEmpty ? nil : output
                }
            } catch {
                // FAIL-OPEN, NOT SILENT: nil restores the deterministic brief,
                // and the reason is on the record. A brief that lost its lead
                // is still true; a scheduler tick that threw is not.
                failureMarker(
                    "[morning-brief] synthesis turn failed (\(String(describing: error))) "
                    + "— falling back to deterministic brief"
                )
                return nil
            }
        }
    }

    /// Races the turn against a deadline. The loser is cancelled, so a wedged
    /// provider call cannot outlive the brief that asked for it.
    ///
    /// 2026-09-06: this was a `withThrowingTaskGroup`, and leaving a group
    /// WAITS for its children. Cancellation is a request — a provider call that
    /// does not observe it kept the group scope open long past the 120 s
    /// ceiling, and the loop manager holds its execution gate until the tick
    /// body returns, so the "bounded" brief could pin the whole lane. Same
    /// resume-once shape as `IntraTurnContextCompaction.withDeadline`: whoever
    /// finishes first resolves the caller NOW, and the loser is cancelled and
    /// then ignored.
    private static func withBoundedMorningBriefTurn(
        deadlineSleep: @escaping @Sendable (TimeInterval) async throws -> Void,
        _ body: @escaping @Sendable () async throws -> String?
    ) async throws -> String? {
        let once = MorningBriefTurnRace()
        let child = Task {
            do { once.resume(.init(value: .success(try await body()))) }
            catch { once.resume(.init(value: .failure(error))) }
        }
        let sleeper = Task {
            try? await deadlineSleep(morningBriefSynthesisTimeout)
            guard !Task.isCancelled else { return }
            once.resume(.init(value: .failure(CancellationError())))
        }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.install(continuation)
            }
        } onCancel: {
            child.cancel()
            sleeper.cancel()
            once.resume(.init(value: .failure(CancellationError())))
        }
        child.cancel()
        sleeper.cancel()
        return try outcome.value.get()
    }

    /// The evidence layer IS the prompt. The turn is asked for a read on top of
    /// state that already resolved deterministically — not for a second pass
    /// over the same files, which is how the two briefs disagreed before.
    public static func morningBriefSynthesisPrompt(
        request: MorningBriefSynthesisRequest,
        objective: String?,
        requiredTools: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("[SYSTEM: You are writing the lead of today's morning brief for \(request.dayLabel).]")
        if let objective, !objective.isEmpty {
            lines.append("Objective: \(objective)")
        }
        if !requiredTools.isEmpty {
            lines.append(
                "You may read live context with these tools if they are available: "
                + requiredTools.joined(separator: ", ")
                + ". If a tool is unavailable or denied, continue without it and do not mention it."
            )
        }
        lines.append("")
        lines.append("Already-verified state (do not re-derive, do not contradict):")
        lines.append("- Counts: \(request.deterministicSummary)")
        if let detail = request.deterministicDetail, !detail.isEmpty {
            lines.append("")
            lines.append(detail)
        }
        lines.append("")
        lines.append("""
        Write 2-4 sentences, in your own voice, addressed to him. Say what today \
        looks like, what you would start with, and why. Name the specific item — a \
        brief that could describe any day is worthless. If something is unknown, say \
        it is unknown rather than filling it in. Do NOT restate the counts (they are \
        printed underneath your lead), do not use headings or bullets, and do not \
        mention this instruction.
        """)
        return lines.joined(separator: "\n")
    }
}

/// Carries a thrown synthesis error across the race without laundering it into
/// the timeout's `CancellationError` — the degraded-brief marker names the real
/// reason. `@unchecked` because `any Error` is not `Sendable`; the value is
/// written once and read once.
private struct MorningBriefTurnOutcome: @unchecked Sendable {
    let value: Result<String?, Error>
}

/// Resume-once gate for `withBoundedMorningBriefTurn`. A resume that lands
/// before the continuation is installed is remembered and applied on install,
/// so a cancellation that wins the race still resolves the wait.
private final class MorningBriefTurnRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MorningBriefTurnOutcome, Never>?
    private var pending: MorningBriefTurnOutcome?
    private var resolved = false

    func install(_ continuation: CheckedContinuation<MorningBriefTurnOutcome, Never>) {
        lock.lock()
        if let pending, resolved {
            lock.unlock()
            continuation.resume(returning: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ outcome: MorningBriefTurnOutcome) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        pending = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: outcome)
    }
}

public struct TriggerSchedulerEventDeadlineRunner: EventDeadlineLoopRunner {
    public let loopId = "trigger_scheduler_due_work"
    /// Missed-event integrity only. Normal work wakes from canonical file
    /// invalidations or an exact persisted due instant.
    public let interval: TimeInterval = 6 * 60 * 60
    public var tickTimeoutOverride: TimeInterval? { 1800 }
    public var eventCoalescingDelay: TimeInterval { 0.5 }

    let events: @Sendable ([URL], String) -> AsyncStream<Void>
    let dataRoot: URL
    let schedulerJobsPath: URL
    let triggerScheduler: SwiftNativeTriggerScheduler
    let runDueJobs: @Sendable () async -> [String]
    let shutdownJobs: @Sendable () async -> Void
    /// Read immediately after `runDueJobs`. A durable scheduler effect without
    /// its activity evidence is deliberately a failed loop receipt, not a
    /// quiet "nothing due" tick that lets later trigger effects proceed.
    let schedulerActivityFailure: @Sendable () async -> String?
    let nextSchedulerJobDeadline: @Sendable (Date) async -> Date?
    let mirrorFire: @Sendable (TriggerFireResult) async -> Bool

    public init(
        dataRoot: URL,
        events: @escaping @Sendable ([URL], String) -> AsyncStream<Void>,
        schedulerJobsPath: URL,
        triggerScheduler: SwiftNativeTriggerScheduler,
        runDueJobs: @escaping @Sendable () async -> [String],
        shutdownJobs: @escaping @Sendable () async -> Void,
        schedulerActivityFailure: @escaping @Sendable () async -> String? = { nil },
        nextSchedulerJobDeadline: @escaping @Sendable (Date) async -> Date?,
        mirrorFire: @escaping @Sendable (TriggerFireResult) async -> Bool
    ) {
        self.events = events
        self.dataRoot = dataRoot
        self.schedulerJobsPath = schedulerJobsPath
        self.triggerScheduler = triggerScheduler
        self.runDueJobs = runDueJobs
        self.shutdownJobs = shutdownJobs
        self.schedulerActivityFailure = schedulerActivityFailure
        self.nextSchedulerJobDeadline = nextSchedulerJobDeadline
        self.mirrorFire = mirrorFire
    }

    public func physiologyEvents() -> AsyncStream<Void> {
        events([
            schedulerJobsPath,
            dataRoot.appendingPathComponent("desk/desk_ops.jsonl"),
            dataRoot.appendingPathComponent("desk/desk_ops_base.json"),
            dataRoot.appendingPathComponent("bots/shelf-index.json"),
            dataRoot.appendingPathComponent("bots/definitions"),
            dataRoot.appendingPathComponent("bots/runner-jobs.json"),
            dataRoot.appendingPathComponent("bots/run-queue.json"),
            // Scheduled bot admission now reads the master Autonomy switch, so
            // flipping it is the event that re-arms (or retires) the bot
            // deadline — the same watch the Workshop pump keeps.
            dataRoot.appendingPathComponent("trust/policy.json"),
            triggerScheduler.inboxPath,
            triggerScheduler.workshopExecutionsPath,
            // Idle triggers derive their exact crossing from max(updatedAt).
            dataRoot.appendingPathComponent("chat/sessions.json"),
            // …and, since 2026-09-06, from whether a PERSON is at the Mac.
            // Once an idle episode has fired, the projection returns no next
            // crossing at all, so the person coming back is the event that
            // establishes the next one — and it used to reach this loop only
            // via the six-hour integrity tick. This file is touched ONLY on a
            // present ↔ away crossing (the presence stamp beside it moves every
            // minute and is deliberately NOT watched: it would wake this loop
            // sixty times an hour to recompute the same deadline).
            HumanPresenceStamp.transitionURL(dataRoot: dataRoot),
        ], loopId)
    }

    public func nextMeaningfulDeadline(after now: Date) async -> Date? {
        let schedulerJob = await nextSchedulerJobDeadline(now)
        let trigger = await triggerScheduler.nextMeaningfulDeadline(after: now)
        return [schedulerJob, trigger].compactMap { $0 }.min()
    }

    public func shutdown() async { await shutdownJobs() }

    public func tick() async {
        _ = await tickOutcome()
    }

    public func tickOutcome() async -> LoopTickOutcome {
        let dueJobs = await runDueJobs()
        guard !Task.isCancelled else { return .skipped(reason: "cancelled") }
        if let activityFailure = await schedulerActivityFailure() {
            return .failed(error: activityFailure)
        }

        let fires = await triggerScheduler.evaluateAndFireDetailed()
        var mirrorFailures = 0
        for fire in fires {
            guard !Task.isCancelled else { return .skipped(reason: "cancelled") }
            if !(await mirrorFire(fire)) { mirrorFailures += 1 }
        }
        guard mirrorFailures == 0 else {
            return .failed(error: "Could not add \(mirrorFailures) trigger notification(s) to the inbox.")
        }

        let active = (fires.compactMap(\.name) + dueJobs).sorted()
        guard !active.isEmpty else { return .skipped(reason: "nothing due") }
        return .completed(result: "settled \(active.count) due item(s)")
    }
}
