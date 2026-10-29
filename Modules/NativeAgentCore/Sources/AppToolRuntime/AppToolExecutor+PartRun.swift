import AuthoredCapabilities
import ChatTurnContracts
import ChatTurnRuntime
import ChatToolRuntime
import ChatToolParsing
import Desk
import Dispatcher
import Foundation
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
// Blueprint: | `AppToolExecutor+PartRun.swift` | `AppToolExecutor`: a part's own run (`doorPart`: Desk holds, the gated `authored.<id>` with its in-flight turn's arrival check (a message or that turn's Stop), `afterPartRun`: MY QUEUE upgrade line, runner-owned effect reconciliation and action-owned version recovery, with fresh-run calls only for no effects, a strict stop kept to resume), `doorPartPreview` retains nested value-call version pins, `doorPartResume` (optional bare/action ability id checked before claiming its checkpoint; receipts name the bare id), `partAlias` (the older skill.*/tool.* doors and older spellings of a part's action, until the release after the one that ships one-part), `doorWouldCard`; stopped checkpoints delegate to Desk’s `PartRunStore` |

/// A part's run through its own action (`authored.<id>`): every call keeps
/// the turn's gates. Its preview runs its code with every write previewed;
/// a strict run that stops to ask is kept to resume; the run's own words
/// about the part (an upgrade it owes) reach MY QUEUE.
extension AppToolExecutor {
    /// The older doors, skill.* and tool.*, and a part's own action by an older
    /// spelling of its id or its name, as the one form's call: each answers
    /// through it and its receipt names the new call. The one place they
    /// resolve, for a turn's call and a part's code alike (`AppScriptRunner.Host`).
    /// Delete in the release after the one that ships one-part.
    static func partAlias(_ id: String, _ args: [String: JSONValue], root: URL, aliases: [String: String]? = nil) -> (id: String, args: [String: JSONValue])? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func partID(_ named: String) -> String? {
            if let aliases { return aliases[named.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] }
            return (try? Parts(root: root).row(named)).flatMap { $0?["id"] }?.scalarText
        }
        if let named = ToolNameAliases.authoredTool(id),
           let part = partID(named), part.lowercased() != named.lowercased() {
            return ("authored." + part, args)
        }
        let doors = ["skill.save": "ability.save", "tool.propose": "ability.save", "skill.read": "ability.read", "skill.list": "ability.list",
            "skill.validate": "ability.validate", "tool.validate": "ability.validate", "skill.enable": "ability.enable", "tool.approve": "ability.enable",
            "skill.restore": "ability.restore", "tool.restore": "ability.restore", "skill.disable": "ability.disable", "skill.quarantine": "ability.disable",
            "tool.quarantine": "ability.disable", "skill.rollback": "ability.rollback", "tool.rollback": "ability.rollback", "skill.drop": "ability.drop",
            "skill.delete": "ability.drop", "tool.drop": "ability.drop", "tool.reject": "ability.drop", "skill.resume": "ability.resume", "skill.run": "authored"]
        guard let door = doors[key] else { return nil }
        var out = door == "ability.save" ? Parts.saveArguments(args) : args
        for key in ["tool_id", "name"] where out["id"] == nil { if let named = out.removeValue(forKey: key) { out["id"] = named } }
        switch key {
        case "skill.read": for field in ["source", "content"] { out.removeValue(forKey: field) }
        case "tool.reject": out["pending"] = .bool(true)
        case "skill.run":
            let part = partID(doorText(out["id"])) ?? doorText(out["id"])
            return ("authored." + part, partFields(args["input"] ?? args["args"]))
        default: break
        }
        return (door, out)
    }

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
                guard let by = (try? await store.hold(ref, session: session)) ?? nil else { continue }
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
            if await doorWouldCard(action, call: args, input: input, surface: surface) { out["would_card"] = .bool(true) }
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
        let row = (try? Parts(root: root).row(id)) ?? nil
        let name = row.flatMap { Parts.fields(.object($0))["name"] }?.scalarText ?? id
        let voices = row.map(Parts.voices) ?? []
        out["name"] = .string(name)
        if case .string(let upgrade)? = out.removeValue(forKey: "upgrade") {
            let parts = upgrade.split(separator: "@", maxSplits: 1).map(String.init)
            _ = try? await MyQueue.add(DeskStep(words: "\(name) stopped on \(parts[0])\(parts.count > 1 && !parts[1].isEmpty ? " at \(parts[1])" : "") "
                + "in 2 of its last 3 runs; upgrade it?", when: "quiet", peers: voices, origin: "self"), store: SwiftNativeDeskStore(dataRoot: root))
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
        let kept = await PartRunStore.save(sealed, id: runID, root: root)
        guard kept else {
            out["resume_note"] = .string("The stopped run could not be saved; the store did not report a cause. Resume is unavailable. Inspect the affected state before starting a new run; completed effects must not be repeated.")
            out["resume_failure"] = .object(["status": .string("failed"), "reason": .string("run_save_failed"),
                "effects": .string("unknown"), "remedy": Repair.reconcile(
                    instruction: "Read the ability and compare its journal with the affected state before choosing a new run.",
                    nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("ability.read"), "args": .object(["id": .string(id)])])]))])
            return .object(out)
        }
        // The Desk items it touched stay its own until it is resumed or dropped:
        // another conversation that works one is told "held by run <id>".
        var held: [String] = []
        if let owner = session?.scalarText ?? ChatToolSessionContext.verifiedSessionId {
            held = (try? await SwiftNativeDeskStore(dataRoot: root).hold(deskRefs(calls), run: runID, session: owner)) ?? []
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
        if let named = args["id"]?.scalarText {
            do {
                let parts = Parts(root: root)
                guard let row = try parts.row(named), let id = row["id"]?.scalarText else {
                    let refusal = try parts.unknown(named)
                    return .object(refusal.fields.merging(["status": .string("refused")]) { $1 })
                }
                if let waiting = await PartRunStore.read(runID, root: root),
                   Self.doorText(waiting["skill"]) != id {
                    return Self.doorRefusal("wrong_ability", "\(runID) is not a stopped run of \(id). Nothing was claimed or run.",
                        remedy: "select_run", "Read the saved run ids and choose this ability's run_id.",
                        next: ["page": .string("tools")], extra: ["id": .string(id), "run_id": .string(runID)])
                }
            } catch { return ChatToolOutcome.failure(error: error, tool: "ability.resume") }
        }
        guard let run = await (preview ? PartRunStore.read(runID, root: root) : PartRunStore.take(runID, root: root)) else {
            return Self.doorRefusal("not_found",
                "No readable, valid stopped run was available for \(runID). The store did not distinguish absent, unreadable or invalid evidence. The ability did not run.",
                remedy: "inspect", "Read the saved run ids and the affected state before choosing a new run; do not repeat completed effects.",
                next: ["page": .string("tools")], extra: ["run_id": .string(runID), "execution": .string("not_run"),
                    "effects": .string(preview ? "none" : "unknown")])
        }
        let name = Self.doorText(run["name"]), id = Self.doorText(run["skill"])
        if run["status"] == .string("stopped"), run["reason"] == .string(DataRootLife.stoppedReason) {
            let input = Self.partFields(run["input"])
            if preview { return .object(["status": .string("stopped"), "reason": .string(DataRootLife.stoppedReason),
                "execution": .string("not_run"), "effects": .string("none"), "resume_mode": .string("fresh"),
                "run_id": .string(runID), "id": .string(id), "ability": .string(id), "input": .object(input)]) }
            do {
                let result = try await Parts(root: root).run(id: id, input: .object(input))
                return await Self.afterPartRun(result, id: id, input: input, session: session, surface: surface, root: root)
            } catch { return ChatToolOutcome.failure(error: error, tool: id) }
        }
        // Claimed in this life: its holds pass to the resuming conversation.
        let store = SwiftNativeDeskStore(dataRoot: root)
        let owner = preview ? nil : session?.scalarText ?? ChatToolSessionContext.verifiedSessionId
        var passed: [String: DeskHold] = [:]
        if let owner { passed = (try? await store.passHolds(run: runID, to: owner)) ?? [:] }
        // Its queued step closes once the run is taken up or closed; a resume turned away
        // busy leaves it open, so the run, its step and its holds wait on together.
        func closeStep() async {
            guard !preview, let state = try? await store.liveState() else { return }
            for entry in MyQueue.entries(state) where entry.step.words.hasPrefix(MyQueue.skillRunPrefix(skill: name, run: runID)) {
                try? await MyQueue.finish(entry, dropped: false, why: "resumed", store: store)
            }
        }
        func closed(_ reason: String, _ why: String) -> JSONValue {
            Self.doorRefusal(reason, why + (preview ? " Resuming run \(runID) would close it; nothing was claimed or run."
                : " Run \(runID) is closed; nothing ran."), remedy: "none", "Read the ability and affected state before choosing what remains; do not repeat completed effects.",
                extra: ["id": .string(id)])
        }
        let row = (try? Parts(root: root).row(id)) ?? nil
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
        let steer = PeerDataTaint.steer(in: run["steer"]), taint = PeerDataTaint.current ?? PeerDataTaint()
        steer.sources.forEach { taint.mark(peer: $0) }
        steer.elevated.forEach { taint.elevate(peer: $0) }
        do {
            return try await OwnedProgramRunner.$wake.withValue(run["wake"]) {
                let result = try await PeerDataTaint.$current.withValue(taint) {
                    try await Parts(root: root).run(id: id, input: .object(input), requiredFingerprint: Self.doorText(run["digest"]),
                        replay: OwnedProgramRunner.Replay(journal: journal, answer: args["answer"] ?? .null))
                }
                // Turned away, its slot busy: nothing of it ran, so it waits as it was, to resume once that call ends.
                if OwnedProgramRunner.turnedAway(result), await PartRunStore.save(run, id: runID, root: root) {
                    if let owner { try? await store.returnHolds(passed, from: owner) }
                    var out = Self.partFields(await Self.afterPartRun(result, id: id, input: input, session: session, surface: surface, root: root))
                    out["resume"] = .object(["run_id": .string(runID), "question": run["question"] ?? .null,
                                             "held": .array(Self.deskRefs(journal).map(JSONValue.string))])
                    out["resume_note"] = .string("Run \(runID) still waits; nothing of it ran. Resume it again once that call finishes.")
                    return .object(out)
                }
                await closeStep()
                return await Self.afterPartRun(result, id: id, input: input, session: session, surface: surface, root: root)
            }
        } catch { await closeStep(); return closed("integrity", error.localizedDescription) }
    }

    /// Whether the real call would file a card for User, read now and changing
    /// nothing: SecurityCenter's own reading of it, explicit card requests,
    /// and the peer floor on a turn a peer steered.
    @MainActor
    func doorWouldCard(_ action: AppAction, call: [String: JSONValue], input: [String: JSONValue], surface: String) async -> Bool {
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
        let protectedAction = PeerTurnEffectPolicy.requiresPeerApproval(tool, input: args)
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

    static func deskRefs(_ journal: [JSONValue]) -> [String] {
        journal.flatMap { entry -> [String] in
            guard case .object(let fields) = entry, case .array(let call)? = fields["call"], call.count > 2,
                  call[0] == .string("action"), case .string(let id) = call[1], case .string(let raw) = call[2],
                  let action = AppActions.action(id), action.page == "desk", !action.read,
                  case .array(let given)? = try? JSONValue.parse(Data(raw.utf8)),
                  case .success(let input) = AppScriptRunner.doorInput(id: id, given: given) else { return [] }
            let args = partFields(input["args"])
            return [args["handle"], args["id"]].compactMap { $0?.scalarText }
        }
    }
}
