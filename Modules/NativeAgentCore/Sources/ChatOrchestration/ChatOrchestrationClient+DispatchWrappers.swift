import Foundation
import ApprovalInbox
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
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import StandingBots

// MARK: - Dotted-alias canonicalization (outermost)

/// 2026-09-06: the dispatcher's dotted-alias canonicalizer (`save.skill` →
/// `save_skill`) ran INSIDE `SwiftToolDispatcher.dispatch`, i.e. after every
/// gate had already judged the spelling the caller supplied. So `save.skill`
/// matched neither `FileAccessGatedDispatcher`'s blocklist nor a Trust Center
/// override keyed on `save_skill`, and `tool.catalog` slipped past the bridge
/// guard's meta-result scrub — while Core still executed `save_skill` /
/// `tool_catalog`. Canonicalize ONCE, outside every gate, so each gate judges
/// the name that will actually execute. Idempotent: the inner dispatcher's own
/// canonicalization then finds nothing left to rewrite.
public final class CanonicalToolNameDispatcher: ToolDispatchClient, @unchecked Sendable {
    private let inner: any ToolDispatchClient
    private let peerDataRoot: URL?
    private let builtInLanes: (any BuiltInAgentLaneProviding)?
    private let conversationScope: String?

    public init(inner: any ToolDispatchClient, peerDataRoot: URL? = nil,
                builtInLanes: (any BuiltInAgentLaneProviding)? = nil, conversationScope: String? = nil) {
        self.inner = inner
        self.peerDataRoot = peerDataRoot
        self.builtInLanes = builtInLanes ?? (inner as? any BuiltInAgentLaneProviding)
        self.conversationScope = conversationScope
    }

    /// Usable builder lanes retain their bare names; otherwise a saved contact owns its name.
    private func namingSavedContact(_ tool: String, _ input: [String: JSONValue]) throws -> [String: JSONValue] {
        guard tool == "agent_message" || tool == "agent_read", let root = peerDataRoot,
              case .string(let agent)? = input["agent"], !agent.contains(":")
        else { return input }
        var input = input
        let name = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        let lane = name.lowercased() == "claude" ? "claude" : name.lowercased()
        if builtInLanes?.builtInAgentLaneUsable(lane) == true {
            input["agent"] = .string(lane)
            return input
        }
        var matches = try AgentPeerStore(dataRoot: root).list().filter {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }.map { "peer:" + $0.id }
        matches += try BotDefinitionStore(dataRoot: root).list().filter {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }.map { "bot:" + $0.id.uuidString }
        guard matches.count <= 1 else {
            throw AgentConversationStore.Failure(message: "More than one contact is named \(name). Choose its exact contact from agent_contacts.")
        }
        if let exact = matches.first { input["agent"] = .string(exact) }
        else if ["codex", "claude", "omp"].contains(lane) { input["agent"] = .string(lane) }
        return input
    }

    /// The exact rule `SwiftToolDispatcher.dispatch` applies downstream:
    /// dotted, non-`mcp__`, not itself a catalog name, and the underscored
    /// spelling IS a catalog name. Unknown names stay unknown.
    public static func canonical(_ name: String) -> String {
        SwiftToolDispatcher.canonicalToolName(name) { candidate in
            SwiftToolDispatcher.dottedAliasCanonicalToolNames.contains(candidate)
        }
    }

    public func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let result = try await inner.withToolArguments(tool: Self.canonical(tool), input: input) { input in
            try await dispatchNormalized(tool: tool, input: input, surface: surface)
        }
        // Attach to structured owner results so every provider lane receives
        // the same replayable receipt, without altering scalar/file contents,
        // adding synthetic chat turns, or changing the cached prompt prefix.
        guard !AgentWorkspaceArrivals.insideWorkspaceDispatch,
              case .object(var fields) = result,
              fields["workspace_arrivals"] == nil,
              let notice = await AgentWorkspaceArrivals.pending(dataRoot: peerDataRoot,
                scope: ChatToolSessionContext.verifiedSessionId ?? conversationScope) else { return result }
        fields["workspace_arrivals"] = notice
        return .object(fields)
    }

    private func dispatchNormalized(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if Self.canonical(tool) == "workspace" {
            guard let root = peerDataRoot,
                  let scope = ChatToolSessionContext.verifiedSessionId ?? conversationScope, !scope.isEmpty else {
                return .object(["status": .string("unavailable"), "message": .string("Workspace needs a verified chat session. No action was performed.")])
            }
            // Admission to the facade is checked first. Each selected read or
            // send then re-enters the SAME complete chain under its real name
            // and complete arguments; workspace cannot confer its authority.
            let admission = try await dispatchExact(tool: tool, input: input, surface: surface)
            guard case .object(let prepared) = admission,
                  prepared["status"] == .string("prepared"),
                  prepared["execution"] == .string("requires_workspace_runtime") else { return admission }
            return try await AgentWorkspaceArrivals.$insideWorkspaceDispatch.withValue(true) {
              try await AgentWorkspaceReadiness.withSnapshot(dataRoot: root) {
              try await AgentWorkspace.dispatch(input: input, scope: scope, dataRoot: root,
                catalog: { try await self.inner.listAvailableToolSchemas() }) { name, arguments in
                let scoped = ChatToolSessionInjection.apply(toolName: name, input: arguments, sessionId: scope)
                return try await self.dispatch(tool: name, input: scoped, surface: surface)
              }
              }
            }
        }
        // Translate the conversational facade before every admission owner.
        // Both the facade policy and the actual executor policy remain visible.
        // Dotted facade aliases are deliberately unsupported: this context has
        // two policy identities, not three.
        let input = try namingSavedContact(tool, input)
        if Self.canonical(tool) == "bot_run_once", let root = peerDataRoot,
           let scope = ChatToolSessionContext.verifiedSessionId ?? conversationScope, !scope.isEmpty {
            return try await BotRunConversation.dispatch(input: input, surface: surface, scope: scope, dataRoot: root) { _, input in
                try await self.dispatchExact(tool: tool, input: input, surface: surface)
            }
        }
        if !AgentConversationContext.isInternalRead,
           ["agent_message", "agent_read"].contains(tool), let root = peerDataRoot,
           let scope = ChatToolSessionContext.verifiedSessionId ?? conversationScope, !scope.isEmpty {
            return try await AgentConversationSession.dispatch(tool: tool, input: input, surface: surface,
                scope: scope, dataRoot: root) { tool, input in
                    try await self.dispatchExact(tool: tool, input: input, surface: surface)
                }
        }
        return try await dispatchExact(tool: tool, input: input, surface: surface)
    }

    private func dispatchExact(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if let route = try AgentConversationRouting.route(tool: tool, input: input) {
            let alias = GatedToolNameAlias(raw: tool, canonical: route.tool)
            return try await GatedToolNameContext.$alias.withValue(alias) {
                let result = try await inner.dispatch(tool: route.tool, input: route.input, surface: surface)
                return AgentConversationRouting.wrap(result: result, route: route, input: input)
            }
        }
        let canonical = Self.canonical(tool)
        // 2026-09-06: canonicalizing before the gates threw away the spelling
        // the caller used, and the Trust Center matches override/block keys
        // against the name it is given — so a user's `"save.skill": "blocked"`
        // stopped applying. Carry the raw spelling down the chain so the policy
        // gates can judge both and keep the stricter answer. Bound even when
        // nothing was rewritten (as nil) so a nested dispatch cannot inherit a
        // stale alias.
        //
        // 2026-09-06: except when the alias already describes THIS dispatch.
        // The bridge wraps a gated client that begins with a canonicalizer of
        // its own, so the inner one is handed the canonical name, rewrites
        // nothing, and used to bind nil — erasing the raw spelling the outer
        // wrapper captured before the gates in between could read it. An
        // inherited alias whose canonical name is exactly the name we were
        // handed is this call's own alias; carry it through. Anything else is
        // a stale alias from an enclosing dispatch and still clears.
        let alias: GatedToolNameAlias?
        if canonical != tool {
            alias = GatedToolNameAlias(raw: tool, canonical: canonical)
        } else if let inherited = GatedToolNameContext.alias,
                  inherited.canonical.trimmingCharacters(in: .whitespaces)
                      == canonical.trimmingCharacters(in: .whitespaces) {
            alias = inherited
        } else {
            alias = nil
        }
        return try await GatedToolNameContext.$alias.withValue(alias) {
            try await inner.dispatch(tool: canonical, input: input, surface: surface)
        }
    }

    public func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools()
    }

    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas()
    }
}

// MARK: - File-access wrapping dispatcher

/// Wraps a ToolDispatchClient and rejects calls to a hard-coded set of
/// filesystem / shell tool name prefixes when fileAccess == "none".
/// Honest carve: we do not introspect tool metadata for "writes_fs" — we
/// gate by name prefix, which is the same coarse rule the daemon uses
/// when fileAccess=none is asserted upstream.
final class FileAccessGatedDispatcher: ToolDispatchClient, PreApprovalToolValidating, @unchecked Sendable {
    private let inner: any ToolDispatchClient
    private let mode: Mode

