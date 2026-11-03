import AuthoredCapabilities
import ChatTurnContracts
import ChatTurnRuntime
import ChatToolRuntime
import ChatToolParsing
import Desk
import Dispatcher
import Foundation
import Experiences
import NativeAgentShared
import Privacy
import NativeAgentCore
import PersistenceCore
import Senses
import ToolExecution
import ToolRegistry
import TrustCenter
import Transcripts
import TurnTrace
// Blueprint: | `AppToolExecutor+PartRun.swift` | `AppToolExecutor`: a part's own run (`doorPart`: Desk holds, the gated `authored.<id>` with its in-flight turn's arrival check (a message or that turn's Stop), `afterPartRun`: MY QUEUE upgrade line, runner-owned effect reconciliation and action-owned version recovery, with fresh-run calls only for no effects, a strict stop kept to resume), `doorPartPreview` retains nested value-call version pins, `doorPartResume` (optional bare/action ability id checked before claiming its checkpoint; receipts name the bare id); holds and bookkeeping failures retain the result and owe their owner repair, `doorWouldCard`; stopped checkpoints delegate to Desk’s `PartRunStore` |

/// A part's run through its own action (`authored.<id>`): every call keeps
/// the turn's gates. Its preview runs its code with every write previewed;
/// a strict run that stops to ask is kept to resume; the run's own words
/// about the part (an upgrade it owes) reach MY QUEUE.
extension AppToolExecutor {
    /// Why a run that used the outside world (any primitive call) is never resumed.
    static let unresumable = "This run used a host primitive (network, screen, hands, model, fetch or another part) before it stopped, so it can't be resumed; run the ability again and give it your answer as an input."

    /// Whether a run's journal holds any primitive call: the outside world,
    /// which a resume can't replay.
    static func usedOutside(_ journal: [JSONValue]) -> Bool {
        journal.contains { entry in
            guard case .array(let call)? = partFields(entry)["call"] else { return false }
            return call.first == .string("primitive")
        }
    }

    /// The stops a strict run is kept for, to resume: her decision, or a card preview.
    static let partHandBacks: Set<String> = ["decide", "would_card"]

