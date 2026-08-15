import Foundation
import BackgroundLoops
import NativeAgentCore
import PersistenceCore
import TriggerScheduler
import WorkshopExecution

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
        let runDueJobs: @Sendable () async -> [String]
        let nextJobDeadline: @Sendable (Date) async -> Date?
        if isLiveRoot {
            runDueJobs = { await dueJobRunner.runDueJobs(maxJobs: 5) }
            nextJobDeadline = { date in
                await dueJobRunner.nextMeaningfulDeadline(after: date)
            }
        } else {
            // Scheduler jobs can dispatch process-global notification,
            // connector, provider, and sync owners. Secondary/test roots may
            // inspect their own files but never borrow those live effects.
            runDueJobs = { [] }
            nextJobDeadline = { _ in nil }
        }
        return TriggerSchedulerEventDeadlineRunner(
            dataRoot: standardized,
            schedulerJobsPath: dueJobRunner.jobsPath,
            triggerScheduler: native,
            runDueJobs: runDueJobs,
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
    // The blueprint stays the source of truth for objective and tools: both are
    // read out of `NativeExperienceCatalogs` rather than restated here, so the
    // two cannot drift into being two different briefs again.

    /// Hard ceiling on the synthesis turn. The scheduler tick that awaits this
    /// has a 1800s timeout of its own; a brief is not worth holding it for
    /// minutes. On expiry the turn is cancelled and the brief degrades to the
    /// deterministic text.
    static let morningBriefSynthesisTimeout: TimeInterval = 120

    static func makeMorningBriefSynthesizer() -> MorningBriefSynthesizer {
        return { request in
            let blueprint = NativeExperienceCatalogs.blueprints.first { $0.id == .morningBriefing }
            let objective = blueprint?.payload["objective"].flatMap { value -> String? in
                if case .string(let text) = value { return text }
                return nil
            }
            let tools = blueprint?.requiredTools ?? []
            let prompt = morningBriefSynthesisPrompt(
                request: request,
                objective: objective,
                requiredTools: tools
            )
            do {
                return try await withBoundedMorningBriefTurn {
                    let client = makeNativeAgentAppChatOrchestrationClient()
                    let response = try await client.runEphemeralToolTurn(
                        message: prompt,
                        fileAccess: "read_only",
                        surface: WorkshopSurfaceVocabulary.canonical
                    )
                    let output = response.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    return output.isEmpty ? nil : output
                }
            } catch {
                // FAIL-OPEN, NOT SILENT: nil restores the deterministic brief,
                // and the reason is on the record. A brief that lost its lead
                // is still true; a scheduler tick that threw is not.
                NSLog("[morning-brief] synthesis turn failed (%@) — falling back to deterministic brief",
                      String(describing: error))
                return nil
            }
        }
    }

    /// Races the turn against a deadline. The loser is cancelled, so a wedged
    /// provider call cannot outlive the brief that asked for it.
    private static func withBoundedMorningBriefTurn(
        _ body: @escaping @Sendable () async throws -> String?
    ) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(morningBriefSynthesisTimeout * 1_000_000_000))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
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
    let nextSchedulerJobDeadline: @Sendable (Date) async -> Date?
    let mirrorFire: @Sendable (TriggerFireResult) async -> Bool

    init(
        dataRoot: URL,
        schedulerJobsPath: URL,
        triggerScheduler: SwiftNativeTriggerScheduler,
        runDueJobs: @escaping @Sendable () async -> [String],
        nextSchedulerJobDeadline: @escaping @Sendable (Date) async -> Date?,
        mirrorFire: @escaping @Sendable (TriggerFireResult) async -> Bool
    ) {
        self.dataRoot = dataRoot
        self.schedulerJobsPath = schedulerJobsPath
        self.triggerScheduler = triggerScheduler
        self.runDueJobs = runDueJobs
        self.nextSchedulerJobDeadline = nextSchedulerJobDeadline
        self.mirrorFire = mirrorFire
    }

    func physiologyEvents() -> AsyncStream<Void> {
        EventDeadlinePhysiology.storeAndFileEvents(paths: [
            schedulerJobsPath,
            triggerScheduler.inboxPath,
            triggerScheduler.workshopExecutionsPath,
            // Idle triggers derive their exact crossing from max(updatedAt).
            dataRoot.appendingPathComponent("chat/sessions.json"),
        ])
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
