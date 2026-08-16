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
        "evolution_propose", "evolution_status", "self_install",
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
        !approvalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && self.tool == tool
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
        injectionApprovalVerifier: (any InjectionApprovalVerifying)? = nil
    ) {
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

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
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
            // A resolved approval is equivalent to the explicit confirmation
            // PersonaWriteGuard was created to require, but only for the exact
            // persisted call and authenticated origin. A mismatch falls back
            // to the normal guard and fails closed when no filer is present.
            hasExplicitAutonomyOverride: approvedReplay?.matches(
                tool: tool,
                surface: surface,
                input: input,
                verifiedSessionID: verifiedSessionId
            ) == true
        )
        // W2/W3-FIX 3 — the injection approval floor, enforced HERE as well as
        // in the trust resolver, because this dispatcher accepts ANY
        // `AutonomyResolver`: mocks in tests, and in production the
        // `SingleApprovedToolAutonomyResolver` that the post-approval replay
        // executor installs. A floor that lives only inside
        // SwiftNativeTrustCenter is a floor a different resolver walks around.
        //
        // The single exemption is the EXACT post-approval replay: same tool,
        // same surface, same input, same verified origin, carrying the approval
        // record id a human already resolved. That is not an autonomy override,
        // it is the second half of one approved call.
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
        let flooredAutonomy = injectionReplayApprovalID != nil
            ? guardResult.autonomy
            : MacInjectionToolNames.clampedAutonomyLevel(
                toolName: tool,
                resolved: guardResult.autonomy
            )
        let autonomyDecision: AutonomyDecision
        if guardResult.source == PersonaWriteGuard.autonomySource {
            autonomyDecision = .requireApproval(
                reason: "autonomy=\(guardResult.autonomy) source=\(PersonaWriteGuard.autonomySource)"
            )
        } else {
            autonomyDecision = AutonomyGate.map(level: flooredAutonomy)
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
            //
            // For an injection tool the only way to be HERE with `.allow` is
            // the exact post-approval replay; `runInner` refuses without an
            // approval id, so an `.allow` that slipped through from any other
            // source still cannot type.
            return try await runInner(
                tool: tool,
                input: input,
                surface: surface,
                injectionApprovalID: injectionReplayApprovalID
            )
        case .deny(let reason):
            try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .block, reason: reason))
            throw AutonomyGateError.toolDenied(reason: reason)
        case .requireApproval(let reason):
            if !securityAsked, Self.approvalStagingToolNames.contains(tool.lowercased()) {
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
                throw AutonomyGateError.toolDenied(
                    reason: "approval required, no filer is available on this noninteractive surface: \(reason)"
                )
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
                let approvalId = try await nonBlocking.fileApprovalRequest(
                    toolName: tool,
                    surface: surface,
                    payload: payload,
                    reason: reason
                )
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
                return await nonBlocking.pendingApprovalResult(
                    id: approvalId,
                    toolName: tool,
                    surface: surface,
                    payload: payload,
                    reason: reason
                )
            }
            let resolved = try await gate.resolveWithApprovalDetailed(
                toolName: tool,
                surface: surface,
                requestPayload: .object(approvalPayloadInput),
                timeoutSeconds: approvalTimeoutSeconds,
                reason: reason
            )
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
                    injectionApprovalID: mintApprovalID
                )
            case .deny(let r):
                try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .block, reason: r))
                throw AutonomyGateError.toolDenied(reason: r)
            case .requireApproval(let r):
                try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .ask, reason: r))
                throw AutonomyGateError.toolDenied(reason: r)
            }
        }
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
        injectionApprovalID: String?
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
                try await inner.dispatch(tool: tool, input: finalInput, surface: surface)
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
