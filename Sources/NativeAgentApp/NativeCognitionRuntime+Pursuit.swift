// Move-only extraction (tightness Wave C) from NativeCognitionRuntime.swift

import Foundation
import ChatOrchestration
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting

extension NativeCognitionRuntime {
    // G-M3: single-consumer bound relocated from the core runtime into the
    // extension that owns its only reader (prefix() below).
    private static let maximumPursuitCandidates = 8

    /// Her top resident self-pursuit projection. This method is deliberately
    /// synchronous: a user turn can never initiate Desk I/O.
    private func currentPursuitIntent(now: Date) -> (activeTask: String, goal: String)? {
        let best = pursuitCandidates
            .compactMap { item in WorkshopPump.choiceScore(for: item, now: now).map { (item, $0) } }
            .max { $0.1.total < $1.1.total }
        guard let p = best?.0.pursuit else { return nil }
        func bound(_ s: String) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
        return (activeTask: bound(p.why), goal: bound(p.doneLooksLike))
    }

    /// Register before the first replay so no committed Desk edge can land in
    /// the read/subscription gap. Matching by exact path preserves injected
    /// data-root hermeticity; `.desk` would cross-invalidate every runtime.
    func startPursuitObservationIfNeeded() {  // internal for actor extensions (move-only Wave C)
        guard pursuitObservationTask == nil else { return }
        let path = dataRoot.appendingPathComponent("desk/desk_ops.jsonl")
        let events = EventDeadlinePhysiology.storeAndFileEvents(paths: [path])
        pursuitObservationTask = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled else { return }
                await self?.pursuitSourceInvalidated()
            }
        }
    }

    private func pursuitSourceInvalidated() {
        pursuitProjectionGeneration &+= 1
        // A possibly closed pursuit must stop steering attention immediately.
        pursuitCandidates = []
        attentionProjection.replacePursuit(activeTask: nil, goal: nil)
        if pursuitRefreshInFlight {
            pursuitRefreshQueued = true
            return
        }
        Task { [weak self] in
            await self?.startPursuitRefresh(waitForCompletion: false)
        }
    }

    func startPursuitRefresh(waitForCompletion: Bool) async {  // internal for actor extensions (move-only Wave C)
        if pursuitRefreshInFlight {
            pursuitRefreshQueued = true
            return
        }
        pursuitRefreshInFlight = true
        let generation = pursuitProjectionGeneration
        let loader = pursuitStateLoader
        let task = Task.detached(priority: .utility) { [weak self] in
            let state: DeskState?
            do {
                state = try await loader()
            } catch {
                state = nil
            }
            await self?.finishPursuitRefresh(state: state, generation: generation)
        }
        if waitForCompletion {
            await task.value
        }
    }

    private func finishPursuitRefresh(state: DeskState?, generation: UInt64) {
        pursuitRefreshInFlight = false
        if generation == pursuitProjectionGeneration {
            pursuitCandidates = Array((state?.items ?? []).filter {
                $0.isPursuit && !$0.status.isTerminal
            }.prefix(Self.maximumPursuitCandidates))
        }
        let intent = currentPursuitIntent(now: now())
        attentionProjection.replacePursuit(
            activeTask: intent?.activeTask,
            goal: intent?.goal
        )
        let needsFollowUp = pursuitRefreshQueued || generation != pursuitProjectionGeneration
        pursuitRefreshQueued = false
        if needsFollowUp {
            Task { [weak self] in
                await self?.startPursuitRefresh(waitForCompletion: false)
            }
        }
    }
}
