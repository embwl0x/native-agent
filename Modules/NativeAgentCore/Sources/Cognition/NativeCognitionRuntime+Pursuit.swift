import Foundation
import NativeAgentShared
import ChatTurnRuntime
import BackgroundLoops
import AgentWorkspace
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import Desk
import Experiences
import ProviderRouting

// Blueprint: | `NativeCognitionRuntime+Pursuit.swift` | Complete Desk/queue advisory snapshots publish through LatestRead on the runtime actor; source invalidations publish unavailable; resident intent has no turn-time Desk I/O |

extension NativeCognitionRuntime: MyQueueTurnProjectionProviding {
    public func queueTurnCandidates() -> (candidates: [DeskItem]?, refreshPendingAfterWrite: Bool) {
        let revision = SwiftNativeDeskStore.currentRevision
        return (pursuitReadRevision == revision && !isFlushedForTermination ? pursuitCandidates : nil,
                !isFlushedForTermination && pursuitCompletedRefreshRevision != revision)
    }

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
    func startPursuitObservationIfNeeded() {
        guard !isFlushedForTermination, pursuitObservationTask == nil else { return }
        startCognitiveSourceObservations()
        let sourceObservations = sourceWakes
        let events = EventDeadlinePhysiology.storeAndFileEvents(paths: [
            dataRoot.appendingPathComponent("desk/desk_ops.jsonl"),
            SwiftNativeDeskStore(dataRoot: dataRoot).basePath,
            dataRoot.appendingPathComponent("memory/memory.sqlite"),
            dataRoot.appendingPathComponent("memory/memory.sqlite-wal"),
            dataRoot.appendingPathComponent("workflows/approvals/requests.json"),
            dataRoot.appendingPathComponent("agents/resident-wake.json")
        ])
        pursuitObservationTask = Task { [weak self] in
            await withTaskCancellationHandler {
                for await _ in events {
                    guard !Task.isCancelled else { return }
                    await self?.pursuitSourceInvalidated()
                }
            } onCancel: {
                sourceObservations.cancelObservations()
            }
        }
        carriedExperienceObservationTask = Task { [weak self, root = dataRoot] in
            let changes = await ExperienceStore.at(root).changes()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.carriedConditionsChanged()
            }
        }
    }

    /// A condition that settled is written off the items that waited on it;
    /// that Desk write is what re-considers them. One pass at a time, read
    /// from the live Desk, so two settlements never write from a stale copy.
    private func carriedConditionsChanged() async {
        guard pursuitCandidates.contains(where: { !$0.status.isTerminal && $0.blockedOn.contains { $0.hasPrefix("exp:") } }) else { return }
        guard !carriedReleaseRunning else { carriedReleaseAgain = true; return }
        carriedReleaseRunning = true
        defer { carriedReleaseRunning = false }
        repeat {
            carriedReleaseAgain = false
            guard !isFlushedForTermination else { return }
            do { try await MyQueueReady.release(items: SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items, dataRoot: dataRoot) }
            catch { ModuleLog(category: "Cognition")("Wait conditions unavailable: %@", error.localizedDescription) }
        } while carriedReleaseAgain
    }

    private func pursuitSourceInvalidated() {
        guard !isFlushedForTermination else { return }
        pursuitRead.write {
            pursuitReadRevision = nil
            // A possibly closed pursuit must stop steering attention immediately.
            attentionProjection.replacePursuit(activeTask: nil, goal: nil)
        }
        if pursuitRefreshInFlight {
            pursuitRefreshQueued = true
            return
        }
        Task { [weak self] in
            await self?.startPursuitRefresh()
        }
    }

    func startPursuitRefresh() async {
        guard !isFlushedForTermination else { return }
        if pursuitRefreshInFlight {
            pursuitRefreshQueued = true
            return
        }
        pursuitRefreshInFlight = true
        sourceWakes.pursuitNextAt = nil
        pursuitRefreshTask = Task { [weak self] in
            await self?.finishPursuitRefresh()
        }
    }

    private func finishPursuitRefresh() async {
        let root = dataRoot, clock = now
        let snapshot = await pursuitRead.read({
            let task = Task.detached(priority: .utility) {
                // A commit during replay invalidates the read, never relabels it.
                let revision = SwiftNativeDeskStore.currentRevision
                let state = try? await SwiftNativeDeskStore(dataRoot: root).liveState()
                let context = state.map { _ in HerScreen.queueContext(dataRoot: root, now: clock(), ownTurn: true) }
                return (state: state, revision: revision, context: context)
            }
            return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }, publish: { snapshot in
            pursuitReadRevision = nil
            guard !isFlushedForTermination, snapshot.revision == SwiftNativeDeskStore.currentRevision,
                  let state = snapshot.state else { return }
            sourceWakes.pursuitNextAt = state.items.filter { !$0.status.isTerminal }
                .compactMap { $0.deferUntil.flatMap(DeskSequencing.parseDeferStamp) }.filter { $0 > now() }.min()
            let before = Dictionary(pursuitCandidates.filter { !$0.status.isTerminal }.map { ($0.handle, $0) },
                uniquingKeysWith: { first, _ in first })
            if pursuitCandidates != state.items { sourceWakes.reachDirty = true }
            pursuitCandidates = state.items
            pursuitCarriedContext = snapshot.context
            pursuitReadRevision = snapshot.revision
            // A condition may have settled before its wait reached the Desk.
            Task { await self.carriedConditionsChanged() }
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
        })

        pursuitRefreshInFlight = false
        pursuitRefreshTask = nil
        guard !isFlushedForTermination else { pursuitRefreshQueued = false; return }
        let intent = currentPursuitIntent(now: now())
        attentionProjection.replacePursuit(
            activeTask: intent?.activeTask,
            goal: intent?.goal
        )
        let needsFollowUp = pursuitRefreshQueued
        pursuitRefreshQueued = false
        // A failed settled refresh stays unavailable, but no longer claims to be pending.
        if !needsFollowUp { pursuitCompletedRefreshRevision = snapshot.revision }
        if needsFollowUp {
            await startPursuitRefresh()
        }
        await rescheduleResidualRepairDeadline()
    }
}

