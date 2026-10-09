import ChatOrchestration
import CryptoKit
import Desk
import Dispatcher
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Skills
import Senses
import ToolRegistry
import TrustCenter

/// `skill.run` and `skill.resume` (skills-as-code PR 3): a runnable script
/// skill runs as a strict run (`AppScriptRunner`) on frozen args its header's
/// params check. Each call it makes is checked here, natively, before it is
/// dispatched: one outside the skill's declared actions stops the run
/// (not_declared), one that never runs inside a skill stops it
/// (denied_in_skill), and one that can't be taken back or is User's hands its
/// step back to her before it runs. A gate that would card hands back too
/// (`SkillRunContext`), so a skill never files a card. A run that stops to ask
/// or hands back is kept (`SkillRunStore`), and `skill.resume` goes on from
/// there with her answer.
extension AppToolExecutor {
    /// Never inside a skill, declared or not, unless it only reads: a run never
    /// starts or edits a skill, changes what she or anything may do (settings,
    /// Trust, cards, tools, connectors, providers, chat controls), sends, or
    /// reaches past the app (her authored tools, MCP). By the page word an id
    /// starts with; gcal's one send; and the passes that stage User's
    /// approvals as they go (dream, REM, self-improvement, consolidation,
    /// hygiene, repair), which swallow a hand-back and report done.
    static let deniedInSkill: Set<String> = [
        "skill", "tool", "setting", "card", "connector", "telegram", "pairing", "mcp", "authored", "chat", "provider",
        "agent", "codex", "omp", "mail", "agentmail", "messages", "slack", "notify", "phone", "inbox",
        "gcal.send_invitations", "mind.dream", "mind.rem", "mind.self_improvement", "memory.consolidate",
        "memory.hygiene", "doctor.repair",
    ]

    /// The stops a run is kept for, to resume: her decision, or a step handed back.
    static let skillHandBacks: Set<String> = ["decide", "irreversible", "users_step", "would_card"]

    /// A run's stops that are the skill's own fault (skills-as-code PR 5): its
    /// logic was wrong (an expect, an expect_fail, a return it can't hand
    /// back, a version it never read), it called past its header or the app
    /// (not_declared, denied_in_skill, an action gone, its own bad args), or
    /// a resume took another path. Never the world's: a stale version, a
    /// changed read, User's no, a provider down, a hand-back, a decide, a timeout.
    static let skillFaults: Set<String> = [
        "expect_failed", "expected_failure_not_seen", "expected_failure_succeeded", "expect_fail_async",
        "expect_fail_nested", "expect_fail_one_call", "not_declared", "denied_in_skill", "unknown_action",
        "unknown_arg", "invalid_args", "missing_arg", "diverged", "not_own_version", "no_own_read", "unreadable_return",
    ]

    /// The skill's own fault a finished run's receipt shows, or nil; a script
    /// error its own JavaScript threw is one too.
    static func skillFault(_ receipt: [String: JSONValue]) -> String? {
        let status = doorText(receipt["status"]), reason = doorText(receipt["reason"])
        if status == "error", reason.isEmpty { return "script_error" }
        return status != "ok" && skillFaults.contains(reason) ? reason : nil
    }

    /// The upkeep a turn that lists or runs skills does (PR 5), for every kind
    /// (`CapabilityLifecycle`): one MY QUEUE line for each skill suspended for
    /// an action gone, and each skill or tool she wrote archived unused.
    static func skillUpkeep(root: URL) async {
        await queueSkillLines(((try? await SwiftNativeSkillsClient(root: root).upkeep(missing: { AppActions.action($0) == nil })) ?? [])
                              + ((try? await ToolRegistryActions.upkeep(dataRoot: root)) ?? []).map { ($0, []) }, root: root)
        if let registry = SensesHub.shared.registry as? any SenseRegistryManaging {
            do { _ = try await registry.archiveUnused(now: Date()) }
            catch { FileHandle.standardError.write(Data("Sense upkeep: \(error)\n".utf8)) }
        }
    }

    /// One quiet MY QUEUE line each for what upkeep did to skills and tools,
    /// and their upgrade signals (`when: quiet`: shown on her next ordinary
    /// turn, never waking her), and recall reconciled; whether every line queued.
    @discardableResult
    static func queueSkillLines(_ lines: [SkillLine], root: URL) async -> Bool {
        guard !lines.isEmpty else { return false }
        let store = SwiftNativeDeskStore(dataRoot: root)
        var queued = true
        // A line naming a peer's or a pack's skill is filed as theirs (masked title, taint latch).
        for line in lines where (try? await MyQueue.add(DeskStep(words: line.words, when: "quiet", peers: line.peers), store: store)) == nil {
            queued = false
        }
        try? await NativeSkillRegistryActions.reconcileSkillEvolutionRecall(
            memory: SwiftNativeMemoryV2.resolvedOwner(dataRoot: root), dataRoot: root,
            personaRoot: defaultPersonaRoot(dataRoot: root))
        return queued
    }

