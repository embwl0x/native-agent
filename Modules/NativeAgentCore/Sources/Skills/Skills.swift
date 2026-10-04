import Privacy
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore

// Local skills registry reads and mutations. Reads preserve stored field
// shapes, sorting, and manifest merge precedence. Mutations serialize registry
// and manifest changes with their path-specific file locks.
// Update/delete operations append activity records; create does not.
// Callers own transport authentication and authorization. Mobile lifecycle
// calls use the Mac owner rather than a second file-backed implementation.

/// A quiet MY QUEUE line about a skill, and whose words its name is
/// (`SkillScript.voices`): none for her own.
public typealias SkillLine = (words: String, peers: [String])

// MARK: - Client protocol

public protocol SkillsClient: Sendable {
    /// GET /v1/skills — the learned-skills registry, sorted by
    /// (updatedAt | createdAt | "") DESC. Pure read (no write-back).
    func listSkills() async throws -> [JSONValue]
    /// GET /v1/skills/manifest — the merged CLI manifest registry reshaped into
    /// a list of `{"name": k, **v}` entries.
    func listManifestSkills() async throws -> [JSONValue]

    // MARK: - Mutations (wave 32 W15) — see SkillsError for the failure modes

    /// POST /v1/skills/update — patch name/description/triggers/kind/status on
    /// the skill matched by id-or-name, restamp updatedAt, save, fire
    /// record_activity. Returns the mutated skill object.
    /// Throws `SkillsError.unknownSkill` if no skill matches (Python ValueError).
    func updateSkill(body: JSONValue) async throws -> JSONValue

    /// POST /v1/skills/delete — remove the skill matched by id-or-name from
    /// registry.json, unlink its body file (path-confined), fire
    /// record_activity, and return `{id, deleted:true}`. If not found in the
    /// legacy registry, falls back to the manifest registry (mirrors the route
    /// handler at the retired daemon): pops the named entry from
    /// manifest_registry.json and returns `{id, deleted:true, source:"manifest"}`.
    /// Throws `SkillsError.unknownSkill` only if found in NEITHER registry.
    func deleteSkill(id: String) async throws -> JSONValue

    /// POST /v1/skills/{name}/enable — mirrors the route handler
    ///: first try update_skill(id:name,
    /// status:"active"); on unknown-skill fall back to the manifest state
    /// machine (drafted|dormant|installed → installed). Returns the mutated
    /// record (legacy skill object, or the manifest entry merged with
    /// {name, state}).
    func enableSkill(name: String) async throws -> JSONValue

    /// POST /v1/skills/{name}/disable — mirrors L52452-52476: try
    /// update_skill(id:name, status:"disabled"); on unknown-skill fall back to
    /// the manifest state machine (installed|active → dormant).
    func disableSkill(name: String) async throws -> JSONValue

    /// POST /v1/skills — create_skill: name-dedup (case-insensitive on name),
    /// slugify id, write the body .md, append the record. Does NOT fire
    /// record_activity (matching the retired daemon create_skill). Returns the
    /// created or updated record. No Mac-UI caller today; included for surface
    /// completeness + smoke parity.
    func createSkill(body: JSONValue) async throws -> JSONValue

    /// Read newest-first reversible versions owned by the Skills subsystem.
    func listSkillVersions(id: String) async throws -> [JSONValue]

    /// Archive without deleting the registry row or body.
    func archiveSkill(id: String) async throws -> JSONValue

    /// Restore one exact recorded version into the canonical registry/body.
    func restoreSkill(id: String, versionId: String) async throws -> JSONValue

    /// The agent's skill_manage lifecycle (User 10-01): set one skill's status
    /// (the legacy row's `status`, or the manifest entry's `state`) and stamp
    /// `marks` on it (`disabledBy`, `trashedAt`). Any status change clears the
    /// earlier marks first, so a mark lives exactly as long as the change that
    /// made it. The row and body stay; nothing is removed.
    func markSkill(name: String, legacyStatus: String, manifestState: String, marks: [String: JSONValue]) async throws -> JSONValue
}

public extension SkillsClient {
    func listSkillVersions(id: String) async throws -> [JSONValue] { [] }
    func archiveSkill(id: String) async throws -> JSONValue {
        throw SkillsError.historyUnavailable("skill archive is unavailable")
    }
    func restoreSkill(id: String, versionId: String) async throws -> JSONValue {
        throw SkillsError.historyUnavailable("skill restore is unavailable")
    }
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
    case historyUnavailable(String)
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
        case .invalidSkillBody(let why), .invalidRegistry(let why), .historyUnavailable(let why), .invalidScript(let why):
            return why
        case .unknownVersion(let version):
            return "No saved skill version matches \(version). Choose a version from the skill's history."
        }
    }
}

// MARK: - SwiftNative impl

public final class SwiftNativeSkillsClient: SkillsClient {
    private let root: URL
    private let persistence: SwiftNativePersistenceCore
    /// The legacy Application Support manifest path (first in the merge order).
    private let legacyManifestPath: URL
    /// Injectable clock for deterministic updatedAt/createdAt stamps in tests.
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - root: the daemon data root (the dir that contains `skills/`).
    ///   - legacyManifestPath: the legacy
    ///     `~/Library/Application Support/NativeAgent/skills/manifest_registry.json`
    ///     path. Injectable for tests; production callers omit it and get the
    ///     real home-relative path (mirrors the daemon's hard-coded
    ///     `Path.home() / "Library" / "Application Support" / ...`).
    ///   - now: clock for mutation timestamps. Defaults to `Date()`.
    public init(
        root: URL,
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore(),
        legacyManifestPath: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root
        self.persistence = persistence
        self.legacyManifestPath = legacyManifestPath ?? Self.defaultLegacyManifestPath()
        self.now = now
    }

    /// Mirrors the daemon's hard-coded legacy path:
    ///   Path.home() / "Library" / "Application Support" / "NativeAgent" / "skills" / "manifest_registry.json"
    public static func defaultLegacyManifestPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("NativeAgent", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("manifest_registry.json")
    }

    private var registryPath: URL {
        root.appendingPathComponent("skills/registry.json")
    }
    /// The data-root manifest (`self.manifest_skills_path` in the daemon).
    private var dataRootManifestPath: URL {
        root.appendingPathComponent("skills/manifest_registry.json")
    }
    private var historyDir: URL {
        root.appendingPathComponent("skills/history", isDirectory: true)
    }

    public func listSkills() async throws -> [JSONValue] {
        SkillsRegistry.sortedDescending(try InstalledSkillInventory.entries(dataRoot: root).map { .object($0.row) })
    }

    public func listManifestSkills() async throws -> [JSONValue] {
        // Read both files in the daemon's iteration order: [legacy, dataRoot].
        // A missing file → the read returns the default object, whose `skills`
        // sub-object is absent → SkillManifestRegistry.merge skips it (matching
        // the daemon's read_json(path, {"schemaVersion":1,"skills":{}}) +
        // `if not isinstance(data.get("skills"), dict): continue`).
        let legacyRaw = try readManifest(legacyManifestPath)
        let dataRootRaw = try readManifest(dataRootManifestPath)
        let merged = SkillManifestRegistry.merge(entries: [
            (raw: legacyRaw,
             parentPath: legacyManifestPath.deletingLastPathComponent().path,
             filePath: legacyManifestPath.path),
            (raw: dataRootRaw,
             parentPath: dataRootManifestPath.deletingLastPathComponent().path,
             filePath: dataRootManifestPath.path),
        ])
        return SkillManifestRegistry.reshapeToList(merged)
    }

    // MARK: - Mutations (wave 32 W15)
    //
    // Every legacy-registry R-M-W is wrapped in withFileLock(registryPath) and
    // every manifest-registry R-M-W in withFileLock(dataRootManifestPath) —
    // matching the Python side's `with file_lock(self.skills_path)` /
    // `with file_lock(self.manifest_skills_path)` this wave adds. The manifest
    // file is the WRITE target for the fallback branches (mirroring the route's
    // `write_json(self.runtime.manifest_skills_path, _mreg)`), so the manifest
    // lock guards the SAME path on both sides.

