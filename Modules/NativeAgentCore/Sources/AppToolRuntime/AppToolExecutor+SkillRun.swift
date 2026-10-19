import AuthoredCapabilities
import ChatOrchestration
import CryptoKit
import Desk
import Dispatcher
import Foundation
import NativeAgentCore
import PersistenceCore
import Skills
import Senses
import ToolRegistry
import TrustCenter

/// Runnable skills keep their declared reach; every call uses the turn's gates.
extension AppToolExecutor {
    /// The stops a run is kept for, to resume: her decision, or a card preview.
    static let skillHandBacks: Set<String> = ["decide", "would_card"]

    /// One quiet MY QUEUE line each for skill availability changes,
    /// and their upgrade signals (`when: quiet`: shown on her next ordinary
    /// turn, never waking her); whether every line queued.
    @discardableResult
    static func queueSkillLines(_ lines: [SkillLine], root: URL) async -> Bool {
        guard !lines.isEmpty else { return false }
        let store = SwiftNativeDeskStore(dataRoot: root)
        var queued = true
        // A line naming a peer's or a pack's skill is filed as theirs (masked title, taint latch).
        for line in lines where (try? await MyQueue.add(DeskStep(words: line.words, when: "quiet", peers: line.peers, origin: "self"), store: store)) == nil {
            queued = false
        }
        return queued
    }

