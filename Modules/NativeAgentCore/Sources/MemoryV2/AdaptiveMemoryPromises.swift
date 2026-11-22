import ChatTurnContracts
import CognitiveSubstrate
import Desk
import Experiences
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TurnTrace

// Blueprint: | `AdaptiveMemoryPromises.swift` | `AdaptiveMemoryPromoter`: which turns are moments and of what share, turn-owned completed acts, promise matching and evidence-backed closure |

extension AdaptiveMemoryPromoter {
    /// Read this turn's completed receipts so far, including nested calls; dispatch closure is not required.
    static func completedActs(_ turn: CognitiveMomentTurn, dataRoot: URL) async throws -> [MemoryManagerAct] {
        guard let id = turn.turnId, !id.isEmpty else {
            throw ToolFailureError("The recorded turn has no id for its act evidence; repair its input.", effects: .none)
        }
        let read = try await TurnTracePersistLane(dataRootOverride: dataRoot).events(
            .init(subjects: [id], kinds: ["tool.dispatch"]))
        var acts: [MemoryManagerAct] = []
        var seen: Set<String> = []
        for event in read.events where event.kind == "tool.dispatch" {
            guard let payload = event.payload.objectValue, payload["phase"] == .string("end"),
                  payload["status"] == .string("ok"), let receipt = payload["receipt"]?.objectValue,
                  receipt["resultClass"] == .string("succeeded"), receipt["preview"] == .bool(false),
                  let actID = receipt["id"]?.stringValue, let action = receipt["action"]?.stringValue,
                  seen.insert(actID).inserted else { continue }
            var record: [String: JSONValue] = ["id": .string(actID), "action": .string(action),
                "status": .string("ok"), "result_class": .string("succeeded")]
            record["arguments"] = payload["args"]
            record["receipt"] = receipt["resultReceipt"]
            if let result = payload["result"]?.stringValue {
                record["result"] = .string(String(result.prefix(1024)))
                record["result_shortened"] = .bool(result.count > 1024)
            }
            acts.append(MemoryManagerAct(id: actID, record: .object(record)))
        }
        if read.unreadable > 0 {
            TurnTraceBus.fire(TurnTraceEvent(turnId: id, kind: "memory.promise.evidence", sessionId: turn.sessionId,
                surface: turn.surface, payload: .object(["unreadable": .int(Int64(read.unreadable)),
                    "reason": .string("Unreadable act details cannot settle promises; readable siblings remain evidence.")]), turn: nil))
        }
        return acts
    }

    /// What share of the after-turn judgment a moment has: whole (meaning, cares, facts, promises and settlement) or settlement alone.
    enum MomentShare: Sendable { case whole, settlement }

    /// A turn is judged after it ends when it could have settled something, whoever started it: a person's words, a completed act, or a reply
    /// that reached a person, while moments are open. A turn with an incoming message from someone, and a care wake, are judged whole. Any other
    /// turn (her own work, or a turn with no incoming row: a return, an approval continuation, an ephemeral turn) has no person's words and no
    /// reply evidence, so only a completed act while a MY QUEUE moment is open can settle anything: it is judged for settlement alone, and
    /// otherwise it is not a moment. Recording asks this of the turn; judgment asks it of the recorded share. `settles` is read only when not whole.
    func share(whole: Bool, settles: () async -> Bool) async -> MomentShare? {
        guard !whole else { return .whole }
        return await settles() ? .settlement : nil
    }

