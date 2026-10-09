import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import SlackConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import ToolRegistry

extension SwiftToolDispatcher {
    /// Read-only skill-manifest/body tools. This is the canonical taxonomy
    /// exported by the Tools page manifest; transcript summaries must not carry a
    /// second hand-maintained spelling of these names.
    public static let skillReaderToolNames: Set<String> = ["list_skills", "read_skill"]

    public static let alwaysOnCoreNames: Set<String> = [
        // User 2026-10-01: "NativeAgent is her tool." One door to the whole
        // app; its pages and actions travel in its results, not its schema.
        // The app's executor contributes it (AppToolExecutor+AppDoor).
        // User 10-02, one-door phase 2: every other tool folded into it, step
        // by step (ToolNameAliases.foldedTools). Step 7: workspace is app's
        // home and tool_catalog/tool_load are gone, so app is the only name.
        "app",
    ]

    /// Always-on tool names wired in SwiftToolDispatcher+Impls.swift.
    static let builtInToolNames: [String] = [
        "agent_contacts", "agent_connect", "agent_message", "agent_read", "agent_cancel",
        "bot_create", "bot_update", "bot_pause", "bot_run_once", "bot_list", "shelf_read", "shelf_entry", "bot_ask", "bot_delete",
        "read_page", "maps_route", "maps_search", "read_file", "list_dir", "write_file", "move_file", "copy_file", "trash_file", "recall_memory", "recall_search", "commit_memory", "search_kg",
        "search_chat_history", "session_search", "workspace", "work_context", "artifact_find",
        "get_persona_doc", "persona_read", "persona_write", "persona_append_section",
        "agent_introspect", "daemon_introspect",
        "tool_result_page", "request_interaction", "list_skills", "read_skill", "save_skill",
        "context_lookup", "context_expand", "scratchpad_read", "recent_trace_summary",
        // 2026-06-08: time_now + Claude-bridge return-channel tools were
        // added to dispatch/catalog but missing from builtInToolNames, so
        // listAvailableTools() didn't include them → tool_catalog's nameSet
        // intersection dropped them from currently_loaded. Add here.
        "time_now", "claude_message",
        // Personality depth item 3 (2026-09-02): the introspection pull. Also in
        // alwaysOnCoreNames — listed here so listAvailableTools() reports it as
        // currently_loaded rather than dropping it from tool_catalog.
        "inner_state",
        "codex_message", "invoke_codex", "omp_message",
        "agent_swarm",
        "market_status", "market_watchlists", "tradingview_watchlist", "market_quote",
        // X (Twitter) read tools — the user's connected account. Posting/DM is
        // intentionally gated through the Activity-approval UI, not chat.
        "x_status", "x_me", "x_search", "x_timeline", "x_user_tweets",
        // OAuth/token-backed cloud connectors. Read tools stay lazy and use
        // the dispatcher's exact data root; connection setup is Mac-owned.
        "gmail_status", "gmail_search", "gmail_read",
        "google_calendar_status", "google_calendar_list", "google_calendar_calendars", "google_calendar_free_busy", "google_calendar_read", "google_calendar_send_invitations",
        "notion_status", "notion_search", "notion_read_page",
        // GitHub — PAT-backed tools. Repo visibility writes are confirm-gated.
        "github_status", "github_list_repos", "github_list_notifications", "github_get_repository",
        "github_list_runs", "github_run_jobs",
        "github_read_repository_content", "github_list_commits", "github_list_issues",
        "github_search", "github_list_pull_requests", "github_get_issue",
        "github_get_pull_request", "github_pull_request_files", "github_pull_request_activity",
        "github_discover_tracking", "github_project_digest", "github_mutate",
        "github_set_repo_visibility",
        // Slack — reads execute immediately; posting stages a replayable approval.
        "slack_status", "slack_list_channels", "slack_search_messages", "slack_post_message",
        // AgentMail — Agent's hosted inbox. Schemas stay lazy-loaded under
        // category "agentmail"; agentmail_send stages an exact send approval.
        "agentmail_list", "agentmail_read", "agentmail_send",
        // Codex-backed image generation. Catalog-visible + lazy-loaded; guarded
        // by multimodalPolicy.image_generation_openai before any Codex/API spend.
        "image_generate",
        // 2026-06-07 — Mac integration chat tools, gated by MacIntegrationPermissionStore.
        // Read-default surfaces (calendar/reminders/spotlight) plus the two notification
        // channels the user trusts (mac.notify + mobile.notify). Phase 1 — read-only macs;
        // Contacts/Mail/Messages/Notes/Music adapters come in Phase 2.
        "mac_calendar_list_upcoming", "mac_calendar_calendars", "mac_calendar_free_busy", "mac_reminders_list_due_today", "mac_reminders_query", "mac_reminders_read", "mac_reminders_update",
        "mac_notify", "mobile_notify", "phone_request", "mac_spotlight_search",
        // 2026-06-07 Phase 2 — Contacts + AppleScript backends. Gated through
        // MacIntegrationPermissionStore. Write-default-OFF for the sensitive 5
        // (mail/messages/notes send + contacts create) — the user wants explicit toggle
        // in Settings → Mac Integration before she can send anything.
        "contacts_search", "contacts_create_or_update",
        "mail_list_recent", "mail_read_batch", "mail_triage_batch", "mail_search", "mail_senders", "mail_send", "mail_save_attachment",
        "messages_recent_threads", "messages_send",
        "notes_search", "notes_create",
        "music_now_playing", "music_control",
        // 2026-06-07 Phase 3 — complete read+write coverage on every Mac
        // Integration toggle. the user said "complete complete" — every tab toggle
        // now has tools behind it. Sensitive writes stay default-OFF per the
        // existing matrix.
        "mac_calendar_create_event", "mac_calendar_modify_event", "mac_calendar_delete_event", "mac_reminders_create", "mac_reminders_complete", "mac_reminders_delete",
        "mac_reminders_list_rename", "mac_reminders_list_create",
        "mail_mark_read", "mail_archive", "mail_delete", "mail_reply", "mail_draft",
        "notes_update", "notes_delete",
        "music_search_library", "music_list_library", "music_list_playlists",
        "contacts_delete",
        "scheduler_list_jobs", "scheduler_create_job",
        "scheduler_cancel_job", "scheduler_delete_job", "scheduler_pause_job",
        "scheduler_resume_job", "scheduler_update_job",
        // U5 W-I — Workshop execution chat lane. Catalog-visible + lazy-loaded (NOT in
        // alwaysOnCoreNames): submit/check Workshop executions from chat. workshop_submit
        // is a thin shim into SwiftNativeWorkshopRunner.submit (downstream gates
        // apply); workshop_status is a read.
        "workshop_submit", "workshop_status",
        // U6 (2026-06-11) — cross-agent task ledger chat lane. Catalog-visible +
        // lazy-loaded (NOT in alwaysOnCoreNames): task_ledger_post is a medium
        // write into <dataRoot>/orchestration/task_ledger.jsonl (bridge-allowed
        // as of 2026-06-13; the actor pin to `agent` is the integrity boundary);
        // task_ledger_list is a read. Claude/Codex write the same feed via
        // script/task_ledger.sh -> Swift task-ledger.
        "task_ledger_post", "task_ledger_list",
        // W2 (2026-08-11) — delegation_status: the READ counterpart to
        // claude_message / codex_message. Catalog-visible and now always-on.
        // Pure local read over the two wake-job stores
        // under ~/.config (roots injectable via agentBridgeConfigRoot).
        "delegation_status",
        // Agent Desk chat lane (agent-desk). Catalog-visible. desk_read is
        // ALWAYS-ON (also in alwaysOnCoreNames — User's "ask her to update me"
        // pull flow). The nine mutations are lazy-loaded (preload on tracking
        // intent) and are medium ledger-class writes into <dataRoot>/desk/ (actor
        // is inherently Agent — DeskOp has no actor field). NOT Full-Mac-gated.
        "desk_read", "desk_add_item", "desk_set_status", "desk_update_item",
        "desk_note", "desk_add_ref", "desk_set_cadence", "desk_set_notify",
        "desk_close", "desk_archive",
        // Sequencing lane: blocked-on EDGES (not prose) + defer + one-call
        // campaign breakdown. Same lazy, ledger_write class as the other
        // mutations.
        "desk_blocked_on", "desk_defer", "desk_breakdown",
        // Nag lane (Wave 3): User's own switch for how hard the desk stays on
        // him. Writes <dataRoot>/desk/nag_config.json, not the op-log — same
        // lazy, medium ledger_write class. It does NOT ping (it configures
        // what may ping), so it is not a notification tool.
        "desk_nag_control",
        // Workshop pursuit lane (Wave A). desk_open_pursuit is the ONLY chat path
        // to an origin=agent pursuit (store-gated on dossier + open-pursuit cap);
        // desk_work_log appends a work receipt to a pursuit. Both lazy-loaded
        // (NOT in alwaysOnCoreNames). No tool exposes reserveWorkSession — the
        // pump's reservation seam is internal API (H5 groundwork).
        "desk_open_pursuit", "desk_work_log",
        // Studio chat lane (desk 903, phases 1–2). Catalog-visible and
        // LAZY-LOADED (NOT in alwaysOnCoreNames, and deliberately in no preload
        // group either): consulting the agent's taste and journaling an
        // encounter are things she or a caller ASKS for, never something the
        // runtime arranges in the background. studio_consult / studio_journal
        // are ledger-class writes into <dataRoot>/studio/; studio_consult_read
        // and studio_recall are pure local reads.
        "studio_consult", "studio_consult_read", "studio_journal", "studio_recall",
        // studio_journal_amend (0.4.14) appends ONE correction record beside the
        // journal. Same ledger-class local write and the same lazy wiring as
        // studio_journal — the journal itself is still never edited.
        "studio_journal_amend",
        "studio_shelf_read", "studio_shelf_set",
        // dream_diary_read (0.4.14): the diary she writes, readable by her.
        // Catalog-visible and LAZY (NOT in alwaysOnCoreNames, no preload group)
        // for the same reason as the studio reads — reading back a night is a
        // deliberate pull. Pure local read under <dataRoot>/dream_diary/.
        "dream_diary_read",
        // Canon (desk 903 phase 4). studio_canon is a pure local read;
        // studio_canon_resolve is HER SEAT — the only path from a canon
        // proposal to a canon row, and deliberately not reachable from any
        // owner surface. Same lazy wiring as the four above.
        "studio_canon", "studio_canon_resolve",
        // The held standing-view tier (item 7, 2026-09-02). Catalog-visible and
        // LAZY, like the studio lane and unlike `inner_state`: adopting a view
        // is deliberate and rare — a handful of times, not per turn — so it has
        // no business costing prompt bytes on every turn. Both are seated on her
        // own live local turn and refuse every bridge, executor and replay.
        "hold_view", "release_view",
        // The moments lane (2026-09-02). Catalog-visible and LAZY — NOT in
        // alwaysOnCoreNames: reviewing what she lived is a deliberate pull a
        // few times a day, not per-turn business, and the per-turn nudge line
        // in the volatile block already tells her when there is anything to
        // pull. memory_moments_pending is a pure read; memory_moment_review is
        // her memory WRITE (accept promotes a proposal into her own store).
        "memory_moments_pending", "memory_moment_review",
        // User, 2026-09-05: curation of her own store, a deliberate pass.
        "forget_memory", "rebuild_knowledge_graph",
        // Agent, 2026-09-06: the whole of one message search only previewed.
        // LAZY — reaching past a preview is a deliberate follow-up to a search,
        // not per-turn business; work_context and history return exact locators.
        "read_chat_message",
    ]

