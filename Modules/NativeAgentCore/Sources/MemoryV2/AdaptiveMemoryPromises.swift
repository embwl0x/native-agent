import ChatTurnContracts
import CognitiveSubstrate
import Desk
import Experiences
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TurnTrace

// Blueprint: | `AdaptiveMemoryPromises.swift` | `AdaptiveMemoryPromoter.applyPromises`: candidate-only promise matching and saved interpretation settlements under recorded turn authority |

extension AdaptiveMemoryPromoter {
    /// Authority is the recorded speaker on this turn, wherever the words were spoken, never a conversation-kind lookup.
    static func settlementWords(_ turn: CognitiveMomentTurn) -> String {
        guard turn.originPrincipal == "person", turn.standingAgentName == nil,
              let envelope = TurnEnvelope.fromPersistedMetadata(turn.envelope), envelope.agent == nil,
              MemoryDataProvenance.author(surface: turn.surface, peer: false) == "user" else { return "" }
        return turn.asked
    }

    struct PromiseFailure: Error, Sendable {
        let cause: OwedCause?
        let words: String
    }

    /// The same application path for a live judgment and a batch's saved meaning. No ambient reflection task or later conversation may lend a promise its
    /// origin.
    func applyPromises(_ interpretation: AfterTurnInterpretation, turn: CognitiveMomentTurn?,
                       momentID: String, dataRoot: URL, heldTurn: Turn) async -> Result<Void, PromiseFailure> {
        guard let door, let moment = await door.moment(momentID) else {
            return .failure(PromiseFailure(cause: nil, words: "The recorded moment is unavailable."))
        }
        var matchingBasis: OwedBasis?
        var deskBasis: OwedBasis?
        var saved: RecoveryCheckpoint
        do {
            saved = try checkpoint(moment)
        } catch {
            oweRecoveryRepair(momentID, cause: error.localizedDescription, door: door)
            return .failure(PromiseFailure(cause: nil, words: error.localizedDescription))
        }
        func failed(_ words: String, owner: String = "LivedMomentDoor", cause: OwedCause? = nil, wait: Bool = true)
            async -> Result<Void, PromiseFailure> {
            guard !Task.isCancelled else { return .failure(PromiseFailure(cause: nil, words: words)) }
            if wait, let cause {
                let basis: OwedBasis?
                switch cause {
                case .provider: basis = matchingBasis
                case .desk: basis = deskBasis
                case .record: basis = await readBasis(moment, cause: .record, door: door)
                default: basis = nil
                }
                await waitForChange(momentID, since: basis, cause: cause, words: words)
            }
            RepairOwed.owe(dataRoot, id: "memory-promise:" + momentID, kind: .act,
                operation: "memory.promise:" + momentID, owner: owner,
                words: "The promise and settlement judgment for moment \(momentID) remains owed: \(words)")
            return .failure(PromiseFailure(cause: cause, words: words))
        }
        guard let turn else {
            return await failed("No recorded turn supplies their authority.", cause: .record)
        }
        guard (saved.captures == nil) == (saved.identities == nil) else {
            return await failed("The retained matching judgment and its candidate identities are incomplete.", wait: false)
        }
        let envelope = TurnEnvelope.fromPersistedMetadata(turn.envelope)
        let personWords = Self.settlementWords(turn)
        guard !interpretation.promises.isEmpty || !interpretation.settled.isEmpty || saved.captures != nil else {
            return .success(())
        }
        let promises = interpretation.promises
        do {
            for promise in promises { try promise.validate(reply: turn.assistant) }
        } catch {
            return await failed(error.localizedDescription, owner: "MemoryManagerPromise", cause: .record)
        }
        guard let sources = turn.carriedSources else {
            return await failed("No recorded carriedSources provenance supplies their authority; repair the recorded turn.", cause: .record)
        }
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        func trace(_ status: String, id: String? = nil, reason: String? = nil) {
            var payload: [String: JSONValue] = ["moment": .string(momentID), "status": .string(status)]
            if status == "matching" {
                payload["basis"] = .object([
                    "route": (matchingBasis?.route).map(JSONValue.string) ?? .null,
                    "answered": (matchingBasis?.answered).map(JSONValue.string) ?? .null,
                ])
            }
            if let id { payload["id"] = .string(id) }
            if let reason { payload["reason"] = .string(reason) }
            TurnTraceBus.fire(TurnTraceEvent(turnId: turn.turnId ?? momentID, kind: "memory.promise",
                sessionId: turn.sessionId, surface: turn.surface,
                destinationId: envelope?.replyRoute.destinationId, threadId: envelope?.replyRoute.threadId,
                payload: .object(payload), turn: heldTurn))
        }
        let open: [DeskItem]
        let terminal: [DeskItem]
        let archived: [ArchiveRecord]
        let landed: Set<String>
        if saved.captures == nil, !promises.isEmpty { deskBasis = await readBasis(moment, cause: .desk, door: door) }
        do {
            let state = try await store.liveState()
            archived = try await store.archivedRecords()
            open = state.items.filter(MyQueue.carries)
            terminal = state.items.filter { $0.status.isTerminal }
            let refs = state.items.flatMap(\.refs) + archived.flatMap(\.refs)
            landed = Set(refs.flatMap { ref -> [String] in
                if case .step(let step) = ref.kind { return step.promiseCaptures }; return []
            })
        } catch {
            if Self.isCancellation(error) {
                return .failure(PromiseFailure(cause: nil, words: "The Desk read was cancelled; the work remains due."))
            }
            trace("failed")
            return await failed(error.localizedDescription, owner: "MyQueue", cause: .desk,
                                wait: saved.captures == nil && !promises.isEmpty)
        }
        let pending = promises.enumerated().filter { !landed.contains(MyQueue.promiseCaptureID(moment: momentID, candidate: $0.offset)) }
        guard saved.captures != nil || !pending.isEmpty || !interpretation.settled.isEmpty else {
            trace("already_captured")
            RepairOwed.settle(dataRoot, operation: "memory.promise:" + momentID,
                evidence: .init(source: "desk/desk_ops.jsonl", id: momentID))
            return .success(())
        }
        let identities: [String]
        let captures: [MemoryManagerPromiseCapture]
        if let kept = saved.captures, let ids = saved.identities {
            captures = kept
            identities = ids
        } else {
            identities = pending.map { MyQueue.promiseCaptureID(moment: momentID, candidate: $0.offset) }
            let matched: [MemoryManagerPromiseCapture]
            if pending.isEmpty { matched = [] }
            else {
                guard let memoryManager else { return await failed("The promise judgment is unavailable.") }
                matchingBasis = await readBasis(moment, cause: .provider, door: door)
                do {
                    trace("matching")
                    matched = try await memoryManager.capturePromises(pending.map(\.element), reply: turn.assistant,
                        open: open, call: LLMCall(turn: heldTurn, surface: turn.surface, purpose: "memory_promise"))
                    let settledIDs = Set(interpretation.settled.map(\.id))
                    guard !matched.contains(where: {
                        if case .keep(_, let target?, _) = $0 { return settledIDs.contains(target) }; return false
                    }) else { throw ToolFailureError("A promise capture cannot refile a moment settled by this interpretation.", effects: .none) }
                } catch {
                    if Self.isCancellation(error) {
                        return .failure(PromiseFailure(cause: nil, words: "Promise matching was cancelled."))
                    }
                    trace("failed")
                    return await failed(error.localizedDescription, owner: "MemoryManagerPromise", cause: .provider)
                }
                await answered(momentID, route: matchingBasis?.route, door: door)
            }
            captures = matched + interpretation.settled.map { .settled(id: $0.id, updatedAt: $0.updatedAt, source: $0.source) }
            saved.captures = captures
            saved.identities = identities
            saved.wait = nil
        }
        let produced = saved
        let write: Result<Void, Error> = await settle {
            do { try await self.keepCheckpoint(momentID, produced, door: door); return .success(()) }
            catch { return .failure(error) }
        }
        if case .failure(let error) = write {
            if Self.isCancellation(error) { return .failure(PromiseFailure(cause: nil, words: error.localizedDescription)) }
            return await failed(error.localizedDescription, wait: false)
        }
        guard !Task.isCancelled else {
            return .failure(PromiseFailure(cause: nil, words: "Promise filing was cancelled; the judgment is retained for the next drain."))
        }
        var filings: [MyQueue.PromiseFiling] = []
        var failure: PromiseFailure?
        for capture in captures {
            switch capture {
            case .ignore: trace("ignored")
            case .settled(let id, let updatedAt, let source):
                guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, personWords.contains(source) else {
                    return await failed("A retained settlement has no exact quote from this turn's person_words.", cause: .record)
                }
                let why = "Settled from the person's words in this turn (" + momentID + "): \"" + source + "\""
                do {
                    if let item = terminal.first(where: { $0.handle == id && $0.status == .done && $0.summary == why }) {
                        guard let step = item.step else { throw ToolFailureError("The settled row has no saved step.", effects: .none) }
                        try MyQueue.releaseFinishedRun(words: step.words, store: store)
                        trace("already_settled", id: "desk." + item.alias, reason: why)
                    } else if let item = archived.first(where: { $0.handle == id && $0.finalStatus == .done && $0.summary == why }) {
                        guard let words = item.refs.compactMap({ ref -> String? in
                            if case .step(let step) = ref.kind { return step.words }; return nil
                        }).last else { throw ToolFailureError("The settled archive has no saved step.", effects: .none) }
                        try MyQueue.releaseFinishedRun(words: words, store: store)
                        trace("already_settled", id: id, reason: why)
                    } else {
                        guard let item = open.first(where: { $0.handle == id }), item.updatedAt == updatedAt,
                              let entry = MyQueue.entry(item) else { throw MyQueue.Superseded() }
                        if let conflict = try await store.runHold(id) {
                            throw ToolFailureError(try conflict.refusal(entry.name).serialize(pretty: false), effects: .none)
                        }
                        try await MyQueue.finish(entry, dropped: false, why: why, store: store)
                        trace("settled", id: entry.name, reason: why)
                    }
                } catch {
                    failure = PromiseFailure(cause: .desk, words: error.localizedDescription)
                    trace("failed", id: id)
                    _ = await failed(error.localizedDescription, owner: "MyQueue", cause: .desk, wait: false)
                }
            case .keep(let promise, let target, let candidates):
                guard let when = MyQueue.When(promise.when) else { return await failed("The promise has no valid time: \(promise.when).", wait: false) }
                let captureIDs = candidates.compactMap { identities.indices.contains($0) ? identities[$0] : nil }
                guard captureIDs.count == candidates.count else { return await failed("The promise judgment named an unknown candidate.", wait: false) }
                if captureIDs.allSatisfy(landed.contains) { continue }
                filings.append(.init(target: target,
                    step: DeskStep(words: promise.words, when: when.stored, card: when.card, source: promise.source, peers: sources,
                        elevated: turn.elevatedSources ?? [], session: turn.sessionId,
                        origin: turn.originPrincipal, replyRoute: turn.envelope, promiseCaptures: captureIDs)))
            }
        }
        do {
            let results: [Result<MyQueue.PromiseLanding, Error>]
            if filings.isEmpty { results = [] }
            else { results = try await MyQueue.capture(filings, store: store) }
            for result in results {
                switch result {
                case .success(let landing): trace(landing.change.rawValue, id: landing.id)
                case .failure(let error):
                    failure = PromiseFailure(cause: .desk, words: error.localizedDescription)
                    trace("failed")
                    _ = await failed(error.localizedDescription, owner: "MyQueue", cause: .desk, wait: false)
                }
            }
        } catch {
            if Self.isCancellation(error) {
                return .failure(PromiseFailure(cause: nil, words: "Promise filing was cancelled; the retained judgment remains due."))
            }
            trace("failed")
            return await failed(error.localizedDescription, owner: "MyQueue", cause: .desk, wait: false)
        }
        if failure == nil {
            RepairOwed.settle(dataRoot, operation: "memory.promise:" + momentID,
                evidence: .init(source: "cognition/cognition.sqlite", id: momentID))
        }
        if let failure { return .failure(failure) }
        return .success(())
    }
}