    /// Whether the turn completed an act (as `completedActs` reads it) while a MY QUEUE moment was open. Its dispatch receipts are flushed before
    /// they are read. An unavailable read supplies no evidence, as it does in the judgment.
    func actedWhileOpen(_ turn: CognitiveMomentTurn, dataRoot: URL) async -> Bool {
        do {
            if let id = turn.turnId { try await (TurnTraceContext.bus ?? .shared).flush(turnId: id) }
            guard !(try await Self.completedActs(turn, dataRoot: dataRoot)).isEmpty else { return false }
            return try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items.contains { MyQueue.entry($0) != nil }
        } catch {
            TurnTraceBus.fire(TurnTraceEvent(turnId: turn.turnId ?? turn.sessionId, kind: "memory.promise.evidence",
                sessionId: turn.sessionId, surface: turn.surface,
                payload: .object(["unavailable": .string(error.localizedDescription)]), turn: nil))
            return false
        }
    }

    /// Authority is the recorded speaker on this turn, wherever the words were spoken, never a conversation-kind lookup.
    static func settlementWords(_ turn: CognitiveMomentTurn) -> String {
        guard turn.originPrincipal == "person", turn.standingAgentName == nil,
              let envelope = TurnEnvelope.fromPersistedMetadata(turn.envelope), envelope.agent == nil,
              MemoryDataProvenance.author(surface: turn.surface, peer: false) == "user" else { return "" }
        return turn.asked
    }

    /// The agent's reply on this turn reached a person: spoken (not a chosen silence or a failed turn) on a local route, where saving the reply
    /// is delivering it (a surface that posts afterwards, such as Slack, Telegram or the phone, has no delivered fact here yet), in a conversation
    /// with people (not its own stream or a peer's), answering the person or its own moment rather than a peer or a standing agent.
    func replyDelivered(_ turn: CognitiveMomentTurn) async -> Bool {
        guard turn.repliedAt != nil, !turn.assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              turn.standingAgentName == nil, turn.originPrincipal == "person" || turn.originPrincipal == "self",
              let envelope = TurnEnvelope.fromPersistedMetadata(turn.envelope),
              AgentBridgeCompletionRoute.Kind(surface: envelope.replyRoute.surface) == .local,
              let kind = await conversationKind(turn.sessionId) else { return false }
        return kind == .direct || kind == .channel
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
        let work = PromiseWork(momentID: momentID, dataRoot: dataRoot, heldTurn: heldTurn, door: door, moment: moment)
        let prepared = await preparePromiseFiling(interpretation, turn: turn, work: work)
        switch prepared {
        case .failure(let failure): return .failure(failure)
        case .success(nil): return .success(())
        case .success(let plan?):
            switch await settlePromiseCaptures(plan, work: work) {
            case .failure(let failure): return .failure(failure)
            case .success(let (filings, failure)):
                return await filePromiseCaptures(filings, after: failure, plan: plan, work: work)
            }
        }
    }

    private final class PromiseWork {
        let momentID: String
        let dataRoot: URL
        let heldTurn: Turn
        let door: LivedMomentDoor
        let moment: CognitiveLivedMoment
        var matchingBasis: OwedBasis?
        var deskBasis: OwedBasis?

        init(momentID: String, dataRoot: URL, heldTurn: Turn, door: LivedMomentDoor, moment: CognitiveLivedMoment) {
            self.momentID = momentID
            self.dataRoot = dataRoot
            self.heldTurn = heldTurn
            self.door = door
            self.moment = moment
        }
    }

    private struct PromiseFilingPlan {
        let turn: CognitiveMomentTurn
        let envelope: TurnEnvelope?
        let personWords: String
        let sources: [String]
        let store: SwiftNativeDeskStore
        let open: [DeskItem]
        let terminal: [DeskItem]
        let archived: [ArchiveRecord]
        let landed: Set<String>
        let identities: [String]
        let captures: [MemoryManagerPromiseCapture]
    }

