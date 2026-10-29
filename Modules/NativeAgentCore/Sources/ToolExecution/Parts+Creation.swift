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
// Blueprint: | `Parts+Creation.swift` | Parts saving and rehearsal with staged-write settlement, inherited input contracts and ratcheting provenance; save receipts retain validate/proof/write milliseconds |

extension Parts {
    /// `ability.save`, a new part or a revision. A revision restates only what changes: its code (or edits to it) and each declaration it
    /// leaves out are its latest version's; an explicit empty value drops one. Under Full Mac her own save is kept and on in this one act;
    /// otherwise it waits as a draft. `origin` is a pack's, for a pack's install.
    public func save(_ input: [String: JSONValue], steer: [String], fullMac: Bool, origin given: JSONValue? = nil) async throws -> [String: JSONValue] {
        let started = ContinuousClock.now
        var validateMS = 0.0, proofMS = 0.0
        func milliseconds(since start: ContinuousClock.Instant) -> Double {
            let elapsed = start.duration(to: .now).components
            return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        }
        func timed(_ receipt: [String: JSONValue]) -> [String: JSONValue] {
            receipt.merging(["timing": .object(["validate_ms": .double(validateMS),
                "proof_ms": .double(proofMS),
                "write_ms": .double(max(0, milliseconds(since: started) - validateMS - proofMS))])]) { _, value in value }
        }
        func refuse(_ why: String) -> PartError { .invalid(why + " Nothing was saved.") }
        guard OwnedProgramInvocation.host != nil else {
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
        // A new part never takes a shipped name; revising a part she has, shipped ones included, is hers.
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
            throw refuse("code is required: sync JavaScript defining function run(input).")
        }
        if let why = OwnedProgram.asyncRefusal(source) { throw SenseFailure(code: "async_code", message: why + " Nothing was saved.") }
        let description = (Self.string(input, "description") ?? Self.string(was, "description") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw refuse("description is required: one line saying when and why this ability helps.") }
        if input["description"] != nil, description.count > 500 || description.rangeOfCharacter(from: .newlines) != nil {
            throw refuse(description.count > 500 ? "description is \(description.count) characters; keep it to one line of at most 500 and put the details in params descriptions or the code."
                : "description is one line; remove its line breaks.")
        }
        // Inputs: params (a type map, {type, description?} each, or a JSON Schema object), or a legacy input_schema kept as given.
        // Unrestated, its latest version's: its program's schema, and its params (a skill's older version declared them inside its script).
        var params = was["params"] ?? Self.fields(was["script"] ?? .null)["params"]
        var schema = base?.program.schema ?? .object(["type": .string("object"), "properties": .object([:])])
        if let declared = input["params"] {
            if declared == .null || declared == .object([:]) {
                params = nil; schema = .object(["type": .string("object"), "properties": .object([:])])
            } else {
                let read = try Self.params(declared)
                params = .object(read.params); schema = Self.inputSchema(read.params, readOnly: read.readOnly)
            }
        } else if let legacy = input["input_schema"] {
            guard case .object = legacy else { throw refuse("input_schema is a JSON Schema object; params is the one form.") }
            params = nil; schema = legacy
        }
        var header = input.filter { AbilityStore.partKeys.contains($0.key) }
        if header["reach"] == nil, let legacy = input["permissions"] { header["permissions"] = legacy }
        for key in AbilityStore.partKeys where header[key] == nil && !(key == "reach" && header["permissions"] != nil) { header[key] = was[key] }
        let part = try AbilityStore.partHeader(header, saving: true)
        let permissions = try Self.declaredStrings(Self.fields(part["reach"] ?? .null)["capabilities"], name: "reach.capabilities")
        // What it calls is read off its code and derived from its reach; actions names only what it reaches dynamically (host.call).
        let reached = AbilityStore.reachActions(permissions)
        let called = OwnedProgram.calledActions(source)
        // Resolve the complete dependency set once when building the candidate; dependencyShapes supplies the same unknown-action refusal
        // for all calls.
        if let bare = Self.bareCalls(source).first {
            throw refuse("app.\(bare)() calls nothing: an action is app.<page>.<action>(…), and app's own verbs are read, find, log, step, decide, expect and expect_fail.")
        }
        if Self.callsAppAsFunction(source) {
            throw refuse("app(…) is the chat spelling, not the program's: in code an action is app.<page>.<action>(args), e.g. app.agent.message({agent: \"Claude Desktop\", text: note}); app's own verbs are read, find, log, step, decide, expect and expect_fail.")
        }
        let declared: [String]
        if let given = input["actions"] {
            declared = try Self.declaredStrings(given, name: "actions").compactMap(Self.dependencyID)
        } else {
            let earlier = Self.strings(was["declaredActions"] ?? was["actions"] ?? Self.fields(was["script"] ?? .null)["actions"])
            let derived = Set(AbilityStore.reachActions(try Self.declaredStrings(Self.fields(was["reach"] ?? .null)["capabilities"], name: "reach.capabilities"))
                + OwnedProgram.calledActions(base?.program.source ?? ""))
            declared = was["declaredActions"] != nil ? earlier : earlier.filter { !derived.contains($0) }
        }
        var actions: [String] = []
        for id in declared + called + reached where !actions.contains(id) { actions.append(id) }
        guard actions.count <= OwnedProgramRunner.actionLimit else { throw refuse("An ability calls at most \(OwnedProgramRunner.actionLimit) app actions.") }
        // The night's keep moment saves against its recorded tape; a tape is never anyone's to write by hand.
        let compiling = Self.compiling
        try compiling?.admit(id: id, actions: actions)
        let suppliedFixtures = input["fixtures"] ?? input["tests"]
        let fixtures = try compiling?.fixtures(input["fixtures"]) ?? suppliedFixtures ?? base?.fixtures ?? .array([])
        if compiling == nil, let suppliedFixtures, case .array(let given) = suppliedFixtures, given.contains(where: { Self.fields($0)["tape"] != nil }) {
            throw refuse("A fixture's tape comes only from recorded practice; give input, calls, answers and expected.")
        }
        guard case .array(let cases) = fixtures, cases.count <= 16, try fixtures.serializedData(pretty: false).count <= 256 * 1024 else {
            throw refuse("fixtures is a list of at most 16 {input, expected} cases in 256 KiB; omit it to capture during ability.validate.")
        }
        let name = Self.string(input, "name") ?? existing.flatMap { Self.string($0, "name") } ?? Self.referenceID(named)
        // Compiled from turns other agents steered, it is theirs as much as hers.
        let origin = given ?? Self.merged([Self.origin(steeredBy: steer + (compiling?.steer ?? []))] + Self.recorded(existing) + (base.map { [Self.fields($0.manifest)["origin"]] } ?? []))
        let guidance = defaultPersonaRoot(dataRoot: root).appendingPathComponent("skills/bodies/\(id).md")
        var manifest: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "description": .string(description), "language": .string("javascript"),
            "inputSchema": schema, "actions": .array(actions.map(JSONValue.string)), "declaredActions": .array(declared.map(JSONValue.string)),
            "origin": origin, "converts": try OwnedProgramStore.conversionSources(input["converts"] ?? was["converts"]),
        ]
        if let params { manifest["params"] = params }
        manifest["compiled"] = compiling?.record ?? was["compiled"]
        if given != nil, let pack = input["capabilityPackInstallId"] { manifest["capabilityPackInstallId"] = pack }
        if let triggers = input["triggers"] ?? was["triggers"] { manifest["triggers"] = triggers }
        if FileManager.default.fileExists(atPath: guidance.path) || was["overrides"] == .string("built_in") { manifest["overrides"] = .string("built_in") }
        manifest.merge(part) { _, value in value }
        let candidate = try OwnedProgramStore.Candidate(
            program: OwnedProgram(kind: .part, id: id, version: "candidate", source: source, entry: .run, schema: schema,
                                  dependencies: actions, permissions: permissions, resident: part["resident"] == .bool(true)),
            manifest: .object(manifest), fixtures: fixtures, dependencyShapes: try dependencyShapes(actions),
            prior: OwnedProgramStore.selection(existing.map(JSONValue.object)))
        let stamp = Self.now()
        enum Staging { case none, attempted, committed }
        var staged = Staging.none
        validateMS = milliseconds(since: started)
        do {
            try mutate(id) { current in
                guard OwnedProgramStore.selection(current.map(JSONValue.object)) == candidate.prior else {
                    throw PartError.invalid("\(id) changed while it was being saved; save against its current version.")
                }
                try store.stage(candidate, writing: { staged = .attempted })
                staged = .committed
                var row = current ?? manifest.merging(["status": .string("draft"), "createdAt": .string(stamp)]) { $1 }
                row["updatedAt"] = .string(stamp)
                row["candidateDigest"] = .string(candidate.digest); row["candidatePrior"] = candidate.prior
                row["candidateValidation"] = .string("invalid")
                row["proposalPath"] = .string(try abilities.path(id: id, slot: .next).path)
                row = try CapabilityLifecycle.preservingOwnerOff(row, before: current)
                row["candidateSelection"] = OwnedProgramStore.selection(.object(row))
                return row
            }
            var receipt: [String: JSONValue] = ["status": .string("saved"), "id": .string(id), "name": .string(name),
                "candidate_digest": .string(candidate.digest), "actions": .array(actions.map(JSONValue.string))]
            if let compiling {
                // Staged, Full Mac included: its tape replays it before anything keeps it.
                compiling.save(id: id, digest: candidate.digest)
                receipt["ability_status"] = try row(id)?["status"] ?? .null
                receipt["next_call"] = .object(["action": .string("ability.validate"), "args": .object(["id": .string(id)])])
                receipt["detail"] = .string("\(name) is staged from your recorded practice. ability.validate replays its \(compiling.examples.count) examples exactly "
                    + "(every call answered from the tape, nothing runs); once they pass, ability.enable keeps it.")
                return timed(receipt)
            }
            if manifest["compiled"] == nil, given == nil, fullMac, Self.keepRefusal(origin: origin, name: name, fullMac: true) == nil {
                // Kept by her under Full Mac: a rehearsal proves no live behavior, so its first real run is its proof.
                let proving = ContinuousClock.now
                try store.kept(candidate, key: try await SwiftNativeManifestSigner(dataRoot: root).loadOrCreateSigningKey())
                proofMS = milliseconds(since: proving)
                try await admit(id: id, digest: candidate.digest, by: "agent")
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

    /// `ability.validate`: rehearses its waiting version on supplied or captured input. Intercepted replies are not behavioral proof.
    public func validate(_ named: String, input: JSONValue?, capture: Bool) async -> Outcome {
        var attempted = false
        do {
            guard let row = try row(named), let id = Self.string(row, "id") else { return try unknown(named) }
            let name = Self.string(row, "name") ?? id
            guard let candidate = try latest(row), row["candidateDigest"] != nil || row["status"] != .string("active") else {
                let failure = Self.revisionFailure("no_waiting_version", "\(id) has no waiting version to rehearse; save a revision with ability.save.", id: id)
                return (false, failure.message, ["id": .string(id), "reason": .string(failure.code), "effects": .string("none"), "remedy": failure.remedy ?? .null])
            }
            var fields: [String: JSONValue] = ["id": .string(id), "name": .string(name), "candidate_digest": .string(candidate.digest),
                "effects": .string("none"), "effect": .string("none"), "read_only": .bool(true), "execution": .string("rehearsed")]
            do {
                attempted = true
                let proof = try await rehearse(candidate, capture: capture, input: input)
                let replayed = Self.fields(proof)["tape"] != nil
                try mutate(id) { current in
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
                    return (true, "Its recorded examples replayed exactly from the tape and nothing ran. That proves those examples, no other input or branch; ability.enable keeps it, and its live runs earn its record.", fields)
                }
                return (true, "The supplied inputs passed rehearsal; intercepted replies are not behavioral proof. Read its exact version before keeping it.", fields)
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

    /// Whose work a version is: hers, or the untrusted agents that steered the turn that wrote it. A trusted agent that started the turn is
    /// its provenance, never its author.
    public static func origin(steeredBy steer: [String]) -> JSONValue {
        let peers = steer.filter { !CapabilityLifecycle.ownerTrusts($0) }
        return peers.isEmpty ? .object(["by": .string("hers")])
            : .object(["by": .string("peer"), "peers": .array(peers.map(JSONValue.string))])
    }

    public static func origin(pack: String) -> JSONValue { .object(["by": .string("pack"), "pack": .string(pack)]) }

    /// hers, peer or pack; nil when missing or malformed.
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

    /// Origins only ratchet toward the owner: no later save of hers launders an untrusted agent's or a pack's mark. A nil entry is an
    /// origin that should exist and doesn't, an unrecorded peer.
    static func merged(_ origins: [JSONValue?]) -> JSONValue {
        var peers: [String] = [], pack: String?
        for given in origins.isEmpty ? [nil] : origins {
            // A tool's older spellings: "self", or the steer of the turn that proposed it.
            let steer = Self.fields(given ?? .null)["steer"]
            let spelled = given == .string("self") ? Self.origin(steeredBy: [])
                : steer != nil && Self.fields(given ?? .null)["by"] == nil ? Self.origin(steeredBy: strings(steer)) : given
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

    /// The origin a record already carries, to merge.
    static func recorded(_ row: [String: JSONValue]?) -> [JSONValue?] {
        guard let row, row["origin"] != nil || row["codeFingerprint"] != nil else { return [] }
        return [row["origin"]]
    }

    static func agentMayAdmit(_ origin: JSONValue?) -> Bool {
        guard let kind = originKind(origin), fields(origin ?? .null)["pack"] == nil else { return false }
        return kind == "hers" || kind == "peer" && strings(fields(origin ?? .null)["peers"]).allSatisfy(CapabilityLifecycle.ownerTrusts)
    }

    /// Whose words a line naming this part carries: none for her own.
    public static func voices(_ row: [String: JSONValue]) -> [String] {
        guard row["origin"] != nil, case .object(let origin) = merged([row["origin"]]) else { return [] }
        return strings(origin["peers"]) + [string(origin, "pack")].compactMap { $0 }
    }

    // MARK: - Inputs

    /// A part's params: each input name to its type (string, int, number, bool, list or object; a trailing ? marks it optional) or {type,
    /// description?}; or a JSON Schema object, whose properties are the params.
    static func params(_ value: JSONValue) throws -> (params: [String: JSONValue], readOnly: Bool) {
        func refuse(_ why: String) -> PartError { .invalid(why + " Nothing was saved.") }
        let shape = "Each param is its type (string, int or integer, number, bool or boolean, list or array, or object; a trailing ? marks it optional) or {type, description?}."
        guard case .object(let fields) = value else { throw refuse("params maps each input name to its type. " + shape) }
        func read(_ fields: [String: JSONValue]) throws -> [String: JSONValue] {
            var params: [String: JSONValue] = [:]
            for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
                guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil else {
                    throw refuse("params.\(name): a param name is a letter or _ then up to 63 letters, digits or _.")
                }
                let given = parameterType(value) ?? "", optional = given.hasSuffix("?")
                let base = optional ? String(given.dropLast()) : given
                let type = ["integer": "int", "boolean": "bool", "array": "list"][base] ?? base
                guard ["string", "int", "number", "bool", "list", "object"].contains(type) else {
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
        // The flat map reads first; only a map that does not read flat and is a JSON Schema object reads as one, an unrequired property
        // optional.
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

    /// The JSON Schema its params mean, checked against every run's input.
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

    /// The action id an `actions` entry spells; nil for a runner verb or no id's shape.
    public static func dependencyID(_ spelled: String) -> String? {
        let id = spelled.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bare = id.hasPrefix("app.") ? String(id.dropFirst(4)) : id
        return !OwnedProgram.verbs.contains(bare) && id.range(of: "^[a-z0-9_-]+(\\.[a-z0-9_-]+)+$", options: .regularExpression) != nil ? id : nil
    }

    /// `app(` — the chat tool's request-object spelling, which the program door never had; refused at save so it never reaches a run as
    /// "app is not a function".
    static func callsAppAsFunction(_ source: String) -> Bool {
        OwnedProgram.code(source).range(of: #"(^|[^\w.$])app\s*\("#, options: .regularExpression) != nil
    }

    /// `app.<name>(` that is no runner verb: a call to nothing (app.call is not the API).
    static func bareCalls(_ source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\bapp\s*\.\s*(\w+)\s*\("#) else { return [] }
        let code = OwnedProgram.code(source)
        return regex.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { match in
            Range(match.range(at: 1), in: code).map { String(code[$0]) }
        }.filter { !OwnedProgram.verbs.contains($0) }
    }

    // MARK: - Older doors

    /// A skill.save's or a tool.propose's arguments, as ability.save's.
    public static func saveArguments(_ args: [String: JSONValue]) -> [String: JSONValue] {
        var out = args
        if let id = out.removeValue(forKey: "tool_id") { out["id"] = id }
        if out["id"] == nil, let name = args["name"] { out["id"] = name }
        if case .object(let script)? = out.removeValue(forKey: "script") {
            out["code"] = out["code"] ?? script["source"]
            if out["params"] == nil, let params = script["params"] { out["params"] = params }
            if out["actions"] == nil, let actions = script["actions"] { out["actions"] = actions }
        }
        if let tests = out.removeValue(forKey: "tests"), out["fixtures"] == nil { out["fixtures"] = tests }
        // A tool's inline rehearsal is ability.validate's now; a built-in's marker is the save's own.
        for key in ["input", "capture", "overrides"] { out.removeValue(forKey: key) }
        return out
    }
}
