import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Wave 34 W06: Native Swift persona/system connector actions (DORMANT — no production wiring)
//
// Retry of the wave-33 W08 batch that died mid-task (API socket) before commit.
// Starts fresh from base. Ports 4 SMALL, SELF-CONTAINED, READ-ONLY persona /
// system connector action handlers from the retired runtime into Swift, so the
// SwiftNativeDispatcher can execute them natively. The four:
//
//   persona_read        ← the retired daemon:_exec_persona_read        (3549)
//   persona_list_skills ← the retired daemon:_exec_persona_list_skills (3757)
//   workspace_list      ← the retired daemon:_exec_workspace_list      (3872)
//   time_now            ← the retired daemon:_exec_time_now            (205)
//
// Each handler takes the same `(input, context)` → result-dict shape as the
// historical executor and returns a `JSONValue` whose keys/values are byte-shape
// equivalent to the old return dict (same keys, defaults, error_code
// strings). NOTHING here is wired into a production caller yet: the production
// `makeDispatcher` factory passes `localActions: nil`; this registry is only
// consulted when a SwiftNativeDispatcher is explicitly constructed with
// `localActions: .fileSystemDefault`. Flipping callers through SwiftNative is a
// separate, leash-gated wave (CUTOVER_PLAN §6.97 disposition).
//
// AUDIT NOTE (HONESTY GATE): the brief asked for "+5". A full audit of the
// remaining unported `_exec_*` builtin handlers found that the 5th would-be
// candidate — `scratchpad_read` — is NOT a clean
// self-contained connector-action port: it reads the stateful, in-process
// `Scratchpad` TTL store which has no shared on-disk
// surface for byte-parity. Every other unported builtin handler
// (tool_catalog / daemon_status / context_lookup / recall_* /
// tradingview_watchlist / daemon_introspect / recent_trace_summary / tool_*)
// requires a LIVE runtime or dispatcher object injected into `context`. These 4
// are the COMPLETE set of read-only, runtime-independent persona/system
// handlers. Porting the 5th would mean porting a subsystem, not an action —
// out of scope for the per-action migration seam. See §6.97.
//
// Sandbox parity: persona_read reuses the EXACT FileSystemActions sandbox
// (allowedRoots + isSensitiveDataPath) so the security posture is identical to
// read_file. persona_list_skills / workspace_list are list-only and resolve
// their roots from the action context (persona_root / workspace_root) with the
// daemon's same priority order, then sandbox-validate (workspace_list rejects a
// subdir that escapes the workspace root, mirroring the Python C4 fix).

// MARK: - Constants

/// the retired daemon `_SKILL_DESC_MAX_LEN = 280`
let personaSkillDescMaxLen = 280

/// the retired daemon `_PERSONA_READ_KINDS`.
let personaReadKinds: Set<String> = ["soul", "user", "skill", "voice", "growth", "agents"]

/// the retired daemon `_SKILL_NAME_RE = re.compile(r'^[A-Za-z0-9_-]+$')`.
private let personaSkillNameRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]+$")

enum PersonaSystemActions {

    // MARK: helpers

