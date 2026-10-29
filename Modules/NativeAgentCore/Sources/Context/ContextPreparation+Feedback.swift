import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import TrustCenter
import CryptoKit
import GRDB
import PersonaEngine
// Blueprint: | `ContextPreparation+Feedback.swift` | Ordered advisory feedback persistence and replay; cache matches generation, event ordinal and decay bucket; retained delivery evidence alone grants conversation-local rest |

extension ContextPreparation {
    func feedbackSnapshot(
        for generation: ContextStoredGeneration
    ) throws -> ContextFeedbackSnapshot {
        let bucket = try Self.feedbackTimeBucket()
        if let cachedFeedback, cachedFeedback.generationID == generation.generation.id,
           cachedFeedback.feedbackOrdinal == feedbackOrdinal,
           cachedFeedback.timeBucket == bucket {
            return cachedFeedback.snapshot
        }
        // The reducer requires one seed per atom ID.
        var seenSeedIDs: Set<ContextAtomID> = []
        let seeds = try generation.atoms.compactMap { atom -> ContextFeedbackSeed? in
            guard seenSeedIDs.insert(atom.draft.id).inserted else { return nil }
            return ContextFeedbackSeed(
                atomID: atom.draft.id,
                baseUtility: atom.draft.recentUsefulness,
                baseActivation: atom.draft.activation,
                baseDecay: atom.draft.decayState,
                createdBucket: try Self.feedbackTimeBucket(atom.draft.freshness.createdAt ?? atom.draft.freshness.updatedAt)
            )
        }
        let validIDs = Set(seeds.map(\.atomID))
        let applicable = feedbackEvents.compactMap { event -> ContextFeedbackEvent? in
            let retained = event.atomIDs.filter(validIDs.contains)
            guard !retained.isEmpty else { return nil }
            return ContextFeedbackEvent(
                id: event.id,
                atomIDs: retained,
                signal: event.signal,
                timeBucket: event.timeBucket,
                evidenceIDs: event.evidenceIDs,
                sessionID: event.sessionID,
                historyMessageFingerprint: event.historyMessageFingerprint
            )
        }
        do {
            let snapshot = try feedbackReducer.rebuild(seeds: seeds, events: applicable, through: bucket)
            cachedFeedback = (generation.generation.id, feedbackOrdinal, bucket, snapshot)
            publishedFeedback = snapshot
            return snapshot
        } catch {
            // The published feedback stands and the failed update is the
            // receipt; nothing is rebuilt without the retained events, and
            // nothing is cached, so the next turn tries the update again.
            lastError = "a context feedback update could not be applied; the last published feedback stands: \(error)"
            diagnostics("[context-flow] \(lastError ?? "")")
            return publishedFeedback ?? ContextFeedbackSnapshot(states: [])
        }
    }

    /// Rest needs proof that this delivery is in this conversation's retained
    /// words. Older events still train global reachability, never local rest.
    func servedTurnsAgo(sessionID: String?, recentTurns: [String]) -> [ContextAtomID: Int] {
        guard let sessionID else { return [:] }
        let fingerprints = Set(recentTurns.map { ContextStableID.digest(parts: [$0]) })
        var result: [ContextAtomID: Int] = [:]
        let deliveries = feedbackEvents.reversed().filter { $0.signal == .selection && $0.sessionID == sessionID }
        for (distance, event) in deliveries.enumerated() {
            guard let fingerprint = event.historyMessageFingerprint, fingerprints.contains(fingerprint) else { continue }
            for id in event.atomIDs where result[id] == nil { result[id] = distance }
        }
        return result
    }

    func recordFeedback(
        signal: ContextFeedbackSignal,
        atomIDs: [ContextAtomID],
        evidenceIDs: [String],
        generationID: Int64,
        sessionID: String?,
        historyMessageFingerprint: String
    ) async {
        let ids = Array(Set(atomIDs)).sorted()
        guard !ids.isEmpty else { return }
        feedbackOrdinal &+= 1
        do {
            let bucket = try Self.feedbackTimeBucket()
            let event = ContextFeedbackEvent(
                id: ContextStableID.digest(parts: [
                    "context-feedback-v1",
                    String(generationID),
                    String(feedbackOrdinal),
                    Self.feedbackSignalName(signal),
                ] + ids.map(\.rawValue) + evidenceIDs.sorted()),
                atomIDs: ids,
                signal: signal,
                timeBucket: bucket,
                evidenceIDs: evidenceIDs,
                sessionID: sessionID,
                historyMessageFingerprint: historyMessageFingerprint
            )
            try await store.recordFeedbackEvent(event)
            feedbackEvents.append(event)
            cachedFeedback = nil
            if feedbackEvents.count > 4_096 {
                feedbackEvents.removeFirst(feedbackEvents.count - 4_096)
            }
        } catch {
            // Context feedback is advisory, but a failed write must not look
            // like a healthy restart that merely learned nothing.
            lastError = "context feedback persistence failed: \(error)"
            diagnostics("[context-flow] \(lastError ?? "context feedback persistence failed")")
            return
        }
    }

    func restoreFeedbackEvents() async {
        let lifecycleID = self.lifecycleID
        cachedFeedback = nil
        do {
            let restored = try await store.recentFeedbackEvents(limit: 4_096)
            guard isCurrent(lifecycleID) else { return }
            // Event IDs are ordinal-scoped. Retaining the current high-water
            // mark prevents a relaunch from overwriting a retained event.
            let ordinal = try await store.feedbackEventOrdinalHighWaterMark()
            guard isCurrent(lifecycleID) else { return }
            feedbackEvents = restored
            feedbackOrdinal = ordinal
            cachedFeedback = nil
        } catch {
            guard isCurrent(lifecycleID) else { return }
            lastError = "context feedback restore failed: \(error)"
            diagnostics("[context-flow] \(lastError ?? "context feedback restore failed")")
        }
    }

    /// Test-session feedback must not train the ranker.
    static func isTestSession(_ sessionID: String?) -> Bool {
        guard let id = sessionID?.lowercased() else { return false }
        return ["bench", "walk", "drive", "test"].contains { id.contains($0) }
    }

    private static func feedbackTimeBucket(_ date: Date = Date()) throws -> Int64 {
        let bucket = (date.timeIntervalSince1970 / 300).rounded(.towardZero)
        guard let value = Int64(exactly: bucket) else {
            throw ContextFlowStoreError.malformedStoredValue("feedback date outside bucket range")
        }
        return value
    }

    private static func feedbackSignalName(_ signal: ContextFeedbackSignal) -> String {
        switch signal {
        case .selection: "selection"
        case .expansion: "expansion"
        case .correction(.confirms): "correction.confirms"
        case .correction(.contradicts): "correction.contradicts"
        case .retry: "retry"
        case .outcome(.completed): "outcome.completed"
        case .outcome(.confirmed): "outcome.confirmed"
        case .outcome(.contradicted): "outcome.contradicted"
        case .outcome(.abandoned): "outcome.abandoned"
        }
    }

}
