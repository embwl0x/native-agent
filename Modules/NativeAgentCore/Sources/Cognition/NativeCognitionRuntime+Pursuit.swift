// Move-only extraction (tightness Wave C) from NativeCognitionRuntime.swift

import Foundation
import ChatOrchestration
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import Desk
import ProviderRouting

extension NativeCognitionRuntime: MyQueueTurnProjectionProviding {
    public func queueTurnCandidates() -> (candidates: [DeskItem]?, refreshPendingAfterWrite: Bool) {
        let revision = SwiftNativeDeskStore.currentRevision
        return (pursuitReadRevision == revision && !isFlushedForTermination ? pursuitCandidates : nil,
                !isFlushedForTermination && pursuitCompletedRefreshRevision != revision)
    }

    // G-M3: single-consumer bound relocated from the core runtime into the
    // extension that owns its only reader (prefix() below).
    private static let maximumPursuitCandidates = 8

    /// Her top resident self-pursuit projection. This method is deliberately
    /// synchronous: a user turn can never initiate Desk I/O.
    private func currentPursuitIntent(now: Date) -> (activeTask: String, goal: String)? {
        guard let candidates = queueTurnCandidates().candidates else { return nil }
        let best = candidates
            .filter { $0.isPursuit && !$0.status.isTerminal }
            .prefix(Self.maximumPursuitCandidates)
            .compactMap { item in host.pursuitChoiceTotal(for: item, now: now).map { (item, $0) } }
            .max { $0.1 < $1.1 }
        guard let p = best?.0.pursuit else { return nil }
        func bound(_ s: String) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
        return (activeTask: bound(p.why), goal: bound(p.doneLooksLike))
    }

    /// Register before the first replay so no committed Desk edge can land in
    /// the read/subscription gap. Matching by exact path preserves injected
    /// data-root hermeticity; `.desk` would cross-invalidate every runtime.
    func startPursuitObservationIfNeeded() {  // internal for actor extensions (move-only Wave C)
        guard !isFlushedForTermination, pursuitObservationTask == nil else { return }
        let events = EventDeadlinePhysiology.storeAndFileEvents(paths: [
            dataRoot.appendingPathComponent("desk/desk_ops.jsonl"),
            dataRoot.appendingPathComponent("workflows/approvals/requests.json"),
            dataRoot.appendingPathComponent("agents/resident-wake.json")
        ])
        pursuitObservationTask = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled else { return }
                await self?.pursuitSourceInvalidated()
            }
        }
    }

    private func pursuitSourceInvalidated() {
        guard !isFlushedForTermination else { return }
        pursuitProjectionGeneration &+= 1
        pursuitReadRevision = nil
        // A possibly closed pursuit must stop steering attention immediately.
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
        guard !isFlushedForTermination else { return }
        if pursuitRefreshInFlight {
            pursuitRefreshQueued = true
            return
        }
        pursuitRefreshInFlight = true
        let generation = pursuitProjectionGeneration
        let root = dataRoot
        let task = Task.detached(priority: .utility) { [weak self] in
            // A commit during replay invalidates the read, never relabels it.
            let revision = SwiftNativeDeskStore.currentRevision
            let state: DeskState?
            do {
                state = try await SwiftNativeDeskStore(dataRoot: root).liveState()
            } catch {
                state = nil
            }
            await self?.finishPursuitRefresh(state: state, revision: revision, generation: generation)
        }
        pursuitRefreshTask = task
        if waitForCompletion {
            await task.value
        }
    }

    private func finishPursuitRefresh(state: DeskState?, revision: UInt64, generation: UInt64) async {
        if generation == pursuitProjectionGeneration { pursuitReadRevision = nil }
        guard !isFlushedForTermination else {
            pursuitRefreshInFlight = false
            pursuitRefreshTask = nil
            pursuitRefreshQueued = false
            return
        }
        if generation == pursuitProjectionGeneration, revision == SwiftNativeDeskStore.currentRevision, let state {
            let before = Dictionary(pursuitCandidates.filter { !$0.status.isTerminal }.map { ($0.handle, $0) },
                uniquingKeysWith: { first, _ in first })
            let root = dataRoot, at = now()
            let context = await Task.detached(priority: .utility) {
                HerScreen.queueContext(dataRoot: root, now: at, ownTurn: true)
            }.value
            await applyDeskRuminations(from: state, context: context, revision: revision, generation: generation)
            if generation == pursuitProjectionGeneration, revision == SwiftNativeDeskStore.currentRevision, !isFlushedForTermination {
                pursuitCandidates = state.items
                pursuitCarriedContext = context
                pursuitReadRevision = revision
                var signals: [(String, SomaticSignalKind)] = []
                for item in state.items {
                    let wasCarried = before[item.handle].map(Self.carries) == true
                    guard Self.carries(item) || wasCarried else { continue }
                    if item.status.isTerminal || !Self.carries(item) {
                        ResidentWake.shared.withdraw(dataRoot: dataRoot, key: "carry." + item.handle)
                        if wasCarried && item.status.isTerminal {
                            signals.append((item.handle, item.status == .canceled ? .deskItemCancelled : .deskItemClosed))
                        }
                    } else if !wasCarried {
                        signals.append((item.handle, .deskItemCreated))
                    } else if item.status == .blocked, before[item.handle]?.status != .blocked {
                        signals.append((item.handle, .deskItemBlocked))
                    }
                    // Old arrival identities retire without renaming stored records.
                    ResidentWake.shared.withdraw(dataRoot: dataRoot, key: "harness." + item.handle)
                    ResidentWake.shared.withdraw(dataRoot: dataRoot, key: "queue:" + item.handle)
                }
                // Bootstrap's awaited replay must finish before signal ingestion
                // can await that same bootstrap. Later writes use this same tail.
                Task { [weak self] in
                    for (handle, kind) in signals {
                        await self?.ingestOrganismSignal(kind: kind, sourceOrgan: "carry." + handle,
                            metadata: ["predictionCorrelationId": .string(handle)],
                            persistSynchronously: false)
                    }
                    await self?.rescheduleResidualRepairDeadline()
                }
            }
        }
        pursuitRefreshInFlight = false
        pursuitRefreshTask = nil
        let intent = currentPursuitIntent(now: now())
        attentionProjection.replacePursuit(
            activeTask: intent?.activeTask,
            goal: intent?.goal
        )
        let needsFollowUp = pursuitRefreshQueued || generation != pursuitProjectionGeneration
        pursuitRefreshQueued = false
        // A failed settled refresh stays unavailable, but no longer claims to be pending.
        if !needsFollowUp { pursuitCompletedRefreshRevision = revision }
        if needsFollowUp {
            await startPursuitRefresh(waitForCompletion: false)
        }
    }
}
