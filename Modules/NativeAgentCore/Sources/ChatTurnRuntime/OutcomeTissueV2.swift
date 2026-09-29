import Foundation
import NativeAgentCore
import PersistenceCore
import ChatSessionWork

extension ResponseOutcomeObservationV2 {
    public static func make(
        turnID rawTurnID: String?,
        messageID rawMessageID: String,
        sessionID rawSessionID: String,
        surface rawSurface: String,
        observedAt: Date,
        responsePersistence: String,
        result: TurnEngineResult? = nil,
        context: TurnContext? = nil,
        interventionAssignment explicitInterventionAssignment: CausalInterventionAssignment? = nil
    ) -> Self? {
        guard let turnID = OutcomeTraceIdentity.normalized(rawTurnID),
              let messageID = closedToken(rawMessageID, maximum: 128),
              let sessionID = NativeAgentChatSessionID.normalizedPathComponent(rawSessionID),
              let surface = closedToken(rawSurface, maximum: 128),
              ["persisted", "partial", "cancelled", "failed"].contains(responsePersistence)
        else { return nil }

        let observation = context.map(TurnEngineResult.TerminalObservation.init(context:))
            ?? result?.terminalObservation
        let packet = context?.fluidContextTurn?.packet
        let toolReferences = Array((result?.toolDispatches ?? []).prefix(64).enumerated()).compactMap {
            index, dispatch -> ResponseOutcomeToolReference? in
            guard let tool = closedToken(dispatch.name, maximum: 128) else { return nil }
            let sourceID = dispatch.id ?? "sequence:\(index)"
            let opaqueID = CausalTransitionEvidence.opaqueIdentity("\(turnID)|tool|\(sourceID)")
            return ResponseOutcomeToolReference(
                callID: opaqueID,
                tool: tool,
                resultClass: ChatToolOutcome.exactResultClass(dispatch.result).rawValue
            )
        }
        var seenMotorReferences = Set<String>()
        let boundedDispatches = Array((result?.toolDispatches ?? []).prefix(64))
        let motorReferences = boundedDispatches.compactMap {
            dispatch -> ResponseOutcomeMotorReference? in
            guard let reference = motorReference(dispatch: dispatch) else { return nil }
            let key = "\(reference.domain)|\(reference.actionID)"
            guard seenMotorReferences.insert(key).inserted else { return nil }
            return reference
        }
        var states: [String: OutcomeEvidenceState] = [
            "responsePersistence": .observed,
            "context": packet == nil ? .censored : .observed,
            // A model string alone cannot name a transport. A production
            // context does carry the admitted provider route, however, so
            // preserve that pre-dispatch fact on the canonical assistant row
            // instead of leaving a permanently unwired historical join.
            "provider": context?.providerId == nil
                ? (result == nil ? .censored : .unknown)
                : .observed,
            "tools": result == nil
                ? .censored
                : (toolReferences.isEmpty
                    ? .notApplicable
                    : (toolReferences.allSatisfy { $0.resultClass != "unknown" }
                        ? .observed : .unverified)),
            "motor": motorReferences.isEmpty
                ? (boundedDispatches.contains(where: {
                    ToolCausalBoundary.hasCanonicalMotorOwner(tool: $0.name)
                        || ToolCausalBoundary.isExternalProtocolTool($0.name)
                }) ? .unknown : .notApplicable)
                : aggregateMotorEvidence(motorReferences.map(\.verification)),
            "reaction": .unknown,
        ]
        if responsePersistence != "persisted" { states["responsePersistence"] = .unverified }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Self(
            turnID: turnID,
            messageID: messageID,
            sessionID: sessionID,
            surface: surface,
            observedAt: formatter.string(from: observedAt),
            responsePersistence: responsePersistence,
            contextGenerationID: packet?.generationID,
            contextSelectionReceiptID: packet.flatMap {
                closedToken($0.receipt.id, maximum: 128)
            },
            providerID: context.flatMap { closedToken($0.providerId, maximum: 128) },
            providerModel: result.flatMap { closedToken($0.modelUsed, maximum: 256) },
            reasoningEffort: observation.flatMap { closedToken($0.reasoningEffort, maximum: 64) },
            turnElapsedMs: result.map { min(24 * 60 * 60 * 1_000, max(0, $0.elapsedMs)) },
            tools: toolReferences,
            motorActions: motorReferences,
            dimensionStates: states,
            interventionAssignment: {
                // An explicit live assignment is authoritative for this
                // observation. If it is malformed, fail closed; never replace
                // it with an unrelated task-local laboratory assignment.
                if let explicitInterventionAssignment {
                    return validAssignment(explicitInterventionAssignment)
                        ? explicitInterventionAssignment
                        : nil
                }
                return validAssignment(OutcomeInterventionContext.assignment)
                    ? OutcomeInterventionContext.assignment
                    : nil
            }()
        )
    }

    private static func motorReference(
        dispatch: TurnEngineResult.ToolDispatchRecord
    ) -> ResponseOutcomeMotorReference? {
        guard case .object(let object) = dispatch.result,
              let binding = ToolCausalBoundary.motorReference(
                  tool: dispatch.name,
                  output: dispatch.result
              ) else { return nil }
        let verification: OutcomeEvidenceState = {
            if case .bool(true)? = object["procedure_verified"] { return .verified }
            if case .bool(false)? = object["procedure_verified"] { return .unverified }
            if case .bool(true)? = object["verifyPassed"] { return .verified }
            if case .bool(true)? = object["verified"] { return .verified }
            if case .bool(false)? = object["verifyPassed"] { return .unverified }
            if case .bool(false)? = object["verified"] { return .unverified }
            if case .string(let raw)? = object["verification"] {
                if raw == "verified" { return .verified } // legacy compatibility
                if let canonical = MotorVerificationState(rawValue: raw) {
                    return outcomeEvidence(for: canonical)
                }
            }
            // Browser's owner defines an observed successful WKWebView
            // navigation (`opened`) as satisfied verification. Preserve that
            // exact owner fact in the response anchor even if the process
            // exits before the detached motor trace reaches disk.
            if binding.domain == .browser, case .bool(let opened)? = object["opened"] {
                return opened ? .verified : .unverified
            }
            return .unknown
        }()
        return ResponseOutcomeMotorReference(
            actionID: binding.actionIdentity,
            ownerActionID: safeOwnerActionID(binding.ownerActionID),
            domain: binding.domain.rawValue,
            verification: verification
        )
    }

    private static func outcomeEvidence(
        for verification: MotorVerificationState
    ) -> OutcomeEvidenceState {
        switch verification {
        case .satisfied, .failed:
            // "Verified" describes evidence quality, not whether the action
            // itself succeeded. Phase/domain state retain outcome polarity.
            return .verified
        case .unverified:
            return .unverified
        case .unknown:
            return .unknown
        case .notStarted, .pending, .notRequired:
            return .observed
        }
    }

}
