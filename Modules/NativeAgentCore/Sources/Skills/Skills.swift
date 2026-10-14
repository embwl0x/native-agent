import Privacy
import Foundation
import NativeAgentCore
import PersistenceCore
import Senses

// Skills project the shared ability files; transport callers own authorization.

/// A quiet MY QUEUE line about a skill, and whose words its name is
/// (`SkillScript.voices`): none for her own.
public typealias SkillLine = (words: String, peers: [String])

/// One learned-skills registry row, as the Capabilities page and the phone
/// snapshot carry it.
public struct SkillRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var triggers: [String]
    public var kind: String?
    public var status: String?
    public var autoCreated: Bool?
    public var sourceRunId: String?
    public var bodyPath: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var useCount: Int?
    public var lastUsedAt: String?
    /// Ordinary discovery projects canonical registry rows only.
    public var source: String?
    /// A repeatable skill's script and the line generated from its header.
    public var script: Script?
    public var signature: String?
    public var scriptDigest: String?

    public struct Script: Codable, Hashable, Sendable { public var source: String }
}

extension SkillRecord {
    /// One registry row; a present field of the wrong type makes it malformed.
    public init(row: JSONValue) throws {
        let row = try JSONRow(row)
        self.init(
            id: try row.string("id"), name: try row.string("name"), description: try row.string("description"),
            triggers: try row.strings("triggers"), kind: try row.optionalString("kind"),
            status: try row.optionalString("status"), autoCreated: try row.optionalBool("autoCreated"),
            sourceRunId: try row.optionalString("sourceRunId"), bodyPath: try row.optionalString("bodyPath"),
            createdAt: try row.optionalString("createdAt"), updatedAt: try row.optionalString("updatedAt"),
            useCount: try row.optionalInt("useCount"), lastUsedAt: try row.optionalString("lastUsedAt"),
            source: try row.optionalString("source"),
            script: try row.optional("script") { value in
                guard case .object(let script) = value, case .string(let source)? = script["source"] else { return nil }
                return Script(source: source)
            },
            signature: try row.optionalString("signature"), scriptDigest: try row.optionalString("scriptDigest"))
    }
}

/// One merged CLI manifest-registry row, as the Skills page lists it.
public struct SkillRegistryEntry: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let state: String     // "drafted" | "installed" | "active" | "dormant" | "quarantined"
    public let version: String
    public let type: String
    public let installedAt: String?
    public let path: String

    public init(name: String, state: String, version: String, type: String, installedAt: String?, path: String) {
        self.name = name; self.state = state; self.version = version
        self.type = type; self.installedAt = installedAt; self.path = path
    }

    init(row: JSONValue) throws {
        let row = try JSONRow(row)
        self.init(name: try row.string("name"), state: try row.string("state"), version: try row.string("version"),
                  type: try row.string("type"), installedAt: try row.optionalString("installedAt"),
                  path: try row.string("path"))
    }
}

// MARK: - Client protocol

public protocol SkillsClient: Sendable {
    /// GET /v1/skills — the learned-skills registry, sorted by
    /// (updatedAt | createdAt | "") DESC. Pure read (no write-back).
    func listSkills() async throws -> [JSONValue]
    // MARK: - Mutations (wave 32 W15) — see SkillsError for the failure modes

    /// POST /v1/skills/update — patch name/description/triggers/kind/status on
    /// the skill matched by id-or-name, restamp updatedAt, save, fire
    /// record_activity. Returns the mutated skill object.
    /// Throws `SkillsError.unknownSkill` if no skill matches (Python ValueError).
    func updateSkill(body: JSONValue) async throws -> JSONValue

    /// Permanently remove the selected ability and its run state.
    func deleteSkill(id: String, ownerAuthorized: Bool) async throws -> JSONValue

    /// Enable the selected runtime row or install the selected manifest entry.
    func enableSkill(name: String) async throws -> JSONValue

    /// Disable the selected runtime row or make the selected manifest dormant.
    func disableSkill(name: String) async throws -> JSONValue

    /// POST /v1/skills — create_skill: name-dedup (case-insensitive on name),
    /// slugify id, write the body .md, append the record. Does NOT fire
    /// record_activity (matching the retired daemon create_skill). Returns the
    /// created or updated record. No Mac-UI caller today; included for surface
    /// completeness + smoke parity.
    func createSkill(body: JSONValue) async throws -> JSONValue

    /// Permanently remove the selected ability.
    func archiveSkill(id: String) async throws -> JSONValue

    /// The common ability store preserves the owner's off state.
    func markSkill(name: String, legacyStatus: String, manifestState: String, marks: [String: JSONValue], restoring: Bool) async throws -> JSONValue
}

/// Mutation failure modes. `unknownSkill` mirrors the daemon's
/// `raise ValueError(f"Unknown skill: {id}")` (the route maps it to a 404 on
/// the manifest-fallback miss). `invalidRegistry` covers a registry file whose
/// root JSON is not the expected array/object (the daemon's read_json default
/// would coerce these, so we coerce too — this is only thrown for genuinely
/// unparseable state).
public enum SkillsError: Error, Equatable, Sendable {
    case unknownSkill(String)
    case stateNotAllowed(name: String, state: String, requirement: String)
    case invalidSkillBody(String)
    case invalidRegistry(String)
    case unknownVersion(String)
    /// A save's `script` that is malformed or has no attested origin (`SkillScript`).
    case invalidScript(String)
}

extension SkillsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownSkill(let name):
            return "No skill matches \(name). Use app {action:\"skill.list\"} to see the available skills."
        case .stateNotAllowed(let name, let state, let requirement):
            return "\(name) is \(state); this change requires \(requirement)."
        case .invalidSkillBody(let why), .invalidRegistry(let why), .invalidScript(let why):
            return why
        case .unknownVersion(let version):
            return "No saved skill version matches \(version). Only the previous version is retained."
        }
    }
}

// MARK: - SwiftNative impl

public final class SwiftNativeSkillsClient: SkillsClient {
    private let root: URL
    private let persistence: SwiftNativePersistenceCore
    /// Injectable clock for deterministic updatedAt/createdAt stamps in tests.
    private let now: @Sendable () -> Date

    public init(
        root: URL,
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root
        self.persistence = persistence
        self.now = now
    }

    private var abilities: AbilityStore { AbilityStore(dataRoot: root) }


    public func listSkills() async throws -> [JSONValue] {
        SkillsRegistry.sortedDescending(try InstalledSkillInventory.entries(dataRoot: root).map { .object($0.row) })
    }

    private func lifecycleRecords() async throws -> [JSONValue] {
        try InstalledSkillInventory.entries(dataRoot: root).map { .object($0.row) }
    }

