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
// Blueprint: | `AppToolExecutor+PartRun.swift` | Part admission, previews, stopped-run checkpoints from the private journal, Desk reservations and settlement |

/// Part calls retain turn gates. Previews preview every write; strict hand-backs retain resumable runs and surface owed upgrades.
extension AppToolExecutor {
    /// Primitive calls touch the outside world and cannot safely replay on resume.
    static let unresumable = """
        This run used a host primitive (network, screen, hands, model, fetch or another part) before it stopped, so it can't be resumed; run the ability \
        again and give it your answer as an input.
        """

    static func usedOutside(_ journal: [JSONValue]) -> Bool {
        journal.contains { entry in
            guard case .array(let call)? = partFields(entry)["call"] else { return false }
            return call.first == .string("primitive")
        }
    }

    /// Only decision and card-preview stops admit resumable strict checkpoints.
    static let partHandBacks: Set<String> = ["decide", "would_card"]

    static func partFields(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let fields)? = value { fields } else { [:] }
    }

    @MainActor
    func doorPart(_ action: AppAction, call: [String: JSONValue], input: [String: JSONValue], surface: String, root: URL,
                  turn: Turn, execution: AppActionExecution) async throws -> JSONValue {
        let given = call.filter { !$0.key.hasPrefix("__") }
        // Its code is kept, so a key or token never rides a part's input.
        if let path = NativeAgentSecretRedactor.secretPath(.object(given)) {
            return Self.doorRefusal("secret_in_input", "\(path) carries a key or token, and an ability's input never does. Nothing ran.",
                remedy: "use_actions", "Pass a key as a single app action, not to an ability.")
        }
        let session = input["__session_id"]?.scalarText ?? turn.verifiedSessionID
        // A part that is not done goes on by itself only inside this conversation's turn in flight, one the person can Stop, until a message or that Stop
        // arrives.
        let inFlight = session.flatMap { session in ChatCancelFlag.inFlightTurns(dataRoot: root).first {
            $0.sessionId == session && $0.turnId == turn.id } }
        var execution = execution
        execution.arrived = inFlight.map { held in { @Sendable () -> Parts.Arrival? in
            ChatCancelFlag.isRaised(held.stop) ? .stop : ChatTurnSteering.hasPending(held.sessionId) ? .message : nil } }
        let result = try await runFolded(action, input: call, surface: surface, turn: turn, execution: execution)
        return await Self.afterPartRun(result, id: action.tool, input: given, surface: surface, root: root,
                                      turn: turn, execution: execution)
    }

    /// Previews read live but preview every write, including nested calls.
    @MainActor
    func doorPartPreview(_ action: AppAction, args: [String: JSONValue], input: [String: JSONValue], surface: String, root: URL,
                         turn: Turn, execution: AppActionExecution) async -> JSONValue {
        do {
            var out = Self.partFields(try await Parts(root: root).run(id: action.tool, input: .object(args),
                requiredFingerprint: execution.valueCall.flatMap { $0.id == action.tool ? $0.version : nil }, preview: true,
                invocation: execution.partInvocation(turn: turn, surface: surface, preview: true)))
            // A previewed run is never resumed: its private journal is let go.
            _ = OwnedProgramRunner.journal(out.removeValue(forKey: "journal_ref"))
            if case .array(let calls)? = out["calls"] {
                out["would"] = .array(calls.compactMap { row -> JSONValue? in
                    guard case .object(let fields) = row, fields["would_card"] == .bool(true) else { return nil }
                    return .object(fields.filter { ["n", "step", "call", "would_card"].contains($0.key) })
                })
            }
            // Its own gate too: a part whose reach needs the owner's card says so.
            if try await doorWouldCard(action, call: args, input: input, surface: surface, turn: turn, execution: execution) { out["would_card"] = .bool(true) }
            // A verb the part refuses before it calls anything (its own argument checks) would refuse live too, so the preflight refuses before any
            // card. A failure after a previewed call is the preview's, never a verdict on the live run.
            let called = if case .array(let rows)? = out["calls"] { !rows.isEmpty } else { false }
            if action.input["verb"] != nil, !called, case .object(let answer)? = out["returned"], answer["status"] == .string("failed"),
               case .string(let reason)? = answer["reason"] {
                out["would_refuse"] = .string(reason)
                out["detail"] = answer["message"] ?? answer["detail"] ?? answer["fix"] ?? .string(reason)
            }
            return .object(out)
        } catch { return ChatToolOutcome.failure(error: error, tool: action.tool) }
    }

    /// Surface the run's owed upgrade, stop remedy and resumable checkpoint without changing its outcome.
    static func afterPartRun(_ result: JSONValue, id: String, input given: [String: JSONValue], surface: String,
        root: URL, turn: Turn, execution: AppActionExecution) async -> JSONValue {
        guard case .object(var out) = result else { return result }
        out["id"] = .string(id)
        // A self-carried run must report the actual input of its last execution.
        let input = if case .object(let last)? = out["ran_on"] { last } else { given }
        // A stopped strict run's replay journal is private: the receipt names it, and only this settlement takes it.
        let reference = out.removeValue(forKey: "journal_ref")
        let row: [String: JSONValue]?
        do { row = try Parts(root: root).row(id) }
        catch {
            // Unsettled, the journal moves to the private run store on disk under the same reference; the result names it, never its raw answers.
            if let named = reference?.stringValue, let journal = OwnedProgramRunner.journal(reference) {
                do {
                    try await PartRunStore.keepJournal(journal, reference: named, root: root)
                    out["unsettled_journal"] = .string(named)
                } catch let kept {
                    out = partSettlementFailure(out, error: kept, operation: "ability.unsettled_journal", id: named, root: root)
                }
            }
            return .object(partSettlementFailure(out, error: error, operation: "ability.metadata", id: id, root: root))
        }
        let calls = OwnedProgramRunner.journal(reference)
        let name = row.flatMap { Parts.fields(.object($0))["name"] }?.scalarText ?? id
        let voices = row.map(Parts.voices) ?? []
        out["name"] = .string(name)
        if case .string(let upgrade)? = out["upgrade"] {
            let parts = upgrade.split(separator: "@", maxSplits: 1).map(String.init)
            do {
                guard let target = parts.first, !target.isEmpty else {
                    throw ToolFailureError("""
                        The run's upgrade evidence has no target. Inspect its result before creating the upgrade intention.
                        """, effects: .none, code: "upgrade_target_unavailable")
                }
                _ = try await MyQueue.add(DeskStep(words: "\(name) stopped on \(target)\(parts.count > 1 && !parts[1].isEmpty ? " at \(parts[1])" : "") "
                    + "in 2 of its last 3 runs; upgrade it?", when: "quiet", peers: voices, origin: "self"), store: SwiftNativeDeskStore(dataRoot: root))
                out.removeValue(forKey: "upgrade")
            } catch { out = partSettlementFailure(out, error: error, operation: "ability.upgrade_queue", id: id, root: root) }
        }
        let reason = doorText(out["reason"])
        // The runner carries the action owner's remedy, including sense-version reads. Only the runner decides what took effect, including the original journal
        // on an aborted resume. A fresh run must not repeat it.
        let outside = calls.map(usedOutside) ?? false
        let reply = ToolResult(.object(out))
        if reply.effects == .some(.none), reason == "state_changed" || (partHandBacks.contains(reason) && outside) {
            out["remedy"] = .object(["kind": .string("run_again"), "instruction": .string(reason == "state_changed"
                ? """
                    Something it read before it stopped reads differently now, so nothing more ran and the run is closed. Read what changed; if the ability \
                    still fits, run it again from the start.
                    """
                : unresumable), "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("authored." + id), "args": .object(
                    input)])])])
        }
        guard out["status"] == .string("stopped"), partHandBacks.contains(reason), let calls,
              !outside, let digest = out["version"]?.scalarText else { return .object(out) }
        let runID = "run-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let back = partFields(out["hand_back"])
        let question = [back["question"], partFields(out["stopped"])["detail"]].lazy.map(doorText).first { !$0.isEmpty } ?? reason
        // Resumes inherit the sealed steer and wake.
        var sealed: [String: JSONValue] = [
            "run_id": .string(runID), "skill": .string(id), "name": .string(name), "digest": .string(digest),
            "input": .object(input), "journal": .array(calls), "question": .string(question), "reason": .string(reason),
            "version": .string(digest), "hostRevision": .string(OwnedProgramStore.hostRevision),
            "at": .string(NativeTimestampFormat.plainZulu(Date())),
            "steer": PeerDataTaint.carriedRecord(turn: turn, peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                                 peerID: turn.envelope?.verifiedUserId),
        ]
        sealed["wake"] = execution.wake
        do { try await PartRunStore.save(sealed, id: runID, root: root) }
        catch {
            out["saved_run_id"] = .string(runID)
            out["resume_failure"] = ChatToolOutcome.failure(error: error, tool: "ability.run_checkpoint")
            return .object(partSettlementFailure(out, error: error, operation: "ability.run_checkpoint", id: runID, root: root))
        }
        // The Desk items it touched stay its own until it is resumed or dropped: another conversation that works one is told "held by run <id>".
        var held: [String] = []
        do {
            held = try await SwiftNativeDeskStore(dataRoot: root).hold(try deskRefs(calls, turn: turn), run: runID,
                session: turn.verifiedSessionID ?? turn.session)
        }
        catch {
            out["saved_run_id"] = .string(runID)
            return .object(partSettlementFailure(out, error: error, operation: "ability.run_holds", id: runID, root: root))
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

    /// Bookkeeping follows a completed run; retain its result and owe the failed owner repair without claiming that the effect should run again.
    static func partSettlementFailure(_ result: [String: JSONValue], error: Error, operation: String, id: String, root: URL) -> [String: JSONValue] {
        var out = result
        let failure = ChatToolOutcome.failure(error: error, tool: operation)
        var failures = out["settlement_failures"]?.arrayValue ?? []
        failures.append(failure)
        out["settlement_failures"] = .array(failures)
        out["settlement_note"] = .string("""
            The run's result is retained, but \(operation) failed: \(error.localizedDescription). Repair this owner and reconcile the saved run and Desk \
            holds before continuing; do not repeat completed effects.
            """)
        RepairOwed.owe(root, id: operation + ":" + id, kind: .run, operation: operation,
            owner: root.appendingPathComponent("abilities").path, words: out["settlement_note"]?.scalarText ?? error.localizedDescription)
        return out
    }

    /// ability.resume claims once and rechecks sealed admission, active version and input; live replay requires matching prior reads.
    /// Preview claims nothing, releases no reservations and closes no queued step.
    @MainActor
    func doorPartResume(_ args: [String: JSONValue], preview: Bool = false, surface: String, root: URL,
                        turn: Turn, execution: AppActionExecution) async -> JSONValue {
        let runID = Self.doorText(args["run_id"])
        if runID.range(of: "^run-[0-9a-f]{8}$", options: .regularExpression) == nil {
            return Self.doorRefusal("invalid_run_id", "run_id must be run- followed by eight lowercase hex digits. Nothing ran.",
                remedy: "select_run", "Read the saved run ids and pass the exact run_id.", next: ["page": .string("tools")])
        }
        // An optional ability reference binds the requested run without claiming it on a typo or a different ability. run_id remains the exact checkpoint.
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
        let store = SwiftNativeDeskStore(dataRoot: root)
        var passed: [String: DeskHold] = [:]
        func checkpoint(_ result: JSONValue, consume: Bool) async -> JSONValue {
            guard let claim else { return result }
            return await settle { [passed] in
                var result = result
                if !consume || Self.partFields(result)["settlement_failures"] != nil {
                    do { try await store.returnHolds(passed) }
                    catch {
                        result = .object(Self.partSettlementFailure(Self.partFields(result), error: error,
                            operation: "ability.return_holds", id: runID, root: root))
                    }
                }
                if consume, Self.partFields(result)["settlement_failures"] != nil {
                    var out = Self.partFields(result)
                    out["unsettled_checkpoint"] = .string(claim.path)
                    return .object(out)
                }
                do {
                    if consume { try claim.consume() } else { try claim.release() }
                    return result
                } catch {
                    var failure = Self.partSettlementFailure(Self.partFields(result), error: error,
                        operation: consume ? "ability.consume_checkpoint" : "ability.release_checkpoint", id: runID, root: root)
                    if consume {
                        do { try await store.returnHolds(passed) }
                        catch {
                            failure = Self.partSettlementFailure(failure, error: error, operation: "ability.return_holds", id: runID, root: root)
                        }
                    }
                    return .object(failure)
                }
            }
        }
        if let requestedAbility, Self.doorText(run["skill"]) != requestedAbility {
            return await checkpoint(Self.doorRefusal("wrong_ability", "\(runID) is not a stopped run of \(requestedAbility). Nothing ran.",
                remedy: "select_run", "Read the saved run ids and choose this ability's run_id.",
                next: ["page": .string("tools")], extra: ["id": .string(requestedAbility), "run_id": .string(runID)]), consume: false)
        }
        let steer: (sources: [String], elevated: [String])
        do { steer = try PeerDataTaint.steer(in: run["steer"]) }
        catch {
            let failure = Self.partFields(ChatToolOutcome.failure(error: error, tool: "ability.resume", effects: ToolFailureError.Effects.none))
            if preview { return .object(failure) }
            return await checkpoint(.object(Self.partSettlementFailure(failure, error: error, operation: "ability.resume_provenance", id: runID, root: root)),
                consume: false)
        }
        // Restore only at a live run, including a fresh one after a prior process
        // life. A preview or a refused checkpoint mutates no turn authority.
        let heldTurn = turn
        func resumedTurn() -> Turn {
            let taint = heldTurn.peerSteering ?? PeerDataTaint()
            steer.sources.forEach { taint.mark(peer: $0) }
            steer.elevated.forEach { taint.elevate(peer: $0) }
            return heldTurn.with(\.peerSteering, taint)
        }
        var execution = execution
        execution.wake = run["wake"]
        let name = Self.doorText(run["name"]), id = Self.doorText(run["skill"])
        // Both fresh restored runs and replayed runs release the stopped run's reservations while retaining its checkpoint.
        if !preview {
            do { passed = try await store.passHolds(run: runID) }
            catch {
                return await checkpoint(.object(Self.partSettlementFailure(Self.partFields(ChatToolOutcome.failure(error: error, tool: "ability.resume")),
                    error: error, operation: "ability.resume_holds", id: runID, root: root)), consume: false)
            }
        }
        if run["status"] == .string("stopped"), run["reason"] == .string(DataRootLife.stoppedReason) {
            let input = Self.partFields(run["input"])
            if preview { return .object(["status": .string("stopped"), "reason": .string(DataRootLife.stoppedReason),
                "execution": .string("not_run"), "effects": .string("none"), "resume_mode": .string("fresh"),
                "run_id": .string(runID), "id": .string(id), "ability": .string(id), "input": .object(input)]) }
            do {
                let turn = resumedTurn()
                let result = try await Parts(root: root).run(id: id, input: .object(input),
                    invocation: execution.partInvocation(turn: turn, surface: surface))
                let out = await Self.afterPartRun(result, id: id, input: input, surface: surface, root: root,
                                                 turn: turn, execution: execution)
                return await checkpoint(out, consume: !OwnedProgramRunner.turnedAway(result))
            } catch { return await checkpoint(ChatToolOutcome.failure(error: error, tool: id), consume: false) }
        }
        if !preview {
            do {
                guard case .array(let heldJournal)? = run["journal"] else {
                    throw ToolFailureError("""
                        The stopped run has no readable journal for Desk ownership. Inspect its checkpoint before resuming.
                        """, effects: .none, code: "run_journal_unavailable")
                }
                if let conflict = try await store.runHold(try Self.deskRefs(heldJournal, turn: turn)) {
                    var refusal = Self.partFields(conflict.refusal("Run \(runID)'s Desk work"))
                    refusal["run_id"] = .string(runID)
                    return await checkpoint(.object(refusal), consume: false)
                }
            }
            catch {
                var failure = Self.partFields(ChatToolOutcome.failure(error: error, tool: "ability.resume", effects: ToolFailureError.Effects.none))
                failure["run_id"] = .string(runID)
                return await checkpoint(.object(Self.partSettlementFailure(failure, error: error, operation: "ability.resume_holds", id: runID, root: root)),
                    consume: false)
            }
        }
        // Its queued step closes once the run is taken up or closed; a resume turned away busy leaves it open, so the run, its step and its holds wait on
        // together.
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
        func closed(_ reason: String, _ why: String) async -> JSONValue {
            await checkpoint(settled(Self.doorRefusal(reason, why + (preview ? " Resuming run \(runID) would close it; nothing was claimed or run."
                : " Run \(runID) is closed; nothing ran."), remedy: "none", """
                    Read the ability and affected state before choosing what remains; do not repeat completed effects.
                    """,
                extra: ["id": .string(id)])), consume: true)
        }
        let row: [String: JSONValue]?
        do { row = try Parts(root: root).row(id) }
        catch {
            let failure = Self.partFields(ChatToolOutcome.failure(error: error, tool: "ability.resume", effects: ToolFailureError.Effects.none))
            return await checkpoint(.object(Self.partSettlementFailure(failure, error: error, operation: "ability.resume_metadata", id: runID, root: root)),
                consume: false)
        }
        guard let row, row["status"] == .string("active"), row["codeFingerprint"] == run["digest"],
              run["hostRevision"] == .string(OwnedProgramStore.hostRevision), case .array(let journal)? = run["journal"] else {
            await closeStep()
            return await closed("script_changed", "\(name) changed or was switched off since run \(runID) stopped.")
        }
        let input = Self.partFields(run["input"])
        if Self.usedOutside(journal) { await closeStep(); return await closed("not_resumable", Self.unresumable) }
        if preview {
            // Retain the exact stopped call and step so the reply resumes at its original boundary.
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
        let turn = resumedTurn()
        do {
            let result = try await Parts(root: root).run(id: id, input: .object(input),
                requiredFingerprint: Self.doorText(run["digest"]),
                replay: OwnedProgramRunner.Replay(journal: journal, answer: args["answer"] ?? .null),
                invocation: execution.partInvocation(turn: turn, surface: surface))
            // A busy resume leaves the checkpoint untouched until its active call ends.
            if OwnedProgramRunner.turnedAway(result) {
                var out = Self.partFields(await Self.afterPartRun(result, id: id, input: input, surface: surface, root: root,
                                                                turn: turn, execution: execution))
                out["resume"] = .object(["run_id": .string(runID), "question": run["question"] ?? .null,
                                         "held": .array(try Self.deskRefs(journal, turn: turn).map(JSONValue.string))])
                out["resume_note"] = .string("Run \(runID) still waits; nothing of it ran. Resume it again once that call finishes.")
                return await checkpoint(.object(out), consume: false)
            }
            await closeStep()
            return await checkpoint(settled(await Self.afterPartRun(result, id: id, input: input, surface: surface, root: root,
                                                            turn: turn, execution: execution)), consume: true)
        } catch {
            return await checkpoint(ChatToolOutcome.failure(error: error, tool: "ability.resume"), consume: false)
        }
    }

    /// Preview reads SecurityCenter, explicit card requests and peer floors without filing a user card.
    @MainActor
    func doorWouldCard(_ action: AppAction, call: [String: JSONValue], input: [String: JSONValue], surface: String,
                       turn: Turn, execution: AppActionExecution) async throws -> Bool {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        // A folded action re-enters under its tool's own name; the rest are the app call's.
        let tool = action.isFold ? action.tool : "app"
        let args = action.isFold ? call : input.filter { $0.key != "preview" }
        let envelope = await SwiftNativeSecurityCenter(dataRoot: root).evaluateTool(
            tool: tool, input: MacInjectionArgRedaction.redacted(tool: tool, input: args, turn: turn),
            origin: AppChatToolDispatcher.securityOrigin(turn: turn, surface: surface), turn: turn)
        guard envelope.decision != .block else { return false }
        if envelope.requiresApproval { return true }
        if action.tool == "request_interaction",
           InlineInteractionNeed.interaction(in: await SwiftToolDispatcher.requestedInteraction(invocation: execution.invocation, input: call,
               dataRoot: root)) != nil {
            return true
        }
        let protectedAction = try PeerTurnEffectPolicy.requiresPeerApproval(tool, input: args, turn: turn)
        return PeerDataTaintDispatcher.peerApproval(turn: turn, surface: surface, protectedAction: protectedAction).required
    }
}

extension AppToolExecutor {
    /// Journaled writes identify the exact items a stopped run must hold.
    static func deskRefs(_ journal: [JSONValue], turn: Turn?) throws -> [String] {
        try journal.flatMap { entry -> [String] in
            guard case .object(let fields) = entry, case .array(let call)? = fields["call"], call.count > 2,
                  call[0] == .string("action"), case .string(let id) = call[1], case .string(let raw) = call[2] else { return [] }
            guard let action = try AppActions.action(id, turn: turn) else {
                throw ToolFailureError("""
                    Stopped-run action \(id) is not in the checked catalog. Read its journal before reconciling Desk holds.
                    """, effects: .none, code: "run_action_unavailable")
            }
            guard action.page == "desk", !action.read else { return [] }
            guard case .array(let given) = try JSONValue.parse(Data(raw.utf8)) else {
                throw ToolFailureError("Stopped-run Desk arguments are not an array. Repair its journal before reconciling holds.", effects: .none,
                    code: "run_arguments_unavailable")
            }
            let input = try AppScriptRunner.doorInput(id: id, given: given, turn: turn).get()
            let args = partFields(input["args"])
            return [args["handle"], args["id"]].compactMap { $0?.scalarText }
        }
    }
}
