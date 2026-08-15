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

extension SwiftToolDispatcher {
    public static let alwaysOnCoreNames: Set<String> = [
        "tool_catalog", "tool_load", "tool_unload", "tool_result_page",
        "list_skills", "read_skill", "save_skill",
        "recall_memory", "search_kg", "search_chat_history",
        // commit_memory — the memory WRITE counterpart to recall_memory.
        // Daemon parity (always_on + AUTO). Must be hot/always-loaded so the
        // model can durably save a fact mid-turn WITHOUT a tool_load dance —
        // the symmetric partner of the always-on recall surface.
        "commit_memory",
        // scratchpad_write was listed here but has no schema or dispatch
        // case — only scratchpad_read exists. Listing it would advertise
        // a tool the LLM can't actually load or call. (gpt-5.5 review-2
        // NEEDS_FIX 5)
        "scratchpad_read",
        "context_expand",
        "time_now",
        "recent_trace_summary",
        // Self-introspection must be always-loaded: it was discovery_only,
        // gated behind a tool_load that needs the chat session id — a
        // chicken-and-egg where the agent can't load the very tool that reports
        // its runtime/model. An agent should always be able to ask "what am I
        // running on" without a load dance. (2026-06-09, found via live test.)
        "agent_introspect",
        "claude_message",
        "codex_message",
        "omp_message",
        // Agent Desk — desk_read is ALWAYS-ON so "update me on what you're
        // tracking" / "what's on the desk" works regardless of phrasing (User's
        // pull-to-retrieve flow, 2026-06-29). The nine desk MUTATIONS stay lazy
        // (preload on tracking intent — the capture flow).
        "desk_read",
    ]

    /// Always-on tool names wired in SwiftToolDispatcher+Impls.swift.
    static let builtInToolNames: [String] = [
        "read_file", "list_dir", "write_file", "recall_memory", "recall_search", "commit_memory", "search_kg",
        "search_chat_history", "session_search",
        "get_persona_doc", "persona_read", "persona_write", "persona_append_section",
        "agent_introspect", "daemon_introspect", "tool_catalog",
        "list_tools", "tool_load", "tool_unload", "tool_result_page", "list_skills", "read_skill", "save_skill",
        "context_lookup", "context_expand", "scratchpad_read", "recent_trace_summary",
        // 2026-06-08: time_now + Claude-bridge return-channel tools were
        // added to dispatch/catalog but missing from builtInToolNames, so
        // listAvailableTools() didn't include them → tool_catalog's nameSet
        // intersection dropped them from currently_loaded. Add here.
        "time_now", "claude_message", "invoke_claude",
        "codex_message", "invoke_codex", "omp_message",
        "agent_swarm",
        "market_status", "market_watchlists", "tradingview_watchlist", "market_quote",
        // X (Twitter) read tools — the user's connected account. Posting/DM is
        // intentionally gated through the Activity-approval UI, not chat.
        "x_status", "x_me", "x_search", "x_timeline", "x_user_tweets",
        // OAuth/token-backed cloud connectors. Read tools stay lazy and use
        // the dispatcher's exact data root; connection setup is Mac-owned.
        "gmail_status", "gmail_search", "gmail_read",
        "google_calendar_status", "google_calendar_list",
        "notion_status", "notion_search", "notion_read_page",
        // GitHub — PAT-backed tools. Repo visibility writes are confirm-gated.
        "github_status", "github_list_repos", "github_list_issues",
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
        "mac_calendar_list_upcoming", "mac_reminders_list_due_today",
        "mac_notify", "mobile_notify", "mac_spotlight_search",
        // 2026-06-07 Phase 2 — Contacts + AppleScript backends. Gated through
        // MacIntegrationPermissionStore. Write-default-OFF for the sensitive 5
        // (mail/messages/notes send + contacts create) — the user wants explicit toggle
        // in Settings → Mac Integration before she can send anything.
        "contacts_search", "contacts_create_or_update",
        "mail_list_recent", "mail_search", "mail_send",
        "messages_recent_threads", "messages_send",
        "notes_search", "notes_create",
        "music_now_playing", "music_control",
        // 2026-06-07 Phase 3 — complete read+write coverage on every Mac
        // Integration toggle. the user said "complete complete" — every tab toggle
        // now has tools behind it. Sensitive writes stay default-OFF per the
        // existing matrix.
        "mac_calendar_create_event", "mac_calendar_modify_event", "mac_reminders_create", "mac_reminders_complete",
        "mail_mark_read", "mail_archive", "mail_delete", "mail_reply",
        "notes_update",
        "music_search_library", "music_list_library", "music_list_playlists",
        "contacts_delete",
        "scheduler_list_jobs", "scheduler_create_job",
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
        // claude_message / codex_message. Catalog-visible + lazy-loaded (NOT
        // in alwaysOnCoreNames). Pure local read over the two wake-job stores
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
    ]

    /// Swift-implemented builder/file tools exposed only when Trust Center's
    /// Full Mac mode is active and the matching MacControl category is enabled.
    static let fullMacFileToolNames: [String] = [
        "file_excerpt", "write_file", "grep",
        "git_status", "git_diff", "git_log", "repo_dirty_summary",
    ]

    static let fullMacSystemToolNames: [String] = [
        "system_info", "remote_node_list",
    ]

    static let fullMacAppToolNames: [String] = [
        "mac_focus_app", "mac_quit_app",
    ]

