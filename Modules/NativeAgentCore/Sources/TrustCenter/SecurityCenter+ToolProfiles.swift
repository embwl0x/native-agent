import Foundation
import PersistenceCore

/// Read-only projection of SecurityCenter's canonical tool profile risk.
/// Consumers may use this metadata for advisory behavior, but it grants no
/// authority and does not replace effect-time SecurityCenter evaluation.
public enum CanonicalToolRisk: String, Sendable, Codable, Equatable {
    case low
    case medium
    case high
    case critical
}

extension SwiftNativeSecurityCenter {
    static let catalogToolNames: Set<String> = ["tool_catalog", "list_tools", "tool_load", "tool_result_page"]
    // notificationToolNames are the carve-out for one-shot ping/notify
    // tools — they get the "notification" capability tag in `profile`
    // which exempts them from the external_send approval gate (a literal
    // notify-banner doesn't reach a third party). claude_message/codex_message
    // are in here because they're agent-to-agent bridge pings backed by local
    // inbox writes; codex_message may also post a local NativeAgent Mac
    // notification, still with no third-party send. (2026-06-08/15)
    static let notificationToolNames: Set<String> = [
        // 2026-09-07: bots tools only read/write local definitions, shelf receipts,
        // reader acknowledgements, or enqueue requests. bot_ask also uses the
        // runner's provider admission/spend gates; none sends or notifies.
        "bot_create", "bot_update", "bot_pause", "bot_run_once", "bot_list", "shelf_read", "shelf_entry", "bot_ask", "bot_delete",
        "mac.notify",
        "mobile.notify",
        "claude_message",
        "codex_message",
        "omp_message",
    ]
    // Local agent bridge handoffs are meant to carry task specifications to
    // another local agent. Those specs often contain instruction-looking text
    // ("do not edit X", "system prompt", "Personal Access Token") that should
    // still be audited/redacted, but not converted into an unserviceable
    // approval ask when the origin is already local or trusted.
    static let localAgentBridgeToolNames: Set<String> = [
        "claude_message",
        "codex_message",
        "omp_message",
        "invoke_claude",
        "invoke_codex",
    ]
    static let approvalStagingToolNames: Set<String> = [
        "agentmail.send",
        "agentmail_send",
        "slack.post_message",
        "slack_post_message",
    ]
    static let builtinToolNames: Set<String> = [
        "bot_create", "bot_update", "bot_pause", "bot_run_once", "bot_list", "shelf_read", "shelf_entry", "bot_ask", "bot_delete",
        "recall_memory",
        // commit_memory (2026-06-11): Agent's memory WRITE path, restored
        // after the Python→Swift chat cutover dropped it. Built-in, low risk —
        // a persona-internal long-term memory write, NOT a Mac filesystem op
        // and NOT a shell/process spawn. Mirrors recall_memory's profiling.
        // (Note: "commit" trips no keyword catcher below, so without this
        // registration it would route through the unsigned path; the explicit
        // memory_write tag branch in profile() pins the capability shape.)
        "commit_memory",
        // The moments lane (2026-09-02). memory_moments_pending is a pure
        // read of her own proposal queue; memory_moment_review promotes or
        // drops one row in her own MemoryV2 store. Registered explicitly so
        // evaluateTool routes both through the built-in path and the pinned
        // branches below decide their shape — "review"/"pending" trip no
        // keyword catcher, so without this they would resolve to
        // {tool_call}/.low with rollbackRequired false.
        "memory_moments_pending", "memory_moment_review",
        // User, 2026-09-05: the agent's own-store curation. Same shape as the
        // moments lane: one plain local read, two writes to her own store.
        "list_memories", "rewrite_memory", "forget_memory", "rebuild_knowledge_graph",
        // Agent, 2026-09-06: read_chat_message reads one already-persisted
        // transcript row. Registered explicitly so evaluateTool routes it
        // through the built-in path — "read"/"message" would otherwise land it
        // on the keyword classifier rather than the plain-local-read shape
        // search_chat_history already has.
        "read_chat_message",
        // workshop_submit / workshop_status (2026-06-11, U5 W-I): Agent's execution
        // chat lane. workshop_submit is a medium-risk write (a thin shim into
        // the execution queue; the executor's own gates apply downstream),
        // workshop_status is a low-risk read. Neither spawns a Process. Register
        // explicitly so SecurityCenter.evaluateTool routes them through the
        // built-in path and the dedicated profile branches pin their shapes —
        // "submit" trips no keyword catcher, and "status" would otherwise only
        // get safe_read.
        "workshop_submit",
        "workshop_status",
        // task_ledger_post / task_ledger_list (2026-06-11, U6): the cross-agent
        // task ledger chat lane. task_ledger_post is a medium-risk WRITE (an
        // append to <dataRoot>/orchestration/task_ledger.jsonl — NOT a Mac
        // filesystem op and NOT a process spawn), task_ledger_list is a
        // low-risk read. "post"/"list" trip no keyword catcher, so register
        // explicitly and pin the shapes via the dedicated profile branches.
        "task_ledger_post",
        "task_ledger_list",
        // delegation_status (2026-08-11, W2): read-only projection over the
        // claude/codex wake-job records under ~/.config. No write, no process
        // spawn, no network — but "status" would otherwise only pick up the
        // generic safe_read keyword catcher via the unsigned path, so register
        // it explicitly and pin the shape in the dedicated branch below.
        "delegation_status",
        // agent-desk chat lane: desk_read is a low-risk read; the nine
        // mutations are medium ledger-class writes into <dataRoot>/desk/ — NOT
        // a Mac filesystem op and NOT a process spawn. Register explicitly so
        // evaluateTool routes them through the built-in path and the dedicated
        // profile branches pin their shapes (otherwise "status"/"note"/"close"
        // mis-classify via the keyword catchers below).
        "desk_read", "desk_add_item", "desk_set_status", "desk_update_item",
        "desk_note", "desk_add_ref", "desk_set_cadence", "desk_set_notify",
        "desk_close", "desk_archive",
        "desk_blocked_on", "desk_defer", "desk_breakdown",
        // desk_nag_control: writes User's nag preferences to
        // <dataRoot>/desk/nag_config.json. Same medium ledger-class write —
        // "control" trips no keyword catcher, so register it explicitly.
        "desk_nag_control",
        // desk_open_pursuit / desk_work_log: registered at the other four
        // sites since the pursuit lane shipped, missing HERE — so `desk_` fell
        // through to no keyword catcher, resolved to {tool_call}/.low, and
        // `rollbackRequired` was false for the only chat path that opens an
        // origin=agent pursuit. Found 2026-08-02; DeskToolRegistrationTests
        // now set-diffs all five sites so a 4-of-5 registration fails the
        // build instead of waiting for an audit.
        "desk_open_pursuit", "desk_work_log",
        // studio chat lane (desk 903): the agent's aesthetic journal and the
        // consults filed against it. studio_consult / studio_journal are medium
        // ledger-class WRITES under <dataRoot>/studio/ — a local file write, NOT
        // a Mac filesystem op, NOT a process spawn, and with no third-party side
        // effect of any kind. studio_consult_read / studio_recall are pure local
        // reads. Registered explicitly because "consult"/"journal" trip NO
        // keyword catcher below (they would resolve to {tool_call}/.low with
        // rollbackRequired false — the 4-of-5 failure the desk lane already
        // shipped once), and because "read"/"recall" would otherwise give the
        // two reads only the generic safe_read catcher via the unsigned path.
        // Checked against every sieve below: none of the four names contains
        // send/post/message/reply/tweet, so external_send does NOT misfire and
        // they must NOT be added to notificationToolNames (that set is a
        // carve-out FROM external_send; adding a tool that never trips it would
        // instead ADD the external_send capability at medium risk).
        "studio_consult", "studio_consult_read", "studio_journal", "studio_recall",
        "studio_shelf_read", "studio_shelf_set",
        // evolution chat tools (2026-06-11, U2b): the three privileged
        // self-evolution chat tools. evolution_propose is a critical-risk
        // evolution-store WRITE, self_install is a critical-risk install-card
        // TRIGGER (it stages a card a human still approves — it never installs),
        // evolution_status is a low-risk read. None spawns a Process. Register
        // explicitly so evaluateTool routes them through the built-in path and
        // the dedicated profile branches pin their shapes — "propose"/"status"
        // trip no keyword catcher, and "install" would otherwise mis-tag
        // self_install as a medium filesystem_write.
        "evolution_propose",
        "evolution_status",
        "evolution_withdraw",
        "self_install",
        "remote_node_list",
        "remote_node_execute",
        // Both names dispatch to the same built-in transcript reader. Keeping
        // the canonical name registered here prevents it from looking like an
        // unsigned dynamic tool while the compatibility alias looks built-in.
        "search_chat_history",
        "session_search",
        "search_kg",
        "recent_trace_summary",
        "tool_result_page",
        "scratchpad_read",
        "scratchpad_write",
        "list_skills",
        // Canonical app-data skill mutation. The skill body may guide future
        // behavior but cannot modify tools, policy, approvals, or authority.
        "save_skill",
        "list_dir",
        "read_file",
        "read_page",
        "write_file",
        // gpt-5.5 review-2 NEEDS_FIX: native file operations the policy
        // preview surfaces (file_move/file_trash → these names). Without
        // registration here SecurityCenter.evaluateTool routed them through
        // the unsigned-high-risk path even though they're built-in Mac
        // file actions. trash_file already classifies as critical destructive
        // via the keyword catcher below; move_file gets filesystem_write
        // (medium) once the `move` keyword is added.
        "move_file",
        "trash_file",
        "persona_read",
        "persona_write",
        "persona_append_section",
        "full_mac_read_file",
        "full_mac_list_dir",
        // ClaudeBridge return channel (2026-06-08): Agent→Claude
        // message tool. Pure file write to ~/.config/claude-bridge/,
        // no external side effect. Built-in, signed by inclusion here.
        "claude_message",
        // Codex bridge return channel (2026-06-08/15): Agent→Codex async
        // note. Local inbox write to ~/.config/codex-agent-bridge/ plus a
        // best-effort local Mac notification when the app bridge is wired.
        "codex_message",
        "omp_message",
        // AgentMail chat lane: list/read are external reads; send only stages a
        // bounded replay request for the shared approval executor.
        "agentmail_list",
        "agentmail_read",
        "agentmail_send",
        // Codex/OpenAI image generation: app-owned spend path that writes
        // generated files only under NativeAgent data/generated_images.
        "image_generate",
        "slack_status",
        "slack_list_channels",
        "slack_search_messages",
        "slack_post_message",
        // time_now (2026-06-08): zero-input, zero-side-effect clock
        // read. Caught missing when Agent called it mid-test and got
        // "not in the dispatch table." Safe to mark built-in.
        "time_now",
        // ClaudeBridge real-time invocation (2026-06-08): Agent spawns
        // `claude -p` as a subprocess to get Claude's help. Process spawn
        // is high-power (full subprocess inheritance), but only spawns
        // the user's own Claude Code binary on his own machine — same trust
        // surface as any other Mac shell command. Audit trail at
        // data/from_claude/<uuid>.json.
        "invoke_claude",
        // Codex bridge real-time invocation (2026-06-08): Agent spawns
        // `codex exec` as a bounded subprocess. Default sandbox is
        // workspace-write and every run audits to data/from_codex/<uuid>.json.
        "invoke_codex",
        // agent-builder-tools (2026-06-08): apply_patch/run_tests and the
        // fixed-argv SwiftPM builders are Process-based builder tools.
        // shell/bash/git get critical risk via the `shell` / `exec` keyword
        // catcher below (lower.contains("shell")) — the others don't trip any
        // keyword, so we register them explicitly here so
        // SecurityCenter.evaluateTool routes them through the built-in path.
        // Their high-risk classification is enforced by the autonomy gate
        // (default `confirm` in policy.json).
        "apply_patch",
        "run_tests",
        "swift_build",
        "swift_test",
        // gpt-5.5 review fix (2026-06-08): explicit registration of the
        // shell-class trio so SecurityCenter.evaluateTool routes them via
        // the built-in path (otherwise `git` alone doesn't trip the shell/
        // exec keyword catcher and lands in the unsigned-high-risk lane).
        "shell",
        "bash",
        "git",
        // App lifecycle tools: restart_app relaunches the installed bundle;
        // install_app schedules the canonical rebuild/sign/install script.
        // No keyword classifier below catches "restart", and "install" alone
        // would undersell the process-spawn/system-control shape.
        "restart_app", "install_app",
        // Visible Browser app tools. They are app-owned WKWebView actions
        // exposed through AppChatToolDispatcher; register them so the security
        // evaluator treats them as signed NativeAgent built-ins rather than
        // unknown tool names.
        "browser.status",
        "browser.open_url",
        "browser.navigate",
        "browser.read_text",
        "browser.read_links",
        "browser.screenshot",
        "browser.chrome_acquire",
        "browser.chrome_renew",
        "browser.chrome_navigate",
        "browser.chrome_snapshot",
        "browser.chrome_click",
        "browser.chrome_fill",
        "browser.chrome_type",
        "browser.chrome_select",
        "browser.chrome_keypress",
        "browser.chrome_set_checked",
        "browser.chrome_double_click",
        "browser.chrome_wait",
        "browser.chrome_scroll",
        "browser.chrome_release",
        // Read-only app health summaries. Their dispatchers redact secrets and
        // Telegram identifiers before results enter model context.
        "doctor_status",
        "telegram_status",
        // App-owned organism review action. It mutates only bounded organism
        // continuity through NativeCognitionRuntime and emits durable receipts;
        // it never dispatches the reviewed reflex as an action.
        "reflex_review",
    ]
    static let builtinToolPrefixes: [String] = [
        "browser.",
        "mac.",
        "memory.",
        "local_files.",
        "calendar.",
        "gmail.",
        "agentmail.",
        "email.",
        "x.",
        "slack.",
        "tool_",
        "list_",
        "search_",
        "read_",
        "get_",
        "persona_",
        "market.",
        "market_",
        // Mac integration chat tools are NativeAgent-builtins with underscore
        // names (e.g. mail_send, messages_send). The actual side-effect gate
        // remains MacIntegrationPermissionStore + autonomy/approval below; this
        // registration only prevents built-ins from looking like unknown
        // unsigned high-risk tools when their names contain send/delete/create.
        "contacts_",
        "mail_",
        "messages_",
        "notes_",
        "music_",
        "mac_calendar_",
        "mac_reminders_",
        "mac_spotlight_",
        "scheduler_",
    ]

