import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Skills
//
// SwiftNativeSkillsClient serves the skills read and mutation surfaces
// directly from local registry files.
//
//   • GET /v1/skills           → NativeClient.getSkills()        (line ~4077)
//   • GET /v1/skills/manifest  → NativeClient.readSkillRegistry() (line ~5349,
//                                 HTTP-first then filesystem fallback)
//
// The list path mirrors Runtime.list_skills EXACTLY:
//   1. read skills/registry.json (default []),
//   2. RETURN sorted by str(updatedAt | createdAt | "") DESC.
//   (No write-back — list_skills is a pure read, unlike list_workflows.)
//
// The manifest path mirrors Runtime.manifest_registered_skills + the route's
// reshape:
//   1. merge TWO registry files — the legacy
//        ~/Library/Application Support/NativeAgent/skills/manifest_registry.json
//      then the data-root
//        <root>/skills/manifest_registry.json
//      (data-root entries win on name collision; each entry is dict-keyed by
//       skill name and gets sourceRoot/registryPath defaulted to its file's
//       parent/path),
//   2. RESHAPE the merged {name: entry} dict into a list of
//        [{"name": name, **entry}, ...]  — the route's own transform.
//
// WRITE/MUTATION routes — PORTED wave 32 W15 (2026-06-01), closing the §6.55
// reopen prereq ("port them now that cross-process flock exists"):
//   POST /v1/skills/update          (update_skill)         → updateSkill
//   POST /v1/skills/delete          (delete_skill + route's manifest fallback) → deleteSkill
//   POST /v1/skills/{name}/enable   (route enable handler)  → enableSkill
//   POST /v1/skills/{name}/disable  (route disable handler) → disableSkill
//   POST /v1/skills                 (create_skill)          → createSkill
//
// These mutate skills/registry.json + skills/manifest_registry.json. The
// Swift impl wraps every read-modify-write in `withFileLock(registryPath, …)`
// (and the manifest path for the manifest-fallback branches).
//
// ACTIVITY-FEED PARITY: update_skill + delete_skill fire
// `record_activity("skill", …)` → an append to <dataRoot>/activity/events.jsonl
// (a flocked JSONL append, redacted via redact_secret_text/value). The Swift
// mutations reproduce that emission byte-for-byte (SkillActivityEmitter below,
// using the NativeAgentCore-owned redaction contract and the same envelope keys
// and flocked append). WITHOUT
// this, flipping `.skills` would silently drop skill-mutation events from the
// /v1/activity feed (a side-effect leak). create_skill does NOT fire
// record_activity in Python, so the Swift createSkill doesn't either.
//
// Mobile callers must route to Swift-native Mac-side handling; skill lifecycle
// operations do not have a legacy runtime fallback.
//
// TRUST-GATE 403 PARITY (wave 34 W19, 2026-06-02) — AUDIT DISPOSITION:
//   The skill mutation routes (POST /v1/skills/update, /delete, /{name}/enable,
//   /{name}/disable, and create POST /v1/skills) carry NO Runtime-level trust
//   gate: update_skill / delete_skill / create_skill (the retired daemon
//   L26663 / L26960 / L32984) have no _full_mac_active check, no trust_policy()
//   gate, no permissionLevel check — they just flock + R-M-W. Their ONLY 403
//   conditions are TWO HTTP-TRANSPORT guards in do_POST (L51976):
//     1. _check_origin()           → 403 forbidden (CSRF/Origin header gate).
//     2. _mobile_admin_route_denied → 403 mobile_route_forbidden, which fires
//        when `not _client_is_loopback() AND a valid remote pairing token`.
//        Every skill mutation POST falls through _mobile_route_allowed's POST
//        allowlist (none of /v1/skills* are in it, L51020-51059), so a
//        paired-mobile remote caller is denied on ALL of them.
//   BOTH guards are TRANSPORT-LAYER concerns keyed off the HTTP client address
//   + Authorization header. The SwiftNative impl below is invoked ONLY in-
//   process by the local Mac NativeClient cutover seam (verified wave 34: the
//   ONLY callers are SkillLifecycleView/ContentView → AppModel → NativeClient;
//   iOS never imports Skills and stays HTTP). The in-process caller is the
//   loopback-equivalent owner BY CONSTRUCTION — there is no remote socket and
//   no pairing token in this path — so neither 403 condition is reachable here.
//   PORTING a mobile-pairing-token check into this client would therefore be
//   DEAD CODE guarding a caller that structurally cannot be a remote/mobile one.
//   This is the SAME disposition the ToolRegistry promote/quarantine port took
//   (those routes are ALSO in the mobile denylist; swiftPromoteTool /
//   swiftQuarantineTool in NativeClient carry no 403 gate). The 403 enforcement
//   stays where it belongs — on the remote boundary — and is NOT duplicated
//   into the local-owner-only Swift seam.
//   (The absence of a 403 check here is a DELIBERATE disposition, not the
//   oversight wave 34's brief premise suspected.) See CUTOVER_PLAN.md §6.97.
//
// The list and manifest paths are pure reads. The mutation paths use the same
// file locks as other native registry writers.