    /// The READ half of the Full-Mac file surface. Every entry only observes:
    /// `file_excerpt` reads a byte range, `grep` shells a search, and the four
    /// git tools run `status --short --branch` / `diff` / `log` / (status+log)
    /// and parse stdout — no ref, object, worktree or index content is written.
    /// The one shared mutable artifact is git's opportunistic index-stat
    /// refresh, and git takes that lock OPTIONALLY (`repo_hold_locked_index`
    /// with flags 0 in `cmd_status`/`cmd_diff`): on contention it skips the
    /// refresh instead of failing, so two of these may run at once.
    /// Split out from the write half so parallel dispatch can admit reads
    /// without admitting `write_file` (see ParallelToolDispatch rule 2).
    package static let fullMacReadOnlyFileToolNames: [String] = [
        "file_excerpt", "grep",
        "git_status", "git_diff", "git_log", "repo_dirty_summary",
    ]

    /// The WRITE half of the Full-Mac file surface — mutates the filesystem.
    static let fullMacWriteFileToolNames: [String] = [
        "write_file", "move_file", "copy_file", "trash_file", "mac_screenshot_save", "mail_save_attachment",
    ]

    /// Swift-implemented builder/file tools exposed only when Trust Center's
    /// Full Mac mode is active and the matching MacControl category is enabled.
    /// Composed from the two halves so gating, catalog membership and dispatch
    /// routing keep covering exactly the same set they always did.
    package static let fullMacFileToolNames: [String] =
        fullMacReadOnlyFileToolNames + fullMacWriteFileToolNames