    /// This wrapper adds no pre-approval rules; it carries the inner
    /// dispatcher's through, since the approval membrane wraps it and would
    /// otherwise see nothing to ask.
    func preApprovalRefusal(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> JSONValue? {
        guard let validating = inner as? any PreApprovalToolValidating else { return nil }
        return await validating.preApprovalRefusal(tool: tool, input: input, surface: surface)
    }

    func approvalCardReason(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> String? {
        guard let validating = inner as? any PreApprovalToolValidating else { return nil }
        return await validating.approvalCardReason(tool: tool, input: input, surface: surface)
    }

    private enum Mode: Equatable {
        case none
        case readOnly
        case allow
    }

    init(inner: any ToolDispatchClient, fileAccess: String) {
        self.inner = inner
        switch fileAccess.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "workspace", "auto", "full":
            self.mode = .allow
        case "read_only", "readonly", "read-only":
            self.mode = .readOnly
        case "none", "off", "disabled":
            self.mode = .none
        default:
            // 2026-07-21 audit fix: an unset/empty string used to map to
            // .allow (the "" case above), silently opening the file gate for
            // any caller forwarding an empty config value. Unknown/empty now
            // fails closed like every other unrecognized value.
            self.mode = .none
        }
    }

    // HOTFIX 2026-06-03: prefix list was dot-namespaced only ("fs.", "file.",
    // "shell.") which missed the new snake_case tools (`read_file`,
    // `list_dir`) the SwiftToolDispatcher exposes — fileAccess=none was
    // letting them through. Also added exact names + snake_case prefixes.
    private static let blockedPrefixes: [String] = [
        "fs.", "file.", "files.", "read.", "write.", "shell.", "bash.", "exec.",
        // snake_case forms the SwiftToolDispatcher built-in set uses:
        "read_file", "write_file", "list_dir", "list_directory",
        "read_skill", "shell_", "bash_", "exec_",
    ]
    private static let blockedExact: Set<String> = [
        "read_file", "list_dir", "read_skill", "list_skills", "save_skill",
        "get_persona_doc", "persona_read", "persona_write", "persona_append_section",
        // agent-builder-tools (2026-06-08) — defense in depth. Builder
        // Process-spawn tools must never dispatch when fileAccess=none.
        "shell", "bash", "git", "apply_patch", "run_tests",
        "swift_build", "swift_test",
        // restart_app (2026-06-10) — process_spawn + app termination.
        // Defense in depth: even if a refactor ever moves its schema out of
        // the Full-Mac block, fileAccess=none keeps it unreachable.
        "restart_app", "install_app",
        // evolution chat tools (2026-06-11, U2b) — defense in depth. The
        // propose/withdraw/install tools mutate the EvolutionProposalStore +
        // stage an install card; even the read-only status tool stays denied
        // here so fileAccess=none keeps the whole evolution surface unreachable.
        "evolution_propose", "evolution_status", "evolution_withdraw", "self_install",
        // 2026-07-31 audit fix: the Full-Mac file/git read tools
        // (SwiftToolDispatcher.fullMacFileToolNames + the git group) matched
        // neither blockedExact nor any blockedPrefix, so fileAccess=none was
        // letting six real filesystem/repo readers through. `write_file` was
        // already covered by prefix. These stay PERMITTED under .readOnly —
        // they are reads, and read_only exists to allow exactly this.
        "file_excerpt", "grep",
        "git_status", "git_diff", "git_log", "repo_dirty_summary",
        // W2/W3 (2026-08-12) — INPUT INJECTION. Defense in depth: a session
        // with no file access has no business synthesizing keystrokes or
        // clicks either, and a keystroke IS a route to arbitrary file access
        // (type into a terminal). Blocked in both restricted modes.
        // W6 `mac_wake` joins them: it posts input, and a session with no file
        // access has no business synthesizing any.
        // USER 2026-08-12 — YOLO: "Nothing should be approval gated for her.
        // Nothing." The Mac motor tools are removed from the read_only
        // blocklist at his explicit direction so they work on the bridge and
        // other non-interactive surfaces. Full Mac + the accessibility category
        // + the macOS TCC grant remain their real gates.
        // (was: "mac_keystroke", "mac_click", "mac_scroll", "mac_ax_act", "mac_wake",)
    ]
    private static let readOnlyBlockedPrefixes: [String] = [
        "write.", "write_", "shell.", "shell_", "bash.", "bash_", "exec.", "exec_",
        // 2026-06-08 NARROWED from broad `mac_` to `mac_write_` only. The
        // previous prefix caught legitimate read tools like
        // mac_reminders_list_due_today / mac_calendar_list_upcoming /
        // mac_contacts_search / mac_mail_list_recent — all READ-tier
        // tools that Claude legitimately uses through the bridge in
        // read_only mode. The destructive mac_ tools (focus_app /
        // quit_app / set_volume / sleep_display / lock_screen /
        // run_shortcut) are now listed explicitly in
        // readOnlyBlockedExact below.
        "mac_write_",
    ]
    private static let readOnlyBlockedExact: Set<String> = [
        "write_file", "file_write", "apply_patch", "run_tests",
        "swift_build", "swift_test",
        // agent-builder-tools (2026-06-08) — even in read_only mode,
        // process-spawn / git mutators / arbitrary shell stay denied.
        "shell", "bash", "git",
        // restart_app (2026-06-10) — read_only must never bounce the app.
        "restart_app", "install_app",
        // evolution chat tools (2026-06-11, U2b) — even in read_only mode the
        // proposal-store mutators and the install-card stager stay denied.
        // status is read-only but listed for parity / catalog-drift defense.
        "evolution_propose", "evolution_status", "evolution_withdraw", "self_install",
        // USER YOLO 2026-08-12: mac_focus_app / mac_quit_app freed too.
        // (was: "mac_focus_app", "mac_quit_app",)
        // W1b/W3.5 — mac_ax_status / mac_ax_tree / mac_ax_find / mac_view are
        // deliberately NOT listed here. read_only exists to allow exactly this
        // class: they read the on-screen AX tree (and, for mac_view, take a
        // picture of it) and mutate nothing. They are likewise absent
        // from blockedExact/blockedPrefixes above — AX perception is not file
        // access, so fileAccess=none does not bear on it; the Trust Center
        // accessibility category remains their real gate.
        // USER YOLO 2026-08-12: the remaining mac system tools freed.
        // (was: "mac_set_volume", "mac_sleep_display", "mac_lock_screen", "mac_run_shortcut",)
        // W7 — mac_nudge is likewise NOT listed. read_only exists to prevent
        // writes; moving the cursor one point writes nothing — it cannot
        // click, type, scroll or drag, so there is no write for the mode to
        // prevent. It sits with the AX reads, not with the four below.
        //
        // W2/W3 — INPUT INJECTION. read_only exists to allow READS; typing and
        // clicking are the opposite of that, and a synthesized keystroke can
        // reach any write the mode is trying to prevent. Denied.
        // W6 `mac_wake` too — the view it returns is not what makes it a write,
        // the mouse event it posts is.
        // USER 2026-08-12 — YOLO: "Nothing should be approval gated for her.
        // Nothing." The Mac motor tools are removed from the read_only
        // blocklist at his explicit direction so they work on the bridge and
        // other non-interactive surfaces. Full Mac + the accessibility category
        // + the macOS TCC grant remain their real gates.
        // (was: "mac_keystroke", "mac_click", "mac_scroll", "mac_ax_act", "mac_wake",)
        // W7 — `activity_query` is deliberately NOT listed here, and its
        // absence is not an oversight. This wrapper gates on fileAccess MODE,
        // which is the wrong axis for it: the tool is refused by SURFACE, not
        // by mode, and read_only sessions on the Mac are exactly who should be
        // able to ask it. The Mac-local refusal lives in
        // `impl_activity_query_tool`, which throws an explicit
        // `toolDenied` naming the surface — an EXPLICIT refusal, per the
        // build-plan W7 decision, rather than a silent 404 that would read as
        // "this tool does not exist" from the phone.
        // `ActivityQueryToolReachabilityTests` pins that refusal.
        "persona_write", "persona_append_section", "save_skill",
    ]

    private func isBlocked(_ name: String) -> Bool {
        let lower = name.lowercased()
        switch mode {
        case .allow:
            return false
        case .none:
            if Self.blockedExact.contains(lower) { return true }
            for p in Self.blockedPrefixes where lower.hasPrefix(p) { return true }
        case .readOnly:
            if Self.readOnlyBlockedExact.contains(lower) { return true }
            for p in Self.readOnlyBlockedPrefixes where lower.hasPrefix(p) { return true }
        }
        return false
    }

    /// User, 2026-09-06: `read` with an explicit `path` OPENS A FILE OFF DISK,
    /// and the name-only blocklists missed it — `"read."` is a namespace
    /// prefix, and bare `read` is in neither exact set — so fileAccess=none
    /// was defeated by the one tool whose name is a bare verb. With NO path it
    /// reads the front window through accessibility, which is not file access
    /// and stays reachable; only the pathful call is refused, and only in the
    /// mode that means "no files at all".
    private func isPathfulReadUnderNoFileAccess(
        tool: String, input: [String: JSONValue]
    ) -> Bool {
        guard mode == .none, tool.lowercased() == "read" else { return false }
        guard case .string(let path)? = input["path"] else { return false }
        return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if isPathfulReadUnderNoFileAccess(tool: tool, input: input) {
            throw AutonomyGateError.toolDenied(
                reason: "fileAccess=none blocks \(tool) with an explicit path; "
                    + "call it with no path to read what is on screen"
            )
        }
        if isBlocked(tool) {
            // Name the ACTUAL mode — this gate also fires for read_only, and
            // the old hardcoded "fileAccess=none" string lied in that case.
            let modeName = mode == .readOnly ? "read_only" : "none"
            throw AutonomyGateError.toolDenied(reason: "fileAccess=\(modeName) blocks \(tool)")
        }
        // User, 2026-09-06: refusing the pathful `read` above is only half of
        // it — the PATHLESS one asks the front window for its `AXDocument` and
        // opens THAT file, a path this gate never sees because it does not
        // exist yet when the gate runs. Carry the mode down so the Mac read
        // organ can decline an inferred path under `none` and read the window's
        // AX text instead. Nothing below reads it in the other two modes.
        return try await MacControlTurnFileAccess.$deniesFileReads.withValue(mode == .none) {
            try await inner.dispatch(tool: tool, input: input, surface: surface)
        }
    }

    func listAvailableTools() async throws -> [String] {
        let all = try await inner.listAvailableTools()
        if mode == .allow { return all }
        return all.filter { !isBlocked($0) }
    }

    // Forward schemas when permitted; filter blocked tools by fileAccess mode.
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        let all = try await inner.listAvailableToolSchemas()
        if mode == .allow { return all }
        return all.filter { !isBlocked($0.name) }
    }
}

