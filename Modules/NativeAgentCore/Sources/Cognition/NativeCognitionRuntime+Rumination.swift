// Desk commitments cross into the existing rumination law, payload-free.
// Carried work shares one external slot; pursuits and hard moments keep the
// other. Canonical Desk events own the replay, never a user turn.

import Foundation
import ChatTurnRuntime
import AgentWorkspace
import BackgroundLoops
import CognitiveSubstrate
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Desk

// Blueprint: | `NativeCognitionRuntime+Rumination.swift` | `NativeCognitionRuntime` rumination bridge: bounded payload-free Desk commitments and moment evidence passed into substrate rumination law |

extension NativeCognitionRuntime {

    /// At most this many open commitments cross per read. The substrate caps
    /// the set it keeps and the slots it will spend; this keeps the crossing
    /// itself bounded.
    private static let maximumDeskRuminations = 8

    /// MOMENTS AS THE SECOND SOURCE (2026-09-02). The Desk holds what she said
    /// she would move; the moments lane holds what actually happened between
    /// them, and a hard word is an open loop in exactly the way an unfinished
    /// item is. Same weight law, same slot budget, same payload-free crossing —
    /// the substrate is not told which owner a row came from, only that it is
    /// external, so neither source outranks the other.
    ///
    /// A moment leaves this set when it heals (a warm moment later in the same
    /// conversation) or when it ages past three days. A complete owner read
    /// confirms that release; exclusion by the window never does.
    private static let maximumMomentRuminations = 4

    /// Map canonical Desk rows to the payload-free shape the lane consumes, and
    /// push, with canonical terminal handles as confirmed closures.
    func applyDeskRuminations(from state: DeskState, context: MyQueue.Context, revision: UInt64, generation: UInt64) async {
        guard !isFlushedForTermination else { return }
        let now = self.now()
        let items: [CognitiveSubstrate.CognitiveExternalRumination] = state.items
            .filter { item in
                item.isPursuit
                    && !item.status.isTerminal
                    && !DeskSequencing.isDeferred(item, now: now)
            }
            .compactMap { item in
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let touched = Self.deskDate(item.updatedAt) ?? Self.deskDate(item.openedAt) ?? now
                return CognitiveSubstrate.CognitiveExternalRumination(
                    // The handle is stable and opaque; it is never rendered.
                    id: item.handle,
                    label: title,
                    lastTouchedAt: touched
                )
            }
            // Oldest touch first: heaviest first, so the crossing cap takes the
            // ones that would have won the slots anyway.
            .sorted { $0.lastTouchedAt < $1.lastTouchedAt }
            .prefix(Self.maximumDeskRuminations - 1)
            .map { $0 }

        let ready = Set(MyQueueReady.ready(items: state.items, context: context).map(\.handle))
        let carried = state.items.filter {
            Self.carries($0) && !$0.isPursuit && !$0.status.isTerminal
        }.map {
            CognitiveSubstrate.CognitiveExternalRumination(id: $0.handle, label: $0.title,
                lastTouchedAt: Self.carriedTouch($0, at: now), isCarried: true,
                isReady: ready.contains($0.handle))
        }

        let priorIDs = await substrate.externalRuminationIDs()
        let moments = await momentRuminations(at: now, priorIDs: priorIDs)
        let closures = Dictionary(uniqueKeysWithValues: state.items.filter { $0.status.isTerminal }.compactMap { item in
            item.closedAt.flatMap(Self.deskDate).map { (item.handle, $0) }
        }).merging(Dictionary(uniqueKeysWithValues: moments.closedIDs.map { ($0, now) })) { desk, _ in desk }
        guard generation == pursuitProjectionGeneration, revision == SwiftNativeDeskStore.currentRevision,
              !isFlushedForTermination else { return }
        await substrate.setExternalRuminations(
            (Array((items + moments.items).sorted { $0.lastTouchedAt < $1.lastTouchedAt }
                .prefix(Self.maximumDeskRuminations - 1)) + carried).sorted {
                if $0.lastTouchedAt != $1.lastTouchedAt { return $0.lastTouchedAt < $1.lastTouchedAt }
                return $0.id < $1.id
            }, confirmedClosures: closures, at: now)
        // The heal rides the same drain the seed lane uses.
        await drainRuminationReleasesIntoSubstrate()
    }

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
            let ready = readyByTime[context.now] ?? Set(MyQueueReady.ready(items: candidates, context: context).map(\.handle))
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

    /// The moments half. `MemoryMoments.ruminationCandidates` owns the whole
    /// rule (admission, healing, window) and is pure; this only reads her own
    /// store and maps into the payload-free shape. A read failure yields an
    /// empty half, never a fabricated one — and never disturbs the Desk half.
    func momentRuminations(
        at now: Date, priorIDs: Set<String>
    ) async -> (items: [CognitiveSubstrate.CognitiveExternalRumination], closedIDs: Set<String>) {
        guard let moments = try? await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).listMemory(
            kind: MemoryMoments.kind
        ) else { return ([], []) }
        let candidates = MemoryMoments.ruminationCandidates(
            from: moments,
            now: now,
            limit: moments.count
        )
        let expiry = candidates.map { Self.afterInclusiveBoundary($0.occurredAt.addingTimeInterval(MemoryMoments.ruminationWindow)) }
            .filter { $0 > now }.min()
        if let expiry { sourceWakes.pursuitNextAt = min(sourceWakes.pursuitNextAt ?? expiry, expiry) }
        let currentIDs = Set(candidates.map(\.id))
        let closedIDs = Set(priorIDs.filter { $0.hasPrefix("moment:") }).subtracting(currentIDs)
        let recordsByID = Dictionary(moments.map { ("moment:" + $0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = candidates.compactMap { candidate -> CognitiveSubstrate.CognitiveExternalRumination? in
            guard let record = recordsByID[candidate.id],
                  let disclosure = MemoryRecordDisclosurePolicy.classify(record) else { return nil }
            return CognitiveSubstrate.CognitiveExternalRumination(
                id: candidate.id,
                label: candidate.label,
                lastTouchedAt: candidate.occurredAt,
                permittedSurfaces: disclosure.permittedSurfaces
            )
        }.prefix(Self.maximumMomentRuminations)
        return (Array(items), closedIDs)
    }

    /// Desk touch stamps are ISO-8601, with or without fractional seconds.
    static func deskDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: trimmed)
    }
}
