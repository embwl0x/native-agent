import Foundation
import BackgroundLoops
import NativeAgentCore
import PersistenceCore
import TriggerScheduler
import WorkshopExecution
import StandingBots
import ProviderRouting
import ChatOrchestration

// Trigger and scheduler-job physiology.
//
// User schedules remain canonical in scheduler/jobs.json and the two trigger
// config stores. BackgroundLoopsManager owns their one lifecycle, single-flight
// execution, status, startup reconciliation, event coalescing, and deadline
// task. This wrapper owns no Task and no timer of its own.

extension BackgroundLoopsAssembly {
    static func makeTriggerSchedulerLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some LoopRunner {
        let standardized = dataRoot.standardizedFileURL
        let isLiveRoot = standardized
            == PersistenceCore.defaultDataRoot().standardizedFileURL
        let workshopRunner: (any WorkshopRunnerClient)? = isLiveRoot
            ? makeWorkshopRunner(lifecycleObserver: NativeCognitionRuntime.shared)
            : nil
        let notifier: TriggerNotifier? = isLiveRoot
            ? TriggerNotifierBinding.pairedDevicePush
            : nil
        let native = SwiftNativeTriggerScheduler(
            root: standardized,
            workshopRunner: workshopRunner,
            notifier: notifier,
            worklogPath: isLiveRoot
                ? nil
                : standardized.appendingPathComponent("no-such-worklog.jsonl"),
            // L5 G3: the time trigger fires the blueprint turn. Live root only —
            // a secondary/test root must never borrow the provider, the tools,
            // or the cost. nil there means the deterministic counts brief,
            // exactly as before.
            morningBriefSynthesizer: isLiveRoot ? makeMorningBriefSynthesizer() : nil
        )
        let mirror: @Sendable (TriggerFireResult) async -> Bool
        if isLiveRoot {
            mirror = { result in
                await TriggerNotifierBinding.mirrorNonNotifiedFire(result)
            }
        } else {
            mirror = { _ in true }
        }
        let dueJobRunner = SchedulerDueJobRunner(root: standardized)
        let botProvider = SwiftNativeLLMClient(
            router: SwiftNativeProviderRouting(dataRoot: standardized), codex: CodexAdapter(),
            anthropic: AnthropicAdapter(), openAI: OpenAIAdapter(),
            openAIOAuthDirect: OpenAIOAuthDirectAdapter(),
            anthropicOAuthDirect: AnthropicOAuthDirectAdapter(),
            lifecycleObserver: NativeCognitionRuntime.shared
        )
        let bots = BotRunnerScheduler(dataRoot: standardized, session: { system, prompt, limit in
            try await botProvider.completeStandingBot(system: system, prompt: prompt, maxOutputTokens: limit,
                preRequestAdmission: {
                    guard await StandingBotToolLoop.admitted(dataRoot: standardized) else { throw BotRunnerError.notPermitted }
                })
        }, admission: {
            await StandingBotToolLoop.admitted(dataRoot: standardized)
        }, toolSession: StandingBotToolLoop.session(dataRoot: standardized,
            tools: makeNativeAgentAppToolDispatchClient(denyExternalMcp: true, dataRoot: standardized),
            lifecycleObserver: NativeCognitionRuntime.shared),
            compact: StandingBotContinuity.compact)
        let runDueJobs: @Sendable () async -> [String]
        let schedulerActivityFailure: @Sendable () async -> String?
        let nextJobDeadline: @Sendable (Date) async -> Date?
        if isLiveRoot {
            runDueJobs = {
                let jobs = await dueJobRunner.runDueJobs(maxJobs: 5)
                return jobs + (await bots.runDue())
            }
            schedulerActivityFailure = {
                let jobs = await dueJobRunner.activityFeedError
                let botFailure = await bots.failure
                return jobs ?? botFailure
            }
            nextJobDeadline = { date in
                let jobs = await dueJobRunner.nextMeaningfulDeadline(after: date)
                let botDeadline = await bots.nextDeadline(after: date)
                return [jobs, botDeadline].compactMap { $0 }.min()
            }
        } else {
            // Scheduler jobs can dispatch process-global notification,
            // connector, provider, and sync owners. Secondary/test roots may
            // inspect their own files but never borrow those live effects.
            runDueJobs = { [] }
            schedulerActivityFailure = { nil }
            nextJobDeadline = { _ in nil }
        }
        return TriggerSchedulerEventDeadlineRunner(
            dataRoot: standardized,
            schedulerJobsPath: dueJobRunner.jobsPath,
            triggerScheduler: native,
            runDueJobs: runDueJobs,
            schedulerActivityFailure: schedulerActivityFailure,
            nextSchedulerJobDeadline: nextJobDeadline,
            mirrorFire: mirror
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
    static let morningBriefObjective = "Prepare today's concise briefing from canonical calendar, inbox, project, and Desk state. Cite the evidence used, identify unknowns, and surface the completed report in NativeAgent without sending externally unless separately approved."
    static let morningBriefTools = ["mac_calendar_list_upcoming", "mail_list_recent", "workshop_status"]

    /// Hard ceiling on the synthesis turn. The scheduler tick that awaits this
    /// has a 1800s timeout of its own; a brief is not worth holding it for
    /// minutes. On expiry the turn is cancelled and the brief degrades to the
    /// deterministic text.
    static let morningBriefSynthesisTimeout: TimeInterval = 120

    static func makeMorningBriefSynthesizer(
        runTurn: @escaping @Sendable (String) async throws -> String = { prompt in
            let client = makeNativeAgentAppChatOrchestrationClient(profile: .background)
            let response = try await client.runEphemeralToolTurn(
                message: prompt,
                fileAccess: "read_only",
                surface: WorkshopSurfaceVocabulary.canonical
            )
            return response.output
        },
        deadlineSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        },
        failureMarker: @escaping @Sendable (String) -> Void = { marker in
            NSLog("%@", marker)
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
    static func morningBriefSynthesisPrompt(
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

struct TriggerSchedulerEventDeadlineRunner: EventDeadlineLoopRunner {
    let loopId = "trigger_scheduler_due_work"
    /// Missed-event integrity only. Normal work wakes from canonical file
    /// invalidations or an exact persisted due instant.
    let interval: TimeInterval = 6 * 60 * 60
    var tickTimeoutOverride: TimeInterval? { 1800 }
    var eventCoalescingDelay: TimeInterval { 0.5 }

    let dataRoot: URL
    let schedulerJobsPath: URL
    let triggerScheduler: SwiftNativeTriggerScheduler
    let runDueJobs: @Sendable () async -> [String]
    /// Read immediately after `runDueJobs`. A durable scheduler effect without
    /// its activity evidence is deliberately a failed loop receipt, not a
    /// quiet "nothing due" tick that lets later trigger effects proceed.
    let schedulerActivityFailure: @Sendable () async -> String?
    let nextSchedulerJobDeadline: @Sendable (Date) async -> Date?
    let mirrorFire: @Sendable (TriggerFireResult) async -> Bool

    init(
        dataRoot: URL,
        schedulerJobsPath: URL,
        triggerScheduler: SwiftNativeTriggerScheduler,
        runDueJobs: @escaping @Sendable () async -> [String],
        schedulerActivityFailure: @escaping @Sendable () async -> String? = { nil },
        nextSchedulerJobDeadline: @escaping @Sendable (Date) async -> Date?,
        mirrorFire: @escaping @Sendable (TriggerFireResult) async -> Bool
    ) {
        self.dataRoot = dataRoot
        self.schedulerJobsPath = schedulerJobsPath
        self.triggerScheduler = triggerScheduler
        self.runDueJobs = runDueJobs
        self.schedulerActivityFailure = schedulerActivityFailure
        self.nextSchedulerJobDeadline = nextSchedulerJobDeadline
        self.mirrorFire = mirrorFire
    }

    func physiologyEvents() -> AsyncStream<Void> {
        EventDeadlinePhysiology.storeAndFileEvents(paths: [
            schedulerJobsPath,
            dataRoot.appendingPathComponent("bots/definitions"),
            dataRoot.appendingPathComponent("bots/runner-jobs.json"),
            dataRoot.appendingPathComponent("bots/run-queue.json"),
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
        ], notifications: [
            BotRunQueue.didChange,
            // 2026-09-06: every deadline this runner reports is an ABSOLUTE
            // instant derived from local time — a cron-shaped job's "09:00", an
            // idle crossing. A clock correction or a time-zone move changes
            // what those instants ARE, and no watched file records it, so the
            // armed deadline went on pointing at the old wall time until the
            // six-hour integrity tick recomputed it.
            .NSSystemClockDidChange,
            .NSSystemTimeZoneDidChange,
        ], loopId: loopId)
    }

    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        let schedulerJob = await nextSchedulerJobDeadline(now)
        let trigger = await triggerScheduler.nextMeaningfulDeadline(after: now)
        return [schedulerJob, trigger].compactMap { $0 }.min()
    }

    func tick() async {
        _ = await tickOutcome()
    }

    func tickOutcome() async -> LoopTickOutcome {
        let dueJobs = await runDueJobs()
        guard !Task.isCancelled else { return .skipped(reason: "cancelled") }
        if let activityFailure = await schedulerActivityFailure() {
            return .failed(error: activityFailure)
        }

        let fires = await triggerScheduler.evaluateAndFireDetailed()
        for fire in fires {
            guard !Task.isCancelled else { return .skipped(reason: "cancelled") }
            _ = await mirrorFire(fire)
        }

        let active = (fires.compactMap(\.name) + dueJobs).sorted()
        guard !active.isEmpty else { return .skipped(reason: "nothing due") }
        return .completed(result: "settled \(active.count) due item(s)")
    }
}
