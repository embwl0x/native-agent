import SwiftUI
import AppKit
import ChatOrchestration

/// Central scheduler for the few visible reads that genuinely sample live
/// heterogeneous state and do not have one complete push owner (currently the
/// chat health and in-flight-work summaries). Canonical local files/stores must
/// use their owner invalidations instead of registering here.
///
/// The scheduler sleeps until the next registered job is due and pauses jobs
/// while the chat is streaming or the app is unfocused.
///
/// Wiring contract:
///   - `AppModel` owns a `let pollScheduler = PollScheduler()` and calls
///     `bind(to: self)` once in its init.
///   - Views register inside `.task { ... }` and unregister in
///     `.onDisappear { ... }` keyed by a stable string id.
@MainActor
final class PollScheduler: ObservableObject {
    struct PollJob: Identifiable, Sendable {
        let id: String
        let interval: TimeInterval
        let pauseWhenStreaming: Bool
        let pauseWhenUnfocused: Bool

        init(id: String, interval: TimeInterval, pauseWhenStreaming: Bool, pauseWhenUnfocused: Bool) {
            self.id = id
            self.interval = interval
            self.pauseWhenStreaming = pauseWhenStreaming
            self.pauseWhenUnfocused = pauseWhenUnfocused
        }
    }

    private var jobs: [String: PollJob] = [:]
    private var handlers: [String: @MainActor () async -> Void] = [:]
    private var lastTick: [String: Date] = [:]
    private var task: Task<Void, Never>?
    private weak var appModel: AppModel?
    private let pausedRecheckInterval: TimeInterval = 5
    private let maxSleepInterval: TimeInterval = 120
    private let minSleepInterval: TimeInterval = 0.5
    /// Ceiling on one handler. These are visible-UI reads; thirty seconds is
    /// already far past any of them finishing honestly.
    private let handlerDeadline: TimeInterval = 30
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let isStreaming: @MainActor (AppModel?) -> Bool
    private let isAppActive: @MainActor () -> Bool

    init(
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(for: .seconds(delay))
        },
        isStreaming: @escaping @MainActor (AppModel?) -> Bool = { model in
            model?.anySessionStreaming == true
        },
        isAppActive: @escaping @MainActor () -> Bool = { NSApp.isActive }
    ) {
        self.now = now
        self.sleep = sleep
        self.isStreaming = isStreaming
        self.isAppActive = isAppActive
    }

    func bind(to model: AppModel) {
        self.appModel = model
        restart()
    }

    func register(_ job: PollJob, fire: @escaping @MainActor () async -> Void) {
        jobs[job.id] = job
        handlers[job.id] = fire
        // Seed lastTick to now so the first poll-driven fire happens one full
        // `interval` after registration — callers that want an immediate fire
        // do it inline BEFORE register(), and we don't want to double-fire on
        // the next 1s scheduler tick. (Review finding #6.)
        lastTick[job.id] = now()
        restart()
    }

    func unregister(_ id: String) {
        jobs.removeValue(forKey: id)
        handlers.removeValue(forKey: id)
        lastTick.removeValue(forKey: id)
        restart()
    }

    private func shouldFire(_ job: PollJob, now: Date) -> Bool {
        if let last = lastTick[job.id], now.timeIntervalSince(last) < job.interval { return false }
        // `anySessionStreaming` already subsumes `isChatStreaming`. (Review #10.)
        if job.pauseWhenStreaming, isStreaming(appModel) { return false }
        if job.pauseWhenUnfocused, !isAppActive() { return false }
        return true
    }

    private func isPaused(_ job: PollJob) -> Bool {
        // `anySessionStreaming` already subsumes `isChatStreaming`. (Review #10.)
        if job.pauseWhenStreaming, isStreaming(appModel) { return true }
        if job.pauseWhenUnfocused, !isAppActive() { return true }
        return false
    }

    private func remainingUntilDue(_ job: PollJob, now: Date) -> TimeInterval {
        guard let last = lastTick[job.id] else { return job.interval }
        return max(0, job.interval - now.timeIntervalSince(last))
    }

    private func nextSleepInterval(now: Date) -> TimeInterval {
        guard !jobs.isEmpty else { return maxSleepInterval }

        var best = maxSleepInterval
        var hasPausedDueJob = false
        for job in jobs.values {
            let remaining = remainingUntilDue(job, now: now)
            if isPaused(job), remaining <= 0 {
                hasPausedDueJob = true
            } else {
                best = min(best, remaining)
            }
        }
        if hasPausedDueJob {
            best = min(best, pausedRecheckInterval)
        }
        return min(max(best, minSleepInterval), maxSleepInterval)
    }

    /// 2026-09-06: a handler that never returns used to stall the whole
    /// scheduler — the pass never reached its sleep, every other job stopped
    /// firing, and the next `restart()` then waited on that same handler
    /// forever. Each fire runs under a hard ceiling; a handler that blows it is
    /// abandoned (cancelled, then ignored) and logged, and the pass moves on.
    private func fire(_ id: String, _ handler: @escaping @MainActor () async -> Void) async {
        let work = Task { @MainActor in await handler() }
        // The race runs in its own unstructured task on purpose: `withDeadline`
        // resolves to nil the moment ITS task is cancelled, and a restart
        // cancels this loop — which would hand the generation back while the
        // handler was still running, the very overlap `restart()` waits to
        // avoid. An unstructured task does not inherit that cancellation, so
        // the wait below ends on the handler or on the ceiling, nothing else.
        let bounded = Task {
            await IntraTurnContextCompaction.withDeadline(seconds: handlerDeadline) {
                await work.value
                return true
            }
        }
        guard await bounded.value == nil else { return }
        work.cancel()
        NSLog(
            "[poll-scheduler] job %@ exceeded its %.0fs ceiling — abandoned, scheduler continuing",
            id, handlerDeadline
        )
    }

    private func restart() {
        // 2026-09-06: cancellation is a request, and the old generation only
        // checked it at the top of its `while`. A restart mid-handler (any
        // register/unregister, and every view appear/disappear does one) left
        // the cancelled loop running the REST of its snapshot while the new
        // loop fired the same handlers — two overlapping reads of the same
        // state. The new generation now waits for the old one to actually exit,
        // and the old one checks cancellation between handlers so that wait is
        // bounded by ONE handler, not a whole pass.
        let previous = task
        previous?.cancel()
        guard !jobs.isEmpty else {
            // 2026-09-06: this used to drop the reference. Unregistering the
            // last job while its handler was still running left the NEXT
            // registration with nothing to await, so the new generation started
            // on top of the old handler — exactly the overlap the wait below
            // exists to prevent. The cancelled task is kept so whoever
            // registers next joins it first.
            return
        }
        task = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled {
                guard let me = self else { return }
                let now = me.now()
                let snapshot = Array(me.jobs.values)
                for job in snapshot where me.shouldFire(job, now: now) {
                    if Task.isCancelled { return }
                    me.lastTick[job.id] = now
                    if let h = me.handlers[job.id] { await me.fire(job.id, h) }
                }
                let delay = me.nextSleepInterval(now: me.now())
                try? await me.sleep(delay)
            }
        }
    }
}