    static func skillFields(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let fields)? = value { fields } else { [:] }
    }

    /// Where a run stopped, as the notice says it: its labeled step, else the script line.
    static func stopPlace(_ out: [String: JSONValue]) -> String {
        let step = doorText(skillFields(out["hand_back"])["step"])
        if !step.isEmpty { return step.hasPrefix("step") ? step : "step " + step }
        let line = doorText(skillFields(out["stopped"])["line"])
        return line.isEmpty ? "" : "line " + line
    }

    static func isDeniedInSkill(_ id: String) -> Bool {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ToolNameAliases.authoredTool(key) != nil || ToolNameAliases.mcpTool(key) != nil
            || ToolNameAliases.foldedTools.contains(where: { $0.key.hasPrefix("mcp__") && $0.value == key }) { return true }
        if AppActions.action(key)?.read == true { return false }
        return deniedInSkill.contains(key) || deniedInSkill.contains(String(key.split(separator: ".").first ?? ""))
    }

    /// One call of a skill's run, before it is dispatched: nil runs it.
    static func skillStep(_ id: String, declared: Set<String>, preview: Bool) -> JSONValue? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isDeniedInSkill(key) {
            return doorRefusal("denied_in_skill", "\(key) never runs inside a skill; it was not run.",
                remedy: "run_alone", "Make that call yourself, outside the skill, if you still want it.")
        }
        guard declared.contains(key) else {
            return doorRefusal("not_declared", "\(key) is not among the actions this skill declares; it was not run.",
                remedy: "none", "The skill's script calls what its header doesn't declare: fix the skill.")
        }
        // An action no flag marks (none in the registry now) counts as irreversible.
        let action = AppActions.action(key)
        guard action?.irreversible != false || action?.isHis == true else { return nil }
        let why = action?.isHis == true ? "users_step" : "irreversible"
        let detail = why == "users_step"
            ? "\(key) is User's, so a skill hands it back to you before it runs: it was not run."
            : "\(key) can't be taken back, so a skill hands it back to you before it runs: it was not run."
        if preview {
            return .object(["status": .string("preview"), "action": .string(key), "would_hand_back": .string(why),
                            "effects": .string("none"), "detail": .string(detail)])
        }
        return .object(["status": .string("not_run"), "reason": .string(why), "not_run_status": .string(why),
                        "effects": .string("none"), "detail": .string(detail)])
    }

    /// One declared action as its pin hashes it: its args and schema, its
    /// flags and revision, and the tool, input and rename it maps to (its
    /// words are not its shape).
    static func actionPin(_ id: String) -> String {
        guard let action = AppActions.action(id) else { return "missing" }
        var fields: [String: JSONValue] = [
            "id": .string(action.id), "page": .string(action.page), "args": .array(action.args.map(JSONValue.string)),
            "his": .bool(action.isHis), "irreversible": .bool(action.irreversible), "screen": .bool(action.screen),
            "safe": .bool(action.safe), "scriptable": .bool(action.scriptable), "read": .bool(action.read),
            "version_exempt": .bool(action.versionExempt), "revision": .int(Int64(action.revision)),
            "tool": .string(action.tool), "input": .object(action.input),
            "rename": .object(action.rename.mapValues(JSONValue.string)),
            "schema": AppActions.foldSchemas[action.tool].flatMap { try? JSONValue.parse($0.parametersJSON) } ?? .null,
        ]
        if !action.readWhen.isEmpty { fields["read_when"] = .object(action.readWhen) }
        return SHA256.hash(data: (try? JSONValue.object(fields).serializedData(pretty: false)) ?? Data())
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Why `args` doesn't fit the header's params, or nil.
    static func paramsMismatch(_ params: [String: JSONValue], _ args: [String: JSONValue]) -> String? {
        if let stray = args.keys.sorted().first(where: { params[$0] == nil }) { return "it takes no \(stray)" }
        for name in params.keys.sorted() {
            guard case .string(let spelled)? = params[name] else { continue }
            let type = spelled.hasSuffix("?") ? String(spelled.dropLast()) : spelled
            guard let value = args[name], value != .null else {
                if spelled.hasSuffix("?") { continue }
                return "\(name) (\(type)) is missing"
            }
            let fits = switch (type, value) {
            case ("string", .string), ("int", .int), ("number", .int), ("number", .double), ("bool", .bool),
                 ("list", .array), ("object", .object): true
            default: false
            }
            if !fits { return "\(name) is a\(type == "int" || type == "object" ? "n" : "") \(type)" }
        }
        return nil
    }

    private struct SkillScriptRun {
        let id: String
        let name: String
        let source: String
        let params: [String: JSONValue]
        let actions: [String]
        let digest: String
        /// The admission it runs under, as it read when the run started.
        let admission: JSONValue?
        /// Whose words its name is, for a line about it (`SkillScript.voices`).
        let voices: [String]
        /// Why it isn't on, for a preview of one that isn't; nil when it runs.
        var off: String?
    }

    /// `skill.run {name, args}` and `skill.resume {run_id, answer}`.
    @MainActor
    func doorSkill(_ id: String, args: [String: JSONValue], input: [String: JSONValue], surface: String) async -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let preview = input["preview"] == .bool(true)
        guard id == "skill.run" else {
            guard !preview else {
                return Self.doorRefusal("not_previewable", "A resume runs; there is nothing to preview. Nothing ran.",
                    remedy: "correct_arguments", "Preview the skill itself with skill.run and preview:true.")
            }
            return await doorSkillResume(args, session: input["__session_id"], surface: surface, root: root)
        }
        let given: [String: JSONValue]
        switch args["args"] {
        case .object(let object)?: given = object
        case nil: given = [:]
        default:
            return Self.doorRefusal("invalid_args", "args is an object, the skill's params by name. Nothing ran.",
                remedy: "correct_arguments", "Call skill.run again with args as an object.")
        }
        if !preview, await Self.freshQuietPosture(dataRoot: root)?.changesAllowed == true {
            await Self.skillUpkeep(root: root)
        }
        let loaded = await loadSkillScript(Self.doorText(args["name"]), preview: preview, root: root)
        guard let skill = loaded.skill else { return loaded.refusal ?? .null }
        if let mismatch = Self.paramsMismatch(skill.params, given) {
            return Self.doorRefusal("invalid_args", "\(skill.name)'s args don't fit its params: \(mismatch). Nothing ran.",
                remedy: "correct_arguments", "Pass args as its signature shows (skill.list).")
        }
        // A Desk item it is given that another conversation works stays theirs: it doesn't run.
        if !preview, let session = Self.inputString(input["__session_id"]) ?? ChatToolSessionContext.verifiedSessionId {
            let store = SwiftNativeDeskStore(dataRoot: root)
            for ref in Self.deskRefs(.object(given)) {
                guard let by = (try? await store.hold(ref, session: session)) ?? nil else { continue }
                return Self.doorRefusal("held_by", "\(ref) is held by \(by), which is working it. Nothing ran.",
                    remedy: "none", "Leave it to that one, or pick it up there.", extra: ["held_by": .string(by)])
            }
        }
        let runID = "run-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return await runSkillScript(skill, input: given, runID: runID, preview: preview, replay: nil,
                                    session: input["__session_id"], surface: surface, root: root)
    }

    /// The script skill `name` names, runnable now with its pin checked, or why not.
    /// A preview also takes one drafted, not admitted for its script, or
    /// suspended: it dispatches no write, so its checks show where it would stop.
    @MainActor
    private func loadSkillScript(_ name: String, preview: Bool = false, root: URL) async -> (skill: SkillScriptRun?, refusal: JSONValue?) {
        func refuse(_ reason: String, _ detail: String, _ instruction: String) -> (SkillScriptRun?, JSONValue?) {
            (nil, Self.doorRefusal(reason, detail + " Nothing ran.", remedy: "none", instruction))
        }
        let entries: [InstalledSkillInventory.Entry]
        do {
            entries = try InstalledSkillInventory.entries(dataRoot: root)
        } catch {
            return refuse("skills_unreadable", "The skill registry didn't read (\(error.localizedDescription)).",
                          "app skill.list shows what reads now.")
        }
        guard let entry = InstalledSkillInventory.match(name, in: entries) else {
            return refuse("unknown_skill", "No skill is called \(name.isEmpty ? "(none passed)" : name).",
                          "app skill.list shows the skills by name.")
        }
        guard case .object(let script)? = entry.row["script"], let digest = SkillScript.digest(entry.row["script"]),
              case .string(let source)? = script["source"] else {
            return refuse("not_a_script", "\(entry.name) is guidance with no script, so it doesn't run.",
                          "Read it with skill.read and follow it yourself.")
        }
        let status = Self.doorText(entry.row["status"]).lowercased()
        var off: String?
        if !entry.isRunnable {
            let why: String
            if case .object(let suspended)? = entry.row["suspended"], case .array(let changed)? = suspended["actions"] {
                why = "suspended: \(changed.compactMap(Self.inputString).joined(separator: ", ")) changed since it was admitted"
            } else if status == "draft" {
                why = "drafted: no admission binds its script"
            } else if InstalledSkillInventory.isAvailable(entry.row) {
                why = "not admitted for its exact script"
            } else {
                why = "off (\(status))"
            }
            guard preview, status == "draft" || InstalledSkillInventory.isAvailable(entry.row) else {
                return refuse("not_runnable", "\(entry.name) is \(why), so it doesn't run.",
                    "skill.enable turns it on for its exact script: yours for your own script under Full Mac, else User's on the Skills page.")
            }
            off = why
        }
        let declared: [JSONValue] = if case .array(let ids)? = script["actions"] { ids } else { [] }
        let actions = declared.compactMap(Self.inputString)
        // Each action pinned as it was at its first run under this digest; any
        // change suspends it. A preview only compares the existing pins.
        var changed: [String] = []
        if off == nil {
            let pins = Dictionary(actions.map { ($0, Self.actionPin($0)) }) { first, _ in first }
            if preview {
                if case .object(let pin)? = entry.row["actionPin"], pin["digest"] == .string(digest),
                   case .object(let held)? = pin["actions"] {
                    let wanted = pins.mapValues(JSONValue.string)
                    changed = Set(held.keys).union(wanted.keys).filter { held[$0] != wanted[$0] }.sorted()
                }
            } else {
                do {
                    changed = try await SwiftNativeSkillsClient(root: root).pinActions(id: entry.id, digest: digest, pins: pins)
                } catch {
                    return refuse("not_runnable", "\(entry.name) didn't pin its actions (\(error.localizedDescription)).",
                                  "app skill.list shows its state now.")
                }
            }
        }
        if !changed.isEmpty {
            if preview {
                return refuse("suspended",
                    "\(entry.name)'s actions changed since its script was admitted: \(changed.joined(separator: ", ")). "
                        + "A real run would suspend it for review. This preview changed nothing.",
                    "Read what changed and check the script still fits before running it.")
            }
            let queued = await Self.queueSkillLines([("\(entry.name) suspended: \(changed.joined(separator: ", ")) changed; re-review",
                                                      SkillScript.voices(entry.row))],
                                                    root: root)
            return refuse("suspended",
                "\(entry.name) is suspended: \(changed.joined(separator: ", ")) changed since its script was admitted, "
                    + "so it doesn't run. It is drafted until skill.enable admits it again"
                    + (queued ? "; MY QUEUE says so." : "."),
                "Read what changed, check the script still fits, then skill.enable admits it again.")
        }
        for action in actions where Self.isDeniedInSkill(action) || AppActions.action(action)?.scriptable != true {
            return refuse(Self.isDeniedInSkill(action) ? "denied_in_skill" : "not_scriptable",
                "\(entry.name) declares \(action), which never runs inside a skill.",
                "Fix the skill: its script makes that call nowhere, or you make it yourself outside the skill.")
        }
        // A write a skill runs takes the version of its own read of that page;
        // one whose page has no version to check runs only if it is exempt.
        // (A step that is User's or can't be taken back hands back before it runs.)
        for id in actions {
            guard let action = AppActions.action(id), !action.read, !action.versionExempt, !action.irreversible,
                  !action.isHis, action.page == "*" || doorPage(action.page) == nil else { continue }
            return refuse("unversioned_write",
                "\(entry.name) declares \(action.id), a write with no page version a skill can check.",
                "Fix the skill: a skill's write goes on the version of its own read, so that step is yours, outside the skill.")
        }
        return (SkillScriptRun(id: entry.id, name: entry.name, source: source,
                               params: Self.skillFields(script["params"]), actions: actions, digest: digest,
                               admission: entry.row["admission"], voices: SkillScript.voices(entry.row), off: off), nil)
    }

    /// Runs it strict, each call checked before it is dispatched; keeps a run
    /// that stopped to ask or hand back, to resume.
    @MainActor
    private func runSkillScript(_ skill: SkillScriptRun, input: [String: JSONValue], runID: String, preview: Bool,
                                replay: AppScriptRunner.Replay?, session: JSONValue?, surface: String,
                                root: URL) async -> JSONValue {
        guard let perform = AppDoorReentry.perform else {
            return Self.doorRefusal("door_unavailable",
                "This call did not come through a chat's tool chain, so it has no gate to pass. Nothing ran.",
                remedy: "none", "Use app from a chat turn.")
        }
        let declared = Set(skill.actions)
        let versions = SkillRunVersions(journal: replay?.journal ?? [])
        let receipt = await SkillRunContext.$handsBack.withValue(true) {
            await DoorNotesSnapshot.$current.withValue(DoorNotesSnapshot()) {
                await AppScriptRunner.run(source: skill.source, preview: preview, strict: true, input: .object(input),
                                          replay: replay) { call in
                    var call = call
                    if case .string(let id)? = call["action"] {
                        if let stop = Self.skillStep(id, declared: declared, preview: preview) { return stop }
                        if let refused = versions.prepare(&call, id: id) { return refused }
                    }
                    if let session { call["__session_id"] = session }
                    let result: JSONValue
                    do { result = try await perform("app", call) } catch { result = ChatToolOutcome.failure(error: error, tool: "app") }
                    versions.observe(call, result)
                    return result
                }
            }
        }
        guard case .object(var out) = receipt else { return receipt }
        let journal = out.removeValue(forKey: "journal")
        out["skill"] = .string(skill.name)
        out["run_id"] = .string(runID)
        if let off = skill.off {
            out["not_on"] = .string("A preview of \(skill.name), which isn't on: it is \(off). It shows where a run would stop; "
                + "a real run is refused until skill.enable turns it on.")
        }
        if preview, case .array(let calls)? = out["calls"] {
            out["would"] = .array(calls.compactMap { row -> JSONValue? in
                guard case .object(let fields) = row, fields["would_card"] == .bool(true) || fields["would_hand_back"] != nil
                else { return nil }
                return .object(fields.filter { ["n", "step", "call", "would_card", "would_hand_back"].contains($0.key) })
            })
        }
        let reason = Self.doorText(out["reason"])
        // What the run says about the skill: a fault of its own (two in a row
        // retire it), the world's, or clean, a rung on the trust ladder.
        if !preview {
            out["script_effects"] = out["effects"]
            out["bookkeeping"] = .string("Skill lifecycle and upkeep.")
            if out["effects"] == .string("none") { out["effects"] = .string("unknown") }
            let fault = Self.skillFault(out)
            let hash = SHA256.hash(data: (try? JSONValue.object(input).serializedData(pretty: false)) ?? Data())
                .map { String(format: "%02x", $0) }.joined()
            if let kept = try? await SwiftNativeSkillsClient(root: root).recordRun(
                id: skill.id, runID: runID, digest: skill.digest, admission: skill.admission, fault: fault,
                clean: fault == nil && out["status"] == .string("ok"), reason: reason.isEmpty ? Self.doorText(out["status"]) : reason,
                step: Self.stopPlace(out), inputHash: String(hash.prefix(16))) {
                if out["script_effects"] == .string("none") { out["effects"] = .string("occurred") }
                out["ladder"] = .object(["clean": .int(Int64(kept.clean)), "of": .int(3)])
                await Self.queueSkillLines(kept.signals, root: root)
                if kept.retired {
                    let words = "\(skill.name) retired: a fault of its own twice in a row (\(fault ?? reason)); "
                        + "archived, not deleted. Fix its script, then skill.enable"
                    let queued = await Self.queueSkillLines([(words, skill.voices)], root: root)
                    out["retired"] = .string(words + (queued ? "; MY QUEUE says so." : "."))
                }
            }
        }
        // Its own version no longer reads: what was, what is, and where; never a fresh re-read.
        if reason == "stale_version", let difference = versions.mismatch {
            var back = Self.skillFields(out["hand_back"])
            back["difference"] = .object(difference)
            out["hand_back"] = .object(back)
            let target = Self.doorText(difference["target"])
            let parts = target.split(separator: "/", maxSplits: 1).map { JSONValue.string(String($0)) }
            var read: [String: JSONValue] = ["page": parts.first ?? .string(target)]
            if parts.count > 1 { read["item"] = parts[1] }
            out["remedy"] = .object([
                "kind": .string("reread"),
                "instruction": .string((out["changed"] == nil ? "" : "The calls in changed took effect; don't run them again. ")
                    + "\(target) changed since this run's own read (hand_back.difference: was, now), so that write didn't run "
                    + "and nothing more did. Read it, decide whether the skill still fits, then run it again."),
                "next_call": .object(["tool": .string("app"), "input": .object(read)]),
            ])
        }
        if reason == "state_changed" {
            out["remedy"] = .object([
                "kind": .string("run_again"),
                "instruction": .string("Something it read before it stopped reads differently now, so nothing more ran and "
                    + "the run is closed. Read what changed; if the skill still fits, run it again from the start."),
                "next_call": .object(["tool": .string("app"), "input": .object([
                    "action": .string("skill.run"), "args": .object(["name": .string(skill.name), "args": .object(input)]),
                ])]),
            ])
        }
        guard !preview, out["status"] == .string("stopped"), Self.skillHandBacks.contains(reason),
              case .array(let calls)? = journal else { return .object(out) }
        let back = Self.skillFields(out["hand_back"])
        let question = [back["question"], Self.skillFields(out["stopped"])["detail"]].lazy.map(Self.doorText)
            .first { !$0.isEmpty } ?? reason
        // Sealed, with the steer of the turn it ran on: a resume takes that steer on.
        let kept = await SkillRunStore.save([
            "run_id": .string(runID), "skill": .string(skill.id), "name": .string(skill.name), "digest": .string(skill.digest),
            "input": .object(input), "journal": .array(calls), "question": .string(question), "reason": .string(reason),
            "at": .string(ISO8601DateFormatter().string(from: Date())),
            "steer": PeerDataTaint.carriedRecord(peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                                 peerID: ChatToolSessionContext.envelope?.verifiedUserId),
        ], id: runID, root: root)
        guard kept else {
            out["resume_note"] = .string("This run is too large to keep, so it can't be resumed: run it again once you've done what it asked.")
            return .object(out)
        }
        // The Desk items it touched stay its own until it is resumed or dropped:
        // another conversation that works one is told "held by run <id>".
        var held: [String] = []
        if let owner = Self.inputString(session) ?? ChatToolSessionContext.verifiedSessionId {
            held = (try? await SwiftNativeDeskStore(dataRoot: root).hold(Self.deskRefs(calls), run: runID, session: owner)) ?? []
        }
        out["resume"] = .object(["run_id": .string(runID), "question": .string(question),
                                 "held": .array(held.map(JSONValue.string))])
        let took = out["changed"] == nil ? "" : "The calls in changed took effect; don't run them again. "
        out["remedy"] = .object([
            "kind": .string("resume"),
            "instruction": .string(took + (reason == "decide"
                ? "It stopped to ask you hand_back.question: answer with skill.resume {run_id, answer}, and app.decide returns your answer."
                : "It handed hand_back's step back before it ran: do it yourself as its own app call if you still want it, "
                    + "then skill.resume {run_id, answer} goes on, the step returning your answer.")
                + " A resume reads again everything it read, and goes on only if it all reads the same."),
            "next_call": .object(["tool": .string("app"), "input": .object([
                "action": .string("skill.resume"), "args": .object(["run_id": .string(runID)]),
            ])]),
        ])
        return .object(out)
    }

    /// `skill.resume`: claimed once, sealed, the same digest, still runnable
    /// and its input still fitting; the turn takes on the steer it ran under.
    /// Then the script runs again: what it read is read again live, and it
    /// goes on only if all of it reads the same (`AppScriptRunner.Replay`).
    @MainActor
    private func doorSkillResume(_ args: [String: JSONValue], session: JSONValue?, surface: String,
                                 root: URL) async -> JSONValue {
        let runID = Self.doorText(args["run_id"])
        guard runID.range(of: "^run-[0-9a-f]{8}$", options: .regularExpression) != nil,
              let run = await SkillRunStore.take(runID, root: root) else {
            return Self.doorRefusal("not_found",
                "No stopped skill run \(runID.isEmpty ? "(none passed)" : runID) is waiting: it finished, was resumed, "
                    + "or is older than the newest \(SkillRunStore.keep). Nothing ran.",
                remedy: "none", "Run the skill again with skill.run.")
        }
        // Claimed: from here the run is closed unless it stops again, and what
        // it held is the resuming conversation's.
        let name = Self.doorText(run["name"])
        let store = SwiftNativeDeskStore(dataRoot: root)
        if let owner = Self.inputString(session) ?? ChatToolSessionContext.verifiedSessionId {
            try? await store.passHolds(run: runID, to: owner)
        }
        if let state = try? await store.liveState() {
            for entry in MyQueue.entries(state) where entry.step.words.hasPrefix(MyQueue.skillRunPrefix(skill: name, run: runID)) {
                try? await MyQueue.finish(entry, dropped: false, why: "resumed", store: store)
            }
        }
        func closed(_ reason: String, _ why: String) -> JSONValue {
            Self.doorRefusal(reason, why + " Run \(runID) is closed; nothing ran.", remedy: "none",
                             "Run it again from the start with skill.run.")
        }
        let loaded = await loadSkillScript(Self.doorText(run["skill"]), root: root)
        guard let skill = loaded.skill else {
            return closed(Self.doorText(Self.skillFields(loaded.refusal)["reason"]),
                          Self.doorText(Self.skillFields(loaded.refusal)["detail"]).replacingOccurrences(of: " Nothing ran.", with: ""))
        }
        guard skill.digest == Self.doorText(run["digest"]), case .array(let journal)? = run["journal"] else {
            return closed("script_changed", "\(name)'s script changed since run \(runID) stopped.")
        }
        let input = Self.skillFields(run["input"])
        if let mismatch = Self.paramsMismatch(skill.params, input) {
            return closed("invalid_args", "\(name)'s args no longer fit its params: \(mismatch).")
        }
        let steer = PeerDataTaint.steer(in: run["steer"])
        steer.sources.forEach { PeerDataTaint.markConsumed(peer: $0) }
        steer.elevated.forEach { PeerDataTaint.markElevated(peer: $0) }
        return await runSkillScript(skill, input: input, runID: runID, preview: false,
                                    replay: AppScriptRunner.Replay(journal: journal, answer: args["answer"] ?? .null),
                                    session: session, surface: surface, root: root)
    }

    /// `skill.read {name, step}` (PR 5): one step of a script skill, its label
    /// and guidance, and its lines when each `app.step` call starts a line of
    /// its own and there is one per step; otherwise its label alone.
    static func skillStepRead(_ name: String, step: JSONValue?, root: URL) -> JSONValue {
        guard let entry = (try? InstalledSkillInventory.entries(dataRoot: root)).flatMap({ InstalledSkillInventory.match(name, in: $0) }) else {
            return doorRefusal("unknown_skill", "No skill is called \(name.isEmpty ? "(none passed)" : name).",
                               remedy: "none", "app skill.list shows the skills by name.")
        }
        guard case .object(let script)? = entry.row["script"], case .string(let source)? = script["source"] else {
            return doorRefusal("not_a_script", "\(entry.name) is guidance with no steps.",
                               remedy: "correct_arguments", "Read it whole with skill.read {name}.")
        }
        let of = if case .int(let n)? = script["of"] { Int(n) } else { 1 }
        guard case .int(let n)? = step, (1...max(of, 1)).contains(Int(n)) else {
            return doorRefusal("invalid_args", "step is 1 to \(of) for \(entry.name).",
                               remedy: "correct_arguments", "Call skill.read again with a step in range.")
        }
        let at = Int(n) - 1
        let lines = source.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0].contains("app.step(") }
        let clean = starts.count == of && starts.allSatisfy { lines[$0].components(separatedBy: "app.step(").count == 2 }
        // Its label and guidance as written, when they are plain strings.
        let literal = #"app\.step\(\s*(["'`])((?:\\.|(?!\1).)*)\1(?:\s*,\s*(["'`])((?:\\.|(?!\3).)*)\3)?"#
        var said: [String] = []
        if clean, let regex = try? NSRegularExpression(pattern: literal) {
            let line = lines[starts[at]]
            if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                said = [2, 4].map { match.range(at: $0).location == NSNotFound ? "" : (Range(match.range(at: $0), in: line).map { String(line[$0]) } ?? "") }
            }
        }
        let labels: [String] = if case .array(let given)? = script["steps"] { given.compactMap(inputString) } else { [] }
        var out: [String: JSONValue] = ["status": .string("ok"), "skill": .string(entry.name), "step": .string("\(n) of \(of)")]
        let label = labels.indices.contains(at) ? labels[at] : said.first ?? ""
        if !label.isEmpty { out["label"] = .string(label) }
        if said.count > 1, !said[1].isEmpty { out["guidance"] = .string(said[1]) }
        if clean {
            let end = at + 1 < starts.count ? starts[at + 1] : lines.count
            out["lines"] = .string("\(starts[at] + 1)-\(end)")
            out["source"] = .string(lines[starts[at]..<end].joined(separator: "\n"))
        } else {
            out["note"] = .string("Its app.step calls don't each start a line of their own, one per step, so this is its label alone; "
                + "skill.read {name} reads it whole.")
        }
        return .object(out)
    }

    /// Whether the real call would file a card for User, read now and changing
    /// nothing: SecurityCenter's own reading of it with Trust's saved level,
    /// the persona guard, explicit card requests, and the peer floor on a turn a peer steered.
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
        if envelope.requiresApproval || PersonaWriteGuard.shouldUpgradeToConfirm(
            tool: tool, kind: Self.inputString(args["kind"]),
            personaSettingWrite: PeerTurnEffectPolicy.isPersonaSettingWrite(tool: tool, input: args),
            resolvedAutonomy: envelope.autonomyLevel,
            hasExplicitAutonomyOverride: envelope.fullMacYoloAuthority == .admitted) { return true }
        if action.tool == "request_interaction",
           InlineInteractionNeed.interaction(in: await SwiftToolDispatcher.requestedInteraction(input: call, dataRoot: root)) != nil {
            return true
        }
        let steer = PeerDataTaint.carried(peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                          peerID: ChatToolSessionContext.envelope?.verifiedUserId)
        guard !(steer.sources + steer.elevated).isEmpty else { return false }
        return PeerTurnEffectPolicy.requiresPeerApproval(tool, capabilities: envelope.capabilities, input: args,
            fullMac: [.admitted, .untrustedOrigin].contains(envelope.fullMacYoloAuthority))
    }
}

