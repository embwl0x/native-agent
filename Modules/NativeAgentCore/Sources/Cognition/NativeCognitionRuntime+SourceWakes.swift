import AgentConversations
import AgentWorkspace
import CognitiveSubstrate
import Foundation
import Experiences
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Desk
import Senses
// Blueprint: | `NativeCognitionRuntime+SourceWakes.swift` | Runtime-owned source observations for canon, horizon, Reach, cares and quiet-hour preferences; launch and calendar-day/clock/time-zone invalidations ask the engine to perceive the local day; the crossing (`SenseCrossing`): a part's arrival or a sense's news that touches a care asks for one ResidentWake naming it, once per watch per care until the care rests; the same line releases open news intentions by the care law through system Desk notes, once per intention in 12 hours; registration precedes reads, renewed directory children remain watched, canon arms journal membership before enumerating input children and compares input stamps to ignore audit output and unchanged directory events, stop cancels observations, and the existing residual deadline owns source cooldown/eligibility/expiry boundaries |

/// Source invalidations and their real time boundaries, owned by this runtime.
/// No interval samples unchanged sources; the existing residual deadline owns
/// cooldown, eligibility and expiry wakes.
struct CognitiveSourceWakes: Sendable {
    var canonObservation: Task<Void, Never>?
    var horizonObservation: Task<Void, Never>?
    var reachObservation: Task<Void, Never>?
    var clockObservation: Task<Void, Never>?
    var careObservation: Task<Void, Never>?
    var lastCares: [CognitiveCare]?
    var canonReady = false
    var canonInputs: [URL: SnapshotTailOpLog.FileStamp]?
    var horizonReady = false
    var reachReady = false
    var reachInputs: [URL: SnapshotTailOpLog.FileStamp]?
    var canonDirty = true
    var canonNextAt: Date?
    var horizonDirty = true
    var horizonNextAt: Date?
    var horizonRunning = false
    var reachDirty = true
    var reachNextAt: Date?
    var reachLastScanAt: Date?
    var clockDirty = true
    var pursuitNextAt: Date?
    var wanderNextAt: Date?
    /// Only concurrent writes are held here; the item's notes own news rest.
    var newsReleasesInFlight: Set<String> = []

    func cancelObservations() {
        canonObservation?.cancel()
        horizonObservation?.cancel()
        reachObservation?.cancel()
        clockObservation?.cancel()
        careObservation?.cancel()
    }
}