    /// Build the merged manifest registry exactly as the daemon's
    /// `manifest_registered_skills()` does (legacy then data-root; data-root
    /// wins; sourceRoot/registryPath setdefault), returned as the daemon's
    /// `{schemaVersion, skills: {name: entry}}` dict shape. Used by the
    /// enable/disable/delete manifest-fallback branches whose write target is
    /// `dataRootManifestPath` — they read the MERGED view but write the merged
    /// dict back to the data-root file, exactly as the route does (this
    /// collapses the legacy file's entries into the data-root file; preserved
    /// for behavior parity, NOT corrected here).
    private func readManifest(_ path: URL) throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .object(["schemaVersion": .int(1), "skills": .object([:])])
        }
        let raw = try JSONValue.parse(Data(contentsOf: path))
        guard case .object(let object) = raw, case .object(let skills)? = object["skills"],
              skills.values.allSatisfy({ $0.objectValue != nil }) else {
            throw SkillsError.invalidRegistry("Skill manifest registry is not a skills object.")
        }
        return raw
    }

    private func manifestRegisteredSkillsObject() async throws -> JSONValue {
        let legacyRaw = try readManifest(legacyManifestPath)
        let dataRootRaw = try readManifest(dataRootManifestPath)
        var skillsByName: [String: JSONValue] = [:]
        for (raw, path) in [(legacyRaw, legacyManifestPath), (dataRootRaw, dataRootManifestPath)] {
            guard case .object(let root) = raw,
                  case .object(let skills)? = root["skills"] else { continue }
            for name in skills.keys.sorted() {
                guard case .object(var entry) = skills[name]! else { continue }
                if entry["sourceRoot"] == nil { entry["sourceRoot"] = .string(path.deletingLastPathComponent().path) }
                if entry["registryPath"] == nil { entry["registryPath"] = .string(path.path) }
                skillsByName[name] = .object(entry)
            }
        }
        var skillsObj: [String: JSONValue] = [:]
        for (k, v) in skillsByName { skillsObj[k] = v }
        return .object(["schemaVersion": .int(1), "skills": .object(skillsObj)])
    }

    public func updateSkill(body: JSONValue) async throws -> JSONValue {
        try await updateSkill(body: body, admittedBy: nil, reviewedDigest: nil)
    }

    /// `admittedBy` (user or agent) admits a script skill it turns on, bound
    /// to `reviewedDigest`, the digest of the script the admitter read; one
    /// that changed since is refused here, inside the lock. Turning one on
    /// without a standing admission for its exact digest is refused.
    private func updateSkill(body: JSONValue, admittedBy: String?, reviewedDigest: String?) async throws -> JSONValue {
        let skillId = SkillMutation.unquote(SkillMutation.string(body, "id")).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await withRegistryLock { () throws -> JSONValue in
            var skills = try self.loadRegistryForMutation()
            for index in skills.indices {
                guard case .object(var skill) = skills[index] else { continue }
                let sid = SkillMutation.pyStr(skill["id"] ?? .null)
                let sname = SkillMutation.pyStr(skill["name"] ?? .null)
                if sid != skillId && sname != skillId { continue }
                let before = skill
                // Patch only the allowed keys present in the body.
                if case .object(let bodyObj) = body {
                    if bodyObj["status"] != nil {
                        for mark in SkillMutation.agentMarks { skill.removeValue(forKey: mark) }
                    }
                    for key in ["name", "description", "triggers", "kind", "status"] + SkillMutation.agentMarks
                    where bodyObj[key] != nil {
                        skill[key] = bodyObj[key]
                    }
                    // Turned on now: upkeep's 30 days count from here at the earliest.
                    if case .string(let status)? = bodyObj["status"], ["active", "installed"].contains(status.lowercased()) {
                        skill["enabledAt"] = .string(SkillMutation.nowISO(self.now))
                    }
                }
                skill["updatedAt"] = .string(SkillMutation.nowISO(self.now))
                if let script = skill["script"], InstalledSkillInventory.isAvailable(skill) {
                    // An admitter always names the digest it reviewed, admitted
                    // before or not: a stale review never turns on a newer script.
                    if let admittedBy {
                        guard let reviewedDigest, reviewedDigest == SkillScript.digest(script) else {
                            throw SkillsError.invalidScript(
                                "\(sname)'s script changed since you looked, or was never shown; nothing was turned on. Review it again.")
                        }
                        skill["admission"] = SkillScript.admission(script, by: admittedBy, at: SkillMutation.nowISO(self.now))
                    }
                    guard SkillScript.isRunnable(skill) else {
                        throw SkillsError.stateNotAllowed(name: sname, state: "drafted",
                                                          requirement: "an admission for its script's exact digest")
                    }
                }
                try await self.recordSkillVersion(.object(before), reason: "before-update")
                let updated = JSONValue.object(skill)
                skills[index] = updated
                try await self.persistence.writeJSON(.array(skills), to: self.registryPath)
                try? await self.recordSkillVersion(updated, reason: "updated")
                return updated
            }
            throw SkillsError.unknownSkill(skillId)
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

    public func deleteSkill(id rawId: String) async throws -> JSONValue {
        let skillId = SkillMutation.unquote(rawId).trimmingCharacters(in: .whitespacesAndNewlines)
        // First: try the legacy registry (delete_skill). Returns nil if not found
        // there, signalling the manifest fallback.
        let legacy: (result: JSONValue, displayName: String)? = try await withRegistryLock {
            () throws -> (JSONValue, String)? in
            let skills = try self.loadRegistryForMutation()
            var kept: [JSONValue] = []
            var removed: JSONValue? = nil
            for skill in skills {
                let sid = SkillMutation.pyStr((skill.objectValue?["id"]) ?? .null)
                let sname = SkillMutation.pyStr((skill.objectValue?["name"]) ?? .null)
                if sid == skillId || sname == skillId { removed = skill } else { kept.append(skill) }
            }
            guard let removedSkill = removed else { return nil }
            try await self.recordSkillVersion(removedSkill, reason: "before-delete")
            // Keep an inactive row until cleanup succeeds, so a leftover body
            // cannot be rediscovered as active loose guidance.
            var tombstone = removedSkill.objectValue ?? [:]
            tombstone["status"] = .string("trashed")
            try await self.persistence.writeJSON(.array(kept + [.object(tombstone)]), to: self.registryPath)
            let bodyPathRaw = SkillMutation.pyStrOptional(tombstone["bodyPath"]).flatMap { $0.isEmpty ? nil : $0 }
                ?? self.skillBodiesDir.appendingPathComponent("\(SkillMutation.pyStrTruthyOr(tombstone["id"], skillId)).md").path
            let bodyRemoved = await self.cleanupBodyFile(bodyPathRaw, skillId: skillId,
                displayName: SkillMutation.pyStrTruthyOr(tombstone["name"], skillId))
            if bodyRemoved {
                try await self.persistence.writeJSON(.array(kept), to: self.registryPath)
            }
            let displayName = SkillMutation.pyStrTruthyOr(removedSkill.objectValue?["name"], skillId)
            return (.object(["id": .string(skillId), "deleted": .bool(true)]), displayName)
        }
        if let hit = legacy {
            try await activity.record(kind: "skill", title: "Skill deleted", detail: hit.displayName,
                                      status: "ok", payload: .object(["skillId": .string(skillId)]))
            return hit.result
        }
        // Remove the legacy source too, so merging cannot resurrect the entry.
        return try await withManifestLock { () throws -> JSONValue in
            var mreg = try await self.manifestRegisteredSkillsObject()
            guard case .object(var mregObj) = mreg, case .object(var skills)? = mregObj["skills"],
                  let entry = skills[skillId] else {
                throw SkillsError.unknownSkill(skillId)
            }
            skills.removeValue(forKey: skillId)
            mregObj["skills"] = .object(skills)
            mreg = .object(mregObj)
            if self.legacyManifestPath.standardizedFileURL != self.dataRootManifestPath.standardizedFileURL {
                try await self.persistence.withFileLock(self.legacyManifestPath) {
                    let raw = try self.readManifest(self.legacyManifestPath)
                    guard case .object(var legacy) = raw, case .object(var entries)? = legacy["skills"],
                          entries.removeValue(forKey: skillId) != nil else { return }
                    legacy["skills"] = .object(entries)
                    try await self.persistence.writeJSON(.object(legacy), to: self.legacyManifestPath)
                }
            }
            try await self.persistence.writeJSON(mreg, to: self.dataRootManifestPath)
            let displayName = SkillMutation.pyStrTruthyOr(entry.objectValue?["name"], skillId)
            try await self.activity.record(kind: "skill", title: "Manifest skill deleted", detail: displayName,
                                           status: "ok", payload: .object(["skillId": .string(skillId)]))
            return .object(["id": .string(skillId), "deleted": .bool(true), "source": .string("manifest")])
        }
    }

    /// Turns on what needs no new admission: a script skill is admitted only
    /// with the digest its admitter reviewed (`enableSkill(name:admittedBy:reviewedDigest:)`).
    public func enableSkill(name rawName: String) async throws -> JSONValue {
        try await enableSkill(name: rawName, admittedBy: nil, reviewedDigest: nil)
    }

    /// `admittedBy` nil turns on only what needs no new admission.
    public func enableSkill(name rawName: String, admittedBy: String?, reviewedDigest: String?) async throws -> JSONValue {
        try await flipStatus(name: rawName, legacyStatus: "active", admittedBy: admittedBy, reviewedDigest: reviewedDigest,
                             allowedManifestStates: ["drafted", "dormant", "installed"],
                             targetManifestState: "installed",
                             requirement: "drafted, dormant, or installed")
    }

    public func disableSkill(name rawName: String) async throws -> JSONValue {
        try await flipStatus(name: rawName, legacyStatus: "disabled", admittedBy: nil, reviewedDigest: nil,
                             allowedManifestStates: ["installed", "active"],
                             targetManifestState: "dormant",
                             requirement: "installed or active")
    }

    /// Shared enable/disable body. Mirrors the two near-identical route handlers
    /// (L52426-52476): try the legacy update_skill status flip first; on
    /// unknown-skill, fall through to the manifest state machine.
    private func flipStatus(
        name rawName: String,
        legacyStatus: String,
        admittedBy: String?,
        reviewedDigest: String?,
        allowedManifestStates: Set<String>,
        targetManifestState: String,
        requirement: String
    ) async throws -> JSONValue {
        let name = SkillMutation.unquote(rawName)
        do {
            return try await updateSkill(body: .object(["id": .string(name), "status": .string(legacyStatus)]),
                                         admittedBy: admittedBy, reviewedDigest: reviewedDigest)
        } catch SkillsError.unknownSkill {
            // Manifest fallback.
            return try await withManifestLock { () throws -> JSONValue in
                var mreg = try await self.manifestRegisteredSkillsObject()
                guard case .object(var mregObj) = mreg, case .object(var skills)? = mregObj["skills"] else {
                    throw SkillsError.unknownSkill(name)
                }
                guard case .object(var entry)? = skills[name] else {
                    throw SkillsError.unknownSkill(name)
                }
                let state = SkillMutation.pyStrOptional(entry["state"])  // .get("state") -> may be None
                guard let st = state, allowedManifestStates.contains(st) else {
                    throw SkillsError.stateNotAllowed(name: name, state: state ?? "None", requirement: requirement)
                }
                entry["state"] = .string(targetManifestState)
                for mark in SkillMutation.agentMarks { entry.removeValue(forKey: mark) }
                entry["updatedAt"] = .string(SkillMutation.nowISO(self.now))
                skills[name] = .object(entry)
                mregObj["skills"] = .object(skills)
                mreg = .object(mregObj)
                try await self.persistence.writeJSON(mreg, to: self.dataRootManifestPath)
                // Route returns {"name": _name, "state": target, **_entry}.
                // The `**_entry` spread is LAST, so a `name`/`state` ALREADY in
                // the entry WINS over the leading literals (gpt-5.5 review
                // finding, wave 32 W15 — the prior code force-overwrote name).
                // entry already carries state=target (set above), and normally
                // has no own `name` key (manifest entries are keyed BY name), so
                // we only fill name/state when the entry omits them.
                var out = entry
                if out["name"] == nil { out["name"] = .string(name) }
                if out["state"] == nil { out["state"] = .string(targetManifestState) }
                return .object(out)
            }
        }
    }

    public func markSkill(
        name rawName: String, legacyStatus: String, manifestState: String, marks: [String: JSONValue]
    ) async throws -> JSONValue {
        let name = SkillMutation.unquote(rawName)
        var body: [String: JSONValue] = ["id": .string(name), "status": .string(legacyStatus)]
        body.merge(marks.filter { SkillMutation.agentMarks.contains($0.key) }) { $1 }
        do {
            return try await updateSkill(body: .object(body))
        } catch SkillsError.unknownSkill {
            return try await withManifestLock { () throws -> JSONValue in
                guard case .object(var mregObj) = try await self.manifestRegisteredSkillsObject(),
                      case .object(var skills)? = mregObj["skills"],
                      case .object(var entry)? = skills[name] else {
                    throw SkillsError.unknownSkill(name)
                }
                entry["state"] = .string(manifestState)
                for mark in SkillMutation.agentMarks { entry.removeValue(forKey: mark) }
                for (key, value) in marks where SkillMutation.agentMarks.contains(key) { entry[key] = value }
                entry["updatedAt"] = .string(SkillMutation.nowISO(self.now))
                skills[name] = .object(entry)
                mregObj["skills"] = .object(skills)
                try await self.persistence.writeJSON(.object(mregObj), to: self.dataRootManifestPath)
                var out = entry
                if out["name"] == nil { out["name"] = .string(name) }
                return .object(out)
            }
        }
    }

    public func createSkill(body: JSONValue) async throws -> JSONValue {
        try await createSkill(body: body, steer: nil)
    }

    /// `steer` is the attested origin of the turn that wrote it
    /// (`SkillScript.origin`); a script is saved, or a script skill edited,
    /// only with one. The body's own `origin` or `admission` is never read.
    public func createSkill(body: JSONValue, steer: JSONValue?) async throws -> JSONValue {
        let obj = body.objectValue ?? [:]
        let script = try obj["script"].flatMap { $0 == .null ? nil : try SkillScript.normalized($0) }
        if let missing = script.map(SkillScript.undeclared), !missing.isEmpty {
            throw SkillsError.invalidScript("Its source calls \(missing.joined(separator: ", ")), which its header's actions "
                + "don't declare: an action is app.<page>.<action>(…) and goes in actions; app.read, find, log, expect, "
                + "expect_fail, decide and step are the runner's own. Declare it or fix the call.")
        }
        let name = String(SkillMutation.pyStrTruthyOr(obj["name"], "Untitled Skill").trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        // Normalize to IMMUTABLE finals before the @Sendable lock closure so
        // nothing mutable is captured.
        let rawDescription = String(SkillMutation.pyStrTruthyOr(obj["description"], "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        var collectedTriggers: [String] = []
        if case .array(let arr)? = obj["triggers"] {
            for t in arr {
                let s = SkillMutation.pyStr(t).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { collectedTriggers.append(s) }
            }
        }
        let rawContent = SkillMutation.pyStrTruthyOr(obj["content"], SkillMutation.pyStrTruthyOr(obj["body"], "")).trimmingCharacters(in: .whitespacesAndNewlines)
        let autoCreated = SkillMutation.boolValue(obj["autoCreated"])
        let description = rawDescription.isEmpty ? "Reusable procedure for \(name)." : rawDescription
        let triggers: [String] = collectedTriggers.isEmpty ? [name] : collectedTriggers
        let content = rawContent.isEmpty ? "# \(name)\n\n\(description)\n" : rawContent
        let hygieneViolations = SkillBodyHygiene.violations(in: content)
        if !hygieneViolations.isEmpty {
            throw SkillsError.invalidSkillBody(SkillBodyHygiene.failureMessage(for: hygieneViolations))
        }

        return try await withRegistryLock { () throws -> JSONValue in
            var skills = try self.loadRegistryForMutation()
            let now = SkillMutation.nowISO(self.now)
            let inventory = try InstalledSkillInventory.entries(dataRoot: self.root)
            if !skills.contains(where: {
                SkillMutation.pyStrTruthyOr($0.objectValue?["name"], "").lowercased() == name.lowercased()
            }), let loose = inventory.first(where: {
                $0.row["source"] == .string("runtime_body") && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                guard let bodyURL = loose.bodyURL, try Data(contentsOf: bodyURL).count <= 65_536 else {
                    throw SkillsError.historyUnavailable("The existing skill body is too large to preserve before updating.")
                }
                var row = loose.row
                row.removeValue(forKey: "source")
                skills.append(.object(row))
            }
            let bodyIDs = try FileManager.default.fileExists(atPath: self.skillBodiesDir.path)
                ? FileManager.default.contentsOfDirectory(at: self.skillBodiesDir, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension.lowercased() == "md" }.map { $0.deletingPathExtension().lastPathComponent }
                : []
            let registryIDs = skills.map { SkillMutation.pyStr($0.objectValue?["id"] ?? .null) }
            let existingIds = Set(registryIDs + inventory.map(\.id) + bodyIDs)
            // case-insensitive name dedup (Python: next(... lower() == name.lower()))
            if let idx = skills.firstIndex(where: {
                SkillMutation.pyStrTruthyOr($0.objectValue?["name"], "").lowercased() == name.lowercased()
            }), case .object(var existing) = skills[idx] {
                // Normalize early/hand-authored registry rows that predate the
                // canonical writer and have no id. `str(null)` used to produce
                // a literal "None.md", disconnecting the manifest name from
                // the body read path. A deduplicated NAME may still slugify
                // to another row's ID, so repair uses the same allocation as
                // a new skill. An existing explicit id remains unchanged.
                // 2026-09-06: an existing row's id was preserved VERBATIM into
                // `skills/bodies/<id>.md`, and nothing validated it — a row
                // whose id carried path separators (a hand-edited or imported
                // registry) wrote the caller's body outside the bodies dir.
                // An id that is not a single safe path segment is not an
                // identity worth keeping; it is reallocated like a new skill's.
                let before = existing
                if script != nil || existing["script"] != nil, steer == nil {
                    throw SkillsError.invalidScript("A script skill is saved only with the origin of the turn that wrote it.")
                }
                let existingId = SkillMutation.pyTruthyStrOptional(existing["id"])
                    .flatMap { SkillMutation.isSafeSkillID($0) ? $0 : nil }
                let skillId = existingId ?? SkillMutation.availableID(
                    for: SkillMutation.pyStrTruthyOr(existing["name"], name), existingIDs: existingIds
                )
                let bodyPath = self.skillBodiesDir.appendingPathComponent("\(skillId).md")
                existing["id"] = .string(skillId)
                // Version under the allocated identity, not a name-derived
                // slug that may belong to another skill. Keep the prior body
                // path until this before-image has been captured.
                try await self.recordSkillVersion(.object(existing), reason: "before-create-update")
                existing["bodyPath"] = .string(bodyPath.path)
                if obj["description"] != nil { existing["description"] = .string(description) }
                if obj["triggers"] != nil { existing["triggers"] = .array(triggers.map { .string($0) }) }
                existing["updatedAt"] = .string(now)
                // body.get("status") or existing.get("status") or "active"
                // (truthiness: a present-but-empty status falls through).
                let bodyStatus = SkillMutation.pyTruthyStrOptional(obj["status"])
                let existingStatus = SkillMutation.pyTruthyStrOptional(existing["status"])
                existing["status"] = .string(bodyStatus ?? existingStatus ?? "active")
                if let script { existing["script"] = script }
                // A save never turns a script on: its status stays its own.
                if existing["script"] != nil { existing["status"] = before["status"] ?? .string("draft") }
                SkillScript.settle(&existing, before: before, origins: [steer] + SkillScript.recorded(before))
                try await self.writeBody(content, to: bodyPath)
                let updated = JSONValue.object(existing)
                skills[idx] = updated
                try await self.persistence.writeJSON(.array(skills), to: self.registryPath)
                try? await self.recordSkillVersion(updated, reason: "created-update")
                return updated
            }
            let skillId = SkillMutation.availableID(for: name, existingIDs: existingIds)
            let bodyPath = self.skillBodiesDir.appendingPathComponent("\(skillId).md")
            try await self.writeBody(content, to: bodyPath)
            // body.get("status") or ("draft" if autoCreated else "active")
            let status = SkillMutation.pyTruthyStrOptional(obj["status"]) ?? (autoCreated ? "draft" : "active")
            var record: [String: JSONValue] = [
                "id": .string(skillId),
                "name": .string(name),
                "description": .string(description),
                "triggers": .array(triggers.map { .string($0) }),
                // body.get("kind") or "skill" (truthiness fall-through).
                "kind": .string(SkillMutation.pyTruthyStrOptional(obj["kind"]) ?? "skill"),
                "status": .string(status),
                "autoCreated": .bool(autoCreated),
                "sourceRunId": obj["sourceRunId"] ?? .null,
                "bodyPath": .string(bodyPath.path),
                "createdAt": .string(now),
                "updatedAt": .string(now),
                "useCount": .int(Int64(SkillMutation.intValue(obj["useCount"]) ?? 0)),
                "lastUsedAt": .null,
            ]
            if let script {
                record["script"] = script
                SkillScript.settle(&record, before: nil, origins: [steer])
            }
            try await self.recordSkillVersion(.object(record), reason: "created")
            skills.append(.object(record))
            try await self.persistence.writeJSON(.array(skills), to: self.registryPath)
            return .object(record)
        }
    }

    public func listSkillVersions(id rawId: String) async throws -> [JSONValue] {
        let skillId = SkillMutation.unquote(rawId).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skillId.isEmpty else { throw SkillsError.unknownSkill(skillId) }
        let path = historyPath(for: skillId)
        return try await persistence.withFileLock(path) {
            let rows = try self.loadSkillHistory(skillId: skillId)
            return Array(rows.reversed())
        }
    }

    public func archiveSkill(id rawId: String) async throws -> JSONValue {
        let skillId = SkillMutation.unquote(rawId).trimmingCharacters(in: .whitespacesAndNewlines)
        return try await updateSkill(body: .object([
            "id": .string(skillId),
            "status": .string("archived"),
        ]))
    }

    public func restoreSkill(id rawId: String, versionId rawVersionId: String) async throws -> JSONValue {
        try await restoreSkill(id: rawId, versionId: rawVersionId, steer: nil)
    }

    /// `steer` is the restoring turn's origin; nil is User's own restore.
    public func restoreSkill(id rawId: String, versionId rawVersionId: String, steer: JSONValue?) async throws -> JSONValue {
        let skillId = SkillMutation.unquote(rawId).trimmingCharacters(in: .whitespacesAndNewlines)
        let versionId = SkillMutation.unquote(rawVersionId).trimmingCharacters(in: .whitespacesAndNewlines)
        let versions = try await listSkillVersions(id: skillId)
        guard let version = versions.first(where: {
            guard case .object(let row) = $0, case .string(let id)? = row["versionId"] else { return false }
            return id == versionId
        }), case .object(let versionObject) = version,
              case .object(let recordedSkill)? = versionObject["skill"] else {
            throw SkillsError.unknownVersion(versionId)
        }
        let restoredId = SkillMutation.pyStrTruthyOr(recordedSkill["id"], skillId)
        guard restoredId == skillId else {
            throw SkillsError.historyUnavailable("Recorded version does not belong to this skill.")
        }
        let restoredBody: String?
        if case .string(let body)? = versionObject["body"] { restoredBody = body } else { restoredBody = nil }
        if let restoredBody {
            let violations = SkillBodyHygiene.violations(in: restoredBody)
            if !violations.isEmpty {
                throw SkillsError.invalidSkillBody(SkillBodyHygiene.failureMessage(for: violations))
            }
        }
        let capturedSkill = recordedSkill
        let capturedBody = restoredBody
        return try await withRegistryLock {
            var skills = try self.loadRegistryForMutation()
            guard let index = skills.firstIndex(where: {
                let object = $0.objectValue
                return SkillMutation.pyStr(object?["id"] ?? .null) == skillId
                    || SkillMutation.pyStr(object?["name"] ?? .null) == skillId
            }) else { throw SkillsError.unknownSkill(skillId) }
            try await self.recordSkillVersion(skills[index], reason: "before-restore")
            var restored = capturedSkill
            let before = skills[index].objectValue ?? [:]
            SkillScript.settle(&restored, before: before,
                origins: SkillScript.recorded(capturedSkill) + SkillScript.recorded(before) + (steer.map { [$0] } ?? []))
            let bodyPath = self.skillBodiesDir.appendingPathComponent("\(skillId).md")
            let priorBody = try? Data(contentsOf: bodyPath)
            let bodyExisted = FileManager.default.fileExists(atPath: bodyPath.path)
            if let capturedBody {
                try await self.writeBody(capturedBody, to: bodyPath)
                restored["bodyPath"] = .string(bodyPath.path)
            }
            restored["updatedAt"] = .string(SkillMutation.nowISO(self.now))
            if InstalledSkillInventory.isAvailable(restored) {
                restored["enabledAt"] = .string(SkillMutation.nowISO(self.now))
            }
            let restoredValue = JSONValue.object(restored)
            skills[index] = restoredValue
            do {
                try await self.persistence.writeJSON(.array(skills), to: self.registryPath)
            } catch {
                if let priorBody { try? priorBody.write(to: bodyPath, options: .atomic) }
                else if !bodyExisted { try? FileManager.default.removeItem(at: bodyPath) }
                throw error
            }
            try? await self.recordSkillVersion(restoredValue, reason: "restored")
            return restoredValue
        }
    }

    /// The pin on the actions a runnable script declares (skills-as-code PR 3):
    /// its first run under the digest records each action's hash (`pins`); a
    /// later run whose hashes differ suspends it, drafted with its admission
    /// and pin gone, so it runs again only on a new admission of its exact
    /// digest. Returns the actions that changed; none when it may run.
    public func pinActions(id rawId: String, digest: String, pins: [String: String]) async throws -> [String] {
        try await withRegistryLock {
            var skills = try self.loadRegistryForMutation()
            guard let index = skills.firstIndex(where: {
                [$0.objectValue?["id"], $0.objectValue?["name"]].contains(.string(rawId))
            }), case .object(var row) = skills[index], SkillScript.isRunnable(row),
                  SkillScript.digest(row["script"]) == digest else {
                throw SkillsError.stateNotAllowed(name: rawId, state: "not runnable", requirement: "an admitted script")
            }
            let held: [String: JSONValue]? = if case .object(let pin)? = row["actionPin"], pin["digest"] == .string(digest),
                case .object(let actions)? = pin["actions"] { actions } else { nil }
            let wanted = pins.mapValues(JSONValue.string)
            if held == wanted { return [] }
            if let held {
                let changed = Set(held.keys).union(wanted.keys).filter { held[$0] != wanted[$0] }.sorted()
                try await self.recordSkillVersion(.object(row), reason: "before-suspend")
                self.suspend(&row, actions: changed)
                skills[index] = .object(row)
                try await self.persistence.writeJSON(.array(skills), to: self.registryPath)
                return changed
            }
            row["actionPin"] = .object(["digest": .string(digest), "actions": .object(wanted)])
            row.removeValue(forKey: "suspended")
            skills[index] = .object(row)
            try await self.persistence.writeJSON(.array(skills), to: self.registryPath)
            return []
        }
    }

    /// Suspended: drafted, its admission and pin gone, naming the actions
    /// that changed; it runs again only on a new admission of its exact digest.
    private func suspend(_ row: inout [String: JSONValue], actions: [String]) {
        row["status"] = .string("draft")
        for key in ["admission", "actionPin"] { row.removeValue(forKey: key) }
        row["suspended"] = .object(["actions": .array(actions.map(JSONValue.string)),
                                    "at": .string(SkillMutation.nowISO(now))])
        row["updatedAt"] = .string(SkillMutation.nowISO(now))
    }

    /// Retired (skills-as-code PR 5): archived, never deleted, and hers to
    /// turn back on; the faults that retired it are spent.
    private func retire(_ row: inout [String: JSONValue], why: String) {
        row["status"] = .string("archived")
        // Never over whoever else turned it off.
        if row["disabledBy"] == nil { row["disabledBy"] = .string("agent") }
        row["retired"] = .object(["why": .string(why), "at": .string(SkillMutation.nowISO(now))])
        row["updatedAt"] = .string(SkillMutation.nowISO(now))
        if case .object(var runs)? = row["runs"] { runs["faults"] = .int(0); row["runs"] = .object(runs) }
    }

    /// What a finished run of a script skill says about it (skills-as-code
    /// PR 5), kept on its row under `runs`: its own faults in a row, the last
    /// result, and the trust ladder, the distinct inputs of its clean runs
    /// under this admission of this digest (a new digest, admission or pin
    /// starts it over). `fault` is the skill's own; a run with none that isn't
    /// `clean` was the world's and counts neither way. Two of its own in a row
    /// retire it. Returns its clean runs on the ladder, whether it retired,
    /// and its upgrade signals (`CapabilityLifecycle`), each one MY QUEUE line
    /// at most once until it changes: the same world stop at the same step in
    /// 2 of its last 3 runs, and a new digest's fault, offering the last clean one.
    /// `runs.last` keeps the run's id, end time, reason and stop `step`.
    /// `admission` is the one the run started under: a row turned off,
    /// changed or admitted again since (by User or anything else) records nothing.
    public func recordRun(id rawId: String, runID: String = "", digest: String, admission: JSONValue?, fault: String?, clean: Bool,
                          reason: String, step: String = "", inputHash: String) async throws -> (clean: Int, retired: Bool, signals: [SkillLine]) {
        try await withRegistryLock {
            var skills = try self.loadRegistryForMutation()
            guard let index = skills.firstIndex(where: {
                [$0.objectValue?["id"], $0.objectValue?["name"]].contains(.string(rawId))
            }), case .object(var row) = skills[index], SkillScript.isRunnable(row), SkillScript.digest(row["script"]) == digest,
                  row["admission"] == admission else { return (0, false, []) }
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
            }
            let name = SkillMutation.pyStrTruthyOr(row["name"], rawId)
            var signals: [SkillLine] = []
            let voices = SkillScript.voices(row)
            if let repeated = CapabilityLifecycle.repeatedStop(stops.compactMap(SkillMutation.pyStrOptional)),
               noted["stop"] != .string(repeated) {
                noted["stop"] = .string(repeated)
                let parts = repeated.split(separator: "@", maxSplits: 1).map(String.init)
                signals.append(("\(name) stopped on \(parts[0])\(parts.count > 1 && !parts[1].isEmpty ? " at step \(parts[1])" : "") "
                    + "in 2 of its last 3 runs; upgrade it?", voices))
            }
            let lastClean = SkillMutation.pyStrOptional(row["lastCleanDigest"])
            if CapabilityLifecycle.offersRollback(digest: digest, faulted: fault != nil, lastClean: lastClean),
               noted["fault"] != .string(digest), let lastClean {
                noted["fault"] = .string(digest)
                signals.append(("\(name)'s new script faulted (\(fault ?? reason)); skill.rollback returns its last clean one "
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
            let retired = faults >= 2
            if retired {
                try await self.recordSkillVersion(skills[index], reason: "before-retire")
                self.retire(&row, why: "a fault of its own twice in a row (last: \(fault ?? reason))")
            }
            skills[index] = .object(row)
            try await self.persistence.writeJSON(.array(skills), to: self.registryPath)
            return (inputs.count, retired, signals)
        }
    }

    /// Upkeep on a turn that lists or runs skills (skills-as-code PR 5), no
    /// timer of its own: a script declaring an action `missing` says the app
    /// no longer has is suspended, and any skill that is on but unused for
    /// 30 days is archived, never deleted (`CapabilityLifecycle`).
    /// Returns one MY QUEUE line per skill it changed.
    public func upkeep(missing: @escaping @Sendable (String) -> Bool,
                       unusedDays: Int = CapabilityLifecycle.unusedDays) async throws -> [SkillLine] {
        try await withRegistryLock {
            var skills = try self.loadRegistryForMutation()
            var lines: [SkillLine] = []
            for index in skills.indices {
                guard case .object(var row) = skills[index] else { continue }
                let name = SkillMutation.pyStrTruthyOr(row["name"], SkillMutation.pyStr(row["id"] ?? .null))
                let status = (SkillMutation.pyStrOptional(row["status"]) ?? "").lowercased()
                // Plain lookups: the optimizer miscompiles (ownership crash) the chained optional/lazy form here.
                let script = row["script"]?.objectValue ?? [:]
                let declared: [JSONValue]
                if case .array(let ids)? = script["actions"] { declared = ids } else { declared = [] }
                let gone = declared.compactMap(SkillMutation.pyStrOptional).filter(missing)
                let admittedAt = row["admission"]?.objectValue?["at"] ?? .null
                var used: String?
                for value in [row["lastUsedAt"] ?? .null, admittedAt, row["updatedAt"] ?? .null, row["createdAt"] ?? .null] where used == nil {
                    used = SkillMutation.pyStrOptional(value)
                }
                // Only one that is on or drafted: a skill someone turned off stays theirs.
                if !gone.isEmpty, InstalledSkillInventory.isAvailable(row) || status == "draft",
                   row["suspended"]?.objectValue?["actions"] != .array(gone.map(JSONValue.string)) {
                    try await self.recordSkillVersion(skills[index], reason: "before-suspend")
                    self.suspend(&row, actions: gone)
                    lines.append(("\(name) suspended: \(gone.joined(separator: ", ")) no longer in the app; fix its script, then skill.enable",
                                  SkillScript.voices(row)))
                } else if gone.isEmpty, InstalledSkillInventory.isAvailable(row),
                          CapabilityLifecycle.isUnused(used: used, enabled: [SkillMutation.pyStrOptional(row["enabledAt"])],
                                                       now: self.now(), days: unusedDays) {
                    try await self.recordSkillVersion(skills[index], reason: "before-retire")
                    self.retire(&row, why: "unused for \(unusedDays) days")
                    lines.append(("\(name) archived: unused for \(unusedDays) days, not deleted; skill.restore brings it back",
                                  SkillScript.voices(row)))
                } else { continue }
                skills[index] = .object(row)
            }
            if !lines.isEmpty { try await self.persistence.writeJSON(.array(skills), to: self.registryPath) }
            return lines
        }
    }

    /// A use that isn't a run (`skill.read`): its clock starts over. Only a
    /// registry row keeps one; a body with no row has no clock.
    public func recordUse(id rawId: String) async throws {
        try await withRegistryLock {
            var skills = try self.loadRegistryForMutation()
            guard let index = skills.firstIndex(where: { [$0.objectValue?["id"], $0.objectValue?["name"]].contains(.string(rawId)) }),
                  case .object(var row) = skills[index] else { return }
            row["lastUsedAt"] = .string(SkillMutation.nowISO(self.now))
            skills[index] = .object(row)
            try await self.persistence.writeJSON(.array(skills), to: self.registryPath)
        }
    }

    /// Archived through the lifecycle, never deleted: a body with no registry
    /// row gets its row first. Already archived changes nothing.
    public func archive(name: String, why: String) async throws {
        guard let entry = InstalledSkillInventory.match(name, in: try InstalledSkillInventory.entries(dataRoot: root)) else {
            throw SkillsError.unknownSkill(name)
        }
        if entry.row["source"] == .string("runtime_body") { try await registerSkillBody(entry.row) }
        try await withRegistryLock {
            var skills = try self.loadRegistryForMutation()
            guard let index = skills.firstIndex(where: { [$0.objectValue?["id"], $0.objectValue?["name"]].contains(.string(entry.id)) }),
                  case .object(var row) = skills[index], row["status"] != .string(CapabilityLifecycle.archived) else { return }
            try await self.recordSkillVersion(skills[index], reason: "before-retire")
            self.retire(&row, why: why)
            skills[index] = .object(row)
            try await self.persistence.writeJSON(.array(skills), to: self.registryPath)
        }
    }

    /// Bring back the script (and header) the skill had before this one, from
    /// its version history: its last clean one when the history has it. It
    /// lands drafted; its origin keeps every hand, the restored version's and
    /// `steer`'s too. `preview` returns the row it would write and writes nothing.
    public func rollbackScript(id rawId: String, steer: JSONValue, preview: Bool = false) async throws -> JSONValue {
        let skillId = SkillMutation.unquote(rawId).trimmingCharacters(in: .whitespacesAndNewlines)
        let history = try await listSkillVersions(id: skillId)
        return try await withRegistryLock {
            var skills = try self.loadRegistryForMutation()
            guard let index = skills.firstIndex(where: {
                [$0.objectValue?["id"], $0.objectValue?["name"]].contains(.string(skillId))
            }), case .object(var row) = skills[index] else { throw SkillsError.unknownSkill(skillId) }
            let before = row
            let earlier = Self.earlierScripts(row, history)
            guard let record = earlier.clean ?? earlier.previous else { throw SkillsError.unknownVersion("no earlier script") }
            let version = record["skill"]?.objectValue ?? [:]
            row["script"] = version["script"]
            SkillScript.settle(&row, before: before, origins: [version["origin"], steer] + SkillScript.recorded(before))
            row["updatedAt"] = .string(SkillMutation.nowISO(self.now))
            if preview { return .object(row) }
            try await self.recordSkillVersion(.object(before), reason: "before-rollback")
            skills[index] = .object(row)
            try await self.persistence.writeJSON(.array(skills), to: self.registryPath)
            try? await self.recordSkillVersion(.object(row), reason: "rolled-back")
            return .object(row)
        }
    }

    /// The earlier scripts rollback weighs in `history` (newest first, as
    /// `listSkillVersions` gives it), each its history record: the previous
    /// one and the last clean one. Rollback lands on the clean, else the previous.
    static func earlierScripts(_ row: [String: JSONValue], _ history: [JSONValue])
        -> (previous: [String: JSONValue]?, clean: [String: JSONValue]?) {
        let current = SkillScript.digest(row["script"])
        let cleanDigest = SkillMutation.pyStrOptional(row["lastCleanDigest"])
        var previous: [String: JSONValue]?
        var clean: [String: JSONValue]?
        for case .object(let record) in history {
            let skill = record["skill"]?.objectValue ?? [:]
            guard let script = skill["script"], SkillScript.digest(script) != current,
                  (try? SkillScript.normalized(script)) == script else { continue }
            if previous == nil { previous = record }
            if clean == nil, SkillScript.digest(script) == cleanDigest { clean = record }
        }
        return (previous, clean)
    }

    /// `skill.read`'s versions (`CapabilityLifecycle`): current, previous and
    /// last clean, each its script's digest (12), when it was made and the
    /// status it lands in (a rollback lands drafted); null when not kept.
    public func scriptVersions(_ row: [String: JSONValue]) async -> JSONValue {
        let id = SkillMutation.pyStrTruthyOr(row["id"], SkillMutation.pyStr(row["name"] ?? .null))
        let earlier = Self.earlierScripts(row, (try? await listSkillVersions(id: id)) ?? [])
        func version(_ script: JSONValue?, _ at: JSONValue?, _ lands: String) -> JSONValue {
            guard let digest = SkillScript.digest(script) else { return .null }
            return .object(["digest": .string(String(digest.prefix(12))), "at": at ?? .null, "lands": .string(lands)])
        }
        func kept(_ record: [String: JSONValue]?) -> JSONValue {
            guard let record else { return .null }
            let skill = record["skill"]?.objectValue ?? [:]
            return version(skill["script"], record["createdAt"], "drafted")
        }
        let status = (SkillMutation.pyStrOptional(row["status"]) ?? "active").lowercased()
        let current = version(row["script"], row["updatedAt"], status == "draft" ? "drafted" : status)
        let clean = SkillMutation.pyStrOptional(row["lastCleanDigest"])
        return .object(["current": current, "previous": kept(earlier.previous),
                        "last_clean": clean != nil && clean == SkillScript.digest(row["script"]) ? current : kept(earlier.clean)])
    }

    /// Why turning `row`'s script on is User's, or nil when it is hers to
    /// admit: the steer on this turn, the script's origin and Trust (`fullMac`).
    static func usersAdmission(_ row: [String: JSONValue], skill: String, steer: [String], fullMac: Bool,
                              ownerAuthorized: Bool) -> String? {
        let origin = row["origin"].flatMap { $0.objectValue } ?? [:]
        let kind = SkillScript.originKind(row["origin"])
        let peers = (origin["peers"].flatMap { if case .array(let peers) = $0 { peers } else { nil } } ?? [])
            .map { SkillMutation.pyStr($0) }
        let users: String? = if !ownerAuthorized, !steer.isEmpty {
            "This turn was steered by \(steer.joined(separator: ", ")), so turning \(skill)'s script on is User's"
        } else if kind == "peer", !ownerAuthorized {
            "\(skill)'s script was steered by "
                + peers.joined(separator: ", ")
                + ", so turning it on is User's"
        } else if kind == "pack" || origin["pack"] != nil {
            "\(skill)'s script came with the \(SkillMutation.pyStr(origin["pack"] ?? .null)) pack, so turning it on is User's"
        } else if kind == nil {
            "\(skill)'s script has no attested origin, so turning it on is User's"
        } else if !fullMac {
            "Below Full Mac turning a script on is User's"
        } else { nil }
        return users
    }

    /// Agent lifecycle policy lives with the registry; the host only presents
    /// its receipt and records a decided Inbox row after a successful install.
    /// `fullMac` is the posture now; `steer` the peers steering this turn.
    /// `preview` (enable, restore, rollback) makes every check the real call makes, writes nothing and says what it would leave.
    public func manageSkill(
        verb asked: String, name: String, personaRoot: URL, retry: String, fullMac: Bool, steer: [String],
        preview: Bool = false, ownerAuthorized: Bool = false,
        reconcile: @Sendable () async throws -> Void
    ) async -> (ok: Bool, text: String, fields: [String: JSONValue]) {
        if preview, !["enable", "restore", "rollback"].contains(asked) {
            return (false, "Only enable, restore and rollback preview here; nothing was done.", [:])
        }
        let records: [JSONValue]
        do {
            records = try await InstalledSkillInventory.entries(dataRoot: root, personaRoot: personaRoot)
                .map { .object($0.row) } + listManifestSkills()
        } catch {
            return (false, "The skill registry didn't read (\(error.localizedDescription))." + retry, [:])
        }
        let key = name.lowercased()
        var selected: (row: [String: JSONValue], manifest: [String: JSONValue])?
        for case .object(let row) in records {
            let manifest: [String: JSONValue]
            if row["state"] != nil {
                guard let value = try? JSONValue.parse(Data(contentsOf: manifestDirectory(for: row).appendingPathComponent("manifest.json"))),
                      case .object(let object) = value else { continue }
                manifest = object
            } else { manifest = [:] }
            if [row["id"], row["name"], manifest["name"]].contains(where: {
                SkillMutation.pyStrOptional($0)?.lowercased() == key
            }) { selected = (row, manifest); break }
        }
        guard !key.isEmpty, let selected else {
            return (false, "No skill is called \(name.isEmpty ? "(none passed)" : name). app skill.list shows the names.", [:])
        }
        let row = selected.row
        let registeredName = SkillMutation.pyStrTruthyOr(row["id"], SkillMutation.pyStrTruthyOr(row["name"], name))
        let skill = SkillMutation.pyStrTruthyOr(selected.manifest["name"], SkillMutation.pyStrTruthyOr(row["name"], name))
        let rawState = SkillMutation.pyStrTruthyOr(row["state"], SkillMutation.pyStrTruthyOr(row["status"], "active")).lowercased()
        let state = rawState == "draft" ? "drafted" : rawState == "disabled" ? "dormant" : rawState
        // Archived (`CapabilityLifecycle`): restore is turning it back on.
        let archived = state == CapabilityLifecycle.archived
        let verb = asked == "restore" && archived ? "enable" : asked
        let on = InstalledSkillInventory.isAvailable(["status": .string(state)])
        let hers = row["disabledBy"] == .string("agent")
        let fields: [String: JSONValue] = ["name": .string(skill), "state_before": .string(state)]
        // A preview says what the real call would leave (`CapabilityLifecycle`):
        // the status, whose turning it on is (hers, User's card, or User's own),
        // and when its 30-day unused clock restarts.
        func would(_ status: String, _ admit: String, now: Bool) -> [String: JSONValue] {
            guard preview else { return [:] }
            return ["would_status": .string(status), "would_admit": .string(admit),
                    "would_clock": .string(now ? "restarts now" : "restarts when it is turned on")]
        }
        func mark(_ legacy: String, _ manifest: String, _ marks: [String: JSONValue], _ done: String,
                  admit: String = "") async -> (ok: Bool, text: String, fields: [String: JSONValue]) {
            if preview { return (true, "Without preview: " + done, fields.merging(would(manifest, admit, now: false)) { $1 }) }
            do {
                _ = try await markSkill(
                    name: registeredName, legacyStatus: legacy, manifestState: manifest, marks: marks)
                try await reconcile()
            } catch {
                return (false, "\(verb) failed: \(error.localizedDescription)." + retry, fields)
            }
            return (true, done, fields)
        }
        let source = SkillMutation.pyStrTruthyOr(row["source"], "")
        let personaBodies = personaRoot.appendingPathComponent("skills/bodies").standardizedFileURL.path + "/"
        let builtIn = source == "persona_body"
            || (SkillMutation.pyStrOptional(row["bodyPath"])?.hasPrefix(personaBodies) ?? false)
        if verb != "enable", builtIn {
            return (false, "\(skill) is built in: it ships with the app in persona/skills, so switching it off or deleting it is User's. Ask him.", fields)
        }
        if ["disable", "delete"].contains(verb), source == "runtime_body" {
            // Hers: a body in the data root, not one the app ships. It gets
            // its registry row now, so her switch has somewhere to live.
            do { try await registerSkillBody(row) } catch {
                return (false, "\(skill) had no registry row, and registering it failed (\(error.localizedDescription))."
                    + retry, fields)
            }
        }
        switch verb {
        case "enable":
            if on { return (true, "\(skill) is already on (\(state)).", fields.merging(["changed": .bool(false)]) { $1 }) }
            if state == "trashed" {
                return (false, "\(skill) is in the trash. skill.restore brings it back (off); then skill.enable turns it on.", fields)
            }
            if state != "drafted", !hers {
                return (false, "User turned \(skill) off; he turns it back on. Ask him.",
                        fields.merging(["reason": .string("users_call")]) { $1 })
            }
            if let reach = Self.reachPastGuidance(selected.manifest) {
                return (false, "\(skill) declares \(reach), which reaches past guidance. Installing it is User's: ask him to Install it on the Skills page.",
                        fields.merging(["reason": .string("users_call")]) { $1 })
            }
            // A script runs only under an admission of its exact digest: hers
            // to give for her own script under Full Mac on her own turn, and
            // otherwise User's, on the Skills page where he reads the script.
            // An archived one is admitted again as it comes back.
            var admit: String?
            var reviewed: String?
            var fields = fields
            if let script = row["script"], !SkillScript.admitted(row) || archived {
                let digest = SkillScript.digest(script) ?? ""
                if let users = Self.usersAdmission(row, skill: skill, steer: steer, fullMac: fullMac, ownerAuthorized: ownerAuthorized) {
                    // `skill_id` and `script` are for the host's card; it strips the script.
                    return (false, users + ": he reads the script and installs it. Nothing changed.",
                            fields.merging(["needs_user": .bool(true), "reason": .string("users_call"),
                                           "script_digest": .string(digest), "skill_id": .string(registeredName),
                                           "script": script]) { $1 }.merging(would("active", "users_card", now: false)) { $1 })
                }
                admit = "agent"
                reviewed = digest
                fields["script_digest"] = .string(digest)
                fields["admitted_by"] = .string("agent")
            }
            if preview {
                return (true, "Would turn \(skill) on, active, " + (admit == nil ? "yours to turn on" : "its script admitted as yours")
                    + "; its 30-day unused clock restarts.", fields.merging(would("active", "hers", now: true)) { $1 })
            }
            do {
                let result = try await enableSkill(name: registeredName, admittedBy: admit, reviewedDigest: reviewed)
                if result.objectValue?["status"] == .string("active") {
                    do { try await reconcile() }
                    catch { return (false, error.localizedDescription + " app skill.list shows its state now.", fields) }
                }
                let refreshed = try await listSkills() + listManifestSkills()
                let saved = refreshed.first {
                    [$0.objectValue?["id"], $0.objectValue?["name"]].contains(.string(registeredName))
                } ?? .null
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
            return await mark("disabled", "dormant", ["disabledBy": .string("agent")],
                              "Disabled \(skill); it is out of recall, and skill.enable turns it back on.")
        case "delete":
            if state == "trashed" {
                return (true, "\(skill) is already in the trash.", fields.merging(["changed": .bool(false)]) { $1 })
            }
            // Her trash keeps whose "off" it was, so restore can't launder User's disable.
            var marks: [String: JSONValue] = ["trashedAt": .string(ISO8601DateFormatter().string(from: Date()))]
            if on || state == "drafted" || hers { marks["disabledBy"] = .string("agent") }
            return await mark("trashed", "trashed", marks,
                              "Moved \(skill) to the trash: it is off and out of recall, body and entry kept. "
                              + "skill.restore brings it back. Nothing empties the trash; erasing for good is User's.")
        case "rollback":
            guard row["state"] == nil else {
                return (false, "\(skill) is a manifest skill; it carries no script to roll back.", fields)
            }
            do {
                let rolled = try await rollbackScript(id: registeredName, steer: SkillScript.origin(steeredBy: steer), preview: preview)
                if preview {
                    let digest = String((SkillScript.digest(rolled.objectValue?["script"]) ?? "").prefix(12))
                    let users = Self.usersAdmission(rolled.objectValue ?? [:], skill: skill, steer: steer, fullMac: fullMac, ownerAuthorized: ownerAuthorized)
                    return (true, "Would roll \(skill) back to script \(digest), drafted: turning it on is "
                        + (users.map { "User's card (\($0))" } ?? "yours, by skill.enable")
                        + "; its 30-day unused clock restarts when it is turned on.",
                        fields.merging(["would_land_on": .string(digest)]) { $1 }
                            .merging(would("drafted", users == nil ? "hers" : "users_card", now: false)) { $1 })
                }
                try await reconcile()
                let digest = SkillScript.digest(rolled.objectValue?["script"]) ?? ""
                return (true, "Rolled \(skill) back to the script it had before this one (digest \(digest.prefix(12))). "
                    + "It is drafted: it runs again only once skill.enable turns it on.",
                    fields.merging(["script_digest": .string(digest), "state": .string("drafted")]) { $1 })
            } catch SkillsError.unknownVersion {
                return (false, "\(skill) has no earlier script to roll back to; nothing changed.", fields)
            } catch {
                return (false, "Rollback failed: \(error.localizedDescription)." + retry, fields)
            }
        case "restore":
            guard state == "trashed" else {
                return (false, "\(skill) is not in the trash (\(state)). enable or disable it instead.", fields)
            }
            // A script never admitted comes back drafted, so Review and Install apply.
            if row["script"] != nil, !SkillScript.admitted(row) {
                return await mark("draft", "drafted", hers ? ["disabledBy": .string("agent")] : [:],
                                  "Restored \(skill) from the trash as a draft: its script was never turned on. skill.enable asks for it.",
                                  admit: Self.usersAdmission(row, skill: skill, steer: steer, fullMac: fullMac, ownerAuthorized: ownerAuthorized) == nil ? "hers" : "users_card")
            }
            return await mark("disabled", "dormant", hers ? ["disabledBy": .string("agent")] : [:],
                              "Restored \(skill) from the trash, switched off. "
                              + (hers ? "skill.enable turns it on." : "User had turned it off, so turning it on is his."),
                              admit: hers ? "hers" : "users")
        default:
            return (false, "No skill_manage verb is called \(verb).", [:])
        }
    }

    /// Skills are guidance: a body, triggers and a description, granting no
    /// tool, permission or approval (save_skill's contract). A manifest that
    /// declares permissions, tools or a sign-in, or is a tool or connector
    /// pack, could reach past that, so installing one stays User's.
    private static func reachPastGuidance(_ manifest: [String: JSONValue]) -> String? {
        var reach: [String] = []
        if case .array(let permissions)? = manifest["permissions"], !permissions.isEmpty {
            reach.append("permissions (\(permissions.map { SkillMutation.pyStr($0) }.joined(separator: ", ")))")
        }
        if case .array(let tools)? = manifest["tools"], !tools.isEmpty { reach.append("tools") }
        if let oauth = manifest["oauth"], oauth != .null { reach.append("a sign-in") }
        let type = SkillMutation.pyStrTruthyOr(manifest["type"], "").lowercased()
        if ["tool", "connector"].contains(type) { reach.append("a \(type) pack") }
        return reach.isEmpty ? nil : reach.joined(separator: ", ")
    }

    public func manifestDirectory(for entry: [String: JSONValue]) -> URL {
        let name = SkillMutation.pyStrTruthyOr(entry["name"], "")
        let fallback = root.appendingPathComponent("skills/\(name)")
        let raw = SkillMutation.pyStrTruthyOr(entry["path"], "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return fallback }
        let candidate = URL(fileURLWithPath: raw).standardizedFileURL
        let allowedRoots = [root.appendingPathComponent("skills").standardizedFileURL,
                            legacyManifestPath.deletingLastPathComponent().standardizedFileURL]
        if allowedRoots.contains(where: { candidate.path == $0.path || candidate.path.hasPrefix($0.path + "/") }),
           FileManager.default.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) { return candidate }
        return fallback
    }

    private func registerSkillBody(_ row: [String: JSONValue]) async throws {
        guard case .string(let name)? = row["name"], case .string(let path)? = row["bodyPath"] else {
            throw SkillsError.unknownSkill(String(describing: row["name"]))
        }
        try await withRegistryLock { [self] in
            var rows = try loadRegistryForMutation()
            guard !rows.contains(where: { $0.objectValue?["id"] == .string(name) || $0.objectValue?["name"] == .string(name) }) else { return }
            var registered = row
            registered.removeValue(forKey: "source")
            registered["bodyPath"] = .string(path)
            registered["createdAt"] = .string(SkillMutation.nowISO(now))
            registered["updatedAt"] = registered["createdAt"]
            try await recordSkillVersion(.object(registered), reason: "registered-body")
            rows.append(.object(registered))
            try await persistence.writeJSON(.array(rows), to: registryPath)
        }
    }

    /// Read-only admission for the whole batch, before the pack host writes anything.
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
        for item in items {
            let violations = SkillBodyHygiene.violations(in: Self.packSkillBody(item, packID: packID).content)
            guard violations.isEmpty else {
                throw SkillsError.invalidSkillBody(SkillBodyHygiene.failureMessage(for: violations))
            }
            if let script = item["script"], script != .null { _ = try SkillScript.normalized(script) }
        }
    }

    public func installPackSkills(
        _ items: [[String: JSONValue]],
        installID: String,
        packID: String,
        nowISO: String
    ) async throws {
        guard !items.isEmpty else { return }
        let path = root.appendingPathComponent("skills/registry.json")
        let bodiesDir = root.appendingPathComponent("skills/bodies", isDirectory: true)
        try await withRegistryLock { [self] in
            try preflightPackSkills(items, installID: installID, packID: packID)
            var rows = try loadRegistryForMutation().compactMap { $0.objectValue }
            let ids = Set(items.map { Self.packSkillID($0).lowercased() })
            rows.removeAll {
                Self.packString($0, "capabilityPackInstallId") == installID
                    && ids.contains(Self.packString($0, "id").lowercased())
            }
            try FileManager.default.createDirectory(at: bodiesDir, withIntermediateDirectories: true)
            for item in items {
                let skillID = Self.packSkillID(item)
                let (name, description, content) = Self.packSkillBody(item, packID: packID)
                let bodyPath = bodiesDir.appendingPathComponent("\(skillID).md")
                try await writeBody(content, to: bodyPath)
                var triggers: [JSONValue] = [.string(name)]
                if case .array(let rawTriggers)? = item["triggers"], !rawTriggers.isEmpty {
                    triggers = rawTriggers
                }
                var row: [String: JSONValue] = [
                    "id": .string(skillID),
                    "name": .string(name),
                    "description": .string(description),
                    "triggers": .array(triggers),
                    "kind": .string(Self.packString(item, "kind").isEmpty ? "skill" : Self.packString(item, "kind")),
                    "status": .string(Self.packString(item, "status").isEmpty ? "active" : Self.packString(item, "status")),
                    "autoCreated": .bool(false),
                    "sourceRunId": .null,
                    "bodyPath": .string(bodyPath.path),
                    "createdAt": .string(nowISO),
                    "updatedAt": .string(nowISO),
                    "useCount": .int(0),
                    "lastUsedAt": .null,
                    "installedByPack": .string(packID),
                    "capabilityPackInstallId": .string(installID),
                    "origin": SkillScript.origin(pack: packID),
                ]
                if let script = item["script"], script != .null {
                    row["script"] = try SkillScript.normalized(script)
                    SkillScript.settle(&row, before: nil, origins: [row["origin"]])
                }
                rows.append(row)
            }
            try await persistence.writeJSON(.array(rows.map { .object($0) }), to: path)
        }
    }

    public func removePackSkills(
        _ ids: [String],
        installID: String,
        packID: String
    ) async throws {
        let path = root.appendingPathComponent("skills/registry.json")
        let bodiesDir = root.appendingPathComponent("skills/bodies", isDirectory: true).standardizedFileURL
        try await withRegistryLock { [self] in
            var rows = try loadRegistryForMutation().compactMap { $0.objectValue }
            var removedBodyPaths: [URL] = []
            rows.removeAll { row in
                let marked = Self.packString(row, "capabilityPackInstallId") == installID || Self.packString(row, "installedByPack") == packID
                let matches = ids.isEmpty || ids.contains(Self.packString(row, "id"))
                guard marked && matches else { return false }
                let body = Self.packString(row, "bodyPath")
                if !body.isEmpty {
                    let bodyURL = URL(fileURLWithPath: body).standardizedFileURL
                    if bodyURL.path == bodiesDir.path || bodyURL.path.hasPrefix(bodiesDir.path + "/") {
                        removedBodyPaths.append(bodyURL)
                    }
                }
                return true
            }
            try await persistence.writeJSON(.array(rows.map { .object($0) }), to: path)
            for bodyPath in removedBodyPaths {
                try? FileManager.default.removeItem(at: bodyPath)
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

    private static func packSkillBody(
        _ item: [String: JSONValue], packID: String
    ) -> (name: String, description: String, content: String) {
        let name = packString(item, "name").isEmpty ? packSkillID(item) : packString(item, "name")
        let description = packString(item, "description").isEmpty
            ? "Installed by capability pack \(packID)." : packString(item, "description")
        let content = packString(item, "content").isEmpty
            ? "# \(name)\n\n\(description)\n" : packString(item, "content")
        return (name, description, content)
    }

    private static func packString(_ row: [String: JSONValue], _ key: String) -> String {
        SkillMutation.pyStrOptional(row[key]) ?? ""
    }

    // MARK: - Mutation helpers

    private var skillBodiesDir: URL { root.appendingPathComponent("skills/bodies", isDirectory: true) }

    private func historyPath(for id: String) -> URL {
        let identity = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return historyDir.appendingPathComponent("by-id", isDirectory: true).appendingPathComponent("\(identity).json")
    }

    private func loadSkillHistory(skillId: String) throws -> [JSONValue] {
        let path = historyPath(for: skillId)
        let canonical = FileManager.default.fileExists(atPath: path.path)
        // Read pre-identity history only for migration, selecting this owner's rows.
        let source = canonical ? path : historyDir.appendingPathComponent("\(SkillMutation.slugify(skillId)).json")
        return try loadHistoryStrict(source).filter { value in
            guard case .object(let row) = value, row["skillId"] == .string(skillId),
                  case .object(let skill)? = row["skill"],
                  SkillMutation.pyStrTruthyOr(skill["id"], SkillMutation.pyStrTruthyOr(skill["name"], "")) == skillId else {
                if canonical { throw SkillsError.historyUnavailable("Recorded version does not belong to this skill.") }
                return false
            }
            return true
        }
    }

    /// Additive, bounded evidence owned by Skills. Nothing consults this data
    /// during chat or background cognition; only an explicit restore reads it.
    private func recordSkillVersion(_ skill: JSONValue, reason: String) async throws {
        guard case .object(let object) = skill else {
            throw SkillsError.historyUnavailable("Cannot version a malformed skill row.")
        }
        let skillId = SkillMutation.pyStrTruthyOr(
            object["id"],
            SkillMutation.pyStrTruthyOr(object["name"], "")
        )
        guard !skillId.isEmpty else {
            throw SkillsError.historyUnavailable("Cannot version a skill without an identifier.")
        }
        var bodyText: String?
        if let path = confinedBodyPath(for: object, skillId: skillId),
           let data = try? Data(contentsOf: path), data.count <= 65_536 {
            bodyText = String(data: data, encoding: .utf8)
        }
        let bodyHash = bodyText.map {
            SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        } ?? ""
        let path = historyPath(for: skillId)
        let capturedBody = bodyText
        let capturedSkill = skill
        try await persistence.withFileLock(path) {
            var rows = try self.loadSkillHistory(skillId: skillId)
            var row: [String: JSONValue] = [
                "versionId": .string(UUID().uuidString.lowercased()),
                "skillId": .string(skillId),
                "reason": .string(String(reason.prefix(80))),
                "createdAt": .string(SkillMutation.nowISO(self.now)),
                "bodySHA256": .string(bodyHash),
                "skill": capturedSkill,
            ]
            if let capturedBody { row["body"] = .string(capturedBody) }
            if let digest = SkillScript.digest(object["script"]) { row["scriptDigest"] = .string(digest) }
            rows.append(.object(row))
            // Registry edits are reversible versions too. Keep current,
            // previous and last clean only (`CapabilityLifecycle`).
            let kept = CapabilityLifecycle.keptVersions(try rows.map {
                let digest = SkillMutation.pyStrOptional($0.objectValue?["scriptDigest"])
                let fields = ["id", "name", "description", "triggers", "kind", "status", "bodyPath", "origin", "admission"]
                    + SkillMutation.agentMarks
                let metadata = JSONValue.object(($0.objectValue?["skill"]?.objectValue ?? [:]).filter { fields.contains($0.key) })
                let identity = try metadata.serialize(pretty: false)
                return ((digest ?? "") + "|" + (SkillMutation.pyStrOptional($0.objectValue?["bodySHA256"]) ?? "") + "|" + identity, digest)
            }, recent: 2, clean: SkillMutation.pyStrOptional(object["lastCleanDigest"]))
            rows = kept.map { rows[$0] }
            try await self.persistence.writeJSON(.array(rows), to: path)
        }
    }

    private func loadHistoryStrict(_ path: URL) throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        do {
            guard case .array(let rows) = try JSONValue.parse(Data(contentsOf: path)) else {
                throw SkillsError.historyUnavailable("Skill history is not a JSON array.")
            }
            return rows
        } catch let error as SkillsError {
            throw error
        } catch {
            throw SkillsError.historyUnavailable("Skill history is unreadable; mutation was refused.")
        }
    }

    /// Mutation reads distinguish a genuinely absent registry (fresh install)
    /// from an existing registry whose bytes or root shape are unusable. The
    /// tolerant read path is appropriate for display, but using its empty
    /// fallback inside a read-modify-write can replace every registered skill
    /// after one malformed/truncated read.
    private func loadRegistryForMutation() throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: registryPath.path) else { return [] }
        do {
            return try SkillsRegistry.decode(JSONValue.parse(Data(contentsOf: registryPath)))
        } catch let error as SkillsError {
            throw error
        } catch {
            throw SkillsError.invalidRegistry(
                "Skill registry is unreadable; mutation was refused."
            )
        }
    }

    private func confinedBodyPath(for skill: [String: JSONValue], skillId: String) -> URL? {
        let candidate: URL
        if case .string(let raw)? = skill["bodyPath"], !raw.isEmpty {
            candidate = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        } else {
            candidate = skillBodiesDir.appendingPathComponent("\(skillId).md")
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let bodiesRoot = skillBodiesDir.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(bodiesRoot.path + "/") else { return nil }
        return resolved
    }

    private var activity: SkillActivityEmitter {
        SkillActivityEmitter(persistence: persistence,
                             activityPath: root.appendingPathComponent("activity/events.jsonl"),
                             now: now)
    }

    /// flock the legacy registry path around an async R-M-W. `persistence` is
    /// concretely `SwiftNativePersistenceCore`, which exposes withFileLock; the
    /// flock target (`<registryPath>.lock`) is the SAME path the Python
    /// `with file_lock(self.skills_path)` locks.
    private func withRegistryLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await persistence.withFileLock(registryPath, body)
    }

    private func withManifestLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await persistence.withFileLock(dataRootManifestPath, body)
    }

    /// Write a skill body .md, creating the bodies dir. Mirrors
    /// `body_path.write_text(content)` (chmod left to FileManager defaults; the
    /// daemon does not chmod body files).
    private func writeBody(_ content: String, to path: URL) async throws {
        let hygieneViolations = SkillBodyHygiene.violations(in: content)
        if !hygieneViolations.isEmpty {
            throw SkillsError.invalidSkillBody(SkillBodyHygiene.failureMessage(for: hygieneViolations))
        }
        // 2026-09-06: the reader (`confinedBodyPath`) has always refused a body
        // outside the bodies dir; the WRITER created parents and wrote wherever
        // the composed path pointed. Every caller builds that path from an id
        // or a caller-supplied name, so this is the last stop before an escape
        // becomes a file. Resolve the PARENT — the body itself need not exist.
        let parent = path.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let bodiesRoot = skillBodiesDir.standardizedFileURL.resolvingSymlinksInPath()
        guard parent.path == bodiesRoot.path,
              SkillMutation.isSafeSkillID(path.deletingPathExtension().lastPathComponent) else {
            throw SkillsError.invalidSkillBody(
                "Skill body path escapes the skill bodies directory; the write was refused."
            )
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.data(using: .utf8)?.write(to: path, options: .atomic)
    }

    /// Path-confined body unlink. Failed cleanup leaves an inactive registry row.
    private func cleanupBodyFile(_ bodyPathRaw: String, skillId: String, displayName: String) async -> Bool {
        let bodyPath = URL(fileURLWithPath: (bodyPathRaw as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        let bodiesRoot = skillBodiesDir.standardizedFileURL.resolvingSymlinksInPath()
        do {
            let isInside = bodyPath.path == bodiesRoot.path || bodyPath.path.hasPrefix(bodiesRoot.path + "/")
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: bodyPath.path, isDirectory: &isDir)
            guard exists else { return true }
            guard !isDir.boolValue, isInside else { return false }
            try FileManager.default.removeItem(at: bodyPath)
            return true
        } catch {
            try? await activity.record(kind: "skill", title: "Skill body cleanup skipped", detail: displayName,
                                       status: "warn",
                                       payload: .object(["skillId": .string(skillId), "error": .string(String(describing: error))]))
            return false
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

// MARK: - One-time registry repairs

/// One-time skill registry repairs, run at launch the house way: a
/// version-stamped marker under skills/migrations, written only once the pass
/// is done, so a failed one runs again.
public enum SkillRegistryMigration {
    /// The old auto-learner is retired (skills-as-code 4b): every learned-*
    /// skill it left is archived through the lifecycle, never deleted.
    public static func runIfNeeded(dataRoot: URL) async {
        let marker = dataRoot.appendingPathComponent("skills/migrations/archive-learned-v2.done")
        guard !FileManager.default.fileExists(atPath: marker.path),
              let entries = try? InstalledSkillInventory.entries(dataRoot: dataRoot) else { return }
        let client = SwiftNativeSkillsClient(root: dataRoot)
        for entry in entries where entry.id.hasPrefix("learned-") && entry.row["source"] != .string("persona_body") {
            do { try await client.archive(name: entry.id, why: "the old auto-learner that made it is retired") } catch { return }
        }
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: marker)
    }
}

// MARK: - Factory

/// Returns the SwiftNative skills client.
public func makeSkillsClient(root: URL) -> any SkillsClient {
    return SwiftNativeSkillsClient(root: root)
}