    private func promiseFailure(_ words: String, work: PromiseWork, owner: String = "LivedMomentDoor", cause: OwedCause? = nil,
                                wait: Bool = true) async -> PromiseFailure {
        let (momentID, dataRoot, door, moment) = (work.momentID, work.dataRoot, work.door, work.moment)
        guard !Task.isCancelled else { return PromiseFailure(cause: nil, words: words) }
        if wait, let cause {
            let basis: OwedBasis?
            switch cause {
            case .provider: basis = work.matchingBasis
            case .desk: basis = work.deskBasis
            case .record: basis = await readBasis(moment, cause: .record, door: door)
            default: basis = nil
            }
            await waitForChange(momentID, since: basis, cause: cause, words: words)
        }
        RepairOwed.owe(dataRoot, id: "memory-promise:" + momentID, kind: .act,
            operation: "memory.promise:" + momentID, owner: owner,
            words: "The promise and settlement judgment for moment \(momentID) remains owed: \(words)")
        return PromiseFailure(cause: cause, words: words)
    }

    private func tracePromise(_ status: String, work: PromiseWork, turn: CognitiveMomentTurn, envelope: TurnEnvelope?,
                              id: String? = nil, reason: String? = nil, basis: String? = nil) {
        let (momentID, heldTurn) = (work.momentID, work.heldTurn)
        var payload: [String: JSONValue] = ["moment": .string(momentID), "status": .string(status)]
        if status == "matching" {
            payload["basis"] = .object([
                "route": (work.matchingBasis?.route).map(JSONValue.string) ?? .null,
                "answered": (work.matchingBasis?.answered).map(JSONValue.string) ?? .null,
            ])
        }
        if let id { payload["id"] = .string(id) }
        if let reason { payload["reason"] = .string(reason) }
        if let basis { payload["basis"] = .string(basis) }
        TurnTraceBus.fire(TurnTraceEvent(turnId: turn.turnId ?? momentID, kind: "memory.promise",
            sessionId: turn.sessionId, surface: turn.surface,
            destinationId: envelope?.replyRoute.destinationId, threadId: envelope?.replyRoute.threadId,
            payload: .object(payload), turn: heldTurn))
    }

