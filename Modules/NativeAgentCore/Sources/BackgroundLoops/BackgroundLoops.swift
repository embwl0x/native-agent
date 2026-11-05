import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Experiences

// Blueprint: | `BackgroundLoops.swift` | SwiftNativeLoopScheduler registrations, timing, backoff and worker lifecycle; LoopTickAccounting settlement |

/// Release execution ownership only after both body exit and caller cadence/backoff accounting settle.
actor LoopTickAccounting {
    private var recorded = false
    private var release: (@Sendable () async -> Void)?

    func releaseAfterRecording(_ action: @escaping @Sendable () async -> Void) async {
        if recorded {
            await action()
        } else {
            release = action
        }
    }

    func didRecord() async {
        recorded = true
        let action = release
        release = nil
        await action?()
    }
}

/// The manager owns one accounting handshake per admitted execution.
struct ManagedLoopExecution: Sendable {
    let accounting = LoopTickAccounting()
}

/// Keep one scheduled task per registration so repeated starts cannot overlap work; stop retains registrations.
public actor SwiftNativeLoopScheduler {
    /// Registration identity prevents a prior wake from rescheduling its replacement.
    internal struct Registration {
        let loop: any LoopRunner
        let registrationId: UUID
        let wake: @Sendable () async -> Void
    }
    internal var loops: [String: Registration] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    internal var states: [String: LoopState] = [:]
    internal let clock: @Sendable () -> Date
    internal let dataRoot: URL
    private var running: Bool = false

    // Backoff and failure notifications share the consecutive-failure streak, reset on real success.
    private let defaultFailureBackoff: LoopFailureBackoffPolicy
    private let jitter: @Sendable (ClosedRange<Double>) -> Double

    /// Floor computed delays so work that outruns its interval cannot busy-spin.
    private let minimumTickSpacing: TimeInterval

    /// Durable run stamps preserve the elapsed part of an interval across launches.
    internal let loopStatePath: URL?
    private let startupStagger: TimeInterval
    internal var persistedLastRun: [String: Date] = [:]

    /// Keep durable completion separate from run stamps so skipped ticks cannot reset dormancy.
    internal var persistedLastCompleted: [String: Date] = [:]

    /// Written once; dormancy starts at max(firstSeen, lastCompleted), never at a skipped tick.
    internal var persistedFirstSeen: [String: Date] = [:]
    package typealias PersistedLoopState = (
        runs: [String: Date], completions: [String: Date], firstSeen: [String: Date], fault: String?
    )
    /// A bounded in-memory reading, advanced only by reading committed details through LatestRead. `unreadable` holds, per organ, its newest beat
    /// detail that no longer decodes, until that detail ages past the record's horizon.
    /// The body's beat reading, kept in memory: fed as each beat is recorded and read from the record once per launch.
    internal var beatReading: (loaded: Bool, rings: [String: [OrganPulse]], unreadable: [String: (at: Date, why: String)]) = (false, [:], [:])
    internal var pendingBeats: [ExperienceStore.Detail] = []
    internal var beatWrite: Task<Void, Never>?

    /// Damaged history restarts timing with a durable fault receipt and unknown dormancy floor.
    internal var persistedStateFault: String?
    static let loopStateReceiptId = "loop_state"
    internal var persistedStateLoaded = false
    internal var persistedStateLoad: Task<PersistedLoopState, Never>?
    /// Installed before suspension so snapshots reach disk in actor order.
    internal var persistedStateWrite: Task<Void, Never>?
    public static let healthCheckpointInterval: TimeInterval = 60
    internal let durableFlushImmediateInterval: TimeInterval
    internal var lastDurableFlushAt: Date?
    /// Stagger overdue startup ticks so starved loops do not all fire at once.
    private var overdueStartupSlots = 0

    /// Salience owns attention; the scheduler preserves each failure’s finding, receipt and backoff.
    internal var failureOutcome: (@Sendable (_ loopId: String, _ error: String) async -> Void)?
    /// Resolve failure findings only after proven health, including cards retained across launch.
    internal var failureRecoveryPush:
        (@Sendable (_ loopId: String, _ healthyAt: Date) async -> Bool)?
    internal var failureRecoveryProbePending: Set<String> = []
    internal var consecutiveFailures: [String: Int] = [:]
    internal var lastFailureReceipt: LastFailureReceipt?
    /// Scheduling state stays in its own file; body details belong to the root's one record.
    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        loopStatePath: URL? = nil,
        startupStagger: TimeInterval = 5,
        failureBackoff: LoopFailureBackoffPolicy = .default,
        minimumTickSpacing: TimeInterval = 0.25,
        durableFlushImmediateInterval: TimeInterval = SwiftNativeLoopScheduler.healthCheckpointInterval,
        jitter: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) {
        self.durableFlushImmediateInterval = max(0, durableFlushImmediateInterval)
        self.clock = clock
        self.dataRoot = dataRoot
        self.loopStatePath = loopStatePath ?? dataRoot.appendingPathComponent("logs/background_loop_state.json")
        self.startupStagger = max(0, startupStagger)
        self.defaultFailureBackoff = failureBackoff
        self.minimumTickSpacing = max(0, minimumTickSpacing)
        self.jitter = jitter
    }

    /// Healthy jitter spreads ticks within Doctor's overdue tolerance; nextTickAt includes it.
    public static let healthyJitterFraction = 0.1

    /// Added jitter stays strictly below Doctor's 60-second overdue-tolerance floor.
    public static let maximumHealthyJitter: TimeInterval = 30

    /// One-sided jitter spreads ticks by adding latency, never extra early ticks.
    public static func jitterCeiling(for interval: TimeInterval) -> TimeInterval {
        max(0, min(max(0, interval) * healthyJitterFraction, maximumHealthyJitter))
    }

    /// Bound added jitter by the overdue tolerance so healthy spreading cannot trigger Doctor.
    public static func jitteredHealthyDelay(
        base: TimeInterval,
        interval: TimeInterval,
        jitter: (ClosedRange<Double>) -> Double
    ) -> TimeInterval {
        let ceiling = jitterCeiling(for: interval)
        guard ceiling > 0 else { return base }
        let draw = min(max(jitter(0...ceiling), 0), ceiling)
        return base + draw
    }

    /// Cap randomized startup staggering to the period so overdue work cannot wait an extra interval.
    public static let maximumStartupStagger: TimeInterval = 60

    public static func randomizedStagger(
        base: TimeInterval,
        slot: Int,
        jitter: (ClosedRange<Double>) -> Double
    ) -> TimeInterval {
        let ladder = max(0, base) * Double(max(1, slot))
        guard ladder > 0 else { return 0 }
        let capped = min(ladder, maximumStartupStagger)
        return min(max(jitter(0...capped), 0), capped)
    }

    /// Missing history waits one period; stagger overdue work and cap the remaining wait to one period.
    public static func firstTickDelay(
        interval: TimeInterval,
        lastRun: Date?,
        now: Date,
        stagger: TimeInterval
    ) -> TimeInterval {
        let period = max(0, interval)
        guard let lastRun else { return period }
        let remaining = period - now.timeIntervalSince(lastRun)
        guard remaining > 0 else { return min(max(0, stagger), period) }
        return min(remaining, period)
    }

    public func setFailureOutcome(
        _ outcome: (@Sendable (_ loopId: String, _ error: String) async -> Void)?
    ) {
        self.failureOutcome = outcome
    }

    public func setFailureRecoveryPush(
        _ push: (@Sendable (_ loopId: String, _ healthyAt: Date) async -> Bool)?
    ) {
        self.failureRecoveryPush = push
    }

    func register(_ loop: any LoopRunner, wake: @escaping @Sendable () async -> Void) async {
        let id = loop.loopId
        // Load durable history before spawning so the first wait uses the remaining interval.
        await loadPersistedStateIfNeeded()
        // Persist first registration synchronously so relaunch cannot reset its clock.
        let stampedFirstSeen: Bool
        if persistedFirstSeen[id] == nil, persistedStateFault == nil {
            persistedFirstSeen[id] = clock()
            stampedFirstSeen = true
        } else {
            stampedFirstSeen = false
        }
        // Damaged history is unknown, not fresh: retain its bytes and fault until a real run proves health.
        if persistedLastRun[id] == nil, let fault = persistedStateFault {
            states[id, default: LoopState(loopId: id)].lastError = fault + "; this loop's last run is unknown"
        } else if persistedLastRun[id] == nil {
            await recordDurableRun(loopId: id, at: clock())
        } else if stampedFirstSeen {
            // A run stamp without firstSeen still needs a synchronous dormancy-floor write.
            await flushLoopState()
        }
        // Retire the previous task before replacement so its slot admits the new registration.
        if let previous = loops[id] {
            tasks.removeValue(forKey: id)?.cancel()
            await previous.loop.shutdown()
        }
        let reg = Registration(loop: loop, registrationId: UUID(), wake: wake)
        loops[id] = reg
        // Probe retained findings once on launch or replacement; resolve only against proven health.
        failureRecoveryProbePending.insert(id)
        // Long-lived socket loops may not finish for an hour, so compare durable completion with the finding’s creation time.
        if let healthyAt = persistedLastCompleted[id],
           let recovery = failureRecoveryPush,
           await recovery(id, healthyAt) {
            failureRecoveryProbePending.remove(id)
        }
        if states[id] == nil {
            states[id] = LoopState(loopId: id)
        }
        if running {
            spawnTaskIfNeeded(for: reg)
        }
    }

    /// Drain work without dropping its registration so cancelled replacement still retains the physical gate.
    func stopWorkForReplacement(loopId: String) async {
        tasks.removeValue(forKey: loopId)?.cancel()
        await loops[loopId]?.loop.shutdown()
    }

    /// Remove only registrations already drained by stopWorkForReplacement.
    public func unregister(loopId: String) {
        loops.removeValue(forKey: loopId)
        states.removeValue(forKey: loopId)
        // A replacement loop starts its own execution backoff.
        consecutiveFailures.removeValue(forKey: loopId)
        failureRecoveryProbePending.remove(loopId)
    }

    public func start() async {
        await loadPersistedStateIfNeeded()
        running = true
        overdueStartupSlots = 0
        for (_, reg) in loops {
            spawnTaskIfNeeded(for: reg)
        }
    }

    public func stop() async {
        running = false
        for (_, t) in tasks {
            t.cancel()
        }
        tasks.removeAll()
        for registration in loops.values {
            await registration.loop.shutdown()
        }
        await flushLoopState()
    }

    public func allLoopStates() async -> [LoopState] {
        states.values.map(withDurableCompletion).sorted { $0.loopId < $1.loopId }
    }

    /// Use the newer live or durable completion so dormancy remains honest across relaunch.
    private func withDurableCompletion(_ state: LoopState) -> LoopState {
        var copy = state
        copy.lastCompletedAt = [state.lastCompletedAt, persistedLastCompleted[state.loopId]]
            .compactMap { $0 }
            .max()
        copy.firstSeenAt = persistedFirstSeen[state.loopId]
        return copy
    }

    /// OS wake eligibility reads the canonical durable cadence but still needs shared-gate admission to coalesce races.
    public func isDue(loopId: String, at requestedNow: Date? = nil) async -> Bool? {
        await loadPersistedStateIfNeeded()
        guard let registration = loops[loopId] else { return nil }
        guard let lastRun = persistedLastRun[loopId] else { return true }
        let now = requestedNow ?? clock()
        // An organ that runs on change is never due by a clock.
        guard let period = registration.loop.wake.period else { return false }
        return now.timeIntervalSince(lastRun) >= period
    }

    public func nextPhysiologyEligibleAt(
        loopId: String,
        at requestedNow: Date? = nil
    ) async -> Date? {
        guard let registration = loops[loopId] else { return nil }
        let now = requestedNow ?? clock()
        guard let lastTickAt = states[loopId]?.lastTickAt else { return now }
        let streak = consecutiveFailures[loopId] ?? 0
        let spacing: TimeInterval
        if streak > 0 {
            let policy = defaultFailureBackoff
            spacing = max(
                minimumTickSpacing,
                policy.delay(forConsecutiveFailures: streak, jitter: jitter)
            )
        } else {
            spacing = minimumTickSpacing
        }
        let eligible = lastTickAt.addingTimeInterval(spacing)
        return eligible > now ? eligible : now
    }

    // MARK: internals

    private func spawnTaskIfNeeded(for reg: Registration) {
        let id = reg.loop.loopId
        if tasks[id] != nil { return }
        // Only a rhythm has a clock; an organ that runs on change is woken by its events, its own deadline and launch.
        guard let interval = reg.loop.wake.period else { return }
        let capturedLoop = reg.loop
        let capturedRegId = reg.registrationId
        let now = clock()

        // Stagger overdue loops so launch cannot fire every starved body at once.
        let persisted = persistedLastRun[id]
        let elapsed = persisted.map { now.timeIntervalSince($0) >= max(0, interval) } ?? false
        let stagger: TimeInterval
        if elapsed {
            overdueStartupSlots += 1
            stagger = Self.randomizedStagger(
                base: startupStagger,
                slot: overdueStartupSlots,
                jitter: jitter
            )
        } else {
            stagger = startupStagger
        }
        let firstDelay = Self.firstTickDelay(
            interval: interval,
            lastRun: persisted,
            now: now,
            stagger: stagger
        )
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            var delay = firstDelay
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds(delay))
                } catch {
                    return
                }
                if Task.isCancelled { return }
                let tickStartedAt = await self.currentClock()
                await reg.wake()
                // Recheck cancellation after tick returns so a stop racing its suspension cannot schedule another sleep.
                if Task.isCancelled { return }
                // The actor computes cadence from tick start and the live failure streak.
                guard let next = await self.nextDelay(
                    for: capturedLoop, registrationId: capturedRegId, tickStartedAt: tickStartedAt
                ) else { return }
                delay = next
            }
        }
        tasks[id] = task
        // Publish the actual first delay for Doctor's overdue check.
        var st = states[id] ?? LoopState(loopId: id)
        st.nextTickAt = now.addingTimeInterval(firstDelay)
        states[id] = st
    }

    /// Read the injected clock on its actor rather than sending its closure into the spawned task.
    private func currentClock() -> Date { clock() }

    /// Failure backoff starts at tick end; healthy cadence starts at tick start and resets the failure streak.
    /// Both honor minimum spacing and publish the same jittered delay that Doctor observes.
    private func nextDelay(
        for loop: any LoopRunner, registrationId: UUID, tickStartedAt: Date
    ) -> TimeInterval? {
        let id = loop.loopId
        guard loops[id]?.registrationId == registrationId else { return nil }
        guard let interval = loop.wake.period else { return nil }
        let now = clock()
        let streak = consecutiveFailures[id] ?? 0
        let delay: TimeInterval
        if streak > 0 {
            let policy = defaultFailureBackoff
            let backoff = policy.delay(forConsecutiveFailures: streak, jitter: jitter)
            delay = max(minimumTickSpacing, max(interval, backoff))
        } else {
            let elapsed = max(0, now.timeIntervalSince(tickStartedAt))
            // Healthy jitter and published nextTickAt use the same delay.
            delay = Self.jitteredHealthyDelay(
                base: max(minimumTickSpacing, interval - elapsed),
                interval: interval,
                jitter: jitter
            )
        }
        // Publish the same corrected delay Doctor will inspect.
        if var st = states[id] {
            st.nextTickAt = now.addingTimeInterval(delay)
            states[id] = st
        }
        return delay
    }
}