// MARK: - Skills registry shaping (mirror Runtime.list_skills)

public enum SkillsRegistry {
    /// Retired truthiness for a scalar/collection JSONValue (matches `bool(x)`):
    /// "" / 0 / 0.0 / false / null / [] / {} are falsey.
    private static func isTruthy(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// Python `str(value)` for the scalar JSON types that can appear in a
    /// timestamp field (mirrors `str(None)`/`str(True)`/`str(123)` etc.).
    private static func pyStr(_ v: JSONValue) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .array, .object: return ""  // not expected for timestamp fields
        }
    }

    /// Sort key: `str(item.get("updatedAt") or item.get("createdAt") or "")`.
    /// Empty string sorts last in DESC order. Mirrors Python's `or` truthiness
    /// across non-string scalars exactly (a truthy numeric/bool timestamp sorts
    /// under its `str(...)` form, not "").
    public static func sortKey(_ value: JSONValue) -> String {
        guard case .object(let obj) = value else { return "" }
        if let u = obj["updatedAt"], isTruthy(u) { return pyStr(u) }
        if let c = obj["createdAt"], isTruthy(c) { return pyStr(c) }
        return ""
    }

    /// Full mirror of Runtime.list_skills:
    ///   sorted(skills, key=lambda i: str(i.get("updatedAt") or i.get("createdAt") or ""), reverse=True)
    /// Python's sorted() is stable; Swift's sort is not, so we tag the index to
    /// emulate stability on equal keys.
    public static func sortedDescending(_ skills: [JSONValue]) -> [JSONValue] {
        skills.enumerated()
            .sorted { lhs, rhs in
                let lk = sortKey(lhs.element)
                let rk = sortKey(rhs.element)
                if lk != rk { return lk > rk }      // DESC
                return lhs.offset < rhs.offset       // stable tie-break
            }
            .map { $0.element }
    }
}

// MARK: - Manifest registry merge + reshape (mirror manifest_registered_skills + route)