extension NativeCognitionRuntime {
    nonisolated static func afterInclusiveBoundary(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.nextUp)
    }
    private nonisolated static func canonInputPaths(at root: URL) throws -> [URL] {
        let journal = root.appendingPathComponent("studio/journal")
        let members: [URL]
        do { members = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil) }
        catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile { members = [] }
        let archives = members.filter { $0.lastPathComponent.hasPrefix("journal_archive_") }
        return ["memory/memory.sqlite", "memory/memory.sqlite-wal", "workflows/approvals/requests.json",
                "studio/canon/canon.jsonl", "studio/canon/recall_hits.json",
                "studio/journal/journal.jsonl", "studio/journal/amendments.jsonl"]
            .map { root.appendingPathComponent($0) } + archives
    }

    private nonisolated static func canonInputStamps(at root: URL) -> [URL: SnapshotTailOpLog.FileStamp]? {
        var stamps: [URL: SnapshotTailOpLog.FileStamp] = [:]
        do {
            for path in try canonInputPaths(at: root) {
                guard let stamp = SnapshotTailOpLog.fileStamp(path) else {
                    throw PersistenceCoreError.ioFailure("Canon input metadata is unavailable: " + path.path)
                }
                stamps[path] = stamp
            }
        } catch { _ = bodySourceFailure(error, source: "canon source arming", dataRoot: root); return nil }
        return stamps
    }

    private nonisolated static func canonSourceEvents(at root: URL) -> AsyncStream<Void> {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Arm membership before enumerating children. An archive created while
        // file watches bind remains buffered and renews those watches next.
        let directory = FileChangeWatcher(paths: [root.appendingPathComponent("studio/journal")]) {
            [continuation = pair.continuation] _ in continuation.yield(())
        }
        let relay: Task<Void, Never>?
        do {
            let files = EventDeadlinePhysiology.storeAndFileEvents(paths: try canonInputPaths(at: root))
            relay = Task { [continuation = pair.continuation] in
                for await _ in files {
                    guard !Task.isCancelled else { return }
                    continuation.yield(())
                }
            }
        } catch {
            _ = bodySourceFailure(error, source: "canon source arming", dataRoot: root)
            relay = nil
        }
        pair.continuation.onTermination = { _ in
            directory.cancel()
            relay?.cancel()
        }
        return pair.stream
    }

    private nonisolated static func reachInputPaths(at root: URL) -> [URL] {
        [SwiftNativeDeskStore(dataRoot: root).opsPath, SwiftNativeDeskStore(dataRoot: root).basePath]
            + ["user_prefs.json", "agents/peers.json", "cognition/user_turn.json", "cognition/reach.json", "memory/profile.json"]
                .map { root.appendingPathComponent($0) }
            + [defaultClaudeWorklog(), defaultCodexRecord()]
    }

    private nonisolated static func reachSourceEvents(at root: URL) -> AsyncStream<Void> {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let files = EventDeadlinePhysiology.storeAndFileEvents(paths: reachInputPaths(at: root))
        let relay = Task { [continuation = pair.continuation] in
            for await _ in files {
                guard !Task.isCancelled else { return }
                continuation.yield(())
            }
        }
        pair.continuation.onTermination = { _ in
            relay.cancel()
        }
        return pair.stream
    }

    func startCognitiveSourceObservations() {
        guard !isFlushedForTermination, sourceWakes.clockObservation == nil else { return }
        startRhythmObservation()
        let root = dataRoot
        let memory = ["memory/memory.sqlite", "memory/memory.sqlite-wal"].map { root.appendingPathComponent($0) }
        let desk = [SwiftNativeDeskStore(dataRoot: root).opsPath, SwiftNativeDeskStore(dataRoot: root).basePath]
        let preferences = root.appendingPathComponent("user_prefs.json")
        let approvals = root.appendingPathComponent("workflows/approvals/requests.json")
        let canonEvents: @Sendable () -> AsyncStream<Void> = {
            Self.canonSourceEvents(at: root)
        }
        let horizonEvents: @Sendable () -> AsyncStream<Void> = {
            let peer = DelegationStatusProjector(configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: root), dataRoot: root)
            return EventDeadlinePhysiology.storeAndFileEvents(paths: memory + desk + peer.watchedPaths
                + [approvals])
        }
        let reachEvents: @Sendable () -> AsyncStream<Void> = {
            Self.reachSourceEvents(at: root)
        }
        // Each observer marks readiness only after registration. Re-arm before
        // each reread so newly created journal/job children are watched too.
        let clock = EventDeadlinePhysiology.storeAndFileEvents(paths: [preferences], notifications: [
            .NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange,
            ProcessInfo.thermalStateDidChangeNotification
        ])
        sourceWakes.canonObservation = Task { [weak self] in
            guard var events = await self?.admittedSourceEvents(canonEvents) else { return }
            await self?.canonSourceChanged()
            while !Task.isCancelled {
                for await _ in events {
                    guard let next = await self?.admittedSourceEvents(canonEvents) else { return }
                    events = next
                    await self?.canonSourceChanged()
                    break
                }
            }
        }
        sourceWakes.horizonObservation = Task { [weak self] in
            guard var events = await self?.admittedSourceEvents(horizonEvents) else { return }
            await self?.horizonSourceChanged()
            while !Task.isCancelled {
                for await _ in events {
                    guard let next = await self?.admittedSourceEvents(horizonEvents) else { return }
                    events = next
                    await self?.horizonSourceChanged()
                    break
                }
            }
        }
        sourceWakes.reachObservation = Task { [weak self] in
            guard var events = await self?.admittedSourceEvents(reachEvents) else { return }
            await self?.reachSourceChanged()
            while !Task.isCancelled {
                for await _ in events {
                    guard let next = await self?.admittedSourceEvents(reachEvents) else { return }
                    events = next
                    await self?.reachSourceChanged()
                    break
                }
            }
        }
        sourceWakes.clockObservation = Task { [weak self] in
            await self?.clockSourceChanged()
            for await _ in clock {
                guard !Task.isCancelled else { return }
                await self?.clockSourceChanged()
            }
        }
        let careChanges = EventDeadlinePhysiology.storeAndFileEvents(paths:
            ["cognition/cognition.sqlite", "cognition/cognition.sqlite-wal"].map { root.appendingPathComponent($0) })
        sourceWakes.careObservation = Task { [weak self] in
            await self?.caresSourceChanged()
            for await _ in careChanges {
                guard !Task.isCancelled else { return }
                await self?.caresSourceChanged()
            }
        }
    }

    /// Registration and the terminal latch share one non-suspending actor
    /// segment, including renewals after an observation await.
    private func admittedSourceEvents(_ make: @Sendable () -> AsyncStream<Void>) -> AsyncStream<Void>? {
        guard !isFlushedForTermination, !Task.isCancelled else { return nil }
        return make()
    }

    private func canonSourceChanged() async {
        guard !isFlushedForTermination else { return }
        let inputs = Self.canonInputStamps(at: dataRoot)
        sourceWakes.canonReady = inputs != nil
        let changed = inputs == nil || inputs != sourceWakes.canonInputs
        sourceWakes.canonInputs = inputs
        if changed {
            sourceWakes.canonDirty = true
            await rescheduleResidualRepairDeadline()
        }
    }

    private func horizonSourceChanged() async {
        guard !isFlushedForTermination else { return }
        sourceWakes.horizonReady = true
        sourceWakes.horizonDirty = true
        await rescheduleResidualRepairDeadline()
    }

    private func reachSourceChanged() async {
        guard !isFlushedForTermination else { return }
        sourceWakes.reachReady = true
        var inputs: [URL: SnapshotTailOpLog.FileStamp] = [:]
        var complete = true
        for path in Self.reachInputPaths(at: dataRoot) {
            if let stamp = SnapshotTailOpLog.fileStamp(path) { inputs[path] = stamp }
            else { complete = false }
        }
        let changed = !complete || inputs != sourceWakes.reachInputs
        let peersPath = dataRoot.appendingPathComponent("agents/peers.json")
        let peopleChanged = sourceWakes.reachInputs == nil || inputs[peersPath] != sourceWakes.reachInputs?[peersPath]
        sourceWakes.reachInputs = complete ? inputs : nil
        if peopleChanged { await substrate.refreshCarePeople() }
        if changed {
            sourceWakes.reachDirty = true
            await rescheduleResidualRepairDeadline()
        }
    }

    private func clockSourceChanged() async {
        guard !isFlushedForTermination else { return }
        rhythm.dirty = true
        sourceWakes.clockDirty = true
        sourceWakes.canonDirty = true
        sourceWakes.reachDirty = true
        sourceWakes.horizonDirty = true
        cachedBodyRead = nil
        await rescheduleCognitionMaintenanceDeadline(force: true)
        await rescheduleResidualRepairDeadline()
        guard !isFlushedForTermination, !Task.isCancelled else { return }
        await host.perceiveDay(dataRoot: dataRoot)
    }

    func caresSourceChanged() async {
        guard !isFlushedForTermination, !Task.isCancelled else { return }
        let cares = await substrate.caresPressing(for: CognitiveCare.ownerKey, at: Date())
            .map(\.care).sorted { $0.id.uuidString < $1.id.uuidString }
        guard !isFlushedForTermination, !Task.isCancelled, sourceWakes.lastCares != cares else { return }
        sourceWakes.lastCares = cares
        sourceWakes.reachDirty = true
        await rescheduleResidualRepairDeadline()
    }

    func nextCognitiveSourceWake(at: Date) -> Date? {
        let canon = reachEnabled && sourceWakes.canonReady && studioCanonTask == nil ? (sourceWakes.canonDirty
            ? lastStudioCanonTendingAt?.addingTimeInterval(Self.studioCanonTendingMinimumInterval) ?? at
            : sourceWakes.canonNextAt) : nil
        let horizon = sourceWakes.horizonReady && horizonRefreshTask == nil ? (sourceWakes.horizonDirty
            ? at
            : sourceWakes.horizonNextAt) : nil
        let reach = sourceWakes.reachReady && reachTask == nil && reachEnabled ? (sourceWakes.reachDirty
            ? sourceWakes.reachNextAt ?? at : sourceWakes.reachNextAt) : nil
        let rhythmAt = rhythm.refresh == nil ? (rhythm.dirty ? at : rhythm.due) : nil
        let wander = studioWanderTask == nil ? sourceWakes.wanderNextAt : nil
        return [canon, horizon, reach, sourceWakes.pursuitNextAt, rhythmAt, wander].compactMap { $0 }.min()
    }
}

