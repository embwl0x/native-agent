import AgentConversations
import AgentWorkspace
import CognitiveSubstrate
import Foundation
import Experiences
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Desk
// Blueprint: | `NativeCognitionRuntime+SourceWakes.swift` | Source observations and checked care-movement consumption |

/// Use source invalidations and actual time boundaries on the existing residual deadline; quiet sources need no interval polling.
struct CognitiveSourceWakes: Sendable {
    var canonObservation: Task<Void, Never>?
    var horizonObservation: Task<Void, Never>?
    var peopleObservation: Task<Void, Never>?
    var clockObservation: Task<Void, Never>?
    /// Serializes opportunity admission across the presence source's suspensions.
    var hourReading: ScopedWaiter?
    var careObservation: Task<Void, Never>?
    /// The care movements already read (their `once` keys), so each is posted once per reading.
    var careMoments: Set<String> = []
    var canonReady = false
    var canonInputs: [URL: SnapshotTailOpLog.FileStamp]?
    var horizonReady = false
    var canonDirty = true
    var canonNextAt: Date?
    var horizonDirty = true
    var horizonNextAt: Date?
    var horizonRunning = false
    var clockDirty = true
    /// Keep only concurrent writes here; item notes own news rest.
    var newsReleasesInFlight: Set<String> = []

    func cancelObservations() {
        canonObservation?.cancel()
        horizonObservation?.cancel()
        peopleObservation?.cancel()
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
        // Observe membership before enumeration so archives created during watch binding remain buffered.
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

    func startCognitiveSourceObservations() {
        guard !isFlushedForTermination, sourceWakes.clockObservation == nil else { return }
        OrganJudge.beat(Self.reflectionOrgan, .held, note: "waiting for dream or replay evidence")
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
        // Mark readiness only after registration; rearm before reads so new children also receive watches.
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
        // The address book names who each care is held with.
        let people = EventDeadlinePhysiology.storeAndFileEvents(paths: [root.appendingPathComponent("agents/peers.json")])
        sourceWakes.peopleObservation = Task { [weak self] in
            await self?.substrate.refreshCarePeople()
            for await _ in people {
                guard !Task.isCancelled else { return }
                await self?.substrate.refreshCarePeople()
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

    /// Keep registration and termination checks in one nonsuspending actor segment, including after observation awaits.
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

    private func clockSourceChanged() async {
        guard !isFlushedForTermination else { return }
        rhythm.dirty = true
        sourceWakes.clockDirty = true
        sourceWakes.canonDirty = true
        sourceWakes.horizonDirty = true
        cachedBodyRead = nil
        await rescheduleCognitionMaintenanceDeadline(force: true)
        await rescheduleResidualRepairDeadline()
        guard !isFlushedForTermination, !Task.isCancelled else { return }
        await host.perceiveDay(dataRoot: dataRoot)
    }

    /// Every new judged movement of a care (a story entry, by whoever judged it: after-turn, reflection, the night, the hour) amends the agent's
    /// thoughts about that care since its previous movement. A movement that lifts the care's pressure up through its bar is a `self` happening,
    /// unless a thought of the agent's own made it (a thought's own acts are attended inside it): a care speaks once per rise, not once per turn.
    func caresSourceChanged() async {
        guard !isFlushedForTermination, !Task.isCancelled, let cares = await substrate.careStories() else { return }
        var seen: Set<String> = []
        var moved: [(care: CognitiveCare, index: Int, once: String)] = []
        for care in cares {
            for (index, moment) in care.story.enumerated() {
                let milliseconds = (moment.at.timeIntervalSince1970 * 1_000).rounded()
                guard milliseconds.isFinite, milliseconds >= Double(Int64.min), milliseconds < Double(Int64.max) else {
                    RepairOwed.owe(dataRoot, id: "attention.care-time:" + care.id.uuidString, kind: .act,
                        operation: "attention.care-time", owner: care.id.uuidString, words: "A care movement has an invalid timestamp.",
                        lever: "Repair this care's recorded timestamp before reading its movement.")
                    continue
                }
                let once = "care:\(care.id.uuidString):\(Int64(milliseconds))"
                guard seen.insert(once).inserted, !sourceWakes.careMoments.contains(once), care.fadedAt == nil,
                      !Task.isCancelled else { continue }
                moved.append((care, index, once))
            }
        }
        sourceWakes.careMoments.formIntersection(seen)
        for (care, index, once) in moved {
            do {
                try await careMoved(care, at: index, once: once)
                sourceWakes.careMoments.insert(once)
                RepairOwed.settle(dataRoot, operation: "attention.amend:" + once, evidence: .init(source: "care", id: once))
            } catch {
                RepairOwed.owe(dataRoot, id: "attention.amend:" + once, kind: .act,
                    operation: "attention.amend:" + once, owner: care.id.uuidString, words: error.localizedDescription,
                    lever: "Repair the named care or thought record; this care movement remains unread.")
            }
        }
    }

    private func careMoved(_ care: CognitiveCare, at index: Int, once: String) async throws {
        guard let moment = care.story.dropFirst(index).first else {
            throw PersistenceCoreError.ioFailure("The care movement is missing: " + once)
        }
        let subject = "care:" + care.id.uuidString
        let words = care.about + ": " + moment.felt + " — " + moment.note
        let bar = CognitiveSubstrate.careReleasePressure
        if let pressure = moment.pressure, pressure.before < bar, pressure.after >= bar,
           !moment.source.hasPrefix("exchange:" + Attention.stream + "/") {
            let happening = Happening(.`self`, subject: subject, door: "care", who: "self", words: words, once: once,
                care: care.id.uuidString, moved: moment.moved, open: pressure.open)
            await Attention.post(happening, dataRoot: dataRoot).value
            guard try await ExperienceStore.at(dataRoot).experience(happening.id) != nil else {
                throw PersistenceCoreError.ioFailure("The care movement happening has not been committed: " + happening.id)
            }
        }
        guard moment.moved != 0 else { return }
        let previous = care.story.prefix(index).last?.at
        let node = try await substrate.attentionNode(care: care.id, subject: subject, words: words).key
        for thought in try await Attention.thoughts(dataRoot: dataRoot, now: now()) where thought.thought?.node == node
            && !thought.claims.contains(where: { $0.claim == Thought.careMoved }) {
            guard let settled = NativeTimestampFormat.parseISO8601FractionalFirst(thought.at) else {
                throw PersistenceCoreError.ioFailure("The thought has an invalid settlement timestamp: " + thought.id)
            }
            guard settled <= moment.at, previous.map({ settled > $0 }) ?? true else { continue }
            try await Attention.amend(thought: thought.id, dataRoot: dataRoot)
        }
    }

    func nextCognitiveSourceWake(at: Date) -> Date? {
        let canon = backgroundThinkingEnabled && sourceWakes.canonReady && studioCanonTask == nil ? (sourceWakes.canonDirty
            ? lastStudioCanonTendingAt?.addingTimeInterval(Self.studioCanonTendingMinimumInterval) ?? at
            : sourceWakes.canonNextAt) : nil
        let horizon = sourceWakes.horizonReady && horizonRefreshTask == nil ? (sourceWakes.horizonDirty
            ? at
            : sourceWakes.horizonNextAt) : nil
        let rhythmAt = rhythm.refresh == nil ? (rhythm.dirty ? at : [rhythm.due, rhythm.nightDue].compactMap { $0 }.min()) : nil
        return [canon, horizon, rhythmAt].compactMap { $0 }.min()
    }

}
