import Foundation
import PersistenceCore

// MARK: - BackgroundLoopsManager
//
// Process-wide owner for Swift background-loop registration, execution, and
// status. Concrete loop assembly stays in NativeAgentApp and is injected via
// `start(loops:)`, keeping this module dependency-light.

public struct LoopStatus: Sendable, Equatable {
    public let name: String
    public let lastRun: Date?
    public let nextRun: Date?
    public let runCount: Int
    public let lastError: String?
    public let running: Bool

    public init(
        name: String,
        lastRun: Date?,
        nextRun: Date?,
        runCount: Int,
        lastError: String?,
        running: Bool = false
    ) {
        self.name = name
        self.lastRun = lastRun
        self.nextRun = nextRun
        self.runCount = runCount
        self.lastError = lastError
        self.running = running
    }
}

/// Serializes every execution request for one loop registration. A request
/// arriving during an active tick waits for that tick and then returns without
/// invoking the underlying loop again.

/// One parked idle-waiter registration. All mutation is confined to the gate
/// actor; `@unchecked Sendable` only so the cancellation handler can hop back
/// onto the actor carrying it.
private final class IdleWait: @unchecked Sendable {
    var continuation: CheckedContinuation<Void, Never>?
    var cancelled = false
}

private actor LoopExecutionGate {
    struct Snapshot: Sendable {
        let lastRun: Date?
        let runCount: Int
    }

    private var active = false
    private var lastRun: Date?
    private var runCount = 0
    private var idleWaiters: [IdleWait] = []
    private var joinCount = 0
    private var joinWaiters: [CheckedContinuation<Void, Never>] = []
    /// Bumped on every successful acquire. `finish` only acts when its token
    /// matches, so a wedged tick that force-released and then completed LATE
    /// can never close a gate a newer tick already owns.
    private var generation: UInt64 = 0

    /// Returns the ownership token to the request that owns this execution.
    /// Coalesced callers wait for that owner and receive nil.
    func acquireOrJoin() async -> UInt64? {
        guard active else {
            active = true
            runCount += 1
            generation &+= 1
            return generation
        }
        joinCount += 1
        let observers = joinWaiters
        joinWaiters.removeAll()
        for observer in observers {
            observer.resume()
        }
        await waitForIdle()
        return nil
    }

    /// Releases the gate for exactly one acquire. `date` is nil for a forced
    /// release (the owner was cancelled/timed out while the underlying tick was
    /// still running) so a wedged tick never advertises a completed run.
    func finish(at date: Date?, token: UInt64) {
        guard active, token == generation else { return }
        if let date { lastRun = date }
        active = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation?.resume()
        }
    }

    func waitUntilIdle() async {
        guard active else { return }
        await waitForIdle()
    }

    /// Drops a parked waiter whose Task was cancelled. 2026-07-21 audit (MED):
    /// a loop wedged ignoring cancellation used to leak the joining Task and
    /// its continuation in `idleWaiters` forever — one per interval.
    private func cancelIdleWait(_ wait: IdleWait) {
        wait.cancelled = true
        guard let idx = idleWaiters.firstIndex(where: { $0 === wait }) else { return }
        idleWaiters.remove(at: idx)
        wait.continuation?.resume()
    }

    /// Parks the caller until the active tick finishes, resuming early when
    /// its Task is cancelled so a wedged tick can never leak the waiter.
    private func waitForIdle() async {
        let wait = IdleWait()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // A cancellation that raced registration must never park.
                if wait.cancelled {
                    continuation.resume()
                } else {
                    wait.continuation = continuation
                    idleWaiters.append(wait)
                }
            }
        } onCancel: {
            Task { await self.cancelIdleWait(wait) }
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(lastRun: lastRun, runCount: runCount)
    }

    func waitForCoalescedRequest() async {
        guard joinCount == 0 else { return }
        await withCheckedContinuation { continuation in
            joinWaiters.append(continuation)
        }
    }
}