    /// Mirror `_validate_skill_name`: allow only
    /// ASCII letters/digits/underscore/hyphen — rejects path-traversal chars.
    static func validateSkillName(_ name: String) -> Bool {
        let ns = name as NSString
        return personaSkillNameRegex.firstMatch(
            in: name, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// Resolve the persona root the same way `_resolve_na_persona_root` does:
    /// explicit context personaRoot wins; otherwise fall through to
    /// PersistenceCore.defaultPersonaRoot (env / stamped bundle / <data>/memory).
    static func personaRootURL(_ ctx: ConnectorActionContext) -> URL {
        if let pr = ctx.personaRoot, !pr.isEmpty {
            return URL(fileURLWithPath: pr)
        }
        if let dr = ctx.dataRoot, !dr.isEmpty {
            return PersistenceCore.defaultPersonaRoot(dataRoot: URL(fileURLWithPath: dr))
        }
        return PersistenceCore.defaultPersonaRoot()
    }

    /// Resolve the data root used for skill bodies + sensitive-path block.
    static func dataRootURL(_ ctx: ConnectorActionContext) -> URL {
        if let dr = ctx.dataRoot, !dr.isEmpty { return URL(fileURLWithPath: dr) }
        return PersistenceCore.defaultDataRoot()
    }

    /// Mirror `_persona_path`. Returns nil for an
    /// invalid skill name / missing skill_name (caller emits bad_input).
    static func personaPath(
        kind: String, skillName: String?, dataRoot: URL, personaRoot: URL
    ) -> URL? {
        switch kind {
        case "soul":   return personaRoot.appendingPathComponent("SOUL.md")
        case "user":   return personaRoot.appendingPathComponent("USER.md")
        case "voice":  return personaRoot.appendingPathComponent("VOICE.md")
        case "growth": return personaRoot.appendingPathComponent("GROWTH.md")
        case "agents": return personaRoot.appendingPathComponent("AGENTS.md")
        case "skill":
            guard let sn = skillName, !sn.isEmpty else { return nil }
            guard validateSkillName(sn) else { return nil }
            // Persona dir wins if the body exists there; else data-root legacy.
            let personaSkill = personaRoot
                .appendingPathComponent("skills")
                .appendingPathComponent("bodies")
                .appendingPathComponent("\(sn).md")
            if FileManager.default.fileExists(atPath: personaSkill.path) {
                return personaSkill
            }
            return dataRoot
                .appendingPathComponent("skills")
                .appendingPathComponent("bodies")
                .appendingPathComponent("\(sn).md")
        default:
            return nil
        }
    }

    // MARK: - persona_read

    static func personaRead(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        // Wave 36 W11 (pre-flip parity fix, gpt-5.5 review): canonicalize `kind`
        // with the SAME pipeline the daemon's `_exec_persona_read` uses —
        // `unicodedata.normalize("NFKC", str(inp.get("kind") or "")).strip().lower()`
        //. The
        // original wave-34 W06 port only `.trimmingCharacters`-trimmed, so a
        // cased (" SOUL "), fullwidth ("ＳＯＵＬ" U+FF33…), or NBSP/ideographic-
        // whitespace variant of a valid kind — which the daemon ACCEPTS — would
        // be REJECTED natively as bad_input, a real divergence on the flip path.
        // Use `precomposedStringWithCompatibilityMapping` (= NFKC, folds
        // fullwidth → ASCII; NFC does NOT) then strip then lower, identical to
        // the verified PersonaWriteGuard canonicalization. `.whitespacesAndNewlines`
        // trims NBSP/ideographic/narrow-NBSP, matching Python `str.strip()` after
        // NFKC maps NBSP U+00A0 → ASCII space.
        let kind = FileSystemActions.stringField(input, "kind")
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !personaReadKinds.contains(kind) {
            let allowed = personaReadKinds.sorted().joined(separator: ", ")
            return FileSystemActions.errResult(
                "kind must be one of: \(allowed)", code: "bad_input")
        }
        // skill_name: Python `inp.get("skill_name") or None` — empty string → nil.
        var skillName: String? = nil
        if case .string(let s)? = input["skill_name"], !s.isEmpty { skillName = s }
        if kind == "skill" && skillName == nil {
            return FileSystemActions.errResult(
                "skill_name is required when kind=skill", code: "bad_input")
        }
        // C3 fix: validate skill_name BEFORE path construction.
        if let sn = skillName, !validateSkillName(sn) {
            return FileSystemActions.errResult(
                "skill_name '\(sn)' contains invalid characters (only A-Za-z0-9_- allowed)",
                code: "bad_input")
        }

        let dataRoot = dataRootURL(ctx)
        let personaRoot = personaRootURL(ctx)
        guard let target = personaPath(
            kind: kind, skillName: skillName, dataRoot: dataRoot, personaRoot: personaRoot
        ) else {
            return FileSystemActions.errResult(
                "Could not resolve persona path", code: "bad_input")
        }

        // Python: only `if not target.exists()` → the dedicated "Persona file
        // not found: <path>" message. Anything else (a directory, a permission
        // error, a non-UTF-8 file) reaches `read_text()`, raises, and is caught
        // into `{ok:false, error:str(exc), error_code:"persona_not_found"}`.
        // (gpt-5.5 review: do NOT pre-reject a directory as "not found" — let
        // the read attempt produce the caught-exception shape Python emits.)
        if !FileManager.default.fileExists(atPath: target.path) {
            return FileSystemActions.errResult(
                "Persona file not found: \(target.path)", code: "persona_not_found")
        }
        let content: String
        do {
            // Throwing read so a directory / permission / decode failure lands in
            // the same caught-exception branch Python's `read_text` does.
            content = try String(contentsOf: target, encoding: .utf8)
        } catch {
            return FileSystemActions.errResult(
                String(describing: error), code: "persona_not_found")
        }
        if kind == "skill" {
            let hygieneViolations = SkillBodyHygiene.violations(in: content)
            if !hygieneViolations.isEmpty {
                return FileSystemActions.errResult(
                    "skill body hygiene failed: \(SkillBodyHygiene.failureMessage(for: hygieneViolations))",
                    code: "skill_hygiene_failed")
            }
        }
        let sizeBytes = content.utf8.count
        return .object([
            "ok": .bool(true),
            "kind": .string(kind),
            "path": .string(target.path),
            "content": .string(content),
            "size_bytes": .int(Int64(sizeBytes)),
        ])
    }

    // MARK: - persona_list_skills

    static func personaListSkills(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        // Python: bool(inp.get("verbose", False)); int(inp.get("limit") or 0);
        // int(inp.get("offset") or 0). Keep RAW values — Python's list slicing
        // honours a negative offset (slice from the end) and treats limit<=0 as
        // "no cap"; the slicing logic below mirrors that exactly (gpt-5.5 review).
        let verbose = boolField(input["verbose"])
        let limit = intOrZero(input["limit"])
        let offset = intOrZero(input["offset"])

        let dataRoot = dataRootURL(ctx)
        let personaRoot = personaRootURL(ctx)
        let personaBodies = personaRoot
            .appendingPathComponent("skills").appendingPathComponent("bodies")
        let dataBodies = dataRoot
            .appendingPathComponent("skills").appendingPathComponent("bodies")

        // Per-name record; persona/ wins on collision (newer authoritative layout).
        // Preserve insertion-independent state via a dict + the source-priority
        // walk order ("persona" first), mirroring the Python `if name in records: continue`.
        var records: [String: SkillRecord] = [:]
        for (source, dir) in [("persona", personaBodies), ("data", dataBodies)] {
            let mdFiles = listMarkdownFiles(in: dir)
            for p in mdFiles {
                let name = p.deletingPathExtension().lastPathComponent
                if records[name] != nil { continue }  // persona/ already claimed it
                let body = (try? String(contentsOf: p, encoding: .utf8)) ?? ""
                guard SkillBodyHygiene.violations(in: body).isEmpty else { continue }
                records[name] = SkillRecord(
                    name: name,
                    source: source,
                    path: p.path,
                    description: extractSkillDescription(p),
                    triggers: nil, kind: nil, useCount: nil
                )
            }
        }

        // Merge runtime metadata from data/skills/registry.json.
        let runtimeReg = loadRuntimeSkillRegistry(dataRoot: dataRoot)
        for (name, entry) in runtimeReg {
            if records[name] == nil {
                guard registrySkillBodyIsClean(entry, dataRoot: dataRoot) else { continue }
                // Registry references a skill whose body is missing — surface a stub.
                var desc = ""
                if case .string(let s)? = entry["description"] { desc = s }
                var bodyPath = ""
                if case .string(let s)? = entry["bodyPath"] { bodyPath = s }
                records[name] = SkillRecord(
                    name: name, source: "registry", path: bodyPath,
                    description: desc, triggers: nil, kind: nil, useCount: nil)
            }
            var rec = records[name]!
            // Prefer a registry description ONLY if extraction failed.
            if rec.description.isEmpty, case .string(let s)? = entry["description"], !s.isEmpty {
                rec.description = s
            }
            // Retired truthiness: `if entry.get("triggers"):` only fires for a
            // NON-EMPTY list; `if entry.get("kind"):` only for a NON-EMPTY string.
            // An empty list / empty string must NOT add the key (gpt-5.5 review).
            if case .array(let arr)? = entry["triggers"], !arr.isEmpty {
                rec.triggers = arr
            }
            if case .string(let s)? = entry["kind"], !s.isEmpty {
                rec.kind = s
            }
            // Python: `if entry.get("useCount") is not None:` — present and not
            // null (0 is kept; only None is skipped).
            if let uc = entry["useCount"], !isNullValue(uc) {
                rec.useCount = uc
            }
            records[name] = rec
        }

        let sortedNames = records.keys.sorted()
        let totalCount = sortedNames.count

        // Pagination: Python `sorted_names[offset:]` then `[:limit]` (when
        // limit>0). Mirror Python list-slice semantics INCLUDING negatives:
        //   offset >= 0 → start at min(offset, count)
        //   offset <  0 → start at max(count + offset, 0)  (from the end)
        var pageNames = sortedNames
        if offset != 0 {
            let count = pageNames.count
            let start: Int
            if offset >= 0 {
                start = Swift.min(offset, count)
            } else {
                start = Swift.max(count + offset, 0)
            }
            pageNames = start < count ? Array(pageNames[start...]) : []
        }
        if limit > 0 && limit < pageNames.count {
            pageNames = Array(pageNames[0..<limit])
        }

        let fullRecords = pageNames.map { records[$0]! }
        let manifest: [JSONValue]
        if verbose {
            manifest = fullRecords.map { $0.toFullJSON() }
        } else {
            manifest = fullRecords.map {
                .object([
                    "name": .string($0.name),
                    "description": .string($0.description),
                    "source": .string($0.source),
                ])
            }
        }

        let sources: [String: JSONValue] = [
            "persona": .int(Int64(fullRecords.filter { $0.source == "persona" }.count)),
            "data": .int(Int64(fullRecords.filter { $0.source == "data" }.count)),
            "registry_only": .int(Int64(fullRecords.filter { $0.source == "registry" }.count)),
        ]
        return .object([
            "ok": .bool(true),
            "skills": .array(pageNames.map { .string($0) }),
            "manifest": .array(manifest),
            "count": .int(Int64(totalCount)),
            "returned": .int(Int64(pageNames.count)),
            "sources": .object(sources),
        ])
    }

    static func registrySkillBodyIsClean(_ entry: [String: JSONValue], dataRoot: URL) -> Bool {
        var candidates: [URL] = []
        if case .string(let rawPath)? = entry["bodyPath"] {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let expanded = (trimmed as NSString).expandingTildeInPath
                if expanded.hasPrefix("/") {
                    candidates.append(URL(fileURLWithPath: expanded))
                } else {
                    candidates.append(dataRoot.appendingPathComponent(expanded))
                }
            }
        }
        if case .string(let name)? = entry["name"], !name.isEmpty {
            candidates.append(dataRoot
                .appendingPathComponent("skills")
                .appendingPathComponent("bodies")
                .appendingPathComponent("\(name).md"))
        }

        var seen: Set<String> = []
        for url in candidates where seen.insert(url.path).inserted {
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return SkillBodyHygiene.violations(in: body).isEmpty
        }
        return true
    }

    /// A per-skill manifest record. Mirrors the Python `records[name]` dict.
    struct SkillRecord {
        var name: String
        var source: String
        var path: String
        var description: String
        var triggers: [JSONValue]?
        var kind: String?
        var useCount: JSONValue?

        /// Full (verbose) record — includes path + the runtime metadata that was
        /// present. Mirrors the Python verbose record (the raw dict).
        func toFullJSON() -> JSONValue {
            var obj: [String: JSONValue] = [
                "name": .string(name),
                "source": .string(source),
                "path": .string(path),
                "description": .string(description),
            ]
            if let t = triggers { obj["triggers"] = .array(t) }
            if let k = kind { obj["kind"] = .string(k) }
            if let uc = useCount { obj["use_count"] = uc }
            return .object(obj)
        }
    }

    /// Mirror `_extract_skill_description`.
    static func extractSkillDescription(_ bodyPath: URL) -> String {
        guard let fh = FileManager.default.contents(atPath: bodyPath.path) else { return "" }
        // Read at most ~4KB prefix (Python reads fh.read(4096)).
        let head = decodeUTF8Replacing4096(fh)
        var descLines: [String] = []
        for raw in splitLinesLocal(head) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if !descLines.isEmpty { break }  // paragraph break ends description
                continue
            }
            if line.hasPrefix("#") { continue }  // skip heading lines
            if line.hasPrefix("-") || line.hasPrefix("*")
                || line.hasPrefix("1.") || line.hasPrefix("2.") {
                if !descLines.isEmpty { break }  // list starts → done
                continue
            }
            descLines.append(line)
        }
        var desc = descLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if desc.count > personaSkillDescMaxLen {
            // Python: desc[: MAX-1].rstrip() + "…"
            let cut = String(desc.prefix(personaSkillDescMaxLen - 1))
            desc = cut.replacingOccurrences(
                of: "\\s+$", with: "", options: .regularExpression) + "…"
        }
        return desc
    }

    /// Mirror `_load_runtime_skill_registry`. Returns a
    /// name→entry map; empty on any error or non-list JSON.
    static func loadRuntimeSkillRegistry(dataRoot: URL) -> [String: [String: JSONValue]] {
        let regPath = dataRoot
            .appendingPathComponent("skills").appendingPathComponent("registry.json")
        guard let data = FileManager.default.contents(atPath: regPath.path) else { return [:] }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let arr = parsed as? [Any] else { return [:] }
        var out: [String: [String: JSONValue]] = [:]
        for item in arr {
            guard let dict = item as? [String: Any],
                  let name = dict["name"] as? String, !name.isEmpty else { continue }
            out[name] = foundationToJSONObject(dict)
        }
        return out
    }

    // MARK: - workspace_list

    static func workspaceList(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let workspaceRoot = workspaceRootURL(ctx)
        // Python: str(inp.get("subdir") or "").strip().lstrip("/")
        var subdir = FileSystemActions.stringField(input, "subdir")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while subdir.hasPrefix("/") { subdir.removeFirst() }

        // C4 fix: resolve root + target with the SAME symlink strategy, then
        // confirm target stays within root. Do NOT mkdir (list-only tool).
        let resolvedRoot = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rawTarget = subdir.isEmpty
            ? resolvedRoot
            : resolvedRoot.appendingPathComponent(subdir)
        let resolvedTarget = rawTarget.standardizedFileURL.resolvingSymlinksInPath()

        // relative_to check (mirror Python ValueError on escape).
        if !isWithinRoot(resolvedTarget, root: resolvedRoot) {
            return FileSystemActions.errResult(
                "subdir '\(subdir)' escapes workspace root '\(workspaceRoot.path)'",
                code: "path_not_allowed")
        }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolvedTarget.path, isDirectory: &isDir)
        if !exists {
            // Workspace may not exist yet on first run — empty, not an error.
            return .object([
                "ok": .bool(true),
                "root": .string(workspaceRoot.path),
                "items": .array([]),
                "count": .int(0),
            ])
        }

        // Python: the iterdir loop is inside a `try` whose `except` returns
        // `{ok:false, error:str(exc)}` with NO error_code. A file-as-target (the
        // path exists but isn't a directory) raises NotADirectoryError there.
        // (gpt-5.5 review: do NOT swallow this into an empty ok=true result.)
        let fm = FileManager.default
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(
                at: resolvedTarget,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [])
        } catch {
            return .object([
                "ok": .bool(false),
                "error": .string(String(describing: error)),
            ])
        }

        // Python sort key: (p.is_file(), p.name) — dirs (is_file False=0) before
        // files (True=1), each group by name.
        struct Entry { let isDir: Bool; let name: String; let size: Int64 }
        var entries: [Entry] = []
        for child in children {
            let name = child.lastPathComponent
            if name == ".gitkeep" { continue }
            var cIsDir: ObjCBool = false
            _ = fm.fileExists(atPath: child.path, isDirectory: &cIsDir)
            let isDirectory = cIsDir.boolValue
            // Python: `entry.stat().st_size if entry.is_file() else 0`; OSError → 0.
            var size: Int64 = 0
            if !isDirectory {
                if let attrs = try? fm.attributesOfItem(atPath: child.path),
                   let s = attrs[.size] as? NSNumber {
                    size = s.int64Value
                }
            }
            entries.append(Entry(isDir: isDirectory, name: name, size: size))
        }
        entries.sort { a, b in
            let aFile = a.isDir ? 0 : 1
            let bFile = b.isDir ? 0 : 1
            if aFile != bFile { return aFile < bFile }
            return a.name < b.name
        }

        var items: [JSONValue] = []
        for e in entries {
            // rel = entry relative to the workspace ROOT. Python computes
            // `entry.relative_to(resolved_root)` where `entry` is
            // `resolved_target / name` (the target is already resolved; the
            // ENTRY itself is NOT individually symlink-resolved — a symlinked
            // entry keeps its listed path). Reconstruct the entry path the same
            // way: `resolvedTarget / name`, then strip the resolvedRoot prefix.
            // (gpt-5.5 review: do NOT resolvingSymlinksInPath() the child — that
            // would rewrite a symlinked entry's reported path away from Python's.)
            let entryPath = resolvedTarget.appendingPathComponent(e.name)
            let rel = relativePath(of: entryPath, base: resolvedRoot)
            items.append(.object([
                "path": .string(rel),
                "size_bytes": .int(e.size),
                "is_dir": .bool(e.isDir),
            ]))
        }
        return .object([
            "ok": .bool(true),
            "root": .string(workspaceRoot.path),
            "items": .array(items),
            "count": .int(Int64(items.count)),
        ])
    }

    /// Resolve workspace root mirroring `_resolve_workspace_root_bt` priority:
    ///   1. explicit context `_na_workspace_root` (test override)
    ///   2. `NATIVE_AGENT_WORKSPACE_ROOT` env var
    ///   3. canonical `NativeAgentWorkspaceRoot` resolution: `<repo>/workspace`
    ///      for a verified source-backed install, otherwise
    ///      `<dataRoot>/workspace` for a public/app-only install.
    static func workspaceRootURL(_ ctx: ConnectorActionContext) -> URL {
        if let ws = ctx.workspaceRoot, !ws.isEmpty {
            return URL(fileURLWithPath: ws)
        }
        return NativeAgentWorkspaceRoot.resolve(dataRoot: dataRootURL(ctx))
    }

    // MARK: - time_now

    static func timeNow(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        // Python: inp.get("timezone") or inp.get("tz") or "" ; .strip()
        var tzName = FileSystemActions.stringField(input, "timezone")
        if tzName.isEmpty { tzName = FileSystemActions.stringField(input, "tz") }
        tzName = tzName.trimmingCharacters(in: .whitespacesAndNewlines)

        let tz: TimeZone
        if !tzName.isEmpty {
            guard let z = TimeZone(identifier: tzName) else {
                return FileSystemActions.errResult(
                    "unknown timezone: \(tzName)", code: "bad_input")
            }
            tz = z
        } else {
            tz = TimeZone.current
            // tz_name = local_probe.tzname() or str(tz) or "local"
            tzName = tz.abbreviation() ?? tz.identifier
            if tzName.isEmpty { tzName = "local" }
        }

        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let comps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday], from: now)

        // ISO-8601 with offset (mirror datetime.isoformat() incl. +HH:MM offset).
        let isoLocal = isoFormat(now, tz: tz)
        let isoUTC = isoFormat(now, tz: TimeZone(identifier: "UTC")!)

        let offsetSecs = tz.secondsFromGMT(for: now)
        let utcOffset = formatUTCOffset(offsetSecs)

        let y = comps.year ?? 0, mo = comps.month ?? 0, d = comps.day ?? 0
        let h = comps.hour ?? 0, mi = comps.minute ?? 0, s = comps.second ?? 0
        let dateStr = String(format: "%04d-%02d-%02d", y, mo, d)
        let timeStr = String(format: "%02d:%02d:%02d", h, mi, s)
        let dayOfWeek = weekdayName(comps.weekday ?? 1)

        return .object([
            "ok": .bool(true),
            "iso": .string(isoLocal),
            "utcIso": .string(isoUTC),
            "timezone": .string(tzName),
            "utcOffset": .string(utcOffset),
            "epochSeconds": .int(Int64(now.timeIntervalSince1970)),
            "date": .string(dateStr),
            "time": .string(timeStr),
            "dayOfWeek": .string(dayOfWeek),
        ])
    }
}

