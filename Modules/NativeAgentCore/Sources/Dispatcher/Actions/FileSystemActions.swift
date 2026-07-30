import Foundation
import MacControl
import PersistenceCore
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Wave 29 W3: Native Swift connector actions (DORMANT — no production wiring)
//
// Ports 5 SMALL, SELF-CONTAINED file/system connector action handlers from the
// retired runtime into Swift, so the SwiftNativeDispatcher can execute them
// natively. The five:
//
//   read_file     ← the retired daemon:_exec_read_file    (751)
//   file_excerpt  ← the retired daemon:_exec_file_excerpt (806)
//   write_file    ← the retired daemon:_exec_write_file   (859)
//   list_dir      ← the retired daemon:_exec_list_dir     (1622)
//   system_info   ← the retired daemon:_exec_system_info (3306)
//
// Each handler takes the same shape as the Python executor — `(input, context)`
// → result dict — and returns a `JSONValue` whose keys/values are byte-shape
// equivalent to the Python return dict (same keys, same defaults, same
// error_code strings). NOTHING here is wired into a production caller yet:
// `SwiftNativeDispatcher.dispatch` only consults this registry when explicitly
// enabled (see `LocalConnectorActions`), and the production factory leaves it
// off. Flipping callers through SwiftNative is a separate wave (CUTOVER_PLAN
// §6.30 disposition).
//
// Sandbox parity: the Python handlers gate on `_allowed_roots(context)` +
// `_is_sensitive_data_path(path, context)`. We reproduce both — driven entirely
// by the `repo_root`, `file_access`, and `_na_data_root` fields the caller
// puts in the action context — so the security posture is identical and the
// check is fully testable without touching global root resolution.

// MARK: - Constants

/// the retired daemon `_READ_FILE_DEFAULT_MAX_BYTES = 200_000`
let connectorReadFileDefaultMaxBytes = 200_000
/// Compact default for long handoff markdown files, unless max_bytes is explicit.
let connectorReadFileHandoffDefaultMaxBytes = 12_000
/// the retired daemon `_LIST_DIR_MAX_ENTRIES = 200`
let connectorListDirMaxEntries = 200
/// the retired daemon `_RESULT_MAX_CHARS = 30_000`
let connectorResultMaxChars = 30_000
/// the retired daemon `_GREP_MAX_RESULTS = 50`
let connectorGrepMaxResults = 50

/// Sensitive data sub-paths under data_root that are never accessible even if a
/// caller adds the full data_root to allowed_roots. Mirrors
/// the retired daemon:_SENSITIVE_DATA_SUBPATHS (691).
let connectorSensitiveDataSubpaths: Set<String> = [
    "oauth",
    "oauth_tokens",
    "secrets",
    "trust",
    "pairings",
    "providers",
    "codex_home",
    "macctl_bridge.json",
    "browser_ipc.json",
    "trust_policy.json",
]

// MARK: - Action context

/// The execution context a connector action reads. Distilled from the Python
/// `context` dict — only the fields the five ported handlers actually consult.
/// Built from a `DispatchContext`'s `repoRoot` + `extra` (`file_access`,
/// `_na_data_root`) in `ConnectorActionContext.fromDispatch`.
public struct ConnectorActionContext: Sendable {
    /// Resolution base for relative paths + an always-allowed root.
    public var repoRoot: String
    /// file_access dict: mode, sandbox, writableRoots, addDirs. Open-shape.
    public var fileAccess: [String: JSONValue]
    /// data root used for the sensitive-path block + data/skills allowance.
    public var dataRoot: String?
    /// Extra allowed roots beyond repo_root (persona root, workspace root).
    /// In Python these come from `_resolve_persona_root_at()` /
    /// `_resolve_workspace_root_at()`; we make them an explicit caller input so
    /// the sandbox is testable without global root resolution.
    public var extraAllowedRoots: [String]
    /// Persona root (SOUL.md / USER.md / VOICE.md / GROWTH.md / AGENTS.md +
    /// `skills/bodies/`). Wave 34 W06: consumed by `persona_read` /
    /// `persona_list_skills`. Mirrors Python `_resolve_na_persona_root(context)`
    /// — in test mode (`_na_data_root` override) the daemon uses
    /// `<dataRoot>/memory`, which is exactly what `fromDispatch` derives when a
    /// data-root override is present. With NO data-root override, persona root
    /// stays nil here and `PersonaSystemActions.personaRootURL` falls through to
    /// `PersistenceCore.defaultPersonaRoot()` (env / stamped-repo / default),
    /// mirroring `_resolve_persona_root_bt`.
    ///
    /// PARITY (gpt-5.5 review): the historical executor had NO `_na_persona_root`
    /// context override; persona root is ONLY derived from `_na_data_root`
    /// (test) or `_resolve_persona_root_bt()` (prod). So `fromDispatch` does NOT
    /// read a `_na_persona_root` key; it derives `<dataRoot>/memory` ONLY when
    /// `_na_data_root` is present.
    public var personaRoot: String?
    /// Workspace root (the `workspace/` dir `workspace_list` enumerates).
    /// Mirrors Python `context["_na_workspace_root"]` override /
    /// `_resolve_workspace_root_bt()`.
    public var workspaceRoot: String?

    public init(
        repoRoot: String,
        fileAccess: [String: JSONValue] = [:],
        dataRoot: String? = nil,
        extraAllowedRoots: [String] = [],
        personaRoot: String? = nil,
        workspaceRoot: String? = nil
    ) {
        self.repoRoot = repoRoot
        self.fileAccess = fileAccess
        self.dataRoot = dataRoot
        self.extraAllowedRoots = extraAllowedRoots
        self.personaRoot = personaRoot
        self.workspaceRoot = workspaceRoot
    }

    /// Build from a DispatchContext. `repo_root` comes from `ctx.repoRoot`;
    /// `file_access` / `_na_data_root` (if present) come from `ctx.extra`.
    public static func fromDispatch(_ ctx: DispatchContext) -> ConnectorActionContext {
        var fa: [String: JSONValue] = [:]
        if case .object(let obj)? = ctx.extra["file_access"] { fa = obj }
        var dataRoot: String? = nil
        // Python `_resolve_na_data_root`: `if override:` — an EMPTY string is
        // falsy and falls through to the default root (gpt-5.5 review). Require
        // non-empty so we don't derive a bogus `/memory` persona path below.
        if case .string(let s)? = ctx.extra["_na_data_root"], !s.isEmpty { dataRoot = s }
        var extra: [String] = []
        if case .array(let arr)? = ctx.extra["_extra_allowed_roots"] {
            for v in arr { if case .string(let s) = v { extra.append(s) } }
        }
        // Persona root: mirror `_resolve_na_persona_root` EXACTLY — under a
        // data-root override (test mode) the daemon uses `<dataRoot>/memory`;
        // otherwise it falls through to `_resolve_persona_root_bt()` which the
        // Swift side handles in `personaRootURL` (nil here → defaultPersonaRoot).
        // There is NO `_na_persona_root` override in Python, so we don't read one.
        var personaRoot: String? = nil
        if let dr = dataRoot {
            personaRoot = URL(fileURLWithPath: dr).appendingPathComponent("memory").path
        }
        var workspaceRoot: String? = nil
        if case .string(let s)? = ctx.extra["_na_workspace_root"] { workspaceRoot = s }
        return ConnectorActionContext(
            repoRoot: ctx.repoRoot,
            fileAccess: fa,
            dataRoot: dataRoot,
            extraAllowedRoots: extra,
            personaRoot: personaRoot,
            workspaceRoot: workspaceRoot
        )
    }
}

// MARK: - Path resolution + sandbox

