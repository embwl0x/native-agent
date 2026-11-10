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
        func trace(_ status: String, id: String? = nil, reason: String? = nil, basis: String? = nil) {
            var payload: [String: JSONValue] = ["moment": .string(momentID), "status": .string(status)]
            if status == "matching" {
                payload["basis"] = .object([
                    "route": (matchingBasis?.route).map(JSONValue.string) ?? .null,
                    "answered": (matchingBasis?.answered).map(JSONValue.string) ?? .null,
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
            trace("failed", reason: error.localizedDescription)
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
                    trace("failed", reason: error.localizedDescription)
                    return await failed(error.localizedDescription, owner: "MemoryManagerPromise", cause: .provider)
                }
                await answered(momentID, route: matchingBasis?.route, door: door)
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
            return await failed(error.localizedDescription, wait: false)
        }
        guard !Task.isCancelled else {
            return .failure(PromiseFailure(cause: nil, words: "Promise filing was cancelled; the judgment is retained for the next drain."))
        }
        var filings: [MyQueue.PromiseFiling] = []
        var failure: PromiseFailure?
        var actEvidence: Result<[MemoryManagerAct], Error>?
        for capture in captures {
            switch capture {
            case .ignore: trace("ignored")
            case .settled(let settlement):
                let id = settlement.id, updatedAt = settlement.updatedAt
                let basis: String
                switch settlement.evidence {
                case .personWords(let source):
                    guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, personWords.contains(source) else {
                        return await failed("A retained settlement has no exact quote from this turn's person_words.", cause: .record)
                    }
                    basis = "person_words: \"" + source + "\""
                case .act(let actID, let source):
                    basis = "act " + actID + " (detail, turn " + (turn.turnId ?? momentID) + "): \"" + source + "\""
                case .reply(let source):
                    guard settlement.outcome == .done, MemoryManagerPromise.quoted(source, in: turn.assistant) else {
                        return await failed("A retained settlement has no exact quote from this turn's reply.", cause: .record)
                    }
                    basis = "reply: \"" + source + "\""
                }
                let dropped = settlement.outcome == .letGo
                let status: DeskStatus = dropped ? .canceled : .done
                let finalStatus: ArchiveFinalStatus = dropped ? .canceled : .done
                let why = settlement.outcome.rawValue + ": " + settlement.reason + " (" + momentID + "; " + basis + ")"
                do {
                    if let item = terminal.first(where: { $0.handle == id && $0.status == status && $0.summary == why }) {
                        guard let step = item.step else { throw ToolFailureError("The settled row has no saved step.", effects: .none) }
                        try MyQueue.releaseFinishedRun(words: step.words, store: store)
                        trace("already_settled", id: "desk." + item.alias, reason: why)
                    } else if let item = archived.first(where: { $0.handle == id && $0.finalStatus == finalStatus && $0.summary == why }) {
                        guard let words = item.refs.compactMap({ ref -> String? in
                            if case .step(let step) = ref.kind { return step.words }; return nil
                        }).last else { throw ToolFailureError("The settled archive has no saved step.", effects: .none) }
                        try MyQueue.releaseFinishedRun(words: words, store: store)
                        trace("already_settled", id: id, reason: why)
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
                                trace("failed", id: id, reason: error.localizedDescription)
                                _ = await failed(error.localizedDescription, owner: "TurnTrace", cause: .record, wait: false)
                                continue
                            }
                        }
                        guard let item = open.first(where: { $0.handle == id }), item.updatedAt == updatedAt,
                              let entry = MyQueue.entry(item) else { throw MyQueue.Superseded() }
                        if let conflict = try await store.runHold(id) {
                            throw ToolFailureError(try conflict.refusal(entry.name).serialize(pretty: false), effects: .none)
                        }
                        try await MyQueue.finish(entry, dropped: dropped, why: why, store: store)
                        trace("settled", id: entry.name, reason: why, basis: settlement.evidence.basis)
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
                    trace("failed", reason: error.localizedDescription)
                    _ = await failed(error.localizedDescription, owner: "MyQueue", cause: .desk, wait: false)
                }
            }
        } catch {
            if Self.isCancellation(error) {
                return .failure(PromiseFailure(cause: nil, words: "Promise filing was cancelled; the retained judgment remains due."))
            }
            trace("failed", reason: error.localizedDescription)
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
