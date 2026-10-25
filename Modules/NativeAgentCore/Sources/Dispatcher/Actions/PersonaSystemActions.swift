import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
// Blueprint: | `PersonaSystemActions.swift` | Protected persona tool reads through PersonaEngine's document selection and the filesystem owner's sensitive-path/regular-descriptor checks; skill/workspace read adapters; `ClockReply` owns timezone selection and date projection with local/chat field adapters |

// MARK: - Native persona/system connector actions
//
// Registered read-only handlers for persona documents, skill inventory,
// workspace listings and the clock. Persona reads resolve the sensitive-path
// fence before opening a verified regular-file descriptor.

package enum PersonaSystemActions {

    // MARK: helpers

    /// An explicit context personaRoot, otherwise
    /// PersistenceCore.defaultPersonaRoot for the context's data root.
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

    // MARK: - persona_read

    package static func personaRead(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let kind = SwiftNativePersonaEngine.canonicalizeKind(FileSystemActions.stringField(input, "kind"))
        if !SwiftNativePersonaEngine.personaReadKinds.contains(kind) {
            let allowed = SwiftNativePersonaEngine.personaReadKinds.sorted().joined(separator: ", ")
            return FileSystemActions.errResult(
                "kind must be one of: \(allowed)", code: "bad_input")
        }
        let personaRoot = personaRootURL(ctx)
        guard let target = SwiftNativePersonaEngine.personaDocumentPath(kind: kind, root: personaRoot) else {
            return FileSystemActions.errResult("Could not resolve persona path", code: "bad_input")
        }

        let resolved = FileSystemActions.resolvePath(target.path, repoRoot: ctx.repoRoot)
        if FileSystemActions.isSensitiveDataPath(resolved, ctx) {
            return FileSystemActions.errResult(
                "Persona file resolves to a protected credential or policy path.", code: "path_not_allowed")
        }
        if !FileManager.default.fileExists(atPath: resolved.path) {
            return FileSystemActions.errResult(
                "Persona file not found: \(target.path)", code: "persona_not_found")
        }
        let content: String
        do {
            let handle = try FileSystemActions.openRegularReadHandle(resolved)
            defer { try? handle.close() }
            let bytes = try handle.readToEnd() ?? Data()
            guard let decoded = String(data: bytes, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            content = decoded
        } catch let error as FileSystemActions.FileReadFailure {
            return FileSystemActions.errResult(error.message, code: error.code)
        } catch {
            return FileSystemActions.errResult(
                String(describing: error), code: "persona_not_found")
        }
        let sizeBytes = content.utf8.count
        return .object([
            "ok": .bool(true),
            "kind": .string(kind),
            "status": .string("ok"),
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
        var records: [String: SkillRecord] = [:]
        let entries: [InstalledSkillInventory.Entry]
        do {
            entries = try InstalledSkillInventory.entries(dataRoot: dataRoot)
        } catch {
            return FileSystemActions.errResult(
                "Could not load skill inventory: \(error.localizedDescription)", code: "skill_inventory_unavailable")
        }
        for entry in entries {
            let row = entry.row
            let text = { (key: String) -> String in
                if case .string(let value)? = row[key] { return value }; return ""
            }
            let source = text("source") == "persona_body" ? "persona"
                : text("source") == "runtime_body" ? "data" : "registry"
            let triggers: [JSONValue]?
            if case .array(let values)? = row["triggers"], !values.isEmpty { triggers = values } else { triggers = nil }
            records[entry.name] = SkillRecord(name: entry.name, source: source,
                path: text("bodyPath"), description: text("description"),
                triggers: triggers, kind: text("kind").isEmpty ? nil : text("kind"),
                useCount: row["useCount"] == .null ? nil : row["useCount"])
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
            "status": .string("ok"),
            "manifest": .array(manifest),
            "count": .int(Int64(totalCount)),
            "returned": .int(Int64(pageNames.count)),
            "sources": .object(sources),
        ])
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
                "status": .string("ok"),
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
            "status": .string("ok"),
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
        ClockReply.read(input) { $0.local }
    }
}

/// One clock projection, with the existing local-action and chat field adapters.
package struct ClockReply {
    let now: Date
    let zone: TimeZone
    let zoneName: String

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    package static func read(_ input: [String: JSONValue], project: (ClockReply) -> JSONValue) -> JSONValue {
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

        return project(ClockReply(now: Date(), zone: tz, zoneName: tzName))
    }

    package var chat: JSONValue {
        let tz = zone, cal = calendar
        let comps = cal.dateComponents([.weekday], from: now)
        let local = ISO8601DateFormatter()
        local.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        local.timeZone = tz
        let human = DateFormatter()
        human.dateStyle = .full
        human.timeStyle = .medium
        human.timeZone = tz
        return .object([
            "status": .string("ok"),
            "iso_utc": .string(ISO8601DateFormatter().string(from: now)),
            "iso_local": .string(local.string(from: now)),
            "epoch_seconds": .int(Int64(now.timeIntervalSince1970)),
            "weekday": .string(weekdayName(comps.weekday ?? 1)),
            "day_of_year": .int(Int64(cal.ordinality(of: .day, in: .year, for: now) ?? 0)),
            "human": .string(human.string(from: now)),
            "timezone": .string(tz.identifier),
            "timezone_offset_seconds": .int(Int64(tz.secondsFromGMT(for: now))),
        ])
    }

    package var local: JSONValue {
        let tz = zone, tzName = zoneName, cal = calendar
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: now)
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
            "status": .string("ok"),
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
    case .double(let d): return Int(exactly: d.rounded(.towardZero)) ?? 0
    case .string(let s):
        if s.isEmpty { return 0 }
        if let i = Int(s) { return i }
        if let dd = Double(s) { return Int(exactly: dd.rounded(.towardZero)) ?? 0 }
        return 0
    case .bool(let b): return b ? 1 : 0
    default: return 0
    }
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