// MARK: - Per-turn tool session context

/// Carries the per-turn verified session id down the tool-dispatch chain so
/// inner app-side dispatchers can reconstruct the SAME security origin (and
/// thus the same trust resolution) that the authoritative `AutonomyGatedDispatcher`
/// already computed.
///
/// Why this exists: `ToolDispatchClient.dispatch(tool:input:surface:)` threads
/// only the surface, not the session. `AutonomyGatedDispatcher` captures the
/// verified session id at construction (per-turn) and is the authoritative
/// security gate. But `AppChatToolDispatcher` (app target) sits BELOW it and is
/// constructed once per client — with no session, its own `evaluateTool` call
/// hardcoded `sessionId: nil`, so for a TRUSTED remote surface (allowlisted
/// Telegram) it could not resolve the chatId, failed the allowlist match, and
/// FALSE-BLOCKED an invoke the authoritative gate had already approved
/// (security/audit.jsonl 2026-06-09 19:24, surface=telegram, sessionId nil).
///
/// `AutonomyGatedDispatcher` binds this TaskLocal around its `inner.dispatch`
/// call, so any downstream dispatcher reads the real session and resolves trust
/// identically. Nil when no gated chain is in play (e.g. read-only catalog
/// refresh), which is correct — those paths carry no remote session.
public enum ChatToolSessionContext {
    public struct ReplyRoute: Sendable, Equatable {
        public let surface: String
        public let destinationId: String?
        public let threadId: String?
        public let sourceKey: String?
        public let replyTo: String?
        public let correlationId: String?

        public init(
            surface: String,
            destinationId: String? = nil,
            threadId: String? = nil,
            sourceKey: String? = nil,
            replyTo: String? = nil,
            correlationId: String? = nil
        ) {
            self.surface = surface
            self.destinationId = destinationId
            self.threadId = threadId
            self.sourceKey = sourceKey
            self.replyTo = replyTo
            self.correlationId = correlationId
        }

        /// Whether this route ends at a surface that can DRAW an inline card.
        ///
        /// Only the Mac and iPhone chat UIs render the card; the Mac's own
        /// in-process turn carries no route at all, which is why a nil route is
        /// treated as the UI (see `rendersInlineCards(_:)` below). Every other
        /// route — Telegram, Slack, the bridge — is text and nothing else, and
        /// a card sent there must be said in prose or it arrives as silence.
        ///
        /// It keys on the ROUTE, never on `surface:` as passed to `chat(…)`:
        /// the Claude bridge deliberately calls in as surface "chat" and
        /// carries its real destination only here.
        public var rendersInlineCards: Bool {
            switch surface.lowercased() {
            case "chat", "mac", "app", "ios", "iphone", "ipad", "icloud": true
            default: false
            }
        }
    }

    /// The turn's route, answered for the ABSENT case too: a Mac chat turn runs
    /// in-process and binds no route, and it is the one surface that has always
    /// been able to draw the card.
    public static func rendersInlineCards(_ route: ReplyRoute?) -> Bool {
        route?.rendersInlineCards ?? true
    }

    /// True while the turn is being consumed as a STREAM by a chat UI.
    ///
    /// Bound by the stream facade, which is what the Mac and iPhone chat views
    /// consume. Telegram, Slack and the bridge all call the non-streaming
    /// `chat(…)` and read `ChatResponse.output`, so they never see this set —
    /// which is a structural fact about how they consume a turn, not a string
    /// anyone can spell wrong.
    @TaskLocal public static var replyStreamRendersCards: Bool = false

    /// Whether this turn's only way to say something is TEXT.
    ///
    /// Both signals must agree before prose is withheld: the turn is being
    /// streamed to a UI, AND the route ends at a surface that draws cards. The
    /// belt and braces are deliberate — the Claude bridge calls in as surface
    /// "chat" and may carry no route at all, and getting this wrong in that
    /// direction is exactly the silence this guards against.
    public static var replyIsTextOnly: Bool {
        !(replyStreamRendersCards && rendersInlineCards(replyRoute))
    }

    /// The per-turn envelope. See `TurnEnvelope` below — this is the ONE
    /// value a new surface adapter fills in, and every field below is its
    /// projection. Bound by the transport around its `chat()` call.
    ///
    /// Nil for turns whose surface predates the envelope; the individual
    /// task-locals below remain the authority in that case, so an adapter can
    /// migrate without a flag day.
    @TaskLocal public static var envelope: TurnEnvelope?

    @TaskLocal public static var verifiedSessionId: String?

    /// The transport-verified remote chat identifier (e.g. Telegram chatId),
    /// set by the remote transport around its `chat()` call. Trust resolution
    /// for Telegram matches the allowlist on this id. We carry it explicitly
    /// because the chatId is NOT always recoverable from the session id string:
    /// the legacy session form is `telegram:<chatId>`, but a `/new` session is a
    /// bare UUID. Without this, an allowlisted Telegram chat on a UUID session
    /// derives `chatId=nil` in BOTH gates and high-risk invokes false-block.
    /// Nil for local/Mac surfaces (no remote id) and for iOS (trust is
    /// policy-based, not id-based) — both correct.
    @TaskLocal public static var verifiedChatId: String?

    /// The transport-verified remote USER identifier (e.g. Slack user id),
    /// set by the remote transport around its `chat()` call. Trust resolution
    /// for Slack can match the user allowlist on this id — without it the
    /// origin builders set userId=nil and a user-only allowlisted sender
    /// transport-accepts but stays high-risk-untrusted (gpt-5.5 review
    /// 2026-07-21). Nil where no per-user trust root exists.
    @TaskLocal public static var verifiedUserId: String?

    /// True when the inbound remote transport has already verified provenance
    /// for this turn. Socket Mode Slack events arrive over a preauthenticated
    /// WebSocket rather than per-event signed HTTP requests; the transport binds
    /// this after it has opened the app-token socket.
    @TaskLocal public static var commandSignatureVerified: Bool?

    /// Immutable return route for work that finishes after the originating
    /// turn has ended. Async agent bridges persist this with their job rather
    /// than trying to rediscover a Telegram chat, Slack thread, or iOS device
    /// from mutable current-surface state at completion time.
    @TaskLocal public static var replyRoute: ReplyRoute?

    /// Bind the turn's return route AND mirror its delivery identity onto the
    /// turn-trace context in one call, so the rows this turn writes name the
    /// conversation it came from.
    ///
    /// 2026-09-13: the trace row was the only record of where Agent last was,
    /// and it carried surface and session but never destination or thread — so
    /// a knock that could have gone back to the Telegram topic or Slack thread
    /// it came from always fell back to the phone. Binding both together is
    /// what keeps a surface from setting one and forgetting the other.
    public static func withReplyRoute<T>(
        _ route: ReplyRoute,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $replyRoute.withValue(route) {
            try await TurnTraceContext.$destinationId.withValue(route.destinationId) {
                try await TurnTraceContext.$threadId.withValue(route.threadId) {
                    try await operation()
                }
            }
        }
    }
}


// MARK: - TurnEnvelope (the per-turn surface contract)

/// EVERYTHING one turn's surface identity consists of, in one value.
///
/// # How to add a surface
///
/// NativeAgent is built so a new messaging surface — Signal, WhatsApp, a
/// device, anything — can be connected later. This type is the contract that
/// makes that a small job. A new adapter does exactly three things and touches
/// nothing outside itself:
///
/// 1. **Bind identity.** Build a `TurnEnvelope` naming its `surface` and the
///    identifiers its transport ACTUALLY VERIFIED — `verifiedChatId` (the
///    conversation) and/or `verifiedUserId` (the person) — and bind it around
///    its `chat()` call with `ChatToolSessionContext.$envelope.withValue(_:)`.
///    Whatever the transport could not verify stays nil. Nil is honest and
///    fails closed; a guess is neither.
/// 2. **Provide a delivery route.** Fill `deliveryRoute` so a completion that
///    lands after the originating loop has moved on still knows where to go.
///    `replyRoute` is this envelope's delivery projection, so every existing
///    `ChatToolSessionContext.replyRoute` consumer keeps working unchanged.
/// 3. **Publish an anchor**, if the surface is a direct conversation with the
///    human rather than a shared room — see `ConversationAnchor` in
///    PersistenceCore. That is a one-line call and it is surface-agnostic:
///    the Mac and the phone consume the anchor without knowing which surface
///    published it.
///
/// There is no fourth step. In particular an adapter must NOT encode identity
/// into the session id and expect a gate to parse it back out. Five sites used
/// to do that (plan §1.2); all five are deleted. The session id is a storage
/// key — path-safe, opaque, and evidence of nothing.
///
/// # Two invariants this type exists to hold
///
/// **A tool call's authority comes from the CURRENT turn's envelope, never
/// from any envelope in history.** History rows are prose plus provenance
/// labels; they grant nothing. A Mac-authored (local, trusted) turn can sit
/// three rows above a remote allowlist-gated turn in the same transcript, and
/// the remote turn is still assessed alone.
///
/// **Surface never widens.** `isRemote` is derived from the surface profile
/// and can be ADDED to an unknown surface but never SUBTRACTED from a
/// known-remote one. That rule is enforced generically in
/// `SecurityCenter.assessOrigin` against `ConversationSurfaceProfile`, so it
/// covers a surface added tomorrow exactly as it covers the ones here today.
public struct TurnEnvelope: Sendable, Equatable {
    /// The immutable return route for work that finishes after the
    /// originating turn has ended. Kept as its own value because it is the
    /// half of the envelope that must be DURABLE on the message row.
    public typealias DeliveryRoute = ChatToolSessionContext.ReplyRoute