    static func partFields(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let fields)? = value { fields } else { [:] }
    }

    /// The part's run: a Desk item it is given that another conversation
    /// works stays theirs, and doesn't run; then its own gated action.
    @MainActor
    func doorPart(_ action: AppAction, call: [String: JSONValue], input: [String: JSONValue], surface: String, root: URL) async throws -> JSONValue {
        let given = call.filter { !$0.key.hasPrefix("__") }
        // Its code is kept, so a key or token never rides a part's input.
        if let path = NativeAgentSecretRedactor.secretPath(.object(given)) {
            return Self.doorRefusal("secret_in_input", "\(path) carries a key or token, and an ability's input never does. Nothing ran.",
                remedy: "use_actions", "Pass a key as a single app action, not to an ability.")
        }
        let session = input["__session_id"]?.scalarText ?? ChatToolSessionContext.verifiedSessionId
        if let session {
            let store = SwiftNativeDeskStore(dataRoot: root)
            for ref in Self.deskRefs(.object(given)) {
                guard let by = try await store.hold(ref, session: session) else { continue }
                return Self.doorRefusal("held_by", "\(ref) is held by \(by), which is working it. Nothing ran.",
                    remedy: "none", "Leave it to that one, or pick it up there.", extra: ["held_by": .string(by)])
            }
        }
        // A part that is not done goes on by itself only inside this conversation's
        // turn in flight, one the person can Stop, until a message or that Stop arrives.
        let turn = session.flatMap { session in ChatCancelFlag.inFlightTurns(dataRoot: root).first {
            $0.sessionId == session && $0.turnId == TurnTraceContext.turnId } }
        let arrived = turn.map { turn in { @Sendable () -> Parts.Arrival? in
            ChatCancelFlag.isRaised(turn.stop) ? .stop : ChatTurnSteering.hasPending(turn.sessionId) ? .message : nil } }
        let result = try await Parts.$arrived.withValue(arrived) {
            try await runFolded(action, input: call, surface: surface)
        }
        return await Self.afterPartRun(result, id: action.tool, input: given, session: input["__session_id"], surface: surface, root: root)
    }

    /// A part's preview: its code runs, reads live and every write previewed,
    /// so it says where each step would card or hand back; nothing changes.
    @MainActor
    func doorPartPreview(_ action: AppAction, args: [String: JSONValue], input: [String: JSONValue], surface: String, root: URL) async -> JSONValue {
        do {
            var out = Self.partFields(try await Parts(root: root).run(id: action.tool, input: .object(args),
                requiredFingerprint: OwnedProgramInvocation.valueCall.flatMap { $0.id == action.tool ? $0.version : nil }, preview: true))
            out.removeValue(forKey: "journal")
            if case .array(let calls)? = out["calls"] {
                out["would"] = .array(calls.compactMap { row -> JSONValue? in
                    guard case .object(let fields) = row, fields["would_card"] == .bool(true) else { return nil }
                    return .object(fields.filter { ["n", "step", "call", "would_card"].contains($0.key) })
                })
            }
            // Its own gate too: a part whose reach needs the owner's card says so.
            if try await doorWouldCard(action, call: args, input: input, surface: surface) { out["would_card"] = .bool(true) }
            return .object(out)
        } catch { return ChatToolOutcome.failure(error: error, tool: action.tool) }
    }

    /// What a run says about its part, once it is back: the upgrade it owes
    /// as a quiet MY QUEUE line, the remedy for a stop, and a run kept to
    /// resume when it stopped to ask or handed a step back.
    static func afterPartRun(_ result: JSONValue, id: String, input given: [String: JSONValue], session: JSONValue?, surface: String, root: URL) async -> JSONValue {
        guard case .object(var out) = result else { return result }
        out["id"] = .string(id)
        // A part that carried itself names the input its last run ran on.
        let input = if case .object(let last)? = out["ran_on"] { last } else { given }
        let calls: [JSONValue]? = if case .array(let calls)? = out.removeValue(forKey: "journal") { calls } else { nil }
        let row: [String: JSONValue]?
        do { row = try Parts(root: root).row(id) }
        catch {
            if let calls { out["unsettled_journal"] = .array(calls) }
            return .object(partSettlementFailure(out, error: error, operation: "ability.metadata", id: id, root: root))
        }
        let name = row.flatMap { Parts.fields(.object($0))["name"] }?.scalarText ?? id
        let voices = row.map(Parts.voices) ?? []
        out["name"] = .string(name)
        if case .string(let upgrade)? = out["upgrade"] {
            let parts = upgrade.split(separator: "@", maxSplits: 1).map(String.init)
            do {
                guard let target = parts.first, !target.isEmpty else {
                    throw ToolFailureError("The run's upgrade evidence has no target. Inspect its result before creating the upgrade intention.", effects: .none, code: "upgrade_target_unavailable")
                }
                _ = try await MyQueue.add(DeskStep(words: "\(name) stopped on \(target)\(parts.count > 1 && !parts[1].isEmpty ? " at \(parts[1])" : "") "
                    + "in 2 of its last 3 runs; upgrade it?", when: "quiet", peers: voices, origin: "self"), store: SwiftNativeDeskStore(dataRoot: root))
                out.removeValue(forKey: "upgrade")
            } catch { out = partSettlementFailure(out, error: error, operation: "ability.upgrade_queue", id: id, root: root) }
        }
        let reason = doorText(out["reason"])
        // The runner carries the action owner's remedy, including sense-version reads.
        // Only the runner decides what took effect, including the original
        // journal on an aborted resume. A fresh run must not repeat it.
        let outside = calls.map(usedOutside) ?? false
        if out["effects"] == .string("none"), reason == "state_changed" || (partHandBacks.contains(reason) && outside) {
            out["remedy"] = .object(["kind": .string("run_again"), "instruction": .string(reason == "state_changed"
                ? "Something it read before it stopped reads differently now, so nothing more ran and the run is closed. Read what changed; if the ability still fits, run it again from the start."
                : unresumable), "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("authored." + id), "args": .object(input)])])])
        }
        guard out["status"] == .string("stopped"), partHandBacks.contains(reason), let calls,
              !outside, let digest = out["version"]?.scalarText else { return .object(out) }
        let runID = "run-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let back = partFields(out["hand_back"])
        let question = [back["question"], partFields(out["stopped"])["detail"]].lazy.map(doorText).first { !$0.isEmpty } ?? reason
        // Sealed, with the steer of the turn it ran on and the wake that ran it:
        // a resume takes both on.
        var sealed: [String: JSONValue] = [
            "run_id": .string(runID), "skill": .string(id), "name": .string(name), "digest": .string(digest),
            "input": .object(input), "journal": .array(calls), "question": .string(question), "reason": .string(reason),
            "version": .string(digest), "hostRevision": .string(OwnedProgramStore.hostRevision),
            "at": .string(NativeTimestampFormat.plainZulu(Date())),
            "steer": PeerDataTaint.carriedRecord(peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                                 peerID: ChatToolSessionContext.envelope?.verifiedUserId),
        ]
        sealed["wake"] = OwnedProgramRunner.wake
        do { try await PartRunStore.save(sealed, id: runID, root: root) }
        catch {
            out["saved_run_id"] = .string(runID)
            out["resume_failure"] = ChatToolOutcome.failure(error: error, tool: "ability.run_checkpoint")
            return .object(partSettlementFailure(out, error: error, operation: "ability.run_checkpoint", id: runID, root: root))
        }
        // The Desk items it touched stay its own until it is resumed or dropped:
        // another conversation that works one is told "held by run <id>".
        var held: [String] = []
        if let owner = session?.scalarText ?? ChatToolSessionContext.verifiedSessionId {
            do { held = try await SwiftNativeDeskStore(dataRoot: root).hold(try deskRefs(calls), run: runID, session: owner) }
            catch {
                out["saved_run_id"] = .string(runID)
                return .object(partSettlementFailure(out, error: error, operation: "ability.run_holds", id: runID, root: root))
            }
        }
        out["resume"] = .object(["run_id": .string(runID), "question": .string(question), "held": .array(held.map(JSONValue.string))])
        let took = out["changed"] == nil ? "" : "The calls in changed took effect; don't run them again. "
        out["remedy"] = .object([
            "kind": .string("resume"),
            "instruction": .string(took + (reason == "decide"
                ? "It stopped to ask you hand_back.question: answer with ability.resume {run_id, answer}, and app.decide returns your answer."
                : "It handed hand_back's step back before it ran: do it yourself as its own app call if you still want it, "
                    + "then ability.resume {run_id, answer} goes on, the step returning your answer.")
                + " A resume reads again everything it read, and goes on only if it all reads the same."),
            "next_call": .object(["tool": .string("app"), "input": .object([
                "action": .string("ability.resume"), "args": .object(["run_id": .string(runID)]),
            ])]),
        ])
        return .object(out)
    }

    /// Bookkeeping follows a completed run; retain its result and owe the
    /// failed owner repair without claiming that the effect should run again.
    static func partSettlementFailure(_ result: [String: JSONValue], error: Error, operation: String, id: String, root: URL) -> [String: JSONValue] {
        var out = result
        let failure = ChatToolOutcome.failure(error: error, tool: operation)
        var failures = out["settlement_failures"]?.arrayValue ?? []
        failures.append(failure)
        out["settlement_failures"] = .array(failures)
        out["settlement_note"] = .string("The run's result is retained, but \(operation) failed: \(error.localizedDescription). Repair this owner and reconcile the saved run and Desk holds before continuing; do not repeat completed effects.")
        RepairOwed.owe(root, id: operation + ":" + id, kind: .run, operation: operation,
            owner: root.appendingPathComponent("abilities").path, words: out["settlement_note"]?.scalarText ?? error.localizedDescription)
        return out
    }

    /// `ability.resume` claims once, rechecks sealed admission, active version and input, and inherits steer and wake.
    /// Live replay rereads prior reads and continues only while they match.
    /// Preview only inspects: it claims no run, transfers no holds and closes no queued step.
    @MainActor
    func doorPartResume(_ args: [String: JSONValue], preview: Bool = false, session: JSONValue?, surface: String, root: URL) async -> JSONValue {
        let runID = Self.doorText(args["run_id"])
        if runID.range(of: "^run-[0-9a-f]{8}$", options: .regularExpression) == nil {
            return Self.doorRefusal("invalid_run_id", "run_id must be run- followed by eight lowercase hex digits. Nothing ran.",
                remedy: "select_run", "Read the saved run ids and pass the exact run_id.", next: ["page": .string("tools")])
        }
        // An optional ability reference binds the requested run without claiming
        // it on a typo or a different ability. run_id remains the exact checkpoint.
        var requestedAbility: String?
        if let named = args["id"]?.scalarText {
            do {
                let parts = Parts(root: root)
                guard let row = try parts.row(named), let id = row["id"]?.scalarText else {
                    let refusal = try parts.unknown(named)
                    return .object(refusal.fields.merging(["status": .string("refused")]) { $1 })
                }
                requestedAbility = id
                let waiting = try await PartRunStore.read(runID, root: root)
                if Self.doorText(waiting["skill"]) != id {
                    return Self.doorRefusal("wrong_ability", "\(runID) is not a stopped run of \(id). Nothing was claimed or run.",
                        remedy: "select_run", "Read the saved run ids and choose this ability's run_id.",
                        next: ["page": .string("tools")], extra: ["id": .string(id), "run_id": .string(runID)])
                }
            } catch { return ChatToolOutcome.failure(error: error, tool: "ability.resume") }
        }
        let run: [String: JSONValue]
        let claim: PartRunStore.Claim?
        do {
            if preview { claim = nil; run = try await PartRunStore.read(runID, root: root) }
            else {
                let taken = try await PartRunStore.take(runID, root: root)
                claim = taken; run = taken.run
            }
        } catch { return ChatToolOutcome.failure(error: error, tool: "ability.resume") }
        func checkpoint(_ result: JSONValue, consume: Bool) -> JSONValue {
            guard let claim else { return result }
            if consume, Self.partFields(result)["settlement_failures"] != nil {
                var out = Self.partFields(result)
                out["unsettled_checkpoint"] = .string(claim.path)
                return .object(out)
            }
            do {
                if consume { try claim.consume() } else { try claim.release() }
                return result
            } catch {
                return .object(Self.partSettlementFailure(Self.partFields(result), error: error,
                    operation: consume ? "ability.consume_checkpoint" : "ability.release_checkpoint", id: runID, root: root))
            }
        }
        if let requestedAbility, Self.doorText(run["skill"]) != requestedAbility {
            return checkpoint(Self.doorRefusal("wrong_ability", "\(runID) is not a stopped run of \(requestedAbility). Nothing ran.",
                remedy: "select_run", "Read the saved run ids and choose this ability's run_id.",
                next: ["page": .string("tools")], extra: ["id": .string(requestedAbility), "run_id": .string(runID)]), consume: false)
        }
        let steer: (sources: [String], elevated: [String])
        do { steer = try PeerDataTaint.steer(in: run["steer"]) }
        catch {
            let failure = Self.partFields(ChatToolOutcome.failure(error: error, tool: "ability.resume", effects: ToolFailureError.Effects.none))
            if preview { return .object(failure) }
            return checkpoint(.object(Self.partSettlementFailure(failure, error: error, operation: "ability.resume_provenance", id: runID, root: root)), consume: false)
        }
        let name = Self.doorText(run["name"]), id = Self.doorText(run["skill"])
        if run["status"] == .string("stopped"), run["reason"] == .string(DataRootLife.stoppedReason) {
            let input = Self.partFields(run["input"])
            if preview { return .object(["status": .string("stopped"), "reason": .string(DataRootLife.stoppedReason),
                "execution": .string("not_run"), "effects": .string("none"), "resume_mode": .string("fresh"),
                "run_id": .string(runID), "id": .string(id), "ability": .string(id), "input": .object(input)]) }
            do {
                let result = try await Parts(root: root).run(id: id, input: .object(input))
                let out = await Self.afterPartRun(result, id: id, input: input, session: session, surface: surface, root: root)
                return checkpoint(out, consume: !OwnedProgramRunner.turnedAway(result))
            } catch { return checkpoint(ChatToolOutcome.failure(error: error, tool: id), consume: false) }
        }
        // Claimed in this life: its holds pass to the resuming conversation.
        let store = SwiftNativeDeskStore(dataRoot: root)
        let owner = preview ? nil : session?.scalarText ?? ChatToolSessionContext.verifiedSessionId
        var passed: [String: DeskHold] = [:]
        if let owner {
            do {
                passed = try await store.passHolds(run: runID, to: owner)
                guard case .array(let heldJournal)? = run["journal"] else {
                    throw ToolFailureError("The stopped run has no readable journal for Desk ownership. Inspect its checkpoint before resuming.", effects: .none, code: "run_journal_unavailable")
                }
                // Re-establish the journal's entire hold set through the
                // current owner, including a stopped run whose original
                // hold settlement failed. A missing saved hold is no grant.
                if let by = try await store.hold(try Self.deskRefs(heldJournal), session: owner) {
                    try await store.returnHolds(passed, from: owner)
                    return checkpoint(Self.doorRefusal("held_by", "Run \(runID) did not resume: its Desk work is held by \(by).",
                        remedy: "inspect", "Leave it to that conversation and inspect the saved run before continuing; completed effects must not be repeated.",
                        extra: ["run_id": .string(runID), "held_by": .string(by)]), consume: false)
                }
            }
            catch {
                var failure = Self.partFields(ChatToolOutcome.failure(error: error, tool: "ability.resume", effects: ToolFailureError.Effects.none))
                do { try await store.returnHolds(passed, from: owner) }
                catch { failure = Self.partSettlementFailure(failure, error: error, operation: "ability.return_holds", id: runID, root: root) }
                failure["run_id"] = .string(runID)
                return checkpoint(.object(Self.partSettlementFailure(failure, error: error, operation: "ability.resume_holds", id: runID, root: root)), consume: false)
            }
        }
        // Its queued step closes once the run is taken up or closed; a resume turned away
        // busy leaves it open, so the run, its step and its holds wait on together.
        var closeFailure: Error?
        func closeStep() async {
            guard !preview else { return }
            do {
                let state = try await store.liveState()
                for entry in MyQueue.entries(state) where entry.step.words.hasPrefix(MyQueue.skillRunPrefix(skill: name, run: runID)) {
                    try await MyQueue.finish(entry, dropped: false, why: "resumed", store: store)
                }
            } catch { closeFailure = error }
        }
        func settled(_ result: JSONValue) -> JSONValue {
            guard let closeFailure else { return result }
            return .object(Self.partSettlementFailure(Self.partFields(result), error: closeFailure,
                operation: "ability.resume_queue", id: runID, root: root))
        }
        func closed(_ reason: String, _ why: String) -> JSONValue {
            checkpoint(settled(Self.doorRefusal(reason, why + (preview ? " Resuming run \(runID) would close it; nothing was claimed or run."
                : " Run \(runID) is closed; nothing ran."), remedy: "none", "Read the ability and affected state before choosing what remains; do not repeat completed effects.",
                extra: ["id": .string(id)])), consume: true)
        }
        let row: [String: JSONValue]?
        do { row = try Parts(root: root).row(id) }
        catch {
            let failure = Self.partFields(ChatToolOutcome.failure(error: error, tool: "ability.resume", effects: ToolFailureError.Effects.none))
            return checkpoint(.object(Self.partSettlementFailure(failure, error: error, operation: "ability.resume_metadata", id: runID, root: root)), consume: false)
        }
        guard let row, row["status"] == .string("active"), row["codeFingerprint"] == run["digest"],
              run["hostRevision"] == .string(OwnedProgramStore.hostRevision), case .array(let journal)? = run["journal"] else {
            await closeStep()
            return closed("script_changed", "\(name) changed or was switched off since run \(runID) stopped.")
        }
        let input = Self.partFields(run["input"])
        if Self.usedOutside(journal) { await closeStep(); return closed("not_resumable", Self.unresumable) }
        if preview {
            // Where it stopped: the call its answer goes to, and the step it was in.
            let last = Self.partFields(journal.last), row = Self.partFields(last["row"])
            var at = row.filter { ["n", "line", "step", "call"].contains($0.key) }
            if at.isEmpty, case .array(let call)? = last["call"], call.count == 4 { at = ["call": call[0], "id": call[1], "line": call[3]] }
            return .object([
                "status": .string("preview"), "effects": .string("none"), "execution": .string("not_run"),
                "run_id": .string(runID), "id": .string(id), "name": .string(name),
                "ability": .string(id), "question": run["question"] ?? .null, "reason": run["reason"] ?? .null,
                "input": .object(input), "wake": run["wake"] ?? .null, "stopped_at": .object(at),
                "detail": .string("Resuming would run \(name) from the top on this input: each call it made before it stopped "
                    + "answers as it did (what it read is read again, and it goes on only if that reads the same), "
                    + "the call at stopped_at returns your answer, and its code goes on live from there. Nothing was claimed or run."),
            ])
        }
        // Who steered it steers the rest, as trusted as the owner holds it now; whom the person answered for stays answered.
        let taint = PeerDataTaint.current ?? PeerDataTaint()
        steer.sources.forEach { taint.mark(peer: $0) }
        steer.elevated.forEach { taint.elevate(peer: $0) }
        do {
            return try await OwnedProgramRunner.$wake.withValue(run["wake"]) {
                let result = try await PeerDataTaint.$current.withValue(taint) {
                    try await Parts(root: root).run(id: id, input: .object(input), requiredFingerprint: Self.doorText(run["digest"]),
                        replay: OwnedProgramRunner.Replay(journal: journal, answer: args["answer"] ?? .null))
                }
                // Turned away, its slot busy: nothing of it ran, so it waits as it was, to resume once that call ends.
                if OwnedProgramRunner.turnedAway(result) {
                    var out = Self.partFields(await Self.afterPartRun(result, id: id, input: input, session: session, surface: surface, root: root))
                    if let owner {
                        do { try await store.returnHolds(passed, from: owner) }
                        catch { return checkpoint(.object(Self.partSettlementFailure(out, error: error, operation: "ability.return_holds", id: runID, root: root)), consume: false) }
                    }
                    out["resume"] = .object(["run_id": .string(runID), "question": run["question"] ?? .null,
                                             "held": .array(try Self.deskRefs(journal).map(JSONValue.string))])
                    out["resume_note"] = .string("Run \(runID) still waits; nothing of it ran. Resume it again once that call finishes.")
                    return checkpoint(.object(out), consume: false)
                }
                await closeStep()
                return checkpoint(settled(await Self.afterPartRun(result, id: id, input: input, session: session, surface: surface, root: root)), consume: true)
            }
        } catch {
            return checkpoint(ChatToolOutcome.failure(error: error, tool: "ability.resume"), consume: false)
        }
    }

    /// Whether the real call would file a card for User, read now and changing
    /// nothing: SecurityCenter's own reading of it, explicit card requests,
    /// and the peer floor on a turn a peer steered.
    @MainActor
    func doorWouldCard(_ action: AppAction, call: [String: JSONValue], input: [String: JSONValue], surface: String) async throws -> Bool {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        // A folded action re-enters under its tool's own name; the rest are the app call's.
        let tool = action.isFold ? action.tool : "app"
        let args = action.isFold ? call : input.filter { $0.key != "preview" }
        let envelope = await SwiftNativeSecurityCenter(dataRoot: root).evaluateTool(
            tool: tool, input: MacInjectionArgRedaction.redacted(tool: tool, input: args),
            origin: .currentTurn(verifiedSessionId: ChatToolSessionContext.verifiedSessionId, surface: surface))
        guard envelope.decision != .block else { return false }
        if envelope.requiresApproval { return true }
        if action.tool == "request_interaction",
           InlineInteractionNeed.interaction(in: await SwiftToolDispatcher.requestedInteraction(input: call, dataRoot: root)) != nil {
            return true
        }
        let protectedAction = try PeerTurnEffectPolicy.requiresPeerApproval(tool, input: args)
        return PeerDataTaintDispatcher.peerApproval(surface: surface, protectedAction: protectedAction).required
    }
}

extension AppToolExecutor {
    /// The Desk items a value names (desk.N or a desk_ handle); in a run's
    /// journal, each Desk write's handle or id.
    static func deskRefs(_ value: JSONValue) -> [String] {
        func named(_ text: String) -> Bool {
            text.range(of: #"^(desk\.[0-9]+(\.[0-9]+)*|desk_[0-9a-f-]+)$"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        switch value {
        case .string(let text): return named(text) ? [text] : []
        case .object(let fields): return fields.keys.sorted().flatMap { deskRefs(fields[$0] ?? .null) }
        case .array(let items): return items.flatMap(deskRefs)
        default: return []
        }
    }

    static func deskRefs(_ journal: [JSONValue]) throws -> [String] {
        try journal.flatMap { entry -> [String] in
            guard case .object(let fields) = entry, case .array(let call)? = fields["call"], call.count > 2,
                  call[0] == .string("action"), case .string(let id) = call[1], case .string(let raw) = call[2] else { return [] }
            guard let action = try AppActions.action(id) else {
                throw ToolFailureError("Stopped-run action \(id) is not in the checked catalog. Read its journal before reconciling Desk holds.", effects: .none, code: "run_action_unavailable")
            }
            guard action.page == "desk", !action.read else { return [] }
            guard case .array(let given) = try JSONValue.parse(Data(raw.utf8)) else {
                throw ToolFailureError("Stopped-run Desk arguments are not an array. Repair its journal before reconciling holds.", effects: .none, code: "run_arguments_unavailable")
            }
            let input = try AppScriptRunner.doorInput(id: id, given: given).get()
            let args = partFields(input["args"])
            return [args["handle"], args["id"]].compactMap { $0?.scalarText }
        }
    }
}
