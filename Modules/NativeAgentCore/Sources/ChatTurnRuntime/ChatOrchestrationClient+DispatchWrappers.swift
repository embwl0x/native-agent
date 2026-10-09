import AgentWorkspace
import Foundation
import ApprovalInbox
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TurnTrace
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import ToolRegistry
import TrustCenter
import KnowledgeGraph
import XConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import StandingBots

// MARK: - File-access wrapping dispatcher

/// Wraps a ToolDispatchClient and rejects calls to a hard-coded set of
/// filesystem / shell tool name prefixes when fileAccess == "none".
/// Honest carve: we do not introspect tool metadata for "writes_fs" — we
/// gate by name prefix, which is the same coarse rule the daemon uses
/// when fileAccess=none is asserted upstream.
final class FileAccessGatedDispatcher: ToolDispatchClient, PreApprovalToolValidating, @unchecked Sendable {
    private let inner: any ToolDispatchClient
    private let mode: Mode

    /// Refuse through the same file-access gate before any inner preview
    /// inspects a target, then carry the inner dispatcher's checks through.
    func preApprovalRefusal(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> JSONValue? {
        if let error = fileAccessRefusal(tool: tool, input: input) {
            return ChatToolOutcome.failure(error: error, tool: tool)
        }
        if let validating = inner as? any PreApprovalToolValidating {
            return await validating.preApprovalRefusal(tool: tool, input: input, surface: surface)
        }
        return await (inner as? any PureToolArgumentValidating)?.argumentRefusal(tool: tool, input: input)
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
        "shell", "bash", "git", "apply_patch",
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
        // (was: "legacy keystroke tool", "legacy click tool", "legacy scroll tool", "legacy AX act tool", "mac_wake",)
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
        "write_file", "file_write", "apply_patch",
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
        // USER YOLO 2026-08-12: legacy app focus tool / legacy app quit tool freed too.
        // (was: "legacy app focus tool", "legacy app quit tool",)
        // W1b/W3.5 — legacy AX status tool / legacy AX tree tool / legacy AX find tool / mac_view are
        // deliberately NOT listed here. read_only exists to allow exactly this
        // class: they read the on-screen AX tree (and, for mac_view, take a
        // picture of it) and mutate nothing. They are likewise absent
        // from blockedExact/blockedPrefixes above — AX perception is not file
        // access, so fileAccess=none does not bear on it; the Trust Center
        // accessibility category remains their real gate.
        // USER YOLO 2026-08-12: the remaining mac system tools freed.
        // (was: "mac_set_volume", "mac_sleep_display", "mac_lock_screen", "mac_run_shortcut",)
        // W7 — legacy bare cursor move tool is likewise NOT listed. read_only exists to prevent
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
        // (was: "legacy keystroke tool", "legacy click tool", "legacy scroll tool", "legacy AX act tool", "mac_wake",)
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

    private func fileAccessRefusal(tool: String, input: [String: JSONValue]) -> AutonomyGateError? {
        if isPathfulReadUnderNoFileAccess(tool: tool, input: input) {
            return AutonomyGateError.toolDenied(
                reason: "fileAccess=none blocks \(tool) with an explicit path; "
                    + "call it with no path to read what is on screen"
            )
        }
        if isBlocked(tool) {
            // Name the ACTUAL mode — this gate also fires for read_only, and
            // the old hardcoded "fileAccess=none" string lied in that case.
            let modeName = mode == .readOnly ? "read_only" : "none"
            return AutonomyGateError.toolDenied(reason: "fileAccess=\(modeName) blocks \(tool)")
        }
        return nil
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if let error = fileAccessRefusal(tool: tool, input: input) { throw error }
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

    func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        let all = try await inner.listAvailableToolSchemas(named: names)
        return mode == .allow ? all : all.filter { !isBlocked($0.name) }
    }

    // Forward schemas when permitted; filter blocked tools by fileAccess mode.
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        let all = try await inner.listAvailableToolSchemas()
        if mode == .allow { return all }
        return all.filter { !isBlocked($0.name) }
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
    /// This chain's file access, recorded on any card it files.
    private let fileAccess: String?

    /// The peer's line for the floor card: its bracketed notes and lane
    /// label left out, secrets redacted, cut to a glance.
    static func peerQuote(_ text: String) -> String {
        var said = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !($0.hasPrefix("[") && $0.hasSuffix("]")) }
            .joined(separator: " ")
        if said.hasPrefix("[from: "), let end = said.firstIndex(of: "]") { said = String(said[said.index(after: end)...]) }
        said = TurnSecretRedactor.redactText(said).trimmingCharacters(in: .whitespaces)
        return said.count > 240 ? String(said.prefix(240)) + "…" : said
    }

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
        peerDirectoryDataRoot: URL? = nil,
        fileAccess: String? = nil
    ) {
        self.fileAccess = fileAccess
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
            || ["browser_open_url", "browser_navigate", "browser_chrome_navigate",
                "browser_chrome_scroll", "mac_activate_app", "app_activate", "speak", "voice_speak", "sound_play"].contains(name)
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if StandingBotContinuity.isHelperTurn, let pending = ChatTurnExecution.current?.pendingApproval { return pending }
        return try await inner.withToolArguments(tool: tool, input: input) { input in
            try await dispatchNormalized(tool: tool, input: input, surface: surface)
        }
    }

