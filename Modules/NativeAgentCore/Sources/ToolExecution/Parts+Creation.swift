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
        let parameter: JSONValue = .object(["anyOf": .array([type, object(["type": type, "description": nonempty], required: ["type"])])])
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
                Input name → type or {type,description?}; integer/boolean/array alias int/bool/list, and ? makes an input optional. Or \
                {type:\"object\",properties:<same map>,required?:[names],additionalProperties?:false,readOnly?:bool}. Only type and description are \
                accepted per param; name allowed values in description. Omit to inherit; null or {} clears.
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
            "create_only": .object(["type": .string("boolean"), "description": .string("Refuse an occupied id or name instead of revising it.")])
        ]) { _, value in value }, required: ["id"])
    }()

    /// A revision inherits omitted declarations and code; explicit empties clear them. Full Mac may keep the agent's own save immediately; other authority
    /// remains a draft.
    public func save(_ input: [String: JSONValue], steer: [String], fullMac: Bool, origin given: JSONValue? = nil,
        invocation: Invocation) async throws -> [String: JSONValue] {
        let started = ContinuousClock.now
        var validateMS = 0.0, proofMS = 0.0
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
            return receipt.merging(["timing": .object(["validate_ms": .double(validateMS),
                "proof_ms": .double(proofMS),
                "write_ms": .double(max(0, milliseconds(since: started) - validateMS - proofMS))])]) { _, value in value }
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
        // A new part never takes a shipped name; revising a part the agent has, shipped ones included, is the agent's call.
        if existing == nil, let shipped = try AbilityStore.reservedPart(id) {
            throw refuse("\(shipped) is reserved for the app's own part. Choose another id.")
        }
        if input["create_only"] == .bool(true), try existing != nil || abilities.contains(id: id) {
            validateMS = milliseconds(since: started)
            return timed(["status": .string("failed"), "id": .string(id), "effects": .string("none"), "reason": .string("name_exists"),
                    "detail": .string("That ability name already exists. Choose a fresh name; nothing was replaced.")])
        }
        let base = try existing.flatMap(latest)
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
                params = .object(read.params); schema = Self.inputSchema(read.params, readOnly: read.readOnly)
            }
        }
        var header = input.filter { AbilityStore.partKeys.contains($0.key) }
        for key in AbilityStore.partKeys where header[key] == nil { header[key] = was[key] }
        let part = try AbilityStore.partHeader(header)
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
            let earlier = Self.strings(was["declaredActions"] ?? was["actions"] ?? Self.fields(was["script"] ?? .null)["actions"])
            let derived = Set(AbilityStore.reachActions(try Self.declaredStrings(Self.fields(was["reach"] ?? .null)["capabilities"],
                name: "reach.capabilities"))
                + OwnedProgram.calledActions(base?.program.source ?? ""))
            declared = was["declaredActions"] != nil ? earlier : earlier.filter { !derived.contains($0) }
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
            if manifest["compiled"] == nil, given == nil, fullMac, Self.keepRefusal(origin: origin, name: name, fullMac: true) == nil {
                // Kept by the agent under Full Mac: a rehearsal proves no live behavior, so its first real run is its proof.
                let proving = ContinuousClock.now
                try store.kept(candidate, key: try await SwiftNativeManifestSigner(dataRoot: root).loadOrCreateSigningKey(), turn: invocation.execution.turn)
                proofMS = milliseconds(since: proving)
                try await admit(id: id, digest: candidate.digest, by: "agent", invocation: invocation)
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

    static func agentMayAdmit(_ origin: JSONValue?) -> Bool {
        guard let kind = originKind(origin), fields(origin ?? .null)["pack"] == nil else { return false }
        return kind == "hers" || kind == "peer" && strings(fields(origin ?? .null)["peers"]).allSatisfy(CapabilityLifecycle.ownerTrusts)
    }

    /// Own work needs no untrusted-origin attribution.
    public static func voices(_ row: [String: JSONValue]) -> [String] {
        guard row["origin"] != nil, case .object(let origin) = merged([row["origin"]]) else { return [] }
        return strings(origin["peers"]) + [string(origin, "pack")].compactMap { $0 }
    }

    // MARK: - Inputs

    /// Parameter maps and JSON Schema share one input contract; a trailing question mark marks an optional flat parameter.
    static func params(_ value: JSONValue) throws -> (params: [String: JSONValue], readOnly: Bool) {
        func refuse(_ why: String) -> PartError { .invalid(why + " Nothing was saved.") }
        let shape = """
            Each param is its type (string, int or integer, number, bool or boolean, list or array, or object; a trailing ? marks it optional) or {type, \
            description?}.
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
                guard case .object(var declaration) = value else { params[name] = .string(spelled); continue }
                if let key = declaration.keys.sorted().first(where: { !["type", "description"].contains($0) }) {
                    throw refuse("params.\(name) takes no \(key). " + shape + (key == "enum" ? " Name its allowed values in description." : ""))
                }
                guard let description = declaration["description"] else { params[name] = .string(spelled); continue }
                guard !(string(["d": description], "d") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw refuse("params.\(name).description is nonempty text, or leave description out.")
                }
                declaration["type"] = .string(spelled)
                params[name] = .object(declaration)
            }
            return params
        }
        // Flat maps take precedence; JSON Schema properties are optional only when not required.
        do { return (try read(fields), false) } catch {
            guard fields["type"] == .string("object"), case .object(let properties)? = fields["properties"],
                  fields.keys.allSatisfy(["type", "properties", "required", "additionalProperties", "readOnly"].contains) else { throw error }
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
            var flat = properties
            for (name, value) in properties where !required.contains(name) {
                guard let type = parameterType(value), !type.hasSuffix("?") else { continue }
                if case .object(var declaration) = value { declaration["type"] = .string(type + "?"); flat[name] = .object(declaration) }
                else { flat[name] = .string(type + "?") }
            }
            return (try read(flat), fields["readOnly"] == .bool(true))
        }
    }

    /// Every run must validate against the derived input schema.
    static func inputSchema(_ params: [String: JSONValue], readOnly: Bool = false) -> JSONValue {
        let types = ["string": "string", "int": "integer", "number": "number", "bool": "boolean", "list": "array", "object": "object"]
        let properties = params.mapValues { value -> JSONValue in
            let type = parameterType(value) ?? ""
            var property: [String: JSONValue] = ["type": .string(types[type.hasSuffix("?") ? String(type.dropLast()) : type] ?? "")]
            if case .object(let declaration) = value, let description = declaration["description"] { property["description"] = description }
            return .object(property)
        }
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties),
            "required": .array(params.keys.sorted().filter { !(parameterType(params[$0]) ?? "").hasSuffix("?") }.map(JSONValue.string)),
            "additionalProperties": .bool(false)]
        if readOnly { schema["readOnly"] = .bool(true) }
        return .object(schema)
    }

    static func parameterType(_ value: JSONValue?) -> String? {
        if case .string(let type)? = value { return type }
        return string(fields(value ?? .null), "type")
    }

    /// Runner verbs and malformed references cannot become action IDs.
    public static func dependencyID(_ spelled: String) -> String? {
        let id = spelled.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id == "find" { return id }
        let bare = id.hasPrefix("app.") ? String(id.dropFirst(4)) : id
        return !OwnedProgram.verbs.contains(bare) && id.range(of: "^[a-z0-9_-]+(\\.[a-z0-9_-]+)+$", options: .regularExpression) != nil ? id : nil
    }

}