/// A skill run's own versions (skills-as-code PR 4): each page's newest, by
/// the run's own reads and its own writes' page_version. A write that needs
/// one takes the run's own, so read → write → write goes on without a re-read;
/// there is never a fresh one, and a version the run never read is refused.
final class SkillRunVersions: @unchecked Sendable {
    private let lock = NSLock()
    private var newest: [String: String] = [:]
    private var seen: Set<String> = []
    private var stale: [String: JSONValue]?

    init(journal: [JSONValue]) { AppScriptRunner.ownVersions(journal).forEach(note) }

    private func note(_ version: String) {
        lock.withLock {
            newest[String(AppScriptRunner.versionScope(version).split(separator: "/").first ?? "")] = version
            seen.insert(version)
        }
    }

    /// The write with the run's own version, or why it doesn't run.
    func prepare(_ call: inout [String: JSONValue], id: String) -> JSONValue? {
        let args: [String: JSONValue] = if case .object(let args)? = call["args"] { args } else { [:] }
        guard let action = AppActions.action(id), !action.readOnly(args: args), !action.versionExempt else { return nil }
        let given = AppToolExecutor.doorText(call["expected_version"])
        return lock.withLock { () -> JSONValue? in
            if !given.isEmpty {
                guard !seen.contains(given) else { return nil }
                return AppToolExecutor.doorRefusal("not_own_version",
                    "\(action.id) passed a version this run never read; a skill's write goes on its own read's version. It was not run.",
                    remedy: "none", "Fix the skill: leave expected_version out, or pass the one its own read returned.")
            }
            guard let version = newest[action.page] else {
                return AppToolExecutor.doorRefusal("no_own_read",
                    "\(action.id) changes \(action.page), which this run has not read; a skill's write goes on its own read's version. "
                        + "It was not run.",
                    remedy: "none", "Fix the skill: read \(action.page) (app.read(\"\(action.page)\")) before this step.")
            }
            call["expected_version"] = .string(version)
            return nil
        }
    }

