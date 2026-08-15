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
import GitHubConnector
import SlackConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import ToolExecution
import Skills

extension SwiftToolDispatcher {
    /// Test seam (2026-07-31) for the lazy-load gate's catalog enumeration.
    /// `listAvailableTools()` on the concrete dispatcher has no natural throw
    /// path, so the fail-closed `catalog_unavailable` branch below is
    /// unreachable from a real dataRoot. Task-local (not a global var) so
    /// parallel test execution can't race it; always nil in production.
    @TaskLocal static var lazyGateCatalogOverrideForTests: (@Sendable () async throws -> [String])?

    public func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if ToolCallParser.isIgnorableToolName(tool) {
            return .object([
                "status": .string("ignored"),
                "reason": .string("placeholder_tool_name"),
                "tool": .string(tool),
            ])
        }
        if !usesCanonicalBody, Self.canonicalBodyOnlyToolNames.contains(tool) {
            return .object([
                "status": .string("failed"),
                "reason": .string("canonical_body_unavailable"),
                "tool": .string(tool),
            ])
        }
        // Lazy-load gate (gpt-5.5 review-2 NEEDS_FIX 1): a tool requires
        // explicit tool_load UNLESS it's:
        //   - in alwaysOnCoreNames (the small hot core; currently under 20)
        //   - an MCP server tool (mcp__*)
        //   - not in the catalog at all (then the dispatch switch's default
        //     case handles it as not_in_dispatch_table)
        //
        // Previous version only checked builtInToolNames, so Full Mac tools
        // (shell, bash, git, apply_patch, run_tests, swift_build,
        // swift_test, mac_focus_app, etc.)
        // bypassed the gate entirely once Full Mac was on — defeating the
        // whole token-saving + safety-deferring point of lazy load.
        //
        // The gate fires when the call carries a session_id (the chat
        // surface always passes one). Surfaces that don't pass a session
        // (claude-bridge, headless tests, programmatic calls) have their
        // own gates upstream — they bypass here.
        if !Self.alwaysOnCoreNames.contains(tool), !tool.hasPrefix("mcp__") {
            let sessionId = Self.extractSessionId(from: input)
            if !sessionId.isEmpty {
                // Build the "exists in catalog" set from listAvailableTools()
                // (the FULL accessible catalog, including Full-Mac additions).
                // 2026-07-31 fail-closed fix: this used to be
                // `if let names = try? await listAvailableTools() { ... } else
                // { allAvailable = [] }`. Because gate enforcement lives
                // INSIDE `allAvailable.contains(tool)`, an empty substitute set
                // made every catalogued tool skip the not_loaded gate — a
                // thrown enumeration silently opened the whole lazy-load gate.
                // Enumeration failure now fails the CALL, not the gate.
                let allAvailable: Set<String>
                do {
                    if let override = Self.lazyGateCatalogOverrideForTests {
                        allAvailable = Set(try await override())
                    } else {
                        allAvailable = Set(try await listAvailableTools())
                    }
                } catch {
                    return .object([
                        "status": .string("failed"),
                        "reason": .string("catalog_unavailable"),
                        "tool": .string(tool),
                        "session_id": .string(sessionId),
                        "detail": .string(String(describing: error)),
                        "fix": .string("The tool catalog could not be enumerated, so the lazy-load gate cannot verify '\(tool)'. Retry; if it persists, check data/tools/registry.json and the MCP server config."),
                    ])
                }
                if allAvailable.contains(tool) {
                    let persisted = await activeToolsStore.load(sessionId: sessionId).activeTools
                    let active = persisted.union(LLMCallContext.turnActiveTools ?? [])
                    if !active.contains(tool) {
                        return .object([
                            "status": .string("failed"),
                            "reason": .string("not_loaded"),
                            "tool": .string(tool),
                            "session_id": .string(sessionId),
                            "fix": .string("Tool exists in catalog but is not loaded in this session. Call tool_load(session_id:\"\(sessionId)\", names:[\"\(tool)\"]) first, then retry."),
                        ])
                    }
                }
            }
            // No sessionId: this is a non-chat surface (claude-bridge,
            // headless, programmatic). Skip the lazy gate — those surfaces
            // are gated elsewhere (Trust Center / yolo window, read_only
            // fileAccess on the RPC path, the external-MCP bridge guard,
            // test fixtures).
        }
        switch tool {
        case "read_file":
            if await fullMacToolAccess(surface: surface).fileOpsAllowed {
                return try await impl_full_mac_read_file(input: input, surface: surface)
            }
            return try await impl_read_file(input: input)
        case "list_dir":
            if await fullMacToolAccess(surface: surface).fileOpsAllowed {
                return try await impl_full_mac_list_dir(input: input, surface: surface)
            }
            return try await impl_list_dir(input: input)
        case "write_file":
            if await fullMacToolAccess(surface: surface).fileOpsAllowed {
                return try await impl_local_connector_tool(tool: tool, input: input, surface: surface)
            }
            return try await impl_trusted_write_file(input: input)
        case "recall_memory":   return try await impl_recall_memory(input: input, surface: surface)
        case "recall_search":   return try await impl_recall_memory(input: input, surface: surface)
        case "commit_memory":   return try await impl_commit_memory(input: input)
        case "workshop_submit": return try await impl_workshop_submit(input: input)
        case "workshop_status": return try await impl_workshop_status(input: input)
        case "task_ledger_post": return try await impl_task_ledger_post(input: input)
        case "task_ledger_list": return try await impl_task_ledger_list(input: input)
        // delegation_status (W2, 2026-08-11): read-only projection over the
        // claude/codex wake-job stores. No write, no spawn, no network.
        case "delegation_status": return try await impl_delegation_status(input: input)
        case "desk_read": return try await impl_desk_read(input: input)
        case "desk_add_item": return try await impl_desk_add_item(input: input)
        case "desk_set_status": return try await impl_desk_set_status(input: input)
        case "desk_update_item": return try await impl_desk_update_item(input: input)
        case "desk_note": return try await impl_desk_note(input: input)
        case "desk_add_ref": return try await impl_desk_add_ref(input: input)
        case "desk_set_cadence": return try await impl_desk_set_cadence(input: input)
        case "desk_set_notify": return try await impl_desk_set_notify(input: input)
        case "desk_close": return try await impl_desk_close(input: input)
        case "desk_archive": return try await impl_desk_archive(input: input)
        case "desk_blocked_on": return try await impl_desk_blocked_on(input: input)
        case "desk_defer": return try await impl_desk_defer(input: input)
        case "desk_breakdown": return try await impl_desk_breakdown(input: input)
        case "desk_nag_control": return try await impl_desk_nag_control(input: input)
        case "desk_open_pursuit": return try await impl_desk_open_pursuit(input: input)
        case "desk_work_log": return try await impl_desk_work_log(input: input)
        case "search_kg":       return try await impl_search_kg(input: input)
        case "search_chat_history": return try await impl_search_chat_history(input: input, invokedAs: tool)
        case "session_search": return try await impl_search_chat_history(input: input, invokedAs: tool)
        case "get_persona_doc": return try await impl_get_persona_doc(input: input)
        case "persona_read": return try await impl_persona_read(input: input)
        case "persona_write": return try await impl_persona_write(input: input)
        case "persona_append_section": return try await impl_persona_append_section(input: input)
        case "agent_introspect": return try await impl_agent_introspect(input: input, invokedAs: tool)
        case "daemon_introspect": return try await impl_agent_introspect(input: input, invokedAs: tool)
        case "tool_catalog": return try await impl_tool_catalog(input: input, surface: surface)
        case "list_tools": return try await impl_tool_catalog(input: input, surface: surface)
        case "tool_load": return try await impl_tool_load(input: input, surface: surface)
        case "tool_unload": return try await impl_tool_unload(input: input, surface: surface)
        case "tool_result_page": return await impl_tool_result_page(input: input)
        case "list_skills":     return try await impl_list_skills(input: input)
        case "read_skill":      return try await impl_read_skill(input: input)
        case "save_skill":      return try await impl_save_skill(input: input)
        case "context_lookup": return try await impl_context_lookup(input: input)
        case "context_expand": return try impl_context_expand(input: input, surface: surface)
        case "scratchpad_read": return try await impl_scratchpad_read(input: input)
        case "recent_trace_summary": return try await impl_recent_trace_summary(input: input)
        case "time_now": return Self.impl_time_now()
        // ── Builder tools (2026-06-08 agent-builder-tools) ──
        // Process-based CLI execution. Trust Center Full Mac file_ops_allowed
        // REQUIRED upstream; default autonomy is `confirm` so every call
        // queues an approval. Audit trail at data/builder_audit/<uuid>.json.
        // Available on the claude/codex bridge as of the user's 2026-06-13 "open the
        // bridges" call, yolo-gated like local chat (only mcp__ stays denied).
        case "shell":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return Self.builderFullMacRequiredEnvelope(tool: "shell")
            }
            return await Self.impl_shell(input: input, dataRoot: dataRoot)
        case "bash":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return Self.builderFullMacRequiredEnvelope(tool: "bash")
            }
            return await Self.impl_bash(input: input, dataRoot: dataRoot)
        case "git":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return Self.builderFullMacRequiredEnvelope(tool: "git")
            }
            return await Self.impl_git(input: input, dataRoot: dataRoot)
        case "apply_patch":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return Self.builderFullMacRequiredEnvelope(tool: "apply_patch")
            }
            return await Self.impl_apply_patch(input: input, dataRoot: dataRoot)
        case "run_tests":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return Self.builderFullMacRequiredEnvelope(tool: "run_tests")
            }
            return await Self.impl_run_tests(input: input, dataRoot: dataRoot)
        case "swift_build":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return Self.builderFullMacRequiredEnvelope(tool: "swift_build")
            }
            return await Self.impl_swift_build(input: input, dataRoot: dataRoot)
        case "swift_test":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return Self.builderFullMacRequiredEnvelope(tool: "swift_test")
            }
            return await Self.impl_swift_test(input: input, dataRoot: dataRoot)
        case "remote_node_list":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return Self.builderFullMacRequiredEnvelope(tool: "remote_node_list")
            }
            return try await impl_remote_node_list()
        case "remote_node_execute":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return Self.builderFullMacRequiredEnvelope(tool: "remote_node_execute")
            }
            return try await impl_remote_node_execute(input: input)
        case "install_app":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return Self.builderFullMacRequiredEnvelope(tool: "install_app")
            }
            return Self.impl_install_app(input: input, dataRoot: dataRoot)
        // restart_app (2026-06-10) — Agent's self-restart, restored from the
        // daemon-era Telegram /restart. Same Full Mac policy gate as the
        // builder tools; the heavy lifting (cooldown flock, audit, detached
        // relauncher, grace-period terminate sized to outlive the final
        // reply LLM call) lives ONCE in AppRestartCoordinator, shared with
        // the Telegram /restart path.
        case "restart_app":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return Self.builderFullMacRequiredEnvelope(tool: "restart_app")
            }
            let reason: String = {
                if case .string(let r)? = input["reason"] { return r }
                return ""
            }()
            return await AppRestartCoordinator.shared.requestRestart(
                reason: reason,
                source: "chat:\(surface)"
            )
        // ── self-evolution chat tools (2026-06-11, U2b) ──
        // Same Full-Mac policy gate as the builder tools; the store mutation /
        // card-stage backends live in the app target (EvolutionProposalStore +
        // BackgroundLoopsAssembly.stageEvolutionApprovals) and are reached via
        // the injected EvolutionToolBridge. A nil bridge returns a
        // `bridge_not_wired` envelope rather than throwing. self_install only
        // STAGES a card a human still approves — it never installs.
        case "evolution_propose":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return Self.builderFullMacRequiredEnvelope(tool: "evolution_propose")
            }
            guard let bridge = evolutionBridge else {
                return Self.evolutionBridgeNotWiredEnvelope(tool: "evolution_propose")
            }
            return try await bridge.evolutionPropose(input: input)
        case "evolution_status":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return Self.builderFullMacRequiredEnvelope(tool: "evolution_status")
            }
            guard let bridge = evolutionBridge else {
                return Self.evolutionBridgeNotWiredEnvelope(tool: "evolution_status")
            }
            return try await bridge.evolutionStatus(input: input)
        case "self_install":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return Self.builderFullMacRequiredEnvelope(tool: "self_install")
            }
            guard let bridge = evolutionBridge else {
                return Self.evolutionBridgeNotWiredEnvelope(tool: "self_install")
            }
            return try await bridge.evolutionStageInstall(input: input)
        case "agent_swarm": return try await impl_agent_swarm(input: input, surface: surface)
        case "market_status": return try await impl_market_status(input: input)
        case "market_watchlists": return try await impl_market_watchlists(input: input)
        case "tradingview_watchlist": return try await impl_tradingview_watchlist(input: input)
        case "market_quote": return try await impl_market_quote(input: input)
        // X (Twitter) — route to XConnector module which already wraps
        // OAuth2 user-context + OAuth1 HMAC-SHA1 against the user's stored creds
        // at <dataRoot>/connectors/x/.
        case "x_status":      return try await XConnectorActions.status(input: input)
        case "x_me":          return try await XConnectorActions.me(input: input)
        case "x_search":      return try await XConnectorActions.searchRecent(input: input)
        case "x_timeline":
            return try await xConnectorWithOAuthFallback(
                input: input,
                primary: { try await XConnectorActions.timelineHome(input: $0) },
                fallback: { try await XConnectorActions.timelineHomeV1(input: $0) }
            )
        case "x_user_tweets":
            return try await xConnectorWithOAuthFallback(
                input: input,
                primary: { try await XConnectorActions.userTweets(input: $0) },
                fallback: { try await XConnectorActions.userTweetsV1(input: $0) }
            )
        case "gmail_status":
            return await impl_gmail_status(input: input)
        case "gmail_search":
            return await impl_gmail_search(input: input)
        case "gmail_read":
            return await impl_gmail_read(input: input)
        case "google_calendar_status":
            return await impl_google_calendar_status(input: input)
        case "google_calendar_list":
            return await impl_google_calendar_list(input: input)
        case "notion_status":
            return await impl_notion_status(input: input)
        case "notion_search":
            return await impl_notion_search(input: input)
        case "notion_read_page":
            return await impl_notion_read_page(input: input)
        case "github_status":
            return try await GitHubConnectorActions.status(input: input, dataRoot: dataRoot)
        case "github_list_repos":
            return try await GitHubConnectorActions.listRepos(input: input, dataRoot: dataRoot)
        case "github_list_issues":
            return try await GitHubConnectorActions.listIssues(input: input, dataRoot: dataRoot)
        case "github_search":
            return try await GitHubConnectorActions.search(input: input, dataRoot: dataRoot)
        case "github_list_pull_requests":
            return try await GitHubConnectorActions.listPullRequests(input: input, dataRoot: dataRoot)
        case "github_get_issue":
            return try await GitHubConnectorActions.getIssue(input: input, dataRoot: dataRoot)
        case "github_get_pull_request":
            return try await GitHubConnectorActions.getPullRequest(input: input, dataRoot: dataRoot)
        case "github_pull_request_files":
            return try await GitHubConnectorActions.pullRequestFiles(input: input, dataRoot: dataRoot)
        case "github_pull_request_activity":
            return try await GitHubConnectorActions.pullRequestActivity(input: input, dataRoot: dataRoot)
        case "github_discover_tracking":
            return try await GitHubConnectorActions.discoverTracking(input: input, dataRoot: dataRoot)
        case "github_project_digest":
            return try await GitHubConnectorActions.projectDigest(input: input, dataRoot: dataRoot)
        case "github_mutate":
            return try await GitHubConnectorActions.mutate(input: input, dataRoot: dataRoot)
        case "github_set_repo_visibility":
            return try await GitHubConnectorActions.setRepoVisibility(input: input, dataRoot: dataRoot)
        case "slack_status":
            return try await SlackConnectorActions.status(input: input)
        case "slack_list_channels":
            return try await SlackConnectorActions.listChannels(input: input)
        case "slack_search_messages":
            return try await SlackConnectorActions.searchMessages(input: input)
        case "slack_post_message":
            return await ExternalSendApprovalLifecycle.stageToolResult(
                invokedAs: tool,
                input: input,
                surface: surface,
                dataRoot: dataRoot
            )
        case "agentmail_list":
            return await AgentMailActions.listRecent(input: input, dataRoot: dataRoot)
        case "agentmail_read":
            return await AgentMailActions.readMessage(input: input, dataRoot: dataRoot)
        case "agentmail_send":
            return await ExternalSendApprovalLifecycle.stageToolResult(
                invokedAs: tool,
                input: input,
                surface: surface,
                dataRoot: dataRoot
            )
        case "image_generate":
            return await impl_image_generate(input: input)
        // ── Mac integration chat tools (2026-06-07) ──
        // Each tool is permission-gated through MacIntegrationPermissionStore.
        // The real backend (EventKit / UserNotifications / Spotlight) is
        // injected as a MacIntegrationToolBridge — see protocol at top of file.
        case "mac_calendar_list_upcoming":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.calendar,
                mode: .read,
                fixHint: "Toggle Read ON for Calendar in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.calendarListUpcoming(input: input) }
            )
        case "mac_reminders_list_due_today":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.reminders,
                mode: .read,
                fixHint: "Toggle Read ON for Reminders in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.remindersListDueToday(input: input) }
            )
        case "mac_notify":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.notifyMac,
                mode: .write,
                fixHint: "Toggle Write ON for Mac Notifications in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.macNotify(input: input) }
            )
        case "claude_message":
            // 2026-06-08 her→me return channel for ClaudeBridge. Agent
            // calls this when she wants to flag something to Claude for
            // follow-up. Appends a JSONL entry to
            // ~/.config/claude-bridge/claude-inbox.jsonl (mode 0600 dir +
            // file). Claude's Claude Code UserPromptSubmit hook reads
            // unread entries at session start and surfaces them as context.
            // 2026-07-25: the append is followed by a real session wakeup
            // (script/claude_thread_wakeup.js) so the message no longer waits
            // for User to open a terminal; receipt rides under "wakeup".
            return try await runClaudeMessage(
                input: input,
                surface: surface,
                configRootOverride: agentBridgeConfigRoot
            )
        case "codex_message":
            // 2026-06-08 Agent -> Codex async return channel. Same durable
            // inbox shape as claude_message, plus a best-effort local Mac
            // notification when the app-side integration bridge is wired.
            return try await runCodexMessage(input: input, surface: surface)
        case "omp_message":
            return try await runOMPMessage(input: input, surface: surface)
        case "invoke_claude":
            // 2026-06-08 her→me REAL-TIME invocation channel. Spawns
            // `claude -p "<context+question>"` as a subprocess, blocks
            // until exit (or timeout), returns stdout. This is the wild
            // pattern from last night's spec: Agent invokes a fresh
            // Claude session in parallel when she's stuck — Claude
            // arrives with full file/git/bash, works the problem, exits,
            // Agent continues with the answer. No push infrastructure.
            return try await Self.runInvokeClaude(input: input, dataRoot: dataRoot)
        case "invoke_codex":
            // 2026-06-08 Agent -> Codex real-time invocation. Spawns
            // `codex exec` as a bounded subprocess and audits the reply at
            // data/from_codex/<uuid>.json. Defaults to workspace-write rather
            // than full-Mac danger mode.
            return try await Self.runInvokeCodex(input: input, dataRoot: dataRoot)
        case "mobile_notify":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.notifyMobile,
                mode: .write,
                fixHint: "Toggle Write ON for iPhone Notifications in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mobileNotify(input: input) }
            )
        case "mac_spotlight_search":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.spotlight,
                mode: .read,
                fixHint: "Toggle Read ON for Spotlight Search in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.spotlightSearch(input: input) }
            )
        // ── Phase 2 (2026-06-07) — Contacts + Mail + Messages + Notes + Music ──
        // Same permission-gate-then-bridge shape as Phase 1. Writes are gated
        // through MacIntegrationPermissionStore which defaults the sensitive 5
        // (contacts.write / mail.write / messages.write / notes.write / music.write)
        // OFF until the user flips them in Settings → Mac Integration.
        case "contacts_search":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.contacts,
                mode: .read,
                fixHint: "Toggle Read ON for Contacts in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.contactsSearch(input: input) }
            )
        case "contacts_create_or_update":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.contacts,
                mode: .write,
                fixHint: "Toggle Write ON for Contacts in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.contactsCreateOrUpdate(input: input) }
            )
        case "mail_list_recent":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.mail,
                mode: .read,
                fixHint: "Toggle Read ON for Mail in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mailListRecent(input: input) }
            )
        case "mail_search":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.mail,
                mode: .read,
                fixHint: "Toggle Read ON for Mail in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mailSearch(input: input) }
            )
        case "mail_send":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.mail,
                mode: .write,
                fixHint: "Toggle Write ON for Mail in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mailSend(input: input) }
            )
        case "messages_recent_threads":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.messages,
                mode: .read,
                fixHint: "Toggle Read ON for Messages in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.messagesRecentThreads(input: input) }
            )
        case "messages_send":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.messages,
                mode: .write,
                fixHint: "Toggle Write ON for Messages in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.messagesSend(input: input) }
            )
        case "notes_search":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.notes,
                mode: .read,
                fixHint: "Toggle Read ON for Notes in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.notesSearch(input: input) }
            )
        case "notes_create":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.notes,
                mode: .write,
                fixHint: "Toggle Write ON for Notes in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.notesCreate(input: input) }
            )
        case "music_now_playing":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.music,
                mode: .read,
                fixHint: "Toggle Read ON for Music in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.musicNowPlaying(input: input) }
            )
        case "music_control":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.music,
                mode: .write,
                fixHint: "Toggle Write ON for Music in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.musicControl(input: input) }
            )
        // ── Phase 3 (2026-06-07) — complete read+write coverage on every
        // Mac Integration toggle. Same permission-gate-then-bridge shape.
        // Sensitive writes default OFF in MacIntegrationPermissionStore.
        case "mac_calendar_create_event":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.calendar,
                mode: .write,
                fixHint: "Toggle Write ON for Calendar in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.calendarCreateEvent(input: input) }
            )
        case "mac_calendar_modify_event":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.calendar,
                mode: .write,
                fixHint: "Toggle Write ON for Calendar in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.calendarModifyEvent(input: input) }
            )
        case "mac_reminders_create":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.reminders,
                mode: .write,
                fixHint: "Toggle Write ON for Reminders in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.remindersCreate(input: input) }
            )
        case "mac_reminders_complete":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.reminders,
                mode: .write,
                fixHint: "Toggle Write ON for Reminders in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.remindersComplete(input: input) }
            )
        case "mail_mark_read":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.mail,
                mode: .write,
                fixHint: "Toggle Write ON for Mail in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mailMarkRead(input: input) }
            )
        case "mail_archive":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.mail,
                mode: .write,
                fixHint: "Toggle Write ON for Mail in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mailArchive(input: input) }
            )
        case "mail_delete":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.mail,
                mode: .write,
                fixHint: "Toggle Write ON for Mail in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mailDelete(input: input) }
            )
        case "mail_reply":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.mail,
                mode: .write,
                fixHint: "Toggle Write ON for Mail in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mailReply(input: input) }
            )
        case "notes_update":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.notes,
                mode: .write,
                fixHint: "Toggle Write ON for Notes in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.notesUpdate(input: input) }
            )
        case "music_search_library":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.music,
                mode: .read,
                fixHint: "Toggle Read ON for Music in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.musicSearchLibrary(input: input) }
            )
        case "music_list_library":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.music,
                mode: .read,
                fixHint: "Toggle Read ON for Music in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.musicListLibrary(input: input) }
            )
        case "music_list_playlists":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.music,
                mode: .read,
                fixHint: "Toggle Read ON for Music in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.musicListPlaylists(input: input) }
            )
        case "contacts_delete":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.contacts,
                mode: .write,
                fixHint: "Toggle Write ON for Contacts in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.contactsDelete(input: input) }
            )
        // Scheduler has no read axis — both list + create gate on .write per
        // MacIntegrationID.supportsRead(scheduler)==false. The W1 substrate
        // already defaults scheduler.write ON (the user trusts it).
        case "scheduler_list_jobs":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.scheduler,
                mode: .write,
                fixHint: "Toggle Write ON for Scheduler in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.schedulerListJobs(input: input) }
            )
        case "scheduler_create_job":
            return try await dispatchMacIntegrationTool(
                integration: MacIntegrationID.scheduler,
                mode: .write,
                fixHint: "Toggle Write ON for Scheduler in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.schedulerCreateJob(input: input) }
            )
        case let name where Self.fullMacFileToolNames.contains(name):
            return try await impl_local_connector_tool(tool: name, input: input, surface: surface)
        case let name where Self.fullMacSystemToolNames.contains(name):
            return try await impl_local_connector_tool(tool: name, input: input, surface: surface)
        case let name where Self.fullMacAppToolNames.contains(name):
            return try await impl_mac_app_control_tool(tool: name, input: input, surface: surface)
        // W1b — READ-ONLY accessibility perception. Separate route from the
        // app-control case above: same gate CATEGORY, read TIER, no approval.
        case let name where Self.fullMacAccessibilityReadToolNames.contains(name):
            return try await impl_mac_accessibility_read_tool(tool: name, input: input, surface: surface)
        // W7 — the NUDGE. Its own case, gated on the same read-tier signal:
        // one bare mouse move, no approval, no capability. It never reaches
        // impl_mac_injection_tool, and it could not use one if it did.
        case let name where Self.fullMacNudgeToolNames.contains(name):
            return try await impl_mac_nudge_tool(tool: name, input: input, surface: surface)
        // W7 — the ambient activity watcher's query tool. Its own route because
        // its gate is not a Mac-control category at all: the impl reads the
        // Trust Center capture toggle and refuses when it is off, and refuses
        // outright on remote surfaces (the tool is Mac-local by decision).
        case let name where Self.activityQueryToolNames.contains(name):
            return try await impl_activity_query_tool(tool: name, input: input, surface: surface)
        // W2/W3 — INJECTION. Third route under the same gate category: the
        // impl adds the approval attestation MacControl requires, which the two
        // routes above deliberately never do.
        case let name where Self.fullMacAccessibilityInjectionToolNames.contains(name):
            return try await impl_mac_injection_tool(tool: name, input: input, surface: surface)
        default:
            if let bridged = Self.parseMCPToolName(tool) {
                return try await impl_mcp_tool(
                    serverId: bridged.serverId,
                    toolName: bridged.toolName,
                    input: input
                )
            }
            // R9: custom tools promoted into data/tools/registry.json route
            // through the sandboxed ToolExecution engine — the same lane
            // WorkflowOrchestration tool_run steps use. runTool enforces
            // active-status, code-fingerprint match, and the subprocess
            // sandbox/timeout; promotion itself is human-approved upstream.
            // Before this route, registry names were catalog-visible but
            // undispatchable (the custom-tool activation gap).
            // Reserved built-in names never reach here (the switch matches
            // them first), so this route only ever executes genuine customs.
            if readRegistryNames().contains(tool) {
                // Review blocker fix: a registry tool executes self-authored
                // code in a subprocess — shell-class. Same Full-Mac file_ops
                // gate as shell/bash/builder tools. Capability-ADD with the
                // existing seatbelt: customs were never chat-dispatchable
                // before R9, so this locks nothing down.
                if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                    return Self.builderFullMacRequiredEnvelope(tool: tool)
                }
                // Review finding 3 fix: runTool only VERIFIES a fingerprint
                // when one exists. The chat lane fails closed on unsigned
                // tools rather than silently weakening the invariant.
                guard let fingerprint = registryToolFingerprint(tool), !fingerprint.isEmpty else {
                    return .object([
                        "status": .string("failed"),
                        "reason": .string("unsigned_tool"),
                        "tool": .string(tool),
                        "fix": .string("Tool '\(tool)' has no codeFingerprint in registry.json or its active manifest. Re-promote it so the promote engine stamps one."),
                    ])
                }
                // The admitted fingerprint is threaded through so a registry
                // or manifest swap between this check and the run fails as
                // fingerprintMismatch instead of downgrading to unverified
                // (review round-2 TOCTOU finding).
                return try await SwiftNativeToolExecution(root: dataRoot)
                    .runTool(id: tool, input: .object(input), requiredFingerprint: fingerprint)
            }
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(tool)' is not in the dispatch table"
            )
        }
    }

}
