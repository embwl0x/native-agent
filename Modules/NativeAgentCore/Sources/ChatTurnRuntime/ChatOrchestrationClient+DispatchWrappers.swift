import AuthoredCapabilities
import NativeAgentShared
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
import ProviderRouting
import ToolRegistry
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import StandingBots
// Blueprint: | `ChatOrchestrationClient+DispatchWrappers.swift` | `FileAccessGatedDispatcher` class; `preApprovalRefusal`, `approvalCardReason`, `sharedFileAccess`; carries the chain's file access to the organs and refuses only an unrecognized mode and a pathful read under `none` (no tool-name lists; admission is posture × declared class in TrustCenter); peer approval uses the declared class without an external-tool resolver; `AutonomyGatedDispatcher` audit rows that fail are owed repairs |

/// Carries the chain's file access down to the organs that read it and refuses
/// what no name can decide: an unrecognized mode, and under `none` a read that
/// names a file. Which calls a restriction admits is the posture and the
/// call's declared class, decided once in TrustCenter, never a tool-name list.
final class FileAccessGatedDispatcher: ToolDispatchClient, PreApprovalToolValidating, Sendable {
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

    private enum Mode: Equatable, Sendable {
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

    /// Under `none`, a pathful Mac read opens a file and must be refused.
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
        if isPathfulReadUnderNoFileAccess(tool: tool, input: input) {
            return ToolFailureError("\(source) blocks \(tool) with an explicit path. The request issuer must resubmit with file access; changing the requested operation to a screen read would not repair this file read.", effects: .none)
        }
        return nil
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if let error = fileAccessRefusal(tool: tool, input: input) { throw error }
        return try await ChatToolSessionContext.$fileAccess.withValue(fileAccess) {
            try await inner.dispatch(tool: tool, input: input, surface: surface)
        }
    }

    func listAvailableTools() async throws -> [String] { try await inner.listAvailableTools() }

    func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names)
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { try await inner.listAvailableToolSchemas() }
}