    /// A page read's version, or a write's page_version, is the run's own from here.
    func observe(_ call: [String: JSONValue], _ result: JSONValue) {
        guard case .object(let fields) = result else { return }
        if call["action"] == nil, call["page"] != nil, let version = AppToolExecutor.inputString(fields["version"]) { note(version) }
        if ChatToolOutcome.outputLooksSuccessful(result), let version = AppToolExecutor.inputString(fields["page_version"]) {
            note(version)
        }
        if AppToolExecutor.doorText(fields["reason"]) == "stale_version" {
            let was = AppToolExecutor.doorText(fields["expected_version"])
            lock.withLock {
                stale = ["target": .string(AppScriptRunner.versionScope(was)), "was": .string(was),
                         "now": fields["current_version"] ?? .null]
            }
        }
    }

    /// The last write whose own version no longer read: target, was, now.
    var mismatch: [String: JSONValue]? { lock.withLock { stale } }
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
            let args = skillFields(input["args"])
            return [args["handle"], args["id"]].compactMap { inputString($0) }
        }
    }
}

/// Stopped skill runs, kept to resume: one file each under skills/runs in
/// the data root, sealed (`seal`), at most 256 KB, the newest 50.
/// The seal stops edits, not a local writer: whoever can write the data root can read the 0600 key beside it.
enum SkillRunStore {
    static let keep = 50
    static let byteLimit = 256 * 1024

