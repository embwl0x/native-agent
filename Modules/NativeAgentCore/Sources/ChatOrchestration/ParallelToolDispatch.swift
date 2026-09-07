import Foundation
import NativeAgentCore
import PersistenceCore
import MacIntegration

// MARK: - Parallel dispatch of independent tool calls (U1 step 6, 2026-06-10)
//
// The OpenAI adapter requests parallel_tool_calls:true and Anthropic batches
// tool_use blocks freely — the model routinely emits 2+ calls per iteration,
// which this loop used to execute strictly one-by-one. When an iteration
// carries multiple SIDE-EFFECT-SAFE calls, they now run concurrently in a
// task group (cap: maxConcurrentPerIteration) and the results are
// reassembled in ORIGINAL INDEX ORDER, so the provider-visible wire shape —
// one assistant message with N tool_use blocks, then ONE user message with N
// tool_result blocks paired by id in the same order — is byte-identical to
// the serial path. (Pairing convention verified in both OAuth adapters:
// tool_result.tool_use_id / function_call_output.call_id echo; blocks are
// encoded in message order, so slot order == tool_use order is the contract.)
//
// SAFE-SET DERIVATION (mechanical, fail-closed — every rule is a veto;
// a tool is parallel-safe only if it survives ALL of them):
//   1. mcp__* tools → SERIAL (external server, side effects unknowable).
//   2. Full-Mac surface lists (SwiftToolDispatcher.fullMacFileToolNames /
//      SystemToolNames / AppToolNames / BuilderToolNames / RestartToolNames)
//      → SERIAL. These are the process-spawn / write-power tools (shell,
//      bash, apply_patch, run_tests, swift_build, swift_test, write_file,
//      mac_focus_app, app_restart...). Referencing the dispatcher constants
//      directly keeps this list drift-proof, same pattern as
//      ToolPreloadHeuristics' builder group.
//      CARVE-OUT (2026-09-01): the READ half of the file surface —
//      SwiftToolDispatcher.fullMacReadOnlyFileToolNames MINUS
//      optionalIndexLockWriters, i.e. file_excerpt, grep, git_status, git_log
//      and repo_dirty_summary — is admitted BEFORE this veto. Vetoing them
//      cost a code turn four serial round-trips for one read fan-out. The
//      "even the read git tools can touch .git/index" worry was REAL and is
//      fixed at the source: FileSystemActions.runGit now runs every git read
//      with GIT_OPTIONAL_LOCKS=0, git's own switch for read-only callers, so
//      the opportunistic index refresh is not written at all. `git diff` of
//      the working tree is the one command git does not apply that switch to,
//      so it is excluded here (see optionalIndexLockWriters). `write_file`
//      stays in the veto with the rest of the surface. Effect-time gates are
//      untouched — Full-Mac access, the autonomy gate and the sandbox still
//      decide whether any of these run at all.
//   3. Explicit serial names: session-state mutators (tool_load/tool_unload
//      write ActiveToolsStore; agent_swarm spawns workers), the agent
//      subprocess pair (invoke_claude/invoke_codex), and the notify
//      channels — mirrors SecurityCenter.profile's explicit branches.
//   4. Mac Integration WRITE tools → SERIAL, derived from the SAME
//      (integration, mode) table the dispatch gate uses
//      (ToolPreloadHeuristics.macIntegrationGates, mode == .write).
//   5. Danger-keyword veto — the keyword classes are mirrored VERBATIM from
//      SecurityCenter.profile's classifier (shell/exec, delete/destructive,
//      write/save/create/patch/..., applescript/system-control, send/post/
//      message/reply, trade/money, secret/credential).
//   6. Positive read signal required: the name must carry one of
//      SecurityCenter's safe_read keywords (read/list/search/recall/status/
//      get) OR sit in the small audited read-only allowlist (time_now,
//      agent_introspect, web_fetch class...). No signal → SERIAL.
// Net effect: read_file, list_dir, recall_memory, search_kg, mail_search,
// x_search, file_excerpt, grep, git_status, git_log and
// repo_dirty_summary parallelize; anything write-class, shell-class,
// Mac-Integration-write, or approval-gated (approval-gated tools are
// write/shell-class by construction in this catalog — the autonomy-gate
// dispatch wrapper continues to gate EVERY call regardless) stays serial.
//
// MIXED BATCHES: consecutive parallel-safe calls coalesce into one
// concurrent group; every unsafe call is its own serial group. Groups
// execute strictly in original order (a write at index k never overlaps
// reads at indices <k or >k), so any execution is observationally
// equivalent to the serial order for side-effect-bearing tools.
//
// ROLLBACK LEVER: set env NATIVE_AGENT_SERIAL_TOOL_DISPATCH=1 (or
// true/yes/on) to force the old strictly-serial path. Default is parallel
// ON. (`forceSerialOverride` is the task-local test hook for the same
// switch.)
//
// FAILURE ISOLATION: each concurrent child catches its own error — a
// throwing tool becomes that slot's `{"error": ...}` result exactly as the
// serial path produces, and never cancels siblings. Turn cancellation
// cancels all children via structured concurrency (task-group teardown);
// the parallel set is read-only by construction, so there are no orphan
// writes to clean up.
//
// STEP-5 INTERACTION: results are still appended as ONE user message per
// iteration, so IntraTurnToolResultClearing ages a parallel batch exactly
// like a serial one (the sweep counts tool-result MESSAGES, not blocks).
enum ParallelToolDispatch {
    /// Concurrency cap per iteration. Anything beyond this queues behind the
    /// window (completion-ordered refill).
    static let maxConcurrentPerIteration = 4

