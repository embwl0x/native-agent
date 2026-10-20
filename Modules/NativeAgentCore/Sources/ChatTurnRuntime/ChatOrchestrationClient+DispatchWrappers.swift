import AuthoredCapabilities
import AgentWorkspace
import Experiences
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

/// Carries the chain's file access down to the organs that read it and refuses
/// what no name can decide: an unrecognized mode, and under `none` a read that
/// names a file. Which calls a restriction admits is the posture and the
/// call's declared class, decided once in TrustCenter, never a tool-name list.
final class FileAccessGatedDispatcher: ToolDispatchClient, PreApprovalToolValidating, @unchecked Sendable {
    private let inner: any ToolDispatchClient
    private let mode: Mode
    private let fileAccess: String

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
        case invalid

        init(_ fileAccess: String) {
            switch fileAccess.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "workspace", "auto", "full": self = .allow
            case "read_only", "readonly", "read-only": self = .readOnly
            case "none": self = .none
            default: self = .invalid
            }
        }
    }

    /// All turns read the Mac's saved choice; a request can only restrict it.
    /// A saved read-only is User's posture echoed (Trust syncs it), and the
    /// law already judges every call by posture, so it fences nothing here;
    /// a caller's own read-only request (the bridge, the phone) still does.
    static func sharedFileAccess(_ requested: String) -> String {
        let saved = UserDefaults.standard.string(forKey: "chatFileAccess") ?? "auto"
        let savedMode = Mode(saved), requestedMode = Mode(requested)
        if savedMode == .invalid { return "invalid saved chatFileAccess: \(saved)" }
        if requestedMode == .invalid { return "invalid request fileAccess: \(requested)" }
        if savedMode == .none || requestedMode == .none { return "none" }
        if requestedMode == .readOnly { return "read_only" }
        return savedMode == .readOnly ? "auto" : saved
    }

    init(inner: any ToolDispatchClient, fileAccess: String) {
        self.inner = inner
        self.mode = Mode(fileAccess)
        self.fileAccess = fileAccess
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

    private func fileAccessRefusal(tool: String, input: [String: JSONValue]) -> ToolFailureError? {
        let source = "effective request fileAccess=\(fileAccess); saved chatFileAccess=\(UserDefaults.standard.string(forKey: "chatFileAccess") ?? "auto")"
        if mode == .invalid {
            return ToolFailureError("\(source) is unrecognized; no file access was inferred.", argumentPath: "request.fileAccess",
                accepted: "auto, workspace, full, read_only, readonly, read-only, none", effects: .none)
        }
        let action = ToolNameAliases.foldedTools[tool] ?? tool
        let read = ["files.read", "files.list", "files.info", "files.excerpt", "files.grep"].contains(action)
        let write = ["files.write", "files.copy", "files.move", "files.trash"].contains(action)
        func withinReach(_ key: String, write: Bool) -> Bool {
            guard case .string(let path)? = input[key], HomePath.expand(path).hasPrefix("/") else { return false }
            return AbilityStore.fileReachAllows(URL(fileURLWithPath: HomePath.expand(path)), write: write)
        }
        if (read || write), withinReach("path", write: write && action != "files.copy"),
           !["files.copy", "files.move"].contains(action) || withinReach("destination", write: true) { return nil }
        if isPathfulReadUnderNoFileAccess(tool: tool, input: input) {
            return ToolFailureError("\(source) blocks \(tool) with an explicit path. The request issuer must resubmit with file access; changing the requested operation to a screen read would not repair this file read.", effects: .none)
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
        // The call runs under this chain's file access, so a worker it starts
        // (a swarm) keeps the same fence.
        return try await MacControlTurnFileAccess.$deniesFileReads.withValue(mode == .none) {
            try await ChatToolSessionContext.$fileAccess.withValue(fileAccess) {
                try await inner.dispatch(tool: tool, input: input, surface: surface)
            }
        }
    }

    func listAvailableTools() async throws -> [String] { try await inner.listAvailableTools() }

    func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names)
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { try await inner.listAvailableToolSchemas() }
}

