import AuthoredCapabilities
import ChatToolRuntime
import ChatToolParsing
import ChatTurnContracts
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
// Blueprint: | `ChatOrchestrationClient+DispatchWrappers.swift` | File-access gates; exact-call consent carried to dispatch; audit failures owe repairs |

/// Carry request ceilings to Trust's canonical refusal before any inner work.
final class FileAccessGatedDispatcher: ExpansionToolDispatchClient, PreApprovalToolValidating, Sendable {
    private let inner: any ExpansionToolDispatchClient
    private let fileAccess: String
    private let dataRoot: URL

    /// Refuse through the same file-access gate before any inner preview
    /// inspects a target, then carry the inner dispatcher's checks through.
    func preApprovalRefusal(
        turn: Turn, invocation: ChatToolInvocation,
        tool: String, input: [String: JSONValue], surface: String
    ) async -> JSONValue? {
        let turn = turn.with(\.fileAccess, fileAccess)
        do {
            if let error = try PermissionLaw.requestFileAccessRefusal(tool: tool, input: input, turn: turn) {
                return ChatToolOutcome.failure(error: error, tool: tool)
            }
        } catch { return ChatToolOutcome.failure(error: error, tool: tool) }
        if let validating = inner as? any PreApprovalToolValidating {
            return await validating.preApprovalRefusal(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface)
        }
        return await (inner as? any PureToolArgumentValidating)?.argumentRefusal(tool: tool, input: input, turn: turn)
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
            switch ICloudChatFileAccessPolicy.Mode(fileAccess) {
            case .some(.workspace), .some(.auto), .some(.full): self = .allow
            case .some(.readOnly): self = .readOnly
            case .some(.none): self = .none
            case nil: self = .invalid
            }
        }
    }

    /// Scalar presentation of the saved posture. The turn intersects this with the original request; the label alone is never its authority.
    static func sharedFileAccess(_ requested: String) -> String {
        let saved = UserDefaults.standard.string(forKey: "chatFileAccess") ?? "auto"
        let savedMode = Mode(saved), requestedMode = Mode(requested)
        if savedMode == .invalid { return "invalid saved chatFileAccess: \(saved)" }
        if requestedMode == .invalid { return "invalid request fileAccess: \(requested)" }
        if savedMode == .none || requestedMode == .none { return "none" }
        if requestedMode == .readOnly { return "read_only" }
        return savedMode == .readOnly ? "auto" : saved
    }

    init(inner: any ExpansionToolDispatchClient, fileAccess: String, dataRoot: URL) {
        self.inner = inner
        self.fileAccess = fileAccess
        self.dataRoot = dataRoot
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String, turn: Turn, invocation: ChatToolInvocation) async throws -> JSONValue {
        let turn = turn.with(\.fileAccess, fileAccess)
        do {
            if let error = try PermissionLaw.requestFileAccessRefusal(tool: tool, input: input, turn: turn) { throw error }
            return try await holding(turn) { turn in
                try await inner.dispatch(tool: tool, input: input, surface: surface, turn: turn, invocation: invocation)
            }
        } catch {
            guard ChatToolDispatchTracer.abilityName(tool: tool, input: input) != nil else { throw error }
            var refusal = ChatToolOutcome.failure(error: error, tool: tool).objectValue ?? [:]
            refusal["checker"] = .string("request_file_access")
            return await ChatToolDispatchTracer.traceUndispatched(turn: turn, tool: tool, input: input, surface: surface,
                result: .object(refusal), dataRoot: dataRoot)
        }
    }

    func readAhead(surface: String, session: String?, turn: Turn, work: ChatTurnWork) async -> JSONValue? {
        await holding(turn.with(\.fileAccess, fileAccess)) { turn in
            await inner.readAhead(surface: surface, session: session, turn: turn, work: work)
        }
    }

    func listAvailableTools(turn: Turn?, surface: String) async throws -> [String] { try await inner.listAvailableTools(turn: turn, surface: surface) }

    func listAvailableToolSchemas(named names: Set<String>, turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names, turn: turn, surface: surface)
    }

    func listAvailableToolSchemas(turn: Turn?, surface: String) async throws -> [LLMToolSchema] { try await inner.listAvailableToolSchemas(turn: turn,
        surface: surface) }
}

