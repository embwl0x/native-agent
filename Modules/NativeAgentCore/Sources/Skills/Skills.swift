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
        let raw = await persistence.readJSON(registryPath, defaultValue: .array([]))
        let registry: [JSONValue]
        if case .array(let arr) = raw {
            registry = arr.compactMap { entry in
                guard case .object(let obj) = entry else { return entry }
                return registrySkillBodyIsClean(obj) ? entry : nil
            }
        } else {
            registry = []
        }

        // Mirror SwiftToolDispatcher.impl_list_skills (the chat-tool path
        // Agent uses): the registry is one of THREE sources. Body markdown
        // files under <root>/skills/bodies/ and <personaRoot>/skills/bodies/
        // are independently usable skills that have never been promoted
        // into the registry. Without merging them, the Skills tab UI shows
        // a different surface than the agent sees, and a fresh repo with
        // only persona bodies looks like "no skills" to the user.
        var seen: Set<String> = []
        for entry in registry {
            if case .object(let obj) = entry,
               case .string(let name)? = obj["name"], !name.isEmpty {
                seen.insert(name)
            }
        }
        let runtimeBodies = Self.scanSkillBodies(
            directory: root.appendingPathComponent("skills/bodies", isDirectory: true),
            source: "runtime_body"
        )
        let personaBodies = Self.scanSkillBodies(
            directory: defaultPersonaRoot(dataRoot: root)
                .appendingPathComponent("skills/bodies", isDirectory: true),
            source: "persona_body"
        )
        var merged = registry
        for row in (runtimeBodies + personaBodies) {
            guard case .object(let obj) = row,
                  case .string(let name)? = obj["name"],
                  !name.isEmpty,
                  !seen.contains(name) else {
                continue
            }
            seen.insert(name)
            merged.append(row)
        }
        return SkillsRegistry.sortedDescending(merged)
    }

    /// Mirrors `SwiftToolDispatcher.scanSkillBodies` — produces skill rows
    /// whose JSON shape decodes cleanly into the Mac UI's `SkillRecord` model
    /// (id+name+description+triggers required), with a `source` tag so the
    /// UI can suppress destructive actions (enable/disable/delete only apply
    /// to runtime-registry rows; body-only skills are read-only here).
    static func scanSkillBodies(directory: URL, source: String) -> [JSONValue] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return files
            .filter { url in
                guard url.pathExtension == "md" else { return false }
                // Skip directories that happen to end in `.md`, and any other
                // non-regular file types (symlinks to nothing, sockets, etc.).
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                let name = url.deletingPathExtension().lastPathComponent
                let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                guard SkillBodyHygiene.violations(in: body).isEmpty else {
                    return nil
                }
                let firstUsefulLine = SkillBodyHygiene.firstUsefulLine(in: body) ?? "Skill body."
                return .object([
                    "id": .string(name),
                    "name": .string(name),
                    "description": .string(String(firstUsefulLine.prefix(240))),
                    "triggers": .array([]),
                    "kind": .string("skill"),
                    "status": .string("active"),
                    "autoCreated": .bool(false),
                    "bodyPath": .string(url.path),
                    "source": .string(source),
                ])
            }
    }

    private func registrySkillBodyIsClean(_ skill: [String: JSONValue]) -> Bool {
        var candidates: [URL] = []
        if case .string(let rawPath)? = skill["bodyPath"] {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                candidates.append(URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath))
            }
        }
        if case .string(let id)? = skill["id"], !id.isEmpty {
            candidates.append(skillBodiesDir.appendingPathComponent("\(id).md"))
        }

        var seen: Set<String> = []
        for url in candidates where seen.insert(url.path).inserted {
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return SkillBodyHygiene.violations(in: body).isEmpty
        }
        return true
    }

    public func listManifestSkills() async throws -> [JSONValue] {
        // Read both files in the daemon's iteration order: [legacy, dataRoot].
        // A missing file → the read returns the default object, whose `skills`
        // sub-object is absent → SkillManifestRegistry.merge skips it (matching
        // the daemon's read_json(path, {"schemaVersion":1,"skills":{}}) +
        // `if not isinstance(data.get("skills"), dict): continue`).
        let defaultDoc: JSONValue = .object(["schemaVersion": .int(1), "skills": .object([:])])
        let legacyRaw = await persistence.readJSON(legacyManifestPath, defaultValue: defaultDoc)
        let dataRootRaw = await persistence.readJSON(dataRootManifestPath, defaultValue: defaultDoc)
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
    private func manifestRegisteredSkillsObject() async -> JSONValue {
        let defaultDoc: JSONValue = .object(["schemaVersion": .int(1), "skills": .object([:])])
        let legacyRaw = await persistence.readJSON(legacyManifestPath, defaultValue: defaultDoc)
        let dataRootRaw = await persistence.readJSON(dataRootManifestPath, defaultValue: defaultDoc)
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
        let skillId = SkillMutation.unquote(SkillMutation.string(body, "id")).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await withRegistryLock { () throws -> JSONValue in
            var skills = try self.loadRegistryForMutation()
            for index in skills.indices {
                guard case .object(var skill) = skills[index] else { continue }
                let sid = SkillMutation.pyStr(skill["id"] ?? .null)
                let sname = SkillMutation.pyStr(skill["name"] ?? .null)
                if sid != skillId && sname != skillId { continue }
                try await self.recordSkillVersion(.object(skill), reason: "before-update")
                // Patch only the allowed keys present in the body.
                if case .object(let bodyObj) = body {
                    for key in ["name", "description", "triggers", "kind", "status"] where bodyObj[key] != nil {
                        skill[key] = bodyObj[key]
                    }
                }
                skill["updatedAt"] = .string(SkillMutation.nowISO(self.now))
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
            // Commit the canonical registry change before removing the body.
            // If registry persistence fails, the still-registered skill must
            // not be left pointing at a body we already destroyed. A later
            // body cleanup failure is safer: the registry remains truthful
            // and the orphaned file is recoverable from version history.
            try await self.persistence.writeJSON(.array(kept), to: self.registryPath)
            // Body-file cleanup, path-confined to skill_bodies_dir (mirrors
            // delete_skill L26883-26891; an unreadable/outside path is skipped
            // with a "warn" activity event but the delete still proceeds).
            if case .object(let robj) = removedSkill,
               case .string(let bodyPathRaw)? = robj["bodyPath"], !bodyPathRaw.isEmpty {
                await self.cleanupBodyFile(bodyPathRaw, skillId: skillId, displayName: SkillMutation.pyStrTruthyOr(robj["name"], skillId))
            }
            let displayName = SkillMutation.pyStrTruthyOr(removedSkill.objectValue?["name"], skillId)
            return (.object(["id": .string(skillId), "deleted": .bool(true)]), displayName)
        }
        if let hit = legacy {
            try await activity.record(kind: "skill", title: "Skill deleted", detail: hit.displayName,
                                      status: "ok", payload: .object(["skillId": .string(skillId)]))
            return hit.result
        }
        // Manifest fallback (route L52412-52421): pop from the merged registry,
        // write the merged dict back to the data-root manifest file.
        return try await withManifestLock { () throws -> JSONValue in
            var mreg = await self.manifestRegisteredSkillsObject()
            guard case .object(var mregObj) = mreg, case .object(var skills)? = mregObj["skills"],
                  let entry = skills[skillId] else {
                throw SkillsError.unknownSkill(skillId)
            }
            skills.removeValue(forKey: skillId)
            mregObj["skills"] = .object(skills)
            mreg = .object(mregObj)
            try await self.persistence.writeJSON(mreg, to: self.dataRootManifestPath)
            let displayName = SkillMutation.pyStrTruthyOr(entry.objectValue?["name"], skillId)
            try await self.activity.record(kind: "skill", title: "Manifest skill deleted", detail: displayName,
                                           status: "ok", payload: .object(["skillId": .string(skillId)]))
            return .object(["id": .string(skillId), "deleted": .bool(true), "source": .string("manifest")])
        }
    }

    public func enableSkill(name rawName: String) async throws -> JSONValue {
        try await flipStatus(name: rawName, legacyStatus: "active",
                             allowedManifestStates: ["drafted", "dormant", "installed"],
                             targetManifestState: "installed",
                             requirement: "drafted, dormant, or installed")
    }

    public func disableSkill(name rawName: String) async throws -> JSONValue {
        try await flipStatus(name: rawName, legacyStatus: "disabled",
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
        allowedManifestStates: Set<String>,
        targetManifestState: String,
        requirement: String
    ) async throws -> JSONValue {
        let name = SkillMutation.unquote(rawName)
        do {
            return try await updateSkill(body: .object(["id": .string(name), "status": .string(legacyStatus)]))
        } catch SkillsError.unknownSkill {
            // Manifest fallback.
            return try await withManifestLock { () throws -> JSONValue in
                var mreg = await self.manifestRegisteredSkillsObject()
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

    public func createSkill(body: JSONValue) async throws -> JSONValue {
        let obj = body.objectValue ?? [:]
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
            let existingIds = Set(skills.map { SkillMutation.pyStr($0.objectValue?["id"] ?? .null) })
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
                existing["description"] = .string(description)
                existing["triggers"] = .array(triggers.map { .string($0) })
                existing["updatedAt"] = .string(now)
                // body.get("status") or existing.get("status") or "active"
                // (truthiness: a present-but-empty status falls through).
                let bodyStatus = SkillMutation.pyTruthyStrOptional(obj["status"])
                let existingStatus = SkillMutation.pyTruthyStrOptional(existing["status"])
                existing["status"] = .string(bodyStatus ?? existingStatus ?? "active")
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
            let record: JSONValue = .object([
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
            ])
            try await self.recordSkillVersion(record, reason: "created")
            skills.append(record)
            try await self.persistence.writeJSON(.array(skills), to: self.registryPath)
            return record
        }
    }

    public func listSkillVersions(id rawId: String) async throws -> [JSONValue] {
        let skillId = SkillMutation.unquote(rawId).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skillId.isEmpty else { throw SkillsError.unknownSkill(skillId) }
        let path = historyPath(for: skillId)
        return try await persistence.withFileLock(path) {
            let rows = try self.loadHistoryStrict(path)
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
            let bodyPath = self.skillBodiesDir.appendingPathComponent("\(skillId).md")
            let priorBody = try? Data(contentsOf: bodyPath)
            let bodyExisted = FileManager.default.fileExists(atPath: bodyPath.path)
            if let capturedBody {
                try await self.writeBody(capturedBody, to: bodyPath)
                restored["bodyPath"] = .string(bodyPath.path)
            }
            restored["updatedAt"] = .string(SkillMutation.nowISO(self.now))
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

    // MARK: - Mutation helpers

    private var skillBodiesDir: URL { root.appendingPathComponent("skills/bodies", isDirectory: true) }

    private func historyPath(for id: String) -> URL {
        historyDir.appendingPathComponent("\(SkillMutation.slugify(id)).json")
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
            var rows = try self.loadHistoryStrict(path)
            var row: [String: JSONValue] = [
                "versionId": .string(UUID().uuidString.lowercased()),
                "skillId": .string(skillId),
                "reason": .string(String(reason.prefix(80))),
                "createdAt": .string(SkillMutation.nowISO(self.now)),
                "bodySHA256": .string(bodyHash),
                "skill": capturedSkill,
            ]
            if let capturedBody { row["body"] = .string(capturedBody) }
            rows.append(.object(row))
            if rows.count > 100 { rows.removeFirst(rows.count - 100) }
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
            guard case .array(let rows) = try JSONValue.parse(Data(contentsOf: registryPath)) else {
                throw SkillsError.invalidRegistry(
                    "Skill registry is not a JSON array; mutation was refused."
                )
            }
            return rows
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

    /// Path-confined body unlink mirroring delete_skill L26883-26891. On any
    /// failure, emit a "warn" activity event and proceed (do NOT throw — the
    /// daemon swallows the exception inside a try/except and still deletes).
    private func cleanupBodyFile(_ bodyPathRaw: String, skillId: String, displayName: String) async {
        let bodyPath = URL(fileURLWithPath: (bodyPathRaw as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        let bodiesRoot = skillBodiesDir.standardizedFileURL.resolvingSymlinksInPath()
        do {
            let isInside = bodyPath.path == bodiesRoot.path || bodyPath.path.hasPrefix(bodiesRoot.path + "/")
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: bodyPath.path, isDirectory: &isDir)
            if exists && !isDir.boolValue && isInside {
                try FileManager.default.removeItem(at: bodyPath)
            }
        } catch {
            try? await activity.record(kind: "skill", title: "Skill body cleanup skipped", detail: displayName,
                                       status: "warn",
                                       payload: .object(["skillId": .string(skillId), "error": .string(String(describing: error))]))
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
