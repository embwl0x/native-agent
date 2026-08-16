import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - BackgroundLoopsManager
//
// Process-wide owner for Swift background-loop registration, execution, and
// status. Concrete loop assembly stays in NativeAgentApp and is injected via
// `start(loops:)`, keeping this module dependency-light.

/// Liveness of ONE event-driven loop's stream listener (sweep R4 item 3).
///
/// An `EventDeadlineLoopRunner` is invalidated by its event stream, not by a
/// timer. When that stream ends — a file watcher invalidated, an upstream
/// continuation finished — the `for await` returns and the listener task exits
/// normally. Before this type existed nothing recorded that exit, so a loop
/// with a dead listener still reported `running: true` and simply stopped
/// firing. `nil` on `LoopStatus` means "this loop has no event listener", which
/// is a different statement from "its listener is down".
public struct LoopEventListenerHealth: Sendable, Equatable {
    /// A listener task is currently consuming the stream.
    public var active: Bool
    /// When the stream last ended on its own (nil = it never has).
    public var lastEndedAt: Date?
    /// How many times this loop's listener has been restarted since
    /// registration. Monotonic; a healthy loop stays at 0.
    public var restartCount: Int
    /// Ends since the last event actually arrived. Reset by a delivered event,
    /// which is the only proof the replacement listener is really working — a
    /// stream that ends immediately on every restart keeps climbing.
    public var consecutiveEnds: Int
    /// Human-readable last termination, carried into Doctor.
    public var lastError: String?

    public init(
        active: Bool = true,
        lastEndedAt: Date? = nil,
        restartCount: Int = 0,
        consecutiveEnds: Int = 0,
        lastError: String? = nil
    ) {
        self.active = active
        self.lastEndedAt = lastEndedAt
        self.restartCount = restartCount
        self.consecutiveEnds = consecutiveEnds
        self.lastError = lastError
    }
}

public struct LoopStatus: Sendable, Equatable {
    public let name: String
    public let lastRun: Date?
    public let nextRun: Date?
    public let runCount: Int
    public let lastError: String?
    public let running: Bool
    /// A loop body is executing right now. This differs from `running`, which
    /// only means the manager owns an active scheduler registration.
    public let executing: Bool
    public let executionStartedAt: Date?
    /// Watchdog budget for the active tick.
    public let executionTimeout: TimeInterval
    /// nil for loops that are not event-driven at all.
    public let eventListener: LoopEventListenerHealth?

    public init(
        name: String,
        lastRun: Date?,
        nextRun: Date?,
        runCount: Int,
        lastError: String?,
        running: Bool = false,
        executing: Bool = false,
        executionStartedAt: Date? = nil,
        executionTimeout: TimeInterval = 300,
        eventListener: LoopEventListenerHealth? = nil
    ) {
        self.name = name
        self.lastRun = lastRun
        self.nextRun = nextRun
        self.runCount = runCount
        self.lastError = lastError
        self.running = running
        self.executing = executing
        self.executionStartedAt = executionStartedAt
        self.executionTimeout = executionTimeout
        self.eventListener = eventListener
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
        let executing: Bool
        let executionStartedAt: Date?
    }

    private var active = false
    private var activeSince: Date?
    private var lastRun: Date?
    private var runCount = 0
    private var idleWaiters: [IdleWait] = []
    private var joinCount = 0
    /// Parked join-waiters. `ScopedWaiter` resumes EXACTLY once and is
    /// race-safe against a resume that beats the park, so registering here
    /// before parking can never strand a continuation.
    private var joinWaiters: [ScopedWaiter] = []
    /// Bumped on every successful acquire. `finish` only acts when its token
    /// matches, so a wedged tick that force-released and then completed LATE
    /// can never close a gate a newer tick already owns.
    private var generation: UInt64 = 0

    /// Returns the ownership token to the request that owns this execution.
    /// Coalesced callers wait for that owner and receive nil.
    func acquireOrJoin(startedAt: Date) async -> UInt64? {
        guard active else {
            active = true
            activeSince = startedAt
            generation &+= 1
            return generation
        }
        joinCount += 1
        let observers = joinWaiters
        joinWaiters.removeAll()
        for observer in observers {
            _ = observer.resume()
        }
        await waitForIdle()
        return nil
    }

    /// Counts only an execution whose body is actually about to run. A
    /// due-aware wake acquires the gate before its final durable due check; if
    /// that check says a periodic winner already settled, the claim is released
    /// without manufacturing a run count.
    func markExecutionStarted(token: UInt64) -> Bool {
        guard active, token == generation else { return false }
        runCount += 1
        return true
    }

