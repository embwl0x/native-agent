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
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

// MARK: - File-access wrapping dispatcher

/// Wraps a ToolDispatchClient and rejects calls to a hard-coded set of
/// filesystem / shell tool name prefixes when fileAccess == "none".
/// Honest carve: we do not introspect tool metadata for "writes_fs" — we
/// gate by name prefix, which is the same coarse rule the daemon uses
/// when fileAccess=none is asserted upstream.
final class FileAccessGatedDispatcher: ToolDispatchClient, @unchecked Sendable {
    private let inner: any ToolDispatchClient
    private let mode: Mode

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
        // propose/install tools mutate the EvolutionProposalStore + stage an
        // install card; even the read-only status tool stays denied here so
        // fileAccess=none keeps the whole evolution surface unreachable.
        "evolution_propose", "evolution_status", "self_install",
        // 2026-07-31 audit fix: the Full-Mac file/git read tools
        // (SwiftToolDispatcher.fullMacFileToolNames + the git group) matched
        // neither blockedExact nor any blockedPrefix, so fileAccess=none was
        // letting six real filesystem/repo readers through. `write_file` was
        // already covered by prefix. These stay PERMITTED under .readOnly —
        // they are reads, and read_only exists to allow exactly this.
        "file_excerpt", "grep",
        "git_status", "git_diff", "git_log", "repo_dirty_summary",
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
        "evolution_propose", "evolution_status", "self_install",
        "mac_focus_app", "mac_quit_app",
        "mac_set_volume", "mac_sleep_display", "mac_lock_screen",
        "mac_run_shortcut",
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

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if isBlocked(tool) {
            // Name the ACTUAL mode — this gate also fires for read_only, and
            // the old hardcoded "fileAccess=none" string lied in that case.
            let modeName = mode == .readOnly ? "read_only" : "none"
            throw AutonomyGateError.toolDenied(reason: "fileAccess=\(modeName) blocks \(tool)")
        }
        return try await inner.dispatch(tool: tool, input: input, surface: surface)
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
    }

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
        public init(model: String, surface: String, personaID: String? = nil) {
            self.model = model
            self.surface = surface
            self.personaID = personaID
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
    private static let approvalStagingToolNames: Set<String> = [
        "agentmail.send",
        "agentmail_send",
        "slack.post_message",
        "slack_post_message",
    ]

    init(
        inner: any ToolDispatchClient,
        gate: AutonomyGate,
        approvalFiler: (any ApprovalFiler)? = nil,
        securityCenter: SwiftNativeSecurityCenter = SwiftNativeSecurityCenter(),
        hasFiler: Bool = false,
        approvalTimeoutSeconds: Double = 30,
        verifiedSessionId: String? = nil
    ) {
        self.inner = inner
        self.gate = gate
        self.approvalFiler = approvalFiler
        self.securityCenter = securityCenter
        self.hasFiler = hasFiler
        self.approvalTimeoutSeconds = approvalTimeoutSeconds
        self.verifiedSessionId = verifiedSessionId
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let envelope = await securityCenter.evaluateTool(
            tool: tool,
            input: input,
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
                reason: "security \(envelope.decision.rawValue): \(Self.primarySecurityReason(envelope.reasons))"
            )
        }

        let autonomyLevel = try await gate.autonomyLevel(
            toolName: tool,
            surface: surface,
            originTrusted: envelope.originTrusted
        )
        let guardResult = PersonaWriteGuard.apply(
            tool: tool,
            kind: Self.jsonString(input["kind"]),
            resolvedAutonomy: autonomyLevel,
            hasExplicitAutonomyOverride: false
        )
        let autonomyDecision: AutonomyDecision
        if guardResult.source == PersonaWriteGuard.autonomySource {
            autonomyDecision = .requireApproval(
                reason: "autonomy=\(guardResult.autonomy) source=\(PersonaWriteGuard.autonomySource)"
            )
        } else {
            autonomyDecision = AutonomyGate.map(level: guardResult.autonomy)
        }
        // Deny outranks every ask; a security .ask outranks autonomy allow
        // (the external-send gate exists precisely to force a human look).
        // Track the SOURCE: the staging shortcut below is only valid for
        // autonomy-source approvals — a SECURITY .ask (injection shield,
        // external_send) on a staging tool must file a REAL approval record,
        // or the inner dispatcher returns a bare pending_approval with
        // nothing ever staged (gpt-5.5 review 2026-07-21).
        let securityAsked: Bool
        let decision: AutonomyDecision
        if case .deny = autonomyDecision {
            decision = autonomyDecision
            securityAsked = false
        } else if envelope.requiresApproval {
            decision = .requireApproval(
                reason: "security ask: \(Self.primarySecurityReason(envelope.reasons))"
            )
            securityAsked = true
        } else {
            decision = autonomyDecision
            securityAsked = false
        }
        switch decision {
        case .allow:
            // Bind the per-turn session so downstream app dispatchers
            // (AppChatToolDispatcher) reconstruct the same security origin we
            // just authorized — otherwise their session-blind re-gate
            // false-blocks trusted remote invokes. See ChatToolSessionContext.
            return try await ChatToolSessionContext.$verifiedSessionId.withValue(verifiedSessionId) {
                try await inner.dispatch(tool: tool, input: input, surface: surface)
            }
        case .deny(let reason):
            try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .block, reason: reason))
            throw AutonomyGateError.toolDenied(reason: reason)
        case .requireApproval(let reason):
            if !securityAsked, Self.approvalStagingToolNames.contains(tool.lowercased()) {
                // These tools only persist a bounded replay request. The actual
                // connector call is owned by the post-resolution executor.
                return try await ChatToolSessionContext.$verifiedSessionId.withValue(verifiedSessionId) {
                    try await inner.dispatch(tool: tool, input: input, surface: surface)
                }
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
                throw AutonomyGateError.toolDenied(
                    reason: "approval required, no filer is available on this noninteractive surface: \(reason)"
                )
            }
            if let nonBlocking = approvalFiler as? (any NonBlockingApprovalFiler) {
                let payload = JSONValue.object(input)
                let approvalId = try await nonBlocking.fileApprovalRequest(
                    toolName: tool,
                    surface: surface,
                    payload: payload,
                    reason: reason
                )
                try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .ask, reason: reason))
                return await nonBlocking.pendingApprovalResult(
                    id: approvalId,
                    toolName: tool,
                    surface: surface,
                    payload: payload,
                    reason: reason
                )
            }
            let resolved = try await gate.resolveWithApproval(
                toolName: tool,
                surface: surface,
                requestPayload: .object(input),
                timeoutSeconds: approvalTimeoutSeconds,
                reason: reason
            )
            switch resolved {
            case .allow:
                // Bind the per-turn session (see the .allow branch above).
                return try await ChatToolSessionContext.$verifiedSessionId.withValue(verifiedSessionId) {
                    try await inner.dispatch(tool: tool, input: input, surface: surface)
                }
            case .deny(let r):
                try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .block, reason: r))
                throw AutonomyGateError.toolDenied(reason: r)
            case .requireApproval(let r):
                try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .ask, reason: r))
                throw AutonomyGateError.toolDenied(reason: r)
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

    private static func primarySecurityReason(_ reasons: [String]) -> String {
        reasons.first { !$0.hasPrefix("autonomy:") }
            ?? reasons.first
            ?? "tool denied"
    }

    private static func securityOrigin(
        verifiedSessionId: String?,
        surface: String
    ) -> SecurityOriginContext {
        let sessionId = verifiedSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usableSessionId = sessionId?.isEmpty == false ? sessionId : nil
        // Prefer the transport-verified chatId (covers UUID sessions where the
        // id can't be parsed from the session string); fall back to the legacy
        // `telegram:<chatId>` session form. See ChatToolSessionContext.
        let chatId = Self.resolvedChatId(sessionId: usableSessionId)
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SecurityOriginContext(
            surface: surface,
            sessionId: usableSessionId,
            userId: ChatToolSessionContext.verifiedUserId,
            chatId: chatId,
            deviceId: nil,
            source: "chat_runtime",
            isRemote: [
                "telegram", "slack", "ios", "icloud", "iphone", "ipad", "mobile", "remote", "watch",
            ].contains(normalizedSurface),
            commandSignatureVerified: ChatToolSessionContext.commandSignatureVerified
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

    private static func telegramChatId(fromSessionId sessionId: String?) -> String? {
        guard let sessionId else { return nil }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("telegram:") else { return nil }
        return String(trimmed.dropFirst("telegram:".count))
    }

    /// Transport-verified chatId wins (covers UUID sessions); otherwise parse
    /// the legacy `telegram:<chatId>` session form. See ChatToolSessionContext.
    static func resolvedChatId(sessionId: String?) -> String? {
        if let verified = ChatToolSessionContext.verifiedChatId?
            .trimmingCharacters(in: .whitespacesAndNewlines), !verified.isEmpty {
            return verified
        }
        return telegramChatId(fromSessionId: sessionId)
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
        copy.reasons.append(reason)
        return copy
    }
}
