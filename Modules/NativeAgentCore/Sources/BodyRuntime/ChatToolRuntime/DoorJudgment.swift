import SenseCore
import MacNerves
import MindCore
import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
import ProviderRouting
// Blueprint: | `DoorJudgment.swift` | Trust judgments, replay identity and the owner of a decision |

extension DoorPipeline {
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
    func personsAsk(tool: String, input: [String: JSONValue], turn: Turn) async -> String? {
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
    func settleCards(decidedBy words: String, tool: String, input: [String: JSONValue], turn: Turn) async -> JSONValue {
        guard let session = turn.verifiedSessionID ?? policy.verifiedSessionId else { return .null }
        let call = Self.withoutBecause(MacInjectionArgRedaction.redacted(tool: tool, input: input, turn: turn))
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
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

    private static func requiresDesktopInteraction(tool: String, capabilities: CapabilitySet) -> Bool {
        let name = tool.replacingOccurrences(of: ".", with: "_")
        if name.hasPrefix("bot_") || name.hasPrefix("shelf_") { return false }
        return !capabilities.isDisjoint(with: .desktopInteraction)
            || ["browser_open_url", "browser_navigate", "browser_chrome_navigate",
                "browser_chrome_scroll", "mac_activate_app", "app_activate", "speak", "voice_speak", "sound_play"].contains(name)
    }

    /// One gated call once its arguments, envelope and replay are read: what decides it and who, carried through every round of
    /// its decision (an owner's ask or the person's own ask turns the decision, and the call is judged again). The stages are this
    /// dispatcher's methods that take it; it lives for one call.
    struct JudgedCall {
        let tool: String
        let input: [String: JSONValue]
        let surface: String
        let turn: Turn
        let work: ChatTurnWork
        let namedConnect: Bool
        let envelope: SecurityToolEnvelope
        let approvedReplayAuthorizes: Bool
        let injectionReplayApprovalID: String?
        let autonomyDecision: AutonomyDecision
        let securityAsked: Bool
        let decidedRequester: String?
        let trustedBridge: Bool
        let requester: String?
        let peerWorded: Bool
        var decision: AutonomyDecision
        var admission: SecurityToolEnvelope
        var ownUndo: String?
        var theirs = false
        // The person's ask, once it decides this call: their act for this exact call, as their card's Approve would be; and the cards it
        // settled that were waiting for this call.
        var wordTurn: Turn?
        var cardsSettled: JSONValue = .null
        var ownerAsked = false
    }

    // Arguments first: the call is checked against its schema and its owner's own checks (targets, names, ids, values) before any
    // decision but .allow is acted on, so a call that cannot run is refused at once in its owner's words and never becomes a card, an
    // approval, a notification or a deny. The order is validate, decide, card, run, for every caller. An allowed call pays no preview:
    // its run's own prepare refuses in the same shape. A question the check would put to the person (a permission it needs) gives way
    // to a deny, which raises nothing.
    func argumentRefusal(denied: Bool, tool: String, input: [String: JSONValue], surface: String, turn: Turn,
                                 work: ChatTurnWork) async -> JSONValue? {
        // Screen control's card admits a part's hand on its watched window before primitive validation.
        guard work.authoredCall?.tool != tool || AuthoredToolEffects.handOperations.contains(tool) else { return nil }
        let turn = turn.with(\.verifiedSessionID, policy.verifiedSessionId ?? turn.verifiedSessionID)
        guard let refusal = await endpoint.preApprovalRefusal(turn: turn, invocation: policy.scoping(work.invocation),
            tool: tool, input: input, surface: surface) else { return nil }
        if ChatToolOutcome.isWaitingInteraction(refusal) { return denied ? nil : refusal }
        return ChatToolOutcome.refusedBeforeRunning(owner: refusal)
    }

    /// What the replay checks found: a refusal that ends the call, or whether a verified replay authorizes it and the injection
    /// approval it carries.
    enum ReplayCheck {
        case refused(JSONValue)
        case checked(approvedReplayAuthorizes: Bool, injectionReplayApprovalID: String?)
    }

    /// Verifies a replay this call claims against the inbox before any exemption or minting; an unverified replay never runs.
    func verifyReplay(tool: String, input: [String: JSONValue], surface: String, turn: Turn,
                              envelope: SecurityToolEnvelope) async throws -> ReplayCheck {
        // Verify every replay against the inbox and burn its exemption for one dispatch; unverified replays are denied.
        guard let replay = policy.approvedReplay,
              replay.matches(turn: turn, tool: tool, surface: surface, input: input, verifiedSessionID: policy.verifiedSessionId)
        else { return .checked(approvedReplayAuthorizes: false, injectionReplayApprovalID: nil) }
        if !MacInjectionToolNames.isInjectionTool(tool) {
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
                    Self.securityEnvelope(envelope, decision: .block, reason: reason), turn: turn
                )
                let store = verdict == .spendUnavailable || verdict == .notSpentByExecutor ? "effect_spends.json" : "requests.json"
                let path = dataRoot.appendingPathComponent("workflows/approvals/" + store).path
                let remedy: JSONValue = .object(["kind": .string("inspect"),
                    "instruction": .string("""
                        Inspect approval \(replay.approvalID) in requests.json and effect_spends.json, then reconcile the effect owner's receipt. \
                        This replay did not run; the earlier effect is unknown. Reading these files does not establish the outcome or authorize a \
                        resend.
                        """),
                    "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("files.read"),
                        "args": .object(["path": .string(path)])])])])
                return .refused(.object(["status": .string("failed"), "reason": .string(reason), "effects": .string("unknown"), "remedy": remedy]))
            }
            return .checked(approvedReplayAuthorizes: true, injectionReplayApprovalID: nil)
        }
        let verdict = try await injectionApprovalVerifier.verifyInjectionApproval(approvalID: replay.approvalID,
            tool: tool, surface: surface, input: input, turn: turn)
        guard verdict == .verified else {
            let reason = "injection_replay_evidence_unverified: \(verdict.rawValue) "
                + "(\(tool) replay claimed approval \(replay.approvalID))"
            await audit(Self.securityEnvelope(envelope, decision: .block, reason: reason), turn: turn)
            throw AutonomyGateError.toolDenied(reason: reason)
        }
        return .checked(approvedReplayAuthorizes: false, injectionReplayApprovalID: replay.approvalID)
    }

    /// Decides the call from the security envelope and the autonomy level, then words it for another agent's steering: who asks,
    /// and whether the agent decided for them.
    func decideCall(tool: String, input: [String: JSONValue], surface: String, turn: Turn, work: ChatTurnWork,
                            namedConnect: Bool, envelope: SecurityToolEnvelope, approvedReplayAuthorizes: Bool,
                            injectionReplayApprovalID: String?) throws -> JudgedCall {
        let autonomyLevel = envelope.autonomyLevel
        let fullMacOn = [.admitted, .untrustedOrigin].contains(envelope.fullMacYoloAuthority)
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
                    + "\(policy.approvedReplay?.approvalID ?? "unknown")"
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
        let peerReasonMayReplace: Bool
        if case .deny = decision { peerReasonMayReplace = false } else { peerReasonMayReplace = true }
        let protectedAction = try PeerTurnEffectPolicy.requiresPeerApproval(tool, input: input, turn: turn)
        var decidedRequester = fullMacOn && protectedAction
            && turn.envelope?.workIdentity?.hasPrefix("carry.") == true ? "Full Mac" : nil
        if botDesktop, fullMacOn, case .allow = decision {
            admission = Self.securityEnvelope(envelope, decision: .allow, reason: "The agent decided for a helper")
            decidedRequester = "a helper"
        }
        let peerTurnID = PeerDataTaint.attestedPeerID(turn: turn)
        let taint = turn.peerSteering
        var heldTrust: PeerDataTaint.TrustRead?
        let trust: () -> PeerDataTaint.TrustRead = {
            if let heldTrust { return heldTrust }
            let sources = PeerDataTaintDispatcher.trustSources(turn: turn)
            let read = PeerTrust.read(sources, dataRoot: turn.dataRoot)
            heldTrust = read
            return read
        }
        let trustedBridge = PeerDataTaint.trustedTurn(turn, trust: trust)
        let peerApproval = PeerDataTaintDispatcher.peerApproval(turn: turn, surface: surface,
            protectedAction: protectedAction, trust: trust)
        let requester = peerApproval.requester
        var peerWorded = false
        if !approvedReplayAuthorizes, injectionReplayApprovalID == nil,
           peerReasonMayReplace, requester != nil {
            // The cards name the steering peers by their contact names, never a raw peer id.
            let sources = taint?.untrustedSources(trust: trust) ?? []
            let named = sources.map { source -> String in
                if source.hasPrefix("peer:") { return trust().doorName(String(source.dropFirst(5))) ?? source }
                return source.contains(" ") ? source : source.prefix(1).uppercased() + source.dropFirst()
            }.joined(separator: ", ")
            if fullMacOn, peerApproval.required {
                // The Full Mac card names steering peers and quotes their relevant line.
                decision = .requireApproval(reason: try PeerTurnEffectPolicy.floorReason(
                    tool: tool, input: input, requester: named.isEmpty ? requester ?? "" : named,
                    quote: Self.peerQuote(taint?.lastLine ?? ""), turn: turn))
                peerWorded = true
            } else if let requester, protectedAction {
                if fullMacOn {
                    // Under Full Mac, audit the agent's allowed decision for the requester.
                    if case .allow = decision {
                        admission = Self.securityEnvelope(envelope, decision: .allow, reason: "The agent decided for \(requester)")
                        decidedRequester = requester
                    }
                } else if peerApproval.required {
                    let bridgeName = peerTurnID.flatMap { trust().doorName($0) } ?? ""
                    decision = .requireApproval(reason: PeerTurnEffectPolicy.approvalReason(
                        requester: named.isEmpty ? bridgeName : named))
                    peerWorded = true
                }
            }
        }
        return JudgedCall(tool: tool, input: input, surface: surface, turn: turn, work: work, namedConnect: namedConnect,
            envelope: envelope, approvedReplayAuthorizes: approvedReplayAuthorizes, injectionReplayApprovalID: injectionReplayApprovalID,
            autonomyDecision: autonomyDecision, securityAsked: securityAsked, decidedRequester: decidedRequester, trustedBridge: trustedBridge,
            requester: requester, peerWorded: peerWorded, decision: decision, admission: admission)
    }

    /// Settles who decides before the call runs or asks: the agent undoing its own act, the person's lever, the argument check a
    /// card would carry, the person's own contact send. Returns a refusal that ends the call.
    func settleWhoDecides(_ judged: inout JudgedCall) async throws -> JSONValue? {
        let tool = judged.tool, input = judged.input, surface = judged.surface, turn = judged.turn, work = judged.work,
            envelope = judged.envelope, securityAsked = judged.securityAsked, autonomyDecision = judged.autonomyDecision,
            requester = judged.requester
        // Removing what the agent's own create made is the agent undoing its own act, not deleting the person's things: it runs without a
        // card in this turn or a later one, as long as the create would run without a card for this same asker now. Another agent's
        // steering and a security ask keep their card; Safe's refusal is a deny and stands.
        if case .requireApproval = judged.decision, !securityAsked, requester == nil,
           let words = await AgentMade.undoing(tool: tool, input: input,
               origin: .currentTurn(turn: turn.with(\.verifiedSessionID, policy.verifiedSessionId ?? turn.verifiedSessionID), surface: surface),
               security: envelope, turn: turn, securityCenter: securityCenter, peerRequester: requester) {
            judged.admission = Self.securityEnvelope(envelope, decision: .allow, reason: words)
            judged.decision = .allow
            judged.ownUndo = words
        }
        // A change that is the person's to decide and that a card can carry (a lever's ask here, a setting raise's or an owner-only row's
        // from its owner below) is decided by their card, or by their own ask when the turn is theirs (`personsAsk`). A security ask,
        // another agent's steering or a peer's request keeps its card.
        if case .requireApproval = autonomyDecision, !securityAsked, requester == nil,
           try PermissionLaw.lever(tool: tool, input: input, turn: turn)?.asks == true {
            let owns = try await SwiftNativeTrustCenter(dataRoot: securityCenter.dataRoot).agentOwnsLevers(turn: turn)
            judged.theirs = !owns
        }
        if case .allow = judged.decision {} else {
            if case .deny(let reason) = judged.decision {
                // Trust's consent history keeps every deny, a call refused for its arguments too.
                await audit(Self.securityEnvelope(envelope, decision: .block, reason: reason), turn: turn)
                if let refusal = await argumentRefusal(denied: true, tool: tool, input: input, surface: surface, turn: turn, work: work) { return refusal }
            } else if let refusal = await argumentRefusal(denied: false, tool: tool, input: input, surface: surface, turn: turn, work: work) { return refusal }
        }
        // The user's own contact send needs no card. Broader execution and Trust refusals must be stated plainly.
        if turn.personInitiatedSend?.claim(tool: tool, input: input, surface: surface) == true {
            let name: String = {
                guard case .string(let agent)? = input["agent"], agent.hasPrefix("peer:") else { return "This contact" }
                return PeerTrust.doorName(String(agent.dropFirst(5)), dataRoot: dataRoot) ?? "This contact"
            }()
            switch judged.decision {
            case .allow: break
            case .requireApproval where envelope.capabilities.isSubset(of: .personInitiatedSendOnly):
                judged.admission = Self.securityEnvelope(envelope, decision: .allow, reason: "person-initiated send from a contact thread")
                judged.decision = .allow
            case .requireApproval:
                await audit(Self.securityEnvelope(envelope, decision: .ask,
                    reason: "person-initiated send needs more than the send"), turn: turn)
                return PersonInitiatedSend.refusal("\(name) runs on this Mac, and your Trust setting asks before starting it. Nothing was sent.")
            case .deny:
                await audit(Self.securityEnvelope(envelope, decision: .block,
                    reason: "person-initiated send refused by Trust"), turn: turn)
                return PersonInitiatedSend.refusal("Your Trust settings don't allow messaging \(name) right now. Nothing was sent.")
            }
        }
        return nil
    }
}
