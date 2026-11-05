import ChatTurnContracts
import CognitiveSubstrate
import Desk
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
import TurnTrace

// Blueprint: | `AdaptiveMemoryPromises.swift` | `AdaptiveMemoryPromoter.applyPromises`: reply-grounded promises under recorded turn authority |

extension AdaptiveMemoryPromoter {
    /// The same application path for a live judgment and a batch's saved meaning. No ambient reflection task or later conversation may lend a promise its
    /// origin.
    func applyPromises(_ interpretation: AfterTurnInterpretation, turn: CognitiveMomentTurn?,
                       momentID: String, dataRoot: URL, heldTurn: Turn) async -> Bool {
        guard !interpretation.promises.isEmpty else { return true }
        guard let turn else {
            nativeLog("MemoryV2: promises in moment %@ have no recorded turn; left meant", momentID)
            return false
        }
        let promises: [MemoryManagerPromise]
        do {
            promises = try MemoryManagerPromise.parse(interpretation.promises.map {
                ["words": $0.words, "when": $0.when, "source": $0.source]
            }, reply: turn.assistant)
        } catch {
            nativeLog("MemoryV2: promises in moment %@ left meant: %@", momentID, String(describing: error))
            return false
        }
        let envelope = TurnEnvelope.fromPersistedMetadata(turn.envelope)
        var sources = turn.carriedSources ?? turn.sourceCheckpoint ?? [PeerDataTaint.unrecorded]
        // Without a carried checkpoint, recorded bridge identity supplies queue.add's same-turn source.
        if turn.carriedSources == nil, PeerTurnEffectPolicy.isPeerBridge(surface: turn.surface) {
            if let id = envelope?.verifiedUserId {
                let peer = "peer:" + id
                if !sources.contains(peer) { sources.append(peer) }
            } else if sources.isEmpty { sources = ["another agent"] }
        }
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        func trace(_ status: String, id: String? = nil) {
            var payload: [String: JSONValue] = ["moment": .string(momentID), "status": .string(status)]
            if let id { payload["id"] = .string(id) }
            TurnTraceBus.fire(TurnTraceEvent(turnId: turn.turnId ?? momentID, kind: "memory.promise",
                sessionId: turn.sessionId, surface: turn.surface,
                destinationId: envelope?.replyRoute.destinationId, threadId: envelope?.replyRoute.threadId,
                payload: .object(payload), turn: heldTurn))
        }
        // Only this turn's explicit filings can explain one of its promises. Older moments without a recorded reply boundary suppress nothing.
        var filed: [MyQueue.Entry] = []
        if let start = turn.occurredAt, let end = turn.repliedAt, start <= end {
            do {
                filed = MyQueue.entries(try await store.liveState()).filter { entry in
                    entry.step.session == turn.sessionId && entry.step.source == nil
                        && (entry.step.filedAt.flatMap(DeskClock.parseISO).map { $0 >= start && $0 <= end } ?? false)
                }
            } catch {
                trace("failed")
                return false
            }
        }
        var settled = true
        for promise in promises {
            guard !Task.isCancelled else { return false }
            if let entry = filed.first(where: { Self.keptPromise(promise, by: $0.step) }) {
                trace("already_queued", id: entry.name)
                continue
            }
            guard let when = MyQueue.When(promise.when) else { return false }
            do {
                let queued = try await MyQueue.add(DeskStep(words: promise.words, when: when.stored,
                    card: when.card, source: promise.source, peers: sources,
                    elevated: turn.elevatedSources ?? [], session: turn.sessionId,
                    origin: turn.originPrincipal, replyRoute: turn.envelope), store: store)
                trace(queued.change.rawValue, id: queued.entry.name)
            } catch is MyQueue.Full {
                trace("skipped_full")
            } catch {
                settled = false
                trace("failed")
                nativeLog("MemoryV2: promise in moment %@ could not be queued: %@", momentID, error.localizedDescription)
            }
        }
        return settled
    }

    private static func keptPromise(_ promise: MemoryManagerPromise, by step: DeskStep) -> Bool {
        let filler: Set<String> = ["i", "i'll", "ill", "i've", "ive", "will", "would", "have", "has", "had",
            "the", "a", "an", "to", "of", "for", "and", "or", "in", "on", "at", "it", "this", "that",
            "you", "your", "me", "my", "be", "been", "is", "as", "with", "do", "up"]
        func content(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }
                .map(String.init)).subtracting(filler)
        }
        let queued = content(step.words), promised = content(promise.words)
        guard !queued.isEmpty, !promised.isEmpty else { return false }
        func most(_ a: Set<String>, _ b: Set<String>) -> Bool {
            a.intersection(b).count * 2 > a.count
        }
        if most(queued, promised) && most(promised, queued) { return true }
        // A source sentence can describe the filing rather than repeat its words.
        let source = content(promise.source)
        let filing: Set<String> = ["queued", "scheduled", "reminder", "remind", "filed", "added", "set"]
        return !source.isDisjoint(with: filing) && most(queued, source)
            && most(promised.subtracting(filing), queued.union(filing))
    }
}