public enum SkillManifestRegistry {
    /// Faithful port of Runtime.manifest_registered_skills MERGE, parameterized
    /// over the two input files' raw contents so it is purely functional and
    /// testable. `entries` is ordered [legacy, dataRoot]; later files win on a
    /// name collision (mirrors the Python loop's `merged["skills"][name] = item`
    /// overwrite as it walks [legacy_path, self.manifest_skills_path]).
    ///
    /// - Parameter entries: list of (rawJSON, parentPath, filePath) tuples in
    ///   the SAME order the daemon iterates them. A file whose root is not an
    ///   object, or whose `skills` is not an object, is skipped (matches the
    ///   `continue` guards). Each surviving entry value is copied and gets
    ///   `sourceRoot` (defaulted to its file's parent dir) and `registryPath`
    ///   (defaulted to its file path) — only when those keys are absent
    ///   (setdefault semantics).
    ///
    /// - Returns: an ORDER-PRESERVING list of (name, mergedEntry) pairs. A
    ///   colliding name updates the value IN PLACE without moving its key's
    ///   position — exactly Python dict `merged[name] = item` semantics, where
    ///   re-assigning an existing key keeps its original insertion order.
    ///   This is what the GET /v1/skills/manifest route's
    ///   `for k, v in merged["skills"].items()` iterates over, so preserving the
    ///   order keeps the emitted list byte-order-equivalent to the daemon
    ///   (gpt-5.5 review finding #2, 2026-06-01).
    public static func merge(
        entries: [(raw: JSONValue, parentPath: String, filePath: String)]
    ) -> [(name: String, entry: JSONValue)] {
        var order: [String] = []
        var byName: [String: JSONValue] = [:]
        for (raw, parentPath, filePath) in entries {
            guard case .object(let root) = raw else { continue }
            guard let skillsV = root["skills"], case .object(let skills) = skillsV else { continue }
            // Python dict iteration over `data["skills"].items()` is insertion
            // order. JSONValue.object backs onto a Swift Dictionary which is
            // unordered, so the per-FILE ordering of brand-new names within one
            // file is not recoverable here. The cross-FILE order (legacy before
            // data-root) and the stable-position-on-collision rule — the parts
            // the route's emitted list actually depends on for a colliding skill
            // name — ARE preserved. Within a single file, names are visited in
            // sorted order for determinism.
            for name in skills.keys.sorted() {
                guard case .object(var entry) = skills[name]! else { continue }  // not a dict → skip
                if entry["sourceRoot"] == nil { entry["sourceRoot"] = .string(parentPath) }
                if entry["registryPath"] == nil { entry["registryPath"] = .string(filePath) }
                if byName[name] == nil { order.append(name) }  // first-seen position
                byName[name] = .object(entry)                  // collision updates in place
            }
        }
        return order.map { (name: $0, entry: byName[$0]!) }
    }

