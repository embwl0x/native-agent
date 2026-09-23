import Foundation
import CryptoKit
import NativeAgentCore
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
    "security",
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

/// 2026-09-06: ONE public entry point for the sensitive-subtree predicate, so
/// callers outside this module apply the exact fence the Full Mac file tools
/// apply. Turning Full Mac OFF selects the basic reader in
/// `SwiftToolDispatcher`, which resolved `data/secrets` / `data/providers` /
/// `data/trust` through the repo sandbox (`data` is an allowed top level) and
/// opened them directly — the Full Mac reader rejects exactly those.
public func connectorPathIsSensitiveData(_ path: URL, dataRoot: URL) -> Bool {
    FileSystemActions.isSensitiveDataPath(
        path,
        ConnectorActionContext(repoRoot: "", dataRoot: dataRoot.path)
    )
}

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
        // Fold both sides, including paths that do not exist yet.
        let drPath = dataRoot.path.lowercased()
        let pPath = resolved.path.lowercased()
        let prefix = drPath.hasSuffix("/") ? drPath : drPath + "/"
        guard pPath == drPath || pPath.hasPrefix(prefix) else { return false }
        let relStr = pPath == drPath ? "" : String(pPath.dropFirst(prefix.count))
        let parts = relStr.split(separator: "/").map(String.init)
        guard let first = parts.first else { return false }
        if connectorSensitiveDataSubpaths.contains(first) { return true }
        // Credential files are fenced where they are actually written, not by
        // basename anywhere: `<root>/research/config.json` and other plain
        // config under the data root are not secrets and stay readable.
        if parts.count >= 2, parts[0] == "connectors",
           ["auth.json", "credential.json", "credentials.json"].contains(parts[parts.count - 1]) {
            return true
        }
        if parts.count == 2, parts[0] == "jev", parts[1] == "credential.json" { return true }
        if parts.count >= 2 {
            if parts[0] == "agents", ["peers.json", "peer-claims"].contains(parts[1]) { return true }
            if parts[0] == "workflows", parts[1] == "approvals" { return true }
            if parts[0] == "tools", parts[1].hasPrefix(".manifest_signing_key") { return true }
            if parts[0] == "memory", parts[1] == "vault" { return true }
        }
        if parts.count >= 2 && parts[0] == "nextgen" && parts[1] == "remote" { return true }
        // *.bin directly under data root (pairing secrets etc.)
        if parts.count == 1 && resolved.pathExtension.lowercased() == "bin" { return true }
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
        // Preserve truncation toward zero for ordinary numeric inputs, but
        // reject unrepresentable values instead of trapping the app process.
        case .double(let d): return Int(exactly: d.rounded(.towardZero))
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

    /// Observes the actual regular-file read request in focused tests, without
    /// exposing file paths/content or adding process-wide instrumentation.
    @TaskLocal static var regularFileReadObserver: (@Sendable (Int) -> Void)?

    private struct FileReadFailure: Error {
        let message: String
        let code: String
    }

    private static func openRegularReadHandle(_ path: URL) throws -> FileHandle {
        #if canImport(Darwin)
        // Descriptor-relative walk from the verified root: each parent is
        // opened O_DIRECTORY|O_NOFOLLOW and the final component O_NOFOLLOW, so
        // a symlink swapped in after the sandbox check cannot redirect this
        // read. Everything below reads the DESCRIPTOR, never the path again.
        let descriptor: Int32
        do { descriptor = try VerifiedPath.open(path, flags: O_RDONLY | O_NONBLOCK) }
        catch let failure as VerifiedPath.Failure {
            throw FileReadFailure(message: "Could not open file: \(failure.message)", code: failure.code)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            close(descriptor)
            throw FileReadFailure(message: "Could not inspect opened file.", code: "read_failed")
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(descriptor)
            throw FileReadFailure(message: "File reads support regular files only; pipes, devices and sockets cannot provide file windows.", code: "unsupported_file_type")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        #else
        throw FileReadFailure(message: "Bounded regular-file reads are unavailable on this platform.", code: "unsupported_file_type")
        #endif
    }

    private static func readFileWindow(
        handle: FileHandle,
        path: URL,
        maxBytes: Int,
        useCompactDefault: Bool,
        offset: Int,
        expectedVersion: String
    ) throws -> (data: Data, totalBytes: Int, version: String?, byteLimit: Int) {
        func limit(for totalBytes: Int) -> Int {
            if useCompactDefault && shouldUseCompactReadDefault(path: path, actualBytes: totalBytes) {
                return min(maxBytes, connectorReadFileHandoffDefaultMaxBytes)
            }
            return maxBytes
        }
        #if canImport(Darwin)
        func version(_ metadata: stat) -> String {
            let fields = [path.path, String(metadata.st_dev), String(metadata.st_ino),
                          String(metadata.st_size), String(metadata.st_mtimespec.tv_sec),
                          String(metadata.st_mtimespec.tv_nsec), String(metadata.st_ctimespec.tv_sec),
                          String(metadata.st_ctimespec.tv_nsec)]
            return SHA256.hash(data: Data(fields.joined(separator: "\0").utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
        var metadata = stat()
        if fstat(handle.fileDescriptor, &metadata) == 0,
           metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
           let totalBytes = Int(exactly: metadata.st_size), totalBytes >= 0 {
            let observedVersion = version(metadata)
            if !expectedVersion.isEmpty && expectedVersion != observedVersion {
                throw FileReadFailure(message: "File changed since the previous window. Restart at offset 0 without version.", code: "file_changed")
            }
            guard offset <= totalBytes else {
                throw FileReadFailure(message: "offset exceeds the file size.", code: "bad_input")
            }
            let byteLimit = limit(for: totalBytes)
            try handle.seek(toOffset: UInt64(offset))
            regularFileReadObserver?(byteLimit)
            let data = try handle.read(upToCount: byteLimit) ?? Data()
            if offset > 0 && (data.isEmpty || data.first.map { $0 & 0xC0 == 0x80 } == true) {
                let prefixCount = min(offset, 3)
                try handle.seek(toOffset: UInt64(offset - prefixCount))
                let nearby = Array(try handle.read(upToCount: prefixCount + 4) ?? Data())
                for start in 0..<min(prefixCount, nearby.count) {
                    let required: Int
                    switch nearby[start] {
                    case 0xC2...0xDF: required = 2
                    case 0xE0...0xEF: required = 3
                    case 0xF0...0xF4: required = 4
                    default: continue
                    }
                    let end = start + required
                    if end > prefixCount, end <= nearby.count,
                       String(data: Data(nearby[start..<end]), encoding: .utf8) != nil {
                        throw FileReadFailure(message: "offset starts inside a UTF-8 character. Use the returned next arguments.", code: "bad_input")
                    }
                }
            }
            var after = stat()
            guard fstat(handle.fileDescriptor, &after) == 0,
                  version(after) == observedVersion else {
                throw FileReadFailure(message: "File changed during the read. Restart at offset 0 without version.", code: "file_changed")
            }
            // Keep complete source scalars together across windows. Invalid
            // source bytes still use replacement decoding; an EOF fragment is
            // malformed source, whereas a window-edge fragment is not.
            let slice = offset + data.count < totalBytes ? completeUTF8Prefix(data) : data
            if byteLimit > 0 && slice.isEmpty && !data.isEmpty {
                throw FileReadFailure(message: "max_bytes cannot hold the next UTF-8 character. Use at least 4 bytes.", code: "window_too_small")
            }
            return (slice, totalBytes, observedVersion, byteLimit)
        }
        #endif
        throw FileReadFailure(message: "Could not establish a regular-file version for this read.", code: "unsupported_file_type")
    }

    private static func completeUTF8Prefix(_ data: Data) -> Data {
        let bytes = Array(data)
        guard !bytes.isEmpty else { return data }
        var start = bytes.count - 1
        while start > 0 && bytes[start] & 0xC0 == 0x80 && bytes.count - start < 4 { start -= 1 }
        let required: Int
        switch bytes[start] {
        case 0xC2...0xDF: required = 2
        case 0xE0...0xEF: required = 3
        case 0xF0...0xF4: required = 4
        default: return data
        }
        guard bytes.count - start < required,
              bytes[(start + 1)...].allSatisfy({ $0 & 0xC0 == 0x80 }) else { return data }
        return Data(bytes.prefix(start))
    }

    static func readFile(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let rawPath = stringField(input, "path")
        if rawPath.isEmpty { return errResult("path is required", code: "bad_input") }
        if case .double(let value)? = input["offset"], Int(exactly: value) == nil {
            return errResult("offset must be a nonnegative whole byte count", code: "bad_input")
        }
        guard let offset = safeInt(input["offset"], default: 0), offset >= 0 else {
            return errResult("offset must be a nonnegative byte count", code: "bad_input")
        }
        switch input["version"] {
        case nil, .null?, .string?: break
        default: return errResult("version must be a string", code: "bad_input")
        }
        let expectedVersion = stringField(input, "version")
        if offset > 0 && expectedVersion.isEmpty {
            return errResult("Use the previous window's next arguments, including version, to continue safely.", code: "bad_input")
        }
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

        // Nonblocking open plus fstat precedes image decoding too: a FIFO
        // with an image extension must not block inside the pixel loader.
        let handle: FileHandle
        do { handle = try openRegularReadHandle(resolved) }
        catch let error as FileReadFailure { return errResult(error.message, code: error.code) }
        catch { return errResult("could not open file", code: "read_failed") }
        defer { try? handle.close() }
        // Decode from the bytes THIS verified descriptor produces. Reopening the
        // path to decode (LocalToolImage.readAuthorizedFile) would validate one
        // file and render another after a swap.
        if VerifiedImageRead.isImagePath(resolved) {
            let bytes = ((try? handle.read(upToCount: LocalToolImage.maximumBytes + 1)) ?? nil) ?? Data()
            let image = VerifiedImageRead.deliver(data: bytes, name: resolved.lastPathComponent)
            guard offset == 0 && expectedVersion.isEmpty else {
                return errResult("Image reads return pixels, not byte windows. Omit offset and version.", code: "bad_input")
            }
            return image
        }
        let window: (data: Data, totalBytes: Int, version: String?, byteLimit: Int)
        do {
            window = try readFileWindow(
                handle: handle, path: resolved, maxBytes: maxBytes, useCompactDefault: !hasExplicitMaxBytes,
                offset: offset, expectedVersion: expectedVersion
            )
        } catch let error as FileReadFailure {
            return errResult(error.message, code: error.code)
        } catch {
            return errResult("could not read file: \(error.localizedDescription)", code: "read_failed")
        }
        let nextOffset = offset + window.data.count
        let hasMore = nextOffset < window.totalBytes
        var result: [String: JSONValue] = [
            "ok": .bool(true),
            "path": .string(resolved.path),
            "bytes": .int(Int64(window.totalBytes)),
            "status": .string("ok"),
            "offset": .int(Int64(offset)),
            "returned_bytes": .int(Int64(window.data.count)),
            "truncated": .bool(hasMore),
            "has_more": .bool(hasMore),
            "content": .string(decodeUTF8Replacing(window.data)),
        ]
        if let version = window.version {
            result["version"] = .string(version)
            if hasMore {
                result["next"] = .object([
                    "path": .string(rawPath), "offset": .int(Int64(nextOffset)),
                    "max_bytes": .int(Int64(max(4, window.byteLimit))), "version": .string(version),
                ])
            }
        } else if hasMore {
            result["continuation_note"] = .string("Nonregular source: stable byte continuation unavailable.")
        }
        return .object(result)
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

        let window: (total: Int, rendered: [String])
        do {
            let handle = try openRegularReadHandle(resolved)
            defer { try? handle.close() }
            window = try readExcerptWindow(handle: handle, path: resolved, startLine: startLine, maxLines: maxLines)
        } catch let failure as FileReadFailure {
            if failure.code == "file_changed" {
                return errResult("The file changed during this read; a consistent excerpt could not be established. Retry the selection. If it came from a search, repeat that search because line positions may have moved.", code: "file_changed")
            }
            return errResult(failure.message, code: failure.code)
        } catch {
            return errResult("could not read file", code: "read_failed")
        }
        let total = window.total
        let startIdx = min(startLine - 1, total)
        let endIdx = min(total, startIdx + maxLines)
        return .object([
            "ok": .bool(true),
            "path": .string(resolved.path),
            "start_line": .int(Int64(total > 0 ? startIdx + 1 : 1)),
            "status": .string("ok"),
            "end_line": .int(Int64(endIdx)),
            "total_lines": .int(Int64(total)),
            "excerpt": .string(window.rendered.joined(separator: "\n")),
            "truncated": .bool(endIdx < total),
        ])
    }

    /// Count the complete stable source while retaining only the requested
    /// lines. Reuse the byte reader's version checks and UTF-8 boundaries;
    /// newline state persists across chunks, including a split CRLF.
    private static func readExcerptWindow(
        handle: FileHandle, path: URL, startLine: Int, maxLines: Int
    ) throws -> (total: Int, rendered: [String]) {
        var offset = 0
        var version = ""
        var total = 0
        var current = ""
        var currentHasContent = false
        var previousWasCR = false
        var retainedBytes = 0
        var rendered: [String] = []
        func selected() -> Bool { total >= startLine - 1 && total - (startLine - 1) < maxLines }
        func finishLine() {
            if selected() { rendered.append("\(total + 1): \(current)") }
            total += 1
            current = ""
            currentHasContent = false
        }
        while true {
            let chunk = try readFileWindow(
                handle: handle, path: path, maxBytes: 65_536, useCompactDefault: false,
                offset: offset, expectedVersion: version
            )
            version = chunk.version ?? ""
            for scalar in decodeUTF8Replacing(chunk.data).unicodeScalars {
                if previousWasCR && scalar.value == 0x0A {
                    previousWasCR = false
                    continue
                }
                previousWasCR = scalar.value == 0x0D
                switch scalar.value {
                case 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
                    finishLine()
                default:
                    currentHasContent = true
                    if selected() {
                        retainedBytes += scalar.utf8.count
                        guard retainedBytes <= 1_048_576 else {
                            throw FileReadFailure(
                                message: "Requested excerpt exceeds 1 MiB of text. Narrow max_lines, or use read_file byte windows and its returned next arguments for a very long line.",
                                code: "excerpt_too_large"
                            )
                        }
                        current.unicodeScalars.append(scalar)
                    }
                }
            }
            offset += chunk.data.count
            if offset >= chunk.totalBytes { break }
            guard !chunk.data.isEmpty else {
                throw FileReadFailure(message: "File ended before its measured size; retry the read.", code: "file_changed")
            }
        }
        if currentHasContent { finishLine() }
        return (total, rendered)
    }

    // MARK: - write_file

    /// Task-scoped observation of the opened append handle for race fixtures.
    @TaskLocal static var appendHandleOpened: (@Sendable () -> Void)?

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
        let expectedHash: String?
        // 2026-09-22: an empty string means "not provided" — a model sending ""
        // looped four times (7.5 min) on the old combined refusal.
        let blankHash: Bool = {
            if case .string(let s)? = input["expected_content_sha256"] {
                return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }()
        if let value = input["expected_content_sha256"], value != .null, !blankHash {
            guard case .string(let hash) = value, hash.count == 64,
                  hash.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) }) else {
                return errResult("expected_content_sha256 must be a 64-character lowercase hex SHA-256, or omitted.", code: "bad_input")
            }
            guard !append else {
                return errResult("expected_content_sha256 guards a replacement; it cannot be used with append=true.", code: "bad_input")
            }
            expectedHash = hash
        } else { expectedHash = nil }

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

        // before_content for inline diff (only on overwrite, not append), ≤ 200 kB.
        var beforeContent: String? = nil

        do {
            // Descriptor-relative walk: every parent component is opened
            // O_DIRECTORY|O_NOFOLLOW from the root, so a symlink swapped in
            // after the sandbox check fails the walk instead of redirecting the
            // write. The final component is opened / renamed RELATIVE to this
            // descriptor, never by pathname.
            //
            // Missing parents are made by the walk itself (`mkdirat` on the
            // verified descriptor). The path-based `createDirectory` that used
            // to run first re-resolved the whole pathname through symlinks and
            // could therefore create directories outside the writable root.
            let verified = try VerifiedPath.openParent(of: resolved, createIntermediates: expectedHash == nil)
            defer { verified.release() }
            let data = Data(content.utf8)
            if append {
                // Append at the kernel's current EOF for every write. Separate
                // exists/seek/write calls can lose concurrent append payloads,
                // including when both callers initially see a missing file.
                let fd: Int32
                do {
                    // Exclusive creation makes concurrent creators resolve to
                    // one creator and one existing-file open on Darwin.
                    fd = try VerifiedPath.openFinal(
                        verified, flags: O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NONBLOCK, mode: 0o666)
                } catch VerifiedPath.Failure.posix(EEXIST) {
                    fd = try VerifiedPath.openFinal(
                        verified, flags: O_WRONLY | O_APPEND | O_NONBLOCK)
                }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var metadata = stat()
                guard fstat(fd, &metadata) == 0,
                      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      metadata.st_nlink == 1 else {
                    return errResult("Append requires a regular file without hard links.", code: "path_not_allowed")
                }
                appendHandleOpened?()
                // Retain Foundation's full-write and I/O-error handling; an
                // append does not promise transactionality across callers.
                try handle.write(contentsOf: data)
            } else {
                var existingMetadata = stat()
                let existingMode: mode_t?
                if fstatat(verified.fd, verified.name, &existingMetadata, AT_SYMLINK_NOFOLLOW) == 0 {
                    guard existingMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                        return errResult("Overwrite requires a regular file.", code: "path_not_allowed")
                    }
                    existingMode = existingMetadata.st_mode & 0o777
                } else if errno == ENOENT {
                    existingMode = nil
                } else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                if let fd = try? VerifiedPath.openFinal(verified, flags: O_RDONLY | O_NONBLOCK) {
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    var metadata = stat()
                    if fstat(fd, &metadata) == 0,
                       metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                       metadata.st_size <= 200_000,
                       let before = try? handle.read(upToCount: 200_000) {
                        beforeContent = decodeUTF8Replacing(before)
                    }
                    try? handle.close()
                }
                // Atomic overwrite via tmp + POSIX renameat(2) INSIDE the
                // verified parent descriptor (matches retired os.replace:
                // atomic, creates-or-replaces the destination).
                // FileManager.replaceItemAt is NOT used — its create-on-missing
                // behavior is undocumented and it can return a moved URL. The
                // .tmp is unlinked in a defer so a failed write/rename never
                // leaks it (state-lifecycle: every create has a remove path).
                let tmpName = "\(resolved.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString.prefix(8)).tmp"
                let tmpFD = openat(
                    verified.fd, tmpName,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    existingMode == nil ? 0o666 : 0o600)
                guard tmpFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                defer { _ = unlinkat(verified.fd, tmpName, 0) }
                let tmpHandle = FileHandle(fileDescriptor: tmpFD, closeOnDealloc: true)
                defer { try? tmpHandle.close() }
                try tmpHandle.write(contentsOf: data)
                // Preserve private files and executable scripts; keep the
                // replacement private until its contents are complete.
                if let existingMode, fchmod(tmpFD, existingMode) != 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                try tmpHandle.close()
                if let expectedHash {
                    // Check the existing bytes through the same verified parent
                    // immediately before replacement. This is a conflict check,
                    // not an atomic compare-and-swap against other processes.
                    do {
                        let currentFD = try VerifiedPath.openFinal(verified, flags: O_RDONLY | O_NONBLOCK)
                        let current = FileHandle(fileDescriptor: currentFD, closeOnDealloc: true)
                        defer { try? current.close() }
                        let window = try readFileWindow(handle: current, path: resolved, maxBytes: 65_536,
                            useCompactDefault: false, offset: 0, expectedVersion: "")
                        var opened = stat(), named = stat()
                        guard window.totalBytes == window.data.count,
                              String(data: window.data, encoding: .utf8) != nil,
                              SHA256.hash(data: window.data).map({ String(format: "%02x", $0) }).joined() == expectedHash,
                              fstat(currentFD, &opened) == 0,
                              fstatat(verified.fd, verified.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
                            return errResult("The file changed since the revision was prepared. Read it again before revising; nothing was written.", code: "file_changed")
                        }
                    } catch {
                        return errResult("The original file could not be verified. Read it again before revising; nothing was written.", code: "file_changed")
                    }
                }
                if renameat(verified.fd, tmpName, verified.fd, verified.name) != 0 {
                    let err = String(cString: strerror(errno))
                    return errResult("atomic write failed: \(err)")
                }
            }
        } catch let failure as VerifiedPath.Failure {
            return errResult(failure.message, code: failure.code)
        } catch {
            return errResult(error.localizedDescription)
        }

        var result: [String: JSONValue] = [
            "ok": .bool(true),
            "path": .string(resolved.path),
            "bytes_written": .int(Int64(Data(content.utf8).count)),
            "status": .string("saved"),
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
        // Every page must advance, even when a caller supplies zero.
        maxEntries = max(1, maxEntries)
        if case .double(let value)? = input["offset"], Int(exactly: value) == nil {
            return errResult("offset must be a nonnegative whole entry count", code: "bad_input")
        }
        for field in ["name_contains", "snapshot"] {
            switch input[field] {
            case nil, .null?, .string?: break
            default: return errResult("\(field) must be a string", code: "bad_input")
            }
        }
        guard let offset = safeInt(input["offset"], default: 0), offset >= 0 else {
            return errResult("offset must be a nonnegative integer", code: "bad_input")
        }
        let nameContains = stringField(input, "name_contains")
        let caseSensitive: Bool
        switch input["case_sensitive"] {
        case .bool(let value)?: caseSensitive = value
        case nil, .null?: caseSensitive = false
        default: return errResult("case_sensitive must be a boolean", code: "bad_input")
        }
        let expectedSnapshot = stringField(input, "snapshot")
        if offset > 0 && expectedSnapshot.isEmpty {
            return errResult("Use the previous page's next arguments, including snapshot, to continue safely.", code: "bad_input")
        }

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
        // Authorize, then list THAT directory: the walk re-opens each component
        // O_DIRECTORY|O_NOFOLLOW from the root and the listing runs on the
        // resulting descriptor via fdopendir, so a symlink swapped in after the
        // sandbox check is refused rather than enumerated.
        let directoryFD: Int32
        do { directoryFD = try VerifiedPath.open(resolved, flags: O_RDONLY | O_DIRECTORY) }
        catch let failure as VerifiedPath.Failure { return errResult(failure.message, code: failure.code) }
        catch { return errResult("could not open directory") }
        guard let directory = fdopendir(directoryFD) else {
            let code = errno
            close(directoryFD)
            return errResult(String(cString: strerror(code)))
        }
        defer { closedir(directory) }
        var beforeStat = stat()
        guard fstat(dirfd(directory), &beforeStat) == 0 else {
            return errResult(String(cString: strerror(errno)))
        }
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
        var afterStat = stat()
        guard fstat(dirfd(directory), &afterStat) == 0 else {
            return errResult(String(cString: strerror(errno)))
        }
        guard beforeStat.st_mtimespec.tv_sec == afterStat.st_mtimespec.tv_sec,
              beforeStat.st_mtimespec.tv_nsec == afterStat.st_mtimespec.tv_nsec,
              beforeStat.st_ctimespec.tv_sec == afterStat.st_ctimespec.tv_sec,
              beforeStat.st_ctimespec.tv_nsec == afterStat.st_ctimespec.tv_nsec else {
            return errResult("Directory changed while listing. Restart at offset 0.", code: "directory_changed")
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
        // A stateless token binds continuation to this path, filter, ordering,
        // and observed names/types. It says nothing about child file contents.
        let fingerprintFields = [resolved.path, nameContains, caseSensitive ? "sensitive" : "insensitive"]
            + entries.flatMap { [$0.name, $0.isFile ? "other" : "directory"] }
        let snapshot = SHA256.hash(data: Data(fingerprintFields.joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
        if !expectedSnapshot.isEmpty && expectedSnapshot != snapshot {
            return errResult("Directory entries or filter changed since the previous page. Restart at offset 0 without snapshot.", code: "directory_changed")
        }
        let matches = entries.filter { entry in
            nameContains.isEmpty || entry.name.range(
                of: nameContains,
                options: caseSensitive ? [.literal] : [.literal, .caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ) != nil
        }
        let start = min(offset, matches.count)
        let page = matches.dropFirst(start).prefix(maxEntries)
        let out = page.map { JSONValue.string($0.isFile ? $0.name : $0.name + "/") }
        let nextOffset = start + out.count
        let hasMore = nextOffset < matches.count
        var result: [String: JSONValue] = [
            "ok": .bool(true),
            "path": .string(resolved.path),
            "entries": .array(out),
            "status": .string("ok"),
            "count": .int(Int64(out.count)),
            "total_visible": .int(Int64(entries.count)),
            "total_matching": .int(Int64(matches.count)),
            "name_contains": .string(nameContains),
            "case_sensitive": .bool(caseSensitive),
            "offset": .int(Int64(start)),
            "snapshot": .string(snapshot),
            "truncated": .bool(hasMore),
            "has_more": .bool(hasMore),
            "coverage": .string("Immediate child names only; no recursion, child metadata probes, or file-content search."),
        ]
        if hasMore {
            result["next"] = .object([
                "path": .string(resolved.path),
                "name_contains": .string(nameContains),
                "case_sensitive": .bool(caseSensitive),
                "max_entries": .int(Int64(maxEntries)),
                "offset": .int(Int64(nextOffset)),
                "snapshot": .string(snapshot),
            ])
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
        var result: [String: JSONValue] = ["ok": .bool(true), "status": .string(failures.isEmpty ? "ok" : "partial")]
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

    /// A task-scoped lookup seam lets dispatch fixtures exercise both installed
    /// search engines without changing the process-wide PATH.
    @TaskLocal static var grepExecutableResolver: (@Sendable (String) -> String?)?

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

        // grep must hand a target to an external engine, and confirming the walk
        // and then spawning against the PATHNAME reopened the very window the
        // walk closes — the engine resolved the name again, after the check.
        // So the walk's descriptor is KEPT: the child is spawned with the
        // verified directory as its working directory and searches ".", which
        // is the pinned inode whatever happens to the names above it.
        //
        // The trailing `catch {}` also swallowed `.notFound` and
        // `.posix(EACCES)` — an unverifiable path went to the engine anyway.
        // Every walk failure is now a refusal.
        var searchTarget = searchPath.path
        var spawnDirectory: URL? = nil
        var fileDisplayPath: String? = nil
        #if canImport(Darwin)
        // Where the child finds the verified FILE. Handing it the basename
        // reopened the swap window the walk closes, so a single-file search
        // hands over the descriptor itself.
        let inheritedChildDescriptor: Int32 = 3
        var cwdFD: Int32 = -1
        var searchFD: Int32 = -1
        defer {
            if cwdFD >= 0 { _ = Darwin.close(cwdFD) }
            if searchFD >= 0 { _ = Darwin.close(searchFD) }
        }
        do {
            let parent = try VerifiedPath.openParent(of: searchPath)
            // Owned by the `defer` above FROM HERE: a throwing `openFinal`
            // used to leak this descriptor.
            cwdFD = parent.fd
            // O_NOFOLLOW on the final component too: it is part of the path the
            // sandbox check judged.
            let finalFD = try VerifiedPath.openFinal(parent, flags: O_RDONLY | O_NONBLOCK)
            var metadata = stat()
            guard fstat(finalFD, &metadata) == 0 else {
                _ = Darwin.close(finalFD)
                return errResult(
                    "The authorized path could not be verified before the search.",
                    code: "path_not_allowed"
                )
            }
            switch metadata.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                // The parent has done its job; ownership of the verified
                // DIRECTORY transfers to the same deferred owner.
                _ = Darwin.close(cwdFD)
                cwdFD = finalFD
                searchTarget = "."
                spawnDirectory = searchPath
            case mode_t(S_IFREG):
                // Kept open and handed to the child as `/dev/fd/<n>`, which
                // resolves to this exact vnode and never to a name.
                searchFD = finalFD
                searchTarget = "/dev/fd/\(inheritedChildDescriptor)"
                fileDisplayPath = searchPath.path
            default:
                // A fifo, socket or device is not a search target, and opening
                // one by name for an engine is exactly the swap this fence is
                // about. Refuse rather than guess.
                _ = Darwin.close(finalFD)
                return errResult(
                    "Only a directory or a regular file can be searched.",
                    code: "path_not_allowed"
                )
            }
        } catch let failure as VerifiedPath.Failure {
            return errResult(failure.message, code: "path_not_allowed")
        } catch {
            return errResult(
                "The authorized path could not be verified before the search.",
                code: "path_not_allowed"
            )
        }
        #endif

        let resolveExecutable: @Sendable (String) -> String? = grepExecutableResolver ?? { which($0) }
        let rgPath = resolveExecutable("rg")
        let launch: String
        let args: [String]
        // Patterns are regex data, never CLI options (e.g. searching --help
        // must not execute the engine's help command and report it as matches).
        // 2026-09-06: the sensitive-path filter below parses
        // NUL-delimited filenames, so the output SHAPE is part of the fence.
        // `--no-config` stops an inherited RIPGREP_CONFIG_PATH from rewriting
        // it (or the search), and `--with-filename` / `-H` keep the filename on
        // every line even when the search path is a single file.
        if let rg = rgPath {
            launch = rg
            args = [
                "--no-config", "--null", "--with-filename", "--no-heading", "--line-number",
                "-m", String(maxResults), "-e", pattern, "--", searchTarget,
            ]
        } else if let grepBin = resolveExecutable("grep") {
            launch = grepBin
            args = ["-rHnE", "--null", "--include=*", "-m", String(maxResults), "-e", pattern, "--", searchTarget]
        } else {
            // Python would raise FileNotFoundError from subprocess.run → caught by
            // the broad `except Exception` → generic error (no error_code).
            return errResult("grep not found")
        }

        // -m limits each file, not the complete recursive output. Keep pipe
        // capture bounded as well as the agent-facing presentation.
        let captureLimit = 1_048_576
        #if canImport(Darwin)
        let run = runProcess(
            launch, args, cwdDescriptor: cwdFD,
            inheritDescriptor: searchFD >= 0
                ? (source: searchFD, target: inheritedChildDescriptor) : nil,
            timeout: 30, captureByteLimit: captureLimit
        )
        #else
        let run = runProcess(launch, args, timeout: 30, captureByteLimit: captureLimit)
        #endif
        if run.timedOut { return errResult("grep timed out after 30s", code: "bash_timeout") }
        if !run.launched { return errResult("could not run grep") }
        // Only 0 (matches) and 1 (no matches) establish a completed search.
        // A killed/aborted engine may leave partial stdout, not valid coverage.
        if run.captureReadFailed {
            return errResult("Could not read the search engine output; search coverage is unknown.", code: "grep_error")
        }
        if run.status != 0 && run.status != 1 {
            let stderr = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return errResult(stderr.isEmpty ? "grep exited with status \(run.status)" : stderr, code: "grep_error")
        }
        // Filenames may contain newlines and colons. Judge the complete NUL-
        // delimited filename before formatting any match for the transcript.
        let admitted = grepMatchRecords(run.stdout).compactMap { record -> String? in
            let path: String
            if let display = fileDisplayPath {
                guard record.path == searchTarget else { return nil }
                path = display
            } else if let directory = spawnDirectory, !record.path.hasPrefix("/") {
                let relative = record.path.hasPrefix("./") ? String(record.path.dropFirst(2)) : record.path
                path = directory.path + "/" + relative
            } else {
                path = record.path
            }
            guard path.hasPrefix("/"), !isSensitiveDataPath(URL(fileURLWithPath: path), ctx) else { return nil }
            return path + ":" + record.match
        }
        // Python: raw_output.splitlines()[:max_results]. Use the guarded
        // sliceCount (negatives already errored at the subprocess above).
        let lines = Array(admitted.prefix(sliceCount))
        let selectedText = lines.joined(separator: "\n")
        let outputClipped = selectedText.count > connectorResultMaxChars
        let output = outputClipped
            ? String(selectedText.prefix(connectorResultMaxChars)) + "\n[match output truncated]"
            : selectedText
        // -m is a per-file engine ceiling; the presentation limit is global.
        // Reaching it cannot establish the total, even when no extra admitted
        // line was observed. Counts never include filtered sensitive paths.
        let limitReached = sliceCount == 0 || admitted.count >= sliceCount
        let omittedObserved = max(0, admitted.count - lines.count)
        var result: [String: JSONValue] = [
            "ok": .bool(true),
            "pattern": .string(pattern),
            "status": .string("ok"),
            "path": .string(searchPath.path),
            "matches": .int(Int64(lines.count)),
            "output": .string(output),
            "coverage": .object([
                "complete": .bool(!limitReached && !outputClipped && !run.stdoutTruncated),
                "scope": .string("Text matches admitted by the existing path policy and search engine ignore/binary rules; not every file on disk."),
                "matches_are_total": .bool(!limitReached && !outputClipped && !run.stdoutTruncated),
                "observed_matches_lower_bound": .int(Int64(admitted.count)),
                "omitted_observed_matches": .int(Int64(omittedObserved)),
                "match_limit_reached": .bool(limitReached),
                "output_truncated": .bool(outputClipped),
                "output_character_limit": .int(Int64(connectorResultMaxChars)),
                "capture_truncated": .bool(run.stdoutTruncated),
                "capture_byte_limit": .int(Int64(captureLimit)),
            ]),
        ]
        if limitReached || outputClipped || run.stdoutTruncated {
            result["coverage_note"] = .string("Matches is the selected line count, not the total number of occurrences. More evidence may be omitted; narrow path/pattern or raise max_results up to 50. Read an identified file with file_excerpt for surrounding lines. Do not infer absence from this limited result.")
        }
        return .object(result)
    }

    /// Both engines emit `filename NUL line:text LF`. Only complete records
    /// count; a capture cut anywhere in a filename or match is discarded.
    static func grepMatchRecords(_ output: String) -> [(path: String, match: String)] {
        var remaining = output.utf8[...]
        var records: [(path: String, match: String)] = []
        while let separator = remaining.firstIndex(of: 0) {
            let path = String(decoding: remaining[..<separator], as: UTF8.self)
            let body = remaining[remaining.index(after: separator)...]
            guard let end = body.firstIndex(of: 10) else { break }
            var match = body[..<end]
            if match.last == 13 { match = match.dropLast() }
            guard !path.isEmpty, let colon = match.firstIndex(of: 58),
                  colon != match.startIndex,
                  match[..<colon].allSatisfy({ (48...57).contains($0) }) else { break }
            records.append((path, String(decoding: match, as: UTF8.self)))
            remaining = body[body.index(after: end)...]
        }
        return records
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
            "status": .string("ok"),
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
        // 2026-09-06: `--no-ext-diff` / `--no-textconv` are the per-command
        // half of the exec fence; the global `-c` overrides in runGit are the
        // other half.
        var args = ["diff", "--no-ext-diff", "--no-textconv"]
        if staged { args.append("--staged") }
        if !pathFilter.isEmpty { args.append(contentsOf: ["--", pathFilter]) }

        let run = runGit(args, cwd: cwd, timeout: 30, label: "git diff", okStatuses: [0, 1])
        if case .failure(let f) = run { return f }
        guard case .success(let result) = run else { return errResult("git diff failed", code: "git_unavailable") }
        return .object([
            "ok": .bool(true),
            "staged": .bool(staged),
            "status": .string("ok"),
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
            "status": .string("ok"),
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
                "status": .string("ok"),
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
    /// Every command routed through `runGit` is a READ (git_status, git_diff,
    /// git_log, repo_dirty_summary — the four tools in
    /// SwiftToolDispatcher.fullMacReadOnlyFileToolNames). `git status` and
    /// `git diff` nevertheless take an OPTIONAL lock on `.git/index` to write
    /// back a refreshed stat cache, which is a shared-file write two concurrent
    /// readers can contend on. `GIT_OPTIONAL_LOCKS=0` is git's own switch for
    /// read-only callers: it skips that refresh write entirely (the reported
    /// status is unchanged), so these tools mutate nothing in the repository
    /// and may safely run beside each other — which is what
    /// ParallelToolDispatch's read carve-out relies on.
    static let gitReadOnlyEnvironmentOverrides: [String: String] = [
        "GIT_OPTIONAL_LOCKS": "0",
        // 2026-09-06: these four tools are READ tools, but git happily runs
        // commands the repository (or the inherited environment) names —
        // `GIT_EXTERNAL_DIFF`, a pager, an SSH command, a system-config hook.
        // A cloned or attacker-supplied checkout could therefore execute
        // arbitrary code from `git_diff` / `git_status`, OUTSIDE the builder
        // sandbox (runProcess applies none). Pin the environment closed;
        // `gitReadOnlyConfigOverrideArgs` closes the config-file half.
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        // 2026-09-06: git shells out (aliases, `git status` sub-processes) and
        // resolves helpers through PATH, so the child gets the system PATH, not
        // whatever the app inherited.
        "PATH": gitSanitizedSearchPath,
    ]

    /// The ONLY PATH a read-tier git child sees, and the only directories
    /// `gitExecutablePath` will resolve the binary from.
    static let gitSanitizedSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Resolve `git` WITHOUT consulting the inherited PATH (2026-09-06): a
    /// PATH the app inherited from a launching shell could name any binary
    /// `git`, and these four tools run it unsandboxed. Fixed location first,
    /// then the Xcode toolchain via `xcrun`, which is itself at a fixed path.
    static func gitExecutablePath() -> String? {
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/git") {
            return "/usr/bin/git"
        }
        let xcrun = "/usr/bin/xcrun"
        guard FileManager.default.isExecutableFile(atPath: xcrun) else { return nil }
        // 2026-09-06: xcrun picks its toolchain from the environment it is
        // handed — DEVELOPER_DIR and TOOLCHAINS name the directory it searches
        // — so inheriting the app's environment let whatever launched the app
        // choose the `git` these unsandboxed read tools execute, and any
        // absolute path xcrun printed was accepted. Hand it PATH alone, and
        // take the answer only when it lands in a developer-tools install.
        let run = runProcess(
            xcrun, ["--find", "git"], timeout: 10,
            environment: ["PATH": gitSanitizedSearchPath]
        )
        guard run.launched, !run.timedOut, run.status == 0 else { return nil }
        let found = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDeveloperToolchainPath(found),
              FileManager.default.isExecutableFile(atPath: found) else { return nil }
        return found
    }

    /// The only locations a toolchain binary may be taken from: Xcode's own
    /// bundle in /Applications, or the developer-tools tree (which is where
    /// the Command Line Tools install and every `xcode-select` root live).
    /// Both are root-owned; anywhere else is a path a user or an inherited
    /// environment could have arranged.
    static func isDeveloperToolchainPath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if standardized.hasPrefix("/Library/Developer/") { return true }
        let parts = standardized.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 2, parts[0] == "Applications" else { return false }
        let bundle = String(parts[1])
        return bundle.hasPrefix("Xcode") && bundle.hasSuffix(".app")
    }

    /// Environment variables that name a command for git to execute. Removed
    /// outright (an empty value is not always the same as unset).
    static let gitReadOnlyEnvironmentRemovals: [String] = [
        "GIT_EXTERNAL_DIFF",
        "GIT_PAGER",
        "GIT_SSH",
        "GIT_SSH_COMMAND",
        "GIT_ASKPASS",
        "SSH_ASKPASS",
        "GIT_EDITOR",
        "GIT_SEQUENCE_EDITOR",
        "GIT_CONFIG_PARAMETERS",
        "GIT_CONFIG_COUNT",
    ]

    /// Global `-c` overrides prepended to every read-tier git invocation. The
    /// exec-capable knobs a repository's own `.git/config` / `.gitattributes`
    /// can set: an external diff driver, a textconv filter, an fsmonitor hook
    /// (`git status` runs it), the hooks directory, and the pager.
    static let gitReadOnlyConfigOverrideArgs: [String] = [
        "--no-pager",
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.pager=cat",
        "-c", "core.sshCommand=",
        "-c", "diff.external=",
        "-c", "protocol.ext.allow=never",
    ]

    /// The inherited environment with the read-only overrides applied. Built by
    /// merging (not replacing) because `Process.environment` is wholesale.
    static var gitReadOnlyEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
            .merging(gitReadOnlyEnvironmentOverrides) { _, override in override }
        for key in gitReadOnlyEnvironmentRemovals { env.removeValue(forKey: key) }
        return env
    }

    static func runGit(
        _ args: [String],
        cwd: URL,
        timeout: TimeInterval,
        label: String,
        okStatuses: [Int32] = [0],
        treatNotAGitRepoSpecially: Bool = true
    ) -> GitRun {
        guard let git = gitExecutablePath() else {
            return .failure(errResult("git not found", code: "git_unavailable"))
        }
        let directoryFD: Int32
        do { directoryFD = try VerifiedPath.open(cwd, flags: O_RDONLY | O_DIRECTORY) }
        catch {
            return .failure(errResult("The authorized Git directory could not be verified.", code: "path_not_allowed"))
        }
        defer { _ = Darwin.close(directoryFD) }
        let run = runProcess(git, gitReadOnlyConfigOverrideArgs + args,
                             cwdDescriptor: directoryFD, timeout: timeout,
                             environment: gitReadOnlyEnvironment)
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
    var previousWasCR = false
    // CRLF is ONE Swift Character, so Character comparisons against CR or LF
    // never recognize it. Python str.splitlines uses scalar boundaries and
    // also recognizes the remaining universal line separators below.
    for scalar in text.unicodeScalars {
        if previousWasCR && scalar.value == 0x0A {
            previousWasCR = false
            continue
        }
        previousWasCR = scalar.value == 0x0D
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
            lines.append(current)
            current = ""
        default:
            current.unicodeScalars.append(scalar)
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

private struct CommandResult { let status: Int32; let stdout: String }

private func runCommand(_ launchPath: String, _ args: [String], timeout: TimeInterval = 5) -> CommandResult? {
    let result = runProcess(launchPath, args, timeout: timeout)
    guard result.launched, !result.timedOut, !result.captureReadFailed else { return nil }
    return CommandResult(status: result.status, stdout: result.stdout)
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
/// `text=True, errors="replace"`). Also backs system_info's `runCommand`.
struct ProcessRunResult {
    var launched: Bool
    var timedOut: Bool
    var status: Int32
    var stdout: String
    var stderr: String
    var stdoutTruncated: Bool = false
    var stderrTruncated: Bool = false
    var captureReadFailed: Bool = false
}

func runProcess(
    _ launchPath: String,
    _ args: [String],
    cwd: URL? = nil,
    timeout: TimeInterval,
    environment: [String: String]? = nil,
    captureByteLimit: Int? = nil
) -> ProcessRunResult {
    guard FileManager.default.isExecutableFile(atPath: launchPath) else {
        return ProcessRunResult(launched: false, timedOut: false, status: -1, stdout: "", stderr: "")
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launchPath)
    proc.arguments = args
    // nil ⇒ inherit this process's environment (Foundation's default, and every
    // pre-existing caller's behavior). A non-nil dictionary REPLACES the child's
    // environment wholesale, so callers must build it by merging onto the
    // inherited one rather than passing overrides alone.
    if let environment { proc.environment = environment }
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
    let stopCapture = ProcessTimeoutFlag()
    let outDone = DispatchSemaphore(value: 0)
    let errDone = DispatchSemaphore(value: 0)
    let outFH = outPipe.fileHandleForReading
    let errFH = errPipe.fileHandleForReading
    let outThread = Thread {
        box.setStdout(captureProcessPipe(outFH, byteLimit: captureByteLimit, stop: stopCapture))
        outDone.signal()
    }
    let errThread = Thread {
        box.setStderr(captureProcessPipe(errFH, byteLimit: captureByteLimit, stop: stopCapture))
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
    watchdogDone.set()
    // Descendants may retain the pipes after the child exits. Stop the
    // nonblocking readers after a shared grace; closing a descriptor from
    // another thread does not reliably interrupt a blocking read.
    let drainGrace: DispatchTime = .now() + 2.0
    let outOK = outDone.wait(timeout: drainGrace) == .success
    let errOK = errDone.wait(timeout: drainGrace) == .success
    if !outOK {
        timedOut.set()
        stopCapture.set()
        outDone.wait()
    }
    if !errOK {
        timedOut.set()
        stopCapture.set()
        errDone.wait()
    }
    let to = timedOut.get()
    let capturedOut = box.stdout()
    let capturedErr = box.stderr()
    return ProcessRunResult(
        launched: true,
        timedOut: to,
        status: proc.terminationStatus,
        stdout: decodeUTF8ReplacingPublic(capturedOut.data),
        stderr: decodeUTF8ReplacingPublic(capturedErr.data),
        stdoutTruncated: capturedOut.truncated,
        stderrTruncated: capturedErr.truncated,
        captureReadFailed: capturedOut.readFailed || capturedErr.readFailed
    )
}

#if canImport(Darwin)
/// `runProcess`, with the child's working directory pinned to an ALREADY
/// VERIFIED DIRECTORY DESCRIPTOR instead of a pathname.
///
/// `Process.currentDirectoryURL` takes a path, and a path is resolved again by
/// the child — which is the swap window `VerifiedPath` exists to close. Only
/// `posix_spawn_file_actions_addfchdir` puts the child in the exact inode the
/// walk verified, so this one caller spawns directly. Everything after the
/// launch — the dedicated drain threads, the bounded capture, the
/// SIGTERM-then-SIGKILL watchdog, the bounded drain wait — mirrors `runProcess`
/// above, and the reasons for each are documented there.
func runProcess(
    _ launchPath: String,
    _ args: [String],
    cwdDescriptor: Int32,
    inheritDescriptor: (source: Int32, target: Int32)? = nil,
    timeout: TimeInterval,
    environment: [String: String]? = nil,
    captureByteLimit: Int? = nil
) -> ProcessRunResult {
    let failed = ProcessRunResult(
        launched: false, timedOut: false, status: -1, stdout: "", stderr: "")
    guard cwdDescriptor >= 0, FileManager.default.isExecutableFile(atPath: launchPath) else {
        return failed
    }
    let outPipe = Pipe()
    let errPipe = Pipe()

    // Darwin's `posix_spawn` dup2 file action PRESERVES the source descriptor's
    // close-on-exec flag, unlike dup2(2) — and every `VerifiedPath` open sets
    // O_CLOEXEC, so the child received a closed descriptor and the engine
    // reported EBADF. A plain `dup` makes an inheritable copy of the same
    // verified vnode and leaves the caller's descriptor untouched.
    var inheritable: Int32 = -1
    defer { if inheritable >= 0 { _ = Darwin.close(inheritable) } }
    if let inheritDescriptor {
        inheritable = dup(inheritDescriptor.source)
        guard inheritable >= 0 else { return failed }
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawn_file_actions_addfchdir(&actions, cwdDescriptor) == 0,
          posix_spawn_file_actions_adddup2(
            &actions, outPipe.fileHandleForWriting.fileDescriptor, 1) == 0,
          posix_spawn_file_actions_adddup2(
            &actions, errPipe.fileHandleForWriting.fileDescriptor, 2) == 0
    else { return failed }
    if let inheritDescriptor {
        guard posix_spawn_file_actions_adddup2(
            &actions, inheritable, inheritDescriptor.target) == 0 else { return failed }
    }

    var argv: [UnsafeMutablePointer<CChar>?] = ([launchPath] + args).map { strdup($0) }
    argv.append(nil)
    defer { for argument in argv { free(argument) } }

    var childEnvironment: [UnsafeMutablePointer<CChar>?] =
        (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") }
    childEnvironment.append(nil)
    defer { for entry in childEnvironment { free(entry) } }
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, launchPath, &actions, nil, argv, childEnvironment)
    // The child owns the write ends now; this side must let go of them or the
    // drains below never see EOF.
    try? outPipe.fileHandleForWriting.close()
    try? errPipe.fileHandleForWriting.close()
    guard spawned == 0 else { return failed }

    let timedOut = ProcessTimeoutFlag()
    let box = ProcessOutputBox()
    let stopCapture = ProcessTimeoutFlag()
    let outDone = DispatchSemaphore(value: 0)
    let errDone = DispatchSemaphore(value: 0)
    let outFH = outPipe.fileHandleForReading
    let errFH = errPipe.fileHandleForReading
    let outThread = Thread {
        box.setStdout(captureProcessPipe(outFH, byteLimit: captureByteLimit, stop: stopCapture))
        outDone.signal()
    }
    let errThread = Thread {
        box.setStderr(captureProcessPipe(errFH, byteLimit: captureByteLimit, stop: stopCapture))
        errDone.signal()
    }
    outThread.stackSize = 1 << 20
    errThread.stackSize = 1 << 20
    outThread.start()
    errThread.start()

    let watchdogDone = ProcessTimeoutFlag()
    let watchdog = Thread {
        let deadline = Date().addingTimeInterval(timeout)
        let killDeadline = Date().addingTimeInterval(timeout + 2.0)
        var sentTerm = false
        while !watchdogDone.get() {
            Thread.sleep(forTimeInterval: 0.05)
            if watchdogDone.get() { return }
            let now = Date()
            if !sentTerm, now >= deadline {
                timedOut.set()
                kill(pid, SIGTERM)
                sentTerm = true
            }
            if now >= killDeadline {
                timedOut.set()
                kill(pid, SIGKILL)
                return
            }
        }
    }
    watchdog.start()

    var waitStatus: Int32 = 0
    while waitpid(pid, &waitStatus, 0) < 0 && errno == EINTR {}
    watchdogDone.set()

    let drainGrace: DispatchTime = .now() + 2.0
    if outDone.wait(timeout: drainGrace) != .success {
        timedOut.set()
        stopCapture.set()
        outDone.wait()
    }
    if errDone.wait(timeout: drainGrace) != .success {
        timedOut.set()
        stopCapture.set()
        errDone.wait()
    }

    // WIFEXITED/WEXITSTATUS by hand — the macros are not imported into Swift.
    // A child that died on a signal reports -1, which the grep caller reads as
    // "not a completed search" exactly as it read Foundation's signal status.
    let status: Int32 = (waitStatus & 0x7f) == 0 ? (waitStatus >> 8) & 0xff : -1
    let capturedOut = box.stdout()
    let capturedErr = box.stderr()
    return ProcessRunResult(
        launched: true,
        timedOut: timedOut.get(),
        status: status,
        stdout: decodeUTF8ReplacingPublic(capturedOut.data),
        stderr: decodeUTF8ReplacingPublic(capturedErr.data),
        stdoutTruncated: capturedOut.truncated,
        stderrTruncated: capturedErr.truncated,
        captureReadFailed: capturedOut.readFailed || capturedErr.readFailed
    )
}
#endif

/// Sendable locked box for the two concurrent pipe drains in `runProcess`.
/// Each setter is called exactly once (from its reader task); the getters run
/// after `group.wait()` so the reads happen-after both writes.
private struct ProcessPipeCapture {
    var data = Data()
    var truncated = false
    var readFailed = false
}

/// Drain to EOF even after retaining the budget so a full pipe cannot block
/// the engine. Existing callers with no budget keep their capture behavior.
private func captureProcessPipe(_ handle: FileHandle, byteLimit: Int?, stop: ProcessTimeoutFlag) -> ProcessPipeCapture {
    defer { try? handle.close() }
    var result = ProcessPipeCapture()
    let limit = max(0, byteLimit ?? Int.max)
    let fd = handle.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
        result.readFailed = true
        return result
    }
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while !stop.get() {
        var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        // Bounded readiness wait lets the owner stop a pipe held by a descendant.
        let ready = poll(&event, 1, 100)
        if ready == 0 { continue }
        if ready < 0 {
            if errno == EINTR { continue }
            result.readFailed = true
            break
        }
        let count = read(fd, &buffer, buffer.count)
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { continue }
            result.readFailed = true
            break
        }
        let retained = min(count, max(0, limit - result.data.count))
        result.data.append(contentsOf: buffer.prefix(retained))
        if retained < count { result.truncated = true }
    }
    return result
}

private final class ProcessOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = ProcessPipeCapture()
    private var err = ProcessPipeCapture()
    func setStdout(_ d: ProcessPipeCapture) { lock.lock(); out = d; lock.unlock() }
    func setStderr(_ d: ProcessPipeCapture) { lock.lock(); err = d; lock.unlock() }
    func stdout() -> ProcessPipeCapture { lock.lock(); defer { lock.unlock() }; return out }
    func stderr() -> ProcessPipeCapture { lock.lock(); defer { lock.unlock() }; return err }
}

/// Thread-safe one-shot flag for the process watchdog and pipe shutdown.
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