    private func preparePromiseFiling(_ interpretation: AfterTurnInterpretation, turn: CognitiveMomentTurn?, work: PromiseWork) async
        -> Result<PromiseFilingPlan?, PromiseFailure> {
        let (momentID, dataRoot, heldTurn, door, moment) = (work.momentID, work.dataRoot, work.heldTurn, work.door, work.moment)
        var saved: RecoveryCheckpoint
        do {
            saved = try checkpoint(moment)
        } catch {
            oweRecoveryRepair(momentID, cause: error.localizedDescription, door: door)
            return .failure(PromiseFailure(cause: nil, words: error.localizedDescription))
        }
        guard let turn else {
            return .failure(await promiseFailure("No recorded turn supplies their authority.", work: work, cause: .record))
        }
        guard (saved.captures == nil) == (saved.identities == nil) else {
            return .failure(await promiseFailure("The retained matching judgment and its candidate identities are incomplete.", work: work, wait: false))
        }
        let envelope = TurnEnvelope.fromPersistedMetadata(turn.envelope)
        let personWords = Self.settlementWords(turn)
        guard !interpretation.promises.isEmpty || !interpretation.settled.isEmpty || saved.captures != nil else {
            return .success(nil)
        }
        let promises = interpretation.promises
        do {
            for promise in promises { try promise.validate(reply: turn.assistant) }
        } catch {
            return .failure(await promiseFailure(error.localizedDescription, work: work, owner: "MemoryManagerPromise", cause: .record))
        }
        guard let sources = turn.carriedSources else {
            return .failure(await promiseFailure("No recorded carriedSources provenance supplies their authority; repair the recorded turn.", work: work, cause: .record))
        }
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let open: [DeskItem]
        let terminal: [DeskItem]
        let archived: [ArchiveRecord]
        let landed: Set<String>
        if saved.captures == nil, !promises.isEmpty { work.deskBasis = await readBasis(moment, cause: .desk, door: door) }
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
            tracePromise("failed", work: work, turn: turn, envelope: envelope, reason: error.localizedDescription)
            return .failure(await promiseFailure(error.localizedDescription, work: work, owner: "MyQueue", cause: .desk,
                                wait: saved.captures == nil && !promises.isEmpty))
        }
        let pending = promises.enumerated().filter { !landed.contains(MyQueue.promiseCaptureID(moment: momentID, candidate: $0.offset)) }
        guard saved.captures != nil || !pending.isEmpty || !interpretation.settled.isEmpty else {
            tracePromise("already_captured", work: work, turn: turn, envelope: envelope)
            RepairOwed.settle(dataRoot, operation: "memory.promise:" + momentID,
                evidence: .init(source: "desk/desk_ops.jsonl", id: momentID))
            return .success(nil)
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
                guard let memoryManager else { return .failure(await promiseFailure("The promise judgment is unavailable.", work: work)) }
                work.matchingBasis = await readBasis(moment, cause: .provider, door: door)
                do {
                    tracePromise("matching", work: work, turn: turn, envelope: envelope)
                    let proposed = try await memoryManager.capturePromises(pending.map(\.element), reply: turn.assistant,
                        open: open, call: LLMCall(turn: heldTurn, surface: turn.surface, purpose: "memory_promise"))
                    // The settlement is read first: a capture that would refile an item this same interpretation settles is answered by that
                    // settlement and files nothing. Refusing it failed the moment, and every drain matched again and failed the same way.
                    let settledIDs = Set(interpretation.settled.map(\.id))
                    matched = proposed.map { capture in
                        guard case .keep(_, let target?, _) = capture, settledIDs.contains(target) else { return capture }
                        tracePromise("settled_by_interpretation", work: work, turn: turn, envelope: envelope, id: target)
                        return .ignore
                    }
                } catch {
                    if Self.isCancellation(error) {
                        return .failure(PromiseFailure(cause: nil, words: "Promise matching was cancelled."))
                    }
                    tracePromise("failed", work: work, turn: turn, envelope: envelope, reason: error.localizedDescription)
                    return .failure(await promiseFailure(error.localizedDescription, work: work, owner: "MemoryManagerPromise", cause: .provider))
                }
                await answered(momentID, route: work.matchingBasis?.route, door: door)
            }
            captures = matched + interpretation.settled.map { .settled($0) }
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
            return .failure(await promiseFailure(error.localizedDescription, work: work, wait: false))
        }
        guard !Task.isCancelled else {
            return .failure(PromiseFailure(cause: nil, words: "Promise filing was cancelled; the judgment is retained for the next drain."))
        }
        return .success(PromiseFilingPlan(turn: turn, envelope: envelope, personWords: personWords, sources: sources,
            store: store, open: open, terminal: terminal, archived: archived, landed: landed, identities: identities, captures: captures))
    }

    private func settlePromiseCaptures(_ plan: PromiseFilingPlan, work: PromiseWork) async
        -> Result<([MyQueue.PromiseFiling], PromiseFailure?), PromiseFailure> {
        let (momentID, dataRoot) = (work.momentID, work.dataRoot)
        let (turn, envelope, personWords, sources, store) = (plan.turn, plan.envelope, plan.personWords, plan.sources, plan.store)
        let (open, terminal, archived, landed, identities, captures) = (plan.open, plan.terminal, plan.archived, plan.landed, plan.identities, plan.captures)
        var filings: [MyQueue.PromiseFiling] = []
        var failure: PromiseFailure?
        var actEvidence: Result<[MemoryManagerAct], Error>?
        for capture in captures {
            switch capture {
            case .ignore: tracePromise("ignored", work: work, turn: turn, envelope: envelope)
            case .settled(let settlement):
                let id = settlement.id, updatedAt = settlement.updatedAt
                let basis: String
                switch settlement.evidence {
                case .personWords(let source):
                    guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, personWords.contains(source) else {
                        return .failure(await promiseFailure("A retained settlement has no exact quote from this turn's person_words.", work: work, cause: .record))
                    }
                    basis = "person_words: \"" + source + "\""
                case .act(let actID, let source):
                    basis = "act " + actID + " (detail, turn " + (turn.turnId ?? momentID) + "): \"" + source + "\""
                case .reply(let source):
                    guard settlement.outcome == .done, MemoryManagerPromise.quoted(source, in: turn.assistant) else {
                        return .failure(await promiseFailure("A retained settlement has no exact quote from this turn's reply.", work: work, cause: .record))
                    }
                    basis = "reply: \"" + source + "\""
                }
                let dropped = settlement.outcome == .letGo
                let status: DeskStatus = dropped ? .canceled : .done
                let finalStatus: ArchiveFinalStatus = dropped ? .canceled : .done
                let why = settlement.outcome.rawValue + ": " + settlement.reason + " (" + momentID + "; " + basis + ")"
                do {
                    if let item = terminal.first(where: { $0.handle == id && $0.status == status && $0.summary == why }) {
                        try MyQueue.releaseFinishedRun(findingKey: item.findingKey, dropped: dropped, store: store)
                        tracePromise("already_settled", work: work, turn: turn, envelope: envelope, id: "desk." + item.alias, reason: why)
                    } else if let item = archived.first(where: { $0.handle == id && $0.finalStatus == finalStatus && $0.summary == why }) {
                        try MyQueue.releaseFinishedRun(findingKey: item.findingKey, dropped: dropped, store: store)
                        tracePromise("already_settled", work: work, turn: turn, envelope: envelope, id: id, reason: why)
                    } else {
                        if case .act(let actID, let source) = settlement.evidence {
                            do {
                                let reading: Result<[MemoryManagerAct], Error>
                                if let kept = actEvidence { reading = kept }
                                else {
                                    do { reading = .success(try await Self.completedActs(turn, dataRoot: dataRoot)) }
                                    catch { reading = .failure(error) }
                                    actEvidence = reading
                                }
                                let acts = try reading.get()
                                guard settlement.outcome == .done,
                                      let act = acts.first(where: { $0.id == actID }), act.contains(source) else {
                                    throw ToolFailureError("The retained completed act evidence is unavailable; work stays open.", effects: .none)
                                }
                            } catch {
                                failure = PromiseFailure(cause: .record, words: error.localizedDescription)
                                tracePromise("failed", work: work, turn: turn, envelope: envelope, id: id, reason: error.localizedDescription)
                                _ = await promiseFailure(error.localizedDescription, work: work, owner: "TurnTrace", cause: .record, wait: false)
                                continue
                            }
                        }
                        guard let item = open.first(where: { $0.handle == id }), item.updatedAt == updatedAt,
                              let entry = MyQueue.entry(item) else { throw MyQueue.Superseded() }
                        if let conflict = try await store.runHold(id) {
                            throw ToolFailureError(try conflict.refusal(entry.name).serialize(pretty: false), effects: .none)
                        }
                        try await MyQueue.finish(entry, dropped: dropped, why: why, store: store)
                        tracePromise("settled", work: work, turn: turn, envelope: envelope, id: entry.name, reason: why, basis: settlement.evidence.basis)
                    }
                } catch let error as MyQueue.Superseded {
                    tracePromise("void", work: work, turn: turn, envelope: envelope, id: id, reason: error.localizedDescription)
                    continue
                } catch {
                    failure = PromiseFailure(cause: .desk, words: error.localizedDescription)
                    tracePromise("failed", work: work, turn: turn, envelope: envelope, id: id, reason: error.localizedDescription)
                    _ = await promiseFailure(error.localizedDescription, work: work, owner: "MyQueue", cause: .desk, wait: false)
                }
            case .keep(let promise, let target, let candidates):
                guard let when = MyQueue.When(promise.when) else { return .failure(await promiseFailure("The promise has no valid time: \(promise.when).", work: work, wait: false)) }
                let captureIDs = candidates.compactMap { identities.indices.contains($0) ? identities[$0] : nil }
                guard captureIDs.count == candidates.count else { return .failure(await promiseFailure("The promise judgment named an unknown candidate.", work: work, wait: false)) }
                if captureIDs.allSatisfy(landed.contains) { continue }
                filings.append(.init(target: target,
                    step: DeskStep(words: promise.words, when: when.stored, card: when.card, source: promise.source, peers: sources,
                        elevated: turn.elevatedSources ?? [], session: turn.sessionId,
                        origin: turn.originPrincipal, replyRoute: turn.envelope, promiseCaptures: captureIDs)))
            }
        }
        return .success((filings, failure))
    }

    private func filePromiseCaptures(_ filings: [MyQueue.PromiseFiling], after priorFailure: PromiseFailure?,
                                    plan: PromiseFilingPlan, work: PromiseWork) async -> Result<Void, PromiseFailure> {
        let (momentID, dataRoot) = (work.momentID, work.dataRoot)
        let (turn, envelope, store) = (plan.turn, plan.envelope, plan.store)
        var failure = priorFailure
        do {
            let results: [Result<MyQueue.PromiseLanding, Error>]
            if filings.isEmpty { results = [] }
            else { results = try await MyQueue.capture(filings, store: store) }
            for result in results {
                switch result {
                case .success(let landing): tracePromise(landing.change.rawValue, work: work, turn: turn, envelope: envelope, id: landing.id)
                case .failure(let error):
                    failure = PromiseFailure(cause: .desk, words: error.localizedDescription)
                    tracePromise("failed", work: work, turn: turn, envelope: envelope, reason: error.localizedDescription)
                    _ = await promiseFailure(error.localizedDescription, work: work, owner: "MyQueue", cause: .desk, wait: false)
                }
            }
            let captures = Set(plan.identities)
            let hasCardCaptures = filings.contains { $0.step.card != nil } || plan.open.contains {
                guard let step = $0.step, step.card != nil else { return false }
                return !captures.isDisjoint(with: step.promiseCaptures)
            }
            if hasCardCaptures {
                guard let reconcilePromiseCard else {
                    throw ToolFailureError("The promise's card settlement owner is unavailable.", effects: .unknown)
                }
                // A retry also reconciles already-landed captures, without refiling their words or changing their conditions.
                let gaps = try await settle {
                    () -> Result<[(id: String, words: String)], any Error> in
                    do {
                        let entries = MyQueue.entries(try await store.liveState())
                        var gaps: [(id: String, words: String)] = []
                        for entry in entries where entry.step.card != nil && !captures.isDisjoint(with: entry.step.promiseCaptures) {
                            do { try await reconcilePromiseCard(entry, store) }
                            catch { gaps.append((entry.name, error.localizedDescription)) }
                        }
                        return .success(gaps)
                    } catch { return .failure(error) }
                }.get()
                for gap in gaps {
                    failure = PromiseFailure(cause: .desk, words: gap.words)
                    tracePromise("failed", work: work, turn: turn, envelope: envelope, id: gap.id, reason: gap.words)
                    _ = await promiseFailure(gap.words, work: work, owner: "MyQueue", cause: .desk, wait: false)
                }
            }
        } catch {
            if Self.isCancellation(error) {
                return .failure(PromiseFailure(cause: nil, words: "Promise filing was cancelled; the retained judgment remains due."))
            }
            tracePromise("failed", work: work, turn: turn, envelope: envelope, reason: error.localizedDescription)
            return .failure(await promiseFailure(error.localizedDescription, work: work, owner: "MyQueue", cause: .desk, wait: false))
        }
        if failure == nil {
            RepairOwed.settle(dataRoot, operation: "memory.promise:" + momentID,
                evidence: .init(source: "cognition/cognition.sqlite", id: momentID))
        }
        if let failure { return .failure(failure) }
        return .success(())
    }

}
