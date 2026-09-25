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

// 2026-09-18: strict providers fill unused optionals with null. Normalize from
// the native schema before approval and execution, including nested objects;
// required nulls and explicit false remain the caller's values.
public enum ToolArguments {
    @TaskLocal static var current: (tool: String, input: [String: JSONValue])?

    public static func normalized(_ input: [String: JSONValue], schema: JSONValue) -> [String: JSONValue] {
        guard case .object(let schema) = schema,
              case .object(let properties)? = schema["properties"] else { return input }
        let required: [JSONValue]
        if case .array(let values)? = schema["required"] { required = values } else { required = [] }
        var result = input
        for (key, value) in input {
            guard let field = properties[key] else { continue }
            if value == .null, !required.contains(.string(key)) {
                result.removeValue(forKey: key)
            } else {
                result[key] = normalizedValue(value, schema: field)
            }
        }
        return result
    }

    // Only coerce an unambiguous declared type. Free-form content and invalid
    // values stay intact for the tool's own validation; never invent a default.
    private static func normalizedValue(_ value: JSONValue, schema: JSONValue) -> JSONValue {
        guard case .object(let field) = schema else { return value }
        if case .object(let object) = value { return .object(normalized(object, schema: schema)) }
        if case .array(let values) = value, let items = field["items"] {
            return .array(values.map { normalizedValue($0, schema: items) })
        }
        let types: [JSONValue]
        if case .array(let values)? = field["type"] { types = values.filter { $0 != .string("null") } }
        else { types = field["type"].map { [$0] } ?? [] }
        guard types.count == 1 else { return value }
        switch (types[0], value) {
        case (.string("boolean"), .string(let raw)):
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: return value
            }
        case (.string("integer"), .string(let raw)):
            return Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)).map(JSONValue.int) ?? value
        case (.string("integer"), .double(let number)):
            return Int64(exactly: number).map(JSONValue.int) ?? value
        case (.string("number"), .string(let raw)):
            let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let integer = Int64(raw) { return .int(integer) }
            if let number = Double(raw), number.isFinite { return .double(number) }
            return value
        case (.string("string"), .int(let number)):
            return .string(String(number))
        case (.string("string"), .double(let number)) where number.isFinite:
            return .string(Int64(exactly: number).map(String.init) ?? String(number))
        case (.string("string"), .string(let raw)):
            guard case .array(let choices)? = field["enum"], !choices.contains(value) else { return value }
            func spelling(_ text: String) -> String {
                text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: "_")
            }
            let matches = choices.filter {
                guard case .string(let choice) = $0 else { return false }
                return spelling(choice) == spelling(raw)
            }
            return matches.count == 1 ? matches[0] : value
        default: return value
        }
    }
}

public extension ToolDispatchClient {
    func withToolArguments(
        tool: String, input: [String: JSONValue],
        body: ([String: JSONValue]) async throws -> JSONValue
    ) async throws -> JSONValue {
        let identity = tool.replacingOccurrences(of: ".", with: "_")
        if let current = ToolArguments.current, current.tool == identity, current.input == input { return try await body(input) }
        let schemas = (try? await listAvailableToolSchemas()) ?? []
        let canonical = SwiftToolDispatcher.canonicalToolName(tool) { name in schemas.contains { $0.name == name } }
        let schema = schemas.first { $0.name == canonical || $0.name.replacingOccurrences(of: ".", with: "_") == canonical }
        let normalized = schema.flatMap { try? JSONValue.parse($0.parametersJSON) }
            .map { ToolArguments.normalized(input, schema: $0) } ?? input
        return try await ToolArguments.$current.withValue((identity, normalized)) { try await body(normalized) }
    }
}