/// Routes every tool dispatch through an AutonomyGate decision BEFORE
/// invoking the inner dispatcher. On `.deny`, throws AutonomyGateError so
/// the tool loop records it as a tool-result error and continues (mirrors
/// the loop's failure-recovery behavior).
final class AutonomyGatedDispatcher: ToolDispatchClient, Sendable {
    private let inner: any ToolDispatchClient
    private let gate: AutonomyGate
    private let approvalFiler: (any ApprovalFiler)?
    private let securityCenter: SwiftNativeSecurityCenter
    private let approvalTimeoutSeconds: Double
    private let verifiedSessionId: String?
    private let approvedReplay: ApprovedChatToolReplay?
    /// The canonical inbox verifies and spends an approval before exemption or minting.
    private let injectionApprovalVerifier: ApprovalInboxInjectionApprovalVerifier
    /// Non-injection replays require a matching approved record just spent by the executor.
    private let approvedReplayVerifier: ApprovalInboxApprovedReplayVerifier
    /// The data root whose persona documents a first-conversation write would
    /// target — supplied ONLY by the Mac chat dispatcher, and nil on every
    /// other chain (bridge, background, ephemeral, approval replay), which is
    /// what keeps progression on one surface. Nil cannot advance a step;
    /// the persona root is never inferred from a process-wide default.
    /// See `FirstConversationPersonaProgression`.
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
        approvedReplayVerifier: ApprovalInboxApprovedReplayVerifier,
        firstConversationDataRoot: URL? = nil,
        peerDirectoryDataRoot: URL? = nil,
        fileAccess: String? = nil
    ) {
        self.fileAccess = fileAccess
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
                if let approval = (ChatTranscriptEvidenceRendering.receiptField("approvalId", in: result))?.scalarText.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 })
                    ?? (ChatTranscriptEvidenceRendering.receiptField("approval_id", in: result))?.scalarText.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }),
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
                        ?? .object(["status": .string("unknown"), "reason": .string("card_outcome_unavailable"),
                            "effects": .string("unknown"), "approval_id": .string(approval),
                            "detail": .string("Approved card \(approval) returned no outcome; approval alone does not prove the action completed."),
                            "remedy": Repair.reconcile(instruction: "Read this exact card's retained execution record, then inspect the affected state before repeating the action.",
                                nextCall: .object(["tool": .string("app"), "input": .object([
                                    "action": .string("files.read"), "args": .object(["path": .string(securityCenter.dataRoot.appendingPathComponent("workflows/approvals/requests.json").path)])])]))])
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
                        throw ToolFailureError("Card \(need.id) cannot resume because the originating conversation is not bound to this call.",
                            effects: .unknown, owner: "originating conversation",
                            nextCall: (try? SwiftNativeTurnEngine.dispatchReceiptCall().serialize(pretty: false)),
                            code: "card_conversation_unavailable",
                            instruction: "Read this turn's receipts to locate the conversation for this card, then resolve the existing card there. Check its outcome before requesting the action again.", recovery: .reconcile)
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
        // SecurityCenter persists evaluated arguments: pass injection count/digest
        // redaction across that boundary, keeping execution characters in memory.
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
        // Only .block hard-denies here; .ask enters the approval flow and denies if no filer exists.
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
        // Verify every replay against the inbox and burn its exemption for one dispatch; unverified replays are denied.
        let approvedReplayAuthorizes: Bool
        if !MacInjectionToolNames.isInjectionTool(tool),
           let replay = approvedReplay,
           replay.matches(
            tool: tool,
            surface: surface,
            input: input,
            verifiedSessionID: verifiedSessionId
           ) {
            let verdict = await approvedReplayVerifier.verifyApprovedReplay(
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
            _ = FirstConversationPersonaProgression.advanceIfMatching(
                tool: tool, input: input, dataRoot: firstConversationDataRoot, sessionID: verifiedSessionId)
        }
        // Injection replay requires a real, approved, unspent inbox record bound
        // to the exact tool, surface, body and verified origin, checked before
        // exemption and minting. Unverified replay is denied without another ask.
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
        // Deny outranks ask, and security ask outranks autonomy allow; only autonomy approvals use the staging shortcut.
        // Verified replays bypass a second ask, bound to the persisted tool, surface, body and verified origin.
        // Injection tools require the separate inbox-verified injectionReplayApprovalID path.
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
        // Peer turns ask for person-owned elevation; Trust denial stands, verified
        // replay answers the same card, and Full Mac preserves an allowed connect.
        let peerReasonMayReplace: Bool
        if case .deny = decision { peerReasonMayReplace = false } else { peerReasonMayReplace = true }
        let protectedAction = PeerTurnEffectPolicy.requiresPeerApproval(tool, input: input)
        var decidedRequester = fullMacOn && protectedAction
            && ChatToolSessionContext.envelope?.workIdentity?.hasPrefix("carry.") == true ? "Full Mac" : nil
        if botDesktop, fullMacOn, case .allow = decision {
            await audit(Self.securityEnvelope(envelope, decision: .allow,
                reason: "The agent decided for a helper"))
            decidedRequester = "a helper"
        }
        let peerTurnID = ChatToolSessionContext.envelope?.verifiedUserId
        let taint = PeerDataTaint.current
        let trustedBridge = PeerDataTaint.trustedTurn
        let peerApproval = PeerDataTaintDispatcher.peerApproval(surface: surface,
            protectedAction: protectedAction, peerName: peerDisplayName(peerID: peerTurnID))
        let requester = peerApproval.requester
        // A person-approved command elevates its steering peers for this turn.
        if approvedReplayAuthorizes || injectionReplayApprovalID != nil, let taint, requester != nil {
            for source in taint.checkpointSources where !PeerDataTaint.ownerTrusts(source) { taint.elevate(peer: source) }
            if let peerTurnID { taint.elevate(peer: "peer:" + peerTurnID) }
        }
        if !approvedReplayAuthorizes, injectionReplayApprovalID == nil,
           peerReasonMayReplace, requester != nil {
            if fullMacOn, peerApproval.required {
                // The Full Mac card names steering peers and quotes their relevant line.
                let sources = (taint?.checkpointSources ?? []).filter { !PeerDataTaint.ownerTrusts($0) }
                let named = sources.map { source -> String in
                    if source.hasPrefix("peer:") { return peerDisplayName(peerID: String(source.dropFirst(5))) ?? source }
                    return source.contains(" ") ? source : source.prefix(1).uppercased() + source.dropFirst()
                }.joined(separator: ", ")
                decision = .requireApproval(reason: PeerTurnEffectPolicy.floorReason(
                    tool: tool, input: input, requester: named.isEmpty ? requester ?? "" : named,
                    quote: Self.peerQuote(taint?.lastLine ?? "")))
            } else if let requester, protectedAction {
                if fullMacOn {
                    // Under Full Mac, audit the agent's allowed decision for the requester.
                    if case .allow = decision {
                        await audit(Self.securityEnvelope(envelope, decision: .allow,
                            reason: "The agent decided for \(requester)"))
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
            if let gate = MacIntegrationGates.byTool[tool] {
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
                let method = input["method"]?.scalarText.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 })?.uppercased() ?? "GET"
                reason = "\(method) \(url.host ?? "")\(url.path) through \(tool). \(reason)"
            } else if let validating = inner as? any PreApprovalToolValidating,
               let disclosed = await validating.approvalCardReason(
                tool: tool, input: input, surface: surface) {
                reason = disclosed + " " + reason
            }
            // Pre-approval validation returns certain refusals as tool errors without filing an approval.
            // Screen control's card admits a part's hand on its watched window before primitive validation.
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
            if namedConnect, case .string(let name)? = input["name"] {
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
            // File approval and await gate resolution; without a usable filer,
            // deny explicitly so the loop records the rejection.
            guard approvalFiler != nil, !AuthoredToolEffects.admissionOnly || approvalFiler is any NonBlockingApprovalFiler else {
                await audit(Self.securityEnvelope(envelope, decision: .ask, reason: reason))
                // Raw/noninteractive callers can deliberately omit a filer and
                // remain fail-closed. Never teach a model to bypass TrustCenter
                // by editing policy; production user-chat profiles wire the
                // canonical ApprovalInbox projection.
                throw AutonomyGateError.notRun(.approvalUnavailable)
            }
            // Persist and display injection arguments as count + digest;
            // execution characters stay only in this process's memory.
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
                // Verify the filer's injection approval against the real inbox
                // record and exact body before minting; its claimed ID alone grants no authority.
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

    /// One execution boundary binds the session and restores approved secret arguments
    /// from memory. Injection capabilities bind the action and exact body for this call;
    /// Full Mac may supply an approval identity. Non-injection calls clear inherited capabilities.
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
            // Full Mac synthesizes a missing injection approval id; category and TCC gates still apply.
            let resolvedApprovalID = injectionApprovalID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let approvalID = if let resolvedApprovalID, !resolvedApprovalID.isEmpty {
                resolvedApprovalID
            } else { "yolo-\(UUID().uuidString)" }
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
                        throw ToolFailureError("The originating ability run ended; its primitive broker is no longer available. This primitive call did not run.",
                            effects: .none, owner: "originating ability run",
                            nextCall: (try? SwiftNativeTurnEngine.dispatchReceiptCall().serialize(pretty: false)),
                            code: "primitive_broker_ended", status: .refused,
                            instruction: "Read the originating run's receipts and inspect any uncertain effects. A new ability run is new execution, not a replay of this primitive; start one only after reconciling earlier work.", recovery: .reconcile)
                    }
                    return try await inner.dispatch(tool: tool, input: finalInput, surface: surface)
                }
            }
        }
    }

    func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools()
    }

    // Forward schemas through the gate wrapper to preserve the inner dispatcher's tool catalog.
    func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names)
    }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas()
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