    /// Raw surface name, as the adapter calls itself ("telegram", "slack",
    /// "signal", "chat"). Normalization to a canonical profile happens at the
    /// trust boundary, not here — this field records what the adapter said.
    public let surface: String
    /// Bridge lane, when the turn arrived through an agent bridge
    /// ("claude", "codex"). Generalizes the existing `metadata.origin.agent`.
    public let agent: String?
    /// The conversation identifier the TRANSPORT verified. Nil when the
    /// transport has no such notion (a local window) or could not verify one.
    public let verifiedChatId: String?
    /// The person identifier the TRANSPORT verified. Nil as above.
    public let verifiedUserId: String?
    /// True when the inbound transport has already verified provenance for
    /// this turn by its own scheme (a signed request, a preauthenticated
    /// socket). Nil means "no such scheme", which is not the same as false.
    public let commandSignatureVerified: Bool?
    /// Where this turn's reply goes, and nowhere else.
    public let deliveryRoute: DeliveryRoute?
    /// Explicit remoteness for a surface the profile does not know yet. It can
    /// only ADD remoteness — see the widening invariant above.
    public let declaredRemote: Bool?

    public init(
        surface: String,
        agent: String? = nil,
        verifiedChatId: String? = nil,
        verifiedUserId: String? = nil,
        commandSignatureVerified: Bool? = nil,
        deliveryRoute: DeliveryRoute? = nil,
        declaredRemote: Bool? = nil
    ) {
        self.surface = surface
        self.agent = agent
        self.verifiedChatId = Self.cleaned(verifiedChatId)
        self.verifiedUserId = Self.cleaned(verifiedUserId)
        self.commandSignatureVerified = commandSignatureVerified
        self.deliveryRoute = deliveryRoute
        self.declaredRemote = declaredRemote
    }

    /// The delivery projection. `ReplyRoute` predates the envelope and has
    /// many consumers; keeping it as a projection rather than replacing it is
    /// what lets Phase 1 land without touching them.
    ///
    /// Falls back to a route carrying just the surface so a caller that bound
    /// an envelope but no explicit route still gets an honest surface tag.
    public var replyRoute: DeliveryRoute {
        deliveryRoute ?? DeliveryRoute(surface: surface)
    }

    /// The durable shape written to `metadata.envelope` on every message row.
    ///
    /// `trusted` is NOT included and must never be: a persisted trust verdict
    /// would be exactly the "authority from history" this type forbids. The
    /// row records WHO and WHERE, and the gate re-decides every turn.
    public func persistedMetadata() -> JSONValue {
        var object: [String: JSONValue] = ["surface": .string(surface)]
        func put(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            object[key] = .string(value)
        }
        put("agent", Self.cleaned(agent))
        put("chatId", verifiedChatId)
        put("userId", verifiedUserId)
        put("destinationId", Self.cleaned(deliveryRoute?.destinationId))
        put("threadId", Self.cleaned(deliveryRoute?.threadId))
        put("sourceKey", Self.cleaned(deliveryRoute?.sourceKey))
        put("replyTo", Self.cleaned(deliveryRoute?.replyTo))
        put("correlationId", Self.cleaned(deliveryRoute?.correlationId))
        return .object(object)
    }

    /// Rebuild an envelope from a persisted row. Provenance only — the result
    /// is a LABEL for a reader, never an authorization for a tool call.
    public static func fromPersistedMetadata(_ value: JSONValue?) -> TurnEnvelope? {
        guard case .object(let object)? = value else { return nil }
        func read(_ key: String) -> String? {
            guard case .string(let string)? = object[key] else { return nil }
            return cleaned(string)
        }
        guard let surface = read("surface") else { return nil }
        let route = ChatToolSessionContext.ReplyRoute(
            surface: surface,
            destinationId: read("destinationId"),
            threadId: read("threadId"),
            sourceKey: read("sourceKey"),
            replyTo: read("replyTo"),
            correlationId: read("correlationId")
        )
        return TurnEnvelope(
            surface: surface,
            agent: read("agent"),
            verifiedChatId: read("chatId"),
            verifiedUserId: read("userId"),
            deliveryRoute: route
        )
    }

    /// Assemble the envelope for the turn in flight.
    ///
    /// Prefers an explicitly bound envelope; otherwise composes one from the
    /// individual `ChatToolSessionContext` task-locals the pre-envelope
    /// adapters already bind. That fallback is what makes Phase 1 additive:
    /// nothing has to migrate on the same day.
    public static func current(surface: String) -> TurnEnvelope {
        if let bound = ChatToolSessionContext.envelope {
            return bound
        }
        return TurnEnvelope(
            surface: surface,
            verifiedChatId: ChatToolSessionContext.verifiedChatId,
            verifiedUserId: ChatToolSessionContext.verifiedUserId,
            commandSignatureVerified: ChatToolSessionContext.commandSignatureVerified,
            deliveryRoute: ChatToolSessionContext.replyRoute
        )
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Exact, single-dispatch evidence that a human already approved the persisted
/// chat-tool request being replayed. This is deliberately not a general
/// autonomy override: it only prevents `PersonaWriteGuard` from asking the
/// same confirmation question twice when every approved payload and verified
/// origin field still matches. SecurityCenter, file access, and the tool's own
/// effect-time validation continue to run normally.
///
/// W2/W3-FIX-R2 1 — THIS TYPE CARRIES NO AUTHORITY OF ITS OWN. It is a public
/// value type with a public init (the post-approval executor lives in the app
/// target and has to be able to build one), so `matches` proves only that the
/// CALLER's fields agree with the CALLER's call. For an injection tool that is
/// not enough and never was: the dispatcher now takes this struct as a POINTER
/// to an approval record and asks `InjectionApprovalVerifying` whether that
/// record exists, is resolved-approved, is for this tool + surface + body, and
/// is unspent — before the floor exemption and before the mint. A forged
/// struct with a made-up id gets no exemption and mints nothing.
public struct ApprovedChatToolReplay: Sendable, Equatable {
    public let approvalID: String
    public let tool: String
    public let surface: String
    public let input: [String: JSONValue]
    public let verifiedSessionID: String?
    public let verifiedChatID: String?
    public let verifiedUserID: String?

    public init(
        approvalID: String,
        tool: String,
        surface: String,
        input: [String: JSONValue],
        verifiedSessionID: String?,
        verifiedChatID: String?,
        verifiedUserID: String?
    ) {
        self.approvalID = approvalID
        self.tool = tool
        self.surface = surface
        self.input = input
        self.verifiedSessionID = verifiedSessionID
        self.verifiedChatID = verifiedChatID
        self.verifiedUserID = verifiedUserID
    }

    fileprivate func matches(
        tool: String,
        surface: String,
        input: [String: JSONValue],
        verifiedSessionID: String?
    ) -> Bool {
        // 2026-09-06: the executor builds this from the PERSISTED tool name
        // (`save.skill`), and the outer canonicalizer rewrites the dispatched
        // name (`save_skill`) before this comparison — a pre-upgrade dotted
        // approval was consumed and then rejected. Compare canonical names.
        !approvalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && CanonicalToolNameDispatcher.canonical(self.tool)
                == CanonicalToolNameDispatcher.canonical(tool)
            && self.surface == surface
            && self.input == input
            && self.verifiedSessionID == verifiedSessionID
            && verifiedChatID == ChatToolSessionContext.verifiedChatId
            && verifiedUserID == ChatToolSessionContext.verifiedUserId
    }
}

/// Per-turn runtime facts the tool loop binds so in-process tools can report
/// what's actually generating the current turn. `agent_introspect` reads this
/// to answer "which model/provider is running me right now" accurately — the
/// live turn model can differ from the surface's configured model (a per-turn
/// override), and the surface lets it resolve the real active provider. Nil
/// when a tool runs outside a chat turn (e.g. a direct dispatch), in which case
/// introspect falls back to the configured model.
public enum ChatTurnRuntimeContext {
    public struct Active: Sendable {
        public let model: String
        public let surface: String
        public let personaID: String?
        /// Exact provider/auth transport admitted for this turn. Keep this
        /// separate from model-family inference: API key, OAuth-direct,
        /// OpenRouter, and Codex may expose overlapping model names.
        public let providerID: String?
        public init(
            model: String,
            surface: String,
            personaID: String? = nil,
            providerID: String? = nil
        ) {
            self.model = model
            self.surface = surface
            self.personaID = personaID
            self.providerID = providerID
        }
    }
    @TaskLocal public static var current: Active?
}

/// Single source of truth for injecting the per-turn session id into tool input
/// before dispatch, so the LLM doesn't have to remember to pass it. Both the
/// structured tool loop AND the Anthropic text-compat tool loop call this — an
/// earlier divergence (the text-compat copy lacked the tool_load/tool_catalog
/// auto-fill) meant claude-* chats — the user's whole setup — bounced lazy-loads with
/// missing_session_id. Keep this the ONLY implementation.
enum ChatToolSessionInjection {
    static func apply(
        toolName: String,
        input: [String: JSONValue],
        sessionId: String?
    ) -> [String: JSONValue] {
        guard let sessionId,
              !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return input
        }
        // Always inject __session_id so the dispatcher's lazy-load gate and
        // tool_catalog/tool_load/tool_unload have access without the LLM
        // having to remember to pass it.
        var out = input
        out["__session_id"] = .string(sessionId)
        if toolName == "scratchpad_read" {
            out["session_id"] = .string(sessionId)
            out["sessionId"] = .string(sessionId)
        }
        if toolName == "recent_trace_summary",
           out["session_id"] == nil,
           out["sessionId"] == nil {
            out["session_id"] = .string(sessionId)
        }
        if toolName == "search_chat_history" || toolName == "session_search" {
            out["current_session_id"] = .string(sessionId)
        }
        if toolName == "tool_load" || toolName == "tool_unload" || toolName == "tool_catalog" || toolName == "tool_result_page" {
            // Auto-fill session_id so the LLM doesn't have to remember it.
            let hasSession: Bool = {
                if case .string(let s) = out["session_id"] ?? .null,
                   !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
                return false
            }()
            if !hasSession {
                out["session_id"] = .string(sessionId)
            }
        }
        return out
    }
}

// MARK: - AutonomyGate-wrapping dispatcher

/// Routes every tool dispatch through an AutonomyGate decision BEFORE
/// invoking the inner dispatcher. On `.deny`, throws AutonomyGateError so
/// the tool loop records it as a tool-result error and continues (mirrors
/// the loop's failure-recovery behavior).
final class AutonomyGatedDispatcher: ToolDispatchClient, @unchecked Sendable {
    private let inner: any ToolDispatchClient
    private let gate: AutonomyGate
    private let approvalFiler: (any ApprovalFiler)?
    private let securityCenter: SwiftNativeSecurityCenter
    private let hasFiler: Bool
    private let approvalTimeoutSeconds: Double
    private let verifiedSessionId: String?
    private let approvedReplay: ApprovedChatToolReplay?
    /// W2/W3-FIX-R2 1. The authority behind every injection approval id this
    /// dispatcher acts on. Nil ⇒ injection tools cannot run at all (fail
    /// closed), which is the correct posture for a raw/noninteractive chain.
    private let injectionApprovalVerifier: (any InjectionApprovalVerifying)?
    /// 2026-09-06. The same authority for every OTHER tool's replay: the
    /// approval id must resolve to a real, approved, this-tool/this-body record
    /// that the executor spent moments ago, and it is good for exactly one
    /// dispatch. Nil ⇒ no replay exemption is granted at all (fail closed).
    private let approvedReplayVerifier: (any ApprovedReplayVerifying)?
    /// Whether an external `mcp__*` tool has effects, per the MCP registry's
    /// own per-tool risk metadata. Used only on peer turns. Nil ⇒ every
    /// external tool is treated as effectful (fail closed).
    private let externalToolIsEffect: (@Sendable (String) -> Bool)?
    /// The data root whose persona documents a first-conversation write would
    /// target — supplied ONLY by the Mac chat dispatcher, and nil on every
    /// other chain (bridge, background, ephemeral, approval replay), which is
    /// what keeps the exemption on one surface (Sol P0-1). Nil ⇒ refused
    /// outright; it is never inferred from a process-wide default, because an
    /// exemption that guesses which persona it is exempting is not scoped.
    /// See `FirstConversationPersonaExemption`.
    private let firstConversationDataRoot: URL?
    /// The data root holding the peer address book (`agents/peers.json`), so a
    /// credential-verified peer id can be shown to the person as the NAME she
    /// gave it in Trust → Connected agents. DISPLAY ONLY — nothing here grants
    /// authority, and a nil root simply falls back to the id.
    private let peerDirectoryDataRoot: URL?

