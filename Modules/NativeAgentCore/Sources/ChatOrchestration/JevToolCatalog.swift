import Foundation

// MARK: - Jev tool-family catalog (lane 1)
//
// A 20-family grouping of the built-in tool catalog with one-line purposes,
// carried as DATA so no routing code branches on a family name. Only the
// purposes travel to the decision service; `names` stays local and is used
// to turn a suggested family back into concrete tool names for the existing
// preload path. Families whose NAME captures topic words carry a negative
// clause, because a bare name reads as a topic and pulls unrelated turns in.
struct JevToolFamily: Sendable {
    let id: String
    let purpose: String
    /// Appended to `purpose` when present; keeps a topic-shaped family name
    /// from capturing turns that merely mention the topic.
    let negative: String?
    let names: [String]

    /// What the decision service sees for this family.
    var described: String { negative.map { "\(purpose) — \($0)" } ?? purpose }
}

enum JevToolCatalog {
    static let families: [JevToolFamily] = [
        JevToolFamily(
            id: "files",
            purpose: "reading, writing, searching or listing files and folders on disk",
            negative: "not any mention of a document or a name that looks like a file; only reading or writing something on this disk",
            names: ["file_excerpt", "grep", "list_dir", "mac_spotlight_search", "read", "read_file", "write_file"]
        ),
        JevToolFamily(
            id: "shell_builder",
            purpose: "running shell commands, git, builds, tests, installing or restarting the app",
            negative: "not any mention of building, shipping or testing; only actually running a command, a build or a test",
            names: ["apply_patch", "bash", "git", "git_diff", "git_log", "git_status", "install_app", "remote_node_execute", "remote_node_list", "repo_dirty_summary", "restart_app", "run_tests", "self_install", "shell", "swift_build", "swift_test", "system_info"]
        ),
        JevToolFamily(
            id: "mac_control",
            purpose: "seeing and driving this Mac's screen, windows, menus, clicks, keystrokes and clipboard",
            negative: "not any mention of the screen or a window; only actually seeing or driving this Mac; "
                + "not the agent's own app pages or settings, which are settings_selfadmin "
                + "(app_page_read, app_setting_set, interaction_act)",
            names: ["act", "activity_query", "clipboard_read", "clipboard_write", "go", "hold_view", "mac_act", "mac_attention", "mac_ax_act", "mac_ax_find", "mac_ax_status", "mac_ax_tree", "mac_click", "mac_focus_app", "mac_keystroke", "mac_look", "mac_notify", "mac_nudge", "mac_quit_app", "mac_scroll", "mac_view", "mac_wake", "menu", "menu_press", "mobile_notify", "release_view", "screen", "wait"]
        ),
        JevToolFamily(
            id: "memory_recall",
            purpose: "recalling, recording, editing or forgetting long-term memories and the knowledge "
                + "graph, including when the person asks the agent to remember, save or note a fact "
                + "for later",
            negative: "not remembering something inside the current conversation; only the long-term memory store",
            names: ["commit_memory", "dream_diary_read", "forget_memory", "list_memories", "memory_moment_review", "memory_moments_pending", "rebuild_knowledge_graph", "recall_memory", "recall_search", "rewrite_memory", "search_kg"]
        ),
        JevToolFamily(
            id: "chat_history",
            purpose: "searching or reading past chat sessions, transcripts and saved replies",
            negative: "not the current conversation, which the agent already has; only past sessions",
            names: ["read_chat_message", "recent_trace_summary", "scratchpad_read", "search_chat_history", "session_search", "shelf_entry", "shelf_read"]
        ),
        JevToolFamily(
            id: "web_research",
            purpose: "fetching public web pages and researching things online",
            negative: "not general knowledge questions that can be answered already; only fetching a page",
            names: ["read_page"]
        ),
        JevToolFamily(
            id: "mail",
            purpose: "reading, searching, sending or filing email",
            negative: "not the word mail in another sense; only real email",
            names: ["agentmail_list", "agentmail_read", "agentmail_send", "gmail_read", "gmail_search", "gmail_status", "mail_archive", "mail_delete", "mail_list_recent", "mail_mark_read", "mail_reply", "mail_search", "mail_send"]
        ),
        JevToolFamily(
            id: "calendar_reminders",
            purpose: "calendar events and reminders/todos with dates",
            negative: nil,
            names: ["google_calendar_list", "google_calendar_status", "mac_calendar_create_event", "mac_calendar_delete_event", "mac_calendar_list_upcoming", "mac_calendar_modify_event", "mac_reminders_complete", "mac_reminders_create", "mac_reminders_list_due_today"]
        ),
        JevToolFamily(
            id: "slack",
            purpose: "Slack channels and messages",
            negative: nil,
            names: ["slack_list_channels", "slack_post_message", "slack_search_messages", "slack_status"]
        ),
        JevToolFamily(
            id: "messaging",
            purpose: "iMessage threads and phone/mobile notifications",
            negative: nil,
            names: ["messages_recent_threads", "messages_send"]
        ),
        JevToolFamily(
            id: "github",
            purpose: "GitHub repos, issues, pull requests and notifications",
            negative: nil,
            names: ["github_discover_tracking", "github_get_issue", "github_get_pull_request", "github_get_repository", "github_list_commits", "github_list_issues", "github_list_notifications", "github_list_pull_requests", "github_list_repos", "github_mutate", "github_project_digest", "github_pull_request_activity", "github_pull_request_files", "github_read_repository_content", "github_search", "github_set_repo_visibility", "github_status"]
        ),
        JevToolFamily(
            id: "persona_self",
            purpose: "the agent's own persona documents, skills, self-knowledge and introspection",
            negative: "not general talk about the agent, its mood, its opinions or who it is; only reading or writing the agent's own persona documents, skills and introspection records",
            names: ["agent_introspect", "context_lookup", "daemon_introspect", "get_persona_doc", "list_skills", "persona_append_section", "persona_read", "persona_write", "read_skill", "save_skill"]
        ),
        JevToolFamily(
            id: "desk_bots_studio",
            purpose: "the Desk (tracked items, pursuits, work log), standing bots, and the Studio journal/canon/taste",
            negative: "not any mention of work, tasks or notes; only the Desk, standing bots and the Studio journal",
            names: ["bot_ask", "bot_create", "bot_delete", "bot_list", "bot_pause", "bot_run_once", "bot_update", "desk_add_item", "desk_add_ref", "desk_archive", "desk_blocked_on", "desk_breakdown", "desk_close", "desk_defer", "desk_nag_control", "desk_note", "desk_open_pursuit", "desk_read", "desk_set_cadence", "desk_set_notify", "desk_set_status", "desk_update_item", "desk_work_log", "studio_canon", "studio_canon_resolve", "studio_consult", "studio_consult_read", "studio_journal", "studio_journal_amend", "studio_recall", "studio_shelf_read", "studio_shelf_set", "workshop_status", "workshop_submit"]
        ),
        JevToolFamily(
            id: "agent_messaging",
            purpose: "talking to other agents: the peer agent, the coding agent, the builder agent, swarms and the cross-agent task ledger",
            negative: "not talking about another agent; only sending to or reading from one",
            names: ["agent_connect", "agent_contacts", "agent_message", "agent_read", "agent_swarm", "codex_message", "claude_message", "delegation_status", "invoke_codex", "invoke_claude", "omp_message", "task_ledger_list", "task_ledger_post"]
        ),
        JevToolFamily(
            id: "settings_selfadmin",
            purpose: "tool loading, scheduling jobs, self-evolution proposals, reading or changing the "
                + "app's own pages and settings, and asking the person to connect or approve something",
            negative: "not any mention of settings or tools; only changing tool loading, scheduling jobs and self-evolution proposals",
            names: ["evolution_propose", "evolution_status", "evolution_withdraw", "inner_state", "list_tools", "request_interaction", "scheduler_create_job", "scheduler_list_jobs", "second_opinion", "time_now", "tool_catalog", "tool_load", "tool_result_page", "tool_unload"]
        ),
        JevToolFamily(
            id: "image",
            purpose: "generating or editing images",
            negative: "not looking at an existing image, which is seeing; only making a new one",
            names: ["image_generate"]
        ),
        JevToolFamily(
            id: "mac_apps",
            purpose: "Apple Notes, Music, Contacts and other local Mac apps' content",
            negative: nil,
            names: ["contacts_create_or_update", "contacts_delete", "contacts_search", "music_control", "music_list_library", "music_list_playlists", "music_now_playing", "music_search_library", "notes_create", "notes_search", "notes_update"]
        ),
        JevToolFamily(
            id: "market_finance",
            purpose: "market quotes, watchlists and finance data",
            negative: "not money or cost in general; only market and finance data",
            names: ["market_quote", "market_status", "market_watchlists", "tradingview_watchlist"]
        ),
        JevToolFamily(
            id: "notion",
            purpose: "Notion pages and databases",
            negative: nil,
            names: ["notion_read_page", "notion_search", "notion_status"]
        ),
        JevToolFamily(
            id: "social_x",
            purpose: "X/Twitter timeline, posts and search",
            negative: "not the letter x or crossing something out; only the X/Twitter service",
            names: ["x_me", "x_search", "x_status", "x_timeline", "x_user_tweets"]
        ),
    ]

    /// Family id -> its one-line description. This is the `choice` criteria
    /// object and the `tools` block of the state sent for a pre-turn brief.
    static var purposesByID: [String: String] {
        Dictionary(uniqueKeysWithValues: families.map { ($0.id, $0.described) })
    }

    /// The family a concrete tool name belongs to, if any.
    static func family(forTool name: String) -> String? {
        families.first { $0.names.contains(name) }?.id
    }
}
