import AgentConversations
import AgentWorkspace
import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore
import Desk
// Blueprint: | `NativeCognitionRuntime+SourceWakes.swift` | Runtime-owned source observations for canon, horizon, Reach, cares and quiet-hour preferences; registration precedes reads, renewed directory children remain watched, canon arms journal membership before enumerating input children and compares input stamps to ignore audit output and unchanged directory events, stop cancels observations, and the existing residual deadline owns source cooldown/eligibility/expiry boundaries |

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
    var horizonLastAt: Date?
    var horizonRunning = false
    var reachDirty = true
    var reachNextAt: Date?
    var reachLastScanAt: Date?
    var clockDirty = true
    var pursuitNextAt: Date?

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
    private nonisolated static func canonInputPaths(at root: URL) -> [URL] {
        let journal = root.appendingPathComponent("studio/journal")
        let archives = ((try? FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("journal_archive_") }
        return ["memory/memory.sqlite", "memory/memory.sqlite-wal", "workflows/approvals/requests.json",
                "studio/canon/canon.jsonl", "studio/canon/recall_hits.json",
                "studio/journal/journal.jsonl", "studio/journal/amendments.jsonl"]
            .map { root.appendingPathComponent($0) } + archives
    }

    private nonisolated static func canonInputStamps(at root: URL) -> [URL: SnapshotTailOpLog.FileStamp]? {
        var stamps: [URL: SnapshotTailOpLog.FileStamp] = [:]
        for path in canonInputPaths(at: root) {
            guard let stamp = SnapshotTailOpLog.fileStamp(path) else { return nil }
            stamps[path] = stamp
        }
        return stamps
    }

    private nonisolated static func canonSourceEvents(at root: URL) -> AsyncStream<Void> {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Arm membership before enumerating children. An archive created while
        // file watches bind remains buffered and renews those watches next.
        let directory = FileChangeWatcher(paths: [root.appendingPathComponent("studio/journal")]) {
            [continuation = pair.continuation] _ in continuation.yield(())
        }
        let files = EventDeadlinePhysiology.storeAndFileEvents(paths: canonInputPaths(at: root))
        let relay = Task { [continuation = pair.continuation] in
            for await _ in files {
                guard !Task.isCancelled else { return }
                continuation.yield(())
            }
        }
        pair.continuation.onTermination = { _ in
            directory.cancel()
            relay.cancel()
        }
        return pair.stream
    }

    private nonisolated static func reachInputPaths(at root: URL) -> [URL] {
        [SwiftNativeDeskStore(dataRoot: root).opsPath, SwiftNativeDeskStore(dataRoot: root).basePath]
            + ["user_prefs.json", "agents/peers.json", "cognition/user_turn.json", "cognition/reach.json", "memory/profile.json"]
                .map { root.appendingPathComponent($0) }
            + [defaultClaudeWorklog(), defaultCodexRecord(),
               FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("CODEX_HANDOFF.md")]
    }

    private nonisolated static func reachSourceEvents(at root: URL) -> AsyncStream<Void> {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Selection can change when a preferred or newly sorted named handoff
        // appears. Bind membership before selecting the file and its watches.
        let directory = FileChangeWatcher(paths: [FileManager.default.homeDirectoryForCurrentUser]) {
            [continuation = pair.continuation] _ in continuation.yield(())
        }
        let files = EventDeadlinePhysiology.storeAndFileEvents(paths: reachInputPaths(at: root))
        let relay = Task { [continuation = pair.continuation] in
            for await _ in files {
                guard !Task.isCancelled else { return }
                continuation.yield(())
            }
        }
        pair.continuation.onTermination = { _ in
            directory.cancel()
            relay.cancel()
        }
        return pair.stream
    }

    func startCognitiveSourceObservations() {
        guard !isFlushedForTermination, sourceWakes.clockObservation == nil else { return }
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
                + [approvals, root.appendingPathComponent("scheduler/jobs.json")])
        }
        let reachEvents: @Sendable () -> AsyncStream<Void> = {
            Self.reachSourceEvents(at: root)
        }
        // Each observer marks readiness only after registration. Re-arm before
        // each reread so newly created journal/job children are watched too.
        let clock = EventDeadlinePhysiology.storeAndFileEvents(paths: [preferences], notifications: [
            .NSSystemTimeZoneDidChange, .NSSystemClockDidChange,
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
        sourceWakes.canonReady = true
        let inputs = Self.canonInputStamps(at: dataRoot)
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
        sourceWakes.reachInputs = complete ? inputs : nil
        if changed {
            sourceWakes.reachDirty = true
            await rescheduleResidualRepairDeadline()
        }
    }

    private func clockSourceChanged() async {
        guard !isFlushedForTermination else { return }
        sourceWakes.clockDirty = true
        sourceWakes.canonDirty = true
        sourceWakes.reachDirty = true
        sourceWakes.horizonDirty = true
        cachedBodyRead = nil
        await rescheduleCognitionMaintenanceDeadline(force: true)
        await rescheduleResidualRepairDeadline()
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
        let canon = sourceWakes.canonReady && studioCanonTask == nil ? (sourceWakes.canonDirty
            ? lastStudioCanonTendingAt?.addingTimeInterval(Self.studioCanonTendingMinimumInterval) ?? at
            : sourceWakes.canonNextAt) : nil
        let horizon = sourceWakes.horizonReady && horizonRefreshTask == nil ? (sourceWakes.horizonDirty
            ? sourceWakes.horizonLastAt?.addingTimeInterval(Self.horizonRefreshMinimumInterval) ?? at
            : sourceWakes.horizonNextAt) : nil
        let reach = sourceWakes.reachReady && reachTask == nil && reachEnabled ? (sourceWakes.reachDirty
            ? sourceWakes.reachNextAt ?? at : sourceWakes.reachNextAt) : nil
        return [canon, horizon, reach, sourceWakes.pursuitNextAt].compactMap { $0 }.min()
    }
}