    private func lifecycleEntry(_ name: String) async throws -> InstalledSkillInventory.Entry {
        let name = SkillMutation.unquote(name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entry = InstalledSkillInventory.match(name, in: try await lifecycleRecords()) else {
            throw SkillsError.unknownSkill(name)
        }
        return entry
    }

    // MARK: - Mutations

    public func updateSkill(body: JSONValue) async throws -> JSONValue {
        let name = SkillMutation.unquote(SkillMutation.string(body, "id")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entry = InstalledSkillInventory.match(name, in: try InstalledSkillInventory.entries(dataRoot: root)
            .filter { $0.row["source"] == .string("runtime_registry") }) else { throw SkillsError.unknownSkill(name) }
        return try await updateSkill(entry, body: body, admittedBy: nil, reviewedDigest: nil)
    }

    /// `admittedBy` (user or agent) admits a script skill it turns on, bound
    /// to `reviewedDigest`, the digest of the script the admitter read; one
    /// that changed since is refused here, inside the lock. Turning one on
    /// without a standing admission for its exact digest is refused.
    private func updateSkill(_ entry: InstalledSkillInventory.Entry, body: JSONValue, admittedBy: String?, reviewedDigest: String?, ownerAuthorized: Bool = false, restoring: Bool = false) async throws -> JSONValue {
        let skillId = entry.id
        if ["active", "installed"].contains(SkillMutation.string(body, "status")), entry.row["script"] != nil || entry.row["candidateDigest"] != nil {
            let row = entry.row
            guard row["candidateDigest"] != nil || row["script"]?.objectValue?["entry"] == .string("run") else {
                throw SkillsError.invalidScript("The original is historical. Save, validate and enable its JS counterpart; Tools census lists conversion blockers.")
            }
            return try await keepRoutine(row, admittedBy: admittedBy, reviewedDigest: reviewedDigest, ownerAuthorized: ownerAuthorized)
        }
        let result = try await mutateRoutine(entry, ownerAuthorized: ownerAuthorized) { skill -> JSONValue in
            let before = skill
            let sname = SkillMutation.pyStr(skill["name"] ?? .null)
            // Patch only the allowed keys present in the body.
            if case .object(let bodyObj) = body {
                if bodyObj["status"] != nil {
                    for mark in SkillMutation.agentMarks { skill.removeValue(forKey: mark) }
                }
                for key in ["name", "description", "triggers", "kind", "status"] + SkillMutation.agentMarks
                where bodyObj[key] != nil {
                    skill[key] = bodyObj[key]
                }
            }
            skill["updatedAt"] = .string(SkillMutation.nowISO(self.now))
            if skill["script"] != nil, InstalledSkillInventory.isAvailable(skill) {
                guard SkillScript.isRunnable(skill) else {
                    throw SkillsError.stateNotAllowed(name: sname, state: "drafted",
                                                      requirement: "an admission for its script's exact digest")
                }
            }
            skill = try CapabilityLifecycle.preservingOwnerOff(skill, before: before,
                ownerAuthorized: ownerAuthorized, enabling: restoring || ["active", "installed"].contains(SkillMutation.pyStrOptional(skill["status"]) ?? ""))
            return .object(skill)
        }
        // record_activity("skill", "Skill updated", name|id, "ok",
        //   payload={"skillId": skillId}) — fired OUTSIDE the registry lock,
        // matching the daemon (record_activity is a separate file + its own
        // flock); inside-the-lock would needlessly serialize the activity write.
        if case .object(let obj) = result {
            let displayName = SkillMutation.pyStrTruthyOr(obj["name"], skillId)
            try await activity.record(kind: "skill", title: "Skill updated", detail: displayName,
                                      status: "ok", payload: .object(["skillId": .string(skillId)]))
        }
        return result
    }

    public func deleteSkill(id rawId: String, ownerAuthorized: Bool = false) async throws -> JSONValue {
        let entry = try await lifecycleEntry(rawId)
        guard entry.row["source"] == .string("runtime_registry") else {
            throw SkillsError.stateNotAllowed(name: entry.name, state: "built in", requirement: "an owner override")
        }
        try CapabilityLifecycle.requireWrite()
        try abilities.remove(id: entry.id, ownerAuthorized: ownerAuthorized)
        return .object(["id": .string(entry.id), "dropped": .bool(true)])
    }

    /// Turns on what needs no new admission: a script skill is admitted only
    /// with the digest its admitter reviewed (`enableSkill(name:admittedBy:reviewedDigest:)`).
    public func enableSkill(name rawName: String) async throws -> JSONValue {
        try await enableSkill(name: rawName, admittedBy: nil, reviewedDigest: nil)
    }

    /// `admittedBy` nil turns on only what needs no new admission.
    public func enableSkill(name rawName: String, admittedBy: String?, reviewedDigest: String?, ownerAuthorized: Bool = false) async throws -> JSONValue {
        try await flipStatus(lifecycleEntry(rawName), legacyStatus: "active", admittedBy: admittedBy, reviewedDigest: reviewedDigest,
                             ownerAuthorized: ownerAuthorized)
    }

    public func disableSkill(name rawName: String) async throws -> JSONValue {
        try await flipStatus(lifecycleEntry(rawName), legacyStatus: "disabled", admittedBy: nil, reviewedDigest: nil,
                             ownerAuthorized: true)
    }

    /// Mutate the selected registry, without resolving its name again.
    private func flipStatus(
        _ entry: InstalledSkillInventory.Entry,
        legacyStatus: String,
        admittedBy: String?,
        reviewedDigest: String?,
        ownerAuthorized: Bool
    ) async throws -> JSONValue {
        try await updateSkill(entry, body: .object(["status": .string(legacyStatus)]),
                              admittedBy: admittedBy, reviewedDigest: reviewedDigest, ownerAuthorized: ownerAuthorized)
    }

    public func markSkill(
        name rawName: String, legacyStatus: String, manifestState: String, marks: [String: JSONValue], restoring: Bool = false
    ) async throws -> JSONValue {
        try await markSkill(lifecycleEntry(rawName), legacyStatus: legacyStatus, manifestState: manifestState, marks: marks, restoring: restoring)
    }

    private func markSkill(
        _ entry: InstalledSkillInventory.Entry, legacyStatus: String, manifestState: String, marks: [String: JSONValue], restoring: Bool = false
    ) async throws -> JSONValue {
        if ["archived", "trashed", "retired"].contains(legacyStatus) { return try await deleteSkill(id: entry.id) }
        var body: [String: JSONValue] = ["status": .string(legacyStatus)]
        body.merge(marks.filter { SkillMutation.agentMarks.contains($0.key) }) { $1 }
        return try await updateSkill(entry, body: .object(body), admittedBy: nil, reviewedDigest: nil, restoring: restoring)
    }

    public func createSkill(body: JSONValue) async throws -> JSONValue {
        try await createSkill(body: body, steer: nil)
    }

    public func createSkill(body: JSONValue, steer: JSONValue?) async throws -> JSONValue {
        let fields = body.objectValue ?? [:]
        let script = try SkillScript.normalized(fields["script"])
        return try await saveRoutine(fields, script: script, steer: steer)
    }

    private var routineStore: OwnedProgramStore { OwnedProgramStore(root: CapabilityLifecycle.Store.skills.directory(in: root)) }

    private static func routineSelection(_ row: [String: JSONValue]) -> JSONValue {
        .object(row.filter { ["status", "codeFingerprint", "scriptDigest", "origin", "candidateOrigin", "admission", "disabledBy", "candidateDigest"].contains($0.key) })
    }

    private func routineKey() throws -> Data {
        guard let key = try CheckedFixedSizeSecretFile.peekExisting(
            at: root.appendingPathComponent("tools/.manifest_signing_key"), byteCount: 32) else {
            throw SkillsError.invalidScript("Validation authority is missing. Validate the routine in the installed app.")
        }
        return key
    }

    private func saveRoutine(_ fields: [String: JSONValue], script: JSONValue, steer: JSONValue?) async throws -> JSONValue {
        guard let steer, SkillScript.originKind(steer) != nil,
              case .string(let name)? = fields["name"], !name.isEmpty, name.count <= 120,
              case .string(let description)? = fields["description"], !description.isEmpty,
              description.count <= 500, description.rangeOfCharacter(from: .newlines) == nil,
              case .array(let fixtures) = fields["fixtures"] ?? .array([]), fixtures.count <= 16,
              try JSONValue.array(fixtures).serializedData(pretty: false).count <= 256 * 1024,
              fields["overrides"] == nil || fields["overrides"] == .null || fields["overrides"] == .string("built_in"),
              case .object(let pins)? = fields["dependencyShapes"] else {
            throw SkillsError.invalidScript("Save requires a name, one-line description, run(input) and checked dependencies with an attested origin; omit fixtures to capture during validation.")
        }
        let missing = SkillScript.undeclared(script)
        guard missing.isEmpty else { throw SkillsError.invalidScript("Declare the calls in actions: \(missing.joined(separator: ", ")).") }
        return try await mutateRegistry { rows in
            let inventory = try InstalledSkillInventory.entries(dataRoot: self.root)
            // Filenames preserve persona identity without exposing legacy guidance.
            let bodies = defaultPersonaRoot(dataRoot: self.root).appendingPathComponent("skills/bodies")
            let builtIn = FileManager.default.fileExists(atPath: bodies.path)
                ? try FileManager.default.contentsOfDirectory(at: bodies, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    .first { $0.pathExtension.lowercased() == "md" && $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame } : nil
            if let builtIn { try VerifiedPath.confirmNoSymlink(builtIn) }
            let builtInID = builtIn?.deletingPathExtension().lastPathComponent
            let index = if let id = SkillMutation.pyStrOptional(fields["id"]) {
                rows.firstIndex { $0.objectValue?["id"] == .string(id) }
            } else {
                InstalledSkillInventory.match(builtInID ?? name, in: rows).flatMap { rows.firstIndex(of: .object($0.row)) }
            }
            var before = index.flatMap { rows[$0].objectValue }
            // Persist persona protection before its name moves to the canonical row.
            if builtIn != nil { before?["overrides"] = .string("built_in") }
            let id = builtInID ?? before.flatMap { SkillMutation.pyStrOptional($0["id"]) }
                ?? SkillMutation.pyStrOptional(fields["id"])
                ?? SkillMutation.availableID(for: name, existingIDs: Set(inventory.map(\.id)))
            guard SkillMutation.isSafeSkillID(id) else { throw SkillsError.invalidScript("The skill identity is not a safe path component.") }
            guard before == nil || before?["id"] == .string(id) else {
                throw SkillsError.invalidScript("A built-in override must use the built-in skill's identity.")
            }
            let origin = SkillScript.merged([steer] + SkillScript.recorded(before))
            let manifest: JSONValue = .object(["id": .string(id), "name": .string(name), "description": .string(description),
                "triggers": fields["triggers"] ?? .array([]), "script": script, "origin": origin,
                "overrides": builtIn != nil || before?["overrides"] == .string("built_in") || fields["overrides"] == .string("built_in") ? .string("built_in") : .null,
                "converts": try OwnedProgramStore.conversionSources(fields["converts"])])
            let candidate = try OwnedProgramStore.Candidate(program: OwnedProgram(kind: .skill, id: id, version: "candidate",
                source: SkillMutation.string(script, "source"), entry: .run, schema: SkillScript.inputSchema(script),
                dependencies: (script.objectValue?["actions"]?.arrayValue ?? []).compactMap(SkillMutation.pyStrOptional)),
                manifest: manifest, fixtures: .array(fixtures), dependencyShapes: .object(pins),
                prior: before.map(Self.routineSelection) ?? .null)
            try self.routineStore.stage(candidate)
            let at = SkillMutation.nowISO(self.now)
            var row = before ?? ["id": .string(id), "name": .string(name), "description": .string(description),
                "triggers": fields["triggers"] ?? .array([]), "status": fields["status"] == .string("disabled") ? .string("disabled") : .string("draft"), "kind": .string("skill"),
                "createdAt": .string(at), "useCount": .int(0)]
            if row["script"] == nil, !InstalledSkillInventory.isAvailable(row) || before == nil {
                row["script"] = script; row["signature"] = .string(SkillScript.signature(script))
                row["scriptDigest"] = SkillScript.sourceChecksum(script).map(JSONValue.string)
            }
            for key in ["installedByPack", "capabilityPackInstallId"] where fields[key] != nil { row[key] = fields[key] }
            if builtIn != nil || fields["overrides"] == .string("built_in") { row["overrides"] = .string("built_in") }
            if row["origin"] == nil { row["origin"] = origin }
            row["candidateOrigin"] = origin
            row["candidateDigest"] = .string(candidate.digest)
            row["candidateValidation"] = .string("invalid")
            row["updatedAt"] = .string(at)
            row = try CapabilityLifecycle.preservingOwnerOff(row, before: before)
            row["candidateSelection"] = Self.routineSelection(row)
            let saved = JSONValue.object(row)
            if let index { rows[index] = saved } else { rows.append(saved) }
            return saved
        }
    }

    public func routineCandidate(name: String) async throws -> OwnedProgramStore.Candidate {
        guard let row = try InstalledSkillInventory.match(name, in: InstalledSkillInventory.entries(dataRoot: root)
                .filter { $0.row["source"] == .string("runtime_registry") })?.row else {
            throw SkillsError.unknownSkill(name)
        }
        return try routineCandidate(row)
    }

    public func routineCandidate(_ row: [String: JSONValue]) throws -> OwnedProgramStore.Candidate {
        guard let id = SkillMutation.pyStrOptional(row["id"]),
              let digest = SkillMutation.pyStrOptional(row["candidateDigest"] ?? row["codeFingerprint"]) else {
            throw SkillsError.unknownSkill(SkillMutation.pyStr(row["id"] ?? .null))
        }
        return try routineStore.load(id: id, digest: digest)
    }

    /// The app adapter executes with intercepted calls; no model-supplied receipt can bind a proof.
    public func validateRoutine(name: String, key: Data,
        execute: @Sendable (OwnedProgramStore.Candidate) async throws -> JSONValue) async throws -> JSONValue {
        let candidate = try await routineCandidate(name: name)
        let proof: JSONValue
        do {
            proof = try await execute(candidate)
            guard try routineStore.proof(candidate, key: key) == proof else { throw SkillsError.invalidScript("Validation proof changed.") }
            guard !(proof.objectValue?["receipts"]?.arrayValue ?? []).isEmpty else { throw SkillsError.invalidScript("Validation returned no runtime receipts.") }
        }
        catch {
            try AbilityStore.withLock {
                if let next = try abilities.read(id: candidate.id, slot: .next),
                   next.metadata["candidate"]?.objectValue?["program"]?.objectValue?["version"] == .string(candidate.digest) {
                    try abilities.remove(id: candidate.id, slot: .next)
                }
            }
            throw error
        }
        let receipts = proof.objectValue?["receipts"]?.arrayValue ?? []
        return try await mutateRegistry { rows in
            guard let index = rows.firstIndex(where: { $0.objectValue?["id"] == .string(candidate.id) }),
                  case .object(var row) = rows[index],
                  (row["candidateDigest"] ?? row["codeFingerprint"]) == .string(candidate.digest) else {
                throw SkillsError.invalidScript("A newer revision replaced this validation. Validate that candidate.")
            }
            row["candidateValidation"] = .string("valid")
            rows[index] = .object(row)
            return .object(["status": .string("ok"), "digest": .string(candidate.digest), "validation": .string("valid"),
                            "capture": proof.objectValue?["capture"] ?? .null,
                            "effects": .string("none"), "receipts": .array(receipts.map { .object(($0.objectValue ?? [:]).filter { $0.key != "journal" }) })])
        }
    }

    public func routineProgram(_ row: [String: JSONValue]) throws -> OwnedProgram {
        guard SkillMutation.pyStrOptional(row["id"]) != nil, let digest = SkillMutation.pyStrOptional(row["codeFingerprint"]) else {
            throw SkillsError.invalidScript("No executable version is selected. Validate and enable this routine.")
        }
        let candidate = try routineStore.load(id: SkillMutation.pyStr(row["id"] ?? .null), digest: digest)
        guard candidate.manifest.objectValue?["script"] == row["script"] else {
            throw SkillsError.invalidScript("Selected code changed. Save, validate and enable it again.")
        }
        if let admitted = row["admission"]?.objectValue?["candidate"], admitted != .string(digest) {
            throw SkillsError.invalidScript("Admission binds another candidate. Review and enable this exact version.")
        }
        _ = try routineStore.proof(candidate, key: routineKey())
        return candidate.program
    }

    private func keepRoutine(_ current: [String: JSONValue], admittedBy: String?, reviewedDigest: String?, ownerAuthorized: Bool) async throws -> JSONValue {
        let id = SkillMutation.pyStr(current["id"] ?? .null)
        guard ownerAuthorized || current["overrides"] != .string("built_in") else {
            throw SkillsError.invalidScript("Turning on an override of a built-in skill is the owner's.")
        }
        let candidate = try routineCandidate(current)
        let manifest = candidate.manifest.objectValue ?? [:]
        for id in candidate.program.dependencies {
            guard OwnedProgramInvocation.host?.dependencyMatches(id, candidate.dependencyShapes.objectValue?[id]) == true else {
                throw SkillsError.invalidScript("Dependency \(id) changed or its app door is unavailable. Validate against its current shape.")
            }
        }
        guard let script = manifest["script"], current["candidateValidation"] == .string("valid") else {
            throw SkillsError.invalidScript("Validate the exact routine candidate before enabling it.")
        }
        var admitted = current
        admitted["script"] = script
        admitted["codeFingerprint"] = .string(candidate.digest)
        admitted["origin"] = SkillScript.merged([manifest["origin"]] + SkillScript.recorded(current))
        if let admittedBy {
            guard reviewedDigest == candidate.digest else { throw SkillsError.invalidScript("The reviewed candidate changed, including source, fixtures or dependencies. Review it again.") }
            admitted["admission"] = .object(["digest": .string(candidate.digest), "candidate": .string(candidate.digest),
                "by": .string(admittedBy), "at": .string(SkillMutation.nowISO(now))])
        }
        guard SkillScript.admitted(admitted) else { throw SkillsError.invalidScript("Enable requires admission for the exact code and its origin.") }
        let admission = admitted["admission"], origin = admitted["origin"], stamp = SkillMutation.nowISO(now)
        let expected = Self.routineSelection(current)
        try await routineStore.keep(candidate, key: routineKey(), ownerAuthorized: ownerAuthorized) { value in
            for id in candidate.program.dependencies {
                guard OwnedProgramInvocation.host?.dependencyMatches(id, candidate.dependencyShapes.objectValue?[id]) == true else {
                    throw SkillsError.invalidScript("Dependency \(id) changed before publication. Save and validate it again.")
                }
            }
            var rows = try SkillsRegistry.decode(value)
            let before = rows
            guard let index = rows.firstIndex(where: { $0.objectValue?["id"] == .string(id) }),
                  case .object(var row) = rows[index], Self.routineSelection(row) == expected,
                  row["candidateDigest"] == nil || row["candidateSelection"] == expected else {
                throw SkillsError.invalidScript("The selected version or off-switch changed. Save and validate against its current state.")
            }
            for key in ["name", "description", "triggers", "script"] { row[key] = manifest[key] }
            row["origin"] = origin; row["admission"] = admission
            if row["codeFingerprint"] != .string(candidate.digest) { row["previousVersion"] = row["codeFingerprint"] ?? row["previousVersion"] }
            row["codeFingerprint"] = .string(candidate.digest)
            row["scriptDigest"] = SkillScript.sourceChecksum(script).map(JSONValue.string)
            row["signature"] = .string(SkillScript.signature(script))
            row["actionPin"] = .object(["digest": row["scriptDigest"] ?? .null, "actions": candidate.dependencyShapes,
                "interpreter": .int(Int64(SkillScript.interpreterRevision))])
            row["status"] = .string("active"); row["updatedAt"] = .string(stamp)
            for key in ["candidateDigest", "candidateSelection", "candidateOrigin"] { row.removeValue(forKey: key) }
            rows[index] = .object(row); value = try self.registryForPersistence(rows, before: before, ownerAuthorized: ownerAuthorized)
        }
        let saved = try await listSkills().first {
            $0.objectValue?["id"] == .string(id) && $0.objectValue?["source"] == .string("runtime_registry")
        } ?? .null
        return saved
    }

    public func readSkill(name: String, source: Bool = false) throws -> JSONValue {
        let entries = try InstalledSkillInventory.entries(dataRoot: root)
        let reviewEntries = entries
        guard let entry = InstalledSkillInventory.match(name, in: reviewEntries)
            ?? (name.hasSuffix(".md") ? InstalledSkillInventory.match(String(name.dropLast(3)), in: reviewEntries) : nil) else {
            throw SkillsError.unknownSkill(name)
        }
        let row = entry.row
        var result = row.filter { ["id", "name", "description", "triggers", "signature", "origin", "admission", "overrides", "suspended"].contains($0.key) }
        result["status"] = .string("ok"); result["skill_status"] = row["status"] ?? .null
        result["runnable"] = .bool(entry.isRunnable)
        result["digest"] = row["codeFingerprint"] ?? .null
        let converted = try routineStore.conversions(id: entry.id).map { candidate in
            JSONValue.object(["version": .string(candidate.digest), "converts": candidate.manifest.objectValue?["converts"] ?? .array([]),
                "rollback_call": .object(["action": .string("skill.rollback"), "args": .object(["name": .string(entry.name), "version": .string(candidate.digest)])])])
        }
        result["converted_versions"] = .array(converted)
        if let script = row["script"] {
            result["params"] = script.objectValue?["params"] ?? .object([:])
            result["input_schema"] = SkillScript.inputSchema(script)
            if result["params"] == .object([:]) { result["input_note"] = .string("No inputs are declared. Read the routine with skill.read {source:true} before running it.") }
            var metadata = script.objectValue ?? [:]
            result["signature"] = .string(SkillScript.signature(script))
            metadata["actions"] = .array(SkillScript.actions(script).map(JSONValue.string))
            if !source { metadata.removeValue(forKey: "source") }
            metadata["digest"] = result["digest"]; metadata["runnable"] = result["runnable"]
            metadata["admission"] = row["admission"] ?? .null; metadata["status"] = row["status"] ?? .null
            result["script"] = .object(metadata)
            result["versions"] = Self.scriptVersionMetadata(row)
        }
        if let selected = row["codeFingerprint"] {
            result["selected_version"] = selected
            if row["candidateDigest"] == nil { result["validation"] = row["candidateValidation"] ?? .null }
        }
        if let candidateDigest = row["candidateDigest"] {
            let candidate = try routineStore.load(id: entry.id, digest: SkillMutation.pyStr(candidateDigest))
            var pending = candidate.manifest.objectValue ?? [:]
            if !source, case .object(var script)? = pending["script"] {
                script.removeValue(forKey: "source"); pending["script"] = .object(script)
            }
            pending["digest"] = candidateDigest; pending["validation"] = row["candidateValidation"] ?? .null
            if source { pending["fixtures"] = candidate.fixtures }
            result["candidate"] = .object(pending)
        }
        if source, let selected = SkillMutation.pyStrOptional(row["codeFingerprint"]), row["script"] != nil {
            result["fixtures"] = try routineStore.load(id: entry.id, digest: selected).fixtures
        }
        if row["script"] == nil {
            if row["source"] == .string("persona_body"), let path = SkillMutation.pyStrOptional(row["bodyPath"]) {
                result["body"] = .string(try String(contentsOfFile: path, encoding: .utf8))
            } else if let file = try abilities.read(id: entry.id) {
                result["body"] = .string(file.body)
            }
        }
        return .object(result)
    }

    public func archiveSkill(id rawId: String) async throws -> JSONValue {
        try await deleteSkill(id: rawId)
    }

    /// Compare the kept action contracts without changing the ability.
    public func pinActions(_ entry: InstalledSkillInventory.Entry, digest: String, pins: [String: String]) async throws -> [String] {
        guard let row = try SkillsRegistry.decode(abilities.registry(kind: .skill))
            .first(where: { $0.objectValue?["id"] == .string(entry.id) })?.objectValue,
              SkillScript.isRunnable(row), row["codeFingerprint"] == .string(digest) else {
            throw SkillsError.stateNotAllowed(name: entry.id, state: "not runnable", requirement: "an admitted script")
        }
        let held: [String: JSONValue] = if case .object(let pin)? = row["actionPin"], pin["digest"] == row["scriptDigest"],
            case .object(let actions)? = pin["actions"] { actions } else { [:] }
        let wanted = pins.mapValues(JSONValue.string)
        return Set(held.keys).union(wanted.keys).filter { held[$0] != wanted[$0] }.sorted()
    }

    /// What a finished run of a script skill says about it (skills-as-code
    /// PR 5), kept in state.json under `runs`: its own faults in a row, the last
    /// result, and the trust ladder, the distinct inputs of its clean runs
    /// under this admission of this digest (a new digest, admission or pin
    /// starts it over). `fault` is the skill's own; a run with none that isn't
    /// `clean` was the world's and counts neither way. Returns its clean runs,
    /// and its upgrade signals (`CapabilityLifecycle`), each one MY QUEUE line
    /// at most once until it changes: the same world stop at the same step in
    /// 2 of its last 3 runs, and a new digest's fault, offering the last clean one.
    /// `runs.last` keeps the run's id, end time, reason and stop `step`.
    /// `admission` is the one the run started under: a row turned off,
    /// changed or admitted again since (by User or anything else) returns nil.
    public func recordRun(_ entry: InstalledSkillInventory.Entry, runID: String = "", digest: String, admission: JSONValue?, fault: String?, clean: Bool,
                          reason: String, step: String = "", inputHash: String) async throws -> (clean: Int, signals: [SkillLine])? {
        try await mutateRoutine(entry) { row in
            guard SkillScript.isRunnable(row), row["codeFingerprint"] == .string(digest),
                  row["admission"] == admission else { return nil }
            let at = SkillMutation.nowISO(self.now)
            let runs = row["runs"]?.objectValue ?? [:]
            let key = JSONValue.string(digest + "@" + (SkillMutation.pyStrOptional(row["admission"]?.objectValue?["at"]) ?? ""))
            let same = runs["key"] == key
            var inputs: [JSONValue] = if same, case .array(let held)? = runs["inputs"] { held } else { [] }
            var noted = same ? runs["noted"]?.objectValue ?? [:] : [:]
            let stop = (fault ?? reason) + "@" + step
            let held: [JSONValue] = if same, case .array(let list)? = runs["stops"] { list } else { [] }
            let stops = Array((held + [.string(stop)]).suffix(3))
            var faults = same ? SkillMutation.intValue(runs["faults"]) ?? 0 : 0
            if fault != nil {
                faults += 1
                inputs = []
            } else if clean {
                faults = 0
                if !inputs.contains(.string(inputHash)) {
                    inputs = Array((inputs + [.string(inputHash)]).suffix(CapabilityLifecycle.inputLimit))
                }
                row["lastCleanDigest"] = .string(digest)
                row["lastCleanVersion"] = row["codeFingerprint"]
            }
            let name = SkillMutation.pyStrTruthyOr(row["name"], entry.id)
            var signals: [SkillLine] = []
            let voices = SkillScript.voices(row)
            if let repeated = CapabilityLifecycle.repeatedStop(stops.compactMap(SkillMutation.pyStrOptional)),
               noted["stop"] != .string(repeated) {
                noted["stop"] = .string(repeated)
                let parts = repeated.split(separator: "@", maxSplits: 1).map(String.init)
                signals.append(("\(name) stopped on \(parts[0])\(parts.count > 1 && !parts[1].isEmpty ? " at \(parts[1])" : "") "
                    + "in 2 of its last 3 runs; upgrade it?", voices))
            }
            let lastClean = SkillMutation.pyStrOptional(row["previousVersion"])
            if CapabilityLifecycle.offersRollback(digest: digest, faulted: fault != nil, lastClean: lastClean),
               noted["fault"] != .string(digest), let lastClean {
                noted["fault"] = .string(digest)
                signals.append(("\(name)'s new script faulted (\(fault ?? reason)); skill.rollback returns its previous version "
                    + "(\(lastClean.prefix(8)))", voices))
            }
            var last: [String: JSONValue] = ["at": .string(at), "result": .string(fault != nil ? "skill_fault" : clean ? "clean" : "world"),
                                             "reason": .string(fault ?? reason), "step": .string(step)]
            if !runID.isEmpty { last["run_id"] = .string(runID) }
            row["runs"] = .object([
                "faults": .int(Int64(faults)), "key": key, "inputs": .array(inputs), "stops": .array(stops),
                "noted": .object(noted), "last": .object(last),
            ])
            row["lastUsedAt"] = .string(at)
            row["useCount"] = .int(Int64((SkillMutation.intValue(row["useCount"]) ?? 0) + 1))
            return (inputs.count, signals)
        }
    }

    /// Swap the current and previous files, preserving origin and owner off.
    public func rollbackScript(_ entry: InstalledSkillInventory.Entry, version: String?, steer: JSONValue, preview: Bool = false) async throws -> JSONValue {
        let row = entry.row
        return try AbilityStore.withLock {
            guard row["source"] == .string("runtime_registry"),
                  let previous = try abilities.read(id: entry.id, slot: .previous),
                  var fields = previous.metadata["record"]?.objectValue else { throw SkillsError.unknownVersion("no earlier routine") }
            let digest = SkillMutation.pyStrOptional(fields["codeFingerprint"]) ?? previous.bodyDigest
            guard version == nil || version == digest else { throw SkillsError.unknownVersion(version!) }
            let current = try SkillsRegistry.decode(abilities.registry(kind: .skill))
            guard let index = current.firstIndex(where: { $0.objectValue?["id"] == row["id"] }),
                  current[index].objectValue.map(Self.routineSelection) == Self.routineSelection(row) else {
                throw SkillsError.invalidScript("The selected routine or off-switch changed during rollback.")
            }
            if var script = fields["script"]?.objectValue { script["source"] = .string(previous.body); fields["script"] = .object(script) }
            fields["origin"] = SkillScript.merged([fields["origin"], steer] + SkillScript.recorded(row))
            if fields["script"] != nil, !SkillScript.admitted(fields) {
                fields["status"] = .string("draft")
                fields.removeValue(forKey: "admission")
            }
            fields.merge(try abilities.states()[entry.id]?.objectValue ?? [:]) { _, statistic in statistic }
            fields = try CapabilityLifecycle.preservingOwnerOff(fields, before: row, preview: preview)
            if preview { return .object(fields) }
            try CapabilityLifecycle.requireWrite()
            try abilities.swap(id: entry.id)
            var rows = try SkillsRegistry.decode(abilities.registry(kind: .skill))
            rows[index] = .object(fields)
            try abilities.saveRegistry(.array(rows), kind: .skill)
            return .object(fields)
        }
    }

    private static func scriptVersionMetadata(_ row: [String: JSONValue]) -> JSONValue {
        .object(["current": row["codeFingerprint"] ?? .null, "previous": row["previousVersion"] ?? .null,
                 "retained": row["versions"] ?? .array([])])
    }

    static func usersAdmission(_ row: [String: JSONValue], skill: String, steer: [String], fullMac: Bool) -> String? {
        let origin = row["origin"].flatMap { $0.objectValue } ?? [:]
        let kind = SkillScript.originKind(row["origin"])
        let peers = (origin["peers"].flatMap { if case .array(let peers) = $0 { peers } else { nil } } ?? [])
            .map { SkillMutation.pyStr($0) }
        let untrusted = steer.filter { !CapabilityLifecycle.ownerTrusts($0) }
        let users: String? = if !untrusted.isEmpty {
            "This turn was steered by \(untrusted.joined(separator: ", ")), so turning \(skill)'s script on is the owner's"
        } else if kind == "peer", !SkillScript.agentMayAdmit(row["origin"]) {
            "\(skill)'s script was steered by "
                + peers.joined(separator: ", ")
                + ", so turning it on is the owner's"
        } else if kind == "pack" || origin["pack"] != nil {
            "\(skill)'s script came with the \(SkillMutation.pyStr(origin["pack"] ?? .null)) pack, so turning it on is the owner's"
        } else if kind == nil {
            "\(skill)'s script has no attested origin, so turning it on is the owner's"
        } else if !fullMac {
            "Below Full Mac turning a script on is the owner's"
        } else { nil }
        return users
    }

    /// Agent lifecycle policy lives with the registry; the host only presents
    /// its receipt and records a decided Inbox row after a successful install.
    /// `fullMac` is the posture now; `steer` the peers steering this turn.
    /// `preview` (enable, restore, rollback) makes every check the real call makes, writes nothing and says what it would leave.
    public func manageSkill(
        verb asked: String, name: String, version: String?, personaRoot: URL, retry: String, fullMac: Bool, steer: [String],
        preview: Bool = false, ownerAuthorized: Bool = false
    ) async -> (ok: Bool, text: String, fields: [String: JSONValue]) {
        if preview, !["enable", "restore", "rollback"].contains(asked) {
            return (false, "Only enable, restore and rollback preview here; nothing was done.", [:])
        }
        let records: [JSONValue]
        do {
            records = try await lifecycleRecords()
        } catch {
            return (false, "The skill registry didn't read (\(error.localizedDescription))." + retry, [:])
        }
        guard !name.isEmpty, let matched = InstalledSkillInventory.match(name, in: records) else {
            return (false, "No skill is called \(name.isEmpty ? "(none passed)" : name). app skill.list shows the names.", [:])
        }
        var row = matched.row
        if row["candidateDigest"] != nil {
            do {
                let candidate = try routineCandidate(row)
                let manifest = candidate.manifest.objectValue ?? [:]
                row["script"] = manifest["script"]
                row["fixtures"] = candidate.fixtures
                row["origin"] = SkillScript.merged([manifest["origin"]] + SkillScript.recorded(row))
            } catch { return (false, "The routine candidate is unreadable: \(error.localizedDescription)", [:]) }
        }
        let registeredName = SkillMutation.pyStrTruthyOr(row["id"], SkillMutation.pyStrTruthyOr(row["name"], name))
        let skill = SkillMutation.pyStrTruthyOr(row["name"], name)
        let rawState = SkillMutation.pyStrTruthyOr(row["state"], SkillMutation.pyStrTruthyOr(row["status"], "active")).lowercased()
        let state = rawState == "draft" ? "drafted" : rawState == "disabled" ? "dormant" : rawState
        let verb = asked == "restore" ? "enable" : ["drop", "archive", "trash", "retire"].contains(asked) ? "delete" : asked
        let on = InstalledSkillInventory.isAvailable(["status": .string(state)])
        let fields: [String: JSONValue] = ["name": .string(skill), "state_before": .string(state)]
        func would(_ status: String, _ admit: String) -> [String: JSONValue] {
            guard preview else { return [:] }
            return ["would_status": .string(status), "would_admit": .string(admit)]
        }
        func mark(_ legacy: String, _ manifest: String, _ marks: [String: JSONValue], _ done: String,
                  admit: String = "") async -> (ok: Bool, text: String, fields: [String: JSONValue]) {
            if preview { return (true, "Without preview: " + done, fields.merging(would(manifest, admit)) { $1 }) }
            do {
                _ = try await updateSkill(matched, body: .object(["status": .string(legacy)]),
                    admittedBy: nil, reviewedDigest: nil, ownerAuthorized: ownerAuthorized)
            } catch {
                return (false, "\(verb) failed: \(error.localizedDescription)." + retry, fields)
            }
            return (true, done, fields)
        }
        let source = SkillMutation.pyStrTruthyOr(row["source"], "")
        if ["enable", "restore"].contains(verb) {
            do {
                if source == "runtime_registry" {
                    try await mutateRegistry { rows in
                        guard let current = rows.first(where: { $0.objectValue?["id"] == .string(registeredName) })?.objectValue else {
                            throw SkillsError.unknownSkill(registeredName)
                        }
                        _ = try CapabilityLifecycle.preservingOwnerOff(current, before: current, ownerAuthorized: ownerAuthorized, enabling: true)
                    }
                }
            } catch let error as NSError where error.domain == "CapabilityLifecycle" {
                return (false, error.localizedDescription, fields.merging(["reason": .string("owners_call")]) { $1 })
            } catch { return (false, error.localizedDescription + retry, fields) }
        }
        let personaBodies = personaRoot.appendingPathComponent("skills/bodies").standardizedFileURL.path + "/"
        let builtIn = source == "persona_body"
            || (SkillMutation.pyStrOptional(row["bodyPath"])?.hasPrefix(personaBodies) ?? false)
        if verb != "enable", builtIn, !ownerAuthorized {
            return (false, "\(skill) is built in: it ships with the app in persona/skills, so switching it off or deleting it is the owner's. Ask them.", fields)
        }
        let override = row["overrides"] == .string("built_in")
        if override, ["enable", "disable", "delete", "quarantine", "rollback"].contains(verb), !ownerAuthorized {
            return (false, "\(skill) is your version of a built-in, so switching it off or deleting it is the owner's. Ask them. "
                + "Changing its active version is the owner's too.", fields)
        }
        switch verb {
        case "enable":
            if let version, (row["candidateDigest"] ?? row["codeFingerprint"]) != .string(version) {
                return (false, "version must be the current candidate digest from skill.read. Nothing changed.",
                        fields.merging(["reason": .string("bad_input"), "next_call": .object([
                            "action": .string("skill.enable"), "args": .object(["name": .string(name),
                                "version": row["candidateDigest"] ?? row["codeFingerprint"] ?? .null])])]) { $1 })
            }
            if on, row["candidateDigest"] == nil, row["script"] == nil || SkillScript.admitted(row) {
                return (true, "\(skill) is already on (\(state)).", fields.merging(["changed": .bool(false)]) { $1 })
            }
            // Trusted peer origins use her own admission rule; other origins
            // ask the owner to review the exact candidate.
            var admit: String?
            var reviewed: String?
            var fields = fields
            if row["candidateDigest"] != nil || row["script"]?.objectValue?["entry"] == .string("run"),
               row["candidateValidation"] != .string("valid") {
                return (false, "Validate \(skill)'s exact candidate with skill.validate before enabling it.", fields)
            }
            if let script = row["script"], !SkillScript.admitted(row)
                || row["candidateDigest"] != nil && row["candidateDigest"] != row["codeFingerprint"] {
                let digest = SkillMutation.pyStr(row["candidateDigest"] ?? row["codeFingerprint"] ?? .null)
                if let users = Self.usersAdmission(row, skill: skill, steer: steer, fullMac: fullMac) {
                    // `skill_id` and `script` are for the host's card; it strips the script.
                    return (false, users + ": they read the script and install it. Nothing changed.",
                            fields.merging(["needs_owner": .bool(true), "reason": .string("owners_call"),
                                           "script_digest": .string(digest), "skill_id": .string(registeredName),
                                           "candidate_digest": row["candidateDigest"] ?? row["codeFingerprint"] ?? .null,
                                           "fixtures": row["fixtures"] ?? .array([]),
                                           "script": script]) { $1 }.merging(would("active", "owners_card")) { $1 })
                }
                admit = "agent"
                reviewed = SkillMutation.pyStrOptional(row["candidateDigest"] ?? row["codeFingerprint"])
                fields["script_digest"] = .string(digest)
                fields["admitted_by"] = admit.map(JSONValue.string)
            }
            if preview {
                return (true, "Would turn \(skill) on, active, " + (admit == nil ? "yours to turn on" : "its script admitted as yours")
                    + ".", fields.merging(would("active", "hers")) { $1 })
            }
            do {
                let saved = try await flipStatus(matched, legacyStatus: "active", admittedBy: admit, reviewedDigest: reviewed,
                    ownerAuthorized: ownerAuthorized)
                let confirmed = SkillMutation.string(saved, "status").isEmpty
                    ? SkillMutation.string(saved, "state") : SkillMutation.string(saved, "status")
                guard ["active", "installed"].contains(confirmed.lowercased()) else {
                    return (false, "Install could not be verified after the registry refresh. app skill.list shows its state now.", fields)
                }
                return (true, "‘\(skill)’ \(confirmed == "active" ? "is now active" : "is installed").", fields)
            } catch {
                return (false, "Install failed: \(error.localizedDescription) app skill.list shows its state now.", fields)
            }
        case "disable":
            guard on else {
                return (true, "\(skill) is not on (\(state)); nothing to disable.", fields.merging(["changed": .bool(false)]) { $1 })
            }
            return await mark("disabled", "dormant", [:],
                              "Disabled \(skill); it is out of find, and skill.enable turns it back on.")
        case "quarantine":
            do {
                _ = try await updateSkill(matched, body: .object(["status": .string("disabled")]),
                    admittedBy: nil, reviewedDigest: nil, ownerAuthorized: ownerAuthorized)
                return (true, "Switched \(skill) off. skill.enable turns it back on.", fields)
            } catch { return (false, "Quarantine failed: \(error.localizedDescription)", fields) }
        case "delete":
            do {
                _ = try await deleteSkill(id: registeredName, ownerAuthorized: ownerAuthorized)
                return (true, "Dropped \(skill) permanently: its ability files and run state are removed.", fields)
            } catch {
                return (false, "Drop failed: \(error.localizedDescription)." + retry, fields)
            }
        case "rollback":
            do {
                let rolled = try await rollbackScript(matched, version: version, steer: SkillScript.origin(steeredBy: steer), preview: preview)
                let lands = SkillMutation.string(rolled, "status")
                let ownerOff = CapabilityLifecycle.requiresOwnerToEnable(rolled.objectValue ?? [:])
                if preview {
                    let digest = String(SkillMutation.pyStr(rolled.objectValue?["candidateDigest"] ?? rolled.objectValue?["codeFingerprint"] ?? .null).prefix(12))
                    let users = Self.usersAdmission(rolled.objectValue ?? [:], skill: skill, steer: steer, fullMac: fullMac)
                    let state = lands == "draft" ? "drafted" : lands
                    return (true, "Would roll \(skill) back to script \(digest), \(state): turning it on is "
                        + (ownerOff ? "the owner's; their off-switch remains" : users.map { "the owner's card (\($0))" } ?? "yours, by skill.enable")
                        + ".",
                        fields.merging(["would_land_on": .string(digest)]) { $1 }
                            .merging(would(state, ownerOff ? "owners" : users == nil ? "hers" : "owners_card")) { $1 })
                }
                let digest = SkillMutation.pyStr(rolled.objectValue?["candidateDigest"] ?? rolled.objectValue?["codeFingerprint"] ?? .null)
                return (true, "Rolled \(skill) back to the script it had before this one (digest \(digest.prefix(12))). "
                    + (ownerOff ? "The owner's off-switch remains; they turn it back on."
                        : ["active", "installed"].contains(lands) ? "It is on under its existing admission."
                        : "It is drafted: skill.enable turns it on."),
                    fields.merging(["script_digest": .string(digest), "state": .string(lands == "draft" ? "drafted" : lands)]) { $1 })
            } catch SkillsError.unknownVersion {
                return (false, "\(skill) has no earlier script to roll back to; nothing changed.", fields)
            } catch {
                return (false, "Rollback failed: \(error.localizedDescription)." + retry, fields)
            }
        default:
            return (false, "No skill_manage verb is called \(verb).", [:])
        }
    }

    public func preflightPackSkills(
        _ items: [[String: JSONValue]], installID: String, packID: String
    ) throws {
        guard !items.isEmpty else { return }
        _ = try loadRegistryForMutation()
        let skillIDs = items.map { Self.packSkillID($0) }
        let ids = Set(skillIDs.map { $0.lowercased() })
        let inventory = try InstalledSkillInventory.entries(dataRoot: root).filter {
            Self.packString($0.row, "capabilityPackInstallId") != installID
        }
        let names = Set(items.map { Self.packString($0, "name").lowercased() }.filter { !$0.isEmpty })
        guard ids.count == items.count,
              skillIDs.allSatisfy(SkillMutation.isSafeSkillID),
              !inventory.contains(where: { ids.contains($0.id.lowercased()) || names.contains($0.name.lowercased()) }) else {
            throw SkillsError.invalidRegistry("Capability pack skills collide with existing skills or have invalid IDs.")
        }
        for item in items { _ = try SkillScript.normalized(item["script"]) }
    }

    public func installPackSkills(_ items: [[String: JSONValue]], installID: String, packID: String) async throws {
        try preflightPackSkills(items, installID: installID, packID: packID)
        for item in items {
            let script = try SkillScript.normalized(item["script"])
            var pins: [String: JSONValue] = [:]
            for case .string(let id) in script.objectValue?["actions"]?.arrayValue ?? [] {
                guard let pin = OwnedProgramInvocation.host?.dependencyPin(id) else {
                    throw SkillsError.invalidScript("Pack routine dependency \(id) is unavailable. Install through the app's Skills lifecycle.")
                }
                pins[id] = .string(pin)
            }
            var fields = item
            fields["id"] = .string(Self.packSkillID(item))
            fields["dependencyShapes"] = .object(pins)
            fields["installedByPack"] = .string(packID); fields["capabilityPackInstallId"] = .string(installID)
            _ = try await saveRoutine(fields, script: script, steer: SkillScript.origin(pack: packID))
        }
    }

    public func removePackSkills(_ skillIDs: [String], installID: String, packID: String) async throws {
        let ids = Set(skillIDs.map { $0.lowercased() })
        try await mutateRegistry(ownerAuthorized: true) { rows in
            rows.removeAll { value in
                guard case .object(let row) = value else { return false }
                return row["capabilityPackInstallId"] == .string(installID)
                    && row["installedByPack"] == .string(packID) && ids.contains(Self.packString(row, "id").lowercased())
            }
        }
    }

    public static func packSkillID(_ item: [String: JSONValue]) -> String {
        let explicit = packString(item, "id")
        if !explicit.isEmpty { return explicit }
        return packString(item, "name").lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(80).description
    }

    private static func packString(_ row: [String: JSONValue], _ key: String) -> String {
        SkillMutation.pyStrOptional(row[key]) ?? ""
    }

    // MARK: - Mutation helpers


    private func loadRegistryForMutation() throws -> [JSONValue] {
        do {
            return try SkillsRegistry.decode(abilities.registry(kind: .skill))
        } catch let error as SkillsError {
            throw error
        } catch {
            throw SkillsError.invalidRegistry(
                "Skill registry is unreadable; mutation was refused."
            )
        }
    }

    private var activity: SkillActivityEmitter {
        SkillActivityEmitter(persistence: persistence, activityPath: root.appendingPathComponent("activity/events.jsonl"), now: now)
    }

    private func registryForPersistence(_ rows: [JSONValue], before: [JSONValue], ownerAuthorized: Bool = false) throws -> JSONValue {
        let protected = try CapabilityLifecycle.preservingOwnerOff(.array(rows), before: .array(before), ownerAuthorized: ownerAuthorized)
        return .array(try (protected.arrayValue ?? []).map { value in
            guard case .object(var row) = value else { throw SkillsError.invalidRegistry("skill registry contains a non-object row") }
            let previous = before.first { $0.objectValue?["id"] == row["id"] }?.objectValue
            if previous == row { return value }
            if previous?["overrides"] == .string("built_in") { row["overrides"] = .string("built_in") }
            return .object(row)
        })
    }

    private func mutateRoutine<T: Sendable>(_ entry: InstalledSkillInventory.Entry, ownerAuthorized: Bool = false,
        _ body: @Sendable (inout [String: JSONValue]) throws -> T) async throws -> T {
        try await mutateRegistry(ownerAuthorized: ownerAuthorized) { rows in
            if entry.row["source"] == .string("persona_body") {
                guard ownerAuthorized, let path = SkillMutation.pyStrOptional(entry.row["bodyPath"]),
                      !rows.contains(where: { $0.objectValue?["id"] == .string(entry.id) }) else {
                    throw SkillsError.stateNotAllowed(name: entry.name, state: "built in", requirement: "the owner")
                }
                var row = entry.row
                row["source"] = .string("runtime_registry")
                row["body"] = .string(try String(contentsOfFile: path, encoding: .utf8))
                let result = try body(&row)
                rows.append(.object(row))
                return result
            }
            for index in rows.indices {
                guard var row = rows[index].objectValue else { continue }
                if entry.row["source"] == .string("runtime_registry"), row["id"] == .string(entry.id) {
                    let result = try body(&row)
                    rows[index] = .object(row)
                    return result
                }
            }
            throw SkillsError.unknownSkill(entry.id)
        }
    }

    private func mutateRegistry<T: Sendable>(ownerAuthorized: Bool = false, _ body: @Sendable (inout [JSONValue]) throws -> T) async throws -> T {
        try AbilityStore.withLock {
            let before = try self.loadRegistryForMutation()
            var rows = before
            let result = try body(&rows)
            if rows != before {
                let saved = try self.registryForPersistence(rows, before: before, ownerAuthorized: ownerAuthorized)
                try self.abilities.saveRegistry(saved, kind: .skill, ownerAuthorized: ownerAuthorized)
            }
            return result
        }
    }


}

// MARK: - Activity emitter (record_activity parity)
//
// A faithful record_activity port: same envelope keys
// {id, kind, title, detail, status, missionId, payload, createdAt}, same
// NativeAgentCore-owned redact_secret_text/value contract, and the same flocked
// append to <dataRoot>/activity/events.jsonl.

struct SkillActivityEmitter: Sendable {
    let persistence: any PersistenceCoreProtocol
    let activityPath: URL
    let now: @Sendable () -> Date

    /// Mirror `Daemon.record_activity(kind, title, detail, status, payload)`
    /// for the skill case (missionId always null). THROWS on a failed append
    /// matching the daemon (record_activity calls append_jsonl with no inner
    /// try/except). The caller fires this AFTER the registry write succeeds.
    func record(kind: String, title: String, detail: String, status: String, payload: JSONValue) async throws {
        let event: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string(kind),
            "title": .string(NativeAgentSecretRedactor.redactText(title)),
            "detail": .string(NativeAgentSecretRedactor.redactText(detail)),
            "status": .string(status),
            "executionId": .null,
            "payload": NativeAgentSecretRedactor.redactValue(payload),
            "createdAt": .string(SkillMutation.nowISO(now)),
        ])
        // U5 fix-round (2026-06-11, gpt-5.5 review): routed through the shared
        // capped append (PersistenceCore.appendJSONLCapped) — it takes the
        // flock itself when persistence is the SwiftNative impl and trims the
        // feed to the shared activity cap, logging what rotation drops.
        try await appendJSONLCapped(
            event, to: activityPath, using: persistence,
            logLabel: "Skills"
        )
    }

}

// MARK: - Factory

/// Returns the SwiftNative skills client.
public func makeSkillsClient(root: URL) -> any SkillsClient {
    return SwiftNativeSkillsClient(root: root)
}
