import Foundation
import PersistenceCore

// MARK: - Wave 29 W3: Local connector-action registry (DORMANT)
//
// A tiny in-process registry of natively-executable connector actions. When a
// `SwiftNativeDispatcher` is constructed WITH a `LocalConnectorActions` that
// knows the requested tool, `dispatch()` runs it NATIVELY in Swift and skips
// the HTTP round-trip entirely — still writing the same client-side ledger
// entry. When the registry is absent (the production default) or doesn't know
// the tool, dispatch falls back to the existing DORMANT-PROXY HTTP path.
//
// This is the per-action migration seam CUTOVER_PLAN §6.11 promised: each
// connector action ports independently without re-touching the dispatcher
// infrastructure. NOTHING wires this into a production caller — the default
// `makeDispatcher` factory passes `localActions: nil`. A later wave flips it on.

/// A single native action handler. Pure-ish: takes the input dict + a
/// connector context, returns the result payload (the value that becomes
/// `Receipt.output` / the `output` field of a DispatchResult).
public typealias ConnectorActionHandler =
    @Sendable (_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue

/// Registry of natively-executable connector actions, keyed by tool name.
public struct LocalConnectorActions: Sendable {
    private let handlers: [String: ConnectorActionHandler]
    /// Tool names whose handler mutates the filesystem. Used so dry-run skips
    /// execution (mirrors the daemon's `side_effects` flag for these tools).
    private let sideEffecting: Set<String>
    /// Tool names whose daemon registration uses `Tool.TRIVIAL_VERIFY`. The
    /// daemon emits `verify_passed=True` for these (the read-only sentinel,
    /// the retired daemon), and `None` for read-only tools left on
    /// `_DEFAULT_VERIFY`. Encoding it here (rather than blanket "every
    /// non-side-effecting tool gets verify_passed=true") keeps the native
    /// receipt's `verifyPassed` byte-correct even if a future read-only action
    /// whose daemon tool is `_DEFAULT_VERIFY` is registered. (Wave 36 W11 /
    /// §6.30 prereq #9 — gpt-5.5 review: all 13 read-only actions in
    /// `.fileSystemDefault` ARE TRIVIAL_VERIFY today, but encode it explicitly
    /// so the parity does not silently break later.)
    private let trivialVerify: Set<String>

    public init(
        handlers: [String: ConnectorActionHandler],
        sideEffecting: Set<String> = [],
        trivialVerify: Set<String> = []
    ) {
        self.handlers = handlers
        self.sideEffecting = sideEffecting
        self.trivialVerify = trivialVerify
    }

    public func canHandle(_ tool: String) -> Bool { handlers[tool] != nil }

    public func isSideEffecting(_ tool: String) -> Bool { sideEffecting.contains(tool) }

    /// True when the tool's daemon registration is `Tool.TRIVIAL_VERIFY` (so the
    /// native receipt should set `verifyPassed=true` to match the daemon's
    /// read-only sentinel). Returns false for `_DEFAULT_VERIFY` read-only tools
    /// (daemon emits `verify_passed=None`) and for side-effecting tools (their
    /// real verify runs server-side; native never executes them on the flip
    /// path today).
    public func isTrivialVerify(_ tool: String) -> Bool { trivialVerify.contains(tool) }

    public func run(_ tool: String, input: [String: JSONValue], ctx: ConnectorActionContext) -> JSONValue? {
        guard let h = handlers[tool] else { return nil }
        return h(input, ctx)
    }

    public var toolNames: Set<String> { Set(handlers.keys) }

    /// The file/system connector actions ported into native Swift.
    ///
    /// Wave 29 W3 (§6.30) — first 5:
    ///   read_file / file_excerpt / list_dir / system_info — read-only
    ///   write_file — side-effecting (skipped on dry_run)
    ///
    /// Wave 32 W08 (§6.76) — 5 MORE, all READ-ONLY (no filesystem mutation;
    /// they shell out to git/rg/grep but write nothing):
    ///   grep / git_status / git_diff / git_log / repo_dirty_summary
    ///
    /// Wave 34 W06 (§6.97 — retry of the W33 W08 that died mid-task) — 4 MORE
    /// persona/system actions, all READ-ONLY (no filesystem mutation):
    ///   persona_read / persona_list_skills / workspace_list / time_now.
    ///   These bind the SAME on-disk persona/skill/workspace files the daemon
    ///   binds; `time_now` is a pure clock read with no FS.
    ///
    ///   AUDIT NOTE: the brief asked for 5. The 5th candidate (`scratchpad_read`,
    ///   the retired daemon) was AUDITED and DEFERRED — it depends on
    ///   the stateful, in-process `Scratchpad` TTL store
    ///   with no shared on-disk surface for byte-parity, so it is a subsystem
    ///   port, not a self-contained connector-action port. Every other unported
    ///   builtin handler (tool_catalog, daemon_status, context_lookup,
    ///   recall_*, tradingview_watchlist, daemon_introspect, recent_trace_summary)
    ///   requires a live runtime/dispatcher object and is likewise not a clean
    ///   self-contained port. These 4 are the complete set of read-only,
    ///   runtime-independent persona/system handlers.
    public static let fileSystemDefault = LocalConnectorActions(
        handlers: [
            // Wave 29 W3
            "read_file":    { FileSystemActions.readFile($0, $1) },
            "file_excerpt": { FileSystemActions.fileExcerpt($0, $1) },
            "write_file":   { FileSystemActions.writeFile($0, $1) },
            "list_dir":     { FileSystemActions.listDir($0, $1) },
            "system_info":  { FileSystemActions.systemInfo($0, $1) },
            // Wave 32 W08 — read-only repo introspection
            "grep":               { FileSystemActions.grep($0, $1) },
            "git_status":         { FileSystemActions.gitStatus($0, $1) },
            "git_diff":           { FileSystemActions.gitDiff($0, $1) },
            "git_log":            { FileSystemActions.gitLog($0, $1) },
            "repo_dirty_summary": { FileSystemActions.repoDirtySummary($0, $1) },
            // Wave 34 W06 — read-only persona/system introspection
            "persona_read":        { PersonaSystemActions.personaRead($0, $1) },
            "persona_list_skills": { PersonaSystemActions.personaListSkills($0, $1) },
            "workspace_list":      { PersonaSystemActions.workspaceList($0, $1) },
            "time_now":            { PersonaSystemActions.timeNow($0, $1) },
        ],
        // Only write_file mutates the filesystem. The wave-32 and wave-34
        // additions are all read-only (git/rg/grep introspection; persona/
        // workspace file reads; clock read), so none is side-effecting.
        sideEffecting: ["write_file"],
        // Every read-only action's daemon registration uses Tool.TRIVIAL_VERIFY
        // (verified against the retired daemon + agent_tools.py registrations:
        // read_file / file_excerpt / list_dir / grep / system_info / git_status /
        // git_diff / git_log / repo_dirty_summary / persona_read /
        // persona_list_skills / workspace_list / time_now). `write_file` is
        // side-effecting with a real `_verify_write_file` and is NOT listed here.
        trivialVerify: [
            "read_file", "file_excerpt", "list_dir", "system_info",
            "grep", "git_status", "git_diff", "git_log", "repo_dirty_summary",
            "persona_read", "persona_list_skills", "workspace_list", "time_now",
        ]
    )

    /// Wave 36 W11 (§6.138) — SCOPED single-action registry for the FIRST
    /// production Dispatcher native flip. Contains ONLY `persona_read` — a
    /// read-only, always-auto, non-sensitive persona-file read (daemon
    /// registration: autonomy=AUTO, side_effects=False, verify=TRIVIAL_VERIFY,
    /// always-on, category="persona"). The production seam
    /// (`NativeClient._swiftDispatch`) wires THIS registry — NOT
    /// `.fileSystemDefault` — when `.dispatchPersonaRead` is ON, so exactly one
    /// action goes native while the other 13 stay DORMANT (HTTP-proxied) and the
    /// 14 §6.30 pre-flip prereqs remain binding for them. `persona_read` is
    /// registered TRIVIAL_VERIFY so the native receipt's `verifyPassed=true`
    /// matches the daemon. NOT side-effecting.
    public static let personaReadOnly = LocalConnectorActions(
        handlers: [
            "persona_read": { PersonaSystemActions.personaRead($0, $1) },
        ],
        sideEffecting: [],
        trivialVerify: ["persona_read"]
    )

    /// Wave 37 W08 (§6.159) — SCOPED single-action registry for the SECOND
    /// production Dispatcher native flip. Contains ONLY `workspace_list` — a
    /// read-only, always-auto, non-sensitive directory listing of `workspace/`
    /// (daemon registration: autonomy=AUTO, side_effects=False,
    /// verify=TRIVIAL_VERIFY, category="workspace", always_on=False). The
    /// production seam (`NativeClient._swiftDispatch`) wires THIS registry — NOT
    /// `.fileSystemDefault`, NOT `.personaReadOnly` — when `.dispatchWorkspaceList`
    /// is ON, so exactly one action goes native while every other connector
    /// action stays DORMANT (HTTP-proxied) and the 14 §6.30 pre-flip prereqs
    /// remain binding for them. `workspace_list` is registered TRIVIAL_VERIFY so
    /// the native receipt's `verifyPassed=true` matches the daemon. NOT
    /// side-effecting (list-only; the native handler never mkdir's, mirroring the
    /// Python C4 fix).
    public static let workspaceListReadOnly = LocalConnectorActions(
        handlers: [
            "workspace_list": { PersonaSystemActions.workspaceList($0, $1) },
        ],
        sideEffecting: [],
        trivialVerify: ["workspace_list"]
    )

    /// Wave 38 W07 (§6.180) — SCOPED single-action registry for the THIRD
    /// production Dispatcher native flip. Contains ONLY `time_now` — the SAFEST
    /// remaining action: a PURE clock read with NO filesystem, NO registry, NO
    /// sandbox (daemon registration: autonomy=AUTO, side_effects=False,
    /// verify=TRIVIAL_VERIFY, category="core", always_on=True). The production
    /// seam (`NativeClient._swiftDispatch`) wires THIS registry — NOT
    /// `.fileSystemDefault`, NOT `.personaReadOnly`, NOT `.workspaceListReadOnly`
    /// — when `.dispatchTimeNow` is ON, so exactly one action goes native while
    /// every other connector action stays DORMANT (HTTP-proxied) and the 14 §6.30
    /// pre-flip prereqs remain binding for them. `time_now` is registered
    /// TRIVIAL_VERIFY so the native receipt's `verifyPassed=true` matches the
    /// daemon. NOT side-effecting (clock read only). It was chosen over
    /// `persona_list_skills` because the latter walks skill-body dirs + merges
    /// registry.json + paginates (many divergence surfaces); `time_now` has a
    /// single edge (unknown-timezone → bad_input) already byte-mirrored against
    /// the retired daemon:_exec_time_now in PersonaSystemActions.timeNow.
    public static let timeNowReadOnly = LocalConnectorActions(
        handlers: [
            "time_now": { PersonaSystemActions.timeNow($0, $1) },
        ],
        sideEffecting: [],
        trivialVerify: ["time_now"]
    )

    /// Wave 39 W08 (§6.201) — SCOPED single-action registry for the FOURTH
    /// production Dispatcher native flip. Contains ONLY `persona_list_skills` — a
    /// read-only skill-manifest probe (daemon registration: autonomy=AUTO,
    /// side_effects=False, verify=TRIVIAL_VERIFY, category="persona",
    /// always_on=True). The production seam (`NativeClient._swiftDispatch`) wires
    /// THIS registry — NOT `.fileSystemDefault`, NOT `.personaReadOnly`, NOT
    /// `.workspaceListReadOnly`, NOT `.timeNowReadOnly` — when
    /// `.dispatchPersonaListSkills` is ON, so exactly one action goes native while
    /// every other connector action stays DORMANT (HTTP-proxied) and the 14 §6.30
    /// pre-flip prereqs remain binding for them. `persona_list_skills` is
    /// registered TRIVIAL_VERIFY so the native receipt's `verifyPassed=true`
    /// matches the daemon. NOT side-effecting (list-only; walks the two skill-body
    /// dirs + merges data/skills/registry.json + extract-description + paginate,
    /// writing nothing). It is the LAST of the four read-only persona/system
    /// actions to flip — chosen last because it has the most divergence surfaces
    /// (two-dir merge, registry.json metadata merge, description extraction,
    /// negative-offset pagination), all byte-mirrored against
    /// the retired daemon:_exec_persona_list_skills in
    /// PersonaSystemActions.personaListSkills (and pinned by the
    /// PersonaSystemActionsTests parity suite).
    public static let personaListSkillsReadOnly = LocalConnectorActions(
        handlers: [
            "persona_list_skills": { PersonaSystemActions.personaListSkills($0, $1) },
        ],
        sideEffecting: [],
        trivialVerify: ["persona_list_skills"]
    )

    /// Wave 40 W14 (§6.220) — SCOPED single-action registry for the FIFTH
    /// production Dispatcher native flip. Contains ONLY `read_file` — a read-only
    /// UTF-8 file read (daemon registration: autonomy=AUTO, side_effects=False,
    /// verify=TRIVIAL_VERIFY, deterministic/cacheable). The production seam
    /// (`NativeClient._swiftDispatch`) wires THIS registry — NOT
    /// `.fileSystemDefault`, NOT any prior scoped registry — when
    /// `.dispatchReadFile` is ON, so exactly one action goes native while every
    /// other connector action stays DORMANT (HTTP-proxied) and the 14 §6.30
    /// pre-flip prereqs remain binding for them. `read_file` is registered
    /// TRIVIAL_VERIFY so the native receipt's `verifyPassed=true` matches the
    /// daemon. NOT side-effecting (pure read). It is the FIRST non-persona/system
    /// FileSystemActions action to flip: the native handler reuses the EXACT
    /// FileSystemActions sandbox (allowedRoots + isSensitiveDataPath) that the
    /// already-LIVE `persona_read` flip shares (§6.138), and has NO subprocess
    /// (unlike grep/git_*/system_info), making it the simplest remaining read-only
    /// action — byte-mirrored against the retired daemon:_exec_read_file in
    /// FileSystemActions.readFile and pinned by the FileSystemActions parity suite.
    public static let readFileReadOnly = LocalConnectorActions(
        handlers: [
            "read_file": { FileSystemActions.readFile($0, $1) },
        ],
        sideEffecting: [],
        trivialVerify: ["read_file"]
    )

    /// Wave 40 W14 (§6.220) — SCOPED single-action registry for the SIXTH
    /// production Dispatcher native flip. Contains ONLY `file_excerpt` — a
    /// read-only bounded line-window file read (daemon registration: autonomy=AUTO,
    /// side_effects=False, verify=TRIVIAL_VERIFY, deterministic/cacheable). The
    /// production seam (`NativeClient._swiftDispatch`) wires THIS registry — NOT
    /// `.fileSystemDefault`, NOT any prior scoped registry — when
    /// `.dispatchFileExcerpt` is ON, so exactly one action goes native while every
    /// other connector action stays DORMANT (HTTP-proxied) and the 14 §6.30
    /// pre-flip prereqs remain binding for them. `file_excerpt` is registered
    /// TRIVIAL_VERIFY so the native receipt's `verifyPassed=true` matches the
    /// daemon. NOT side-effecting (pure read). It pairs with `read_file` as the
    /// SIXTH flip: the same shared FileSystemActions sandbox, NO subprocess, plus
    /// one extra deterministic surface (the start_line/max_lines line-window
    /// slice), byte-mirrored against the retired daemon:_exec_file_excerpt in
    /// FileSystemActions.fileExcerpt and pinned by the FileSystemActions parity
    /// suite.
    public static let fileExcerptReadOnly = LocalConnectorActions(
        handlers: [
            "file_excerpt": { FileSystemActions.fileExcerpt($0, $1) },
        ],
        sideEffecting: [],
        trivialVerify: ["file_excerpt"]
    )

    /// Wave 41 W14 (§6.240) — SCOPED single-action registry for the SEVENTH
    /// production Dispatcher native flip. Contains ONLY `system_info` — a read-only
    /// macOS system-state probe (daemon registration the retired daemon:
    /// autonomy=AUTO, side_effects=False, verify=TRIVIAL_VERIFY, category="system",
    /// always_on=False). The production seam (`NativeClient._swiftDispatch`) wires
    /// THIS registry — NOT `.fileSystemDefault`, NOT any prior scoped registry —
    /// when `.dispatchSystemInfo` is ON, so exactly one action goes native while
    /// every other connector action stays DORMANT (HTTP-proxied) and the 14 §6.30
    /// pre-flip prereqs remain binding for them. `system_info` is registered
    /// TRIVIAL_VERIFY so the native receipt's `verifyPassed=true` matches the daemon.
    /// NOT side-effecting (pure read). CRITICALLY it is the ONLY remaining ported
    /// read-only action that does NOT touch the file_access sandbox: it takes NO
    /// `path` input and runs NO `resolvePath`/`allowedRoots`/`isSensitiveDataPath`
    /// check (it reads statfs + vm_stat/ping/pmset only). That makes it the safe
    /// flip THIS wave while the W02 cluster fixes the empty-repoRoot/empty-allowedRoots
    /// `DispatchContext.defaultForSurface` sandbox-threading gap that the §6.220
    /// round-2 reopen flagged for the sandbox-coupled actions (read_file/file_excerpt
    /// + list_dir/grep/git_*). Byte-mirrored against
    /// the retired daemon:_exec_system_info in FileSystemActions.systemInfo.
    public static let systemInfoReadOnly = LocalConnectorActions(
        handlers: [
            "system_info": { FileSystemActions.systemInfo($0, $1) },
        ],
        sideEffecting: [],
        trivialVerify: ["system_info"]
    )
}