    /// READ-ONLY accessibility perception tools (W1b). These share the
    /// `accessibility` gate CATEGORY with mac_focus_app/mac_quit_app but they
    /// are a different TIER: they read the on-screen AX tree and mutate
    /// nothing — no CGEvent, no AXUIElementPerformAction, no attribute write.
    /// Kept in their own list (not folded into fullMacAppToolNames) for two
    /// reasons: the tool catalog would otherwise label perception reads
    /// "app control", and the dispatch route must land on
    /// `impl_mac_accessibility_read_tool`, which gates on the READ signal
    /// (`FullMacToolAccess.accessibilityReadAllowed`) rather than
    /// `appControlAllowed`.
    /// `mac_view` (W3.5) is here rather than in a list of its own: it is the
    /// same gate category, the same read TIER, the same route and the same
    /// no-approval contract as the three AX reads — it just fuses the picture
    /// onto them. Its one extra requirement, the Screen Recording TCC grant, is
    /// a SYSTEM permission it reports in its result, not a policy tier, exactly
    /// as the AX reads report the Accessibility grant.
    static let fullMacAccessibilityReadToolNames: [String] = [
        "mac_ax_status", "mac_ax_tree", "mac_ax_find", "mac_view",
    ]

    /// W7 — `mac_nudge`, the one-mouse-move tool. Its own list because it is
    /// neither of the two neighbours: it POSTS a CGEvent (so it cannot join the
    /// read list, whose contract is "no CGEvent"), and it emits only a bare
    /// move — no button, no key — so it changes no app state and there is
    /// nothing for a human to approve (so it must not join the injection list,
    /// which is the approval-capability predicate).
    ///
    /// It is surfaced and gated EXACTLY like `mac_ax_status`: the same
    /// `FullMacToolAccess.accessibilityReadAllowed` signal, the same catalog
    /// visibility flag, `auto` autonomy, no approval filer, no
    /// `MacInjectionCapability`. Anything that would let it click or type
    /// belongs in `fullMacAccessibilityInjectionToolNames` instead.
    static let fullMacNudgeToolNames: [String] = ["mac_nudge"]

    /// W7 (2026-08-14) — the ambient activity watcher's query tool.
    ///
    /// Its own list, and deliberately NOT under any Full Mac flag: this reads a
    /// local SQLite rollup, not the live screen, so borrowing the accessibility
    /// category would tie it to a gate that has nothing to do with it and would
    /// let an active Full Mac window imply consent the user never gave.
    ///
    /// Its gate is `ActivityPolicy.captureEnabled` — the Trust Center toggle,
    /// OFF by default. `listAvailableTools()` surfaces it only when that toggle
    /// is on (so the catalog does not advertise a tool that will refuse), and
    /// `impl_activity_query_tool` re-reads the policy and refuses anyway, so a
    /// stale catalog cannot become an answer.
    static let activityQueryToolNames: [String] = ["activity_query"]

    /// INJECTION tools (W2/W3). Same `accessibility` gate category again, but
    /// the far end of it: these synthesize keyboard/mouse input and drive other
    /// apps' UI. Their own list because all three of the following differ from
    /// both lists above — they route to `impl_mac_injection_tool`, they carry an
    /// approval floor that survives an active Full Mac YOLO window, and they are
    /// blocked under `fileAccess=read_only`.
    /// `mac_wake` (W6) is in this list rather than the read list even though
    /// most of what it RETURNS is a `mac_view` result: it posts a HID mouse
    /// move first, and the tier is decided by what a tool does, not by what it
    /// hands back. Read tier for it would have been a bypass with a view-shaped
    /// result stapled to it.
    static let fullMacAccessibilityInjectionToolNames: [String] = [
        "mac_keystroke", "mac_click", "mac_scroll", "mac_ax_act", "mac_wake",
    ]

    // Builder tools (agent-builder-tools, 2026-06-08). Gated on Full Mac
    // file_ops_allowed at dispatch time; surfaced in listAvailableTools()
    // under the same gate so catalog and dispatch agree. shell/bash/git/
    // apply_patch/run_tests keep the workspace-write sandbox wrapper; the
    // fixed-argv swift_build/swift_test tools deliberately lift the OUTER
    // wrapper to avoid SwiftPM's nested sandbox failure.
    static let fullMacBuilderToolNames: [String] = [
        "shell", "bash", "git", "apply_patch", "run_tests",
        "swift_build", "swift_test", "remote_node_execute",
    ]

    // App lifecycle tools. Not general builder tools (no arbitrary Process
    // args/cwd surface), but they share the builder tools' policy shape:
    // schema lives in the includeFullMacFileTools block, dispatch gates on
    // file_ops_allowed, and listAvailableTools() surfaces them under the same
    // gate. Kept in a separate list so the tool catalog doesn't mislabel them
    // "implemented_swift_builder_tools".
    static let fullMacRestartToolNames: [String] = [
        "restart_app", "install_app",
    ]

    // evolution chat tools (2026-06-11, U2b). Not builder tools (no Process
    // spawn) but they share the builder tools' policy shape: schemas live in
    // the includeFullMacFileTools block, dispatch gates on file_ops_allowed,
    // and listAvailableTools() / tool_load surface them under the same gate so
    // catalog and dispatch agree. Their own list keeps the tool catalog from
    // mislabeling them "implemented_swift_builder_tools".
    static let fullMacEvolutionToolNames: [String] = [
        "evolution_propose", "evolution_status", "self_install",
    ]

}
