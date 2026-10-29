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
        ctx.personaRoot ?? PersistenceCore.defaultPersonaRoot(dataRoot: dataRootURL(ctx))
    }

    /// Resolve the data root used for skill bodies + sensitive-path block.
    static func dataRootURL(_ ctx: ConnectorActionContext) -> URL {
        ctx.dataRoot ?? PersistenceCore.defaultDataRoot()
    }

    // MARK: - persona_read

    package static func personaRead(_ input: [String: JSONValue], _ ctx: ConnectorActionContext, selectedDocument: URL? = nil) -> JSONValue {
        let kind = SwiftNativePersonaEngine.canonicalizeKind((input["kind"]?.stringValue ?? ""))
        if selectedDocument == nil, !SwiftNativePersonaEngine.personaReadKinds.contains(kind) {
            let allowed = SwiftNativePersonaEngine.personaReadKinds.sorted().joined(separator: ", ")
            return FileSystemActions.errResult(
                "kind must be one of: \(allowed)", code: "bad_input")
        }
        let personaRoot = personaRootURL(ctx)
        guard let target = selectedDocument ?? SwiftNativePersonaEngine.personaDocumentPath(kind: kind, root: personaRoot) else {
            return FileSystemActions.errResult("Could not resolve persona path", code: "bad_input")
        }

        let resolved = NativeAgentWorkspaceRoot.canonicalFileURL(target)
        let rootPath = personaRoot.resolvingSymlinksInPath().path
        guard let tail = NativeAgentWorkspaceRoot.relativePath(resolved.path, under: rootPath), !tail.isEmpty else {
            return FileSystemActions.errResult("Persona path escapes personaRoot.", code: "path_not_allowed")
        }
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
        let verbose = boolField(input["verbose"])
        let limit = intOrZero(input["limit"])
        let offset = intOrZero(input["offset"])

        let dataRoot = dataRootURL(ctx)
        var records: [String: PersonaEngine.SkillRecord] = [:]
        let entries: [PersonaEngine.SkillRecord]
        do {
            entries = try InstalledSkillInventory.entries(dataRoot: dataRoot)
        } catch {
            return FileSystemActions.errResult(
                "Could not load skill inventory: \(error.localizedDescription)", code: "skill_inventory_unavailable")
        }
        for entry in entries {
            records[entry.name] = entry
        }

        let sortedNames = records.keys.sorted()
        let totalCount = sortedNames.count

        // Negative offsets count from the end, clamped to zero; positive offsets cap at count; limit <= 0 is uncapped.
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

        let fullRecords = pageNames.compactMap { records[$0] }
        let manifest: [JSONValue]
        if verbose {
            manifest = fullRecords.map { skill in
                var row: [String: JSONValue] = ["name": .string(skill.name), "source": .string("persona"),
                    "path": .string(skill.bodyPath ?? ""), "description": .string(skill.description)]
                if !skill.triggers.isEmpty { row["triggers"] = .array(skill.triggers.map(JSONValue.string)) }
                if let kind = skill.kind { row["kind"] = .string(kind) }
                if let count = skill.useCount { row["use_count"] = .int(Int64(count)) }
                return .object(row)
            }
        } else {
            manifest = fullRecords.map {
                .object([
                    "name": .string($0.name),
                    "description": .string($0.description),
                    "source": .string("persona"),
                ])
            }
        }

        let sources: [String: JSONValue] = [
            "persona": .int(Int64(fullRecords.count)),
            "data": .int(0),
            "registry_only": .int(0),
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

    // MARK: - workspace_list

    static func workspaceList(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let workspaceRoot = workspaceRootURL(ctx)
        var subdir = (input["subdir"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while subdir.hasPrefix("/") { subdir.removeFirst() }

        // Resolve root and target identically before checking containment; listing never creates directories.
        let resolvedRoot = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rawTarget = subdir.isEmpty
            ? resolvedRoot
            : resolvedRoot.appendingPathComponent(subdir)
        let resolvedTarget = rawTarget.standardizedFileURL.resolvingSymlinksInPath()

        if NativeAgentWorkspaceRoot.relativePath(resolvedTarget.path, under: resolvedRoot.path) == nil {
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

        // Listing failures, including a file target, return ok=false and error without error_code.
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

        // Directories sort before files, each group by name.
        struct Entry { let isDir: Bool; let name: String; let size: Int64 }
        var entries: [Entry] = []
        for child in children {
            let name = child.lastPathComponent
            if name == ".gitkeep" { continue }
            var cIsDir: ObjCBool = false
            _ = fm.fileExists(atPath: child.path, isDirectory: &cIsDir)
            let isDirectory = cIsDir.boolValue
            // Directories and unreadable metadata report zero bytes.
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
            // Report paths relative to the resolved workspace root; do not resolve child symlinks away from listed names.
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

    /// Explicit workspaceRoot wins; otherwise NativeAgentWorkspaceRoot owns environment and install-root resolution.
    static func workspaceRootURL(_ ctx: ConnectorActionContext) -> URL {
        ctx.workspaceRoot ?? NativeAgentWorkspaceRoot.resolve(dataRoot: dataRootURL(ctx))
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
        var tzName = input["timezone"]?.stringValue ?? ""
        if tzName.isEmpty { tzName = (input["tz"]?.stringValue ?? "") }
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
        // Local-action timestamps use optional six-digit microseconds and an explicit ±HH:MM offset, including UTC.
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

/// Numbers and numeric strings truncate toward zero, booleans map to 0/1, and absent or invalid values yield zero.
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

/// Listed entry path relative to the resolved base, preserving the entry's symlink name.
private func relativePath(of entry: URL, base: URL) -> String {
    NativeAgentWorkspaceRoot.relativePath(entry.path, under: base.path) ?? entry.lastPathComponent
}

/// YYYY-MM-DDTHH:MM:SS.ffffff±HH:MM, omitting the fraction when microseconds are zero.
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

/// ±HH:MM; UTC is +00:00.
private func isoOffset(_ seconds: Int) -> String {
    let sign = seconds < 0 ? "-" : "+"
    let abs = Swift.abs(seconds)
    let h = abs / 3600
    let m = (abs % 3600) / 60
    return String(format: "%@%02d:%02d", sign, h, m)
}

/// ±HHMM without a colon.
private func formatUTCOffset(_ seconds: Int) -> String {
    let sign = seconds < 0 ? "-" : "+"
    let abs = Swift.abs(seconds)
    let h = abs / 3600
    let m = (abs % 3600) / 60
    return String(format: "%@%02d%02d", sign, h, m)
}

/// Gregorian weekday (1=Sunday … 7=Saturday) to its English name.
private func weekdayName(_ weekday: Int) -> String {
    let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    let idx = weekday - 1
    return (idx >= 0 && idx < names.count) ? names[idx] : "Sunday"
}