// What reaches her mind is a change that touches what she cares about
// (docs/SUBCONSCIOUS.md, Cares). Owed work (carried promises, approvals, her
// opened apps, Reach, agent messages) files its own arrivals. News intentions
// meet their world moment here and join that same carried-work path.
extension NativeCognitionRuntime: SenseCrossing {
    public func cross(_ line: String, watch: String, reason: String, id: String, says: String,
                      agent: String?) async -> SenseCrossed {
        guard !isFlushedForTermination else { return .unweighed }
        // Whatever it weighs, the moment stays primed for her next turn.
        PrimedMoments.prime(dataRoot: dataRoot, line: says.isEmpty ? line : says, source: watch)
        await releaseNewsIntentions(touchedBy: line, watch: watch)
        guard !isFlushedForTermination else { return .unweighed }
        switch await substrate.careTouched(by: line, watch: watch) {
        case .unweighed: return .unweighed
        case .untouched: return .untouched
        case .touches(let care, resting: true): return .resting(care: care.about)
        case .touches(let care, resting: false):
            // The watch's thread carries the hop rule, so a watch cannot keep waking her.
            let wokeAt = now()
            guard ResidentWake.shared.request(dataRoot: dataRoot, reason: reason + " about " + care.about, items: [
                .init(id: id, line: says, thread: watch, agent: agent, home: true, at: wokeAt, careID: care.id)
            ]) else { return .notKept(care: care.about) }
            await substrate.watchWoke(watch, about: care, at: wokeAt)
            return .woke(care: care.about)
        }
    }

