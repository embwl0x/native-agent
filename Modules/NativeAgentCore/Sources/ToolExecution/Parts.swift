import AuthoredCapabilities
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import ToolRegistry
import Senses
import PersonaEngine
import Privacy
// Blueprint: | `Parts.swift` | `Parts`, `PartError`: the one form of a part (docs/AGENT_IS_THE_APP.md): one save (a revision inherits what it does not restate; `edits` revise its code), one read-only keep eligibility projection shared by Tools and enable (`prepareKeep`, current row against the reviewed full digest and sealed proof; nil version restores only disabled Markdown guidance without a candidate or code fingerprint, decided and written under the ability-store lock; `keepRefusal`: theirs under Full Mac for them own work, else the owner's card), one signed admission re-verified each run, one run with bounded version-pinned typed `call` (optional native preview retains the runner/host preview posture; optional native `CallReach` narrows the pinned candidate's actions/primitive capabilities before suspension) and pure `face` entries and broker settlement, one all-kind list shared with the Tools page, one read (kind/version and selected declarations and latest code labeled by source.version, built-in guidance through InstalledSkillInventory), one lifecycle (enable, restore, disable, rollback, drop, validate); launch migration of tool and skill records; bundled seeds kept with exact sealed admission |

public enum PartError: Error, LocalizedError {
    case invalid(String)
    case notFound(String)
    /// The version was staged by this call (committed: the write returned; else
    /// the write was attempted and may be on disk) and the call did not complete.
    case stagedButFailed(digest: String, committed: Bool, why: String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let why): return why
        case .notFound(let name): return "No ability has id or name \(name). Use app {action:\"ability.list\"} to choose an exact id, or ability.save to create one."
        case .stagedButFailed(_, let committed, let why): return "\(committed ? "staged" : "staging attempted"), the call did not complete: \(why)"
        }
    }
}

/// A part is a part (docs/AGENT_IS_THE_APP.md): what it can do is what it
/// declares, never which door made it. One save, one keep, one run, one read
/// and one lifecycle over the shared ability files, one signed admission
/// re-verified on every run.
public struct Parts: Sendable {
    public typealias Outcome = (ok: Bool, text: String, fields: [String: JSONValue])
    public let root: URL
    public init(root: URL = PersistenceCore.defaultDataRoot()) { self.root = root }
    var store: OwnedProgramStore { OwnedProgramStore(root: root.appendingPathComponent("abilities")) }
    var abilities: AbilityStore { AbilityStore(dataRoot: root) }

    // MARK: - Rows

    /// Execution records by default; nil includes every stored kind for reads.
    public func rows(kind: AbilityStore.Kind? = .part) throws -> [[String: JSONValue]] {
        guard case .array(let rows) = try abilities.registry(kind: kind) else {
            throw ToolFailureError("The ability registry did not return rows.", effects: .none, owner: abilities.root.path,
                nextCall: ToolFailureError.call("app", ["action": .string("files.list"), "args": .object(["path": .string(abilities.root.path)])]),
                code: "ability_registry_shape", instruction: "Inspect the ability sources and repair the reported malformed header from retained evidence; preserve versions and authority.", recovery: .inspect)
        }
        return rows.map(Self.fields)
    }