/// One-shot latch resolving the race between "the underlying tick returned"
/// and "our own Task was cancelled". Exactly one resolution wins; a LATE
/// completion from a wedged tick is dropped as stale.
private actor ManagedTickRace {
    enum Result: Sendable {
        case finished(LoopTickOutcome)
        case cancelled
    }

    private var result: Result?
    private var waiters: [CheckedContinuation<Result, Never>] = []

    func resolve(_ value: Result) {
        guard result == nil else { return }
        result = value
        let parked = waiters
        waiters.removeAll()
        for waiter in parked { waiter.resume(returning: value) }
    }

    func wait() async -> Result {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private struct ManagedLoopRunner: LoopRunner {
    let underlying: any LoopRunner
    let gate: LoopExecutionGate
    let clock: @Sendable () -> Date
    let onFinished: @Sendable () async -> Void

    var loopId: String { underlying.loopId }
    var interval: TimeInterval { underlying.interval }
    var tickTimeoutOverride: TimeInterval? { underlying.tickTimeoutOverride }

    /// Single-release discipline: exactly one `finish` per `acquireOrJoin`,
    /// carrying the acquire's token. The underlying tick runs in an
    /// unstructured child so cancellation of THIS task (the manager's tick
    /// timeout cancels it) releases the gate immediately even when the loop
    /// body ignores cooperative cancellation — otherwise the gate stayed
    /// active forever and every later tick coalesced into a skip, permanently
    /// wedging the loop behind a one-time timeout.
    func tickOutcome() async -> LoopTickOutcome {
        guard let token = await gate.acquireOrJoin() else {
            return .skipped(reason: LoopTickOutcome.coalescedSkipReason)
        }
        let race = ManagedTickRace()
        let loop = underlying
        let child = Task {
            let outcome = await loop.tickOutcome()
            await race.resolve(.finished(outcome))
        }
        let result = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            child.cancel()
            Task { await race.resolve(.cancelled) }
        }

        switch result {
        case .finished(let outcome):
            await gate.finish(at: clock(), token: token)
            await onFinished()
            return outcome
        case .cancelled:
            // Forced release: the child may still be running. It can only
            // resolve an already-latched race and its token is stale, so it
            // cannot double-finish or close a newer tick's gate.
            await gate.finish(at: nil, token: token)
            await onFinished()
            return .failed(error: "cancelled before tick completed")
        }
    }
}

private struct ManagedLoopRegistration {
    let runner: ManagedLoopRunner
    let gate: LoopExecutionGate
}

public actor BackgroundLoopsManager {
    public static let shared = BackgroundLoopsManager(
        scheduler: SwiftNativeLoopScheduler(
            failureReceiptsPath: PersistenceCore.defaultDataRoot()
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("background_loop_failures.jsonl")
        )
    )

    private let scheduler: SwiftNativeLoopScheduler
    private let clock: @Sendable () -> Date
    private var started = false
    private var starting = false
    private var startedAt: Date?
    private var lifecycleGeneration: UInt64 = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var registrations: [String: ManagedLoopRegistration] = [:]
    private var registeredIds: [String] = []
    /// Event/deadline physiology stays owned by the same manager as periodic
    /// integrity sweeps. Per-loop generations make replacement fail closed:
    /// a stale stream/deadline can never execute a newly registered runner.
    private var physiologyRunners: [String: any EventDeadlineLoopRunner] = [:]
    private var physiologyGenerations: [String: UUID] = [:]
    /// Owns the one-shot startup/restart reconciliation separately from the
    /// long-lived event listener. Keeping a completion handle makes the
    /// lifecycle guarantee observable without relying on a wall-clock poll,
    /// while `start()` remains non-blocking for lanes whose reconciliation may
    /// legitimately perform long-running work.
    private var physiologyStartupTasks: [String: Task<Void, Never>] = [:]
    private var physiologyEventTasks: [String: Task<Void, Never>] = [:]
    private var physiologyDebounceTasks: [String: Task<Void, Never>] = [:]
    private var physiologyDeadlineTasks: [String: Task<Void, Never>] = [:]
    private var physiologyDeadlines: [String: Date] = [:]

    public init(
        scheduler: SwiftNativeLoopScheduler = SwiftNativeLoopScheduler(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scheduler = scheduler
        self.clock = clock
    }

    /// A4.2/A4.8: install the app-side push fired when a loop enters a real
    /// failure streak (2 consecutive failures, 6h-cooldown-paced — all gated
    /// inside the scheduler). Forwarded to the owned scheduler.
    public func setFailureTransitionPush(
        _ push: (@Sendable (_ loopId: String, _ error: String) async -> Void)?
    ) async {
        await scheduler.setFailureTransitionPush(push)
    }

    /// Injects the app-assembled manifest and starts its periodic tasks. Once
    /// running, repeated calls are idempotent for existing ids and only add
    /// missing registrations. Runtime reconfiguration must use
    /// `restartLoop(id:newLoop:)` so unrelated loop tasks and counters survive.
    @discardableResult
    public func start(loops: [any LoopRunner]) async -> Bool {
        if started {
            for loop in loops where registrations[loop.loopId] == nil {
                await register(loop)
            }
            return false
        }
        if starting {
            await waitForStartTransition()
            if started {
                for loop in loops where registrations[loop.loopId] == nil {
                    await register(loop)
                }
            }
            return false
        }

        starting = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        for loop in loops {
            await register(loop)
        }
        guard starting, lifecycleGeneration == generation else { return false }

        await scheduler.start()
        guard starting, lifecycleGeneration == generation else {
            await scheduler.stop()
            return false
        }
        started = true
        startedAt = clock()
        activateAllPhysiology()
        finishStartTransition()
        return true
    }

    /// Starts registrations already injected into the manager.
    @discardableResult
    public func start() async -> Bool {
        if started { return false }
        if starting {
            await waitForStartTransition()
            return false
        }

        starting = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        await scheduler.start()
        guard starting, lifecycleGeneration == generation else {
            await scheduler.stop()
            return false
        }
        started = true
        startedAt = clock()
        activateAllPhysiology()
        finishStartTransition()
        return true
    }

    public func stop() async {
        lifecycleGeneration &+= 1
        started = false
        if starting {
            finishStartTransition()
        }
        cancelAllPhysiologyTasks()
        await scheduler.stop()
    }

    public func status() async -> [LoopStatus] {
        let states = await scheduler.allLoopStates()
        var result: [LoopStatus] = []
        result.reserveCapacity(states.count)
        for state in states {
            let snapshot = await registrations[state.loopId]?.gate.snapshot()
            let lastRun = [state.lastTickAt, snapshot?.lastRun]
                .compactMap { $0 }
                .max()
            let nextRun = [state.nextTickAt, physiologyDeadlines[state.loopId]]
                .compactMap { $0 }
                .min()
            result.append(LoopStatus(
                name: state.loopId,
                lastRun: lastRun,
                nextRun: nextRun,
                runCount: max(state.tickCount, snapshot?.runCount ?? 0),
                lastError: state.lastError,
                running: started && registrations[state.loopId] != nil
            ))
        }
        return result
    }

    public func isRunning() -> Bool { started }

    public func isRunning(loopId: String) -> Bool {
        started && registrations[loopId] != nil
    }

    public func registered() -> [String] { registeredIds }

    public func uptimeSeconds(now: Date = Date()) -> Double {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    /// Executes one registered loop through the same single-flight runner used
    /// by its periodic task. If a periodic tick is active, this call waits for
    /// that execution instead of overlapping it.
    @discardableResult
    public func runTickOnce(loopId: String) async -> LoopTickOutcome {
        if starting { await waitForStartTransition() }
        if !started { _ = await start() }
        guard started else {
            return .failed(error: "background loop manager unavailable")
        }
        guard let registration = registrations[loopId] else {
            return .failed(error: "loop not registered: \(loopId)")
        }
        do {
            let outcome = try await tickWithTimeoutOutcome(
                registration.runner,
                timeout: registration.runner.tickTimeoutOverride ?? 300
            )
            switch outcome {
            case .completed(let result):
                await scheduler.recordResult(loopId: loopId, result: result ?? "completed")
            case .skipped(let reason):
                if reason != LoopTickOutcome.coalescedSkipReason {
                    await scheduler.recordResult(loopId: loopId, result: "skipped: \(reason)")
                }
            case .failed(let error):
                await scheduler.recordFailure(loopId: loopId, error: error)
            }
            return outcome
        } catch is CancellationError {
            await reschedulePhysiologyDeadline(loopId: loopId)
            return .skipped(reason: "cancelled")
        } catch is TickTimeoutError {
            let error = "timeout after \(formatTimeout(registration.runner.tickTimeoutOverride ?? 300))"
            await scheduler.recordFailure(
                loopId: loopId,
                error: error
            )
            await reschedulePhysiologyDeadline(loopId: loopId)
            return .failed(error: error)
        } catch {
            let detail = String(describing: error)
            await scheduler.recordFailure(loopId: loopId, error: detail)
            await reschedulePhysiologyDeadline(loopId: loopId)
            return .failed(error: detail)
        }
    }

    /// Replaces or removes exactly one registration. The old target is
    /// cancelled and allowed to drain before its replacement is registered;
    /// every unrelated scheduler task and status counter remains untouched.
    public func restartLoop(id: String, newLoop: (any LoopRunner)?) async {
        if let newLoop, newLoop.loopId != id { return }

        cancelPhysiology(loopId: id)
        let previous = registrations.removeValue(forKey: id)
        registeredIds.removeAll { $0 == id }
        await scheduler.unregister(loopId: id)
        await previous?.gate.waitUntilIdle()

        if let newLoop {
            await register(newLoop)
        }
    }

    private func register(_ loop: any LoopRunner) async {
        let gate = LoopExecutionGate()
        let runner = ManagedLoopRunner(
            underlying: loop,
            gate: gate,
            clock: clock,
            onFinished: { [weak self] in
                await self?.reschedulePhysiologyDeadline(loopId: loop.loopId)
            }
        )
        registrations[loop.loopId] = ManagedLoopRegistration(runner: runner, gate: gate)
        if !registeredIds.contains(loop.loopId) {
            registeredIds.append(loop.loopId)
        }
        if let physiology = loop as? any EventDeadlineLoopRunner {
            physiologyRunners[loop.loopId] = physiology
            physiologyGenerations[loop.loopId] = UUID()
        } else {
            cancelPhysiology(loopId: loop.loopId)
        }
        await scheduler.register(runner)
        if started {
            activatePhysiology(loopId: loop.loopId)
        }
    }

    // MARK: Event/deadline physiology

    private func activateAllPhysiology() {
        for id in physiologyRunners.keys.sorted() {
            activatePhysiology(loopId: id)
        }
    }

    private func activatePhysiology(loopId: String) {
        guard started,
              let runner = physiologyRunners[loopId],
              let generation = physiologyGenerations[loopId]
        else { return }
        physiologyStartupTasks.removeValue(forKey: loopId)?.cancel()
        physiologyEventTasks[loopId]?.cancel()
        let stream = runner.physiologyEvents()
        physiologyEventTasks[loopId] = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await self?.physiologyEventArrived(loopId: loopId, generation: generation)
            }
        }
        // Startup/restart reconciliation closes the missed-event window
        // without waiting for the slow integrity sweep. It is deliberately a
        // separately owned one-shot task: coupling it to the infinite stream
        // consumer made completion depend on when that listener happened to
        // receive executor time under whole-suite or host saturation.
        physiologyStartupTasks[loopId] = Task { [weak self] in
            await self?.reschedulePhysiologyDeadline(loopId: loopId)
            await self?.firePhysiology(loopId: loopId, generation: generation)
        }
    }

    private func physiologyEventArrived(loopId: String, generation: UUID) {
        guard started,
              physiologyGenerations[loopId] == generation,
              let runner = physiologyRunners[loopId]
        else { return }
        physiologyDeadlineTasks.removeValue(forKey: loopId)?.cancel()
        physiologyDeadlines.removeValue(forKey: loopId)
        physiologyDebounceTasks.removeValue(forKey: loopId)?.cancel()
        let delay = max(0, min(runner.eventCoalescingDelay, 60))
        physiologyDebounceTasks[loopId] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            await self?.firePhysiology(loopId: loopId, generation: generation)
        }
    }

    private func firePhysiology(loopId: String, generation: UUID) async {
        guard started, physiologyGenerations[loopId] == generation else { return }
        physiologyDebounceTasks.removeValue(forKey: loopId)
        _ = await runTickOnce(loopId: loopId)
    }

    private func reschedulePhysiologyDeadline(loopId: String) async {
        physiologyDeadlineTasks.removeValue(forKey: loopId)?.cancel()
        physiologyDeadlines.removeValue(forKey: loopId)
        guard started,
              let runner = physiologyRunners[loopId],
              let generation = physiologyGenerations[loopId]
        else { return }
        let current = clock()
        guard let deadline = await runner.nextMeaningfulDeadline(after: current),
              deadline.timeIntervalSince(current).isFinite,
              deadline > current
        else { return }
        physiologyDeadlines[loopId] = deadline
        let delay = min(deadline.timeIntervalSince(current), 365 * 24 * 60 * 60)
        physiologyDeadlineTasks[loopId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.firePhysiologyDeadline(
                loopId: loopId,
                generation: generation,
                deadline: deadline
            )
        }
    }

    private func firePhysiologyDeadline(
        loopId: String,
        generation: UUID,
        deadline: Date
    ) async {
        guard started,
              physiologyGenerations[loopId] == generation,
              physiologyDeadlines[loopId] == deadline
        else { return }
        physiologyDeadlineTasks.removeValue(forKey: loopId)
        physiologyDeadlines.removeValue(forKey: loopId)
        _ = await runTickOnce(loopId: loopId)
    }

    private func cancelPhysiology(loopId: String) {
        physiologyStartupTasks.removeValue(forKey: loopId)?.cancel()
        physiologyEventTasks.removeValue(forKey: loopId)?.cancel()
        physiologyDebounceTasks.removeValue(forKey: loopId)?.cancel()
        physiologyDeadlineTasks.removeValue(forKey: loopId)?.cancel()
        physiologyDeadlines.removeValue(forKey: loopId)
        physiologyGenerations.removeValue(forKey: loopId)
        physiologyRunners.removeValue(forKey: loopId)
    }

    private func cancelAllPhysiologyTasks() {
        for task in physiologyStartupTasks.values { task.cancel() }
        for task in physiologyEventTasks.values { task.cancel() }
        for task in physiologyDebounceTasks.values { task.cancel() }
        for task in physiologyDeadlineTasks.values { task.cancel() }
        physiologyStartupTasks.removeAll()
        physiologyEventTasks.removeAll()
        physiologyDebounceTasks.removeAll()
        physiologyDeadlineTasks.removeAll()
        physiologyDeadlines.removeAll()
    }

    private func waitForStartTransition() async {
        guard starting else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    private func finishStartTransition() {
        starting = false
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private nonisolated func formatTimeout(_ seconds: TimeInterval) -> String {
        if seconds.rounded() == seconds {
            return "\(Int(seconds))s"
        }
        return "\(seconds)s"
    }

    // MARK: Test seams

    internal func _testRunPeriodicTick(loopId: String) async {
        await scheduler._testRunOneTick(loopId: loopId)
    }

    internal func _testTaskHandle(loopId: String) async -> Task<Void, Never>? {
        await scheduler._testTaskHandle(loopId: loopId)
    }

    internal func _testWaitForCoalescedRequest(loopId: String) async {
        await registrations[loopId]?.gate.waitForCoalescedRequest()
    }

    internal func _testPhysiologyDeadline(loopId: String) -> Date? {
        physiologyDeadlines[loopId]
    }

    /// Deterministic proof seam for the manager-owned startup reconciliation.
    /// Awaiting the actual lifecycle task preserves the invariant under host
    /// load; a fixed polling timeout can only prove scheduler availability.
    internal func _testWaitForPhysiologyStartup(loopId: String) async {
        guard let task = physiologyStartupTasks[loopId] else { return }
        await task.value
    }

    internal func _testFirePhysiologyDeadline(loopId: String) async {
        guard let generation = physiologyGenerations[loopId],
              let deadline = physiologyDeadlines[loopId]
        else { return }
        physiologyDeadlineTasks.removeValue(forKey: loopId)?.cancel()
        await firePhysiologyDeadline(
            loopId: loopId,
            generation: generation,
            deadline: deadline
        )
    }
}