// MARK: - File-local value helpers (private to this file)

private func boolField(_ v: JSONValue?) -> Bool {
    switch v ?? .null {
    case .bool(let b): return b
    case .int(let i): return i != 0
    case .double(let d): return d != 0
    case .string(let s): return !s.isEmpty
    default: return false
    }
}

/// Mirror Python `int(inp.get("k") or 0)`: null/missing/empty → 0; numeric or
/// numeric-string → its int; non-numeric → 0 (Python would raise, but these
/// inputs are model-supplied and the daemon path tolerates them upstream).
private func intOrZero(_ v: JSONValue?) -> Int {
    switch v ?? .null {
    case .null: return 0
    case .int(let i): return Int(i)
    case .double(let d): return Int(d)
    case .string(let s):
        if s.isEmpty { return 0 }
        if let i = Int(s) { return i }
        if let dd = Double(s) { return Int(dd) }
        return 0
    case .bool(let b): return b ? 1 : 0
    default: return 0
    }
}

private func isNullValue(_ v: JSONValue) -> Bool {
    if case .null = v { return true }; return false
}

/// List `*.md` regular files in a directory (mirror `bodies_dir.glob("*.md")`
/// + `p.is_file()`). Empty when the dir is absent / unreadable.
private func listMarkdownFiles(in dir: URL) -> [URL] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return [] }
    guard let children = try? fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return [] }
    return children.filter { url in
        guard url.pathExtension == "md" else { return false }
        var f: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &f)
        return exists && !f.boolValue
    }
}

