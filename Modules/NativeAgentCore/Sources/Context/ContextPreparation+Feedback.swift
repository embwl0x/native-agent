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
        if let feedbackRestoreFailure { throw ContextFlowStoreError.malformedStoredValue(feedbackRestoreFailure) }
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
            return snapshot
        } catch {
            lastError = "Context feedback could not be reduced; repair its saved events before preparing another turn: \(error)"
            diagnostics("[context-flow] \(lastError ?? "")")
            throw error
        }
    }

    /// Rest needs proof that this delivery is in this conversation's retained
    /// exchanges. Older events still train global reachability, never local rest.
    func servedTurnsAgo(sessionID: String?, recentExchanges: [[String]]) -> [ContextAtomID: Int] {
        guard let sessionID else { return [:] }
        var distances: [String: Int] = [:]
        for (distance, words) in recentExchanges.reversed().enumerated() {
            for text in words {
                let fingerprint = ContextStableID.digest(parts: [text])
                if distances[fingerprint] == nil { distances[fingerprint] = distance }
            }
        }
        var result: [ContextAtomID: Int] = [:]
        let deliveries = feedbackEvents.reversed().filter { $0.signal == .selection && $0.sessionID == sessionID }
        for event in deliveries {
            guard let fingerprint = event.historyMessageFingerprint, let distance = distances[fingerprint] else { continue }
            for id in event.atomIDs { result[id] = min(result[id] ?? distance, distance) }
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
        feedbackRestoreFailure = "Context feedback restoration is in progress."
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
            feedbackRestoreFailure = nil
        } catch {
            guard isCurrent(lifecycleID) else { return }
            lastError = "context feedback restore failed: \(error)"
            feedbackRestoreFailure = lastError
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