    package static let fullMacSystemToolNames: [String] = [
        "system_info", "mac_volume", "mac_media", "remote_node_list",
    ]


    /// Read-only Mac perception under the Accessibility category. `mac_view`
    /// also reports the separate Screen Recording grant for its image.
    static let fullMacAccessibilityReadToolNames: [String] = [
        "mac_view", "mac_attention",
        // native-look item 2 — `mac_look`. Same category, same read tier, same
        // route, same no-approval contract as the reads beside it, and it needs
        // no system grant beyond the Accessibility one they all need.
        "mac_look",
        // four-verbs (User, 2026-08-22: "a live screen she looks at and hands
        // she can use, native to an LLM"): `screen` and `wait` are pure
        // perception — they hold nothing, they expire nothing.
        "screen", "wait",
    ]

    /// The clipboard organ has its own read and write gates.
    ///
    ///   • It is not an accessibility READ — it walks no AX tree and needs no
    ///     Accessibility TCC grant to answer.
    ///   • It is not INJECTION — it posts no CGEvent and performs no AX action,
    ///     so it must not carry the injection list's approval capability.
    ///
    /// Clipboard is separately reachable through the four-verb surface.
    ///
    /// GATE, split by half: the read rides `accessibilityReadAllowed`, the
    /// write rides `appControlAllowed`. Both still require an ACTIVE Full Mac
    /// window and the accessibility category, enforced again inside MacControl.
    static let macClipboardReadToolNames: [String] = ["clipboard_read"]
    static let macClipboardWriteToolNames: [String] = ["clipboard_write"]
    static let macClipboardToolNames: [String] =
        macClipboardReadToolNames + macClipboardWriteToolNames