enum FileSystemActions {

    /// Mirror `_resolve_path`: resolve a possibly
    /// relative path against repo_root, then canonicalise. We use
    /// `standardizedFileURL.resolvingSymlinksInPath()` so macOS
    /// `/var → /private/var` symlinks normalise the same way Python's
    /// `Path.resolve()` does.
    static func resolvePath(_ raw: String, repoRoot: String) -> URL {
        let base = repoRoot.isEmpty ? "." : repoRoot
        let expanded = (raw as NSString).expandingTildeInPath
        let p: URL
        if expanded.hasPrefix("/") {
            p = URL(fileURLWithPath: expanded)
        } else {
            p = URL(fileURLWithPath: base).appendingPathComponent(expanded)
        }
        return p.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Mirror `_allowed_roots`. Returns [] (sandbox
    /// disabled at this layer) when file_access mode == "full" OR sandbox ==
    /// "danger-full-access". Otherwise repo_root + writableRoots + addDirs +
    /// extraAllowedRoots + data/skills.
    static func allowedRoots(_ ctx: ConnectorActionContext) -> [URL] {
        let mode = stringField(ctx.fileAccess, "mode").lowercased()
        let sandbox = stringField(ctx.fileAccess, "sandbox").lowercased()
        if mode == "full" || sandbox == "danger-full-access" {
            return []  // disable sandbox at this layer; sensitive-path block stays.
        }
        var roots: [URL] = []
        func add(_ raw: String) {
            guard !raw.isEmpty else { return }
            let u = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
            if !roots.contains(u) { roots.append(u) }
        }
        if !ctx.repoRoot.isEmpty { add(ctx.repoRoot) }
        if case .array(let arr)? = ctx.fileAccess["writableRoots"] {
            for v in arr { if case .string(let s) = v { add(s) } }
        }
        if case .array(let arr)? = ctx.fileAccess["addDirs"] {
            for v in arr { if case .string(let s) = v { add(s) } }
        }
        for r in ctx.extraAllowedRoots { add(r) }
        // data/skills sub-tree only (committed skill bodies). NOT full data root.
        if let dr = ctx.dataRoot, !dr.isEmpty {
            add(URL(fileURLWithPath: dr).appendingPathComponent("skills").path)
        }
        return roots
    }

    /// Mirror `_is_within_roots`.
    static func isWithinRoots(_ path: URL, _ roots: [URL]) -> Bool {
        let target = path.standardizedFileURL.resolvingSymlinksInPath().path
        for root in roots {
            let r = root.standardizedFileURL.resolvingSymlinksInPath().path
            if target == r { return true }
            let prefix = r.hasSuffix("/") ? r : r + "/"
            if target.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// Mirror `_is_sensitive_data_path`. True when
    /// path falls under a sensitive sub-tree of data_root.
    ///
    /// SECURITY parity (gpt-5.5 review): Python falls back to the *default*
    /// data root (`_resolve_data_root_at()`) when no `_na_data_root` override is
    /// present, so OAuth tokens / secrets / pairing keys stay blocked even when
    /// the caller didn't thread a data root through. Swift must do the same —
    /// returning `false` on a nil dataRoot would silently open the sensitive
    /// sub-tree under full-mode or a broad allowed root.
    static func isSensitiveDataPath(_ path: URL, _ ctx: ConnectorActionContext) -> Bool {
        let dr: String
        if let explicit = ctx.dataRoot, !explicit.isEmpty {
            dr = explicit
        } else {
            dr = PersistenceCore.defaultDataRoot().path
        }
        guard !dr.isEmpty else { return false }
        let dataRoot = URL(fileURLWithPath: dr).standardizedFileURL.resolvingSymlinksInPath()
        let resolved = path.standardizedFileURL.resolvingSymlinksInPath()
        // rel = resolved relative to dataRoot
        let drPath = dataRoot.path
        let pPath = resolved.path
        let prefix = drPath.hasSuffix("/") ? drPath : drPath + "/"
        guard pPath == drPath || pPath.hasPrefix(prefix) else { return false }
        let relStr = pPath == drPath ? "" : String(pPath.dropFirst(prefix.count))
        let parts = relStr.split(separator: "/").map(String.init)
        guard let first = parts.first else { return false }
        if connectorSensitiveDataSubpaths.contains(first) { return true }
        if parts.count >= 2 && parts[0] == "nextgen" && parts[1] == "remote" { return true }
        // *.bin directly under data root (pairing secrets etc.)
        if parts.count == 1 && resolved.pathExtension == "bin" { return true }
        return false
    }

    /// Mirror `_truncate`.
    static func truncate(_ text: String, maxChars: Int = connectorResultMaxChars) -> String {
        if text.count <= maxChars { return text }
        let remaining = text.count - maxChars
        let head = String(text.prefix(maxChars))
        return head + "\n...(truncated, \(remaining) more bytes)"
    }

    static func shouldUseCompactReadDefault(path: URL, actualBytes: Int) -> Bool {
        guard actualBytes > connectorResultMaxChars else { return false }
        guard path.pathExtension.lowercased() == "md" else { return false }
        return path.deletingPathExtension().lastPathComponent.lowercased().contains("handoff")
    }

    /// Mirror `_safe_int`. Returns default when
    /// value is null/empty; returns nil (bad_input signal) when unparseable.
    static func safeInt(_ value: JSONValue?, default def: Int) -> Int? {
        switch value ?? .null {
        case .null: return def
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .string(let s):
            if s.isEmpty { return def }
            if let i = Int(s) { return i }
            return nil
        default: return nil
        }
    }

    // MARK: helpers

    static func stringField(_ obj: [String: JSONValue], _ key: String) -> String {
        if case .string(let s)? = obj[key] { return s }
        return ""
    }

    static func errResult(_ message: String, code: String? = nil) -> JSONValue {
        var obj: [String: JSONValue] = ["ok": .bool(false), "error": .string(message)]
        if let code { obj["error_code"] = .string(code) }
        return .object(obj)
    }

    // MARK: - read_file

    static func readFile(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let rawPath = stringField(input, "path")
        if rawPath.isEmpty { return errResult("path is required", code: "bad_input") }
        let rawMb = input["max_bytes"]
        let hasExplicitMaxBytes: Bool = {
            switch rawMb {
            case nil, .some(.null): return false
            default: return true
            }
        }()
        guard var maxBytes = safeInt(rawMb, default: connectorReadFileDefaultMaxBytes) else {
            return errResult("max_bytes must be an integer, got \(jsonRepr(rawMb))", code: "bad_input")
        }
        maxBytes = min(maxBytes, connectorReadFileDefaultMaxBytes)
        // Guard against a negative max_bytes trapping Data.prefix(_:). Python's
        // negative slice is a misuse-case quirk; clamp to 0 (empty window).
        maxBytes = max(0, maxBytes)

        let resolved = resolvePath(rawPath, repoRoot: ctx.repoRoot)
        let allowed = allowedRoots(ctx)
        if !allowed.isEmpty && !isWithinRoots(resolved, allowed) {
            return errResult(
                "Path '\(resolved.path)' is outside allowed sandbox roots: \(rootsRepr(allowed))",
                code: "path_not_allowed"
            )
        }
        if isSensitiveDataPath(resolved, ctx) {
            return errResult(
                "Path '\(resolved.path)' is under a sensitive data sub-tree (OAuth tokens, "
                + "pairing secrets, provider credentials, trust policy). "
                + "Use dedicated Swift runtime tools such as agent_introspect or recall_search instead.",
                code: "path_not_allowed"
            )
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir)
        if !exists { return errResult("File not found: \(resolved.path)", code: "file_not_found") }
        if isDir.boolValue { return errResult("Not a file: \(resolved.path)", code: "file_not_found") }

        guard let rawData = FileManager.default.contents(atPath: resolved.path) else {
            return errResult("could not read file")
        }
        let actualBytes = rawData.count
        if !hasExplicitMaxBytes && shouldUseCompactReadDefault(path: resolved, actualBytes: actualBytes) {
            maxBytes = min(maxBytes, connectorReadFileHandoffDefaultMaxBytes)
        }
        let slice = actualBytes > maxBytes ? rawData.prefix(maxBytes) : rawData[...]
        // Python: decode("utf-8", errors="replace")
        let content = decodeUTF8Replacing(Data(slice))
        return .object([
            "ok": .bool(true),
            "path": .string(resolved.path),
            "bytes": .int(Int64(actualBytes)),
            "returned_bytes": .int(Int64(slice.count)),
            "truncated": .bool(actualBytes > slice.count),
            "content": .string(truncate(content)),
        ])
    }

    // MARK: - file_excerpt

    static func fileExcerpt(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let rawPath = stringField(input, "path")
        if rawPath.isEmpty { return errResult("path is required", code: "bad_input") }
        guard let startLineRaw = safeInt(input["start_line"], default: 1),
              let maxLinesRaw = safeInt(input["max_lines"], default: 80) else {
            return errResult("start_line and max_lines must be integers", code: "bad_input")
        }
        let startLine = max(1, startLineRaw)
        let maxLines = max(1, min(maxLinesRaw, 240))

        let resolved = resolvePath(rawPath, repoRoot: ctx.repoRoot)
        let allowed = allowedRoots(ctx)
        if !allowed.isEmpty && !isWithinRoots(resolved, allowed) {
            return errResult(
                "Path '\(resolved.path)' is outside allowed sandbox roots: \(rootsRepr(allowed))",
                code: "path_not_allowed"
            )
        }
        if isSensitiveDataPath(resolved, ctx) {
            return errResult("Path '\(resolved.path)' is under a sensitive data sub-tree.", code: "path_not_allowed")
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir)
        if !exists { return errResult("File not found: \(resolved.path)", code: "file_not_found") }
        if isDir.boolValue { return errResult("Not a file: \(resolved.path)", code: "file_not_found") }

        guard let rawData = FileManager.default.contents(atPath: resolved.path) else {
            return errResult("could not read file")
        }
        let text = decodeUTF8Replacing(rawData)
        // Python: str.splitlines() — split on universal newlines, no trailing empty.
        let lines = splitLines(text)
        let total = lines.count
        let startIdx = min(startLine - 1, total)
        let endIdx = min(total, startIdx + maxLines)
        var rendered: [String] = []
        if startIdx < endIdx {
            for idx in startIdx..<endIdx {
                rendered.append("\(idx + 1): \(lines[idx])")
            }
        }
        return .object([
            "ok": .bool(true),
            "path": .string(resolved.path),
            "start_line": .int(Int64(total > 0 ? startIdx + 1 : 1)),
            "end_line": .int(Int64(endIdx)),
            "total_lines": .int(Int64(total)),
            "excerpt": .string(rendered.joined(separator: "\n")),
            "truncated": .bool(endIdx < total),
        ])
    }

    // MARK: - write_file

    static func writeFile(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let rawPath = stringField(input, "path")
        if rawPath.isEmpty { return errResult("path is required", code: "bad_input") }
        guard let contentVal = input["content"], !isNull(contentVal) else {
            return errResult("content is required", code: "bad_input")
        }
        let content = jsonToStr(contentVal)
        let append: Bool = {
            if case .bool(let b)? = input["append"] { return b }
            return false
        }()

        let resolved = resolvePath(rawPath, repoRoot: ctx.repoRoot)
        let allowed = allowedRoots(ctx)
        let sandbox = stringField(ctx.fileAccess, "sandbox")
        let mode = stringField(ctx.fileAccess, "mode")
        if sandbox == "read-only" || mode == "read_only" {
            return errResult(
                "Sandbox is read-only — cannot write files. Request write access for this session.",
                code: "path_not_allowed"
            )
        }
        if !allowed.isEmpty && !isWithinRoots(resolved, allowed) {
            return errResult(
                "Path '\(resolved.path)' is outside writable sandbox roots: \(rootsRepr(allowed))",
                code: "path_not_allowed"
            )
        }
        if isSensitiveDataPath(resolved, ctx) {
            return errResult(
                "Path '\(resolved.path)' is under a sensitive data sub-tree (OAuth tokens, "
                + "pairing secrets, provider credentials, trust policy). "
                + "Writes to these paths are not permitted via write_file. "
                + "Use dedicated Swift runtime tools instead.",
                code: "path_not_allowed"
            )
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: resolved.path) {
            return errResult(reason, code: "path_not_allowed")
        }

        let fm = FileManager.default
        // before_content for inline diff (only on overwrite, not append), ≤ 200 kB.
        var beforeContent: String? = nil
        if !append {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue {
                if let before = fm.contents(atPath: resolved.path), before.count <= 200_000 {
                    beforeContent = decodeUTF8Replacing(before)
                }
            }
        }

        do {
            let parent = resolved.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let data = Data(content.utf8)
            if append {
                if fm.fileExists(atPath: resolved.path) {
                    let handle = try FileHandle(forWritingTo: resolved)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: resolved)
                }
            } else {
                // Atomic overwrite via tmp + POSIX rename(2) (matches retired
                // os.replace: atomic, creates-or-replaces the destination).
                // FileManager.replaceItemAt is NOT used — its create-on-missing
                // behavior is undocumented and it can return a moved URL. The
                // .tmp is removed in a defer so a failed write/rename never
                // leaks it (state-lifecycle: every create has a remove path).
                let tmpName = "\(resolved.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString.prefix(8)).tmp"
                let tmp = parent.appendingPathComponent(tmpName)
                defer { try? fm.removeItem(at: tmp) }
                try data.write(to: tmp)
                let rc = tmp.withUnsafeFileSystemRepresentation { src -> Int32 in
                    resolved.withUnsafeFileSystemRepresentation { dst -> Int32 in
                        guard let src, let dst else { return -1 }
                        return rename(src, dst)
                    }
                }
                if rc != 0 {
                    let err = String(cString: strerror(errno))
                    return errResult("atomic write failed: \(err)")
                }
            }
        } catch {
            return errResult(error.localizedDescription)
        }

        var result: [String: JSONValue] = [
            "ok": .bool(true),
            "path": .string(resolved.path),
            "bytes_written": .int(Int64(Data(content.utf8).count)),
            "append": .bool(append),
        ]
        if !append {
            if let bc = beforeContent {
                result["before_content"] = .string(String(bc.prefix(8000)))
            }
            result["after_content"] = .string(String(content.prefix(8000)))
        }
        return .object(result)
    }

    // MARK: - list_dir

    static func listDir(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let rawPath = stringField(input, "path")
        if rawPath.isEmpty { return errResult("path is required", code: "bad_input") }
        let rawMe = input["max_entries"]
        guard var maxEntries = safeInt(rawMe, default: connectorListDirMaxEntries) else {
            return errResult("max_entries must be an integer, got \(jsonRepr(rawMe))", code: "bad_input")
        }
        maxEntries = min(maxEntries, connectorListDirMaxEntries)
        // Guard against a negative max_entries trapping prefix(_:).
        maxEntries = max(0, maxEntries)

        let resolved = resolvePath(rawPath, repoRoot: ctx.repoRoot)
        let allowed = allowedRoots(ctx)
        if !allowed.isEmpty && !isWithinRoots(resolved, allowed) {
            return errResult(
                "Path '\(resolved.path)' is outside sandbox roots: \(rootsRepr(allowed))",
                code: "path_not_allowed"
            )
        }
        if isSensitiveDataPath(resolved, ctx) {
            return errResult(
                "Path '\(resolved.path)' is under a sensitive data sub-tree (OAuth tokens, "
                + "pairing secrets, provider credentials, trust policy). "
                + "Use dedicated Swift runtime tools instead.",
                code: "path_not_allowed"
            )
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: resolved.path, isDirectory: &isDir)
        if !exists { return errResult("Directory not found: \(resolved.path)", code: "file_not_found") }
        if !isDir.boolValue { return errResult("Not a directory: \(resolved.path)", code: "file_not_found") }

        // Read dirent type information from the PARENT directory. The former
        // implementation called fileExists for every child merely to sort
        // directories first. A child that is a dormant network/virtio mount can
        // block that metadata probe for minutes even though listing its parent
        // is immediate. readdir's d_type classifies the entry without entering
        // the child mount. Unknown/symlink types are conservatively presented
        // as files; list_dir is presentation-only and must not follow them.
        struct Entry { let name: String; let isFile: Bool }
        var entries: [Entry] = []
        #if canImport(Darwin)
        guard let directory = opendir(resolved.path) else {
            return errResult(String(cString: strerror(errno)))
        }
        defer { closedir(directory) }
        errno = 0
        while let pointer = readdir(directory) {
            var bytes = pointer.pointee.d_name
            let name = withUnsafePointer(to: &bytes) { tuplePointer in
                tuplePointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            entries.append(Entry(
                name: name,
                isFile: pointer.pointee.d_type != UInt8(DT_DIR)
            ))
        }
        if errno != 0 {
            return errResult(String(cString: strerror(errno)))
        }
        #else
        do {
            entries = try fm.contentsOfDirectory(atPath: resolved.path)
                .map { Entry(name: $0, isFile: true) }
        } catch {
            return errResult(error.localizedDescription)
        }
        #endif
        entries.sort { lhs, rhs in
            if lhs.isFile != rhs.isFile { return !lhs.isFile && rhs.isFile }
            return lhs.name < rhs.name
        }
        var out: [JSONValue] = []
        for e in entries.prefix(maxEntries) {
            out.append(.string(e.isFile ? e.name : e.name + "/"))
        }
        var result: [String: JSONValue] = [
            "ok": .bool(true),
            "path": .string(resolved.path),
            "entries": .array(out),
            "count": .int(Int64(out.count)),
        ]
        if entries.count > maxEntries {
            result["truncated"] = .bool(true)
            result["total_visible"] = .int(Int64(entries.count))
        }
        return .object(result)
    }

    // MARK: - system_info

    static func systemInfo(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        var failures: [String] = []

        // Disk: statfs("/") → total/used/free GB + percent_used.
        do {
            var st = statfs()
            if statfs("/", &st) == 0 {
                // Match Python shutil.disk_usage: total = f_blocks * f_frsize,
                // free = f_bavail * f_frsize (user-available), used =
                // (f_blocks - f_bfree) * f_frsize. Note used uses f_bfree (all
                // free blocks incl. root-reserved), NOT f_bavail — so
                // total != used + free, exactly as Python reports it.
                let blockSize = UInt64(st.f_bsize)
                let total = UInt64(st.f_blocks) * blockSize
                let free = UInt64(st.f_bavail) * blockSize
                let used = UInt64(st.f_blocks >= st.f_bfree ? st.f_blocks - st.f_bfree : 0) * blockSize
                func gb(_ v: UInt64) -> Double { round2(Double(v) / 1_073_741_824.0) }
                let pct = total > 0 ? round1(Double(used) / Double(total) * 100.0) : 0.0
                fields["disk"] = .object([
                    "total_gb": .double(gb(total)),
                    "used_gb": .double(gb(used)),
                    "free_gb": .double(gb(free)),
                    "percent_used": .double(pct),
                ])
            } else {
                failures.append("disk: statfs failed")
            }
        }

        // Memory: vm_stat output → pages × page_size → MB.
        if let vmOut = runCommand("/usr/bin/vm_stat", []) , vmOut.status == 0 {
            let text = vmOut.stdout
            var pageSize = 4096
            if let ps = firstCapturedInt(in: text, pattern: #"page size of (\d+) bytes"#) {
                pageSize = ps
            }
            func pages(_ label: String) -> Int {
                firstCapturedInt(in: text, pattern: "\(NSRegularExpression.escapedPattern(for: label)):\\s+([\\d.]+)") ?? 0
            }
            let free = pages("Pages free")
            let active = pages("Pages active")
            let inactive = pages("Pages inactive")
            let wired = pages("Pages wired down")
            let speculative = pages("Pages speculative")
            func toMB(_ p: Int) -> Int64 { Int64((Double(p) * Double(pageSize) / (1024.0 * 1024.0)).rounded()) }
            let totalPages = free + active + inactive + wired + speculative
            fields["memory"] = .object([
                "free_mb": .int(toMB(free)),
                "active_mb": .int(toMB(active)),
                "inactive_mb": .int(toMB(inactive)),
                "wired_mb": .int(toMB(wired)),
                "total_mb": .int(toMB(totalPages)),
            ])
        } else {
            failures.append("memory: vm_stat failed")
        }

        // Network: ping 8.8.8.8 → reachable bool.
        if let ping = runCommand("/sbin/ping", ["-c", "1", "-W", "1000", "8.8.8.8"]) {
            fields["network"] = .object(["reachable": .bool(ping.status == 0)])
        } else {
            failures.append("network: ping failed")
        }

        // Screen lock: pmset -g → CGSSessionScreenIsLocked = 0/1.
        if let pm = runCommand("/usr/bin/pmset", ["-g"]), pm.status == 0 {
            if let m = firstCapturedString(in: pm.stdout, pattern: #"CGSSessionScreenIsLocked\s*=\s*(\d)"#) {
                fields["screen_lock"] = .object(["locked": .bool(m == "1")])
            } else {
                fields["screen_lock"] = .object(["locked": .bool(false)])
            }
        } else {
            failures.append("screen_lock: pmset failed")
        }

        // Battery: pmset -g batt → percent/charging/source.
        if let batt = runCommand("/usr/bin/pmset", ["-g", "batt"]), batt.status == 0 {
            let out = batt.stdout
            let source: JSONValue = firstCapturedString(in: out, pattern: #"Now drawing from '([^']+)'"#)
                .map { .string($0) } ?? .null
            let percent: JSONValue = firstCapturedInt(in: out, pattern: #"(\d+)%;"#)
                .map { .int(Int64($0)) } ?? .null
            var charging: JSONValue = .null
            let lower = out.lowercased()
            if lower.contains("charging") {
                charging = .bool(!lower.contains("discharging"))
            }
            fields["battery"] = .object([
                "percent": percent,
                "charging": charging,
                "source": source,
            ])
        } else {
            // Desktop Mac — no battery.
            fields["battery"] = .object([
                "percent": .null,
                "charging": .null,
                "source": .string("AC Power"),
            ])
        }

        if !failures.isEmpty && fields.isEmpty {
            return .object([
                "ok": .bool(false),
                "error": .string(failures.joined(separator: "; ")),
                "error_code": .string("system_info_partial"),
            ])
        }
        var result: [String: JSONValue] = ["ok": .bool(true)]
        for (k, v) in fields { result[k] = v }
        if !failures.isEmpty {
            result["partial_failures"] = .array(failures.map { .string($0) })
            result["error_code"] = .string("system_info_partial")
        }
        return .object(result)
    }

    // MARK: - grep
    //
    // Wave 32 W08: read-only repo search. Mirrors `_exec_grep` byte-for-byte:
    // pattern required (bad_input), `max_results` via `safeInt` capped at
    // `_GREP_MAX_RESULTS = 50` (unparseable → bad_input, matching Python's
    // `if max_results is None`), search_path = `inp.path or repo_root` resolved
    // against repo_root, sandbox + sensitive-data block, `rg` if on PATH else
    // `grep -rnE`. grep/rg exit code 2 = grep_error; otherwise the first
    // `max_results` output lines are returned (joined + truncated). Timeout 30s
    // → bash_timeout, any other launch failure → generic error (no error_code).

    static func grep(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let pattern = stringField(input, "pattern").trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.isEmpty { return errResult("pattern is required", code: "bad_input") }
        let rawMr = input["max_results"]
        guard let parsedMr = safeInt(rawMr, default: connectorGrepMaxResults) else {
            return errResult("max_results must be an integer, got \(jsonRepr(rawMr))", code: "bad_input")
        }
        // PARITY (gpt-5.5 review): Python does ONLY `min(max_results, 50)` — no
        // lower clamp — then passes `str(max_results)` to `rg -m`/`grep -m`. A
        // negative value makes rg/grep reject the arg (exit 2 → grep_error)
        // BEFORE the output slice runs. So pass the (possibly-negative) capped
        // value to the subprocess verbatim to reproduce the grep_error path; the
        // Swift `prefix(_:)` later is guarded separately (it would trap on a
        // negative). Non-negative values behave identically to Python.
        let maxResults = min(parsedMr, connectorGrepMaxResults)
        let sliceCount = max(0, maxResults)

        // Python: `raw_search_path = inp.get("path") or str(repo_root)` — the
        // `or` makes an empty-string path fall back to repo_root too.
        let rawPathField = stringField(input, "path")
        let rawSearchPath = rawPathField.isEmpty ? (ctx.repoRoot.isEmpty ? "." : ctx.repoRoot) : rawPathField
        let searchPath = resolvePath(rawSearchPath, repoRoot: ctx.repoRoot)

        let allowed = allowedRoots(ctx)
        if !allowed.isEmpty && !isWithinRoots(searchPath, allowed) {
            return errResult(
                "Path '\(searchPath.path)' is outside sandbox roots: \(rootsRepr(allowed))",
                code: "path_not_allowed"
            )
        }
        if isSensitiveDataPath(searchPath, ctx) {
            return errResult(
                "Path '\(searchPath.path)' is under a sensitive data sub-tree (OAuth tokens, "
                + "pairing secrets, provider credentials, trust policy). "
                + "Use dedicated Swift runtime tools instead.",
                code: "path_not_allowed"
            )
        }

        let rgPath = which("rg")
        let launch: String
        let args: [String]
        if let rg = rgPath {
            launch = rg
            args = ["--no-heading", "--line-number", "-m", String(maxResults), pattern, searchPath.path]
        } else if let grepBin = which("grep") {
            launch = grepBin
            args = ["-rnE", "--include=*", "-m", String(maxResults), pattern, searchPath.path]
        } else {
            // Python would raise FileNotFoundError from subprocess.run → caught by
            // the broad `except Exception` → generic error (no error_code).
            return errResult("grep not found")
        }

        let run = runProcess(launch, args, timeout: 30)
        if run.timedOut { return errResult("grep timed out after 30s", code: "bash_timeout") }
        if !run.launched { return errResult("could not run grep") }
        // grep exit 1 = no matches (ok); exit 2 = error.
        if run.status == 2 {
            let stderr = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return errResult(stderr.isEmpty ? "grep error" : stderr, code: "grep_error")
        }
        let rawOutput = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // Python: raw_output.splitlines()[:max_results]. Use the guarded
        // sliceCount (negatives already errored at the subprocess above).
        let lines = Array(splitLines(rawOutput).prefix(sliceCount))
        let output = truncate(lines.joined(separator: "\n"))
        return .object([
            "ok": .bool(true),
            "pattern": .string(pattern),
            "path": .string(searchPath.path),
            "matches": .int(Int64(lines.count)),
            "output": .string(output),
        ])
    }

    // MARK: - git_status
    //
    // Wave 32 W08: `git status --short --branch`, parsed into branch plus
    // staged/unstaged/untracked.
    // cwd = `inp.cwd or repo_root` resolved + sandbox-validated. git-missing →
    // git_unavailable, timeout → git_unavailable, non-zero exit → git_unavailable.

    static func gitStatus(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        guard let cwd = gitResolveCwd(input, ctx, tool: "git_status") else {
            return gitCwdBlocked(input, ctx, tool: "git_status")
        }
        let run = runGit(["status", "--short", "--branch"], cwd: cwd, timeout: 15, label: "git status")
        if case .failure(let f) = run { return f }
        guard case .success(let result) = run else { return errResult("git status failed", code: "git_unavailable") }

        var staged: [JSONValue] = []
        var unstaged: [JSONValue] = []
        var untracked: [JSONValue] = []
        var branch = ""
        var ahead = 0
        var behind = 0
        for (idx, line) in splitLines(result.stdout).enumerated() {
            if idx == 0 && line.hasPrefix("## ") {
                branch = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if branch.contains("[ahead ") {
                    ahead = parseTrailingInt(branch, after: "[ahead ") ?? 0
                }
                if branch.contains("behind ") {
                    behind = parseTrailingInt(branch, after: "behind ") ?? 0
                }
                continue
            }
            // Python: `if len(line) < 2: continue`; xy=line[:2]; fname=line[3:].
            let chars = Array(line)
            if chars.count < 2 { continue }
            let x = chars[0]
            let y = chars[1]
            let fname = chars.count > 3 ? String(chars[3...]) : ""
            if x == "?" && y == "?" {
                untracked.append(.string(fname))
            } else {
                if x != " " && x != "?" { staged.append(.string(fname)) }
                if y != " " && y != "?" { unstaged.append(.string(fname)) }
            }
        }
        let clean = staged.isEmpty && unstaged.isEmpty && untracked.isEmpty
        return .object([
            "ok": .bool(true),
            "branch": .string(branch),
            "ahead": .int(Int64(ahead)),
            "behind": .int(Int64(behind)),
            "clean": .bool(clean),
            "staged": .array(staged),
            "unstaged": .array(unstaged),
            "untracked": .array(untracked),
            "raw": .string(result.stdout),
        ])
    }

    // MARK: - git_diff
    //
    // Wave 32 W08: working-tree or staged diff. `staged` bool, `path` filter.
    // Exit codes 0/1 are OK (1 = diff present under some git configs); anything
    // else → git_unavailable. `bytes` reports the UN-truncated stdout length
    // (Python `len(result.stdout)` = character count), `diff` is truncated.

    static func gitDiff(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        guard let cwd = gitResolveCwd(input, ctx, tool: "git_diff") else {
            return gitCwdBlocked(input, ctx, tool: "git_diff")
        }
        let staged: Bool = {
            if case .bool(let b)? = input["staged"] { return b }
            return false
        }()
        let pathFilter = stringField(input, "path")
        var args = ["diff"]
        if staged { args.append("--staged") }
        if !pathFilter.isEmpty { args.append(contentsOf: ["--", pathFilter]) }

        let run = runGit(args, cwd: cwd, timeout: 30, label: "git diff", okStatuses: [0, 1])
        if case .failure(let f) = run { return f }
        guard case .success(let result) = run else { return errResult("git diff failed", code: "git_unavailable") }
        return .object([
            "ok": .bool(true),
            "staged": .bool(staged),
            "diff": .string(truncate(result.stdout)),
            // PARITY (gpt-5.5 review): Python `len(result.stdout)` counts Unicode
            // CODE POINTS, not grapheme clusters. Swift String.count is grapheme
            // clusters (an emoji or combining sequence collapses to 1), so use
            // unicodeScalars.count to match Python's len() on the str.
            "bytes": .int(Int64(result.stdout.unicodeScalars.count)),
        ])
    }

    // MARK: - git_log
    //
    // Wave 32 W08: recent commits. limit via `safeInt(default:10) or 10` capped
    // at 100 (retired behavior: `min(_safe_int(...) or 10, 100)` — unparseable OR
    // zero falls back to 10, NOT bad_input, unlike grep). Format
    // `%h|%an|%ai|%s` split into hash/author/date/subject.

    static func gitLog(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        guard let cwd = gitResolveCwd(input, ctx, tool: "git_log") else {
            return gitCwdBlocked(input, ctx, tool: "git_log")
        }
        // Python: min(_safe_int(inp.get("limit"), default=10) or 10, 100).
        // safeInt returns nil on unparseable; `or 10` also coerces 0 → 10.
        let parsed = safeInt(input["limit"], default: 10)
        let limit = min((parsed == nil || parsed == 0) ? 10 : parsed!, 100)

        let run = runGit(["log", "-n\(limit)", "--format=%h|%an|%ai|%s"], cwd: cwd, timeout: 15, label: "git log")
        if case .failure(let f) = run { return f }
        guard case .success(let result) = run else { return errResult("git log failed", code: "git_unavailable") }

        var commits: [JSONValue] = []
        for rawLine in splitLines(result.stdout) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let parts = splitN(line, separator: "|", maxSplits: 3)
            commits.append(.object([
                "hash": .string(parts.count > 0 ? parts[0] : ""),
                "author": .string(parts.count > 1 ? parts[1] : ""),
                "date": .string(parts.count > 2 ? parts[2] : ""),
                "subject": .string(parts.count > 3 ? parts[3] : ""),
            ]))
        }
        return .object([
            "ok": .bool(true),
            "commits": .array(commits),
            "count": .int(Int64(commits.count)),
        ])
    }

    // MARK: - repo_dirty_summary
    //
    // Wave 32 W08: combined `git status --short --branch` + `git log` (limit via
    // `safeInt(default:5) or 5` capped at 20). Parses branch + ahead/behind from
    // the `## ` header line and staged/unstaged/untracked from the body, plus a
    // short commit list. status non-zero → git_unavailable; the log sub-command
    // is best-effort (an empty commit list if it fails), matching Python.

    static func repoDirtySummary(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        guard let cwd = gitResolveCwd(input, ctx, tool: "repo_dirty_summary") else {
            return gitCwdBlocked(input, ctx, tool: "repo_dirty_summary")
        }
        let parsed = safeInt(input["log_limit"], default: 5)
        let logLimit = min((parsed == nil || parsed == 0) ? 5 : parsed!, 20)

        // Python runs both inside ONE try; FileNotFound/timeout on EITHER →
        // git_unavailable. Run status first (its non-zero is a hard error), then
        // log (best-effort: a non-zero log just yields an empty commit list).
        let statusRun = runGit(["status", "--short", "--branch"], cwd: cwd, timeout: 15,
                               label: "git status", treatNotAGitRepoSpecially: false)
        switch statusRun {
        case .failure(let f): return f
        case .success(let status):
            let logRun = runGit(["log", "-n\(logLimit)", "--format=%h|%s"], cwd: cwd, timeout: 15,
                                label: "git log", treatNotAGitRepoSpecially: false)
            // A FileNotFound/timeout on the log sub-command is a hard failure in
            // Python (same outer try). A non-zero exit is NOT (commits stays []).
            if case .failure(let lf) = logRun, isProcessLevelFailure(logRun) { return lf }

            var staged: [JSONValue] = []
            var unstaged: [JSONValue] = []
            var untracked: [JSONValue] = []
            var branch = ""
            var ahead = 0
            var behind = 0
            for (idx, line) in splitLines(status.stdout).enumerated() {
                if idx == 0 && line.hasPrefix("## ") {
                    branch = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    if branch.contains("[ahead ") {
                        ahead = parseTrailingInt(branch, after: "[ahead ") ?? 0
                    }
                    if branch.contains("behind ") {
                        behind = parseTrailingInt(branch, after: "behind ") ?? 0
                    }
                    continue
                }
                let chars = Array(line)
                if chars.count < 2 { continue }
                let xy = String(chars[0...1])
                let fname = chars.count > 3 ? String(chars[3...]) : ""
                if xy == "??" {
                    untracked.append(.string(fname))
                } else {
                    if chars[0] != " " && chars[0] != "?" { staged.append(.string(fname)) }
                    if chars[1] != " " && chars[1] != "?" { unstaged.append(.string(fname)) }
                }
            }
            var commits: [JSONValue] = []
            if case .success(let log) = logRun {
                for line in splitLines(log.stdout) {
                    let parts = splitN(line, separator: "|", maxSplits: 1)
                    commits.append(.object([
                        "hash": .string(parts.count > 0 ? parts[0] : ""),
                        "subject": .string(parts.count > 1 ? parts[1] : ""),
                    ]))
                }
            }
            let clean = staged.isEmpty && unstaged.isEmpty && untracked.isEmpty
            return .object([
                "ok": .bool(true),
                "branch": .string(branch),
                "ahead": .int(Int64(ahead)),
                "behind": .int(Int64(behind)),
                "clean": .bool(clean),
                "staged": .array(staged),
                "unstaged": .array(unstaged),
                "untracked": .array(untracked),
                "commits": .array(commits),
            ])
        }
    }

    // MARK: - git helpers (Wave 32 W08)

    /// Outcome of a `git` sub-process run, classified the way the Python
    /// executors do: a clean `.success(stdout)`, or a `.failure(errDict)` already
    /// shaped into the git_unavailable error result.
    enum GitRun {
        case success(GitResult)
        case failure(JSONValue)
    }
    struct GitResult { let stdout: String; let status: Int32 }

    /// Resolve+sandbox-validate the git `cwd` arg. Returns the resolved URL when
    /// allowed, or nil when blocked (caller emits `gitCwdBlocked`). Mirrors the
    /// C4-fix in every git executor: `cwd = inp.cwd or repo_root`, resolved, then
    /// `_allowed_roots` membership.
    static func gitResolveCwd(_ input: [String: JSONValue], _ ctx: ConnectorActionContext, tool: String) -> URL? {
        let rawCwd = stringField(input, "cwd")
        let base = rawCwd.isEmpty ? (ctx.repoRoot.isEmpty ? "." : ctx.repoRoot) : rawCwd
        let cwd = resolvePath(base, repoRoot: ctx.repoRoot)
        let allowed = allowedRoots(ctx)
        if !allowed.isEmpty && !isWithinRoots(cwd, allowed) { return nil }
        return cwd
    }

    static func gitCwdBlocked(_ input: [String: JSONValue], _ ctx: ConnectorActionContext, tool: String) -> JSONValue {
        let rawCwd = stringField(input, "cwd")
        let base = rawCwd.isEmpty ? (ctx.repoRoot.isEmpty ? "." : ctx.repoRoot) : rawCwd
        let cwd = resolvePath(base, repoRoot: ctx.repoRoot)
        let allowed = allowedRoots(ctx)
        return errResult(
            "\(tool) cwd '\(cwd.path)' is outside allowed sandbox roots: \(rootsRepr(allowed))",
            code: "path_not_allowed"
        )
    }

    /// Run `git <args>` in `cwd`. Mirrors the Python error taxonomy: git binary
    /// missing → "git not found" / git_unavailable; timeout → git_unavailable;
    /// exit code outside `okStatuses` → git_unavailable (preferring stderr, with
    /// the "not a git repository" message passed through verbatim).
    static func runGit(
        _ args: [String],
        cwd: URL,
        timeout: TimeInterval,
        label: String,
        okStatuses: [Int32] = [0],
        treatNotAGitRepoSpecially: Bool = true
    ) -> GitRun {
        guard let git = which("git") else {
            return .failure(errResult("git not found", code: "git_unavailable"))
        }
        let run = runProcess(git, args, cwd: cwd, timeout: timeout)
        if run.timedOut {
            return .failure(errResult("\(label) timed out", code: "git_unavailable"))
        }
        if !run.launched {
            // FileNotFoundError parity (git vanished between which() and run).
            return .failure(errResult("git not found", code: "git_unavailable"))
        }
        if !okStatuses.contains(run.status) {
            let err = (run.stderr.isEmpty ? run.stdout : run.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = err.isEmpty ? "\(label) exited \(run.status)" : err
            return .failure(errResult(msg, code: "git_unavailable"))
        }
        return .success(GitResult(stdout: run.stdout, status: run.status))
    }

    /// True when a GitRun failure was a PROCESS-level failure (git missing /
    /// timeout) rather than a non-zero-exit failure — used by repo_dirty_summary
    /// to decide whether a failed log sub-command aborts the whole summary
    /// (process-level: yes; non-zero: no, commits just stays []).
    static func isProcessLevelFailure(_ run: GitRun) -> Bool {
        guard case .failure(let v) = run, case .object(let o) = v else { return false }
        // Process-level failures carry the "git not found" / "...timed out"
        // messages; a non-zero exit carries an "exited N" / stderr message.
        if case .string(let msg)? = o["error"] {
            return msg == "git not found" || msg.hasSuffix("timed out")
        }
        return false
    }
}

// MARK: - Small value helpers

private func isNull(_ v: JSONValue) -> Bool { if case .null = v { return true }; return false }

/// Python `str(content)` of a JSON value being written. For a JSON string this
/// is the raw string; for other scalars it stringifies; non-scalars serialise.
private func jsonToStr(_ v: JSONValue) -> String {
    switch v {
    case .string(let s): return s
    case .bool(let b): return b ? "True" : "False"
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    case .null: return "None"
    default: return (try? v.serialize(pretty: false)) ?? ""
    }
}

/// repr-ish rendering for error messages (`got <x>`). Best-effort.
private func jsonRepr(_ v: JSONValue?) -> String {
    guard let v else { return "None" }
    switch v {
    case .null: return "None"
    case .string(let s): return "'\(s)'"
    case .bool(let b): return b ? "True" : "False"
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    default: return (try? v.serialize(pretty: false)) ?? ""
    }
}

private func rootsRepr(_ roots: [URL]) -> String {
    "[" + roots.map { "'\($0.path)'" }.joined(separator: ", ") + "]"
}

/// Decode bytes as UTF-8 with replacement on invalid sequences (Python
/// `decode("utf-8", errors="replace")`).
private func decodeUTF8Replacing(_ data: Data) -> String {
    if let s = String(data: data, encoding: .utf8) { return s }
    // Lossy fallback: map invalid bytes to U+FFFD.
    var scalars = String.UnicodeScalarView()
    var decoder = UTF8()
    var iter = data.makeIterator()
    loop: while true {
        switch decoder.decode(&iter) {
        case .scalarValue(let s): scalars.append(s)
        case .emptyInput: break loop
        case .error: scalars.append(Unicode.Scalar(0xFFFD)!)
        }
    }
    return String(scalars)
}

/// Mirror Python `str.splitlines()`: split on universal newlines, no trailing
/// empty element for a final newline.
private func splitLines(_ text: String) -> [String] {
    if text.isEmpty { return [] }
    var lines: [String] = []
    var current = ""
    let chars = Array(text)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "\r" {
            lines.append(current)
            current = ""
            // CRLF collapses to one break.
            if i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
        } else if c == "\n" {
            lines.append(current)
            current = ""
        } else {
            current.append(c)
        }
        i += 1
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

private struct CommandResult { let status: Int32; let stdout: String }

private func runCommand(_ launchPath: String, _ args: [String], timeout: TimeInterval = 5) -> CommandResult? {
    guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launchPath)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
        try proc.run()
    } catch {
        return nil
    }
    // Timeout parity with Python's subprocess.run(..., timeout=5): a hung
    // command must not hang system_info. A watchdog terminates the process so
    // the field records a failure (nil) instead of blocking forever. Read the
    // pipe to EOF FIRST — that returns once the process exits (or is killed),
    // avoiding a deadlock on a full pipe buffer.
    let timedOut = ManagedAtomicFlag()
    let watchdog = DispatchWorkItem {
        if proc.isRunning {
            timedOut.set()
            proc.terminate()
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    watchdog.cancel()
    if timedOut.get() { return nil }
    return CommandResult(status: proc.terminationStatus, stdout: String(data: data, encoding: .utf8) ?? "")
}

/// Minimal thread-safe boolean flag for the runCommand watchdog (avoids a
/// dependency on swift-atomics). Set once by the watchdog, read after join.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private func firstCapturedString(in text: String, pattern: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = text as NSString
    guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges >= 2,
          m.range(at: 1).location != NSNotFound else { return nil }
    return ns.substring(with: m.range(at: 1))
}

private func firstCapturedInt(in text: String, pattern: String) -> Int? {
    guard let s = firstCapturedString(in: text, pattern: pattern) else { return nil }
    // Python does int(float(...)) for page counts; tolerate a decimal point.
    if let i = Int(s) { return i }
    if let d = Double(s) { return Int(d) }
    return nil
}

// MARK: - Wave 32 W08 process helpers (grep + git)

/// Mirror `shutil.which(name)` EXACTLY: resolve a bare executable name against
/// `$PATH` only (an absolute/relative path is honoured verbatim if executable).
/// Returns the absolute path, or nil when not found — letting the grep/git
/// handlers reproduce Python's FileNotFoundError taxonomy. PARITY (gpt-5.5
/// review): does NOT append Homebrew / /usr/local. Python's `shutil.which` and
/// `subprocess.run` both honour ONLY the inherited PATH; appending extra dirs
/// could make the runtime pick `rg` where its actual PATH would pick `grep`,
/// silently changing matching/coverage.
func which(_ name: String) -> String? {
    if name.contains("/") {
        return FileManager.default.isExecutableFile(atPath: name) ? name : nil
    }
    // shutil.which uses os.defpath ("/bin:/usr/bin") only when PATH is unset.
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/bin:/usr/bin"
    for dir in path.split(separator: ":", omittingEmptySubsequences: false) {
        // shutil.which treats an empty PATH entry as the cwd; mirror by skipping
        // (a bare-name lookup against cwd is not what these tools want anyway).
        if dir.isEmpty { continue }
        let candidate = (String(dir) as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

/// Richer process result for the grep/git handlers: distinguishes a launch
/// failure (`launched == false`, ~ FileNotFoundError) from a timeout
/// (`timedOut == true`, ~ TimeoutExpired) from a clean run (status + captured
/// stdout/stderr, both decoded UTF-8-with-replacement to mirror Python's
/// `text=True, errors="replace"`). Distinct from `runCommand` (the wave-30
/// system_info helper) which neither captures stderr nor accepts a cwd; left
/// untouched to keep that reviewed code's blast radius zero.
struct ProcessRunResult {
    var launched: Bool
    var timedOut: Bool
    var status: Int32
    var stdout: String
    var stderr: String
}

func runProcess(_ launchPath: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval) -> ProcessRunResult {
    guard FileManager.default.isExecutableFile(atPath: launchPath) else {
        return ProcessRunResult(launched: false, timedOut: false, status: -1, stdout: "", stderr: "")
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launchPath)
    proc.arguments = args
    if let cwd { proc.currentDirectoryURL = cwd }
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    do {
        try proc.run()
    } catch {
        return ProcessRunResult(launched: false, timedOut: false, status: -1, stdout: "", stderr: "")
    }
    // Drain BOTH pipes to EOF on DEDICATED THREADS — NOT DispatchQueue.global().
    // CONCURRENCY (deadlock fix, found empirically when 13 parallel tests hung at
    // 0% CPU): `Process.waitUntilExit()` itself parks on a libdispatch readability
    // source serviced by the global concurrent pool; if the two blocking
    // `readDataToEndOfFile()` drains ALSO sit on that pool, enough concurrent
    // runProcess() calls oversubscribe and starve the pool, so waitUntilExit()
    // can never wake → permanent hang. Dedicated Threads cannot be starved by the
    // pool, so the drains always make progress and the write-ends EOF when the
    // process dies. Each drain signals its own semaphore; results land in a
    // Sendable locked box (each setter called exactly once, read after both
    // semaphores → happens-after, no race).
    let timedOut = ProcessTimeoutFlag()
    let box = ProcessOutputBox()
    let outDone = DispatchSemaphore(value: 0)
    let errDone = DispatchSemaphore(value: 0)
    let outFH = outPipe.fileHandleForReading
    let errFH = errPipe.fileHandleForReading
    let outThread = Thread {
        box.setStdout(outFH.readDataToEndOfFile())
        outDone.signal()
    }
    let errThread = Thread {
        box.setStderr(errFH.readDataToEndOfFile())
        errDone.signal()
    }
    outThread.stackSize = 1 << 20
    errThread.stackSize = 1 << 20
    outThread.start()
    errThread.start()

    // Watchdog escalation (gpt-5.5 review): SIGTERM first; if the process ignores
    // it (or a grandchild keeps the pipes open), SIGKILL after a short grace so
    // waitUntilExit()/the drains cannot hang forever. Mirrors
    // subprocess.run(timeout=)'s kill-on-timeout — Python's Popen.kill() is
    // SIGKILL — guaranteeing the read FDs close and the drains complete. The
    // watchdog runs on its own thread (also pool-independent) and is told to
    // stand down via a flag once the process exits normally.
    let watchdogDone = ProcessTimeoutFlag()
    let pid = proc.processIdentifier
    let watchdog = Thread {
        // Sleep in small slices so a normally-exiting process cancels promptly.
        let deadline = Date().addingTimeInterval(timeout)
        let killDeadline = Date().addingTimeInterval(timeout + 2.0)
        var sentTerm = false
        while !watchdogDone.get() {
            Thread.sleep(forTimeInterval: 0.05)
            if watchdogDone.get() { return }
            let now = Date()
            if !sentTerm && now >= deadline {
                if proc.isRunning { timedOut.set(); proc.terminate() }
                sentTerm = true
            }
            if now >= killDeadline {
                if proc.isRunning { timedOut.set(); kill(pid, SIGKILL) }
                return
            }
        }
    }
    watchdog.start()

    proc.waitUntilExit()
    // Process is gone → its OWN pipe write-ends are closed → both drains hit EOF
    // promptly in the normal case. EDGE CASE (gpt-5.5 round-2): if a GRANDCHILD
    // inherited the stdout/stderr FDs and outlived the direct child, the
    // write-end stays open and `readDataToEndOfFile()` would never return —
    // killing `proc` (already dead) does nothing. None of this wave's tools
    // (git/rg/grep) spawn such grandchildren, but to GUARANTEE runProcess always
    // returns, bound the drain wait: if either reader hasn't hit EOF within a
    // short grace, force-close its FileHandle (which makes the blocked
    // readDataToEndOfFile return with what it has) and proceed. This is the Swift
    // analogue of Python's kill-on-timeout — the result is captured, the threads
    // exit, no unbounded wait.
    let drainGrace: DispatchTime = .now() + 2.0
    let outOK = outDone.wait(timeout: drainGrace) == .success
    let errOK = errDone.wait(timeout: drainGrace) == .success
    if !outOK {
        timedOut.set()
        try? outFH.close()   // unblocks the reader → it signals → thread exits
        outDone.wait()
    }
    if !errOK {
        timedOut.set()
        try? errFH.close()
        errDone.wait()
    }
    watchdogDone.set()  // stand the watchdog thread down
    let to = timedOut.get()
    return ProcessRunResult(
        launched: true,
        timedOut: to,
        status: proc.terminationStatus,
        stdout: decodeUTF8ReplacingPublic(box.stdout()),
        stderr: decodeUTF8ReplacingPublic(box.stderr())
    )
}

/// Sendable locked box for the two concurrent pipe drains in `runProcess`.
/// Each setter is called exactly once (from its reader task); the getters run
/// after `group.wait()` so the reads happen-after both writes.
private final class ProcessOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    func setStdout(_ d: Data) { lock.lock(); out = d; lock.unlock() }
    func setStderr(_ d: Data) { lock.lock(); err = d; lock.unlock() }
    func stdout() -> Data { lock.lock(); defer { lock.unlock() }; return out }
    func stderr() -> Data { lock.lock(); defer { lock.unlock() }; return err }
}

/// Thread-safe one-shot flag for the runProcess watchdog (mirrors the wave-30
/// ManagedAtomicFlag; file-private name kept distinct to avoid a clash).
private final class ProcessTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Public-to-file decode mirror (the wave-30 `decodeUTF8Replacing` is private).
func decodeUTF8ReplacingPublic(_ data: Data) -> String {
    if let s = String(data: data, encoding: .utf8) { return s }
    var scalars = String.UnicodeScalarView()
    var decoder = UTF8()
    var iter = data.makeIterator()
    loop: while true {
        switch decoder.decode(&iter) {
        case .scalarValue(let s): scalars.append(s)
        case .emptyInput: break loop
        case .error: scalars.append(Unicode.Scalar(0xFFFD)!)
        }
    }
    return String(scalars)
}

/// Mirror Python `str.split(sep, maxsplit)`: at most `maxSplits` splits, so the
/// final element keeps any remaining separators. Used for the `%h|%an|%ai|%s`
/// commit-line parse where the subject may itself contain `|`.
func splitN(_ s: String, separator: Character, maxSplits: Int) -> [String] {
    if maxSplits <= 0 { return [s] }
    var parts: [String] = []
    var current = ""
    var splits = 0
    for ch in s {
        if ch == separator && splits < maxSplits {
            parts.append(current)
            current = ""
            splits += 1
        } else {
            current.append(ch)
        }
    }
    parts.append(current)
    return parts
}

/// Parse the leading integer that appears immediately after `marker` in `s`.
/// Mirrors the repo_dirty_summary ahead/behind extraction:
/// `branch.split("[ahead ", 1)[1].split("]", 1)[0].split(",", 1)[0]` then int().
func parseTrailingInt(_ s: String, after marker: String) -> Int? {
    guard let r = s.range(of: marker) else { return nil }
    let rest = s[r.upperBound...]
    // Take up to the first ']' or ',' (matching the chained Python splits).
    var digits = ""
    for ch in rest {
        if ch == "]" || ch == "," { break }
        digits.append(ch)
    }
    return Int(digits.trimmingCharacters(in: .whitespaces))
}
