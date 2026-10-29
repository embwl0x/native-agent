import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `BackgroundLoops.swift` | SwiftNativeLoopScheduler registrations, timing, backoff and worker lifecycle; LoopTickAccounting settlement |

/// An execution releases ownership only after both its body and the caller's
/// cadence/backoff accounting have finished, in either order.
actor LoopTickAccounting {
    @TaskLocal static var current: LoopTickAccounting?
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

/// In-process wake scheduler with one Task per configured loop. start()
/// is idempotent at the per-loop level — calling start() twice will not
/// double-spawn a tick task for any single loop. stop() cancels every
/// outstanding task and clears them; loops remain registered and a fresh
/// start() will reactivate them.
public actor SwiftNativeLoopScheduler {
    /// A per-registration record. `registrationId` is the generation token
    /// used to keep a retired wake from rescheduling a replacement.
    internal struct Registration {
        let loop: any LoopRunner
        let registrationId: UUID
        let wake: @Sendable () async -> Void
    }
    internal var loops: [String: Registration] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    internal var states: [String: LoopState] = [:]
    internal let clock: @Sendable () -> Date
    internal let failureReceiptsPath: URL?
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

    /// The completions map records real work without changing the saved run-stamp shape.
    internal var persistedLastCompleted: [String: Date] = [:]

    /// Written once; dormancy starts at max(firstSeen, lastCompleted), never at a skipped tick.
    internal var persistedFirstSeen: [String: Date] = [:]
    /// The last `OrganPulse` per organ, flushed under the "pulses" key.
    internal var persistedPulses: [String: OrganPulse] = [:]
    package typealias PersistedLoopState = (
        runs: [String: Date], completions: [String: Date], firstSeen: [String: Date], pulses: [String: OrganPulse], fault: String?
    )

    /// Damaged history restarts timing with a durable fault receipt and unknown dormancy floor.
    internal var persistedStateFault: String?
    /// The pseudo loop id that the run-history store files its receipts under.
    static let loopStateReceiptId = "loop_state"
    internal var persistedStateLoaded = false
    internal var persistedStateLoad: Task<PersistedLoopState, Never>?
    /// Installed before suspension so snapshots reach disk in actor order.
    internal var persistedStateWrite: Task<Void, Never>?
    public static let healthCheckpointInterval: TimeInterval = 60
    internal let durableFlushImmediateInterval: TimeInterval
    internal var lastDurableFlushAt: Date?
    /// Slot counter used to fan overdue startup ticks out instead of firing
    /// every starved loop in the same instant. Reset on each `start()`.
    private var overdueStartupSlots = 0

    /// Every failure files or refreshes the loop's one finding. Salience owns
    /// attention; the scheduler keeps its receipts and execution backoff.
    internal var failureOutcome: (@Sendable (_ loopId: String, _ error: String) async -> Void)?
    /// Resolve the finding after the first proven-healthy tick on launch and
    /// after every recorded failure episode.
    internal var failureRecoveryPush:
        (@Sendable (_ loopId: String, _ healthyAt: Date) async -> Bool)?
    internal var failureRecoveryProbePending: Set<String> = []
    internal var consecutiveFailures: [String: Int] = [:]
    internal var lastFailureReceipt: LastFailureReceipt?
    /// `loopStatePath` holds the durable per-loop last-run map. When nil it is
    /// derived as a sibling of `failureReceiptsPath` — durable run state lives
    /// beside the durable failure receipts.
    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        failureReceiptsPath: URL? = nil,
        loopStatePath: URL? = nil,
        startupStagger: TimeInterval = 5,
        failureBackoff: LoopFailureBackoffPolicy = .default,
        minimumTickSpacing: TimeInterval = 0.25,
        durableFlushImmediateInterval: TimeInterval = SwiftNativeLoopScheduler.healthCheckpointInterval,
        jitter: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) {
        self.durableFlushImmediateInterval = max(0, durableFlushImmediateInterval)
        self.clock = clock
        self.failureReceiptsPath = failureReceiptsPath
        self.loopStatePath = loopStatePath ?? failureReceiptsPath?
            .deletingLastPathComponent()
            .appendingPathComponent("background_loop_state.json")
        self.startupStagger = max(0, startupStagger)
        self.defaultFailureBackoff = failureBackoff
        self.minimumTickSpacing = max(0, minimumTickSpacing)
        self.jitter = jitter
    }

    /// Healthy jitter spreads ticks within Doctor's overdue tolerance; nextTickAt includes it.
    public static let healthyJitterFraction = 0.1

    /// Added jitter stays strictly below Doctor's 60-second overdue-tolerance floor.
    public static let maximumHealthyJitter: TimeInterval = 30

    /// The largest delay jitter may ADD for `interval`. One-sided (never early)
    /// so the spread costs latency, never extra ticks.
    public static func jitterCeiling(for interval: TimeInterval) -> TimeInterval {
        max(0, min(max(0, interval) * healthyJitterFraction, maximumHealthyJitter))
    }

    /// `base` plus a jittered fraction of `interval`, bounded by
    /// `jitterCeiling(for:)`. `jitter` returns a value inside the range it is
    /// handed (the injected `Double.random(in:)` in production).
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

    /// Randomize overdue startup slots within this ceiling; firstTickDelay also caps them to the period.
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

    /// Missing history waits one period; overdue work uses bounded stagger; other work waits the remainder, capped to one period.
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
        // Damaged history is unknown, not fresh: no stamp is written over it,
        // and the loop carries the fault until it truly runs.
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
        // One launch/replacement probe repairs a card left active by a prior
        // process. It resolves only after this registration proves health.
        failureRecoveryProbePending.insert(id)
        // A long-lived loop (Slack socket mode) may not return from its first
        // new session for an hour. A durable completion from a prior process is
        // already health proof; the app resolver compares it with the card's
        // creation time before retiring anything.
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

    /// Drain scheduled work and passive domain resources while retaining the
    /// registration: a canceled replacement must preserve its physical gate.
    func stopWorkForReplacement(loopId: String) async {
        tasks.removeValue(forKey: loopId)?.cancel()
        await loops[loopId]?.loop.shutdown()
    }

    /// Remove a registration already drained by `stopWorkForReplacement`.
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

    /// The in-memory state only knows about completions THIS process saw. The
    /// durable map carries the rest, and it is the newer of the two that tells
    /// the truth about dormancy across a relaunch.
    private func withDurableCompletion(_ state: LoopState) -> LoopState {
        var copy = state
        copy.lastCompletedAt = [state.lastCompletedAt, persistedLastCompleted[state.loopId]]
            .compactMap { $0 }
            .max()
        copy.firstSeenAt = persistedFirstSeen[state.loopId]
        return copy
    }

    /// Read-only eligibility projection for an opportunistic OS wake.
    ///
    /// The periodic scheduler and this projection consult the same durable
    /// per-loop last-run map. The caller must still enter the manager's shared
    /// execution gate after a `true` result: eligibility is deliberately not a
    /// second claim owner, and concurrent periodic/OS wakes are coalesced by
    /// that existing gate.
    public func isDue(loopId: String, at requestedNow: Date? = nil) async -> Bool? {
        await loadPersistedStateIfNeeded()
        guard let registration = loops[loopId] else { return nil }
        guard let lastRun = persistedLastRun[loopId] else { return true }
        let now = requestedNow ?? clock()
        return now.timeIntervalSince(lastRun) >= max(0, registration.loop.interval)
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
        let interval = reg.loop.interval
        let capturedLoop = reg.loop
        let capturedRegId = reg.registrationId
        let now = clock()

        // A loop whose persisted period already elapsed gets a stagger slot so
        // N starved loops do not all fire in the same instant on launch.
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
                // Cooperative cancellation check immediately after tick
                // returns — a tick that suspended a long time may have been
                // raced by stop(); exit the loop before sleeping again.
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

    /// Actor-hopped read of the injected clock so the spawned tick task can
    /// stamp a tick's START without capturing the closure itself.
    private func currentClock() -> Date { clock() }

    /// Failure backoff runs from tick end and resets on success or health-bearing skip; healthy cadence runs from tick start.
    /// Both delays respect minimumTickSpacing, and the published nextTickAt includes jitter.
    private func nextDelay(
        for loop: any LoopRunner, registrationId: UUID, tickStartedAt: Date
    ) -> TimeInterval? {
        let id = loop.loopId
        guard loops[id]?.registrationId == registrationId else { return nil }
        let interval = max(0, loop.interval)
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