    /// fable51 item 29 — THE MENU BAR ORGAN, split the same way and for the
    /// same reasons as the clipboard above: `menu` is a bounded read-only walk
    /// of `AXMenuBar` (no CGEvent, no AX action, it does not even open a menu),
    /// while `menu_press` runs the app's own handler and clears the full
    /// injection contract inside MacControl.
    ///
    /// Their own lists so neither lands in `legacyMacModelToolNames` — the menu
    /// organ is a NEW surface for the four verbs to reach for, not a legacy
    /// mac_* organ being retired behind the cutover.
    static let macMenuReadToolNames: [String] = ["menu"]
    static let macMenuPressToolNames: [String] = ["menu_press"]
    static let macMenuToolNames: [String] = macMenuReadToolNames + macMenuPressToolNames

    /// fable51 item 33 — THE READ ORGAN. Its own list for the same reason the
    /// two organs above have theirs: it is neither neighbour.
    ///
    ///   • It is not one of the accessibility READS. That list's contract is
    ///     the bounded glance under `look`'s budgets, and this one deliberately
    ///     is not bounded that way — it returns a whole document and lets the
    ///     turn's existing spill pager carry it.
    ///   • It is not INJECTION. It moves a viewport and puts it back; it
    ///     presses, types and activates nothing, so it must not carry the
    ///     injection list's approval capability.
    ///
    /// The separate list also keeps it OUT of `legacyMacModelToolNames`: `read`
    /// is a NEW organ for the four-verb surface to reach for, not a legacy
    /// `mac_*` organ being retired.
    ///
    /// GATE: `accessibilityReadAllowed`, plus the file gate (`fileOpsAllowed`
    /// and workspace file policy) for ANY filesystem route — a `path` the caller
    /// names or one inferred from `AXDocument` (see `impl_mac_read_tool`).
    static let macReadToolNames: [String] = ["read"]

