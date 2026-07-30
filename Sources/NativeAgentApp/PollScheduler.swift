import SwiftUI
import AppKit

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

    init() {}

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
        lastTick[job.id] = Date()
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
        if job.pauseWhenStreaming, appModel?.anySessionStreaming == true { return false }
        if job.pauseWhenUnfocused, !NSApp.isActive { return false }
        return true
    }

    private func isPaused(_ job: PollJob) -> Bool {
        // `anySessionStreaming` already subsumes `isChatStreaming`. (Review #10.)
        if job.pauseWhenStreaming, appModel?.anySessionStreaming == true { return true }
        if job.pauseWhenUnfocused, !NSApp.isActive { return true }
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

    private func restart() {
        task?.cancel()
        guard !jobs.isEmpty else {
            task = nil
            return
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date()
                guard let me = self else { return }
                let snapshot = Array(me.jobs.values)
                for job in snapshot where me.shouldFire(job, now: now) {
                    me.lastTick[job.id] = now
                    if let h = me.handlers[job.id] { await h() }
                }
                let delay = me.nextSleepInterval(now: Date())
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }
}