/// The file access the chat hands its chain, for the permissions proof.
package func sharedChatFileAccess(_ requested: String) -> String { FileAccessGatedDispatcher.sharedFileAccess(requested) }

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
    private let approvalTimeoutSeconds: Double
    private let verifiedSessionId: String?
    private let approvedReplay: ApprovedChatToolReplay?
    /// The canonical inbox verifies and spends an approval before exemption or minting.
    private let injectionApprovalVerifier: ApprovalInboxInjectionApprovalVerifier
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

    init(
        inner: any ToolDispatchClient,
        gate: AutonomyGate,
        approvalFiler: (any ApprovalFiler)? = nil,
        securityCenter: SwiftNativeSecurityCenter = SwiftNativeSecurityCenter(),
        approvalTimeoutSeconds: Double = 30,
        verifiedSessionId: String? = nil,
        approvedReplay: ApprovedChatToolReplay? = nil,
        injectionApprovalVerifier: ApprovalInboxInjectionApprovalVerifier,
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
        self.approvalTimeoutSeconds = approvalTimeoutSeconds
        self.verifiedSessionId = verifiedSessionId
        self.approvedReplay = approvedReplay
        self.injectionApprovalVerifier = injectionApprovalVerifier
    }

    /// The audit row this decision owes. A write that fails is a receipt owed
    /// under the audit file, never dropped; the decision itself stands.
    private func audit(_ envelope: SecurityToolEnvelope) async {
        do { try await securityCenter.record(envelope) } catch {
            let file = securityCenter.dataRoot.appendingPathComponent("security/audit.jsonl").path
            RepairOwed.owe(securityCenter.dataRoot, id: "security-audit:" + UUID().uuidString, kind: .run,
                operation: "security.audit", owner: file,
                words: "The security audit row for \(envelope.tool) (\(envelope.decision.rawValue)) was not written: \(error.localizedDescription)",
                nextCall: ToolFailureError.call("app", ["action": .string("files.info"), "args": .object(["path": .string(file)])]))
        }
    }

    private static func requiresDesktopInteraction(tool: String, capabilities: [String]) -> Bool {
        let name = tool.replacingOccurrences(of: ".", with: "_")
        if name.hasPrefix("bot_") || name.hasPrefix("shelf_") { return false }
        return !Set(capabilities).isDisjoint(with: ["ax_injection", "hid_injection", "browser_interaction", "notification", "system_control", "shell", "process_spawn"])
            || ["browser_open_url", "browser_navigate", "browser_chrome_navigate",
                "browser_chrome_scroll", "mac_activate_app", "app_activate", "speak", "voice_speak", "sound_play"].contains(name)
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        try Task.checkCancellation()
        if StandingBotContinuity.isHelperTurn, let pending = ChatTurnExecution.current?.pendingApproval { return pending }
        return try await inner.withToolArguments(tool: tool, input: input) { input in
            guard SkillRunContext.partID != nil, !SkillRunContext.handsBack else {
                return try await dispatchNormalized(tool: tool, input: input, surface: surface)
            }
            let id = UUID()
            let call = AuthoredToolEffects.call, reach = AbilityStore.fileReach
            let events = await ApprovalLifecycleBus.shared.events(forHostCall: id, context: { work in
                try await AbilityStore.$fileReach.withValue(reach) {
                    try await AuthoredToolEffects.$call.withValue(call) { try await work() }
                }
            })
            do {
                var result = try await SkillRunContext.$hostCallID.withValue(id) {
                    try await dispatchNormalized(tool: tool, input: input, surface: surface)
                }
                if let approval = Self.jsonString(SessionHistoryPromptRenderer.receiptField("approvalId", in: result))
                    ?? Self.jsonString(SessionHistoryPromptRenderer.receiptField("approval_id", in: result)),
                   ChatToolOutcome.isWaitingOnPerson(result) {
                    var event = try await TurnDeadline.withHumanWait {
                        for await event in events where event.record.id == approval { return event }
                        throw CancellationError()
                    }
                    if event.phase != .executed, event.record.decision == "approved" {
                        for await settled in events where settled.phase == .executed && settled.record.id == approval {
                            event = settled
                            break
                        }
                    }
                    try Task.checkCancellation()
                    result = event.record.decision == "approved" ? event.result
                        ?? .object(["status": .string("failed"), "reason": .string("card_outcome_unavailable"),
                            "detail": .string("The approved action returned no outcome; check its receipt before continuing.")])
                        : .object(["status": .string("failed"), "reason": .string(event.record.status == "orphaned" ? "approval_expired" : "declined"),
                            "detail": .string("workflows/approvals/requests.json card \(approval): status=\(event.record.status), decision=\(event.record.decision ?? "unanswered"). Nothing ran; the part is no longer waiting."), "effects": .string("none")])
                    if event.record.status == "orphaned", case .object(var fields) = result {
                        fields["remedy"] = .object(["kind": .string("correct_arguments"),
                            "instruction": .string("This card expired; revise or withdraw the work, or request it again if still needed."),
                            "next_call": .object(["tool": .string(tool), "input": .object(input)])])
                        result = .object(fields)
                    }
                }
                await ApprovalLifecycleBus.shared.finish(id)
                if let need = InlineInteractionNeed.interaction(in: result) {
                    guard let wait = AppDoorReentry.waitForInteraction else {
                        throw ToolFailureError("A card needs the originating conversation.", effects: .none)
                    }
                    result = await wait(need, tool, input)
                }
                return result
            } catch {
                await ApprovalLifecycleBus.shared.finish(id)
                throw error
            }
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
                if case .string(let name)? = input["name"], let row = AgentHostDirectory.row(named: name),
                   let line = row.commandLine, let path = row.resolveExecutable(line.executable) {
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
        // structurally dead. .ask now routes into the
        // requireApproval flow below (filer / resolveWithApproval / honest
        // no-filer deny), exactly like an autonomy-level requireApproval.
        if envelope.decision == .block {
            await audit(envelope)
            throw AutonomyGateError.toolDenied(reason: envelope.primaryReason, remedy: envelope.remedy)
        }

        // SecurityCenter judged this exact call once (its roots, profile,
        // class and reach, then User's saved entries); that is the answer.
        let autonomyLevel = envelope.autonomyLevel
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
                    + ". Authority: workflows/approvals/requests.json and effect_spends.json. Inspect this card's execution receipt and the effect owner's state before any new request; a missing or unreadable spend does not prove nothing ran."
                await audit(
                    Self.securityEnvelope(envelope, decision: .block, reason: reason)
                )
                let store = verdict == .spendUnavailable || verdict == .notSpentByExecutor ? "effect_spends.json" : "requests.json"
                let path = (peerDirectoryDataRoot ?? defaultDataRoot()).appendingPathComponent("workflows/approvals/" + store).path
                let remedy: JSONValue = .object(["kind": .string("inspect"),
                    "instruction": .string("Inspect approval \(replay.approvalID) in requests.json and effect_spends.json, then reconcile the effect owner's receipt. This replay did not run; the earlier effect is unknown. Reading these files does not establish the outcome or authorize a resend."),
                    "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("files.read"),
                        "args": .object(["path": .string(path)])])])])
                return .object(["status": .string("failed"), "reason": .string(reason), "effects": .string("unknown"), "remedy": remedy])
            }
            approvedReplayAuthorizes = true
        } else {
            approvedReplayAuthorizes = false
        }
        // The first conversation's one documented line still spends its token,
        // which arms the voice step after it; posture alone authorizes the write.
        if surface == "chat" {
            _ = FirstConversationPersonaExemption.consumeIfExempt(
                tool: tool, input: input, dataRoot: firstConversationDataRoot, sessionID: verifiedSessionId)
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
            let verdict = await injectionApprovalVerifier.verifyInjectionApproval(
                approvalID: replay.approvalID,
                tool: tool,
                surface: surface,
                input: input
            )
            guard verdict == .verified else {
                let reason = "injection_replay_evidence_unverified: \(verdict.rawValue) "
                    + "(\(tool) replay claimed approval \(replay.approvalID))"
                await audit(
                    Self.securityEnvelope(envelope, decision: .block, reason: reason)
                )
                throw AutonomyGateError.toolDenied(reason: reason)
            }
            injectionReplayApprovalID = replay.approvalID
        }
        let autonomyDecision: AutonomyDecision
        switch AutonomyGate.map(level: autonomyLevel, toolName: tool) {
        case .requireApproval where approvedReplayAuthorizes: autonomyDecision = .allow
        case .requireApproval: autonomyDecision = .requireApproval(reason: envelope.autonomyReason ?? "autonomy=\(autonomyLevel)")
        case .deny: autonomyDecision = .deny(reason: envelope.autonomyReason ?? "autonomy=\(autonomyLevel)")
        case .allow: autonomyDecision = .allow
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
        // through to the missing-filer deny below and mail_send / messages_send /
        // mail_reply were consumed and then refused. The exemption is bound to
        // the exact persisted tool, surface, body and verified origin, and it
        // does NOT cover injection tools — those keep the inbox-verified
        // `injectionReplayApprovalID` path above, which is stricter.
        // `approvedReplayAuthorizes` was resolved (and the approval record
        // verified and burned) above.
        if approvedReplayAuthorizes, envelope.requiresApproval {
            // The exemption is audited, not silent.
            await audit(Self.securityEnvelope(
                envelope,
                decision: .allow,
                reason: "approved replay of \(tool) honours approval "
                    + "\(approvedReplay?.approvalID ?? "unknown")"
            ))
        }
        let securityAsked: Bool
        var decision: AutonomyDecision
        let botDesktop = StandingBotContinuity.isHelperTurn && !approvedReplayAuthorizes && injectionReplayApprovalID == nil
            && Self.requiresDesktopInteraction(tool: tool, capabilities: envelope.capabilities)
        if case .deny = autonomyDecision {
            decision = autonomyDecision
            securityAsked = false
        } else if envelope.requiresApproval, !approvedReplayAuthorizes {
            decision = .requireApproval(
                reason: envelope.primaryReason
            )
            securityAsked = true
        } else {
            decision = autonomyDecision
            securityAsked = false
        }
        // 09-15 ruling: a peer turn asks; it does not refuse. Elevation is
        // the person's alone. A Trust deny stands; only a verified replay
        // answers the same card, and Full Mac keeps an allowed connect allowed.
        let peerReasonMayReplace: Bool
        if case .deny = decision { peerReasonMayReplace = false } else { peerReasonMayReplace = true }
        let protectedAction = PeerTurnEffectPolicy.requiresPeerApproval(tool, capabilities: envelope.capabilities,
            externalToolIsEffect: externalToolIsEffect, input: input,
            workspaceRoot: NativeAgentWorkspaceRoot.resolve(dataRoot: peerDirectoryDataRoot ?? defaultDataRoot()),
            relativeBases: SwiftToolDispatcher.builderSourceRepoRoot(
                dataRoot: peerDirectoryDataRoot ?? defaultDataRoot()).map { [$0] } ?? [])
        var decidedRequester = fullMacOn && protectedAction
            && ChatToolSessionContext.envelope?.workIdentity?.hasPrefix("carry.") == true ? "Full Mac" : nil
        if botDesktop, fullMacOn, case .allow = decision {
            await audit(Self.securityEnvelope(envelope, decision: .allow,
                reason: "Agent decided for a helper"))
            decidedRequester = "a helper"
        }
        let peerTurnID = ChatToolSessionContext.envelope?.verifiedUserId
        let taint = PeerDataTaint.current
        let trustedBridge = PeerDataTaint.trustedTurn
        let peerApproval = PeerDataTaintDispatcher.peerApproval(tool: tool, capabilities: envelope.capabilities, input: input,
            surface: surface, fullMac: fullMacOn, protectedAction: protectedAction, peerName: peerDisplayName(peerID: peerTurnID))
        let requester = peerApproval.requester
        // The person answered this command's card (one card per command, User
        // 10-20): the peers that steer this run act for the rest of it.
        if approvedReplayAuthorizes || injectionReplayApprovalID != nil, let taint, requester != nil {
            for source in taint.checkpointSources where !PeerDataTaint.ownerTrusts(source) { taint.elevate(peer: source) }
            if let peerTurnID { taint.elevate(peer: "peer:" + peerTurnID) }
        }
        if !approvedReplayAuthorizes, injectionReplayApprovalID == nil,
           peerReasonMayReplace, requester != nil {
            if fullMacOn, peerApproval.required {
                // The Full Mac floor (Agent 10-02): the card names the peer
                // that steers and quotes the line of theirs that led here.
                let sources = (taint?.checkpointSources ?? []).filter { !PeerDataTaint.ownerTrusts($0) }
                let named = sources.map { source -> String in
                    if source.hasPrefix("peer:") { return peerDisplayName(peerID: String(source.dropFirst(5))) ?? source }
                    return source.contains(" ") ? source : source.prefix(1).uppercased() + source.dropFirst()
                }.joined(separator: ", ")
                decision = .requireApproval(reason: PeerTurnEffectPolicy.floorReason(
                    tool: tool, input: input, capabilities: Set(envelope.capabilities), requester: named.isEmpty ? requester ?? "" : named,
                    quote: Self.peerQuote(taint?.lastLine ?? "")))
            } else if let requester, protectedAction {
                if fullMacOn {
                    // Hers under Full Mac (User 10-01): no card, and he sees it.
                    if case .allow = decision {
                        await audit(Self.securityEnvelope(envelope, decision: .allow,
                            reason: "Agent decided for \(requester)"))
                        decidedRequester = requester
                    }
                } else if peerApproval.required {
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
                await audit(Self.securityEnvelope(envelope, decision: .allow,
                    reason: "person-initiated send from a contact thread"))
                decision = .allow
            case .requireApproval:
                await audit(Self.securityEnvelope(envelope, decision: .ask,
                    reason: "person-initiated send needs more than the send"))
                return PersonInitiatedSend.refusal("\(name) runs on this Mac, and your Trust setting asks before starting it. Nothing was sent.")
            case .deny:
                await audit(Self.securityEnvelope(envelope, decision: .block,
                    reason: "person-initiated send refused by Trust"))
                return PersonInitiatedSend.refusal("Your Trust settings don't allow messaging \(name) right now. Nothing was sent.")
            }
        }
        try Task.checkCancellation()
        switch decision {
        case .allow:
            if AuthoredToolEffects.call?.tool == tool {
                await audit(Self.securityEnvelope(envelope, decision: .allow, reason: "admitted"))
            }
            if AuthoredToolEffects.admissionOnly {
                return .object(["status": .string("admitted"), "effects": .string("none"),
                                "execution": .string("not_run"), "reason": .string("admitted")])
            }
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
            if let decidedRequester, !trustedBridge, tool != "app",
               ChatToolOutcome.exactResultClass(result) == .succeeded {
                HarnessDecidedRow.post(requester: decidedRequester, tool: tool, sessionID: verifiedSessionId,
                                      dataRoot: peerDirectoryDataRoot ?? defaultDataRoot(), ran: true)
            }
            return result
        case .deny(let reason):
            await audit(Self.securityEnvelope(envelope, decision: .block, reason: reason))
            throw AutonomyGateError.toolDenied(reason: reason, remedy: envelope.remedy)
        case .requireApproval(let gateReason):
            // A switch User turned off refuses before any card, whatever the
            // posture: a card never asks for what the switch would refuse.
            if let gate = ToolPreloadHeuristics.macIntegrationGates[tool] {
                let root = peerDirectoryDataRoot ?? defaultDataRoot()
                let store = root == defaultDataRoot() ? MacIntegrationPermissionStore.shared : MacIntegrationPermissionStore(dataRoot: root)
                if let refusal = try await SwiftToolDispatcher.switchRefusal(integration: gate.integration, mode: gate.mode, store: store) {
                    return ChatToolOutcome.refusedBeforeRunning(refusal)
                }
            }
            // A skill's step never files a card: it hands back to her.
            if SkillRunContext.handsBack, !AuthoredToolEffects.admissionOnly { return SkillRunContext.handBack(ApprovalActionText.reason(gateReason, tool: tool)) }
            // Preserve the deciding rule alongside the implementation's disclosure.
            var reason = ApprovalActionText.reason(gateReason, tool: tool)
            if let cause = envelope.autonomyReason, !reason.contains(cause) { reason += " " + cause }
            if tool.hasPrefix("fetch."), case .string(let raw)? = input["url"], let url = URL(string: raw) {
                let method = Self.jsonString(input["method"])?.uppercased() ?? "GET"
                reason = "\(method) \(url.host ?? "")\(url.path) through \(tool). \(reason)"
            } else if let validating = inner as? any PreApprovalToolValidating,
               let disclosed = await validating.approvalCardReason(
                tool: tool, input: input, surface: surface) {
                reason = disclosed + " " + reason
            }
            // Nothing the implementation would have refused outright is worth a
            // person's click. The inner dispatcher runs its own cheap, certain
            // checks — is this tool loaded for the turn, do its arguments parse
            // — and a refusal here comes back to the model as an ordinary tool
            // error, with no approval filed (2026-09-13, the 0.4.12 drive: two
            // bot_create calls raised a card and only then failed on cadence).
            // A part's hand on its watched window is answered by Screen
            // control's card first, as act is.
            let primitiveCall = AuthoredToolEffects.call?.tool == tool && !AuthoredToolEffects.handOperations.contains(tool)
            if !primitiveCall, !AuthoredToolEffects.admissionOnly, let validating = inner as? any PreApprovalToolValidating {
                let refusal = await ChatToolSessionContext.$verifiedSessionId.withValue(
                    verifiedSessionId ?? ChatToolSessionContext.verifiedSessionId
                ) {
                    await validating.preApprovalRefusal(tool: tool, input: input, surface: surface)
                }
                if let refusal { return ChatToolOutcome.refusedBeforeRunning(refusal) }
            } else if !primitiveCall, !AuthoredToolEffects.admissionOnly, let validating = inner as? any PureToolArgumentValidating,
                      let refusal = await validating.argumentRefusal(tool: tool, input: input) {
                return ChatToolOutcome.refusedBeforeRunning(refusal)
            }
            let ownsACPConnectCard: Bool
            if tool == "agent_connect", case .string(let name)? = input["name"],
               input["endpoint"] == nil, input["app_bundle_id"] == nil,
               input["disconnect"] == nil,
               input["transport"] == nil || input["transport"] == .string("auto") {
                ownsACPConnectCard = AgentHostDirectory.row(named: name)?.acp != nil
            } else { ownsACPConnectCard = false }
            if !securityAsked, envelope.capabilities.contains("approval_stage") || ownsACPConnectCard {
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
            guard approvalFiler != nil, !AuthoredToolEffects.admissionOnly || approvalFiler is any NonBlockingApprovalFiler else {
                await audit(Self.securityEnvelope(envelope, decision: .ask, reason: reason))
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
                await audit(Self.securityEnvelope(envelope, decision: .ask, reason: reason))
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
                if let remedy = envelope.remedy, case .object(var fields) = pending {
                    fields["remedy"] = remedy
                    pending = .object(fields)
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
                    let verdict = await injectionApprovalVerifier.verifyInjectionApproval(
                        approvalID: resolved.approvalID ?? "",
                        tool: tool,
                        surface: surface,
                        input: input
                    )
                    guard verdict == .verified else {
                        let r = "injection_approval_unverified: \(verdict.rawValue) "
                            + "(\(tool) resolved approval \(resolved.approvalID ?? "<none>"))"
                        await audit(
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
                await audit(Self.securityEnvelope(envelope, decision: .block, reason: r))
                throw AutonomyGateError.notRun(resolved.notRunStatus ?? .blocked)
            case .requireApproval(let r):
                await audit(Self.securityEnvelope(envelope, decision: .ask, reason: r))
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
        try Task.checkCancellation()
        return try await ChatToolSessionContext.$verifiedSessionId.withValue(verifiedSessionId) {
            // Bound even when nil: a non-injection tool must never inherit a
            // capability left in scope by an enclosing task.
            try await MacInjectionCapabilityContext.$current.withValue(finalCapability) {
                try await AgentHostConnection.$personApproved.withValue(personApprovedHost) {
                    if let call = AuthoredToolEffects.call, call.tool == tool { return try await call.perform() }
                    if AuthoredToolEffects.primitiveCapabilities[tool] != nil || tool.hasPrefix("fetch.") {
                        throw AutonomyGateError.toolDenied(reason: "The originating part run ended. Call the part again; its broker cannot be recreated for replay.")
                    }
                    return try await inner.dispatch(tool: tool, input: finalInput, surface: surface)
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

    private static func jsonString(_ raw: JSONValue?) -> String? {
        switch raw {
        case .string(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
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