/// A dispatcher that can refuse a call BEFORE the approval membrane files a
/// card for it. Everything cheap and certain — is this tool even loaded, do its
/// arguments parse — belongs here: a person should never approve a call that was
/// always going to fail, and a model should hear about a bad call in the same
/// turn it made it (2026-09-13, the 0.4.12 drive).
public protocol PreApprovalToolValidating: Sendable {
    func preApprovalRefusal(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> JSONValue?

    /// The words the person should read on the card for THIS call, when the
    /// generic "autonomy=confirm" reason cannot say what is about to happen.
    /// A setup that writes into another program's settings has to disclose the
    /// exact file, the exact entry and the exact access before anyone presses
    /// anything, and only the implementation knows those. Nil keeps the
    /// caller's own reason, which is every existing tool.
    func approvalCardReason(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> String?
}

public extension PreApprovalToolValidating {
    func approvalCardReason(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> String? { nil }
}

extension SwiftToolDispatcher {
    /// Test seam (2026-07-31) for the lazy-load gate's catalog enumeration.
    /// `listAvailableTools()` on the concrete dispatcher has no natural throw
    /// path, so the fail-closed `catalog_unavailable` branch below is
    /// unreachable from a real dataRoot. Task-local (not a global var) so
    /// parallel test execution can't race it; always nil in production.
    @TaskLocal static var lazyGateCatalogOverrideForTests: (@Sendable () async throws -> [String])?

    /// The chat catalog names tools `mac_look`; the Trust Center registry and
    /// the autonomy gate also speak `mac.look` (the connector-action id). A
    /// model that has just read a registry row will call the dotted form —
    /// Agent did on 2026-08-22 (mac.look / mac.act / mac.view, every call
    /// "not in the dispatch table", whole acceptance run void). The two
    /// spellings name ONE tool; resolve the dotted one to its catalog name
    /// when, and only when, that catalog name exists. Unknown names stay
    /// unknown — this is an alias, not a fuzzy match.
    static func canonicalToolName(_ name: String, catalog: (String) -> Bool) -> String {
        guard name.contains("."), !name.hasPrefix("mcp__"), !catalog(name) else { return name }
        let underscored = name.replacingOccurrences(of: ".", with: "_")
        guard !["agent_message", "agent_read"].contains(underscored) else { return name }
        return catalog(underscored) ? underscored : name
    }

    public func dispatch(tool requestedTool: String, input rawInput: [String: JSONValue], surface: String) async throws -> JSONValue {
        ChatToolOutcome.normalizedFailure(try await withToolArguments(tool: requestedTool, input: rawInput) { input in
            try await dispatchNormalized(tool: requestedTool, input: input, surface: surface)
        })
    }

    private func dispatchNormalized(tool requestedTool: String, input rawInput: [String: JSONValue], surface: String) async throws -> JSONValue {
        // The gated chat dispatcher already binds its transport-verified
        // session in task-local context. Keep direct diagnostics fail-closed,
        // but do not make a model repeat that internal routing field on every
        // lazy tool call. LLMCallContext is the lower-authority compatibility
        // seam for direct tool-loop dispatchers that bind no gate wrapper.
        // An explicit non-empty input value remains authoritative only when
        // neither canonical task-local owner is present.
        var input = rawInput
        let taskSession = [ChatToolSessionContext.verifiedSessionId, LLMCallContext.sessionId]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let taskSession {
            input["__session_id"] = .string(taskSession)
        }
        let tool = Self.canonicalToolName(requestedTool) { candidate in
            Self.dottedAliasCanonicalToolNames.contains(candidate)
        }
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
        // Four-verb cutover: a conversational call always carries session_id.
        // Keep the mac_* organs callable by direct diagnostics (which do not)
        // while refusing stale model calls from an old persisted loadout.
        if Self.legacyMacModelToolNames.contains(tool),
           !Self.extractSessionId(from: input).isEmpty {
            return .object([
                "status": .string("failed"),
                "reason": .string("legacy_mac_tool_internal_only"),
                "tool": .string(tool),
                "replacement": .array(Self.fourVerbToolNames.map { .string($0) }),
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
        // A lazy tool always needs a concrete session. Without one there is
        // no active-tool set to check, and treating that absence as a
        // non-chat exception would silently turn the whole catalog on for
        // whichever caller forgot to carry its session through dispatch.
        // The always-on core and external MCP namespace retain their explicit
        // exceptions above; every catalogued native lazy tool fails closed.
        if let refusal = await lazyToolLoadingRefusal(tool: tool, input: input) {
            return refusal
        }
        switch tool {
        case "read_page":
            guard case .string(let url)? = input["url"],
                  let parsed = URL(string: url),
                  ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                  parsed.host?.isEmpty == false, parsed.user == nil, parsed.password == nil else {
                throw AutonomyGateError.toolDenied(reason: "read_page requires a public http(s) URL.")
            }
            return try await pageReader.fetchURL(url).toJSON()
        // The three basic file tools, when Full Mac file access is off. A path
        // the workspace lane cannot reach is not a fact to report in prose —
        // it is one switch away, and asking for it is the honest move.
        case "read_file":
            if await fullMacToolAccess(surface: surface).fileOpsAllowed {
                return try await impl_full_mac_read_file(input: input, surface: surface)
            }
            do {
                return try await impl_read_file(input: input)
            } catch {
                guard let need = fileOpsNeedEnvelope(
                    tool: tool, mode: .read, path: jsonString(input["path"]), error: error
                ) else { throw error }
                return need
            }
        case "list_dir":
            if await fullMacToolAccess(surface: surface).fileOpsAllowed {
                return try await impl_full_mac_list_dir(input: input, surface: surface)
            }
            do {
                return try await impl_list_dir(input: input)
            } catch {
                guard let need = fileOpsNeedEnvelope(
                    tool: tool, mode: .read, path: jsonString(input["path"]), error: error
                ) else { throw error }
                return need
            }
        case "write_file":
            if await fullMacToolAccess(surface: surface).fileOpsAllowed {
                return try await impl_local_connector_tool(tool: tool, input: input, surface: surface)
            }
            do {
                return try await impl_trusted_write_file(input: input)
            } catch {
                guard let need = fileOpsNeedEnvelope(
                    tool: tool, mode: .write, path: jsonString(input["path"]), error: error
                ) else { throw error }
                return need
            }
        case "bot_create", "bot_update", "bot_pause", "bot_run_once", "bot_list", "shelf_read", "shelf_entry", "bot_ask", "bot_delete":
            return try await impl_standingBots(tool: tool, input: input)
        case "recall_memory":   return try await impl_recall_memory(input: input, surface: surface)
        case "recall_search":   return try await impl_recall_memory(input: input, surface: surface)
        case "commit_memory":   return try await impl_commit_memory(input: input)
        // The moments lane (2026-09-02): her review seat over the moment
        // proposals the post-turn promoter stages. Both refuse any id whose
        // lane is not "moment".
        case "memory_moments_pending": return try await impl_memory_moments_pending()
        case "memory_moment_review": return try await impl_memory_moment_review(input: input)
        case "list_memories":   return try await impl_list_memories(input: input)
        case "rewrite_memory":  return try await impl_rewrite_memory(input: input)
        case "forget_memory":   return try await impl_forget_memory(input: input)
        case "rebuild_knowledge_graph": return try await impl_rebuild_knowledge_graph(input: input)
        case "workshop_submit": return try await impl_workshop_submit(input: input)
        case "workshop_status": return try await impl_workshop_status(input: input)
        case "task_ledger_post": return try await impl_task_ledger_post(input: input)
        case "task_ledger_list": return try await impl_task_ledger_list(input: input)
        // delegation_status (W2, 2026-08-11): read-only projection over the
        // claude/codex wake-job stores. No write, no spawn, no network.
        case "delegation_status": return try await impl_delegation_status(input: input)
        case "agent_contacts", "agent_connect", "agent_message", "agent_read":
            return try await impl_agentCommunication(tool: tool, input: input, surface: surface)
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
        // Studio chat lane (desk 903): consults filed against the agent's taste
        // and the journal she writes herself. Nothing here auto-appends and
        // nothing auto-retrieves.
        case "studio_consult": return try await impl_studio_consult(input: input)
        case "studio_consult_read": return try await impl_studio_consult_read(input: input)
        case "studio_journal": return try await impl_studio_journal(input: input)
        case "studio_journal_amend": return try await impl_studio_journal_amend(input: input)
        case "studio_recall": return try await impl_studio_recall(input: input)
        case "dream_diary_read": return try await impl_dream_diary_read(input: input)
        case "studio_shelf_read": return await impl_studio_shelf(input: input, surface: surface, set: false)
        case "studio_shelf_set": return await impl_studio_shelf(input: input, surface: surface, set: true)
        case "studio_canon": return try await impl_studio_canon(input: input)
        // `surface` is threaded in because the canon SEAT is decided from
        // runtime provenance and cross-checked against the running turn, never
        // read from tool input. See StudioCanonSeatGate.
        case "studio_canon_resolve":
            return try await impl_studio_canon_resolve(input: input, surface: surface)
        // Item 7 (2026-09-02): the held tier's two verbs. Both are seated on
        // her own live local turn inside the impl — see
        // SwiftToolDispatcher+StandingViewTools.swift.
        case "hold_view":
            return await impl_hold_view(input: input, surface: surface)
        case "release_view":
            return await impl_release_view(input: input, surface: surface)
        case "search_kg":       return try await impl_search_kg(input: input)
        case "search_chat_history": return try await impl_search_chat_history(input: input, invokedAs: tool)
        case "workspace":
            // The outer verified-session facade consumes this preparation;
            // Core alone never turns a button into an ungated nested action.
            return .object(["status": .string("prepared"), "execution": .string("requires_workspace_runtime")])
        case "work_context": return try await impl_work_context(input: input)
        case "artifact_find": return try await impl_artifact_find(input: input)
        case "session_search": return try await impl_search_chat_history(input: input, invokedAs: tool)
        case "read_chat_message": return try await impl_read_chat_message(input: input, invokedAs: tool)
        case "chat_conversations": return try await impl_chat_conversations(input: input)
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
        case "request_interaction": return await impl_request_interaction(input: input)
        case "list_skills":     return try await impl_list_skills(input: input)
        case "read_skill":      return try await impl_read_skill(input: input)
        case "save_skill":      return try await impl_save_skill(input: input)
        case "context_lookup": return try await impl_context_lookup(input: input)
        case "context_expand": return try impl_context_expand(input: input, surface: surface)
        case "scratchpad_read": return try await impl_scratchpad_read(input: input)
        case "recent_trace_summary": return try await impl_recent_trace_summary(input: input)
        case "time_now": return Self.impl_time_now()
        // Personality depth item 3 (2026-09-02): a PURE read of her own inner
        // state. No mutation, no persistence, no provider call — reading never
        // changes what it reads (substrate design law 5).
        case "inner_state": return await impl_inner_state(input: input)
        // ── Builder tools (2026-06-08 agent-builder-tools) ──
        // Process-based CLI execution. Trust Center Full Mac file_ops_allowed
        // REQUIRED upstream; default autonomy is `confirm` so every call
        // queues an approval. Audit trail at data/builder_audit/<uuid>.json.
        // Available on the claude/codex bridge as of the user's 2026-06-13 "open the
        // bridges" call, yolo-gated like local chat (only mcp__ stays denied).
        case "shell":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return builderFullMacRequired(tool: "shell")
            }
            return await Self.impl_shell(input: input, dataRoot: dataRoot)
        case "bash":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return builderFullMacRequired(tool: "bash")
            }
            return await Self.impl_bash(input: input, dataRoot: dataRoot)
        case "git":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return builderFullMacRequired(tool: "git")
            }
            return await Self.impl_git(input: input, dataRoot: dataRoot)
        case "apply_patch":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return builderFullMacRequired(tool: "apply_patch")
            }
            return await Self.impl_apply_patch(input: input, dataRoot: dataRoot)
        case "run_tests":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return builderFullMacRequired(tool: "run_tests")
            }
            return await Self.impl_run_tests(input: input, dataRoot: dataRoot)
        case "swift_build":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return builderFullMacRequired(tool: "swift_build")
            }
            return await Self.impl_swift_build(input: input, dataRoot: dataRoot)
        case "swift_test":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return builderFullMacRequired(tool: "swift_test")
            }
            return await Self.impl_swift_test(input: input, dataRoot: dataRoot)
        case "remote_node_list":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return builderFullMacRequired(tool: "remote_node_list")
            }
            return try await impl_remote_node_list()
        case "remote_node_execute":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return builderFullMacRequired(tool: "remote_node_execute")
            }
            return try await impl_remote_node_execute(input: input)
        case "install_app":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return builderFullMacRequired(tool: "install_app")
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
                return builderFullMacRequired(tool: "restart_app")
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
                return builderFullMacRequired(tool: "evolution_propose")
            }
            guard let bridge = evolutionBridge else {
                return Self.evolutionBridgeNotWiredEnvelope(tool: "evolution_propose")
            }
            return try await bridge.evolutionPropose(input: input)
        case "evolution_status":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return builderFullMacRequired(tool: "evolution_status")
            }
            guard let bridge = evolutionBridge else {
                return Self.evolutionBridgeNotWiredEnvelope(tool: "evolution_status")
            }
            return try await bridge.evolutionStatus(input: input)
        case "evolution_withdraw":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return builderFullMacRequired(tool: "evolution_withdraw")
            }
            guard let bridge = evolutionBridge else {
                return Self.evolutionBridgeNotWiredEnvelope(tool: "evolution_withdraw")
            }
            return try await bridge.evolutionWithdraw(input: input)
        case "self_install":
            if !(await fullMacToolAccess(surface: surface).fileOpsAllowed) {
                return builderFullMacRequired(tool: "self_install")
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
        case "github_list_notifications":
            return try await GitHubConnectorActions.listNotifications(input: input, dataRoot: dataRoot)
        case "github_get_repository":
            return try await GitHubConnectorActions.getRepository(input: input, dataRoot: dataRoot)
        case "github_read_repository_content":
            return try await GitHubConnectorActions.readRepositoryContent(input: input, dataRoot: dataRoot)
        case "github_list_commits":
            return try await GitHubConnectorActions.listCommits(input: input, dataRoot: dataRoot)
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
            if await fullMacYoloAdmitted(tool: tool, surface: surface) {
                return await ExternalSendApprovalLifecycle.executeAdmittedYoloToolResult(
                    invokedAs: tool,
                    input: input,
                    dataRoot: dataRoot
                )
            }
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
            if await fullMacYoloAdmitted(tool: tool, surface: surface) {
                return await ExternalSendApprovalLifecycle.executeAdmittedYoloToolResult(
                    invokedAs: tool,
                    input: input,
                    dataRoot: dataRoot
                )
            }
            return await ExternalSendApprovalLifecycle.stageToolResult(
                invokedAs: tool,
                input: input,
                surface: surface,
                dataRoot: dataRoot
            )
        case "image_generate":
            return Self.studioImageInvitation(await impl_image_generate(input: input, surface: surface))
        // ── Mac integration chat tools (2026-06-07) ──
        // Each tool is permission-gated through MacIntegrationPermissionStore.
        // The real backend (EventKit / UserNotifications / Spotlight) is
        // injected as a MacIntegrationToolBridge — see protocol at top of file.
        case "mac_calendar_list_upcoming":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.calendar,
                mode: .read,
                fixHint: "Toggle Read ON for Calendar in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in HerLifePulse.noted("calendar", try await bridge.calendarListUpcoming(input: input)) }
            )
        case "mac_reminders_list_due_today":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.reminders,
                mode: .read,
                fixHint: "Toggle Read ON for Reminders in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in HerLifePulse.noted("reminders", try await bridge.remindersListDueToday(input: input)) }
            )
        case "mac_notify":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
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
                tool: tool, surface: surface,
                integration: MacIntegrationID.notifyMobile,
                mode: .write,
                fixHint: "Toggle Write ON for iPhone Notifications in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mobileNotify(input: input) }
            )
        case "mac_spotlight_search":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
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
                tool: tool, surface: surface,
                integration: MacIntegrationID.contacts,
                mode: .read,
                fixHint: "Toggle Read ON for Contacts in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.contactsSearch(input: input) }
            )
        case "contacts_create_or_update":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.contacts,
                mode: .write,
                fixHint: "Toggle Write ON for Contacts in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.contactsCreateOrUpdate(input: input) }
            )
        case "mail_list_recent":
            let inbox = try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.mail,
                mode: .read,
                fixHint: "Toggle Read ON for Mail in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mailListRecent(input: input) }
            )
            HerMailStatus.shared.note(inbox) // home's mail count, no read of its own
            return inbox
        case "mail_search":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.mail,
                mode: .read,
                fixHint: "Toggle Read ON for Mail in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mailSearch(input: input) }
            )
        case "mail_send":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.mail,
                mode: .write,
                fixHint: "Toggle Write ON for Mail in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mailSend(input: input) }
            )
        case "messages_recent_threads":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.messages,
                mode: .read,
                fixHint: "Toggle Read ON for Messages in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.messagesRecentThreads(input: input) }
            )
        case "messages_send":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.messages,
                mode: .write,
                fixHint: "Toggle Write ON for Messages in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.messagesSend(input: input) }
            )
        case "notes_search":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.notes,
                mode: .read,
                fixHint: "Toggle Read ON for Notes in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.notesSearch(input: input) }
            )
        case "notes_create":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.notes,
                mode: .write,
                fixHint: "Toggle Write ON for Notes in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.notesCreate(input: input) }
            )
        case "music_now_playing":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.music,
                mode: .read,
                fixHint: "Toggle Read ON for Music in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.musicNowPlaying(input: input) }
            )
        case "music_control":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
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
                tool: tool, surface: surface,
                integration: MacIntegrationID.calendar,
                mode: .write,
                fixHint: "Toggle Write ON for Calendar in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.calendarCreateEvent(input: input) }
            )
        case "mac_calendar_modify_event":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.calendar,
                mode: .write,
                fixHint: "Toggle Write ON for Calendar in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.calendarModifyEvent(input: input) }
            )
        case "mac_calendar_delete_event":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.calendar,
                mode: .write,
                fixHint: "Toggle Write ON for Calendar in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.calendarDeleteEvent(input: input) }
            )
        case "mac_reminders_create":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.reminders,
                mode: .write,
                fixHint: "Toggle Write ON for Reminders in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.remindersCreate(input: input) }
            )
        case "mac_reminders_complete":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.reminders,
                mode: .write,
                fixHint: "Toggle Write ON for Reminders in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.remindersComplete(input: input) }
            )
        case "mail_mark_read":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.mail,
                mode: .write,
                fixHint: "Toggle Write ON for Mail in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mailMarkRead(input: input) }
            )
        case "mail_archive":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.mail,
                mode: .write,
                fixHint: "Toggle Write ON for Mail in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mailArchive(input: input) }
            )
        case "mail_delete":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.mail,
                mode: .write,
                fixHint: "Toggle Write ON for Mail in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mailDelete(input: input) }
            )
        case "mail_reply":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.mail,
                mode: .write,
                fixHint: "Toggle Write ON for Mail in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.mailReply(input: input) }
            )
        case "notes_update":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.notes,
                mode: .write,
                fixHint: "Toggle Write ON for Notes in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.notesUpdate(input: input) }
            )
        case "music_search_library":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.music,
                mode: .read,
                fixHint: "Toggle Read ON for Music in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.musicSearchLibrary(input: input) }
            )
        case "music_list_library":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.music,
                mode: .read,
                fixHint: "Toggle Read ON for Music in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.musicListLibrary(input: input) }
            )
        case "music_list_playlists":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
                integration: MacIntegrationID.music,
                mode: .read,
                fixHint: "Toggle Read ON for Music in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.musicListPlaylists(input: input) }
            )
        case "contacts_delete":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
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
                tool: tool, surface: surface,
                integration: MacIntegrationID.scheduler,
                mode: .write,
                fixHint: "Toggle Write ON for Scheduler in Settings → Mac Integration.",
                input: input,
                run: { bridge, input in try await bridge.schedulerListJobs(input: input) }
            )
        case "scheduler_create_job":
            return try await dispatchMacIntegrationTool(
                tool: tool, surface: surface,
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
        case let name where Self.fourVerbToolNames.contains(name):
            // Must precede the read/injection list cases: `screen`/`wait` sit
            // in the read list and `act`/`go` in the injection list for
            // loading/visibility, but they ROUTE here.
            return try await impl_mac_four_verbs_tool(tool: name, input: input, surface: surface)
        case let name where Self.fullMacAccessibilityReadToolNames.contains(name):
            return try await impl_mac_accessibility_read_tool(tool: name, input: input, surface: surface)
        // W7 — the NUDGE. Its own case, gated on the same read-tier signal:
        // one bare mouse move, no approval, no capability. It never reaches
        // impl_mac_injection_tool, and it could not use one if it did.
        case let name where Self.fullMacNudgeToolNames.contains(name):
            return try await impl_mac_nudge_tool(tool: name, input: input, surface: surface)
        // fable51 item 30 — THE CLIPBOARD ORGAN. Its own route, because its
        // gate is split down the middle: the read clears the accessibility READ
        // tier, the write clears app control. Neither needs an injection
        // capability, so it must not reach `impl_mac_injection_tool`.
        case let name where Self.macClipboardToolNames.contains(name):
            return try await impl_mac_clipboard_tool(tool: name, input: input, surface: surface)
        // fable51 item 29 — THE MENU BAR ORGAN. Its own route for the same
        // reason: the walk is read tier, the press is the full injection
        // contract, and one route that knows the difference is clearer than
        // splitting one organ across two neighbours' lists.
        case let name where Self.macMenuToolNames.contains(name):
            return try await impl_mac_menu_tool(tool: name, input: input, surface: surface)
        // fable51 item 33 — THE READ ORGAN. Its own route because its gate is
        // CONDITIONAL: read tier always, plus file_ops when — and only when —
        // the call names a path of its own. No neighbour's list can express
        // "the gate depends on an argument", so it gets its own case.
        case let name where Self.macReadToolNames.contains(name):
            return try await impl_mac_read_tool(tool: name, input: input, surface: surface)
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
                    input: input,
                    surface: surface
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
                    return builderFullMacRequired(tool: tool)
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

extension SwiftToolDispatcher: PreApprovalToolValidating {
    /// The lazy-load gate of docs/TOOL_LOADING.md, as a check any caller can run
    /// on its own: nil when the call may proceed, the refusal otherwise.
    /// `dispatch` runs it where it always did; the approval membrane runs it
    /// before it files a card. A known tool loads here and continues through
    /// the same argument, approval, and execution gates as a loaded call.
    func lazyToolLoadingRefusal(tool: String, input: [String: JSONValue]) async -> JSONValue? {
        guard enforcesLazyToolLoading,
              !Self.alwaysOnCoreNames.contains(tool),
              !tool.hasPrefix("mcp__") else { return nil }
        let sessionId = Self.extractSessionId(from: input)
        guard !sessionId.isEmpty else {
            return JSONValue.object([
                "status": .string("failed"),
                "reason": .string("missing_session_id"),
                "tool": .string(tool),
                "fix": .string("Pass the current chat session id as session_id or __session_id."),
            ])
        }
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
            return JSONValue.object([
                "status": .string("failed"),
                "reason": .string("catalog_unavailable"),
                "tool": .string(tool),
                "session_id": .string(sessionId),
                "detail": .string(String(describing: error)),
                "fix": .string("The tool catalog could not be enumerated, so the lazy-load gate cannot verify '\(tool)'. Retry; if it persists, check data/tools/registry.json and the MCP server config."),
            ])
        }
        // The outer facade router preserves both permission names. Its loaded
        // facade authorizes using only the corresponding local implementation,
        // without requiring the model to separately discover legacy names.
        let facade: String?
        if let raw = GatedToolNameContext.rawSpelling(of: tool),
           (raw == "agent_message" && ["codex_message", "claude_message", "omp_message", "bot_ask"].contains(tool))
            || (raw == "agent_read" && ["delegation_status", "shelf_read", "shelf_entry"].contains(tool)) {
            facade = raw
        } else { facade = nil }
        if let facade, !allAvailable.contains(tool) || !allAvailable.contains(facade) {
            return .object(["status": .string("failed"), "reason": .string("tool_unavailable"),
                            "tool": .string(tool), "detail": .string("The requested agent route is not available in this tool catalog.")])
        }
        if allAvailable.contains(tool) {
            let loadedName = facade ?? tool
            let persisted = await activeToolsStore.load(sessionId: sessionId).activeTools
            // CURRENT-TURN UNLOADS (2026-09-13): `turnActiveTools` is frozen at
            // turn start, so unioning it re-admitted a tool `tool_unload` had
            // just retracted (and everything after `tool_unload(all:)`) for the
            // rest of the turn. An explicit `tool_load` clears the exclusion.
            let unloadedThisTurn = await activeToolsStore.turnUnloadedNames(sessionId: sessionId)
            if unloadedThisTurn.contains(loadedName) {
                return .object([
                    "status": .string("failed"), "reason": .string("not_loaded"),
                    "tool": .string(tool), "detail": .string("This tool was unloaded for this turn."),
                ])
            }
            let active = persisted
                .union(LLMCallContext.turnActiveTools ?? [])
                .subtracting(unloadedThisTurn)
            // USAGE STAMP (2026-09-01): a session-loaded tool that is being
            // CALLED stays advertised. This is the only signal feeding
            // beginTurn's idle drop — without it the drop would be a timer,
            // not "she's done with it".
            if persisted.contains(loadedName) {
                await activeToolsStore.markUsed(sessionId: sessionId, names: [loadedName])
            }
            if !active.contains(loadedName) {
                do {
                    let receipt = try await impl_tool_load(input: [
                        "session_id": .string(sessionId),
                        "names": .array([.string(loadedName)]),
                    ])
                    guard case .object(let object) = receipt,
                          case .array(let loaded)? = object["loaded"],
                          loaded.contains(.string(loadedName)) else { return receipt }
                    await activeToolsStore.markUsed(sessionId: sessionId, names: [loadedName])
                } catch {
                    return .object([
                        "status": .string("failed"), "reason": .string("tool_load_failed"),
                        "tool": .string(tool), "detail": .string(String(describing: error)),
                    ])
                }
            }
        }
        return nil
    }

    /// Everything that must be true before a tool call is worth a person's
    /// attention: it is loaded for this turn, and its arguments are ones the
    /// implementation will accept. Returns the tool error to hand back to the
    /// model, or nil to go on and file the approval.
    public func preApprovalRefusal(
        tool requestedTool: String, input rawInput: [String: JSONValue], surface: String
    ) async -> JSONValue? {
        var input = rawInput
        let taskSession = [ChatToolSessionContext.verifiedSessionId, LLMCallContext.sessionId]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let taskSession { input["__session_id"] = .string(taskSession) }
        let tool = Self.canonicalToolName(requestedTool) { candidate in
            Self.dottedAliasCanonicalToolNames.contains(candidate)
        }
        if let refusal = await lazyToolLoadingRefusal(tool: tool, input: input) { return refusal }
        if let refusal = agentHostSetupRefusal(tool: tool, input: input) { return refusal }
        if let problem = await standingBotsArgumentProblem(tool: tool, input: input) {
            return .object([
                "status": .string("failed"),
                "reason": .string("invalid_arguments"),
                "tool": .string(tool),
                "detail": .string(problem),
            ])
        }
        return nil
    }

    /// Connect-by-name, before a card exists. An agent this build has no row
    /// for, or one that is not installed, is a certain "no" — the person should
    /// never be asked to approve a setup that was always going to fail.
    private func agentHostSetupRefusal(tool: String, input: [String: JSONValue]) -> JSONValue? {
        guard let proposal = agentHostProposal(tool: tool, input: input) else { return nil }
        switch proposal {
        case .success: return nil
        case .failure(let error):
            return .object(["status": .string("not_supported"),
                            "tool": .string(tool),
                            "changed": .bool(false),
                            "known_agents": .array(AgentHostDirectory.knownNames.map(JSONValue.string)),
                            "detail": .string(error.localizedDescription)])
        }
    }

    /// Nil unless this really is an `agent_connect` with a name and nothing
    /// else — the by-name setup path and no other shape of the call.
    private func agentHostProposal(tool: String, input: [String: JSONValue])
        -> Result<AgentHostConnection.Proposal, AgentHostConnection.Refusal>? {
        guard tool == "agent_connect", usesCanonicalBody,
              case .string(let name)? = input["name"],
              input["endpoint"] == nil || input["endpoint"] == .null || input["endpoint"] == .string(""),
              input["app_bundle_id"] == nil || input["app_bundle_id"] == .null || input["app_bundle_id"] == .string(""),
              input["disconnect"] == nil || input["disconnect"] == .null || input["disconnect"] == .bool(false),
              input["transport"] == nil || input["transport"] == .null
                || input["transport"] == .string("") || input["transport"] == .string("auto") else { return nil }
        let folder: String?
        if case .string(let path)? = input["working_directory"] { folder = path } else { folder = nil }
        let workspace: String?
        if case .string(let value)? = input["workspace"] { workspace = value } else { workspace = nil }
        do { return .success(try AgentHostConnection.propose(name: name, store: AgentPeerStore(dataRoot: dataRoot), dataRoot: dataRoot, workspace: workspace, workingDirectory: folder)) }
        catch let refusal as AgentHostConnection.Refusal { return .failure(refusal) }
        catch { return nil }
    }

    /// ONE approval card covers the disclosed setup and nothing else, in the
    /// words `AgentHostConnection.cardText` writes.
    public func approvalCardReason(
        tool requestedTool: String, input: [String: JSONValue], surface: String
    ) async -> String? {
        let tool = Self.canonicalToolName(requestedTool) { candidate in
            Self.dottedAliasCanonicalToolNames.contains(candidate)
        }
        // ACP's live connect card binds the exact resolved executable and
        // reported version. It is also required when ordinary tool trust allows.
        if tool == "agent_connect", case .string(let name)? = input["name"],
           AgentHostDirectory.row(named: name)?.acp != nil { return nil }
        if let sentence = standingBotApprovalReason(tool: tool, input: input) {
            return sentence
        }
        guard case .success(var proposal)? = agentHostProposal(tool: tool, input: input),
              proposal.existing == nil || proposal.row.route == .grokBot else { return nil }
        // The approved replay carries this exact observation, not a later PATH lookup.
        if case .string(let path)? = input["executable_path"] { proposal.executablePath = path }
        else { proposal.executablePath = nil }
        return AgentHostConnection.cardText(proposal, appName: Self.appDisplayName)
    }

    /// The product's own name for the card's title. Not a persona name.
    public static var appDisplayName: String {
        let bundle = Bundle.main
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "this app" : trimmed
    }
}