    static func file(_ id: String, root: URL) -> URL {
        SwiftNativeDeskStore.skillRunFile(id, dataRoot: root)
    }

    static func waitingIDs(root: URL) throws -> [String] {
        let paths: [URL]
        do { paths = try FileManager.default.contentsOfDirectory(at: file("", root: root).deletingLastPathComponent(), includingPropertiesForKeys: nil) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
        return paths.filter { $0.lastPathComponent.range(of: "^run-[0-9a-f]{8}\\.json$", options: .regularExpression) != nil }
            .map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    static func save(_ run: [String: JSONValue], id: String, root: URL) async -> Bool {
        let fm = FileManager.default
        let url = file(id, root: root)
        var run = run
        guard let mac = await seal(run, root: root) else { return false }
        run["seal"] = .string(mac)
        guard let data = try? JSONValue.object(run).serializedData(pretty: false), data.count <= byteLimit,
              (try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
              (try? data.write(to: url, options: .atomic)) != nil else { return false }
        let runs = (try? fm.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = runs.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (old, _) in newest.dropFirst(keep) { try? fm.removeItem(at: old) }
        return true
    }

    /// Claims a run to resume, first, by an atomic rename to a name of this
    /// claim's own: a second claimer's rename finds nothing. Then it is read
    /// and its seal checked; a missing or bad seal, or one sealed under
    /// another run's id, is no run at all.
    static func take(_ id: String, root: URL) async -> [String: JSONValue]? {
        let fm = FileManager.default
        let claimed = file(id, root: root).deletingPathExtension().appendingPathExtension("\(UUID().uuidString).claimed")
        guard (try? fm.moveItem(at: file(id, root: root), to: claimed)) != nil else { return nil }
        defer { try? fm.removeItem(at: claimed) }
        guard let data = try? Data(contentsOf: claimed), case .object(let run)? = try? JSONValue.parse(data),
              run["run_id"] == .string(id), case .string(let held)? = run["seal"], let mac = await seal(run, root: root),
              held.utf8.count == mac.utf8.count,
              zip(held.utf8, mac.utf8).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else { return nil }
        return run
    }

    /// HMAC-SHA256 over the run's body (all of it but its seal), keyed by the
    /// install's signing key bound to this one use, so no tool manifest's
    /// signature ever verifies as a run, nor a run's as a manifest.
    static func seal(_ run: [String: JSONValue], root: URL) async -> String? {
        guard let base = try? await SwiftNativeManifestSigner(dataRoot: root).loadOrCreateSigningKey(),
              let body = try? JSONValue.object(run.filter { $0.key != "seal" }).serializedData(pretty: false) else { return nil }
        let key = HMAC<SHA256>.authenticationCode(for: Data("nativeagent.skill_run.v1".utf8), using: SymmetricKey(data: base))
        return HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(key)))
            .map { String(format: "%02x", $0) }.joined()
    }
}