extension NativeCognitionRuntime {
    static func carries(_ item: DeskItem) -> Bool {
        item.project == MyQueue.project || item.assignee == "agent"
    }

    static func carriedTouch(_ item: DeskItem, at now: Date) -> Date {
        max(Self.deskDate(item.openedAt) ?? now,
            item.notes.filter { $0.author == "agent" }.compactMap { Self.deskDate($0.ts) }.max() ?? .distantPast)
    }

    /// One salience law, one exact-deadline owner and one existing wake door.
    func considerCarried() async -> Date? {
        guard !isFlushedForTermination, !pursuitRefreshInFlight, !pursuitRefreshQueued,
              let revision = pursuitReadRevision, let candidates = queueTurnCandidates().candidates,
              var context = pursuitCarriedContext else { return nil }
        let at = now(), root = dataRoot
        let generation = residualDeadline.generation
        guard candidates.contains(where: { Self.carries($0) && !$0.isPursuit }) else { return nil }
        guard !liveTurnInFlight else { return nil }
        let lastTurnActivityAt = await ChatTurnSteering.shared.turnActivityOrSeed(for: root, at: at)
        let quietAt = lastTurnActivityAt.addingTimeInterval(StudioWanderLane.quietInterval)
        guard revision == SwiftNativeDeskStore.currentRevision else { return nil }
        let opportunities = ResidentWake.carriedOpportunities(dataRoot: root,
            items: candidates.filter { Self.carries($0) && !$0.isPursuit }, at: at)
        var next: Date?, best: DeskItem?
        var readyByTime: [Date: Set<String>] = [:]
        for item in candidates {
            guard let wakeAt = opportunities[item.handle] else { continue }
            var crossing = wakeAt
            if let entry = MyQueue.entry(item), case .at(let due) = MyQueue.when(entry) {
                crossing = max(crossing, due)
            }
            if let deferred = item.deferUntil.flatMap(DeskSequencing.parseDeferStamp) { crossing = max(crossing, deferred) }
            crossing = max(crossing, quietAt)
            context.now = max(at, crossing)
            let ready = readyByTime[context.now] ?? Set(MyQueueReady.ready(items: candidates, context: context, dataRoot: dataRoot).map(\.handle))
            readyByTime[context.now] = ready
            guard ready.contains(item.handle) else { continue }
            if crossing > at { next = min(next ?? crossing, crossing); continue }
            if let current = best {
                if Self.carriedTouch(item, at: at) < Self.carriedTouch(current, at: at) { best = item }
            } else { best = item }
        }
        guard let best else { return next }
        let freedom = StudioWanderLane.decide(now: at, turnInFlight: liveTurnInFlight,
            lastTurnActivityAt: lastTurnActivityAt, lastWanderAt: nil)
        guard freedom == .wander else {
            guard freedom == .notQuiet else { return next }
            let freeAt = Date(timeIntervalSinceReferenceDate: quietAt.timeIntervalSinceReferenceDate.nextUp)
            return min(next ?? freeAt, freeAt)
        }
        guard revision == SwiftNativeDeskStore.currentRevision else { return nil }
        guard !liveTurnInFlight,
              generation == residualDeadline.generation, !isFlushedForTermination else { return next }
        ResidentWake.shared.request(dataRoot: root, reason: "what you carry", items: [ResidentWake.carriedArrival(best, crossing: at)])
        return next
    }

    /// Desk touch stamps are ISO-8601, with or without fractional seconds.
    static func deskDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = NativeTimestampFormat.parseISO8601FractionalFirst(trimmed) { return date }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: trimmed)
    }
}
