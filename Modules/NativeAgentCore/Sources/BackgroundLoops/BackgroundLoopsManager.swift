import Foundation
import NativeAgentCore
import PersistenceCore
import Synchronization
// Blueprint: | `BackgroundLoopsManager.swift` | BackgroundLoopLifetimes registration, execution, status, resident observation and lifecycle settlement |

// EngineRuntime composes registrations; this owner keeps their lifecycle, execution and status together.

public actor BackgroundLoopLifetimes {
    public static let shared = BackgroundLoopLifetimes()

    internal let scheduler: SwiftNativeLoopScheduler
    internal let clock: @Sendable () -> Date
    internal var started = false
    private var starting = false
    private var stopped = false
    private var startedAt: Date?
    internal var lifecycleGeneration: UInt64 = 0
    // Share lifecycle with engine observation; retain a cancelled predecessor until exit before admitting its successor.
    private var residentObservation: (@Sendable () async -> Void)?
    private var residentObservationTask: Task<Void, Never>?
    private var residentObservationID: UUID?
    private var startTransition = ScopedWaiter()
    private var registrations: [String: LoopRegistration] = [:]
    // Expected configuration survives the live registration's retirement drain.
    private var configuredRegistrations: [String: LoopRegistration] = [:]
    private var registeredIds: [String] = []
    /// Keep event and periodic work under one owner; registration identity prevents stale wakes from executing replacements.
    internal var physiologyRunners: [String: any EventDeadlineLoopRunner] = [:]
    internal var physiologyGenerations: [String: UUID] = [:]
    /// Own startup reconciliation independently of listeners so start stays nonblocking and stop can still join it.
    internal var physiologyStartupTasks: [String: Task<Void, Never>] = [:]
    internal var physiologyEventTasks: [String: Task<Void, Never>] = [:]
    internal var physiologyDebounceTasks: [String: Task<Void, Never>] = [:]
    internal var physiologyDebounceTokens: [String: UUID] = [:]
    /// Transfer firing wakes to owned execution; new debounce arrivals must not cancel work already running.
    internal var physiologyExecutionTasks: [String: [UUID: Task<Void, Never>]] = [:]
    internal var physiologyPendingEvents: Set<String> = []
    internal var physiologyDeadlineTasks: [String: Task<Void, Never>] = [:]
    internal var physiologyDeadlines: [String: Date] = [:]
    /// Only the latest projection may arm or fire a deadline for this loop.
    internal var physiologyDeadlineTokens: [String: UUID] = [:]
    internal var wallClockObservers: [NSObjectProtocol] = []
    internal var physiologyListenerHealth: [String: LoopEventListenerHealth] = [:]
    internal var physiologyListenerRestartTasks: [String: Task<Void, Never>] = [:]
    /// Cap dead-listener retries at 30 seconds to avoid spinning; retain consecutive ends so status exposes the fault.
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

    /// The app's one fact that setup has finished, so the agent exists. Until it is installed every pass may start.
    private nonisolated let agentFact = Mutex<(@Sendable () -> Bool)?>(nil)

    /// Install the fact before start: a pass that needs the agent is not started until it holds.
    public nonisolated func admitAgentPasses(when agentExists: @escaping @Sendable () -> Bool) {
        agentFact.withLock { $0 = agentExists }
    }

    nonisolated func agentExists() -> Bool {
        agentFact.withLock { $0 }?() ?? true
    }

    public func setFailureRecoveryPush(
        _ push: (@Sendable (_ loopId: String, _ healthyAt: Date) async -> Bool)?
    ) async {
        await scheduler.setFailureRecoveryPush(push)
    }

    /// Install pulse recording and the body read before any organ can beat, so its first pulse reaches durable loop state. `felt` hears each beat once it
    /// is in its ring.
    public nonisolated func receiveOrganPulses(felt: @escaping @Sendable (OrganPulse) async -> Void) {
        let scheduler = scheduler
        OrganPulse.install { pulse in Task { await scheduler.recordPulse(pulse); await felt(pulse) } }
        OrganBody.install { now in try await self.organBody(now: now) }
    }

    /// The body projection, judged against this launch: a loop manager that has not started judges no silence. Each organ's record (its ring,
    /// latest beat, profile and deviation) is read from the beats themselves; an organ whose beats do not decode is named unreadable, and a failed
    /// record read throws.
    public func organBody(now: Date) async throws -> OrganBody {
        let reading = try await scheduler.organRecords()
        return OrganBody(records: reading.records, unreadable: reading.unreadable, now: now,
                         launchedAt: now.addingTimeInterval(-uptimeSeconds(now: now)))
    }

    /// Repeated starts add only missing ids; use restartLoop for reconfiguration so unrelated tasks and counters survive.
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
        // Retain gates across stop/start while cancelled work still owns physical execution.
        for loop in loops where registrations[loop.loopId] == nil {
            await register(loop)
        }
        let early = earlyRestarts; earlyRestarts = [:]
        for (id, newLoop) in early { await replaceLoop(id: id, newLoop: await newLoop(), lifecycle: generation) }
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

    /// Terminal shutdown cannot restart; ordinary stop retains registrations for a later start.
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
            let nextRun = runner.wake.period == nil ? nil : [state.nextTickAt, physiologyDeadlines[state.loopId]]
                .compactMap { $0 }
                .min()
            result.append(LoopStatus(
                name: state.loopId,
                wake: runner.wake,
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
                    name: loopId, wake: nil, lastRun: nil, nextRun: nil,
                    runCount: 0, lastError: nil, disabledReason: reason,
                    lastResult: "skipped: " + LoopTickOutcome.offPrefix + reason
                ))
            } else if case .unreadable(let loopId, let error) = registration {
                result.append(LoopStatus(
                    name: loopId, wake: nil, lastRun: nil, nextRun: nil,
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

    public func configuredLoops() -> [String: LoopRegistration] {
        configuredRegistrations
    }

    public func loopRunner(loopId: String) -> (any LoopRunner)? { managedRunner(loopId: loopId)?.underlying }

    internal func managedRunner(loopId: String) -> ManagedLoopRunner? {
        registrations[loopId]?.runner as? ManagedLoopRunner
    }

    public func uptimeSeconds(now: Date = Date()) -> Double {
        // Stopped managers have no running-loop uptime; process age is not lifecycle age.
        guard started, let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    /// Use the periodic runner’s single-flight gate so manual requests join active execution instead of overlapping it.
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

    /// Share outcome accounting with out-of-band work so skips cannot claim completion and failures keep their streak.
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
        execution: ManagedLoopExecution,
        isDue: @escaping @Sendable () async -> Bool
    ) async -> LoopTickOutcome {
        let result: Result<LoopTickOutcome, Error>
        do {
            result = .success(try await tickWithTimeoutOutcome(
                { await runner.tickOutcome(ifDue: isDue, execution: execution) },
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

    /// Revalidate registration after suspension and gate admission; automatic wakes also retain their admitting lifecycle.
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
        let execution = ManagedLoopExecution()
        let outcome = await executeAndRecordOutcome(loopId: loopId, runner: runner, gate: runner.gate,
            automaticLifecycle: lifecycle, execution: execution, isDue: isDue)
        await execution.accounting.didRecord()
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

    /// Close admission while the target drains; preserve unrelated registrations and counters.
    /// Serialize same-id restarts in arrival order and build at admission so an older suspended restart cannot replace a newer one.
    public func restartLoop(id: String, newLoop: @escaping @Sendable () async -> LoopRegistration?) async {
        guard !stopped else { return }
        // Before start, defer to manifest assembly so the last requested configuration wins.
        guard started || starting else { earlyRestarts[id] = newLoop; return }
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
    private var earlyRestarts: [String: @Sendable () async -> LoopRegistration?] = [:]
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
            configuredRegistrations.removeValue(forKey: id)
        }
    }

    private func register(_ registration: LoopRegistration) async {
        let loopId = registration.loopId
        configuredRegistrations[loopId] = registration
        if !registeredIds.contains(loopId) { registeredIds.append(loopId) }
        guard let loop = registration.runner else {
            registrations[loopId] = registration
            return
        }
        // A change-woken organ needs events to be woken by; without them it would never run.
        guard loop.wake != .onChange || loop is any EventDeadlineLoopRunner else {
            registrations[loopId] = .unreadable(loopId: loopId, error: "\(loopId) declares it runs on change but has no events; it cannot be woken")
            return
        }
        let gate = LoopExecutionGate()
        let runner = ManagedLoopRunner(
            underlying: loop,
            gate: gate,
            clock: clock,
            onFinished: { [weak self] in
                await self?.reschedulePhysiologyDeadline(loopId: loop.loopId)
            },
            agentExists: { [weak self] in self?.agentExists() ?? true }
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

    /// Retain replaced tasks until exit even after slot reuse; these joins admit no new work.
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