/// Decode at most a 4096-byte UTF-8 prefix with replacement (Python
/// `fh.read(4096)` on a text handle reads up to 4096 CHARS, but the description
/// always lives in the first few lines so a 4096-byte prefix is an
/// over-approximation that never truncates a real description short).
private func decodeUTF8Replacing4096(_ data: Data) -> String {
    let slice = data.count > 4096 ? data.prefix(4096) : data[...]
    if let s = String(data: Data(slice), encoding: .utf8) { return s }
    var scalars = String.UnicodeScalarView()
    var decoder = UTF8()
    var iter = Data(slice).makeIterator()
    loop: while true {
        switch decoder.decode(&iter) {
        case .scalarValue(let sc): scalars.append(sc)
        case .emptyInput: break loop
        case .error: scalars.append(Unicode.Scalar(0xFFFD)!)
        }
    }
    return String(scalars)
}

/// Mirror Python `str.splitlines()` (universal newlines, no trailing empty
/// element for a final newline).
private func splitLinesLocal(_ text: String) -> [String] {
    if text.isEmpty { return [] }
    var lines: [String] = []
    var current = ""
    let chars = Array(text)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "\r" {
            lines.append(current); current = ""
            if i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
        } else if c == "\n" {
            lines.append(current); current = ""
        } else {
            current.append(c)
        }
        i += 1
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

/// True when `path` equals or is nested under `root` (both pre-resolved).
private func isWithinRoot(_ path: URL, root: URL) -> Bool {
    let p = path.path
    let r = root.path
    if p == r { return true }
    let prefix = r.hasSuffix("/") ? r : r + "/"
    return p.hasPrefix(prefix)
}

/// `entry` path relative to `base` (both resolved). Mirrors `Path.relative_to`.
private func relativePath(of entry: URL, base: URL) -> String {
    let e = entry.path
    let b = base.path
    if e == b { return "" }
    let prefix = b.hasSuffix("/") ? b : b + "/"
    if e.hasPrefix(prefix) { return String(e.dropFirst(prefix.count)) }
    return entry.lastPathComponent
}

/// ISO-8601 with timezone offset, microsecond fractional seconds (mirrors
/// Python `datetime.isoformat()` which emits `YYYY-MM-DDTHH:MM:SS.ffffff±HH:MM`,
/// or `...SS±HH:MM` when microseconds are zero).
private func isoFormat(_ date: Date, tz: TimeZone) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let c = cal.dateComponents(
        [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
    let micros = (c.nanosecond ?? 0) / 1000
    let base = String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    let frac = micros == 0 ? "" : String(format: ".%06d", micros)
    let offset = isoOffset(tz.secondsFromGMT(for: date))
    return base + frac + offset
}

/// `±HH:MM` (Python isoformat offset). UTC → `+00:00`.
private func isoOffset(_ seconds: Int) -> String {
    let sign = seconds < 0 ? "-" : "+"
    let abs = Swift.abs(seconds)
    let h = abs / 3600
    let m = (abs % 3600) / 60
    return String(format: "%@%02d:%02d", sign, h, m)
}

/// `±HHMM` (Python `strftime("%z")`).
private func formatUTCOffset(_ seconds: Int) -> String {
    let sign = seconds < 0 ? "-" : "+"
    let abs = Swift.abs(seconds)
    let h = abs / 3600
    let m = (abs % 3600) / 60
    return String(format: "%@%02d%02d", sign, h, m)
}

/// Calendar weekday (1=Sunday … 7=Saturday) → English name (Python
/// `strftime("%A")`, which is locale-default English in the daemon).
private func weekdayName(_ weekday: Int) -> String {
    let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    let idx = weekday - 1
    return (idx >= 0 && idx < names.count) ? names[idx] : "Sunday"
}

/// Convert a Foundation-parsed JSON dict (from JSONSerialization) into a
/// `[String: JSONValue]`. Used for registry.json entries.
private func foundationToJSONObject(_ dict: [String: Any]) -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]
    for (k, v) in dict { out[k] = foundationToJSONValue(v) }
    return out
}

private func foundationToJSONValue(_ v: Any) -> JSONValue {
    switch v {
    case let s as String:
        return .string(s)
    case let n as NSNumber:
        // Distinguish bool from numeric: a CFBoolean has the boolean type id.
        if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
            return .bool(n.boolValue)
        }
        // Integral vs floating.
        let dbl = n.doubleValue
        if dbl == dbl.rounded() && Swift.abs(dbl) < 9.0e18 {
            return .int(n.int64Value)
        }
        return .double(dbl)
    case let arr as [Any]:
        return .array(arr.map { foundationToJSONValue($0) })
    case let obj as [String: Any]:
        return .object(foundationToJSONObject(obj))
    case is NSNull:
        return .null
    default:
        return .null
    }
}
