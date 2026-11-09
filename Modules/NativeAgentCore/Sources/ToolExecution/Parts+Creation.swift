import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter
import ToolRegistry
import CryptoKit
import NativeAgentShared
import PersonaEngine
import Privacy
// Blueprint: | `Parts+Creation.swift` | checked save/rehearsal; ratcheted provenance |

extension Parts {
    static let descriptionLimit = 500
    /// A trial's or setting aside's why: trimmed, then refused past this many characters so the stored words are exactly the agent's.
    static let whyLimit = 500
    static let parameterNamePattern = "^[A-Za-z_][A-Za-z0-9_]{0,63}$"
    static let parameterTypes = ["string": "string", "int": "int", "integer": "int", "number": "number",
                                 "bool": "bool", "boolean": "bool", "list": "list", "array": "list", "object": "object"]

    /// Revisions inherit omitted fields, so create-only requirements remain with the save validator rather than its optional argument schema.
    public static let saveArgumentsSchema: JSONValue = {
        func text(_ description: String) -> JSONValue { .object(["type": .string("string"), "description": .string(description)]) }
        func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
            .object(["type": .string("object"), "properties": .object(properties),
                     "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
        }
        func list(_ items: JSONValue, _ description: String) -> JSONValue {
            .object(["type": .string("array"), "items": items, "description": .string(description)])
        }
        let spellings = parameterTypes.keys.sorted().flatMap { [$0, $0 + "?"] }.map(JSONValue.string)
        let type: JSONValue = .object(["type": .string("string"), "enum": .array(spellings)])
        let nonempty: JSONValue = .object(["type": .string("string"), "pattern": .string(#"\S"#)])
        let declaration: JSONValue = .object(["type": .string("object"),
            "properties": .object(["type": type, "description": nonempty]), "required": .array([.string("type")]),
            "additionalProperties": .bool(true), "description": .string("Parameter schema; constraints use the shared JSON Schema validator.")])
        let parameter: JSONValue = .object(["anyOf": .array([nonempty, declaration])])
        let map: JSONValue = .object(["type": .string("object"),
            "propertyNames": .object(["pattern": .string(parameterNamePattern)]), "additionalProperties": parameter])
        let strings = list(.object(["type": .string("string")]), "A list of strings.")
        let schema = object(["type": .object(["const": .string("object")]), "properties": map,
            "required": strings, "additionalProperties": .object(["const": .bool(false)]),
            "readOnly": .object(["type": .string("boolean")])], required: ["type", "properties"])
        let fixtures: JSONValue = .object(["type": .string("array"), "maxItems": .int(16),
            "description": .string("""
                At most 16 cases in 256 KiB. Omit to inherit; [] clears. Hand-written cases supply input and expected, with optional calls and answers. \
                Recorded tape fixtures on older compiled abilities may only be inherited.
                """),
            "items": .object(["anyOf": .array([
                .object(["type": .string("object"), "properties": .object(["input": .object([:]), "expected": .object([:])]),
                    "required": .array([.string("input"), .string("expected")])]),
                object(["input": .object(["type": .string("object")])], required: ["input"])
            ])])])
        return object(AbilityStore.partArgumentSchemas.merging([
            "id": text(
                "Required: a new id, or an existing ability's id or name. New ids normalize to 2–64 lowercase letters, digits, - and _, a letter first."),
            "description": text("""
                Required for a new ability; omitted on revision it inherits. Nonempty after trimming. Save keeps the first line within \
                \(descriptionLimit) characters, ending at its last sentence when possible, and says when it shortened it; details belong in params \
                descriptions or code.
                """),
            "code": text("""
                Required for a new ability. JavaScript defining function run(input) or async function run(input), returning JSON; at most \
                \(AbilityStore.sourceLimit) UTF-8 bytes. Both app.<page>.<action>(args) and app({action:'page.action',args}) work; app({actions:[…]}), \
                app({find:'words'}) and app({item:…}) also work. app and host calls answer synchronously and may be awaited; a returned Promise must \
                settle in the helper's microtask drain. Omit on revision to inherit, or use edits instead.
                """),
            "edits": .object(["type": .string("array"), "minItems": .int(1),
                "description": .string(
                    "Revision only, instead of code: ordered replacements, each old occurring exactly once in the latest code after earlier edits."),
                "items": .object(["type": .string("object"), "properties": .object([
                    "old": .object(["type": .string("string"), "minLength": .int(1)]), "new": .object(["type": .string("string")])]),
                    "required": .array([.string("old"), .string("new")])])]),
            "params": .object(["description": .string("""
                Input name → description string or {type,description?}. A leading type word, optionally after optional, sets the type; otherwise string. \
                Words end at whitespace, commas, colons or parentheses. integer/boolean/array alias int/bool/list; ? on the type or the word optional \
                makes an input optional. Or \
                {type:\"object\",properties:<same map>,required?:[names],additionalProperties?:false,readOnly?:bool}. Parameter schemas retain their \
                constraints, including array items and enum, checked by the shared JSON Schema validator. Omit to inherit; null or {} clears.
                """),
                "anyOf": .array([map, schema, .object(["type": .string("null")])])]),
            "actions": list(.object(["type": .string("string")]), """
                App actions reached through host.call, app.call, app.read(actionID) or part.call, whether their names are literal or computed. Literal \
                callable app requests, direct app dot/bracket members and reach derive the other dependencies. Unknown literals and missing declarations \
                refuse save; computed names retain runtime checks and produce warnings.
                """),
            "fixtures": fixtures,
            "name": text("Display name; omitted it inherits or uses the id."),
            "triggers": .object(["type": .string("array"), "description": .string("Retained trigger metadata; omit to inherit.")]),
            "converts": list(.object(["type": .string("string"), "pattern": .string("^[0-9a-f]{64}$")]),
                "Original source SHA-256 digests from the conversion census."),
            "create_only": .object(["type": .string("boolean"), "description": .string("Refuse an occupied id or name instead of revising it.")]),
            "trial": .object(["type": .string("boolean"), "description": .string("""
                Revise a kept ability as a trial: code or edits, and why, are required. The stem records the trial (learned.trial) and judges it \
                against the kept version from its runs; one open trial per ability. A later save without trial supersedes an open trial. For your \
                turn program (id: "turn") every revision is a trial and needs why; trial may be omitted, and a revision supersedes its open trial.
                """)]),
            "set_aside": .object(["type": .string("boolean"), "description": .string("""
                Set aside an open trial whose version is current: the kept version's code and declarations are saved forward as a new version, \
                under the same Trust as any save. Send only id, and why if any. For your turn program (id: "turn"), turn.prev.js is saved forward.
                """)]),
            "why": .object(["type": .string("string"), "pattern": .string(#"\S"#), "maxLength": .int(Int64(whyLimit)), "description": .string("""
                With trial or set_aside: the reason in a sentence, at most \(whyLimit) characters after trimming. Shown, never scored. Required with \
                every revision of your turn program (id: "turn"), since each one is a trial: what it changes and the surprise it answers.
                """)])
        ]) { _, value in value }, required: ["id"])
    }()

    /// A revision inherits omitted declarations and code; explicit empties clear them. Full Mac may keep the agent's own save immediately; other authority
    /// remains a draft. A part's trial follows what becomes current (AbilityStore.TrialChange), never a save that only waits.
    public func save(_ input: [String: JSONValue], steer: [String], fullMac: Bool, origin given: JSONValue? = nil,
        invocation: Invocation) async throws -> [String: JSONValue] {
        try await save(input, steer: steer, fullMac: fullMac, origin: given, invocation: invocation, keptSelf: nil)
    }

    /// `keptSelf` saves the kept self forward: it is the base every omitted field inherits from, and the staged version is marked as the open
    /// trial's setting aside, with the agent's why.
    private func save(_ input: [String: JSONValue], steer: [String], fullMac: Bool, origin given: JSONValue?,
        invocation: Invocation, keptSelf: (kept: OwnedProgramStore.Candidate, why: String?)?) async throws -> [String: JSONValue] {
        let started = ContinuousClock.now
        // A phase this save never ran is absent from its timing, never a zero.
        var validateMS: Double?, proofMS: Double?
        var descriptionNote: String?
        func milliseconds(since start: ContinuousClock.Instant) -> Double {
            let elapsed = start.duration(to: .now).components
            return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        }
        func timed(_ receipt: [String: JSONValue]) -> [String: JSONValue] {
            var receipt = receipt
            if let descriptionNote {
                receipt["description_note"] = .string(descriptionNote)
                receipt["detail"] = .string((Self.string(receipt, "detail").map { $0 + " " } ?? "") + descriptionNote + ".")
            }
            var timing: [String: JSONValue] = ["write_ms": .double(max(0, milliseconds(since: started) - (validateMS ?? 0) - (proofMS ?? 0)))]
            timing["validate_ms"] = validateMS.map(JSONValue.double)
            timing["proof_ms"] = proofMS.map(JSONValue.double)
            return receipt.merging(["timing": .object(timing)]) { _, value in value }
        }
        func refuse(_ why: String) -> PartError { .invalid(why + " Nothing was saved.") }
        guard case .object(let declaredArguments)? = Self.fields(Self.saveArgumentsSchema)["properties"] else {
            throw refuse("The installed ability.save schema has no argument properties. Repair that schema before saving.")
        }
        if let unknown = input.keys.sorted().first(where: { !$0.hasPrefix("__") && !["verb", "preview"].contains($0) && declaredArguments[$0] == nil }) {
            throw refuse("""
                \(unknown) is not an ability.save argument. Read ability.save's current schema; declare input with params and authority with \
                reach.capabilities.
                """)
        }
        guard invocation.host != nil else {
            throw refuse("ability.save needs the gated app door of a conversation or wake run to check dependencies.")
        }
        guard let named = Self.string(input, "id")?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty else {
            throw refuse("id is required: the new ability's id, or the id or name of the ability to revise.")
        }
        let existing = try row(named)
        let id = existing.flatMap { Self.string($0, "id") } ?? Self.id(named)
        guard existing != nil || AbilityStore.isAbilityID(id) else {
            throw refuse("id is 2 to 64 lowercase letters, digits, - and _, a letter first; \(named) reads as \(id).")
        }
        // A new part never takes a shipped name; revising a part the agent has, shipped ones included, is the agent's call. The turn program is the
        // agent's own: it is revised, never created.
        if existing == nil, id == Self.turnID { return timed(try saveTurn(input, steer: steer, fullMac: fullMac, invocation: invocation)) }
        if existing == nil, let shipped = try AbilityStore.reservedPart(id) {
            throw refuse("\(shipped) is reserved for the app's own part. Choose another id.")
        }
        if case .object(let learned)? = input["learned"], learned["trial"] != nil {
            throw refuse("learned.trial is the stem's record of a trial; revise with trial: true and why.")
        }
        let trial = input["trial"] == .bool(true), settingAside = input["set_aside"] == .bool(true)
        guard !(trial && settingAside) else { throw refuse("Send trial or set_aside, not both.") }
        var why: String?
        if input["why"] != nil {
            guard trial || settingAside else { throw refuse("why belongs to a trial or a setting aside; send it with trial: true or set_aside: true.") }
            let text = (Self.string(input, "why") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw refuse("why is nonempty text after trimming.") }
            guard text.count <= Self.whyLimit else { throw refuse("why is at most \(Self.whyLimit) characters after trimming; this one has \(text.count).") }
            why = text
        }
        // The stem's own record decides whether a trial is open, read unredacted, after any trial whose version left both slots is closed.
        if trial || settingAside { try abilities.changeTrial(id: id, .reconcile(by: "stem"), turn: invocation.execution.turn) }
        let accounting = try trial || settingAside ? abilities.states()[id]?.objectValue ?? [:] : [:]
        var opening: (kept: String, why: String)?
        if trial {
            guard existing != nil, let kept = try abilities.read(id: id) else {
                throw refuse("trial revises a kept ability; \(id) has no kept version. Save it and keep it first.")
            }
            guard input["code"] != nil || input["edits"] != nil else { throw refuse("A trial is a revision: send code or edits.") }
            guard let why else { throw refuse("A trial needs why: what it changes and the surprise it answers, in a sentence.") }
            guard accounting["trial"] == nil else { throw refuse("One open trial per part: wait for its verdict or set it aside.") }
            opening = (abilities.versionKey(kept), why)
        }
        if settingAside {
            if let extra = input.keys.sorted().first(where: { !$0.hasPrefix("__") && !["verb", "preview", "id", "set_aside", "why"].contains($0) }) {
                throw refuse("set_aside saves the kept version forward as it was; send only id and why, not \(extra).")
            }
            return try await setAside(id, accounting: accounting, why: why, steer: steer, fullMac: fullMac, origin: given, invocation: invocation)
        }
        if input["create_only"] == .bool(true), try existing != nil || abilities.contains(id: id) {
            validateMS = milliseconds(since: started)
            return timed(["status": .string("failed"), "id": .string(id), "effects": .string("none"), "reason": .string("name_exists"),
                    "detail": .string("That ability name already exists. Choose a fresh name; nothing was replaced.")])
        }
        let base = try keptSelf?.kept ?? existing.flatMap(latest)
        let was = base.map { Self.fields($0.manifest) } ?? [:]
        var code = Self.string(input, "code")
        if let edits = input["edits"] {
            guard code == nil else { throw refuse("Send code or edits, not both.") }
            guard let base else { throw refuse("edits revise a saved ability's code; \(id) has none yet, so send code.") }
            do { code = try AbilityStore.edited(base.program.source, edits) } catch {
                throw refuse(error.localizedDescription + " The edits apply to version \(base.digest), whose code ability.read {id:\"\(id)\"} shows.")
            }
        }
        guard let source = code ?? base?.program.source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw refuse("code is required: JavaScript defining function run(input) or async function run(input).")
        }
        let suppliedDescription = (Self.string(input, "description") ?? Self.string(was, "description") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suppliedDescription.isEmpty else { throw refuse("description is required: one line saying when and why this ability helps.") }
        var description = String(suppliedDescription.prefix { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
        if description.count > Self.descriptionLimit {
            let head = String(description.prefix(Self.descriptionLimit))
            let sentence = head.indices.last { index in
                let next = head.index(after: index)
                return ".!?…。！？".contains(head[index]) && (next == head.endIndex || head[next].isWhitespace)
            }
            description = sentence.map { String(head[...$0]) } ?? String(head.prefix(Self.descriptionLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        if description != suppliedDescription {
            descriptionNote = "description kept to its first \(description.count) characters"
        }
        // Inputs inherit the latest version's contract unless explicitly restated.
        var params = was["params"] ?? Self.fields(was["script"] ?? .null)["params"]
        var schema = base?.program.schema ?? .object(["type": .string("object"), "properties": .object([:])])
        if let declared = input["params"] {
            if declared == .null || declared == .object([:]) {
                params = nil; schema = .object(["type": .string("object"), "properties": .object([:])])
            } else {
                let read = try Self.params(declared)
                params = .object(read.params); schema = try Self.inputSchema(read.params, readOnly: read.readOnly)
            }
        }
        var header = input.filter { AbilityStore.partKeys.contains($0.key) }
        for key in AbilityStore.partKeys where header[key] == nil { header[key] = was[key] }
        let part = try AbilityStore.partHeader(header)
        // A part that answers door verbs takes {verb, ...args}; each verb's args are its declared schema, so params never sits beside answers.
        if let answered = AbilityStore.answeredInputSchema(part["answers"]) {
            if let declared = input["params"], declared != .null { throw refuse("answers declares this part's inputs; remove params.") }
            params = nil; schema = answered
        }
        let permissions = try Self.declaredStrings(Self.fields(part["reach"] ?? .null)["capabilities"], name: "reach.capabilities")
        // Direct app members, literal door requests and reach derive dependencies; indirect calls declare theirs in actions.
        let reached = AbilityStore.reachActions(permissions)
        let calls = OwnedProgram.calls(source)
        let called = calls.literal.filter { $0.inferred && !$0.primitive }.map(\.id)
        let declared: [String]
        if let given = input["actions"] {
            declared = try Self.declaredStrings(given, name: "actions").map { spelled in
                guard let action = Self.dependencyID(spelled) else {
                    throw refuse("""
                        actions entry \"\(spelled)\" is not an app action id. Use a current dotted action id; app's own \
                        read/find/log/step/decide/expect/expect_fail verbs need no declaration.
                        """)
                }
                return action
            }
        } else {
            declared = try Self.declaredActions(was, source: base?.program.source ?? "")
        }
        var actions: [String] = []
        for id in declared + called + reached where !actions.contains(id) { actions.append(id) }
        guard actions.count <= OwnedProgramRunner.actionLimit else { throw refuse("An ability calls at most \(OwnedProgramRunner.actionLimit) app actions.") }
        let shapes = try await checkedCallShapes(calls, id: id, actions: actions, selfSchema: schema, invocation: invocation)
        // Only recorded practice can supply an inherited tape; callers cannot author proof.
        let suppliedFixtures = input["fixtures"]
        let fixtures = suppliedFixtures ?? base?.fixtures ?? .array([])
        if let suppliedFixtures, case .array(let given) = suppliedFixtures, given.contains(where: { Self.fields($0)["tape"] != nil }) {
            throw refuse("A fixture's tape comes only from recorded practice; give input, calls, answers and expected.")
        }
        guard case .array(let cases) = fixtures, cases.count <= 16, try fixtures.serializedData(pretty: false).count <= 256 * 1024 else {
            throw refuse("fixtures is a list of at most 16 {input, expected} cases in 256 KiB; omit it to capture during ability.validate.")
        }
        let name = Self.string(input, "name") ?? existing.flatMap { Self.string($0, "name") } ?? Self.referenceID(named)
        let origin = given ?? Self.merged([Self.origin(steeredBy: steer)] + Self.recorded(existing) + (base.map { [Self.fields($0.manifest)["origin"]] } ?? []))
        let guidance = defaultPersonaRoot(dataRoot: root).appendingPathComponent("skills/bodies/\(id).md")
        var manifest: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "description": .string(description), "language": .string("javascript"),
            "inputSchema": schema, "actions": .array(actions.map(JSONValue.string)), "declaredActions": .array(declared.map(JSONValue.string)),
            "origin": origin, "converts": try OwnedProgramStore.conversionSources(input["converts"] ?? was["converts"]),
        ]
        if let params { manifest["params"] = params }
        manifest["compiled"] = was["compiled"]
        if given != nil, let pack = input["capabilityPackInstallId"] { manifest["capabilityPackInstallId"] = pack }
        if let triggers = input["triggers"] ?? was["triggers"] { manifest["triggers"] = triggers }
        if FileManager.default.fileExists(atPath: guidance.path) || was["overrides"] == .string("built_in") { manifest["overrides"] = .string("built_in") }
        manifest.merge(part) { _, value in value }
        if keptSelf == nil, let base {
            // Selection/proof are not authored content. Compare before minting an identity that includes the current selection.
            let authoredKeys = AbilityStore.partKeys.union(["id", "name", "description", "language", "inputSchema", "actions", "declaredActions",
                "origin", "converts", "params", "compiled", "capabilityPackInstallId", "triggers", "overrides"])
            var before = was.filter { authoredKeys.contains($0.key) }
            before.merge(try AbilityStore.partHeader(was.filter { AbilityStore.partKeys.contains($0.key) })) { _, value in value }
            before["converts"] = try OwnedProgramStore.conversionSources(was["converts"])
            before["declaredActions"] = .array(try Self.declaredActions(was, source: base.program.source).map(JSONValue.string))
            before["inputSchema"] = base.program.schema
            if source == base.program.source, fixtures == base.fixtures, before == manifest {
                try AbilityStore.withLock {
                    let live = try row(id)
                    let selected = try live.flatMap(latest)
                    guard OwnedProgramStore.selection(live.map(JSONValue.object)) == OwnedProgramStore.selection(existing.map(JSONValue.object)),
                          selected == base else {
                        throw refuse("\(id) changed while its content was compared; read its current version.")
                    }
                }
                validateMS = milliseconds(since: started)
                return timed(["status": .string("ok"), "id": .string(id), "name": .string(name), "effects": .string("none"),
                    "version": .string(base.digest), "ability_status": existing?["status"] ?? .null,
                    "detail": .string("\(name) already has this authored content; its versions and trial were left as they are.")])
            }
        }
        let candidate = try OwnedProgramStore.Candidate(
            program: OwnedProgram(kind: .part, id: id, version: "candidate", source: source, entry: .run, schema: schema,
                                  dependencies: actions, permissions: permissions, resident: part["resident"] == .bool(true)),
            manifest: .object(manifest), fixtures: fixtures, dependencyShapes: shapes,
            prior: OwnedProgramStore.selection(existing.map(JSONValue.object)))
        let stamp = Self.now()
        enum Staging { case none, attempted, committed }
        var staged = Staging.none
        validateMS = milliseconds(since: started)
        do {
            try mutate(id, turn: invocation.execution.turn) { current in
                guard OwnedProgramStore.selection(current.map(JSONValue.object)) == candidate.prior else {
                    throw PartError.invalid("\(id) changed while it was being saved; save against its current version.")
                }
                try store.stage(candidate, turn: invocation.execution.turn, writing: { staged = .attempted })
                staged = .committed
                var row = current ?? manifest.merging(["status": .string("draft"), "createdAt": .string(stamp)]) { $1 }
                row["updatedAt"] = .string(stamp)
                row["candidateDigest"] = .string(candidate.digest); row["candidatePrior"] = candidate.prior
                row["candidateValidation"] = .string("invalid")
                row["proposalPath"] = .string(try abilities.path(id: id, slot: .next).path)
                row = try CapabilityLifecycle.preservingOwnerOff(row, before: current, turn: invocation.execution.turn)
                row["candidateSelection"] = OwnedProgramStore.selection(.object(row))
                return row
            }
            var receipt: [String: JSONValue] = ["status": .string("saved"), "id": .string(id), "name": .string(name),
                "candidate_digest": .string(candidate.digest), "actions": .array(actions.map(JSONValue.string))]
            if !calls.warnings.isEmpty { receipt["warnings"] = .array(calls.warnings.map(JSONValue.string)) }
            // The staged version's trial is written before any keep, so the keep that selects it sees it. The version under trial is this
            // candidate's identity, which the kept file keeps (identity reads candidate.program.version, which is candidate.digest). Any other
            // save reconciles: staging over the trial's own waiting draft leaves the trial's version in neither slot.
            let change = opening.map { AbilityStore.TrialChange.open(version: candidate.digest, kept: $0.kept, why: $0.why) }
                ?? keptSelf.map { AbilityStore.TrialChange.settingAside(version: candidate.digest, why: $0.why) } ?? .reconcile(by: "agent")
            do {
                if let trial = try abilities.changeTrial(id: id, change, turn: invocation.execution.turn) { receipt["trial"] = trial }
                else if opening != nil || keptSelf != nil {
                    receipt["accounting_error"] = .string("\(id)'s trial changed meanwhile, so this version was saved without a trial change.")
                }
            } catch { receipt["accounting_error"] = .string(error.localizedDescription) }
            // The person's own decision of this exact call (Home's Set aside) keeps it in one act at any posture, as theirs.
            let person = invocation.execution.turn?.personAct != nil
            if manifest["compiled"] == nil, given == nil, person || fullMac && Self.keepRefusal(origin: origin, name: name, fullMac: true) == nil {
                // Kept by the agent under Full Mac, or by the person: a rehearsal proves no live behavior, so its first real run is its proof.
                let proving = ContinuousClock.now
                try store.kept(candidate, key: try await SwiftNativeManifestSigner(dataRoot: root).loadOrCreateSigningKey(), turn: invocation.execution.turn)
                proofMS = milliseconds(since: proving)
                if let closed = try await admit(id: id, digest: candidate.digest, by: person ? "user" : "agent", ownerAuthorized: person,
                    invocation: invocation) {
                    receipt["trial"] = closed
                }
                receipt["status"] = .string("kept"); receipt["ability_status"] = .string("active")
                receipt["next_call"] = .object(["action": .string("authored." + id), "args": .object([:])])
                receipt["detail"] = .string("\(name) is kept and on: run it as authored.\(id); its first real run is its proof.")
                return timed(receipt)
            }
            receipt["ability_status"] = try row(id)?["status"] ?? .null
            receipt["next_call"] = .object(["action": .string("ability.validate"), "args": .object(["id": .string(id)])])
            receipt["detail"] = .string("\(name) is saved as a draft. ability.validate rehearses it; ability.enable keeps it "
                + (fullMac ? "(yours when it is your own work)." : "(below Full Mac, the owner's card)."))
            return timed(receipt)
        } catch {
            switch staged {
            case .none: throw error
            case .attempted, .committed:
                throw PartError.stagedButFailed(digest: candidate.digest, committed: staged == .committed, why: error.localizedDescription)
            }
        }
    }

    /// Setting aside saves the kept self (the retained previous version whose key the trial names) forward through save itself, with the kept self
    /// as the base every field inherits from, so Trust applies as for any save; the trial closes as set aside when that version becomes current.
    /// Never a version swap.
    private func setAside(_ id: String, accounting: [String: JSONValue], why: String?, steer: [String], fullMac: Bool, origin given: JSONValue?,
        invocation: Invocation) async throws -> [String: JSONValue] {
        func refuse(_ why: String) -> PartError { .invalid(why + " Nothing was saved.") }
        guard let open = accounting["trial"] else { throw refuse("\(id) has no open trial to set aside.") }
        guard case .object(let trial) = open, let version = Self.string(trial, "version"), let keptKey = Self.string(trial, "kept") else {
            throw refuse("\(id)'s open trial is unreadable in abilities/state.json; repair that record before setting it aside.")
        }
        guard let current = try abilities.read(id: id), abilities.identity(current) == version else {
            let waiting = try abilities.read(id: id, slot: .next).flatMap(abilities.identity) == version
            throw refuse(waiting
                ? "\(id)'s trial version \(version.prefix(12)) is a waiting draft, never kept; ability.drop {id:\"\(id)\", pending:true} discards it."
                : "\(id)'s trial of \(version.prefix(12)) was superseded: the current version is neither it nor its waiting draft.")
        }
        guard let keptFile = try abilities.read(id: id, slot: .previous), abilities.versionKey(keptFile) == keptKey,
              let keptDigest = abilities.identity(keptFile) else {
            throw refuse("The kept version \(keptKey) is no longer \(id)'s retained previous version, so it cannot be saved forward.")
        }
        let kept = try store.load(id: id, digest: keptDigest)
        var receipt = try await save(["id": .string(id)], steer: steer, fullMac: fullMac, origin: given, invocation: invocation,
            keptSelf: (kept, why))
        receipt["detail"] = .string("The earlier version \(keptKey) was saved forward as a new version. " + (Self.string(receipt, "detail") ?? ""))
        return receipt
    }

    /// Actions a version declared beyond those its reach and literal calls derive.
    static func declaredActions(_ manifest: [String: JSONValue], source: String) throws -> [String] {
        let earlier = Self.strings(manifest["declaredActions"] ?? manifest["actions"] ?? Self.fields(manifest["script"] ?? .null)["actions"])
        let derived = Set(AbilityStore.reachActions(try Self.declaredStrings(Self.fields(manifest["reach"] ?? .null)["capabilities"],
            name: "reach.capabilities")) + OwnedProgram.calledActions(source))
        return manifest["declaredActions"] != nil ? earlier : earlier.filter { !derived.contains($0) }
    }

    // MARK: - Rehearsal

    /// Intercepted validation replies cannot establish live behavior.
    public func validate(_ named: String, input: JSONValue?, capture: Bool, invocation: Invocation) async -> Outcome {
        var attempted = false
        do {
            guard let row = try row(named), let id = Self.string(row, "id") else { return try unknown(named) }
            let name = Self.string(row, "name") ?? id
            guard let candidate = try latest(row), row["candidateDigest"] != nil || row["status"] != .string("active") else {
                let failure = Self.revisionFailure("no_waiting_version", "\(id) has no waiting version to rehearse; save a revision with ability.save.", id: id)
                return (false, failure.message, ["id": .string(id), "reason": .string(failure.code), "effects": .string("none"), "remedy": failure.remedy
                    ?? .null])
            }
            var fields: [String: JSONValue] = ["id": .string(id), "name": .string(name), "candidate_digest": .string(candidate.digest),
                "effects": .string("none"), "effect": .string("none"), "read_only": .bool(true), "execution": .string("rehearsed")]
            let calls = OwnedProgram.calls(candidate.program.source)
            _ = try await checkedCallShapes(calls, id: id, actions: candidate.program.dependencies, selfSchema: candidate.program.schema,
                invocation: invocation)
            if !calls.warnings.isEmpty { fields["warnings"] = .array(calls.warnings.map(JSONValue.string)) }
            do {
                attempted = true
                let proof = try await rehearse(candidate, capture: capture, input: input, invocation: invocation)
                let replayed = Self.fields(proof)["tape"] != nil
                try mutate(id, turn: invocation.execution.turn) { current in
                    guard var row = current, (row["candidateDigest"] ?? row["codeFingerprint"]) == .string(candidate.digest) else {
                        throw PartError.invalid("A newer version replaced this rehearsal; rehearse that one.")
                    }
                    row["candidateValidation"] = .string(replayed ? "replayed" : "rehearsed")
                    return row
                }
                fields["validation_evidence"] = AbilityStore.validationEvidence(proof, fixtures: candidate.fixtures)
                fields["capture"] = Self.fields(proof)["capture"] ?? .null
                fields["next_call"] = .object(["action": .string("ability.read"), "args": .object(["id": .string(id)])])
                if replayed {
                    return (true, """
                        Its recorded examples replayed exactly from the tape and nothing ran. That proves those examples, no other input or branch; \
                        ability.enable keeps it, and its live runs earn its record.
                        """, fields)
                }
                return (true,
                    "The supplied inputs passed rehearsal; intercepted replies are not behavioral proof. Read its exact version before keeping it.", fields)
            } catch let failure as SenseFailure where failure.code == "bad_input" {
                return (false, "Rehearsal needs input: \(failure.message) Pass input as an object matching \(name)'s params.",
                        fields.merging(["reason": .string("bad_input"), "effects": .string("none"), "input_schema": candidate.program.schema,
                                        "remedy": failure.remedy ?? .null]) { $1 })
            }
        } catch {
            var fields = Self.fields(ToolHost.failure(error, effects: "none", execution: attempted ? "rehearsed" : "not_run"))
            fields["effects"] = .string("none")
            fields["effect"] = .string("none"); fields["read_only"] = .bool(true)
            fields["remedy"] = fields["remedy"] ?? Repair.remedy(owner: "ability " + named, nextCall: Self.readCall(named), tap: nil,
                instruction: "Read the waiting version and repair the reported rehearsal failure before validating it again.")
            return (false, "Rehearsal for \(named) did not complete: \(error.localizedDescription)", fields)
        }
    }

    // MARK: - Origin

    /// Untrusted steering remains provenance of the authoring turn; a trusted initiating peer is provenance, never authorship.
    public static func origin(steeredBy steer: [String]) -> JSONValue {
        let peers = steer.filter { !CapabilityLifecycle.ownerTrusts($0) }
        return peers.isEmpty ? .object(["by": .string("hers")])
            : .object(["by": .string("peer"), "peers": .array(peers.map(JSONValue.string))])
    }

    public static func origin(pack: String) -> JSONValue { .object(["by": .string("pack"), "pack": .string(pack)]) }

    /// Missing or malformed authorship stays unknown.
    static func originKind(_ value: JSONValue?) -> String? {
        let fields = fields(value ?? .null)
        switch string(fields, "by") {
        case "hers"?: return "hers"
        case "peer"?:
            // Every peer a nonempty string: a malformed list is no origin, never filtered.
            guard case .array(let peers)? = fields["peers"], !peers.isEmpty,
                  peers.allSatisfy({ if case .string(let peer) = $0 { !peer.isEmpty } else { false } }) else { return nil }
            return "peer"
        case "pack"?: return (string(fields, "pack") ?? "").isEmpty ? nil : "pack"
        default: return nil
        }
    }

    /// Origins only ratchet toward the owner: no later save of the agent's launders an untrusted agent's or a pack's mark. A nil entry is an origin that should
    /// exist and doesn't, an unrecorded peer.
    static func merged(_ origins: [JSONValue?]) -> JSONValue {
        var peers: [String] = [], pack: String?
        for given in origins.isEmpty ? [nil] : origins {
            // Persisted origin spellings encode self-authorship or the turn's steering source.
            let steer = Self.fields(given ?? .null)["steer"]
            let spelled: JSONValue?
            if given == .string("self") { spelled = Self.origin(steeredBy: []) }
            else if let steer, Self.fields(given ?? .null)["by"] == nil {
                guard case .array(let entries) = steer, entries.allSatisfy({
                    if case .string(let peer) = $0 { !peer.isEmpty } else { false }
                }) else { peers.append("unrecorded"); continue }
                spelled = Self.origin(steeredBy: strings(steer))
            } else { spelled = given }
            guard let kind = originKind(spelled) else { peers.append("unrecorded"); continue }
            let recorded = Self.fields(spelled ?? .null)
            if kind == "peer" { peers += strings(recorded["peers"]).filter { !CapabilityLifecycle.ownerTrusts($0) } }
            if let named = string(recorded, "pack"), !named.isEmpty, kind != "hers" { pack = pack ?? named }
        }
        var seen: Set<String> = []
        peers = peers.filter { seen.insert($0).inserted }
        guard !peers.isEmpty else { return pack.map(origin(pack:)) ?? origin(steeredBy: []) }
        var fields: [String: JSONValue] = ["by": .string("peer"), "peers": .array(peers.map(JSONValue.string))]
        if let pack { fields["pack"] = .string(pack) }
        return .object(fields)
    }

    /// Merge against the record's own retained origin.
    static func recorded(_ row: [String: JSONValue]?) -> [JSONValue?] {
        guard let row, row["origin"] != nil || row["codeFingerprint"] != nil else { return [] }
        return [row["origin"]]
    }

    /// Own work needs no untrusted-origin attribution.
    public static func voices(_ row: [String: JSONValue]) -> [String] {
        guard row["origin"] != nil, case .object(let origin) = merged([row["origin"]]) else { return [] }
        return strings(origin["peers"]) + [string(origin, "pack")].compactMap { $0 }
    }

    // MARK: - Inputs

    /// Parameter maps and JSON Schema share one input contract; plain strings express optionality with ? on the type or the word optional.
    static func params(_ value: JSONValue) throws -> (params: [String: JSONValue], readOnly: Bool) {
        func refuse(_ why: String) -> PartError { .invalid(why + " Nothing was saved.") }
        let shape = """
            Each param is a description string (a leading string, int/integer, number, bool/boolean, list/array or object, optionally after optional, \
            sets its type; otherwise string; ? on the type or the word optional marks it optional; words end at whitespace, commas, colons or \
            parentheses), or {type, description?, ...schema constraints}.
            """
        guard case .object(let fields) = value else { throw refuse("params maps each input name to its type. " + shape) }
        func read(_ fields: [String: JSONValue]) throws -> [String: JSONValue] {
            var params: [String: JSONValue] = [:]
            for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
                guard name.range(of: parameterNamePattern, options: .regularExpression) != nil else {
                    throw refuse("params.\(name): a param name is a letter or _ then up to 63 letters, digits or _.")
                }
                let given = parameterType(value) ?? "", optional = given.hasSuffix("?")
                let base = optional ? String(given.dropLast()) : given
                guard let type = parameterTypes[base] else {
                    throw refuse("params.\(name)'s type is " + (given.isEmpty ? "missing" : "\"\(given)\"") + ". " + shape)
                }
                let spelled = type + (optional ? "?" : "")
                guard var declaration = parameterDeclaration(value) else { throw refuse("params.\(name) has no parameter declaration. " + shape) }
                if let description = declaration["description"] {
                    guard case .string(let text) = description, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw refuse("params.\(name).description is nonempty text, or leave description out.")
                    }
                }
                declaration["type"] = .string(spelled)
                if let problem = JSONValue.null.schemaProblem(schema: try inputProperty(.object(declaration))), problem.keyword == "schema" {
                    throw refuse("params.\(name): \(problem.words).")
                }
                params[name] = .object(declaration)
            }
            return params
        }
        // A type-bearing value names a parameter, including parameters named type or properties.
        let namedParameters = fields.values.allSatisfy { parameterType($0) != nil }
        if !namedParameters, fields["type"] == .string("object"), case .object(let properties)? = fields["properties"] {
            if let stray = fields.keys.sorted().first(where: { !["type", "properties", "required", "additionalProperties", "readOnly"].contains($0) }) {
                throw refuse("params takes no \(stray); put each parameter's constraints in properties.")
            }
            guard fields["additionalProperties"] == nil || fields["additionalProperties"] == .bool(false) else {
                throw refuse("params.additionalProperties is false or left out: an ability takes only its declared params.")
            }
            guard fields["readOnly"] == nil || fields["readOnly"] == .bool(true) || fields["readOnly"] == .bool(false) else {
                throw refuse("params.readOnly is a Boolean.")
            }
            var required: Set<String> = []
            if let names = fields["required"] {
                guard case .array(let list) = names, list.allSatisfy({ if case .string = $0 { true } else { false } }) else {
                    throw refuse("params.required is a list of param names.")
                }
                required = Set(strings(names))
                if let stray = required.sorted().first(where: { properties[$0] == nil }) {
                    throw refuse("params.required names \(stray), which properties does not declare.")
                }
            }
            for name in required {
                if let type = parameterType(properties[name]), type.hasSuffix("?") {
                    throw refuse("params.\(name) is required and has an optional type; choose one meaning.")
                }
            }
            var flat = properties
            for (name, value) in properties where !required.contains(name) {
                guard let type = parameterType(value), !type.hasSuffix("?") else { continue }
                guard var declaration = parameterDeclaration(value) else { continue }
                declaration["type"] = .string(type + "?"); flat[name] = .object(declaration)
            }
            return (try read(flat), fields["readOnly"] == .bool(true))
        }
        return (try read(fields), false)
    }

    /// Plain spellings and schema declarations keep one canonical type without losing the parameter's constraints.
    private static func inputProperty(_ value: JSONValue) throws -> JSONValue {
        let types = ["string": "string", "int": "integer", "number": "number", "bool": "boolean", "list": "array", "object": "object"]
        guard let type = parameterType(value), let jsonType = types[type.hasSuffix("?") ? String(type.dropLast()) : type] else {
            throw PartError.invalid("A parameter has no canonical type. Nothing was saved.")
        }
        guard var property = parameterDeclaration(value) else { throw PartError.invalid("A parameter declaration is missing. Nothing was saved.") }
        property["type"] = .string(jsonType)
        return .object(property)
    }

    /// Every run must validate against the derived input schema.
    static func inputSchema(_ params: [String: JSONValue], readOnly: Bool = false) throws -> JSONValue {
        let properties = try params.mapValues(inputProperty)
        var required: [JSONValue] = []
        for (name, value) in params.sorted(by: { $0.key < $1.key }) {
            guard let type = parameterType(value) else { throw PartError.invalid("params.\(name) has no type. Nothing was saved.") }
            if !type.hasSuffix("?") { required.append(.string(name)) }
        }
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties),
            "required": .array(required),
            "additionalProperties": .bool(false)]
        if readOnly { schema["readOnly"] = .bool(true) }
        return .object(schema)
    }

    static func parameterType(_ value: JSONValue?) -> String? {
        parameterDeclaration(value).flatMap { string($0, "type") }
    }

    /// Strings retain their description. Words end at whitespace, commas, colons or parentheses; the leading type may follow optional.
    /// A ? on that type or the word optional anywhere marks optionality, even when an untyped description names a string.
    private static func parameterDeclaration(_ value: JSONValue?) -> [String: JSONValue]? {
        if case .object(let declaration)? = value { return declaration }
        guard case .string(let supplied)? = value else { return nil }
        let description = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return nil }
        let words = description.lowercased().split { $0.isWhitespace || $0 == "," || $0 == ":" || $0 == "(" || $0 == ")" }
        let word = words.first == "optional" ? words.dropFirst().first : words.first
        let questioned = word?.hasSuffix("?") == true
        let base = word.map { questioned ? String($0.dropLast()) : String($0) }
        let declaredType = base.flatMap { parameterTypes[$0] }
        let optional = words.contains("optional") || (questioned && declaredType != nil)
        return ["type": .string((declaredType ?? "string") + (optional ? "?" : "")), "description": .string(description)]
    }

    /// Runner verbs and malformed references cannot become action IDs.
    public static func dependencyID(_ spelled: String) -> String? {
        let id = spelled.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id == "find" { return id }
        let bare = id.hasPrefix("app.") ? String(id.dropFirst(4)) : id
        return !OwnedProgram.verbs.contains(bare) && id.range(of: "^[a-z0-9_-]+(\\.[a-z0-9_-]+)+$", options: .regularExpression) != nil ? id : nil
    }

}