    private func dispatchNormalized(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // W2/W3-FIX-R2 2 — SecurityCenter PERSISTS what it evaluates.
        // `evaluateTool` builds `redactedInputPreview` from this argument and
        // `record` appends it to security/audit.jsonl; its own redactor is
        // generic (secret-SHAPED strings and secret-NAMED keys), and
        // `legacy keystroke tool.text` / `legacy AX act tool.value` are neither — "hunter2" is
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
            origin: .currentTurn(
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

        var autonomyLevel = try await gate.autonomyLevel(
            toolName: tool,
            surface: surface,
            originTrusted: envelope.originTrusted
        )
        let admittedFullMacYolo = envelope.fullMacYoloAuthority == .admitted
        // The saved posture is Full Mac, whoever is asking (a peer or helper
        // surface is never admitted, but it is still running under Full Mac).
        let fullMacOn = [.admitted, .untrustedOrigin].contains(envelope.fullMacYoloAuthority)
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
        // An app door action keeps the level User saved on the old tool it
        // runs in process; SecurityCenter resolved it from the action, and
        // the stricter stands. The card files on the app call, and its
        // approved replay is not asked again.
        if tool == "app", !approvedReplayAuthorizes {
            autonomyLevel = SwiftNativeTrustCenter.moreRestrictiveAutonomy(autonomyLevel, envelope.autonomyLevel)
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
            personaSettingWrite: PeerTurnEffectPolicy.isPersonaSettingWrite(tool: tool, input: input),
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
        if guardResult.source == PersonaWriteGuard.autonomySource
            && !admittedFullMacYolo && !approvedReplayAuthorizes {
            autonomyDecision = .requireApproval(
                reason: "autonomy=\(guardResult.autonomy) source=\(PersonaWriteGuard.autonomySource)"
            )
        } else {
            let mapped = AutonomyGate.map(level: flooredAutonomy, toolName: tool)
            let approvedAsk: Bool
            if case .requireApproval = mapped { approvedAsk = approvedReplayAuthorizes }
            else { approvedAsk = false }
            autonomyDecision = admittedFullMacYolo || approvedAsk
                ? .allow
                : mapped
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
        let botDesktop = StandingBotContinuity.isHelperTurn && !approvedReplayAuthorizes && injectionReplayApprovalID == nil
            && Self.requiresDesktopInteraction(tool: tool, capabilities: envelope.capabilities)
        if case .deny = autonomyDecision {
            decision = autonomyDecision
            securityAsked = false
        } else if botDesktop, !fullMacOn {
            // Under Full Mac her helpers use the desktop on her say (User 10-01);
            // MacAttention still refuses typing over the person.
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
        var decidedRequester: String?
        if botDesktop, fullMacOn, case .allow = decision {
            try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .allow,
                reason: "Agent decided for a helper"))
            decidedRequester = "a helper"
        }
        let peerTurnID = ChatToolSessionContext.envelope?.verifiedUserId
        let taint = PeerDataTaint.current
        // A bridge agent User trusted asks for nothing of its own (User 10-08).
        let trustedBridge = PeerDataTaint.trustedTurn
        let requester = trustedBridge && taint?.isTainted != true ? nil : PeerTurnEffectPolicy.peerRequester(
            surface: surface,
            peerID: peerTurnID,
            peerName: peerDisplayName(peerID: peerTurnID),
            taintSource: taint.flatMap {
                $0.isTainted ? $0.sourceDescription : nil
            }
        )
        // A peer the person elevated frees everything but the floor.
        let elevatedBy = taint?.elevatedSources ?? []
        if !approvedReplayAuthorizes, injectionReplayApprovalID == nil,
           peerReasonMayReplace, requester != nil || !elevatedBy.isEmpty {
            if fullMacOn, PeerTurnEffectPolicy.requiresPeerApproval(tool, capabilities: envelope.capabilities,
                                                                      input: input, fullMac: true) {
                // The Full Mac floor (Agent 10-02): the card names the peer
                // and quotes the line of theirs that led here.
                let sources = taint?.isTainted == true ? taint?.checkpointSources ?? [] : requester == nil ? elevatedBy : []
                let named = sources.map { source -> String in
                    if source.hasPrefix("peer:") { return peerDisplayName(peerID: String(source.dropFirst(5))) ?? source }
                    return source.contains(" ") ? source : source.prefix(1).uppercased() + source.dropFirst()
                }.joined(separator: ", ")
                decision = .requireApproval(reason: PeerTurnEffectPolicy.floorReason(
                    tool: tool, input: input, capabilities: Set(envelope.capabilities), requester: named.isEmpty ? requester ?? "" : named,
                    quote: Self.peerQuote(taint?.lastLine ?? "")))
            } else if let requester, PeerTurnEffectPolicy.requiresPeerApproval(tool, capabilities: envelope.capabilities,
                                                    externalToolIsEffect: externalToolIsEffect,
                                                    input: input,
                                                    workspaceRoot: NativeAgentWorkspaceRoot.resolve(
                                                        dataRoot: peerDirectoryDataRoot ?? defaultDataRoot()),
                                                    // Full Mac file ops resolve relative paths here.
                                                    relativeBases: SwiftToolDispatcher.builderSourceRepoRoot(
                                                        dataRoot: peerDirectoryDataRoot ?? defaultDataRoot()).map { [$0] } ?? []) {
                if fullMacOn {
                    // Hers under Full Mac (User 10-01): no card, and he sees it.
                    if case .allow = decision {
                        try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .allow,
                            reason: "Agent decided for \(requester)"))
                        decidedRequester = requester
                    }
                } else {
                    decision = .requireApproval(
                        reason: PeerTurnEffectPolicy.approvalReason(tool: tool, requester: requester)
                    )
                }
            }
        }
        // THE PERSON'S OWN SEND. Typed in a contact's thread and sent by their
        // click, it needs no card for the send itself. Anything more (running a
        // program on this Mac, a Trust refusal) is said plainly, never carded.
        if PersonInitiatedSend.current?.claim(tool: tool, input: input, surface: surface) == true {
            let name: String = {
                guard case .string(let agent)? = input["agent"], agent.hasPrefix("peer:") else { return "This contact" }
                return peerDisplayName(peerID: String(agent.dropFirst(5))) ?? "This contact"
            }()
            switch decision {
            case .allow: break
            case .requireApproval where Set(envelope.capabilities).isSubset(of: PersonInitiatedSend.sendOnly):
                try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .allow,
                    reason: "person-initiated send from a contact thread"))
                decision = .allow
            case .requireApproval:
                try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .ask,
                    reason: "person-initiated send needs more than the send"))
                return PersonInitiatedSend.refusal("\(name) runs on this Mac, and your Trust setting asks before starting it. Nothing was sent.")
            case .deny:
                try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .block,
                    reason: "person-initiated send refused by Trust"))
                return PersonInitiatedSend.refusal("Your Trust settings don't allow messaging \(name) right now. Nothing was sent.")
            }
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
            let result = try await runInner(
                tool: tool,
                input: input,
                surface: surface,
                injectionApprovalID: injectionReplayApprovalID ?? (approvedReplayAuthorizes ? approvedReplay?.approvalID : nil),
                // Reaching .allow IS the person's go-ahead: their approval, or Full Mac.
                personApprovedHost: namedConnect
            )
            if let decidedRequester, !trustedBridge,
               ChatToolOutcome.exactResultClass(result) == .succeeded {
                HarnessDecidedRow.post(requester: decidedRequester, tool: tool, sessionID: verifiedSessionId,
                                      dataRoot: peerDirectoryDataRoot ?? defaultDataRoot(), ran: true)
            }
            return result
        case .deny(let reason):
            try? await securityCenter.record(Self.securityEnvelope(envelope, decision: .block, reason: reason))
            throw AutonomyGateError.toolDenied(reason: reason)
        case .requireApproval(let gateReason):
            // A skill's step never files a card: it hands back to her.
            if SkillRunContext.handsBack { return SkillRunContext.handBack(ApprovalActionText.reason(gateReason, tool: tool)) }
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
                if let refusal { return Self.refusedBeforeRunning(refusal) }
            } else if let validating = inner as? any PureToolArgumentValidating,
                      let refusal = await validating.argumentRefusal(tool: tool, input: input) {
                return Self.refusedBeforeRunning(refusal)
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
            // legacy keystroke tool carries the literal characters Agent is about to
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
                if StandingBotContinuity.isHelperTurn { ChatTurnExecution.current?.keepApproval(id: approvalId, pending) }
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
        return try await ChatToolSessionContext.$fileAccess.withValue(fileAccess) {
            try await ChatToolSessionContext.$verifiedSessionId.withValue(
                filingSessionId,
                operation: body
            )
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
    /// Secret-bearing calls restore their approved arguments from memory before
    /// dispatch, whether or not they use a MacInjectionCapability.
    private func runInner(
        tool: String,
        input: [String: JSONValue],
        surface: String,
        injectionApprovalID: String?,
        personApprovedHost: Bool = false
    ) async throws -> JSONValue {
        var effectiveInput = input
        var capability: MacInjectionCapability?

        if MacInjectionArgRedaction.isRedacted(tool: tool, input: input) {
            guard let approvalID = injectionApprovalID,
                  let secrets = await MacInjectionSecretVault.shared.take(approvalID: approvalID),
                  !secrets.isEmpty else {
                throw AutonomyGateError.toolDenied(
                    reason: "injection_secret_unavailable: the approved text for \(tool) is no "
                        + "longer held in memory (app restarted or already replayed). Ask again."
                )
            }
            effectiveInput = MacInjectionArgRedaction.rehydrated(tool: tool, input: input, secrets: secrets)
            guard !MacInjectionArgRedaction.isRedacted(tool: tool, input: effectiveInput),
                  MacInjectionArgRedaction.redacted(tool: tool, input: effectiveInput) == input else {
                throw AutonomyGateError.toolDenied(reason: "injection_secret_mismatch: approved text for \(tool) could not be verified.")
            }
        } else if let approvalID = injectionApprovalID {
            // An approval resolved in this call still has its original arguments.
            _ = await MacInjectionSecretVault.shared.take(approvalID: approvalID)
        }

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
    func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names)
    }

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

    /// Refused before it ran or a card was filed: nothing changed.
    private static func refusedBeforeRunning(_ refusal: JSONValue) -> JSONValue {
        guard case .object(var fields) = refusal, fields["effects"] == nil else { return refusal }
        fields["effects"] = .string("none")
        return .object(fields)
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
