import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `BackgroundLoopsManager.swift` | BackgroundLoopLifetimes registration, execution, status, resident observation and lifecycle settlement |

// EngineRuntime composes registrations; this owner holds their lifecycle,
// execution and status.

public actor BackgroundLoopLifetimes {
    public static let systemBackgroundActivities: [(loopId: String, interval: TimeInterval)] = [
        ("self_improvement_sweep", 7 * 24 * 60 * 60),
    ]
    public static let retiredSystemBackgroundActivities = ["dream_cycle", "rem_cycle"]

    public static let shared = BackgroundLoopLifetimes(
        scheduler: SwiftNativeLoopScheduler(
            failureReceiptsPath: PersistenceCore.defaultDataRoot()
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("background_loop_failures.jsonl")
        )
    )

    internal let scheduler: SwiftNativeLoopScheduler
    internal let clock: @Sendable () -> Date
    internal var started = false
    private var starting = false
    private var stopped = false
    private var startedAt: Date?
    internal var lifecycleGeneration: UInt64 = 0
    // One engine-assembled observation body shares this owner's start/stop.
    // Retain a cancelled predecessor through exit before admitting its successor.
    private var residentObservation: (@Sendable () async -> Void)?
    private var residentObservationTask: Task<Void, Never>?
    private var residentObservationID: UUID?
    private var startTransition = ScopedWaiter()
    private var registrations: [String: LoopRegistration] = [:]
    // Expected configuration survives the live registration's retirement drain.
    private var configuredLoopIntervals: [String: TimeInterval] = [:]
    private var registeredIds: [String] = []
    /// Event/deadline physiology stays owned by the same manager as periodic
    /// integrity sweeps. Per-loop generations make replacement fail closed:
    /// a stale stream/deadline can never execute a newly registered runner.
    internal var physiologyRunners: [String: any EventDeadlineLoopRunner] = [:]
    internal var physiologyGenerations: [String: UUID] = [:]
    /// Retain startup/restart reconciliation independently of listener lifetime;
    /// `start()` remains non-blocking while lifecycle settlement can join it.
    internal var physiologyStartupTasks: [String: Task<Void, Never>] = [:]
    internal var physiologyEventTasks: [String: Task<Void, Never>] = [:]
    internal var physiologyDebounceTasks: [String: Task<Void, Never>] = [:]
    internal var physiologyDebounceTokens: [String: UUID] = [:]
    /// A firing wake transfers its handle here before executing. Arrivals may
    /// replace a pending debounce, but only stop/replacement cancels execution.
    internal var physiologyExecutionTasks: [String: [UUID: Task<Void, Never>]] = [:]
    internal var physiologyPendingEvents: Set<String> = []
    internal var physiologyDeadlineTasks: [String: Task<Void, Never>] = [:]
    internal var physiologyDeadlines: [String: Date] = [:]
    /// Only the latest projection may arm or fire a deadline for this loop.
    internal var physiologyDeadlineTokens: [String: UUID] = [:]
    internal var wallClockObservers: [NSObjectProtocol] = []
    /// Per-loop listener liveness and the pending restart task.
    internal var physiologyListenerHealth: [String: LoopEventListenerHealth] = [:]
    internal var physiologyListenerRestartTasks: [String: Task<Void, Never>] = [:]
    /// Bounded restart backoff for an event listener whose stream ended. The
    /// last entry is the ceiling: a permanently dead source retries every 30s
    /// forever rather than spinning, and its climbing `consecutiveEnds` is what
    /// surfaces the problem in `status()` instead of a respawn loop hiding it.
    internal let eventListenerRestartBackoff: [TimeInterval] = [1, 5, 30]

    public init(
        scheduler: SwiftNativeLoopScheduler = SwiftNativeLoopScheduler(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scheduler = scheduler
        self.clock = clock
    }

    isolated deinit {
        for observer in wallClockObservers { NotificationCenter.default.removeObserver(observer) }
    }

    public func setFailureOutcome(
        _ outcome: (@Sendable (_ loopId: String, _ error: String) async -> Void)?
    ) async {
        await scheduler.setFailureOutcome(outcome)
    }

    public func setFailureRecoveryPush(
        _ push: (@Sendable (_ loopId: String, _ healthyAt: Date) async -> Bool)?
    ) async {
        await scheduler.setFailureRecoveryPush(push)
    }

    /// Lands every organ's `OrganPulse.record` in this scheduler's loop-state
    /// file. The app installs it once, before anything can beat.
    public nonisolated func receiveOrganPulses() {
        let scheduler = scheduler
        OrganPulse.install { pulse in Task { await scheduler.recordPulse(pulse) } }
    }

    public func organPulses() async -> [OrganPulse] {
        await scheduler.organPulses()
    }

    /// Injects the app-assembled manifest and starts its periodic tasks. Once
    /// running, repeated calls are idempotent for existing ids and only add
    /// missing registrations. Runtime reconfiguration must use
    /// `restartLoop(id:newLoop:)` so unrelated loop tasks and counters survive.
    @discardableResult
    public func start(loops: [LoopRegistration] = [],
                      residentObservation: (@Sendable () async -> Void)? = nil) async -> Bool {
        guard !stopped else { return false }
        if starting {
            await startTransition.park()
            guard started, !stopped else { return false }
        }
        if started {
            for loop in loops where registrations[loop.loopId] == nil {
                await register(loop)
            }
            await scheduler.start()
            return false
        }
        if let residentObservation { self.residentObservation = residentObservation }
        starting = true
        startTransition = ScopedWaiter()
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        // Stop retains registrations, including gates held by cancelled work
        // that has not exited yet. Reusing the manifest must retain those gates.
        for loop in loops where registrations[loop.loopId] == nil {
            await register(loop)
        }
        guard starting, !stopped, lifecycleGeneration == generation else { return false }

        for registration in Array(registrations.values) {
            if let runner = registration.runner as? ManagedLoopRunner { await runner.gate.reopen() }
        }
        await scheduler.start()
        guard starting, !stopped, lifecycleGeneration == generation else {
            await scheduler.stop()
            return false
        }
        started = true
        startedAt = clock()
        let previousObservation = residentObservationTask
        let observation = self.residentObservation
        let observationID = UUID()
        residentObservationID = observationID
        residentObservationTask = Task { [weak self] in
            await previousObservation?.value
            if !Task.isCancelled { await observation?() }
            await settle { [weak self] in await self?.retireResidentObservation(observationID) }
        }
        observeWallClock(lifecycle: generation)
        activateAllPhysiology()
        finishStartTransition()
        return true
    }

    private func retireResidentObservation(_ id: UUID) {
        guard residentObservationID == id else { return }
        residentObservationTask = nil
        residentObservationID = nil
    }

    /// Terminal stop for app quit: the manager never starts again. Plain
    /// `stop()` stays restartable and keeps registrations.
    public func shutdown() async {
        stopped = true
        await stop()
    }

    public func stop() async {
        lifecycleGeneration &+= 1
        started = false
        let observation = residentObservationTask
        observation?.cancel()
        if starting {
            finishStartTransition()
        }
        cancelAllPhysiologyTasks()
        let replacements = restartTails.values.map(\.task)
        for task in replacements { task.cancel() }
        for observer in wallClockObservers { NotificationCenter.default.removeObserver(observer) }
        wallClockObservers.removeAll()
        await scheduler.stop()
        await settle {
            await observation?.value
            for task in replacements { await task.value }
        }
        while !retiringTasks.isEmpty {
            let retiring = Array(retiringTasks.values)
            await settle { for task in retiring { await task.value } }
        }
    }

    public func status() async -> [LoopStatus] {
        let states = await scheduler.allLoopStates()
        let currentRegistrations = registrations
        let running = started
        var result: [LoopStatus] = []
        result.reserveCapacity(states.count)
        for state in states {
            guard let runner = currentRegistrations[state.loopId]?.runner as? ManagedLoopRunner else { continue }
            let snapshot = await runner.gate.snapshot()
            let nextRun = [state.nextTickAt, physiologyDeadlines[state.loopId]]
                .compactMap { $0 }
                .min()
            result.append(LoopStatus(
                name: state.loopId,
                interval: runner.interval,
                lastRun: state.lastTickAt,
                nextRun: nextRun,
                runCount: state.tickCount,
                lastError: state.lastError,
                running: running,
                executing: snapshot.executing,
                executionStartedAt: snapshot.executionStartedAt,
                executionTimeout: runner.tickTimeoutOverride ?? 300,
                // Listener liveness is separate from registration and manager uptime.
                eventListener: physiologyRunners[state.loopId] == nil
                    ? nil
                    : (physiologyListenerHealth[state.loopId] ?? LoopEventListenerHealth()),
                lastResult: state.lastResult,
                lastSuccessfulWorkAt: state.lastCompletedAt,
                firstSeenAt: state.firstSeenAt
            ))
        }
        for registration in currentRegistrations.values {
            if case .disabled(let loopId, let reason) = registration {
                result.append(LoopStatus(
                    name: loopId, interval: 0, lastRun: nil, nextRun: nil,
                    runCount: 0, lastError: nil, disabledReason: reason,
                    lastResult: "skipped: " + LoopTickOutcome.offPrefix + reason
                ))
            } else if case .unreadable(let loopId, let error) = registration {
                result.append(LoopStatus(
                    name: loopId, interval: 0, lastRun: nil, nextRun: nil,
                    runCount: 0, lastError: error
                ))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    public func isRunning() -> Bool { started }

    public func isRunning(loopId: String) -> Bool {
        started && managedRunner(loopId: loopId) != nil
    }

    public func registered() -> [String] { registeredIds }

    public func configuredIntervals() -> [String: TimeInterval] {
        configuredLoopIntervals
    }

    public func loopRunner(loopId: String) -> (any LoopRunner)? { managedRunner(loopId: loopId)?.underlying }

    internal func managedRunner(loopId: String) -> ManagedLoopRunner? {
        registrations[loopId]?.runner as? ManagedLoopRunner
    }

    public func uptimeSeconds(now: Date = Date()) -> Double {
        // Uptime describes the CURRENT manager lifecycle, not process age or a
        // historical start. A stopped manager has no running-loop uptime.
        guard started, let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    /// Executes one registered loop through the same single-flight runner used
    /// by its periodic task. If a periodic tick is active, this call waits for
    /// that execution instead of overlapping it.
    @discardableResult
    public func runTickOnce(loopId: String) async -> LoopTickOutcome {
        if starting { await startTransition.park() }
        if !started { _ = await start() }
        guard started else {
            return .failed(error: "background loop manager unavailable")
        }
        guard let runner = managedRunner(loopId: loopId) else {
            if case .disabled(_, let reason) = registrations[loopId] { return .off(reason) }
            if case .unreadable(_, let error) = registrations[loopId] { return .failed(error: error) }
            return .failed(error: "loop not registered: \(loopId)")
        }
        return await executeRegisteredTick(
            loopId: loopId, runner: runner, lifecycle: nil, requiresDue: false
        )
    }

    /// Record work performed outside the loop's own tick through shared accounting:
    /// only completion advances the durable stamp; health-neutral skips do not
    /// record health, and failures advance the failure streak.
    public func recordOutOfBandOutcome(loopId: String, outcome: LoopTickOutcome, startedAt: Date? = nil) async {
        switch outcome {
        case .completed(let result):
            await scheduler.recordResult(loopId: loopId, result: result ?? "completed", startedAt: startedAt)
        case .skipped(let reason, _):
            guard !outcome.isHealthNeutralSkip else { return }
            await scheduler.recordResult(
                loopId: loopId,
                result: "skipped: \(reason)",
                completedWork: false, startedAt: startedAt
            )
        case .failed(let error):
            await scheduler.recordFailure(loopId: loopId, error: error)
        }
    }

    private func executeAndRecordOutcome(
        loopId: String,
        runner: ManagedLoopRunner,
        gate: LoopExecutionGate,
        automaticLifecycle: UInt64?,
        isDue: @escaping @Sendable () async -> Bool
    ) async -> LoopTickOutcome {
        let result: Result<LoopTickOutcome, Error>
        do {
            result = .success(try await tickWithTimeoutOutcome(
                { await runner.tickOutcome(ifDue: isDue) },
                timeout: runner.tickTimeoutOverride ?? 300
            ))
        } catch { result = .failure(error) }
        let execution = await gate.snapshot()
        guard registrationIsCurrent(loopId: loopId, gate: gate, lifecycle: automaticLifecycle) else {
            return .skipped(reason: LoopTickOutcome.notDueSkipReason, healthNeutral: true)
        }
        switch result {
        case .success(let outcome):
            await recordOutOfBandOutcome(loopId: loopId, outcome: outcome, startedAt: execution.executionStartedAt)
            return outcome
        case .failure(let error):
            let outcome: LoopTickOutcome
            if error is CancellationError {
                outcome = .skipped(reason: "cancelled")
            } else if error is TickTimeoutError {
                let detail = "timeout after \(formatTimeout(runner.tickTimeoutOverride ?? 300))"
                // A timeout does not advance the durable successful-run clock.
                await scheduler.recordFailure(loopId: loopId, error: detail, advanceDurableRun: false)
                outcome = .failed(error: detail)
            } else {
                let detail = String(describing: error)
                await scheduler.recordFailure(loopId: loopId, error: detail)
                outcome = .failed(error: detail)
            }
            await reschedulePhysiologyDeadline(loopId: loopId)
            return outcome
        }
    }

    /// Accepts an opportunistic wake only when the canonical scheduler's
    /// durable cadence is due. This is the NSBackgroundActivityScheduler path:
    /// it is a wake source into Core, not an independent second cadence.
    /// Explicit user/manual force-runs continue to use `runTickOnce`.
    ///
    /// A cheap initial eligibility read avoids touching the gate for normal
    /// early wakes. The authoritative read happens again after gate admission,
    /// so a periodic tick that settles between those reads prevents this wake
    /// from invoking the body.
    @discardableResult
    public func runTickIfDue(loopId: String) async -> LoopTickOutcome {
        let lifecycle = lifecycleGeneration
        if starting { await startTransition.park() }
        guard automaticLifecycleIsCurrent(lifecycle) else {
            return .skipped(reason: LoopTickOutcome.notDueSkipReason, healthNeutral: true)
        }
        guard let runner = managedRunner(loopId: loopId) else {
            if case .disabled(_, let reason) = registrations[loopId] { return .off(reason) }
            if case .unreadable(_, let error) = registrations[loopId] { return .failed(error: error) }
            return .failed(error: "loop not registered: \(loopId)")
        }
        // Cheap early rejection. This is NOT the authoritative decision: the
        // same durable predicate runs again only after this request owns the
        // shared execution gate.
        guard await scheduler.isDue(loopId: loopId) == true else {
            return .skipped(reason: LoopTickOutcome.notDueSkipReason, healthNeutral: true)
        }
        return await executeRegisteredTick(
            loopId: loopId, runner: runner, lifecycle: lifecycle, requiresDue: true
        )
    }

    /// Validate registration after suspension and inside the execution gate.
    /// Automatic wakes also carry the lifecycle that admitted them.
    internal func executeRegisteredTick(
        loopId: String,
        runner: ManagedLoopRunner,
        lifecycle: UInt64?,
        requiresDue: Bool
    ) async -> LoopTickOutcome {
        guard registrationIsCurrent(loopId: loopId, gate: runner.gate, lifecycle: lifecycle) else {
            return .skipped(reason: LoopTickOutcome.notDueSkipReason, healthNeutral: true)
        }
        let isDue: @Sendable () async -> Bool = { [weak self, scheduler, gate = runner.gate] in
            guard let self else { return false }
            if requiresDue, await scheduler.isDue(loopId: loopId) != true { return false }
            return await self.registrationIsCurrent(loopId: loopId, gate: gate, lifecycle: lifecycle)
        }
        let accounting = LoopTickAccounting()
        let outcome = await LoopTickAccounting.$current.withValue(accounting) {
            await executeAndRecordOutcome(loopId: loopId, runner: runner, gate: runner.gate,
                automaticLifecycle: lifecycle, isDue: isDue)
        }
        await accounting.didRecord()
        return outcome
    }

    internal func automaticLifecycleIsCurrent(_ lifecycle: UInt64?) -> Bool {
        guard let lifecycle else { return true } // Explicit manual execution.
        return !Task.isCancelled && started && lifecycleGeneration == lifecycle
    }

    private func registrationIsCurrent(
        loopId: String,
        gate: LoopExecutionGate,
        lifecycle: UInt64?
    ) -> Bool {
        automaticLifecycleIsCurrent(lifecycle) && !replacingLoopIds.contains(loopId)
            && managedRunner(loopId: loopId)?.gate === gate
    }

    /// Replaces or removes exactly one registration. Admission closes while
    /// the old target drains before its replacement is registered;
    /// every unrelated scheduler task and status counter remains untouched.
    /// Restarts of one id run one at a time in arrival order, and each builds
    /// its replacement when its turn comes: an older restart resuming from the
    /// drain can never replace a newer one, and the last installs what is saved now.
    public func restartLoop(id: String, newLoop: @escaping @Sendable () async -> LoopRegistration?) async {
        guard !stopped, started || starting else { return }
        let lifecycle = lifecycleGeneration
        let prior = restartTails[id]?.task
        let token = UUID()
        let turn = Task {
            await withTaskCancellationHandler {
                await prior?.value
            } onCancel: { prior?.cancel() }
            guard replacementIsCurrent(lifecycle) else { return }
            let replacement = await newLoop()
            guard replacementIsCurrent(lifecycle) else { return }
            await replaceLoop(id: id, newLoop: replacement, lifecycle: lifecycle)
        }
        restartTails[id] = (token, turn)
        await turn.value
        if restartTails[id]?.token == token { restartTails.removeValue(forKey: id) }
    }

    private var restartTails: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    private var replacingLoopIds: Set<String> = []

    private func replacementIsCurrent(_ lifecycle: UInt64) -> Bool {
        !stopped && !Task.isCancelled && lifecycleGeneration == lifecycle
    }

    private func replaceLoop(id: String, newLoop: LoopRegistration?, lifecycle: UInt64) async {
        if let newLoop, newLoop.loopId != id { return }

        replacingLoopIds.insert(id)
        defer { replacingLoopIds.remove(id) }
        cancelPhysiologyTasks(loopId: id)
        await scheduler.stopWorkForReplacement(loopId: id)
        guard replacementIsCurrent(lifecycle) else { return }
        cancelPhysiology(loopId: id)
        registrations.removeValue(forKey: id)
        registeredIds.removeAll { $0 == id }
        await scheduler.unregister(loopId: id)
        guard replacementIsCurrent(lifecycle) else { return }

        if let newLoop {
            await register(newLoop)
        } else {
            configuredLoopIntervals.removeValue(forKey: id)
        }
    }

    private func register(_ registration: LoopRegistration) async {
        let loopId = registration.loopId
        configuredLoopIntervals[loopId] = registration.runner?.interval ?? 0
        if !registeredIds.contains(loopId) { registeredIds.append(loopId) }
        guard let loop = registration.runner else {
            registrations[loopId] = registration
            return
        }
        let gate = LoopExecutionGate()
        let runner = ManagedLoopRunner(
            underlying: loop,
            gate: gate,
            clock: clock,
            onFinished: { [weak self] in
                await self?.reschedulePhysiologyDeadline(loopId: loop.loopId)
            }
        )
        registrations[loop.loopId] = .enabled(runner)
        if let physiology = loop as? any EventDeadlineLoopRunner {
            physiologyRunners[loop.loopId] = physiology
            physiologyGenerations[loop.loopId] = UUID()
        } else {
            cancelPhysiology(loopId: loop.loopId)
        }
        await scheduler.register(runner) { [weak self] in
            guard let self else { return }
            let lifecycle = await self.lifecycleGeneration
            _ = await self.executeRegisteredTick(
                loopId: loopId, runner: runner, lifecycle: lifecycle, requiresDue: false
            )
        }
        if started {
            activatePhysiology(loopId: loop.loopId)
        }
    }

    /// A replaced task stays owned through its exit, even after its active
    /// slot is reused. These tasks only join settlement; they admit no work.
    internal var retiringTasks: [UUID: Task<Void, Never>] = [:]

    private func finishStartTransition() {
        starting = false
        startTransition.resume()
    }

    internal nonisolated func formatTimeout(_ seconds: TimeInterval) -> String {
        if seconds.rounded() == seconds {
            return "\(Int(seconds))s"
        }
        return "\(seconds)s"
    }
}
