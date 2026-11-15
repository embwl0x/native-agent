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
// Blueprint: | `ChatOrchestrationClient+DispatchWrappers.swift` | File-access gates; exact-call consent carried to dispatch, the person's own turn deciding what is theirs; audit failures owe repairs |

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

    /// The person's own ask this call runs on, when the turn is the person's (`Turn.personsAsk`): in a turn the person started at a door that
    /// is theirs, every lever, raise and owner-only change the agent calls is the person's act, decided by that ask. A preview, a helper's
    /// turn, a turn an agent the person has not trusted steers and the mind's own thought have none, so their ask keeps its card.
    private func personsAsk(tool: String, input: [String: JSONValue], turn: Turn) async -> String? {
        guard tool == "app", input["preview"] != .bool(true), !StandingBotContinuity.isHelperTurn(turn: turn),
              let ask = turn.personsAsk else { return nil }
        return await ask()
    }

    /// The owner's own words for its answer: beside the door's receipt, or inside its `result`, where the door hands an action's own answer
    /// back. One reader for both shapes, so an owner's ask is never missed for where the door put it.
    static func ownersDetail(_ result: JSONValue) -> String? {
        guard case .object(let fields) = result else { return nil }
        return [fields, fields["result"]?.objectValue ?? [:]].lazy.compactMap { $0["detail"]?.stringValue }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    /// The call as a card names it, without the quoted request (`because`) beside it, in its args or on its steps: a card filed before the
    /// person's words were quoted is for the same call.
    static func withoutBecause(_ call: [String: JSONValue]) -> [String: JSONValue] {
        var call = call
        call["because"] = nil
        if case .object(var args)? = call["args"] { args["because"] = nil; call["args"] = .object(args) }
        if case .array(let steps)? = call["actions"] { call["actions"] = .array(steps.map { .object(withoutBecause($0.objectValue ?? [:])) }) }
        return call
    }

    /// A card still waiting for the call the person's word now decides is settled now, through the inbox's own decision write, as decided
    /// by their word, with their words: it cannot sit in their inbox and replay a change already made. Its reconciliation then reports it as
    /// not run, as every withdrawn card is. Returns the cards settled and any that could not be.
    private func settleCards(decidedBy words: String, tool: String, input: [String: JSONValue], turn: Turn) async -> JSONValue {
        guard let session = turn.verifiedSessionID ?? verifiedSessionId else { return .null }
        let call = Self.withoutBecause(MacInjectionArgRedaction.redacted(tool: tool, input: input, turn: turn))
        let inbox = SwiftNativeApprovalInbox(root: peerDirectoryDataRoot ?? defaultDataRoot())
        let waiting: [ApprovalRecord]
        do { waiting = try await inbox.list(filter: ApprovalFilter(status: "pending", action: tool)) }
        catch { return .object(["unreadable": .string(error.localizedDescription)]) }
        var settled: [JSONValue] = [], failed: [JSONValue] = []
        for record in waiting {
            guard case .object(let payload) = record.payload, payload["kind"] == .string("chat_tool_approval"),
                  payload["toolName"] == .string(tool), payload["origin"]?.objectValue?["sessionId"] == .string(session),
                  case .object(let filed)? = payload["input"], Self.withoutBecause(filed) == call else { continue }
            do {
                _ = try await inbox.resolve(record.id, decision: .canceled,
                    provenance: .local(decidedBy: ApprovalRecord.personsWordDecider + "“\(words)”"))
                settled.append(.string(record.id))
            } catch {
                failed.append(.object(["id": .string(record.id), "error": .string(error.localizedDescription)]))
            }
        }
        guard !settled.isEmpty || !failed.isEmpty else { return .null }
        return .object(["settled": .array(settled), "not_settled": .array(failed)])
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
        var result = try await dispatchHeld(tool: tool, input: input, surface: surface, turn: turn, invocation: invocation)
        // What the agent's own create made, by the id its receipt declares, is kept so a later removal of it, in this turn or any other, is
        // known as undoing its own act; a removal that ran takes it away. Recorded once, by the declared create or removal itself: a folded
        // `app` call re-enters here under its tool's own name, and its outer `app` call (no declaration of its own) records nothing.
        if ToolResult(result).outcome == .succeeded, let schema = AppActionBinding.declaredSchema(tool) {
            do {
                if let key = schema.makes, let id = ChatTranscriptEvidenceRendering.receiptField(key, in: result)?.stringValue {
                    try AgentMade.note(id, madeBy: tool, root: securityCenter.dataRoot)
                }
                if let key = schema.removes, let id = input[key]?.stringValue { try AgentMade.forget(id, root: securityCenter.dataRoot) }
            } catch {
                if case .object(var fields) = result {
                    fields["made_record_unavailable"] = .string("trust/made.json was not updated (\(error.localizedDescription)), so removing "
                        + "what this made asks the person as removing the person's things does.")
                    result = .object(fields)
                }
            }
        }
        return result
    }

    private func dispatchHeld(tool: String, input: [String: JSONValue], surface: String, turn: Turn,
                              invocation: ChatToolInvocation) async throws -> JSONValue {
        try await inner.withToolArguments(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface) { input, invocation in
            var work = self.work.with(\.toolInvocation, invocation)
            work.handsBack = work.handsBack || invocation.handsBack
            // A card never holds a running call: a call from a script or a part returns pending at once with its card, as a top-level call
            // does, and the program sees pending and goes on or ends; the person's Approve replays the call from the card. Only an ability's
            // own authored body waits on its card, since that body runs nowhere but inside its live run.
            guard turn.partID != nil, work.authoredCall != nil, !work.handsBack else {
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
        // Arguments first: the call is checked against its schema and its owner's own checks (targets, names, ids, values) before any
        // decision but .allow is acted on, so a call that cannot run is refused at once in its owner's words and never becomes a card, an
        // approval, a notification or a deny. The order is validate, decide, card, run, for every caller. An allowed call pays no preview:
        // its run's own prepare refuses in the same shape. A question the check would put to the person (a permission it needs) gives way
        // to a deny, which raises nothing.
        func argumentRefusal(denied: Bool) async -> JSONValue? {
            // Screen control's card admits a part's hand on its watched window before primitive validation.
            let primitiveCall = work.authoredCall?.tool == tool && !AuthoredToolEffects.handOperations.contains(tool)
            var refusal: JSONValue?
            if !primitiveCall, let validating = inner as? any PreApprovalToolValidating {
                refusal = await holding(turn.with(\.verifiedSessionID, verifiedSessionId ?? turn.verifiedSessionID)) { turn in
                    await validating.preApprovalRefusal(turn: turn, invocation: work.invocation, tool: tool, input: input, surface: surface)
                }
            } else if !primitiveCall, let validating = inner as? any PureToolArgumentValidating {
                refusal = await validating.argumentRefusal(tool: tool, input: input, turn: turn)
            }
            guard let refusal else { return nil }
            if ChatToolOutcome.isWaitingInteraction(refusal) { return denied ? nil : refusal }
            return ChatToolOutcome.refusedBeforeRunning(owner: refusal)
        }
        // .block is the person's Trust (Safe's blocked level, Pause everything) or their security policy: a good call it stops is refused
        // before it ran, as the person's call. .ask enters the approval flow and denies if no filer exists.
        if envelope.decision == .block {
            await audit(envelope)
            if let refusal = await argumentRefusal(denied: true) { return refusal }
            return ChatToolOutcome.refusedBeforeRunning(code: "owners_call", detail: envelope.primaryReason,
                extra: (envelope.remedy.map { ["remedy": $0] } ?? [:]).merging(["decided_by": .string("trust")]) { $1 })
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
        // Removing what the agent's own create made is the agent undoing its own act, not deleting the person's things: it runs without a
        // card in this turn or a later one, as long as the create would run without a card for this same asker now. Another agent's
        // steering and a security ask keep their card; Safe's refusal is a deny and stands.
        var ownUndo: String?
        if case .requireApproval = decision, !securityAsked,
           let words = await AgentMade.undoing(tool: tool, input: input, surface: surface,
               origin: .currentTurn(turn: turn.with(\.verifiedSessionID, verifiedSessionId ?? turn.verifiedSessionID), surface: surface),
               security: envelope, turn: turn, securityCenter: securityCenter) {
            admission = Self.securityEnvelope(envelope, decision: .allow, reason: words)
            decision = .allow
            ownUndo = words
        }
        // A change that is the person's to decide and that a card can carry (a lever's ask here, a setting raise's or an owner-only row's
        // from its owner below) is decided by their card, or by their own ask when the turn is theirs (`personsAsk`). A security ask,
        // another agent's steering or a peer's request keeps its card.
        var theirs = false
        if case .requireApproval = autonomyDecision, !securityAsked, requester == nil,
           try PermissionLaw.lever(tool: tool, input: input, turn: turn)?.asks == true { theirs = true }
        // The person's ask, once it decides this call: their act for this exact call, as their card's Approve would be; and the cards it
        // settled that were waiting for this call.
        var wordTurn: Turn?
        var cardsSettled: JSONValue = .null
        if case .allow = decision {} else {
            if case .deny(let reason) = decision {
                // Trust's consent history keeps every deny, a call refused for its arguments too.
                await audit(Self.securityEnvelope(envelope, decision: .block, reason: reason))
                if let refusal = await argumentRefusal(denied: true) { return refusal }
            } else if let refusal = await argumentRefusal(denied: false) { return refusal }
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
        var ownerAsked = false
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
            var result = try await runInner(
                admission: admission,
                tool: tool,
                input: input,
                surface: surface,
                injectionApprovalID: injectionReplayApprovalID ?? (approvedReplayAuthorizes ? approvedReplay?.approvalID : nil),
                // Reaching .allow IS the person's go-ahead: their approval, or Full Mac.
                personApprovedHost: namedConnect,
                // A verified replay of the person's approved card runs as their decision of this exact call, levers included; so does a call
                // the person asked for in their own words.
                turn: approvedReplay.flatMap { (replay) -> Turn? in
                    guard approvedReplayAuthorizes else { return nil }
                    turn.cardCause?.approved(by: replay.approvalID)
                    return turn.with(\.personAct, PersonAct(by: .card(id: replay.approvalID), tool: tool, input: input, spent: [.call])) }
                    ?? wordTurn ?? turn,
                work: work)
            let reply = ToolResult(result)
            // Only the stem's own verbs ask this way (an app action that is no part's, connector's or folded tool's, or the door's own list
            // of calls that are all the person's to decide), so no reply a part, a peer or a remote tool writes can word the person's card.
            let stemAsks: Bool = if let asking = input["action"]?.stringValue { AppActionBinding.declaredBinding(asking)?.folded == false }
                else { input["action"] == nil && input["actions"]?.arrayValue != nil }
            if reply.said("needs_person"), !approvedReplayAuthorizes, turn.personAct == nil, input["preview"] != .bool(true), tool == "app",
               stemAsks, let words = Self.ownersDetail(result) {
                decision = .requireApproval(reason: words)
                ownerAsked = true
                // The owner's ask is the person's, as a lever's is, unless another agent is behind this turn; one their ask already
                // decided and that still asks goes on their card.
                theirs = requester == nil && wordTurn == nil
                wordTurn = nil
                continue
            }
            // What the agent reads says it undid its own act, and what it made.
            if let ownUndo, case .object(var fields) = result {
                fields["undoing_own_act"] = .string(ownUndo)
                result = .object(fields)
            }
            // What the agent reads says the call ran as the person's act, on their own ask.
            if let words = wordTurn?.personAct?.words, case .object(var fields) = result {
                fields["decided_by"] = .string("person")
                fields["persons_word"] = .string(words)
                if cardsSettled != .null { fields["cards_settled_by_persons_word"] = cardsSettled }
                result = .object(fields)
            }
            // A call the person's card decided says which card and that the person decided it, so the agent's own log ties it to them.
            if approvedReplayAuthorizes, let replay = approvedReplay, case .object(var fields) = result {
                fields["decided_by"] = .string("person")
                fields["card"] = .string("\(ApprovalWords.call(tool: tool, input: .object(input)).act) (\(replay.approvalID)), approved by the person")
                result = .object(fields)
            }
            if let decidedRequester, !trustedBridge, tool != "app",
               reply.outcome == .succeeded {
                BodyDecidedRow.post(turn: turn, requester: decidedRequester, tool: tool, sessionID: verifiedSessionId,
                                      dataRoot: peerDirectoryDataRoot ?? defaultDataRoot(), ran: true)
            }
            return result
        case .deny(let reason):
            // A good call the person's Trust denies is refused before it ran, in the gate's words: the person's call, not a failure. Its
            // deny was audited above, with the argument check.
            return ChatToolOutcome.refusedBeforeRunning(code: "owners_call", detail: reason,
                extra: (envelope.remedy.map { ["remedy": $0] } ?? [:]).merging(["decided_by": .string("trust")]) { $1 })
        case .requireApproval(let gateReason):
            // The arguments were checked above, before any decision was acted on.
            let root = peerDirectoryDataRoot ?? defaultDataRoot()
            if let refusal = try await MacAppActGate.requestRefusal(tool: tool, input: input, dataRoot: root,
                turn: turn, context: work.invocation.macContext(dataRoot: root)) {
                return ChatToolOutcome.refusedBeforeRunning(owner: .object(refusal.fields))
            }
            // A switch the user turned off refuses before any card, regardless of posture.
            if let gate = try SwiftToolDispatcher.integrationGate(tool: tool, input: input, turn: turn) {
                let root = peerDirectoryDataRoot ?? defaultDataRoot()
                let store = root == defaultDataRoot() ? MacIntegrationPermissionStore.shared : MacIntegrationPermissionStore(dataRoot: root)
                if let refusal = try await SwiftToolDispatcher.switchRefusal(integration: gate.integration, mode: gate.mode, store: store) {
                    return ChatToolOutcome.refusedBeforeRunning(owner: refusal)
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
            // In the person's own turn their ask is their act: this exact call runs as theirs, admitted the way their card's Approve is (this
            // call, once), and the receipt and consent record carry their message. No card is filed; one still waiting for it is settled.
            if theirs, let words = await personsAsk(tool: tool, input: input, turn: turn) {
                wordTurn = turn.with(\.personAct, PersonAct(by: .word(quote: words), tool: tool, input: input, spent: [.call]))
                if !work.admissionOnly { cardsSettled = await settleCards(decidedBy: words, tool: tool, input: input, turn: turn) }
                admission = Self.securityEnvelope(envelope, decision: .allow,
                    reason: "The person asked for this in their own message in this conversation: “\(words)”.")
                theirs = false
                decision = .allow
                continue
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
                // The owner's ask, or a lever's, is now the person's card: what the agent reads says so, and what to do next.
                if ownerAsked || theirs, case .object(var fields) = pending {
                    let card = ApprovalWords.call(tool: tool, input: .object(approvalPayloadInput)).act
                    fields["card"] = .string("The person's card \"\(card)\" (\(approvalId)) is up in Mac chat and on their phone, and they decide: "
                        + "their Approve runs this exact call as theirs, their Decline leaves everything as it is; do not call it again.")
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
                    turn: resolved.approvalID.map { (id) -> Turn in
                        turn.cardCause?.approved(by: id)
                        return turn.with(\.personAct, PersonAct(by: .card(id: id), tool: tool, input: input, spent: [.call])) } ?? turn,
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