    /// The route's reshape:
    ///   [{"name": k, **v} for k, v in merged["skills"].items()]
    /// Consumes the order-preserving merge output so the emitted list matches
    /// the daemon's iteration order.
    public static func reshapeToList(_ merged: [(name: String, entry: JSONValue)]) -> [JSONValue] {
        merged.map { (name, entryV) in
            guard case .object(var entry) = entryV else {
                return .object(["name": .string(name)])
            }
            // {"name": k, **v} — the explicit "name" key is FIRST, so a `name`
            // already inside the entry value (from **v) WINS, mirroring Python's
            // `{"name": k, **v}` where the spread overwrites the leading literal.
            if entry["name"] == nil { entry["name"] = .string(name) }
            return .object(entry)
        }
    }
}

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
            let raw = await self.persistence.readJSON(self.registryPath, defaultValue: .array([]))
            var skills: [JSONValue] = { if case .array(let a) = raw { return a } else { return [] } }()
            for index in skills.indices {
                guard case .object(var skill) = skills[index] else { continue }
                let sid = SkillMutation.pyStr(skill["id"] ?? .null)
                let sname = SkillMutation.pyStr(skill["name"] ?? .null)
                if sid != skillId && sname != skillId { continue }
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
            let raw = await self.persistence.readJSON(self.registryPath, defaultValue: .array([]))
            let skills: [JSONValue] = { if case .array(let a) = raw { return a } else { return [] } }()
            var kept: [JSONValue] = []
            var removed: JSONValue? = nil
            for skill in skills {
                let sid = SkillMutation.pyStr((skill.objectValue?["id"]) ?? .null)
                let sname = SkillMutation.pyStr((skill.objectValue?["name"]) ?? .null)
                if sid == skillId || sname == skillId { removed = skill } else { kept.append(skill) }
            }
            guard let removedSkill = removed else { return nil }
            // Body-file cleanup, path-confined to skill_bodies_dir (mirrors
            // delete_skill L26883-26891; an unreadable/outside path is skipped
            // with a "warn" activity event but the delete still proceeds).
            if case .object(let robj) = removedSkill,
               case .string(let bodyPathRaw)? = robj["bodyPath"], !bodyPathRaw.isEmpty {
                await self.cleanupBodyFile(bodyPathRaw, skillId: skillId, displayName: SkillMutation.pyStrTruthyOr(robj["name"], skillId))
            }
            try await self.persistence.writeJSON(.array(kept), to: self.registryPath)
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
            let raw = await self.persistence.readJSON(self.registryPath, defaultValue: .array([]))
            var skills: [JSONValue] = { if case .array(let a) = raw { return a } else { return [] } }()
            let now = SkillMutation.nowISO(self.now)
            // case-insensitive name dedup (Python: next(... lower() == name.lower()))
            if let idx = skills.firstIndex(where: {
                SkillMutation.pyStrTruthyOr($0.objectValue?["name"], "").lowercased() == name.lowercased()
            }), case .object(var existing) = skills[idx] {
                // Normalize early/hand-authored registry rows that predate the
                // canonical writer and have no id. `str(null)` used to produce
                // a literal "None.md", disconnecting the manifest name from
                // the body read path. The skill name is already deduplicated,
                // so its canonical slug is the safe repair id.
                let existingId = SkillMutation.pyTruthyStrOptional(existing["id"])
                let skillId = existingId ?? SkillMutation.slugify(
                    SkillMutation.pyStrTruthyOr(existing["name"], name)
                )
                let bodyPath = self.skillBodiesDir.appendingPathComponent("\(skillId).md")
                existing["id"] = .string(skillId)
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
                return updated
            }
            var skillId = SkillMutation.slugify(name)
            // Python: existing_ids = {str(skill.get("id")) for skill in skills}
            // — bare str() (a null id → "None"), NOT the `or ""` truthiness.
            let existingIds = Set(skills.map { SkillMutation.pyStr($0.objectValue?["id"] ?? .null) })
            if existingIds.contains(skillId) {
                skillId = "\(skillId)-\(String(UUID().uuidString.lowercased().prefix(8)))"
            }
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
            skills.append(record)
            try await self.persistence.writeJSON(.array(skills), to: self.registryPath)
            return record
        }
    }

    // MARK: - Mutation helpers

    private var skillBodiesDir: URL { root.appendingPathComponent("skills/bodies", isDirectory: true) }

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

// MARK: - JSONValue convenience (local to Skills)

extension JSONValue {
    /// The backing dict if this is an `.object`, else nil. Local helper for the
    /// mutation paths' field reads.
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

// MARK: - Python-semantics helpers for the mutation port

enum SkillMutation {
    /// `urllib.parse.unquote` — percent-decode using UTF-8 (matches Python's
    /// default). Leaves a string with no `%` sequences untouched.
    static func unquote(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    /// `str(body.get(key) or "")`-style read of a top-level string field.
    /// The `or ""` truthiness collapses a missing key, null, false, 0, and ""
    /// all to "" — matching Python (NOT pyStr, which would yield "None"/"False"/
    /// "0" for those). gpt-5.5 review finding (wave 32 W15).
    static func string(_ v: JSONValue, _ key: String) -> String {
        guard case .object(let o) = v else { return "" }
        return pyStrTruthyOr(o[key], "")
    }

    /// Python `str(x)` for the scalar JSON types that flow through these paths.
    /// null→"None", bools→"True"/"False" (matches Python str()), numbers→repr.
    static func pyStr(_ v: JSONValue) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .array, .object: return ""
        }
    }