    /// Releases the gate for exactly one acquire. `date` is nil for a forced
    /// release (the owner was cancelled/timed out while the underlying tick was
    /// still running) so a wedged tick never advertises a completed run.
    func finish(at date: Date?, token: UInt64) {
        guard active, token == generation else { return }
        if let date { lastRun = date }
        active = false
        activeSince = nil
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation?.resume()
        }
        // No request can coalesce into a tick that already finished, so any
        // still-parked join-waiter is waiting on an event that can never
        // happen. Releasing it here is the "every exit releases" half that
        // `joinWaiters` was missing.
        releaseJoinWaitersOnIdle()
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
        Snapshot(
            lastRun: lastRun,
            runCount: runCount,
            executing: active,
            executionStartedAt: activeSince
        )
    }

    /// Parks until a coalescing request joins the active tick.
    ///
    /// fix-join-waiter-leak (2026-08-02): this used to append a BARE
    /// continuation that only `acquireOrJoin` ever resumed. Every other exit —
    /// the tick finishing with no join, the waiting Task being cancelled —
    /// left the continuation parked in `joinWaiters` forever and hung the
    /// awaiting Task for the life of the process. `finish` never touched
    /// `joinWaiters` at all. The `IdleWait` path directly above already had the
    /// right shape; this one didn't. Now: a `ScopedWaiter` that resumes exactly
    /// once, is dropped from the registry on every exit, and carries a
    /// deadline so "never joined" surfaces as a logged false, not a hang.
    ///
    /// Returns true only when a coalescing request actually arrived.
    @discardableResult
    func waitForCoalescedRequest(timeoutSeconds: TimeInterval = 10) async -> Bool {
        guard joinCount == 0 else { return true }
        let waiter = ScopedWaiter()
        joinWaiters.append(waiter)
        let joined = await withTaskCancellationHandler {
            await waiter.park(
                timeoutSeconds: timeoutSeconds,
                reason: "coalesced loop join request"
            )
        } onCancel: {
            Task { await self.dropJoinWaiter(waiter) }
        }
        if !joined { dropJoinWaiter(waiter) }
        return joined
    }

    /// Removes a join-waiter that resolved without a join (cancelled or timed
    /// out). Resuming through the same one-shot latch keeps the resume count at
    /// exactly one even if `acquireOrJoin` races us.
    private func dropJoinWaiter(_ waiter: ScopedWaiter) {
        _ = waiter.cancel()
        guard let idx = joinWaiters.firstIndex(where: { $0 === waiter }) else { return }
        joinWaiters.remove(at: idx)
    }

    /// Releases parked join-waiters when the gate goes idle without a join —
    /// nothing can join a finished tick, so waiting further is a guaranteed
    /// timeout.
    func releaseJoinWaitersOnIdle() {
        let parked = joinWaiters
        joinWaiters.removeAll()
        for waiter in parked { _ = waiter.cancel() }
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

    /// Returns true only to the first resolver. A cancelled manager-facing
    /// wait can therefore leave lifecycle cleanup to the still-running child:
    /// when that child eventually exits, its rejected `.finished` resolution
    /// is the proof that it is finally safe to release the execution gate.
    @discardableResult
    func resolve(_ value: Result) -> Bool {
        guard result == nil else { return false }
        result = value
        let parked = waiters
        waiters.removeAll()
        for waiter in parked { waiter.resume(returning: value) }
        return true
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
    var failureBackoffPolicy: LoopFailureBackoffPolicy? { underlying.failureBackoffPolicy }

    /// Single-release discipline: exactly one `finish` per `acquireOrJoin`,
    /// carrying the acquire's token. The underlying tick runs in an
    /// unstructured child so the manager-facing timeout stays bounded even
    /// when a buggy body ignores cooperative cancellation. Crucially, that
    /// timeout no longer releases the gate: the registration stays
    /// quarantined/busy until the actual child exits. Releasing early allowed
    /// a replacement effecting tick to overlap a timed-out body whose external
    /// effects were still in flight.
    func tickOutcome() async -> LoopTickOutcome {
        await tickOutcome(ifDue: nil)
    }

    /// Due-aware entry used by opportunistic OS wakes. Gate ownership comes
    /// first; the durable due check comes second. That order closes the race in
    /// which a periodic tick could settle after an early due read but before
    /// this request entered the single-flight owner.
    func tickOutcomeIfDue(
        _ isDue: @escaping @Sendable () async -> Bool
    ) async -> LoopTickOutcome {
        await tickOutcome(ifDue: isDue)
    }

    private func tickOutcome(
        ifDue isDue: (@Sendable () async -> Bool)?
    ) async -> LoopTickOutcome {
        guard let token = await gate.acquireOrJoin(startedAt: clock()) else {
            return .skipped(reason: LoopTickOutcome.coalescedSkipReason)
        }
        if let isDue, !(await isDue()) {
            await gate.finish(at: nil, token: token)
            await onFinished()
            return .skipped(
                reason: LoopTickOutcome.notDueSkipReason,
                healthNeutral: true
            )
        }
        guard await gate.markExecutionStarted(token: token) else {
            await gate.finish(at: nil, token: token)
            return .failed(error: "background loop execution ownership lost")
        }
        let race = ManagedTickRace()
        let loop = underlying
        let child = Task {
            let outcome = await loop.tickOutcome()
            let delivered = await race.resolve(.finished(outcome))
            if !delivered {
                // Cancellation/timeout already won the caller-facing race.
                // This return is nevertheless the first authoritative proof
                // that the old effecting body is gone, so only now may a new
                // execution acquire the registration.
                await gate.finish(at: nil, token: token)
                await onFinished()
            }
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
            // The caller receives a bounded failure, but the gate deliberately
            // remains active. The child above releases it only after its real
            // exit, preventing a replacement effecting tick from overlapping
            // this quarantined execution.
            return .failed(error: "cancelled before tick completed")
        }
    }
}

/// Adapts the managed runner's gate-then-due entry back to `LoopRunner` so the
/// existing timeout and outcome-accounting path stays singular.
private struct DueAwareManagedLoopRunner: LoopRunner {
    let base: ManagedLoopRunner
    let isDue: @Sendable () async -> Bool

    var loopId: String { base.loopId }
    var interval: TimeInterval { base.interval }
    var tickTimeoutOverride: TimeInterval? { base.tickTimeoutOverride }
    var failureBackoffPolicy: LoopFailureBackoffPolicy? { base.failureBackoffPolicy }

    func tickOutcome() async -> LoopTickOutcome {
        await base.tickOutcomeIfDue(isDue)
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
    /// Sweep R4 item 3: per-loop listener liveness + the pending restart task.
    private var physiologyListenerHealth: [String: LoopEventListenerHealth] = [:]
    private var physiologyListenerRestartTasks: [String: Task<Void, Never>] = [:]
    /// Bounded restart backoff for an event listener whose stream ended. The
    /// last entry is the ceiling: a permanently dead source retries every 30s
    /// forever rather than spinning, and its climbing `consecutiveEnds` is what
    /// surfaces the problem in `status()` instead of a respawn loop hiding it.
    /// `internal` so a test can compress the schedule; production never sets it.
    internal var eventListenerRestartBackoff: [TimeInterval] = [1, 5, 30]
    /// Deterministic test seam for the due-read → gate-admission race. nil in
    /// production; it carries no runtime policy or state.
    internal var dueWakePreAdmissionHook: (@Sendable () async -> Void)?

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
                running: started && registrations[state.loopId] != nil,
                executing: snapshot?.executing ?? false,
                executionStartedAt: snapshot?.executionStartedAt,
                executionTimeout: registrations[state.loopId]?.runner.tickTimeoutOverride ?? 300,
                // Sweep R4 item 3: liveness of the EVENT lane, reported
                // separately from `running` (which only proves the manager
                // started and the loop is registered). A loop can be running
                // with a dead listener; that is precisely the state that used
                // to be invisible.
                eventListener: physiologyRunners[state.loopId] == nil
                    ? nil
                    : (physiologyListenerHealth[state.loopId] ?? LoopEventListenerHealth())
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
        return await executeAndRecord(loopId: loopId, runner: registration.runner)
    }

    private func executeAndRecord(
        loopId: String,
        runner: any LoopRunner
    ) async -> LoopTickOutcome {
        do {
            let outcome = try await tickWithTimeoutOutcome(
                runner,
                timeout: runner.tickTimeoutOverride ?? 300
            )
            switch outcome {
            case .completed(let result):
                await scheduler.recordResult(loopId: loopId, result: result ?? "completed")
            case .skipped(let reason, _):
                // `recordResult` clears the consecutive-failure streak, so an
                // out-of-band run that skipped for a HEALTH-NEUTRAL reason
                // (coalesced, or "backing off because I am failing") must not
                // go through it — same accounting as the periodic path in
                // SwiftNativeLoopScheduler.record.
                if !outcome.isHealthNeutralSkip {
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
            let error = "timeout after \(formatTimeout(runner.tickTimeoutOverride ?? 300))"
            // A TIMED-OUT tick did not complete its body, so it must NOT book a
            // fresh durable last-run stamp — same accounting as the periodic
            // path in `SwiftNativeLoopScheduler.runOneTick`. Without this a
            // wedged weekly loop timing out through the manual/background-task
            // path persisted `lastRun = now`, and restart catch-up slept another
            // week instead of treating it as overdue (gpt-5.5 BLOCKING).
            await scheduler.recordFailure(
                loopId: loopId,
                error: error,
                advanceDurableRun: false
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
        if starting { await waitForStartTransition() }
        if !started { _ = await start() }
        guard started else {
            return .failed(error: "background loop manager unavailable")
        }
        guard let registration = registrations[loopId] else {
            return .failed(error: "loop not registered: \(loopId)")
        }
        // Cheap early rejection. This is NOT the authoritative decision: the
        // same durable predicate runs again only after this request owns the
        // shared execution gate.
        guard await scheduler.isDue(loopId: loopId) == true else {
            return .skipped(reason: LoopTickOutcome.notDueSkipReason, healthNeutral: true)
        }
        await dueWakePreAdmissionHook?()
        let dueRunner = DueAwareManagedLoopRunner(
            base: registration.runner,
            isDue: { [weak self, scheduler, gate = registration.gate] in
                guard let self,
                      await self.registrationGateIsCurrent(loopId: loopId, gate: gate)
                else { return false }
                return await scheduler.isDue(loopId: loopId) == true
            }
        )
        return await executeAndRecord(loopId: loopId, runner: dueRunner)
    }

    private func registrationGateIsCurrent(
        loopId: String,
        gate: LoopExecutionGate
    ) -> Bool {
        registrations[loopId]?.gate === gate
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

    private func activatePhysiology(loopId: String, reconcile: Bool = true) {
        guard started,
              let runner = physiologyRunners[loopId],
              let generation = physiologyGenerations[loopId]
        else { return }
        physiologyStartupTasks.removeValue(forKey: loopId)?.cancel()
        physiologyEventTasks[loopId]?.cancel()
        physiologyListenerRestartTasks.removeValue(forKey: loopId)?.cancel()
        var health = physiologyListenerHealth[loopId] ?? LoopEventListenerHealth()
        health.active = true
        physiologyListenerHealth[loopId] = health
        let stream = runner.physiologyEvents()
        physiologyEventTasks[loopId] = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await self?.physiologyEventArrived(loopId: loopId, generation: generation)
            }
            // The stream ENDED. Before sweep R4 item 3 this task simply
            // returned and nothing anywhere knew: `status()` still reported the
            // loop running, and a purely event-driven loop stopped firing until
            // the process restarted. Cancellation is the legitimate exit
            // (stop/restart/replacement) and stays silent.
            guard !Task.isCancelled else { return }
            await self?.physiologyEventStreamEnded(loopId: loopId, generation: generation)
        }
        // Startup/restart reconciliation closes the missed-event window
        // without waiting for the slow integrity sweep. It is deliberately a
        // separately owned one-shot task: coupling it to the infinite stream
        // consumer made completion depend on when that listener happened to
        // receive executor time under whole-suite or host saturation.
        //
        // `reconcile: false` is the PERMANENTLY-DEAD-SOURCE case (sweep R4
        // item 3). Reconciling on every listener restart is right while the
        // source might come back, but a source that is simply gone retries at
        // the 30s ceiling forever — and reconciling each time would turn a dead
        // watcher into a forced tick every 30s for the life of the process.
        // After the third consecutive end we keep rebuilding the listener and
        // keep reporting the failure, without the tick.
        guard reconcile else { return }
        physiologyStartupTasks[loopId] = Task { [weak self] in
            await self?.reschedulePhysiologyDeadline(loopId: loopId)
            await self?.firePhysiology(loopId: loopId, generation: generation)
        }
    }

    /// A listener's stream finished on its own. Record it, then rebuild the
    /// listener after a bounded backoff. The rebuild goes through
    /// `activatePhysiology`, which ALSO re-runs the startup reconciliation —
    /// deliberately: the window in which no listener existed is a window in
    /// which events were missed, and reconciliation is the existing mechanism
    /// for closing exactly that gap.
    private func physiologyEventStreamEnded(loopId: String, generation: UUID) async {
        guard started, physiologyGenerations[loopId] == generation else { return }
        var health = physiologyListenerHealth[loopId] ?? LoopEventListenerHealth()
        health.active = false
        health.lastEndedAt = clock()
        health.consecutiveEnds += 1
        let delay = backoffDelay(forEndCount: health.consecutiveEnds)
        health.lastError = "event stream ended (\(health.consecutiveEnds) consecutive); restarting in \(formatTimeout(delay))"
        physiologyListenerHealth[loopId] = health

        physiologyListenerRestartTasks.removeValue(forKey: loopId)?.cancel()
        physiologyListenerRestartTasks[loopId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.restartPhysiologyListener(loopId: loopId, generation: generation)
        }
    }

    private func restartPhysiologyListener(loopId: String, generation: UUID) {
        physiologyListenerRestartTasks.removeValue(forKey: loopId)
        guard started, physiologyGenerations[loopId] == generation else { return }
        physiologyListenerHealth[loopId]?.restartCount += 1
        let ends = physiologyListenerHealth[loopId]?.consecutiveEnds ?? 0
        activatePhysiology(loopId: loopId, reconcile: ends <= 2)
    }

    private func backoffDelay(forEndCount count: Int) -> TimeInterval {
        guard !eventListenerRestartBackoff.isEmpty else { return 30 }
        let index = min(max(count, 1) - 1, eventListenerRestartBackoff.count - 1)
        return eventListenerRestartBackoff[index]
    }

    private func physiologyEventArrived(loopId: String, generation: UUID) {
        guard started,
              physiologyGenerations[loopId] == generation,
              let runner = physiologyRunners[loopId]
        else { return }
        // A delivered event is the ONLY proof a restarted listener actually
        // works; a stream that ends immediately every time never gets here, so
        // its consecutive-end count keeps climbing into Doctor.
        if var health = physiologyListenerHealth[loopId], health.consecutiveEnds != 0 || !health.active {
            health.consecutiveEnds = 0
            health.active = true
            health.lastError = nil
            physiologyListenerHealth[loopId] = health
        }
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
        physiologyListenerRestartTasks.removeValue(forKey: loopId)?.cancel()
        // Health belongs to a REGISTRATION, not to a process: a replaced or
        // unregistered runner must not inherit the old one's restart history.
        physiologyListenerHealth.removeValue(forKey: loopId)
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
        for task in physiologyListenerRestartTasks.values { task.cancel() }
        physiologyStartupTasks.removeAll()
        physiologyEventTasks.removeAll()
        physiologyDebounceTasks.removeAll()
        physiologyDeadlineTasks.removeAll()
        physiologyListenerRestartTasks.removeAll()
        physiologyDeadlines.removeAll()
        // A stopped manager has no listeners by definition. Marking them
        // inactive (rather than dropping the history) keeps a subsequent
        // status() honest without inventing a fresh healthy record.
        for id in physiologyListenerHealth.keys {
            physiologyListenerHealth[id]?.active = false
        }
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

    internal func _testSetDueWakePreAdmissionHook(
        _ hook: (@Sendable () async -> Void)?
    ) {
        dueWakePreAdmissionHook = hook
    }

    internal func _testTaskHandle(loopId: String) async -> Task<Void, Never>? {
        await scheduler._testTaskHandle(loopId: loopId)
    }

    @discardableResult
    internal func _testWaitForCoalescedRequest(
        loopId: String,
        timeoutSeconds: TimeInterval = 10
    ) async -> Bool {
        await registrations[loopId]?.gate.waitForCoalescedRequest(
            timeoutSeconds: timeoutSeconds
        ) ?? false
    }

    internal func _testPhysiologyDeadline(loopId: String) -> Date? {
        physiologyDeadlines[loopId]
    }

    /// Compresses the listener restart backoff so a test proves the SHAPE
    /// (ended → recorded → restarted after a delay) without sleeping seconds.
    internal func _testSetEventListenerBackoff(_ schedule: [TimeInterval]) {
        eventListenerRestartBackoff = schedule
    }

    internal func _testEventListenerHealth(loopId: String) -> LoopEventListenerHealth? {
        physiologyListenerHealth[loopId]
    }

    /// Awaits the pending restart task rather than polling a wall clock, so the
    /// restart is proven to have run even on a saturated host.
    internal func _testAwaitListenerRestart(loopId: String) async {
        guard let task = physiologyListenerRestartTasks[loopId] else { return }
        await task.value
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
