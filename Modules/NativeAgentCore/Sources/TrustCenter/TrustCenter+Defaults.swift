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
        // Wave 4 phase A: STILL the old key. Readers accept `workshopPolicy`
        // too (WorkshopPolicyBlockVocabulary), but every writer keeps emitting
        // `missionPolicy` so a 0.3.7 iOS install decodes this byte-for-byte.
        policy[WorkshopPolicyBlockVocabulary.wireKey] = .object([
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
            "toolSigningRequired": .bool(false),  // USER YOLO 2026-08-12
            "auditReceiptsEnabled": .bool(true),
            "allowAppNotifications": .bool(true),
            "killSwitchEnabled": .bool(false),
            "remoteHighRiskDefault": .string("block"),
            "criticalRequiresDeveloperMode": .bool(false),  // USER YOLO 2026-08-12
        ])
        policy["providerPolicy"] = .object([
            "active_per_surface": .object([
                "chat": .string("openai_oauth_direct"),
                "ios": .string("openai_oauth_direct"),
                "telegram": .string("openai_oauth_direct"),
                // Both spellings: the merge below is default-union-saved, so a
                // saved 0.3.x policy keyed `missions` keeps working while a
                // canonical reader finds `workshop` (P2-3).
                "workshop": .string("openai_oauth_direct"),
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
        "remote_node_execute": .string("confirm"),
        "remote_node_list": .string("auto"),
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
        // W1b — READ-ONLY accessibility perception. Explicit "auto" tier
        // rather than fallback: they read the on-screen AX tree and mutate
        // nothing, so they sit with spotlight_search, not with the
        // send_approval mac.focus_app / mac.quit_app pair below. The
        // Trust Center accessibility category still gates them.
        "mac.ax_status": .string("auto"),
        "mac.ax_tree": .string("auto"),
        "mac.ax_find": .string("auto"),
        // W3.5 — the fused view sits with them: perception, no approval. The
        // accessibility category AND the Screen Recording system grant both
        // still apply.
        "mac.view": .string("auto"),
        "mac_view": .string("auto"),
        // W7 — mac_nudge sits with them: one bare mouse move, no click, no
        // keystroke, no app state changed, so there is nothing to approve.
        // Pinned under BOTH spellings for the same reason the injection pair
        // below is — `autonomyForTool` matches the override key literally, and
        // the gate is asked about `mac_nudge` while the connector registry and
        // any card speak `mac.nudge`.
        "mac.nudge": .string("auto"),
        "mac_nudge": .string("auto"),
        // USER 2026-08-12 — YOLO: "Nothing should be approval gated for her. Nothing."
        // Every Mac motor action is `auto`. His machine, his agent, his call: the
        // Full-Mac grant IS the consent. Per-call approval made these dead on any
        // non-interactive surface (bridge / while he is away) — the exact moments
        // she needs to act. Full Mac + accessibility category + TCC still gate ALL
        // of these; this only removes the per-call prompt.
        // W2/W3 — INPUT INJECTION. Previously send_approval, pinned under
        // BOTH spellings on purpose: `autonomyForTool` matches the override key
        // literally, and the autonomy gate is asked about the model-tool name
        // (`mac_keystroke`) while the connector registry and the approval card
        // speak the action id (`mac.keystroke`). One spelling alone would leave
        // the other resolving through `autonomyDefault` instead of this floor.
        //
        // These four are also on `isFullMacYoloAutonomyExcludedTool`, so an
        // active Full Mac YOLO window cannot flatten them to auto the way it
        // does for mac.focus_app / mac.quit_app.
        "mac.keystroke": .string("auto"),
        "mac.click": .string("auto"),
        "mac.scroll": .string("auto"),
        "mac.ax_act": .string("auto"),
        "mac_keystroke": .string("auto"),
        "mac_click": .string("auto"),
        "mac_scroll": .string("auto"),
        "mac_ax_act": .string("auto"),
        // W6 — mac_wake. Both spellings, same floor, for the same reason: it
        // posts a HID event. The result it returns is a mac_view, but the tier
        // follows the emission, not the payload.
        "mac.wake": .string("auto"),
        "mac_wake": .string("auto"),
        // W7 — activity_query. Explicit "auto" rather than fallback, under BOTH
        // spellings for the same reason the Mac pairs above are: `autonomyForTool`
        // matches the override key LITERALLY, and the autonomy gate is asked
        // about the model-tool name (`activity_query`) while the connector
        // registry and any card speak the action id (`activity.query`). One
        // spelling alone leaves the other resolving through `autonomyDefault`.
        //
        // "auto" is not a weakening: this tool's real gate is the Trust Center
        // Activity Capture toggle, which is OFF by default and which the impl
        // re-reads and refuses on. Asking for approval to read data the user
        // explicitly asked to have recorded would be theatre.
        "activity.query": .string("auto"),
        "activity_query": .string("auto"),
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
        "mac.applescript": .string("auto"),
        "mac.jxa": .string("auto"),
        "mac.focus_app": .string("auto"),
        "mac.quit_app": .string("auto"),
        "mac.write_file": .string("auto"),
        "mac.set_volume": .string("auto"),
        "mac.sleep_display": .string("auto"),
        "mac.lock_screen": .string("auto"),
        "mac.shell": .string("auto"),
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
        "omp_message": .string("auto"),
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
        // USER 2026-08-12 YOLO: the catch-all no longer gates her. Anything
        // unlisted resolves auto; Full Mac + category + TCC remain the gates.
        "default": .string("auto"),
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
        "remote_node_execute": .string("confirm"),
        "remote_node_list": .string("auto"),
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
        "omp_message": .string("auto"),
        // App lifecycle tools: backfilled into saved policies at load time as
        // `confirm` (user-gated approval). A live policy.json entry (e.g. the user
        // promoting to auto) always wins over this default.
        "restart_app": .string("confirm"),
        "install_app": .string("confirm"),
        // USER 2026-08-12 YOLO: the catch-all no longer gates her. Anything
        // unlisted resolves auto; Full Mac + category + TCC remain the gates.
        "default": .string("auto"),
    ]

}