    /// The peer's contact name, or nil when the directory has none.
    private func peerDisplayName(peerID: String?) -> String? {
        guard let peerID, !peerID.isEmpty, let root = peerDirectoryDataRoot,
              let peer = try? AgentPeerStore(dataRoot: root).list()
                .first(where: { $0.id == peerID })
        else { return nil }
        let name = peer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
    private static let approvalStagingToolNames: Set<String> = [
        "agentmail.send",
        "agentmail_send",
        "slack.post_message",
        "slack_post_message",
    ]

    /// Test seam for `macInjection_areNotApprovalStagingTools`, which pins that
    /// no injection tool ever joins this set — membership means "dispatch
    /// without waiting for the approval", which for an injection tool would be
    /// a bypass.
    static var approvalStagingToolNamesForTesting: Set<String> { approvalStagingToolNames }

    init(
        inner: any ToolDispatchClient,
        gate: AutonomyGate,
        approvalFiler: (any ApprovalFiler)? = nil,
        securityCenter: SwiftNativeSecurityCenter = SwiftNativeSecurityCenter(),
        hasFiler: Bool = false,
        approvalTimeoutSeconds: Double = 30,
        verifiedSessionId: String? = nil,
        approvedReplay: ApprovedChatToolReplay? = nil,
        injectionApprovalVerifier: (any InjectionApprovalVerifying)? = nil,
        approvedReplayVerifier: (any ApprovedReplayVerifying)? = nil,
        externalToolIsEffect: (@Sendable (String) -> Bool)? = nil,
        firstConversationDataRoot: URL? = nil,
        peerDirectoryDataRoot: URL? = nil
    ) {
        self.externalToolIsEffect = externalToolIsEffect
        self.firstConversationDataRoot = firstConversationDataRoot
        self.peerDirectoryDataRoot = peerDirectoryDataRoot
        self.approvedReplayVerifier = approvedReplayVerifier
        self.inner = inner
        self.gate = gate
        self.approvalFiler = approvalFiler
        self.securityCenter = securityCenter
        self.hasFiler = hasFiler
        self.approvalTimeoutSeconds = approvalTimeoutSeconds
        self.verifiedSessionId = verifiedSessionId
        self.approvedReplay = approvedReplay
        self.injectionApprovalVerifier = injectionApprovalVerifier
    }

    private static func requiresDesktopInteraction(tool: String, capabilities: [String]) -> Bool {
        let name = tool.replacingOccurrences(of: ".", with: "_")
        if name.hasPrefix("bot_") || name.hasPrefix("shelf_") { return false }
        return !Set(capabilities).isDisjoint(with: ["ax_injection", "hid_injection", "browser_interaction", "notification", "system_control", "shell", "process_spawn"])
            || ["browser_open_url", "browser_navigate", "browser_chrome_acquire", "browser_chrome_navigate",
                "browser_chrome_scroll", "mac_activate_app", "app_activate", "speak", "voice_speak", "sound_play"].contains(name)
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if surface == "bot", let pending = ChatTurnExecution.current?.pendingApproval { return pending }
        return try await inner.withToolArguments(tool: tool, input: input) { input in
            try await dispatchNormalized(tool: tool, input: input, surface: surface)
        }
    }

    private func dispatchNormalized(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // W2/W3-FIX-R2 2 — SecurityCenter PERSISTS what it evaluates.
        // `evaluateTool` builds `redactedInputPreview` from this argument and
        // `record` appends it to security/audit.jsonl; its own redactor is
        // generic (secret-SHAPED strings and secret-NAMED keys), and
        // `mac_keystroke.text` / `mac_ax_act.value` are neither — "hunter2" is
        // an ordinary short string under an ordinary key name. So the literal
        // characters were landing in an unencrypted, long-lived audit file
        // BEFORE the approval filer's redaction ever ran. The gate needs the
        // tool, the origin and the argument SHAPE, not the characters: it gets
        // the same count+digest form the approval record stores. SecurityCenter
        // redacts again for itself (defense in depth) — this is the call site
        // making sure the raw form never crosses the boundary in the first
        // place.
        let namedConnect = AgentHostConnection.isNamedConnect(tool: tool, input: input)
        let input: [String: JSONValue] = {
            var bound = input
            // Preserve the exact disclosed path on replay, even when it was absent.
            if namedConnect, approvedReplay == nil {
                bound.removeValue(forKey: "executable_path")
                if case .string(let name)? = input["name"],
                   let line = AgentHostDirectory.row(named: name)?.commandLine,
                   let path = AgentHostCommandLines.resolveExecutable(line.executable) {
                    bound["executable_path"] = .string(path)
                }
            }
            return bound
        }()
        let securityInput = MacInjectionArgRedaction.redacted(tool: tool, input: input)
        let envelope = await securityCenter.evaluateTool(
            tool: tool,
            input: securityInput,
            origin: Self.securityOrigin(
                verifiedSessionId: verifiedSessionId,
                surface: surface
            ),
            enforceAutonomy: false
        )
        // 2026-07-21 audit fix: only .block hard-denies here. A security .ask
        // (external_send gate, injection shield) previously fell into this
        // same throw because `allowed == (decision == .allow)` — a hard
        // denial BEFORE any approval path ran, leaving mail_send/messages_send
        // structurally dead and the defaultToolAutonomy "mail_*": "auto"
        // entries unable to take effect. .ask now routes into the
        // requireApproval flow below (filer / resolveWithApproval / honest
        // no-filer deny), exactly like an autonomy-level requireApproval.
        if envelope.decision == .block {
            try? await securityCenter.record(envelope)
            throw AutonomyGateError.toolDenied(
                reason: envelope.primaryReason
            )
        }

        let autonomyLevel = try await gate.autonomyLevel(
            toolName: tool,
            surface: surface,
            originTrusted: envelope.originTrusted
        )
        let admittedFullMacYolo = envelope.fullMacYoloAuthority == .admitted
        // 2026-09-06: EVERY replay exemption is verified against the approval
        // inbox, not just the injection ones. `ApprovedChatToolReplay` is a
        // public struct with a public init, so field equality proved only that
        // the caller agreed with itself — enough, until now, to skip the
        // SecurityCenter `.ask` on every non-injection tool, repeatedly, with a
        // made-up id. The verifier resolves the id against the real record
        // (approved, this tool, this body, spent by the executor moments ago)
        // and burns it, so a second dispatch with the same id is refused. An
        // unverified replay is denied here rather than falling through to an
        // ordinary approval prompt, which would hide the forgery attempt.
        let approvedReplayAuthorizes: Bool
        if !MacInjectionToolNames.isInjectionTool(tool),
           let replay = approvedReplay,
           replay.matches(
            tool: tool,
            surface: surface,
            input: input,
            verifiedSessionID: verifiedSessionId
           ) {
            let verdict = await Self.verifyApprovedReplay(
                verifier: approvedReplayVerifier,
                approvalID: replay.approvalID,
                tool: tool,
                surface: surface,
                input: input
            )
            guard verdict == .verified else {
                let reason = "approved_replay_evidence_unverified: \(verdict.rawValue) "
                    + "(\(tool) replay claimed approval \(replay.approvalID))"
                try? await securityCenter.record(
                    Self.securityEnvelope(envelope, decision: .block, reason: reason)
                )
                throw AutonomyGateError.toolDenied(reason: reason)
            }
            approvedReplayAuthorizes = true
        } else {
            approvedReplayAuthorizes = false
        }
        // The first conversation's ONE documented line (User, 2026-09-15;
        // hardened after Sol's P0-1/2/3, same day).
        //
        // This is a one-shot bearer token, not a re-evaluatable predicate. It
        // is only ever offered to the Mac chat chain (`firstConversationDataRoot`
        // is nil everywhere else), it must name THIS verified session, it must
        // carry the exact section title the app armed it with, and granting it
        // RENAMES it — so of any number of concurrent or repeated dispatches
        // exactly one can win, and there is no second write to race with the
        // append. Everything else `persona_append_section` does keeps the guard.
        //
        // The surface is pinned too: a remote conversation riding this chain
        // under its own surface name is not the person sitting in front of the
        // first-run window.
        let firstConversationWriteExempt = surface == "chat"
            && FirstConversationPersonaExemption.consumeIfExempt(
                tool: tool,
                input: input,
                dataRoot: firstConversationDataRoot,
                sessionID: verifiedSessionId
            )
        let guardResult = PersonaWriteGuard.apply(
            tool: tool,
            kind: Self.jsonString(input["kind"]),
            resolvedAutonomy: autonomyLevel,
            // A resolved approval is equivalent to the explicit confirmation
            // PersonaWriteGuard was created to require, but only for the exact
            // persisted call and authenticated origin, and only once the
            // approval record itself has been verified. A mismatch falls back
            // to the normal guard and fails closed when no filer is present.
            hasExplicitAutonomyOverride: admittedFullMacYolo || approvedReplayAuthorizes
                || firstConversationWriteExempt
        )
        if firstConversationWriteExempt {
            // The exemption is audited, not silent — same posture as the
            // admitted-YOLO and approved-replay exemptions below.
            try? await securityCenter.record(Self.securityEnvelope(
                envelope,
                decision: .allow,
                reason: "first conversation persona write exempt from "
                    + PersonaWriteGuard.autonomySource
            ))
        }
        // W2/W3-FIX 3 — injection authority is enforced HERE as well as in the
        // trust resolver, because this dispatcher accepts ANY
        // `AutonomyResolver`: mocks in tests, and in production the
        // `SingleApprovedToolAutonomyResolver` used for post-approval replay.
        // Admitted Full Mac YOLO is the other checked authority source.
        //
        // Both admitted YOLO and replay remain bound to the exact tool, surface,
        // input, and verified origin; neither is a bearer string from tool input.
        //
        // W2/W3-FIX-R2 1 — AND THE EVIDENCE IS CHECKED, not asserted. Field
        // equality on a caller-built struct proves only that the caller agrees
        // with itself. Before the exemption is granted (and again before the
        // mint) the approval id is resolved against the real ApprovalInbox: the
        // record must exist, be resolved-approved, name THIS tool and surface,
        // be bound to THIS body, and be unspent. A forged replay is refused
        // here — it does not fall through to the floor, because falling through
        // would hide a forgery attempt behind an ordinary approval prompt.
        var injectionReplayApprovalID: String?
        if MacInjectionToolNames.isInjectionTool(tool),
           let replay = approvedReplay,
           replay.matches(
            tool: tool,
            surface: surface,
            input: input,
            verifiedSessionID: verifiedSessionId
           ) {
            let verdict = await Self.verifyInjectionApproval(
                verifier: injectionApprovalVerifier,
                approvalID: replay.approvalID,
                tool: tool,
                surface: surface,
                input: input
            )
            guard verdict == .verified else {
                let reason = "injection_replay_evidence_unverified: \(verdict.rawValue) "
                    + "(\(tool) replay claimed approval \(replay.approvalID))"
                try? await securityCenter.record(
                    Self.securityEnvelope(envelope, decision: .block, reason: reason)
                )
                throw AutonomyGateError.toolDenied(reason: reason)
            }
            injectionReplayApprovalID = replay.approvalID
        }
        let flooredAutonomy = admittedFullMacYolo || injectionReplayApprovalID != nil
            ? guardResult.autonomy
            : MacInjectionToolNames.clampedAutonomyLevel(
                toolName: tool,
                resolved: guardResult.autonomy
            )
        let autonomyDecision: AutonomyDecision
        if guardResult.source == PersonaWriteGuard.autonomySource && !admittedFullMacYolo {
            autonomyDecision = .requireApproval(
                reason: "autonomy=\(guardResult.autonomy) source=\(PersonaWriteGuard.autonomySource)"
            )
        } else {
            autonomyDecision = admittedFullMacYolo
                ? .allow
                : AutonomyGate.map(level: flooredAutonomy, toolName: tool)
        }
        // Deny outranks every ask; a security .ask outranks autonomy allow
        // (the external-send gate exists precisely to force a human look).
        // Track the SOURCE: the staging shortcut below is only valid for
        // autonomy-source approvals — a SECURITY .ask (injection shield,
        // external_send) on a staging tool must file a REAL approval record,
        // or the inner dispatcher returns a bare pending_approval with
        // nothing ever staged (gpt-5.5 review 2026-07-21).
        //
        // 2026-09-06: a post-approval REPLAY must not be asked again. The
        // executor resolves the approval, durably SPENDS it, then re-dispatches
        // here with `approvedReplay` and no filer — so a second security .ask
        // (external_send, with sendExternalMessagesRequiresApproval on) fell
        // through to the `hasFiler` deny below and mail_send / messages_send /
        // mail_reply were consumed and then refused. The exemption is bound to
        // the exact persisted tool, surface, body and verified origin, and it
        // does NOT cover injection tools — those keep the inbox-verified
        // `injectionReplayApprovalID` path above, which is stricter.
        // `approvedReplayAuthorizes` was resolved (and the approval record
        // verified and burned) before the persona guard above.
        if approvedReplayAuthorizes, envelope.requiresApproval {
            // The exemption is audited, not silent.
            try? await securityCenter.record(Self.securityEnvelope(
                envelope,
                decision: .allow,
                reason: "approved replay of \(tool) honours approval "
                    + "\(approvedReplay?.approvalID ?? "unknown")"
            ))
        }
        let securityAsked: Bool
        var securityReasonMayBeReplaced = false
        var decision: AutonomyDecision
        if case .deny = autonomyDecision {
            decision = autonomyDecision
            securityAsked = false
        } else if surface == "bot", !approvedReplayAuthorizes, injectionReplayApprovalID == nil,
                  Self.requiresDesktopInteraction(tool: tool, capabilities: envelope.capabilities) {
            // A verified replay is the person having already clicked Approve on
            // exactly this call. The executor keeps surface "bot" and wires no
            // filer, so asking again here spent the approval, demanded another,
            // and then failed "no filer" — the bot could never finish the thing
            // it was approved to do. Both exemptions are the inbox-verified ones
            // resolved above (bound to this tool, surface, body and origin), not
            // a claim from tool input.
            decision = .requireApproval(reason: "This bot needs permission to use the visible desktop or play sound.")
            securityAsked = true
        } else if envelope.requiresApproval, !approvedReplayAuthorizes {
            decision = .requireApproval(
                reason: envelope.primaryReason
            )
            securityReasonMayBeReplaced = true
            securityAsked = true
        } else {
            decision = autonomyDecision
            securityAsked = false
        }
        // 2026-09-15 — A PEER TURN ASKS; IT DOES NOT REFUSE.
        //
        // User's ruling: a peer gets the whole Agent, and when another agent
        // asks her for something destructive her existing behaviour IS the
        // safety — she comes to him and asks. So an effect verb on a peer turn
        // does not lose a tool and does not get a wall of refusal text: it
        // takes the same route a Trust-gated action takes, the person's own
        // permission card, with the peer named as the requester. Approve and
        // it runs. A peer the person elevated in Trust → Connected agents
        // never reaches here at all — its turns run on `chat` (User's ruling).
        //
        // Placed AFTER the security/autonomy decision so it can only ever
        // narrow `.allow` to `.requireApproval`; a deny stays a deny and an
        // existing ask keeps its own reason.
        //
        // Sol, 2026-09-15: EXCEPT on a post-approval replay. The executor
        // re-dispatches an approved call with `approvedReplay` and no filer,
        // and the surface is still `agent-bridge` — so asking again here
        // turned the person's own Approve into "approval required, no filer
        // is available", and nothing a peer asked for could ever finish. Both
        // exemptions are the inbox-verified ones resolved above, bound to this
        // tool, surface, body and origin; neither is a claim from tool input.
        //
        // 2026-09-15, from the live peer proof: an effect that the ORIGIN gates
        // had already downgraded to `.ask` arrived here as
        // `.requireApproval("security ask: remote origin has no trust root")`,
        // not `.allow` — so the card the person read named neither the peer nor
        // the thing being asked for. A generic security ask on a peer turn is
        // the SAME question in worse words, so the peer reason replaces it; a
        // deny, and any ask with a reason of its own, still keep theirs.
        let peerReasonMayReplace: Bool
        // USER: "Full Mac is full mac." An allowed connect stays allowed: below
        // Full Mac the SecurityCenter already asks (other_app_settings_write),
        // and the exact executable is still bound and re-checked at launch.
        switch decision {
        case .allow: peerReasonMayReplace = true
        case .requireApproval: peerReasonMayReplace = securityReasonMayBeReplaced
        case .deny: peerReasonMayReplace = false
        }
        let peerTurnID = ChatToolSessionContext.envelope?.verifiedUserId
        if !approvedReplayAuthorizes, injectionReplayApprovalID == nil,
           peerReasonMayReplace,
           let requester = PeerTurnEffectPolicy.peerRequester(
            surface: surface,
            peerID: peerTurnID,
            peerName: peerDisplayName(peerID: peerTurnID),
            taintSource: PeerDataTaint.current.flatMap {
                $0.isTainted ? $0.sourceDescription : nil
            }
           ),
           PeerTurnEffectPolicy.requiresPeerApproval(tool, capabilities: envelope.capabilities,
                                                    externalToolIsEffect: externalToolIsEffect,
                                                    input: input,
                                                    workspaceRoot: NativeAgentWorkspaceRoot.resolve(
                                                        dataRoot: peerDirectoryDataRoot ?? defaultDataRoot()),
                                                    // Full Mac file ops resolve relative paths here.
                                                    relativeBases: SwiftToolDispatcher.builderSourceRepoRoot(
                                                        dataRoot: peerDirectoryDataRoot ?? defaultDataRoot()).map { [$0] } ?? []) {
            decision = .requireApproval(
                reason: PeerTurnEffectPolicy.approvalReason(tool: tool, requester: requester)
            )
        }
        switch decision {
        case .allow:
            // Bind the per-turn session so downstream app dispatchers
            // (AppChatToolDispatcher) reconstruct the same security origin we
            // just authorized — otherwise their session-blind re-gate
            // false-blocks trusted remote invokes. See ChatToolSessionContext.
            //
            // For an injection tool the only way to be HERE with `.allow` is
            // the exact post-approval replay; `runInner` refuses without an
            // approval id, so an `.allow` that slipped through from any other
            // source still cannot type.
            return try await runInner(
                tool: tool,
                input: input,
                surface: surface,
                injectionApprovalID: injectionReplayApprovalID,
                // Reaching .allow IS the person's go-ahead: their approval, or Full Mac.
                personApprovedHost: namedConnect
            )
        case .deny(let reason):
            try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .block, reason: reason))
            throw AutonomyGateError.toolDenied(reason: reason)
        case .requireApproval(let gateReason):
            // THE CARD'S WORDS. A tool that writes into another program's own
            // settings owes the person the exact file, the exact entry and the
            // exact access BEFORE they press anything, and "autonomy=confirm"
            // says none of that. Only the implementation knows them, so it is
            // asked here; every existing tool answers nil and keeps the gate's
            // reason unchanged.
            var reason = ApprovalActionText.reason(gateReason, tool: tool)
            if let validating = inner as? any PreApprovalToolValidating,
               let disclosed = await validating.approvalCardReason(
                tool: tool, input: input, surface: surface) {
                reason = disclosed
            }
            // Nothing the implementation would have refused outright is worth a
            // person's click. The inner dispatcher runs its own cheap, certain
            // checks — is this tool loaded for the turn, do its arguments parse
            // — and a refusal here comes back to the model as an ordinary tool
            // error, with no approval filed (2026-09-13, the 0.4.12 drive: two
            // bot_create calls raised a card and only then failed on cadence).
            if let validating = inner as? any PreApprovalToolValidating {
                let refusal = await ChatToolSessionContext.$verifiedSessionId.withValue(
                    verifiedSessionId ?? ChatToolSessionContext.verifiedSessionId
                ) {
                    await validating.preApprovalRefusal(tool: tool, input: input, surface: surface)
                }
                if let refusal { return ToolNotRunStatus.blocked.reporting(refusal) }
            }
            let ownsACPConnectCard: Bool
            if tool == "agent_connect", case .string(let name)? = input["name"],
               input["endpoint"] == nil, input["app_bundle_id"] == nil,
               input["disconnect"] == nil,
               input["transport"] == nil || input["transport"] == .string("auto") {
                ownsACPConnectCard = AgentHostDirectory.row(named: name)?.acp != nil
            } else { ownsACPConnectCard = false }
            if !securityAsked, Self.approvalStagingToolNames.contains(tool.lowercased()) || ownsACPConnectCard {
                // ACP files and awaits its own canonical connect card over an
                // immutable executable proposal; no executable grant precedes it.
                // These tools only persist a bounded replay request. The actual
                // connector call is owned by the post-resolution executor.
                // Injection tools are never in this set (asserted by
                // `macInjectionTools_areNotApprovalStagingTools`), so this
                // shortcut cannot become an injection bypass.
                return try await runInner(
                    tool: tool,
                    input: input,
                    surface: surface,
                    injectionApprovalID: nil
                )
            }
            // When a filer is wired, file approval and await resolution via the gate.
            // When none is wired, surface as a deny so the loop records the rejection
            // rather than hanging — same as the legacy behavior.
            guard hasFiler else {
                try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .ask, reason: reason))
                // Raw/noninteractive callers can deliberately omit a filer and
                // remain fail-closed. Never teach a model to bypass TrustCenter
                // by editing policy; production user-chat profiles wire the
                // canonical ApprovalInbox projection.
                throw AutonomyGateError.notRun(.approvalUnavailable)
            }
            // W2/W3-FIX 4 — REDACT BEFORE PERSISTING. `input` for a
            // mac_keystroke carries the literal characters Agent is about to
            // type, which can be a password or a 2FA code. The approval record
            // is `remoteResolvable`, so an un-redacted payload syncs to iOS and
            // is echoed into a Telegram prompt. Everything that leaves this
            // method for storage or display carries count + digest instead; the
            // real characters stay in this process's memory only.
            let approvalPayloadInput = MacInjectionArgRedaction.redacted(tool: tool, input: input)
            let injectionSecrets = MacInjectionArgRedaction.extractSecrets(tool: tool, input: input)
            if let nonBlocking = approvalFiler as? (any NonBlockingApprovalFiler) {
                let payload = JSONValue.object(approvalPayloadInput)
                let approvalId = try await withFilingSession {
                    do {
                        return try await nonBlocking.fileApprovalRequest(
                            toolName: tool, surface: surface, payload: payload, reason: reason
                        )
                    } catch let error as AutonomyGateError {
                        throw error
                    } catch {
                        throw AutonomyGateError.approvalFilingFailed(String(describing: error))
                    }
                }
                // Hand the characters to the in-memory vault keyed by the
                // approval the human is about to look at. The replay path takes
                // them back out exactly once. If this process dies first, the
                // replay refuses rather than typing something it can't
                // reconstruct — see MacInjectionSecretVault.
                if !injectionSecrets.isEmpty {
                    await MacInjectionSecretVault.shared.store(
                        approvalID: approvalId,
                        secrets: injectionSecrets
                    )
                }
                try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .ask, reason: reason))
                var pending = await nonBlocking.pendingApprovalResult(
                    id: approvalId,
                    toolName: tool,
                    surface: surface,
                    payload: payload,
                    reason: reason
                )
                if case .object(let fields) = pending, fields["not_run_status"] == nil {
                    pending = ToolNotRunStatus.approvalFiled.reporting(pending)
                }
                if surface == "bot" { ChatTurnExecution.current?.keepApproval(id: approvalId, pending) }
                return pending
            }
            let resolved = try await withFilingSession {
                try await gate.resolveWithApprovalDetailed(
                    toolName: tool,
                    surface: surface,
                    requestPayload: .object(approvalPayloadInput),
                    timeoutSeconds: approvalTimeoutSeconds,
                    reason: reason
                )
            }
            if !injectionSecrets.isEmpty, let filedID = resolved.approvalID {
                await MacInjectionSecretVault.shared.store(
                    approvalID: filedID,
                    secrets: injectionSecrets
                )
            }
            switch resolved.decision {
            case .allow:
                // Bind the per-turn session (see the .allow branch above). The
                // capability is minted from THIS approval id — the human just
                // resolved it, in this call, for this exact body.
                //
                // W2/W3-FIX-R2 1 — for an INJECTION tool that id is still
                // checked against the real inbox record before it can mint.
                // "The filer told me it was approved" is the same class of
                // claim as "the replay struct told me it was approved": this
                // dispatcher accepts ANY `ApprovalFiler`, so a filer that
                // returns an id and says .approved must not by itself be able
                // to authorize a keystroke.
                var mintApprovalID = resolved.approvalID
                if MacInjectionToolNames.isInjectionTool(tool) {
                    let verdict = await Self.verifyInjectionApproval(
                        verifier: injectionApprovalVerifier,
                        approvalID: resolved.approvalID ?? "",
                        tool: tool,
                        surface: surface,
                        input: input
                    )
                    guard verdict == .verified else {
                        let r = "injection_approval_unverified: \(verdict.rawValue) "
                            + "(\(tool) resolved approval \(resolved.approvalID ?? "<none>"))"
                        try? await securityCenter.record(
                            Self.securityEnvelope(envelope, decision: .block, reason: r)
                        )
                        throw AutonomyGateError.toolDenied(reason: r)
                    }
                    mintApprovalID = resolved.approvalID
                }
                return try await runInner(
                    tool: tool,
                    input: input,
                    surface: surface,
                    injectionApprovalID: mintApprovalID,
                    personApprovedHost: namedConnect
                )
            case .deny(let r):
                try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .block, reason: r))
                throw AutonomyGateError.notRun(resolved.notRunStatus ?? .blocked)
            case .requireApproval(let r):
                try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .ask, reason: r))
                throw AutonomyGateError.toolDenied(reason: r)
            }
        }
    }

    /// Desk 658.12 — the session an approval RECORD is filed under.
    ///
    /// `runInner` binds `verifiedSessionId` for the tool call itself, but an
    /// approval is filed BEFORE any tool runs, so a filer reading
    /// `ChatToolSessionContext.verifiedSessionId` saw whatever the enclosing
    /// task happened to hold. Remote transports bind it around their own
    /// `chat()` call, so Telegram/Slack records carried an origin; the local
    /// Mac chat path has no such outer binding, so every Mac chat approval was
    /// written with `origin.sessionId = null` and could not be matched back to
    /// the conversation that asked for it.
    ///
    /// An outer binding always wins: a transport that verified the session
    /// against its own identity is the better authority, and this must never
    /// overwrite it. This only fills the nil case, from the same per-turn
    /// session the gate already resolved trust with — it invents nothing and
    /// changes no gate decision.
    private func withFilingSession<T>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        let filingSessionId = ChatToolSessionContext.verifiedSessionId ?? verifiedSessionId
        return try await ChatToolSessionContext.$verifiedSessionId.withValue(
            filingSessionId,
            operation: body
        )
    }

    /// THE SINGLE EXECUTION DOOR of this dispatcher, and the ONLY place in the
    /// repo that mints a `MacInjectionCapability` (pinned by
    /// `macInjectionCapability_hasExactlyOneMintSite`).
    ///
    /// Every `.allow` branch above routes through here, which is what makes the
    /// injection rule unconditional rather than a property of whichever branch
    /// you happened to take:
    ///   • non-injection tools: bind the session, clear any inherited
    ///     capability, dispatch. Unchanged behavior.
    ///   • injection tools with no approval id: refused. There is no branch
    ///     that reaches `inner.dispatch` for an injection tool without one.
    ///   • injection tools with an approval id: rehydrate the redacted secret
    ///     arguments, mint a capability bound to this action + the exact body
    ///     about to run, and bind it for the duration of the call only.
    private func runInner(
        tool: String,
        input: [String: JSONValue],
        surface: String,
        injectionApprovalID: String?,
        personApprovedHost: Bool = false
    ) async throws -> JSONValue {
        var effectiveInput = input
        var capability: MacInjectionCapability?

        if MacInjectionToolNames.isInjectionTool(tool) {
            // USER 2026-08-12 — YOLO: nothing approval-gated. A missing approval
            // id is synthesized rather than refused; Full Mac + category + TCC
            // remain the gates.
            let resolvedApprovalID = injectionApprovalID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let approvalID = (resolvedApprovalID?.isEmpty == false)
                ? resolvedApprovalID!
                : "yolo-\(UUID().uuidString)"
            guard let action = MacInjectionToolNames.action(forTool: tool) else {
                throw AutonomyGateError.toolDenied(
                    reason: "injection_approval_missing: \(tool) has no mapped action"
                )
            }
            // Replay path: the persisted input is the REDACTED form. Put the
            // characters back from the vault before the digest is computed, so
            // the capability binds what actually runs.
            if let secrets = await MacInjectionSecretVault.shared.take(approvalID: approvalID),
               !secrets.isEmpty {
                effectiveInput = MacInjectionArgRedaction.rehydrated(
                    tool: tool,
                    input: effectiveInput,
                    secrets: secrets
                )
            } else if MacInjectionArgRedaction.isRedacted(tool: tool, input: effectiveInput) {
                // The record says characters were redacted but the vault no
                // longer holds them (app restarted, or they were already
                // spent). Typing a placeholder into whatever is frontmost would
                // be worse than refusing.
                throw AutonomyGateError.toolDenied(
                    reason: "injection_secret_unavailable: the approved text for \(tool) is no "
                        + "longer held in memory (app restarted or already replayed). Ask again."
                )
            }
            guard let minted = MacInjectionCapability.mint(
                approvalID: approvalID,
                action: action,
                body: effectiveInput
            ) else {
                throw AutonomyGateError.toolDenied(
                    reason: "injection_capability_mint_failed: \(tool) could not be authorized"
                )
            }
            capability = minted
        }

        let finalInput = effectiveInput
        let finalCapability = capability
        return try await ChatToolSessionContext.$verifiedSessionId.withValue(verifiedSessionId) {
            // Bound even when nil: a non-injection tool must never inherit a
            // capability left in scope by an enclosing task.
            try await MacInjectionCapabilityContext.$current.withValue(finalCapability) {
                try await AgentHostConnection.$personApproved.withValue(personApprovedHost) {
                    try await inner.dispatch(tool: tool, input: finalInput, surface: surface)
                }
            }
        }
    }

    func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools()
    }

    // HOTFIX 2026-06-03: forward schemas. Without this the gate wrapper
    // silently dropped to the default-empty schema list, so the LLM never
    // saw the SwiftToolDispatcher's 7 built-ins behind the autonomy gate.
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas()
    }

    /// W2/W3-FIX-R2 1 — the single place an injection approval id becomes
    /// trusted. Both entry points (exact post-approval replay, and an approval
    /// resolved inside this call) route through here, so there is no branch
    /// where a nonempty string is sufficient. No verifier wired ⇒ `.noVerifier`
    /// ⇒ refused: a chain with no way to check its approvals is a chain that
    /// does not inject.
    private static func verifyInjectionApproval(
        verifier: (any InjectionApprovalVerifying)?,
        approvalID: String,
        tool: String,
        surface: String,
        input: [String: JSONValue]
    ) async -> InjectionApprovalVerification {
        guard let verifier else { return .noVerifier }
        return await verifier.verifyInjectionApproval(
            approvalID: approvalID,
            tool: tool,
            surface: surface,
            input: input
        )
    }

    /// 2026-09-06 — the same single place for every OTHER tool's replay id. No
    /// verifier wired ⇒ `.noVerifier` ⇒ no exemption: a chain with no way to
    /// check its approvals does not honour one.
    private static func verifyApprovedReplay(
        verifier: (any ApprovedReplayVerifying)?,
        approvalID: String,
        tool: String,
        surface: String,
        input: [String: JSONValue]
    ) async -> ApprovedReplayVerification {
        guard let verifier else { return .noVerifier }
        return await verifier.verifyApprovedReplay(
            approvalID: approvalID,
            tool: tool,
            surface: surface,
            input: input
        )
    }

    /// THE origin projection. Every security field here comes from the TURN
    /// ENVELOPE, not from the `surface` the caller happened to dispatch under.
    ///
    /// That distinction is the whole point. A remote adapter binds
    /// `TurnEnvelope(surface: "signal", declaredRemote: true, verifiedUserId: …)`
    /// while its `client.chat` call still runs with the shared tool surface
    /// `"chat"` (the bridges deliberately do exactly that). Reading `surface`
    /// here would then hand a genuinely remote turn a LOCAL, trusted origin —
    /// `assessOrigin` short-circuits to "local app surface" before any
    /// allowlist is consulted. The envelope is the one value that knows what
    /// the turn actually is, so it is the one value this reads.
    ///
    /// `TurnEnvelope.current(surface:)` is the ONLY path to the task-locals:
    /// when no envelope is bound it composes one from them, so a pre-envelope
    /// adapter keeps its exact behavior and there is no second place that can
    /// disagree about identity.
    /// Internal, not private, for the same reason `resolvedChatId` is: this
    /// projection is a trust boundary and gets tested directly.
    static func securityOrigin(
        verifiedSessionId: String?,
        surface: String
    ) -> SecurityOriginContext {
        let sessionId = verifiedSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usableSessionId = sessionId?.isEmpty == false ? sessionId : nil
        let envelope = TurnEnvelope.current(surface: surface)
        // Remoteness only ever WIDENS: the surface profile owns the known
        // remote set, and `declaredRemote` can add remoteness to a surface the
        // profile has not heard of yet. Neither can subtract it — see the
        // same rule restated in `SecurityCenter.assessOrigin`.
        let remote = ConversationSurfaceProfile(envelope.surface).isRemote
            || envelope.declaredRemote == true
        return SecurityOriginContext(
            surface: envelope.surface,
            sessionId: usableSessionId,
            userId: envelope.verifiedUserId,
            chatId: envelope.verifiedChatId,
            deviceId: nil,
            source: "chat_runtime",
            isRemote: remote,
            commandSignatureVerified: envelope.commandSignatureVerified
        )
    }

    private static func jsonString(_ raw: JSONValue?) -> String? {
        switch raw {
        case .string(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// The turn's verified remote chat identity, and NOTHING ELSE.
    ///
    /// PARSE SITE 2 of 5, DELETED (one-thread-many-surfaces plan §1.2). This
    /// used to fall back to parsing `telegram:<chatId>` out of the session id
    /// string. That fallback is unsound and always was: `chat/sessions.json`
    /// holds rows whose ids are `telegram:codex-probe` and
    /// `telegram:codex-tool-catalog-probe` but whose source is `app`, so the
    /// "chatId" it yielded for those was the literal string `codex-probe`. It
    /// failed closed only because that string is not in anyone's allowlist —
    /// a namespace collision waiting for a collaborator.
    ///
    /// The session id is a STORAGE KEY. It is not identity, it is not
    /// provenance, and it is not evidence. Identity comes from the transport,
    /// on the envelope, or it does not come at all.
    ///
    /// `sessionId` stays in the signature because callers pass it and because
    /// deleting the parameter would hide, rather than record, what was removed.
    static func resolvedChatId(sessionId: String?) -> String? {
        _ = sessionId
        if let bound = ChatToolSessionContext.envelope?.verifiedChatId?
            .trimmingCharacters(in: .whitespacesAndNewlines), !bound.isEmpty {
            return bound
        }
        guard let verified = ChatToolSessionContext.verifiedChatId?
            .trimmingCharacters(in: .whitespacesAndNewlines), !verified.isEmpty else {
            return nil
        }
        return verified
    }

    private static func securityEnvelope(
        _ envelope: SecurityToolEnvelope,
        decision: SecurityToolDecision,
        reason: String
    ) -> SecurityToolEnvelope {
        var copy = envelope
        copy.decision = decision
        copy.allowed = decision == .allow
        copy.requiresApproval = decision == .ask
        copy.reasons.append(.init(decision == .allow ? .note : .cause, reason))
        return copy
    }
}