    static func skillFields(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let fields)? = value { fields } else { [:] }
    }

    /// Where a run stopped, as the notice says it: its labeled step, else the script line.
    static func stopPlace(_ out: [String: JSONValue]) -> String {
        let step = doorText(skillFields(out["hand_back"])["step"])
        if !step.isEmpty { return step.hasPrefix("step") ? step : "step " + step }
        let line = doorText(skillFields(out["stopped"] ?? out["error"])["line"])
        return line.isEmpty ? "" : "line " + line
    }

    /// One call of a skill's run, before it is dispatched: nil runs it.
    static func skillStep(_ id: String, declared: Set<String>) -> JSONValue? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard declared.contains(key) else {
            return doorRefusal("not_declared", "\(key) is not among the actions this skill declares; it was not run.",
                remedy: "none", "The skill's script calls what its header doesn't declare: fix the skill.")
        }
        return nil
    }

    /// Whether the contract a skill saved for an action still fits it: equal,
    /// or the action now accepts every call the saved one did.
    static func dependencyFits(_ id: String, _ saved: JSONValue?, root: URL = PersistenceCore.defaultDataRoot()) -> Bool {
        AppScriptRunner.Host(call: { _ in .null }, toolHost: true, dataRoot: root).dependencyMatches(id, saved)
    }

    /// Why `args` doesn't fit the header's params, or nil.
    static func paramsMismatch(_ params: [String: JSONValue], _ args: [String: JSONValue]) -> String? {
        if let stray = args.keys.sorted().first(where: { params[$0] == nil }) { return "it takes no \(stray)" }
        for name in params.keys.sorted() {
            guard let spelled = SkillScript.parameterType(params[name]) else { continue }
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
        let binding: OwnedProgramRunner.Binding
        let entry: InstalledSkillInventory.Entry
        var id: String { entry.id }
        var name: String { entry.name }
        let source: String
        let program: OwnedProgram
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

    /// `skill.run {name, input}` and `skill.resume {run_id, answer}`.
    @MainActor
    func doorSkill(_ id: String, args: [String: JSONValue], input: [String: JSONValue], surface: String) async -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let preview = input["preview"] == .bool(true)
        if id == "skill.validate" {
            guard !preview else {
                return Self.doorRefusal("not_previewable", "Validation records proof, so it cannot preview. Nothing was validated or changed.",
                    remedy: "correct_arguments", "Call skill.validate without preview to validate and retain proof for the exact candidate.")
            }
            return await validateSkillRoutine(args, root: root)
        }
        guard id == "skill.run" else {
            guard !preview else {
                return Self.doorRefusal("not_previewable", "A resume runs; there is nothing to preview. Nothing ran.",
                    remedy: "correct_arguments", "Preview the skill itself with skill.run and preview:true.")
            }
            return await doorSkillResume(args, session: input["__session_id"], surface: surface, root: root)
        }
        if let input = args["input"], let legacy = args["args"], input != legacy {
            return Self.doorRefusal("invalid_args", "input and args disagree. Nothing ran.",
                remedy: "correct_arguments", "Pass the skill's input once, as input.")
        }
        let given: [String: JSONValue]
        switch args["input"] ?? args["args"] {
        case .object(let object)?: given = object
        case nil: given = [:]
        default:
            return Self.doorRefusal("invalid_args", "input is an object, the skill's params by name. Nothing ran.",
                remedy: "correct_arguments", "Call skill.run again with input as an object.")
        }
        let loaded = await loadSkillScript(Self.doorText(args["name"]), preview: preview, root: root)
        guard let skill = loaded.skill else { return loaded.refusal ?? .null }
        if let mismatch = Self.paramsMismatch(skill.params, given) {
            return Self.doorRefusal("invalid_args", "\(skill.name)'s input doesn't fit its params: \(mismatch). Nothing ran.",
                remedy: "correct_arguments", "Pass input as its signature shows (skill.list).")
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
        var selected: InstalledSkillInventory.Entry?
        func refuse(_ reason: String, _ detail: String, _ instruction: String) -> (SkillScriptRun?, JSONValue?) {
            var receipt = Self.doorRefusal(reason, detail + " Nothing ran.", remedy: "none", instruction)
            if !preview, let selected, let digest = Self.inputString(selected.row["codeFingerprint"]) {
                do { try AbilityStore(dataRoot: root).recordRun(id: selected.id, version: digest, receipt: receipt) }
                catch {
                    var fields = Self.skillFields(receipt); fields["accounting_error"] = .string(error.localizedDescription)
                    receipt = .object(fields)
                }
            }
            return (nil, receipt)
        }
        let entries: [InstalledSkillInventory.Entry]
        var revision: [String]
        do {
            revision = try AbilityStore(dataRoot: root).revision()
            entries = try InstalledSkillInventory.entries(dataRoot: root)
        } catch {
            return refuse("skills_unreadable", "The skill registry didn't read (\(error.localizedDescription)).",
                          "app skill.list shows what reads now.")
        }
        guard let entry = InstalledSkillInventory.match(name, in: entries) else {
            return refuse("unknown_skill", "No skill is called \(name.isEmpty ? "(none passed)" : name).",
                          "app skill.list shows the skills by name.")
        }
        selected = entry
        guard case .object(let script)? = entry.row["script"],
              case .string(let source)? = script["source"] else {
            return refuse("not_a_script", "\(entry.name) has no JS routine, so it doesn't run.",
                          "Convert the original, then save, validate and enable its JS counterpart.")
        }
        let status = Self.doorText(entry.row["status"]).lowercased()
        let program: OwnedProgram
        do {
            let client = SwiftNativeSkillsClient(root: root)
            program = preview && !entry.isRunnable ? try client.routineCandidate(entry.row).program
                : try client.routineProgram(entry.row)
        } catch {
            return refuse("integrity", error.localizedDescription, "Save, validate and enable the exact routine again.")
        }
        let digest = program.version
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
                    "skill.enable turns it on for its exact script: yours for your own script under Full Mac, else the owner's on the Skills page.")
            }
            off = why
        }
        let declared: [JSONValue] = if case .array(let ids)? = script["actions"] { ids } else { [] }
        let actions = declared.compactMap(Self.inputString)
        do { revision += try AppScriptRunner.Host(call: { _ in .null }, dataRoot: root).dependencyRevision(actions) }
        catch { return refuse("integrity", error.localizedDescription, "app skill.list shows the skills by name.") }
        // Each action pinned as it was when its script was admitted; a change
        // that no longer accepts the calls it did suspends it. A preview only
        // compares the existing pins.
        var changed: [String] = []
        if off == nil {
            let fits: @Sendable (String, JSONValue?) -> Bool = { Self.dependencyFits($0, $1, root: root) }
            if preview {
                if case .object(let pin)? = entry.row["actionPin"], pin["digest"] == entry.row["scriptDigest"],
                   case .object(let held)? = pin["actions"] {
                    changed = Set(held.keys).union(actions).filter { !fits($0, held[$0]) }.sorted()
                }
            } else {
                do {
                    changed = try await SwiftNativeSkillsClient(root: root).pinActions(entry, digest: digest, ids: actions, fits: fits)
                } catch {
                    return refuse("not_runnable", "\(entry.name)'s action pins did not read (\(error.localizedDescription)).",
                                  "app skill.list shows its state now.")
                }
            }
        }
        if !changed.isEmpty {
            if preview {
                return refuse("stale_dependency",
                    "\(entry.name)'s actions changed since its script was admitted: \(changed.joined(separator: ", ")). "
                        + "A real run would refuse it until its current actions are reviewed. This preview changed nothing.",
                    "Read what changed and check the script still fits before running it.")
            }
            let queued = await Self.queueSkillLines([("\(entry.name) needs review: \(changed.joined(separator: ", ")) changed; re-review",
                                                      SkillScript.voices(entry.row))],
                                                    root: root)
            return refuse("stale_dependency",
                "\(entry.name) cannot run: \(changed.joined(separator: ", ")) changed since its script was admitted, "
                    + "so it needs validation and admission against the current actions"
                    + (queued ? "; MY QUEUE says so." : "."),
                "Read what changed, check the script still fits, then skill.enable admits it again.")
        }
        for action in actions where AppActions.action(action, dataRoot: root) == nil {
            return refuse("unknown_action",
                "\(entry.name) declares \(action), which is no action now.",
                "Fix the skill: its script makes that call nowhere, or names the action it means.")
        }
        return (SkillScriptRun(binding: .init(revision: revision), entry: entry, source: source, program: program,
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
                remedy: "correct_arguments", "Call app from a chat turn's tool chain; this caller cannot bind a chat by supplying a session id.")
        }
        let declared = Set(skill.actions)
        let versions = SkillRunVersions(journal: replay?.journal ?? [], root: root)
        let receipt = await SkillRunContext.$handsBack.withValue(false) {
            await DoorNotesSnapshot.$current.withValue(DoorNotesSnapshot()) {
                await AppScriptRunner.run(source: skill.source, preview: preview, strict: true, input: .object(input),
                                          replay: replay, program: skill.program, dataRoot: root) { call in
                    var call = call
                    if Task.isCancelled { return Self.failure("cancelled", "The turn stopped; nothing more ran.") }
                    if !preview {
                        do {
                            try await skill.binding.check(AbilityStore(dataRoot: root).revision()
                                + AppScriptRunner.Host(call: { _ in .null }, dataRoot: root).dependencyRevision(skill.actions)) {
                                let entry = try InstalledSkillInventory.entries(dataRoot: root)
                                    .first { $0.id == skill.id && $0.row["source"] == skill.entry.row["source"] }
                                guard let entry, SkillScript.isRunnable(entry.row), entry.row["admission"] == skill.admission,
                                      try SwiftNativeSkillsClient(root: root).routineProgram(entry.row) == skill.program else {
                                    throw SenseFailure(code: "state_changed", message: "The routine's selection or admission changed; nothing more ran.")
                                }
                                let changed = try await SwiftNativeSkillsClient(root: root).pinActions(entry, digest: skill.digest,
                                    ids: skill.program.dependencies) { Self.dependencyFits($0, $1, root: root) }
                                guard changed.isEmpty else {
                                    throw SenseFailure(code: "stale_dependency", message: "Dependencies changed: \(changed.joined(separator: ", ")). Nothing more ran; re-author and validate the routine.")
                                }
                            }
                        } catch {
                            return Self.failure((error as? SenseFailure)?.code ?? "integrity", error.localizedDescription)
                        }
                    }
                    if case .string(let id)? = call["action"] {
                        if let stop = Self.skillStep(id, declared: declared) { return stop }
                        if let refused = versions.prepare(&call, id: id) { return refused }
                    }
                    if Task.isCancelled { return Self.failure("cancelled", "The turn stopped; nothing more ran.") }
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
        out["version"] = .string(skill.program.version)
        if let off = skill.off {
            out["not_on"] = .string("A preview of \(skill.name), which isn't on: it is \(off). It shows where a run would stop; "
                + "a real run is refused until skill.enable turns it on.")
        }
        if preview, case .array(let calls)? = out["calls"] {
            out["would"] = .array(calls.compactMap { row -> JSONValue? in
                guard case .object(let fields) = row, fields["would_card"] == .bool(true)
                else { return nil }
                return .object(fields.filter { ["n", "step", "call", "would_card"].contains($0.key) })
            })
        }
        let reason = Self.doorText(out["reason"])
        // What the run says about the skill: its own fault, the world's, or a clean run.
        if !preview {
            out["bookkeeping"] = .string("Skill lifecycle and upkeep.")
            let fault = AbilityStore.runOutcome(.object(out)) == "error" ? (reason.isEmpty ? "script_error" : reason) : nil
            let hash = SHA256.hash(data: (try? JSONValue.object(input).serializedData(pretty: false)) ?? Data())
                .map { String(format: "%02x", $0) }.joined()
            if let kept = try? await SwiftNativeSkillsClient(root: root).recordRun(
                skill.entry, runID: runID, digest: skill.digest, admission: skill.admission, fault: fault,
                clean: fault == nil && out["status"] == .string("ok"), reason: reason.isEmpty ? Self.doorText(out["status"]) : reason,
                step: Self.stopPlace(out), inputHash: String(hash.prefix(16))) {
                out["ladder"] = .object(["clean": .int(Int64(kept.clean)), "of": .int(3)])
                await Self.queueSkillLines(kept.signals, root: root)

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
            "version": .string(skill.program.version),
            "hostRevision": .string(OwnedProgramStore.hostRevision),
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

    @MainActor
    private func validateSkillRoutine(_ args: [String: JSONValue], root: URL) async -> JSONValue {
        do {
            let key = try await SwiftNativeManifestSigner(dataRoot: root).loadOrCreateSigningKey()
            return try await SwiftNativeSkillsClient(root: root).validateRoutine(name: Self.doorText(args["name"]), key: key) { candidate in
                let saved = Self.skillFields(candidate.dependencyShapes)
                guard candidate.program.dependencies.allSatisfy({ Self.dependencyFits($0, saved[$0], root: root) }) else {
                    throw SkillsError.invalidScript("Dependencies changed. Save the routine against the current actions.")
                }
                for id in candidate.program.dependencies {
                    guard AppActions.action(id, dataRoot: root) != nil else {
                        throw SkillsError.invalidScript("Dependency \(id) is no action now. Save the routine against the current actions.")
                    }
                }
                let params = Self.skillFields(Self.skillFields(Self.skillFields(candidate.manifest)["script"])["params"])
                return try await OwnedProgramStore(root: root.appendingPathComponent("skills")).validate(candidate,
                    key: key, capture: args["capture"] == .bool(true), input: args["input"],
                    runner: AppScriptRunner.runner(dataRoot: root), host: {
                        let versions = SkillRunVersions(journal: [], root: root)
                        return AppScriptRunner.Host(call: Self.doorCall(), validation: { call, fixture in
                            var call = call
                            if let id = Self.inputString(call["action"]) {
                                guard Self.dependencyFits(id, saved[id], root: root) else {
                                    return Self.failure("stale_dependency", "The declared action changed during validation.")
                                }
                                if !(await fixture.captured) {
                                    if let stop = Self.skillStep(id, declared: Set(candidate.program.dependencies)) { return stop }
                                    if let stop = versions.prepare(&call, id: id) { return stop }
                                }
                            }
                            let receipt = await fixture.reply(call)
                            versions.observe(call, receipt)
                            return receipt
                        }, dataRoot: root)
                }) { input in
                    guard case .object(let fields) = input, AppScriptRunner.secretPath(input) == nil else {
                        throw SenseFailure(code: "bad_input", message: "Validation input must be an object matching params and contain no keys or tokens.")
                    }
                    if let mismatch = Self.paramsMismatch(params, fields) {
                        throw SenseFailure(code: "bad_input", message: "Capture validation needs sample input in the input parameter matching params: \(mismatch).")
                    }
                }
            }
        } catch let error as SenseFailure where error.code == "bad_input" {
            do {
                let candidate = try await SwiftNativeSkillsClient(root: root).routineCandidate(name: Self.doorText(args["name"]))
                guard case .object(let manifest) = candidate.manifest, let script = manifest["script"] else {
                    throw SkillsError.invalidScript("The routine candidate has no script. Save it again before validation.")
                }
                if candidate.fixtures != .array([]) {
                    return Self.doorRefusal(error.code, error.message, remedy: "correct_arguments",
                        "Save the routine without invalid fixtures, then validate with sample input matching params.",
                        next: ["action": .string("skill.save"), "args": .object(manifest.filter {
                            ["name", "description", "triggers", "script", "overrides", "converts"].contains($0.key)
                        })])
                }
                return Self.doorRefusal(error.code, error.message, remedy: "correct_arguments",
                    "Pass input as an object matching the skill's params (skill.read).",
                    next: ["action": .string("skill.validate"), "args": .object([
                        "name": args["name"] ?? .null, "input": ToolSignature.example(SkillScript.inputSchema(script), name: "input")])])
            } catch {
                return Self.failure("validation_failed", error.localizedDescription, extra: ["effects": .string("unknown")])
            }
        } catch {
            return Self.failure("validation_failed", error.localizedDescription, extra: ["effects": .string("unknown")])
        }
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
        guard skill.digest == Self.doorText(run["digest"]), case .array(let journal)? = run["journal"],
              (run["version"] == .string(skill.program.version)
                  && run["hostRevision"] == .string(OwnedProgramStore.hostRevision)) else {
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
    static func skillStepRead(_ name: String, step: JSONValue?, source requestedSource: Bool, root: URL) -> JSONValue {
        guard let entry = (try? InstalledSkillInventory.entries(dataRoot: root)).flatMap({ InstalledSkillInventory.match(name, in: $0) }) else {
            return doorRefusal("unknown_skill", "No skill is called \(name.isEmpty ? "(none passed)" : name).",
                               remedy: "none", "app skill.list shows the skills by name.")
        }
        guard case .object(let script)? = entry.row["script"], case .string(let source)? = script["source"] else {
            return doorRefusal("not_a_script", "\(entry.name) has no JS routine steps.",
                               remedy: "correct_arguments", "Read it whole with skill.read {name}.")
        }
        let of = if case .int(let n)? = script["of"] { Int(n) } else { 1 }
        guard case .int(let n)? = step, (1...max(of, 1)).contains(Int(n)) else {
            return doorRefusal("invalid_args", "step is 1 to \(of) for \(entry.name).",
                               remedy: "correct_arguments", "Call skill.read again with a step in range.")
        }
        let at = Int(n) - 1
        if !requestedSource {
            let labels: [JSONValue] = if case .array(let labels)? = script["steps"] { labels } else { [] }
            return .object(["status": .string("ok"), "skill": .string(entry.name), "step": .string("\(n) of \(of)"),
                "label": labels.indices.contains(at) ? labels[at] : .null])
        }
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
        return PeerDataTaintDispatcher.peerApproval(tool: tool, capabilities: envelope.capabilities, input: args,
            surface: surface, fullMac: [.admitted, .untrustedOrigin].contains(envelope.fullMacYoloAuthority),
            protectedAction: protectedAction).required
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
    private let root: URL

    init(journal: [JSONValue], root: URL = PersistenceCore.defaultDataRoot()) {
        self.root = root
        AppScriptRunner.ownVersions(journal).forEach(note)
    }

    private func note(_ version: String) {
        lock.withLock {
            newest[String(AppScriptRunner.versionScope(version).split(separator: "/").first ?? "")] = version
            seen.insert(version)
        }
    }

    /// A write goes on the version of the page this run read; one on a page it
    /// never read goes as her turn's would, with none. A version she passes
    /// herself must be one the run read.
    func prepare(_ call: inout [String: JSONValue], id: String) -> JSONValue? {
        let args: [String: JSONValue] = if case .object(let args)? = call["args"] { args } else { [:] }
        guard let action = AppActions.action(id, dataRoot: root), !action.readOnly(args: args), !action.versionExempt else { return nil }
        let given = AppToolExecutor.doorText(call["expected_version"])
        return lock.withLock { () -> JSONValue? in
            if !given.isEmpty {
                guard !seen.contains(given) else { return nil }
                return AppToolExecutor.doorRefusal("not_own_version",
                    "\(action.id) passed a version this run never read; a skill's write goes on its own read's version. It was not run.",
                    remedy: "none", "Fix the skill: leave expected_version out, or pass the one its own read returned.")
            }
            if let version = newest[action.page] { call["expected_version"] = .string(version) }
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