    /// The part a name names: its id, else its name, either case.
    public func row(_ named: String, kind: AbilityStore.Kind? = .part) throws -> [String: JSONValue]? {
        let name = named.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try rows(kind: kind)
        return all.first { Self.string($0, "id")?.caseInsensitiveCompare(name) == .orderedSame }
            ?? all.first { Self.string($0, "name")?.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The id rule: lowercase letters, digits, - and _, a letter first, 2 to
    /// 64 long. "Days left" is days-left.
    public static func id(_ given: String) -> String {
        AbilityStore.normalizedID(given)
    }

    /// Its latest version: the one waiting, else the selected one.
    public func latest(_ row: [String: JSONValue]) throws -> OwnedProgramStore.Candidate? {
        guard let id = Self.string(row, "id"),
              let digest = Self.string(row, "candidateDigest") ?? Self.string(row, "codeFingerprint") else { return nil }
        return try store.load(id: id, digest: digest)
    }

    // MARK: - One save

    /// `ability.save`, a new part or a revision. A revision restates only what
    /// changes: its code (or edits to it) and each declaration it leaves out
    /// are its latest version's; an explicit empty value drops one. Under Full
    /// Mac her own save is kept and on in this one act; otherwise it waits as
    /// a draft. `origin` is a pack's, for a pack's install.
    public func save(_ input: [String: JSONValue], steer: [String], fullMac: Bool, origin given: JSONValue? = nil) async throws -> [String: JSONValue] {
        func refuse(_ why: String) -> PartError { .invalid(why + " Nothing was saved.") }
        guard let host = OwnedProgramInvocation.host else {
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
            return ["status": .string("failed"), "effects": .string("none"), "reason": .string("name_exists"),
                    "detail": .string("That ability name already exists. Choose a fresh name; nothing was replaced.")]
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
        // Inputs: params (a type map, {type, description?} each, or a JSON
        // Schema object), or a legacy input_schema kept as given.
        // Unrestated, its latest version's: its program's schema, and its params
        // (a skill's older version declared them inside its script).
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
        // What it calls is read off its code and derived from its reach; actions
        // names only what it reaches dynamically (host.call).
        let reached = Self.reachActions(permissions)
        let called = OwnedProgram.calledActions(source)
        if let unknown = called.first(where: { host.dependencyShape($0) == nil }) {
            throw refuse("Its code calls app.\(unknown)(…), which is no action now: fix the call, or use the action find shows.")
        }
        if let bare = Self.bareCalls(source).first {
            throw refuse("app.\(bare)() calls nothing: an action is app.<page>.<action>(…), and app's own verbs are read, find, log, step, decide, expect and expect_fail.")
        }
        let declared: [String]
        if let given = input["actions"] {
            declared = try Self.declaredStrings(given, name: "actions").compactMap(Self.dependencyID)
        } else {
            let earlier = Self.strings(was["declaredActions"] ?? was["actions"] ?? Self.fields(was["script"] ?? .null)["actions"])
            let derived = Set(Self.reachActions(try Self.declaredStrings(Self.fields(was["reach"] ?? .null)["capabilities"], name: "reach.capabilities"))
                + OwnedProgram.calledActions(base?.program.source ?? ""))
            declared = was["declaredActions"] != nil ? earlier : earlier.filter { !derived.contains($0) }
        }
        var actions: [String] = []
        for id in declared + called + reached where !actions.contains(id) { actions.append(id) }
        guard actions.count <= OwnedProgramRunner.actionLimit else { throw refuse("An ability calls at most \(OwnedProgramRunner.actionLimit) app actions.") }
        let fixtures = input["fixtures"] ?? input["tests"] ?? .array([])
        guard case .array(let cases) = fixtures, cases.count <= 16, try fixtures.serializedData(pretty: false).count <= 256 * 1024 else {
            throw refuse("fixtures is a list of at most 16 {input, expected} cases in 256 KiB; omit it to capture during ability.validate.")
        }
        let name = Self.string(input, "name") ?? existing.flatMap { Self.string($0, "name") } ?? named
        let origin = given ?? Self.merged([Self.origin(steeredBy: steer)] + Self.recorded(existing) + (base.map { [Self.fields($0.manifest)["origin"]] } ?? []))
        let guidance = defaultPersonaRoot(dataRoot: root).appendingPathComponent("skills/bodies/\(id).md")
        var manifest: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "description": .string(description), "language": .string("javascript"),
            "inputSchema": schema, "actions": .array(actions.map(JSONValue.string)), "declaredActions": .array(declared.map(JSONValue.string)),
            "origin": origin, "converts": try OwnedProgramStore.conversionSources(input["converts"]),
        ]
        if let params { manifest["params"] = params }
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
        let staged = StagedFlag()
        do {
            try mutate(id) { current in
                guard OwnedProgramStore.selection(current.map(JSONValue.object)) == candidate.prior else {
                    throw PartError.invalid("\(id) changed while it was being saved; save against its current version.")
                }
                try store.stage(candidate, writing: staged.attempt)
                staged.commit()
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
            if given == nil, fullMac, Self.keepRefusal(origin: origin, name: name, fullMac: true) == nil {
                // Kept by her under Full Mac (User 10-15): a rehearsal proves no live
                // behavior, so its first real run is its proof.
                try store.kept(candidate, key: try await SwiftNativeManifestSigner(dataRoot: root).loadOrCreateSigningKey())
                try await admit(id: id, digest: candidate.digest, by: "agent")
                receipt["status"] = .string("kept"); receipt["ability_status"] = .string("active")
                receipt["next_call"] = .object(["action": .string("authored." + id), "args": .object([:])])
                receipt["detail"] = .string("\(name) is kept and on: run it as authored.\(id); its first real run is its proof.")
                return receipt
            }
            receipt["ability_status"] = try row(id)?["status"] ?? .null
            receipt["next_call"] = .object(["action": .string("ability.validate"), "args": .object(["id": .string(id)])])
            receipt["detail"] = .string("\(name) is saved as a draft. ability.validate rehearses it; ability.enable keeps it "
                + (fullMac ? "(yours when it is your own work)." : "(below Full Mac, the owner's card)."))
            return receipt
        } catch {
            switch staged.state {
            case .none: throw error
            case .attempted, .committed:
                throw PartError.stagedButFailed(digest: candidate.digest, committed: staged.state == .committed, why: error.localizedDescription)
            }
        }
    }

    /// Where the version write stands, read by the failure path.
    private final class StagedFlag: @unchecked Sendable {
        enum State { case none, attempted, committed }
        private let lock = NSLock()
        private var value = State.none
        func attempt() { lock.withLock { value = .attempted } }
        func commit() { lock.withLock { value = .committed } }
        var state: State { lock.withLock { value } }
    }

    /// One part's record, changed under the store's lock.
    func mutate(_ id: String, ownerAuthorized: Bool = false, enabling: Bool = false,
                _ change: ([String: JSONValue]?) throws -> [String: JSONValue]) throws {
        try AbilityStore.withLock {
            var rows = try self.rows()
            let index = rows.firstIndex { $0["id"] == .string(id) }
            let row = try change(index.map { rows[$0] })
            if let index { rows[index] = row } else { rows.append(row) }
            try abilities.saveRegistry(.array(rows.map(JSONValue.object)), kind: .part, ownerAuthorized: ownerAuthorized, enabling: enabling)
        }
    }

    // MARK: - One keep

    /// Who keeps a version: nil when it is hers to keep now, else why it is
    /// the owner's. Her own work is hers under Full Mac; a version from
    /// untrusted agents or a pack, and anything below Full Mac, are the
    /// owner's. A turn an untrusted agent started asks its one command card
    /// at the gate, and the store refuses its writes until that is answered.
    public static func keepRefusal(origin: JSONValue?, name: String, fullMac: Bool) -> String? {
        let fields = fields(origin ?? .null)
        switch originKind(origin) {
        case "peer"?: return "\(name) came from untrusted agents \(strings(fields["peers"]).joined(separator: ", ")), so keeping it is the owner's card for this exact version"
        case "pack"?: return "\(name) came with the \(string(fields, "pack") ?? "") pack, so keeping it is the owner's"
        case nil: return "\(name) has no attested origin, so keeping it is the owner's"
        default: break
        }
        return fullMac ? nil : "Below Full Mac, keeping an ability is the owner's"
    }

    /// Admits one version: signs its sealed proof (rehearsed, kept or a seed's)
    /// and selects it, on. `by` is who kept it, user or agent.
    func admit(id: String, digest: String, by: String, ownerAuthorized: Bool = false) async throws {
        let candidate = try store.load(id: id, digest: digest)
        try checkDependencies(candidate)
        let signer = SwiftNativeManifestSigner(dataRoot: root)
        let key = try await signer.loadOrCreateSigningKey()
        let proof = try store.proof(candidate, key: key)
        let admission = try await signer.sign(["id": .string(id), "candidate": .string(digest), "proof": proof, "by": .string(by)])
        let path = try abilities.path(id: id).path, stamp = Self.now()
        try await store.keep(candidate, key: key, ownerAuthorized: ownerAuthorized) { value in
            guard case .array(var rows) = value, let index = rows.firstIndex(where: { Self.fields($0)["id"] == .string(id) }),
                  case .object(var row) = rows[index],
                  row["candidateDigest"] == .string(digest) || row["candidateDigest"] == nil && row["codeFingerprint"] == .string(digest) else {
                throw PartError.invalid("\(id)'s waiting version is no longer \(digest.prefix(12)); read it and keep the one it shows.")
            }
            // Its record is what this version declares; a skill's older version
            // declared its params inside its script. The origin only ratchets.
            // Its id stays the owner's: a migrated version declares the id it was sealed under.
            var declared = Self.fields(candidate.manifest).filter { $0.value != .null }
            declared["id"] = .string(candidate.id)
            if case .object(let script)? = declared.removeValue(forKey: "script"), declared["params"] == nil { declared["params"] = script["params"] }
            let origin = Self.merged([declared["origin"]] + Self.recorded(row))
            // Its params are this version's: one it declares none for takes none.
            row.removeValue(forKey: "params")
            row.merge(declared) { $1 }
            row["origin"] = origin; row["language"] = .string("javascript"); row["inputSchema"] = candidate.program.schema
            row["actions"] = .array(candidate.program.dependencies.map(JSONValue.string))
            // Turned back on by hand: a retired seed's fade leaves it on.
            if row["status"] == .string("disabled") { row["enabledAt"] = .string(stamp) }
            row["status"] = .string("active"); row["codeFingerprint"] = .string(digest); row["activePath"] = .string(path)
            row["admission"] = .object(admission)
            for key in ["disabledBy", "disabledReason", "phase"] { row.removeValue(forKey: key) }
            row["promotedAt"] = .string(stamp); row["updatedAt"] = .string(stamp)
            rows[index] = .object(row); value = .array(rows)
        }
    }

    private enum KeepPlan {
        case stopped(Outcome)
        case guidance(String, String, [String: JSONValue])
        case code(String, String, String, OwnedProgramStore.Candidate, Bool, [String: JSONValue])

        func preview(ownerAuthorized: Bool) -> Outcome {
            switch self {
            case .stopped(let outcome): return outcome
            case .guidance(_, let name, let fields):
                return (true, "Would turn \(name) back on.", fields.merging(["would_status": .string("active")]) { $1 })
            case .code(_, let name, _, _, let proved, let fields):
                return (true, "Would keep \(name) and turn it on" + (proved ? "." : ", sealed as kept: its first real run is its proof."),
                        fields.merging(["would_status": .string("active"), "would_admit": .string(ownerAuthorized ? "owners" : "hers")]) { $1 })
            }
        }
    }

    /// One read-only keep decision, including the exact candidate's sealed proof.
    private func prepareKeep(_ named: String, row: [String: JSONValue]?, version: String?, fullMac: Bool, ownerAuthorized: Bool) throws -> KeepPlan {
        guard let row, let id = Self.string(row, "id") else { return .stopped(Self.unknown(named)) }
        let name = Self.string(row, "name") ?? id, status = Self.string(row, "status") ?? ""
        var fields: [String: JSONValue] = ["id": .string(id), "name": .string(name), "state_before": .string(status)]
        guard let digest = Self.string(row, "candidateDigest") ?? Self.string(row, "codeFingerprint") else {
            // Guidance (a Markdown ability) has no code: back on is its status
            // alone, by the same authority (the store keeps the owner's off his).
            guard version == nil, status == "disabled", try abilities.read(id: id)?.pathExtension == "md" else {
                let failure = Self.revisionFailure("no_ability_code", "\(id) has no code to keep. Save synchronous JavaScript defining run(input) with ability.save.", id: id)
                return .stopped((false, failure.message, fields.merging(["reason": .string(failure.code), "effects": .string("none"), "remedy": failure.remedy ?? .null]) { $1 }))
            }
            if !ownerAuthorized, let why = CapabilityLifecycle.requiresOwnerToEnable(row) ? "The owner switched \(name) off, so turning it back on is theirs"
                : Self.keepRefusal(origin: Self.merged([row["origin"]]), name: name, fullMac: fullMac) {
                return .stopped((false, why + ". Nothing changed.", fields.merging(["reason": .string("owners_call")]) { $1 }))
            }
            return .guidance(id, name, fields)
        }
        if version != digest {
            return .stopped((false, "version must be \(name)'s waiting version (ability.read shows it). Nothing changed.",
                    fields.merging(["reason": .string("bad_input"), "next_call": .object(["action": .string("ability.read"),
                        "args": .object(["id": .string(id)])])]) { $1 }))
        }
        if status == "active", row["candidateDigest"] == nil {
            return .stopped((true, "\(name) is already on.", fields.merging(["changed": .bool(false)]) { $1 }))
        }
        // The guard reads the off's actor (an unreadable one is refused and
        // named); the owner's off is his to lift, hers to ask, on his card.
        let ownersOff = !ownerAuthorized && CapabilityLifecycle.requiresOwnerToEnable(row)
        do { _ = try CapabilityLifecycle.preservingOwnerOff(row, before: row, ownerAuthorized: ownerAuthorized || ownersOff, enabling: true, preview: true) }
        catch let error as ToolFailureError {
            return .stopped((false, error.localizedDescription, fields.merging(["reason": .string("owners_call"), "remedy": Self.remedy(error)]) { $1 }))
        }
        let candidate = try store.load(id: id, digest: digest)
        if let why = OwnedProgram.asyncRefusal(candidate.program.source) {
            return .stopped((false, why + " ability.save it so, then enable it. Nothing changed.", fields))
        }
        let key: Data?
        do { key = try SwiftNativeManifestSigner(dataRoot: root).existingSigningKey() }
        catch { throw ManifestSigningError.keyUnavailable(error.localizedDescription) }
        let proved = key.flatMap { try? store.proof(candidate, key: $0) } != nil
        let origin = Self.merged([Self.fields(candidate.manifest)["origin"]] + Self.recorded(row))
        fields["candidate_digest"] = .string(digest)
        if !ownerAuthorized, let why = ownersOff ? "The owner switched \(name) off, so turning it back on is theirs"
            : Self.keepRefusal(origin: origin, name: name, fullMac: fullMac) {
            guard proved else {
                return .stopped((false, "Rehearse \(name)'s waiting version with ability.validate before it goes to the owner. Nothing changed.",
                        fields.merging(["next_call": .object(["action": .string("ability.validate"), "args": .object(["id": .string(id)])])]) { $1 }))
            }
            // The complete version is for the owner's card; the door strips it.
            return .stopped((false, why + ": they read it and keep it. Nothing changed.",
                    fields.merging(["needs_owner": .bool(true), "reason": .string("owners_call"),
                                    "review": .object(["version": .string(digest), "code": .string(candidate.program.source),
                                        "manifest": candidate.manifest, "fixtures": candidate.fixtures,
                                        "dependencyShapes": candidate.dependencyShapes, "prior": candidate.prior]),
                                    "would_status": .string("active"), "would_admit": .string("owners_card")]) { $1 }))
        }
        guard proved || !ownerAuthorized else {
            return .stopped((false, "Rehearse \(name)'s waiting version before keeping it.", fields))
        }
        return .code(id, name, digest, candidate, proved, fields)
    }

    public func keepEligibility(_ record: ToolRecord, fullMac: Bool, ownerAuthorized: Bool) -> Outcome {
        do { return try AbilityStore.withLock {
            try prepareKeep(record.id, row: row(record.id), version: record.reviewedKeepDigest,
                            fullMac: fullMac, ownerAuthorized: ownerAuthorized).preview(ownerAuthorized: ownerAuthorized)
        } }
        catch {
            var fields = Self.fields(ToolHost.failure(error, effects: "none", execution: "not_run"))
            let detail = "Keeping \(record.id) could not be assessed: \(error.localizedDescription)"
            fields["detail"] = .string(detail)
            if fields["reason"] == .string("world_error") {
                fields["reason"] = .string("keep_eligibility_unavailable"); fields["failure_code"] = fields["reason"]
            }
            if fields["remedy"] == nil || fields["remedy"] == .null {
                fields["remedy"] = Repair.reconcile(instruction: "Read this ability and resolve the reported cause before assessing whether to keep it.", nextCall: Self.readCall(record.id))
            }
            return (false, detail, fields)
        }
    }

    /// Keep the checked candidate: hers under Full Mac for her own work,
    /// otherwise the owner's exact card. Code requires its full digest; nil
    /// restores guidance only. Preview uses the same read-only decision.
    public func enable(_ named: String, version: String?, fullMac: Bool,
                       ownerAuthorized: Bool, preview: Bool = false) async -> Outcome {
        var attempted = false
        do {
            // Guidance selection and restoration are one store transaction, so
            // staging code cannot change what a nil-version restore authorizes.
            let plan = try AbilityStore.withLock {
                let plan = try prepareKeep(named, row: try row(named), version: version, fullMac: fullMac, ownerAuthorized: ownerAuthorized)
                if !preview, case .guidance(let id, let name, _) = plan {
                    attempted = true
                    try mutate(id, ownerAuthorized: ownerAuthorized, enabling: true) { current in
                        guard var row = current, row["status"] == .string("disabled") else { throw PartError.invalid("\(name) changed meanwhile; read it again.") }
                        row["status"] = .string("active"); row["enabledAt"] = .string(Self.now()); row["updatedAt"] = row["enabledAt"]
                        for key in ["disabledBy", "disabledReason"] { row.removeValue(forKey: key) }
                        return row
                    }
                }
                return plan
            }
            if preview { return plan.preview(ownerAuthorized: ownerAuthorized) }
            switch plan {
            case .stopped(let outcome): return outcome
            case .guidance(_, let name, let fields):
                return (true, "\(name) is on: it is guidance, read with ability.read.", fields)
            case .code(let id, let name, let digest, let candidate, let proved, let fields):
                attempted = true
                if !proved { try store.kept(candidate, key: try await SwiftNativeManifestSigner(dataRoot: root).loadOrCreateSigningKey()) }
                try await admit(id: id, digest: digest, by: ownerAuthorized ? "user" : "agent", ownerAuthorized: ownerAuthorized)
                guard try self.row(id)?["status"] == .string("active") else {
                    return (false, "Keeping \(name) could not be confirmed after reading it again.", fields.merging([
                        "reason": .string("keep_unconfirmed"), "effects": .string("unknown"),
                        "remedy": Repair.reconcile(instruction: "Read the selected status and version before another change.", nextCall: Self.readCall(id))]) { $1 })
                }
                return (true, "\(name) is on: run it as authored.\(id).", fields.merging(["run": .string("authored." + id)]) { $1 })
            }
        } catch { return Self.mutationFailure(error, named: named, operation: "enable", attempted: attempted) }
    }

    /// `ability.disable`: off, all its versions kept; ability.enable turns it back on.
    /// `disabledBy` is who did it: the owner only on his own surface
    /// (`ownerAuthorized`), an untrusted agent that steered the turn, else
    /// hers (a trusted agent that started the turn is provenance, as in authorship).
    public func disable(_ named: String, reason: String?, steer: [String] = [], fullMac: Bool, ownerAuthorized: Bool) -> Outcome {
        var attempted = false
        do {
            guard let row = try row(named), let id = Self.string(row, "id") else { return Self.unknown(named) }
            let name = Self.string(row, "name") ?? id
            let fields: [String: JSONValue] = ["id": .string(id), "name": .string(name), "state_before": row["status"] ?? .null]
            if let refusal = Self.overrideRefusal(row, name: name, fullMac: fullMac, ownerAuthorized: ownerAuthorized) { return (false, refusal, fields) }
            let untrusted = steer.filter { !CapabilityLifecycle.ownerTrusts($0) }
            let by = ownerAuthorized ? "owner" : untrusted.isEmpty ? "hers" : "peer"
            // His switch on what is already off makes it his; nothing else changes an off.
            guard row["status"] != .string("disabled") || by == "owner" && row["disabledBy"] != .string("owner") else {
                return (true, "\(name) is already off.", fields.merging(["changed": .bool(false)]) { $1 })
            }
            attempted = true
            try mutate(id, ownerAuthorized: ownerAuthorized) { current in
                guard var row = current else { throw PartError.notFound(named) }
                row["status"] = .string("disabled"); row.removeValue(forKey: "phase")
                let who = by == "owner" ? "the owner" : by == "hers" ? "her" : untrusted.joined(separator: ", ")
                row["disabledBy"] = .string(by)
                row["disabledReason"] = .string("Switched off by \(who)" + (reason.map { ": " + $0 } ?? "."))
                row["updatedAt"] = .string(Self.now())
                return row
            }
            return (true, by == "owner" ? "\(name) is off; the owner turns it back on." : "\(name) is off; ability.enable turns it back on.",
                    fields.merging(["disabled_by": .string(by)]) { $1 })
        } catch { return Self.mutationFailure(error, named: named, operation: "disable", attempted: attempted) }
    }

    /// `ability.drop`: deletes the part, its versions and its run state, for
    /// good; `pending` discards only its waiting version.
    public func drop(_ named: String, pending: Bool, fullMac: Bool, ownerAuthorized: Bool, preview: Bool) -> Outcome {
        var attempted = false
        do {
            guard let row = try row(named), let id = Self.string(row, "id") else { return Self.unknown(named) }
            let name = Self.string(row, "name") ?? id
            let fields: [String: JSONValue] = ["id": .string(id), "name": .string(name)]
            if pending {
                guard try abilities.read(id: id, slot: .next) != nil else {
                    return (false, "\(name) has no waiting version; nothing changed.", fields.merging([
                        "reason": .string("no_waiting_version"), "effects": .string("none"),
                        "remedy": Repair.terminal(instruction: "There is no draft to discard; no further drop call is needed.")]) { $1 })
                }
                if preview { return (true, "Would discard \(name)'s waiting version.", fields) }
                attempted = true
                try AbilityStore.withLock {
                    if try abilities.read(id: id) == nil { try abilities.remove(id: id) } else { try abilities.remove(id: id, slot: .next) }
                }
                return (true, "\(name)'s waiting version was discarded.", fields)
            }
            if let refusal = Self.overrideRefusal(row, name: name, fullMac: fullMac, ownerAuthorized: ownerAuthorized) { return (false, refusal, fields) }
            attempted = !preview
            try abilities.remove(id: id, ownerAuthorized: ownerAuthorized, preview: preview)
            return (true, preview ? "Would delete \(name), its versions and its run state permanently."
                : "Dropped \(name) permanently: its ability files and run state are removed.", fields)
        } catch { return Self.mutationFailure(error, named: named, operation: "drop", attempted: attempted) }
    }

    /// `ability.rollback`: swaps its current and previous versions. A version
    /// whose admission still verifies keeps the status; one without waits as a draft.
    public func rollback(_ named: String, version: String?, fullMac: Bool, ownerAuthorized: Bool, preview: Bool) async -> Outcome {
        var attempted = false
        do {
            let selection = try AbilityStore.withLock { () -> ([String: JSONValue], AbilityStore.File?)? in
                guard let row = try row(named), let id = Self.string(row, "id") else { return nil }
                return (row, try abilities.read(id: id))
            }
            guard let (row, current) = selection, let id = Self.string(row, "id") else { return Self.unknown(named) }
            let name = Self.string(row, "name") ?? id
            var fields: [String: JSONValue] = ["id": .string(id), "name": .string(name)]
            if let refusal = Self.overrideRefusal(row, name: name, fullMac: fullMac, ownerAuthorized: ownerAuthorized) { return (false, refusal, fields) }
            guard let previous = try abilities.read(id: id, slot: .previous) else {
                return (false, "\(name) has no earlier version to select; nothing changed.", fields.merging([
                    "reason": .string("no_previous_version"), "effects": .string("none"),
                    "remedy": Repair.terminal(instruction: "No retained prior version exists; revise with ability.save if a change is needed.")]) { $1 })
            }
            guard var selected = previous.record,
                  let digest = Self.string(selected, "codeFingerprint") ?? Self.string(Self.fields(Self.fields(previous.metadata["candidate"] ?? .null)["program"] ?? .null), "version") else {
                let source = try abilities.path(id: id, slot: .previous, pathExtension: previous.pathExtension)
                let failure = abilities.repairFailure(source: source, detail: "The retained prior version has no selection record or code digest.")
                return (false, failure.message, fields.merging(["reason": .string("prior_version_unreadable"), "effects": .string("none"),
                    "remedy": Self.remedy(failure)]) { $1 })
            }
            guard version == nil || version == digest else { return (false, "Only \(id)'s previous version, \(digest), can be selected.", fields.merging([
                "reason": .string("wrong_previous_version"), "effects": .string("none"),
                "remedy": Repair.reconcile(instruction: "Read the retained versions before selecting the exact previous digest.", nextCall: Self.readCall(id))]) { $1 }) }
            let target = try store.load(id: id, digest: digest)
            selected["activePath"] = .string(try store.fileURL(id: id, digest: digest).path)
            let admitted: Bool
            do { try await checkAdmission(target, row: selected); admitted = true }
            catch let failure as SenseFailure where failure.code == "integrity" { admitted = false }
            let status = Self.string(row, "status") == "disabled" ? "disabled" : admitted ? Self.string(row, "status") ?? "draft" : "draft"
            fields["would_land_on"] = .string(String(digest.prefix(12))); fields["would_status"] = .string(status)
            if preview {
                return (true, "Would swap \(name)'s current and previous versions, selecting \(digest.prefix(12)); it would be \(status)"
                    + (status == "draft" ? ": ability.enable keeps it." : "."), fields)
            }
            try AbilityStore.withLock {
                guard try abilities.read(id: id, slot: .previous) == previous, try abilities.read(id: id) == current else {
                    throw PartError.invalid("\(name) changed during rollback; read it again.")
                }
                for key in ["status", "disabledBy", "disabledReason"] { selected[key] = row[key] }
                selected["status"] = .string(status)
                // Selected, it lives in the current file.
                if admitted { selected["activePath"] = .string(try abilities.path(id: id).path) }
                else { for key in ["admission", "activePath"] { selected.removeValue(forKey: key) } }
                for key in ["phase", "manifestSignature", "signedAt", "signatureVersion"] { selected.removeValue(forKey: key) }
                // What restricts it survives the swap: an untrusted agent's or a
                // pack's origin ratchets, and a built-in's own version stays one.
                selected["origin"] = Self.merged(Self.recorded(selected) + Self.recorded(row))
                if row["overrides"] == .string("built_in") { selected["overrides"] = .string("built_in") }
                selected["updatedAt"] = .string(Self.now())
                attempted = true
                try abilities.swap(id: id, record: selected)
            }
            return (true, "Rolled \(name) back to its previous version (\(digest.prefix(12))). "
                + (status == "draft" ? "It is a draft: ability.enable keeps it." : status == "disabled" ? "It stays off." : "It is on under its admission."),
                fields.merging(["state": .string(status)]) { $1 })
        } catch { return Self.mutationFailure(error, named: named, operation: "rollback", attempted: attempted) }
    }

    static func mutationFailure(_ error: Error, named: String, operation: String, attempted: Bool) -> Outcome {
        let cause = ToolHost.failure(error, effects: attempted ? "unknown" : "none", execution: attempted ? "attempted" : "not_run")
        var fields = Self.fields(cause)
        let detail = "ability.\(operation) for \(named) did not complete: \(error.localizedDescription)"
        fields["detail"] = .string(detail)
        fields["effects"] = .string(attempted ? "unknown" : "none")
        if fields["reason"] == .string("world_error") {
            fields["reason"] = .string("ability_\(operation)_failed"); fields["failure_code"] = fields["reason"]
        }
        if attempted {
            fields["result"] = cause
            fields["remedy"] = Repair.reconcile(instruction: "A write was attempted; its final state is unconfirmed. Read \(named)'s status and retained versions before another change, then address the reported cause.", nextCall: readCall(named))
        } else if fields["remedy"] == nil || fields["remedy"] == .null {
            fields["remedy"] = Repair.reconcile(instruction: "No mutation was attempted. Read this ability and address the reported cause before changing it.", nextCall: readCall(named))
        }
        return (false, detail, fields)
    }

    /// A built-in skill's own version: switching it off, dropping it or
    /// changing its version is the owner's below Full Mac.
    static func overrideRefusal(_ row: [String: JSONValue], name: String, fullMac: Bool, ownerAuthorized: Bool) -> String? {
        guard row["overrides"] == .string("built_in"), !fullMac, !ownerAuthorized else { return nil }
        return "\(name) is your version of a built-in skill, so switching it off, dropping it or changing its version is the owner's. Ask them."
    }

    static func unknown(_ named: String) -> Outcome {
        (false, "No ability of yours is called \(named.isEmpty ? "(none passed)" : named). ability.list shows them.",
         ["reason": .string("unknown_part"), "effects": .string("none"),
          "remedy": Repair.remedy(owner: "abilities", nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("ability.list")])]), tap: nil,
                                  instruction: "Choose an exact id from ability.list, or save a new ability.")])
    }

    static func readCall(_ id: String) -> JSONValue {
        .object(["tool": .string("app"), "input": .object(["action": .string("ability.read"), "args": .object(["id": .string(id)])])])
    }

    static func missing(_ named: String) -> ToolFailureError {
        ToolFailureError(PartError.notFound(named).localizedDescription, effects: .none, owner: "abilities",
            nextCall: ToolFailureError.call("app", ["action": .string("ability.list")]), code: "unknown_part", status: .refused,
            instruction: "Choose an exact id from ability.list, or save a new ability.", recovery: .inspect)
    }

    static func revisionFailure(_ code: String, _ detail: String, id: String, version: String? = nil) -> SenseFailure {
        SenseFailure(code: code, message: detail, remedy: Repair.remedy(
            owner: "ability \(id)" + (version.map { " version \($0)" } ?? ""), nextCall: readCall(id), tap: nil,
            instruction: "Read \(id) and its retained versions; revise the rejected code or declaration with ability.save, then keep the reviewed version with ability.enable. Do not replay observed effects."))
    }

    package static func remedy(_ error: ToolFailureError) -> JSONValue {
        let call = error.nextCall.flatMap { try? JSONValue.parse(Data($0.utf8)) }
        if error.recovery == .terminal { return Repair.terminal(instruction: error.instruction ?? error.message) }
        if error.recovery == .reconcile, let call { return Repair.reconcile(instruction: error.instruction ?? error.message, nextCall: call) }
        if let owner = error.owner {
            if error.personDecides, let tap = error.tap { return Repair.why(owner: owner, tap: tap, instruction: error.instruction) }
            return Repair.remedy(owner: owner, nextCall: call, tap: error.tap, instruction: error.instruction)
        }
        if let recovery = error.recovery {
            return .object(["kind": .string(recovery.rawValue), "instruction": .string(error.instruction ?? error.message),
                            "next_call": call ?? .null])
        }
        if let call {
            return .object(["kind": .string(error.argumentPath == nil ? "inspect" : "correct_arguments"),
                            "instruction": .string(error.instruction ?? error.message), "next_call": call])
        }
        return .null
    }

    // MARK: - Rehearsal

    /// `ability.validate`: rehearses its waiting version on supplied or captured
    /// input. Intercepted replies are not behavioral proof.
    public func validate(_ named: String, input: JSONValue?, capture: Bool) async -> Outcome {
        var attempted = false
        do {
            guard let row = try row(named), let id = Self.string(row, "id") else { return Self.unknown(named) }
            let name = Self.string(row, "name") ?? id
            guard let candidate = try latest(row), row["candidateDigest"] != nil || row["status"] != .string("active") else {
                let failure = Self.revisionFailure("no_waiting_version", "\(id) has no waiting version to rehearse; save a revision with ability.save.", id: id)
                return (false, failure.message, ["id": .string(id), "reason": .string(failure.code), "effects": .string("none"), "remedy": failure.remedy ?? .null])
            }
            var fields: [String: JSONValue] = ["id": .string(id), "name": .string(name), "candidate_digest": .string(candidate.digest)]
            do {
                attempted = true
                let proof = try await rehearse(candidate, capture: capture, input: input)
                try mutate(id) { current in
                    guard var row = current, (row["candidateDigest"] ?? row["codeFingerprint"]) == .string(candidate.digest) else {
                        throw PartError.invalid("A newer version replaced this rehearsal; rehearse that one.")
                    }
                    row["candidateValidation"] = .string("rehearsed")
                    return row
                }
                fields["validation_evidence"] = AbilityStore.validationEvidence(proof, fixtures: candidate.fixtures)
                fields["capture"] = Self.fields(proof)["capture"] ?? .null
                fields["next_call"] = .object(["action": .string("ability.read"), "args": .object(["id": .string(id)])])
                return (true, "The supplied inputs passed rehearsal; intercepted replies are not behavioral proof. Read its exact version before keeping it.", fields)
            } catch let failure as SenseFailure where failure.code == "bad_input" {
                return (false, "Rehearsal needs input: \(failure.message) Pass input as an object matching \(name)'s params.",
                        fields.merging(["reason": .string("bad_input"), "effects": .string("none"), "input_schema": candidate.program.schema,
                                        "remedy": failure.remedy ?? .null]) { $1 })
            }
        } catch { return Self.mutationFailure(error, named: named, operation: "validate", attempted: attempted) }
    }

    // MARK: - One read

    /// `ability.read`: selected declarations/status plus the latest code
    /// (waiting before selected), labeled by source.version; guidance reads too.
    public func read(_ named: String, offset: Int = 0, step: Int? = nil) throws -> JSONValue {
        guard let row = try row(named, kind: nil), let id = Self.string(row, "id") else {
            guard let guidance = InstalledSkillInventory.match(named.trimmingCharacters(in: .whitespacesAndNewlines),
                in: try InstalledSkillInventory.entries(dataRoot: root)) else {
                return .object(["status": .string("not_found"), "reason": .string("unknown_part"), "effects": .string("none"),
                                "detail": .string(Self.unknown(named).text)])
            }
            return .object(["status": .string("ok"), "id": .string(guidance.id), "built_in": .bool(true),
                            "guidance": .string(guidance.readme),
                            "note": .string("Built-in guidance from the persona: read it; it is not an ability and does not run.")])
        }
        var read = row.filter { ["id", "kind", "version", "name", "description", "status", "triggers", "origin", "overrides", "disabledBy", "disabledReason",
                                 "validation_evidence", "candidate_validation_evidence", "learned"].contains($0.key) }
        read["status"] = .string("ok"); read["ability_status"] = row["status"] ?? .null
        var declares: [String: JSONValue] = [:]
        for (key, field) in [("params", "params"), ("input_schema", "inputSchema"), ("actions", "actions"), ("reach", "reach"),
                             ("wake", "wake"), ("face", "face"), ("resident", "resident")] { declares[key] = row[field] ?? .null }
        if row["kind"] == .string("sense") {
            declares.removeValue(forKey: "wake"); declares.removeValue(forKey: "resident"); declares["mode"] = row["mode"]
        }
        read["declares"] = .object(declares)
        var versions: [String: JSONValue] = [:]
        for (key, field) in [("current", "codeFingerprint"), ("waiting", "candidateDigest"), ("previous", "previousVersion"),
                             ("last_clean", "lastCleanVersion")] { versions[key] = row[field] ?? .null }
        if row["candidateDigest"] != nil { versions["waiting_validation"] = row["candidateValidation"] ?? .null }
        if row["kind"] != .string("ability") {
            versions = ["current": row["version"] ?? .null, "previous": row["previousVersion"] ?? .null]
        }
        read["versions"] = .object(versions)
        if Self.runs(row) { read["run"] = .object(["action": .string("authored." + id), "args": .object([:])]) }
        read["converted_versions"] = .array(try (row["kind"] == .string("ability") ? store.conversions(id: id) : []).map { candidate in
            .object(["version": .string(candidate.digest), "converts": Self.fields(candidate.manifest)["converts"] ?? .array([]),
                     "rollback_call": .object(["action": .string("ability.rollback"), "args": .object(["id": .string(id), "version": .string(candidate.digest)])])])
        })
        let latest = row["kind"] == .string("ability") ? try latest(row) : nil
        let file = latest == nil ? try abilities.files().first(where: { $0.id == id }) : nil
        if let source = latest?.program.source ?? file?.body {
            if latest != nil || file?.pathExtension == "js" {
                let version = try latest?.digest ?? (file?.record?["version"] ?? .null).serialize(pretty: false)
                read["source"] = AbilityStore.sourcePage(source, version: version, offset: offset) {
                    .object(["tool": .string("app"), "input": .object(["action": .string("ability.read"),
                        "args": .object(["id": .string(id), "offset": .int(Int64($0))])])])
                }
                if let step { read["step"] = Self.step(source, step) }
            } else { read["guidance"] = .string(source) }
        }
        return .object(read)
    }

    /// One `app.step` of its code: its label and guidance as written, and its
    /// lines when each step starts a line of its own.
    static func step(_ source: String, _ n: Int) -> JSONValue {
        let lines = source.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0].contains("app.step(") }
        guard n >= 1, n <= starts.count else {
            let instruction = starts.isEmpty ? "This code declares no app.step calls; omit step to read its source."
                : "Set step to an integer from 1 to \(starts.count), or omit it to read the source."
            return .object(["status": .string("refused"), "reason": .string("invalid_ability_step"), "effects": .string("none"),
                "argument_path": .string("step"), "accepted": .string(starts.isEmpty ? "omit step; no steps exist" : "an integer from 1 to \(starts.count)"),
                "detail": .string("The code declares \(starts.count) app.step calls; step \(n) does not select one."),
                "remedy": .object(["kind": .string("correct_arguments"), "instruction": .string(instruction), "next_call": .null])])
        }
        let at = n - 1
        var out: [String: JSONValue] = ["step": .string("\(n) of \(starts.count)")]
        let literal = #"app\.step\(\s*(["'`])((?:\\.|(?!\1).)*)\1(?:\s*,\s*(["'`])((?:\\.|(?!\3).)*)\3)?"#
        let line = lines[starts[at]]
        if let regex = try? NSRegularExpression(pattern: literal), let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            for (index, key) in [(2, "label"), (4, "guidance")] {
                if let range = Range(match.range(at: index), in: line), !line[range].isEmpty { out[key] = .string(String(line[range])) }
            }
        }
        let end = at + 1 < starts.count ? starts[at + 1] : lines.count
        out["lines"] = .string("\(starts[at] + 1)-\(end)")
        out["source"] = .string(lines[starts[at]..<end].joined(separator: "\n"))
        return .object(out)
    }

    /// `ability.list`: every part, one row each, and the built-in guidance to read.
    public func list() throws -> JSONValue {
        let rows = try rows(kind: nil)
        let parts = rows.map { row -> JSONValue in
            let id = Self.string(row, "id") ?? ""
            var item = row.filter { ["id", "kind", "version", "name", "description", "status", "versions", "candidateDigest", "reach", "wake", "resident", "mode"].contains($0.key) }
            item["next_call"] = .object(Self.runs(row)
                ? ["action": .string("authored." + id), "args": .object([:])]
                : ["action": .string("ability.read"), "args": .object(["id": .string(id)])])
            return .object(item)
        }
        let guidance = try InstalledSkillInventory.entries(dataRoot: root).map(\.id).sorted()
        return .object(["status": .string("ok"), "abilities": .array(parts), "built_in_guidance": .array(guidance.map(JSONValue.string))])
    }

    // MARK: - One run

    /// A native caller may narrow a part's admitted reach for this operation.
    /// This never grants an action or capability the selected part lacks.
    public struct CallReach: Sendable {
        public let actions: Set<String>
        public let capabilities: Set<String>
        public init(actions: Set<String>, capabilities: Set<String>) {
            self.actions = actions; self.capabilities = capabilities
        }
    }

    /// Bounded immutable JSON in; a version-pinned decision out. Native callers
    /// supply their originating gated host through OwnedProgramInvocation.
    /// The domain commits a successful value in its own transaction after this
    /// returns, never while holding that transaction's lock across JavaScript.
    public func call<Value: Codable & Sendable>(id: String, input: JSONValue, preview: Bool = false,
        within reach: CallReach? = nil, as type: Value.Type = Value.self) async -> PartCallResult<Value> {
        await callValue(id: id, input: input, projection: false, preview: preview, reach: reach, as: type)
    }

    /// Called by source owners, never by a view's render. Faces have no host
    /// effects or notebook access; all their sources arrive in frozen input.
    public func face(id: String, input: JSONValue, version: String) async -> PartCallResult<PartFace> {
        let result: PartCallResult<JSONValue> = await callValue(id: id, input: input, projection: true, pinned: version)
        switch result {
        case .failure(let error): return .failure(error)
        case .success(let value):
            do { return .success(try PartFace.decode(value)) }
            catch { return .failure(.init(code: "bad_face", message: error.localizedDescription)) }
        }
    }

    private func callValue<Value: Codable & Sendable>(id: String, input: JSONValue, projection: Bool,
        pinned: String? = nil, preview: Bool = false, reach: CallReach? = nil,
        as type: Value.Type = Value.self) async -> PartCallResult<Value> {
        do {
            try Task.checkCancellation()
            guard case .object = input, try input.serializedData(pretty: false).count <= 4 * 1024 * 1024 else {
                throw SenseFailure(code: "input_limit", message: "part.call input is a JSON object of at most 4 MiB.")
            }
            if let path = NativeAgentSecretRedactor.secretPath(input) {
                throw SenseFailure(code: "secret_in_input", message: "\(path) carries a credential; credentials never enter a part.")
            }
            // Selection precedes the first suspension; a replacement can stop
            // this call, but can never splice its own code into this invocation.
            let version = try AbilityStore.withLock {
                guard let row = try row(id), let version = Self.string(row, "codeFingerprint") else { throw Self.missing(id) }
                if let reach {
                    let selected = try store.load(id: id, digest: version).program
                    guard Set(selected.dependencies).isSubset(of: reach.actions),
                          Set(selected.permissions).isSubset(of: reach.capabilities) else {
                        throw SenseFailure(code: "caller_reach", message: "The selected part exceeds this caller's action or capability reach; the part did not run.")
                    }
                }
                return version
            }
            guard pinned == nil || pinned == version else {
                throw Self.revisionFailure("state_changed", "Ability \(id) selected \(version) before projection; the requested version was \(pinned ?? "none").", id: id, version: pinned)
            }
            let receipt = try await OwnedProgramRunner.$wake.withValue(nil) {
                if projection {
                    return try await runSelected(id: id, input: input, pinned: version,
                        preview: false, replay: nil, projection: true)
                }
                return try await run(id: id, input: input, requiredFingerprint: version, preview: preview)
            }
            try Task.checkCancellation()
            return Self.callResult(receipt, as: type)
        } catch {
            return .failure((error as? PartCallError) ?? .init(
                code: error is CancellationError ? "cancelled" : (error as? ToolFailureError)?.code ?? (error as? SenseFailure)?.code ?? "failed",
                message: error.localizedDescription))
        }
    }

    /// Value calls retain the runner envelope even when a face action normally
    /// presents its business payload directly. JS and Swift decode it here.
    static func callResult<Value: Codable & Sendable>(_ raw: JSONValue, as type: Value.Type) -> PartCallResult<Value> {
        let outer = Self.fields(raw)
        let receipt = outer["action"] != nil && outer["result"]?.objectValue != nil ? Self.fields(outer["result"]!) : outer
        do {
            guard receipt["status"] == .string("ok"), receipt["returned_note"] == nil,
                  receipt["accounting_error"] == nil else {
                let terminal = Self.fields(receipt["error"] ?? receipt["stopped"] ?? .null)
                throw PartCallError(code: Self.string(receipt, "reason") ?? Self.string(terminal, "reason") ?? "failed",
                    message: Self.string(receipt, "detail") ?? Self.string(receipt, "returned_note")
                        ?? Self.string(receipt, "accounting_error") ?? Self.string(terminal, "message") ?? "The part did not return a complete decision.")
            }
            let value = receipt["returned"] ?? .null
            return .success(try JSONDecoder().decode(type, from: value.serializedData(pretty: false)))
        } catch {
            return .failure((error as? PartCallError) ?? .init(
                code: error is CancellationError ? "cancelled" : (error as? ToolFailureError)?.code ?? (error as? SenseFailure)?.code ?? "failed",
                message: error.localizedDescription))
        }
    }

    /// Whether `authored.<id>` runs it: on, JavaScript, a version selected.
    /// Guidance (a Markdown ability) is read, never run.
    static func runs(_ row: [String: JSONValue]) -> Bool {
        row["status"] == .string("active") && row["language"] == .string("javascript") && string(row, "codeFingerprint") != nil
    }

    /// `authored.<id>`: its selected version under its signed admission,
    /// re-verified now, with its declared reach and nothing else. `preview`
    /// dispatches no write; `replay` resumes a run that stopped.
    public func run(id: String, input: JSONValue, requiredFingerprint: String? = nil, preview: Bool = false,
                    replay: OwnedProgramRunner.Replay? = nil) async throws -> JSONValue {
        do {
            return try await OwnedProgramInvocation.$valueCall.withValue(nil) {
                try await runSelected(id: id, input: input, pinned: requiredFingerprint, preview: preview, replay: replay)
            }
        }
        catch {
            if !preview, let version = try? requiredFingerprint ?? row(id).flatMap({ Self.string($0, "codeFingerprint") }) {
                let terminal = await abilities.settleRun(id: id, version: version,
                    receipt: ToolHost.failure(error, effects: "none", execution: "not_run"), input: nil)
                if let failed = terminal.objectValue?["accounting_error"]?.stringValue { throw PartError.invalid(failed) }
            }
            throw error
        }
    }

    private func runSelected(id: String, input: JSONValue, pinned: String?, preview: Bool, replay: OwnedProgramRunner.Replay?, projection: Bool = false) async throws -> JSONValue {
        guard let host = OwnedProgramInvocation.host else { throw PartError.invalid("An ability needs the gated app door of a conversation or wake run.") }
        let catalogRevision = try abilities.revision()
        guard let row = try row(id), Self.string(row, "id") == id else { throw Self.missing(id) }
        guard row["status"] == .string("active") else {
            throw Self.revisionFailure("not_active", "\(id) is \(Self.string(row, "status") ?? "off"); read it before requesting ability.enable for its exact version. An owner's off-switch remains the owner's decision.", id: id)
        }
        guard let digest = Self.string(row, "codeFingerprint"), pinned == nil || pinned == digest else {
            throw Self.revisionFailure("state_changed", "Ability \(id) no longer selects admitted version \(pinned ?? "(unavailable)").", id: id, version: pinned)
        }
        let candidate: OwnedProgramStore.Candidate
        do { candidate = try store.load(id: id, digest: digest) }
        catch { throw Self.revisionFailure("integrity", "Ability \(id) version \(digest) is unreadable: \(error.localizedDescription)", id: id, version: digest) }
        if let why = OwnedProgram.asyncRefusal(candidate.program.source) {
            throw SenseFailure(code: "async_code", message: why + " ability.save it so. Nothing ran.")
        }
        let revision = try catalogRevision + host.dependencyRevision(candidate.program.dependencies)
        try await checkAdmission(candidate, row: row)
        try checkDependencies(candidate)
        let binding = OwnedProgramRunner.Binding(revision: revision)
        // A wake's run is given none of its input, so its params never refuse it.
        if !projection, OwnedProgramRunner.wake == nil, let problem = input.schemaProblem(schema: candidate.program.schema) {
            throw SenseFailure(code: "bad_input", message: "Its input \(problem.path) must be \(problem.expected).", remedy: .object([
                "kind": .string("correct_arguments"), "instruction": .string("Correct input \(problem.path) to match \(problem.expected); ability.read shows \(id)'s params."),
                "next_call": Self.readCall(id)]))
        }
        if !projection, !preview, replay == nil, let refused = await host.admitTool(id, input: Self.fields(input)) {
            try abilities.recordRun(id: id, version: digest, receipt: refused)
            return refused
        }
        // A resident ability holds what it starts and opens across its runs, a
        // resumed one included (a resume never replays a primitive call).
        let program: OwnedProgram
        if projection {
            guard Self.fields(Self.fields(candidate.manifest)["face"] ?? .null)["projection"] == .bool(true) else {
                throw SenseFailure(code: "no_face", message: "This part does not declare face.projection.")
            }
            let owned = candidate.owned
            program = OwnedProgram(kind: owned.kind, id: id, version: owned.version, source: owned.source, entry: .face,
                dependencies: owned.dependencies, permissions: owned.permissions, seconds: owned.seconds)
        } else { program = candidate.owned }
        let dataRoot = root
        let broker = program.isResident && !preview
            ? try await OwnedProgramRunner.holding(program, dataRoot: dataRoot,
                make: { ToolPrimitiveBroker(permissions: Set(program.permissions), abilityID: id, held: AbilityStore(dataRoot: dataRoot)) },
                end: { _ = await $0.close() })
            : ToolPrimitiveBroker(permissions: Set(program.permissions), abilityID: id)
        let profile = ToolHost(base: host, candidate: candidate, broker: broker, dataRoot: root, projection: projection, preview: preview,
            admission: {
                try await binding.check(self.abilities.revision() + host.dependencyRevision(candidate.program.dependencies)) {
                    try await self.checkSelected(candidate, pinned: digest)
                }
            })
        await broker.begin()
        var result = Self.fields(await runner().run(program, input: input, preview: preview, replay: replay, host: profile))
        // A watch leaves one receipt for all its frames, however it ended.
        let watched = await settle { await broker.finish() }
        if !watched.isEmpty { result["watch"] = watched.count == 1 ? watched[0] : .array(watched) }
        result["ability"] = .string(id); result["version"] = .string(candidate.digest)
        if result["status"] == .string("stopped"), !candidate.program.isStrict {
            let stopped = Self.fields(result["stopped"] ?? .null)
            result["status"] = .string(stopped["not_run_status"] == .string("approval_filed") ? "waiting_approval"
                : stopped["reason"] == .string("cancelled") ? "cancelled" : "refused")
            result["reason"] = stopped["reason"]; result["detail"] = stopped["detail"]
            for key in ["approvalId", "not_run_status", "remedy"] { result[key] = stopped[key] }
        }
        // What ended the run reads the same at the top, however deep: the call its
        // terminal error names (a caught or expected failure before it never does),
        // else that error's own words.
        if result["status"] != .string("ok"), result["detail"] == nil {
            let terminal = Self.fields(result["stopped"] ?? result["error"] ?? .null)
            let rows: [JSONValue] = if case .array(let rows)? = result["calls"] { rows } else { [] }
            let named = terminal["n"].flatMap { n in rows.first { Self.fields($0)["n"] == n } }.flatMap { Self.string(Self.fields($0), "detail") }
            if let words = [named, Self.string(terminal, "message"), Self.string(terminal, "detail")].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                result["detail"] = .string(words)
            }
        }
        return .object(result)
    }

    func runner() -> OwnedProgramRunner {
        let helper = SenseHostLocator.helperURL, dataRoot = root
        return OwnedProgramRunner(helperURL: helper, dataRoot: dataRoot) { scratch in
            try SenseSandboxProfile.build(reach: SenseReach(), helperURL: helper, scratch: scratch,
                dataRoot: dataRoot, personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot))
        }
    }

    func checkSelected(_ candidate: OwnedProgramStore.Candidate, pinned: String) async throws {
        guard let row = try row(candidate.id), row["status"] == .string("active"), row["codeFingerprint"] == .string(pinned) else {
            throw Self.revisionFailure("state_changed", "Ability \(candidate.id) version \(pinned) was stopped or replaced; no further calls were admitted.", id: candidate.id, version: pinned)
        }
        try await checkAdmission(candidate, row: row)
        try checkDependencies(candidate)
    }

    /// The one admission, re-verified each run: signed for this exact version
    /// and its sealed proof, and the record still selecting it.
    public func checkAdmission(_ candidate: OwnedProgramStore.Candidate, row: [String: JSONValue]) async throws {
        guard row["codeFingerprint"] == .string(candidate.digest), row["inputSchema"] == candidate.program.schema,
              row["actions"] == .array(candidate.program.dependencies.map(JSONValue.string)),
              row["activePath"] == .string(try store.fileURL(id: candidate.id, digest: candidate.digest).path),
              case .object(let admission)? = row["admission"] else {
            throw Self.revisionFailure("integrity", "Ability \(candidate.id) version \(candidate.digest) no longer matches its admission or selected record.", id: candidate.id, version: candidate.digest)
        }
        let signer = SwiftNativeManifestSigner(dataRoot: root)
        let errors = try await signer.verify(admission)
        guard errors.isEmpty, admission["candidate"] == .string(candidate.digest) else {
            throw Self.revisionFailure("integrity", "Ability \(candidate.id) version \(candidate.digest): " + (errors.isEmpty ? "the admission names another version." : errors.joined(separator: "; ")), id: candidate.id, version: candidate.digest)
        }
        guard admission["proof"] == (try store.proof(candidate, key: try await signer.loadOrCreateSigningKey())) else {
            throw Self.revisionFailure("integrity", "Ability \(candidate.id) version \(candidate.digest) no longer matches its admitted proof.", id: candidate.id, version: candidate.digest)
        }
    }

    func dependencyShapes(_ actions: [String]) throws -> JSONValue {
        var shapes: [String: JSONValue] = [:]
        for action in actions {
            guard let shape = OwnedProgramInvocation.host?.dependencyShape(action) else {
                throw ToolFailureError("Dependency \(action) is unavailable in this app door.", argumentPath: "actions", accepted: "current app action ids", effects: .none,
                    nextCall: ToolFailureError.call("app", ["find": .string(action)]), code: "unknown_dependency", status: .refused,
                    instruction: "Find the current action, then correct this ability's call or actions declaration with ability.save.", recovery: .correctArguments)
            }
            shapes[action] = shape
        }
        return .object(shapes)
    }

    func checkDependencies(_ candidate: OwnedProgramStore.Candidate) throws {
        if let action = Self.string(Self.fields(Self.fields(candidate.manifest)["face"] ?? .null), "action"),
           let owner = OwnedProgramInvocation.host?.action(action), owner.partID != candidate.id {
            throw Self.revisionFailure("face_action_collision", "Ability \(candidate.id) cannot own face.action \(action); it belongs to \(owner.partID ?? "the app"). Remove it or choose an unused action id.", id: candidate.id, version: candidate.digest)
        }
        // No door in this turn is not a changed dependency: say which it is.
        guard let host = OwnedProgramInvocation.host else {
            throw SenseFailure(code: "door_unavailable", message: "This run has no gated app door, so its app-action dependencies could not be checked. Use the app door of a conversation or wake run.")
        }
        for action in candidate.program.dependencies where !host.dependencyMatches(action, Self.fields(candidate.dependencyShapes)[action]) {
            let before = Self.fields(candidate.dependencyShapes)[action] ?? .null
            let after = host.dependencyShape(action) ?? .null
            let fields = JSONValue.differences(before, after).map { $0.isEmpty ? "contract" : $0 }.joined(separator: ", ")
            let file = try AbilityStore.File(id: candidate.id, kind: .part, metadata: ["record": candidate.manifest],
                body: candidate.program.source, pathExtension: "js")
            throw ToolFailureError("Dependency \(action) changed at \(fields). Saved: \(try before.serialize(pretty: false)); current: \(try after.serialize(pretty: false)). Revise \(candidate.id) version \(candidate.digest) with ability.save against this contract, keep it, then repeat the failed operation.",
                effects: .none, owner: "ability \(candidate.id) version \(candidate.digest) > candidate.dependencyShapes.\(action) > \(fields)",
                nextCall: try abilities.repairCall(file), code: "stale_dependency", status: .refused,
                instruction: "Revise this ability against the reported current dependency contract, then keep the reviewed version. Do not replay observed effects.")
        }
    }

    /// The app actions a reach includes: its pages' doors, and file reads or writes.
    static func reachActions(_ permissions: [String]) -> [String] {
        let pages = Set(permissions).intersection(["calendar", "reminders", "contacts"])
        let fileReads = !Set(permissions).isDisjoint(with: ["app_data_read", "app_data_write", "computer_files", "arbitrary_file_write"])
        let fileWrites = !Set(permissions).isDisjoint(with: ["app_data_write", "arbitrary_file_write"])
        return OwnedProgramInvocation.host.map { host in
            host.actionIDs.filter { host.action($0).map {
                pages.contains($0.page) || $0.page == "files" && (fileWrites || fileReads && $0.read)
            } == true }
        } ?? []
    }

    // MARK: - Seeds

    /// A bundled seed lands kept and on: its bytes are the app's own.
    package func bundledSeed(_ seed: AbilityStore.File) async throws -> AbilityStore.File {
        guard let record = seed.record?.filter({ !["kind", "version"].contains($0.key) }),
              case .string(let description)? = record["description"], !description.isEmpty else {
            throw PartError.invalid("Seed \(seed.id) needs a description in its record. Fix the bundled seed and relaunch.")
        }
        let actions = try Self.declaredStrings(record["actions"], name: "actions")
        let permissions = try Self.declaredStrings(Self.fields(seed.part["reach"] ?? .null)["capabilities"], name: "reach.capabilities")
        let schema = record["inputSchema"] ?? .object(["type": .string("object")])
        let manifest = record.merging([
            "id": .string(seed.id), "name": record["name"] ?? .string(seed.id), "origin": .object(["by": .string("hers")]),
            "language": .string("javascript"), "inputSchema": schema, "actions": .array(actions.map(JSONValue.string)),
        ]) { _, value in value }.merging(seed.part) { _, value in value }
        let candidate = try OwnedProgramStore.Candidate(
            program: OwnedProgram(kind: .part, id: seed.id, version: "seed", source: seed.body, entry: .run,
                schema: schema, dependencies: actions, permissions: permissions, resident: seed.part["resident"] == .bool(true)),
            manifest: .object(manifest), fixtures: .array([]), dependencyShapes: try dependencyShapes(actions), prior: .null)
        try checkDependencies(candidate)
        let signer = SwiftNativeManifestSigner(dataRoot: root)
        let key = try await signer.loadOrCreateSigningKey()
        let version: Int64 = if case .int(let value)? = seed.metadata["version"] { value } else { 1 }
        var file = try store.bundledSeed(candidate, version: version, key: key)
        let admission = try await signer.sign(["id": .string(seed.id), "candidate": .string(candidate.digest), "proof": file.metadata["proof"]!, "by": .string("user")])
        let stamp = Self.now()
        file.metadata["record"] = .object(manifest.merging([
            "status": .string("active"), "createdAt": .string(stamp), "updatedAt": .string(stamp),
            "codeFingerprint": .string(candidate.digest), "activePath": .string(try abilities.path(id: seed.id).path),
            "admission": .object(admission),
        ]) { _, value in value })
        return file
    }

    // MARK: - Migration

    /// At launch every tool and skill file takes the one form, each slot,
    /// with no change in what runs: the same ids, code, versions and digests;
    /// a skill's admission is re-signed as the one admission when it was
    /// runnable, and anything that was not runnable waits as a draft.
    /// Idempotent: a record already in the one form is left as it is.
    public func migrate() async throws {
        var pending: [(AbilityStore.File, AbilityStore.Slot)] = []
        for identity in try abilities.files(kind: .part) {
            for slot in AbilityStore.Slot.allCases {
                if let file = try abilities.read(id: identity.id, slot: slot), let row = file.metadata["record"].map(Self.fields), Self.legacy(row) {
                    pending.append((file, slot))
                }
            }
        }
        guard !pending.isEmpty else { return }
        let signer = SwiftNativeManifestSigner(dataRoot: root)
        let key = try await signer.loadOrCreateSigningKey()
        for (file, slot) in pending {
            var row = Self.fields(file.metadata["record"] ?? .null)
            let descriptor = Self.fields(file.metadata["candidate"] ?? .null)
            let digest = Self.string(Self.fields(descriptor["program"] ?? .null), "version")
            let candidate = try digest.map { try store.load(id: file.id, digest: $0) }
            if row["status"] == .string("proposed") { row["status"] = .string("draft") }
            let recordedOrigin = row["origin"]
            if row["origin"] != nil { row["origin"] = Self.merged([row["origin"]]) }
            if row["status"] == .string("installed") { row["status"] = .string("active") }
            row.removeValue(forKey: "phase")
            if row["script"] != nil || row["actionPin"] != nil || row["scriptDigest"] != nil {
                // A skill: what ran, now declared as a part's record.
                let script = Self.fields(row.removeValue(forKey: "script") ?? .null)
                let pin = Self.fields(row["actionPin"] ?? .null)
                let admission = Self.fields(row["admission"] ?? .null)
                let selected = slot != .next ? Self.string(row, "codeFingerprint") : nil
                // The checks that made it runnable before stay what admits it now.
                var whole = script; whole["source"] = .string(file.body)
                let checksum = (try? JSONValue.object(whole).serializedData(pretty: false))
                    .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
                let proof = candidate.flatMap { try? store.proof($0, key: key) }
                let notRunnable: String? = if selected == nil || selected != digest { "no selected version is this file's code" }
                    else if admission["candidate"] != .string(selected ?? "") { "no admission binds its exact version" }
                    else if Self.originKind(recordedOrigin) == nil { "its origin is missing or malformed" }
                    else if !(admission["by"] == .string("user") || admission["by"] == .string("agent") && Self.agentMayAdmit(recordedOrigin)) {
                        "its admission is not one its origin allows" }
                    else if script["entry"] != .string("run") { "its script has no run(input) entry" }
                    else if !Self.canonical(script, source: file.body) { "its script is not in its normal form" }
                    else if pin["interpreter"] != .int(2) { "its action pin is from another interpreter revision" }
                    else if checksum == nil || pin["digest"] != checksum.map(JSONValue.string) { "its script changed since its action pin" }
                    else if proof == nil { "its sealed proof is missing or stale" }
                    else { nil }
                let evidence = row.filter { ["admission", "actionPin", "scriptDigest", "suspended"].contains($0.key) }
                for key in ["scriptDigest", "signature", "actionPin", "suspended", "candidateOrigin", "admission", "kind"] { row.removeValue(forKey: key) }
                row["language"] = .string("javascript")
                if let params = script["params"], params != .object([:]) { row["params"] = params }
                if let candidate {
                    row["inputSchema"] = candidate.program.schema
                    row["actions"] = .array(candidate.program.dependencies.map(JSONValue.string))
                }
                if notRunnable == nil, let digest, let proof {
                    row["admission"] = .object(try await signer.sign(["id": .string(file.id), "candidate": .string(digest),
                        "proof": proof, "by": admission["by"] ?? .string("agent")]))
                    row["activePath"] = .string(try store.fileURL(id: file.id, digest: digest).path)
                } else if slot != .next {
                    // Not runnable before, so a draft now, with why and what it carried.
                    if row["status"] == .string("active") { row["status"] = .string("draft") }
                    row["migrationEvidence"] = .object(evidence.merging(["not_runnable": .string(notRunnable ?? "")]) { $1 })
                }
            }
            try AbilityStore.withLock {
                guard var current = try abilities.read(id: file.id, slot: slot), current == file else { return }
                current.metadata["record"] = .object(row)
                try abilities.write(current, slot: slot)
            }
        }
    }

    /// A skill's script as its save stored it, in its normal form: the old
    /// admission's own test, which migration keeps.
    static func canonical(_ script: [String: JSONValue], source: String) -> Bool {
        // The old normal form always carried params and actions, possibly empty.
        guard Set(script.keys).isSubset(of: ["params", "actions", "steps", "of", "entry"]),
              case .object(let params)? = script["params"], case .array? = script["actions"],
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.utf8.count <= AbilityStore.sourceLimit,
              case .int(let of)? = script["of"], (1...50).contains(of) else { return false }
        guard params.isEmpty || (try? Self.params(.object(params)))?.params == params else { return false }
        let actions = strings(script["actions"])
        guard script["actions"] == .array(actions.map(JSONValue.string)), actions.count <= 50,
              Set(actions).count == actions.count, actions.allSatisfy({ dependencyID($0) == $0 }) else { return false }
        guard let steps = script["steps"] else { return true }
        let labels = strings(steps)
        return steps == .array(labels.map(JSONValue.string)) && labels.count == Int(of) && labels.allSatisfy { !$0.isEmpty && $0.count <= 160 }
    }

    /// A record from before the one form: a skill's, or a tool's proposal.
    static func legacy(_ row: [String: JSONValue]) -> Bool {
        ["script", "actionPin", "scriptDigest", "phase"].contains { row[$0] != nil }
            || [.string("proposed"), .string("installed")].contains(row["status"] ?? .null)
    }

    // MARK: - Origin

    /// Whose work a version is: hers, or the untrusted agents that steered
    /// the turn that wrote it. A trusted agent that started the turn is its
    /// provenance, never its author.
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

    /// Origins only ratchet toward the owner: no later save of hers launders
    /// an untrusted agent's or a pack's mark. A nil entry is an origin that
    /// should exist and doesn't, an unrecorded peer.
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

    /// A part's params: each input name to its type (string, int, number,
    /// bool, list or object; a trailing ? marks it optional) or {type,
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
        // The flat map reads first; only a map that does not read flat and is
        // a JSON Schema object reads as one, an unrequired property optional.
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
    /// Delete with the aliases, in the release after the one that ships one-part.
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

    // MARK: - JSON

    public static func fields(_ value: JSONValue) -> [String: JSONValue] { if case .object(let fields) = value { fields } else { [:] } }
    static func strings(_ value: JSONValue?) -> [String] {
        if case .array(let values)? = value { values.compactMap { if case .string(let text) = $0 { text } else { nil } } } else { [] }
    }
    public static func string(_ fields: [String: JSONValue], _ key: String) -> String? { if case .string(let text)? = fields[key] { text } else { nil } }
    public static func declaredStrings(_ value: JSONValue?, name: String) throws -> [String] {
        guard let value else { return [] }
        guard case .array(let values) = value, values.allSatisfy({ if case .string = $0 { true } else { false } }) else {
            throw PartError.invalid("\(name) must be an array of strings.")
        }
        return strings(value)
    }
    static func now() -> String { SwiftNativeToolRegistry.isoTimestamp(Date()) }
}