    static let slackReadToolNames: Set<String> = [
        "slack.status",
        "slack.list_channels",
        "slack.search_messages",
        "slack.list_unreads",
        "slack_status",
        "slack_list_channels",
        "slack_search_messages",
    ]

    struct ToolProfile: Sendable {
        var capabilities: Set<String>
        var risk: SecurityRisk
    }

    /// Classify a tool through the same profile owner used by authorization.
    /// This is deliberately pure: it does not read policy, assess origins,
    /// record receipts, or imply that the tool is allowed to run.
    public static func canonicalToolRisk(
        tool: String,
        input: [String: JSONValue],
        dataRoot: URL,
        trustedWorkspaceRoots: [URL] = []
    ) -> CanonicalToolRisk {
        let risk = profile(
            tool: canonicalToolName(tool),
            input: input,
            dataRoot: dataRoot,
            trustedWorkspaceRoots: trustedWorkspaceRoots
        ).risk
        switch risk {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .critical: return .critical
        }
    }

    static func profile(
        tool: String,
        input: [String: JSONValue],
        dataRoot: URL,
        trustedWorkspaceRoots: [URL] = []
    ) -> ToolProfile {
        var capabilities: Set<String> = ["tool_call"]
        var risk = SecurityRisk.low
        func add(_ capability: String, _ newRisk: SecurityRisk) {
            capabilities.insert(capability)
            risk = max(risk, newRisk)
        }

        if tool == "mail_mark_read" {
            add("app_data_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if catalogToolNames.contains(tool) {
            add("catalog_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if notificationToolNames.contains(tool) {
            add("notification", .medium)
            add("external_send", .medium)
        }
        if ["bot_create", "bot_update", "bot_pause", "bot_run_once", "bot_list", "shelf_read", "shelf_entry", "bot_ask", "bot_delete"].contains(tool) {
            // Local app-data IO uses the notification-tier carve-out above.
            // Do not classify "create" as an arbitrary filesystem mutation.
            add(tool == "bot_list" ? "safe_read" : "app_data_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "agentmail_list" || tool == "agentmail_read" || tool == "agentmail.list_inbox" || tool == "agentmail.read" || tool == "agentmail.search" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "image_generate" {
            add("network_write", .medium)
            add("app_data_write", .medium)
            add("image_generation", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if slackReadToolNames.contains(tool) {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if approvalStagingToolNames.contains(tool) {
            add("approval_stage", .high)
            add("external_send", .high)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        let xReadOnlyConnectorTools: Set<String> = [
            "x.status",
            "x.me",
            "x.search_recent",
            "x.timeline_home",
            "x.user_tweets",
            "x.timeline_home_v1",
            "x.user_tweets_v1",
        ]
        if xReadOnlyConnectorTools.contains(tool) {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        let browserReadTools: Set<String> = [
            "browser.status",
            "browser.read_text",
            "browser.read_links",
            "browser.screenshot",
            "browser.chrome_snapshot",
            "browser.chrome_wait",
            "browser.chrome_scroll",
            // A renew moves the lease's own expiry and touches no page state,
            // so it sits with release rather than with the page verbs.
            "browser.chrome_renew",
            "browser.chrome_release",
        ]
        if browserReadTools.contains(tool) {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "doctor_status" || tool == "telegram_status" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // fable51 item 30 — THE CLIPBOARD ORGAN. Both EARLY-RETURN so neither
        // falls through to the keyword classifier below ("write" would tag the
        // write half `filesystem_write`, which is a lie: it touches no file).
        //
        // The read is a `safe_read`: it changes nothing, and the text it hands
        // back has already been through the shape redactor.
        //
        // The write gets its own `clipboard_write` capability at MEDIUM rather
        // than being folded into an existing tag. It is not a filesystem write
        // and not input injection; what it IS is a change to shared machine
        // state that every app can read, and it deserves a name that says so.
        if tool == "clipboard_read" || tool == "mac.clipboard_read" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "clipboard_write" || tool == "mac.clipboard_write" {
            add("clipboard_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // fable51 item 29 — THE MENU BAR ORGAN. Both EARLY-RETURN so neither
        // reaches the keyword classifier ("press" trips nothing today, but a
        // menu path like "File › Delete" must never be classified from its
        // ARGUMENTS, and the walk must never be mistaken for an act).
        //
        // The walk is a `safe_read`: one bounded descent, no CGEvent, no AX
        // action, and it does not even open a menu.
        //
        // The press carries the same `ax_injection` shape as the other
        // accessibility acts, at HIGH: it runs the app's own handler, and the
        // handler behind "File › Quit" or "Edit › Delete" is not medium.
        if tool == "menu" || tool == "mac.menu" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // fable51 item 33 — THE READ ORGAN. An EARLY RETURN so it never reaches
        // the keyword classifier, which would tag it from the word "read" alone
        // and land it in whatever bucket that heuristic happens to pick.
        //
        // `safe_read` at LOW, beside `browser.chrome_scroll` — which is the
        // exact precedent: a scroll whose only purpose is to bring more of a
        // document into view, graded on what it can do rather than on the fact
        // that it emits something. This organ presses nothing, types nothing
        // and activates nothing; it moves a viewport and scrolls it back. Its
        // text has already been through the shape redactor before it returns.
        //
        // The one authority it can reach beyond a read — opening a file the
        // caller NAMES — is gated separately at dispatch on Full Mac file
        // access, not here.
        if tool == "read" || tool == "mac.read" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "menu_press" || tool == "mac.menu_press" {
            add("ax_injection", .high)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "browser.open_url" || tool == "browser.navigate" {
            add("network_read", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "browser.chrome_acquire" || tool == "browser.chrome_navigate" {
            add("network_read", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "browser.chrome_click"
            || tool == "browser.chrome_fill"
            || tool == "browser.chrome_type"
            || tool == "browser.chrome_select"
            || tool == "browser.chrome_keypress"
            || tool == "browser.chrome_set_checked"
            || tool == "browser.chrome_double_click" {
            add("browser_interaction", .high)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "reflex_review" {
            // This writes bounded app-owned procedural posture only. A review
            // cannot dispatch the reflex, open a permission, or mutate files;
            // the runtime separately restricts approval to low-risk candidates.
            // Keep the tool callable on bridge surfaces with no approval filer.
            add("organism_state_write", .low)
            add("app_data_write", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }

        let lower = tool.lowercased()
        // gpt-5.5 review fix (2026-06-08): explicit branch for builder
        // Process-spawn tools. The keyword classifier below catches
        // `shell`/`exec` but misses `bash`, `git`, `run_tests`, the SwiftPM
        // builders, and undersells `apply_patch`. Register the precise
        // capabilities BEFORE the keyword classifier so the policy preview
        // surface gets the right risk shape.
        let builderProcessTools: Set<String> = [
            "shell", "bash", "git", "apply_patch", "run_tests",
            "swift_build", "swift_test",
        ]
        if builderProcessTools.contains(tool) {
            add("shell", .critical)
            add("process_spawn", .critical)
            // A shell is broad by design, but mutating macOS's permission
            // authority is not ordinary builder work. Classify the concrete
            // effect from the command body so SecurityCenter can hard-block it
            // without producing a contradictory approval prompt while Full
            // Mac/YOLO remains available for normal builds and repairs.
            if tool == "apply_patch" || tool == "git" || tool == "swift_build" || tool == "swift_test" {
                add("filesystem_write", .high)
            }
            if tool == "run_tests" || tool == "swift_test" {
                // Tests are allowed to mutate the workspace (build
                // artifacts, snapshot files, etc.).
                add("destructive", .high)
            }
        }
        // Keep the effect classifier outside the builder-name membership so
        // catalog aliases (`mac.shell` / `mac_shell`) receive the same floor.
        if commandMutatesSystemPermissionAuthority(tool: tool, input: input) {
            add("system_permission_reset", .critical)
            add("destructive", .critical)
        }
        let agentSubprocessTools: Set<String> = ["invoke_claude", "invoke_codex"]
        if agentSubprocessTools.contains(tool) {
            add("process_spawn", .high)
            add("agent_delegate", .high)
        }
        // commit_memory (2026-06-11): persona-internal long-term memory write.
        // Explicit low-risk memory_write tag — it writes only to Agent's own
        // MemoryV2 store, no Mac filesystem mutation and no process spawn, so
        // it must NOT inherit the medium filesystem_write tag the "write"
        // keyword would otherwise imply (the word "commit" dodges that catcher,
        // but pin the shape explicitly for the policy preview).
        if tool == "commit_memory" {
            add("memory_write", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // The moments lane. Same store, same shape as commit_memory: no Mac
        // filesystem mutation, no process spawn, no third-party effect. The
        // read half is a plain local read. Early-return so neither falls
        // through to the keyword classifier.
        if tool == "memory_moments_pending" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "memory_moment_review" {
            add("memory_write", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "list_memories" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // One already-persisted transcript row, read back verbatim. Same shape
        // as the search that hands out its id (Agent, 2026-09-06).
        if tool == "read_chat_message" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "rewrite_memory" || tool == "forget_memory" || tool == "rebuild_knowledge_graph" {
            add("memory_write", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "save_skill" {
            add("skill_write", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // workshop_submit (2026-06-11, U5 W-I): medium-risk execution queue write.
        // A thin shim into SwiftNativeWorkshopRunner.submit — no Mac filesystem
        // mutation, no process spawn. The executor's own missionPolicy gate,
        // slot cap, and per-step approval gates apply downstream; this profile
        // pins the tool-layer shape (the word "submit" trips no keyword
        // catcher). workshop_status is a pure read.
        if tool == "workshop_submit" {
            add("workshop_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "workshop_status" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // task_ledger_post (2026-06-11, U6): medium-risk cross-agent task ledger
        // WRITE. Appends one event to <dataRoot>/orchestration/task_ledger.jsonl
        // under the shared flock — no Mac filesystem mutation, no process spawn.
        // The dedicated `ledger_write` tag pins the tool-layer shape (the word
        // "post" trips no keyword catcher). task_ledger_list is a pure read.
        if tool == "task_ledger_post" {
            add("ledger_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "task_ledger_list" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // delegation_status (2026-08-11, W2): pure read of the on-disk wake-job
        // records. Explicitly NOT notification-tier — nothing leaves the
        // machine, so the external_send carve-out must not apply to it.
        if tool == "delegation_status" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // agent-desk (agent-desk): desk_read is a pure read; the nine desk
        // mutations are medium ledger-class WRITES (append one op to
        // <dataRoot>/desk/ under the shared flock — no Mac filesystem mutation,
        // no process spawn). Same `ledger_write` tag + medium risk as
        // task_ledger_post. Early-return so they don't fall through to the
        // keyword classifier ("status"/"close"/"archive" would otherwise
        // mis-tag).
        if tool == "desk_read" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // Exact set of the desk MUTATIONS (NOT a `desk_` prefix) so a future
        // desk_* read/admin tool can't silently inherit the write profile
        // before it's explicitly classified (gpt-5.5 breadth review). Mirror of
        // the names registered in SwiftToolDispatcher+DeskTools.swift.
        let deskWriteTools: Set<String> = [
            "desk_add_item", "desk_set_status", "desk_update_item", "desk_note",
            "desk_add_ref", "desk_set_cadence", "desk_set_notify", "desk_close", "desk_archive",
            "desk_blocked_on", "desk_defer", "desk_breakdown",
            "desk_nag_control",
            // Both are desk WRITES and belong here for the same reason as
            // their siblings: desk_open_pursuit appends an origin=agent
            // pursuit row, desk_work_log appends a work-log entry.
            "desk_open_pursuit", "desk_work_log",
        ]
        if deskWriteTools.contains(tool) {
            add("ledger_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // studio (desk 903): the same shape as the desk lane. The two writes
        // append/write one local record under <dataRoot>/studio/ and reach
        // nothing outside it; the two reads touch only those same files. Exact
        // sets rather than a `studio_` prefix, so a later studio tool cannot
        // inherit either profile before it has been classified on its own.
        if tool == "studio_consult_read" || tool == "studio_recall" || tool == "studio_shelf_read" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "studio_consult" || tool == "studio_journal" || tool == "studio_shelf_set" {
            add("ledger_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // evolution chat tools (2026-06-11, U2b). All three EARLY-RETURN: the
        // shapes are pinned here and must not fall through to the keyword
        // classifier below. evolution_propose / self_install are critical (a
        // self-evolution-store write and an install-card trigger). The early
        // return on self_install is REQUIRED — the `install` keyword at the
        // filesystem_write catcher below would otherwise mis-tag it medium.
        // evolution_status is a pure read. None spawns a Process.
        if tool == "evolution_propose" {
            add("evolution_write", .critical)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "self_install" {
            add("evolution_apply_trigger", .critical)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "evolution_status" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // evolution_withdraw (2026-09-02) EARLY-RETURNS too. It is an
        // evolution-store write, so it carries `evolution_write` — but it is
        // strictly DE-escalating (it can only park one of the agent's OWN
        // proposals in the terminal denied state; it can never apply, install,
        // or revert code), so it sits at high rather than critical. The early
        // return keeps "withdraw" clear of the keyword classifier below.
        if tool == "evolution_withdraw" {
            add("evolution_write", .high)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "remote_node_list" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "remote_node_execute" {
            add("process_spawn", .critical)
            add("remote_effect", .critical)
            add("filesystem_write", .high)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // restart_app (2026-06-10): spawns a detached relauncher process AND
        // terminates the running app — both axes are critical. No keyword
        // catcher below covers "restart"; classify explicitly so the policy
        // preview shows the real risk shape.
        if tool == "restart_app" || tool == "install_app" {
            add("process_spawn", .critical)
            add("system_control", .critical)
            if tool == "install_app" {
                add("filesystem_write", .critical)
                add("destructive", .critical)
            }
        }
        if lower.contains("shell") || lower.contains("terminal") || lower.contains("exec") {
            add("shell", .critical)
        }
        if lower.contains("delete") || lower.contains("trash") || lower.contains("remove")
            || lower.contains("wipe") || lower.contains("erase") || lower.contains(".rm")
            || lower.hasPrefix("rm_") || lower.contains("quarantine") {
            add("filesystem_delete", .critical)
            add("destructive", .critical)
        }
        if lower.contains("write") || lower.contains("save") || lower.contains("create")
            || lower.contains("patch") || lower.contains("edit") || lower.contains("append")
            || lower.contains("promote") || lower.contains("install")
            || lower.contains("enable") || lower.contains("disable") || lower.contains("configure")
            || lower.contains("set_") || lower.hasSuffix(".set")
            // gpt-5.5 review-2 NEEDS_FIX: move IS a write op — dst is
            // mutated and src is unlinked. Without this, `move_file` slid
            // through as low risk and the policy preview understated it.
            || lower.contains("move") || lower.hasPrefix("mv_") {
            add("filesystem_write", .medium)
        }
        if lower.contains("applescript") || lower.contains("jxa") || lower.contains("shortcut")
            || lower.contains("focus_app") || lower.contains("quit_app")
            || lower.contains("sleep") || lower.contains("lock_screen")
            || lower.contains("set_volume") {
            add("system_control", lower.contains("shortcut") ? .high : .critical)
        }
        // 2026-06-07 the user caught: messages_recent_threads was being
        // classified as high-risk external_send because the keyword
        // "message" matches it. That's a READ-ONLY tool (list threads).
        // The autonomy gate then blocked the call as a security risk.
        // Allowlist the Mac Integration read tools that contain a
        // sensitive keyword in their name; they go through the per-
        // integration permission store gate (mode: .read), not the
        // generic external_send classification.
        let macIntegrationReadOnly: Set<String> = [
            "messages_recent_threads",
            "mail_list_recent",
            "mail_search",
        ]
        if (lower.contains("send") || lower.contains("post") || lower.contains("tweet")
            || lower.contains("message") || lower.contains("reply"))
            && !macIntegrationReadOnly.contains(tool) {
            add("external_send", notificationToolNames.contains(tool) ? .medium : .high)
        }
        if lower.contains("trade") || lower.contains("broker") || lower.contains("order")
            || lower.contains("buy") || lower.contains("sell") || lower.contains("wallet") {
            add("money", .critical)
        }
        if lower.contains("secret") || lower.contains("credential") || lower.contains("token")
            || lower.contains("keychain") {
            add("secrets", .high)
        }
        if lower.contains("read") || lower.contains("list") || lower.contains("search")
            || lower.contains("recall") || lower.contains("status") || lower.contains("get") {
            capabilities.insert("safe_read")
        }

        if capabilityWritesOutsideAppData(
            input: input,
            dataRoot: dataRoot,
            trustedWorkspaceRoots: trustedWorkspaceRoots
        ),
           capabilities.contains("filesystem_write") || capabilities.contains("filesystem_delete") {
            add("outside_app_data_write", .high)
        }
        if !secretKeys(in: .object(input)).isEmpty {
            add("secret_input", .high)
        }
        return ToolProfile(capabilities: capabilities, risk: risk)
    }

    /// Pure effect classifier for commands that mutate the host permission
    /// authority. This is deliberately not an LLM instruction or word-choice
    /// constraint: the Trust boundary evaluates the exact tool arguments at
    /// effect time. It catches the supported `tccutil reset` path plus direct
    /// mutation attempts against TCC.db. False positives only request a human
    /// confirmation; false negatives would let an agent silently revoke its
    /// own capabilities.
    static func commandMutatesSystemPermissionAuthority(
        tool: String,
        input: [String: JSONValue]
    ) -> Bool {
        let normalizedTool = tool.lowercased()
        guard ["shell", "bash", "mac.shell", "mac_shell"].contains(normalizedTool) else {
            return false
        }
        let command = string(input["cmd"])
            ?? string(input["command"])
            ?? ""
        let lower = command.lowercased()
        if lower.contains("tccutil"),
           lower.range(of: #"\breset\b"#, options: .regularExpression) != nil {
            return true
        }
        guard lower.contains("tcc.db") else { return false }

        // Reading the TCC database is diagnostic evidence, not a permission
        // change. In particular, `sqlite3 ...TCC.db "SELECT ..."` must stay
        // autonomous under Full Mac. Require an actual mutating SQL or file
        // operation instead of treating the mere presence of `sqlite3` as a
        // write. Word boundaries avoid accidental matches inside paths/text.
        let mutationPattern = #"\b(delete|update|insert|replace|drop|alter|create|vacuum|reindex|rm|mv|cp|truncate|chmod|chown|dd)\b"#
        return lower.range(of: mutationPattern, options: .regularExpression) != nil
    }

    static func canonicalToolName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "mobile_notify", "iphone.notify", "iphone_notify", "ios.notify", "ios_notify", "apns.notify", "apns_notify", "push.notify", "push_notify":
            return "mobile.notify"
        case "mac_notify", "native.notify", "native_notify":
            return "mac.notify"
        case "x_status":
            return "x.status"
        case "x_me":
            return "x.me"
        case "x_search":
            return "x.search_recent"
        case "x_timeline":
            return "x.timeline_home"
        case "x_user_tweets":
            return "x.user_tweets"
        case "slack_status":
            return "slack.status"
        case "slack_list_channels":
            return "slack.list_channels"
        case "slack_search_messages":
            return "slack.search_messages"
        case "slack_post_message":
            return "slack.post_message"
        case "agentmail_send":
            return "agentmail.send"
        case "browser_status":
            return "browser.status"
        case "browser_open_url":
            return "browser.open_url"
        case "browser_navigate":
            return "browser.navigate"
        case "browser_read_text":
            return "browser.read_text"
        case "browser_read_links":
            return "browser.read_links"
        case "browser_screenshot":
            return "browser.screenshot"
        default:
            return trimmed
        }
    }
}