    /// W7 (2026-08-14) — the ambient activity watcher's query tool.
    ///
    /// Its own list: this reads a local SQLite rollup, not the live screen.
    /// Capture must be enabled; agent access comes from its separate preference
    /// or checked Full Mac admission, never the accessibility category.
    ///
    /// Its gate is `ActivityPolicy.captureEnabled` — the Trust Center toggle,
    /// OFF by default. `listAvailableTools()` surfaces it only when that toggle
    /// is on (so the catalog does not advertise a tool that will refuse), and
    /// `impl_activity_query_tool` re-reads the policy and refuses anyway, so a
    /// stale catalog cannot become an answer.
    static let activityQueryToolNames: [String] = ["activity_query"]

    /// INJECTION tools (W2/W3). Same `accessibility` gate category again, but
    /// the far end of it: these synthesize keyboard/mouse input and drive other
    /// apps' UI. Their own list because they route to
    /// `impl_mac_injection_tool`, require a body-bound injection capability,
    /// and are blocked under `fileAccess=read_only`. Standard modes obtain the
    /// capability through approved replay; admitted Full Mac YOLO obtains it
    /// directly for the checked call without a per-call prompt.
    /// `mac_wake` (W6) is in this list rather than the read list even though
    /// most of what it RETURNS is a `mac_view` result: it posts a HID mouse
    /// move first, and the tier is decided by what a tool does, not by what it
    /// hands back. Read tier for it would have been a bypass with a view-shaped
    /// result stapled to it.
    static let fullMacAccessibilityInjectionToolNames: [String] = [
        "mac_wake",
        // Four verbs: `act` drives the closed loop (raise,
        // gates, actuator, observer) addressed by NAME instead of handle;
        // `go` activates/launches/opens — hands, so injection tier.
        "act", "go",
    ]

    /// The four-verb surface routes to its OWN impl (see the dispatch switch:
    /// its case precedes the read/injection list cases, so membership above
    /// buys loading/visibility while routing lands here).
    static let fourVerbToolNames: [String] = ["screen", "act", "go", "wait"]

    /// The implementation organs retained for direct diagnostics and the Tools
    /// UI, but removed from the conversational model surface. This one set is
    /// the cutover boundary; prompt filters, same-turn loading, and stale-call
    /// rejection all consult it instead of maintaining parallel exclusion
    /// lists.
    package static var legacyMacModelToolNames: Set<String> {
        Set(fullMacAccessibilityReadToolNames
            + fullMacAccessibilityInjectionToolNames)
            .subtracting(fourVerbToolNames)
    }

    /// Names her catalog never shows: the legacy Mac organs, the tools
    /// folded into `app` or retired from it, and `workspace` (app's home).
    /// All stay callable by name for internal callers; the deleted discovery
    /// names never return from an old session's pinned row.
    package static var modelHiddenToolNames: Set<String> {
        legacyMacModelToolNames.union(ToolNameAliases.foldedTools.keys).union(ToolNameAliases.mergedTools)
            .union(ToolNameAliases.retiredAppTools)
    }