    /// The Desk story is both the release and its rest ledger. Her next note
    /// consumes a release; another watch may release it before this one rests.
    private func releaseNewsIntentions(touchedBy line: String, watch: String) async {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        do {
            let entries = MyQueue.entries(try await store.liveState()).filter {
                if case .news? = MyQueue.when($0) { return $0.step.status != "stopped" && !MyQueue.isOver($0, at: now()) }
                return false
            }
            let words = entries.compactMap { entry -> (id: String, words: String)? in
                guard case .news(let words)? = MyQueue.when(entry) else { return nil }
                return (entry.item.handle, words)
            }
            guard let touched = await substrate.newsIntentionsTouched(by: line, among: words) else { return }
            var released = false
            for handle in touched {
                let key = handle
                guard sourceWakes.newsReleasesInFlight.insert(key).inserted else { continue }
                defer { sourceWakes.newsReleasesInFlight.remove(key) }
                guard let weighed = entries.first(where: { $0.item.handle == handle }),
                      !isFlushedForTermination, !Task.isCancelled else { continue }
                // A refile, closure, topic change and the topic's 12-hour rest
                // are checked in the transaction that appends the release.
                if try await MyQueue.releaseNews(weighed, summary: String(line.prefix(160)) + " (" + watch + ")",
                    store: store, at: now(), rest: CognitiveSubstrate.careReleaseRest) { released = true }
            }
            if released { await startPursuitRefresh() }
        } catch {
            ModuleLog(category: "Cognition")("News intention release unavailable: %@", error.localizedDescription)
        }
    }
}
