import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftNativeTrustCenter {
    /// Default trust policy for the Swift runtime. Saved policy values are
    /// merged over this shape by `loadTrustPolicy()`.
    public nonisolated func defaultTrustPolicy() -> [String: JSONValue] {
        var policy: [String: JSONValue] = [:]
        policy["permissionLevel"] = .string("balanced")
        policy["autonomyDefault"] = .string("supervised")
        policy["updatedAt"] = .string(Self.isoTimestamp(clock()))
        policy["appDataRoot"] = .string(dataRoot.path)
        policy["missionPolicy"] = .object([
            "allowBackgroundMissions": .bool(true),
            "requireReceipts": .bool(true),
            "autoCreateMissionFromChat": .bool(false),
            "enabled": .bool(true),
            "showTimeline": .bool(true),
        ])
        policy["toolAutonomy"] = .object(Self.defaultToolAutonomy)
        policy["toolPolicy"] = .object([
            "autoPromoteSafeTools": .bool(true),
            "autoRunSafeTools": .bool(true),
            "riskyToolApproval": .string("ask"),
        ])
        policy["filePolicy"] = .object([
            "allowedWorkspaceIds": .array([]),
            "workspaceRoots": .array(TrustCenterDefaultWorkspaceRoots.defaultRootPaths().map { .string($0) }),
            "requireBackupBeforeWrite": .bool(true),
            "allowDestructiveActions": .bool(false),
            "outsideWorkspaceDefault": .string("deny"),
        ])
        policy["connectorPolicy"] = .object([
            "defaultEnabled": .bool(false),
            "sendExternalMessagesRequiresApproval": .bool(true),
        ])
        policy["multimodalPolicy"] = .object([
            "screen_capture": .bool(false),
            "vision_api_calls": .bool(true),
            "file_ingestion_pdf": .bool(true),
            "file_ingestion_docx": .bool(true),
            "image_generation_openai": .bool(false),
            "tts_openai": .bool(false),
        ])
        policy["trainingPolicy"] = .object([
            "autonomous_training": .bool(true),
            "dream_scheduler": .bool(false),
            "route_through_promotion": .bool(true),
        ])
        policy["promotionPolicy"] = .object([
            "enabled": .bool(true),
            "auto_promote_tier_a": .bool(false),
            "run_smoke_in_harness": .bool(true),
        ])
        policy["personalityPolicy"] = .object([
            "runtime_v2": .bool(true),
            "session_memory_extraction": .bool(true),
            "confidence_calibration": .bool(false),
            "completion_guard_enabled": .bool(true),
            "completion_guard_max_repairs": .int(2),
        ])
        policy["memoryPolicy"] = .object([
            "consolidation_enabled": .bool(true),
            "cross_session_recall": .bool(true),
            "auto_promote_consolidated": .bool(true),
            "knowledge_graph_enabled": .bool(false),
            "adaptive_promotion": .bool(true),
            "hygiene_enabled": .bool(true),
            "hygiene_interval_hours": .int(6),
            "archive_noisy_reflections": .bool(true),
            "reject_low_value_proposals": .bool(true),
            "vault_enabled": .bool(true),
            "vault_require_encryption": .bool(true),
        ])
        policy["skillBuilderPolicy"] = .object([
            "allow_ui_panels": .bool(true),
            "v2_enabled": .bool(true),
        ])
        policy["swarmPolicy"] = .object([
            "enabled": .bool(true),
            "maxAgents": .int(20),
            "maxParallel": .int(6),
            "storeReceipts": .bool(true),
        ])
        policy["inboxPolicy"] = .object(["enabled": .bool(true)])
        policy["mcpPolicy"] = .object(["allow_lifecycle_ops": .bool(false)])
        policy["macControlPolicy"] = .object([
            "enabled": .bool(false),
            "applescript_allowed": .bool(false),
            "jxa_allowed": .bool(false),
            "shortcuts_allowed": .bool(true),
            "accessibility_allowed": .bool(false),
            "system_control_allowed": .bool(false),
            "file_ops_allowed": .bool(false),
            "shell_allowed": .bool(false),
            "notifications_allowed": .bool(true),
            "spotlight_allowed": .bool(true),
            "approval_required_for": .array([
                .string("shell"), .string("file_ops"),
                .string("applescript"), .string("jxa"), .string("accessibility"),
            ]),
            "remote_from_ios_allowed": .bool(false),
            "riskGatePolicy": .object([
                "low": .string("auto"),
                "medium": .string("approve_each"),
                "high": .string("approve_each"),
                "critical": .string("approve_each"),
            ]),
        ])
        policy["securityPolicy"] = .object([
            "securityCenterEnabled": .bool(true),
            "capabilityPolicyEnabled": .bool(true),
            "originTrustEnabled": .bool(true),
            "signedRemoteCommandsRequired": .bool(true),
            "promptInjectionShieldEnabled": .bool(true),
            "dangerGatesEnabled": .bool(true),
            "rollbackByDefault": .bool(true),
            "secretFirewallEnabled": .bool(true),
            "toolSigningRequired": .bool(true),
            "auditReceiptsEnabled": .bool(true),
            "allowAppNotifications": .bool(true),
            "killSwitchEnabled": .bool(false),
            "remoteHighRiskDefault": .string("block"),
            "criticalRequiresDeveloperMode": .bool(true),
        ])
        policy["providerPolicy"] = .object([
            "active_per_surface": .object([
                "chat": .string("openai_oauth_direct"),
                "ios": .string("openai_oauth_direct"),
                "telegram": .string("openai_oauth_direct"),
                "missions": .string("openai_oauth_direct"),
                "training": .string("openai_oauth_direct"),
                "dream": .string("openai_oauth_direct"),
                "autonomy": .string("openai_oauth_direct"),
            ]),
            "fallback_chain": .object([
                "chat": .array(Self.defaultFallbackChain),
                "ios": .array(Self.defaultFallbackChain),
                "telegram": .array(Self.defaultFallbackChain),
                "swarms": .array(Self.defaultSwarmFallbackChain),
            ]),
        ])
        return policy
    }

    private static let defaultFallbackChain: [JSONValue] = [
        .string("openai_oauth_direct"),
        .string("anthropic_oauth_direct"),
        .string("codex"),
        .string("anthropic"),
        .string("openrouter"),
        .string("local"),
    ]

    private static let defaultSwarmFallbackChain: [JSONValue] = [
        .string("openai_oauth_direct"),
        .string("anthropic_oauth_direct"),
        .string("codex"),
        .string("openrouter"),
        .string("local"),
    ]

    /// `toolAutonomy` defaults. The glob-matched entries are load-bearing for
    /// `autonomyForTool` resolution.
    private static let defaultToolAutonomy: [String: JSONValue] = [
        // U4 Wave D (gpt-5.5 review NEW-BLOCKER): the self-evolution chat tools
        // MUST default to `confirm` in SHIPPED CODE, not only in the git-ignored
        // live policy.json. An absent key falls through to the `default` ("auto")
        // → a fresh install or a policy reset would AUTO-FIRE the app-self-mod
        // tools (the exact builder-tools bug class). Pinned here + in
        // missionsDefaultToolAutonomy (the load-time backfill) so the posture is
        // effective on every install path; the user can still relax per-tool (saved
        // wins). evolution_status is read-only and a strong relax-to-auto
        // candidate — NEEDS-USER.
        "evolution_propose": .string("confirm"),
        "evolution_status": .string("confirm"),
        "self_install": .string("confirm"),
        "search.*": .string("auto"),
        "calendar.list_events": .string("auto"),
        "calendar.availability": .string("auto"),
        "calendar.create_event": .string("draft_auto"),
        "email.list_inbox": .string("auto"),
        "email.draft": .string("auto"),
        "x.status": .string("auto"),
        "x.me": .string("auto"),
        "x.search_recent": .string("auto"),
        "x.timeline_home": .string("auto"),
        "x.user_tweets": .string("auto"),
        "x.timeline_home_v1": .string("auto"),
        "x.user_tweets_v1": .string("auto"),
        "x.post_tweet": .string("send_approval"),
        "gmail.list_inbox": .string("auto"),
        "gmail.read": .string("auto"),
        "gmail.draft": .string("auto"),
        "gmail.search": .string("auto"),
        "gmail.send": .string("send_approval"),
        "agentmail.send": .string("send_approval"),
        "agentmail.list_inbox": .string("auto"),
        "agentmail.read": .string("auto"),
        "agentmail.search": .string("auto"),
        "agentmail_list": .string("auto"),
        "agentmail_read": .string("auto"),
        "agentmail_send": .string("send_approval"),
        "image_generate": .string("auto"),
        "email.send": .string("send_approval"),
        "slack.post_message": .string("send_approval"),
        "slack.status": .string("auto"),
        "slack.list_channels": .string("auto"),
        "slack.search_messages": .string("auto"),
        "slack.list_unreads": .string("auto"),
        "slack_status": .string("auto"),
        "slack_list_channels": .string("auto"),
        "slack_search_messages": .string("auto"),
        "slack_post_message": .string("send_approval"),
        "browser.status": .string("auto"),
        "browser.open_url": .string("auto"),
        "browser.navigate": .string("auto"),
        "browser.read_text": .string("auto"),
        "browser.read_links": .string("auto"),
        "browser.screenshot": .string("auto"),
        "doctor_status": .string("auto"),
        "telegram_status": .string("auto"),
        "gh.create_issue": .string("draft_auto"),
        "github.status": .string("auto"),
        "github_status": .string("auto"),
        "github.list_repos": .string("auto"),
        "github.list_issues": .string("auto"),
        "github.search": .string("auto"),
        "github.list_pull_requests": .string("auto"),
        "github.get_issue": .string("auto"),
        "github.get_pull_request": .string("auto"),
        "github.pull_request_files": .string("auto"),
        "github.pull_request_activity": .string("auto"),
        "github.discover_tracking": .string("auto"),
        "github.project_digest": .string("auto"),
        "github.mutate": .string("confirm"),
        "github_search": .string("auto"),
        "github_list_pull_requests": .string("auto"),
        "github_get_issue": .string("auto"),
        "github_get_pull_request": .string("auto"),
        "github_pull_request_files": .string("auto"),
        "github_pull_request_activity": .string("auto"),
        "github_discover_tracking": .string("auto"),
        "github_project_digest": .string("auto"),
        "github_mutate": .string("confirm"),
        "github.set_repo_visibility": .string("confirm"),
        "github_set_repo_visibility": .string("confirm"),
        "gh.list_repos": .string("auto"),
        "gh.search_issues": .string("auto"),
        "chat.synthesize": .string("auto"),
        "calendar_*": .string("auto"),
        "messages_*": .string("auto"),
        "mail_*": .string("auto"),
        "reminders_*": .string("auto"),
        "mac.spotlight_search": .string("auto"),
        "mac.notify": .string("auto"),
        "mobile.notify": .string("auto"),
        "codex.work_journal": .string("auto"),
        "codex.handoff": .string("auto"),
        "scheduler.schedule_job": .string("auto"),
        "scheduler.create_job": .string("auto"),
        "scheduler.list_jobs": .string("auto"),
        "scheduler.cancel_job": .string("auto"),
        "mac_assistant.watch_templates": .string("auto"),
        "mac.mail_list_recent": .string("auto"),
        "mac.calendar_list_upcoming": .string("auto"),
        "mac.reminders_list_due_today": .string("auto"),
        "mac.messages_list_recent": .string("auto"),
        "mac.notes_list_recent": .string("auto"),
        "mac.notes_search": .string("auto"),
        "mac.contacts_search": .string("auto"),
        "mac.run_shortcut": .string("auto"),
        "mac.list_shortcuts": .string("auto"),
        "mac.read_file": .string("auto"),
        "mac.list_directory": .string("auto"),
        "mac.running_apps": .string("auto"),
        "mac.applescript": .string("send_approval"),
        "mac.jxa": .string("send_approval"),
        "mac.focus_app": .string("send_approval"),
        "mac.quit_app": .string("send_approval"),
        "mac.write_file": .string("send_approval"),
        "mac.set_volume": .string("send_approval"),
        "mac.sleep_display": .string("send_approval"),
        "mac.lock_screen": .string("send_approval"),
        "mac.shell": .string("send_approval"),
        "tool_catalog": .string("auto"),
        "list_tools": .string("auto"),
        "tool_load": .string("auto"),
        "tool_result_page": .string("auto"),
        // Read-only resident/runtime inspection. These expose bounded status
        // already available in the app and have no side effects; allowing them
        // to fall through to the global send_approval default makes a fresh
        // install ask permission merely to describe its own capabilities.
        "agent_introspect": .string("auto"),
        "daemon_introspect": .string("auto"),
        "time_now": .string("auto"),
        // Bounded app-owned procedural posture review. The runtime permits
        // approve only for low-risk candidates; hold/reject never dispatch an
        // action. Keep it usable on bridge tool surfaces with no approval filer.
        "reflex_review": .string("auto"),
        "list_skills": .string("auto"),
        "save_skill": .string("auto"),
        "recall_memory": .string("auto"),
        // Canonical chat-history tool plus its compatibility alias. Keep both
        // explicit: `search.*` only matches dotted names, so omitting the
        // underscore form silently falls through to the approval default.
        "search_chat_history": .string("auto"),
        "session_search": .string("auto"),
        "search_kg": .string("auto"),
        "recent_trace_summary": .string("auto"),
        "scratchpad_read": .string("auto"),
        "scratchpad_write": .string("auto"),
        "persona_read": .string("auto"),
        "persona_write": .string("auto"),
        "persona_append_section": .string("auto"),
        "read_file": .string("auto"),
        "list_dir": .string("auto"),
        "full_mac_read_file": .string("auto"),
        "full_mac_list_dir": .string("auto"),
        // Agent-to-agent local bridge pings. These are not external account
        // sends; they write local inbox rows and optional local notifications.
        "claude_message": .string("auto"),
        "codex_message": .string("auto"),
        // the user intent, 2026-06-08: these are Agent's easy workspace helpers.
        // They are always-on chat tools and default to auto so she can stay in
        // workspace mode and delegate focused work without an approval detour.
        // Reachable on the claude/codex bridge as of 2026-06-13 (open-the-bridges).
        "invoke_claude": .string("auto"),
        "invoke_codex": .string("auto"),
        // App lifecycle tools default to `confirm` — every call queues a
        // the user-in-the-loop approval. TEMPLATE defaults only; the user's live
        // data/trust/policy.json can promote them to auto (saved values always
        // win over these defaults — never write live policy from code).
        "restart_app": .string("confirm"),
        "install_app": .string("confirm"),
        "default": .string("send_approval"),
    ]

    /// Mirror of `Workshop executions.DEFAULT_TOOL_AUTONOMY`.
    /// Backfilled into `toolAutonomy` at load time so new default keys take
    /// effect without resetting saved policies. Saved values always win.
    static let workshopExecutionsDefaultToolAutonomy: [String: JSONValue] = [
        // U4 Wave D (gpt-5.5 review NEW-BLOCKER): ship the self-evolution tools'
        // `confirm` posture in code. This dict is backfilled into toolAutonomy on
        // EVERY load (saved wins), so adding here makes confirm effective on both
        // fresh installs AND existing saved policies — closing the absent-key →
        // default:"auto" auto-fire path. See defaultToolAutonomy for rationale.
        "evolution_propose": .string("confirm"),
        "evolution_status": .string("confirm"),
        "self_install": .string("confirm"),
        "search.*": .string("auto"),
        "agent_introspect": .string("auto"),
        "daemon_introspect": .string("auto"),
        "time_now": .string("auto"),
        "chat.synthesize": .string("auto"),
        "local_files.search": .string("auto"),
        "local_files.read": .string("auto"),
        "local_files.list": .string("auto"),
        "searxng.search": .string("auto"),
        "searxng.fetch": .string("auto"),
        "gh.search_issues": .string("auto"),
        "gh.list_repos": .string("auto"),
        "github.status": .string("auto"),
        "github_status": .string("auto"),
        "github.list_issues": .string("auto"),
        "github.list_repos": .string("auto"),
        "github.search": .string("auto"),
        "github.list_pull_requests": .string("auto"),
        "github.get_issue": .string("auto"),
        "github.get_pull_request": .string("auto"),
        "github.pull_request_files": .string("auto"),
        "github.pull_request_activity": .string("auto"),
        "github.discover_tracking": .string("auto"),
        "github.project_digest": .string("auto"),
        "github.mutate": .string("confirm"),
        "github_search": .string("auto"),
        "github_list_pull_requests": .string("auto"),
        "github_get_issue": .string("auto"),
        "github_get_pull_request": .string("auto"),
        "github_pull_request_files": .string("auto"),
        "github_pull_request_activity": .string("auto"),
        "github_discover_tracking": .string("auto"),
        "github_project_digest": .string("auto"),
        "github_mutate": .string("confirm"),
        "github.set_repo_visibility": .string("confirm"),
        "github_set_repo_visibility": .string("confirm"),
        "gh.get_issue": .string("auto"),
        "gh.get_pull_request": .string("auto"),
        "gh.create_issue": .string("draft_auto"),
        "gmail.list_inbox": .string("auto"),
        "gmail.read": .string("auto"),
        "gmail.search": .string("auto"),
        "gmail.draft": .string("auto"),
        "gmail.send": .string("send_approval"),
        "agentmail.send": .string("send_approval"),
        "agentmail.list_inbox": .string("auto"),
        "agentmail.read": .string("auto"),
        "agentmail.search": .string("auto"),
        "agentmail_list": .string("auto"),
        "agentmail_read": .string("auto"),
        "agentmail_send": .string("send_approval"),
        "image_generate": .string("auto"),
        "email.list_inbox": .string("auto"),
        "email.draft": .string("auto"),
        "email.send": .string("send_approval"),
        "calendar.list_events": .string("auto"),
        "calendar.availability": .string("auto"),
        "calendar.find_availability": .string("auto"),
        "calendar.create_event": .string("draft_auto"),
        "calendar.cancel_event": .string("send_approval"),
        "notion.search": .string("auto"),
        "notion.read_page": .string("auto"),
        "notion.query_database": .string("auto"),
        "notion.create_page": .string("draft_auto"),
        "notion.append_block": .string("draft_auto"),
        "slack.status": .string("auto"),
        "slack.list_channels": .string("auto"),
        "slack.search_messages": .string("auto"),
        "slack.list_unreads": .string("auto"),
        "slack.post_message": .string("send_approval"),
        "slack_status": .string("auto"),
        "slack_list_channels": .string("auto"),
        "slack_search_messages": .string("auto"),
        "slack_post_message": .string("send_approval"),
        "browser.navigate": .string("auto"),
        "browser.status": .string("auto"),
        "browser.open_url": .string("auto"),
        "browser.screenshot": .string("auto"),
        "browser.read_text": .string("auto"),
        "browser.read_links": .string("auto"),
        "doctor_status": .string("auto"),
        "telegram_status": .string("auto"),
        "tool_catalog": .string("auto"),
        "list_tools": .string("auto"),
        "tool_load": .string("auto"),
        "tool_result_page": .string("auto"),
        "list_skills": .string("auto"),
        "save_skill": .string("auto"),
        "recall_memory": .string("auto"),
        "search_chat_history": .string("auto"),
        "session_search": .string("auto"),
        "search_kg": .string("auto"),
        "recent_trace_summary": .string("auto"),
        "scratchpad_read": .string("auto"),
        "scratchpad_write": .string("auto"),
        "read_file": .string("auto"),
        "list_dir": .string("auto"),
        "full_mac_read_file": .string("auto"),
        "full_mac_list_dir": .string("auto"),
        "claude_message": .string("auto"),
        "codex_message": .string("auto"),
        // App lifecycle tools: backfilled into saved policies at load time as
        // `confirm` (user-gated approval). A live policy.json entry (e.g. the user
        // promoting to auto) always wins over this default.
        "restart_app": .string("confirm"),
        "install_app": .string("confirm"),
        "default": .string("send_approval"),
    ]

}