    /// Rollback lever (documented above). Checked once per process.
    static let serialFallbackEnvVar = "NATIVE_AGENT_SERIAL_TOOL_DISPATCH"

    /// Pure, injectable parser for the env flag (unit-testable without
    /// mutating process state).
    static func isSerialFallbackForced(env: [String: String]) -> Bool {
        guard let raw = env[serialFallbackEnvVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !raw.isEmpty else { return false }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    static let serialFallbackForcedFromEnv =
        isSerialFallbackForced(env: ProcessInfo.processInfo.environment)

    /// Test hook: binds over the env flag for the duration of a task tree.
    /// Production never binds it (nil → env flag decides).
    @TaskLocal static var forceSerialOverride: Bool?

    static var effectiveForceSerial: Bool {
        forceSerialOverride ?? serialFallbackForcedFromEnv
    }

    // MARK: Safe-set predicate (rules 1-6 above)

    /// Full-Mac power surface — referenced from the dispatcher constants so
    /// the set cannot drift from the catalog (rule 2).
    static let fullMacSerialNames: Set<String> = Set(
        SwiftToolDispatcher.fullMacFileToolNames
            + SwiftToolDispatcher.fullMacSystemToolNames
            + SwiftToolDispatcher.fullMacAppToolNames
            + SwiftToolDispatcher.fullMacBuilderToolNames
            + SwiftToolDispatcher.fullMacRestartToolNames
    )

    /// `git diff` of the WORKING TREE is the one Full-Mac read that is not
    /// provably write-free. FileSystemActions runs every git read with
    /// `GIT_OPTIONAL_LOCKS=0`, which suppresses the opportunistic `.git/index`
    /// stat-cache write for `git status`, `git log` and `git diff --staged` —
    /// but git's `builtin/diff.c refresh_index_quietly()` does not consult
    /// `use_optional_locks()`, so a plain `git diff` still rewrites the index
    /// (verified on git 2.50.1; pinned by
    /// RepoIntrospectActionsTests.readOnlyGitReadsLeaveTheIndexUnwritten...).
    /// A set whose premise is "these mutate nothing" cannot contain it, so it
    /// stays serial. If a future git honors the flag here, that test fails and
    /// this entry can be deleted.
    static let optionalIndexLockWriters: Set<String> = ["git_diff"]

    /// Rule 2 read carve-out — the audited READ half of the Full-Mac file
    /// surface, admitted before the veto above. Same drift-proofing: the names
    /// come from the dispatcher constant, so a tool moved between the read and
    /// write halves changes its dispatch class with it. Anything NOT in this
    /// half (write_file, and every future addition to the write list or to the
    /// system/app/builder/restart lists) still falls to the veto.
    static let fullMacReadOnlyNames: Set<String> = Set(
        SwiftToolDispatcher.fullMacReadOnlyFileToolNames
    ).subtracting(optionalIndexLockWriters)

    /// Rule 3 — explicit serial names (state mutators, subprocess spawners,
    /// notify channels). claude_message/codex_message also trip the
    /// "message" keyword; listed anyway so the intent is visible.
    static let explicitSerialNames: Set<String> = [
        "tool_load", "tool_unload", "agent_swarm",
        "invoke_claude", "invoke_codex",
        "mac_notify", "mobile_notify", "mac.notify", "mobile.notify",
        "claude_message", "codex_message",
    ]

    /// Rule 5 — danger keywords, drawn from SecurityCenter.profile's
    /// classifier classes. NOT a verbatim mirror: SecurityCenter carves a
    /// read-only exception for messages_recent_threads that this veto
    /// deliberately does not replicate — stricter here is fail-safe (a
    /// vetoed read-only tool just runs serially). Any hit vetoes.
    static let dangerKeywords: [String] = [
        // shell class
        "shell", "terminal", "exec",
        // delete/destructive class
        "delete", "trash", "remove", "wipe", "erase", ".rm", "quarantine",
        // write class
        "write", "save", "create", "patch", "edit", "append", "promote",
        "install", "enable", "disable", "configure", "set_", "move",
        // system-control class
        "applescript", "jxa", "shortcut", "focus_app", "quit_app",
        "sleep", "lock_screen", "set_volume",
        // external-send class
        "send", "post", "tweet", "message", "reply",
        // money class
        "trade", "broker", "order", "buy", "sell", "wallet",
        // secrets class
        "secret", "credential", "token", "keychain",
    ]

    /// Rule 6 — SecurityCenter's safe_read keyword set.
    static let safeReadKeywords: [String] = [
        "read", "list", "search", "recall", "status", "get",
    ]

    /// Rule 6 fallback — audited read-only tools whose names carry no
    /// safe_read keyword. Keep tight; growing this list requires reading
    /// the tool's impl and confirming zero side effects.
    static let readOnlyAllowlist: Set<String> = [
        "time_now", "agent_introspect", "daemon_introspect",
        "recent_trace_summary", "tool_catalog",
        "web_fetch", "x_me", "x_timeline",
        "music_now_playing", "market_quote",
    ]

    /// The predicate. Input is the INTERNAL tool name (post
    /// ProviderToolNameMap reverse-mapping), matching what dispatch sees.
    static func isParallelSafe(internalToolName name: String) -> Bool {
        // Rule 1: external MCP tools — unknowable side effects.
        if name.hasPrefix("mcp__") { return false }
        // Rule 2 carve-out: the audited READ half of the Full-Mac file
        // surface. Consulted before the veto (and before the keyword rules,
        // which have no positive signal for `grep`/`git_diff`/`git_log`/
        // `file_excerpt`/`repo_dirty_summary`).
        if fullMacReadOnlyNames.contains(name) { return true }
        // Rule 2: Full-Mac power surface.
        if fullMacSerialNames.contains(name) { return false }
        // Rule 3: explicit serial names.
        if explicitSerialNames.contains(name) { return false }
        // Rule 4: Mac Integration write-mode (same table the dispatch gate
        // uses).
        if ToolPreloadHeuristics.macIntegrationGates[name]?.mode == .write {
            return false
        }
        let lower = name.lowercased()
        // Rule 5: danger-keyword veto (incl. the rm_/mv_ prefix forms and
        // the ".set" suffix from SecurityCenter's classifier).
        if dangerKeywords.contains(where: { lower.contains($0) }) { return false }
        if lower.hasPrefix("rm_") || lower.hasPrefix("mv_") || lower.hasSuffix(".set") {
            return false
        }
        // Rule 6: positive read signal required (fail closed).
        if readOnlyAllowlist.contains(name) { return true }
        return safeReadKeywords.contains(where: { lower.contains($0) })
    }

    /// Fleet-dispatch exception (User, 2026-08-27): `invoke_codex` is serial by
    /// name (explicitSerialNames) because two spawns sharing a checkout stash
    /// each other's edits. But when EVERY invoke_codex call in the iteration
    /// carries an explicit cwd and those cwds are pairwise distinct (per-lane
    /// worktrees), the spawns share no mutable state and may run concurrently —
    /// that is exactly Agent's lane-burn shape. Any missing, blank, or
    /// duplicate cwd disables the override for the whole iteration (fail
    /// closed, back to serial). `invoke_claude` is deliberately never
    /// overridden: it resumes ONE pinned session, and concurrent resumes of
    /// the same session corrupt it.
    ///
    /// Returns one entry per call: `true` to force parallel-safe, `nil` to
    /// keep the name-based verdict.
    static func fleetParallelOverrides(
        names: [String], inputs: [[String: JSONValue]]
    ) -> [Bool?] {
        let none: [Bool?] = Array(repeating: nil, count: names.count)
        let codexIdx = names.indices.filter { names[$0] == "invoke_codex" }
        guard codexIdx.count >= 2 else { return none }
        // Distinctness must be FILESYSTEM identity, not string identity:
        // symlinked or case-aliased paths on APFS can name the same checkout
        // (gpt-5.5 review BLOCKING, 2026-08-27). Each cwd must exist and
        // resolve to a unique (device, inode); anything else fails closed.
        var identities: Set<FleetCwdIdentity> = []
        for i in codexIdx {
            guard case .string(let c)? = inputs[i]["cwd"],
                  !c.trimmingCharacters(in: .whitespaces).isEmpty,
                  let identity = Self.fleetCwdIdentity(path: c),
                  identities.insert(identity).inserted else {
                return none
            }
        }
        var out = none
        for i in codexIdx { out[i] = true }
        return out
    }

    struct FleetCwdIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    /// (device, inode) of the resolved directory — nil when it does not
    /// exist. Symlinks are resolved before stat so aliases collapse.
    static func fleetCwdIdentity(path: String) -> FleetCwdIdentity? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
              let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
              let device = (attrs[.systemNumber] as? NSNumber)?.uint64Value else {
            return nil
        }
        return FleetCwdIdentity(device: device, inode: inode)
    }

    // MARK: Iteration planning

    /// One iteration's execution plan: consecutive parallel-safe indices
    /// coalesce into a `.concurrent` group (only when 2+ — a lone safe call
    /// runs serially so single-call iterations keep the exact serial event
    /// order); everything else is its own `.sequential` slot. Groups run in
    /// order; results always reassemble by original index.
    enum ExecutionGroup: Equatable {
        case concurrent([Int])
        case sequential(Int)
    }

    static func plan(parallelSafe: [Bool], forceSerial: Bool) -> [ExecutionGroup] {
        guard !forceSerial else {
            return parallelSafe.indices.map { .sequential($0) }
        }
        var groups: [ExecutionGroup] = []
        var run: [Int] = []
        func flushRun() {
            if run.count >= 2 {
                groups.append(.concurrent(run))
            } else {
                for idx in run { groups.append(.sequential(idx)) }
            }
            run = []
        }
        for (idx, safe) in parallelSafe.enumerated() {
            if safe {
                run.append(idx)
            } else {
                flushRun()
                groups.append(.sequential(idx))
            }
        }
        flushRun()
        return groups
    }
}
