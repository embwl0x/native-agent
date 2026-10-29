import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `BackgroundLoopWakes.swift` | BackgroundLoopLifetimes event listeners, coalesced wakes, wall-clock invalidation, deadlines and retained wake settlement |

extension BackgroundLoopLifetimes {
    // MARK: Event/deadline physiology

    internal func observeWallClock(lifecycle: UInt64) {
        guard wallClockObservers.isEmpty else { return }
        wallClockObservers = [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { await self?.wallClockChanged(lifecycle: lifecycle) }
            }
        }
    }

    private func wallClockChanged(lifecycle: UInt64) {
        guard automaticLifecycleIsCurrent(lifecycle) else { return }
        for id in physiologyRunners.keys.sorted() {
            if let generation = physiologyGenerations[id] {
                physiologyEventArrived(loopId: id, generation: generation)
            }
        }
    }

    internal func activateAllPhysiology() {
        for id in physiologyRunners.keys.sorted() {
            activatePhysiology(loopId: id)
        }
    }

    internal func activatePhysiology(loopId: String, reconcile: Bool = true) {
        guard started,
              let runner = physiologyRunners[loopId],
              let generation = physiologyGenerations[loopId]
        else { return }
        retire(physiologyStartupTasks.removeValue(forKey: loopId))
        retire(physiologyEventTasks.removeValue(forKey: loopId))
        retire(physiologyListenerRestartTasks.removeValue(forKey: loopId))
        var health = physiologyListenerHealth[loopId] ?? LoopEventListenerHealth()
        health.active = true
        physiologyListenerHealth[loopId] = health
        let stream = runner.physiologyEvents()
        physiologyEventTasks[loopId] = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await self?.physiologyEventArrived(loopId: loopId, generation: generation)
            }
            // Unexpected stream ends update health and restart; cancellation is the normal exit.
            guard !Task.isCancelled else { return }
            await self?.physiologyEventStreamEnded(loopId: loopId, generation: generation)
        }
        // A retained startup pass reconciles missed events independently of the stream consumer.
        // After two consecutive listener ends, keep retrying the listener without forcing ticks.
        guard reconcile else { return }
        physiologyStartupTasks[loopId] = Task { [weak self] in
            await self?.reschedulePhysiologyDeadline(loopId: loopId)
            await self?.firePhysiology(loopId: loopId, generation: generation)
        }
    }

    /// Record an unexpected stream end, then rebuild with bounded backoff and missed-event reconciliation.
    private func physiologyEventStreamEnded(loopId: String, generation: UUID) async {
        guard started, physiologyGenerations[loopId] == generation else { return }
        var health = physiologyListenerHealth[loopId] ?? LoopEventListenerHealth()
        health.active = false
        health.lastEndedAt = clock()
        health.consecutiveEnds += 1
        let delay = backoffDelay(forEndCount: health.consecutiveEnds)
        health.lastError = "event stream ended (\(health.consecutiveEnds) consecutive); restarting in \(formatTimeout(delay))"
        physiologyListenerHealth[loopId] = health

        retire(physiologyListenerRestartTasks.removeValue(forKey: loopId))
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
        let index = min(max(count, 1) - 1, eventListenerRestartBackoff.count - 1)
        return eventListenerRestartBackoff[index]
    }

    private func physiologyEventArrived(loopId: String, generation: UUID) {
        guard !Task.isCancelled, started,
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
        retire(physiologyDeadlineTasks.removeValue(forKey: loopId))
        physiologyDeadlines.removeValue(forKey: loopId)
        physiologyDeadlineTokens.removeValue(forKey: loopId)
        retire(physiologyDebounceTasks.removeValue(forKey: loopId))
        physiologyDebounceTokens.removeValue(forKey: loopId)
        if physiologyExecutionTasks[loopId] != nil {
            physiologyPendingEvents.insert(loopId)
            return
        }
        let delay = max(0, min(runner.eventCoalescingDelay, 60))
        let token = UUID()
        physiologyDebounceTokens[loopId] = token
        physiologyDebounceTasks[loopId] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            await self?.fireDebouncedPhysiology(loopId: loopId, generation: generation, token: token)
        }
    }

    private func fireDebouncedPhysiology(loopId: String, generation: UUID, token: UUID) async {
        guard physiologyDebounceTokens[loopId] == token,
              let task = physiologyDebounceTasks.removeValue(forKey: loopId) else { return }
        physiologyDebounceTokens.removeValue(forKey: loopId)
        physiologyExecutionTasks[loopId, default: [:]][token] = task
        defer { retirePhysiologyExecution(loopId: loopId, generation: generation, token: token) }
        await firePhysiology(loopId: loopId, generation: generation)
    }

    private func retirePhysiologyExecution(loopId: String, generation: UUID, token: UUID) {
        guard physiologyExecutionTasks[loopId]?.removeValue(forKey: token) != nil,
              physiologyExecutionTasks[loopId]?.isEmpty == true else { return }
        physiologyExecutionTasks.removeValue(forKey: loopId)
        if physiologyGenerations[loopId] == generation,
           physiologyPendingEvents.remove(loopId) != nil {
            physiologyEventArrived(loopId: loopId, generation: generation)
        }
    }

    private func firePhysiology(loopId: String, generation: UUID) async {
        let lifecycle = lifecycleGeneration
        guard automaticLifecycleIsCurrent(lifecycle), physiologyGenerations[loopId] == generation else { return }
        guard await waitUntilPhysiologyEligible(loopId: loopId, generation: generation, lifecycle: lifecycle),
              physiologyGenerations[loopId] == generation,
              let runner = managedRunner(loopId: loopId) else { return }
        let outcome = await executeRegisteredTick(
            loopId: loopId, runner: runner, lifecycle: lifecycle, requiresDue: false
        )
        // A wake arriving during work joins its physical exit. Preserve one
        // reconciliation afterwards: the active pass may have left a capped
        // remainder, or read before this event or deadline crossing.
        if outcome.isCoalescedSkip,
           automaticLifecycleIsCurrent(lifecycle), physiologyGenerations[loopId] == generation {
            physiologyEventArrived(loopId: loopId, generation: generation)
        }
    }

    internal func reschedulePhysiologyDeadline(loopId: String) async {
        let lifecycle = lifecycleGeneration
        retire(physiologyDeadlineTasks.removeValue(forKey: loopId))
        physiologyDeadlines.removeValue(forKey: loopId)
        guard started,
              let runner = physiologyRunners[loopId],
              let generation = physiologyGenerations[loopId]
        else { return }
        let token = UUID()
        physiologyDeadlineTokens[loopId] = token
        let current = clock()
        guard let deadline = await runner.nextMeaningfulDeadline(after: current),
              started, lifecycleGeneration == lifecycle,
              physiologyGenerations[loopId] == generation,
              physiologyDeadlineTokens[loopId] == token,
              deadline.timeIntervalSince(current).isFinite,
              deadline > current
        else { return }
        physiologyDeadlines[loopId] = deadline
        let delay = min(deadline.timeIntervalSince(current), 365 * 24 * 60 * 60)
        physiologyDeadlineTasks[loopId] = Task { [weak self] in
            // Clock and zone changes invalidate this one sleep through the
            // manager's lifecycle-owned observers, then project a new deadline.
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.firePhysiologyDeadline(
                loopId: loopId,
                generation: generation,
                token: token,
                deadline: deadline
            )
        }
    }

    private func firePhysiologyDeadline(
        loopId: String,
        generation: UUID,
        token: UUID,
        deadline: Date
    ) async {
        let lifecycle = lifecycleGeneration
        guard automaticLifecycleIsCurrent(lifecycle),
              physiologyGenerations[loopId] == generation,
              physiologyDeadlineTokens[loopId] == token,
              physiologyDeadlines[loopId] == deadline,
              let task = physiologyDeadlineTasks.removeValue(forKey: loopId)
        else { return }
        physiologyDeadlines.removeValue(forKey: loopId)
        physiologyDeadlineTokens.removeValue(forKey: loopId)
        // This wake is executing now, not a replaceable sleep. Completion can
        // rearm its successor without cancelling the task doing the projection.
        physiologyExecutionTasks[loopId, default: [:]][token] = task
        defer { retirePhysiologyExecution(loopId: loopId, generation: generation, token: token) }
        await firePhysiology(loopId: loopId, generation: generation)
    }

    private func waitUntilPhysiologyEligible(loopId: String, generation: UUID, lifecycle: UInt64) async -> Bool {
        while automaticLifecycleIsCurrent(lifecycle), physiologyGenerations[loopId] == generation {
            guard let eligibleAt = await scheduler.nextPhysiologyEligibleAt(
                loopId: loopId,
                at: clock()
            ), automaticLifecycleIsCurrent(lifecycle),
               physiologyGenerations[loopId] == generation else { return false }
            let delay = max(0, eligibleAt.timeIntervalSince(clock()))
            guard delay > 0 else { return true }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return false
            }
        }
        return false
    }

    internal func retire(_ task: Task<Void, Never>?) {
        guard let task else { return }
        task.cancel()
        let id = UUID()
        retiringTasks[id] = Task {
            await task.value
            self.retiringTasks.removeValue(forKey: id)
        }
    }

    internal func cancelPhysiologyTasks(loopId: String) {
        retire(physiologyStartupTasks.removeValue(forKey: loopId))
        retire(physiologyEventTasks.removeValue(forKey: loopId))
        retire(physiologyListenerRestartTasks.removeValue(forKey: loopId))
        physiologyListenerHealth[loopId]?.active = false
        retire(physiologyDebounceTasks.removeValue(forKey: loopId))
        physiologyDebounceTokens.removeValue(forKey: loopId)
        if let tasks = physiologyExecutionTasks.removeValue(forKey: loopId) {
            for task in tasks.values { retire(task) }
        }
        physiologyPendingEvents.remove(loopId)
        retire(physiologyDeadlineTasks.removeValue(forKey: loopId))
        physiologyDeadlines.removeValue(forKey: loopId)
        physiologyDeadlineTokens.removeValue(forKey: loopId)
    }

    internal func cancelPhysiology(loopId: String) {
        cancelPhysiologyTasks(loopId: loopId)
        // Health belongs to a registration, not the process.
        physiologyListenerHealth.removeValue(forKey: loopId)
        physiologyGenerations.removeValue(forKey: loopId)
        physiologyRunners.removeValue(forKey: loopId)
        // Replacement registrations must not inherit retired self-write stamps.
        PhysiologySelfWriteRegistry.shared.clear(loopId: loopId)
    }

    internal func cancelAllPhysiologyTasks() {
        for id in physiologyRunners.keys {
            cancelPhysiologyTasks(loopId: id)
        }
    }

}