    /// `str(value)` only when the value is a NON-NULL string-or-scalar; returns
    /// nil for a missing key or an explicit JSON null. Mirrors Python's
    /// `entry.get("state")` returning `None` (vs the literal "None" string).
    static func pyStrOptional(_ v: JSONValue?) -> String? {
        guard let v, v != .null else { return nil }
        return pyStr(v)
    }

    /// The truthy half of Python's `x or fallback` chain: returns `str(x)` when
    /// `x` is TRUTHY, else nil (so the caller can chain `?? next ?? default`).
    /// Differs from `pyStrOptional` in that a present-but-FALSEY value (""/0/
    /// false/[]/{}) returns nil — matching `body.get("status") or …` where an
    /// empty string falls through (gpt-5.5 review finding, wave 32 W15).
    static func pyTruthyStrOptional(_ v: JSONValue?) -> String? {
        guard let v else { return nil }
        switch v {
        case .null: return nil
        case .bool(let b): return b ? "True" : nil
        case .int(let i): return i == 0 ? nil : String(i)
        case .double(let d): return d == 0 ? nil : String(d)
        case .string(let s): return s.isEmpty ? nil : s
        case .array(let a): return a.isEmpty ? nil : ""
        case .object(let o): return o.isEmpty ? nil : ""
        }
    }

    /// `str(item.get(key) or fallback)` truthiness fold: returns the value's
    /// `str()` form when truthy, else `fallback`. Used for the record_activity
    /// display name `str(skill.get("name") or skill_id)`.
    static func pyStrTruthyOr(_ v: JSONValue?, _ fallback: String) -> String {
        guard let v else { return fallback }
        switch v {
        case .null: return fallback
        case .bool(let b): return b ? "True" : fallback
        case .int(let i): return i == 0 ? fallback : String(i)
        case .double(let d): return d == 0 ? fallback : String(d)
        case .string(let s): return s.isEmpty ? fallback : s
        case .array(let a): return a.isEmpty ? fallback : ""
        case .object(let o): return o.isEmpty ? fallback : ""
        }
    }

    /// `bool(body.get(key, False))` — retired truthiness across the scalar types.
    static func boolValue(_ v: JSONValue?) -> Bool {
        guard let v else { return false }
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// `int(body.get(key) or 0)` for the useCount field. Coerces int/double/
    /// numeric-string; nil/non-numeric → nil (caller defaults to 0).
    static func intValue(_ v: JSONValue?) -> Int? {
        guard let v else { return nil }
        switch v {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// `slugify` mirror: lowercase, replace every run of
    /// non-`[a-z0-9]` with `-`, strip leading/trailing `-`, cap at 80; empty →
    /// a fresh uuid4.
    static func slugify(_ value: String) -> String {
        let lowered = value.lowercased()
        var out = ""
        var lastWasDash = false
        for ch in lowered.unicodeScalars {
            let isAllowed = (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9")
            if isAllowed {
                out.unicodeScalars.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        // strip("-")
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        let capped = String(out.prefix(80))
        return capped.isEmpty ? UUID().uuidString.lowercased() : capped
    }

    /// `now_iso()` = `datetime.now(timezone.utc).isoformat()`. Python emits
    /// MICROSECOND precision with a `+00:00` offset. The Swift cutover convention
    /// (established wave 7 routerPlan / WorkshopExecution.isoTimestamp) uses MILLISECOND
    /// fractional seconds + `+00:00`. This is the documented intra-cutover
    /// deviation: updatedAt/createdAt are never compared for equality across the
    /// boundary, only sorted lexicographically DESC, and a single record is
    /// stamped by exactly ONE side per mutation — so ms-vs-µs only perturbs the
    /// relative order of two records written within the same millisecond, an
    /// ordering the daemon itself does not guarantee.
    static func nowISO(_ now: @Sendable () -> Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let zulu = fmt.string(from: now())
        if zulu.hasSuffix("Z") { return String(zulu.dropLast()) + "+00:00" }
        return zulu
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
            "missionId": .null,
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