/// Deny before invoking the inner dispatcher; report a tool error so the loop can continue under the same gate.
final class AutonomyGatedDispatcher: ToolDispatchClient, Sendable {
    private let work: ChatTurnWork
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
    /// Resolve peer names from `agents/peers.json` for display only; a missing root leaves the ID visible and grants no authority.
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
        peerDirectoryDataRoot: URL? = nil,
        fileAccess: String? = nil,
        work: ChatTurnWork = .init(
    )) {
        self.work = work
        self.fileAccess = fileAccess
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

    /// Failed consent records remain owed under the life record; they do not alter the decision.
    private func audit(_ envelope: SecurityToolEnvelope) async {
        do { try await securityCenter.record(envelope) } catch {
            let file = securityCenter.dataRoot.appendingPathComponent("experiences/experiences.sqlite").path
            RepairOwed.owe(securityCenter.dataRoot, id: "security-audit:" + UUID().uuidString, kind: .run,
                operation: "security.audit", owner: file,
                words: "The consent detail for \(envelope.tool) (\(envelope.decision.rawValue)) was not written: \(error.localizedDescription)",
                nextCall: ToolFailureError.call("app", ["action": .string("files.info"), "args": .object(["path": .string(file)])]))
        }
    }

    private static func requiresDesktopInteraction(tool: String, capabilities: [String]) -> Bool {
        let name = tool.replacingOccurrences(of: ".", with: "_")
        if name.hasPrefix("bot_") || name.hasPrefix("shelf_") { return false }
        return !Set(capabilities).isDisjoint(with: ["ax_injection", "hid_injection", "browser_interaction", "notification", "system_control", "shell",
            "process_spawn"])
            || ["browser_open_url", "browser_navigate", "browser_chrome_navigate",
                "browser_chrome_scroll", "mac_activate_app", "app_activate", "speak", "voice_speak", "sound_play"].contains(name)
    }

    func dispatch(tool: String, input: [String: JSONValue], surface: String, turn: Turn, invocation: ChatToolInvocation) async throws -> JSONValue {
        try Task.checkCancellation()
        if StandingBotContinuity.isHelperTurn(turn: turn), let pending = turn.execution?.pendingApproval { return pending }
        return try await inner.withToolArguments(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface) { input, invocation in
            var work = self.work.with(\.toolInvocation, invocation)
            work.handsBack = work.handsBack || invocation.handsBack
            guard turn.partID != nil, !work.handsBack else {
                let result = try await dispatchNormalized(tool: tool, input: input, surface: surface, turn: turn, work: work)
                guard input["preview"] != .bool(true), let need = InlineInteractionNeed.interaction(in: result),
                      let session = verifiedSessionId else { return result }
                let arguments = try JSONValue.object(input).serialize(pretty: false)
                let blocked = ToolNameAliases.ranTool(tool, input: input) != InlineInteractionWire.toolName
                let filed = try await SwiftNativeChatOrchestrationClient.fileInlineInteraction(
                    need, sessionID: session, toolName: blocked ? tool : nil,
                    toolArgumentsJSON: blocked && SwiftNativeChatOrchestrationClient.redactedPersistedToolInput(tool: tool, json: arguments,
                        turn: turn) == arguments
                        ? arguments : nil,
                    requestingTool: tool, origin: TurnEnvelope.current(turn: turn, surface: surface), dataRoot: securityCenter.dataRoot,turn: turn)
                let retained = filed.card
                if blocked, PermissionLaw.personDecided(tool: tool, input: input, turn: turn) {
                    PersonParkedCalls.park(retained.id, tool: tool, input: input)
                }
                if filed.changed { NotificationCenter.default.post(name: InlineInteractionWire.changedNotification, object: session) }
                guard case .object(var fields) = result,
                      let encoded = InlineInteractionNeed.encode(retained) else {
                    throw ToolFailureError("The retained card could not be returned.", effects: .none, code: "card_encoding_failed")
                }
                fields[InlineInteractionWire.needsKey] = encoded
                fields["card_id"] = .string(retained.id)
                return .object(fields)
            }
            let id = UUID()
            let events = await ApprovalLifecycleBus.shared.events(forHostCall: id,
                context: .init(turn: turn,
                    effectOptions: .init(admissionOnly: work.admissionOnly),
                    effectExecutor: work.authoredCall.map { .init(tool: $0.tool, perform: $0.perform) }))
            do {
                var result = try await holding(turn.with(\.hostCallID, id)) { turn in
                    try await dispatchNormalized(tool: tool, input: input, surface: surface, turn: turn, work: work)
                }
                let reply = ToolResult(result)
                if let approval = (ChatTranscriptEvidenceRendering.receiptField("approvalId", in: result))?.scalarText.flatMap({ $0.trimmingCharacters(in:
                    .whitespacesAndNewlines).isEmpty ? nil : $0 })
                    ?? (ChatTranscriptEvidenceRendering.receiptField("approval_id", in: result))?.scalarText.flatMap({ $0.trimmingCharacters(in:
                        .whitespacesAndNewlines).isEmpty ? nil : $0 }),
                   ChatToolOutcome.isWaitingOnPerson(reply.payload, verdict: reply.outcome) {
                    var event = try await work.deadlines.withHumanWait {
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
                            "remedy": Repair.reconcile(
                                instruction: "Read this exact card's retained execution record, then inspect the affected state before repeating the action.",
                                nextCall: .object(["tool": .string("app"), "input": .object([
                                    "action": .string("files.read"), "args": .object(["path": .string(securityCenter.dataRoot
                                        .appendingPathComponent("workflows/approvals/requests.json").path)])])]))])
                        : .object(["status": .string("failed"), "reason": .string(event.record.status == "orphaned" ? "approval_expired" : "declined"),
                            "detail": .string("""
                                workflows/approvals/requests.json card \(approval): status=\(event.record.status), \
                                decision=\(event.record.decision ?? "unanswered"). Nothing ran; the part is no longer waiting.
                                """), "effects": .string("none")])
                    if event.record.status == "orphaned", case .object(var fields) = result {
                        fields["remedy"] = .object(["kind": .string("correct_arguments"),
                            "instruction": .string("This card expired; revise or withdraw the work, or request it again if still needed."),
                            "next_call": .object(["tool": .string(tool), "input": .object(input)])])
                        result = .object(fields)
                    }
                }
                await ApprovalLifecycleBus.shared.finish(id)
                if let need = InlineInteractionNeed.interaction(in: result) {
                    guard let wait = work.waitForInteraction else {
                        throw ToolFailureError("Card \(need.id) cannot resume because the originating conversation is not bound to this call.",
                            effects: .unknown, owner: "originating conversation",
                            nextCall: (try? SwiftNativeTurnEngine.dispatchReceiptCall(turn: turn).serialize(pretty: false)),
                            code: "card_conversation_unavailable",
                            instruction: """
                                Read this turn's receipts to locate the conversation for this card, then resolve the existing card there. Check its \
                                outcome before requesting the action again.
                                """, recovery: .reconcile)
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

    private func dispatchNormalized(tool: String, input: [String: JSONValue], surface: String, turn: Turn, work: ChatTurnWork) async throws -> JSONValue {
        // The person's act admits its own call once per form in one run; every other call here is judged as the agent's.
        let turn = PermissionLaw.admitting(tool: tool, input: input, turn: turn)
        if let refusal = await inner.unrecognizedAppActionRefusal(tool: tool, input: input, surface: surface,
            turn: turn, invocation: work.invocation) { return refusal }
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
        let securityInput = MacInjectionArgRedaction.redacted(tool: tool, input: input, turn: turn)
        let envelope = await securityCenter.evaluateTool(
            tool: tool,
            input: securityInput,
            origin: .currentTurn(
                turn: turn.with(\.verifiedSessionID, verifiedSessionId ?? turn.verifiedSessionID),
                surface: surface
            ),
            enforceAutonomy: false, turn: turn
        )
        // Only .block hard-denies here; .ask enters the approval flow and denies if no filer exists.
        if envelope.decision == .block {
            await audit(envelope)
            throw AutonomyGateError.toolDenied(reason: envelope.primaryReason, remedy: envelope.remedy)
        }

        // Use SecurityCenter's decision for this exact call, including roots, profile, class, reach and saved user entries.
        let autonomyLevel = envelope.autonomyLevel
        // The saved posture is Full Mac, whoever is asking (a peer or helper
        // surface is never admitted, but it is still running under Full Mac).
        let fullMacOn = [.admitted, .untrustedOrigin].contains(envelope.fullMacYoloAuthority)
        // Verify every replay against the inbox and burn its exemption for one dispatch; unverified replays are denied.
        let approvedReplayAuthorizes: Bool
        if !MacInjectionToolNames.isInjectionTool(tool),
           let replay = approvedReplay,
           replay.matches(turn: turn,
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
                    + """
                        . Authority: workflows/approvals/requests.json and effect_spends.json. Inspect this card's execution receipt and the effect \
                        owner's state before any new request; a missing or unreadable spend does not prove nothing ran.
                        """
                await audit(
                    Self.securityEnvelope(envelope, decision: .block, reason: reason)
                )
                let store = verdict == .spendUnavailable || verdict == .notSpentByExecutor ? "effect_spends.json" : "requests.json"
                let path = (peerDirectoryDataRoot ?? defaultDataRoot()).appendingPathComponent("workflows/approvals/" + store).path
                let remedy: JSONValue = .object(["kind": .string("inspect"),
                    "instruction": .string("""
                        Inspect approval \(replay.approvalID) in requests.json and effect_spends.json, then reconcile the effect owner's receipt. \
                        This replay did not run; the earlier effect is unknown. Reading these files does not establish the outcome or authorize a \
                        resend.
                        """),
                    "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("files.read"),
                        "args": .object(["path": .string(path)])])])])
                return .object(["status": .string("failed"), "reason": .string(reason), "effects": .string("unknown"), "remedy": remedy])
            }
            approvedReplayAuthorizes = true
        } else {
            approvedReplayAuthorizes = false
        }
        // Injection replay requires a real, approved, unspent inbox record bound
        // to the exact tool, surface, body and verified origin, checked before
        // exemption and minting. Unverified replay is denied without another ask.
        var injectionReplayApprovalID: String?
        if MacInjectionToolNames.isInjectionTool(tool),
           let replay = approvedReplay,
           replay.matches(turn: turn,
            tool: tool,
            surface: surface,
            input: input,
            verifiedSessionID: verifiedSessionId
           ) {
            let verdict = try await injectionApprovalVerifier.verifyInjectionApproval(
                approvalID: replay.approvalID,
                tool: tool,
                surface: surface,
                input: input,
                turn: turn
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
        var admission = envelope
        if approvedReplayAuthorizes, envelope.requiresApproval {
            // The exemption is audited, not silent.
            admission = Self.securityEnvelope(
                envelope,
                decision: .allow,
                reason: "approved replay of \(tool) honours approval "
                    + "\(approvedReplay?.approvalID ?? "unknown")"
            )
        }
        let securityAsked: Bool
        var decision: AutonomyDecision
        let botDesktop = StandingBotContinuity.isHelperTurn(turn: turn) && !approvedReplayAuthorizes && injectionReplayApprovalID == nil
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
        let protectedAction = try PeerTurnEffectPolicy.requiresPeerApproval(tool, input: input, turn: turn)
        var decidedRequester = fullMacOn && protectedAction
            && turn.envelope?.workIdentity?.hasPrefix("carry.") == true ? "Full Mac" : nil
        if botDesktop, fullMacOn, case .allow = decision {
            admission = Self.securityEnvelope(envelope, decision: .allow, reason: "The agent decided for a helper")
            decidedRequester = "a helper"
        }
        let peerTurnID = turn.envelope?.verifiedUserId
        let taint = turn.peerSteering
        let trustedBridge = PeerDataTaint.trustedTurn(turn)
        let peerApproval = PeerDataTaintDispatcher.peerApproval(turn: turn, surface: surface,
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
                decision = .requireApproval(reason: try PeerTurnEffectPolicy.floorReason(
                    tool: tool, input: input, requester: named.isEmpty ? requester ?? "" : named,
                    quote: Self.peerQuote(taint?.lastLine ?? ""), turn: turn))
            } else if let requester, protectedAction {
                if fullMacOn {
                    // Under Full Mac, audit the agent's allowed decision for the requester.
                    if case .allow = decision {
                        admission = Self.securityEnvelope(envelope, decision: .allow, reason: "The agent decided for \(requester)")
                        decidedRequester = requester
                    }
                } else if peerApproval.required {
                    decision = .requireApproval(
                        reason: PeerTurnEffectPolicy.approvalReason(tool: tool, requester: requester)
                    )
                }
            }
        }
        // The user's own contact send needs no card. Broader execution and Trust refusals must be stated plainly.
        if turn.personInitiatedSend?.claim(tool: tool, input: input, surface: surface) == true {
            let name: String = {
                guard case .string(let agent)? = input["agent"], agent.hasPrefix("peer:") else { return "This contact" }
                return peerDisplayName(peerID: String(agent.dropFirst(5))) ?? "This contact"
            }()
            switch decision {
            case .allow: break
            case .requireApproval where Set(envelope.capabilities).isSubset(of: PersonInitiatedSend.sendOnly):
                admission = Self.securityEnvelope(envelope, decision: .allow, reason: "person-initiated send from a contact thread")
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
        // An owner that needs the person's yes for this exact call says so in its reply (`needs_person`, with its words): the call then asks
        // as a gate's ask does, and the person's Approve replays it as their own act. The person's own act, or its replay, never asks again.
        while true {
        switch decision {
        case .allow:
            if work.admissionOnly {
                if tool != "app" || input["preview"] != .bool(true) {
                    await audit(Self.securityEnvelope(admission, decision: .allow, reason: "admitted"))
                }
                return .object(["status": .string("admitted"), "effects": .string("none"),
                                "execution": .string("not_run"), "reason": .string("admitted")])
            }
            // Bind the approved session so downstream dispatch reconstructs the same origin instead of falsely blocking it.
            // Injection still requires exact approved replay; `runInner` refuses any allow without its approval ID.
            let result = try await runInner(
                admission: admission,
                tool: tool,
                input: input,
                surface: surface,
                injectionApprovalID: injectionReplayApprovalID ?? (approvedReplayAuthorizes ? approvedReplay?.approvalID : nil),
                // Reaching .allow IS the person's go-ahead: their approval, or Full Mac.
                personApprovedHost: namedConnect,
                // A verified replay of the person's approved card runs as their decision of this exact call, levers included.
                turn: approvedReplay.flatMap { replay in approvedReplayAuthorizes
                    ? turn.with(\.personAct, PersonAct(by: .card(id: replay.approvalID), tool: tool, input: input, spent: [.call])) : nil }
                    ?? turn,
                work: work)
            let reply = ToolResult(result)
            // Only the stem's own verbs ask this way (an app action that is no part's, connector's or folded tool's), so no reply a part,
            // a peer or a remote tool writes can word the person's card.
            if reply.said("needs_person"), !approvedReplayAuthorizes, turn.personAct == nil, input["preview"] != .bool(true), tool == "app",
               let asking = input["action"]?.stringValue, AppActionBinding.declaredBinding(asking)?.folded == false,
               let words = result.objectValue?["detail"]?.stringValue, !words.isEmpty {
                decision = .requireApproval(reason: words)
                continue
            }
            if let decidedRequester, !trustedBridge, tool != "app",
               reply.outcome == .succeeded {
                BodyDecidedRow.post(turn: turn, requester: decidedRequester, tool: tool, sessionID: verifiedSessionId,
                                      dataRoot: peerDirectoryDataRoot ?? defaultDataRoot(), ran: true)
            }
            return result
        case .deny(let reason):
            await audit(Self.securityEnvelope(envelope, decision: .block, reason: reason))
            throw AutonomyGateError.toolDenied(reason: reason, remedy: envelope.remedy)
        case .requireApproval(let gateReason):
            let root = peerDirectoryDataRoot ?? defaultDataRoot()
            if let refusal = try await MacAppActGate.requestRefusal(tool: tool, input: input, dataRoot: root,
                turn: turn, context: work.invocation.macContext(dataRoot: root)) {
                return ChatToolOutcome.refusedBeforeRunning(.object(refusal.fields))
            }
            // A switch the user turned off refuses before any card, regardless of posture.
            if let gate = try SwiftToolDispatcher.integrationGate(tool: tool, input: input, turn: turn) {
                let root = peerDirectoryDataRoot ?? defaultDataRoot()
                let store = root == defaultDataRoot() ? MacIntegrationPermissionStore.shared : MacIntegrationPermissionStore(dataRoot: root)
                if let refusal = try await SwiftToolDispatcher.switchRefusal(integration: gate.integration, mode: gate.mode, store: store) {
                    return ChatToolOutcome.refusedBeforeRunning(refusal)
                }
            }
            // A skill's step never files a card: it hands back to the agent.
            if work.handsBack, !work.admissionOnly { return SkillRunContext.handBack(ApprovalActionText.reason(gateReason,
                tool: tool)) }
            // Preserve the deciding rule alongside the implementation's disclosure.
            var reason = ApprovalActionText.reason(gateReason, tool: tool)
            if let cause = envelope.autonomyReason, !reason.contains(cause) { reason += " " + cause }
            if tool.hasPrefix("fetch."), case .string(let raw)? = input["url"], let url = URL(string: raw) {
                let method = input["method"]?.scalarText.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 })?.uppercased()
                    ?? "GET"
                reason = "\(method) \(url.host ?? "")\(url.path) through \(tool). \(reason)"
            } else if let validating = inner as? any PreApprovalToolValidating,
               let disclosed = await validating.approvalCardReason(
                tool: tool, input: input, surface: surface) {
                reason = disclosed + " " + reason
            }
            // Pre-approval validation returns certain refusals as tool errors without filing an approval.
            // Screen control's card admits a part's hand on its watched window before primitive validation.
            let primitiveCall = work.authoredCall?.tool == tool && !AuthoredToolEffects.handOperations.contains(tool)
            if !primitiveCall, !work.admissionOnly, let validating = inner as? any PreApprovalToolValidating {
                let refusal = await holding(turn.with(\.verifiedSessionID, verifiedSessionId ?? turn.verifiedSessionID)) { turn in
                    await validating.preApprovalRefusal(turn: turn, invocation: work.invocation, tool: tool, input: input, surface: surface)
                }
                if let refusal { return ChatToolOutcome.refusedBeforeRunning(refusal) }
            } else if !primitiveCall, !work.admissionOnly, let validating = inner as? any PureToolArgumentValidating,
                      let refusal = await validating.argumentRefusal(tool: tool, input: input, turn: turn) {
                return ChatToolOutcome.refusedBeforeRunning(refusal)
            }
            let ownsACPConnectCard: Bool
            if namedConnect, case .string(let name)? = input["name"] {
                ownsACPConnectCard = AgentHostDirectory.row(named: name)?.acp != nil
            } else { ownsACPConnectCard = false }
            if !securityAsked, envelope.capabilities.contains("approval_stage") || ownsACPConnectCard {
                // ACP owns the connect card and immutable executable proposal; no executable grant precedes approval.
                // Staging persists only bounded replay requests. Injection never takes this shortcut; its approval path must remain separate.
                return try await runInner(
                    admission: admission,
                    tool: tool,
                    input: input,
                    surface: surface,
                    injectionApprovalID: nil,
                 turn: turn, work: work)
            }
            // File approval and await gate resolution; without a usable filer,
            // deny explicitly so the loop records the rejection.
            guard approvalFiler != nil, !work.admissionOnly || approvalFiler is any NonBlockingApprovalFiler else {
                await audit(Self.securityEnvelope(envelope, decision: .ask, reason: reason))
                // Missing filers fail closed. User-chat profiles wire the canonical inbox; policy edits must never bypass TrustCenter.
                return ToolNotRunStatus.approvalUnavailable.reporting(.object([
                    "status": .string("refused"), "reason": .string("approval_unavailable"), "checker": .string("approval_admission"),
                    "effects": .string("none"), "remedy": Repair.why(owner: "approval for this call", tap: "NativeAgent chat on Mac, phone or Telegram",
                        instruction: "Make this request in a conversation with an approval inbox; no card was filed here and policy edits cannot grant it.")]))
            }
            // Persist and display injection arguments as count + digest;
            // execution characters stay only in this process's memory.
            let approvalPayloadInput = MacInjectionArgRedaction.redacted(tool: tool, input: input, turn: turn)
            let injectionSecrets = try MacInjectionArgRedaction.extractSecrets(tool: tool, input: input, turn: turn)
            if let nonBlocking = approvalFiler as? (any NonBlockingApprovalFiler) {
                let payload = JSONValue.object(approvalPayloadInput)
                let approvalId = try await withFilingSession(turn: turn) { turn in
                    do {
                        return try await nonBlocking.fileApprovalRequest(
                            toolName: tool, surface: surface, payload: payload, reason: reason
                        ,turn: turn)
                    } catch let error as AutonomyGateError {
                        throw error
                    } catch {
                        throw AutonomyGateError.approvalFilingFailed(String(describing: error))
                    }
                }
                // Keep injection characters in the one-use in-memory approval vault; after process death, replay must refuse absent characters.
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
                ,turn: turn)
                if case .object(let fields) = pending, fields["not_run_status"] == nil {
                    pending = ToolNotRunStatus.approvalFiled.reporting(pending)
                }
                if let remedy = envelope.remedy, case .object(var fields) = pending {
                    fields["remedy"] = remedy
                    pending = .object(fields)
                }
                if StandingBotContinuity.isHelperTurn(turn: turn) { turn.execution?.keepApproval(id: approvalId, pending) }
                return pending
            }
            let resolved = try await withFilingSession(turn: turn) { turn in
                try await gate.resolveWithApprovalDetailed(
                    toolName: tool,
                    surface: surface,
                    requestPayload: .object(approvalPayloadInput),
                    timeoutSeconds: approvalTimeoutSeconds,
                    reason: reason
                ,turn: turn)
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
                    let verdict = try await injectionApprovalVerifier.verifyInjectionApproval(
                        approvalID: resolved.approvalID ?? "",
                        tool: tool,
                        surface: surface,
                        input: input,
                        turn: turn
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
                // The person may answer after the saved policy changes. The membrane refreshes hard blocks before carrying the approved call.
                let current = await securityCenter.evaluateTool(tool: tool,
                    input: MacInjectionArgRedaction.redacted(tool: tool, input: input, turn: turn),
                    origin: .currentTurn(turn: turn.with(\.verifiedSessionID, verifiedSessionId ?? turn.verifiedSessionID), surface: surface),
                    enforceAutonomy: false, turn: turn)
                if current.decision == .block {
                    await audit(current)
                    throw AutonomyGateError.toolDenied(reason: current.primaryReason, remedy: current.remedy)
                }
                return try await runInner(
                    admission: Self.securityEnvelope(current, decision: .allow, reason: "The person approved this call."),
                    tool: tool,
                    input: input,
                    surface: surface,
                    injectionApprovalID: mintApprovalID,
                    personApprovedHost: namedConnect,
                    // The person approved this exact call on its card: it runs as their decision, levers included.
                    turn: resolved.approvalID.map { id in
                        turn.with(\.personAct, PersonAct(by: .card(id: id), tool: tool, input: input, spent: [.call])) } ?? turn,
                    work: work)
            case .deny(let r):
                await audit(Self.securityEnvelope(envelope, decision: .block, reason: r))
                var refused: [String: JSONValue] = ["status": .string("refused"), "reason": .string(r), "gate_reason": .string(r),
                    "checker": .string("approval_admission"), "effects": .string("none"),
                    "remedy": Repair.terminal(instruction: "Respect the reported approval outcome. Inspect the retained card before another request; "
                        + "do not repeat prior effects to answer an unresolved outcome.")]
                refused["approvalId"] = resolved.approvalID.map(JSONValue.string)
                if let status = resolved.notRunStatus { return status.reporting(.object(refused), tool: tool) }
                return .object(refused)
            case .requireApproval(let r):
                await audit(Self.securityEnvelope(envelope, decision: .ask, reason: r))
                throw AutonomyGateError.toolDenied(reason: r, remedy: Repair.why(owner: "approval for this call",
                    tap: "NativeAgent chat on Mac, phone or Telegram", instruction: "Inspect the existing approval request before asking again."))
            }
        }
        }
    }

    /// Approval filing precedes dispatch, so bind its session from the same origin the gate resolved.
    /// Preserve an outer transport-verified session; fill only nil and never change the gate decision.
    private func withFilingSession<T>(
        turn: Turn, _ body: (Turn) async throws -> T
    ) async rethrows -> T {
        let filingSessionId = turn.verifiedSessionID ?? verifiedSessionId
        return try await holding(turn.with(\.fileAccess, fileAccess)) { turn in
            try await holding(turn.with(\.verifiedSessionID, filingSessionId),
                operation: body
            )
        }
    }

    /// Restore approved secrets at the execution boundary and bind injection capabilities to the exact action and body.
    /// Full Mac may supply approval identity; non-injection calls clear inherited capabilities.
    private func runInner(
        admission: SecurityToolEnvelope,
        tool: String,
        input: [String: JSONValue],
        surface: String,
        injectionApprovalID: String?,
        personApprovedHost: Bool = false,
        turn: Turn, work: ChatTurnWork
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
                  MacInjectionArgRedaction.redacted(tool: tool, input: effectiveInput, turn: turn) == input else {
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

        let finalCapability = capability
        // Inline-card replay binds its verified session around dispatch rather
        // than at factory construction. Keep that owner's binding through the
        // writer and capture it before detached settlement loses task locals.
        let executionSessionID = verifiedSessionId ?? turn.verifiedSessionID
        let finalInput = ChatToolSessionInjection.apply(toolName: tool, input: effectiveInput, sessionId: executionSessionID)
        try Task.checkCancellation()
        let result = try await holding(turn.with(\.verifiedSessionID, executionSessionID)) { turn in
            // Bound even when nil: a non-injection tool must never inherit a
            // capability left in scope by an enclosing task.
            try await holding(turn.with(\.injectionCapability, finalCapability)) { turn in
                try await holding(turn.with(\.personApprovedHost, personApprovedHost)) { turn in
                    let admitted = Self.securityEnvelope(admission, decision: .allow, reason: "admitted")
                    if let call = work.authoredCall, call.tool == tool {
                        if tool != "app" || finalInput["preview"] != .bool(true) { await audit(admitted) }
                        return try await call.perform()
                    }
                    if AuthoredToolEffects.primitiveCapabilities[tool] != nil || tool.hasPrefix("fetch.") {
                        throw ToolFailureError("""
                            The originating ability run ended; its primitive broker is no longer available. This primitive call did not \
                            run.
                            """,
                            effects: .none, owner: "originating ability run",
                            nextCall: (try? SwiftNativeTurnEngine.dispatchReceiptCall(turn: turn).serialize(pretty: false)),
                            code: "primitive_broker_ended", status: .refused,
                            instruction: """
                                Read the originating run's receipts and inspect any uncertain effects. A new ability run is new execution, not a \
                                replay of this primitive; start one only after reconciling earlier work.
                                """, recovery: .reconcile)
                    }
                    var invocation = work.invocation
                    invocation.securityAdmission = SecurityToolAdmission(envelope: admitted, tool: tool, input: finalInput,
                        surface: surface, turn: turn, sessionID: turn.verifiedSessionID)
                    return try await inner.dispatch(tool: tool, input: finalInput, surface: surface, turn: turn, invocation: invocation)
                }
            }
        }
        let reply = ToolResult(result)
        if surface == "chat", tool == FirstConversationPersonaProgression.writeTool,
           finalInput["preview"] != .bool(true), reply.outcome == .succeeded {
            let root = securityCenter.dataRoot, session = executionSessionID
            // Stop does not cancel the bookkeeping for an already committed write.
            // Every allowed path (including approved replay) settles here once.
            let progressionFailure: String? = await settle {
                do {
                    _ = try await FirstConversationPersonaProgression.settleSuccessfulWrite(
                        tool: tool, input: finalInput, dataRoot: root, sessionID: session)
                    return nil
                } catch {
                    RepairOwed.owe(root, id: "first-conversation:" + UUID().uuidString, kind: .run,
                        operation: "first_conversation.progression", owner: PersonaRootResolver.resolveIsolated(dataRoot: root).path,
                        words: """
                            The persona append succeeded, but its progression remains owed: \(error.localizedDescription). Inspect the retained token \
                            and persona bytes; repair progression without appending the same section again.
                            """)
                    return error.localizedDescription
                }
            }
            if let progressionFailure, case .object(var fields) = result {
                fields["progression_status"] = .string("repair_owed")
                fields["progression_detail"] = .string("The persona append succeeded. Repair its progression without repeating the append: "
                    + progressionFailure)
                return .object(fields)
            }
        }
        return result
    }

    func listAvailableTools(turn: Turn?, surface: String) async throws -> [String] {
        try await inner.listAvailableTools(turn: turn, surface: surface)
    }

    // Forward the actual inner schemas so wrapping gates cannot change the offered catalog.
    func listAvailableToolSchemas(named names: Set<String>, turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names, turn: turn, surface: surface)
    }

    func listAvailableToolSchemas(turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(turn: turn, surface: surface)
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