    /// `modelHiddenToolNames`, and every MCP server's tools: each is an `app`
    /// action (`mcp.<server>.<tool>`) generated from its live list.
    package static func isModelHidden(_ name: String) -> Bool {
        modelHiddenToolNames.contains(name) || ToolNameAliases.mcpAction(name) != nil
    }

    /// Keep the retained UI and studio tools out of the conversational catalog.
    public static func modelVisibleCatalogToolNames(
        _ availableToolNames: Set<String>
    ) -> Set<String> {
        availableToolNames.filter { !isModelHidden($0) }
    }

    /// A tool a session loaded before it folded into `app` is never offered
    /// by its old name again.
    package static func normalModelToolNames(activeTools: Set<String>) -> Set<String> {
        alwaysOnCoreNames.union(activeTools.filter { !isModelHidden($0) })
    }

    /// The advertised tool contract for one turn, split into the part that can
    /// never move and the part that only ever grows.
    ///
    /// FLOOR is `alwaysOnCoreNames ∩ available`, sorted by name — the same
    /// bytes on turn 1 and turn 40 of a session. APPENDED is everything else
    /// in LOAD ORDER, never re-sorted, so a `tool_load` adds rows at the END
    /// instead of shifting every later row the way an alphabetical sort did.
    /// That is what makes the contract append-only and the provider prefix
    /// cache survivable across a session.
    package struct ToolContractOrdering: Sendable, Equatable {
        package let floor: [String]
        package let appended: [String]

        init(floor: [String], appended: [String]) {
            self.floor = floor
            self.appended = appended
        }

        package var advertised: [String] { floor + appended }

        /// SHA-256 over the ordered advertised contract. Two consecutive turns
        /// with the same fingerprint carry the same catalog rows in the same
        /// order, so a cache miss between them cannot be blamed on the tool
        /// contract. Membership AND order both feed the digest — reordering
        /// alone breaks a prefix just as thoroughly as adding a row.
        package var fingerprintSHA256: String {
            let text = floor.joined(separator: "\n")
                + "\n\u{1F}\n"
                + appended.joined(separator: "\n")
            return SHA256.hash(data: Data(text.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    /// Canonical advertised order for `names`: the floor sorted by name, then
    /// everything else in incoming order.
    package static func canonicalToolOrder(_ names: some Sequence<String>) -> ToolContractOrdering {
        var seen = Set<String>()
        let ordered = names.filter { seen.insert($0).inserted }
        return ToolContractOrdering(
            floor: ordered.filter { alwaysOnCoreNames.contains($0) }.sorted(),
            appended: ordered.filter { !alwaysOnCoreNames.contains($0) }
        )
    }

    // Builder tools (agent-builder-tools, 2026-06-08). Gated on Full Mac
    // file_ops_allowed at dispatch time; surfaced in listAvailableTools()
    // under the same gate so catalog and dispatch agree. shell/bash/git/
    // apply_patch keep the workspace-write sandbox wrapper; the
    // fixed-argv swift_build/swift_test tools deliberately lift the OUTER
    // wrapper to avoid SwiftPM's nested sandbox failure.
    package static let fullMacBuilderToolNames: [String] = [
        "shell", "bash", "git", "apply_patch",
        "swift_build", "swift_test", "remote_node_execute",
    ]

    // App lifecycle tools. Not general builder tools (no arbitrary Process
    // args/cwd surface), but they share the builder tools' policy shape:
    // schema lives in the includeFullMacFileTools block, dispatch gates on
    // file_ops_allowed, and listAvailableTools() surfaces them under the same
    // gate. Kept in a separate list so the tool catalog doesn't mislabel them
    // "implemented_swift_builder_tools".
    package static let fullMacRestartToolNames: [String] = [
        "restart_app", "install_app",
    ]

    // evolution chat tools (2026-06-11, U2b). Not builder tools (no Process
    // spawn) but they share the builder tools' policy shape: schemas live in
    // the includeFullMacFileTools block, dispatch gates on file_ops_allowed,
    // and listAvailableTools() / tool_load surface them under the same gate so
    // catalog and dispatch agree. Their own list keeps the tool catalog from
    // mislabeling them "implemented_swift_builder_tools".
    static let fullMacEvolutionToolNames: [String] = [
        "evolution_propose", "evolution_status", "evolution_withdraw", "self_install",
    ]

    /// Names implemented by this dispatcher, including capability-gated
    /// surfaces. Dynamic registry and MCP tools are catalog rows too, but are
    /// intentionally not claimed here because this static dispatcher cannot
    /// vouch for their registration lifecycle.
    public static var catalogRegisteredToolNames: Set<String> {
        Set(
            builtInToolNames
            + fullMacFileToolNames
            + fullMacSystemToolNames
            + fullMacAccessibilityReadToolNames
            + activityQueryToolNames
            + fullMacAccessibilityInjectionToolNames
            + fullMacBuilderToolNames
            + fullMacRestartToolNames
            + fullMacEvolutionToolNames
        )
    }

    /// Returns nil deliberately for a name without an explicit reviewed
    /// category. Callers must present that condition visibly instead of
    /// treating an arbitrary runtime name as a reviewed category.
    public static func catalogBucket(forRegisteredToolNamed name: String) -> ChatToolCatalogBucket? {
        guard catalogRegisteredToolNames.contains(name) else { return nil }
        if Self.fullMacBuilderToolNames.contains(name)
            || Self.fullMacRestartToolNames.contains(name)
            || Self.fullMacEvolutionToolNames.contains(name) {
            return .shell
        }
        if Self.standardFileToolNames.contains(name) || Self.fullMacFileToolNames.contains(name) {
            return .fileOps
        }
        if Self.fullMacSystemToolNames.contains(name) {
            return .system
        }
        if Self.fullMacAccessibilityReadToolNames.contains(name)
            || Self.fullMacAccessibilityInjectionToolNames.contains(name) {
            return .macControl
        }
        if Self.macIntegrationToolNames.contains(name) {
            return .macIntegration
        }
        return Self.coreCatalogToolNames.contains(name) ? .core : nil
    }

    private static let standardFileToolNames: Set<String> = [
        "read_file", "list_dir", "write_file", "move_file", "copy_file", "trash_file", "mail_save_attachment",
    ]

    private static let macIntegrationToolNames: Set<String> = [
        "mac_calendar_list_upcoming", "mac_calendar_calendars", "mac_calendar_free_busy", "mac_reminders_list_due_today", "mac_reminders_query", "mac_reminders_read", "mac_reminders_update",
        "mac_notify", "mobile_notify", "phone_request", "mac_spotlight_search",
        "contacts_search", "contacts_create_or_update", "mail_list_recent",
        "mail_read_batch", "mail_triage_batch", "mail_search", "mail_senders", "mail_send", "messages_recent_threads", "messages_send",
        "notes_search", "notes_create", "music_now_playing", "music_control",
        "mac_calendar_create_event", "mac_calendar_modify_event", "mac_calendar_delete_event",
        "mac_reminders_create", "mac_reminders_complete", "mac_reminders_delete", "mail_mark_read",
        "mac_reminders_list_rename", "mac_reminders_list_create",
        "mail_archive", "mail_delete", "mail_reply", "mail_draft", "notes_update", "notes_delete",
        "music_search_library", "music_list_library", "music_list_playlists",
        "contacts_delete", "scheduler_list_jobs", "scheduler_create_job",
        "scheduler_cancel_job", "scheduler_delete_job", "scheduler_pause_job",
        "scheduler_resume_job", "scheduler_update_job",
    ]

    /// Core membership comes only from reviewed built-ins and the separately
    /// registered activity query, never from arbitrary runtime names.
    private static let coreCatalogToolNames = Set(builtInToolNames)
        .subtracting(standardFileToolNames)
        .subtracting(macIntegrationToolNames)
        .union(activityQueryToolNames)

}
