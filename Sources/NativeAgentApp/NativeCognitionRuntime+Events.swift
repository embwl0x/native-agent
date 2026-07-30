import Foundation
import CognitiveSubstrate
import NativeAgentCore
import PersistenceCore

enum NativeCognitiveEventFactory {
    static func turnMessage(
        surface: String,
        role: String,
        text: String,
        sessionId: String?,
        messageId: String?,
        turnKind: CognitiveTurnKind? = nil,
        now: Date = Date()
    ) -> CognitiveEvent? {
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kind: CognitiveEventKind
        let sourceClass: CognitiveSourceClass
        switch normalizedRole {
        case "user":
            kind = .userMessageReceived
            sourceClass = .userStated
        case "assistant":
            kind = .assistantTurnCompleted
            sourceClass = .observed
        default:
            return nil
        }

        let safeText = bounded(redact(text.trimmingCharacters(in: .whitespacesAndNewlines)), max: 700)
        guard !safeText.isEmpty else { return nil }
        let safeSurface = bounded(redact(surface), max: 80)
        let safeSession = bounded(redact(sessionId ?? "unknown"), max: 180)
        let safeMessage = bounded(redact(messageId ?? timestampID(now)), max: 180)

        let resolvedTurnKind: CognitiveTurnKind = if let turnKind {
            turnKind
        } else {
            switch CognitiveTurnKind.inferred(fromSignals: [safeSurface, safeText]) {
            case .debug: .debug
            case .verification: .verification
            case .live, .system: .live
            }
        }

        return CognitiveEvent(
            id: "turn:\(safeSurface):\(normalizedRole):\(safeSession):\(safeMessage):\(timestampID(now))",
            kind: kind,
            subject: CognitiveSubjectReference(
                type: "chat_turn",
                id: "\(safeSession):\(safeMessage)",
                label: "\(safeSurface) \(normalizedRole)"
            ),
            sourceClass: sourceClass,
            occurredAt: now,
            summary: safeText,
            importance: normalizedRole == "user" ? 0.62 : 0.48,
            turnKind: resolvedTurnKind,
            metadata: [
                "surface": .string(safeSurface),
                "role": .string(normalizedRole),
                "sessionId": .string(safeSession),
                "messageId": .string(safeMessage),
                "event_class": .string(kind.rawValue),
            ]
        )
    }

    static func remoteAction(
        surface: String,
        action: String,
        payload: [String: String],
        response: [String: String],
        now: Date = Date()
    ) -> CognitiveEvent? {
        let normalizedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAction.isEmpty else { return nil }

        let status = response["status"] ?? response["ok"] ?? "unknown"
        let lowerAction = normalizedAction.lowercased()
        let lowerStatus = status.lowercased()
        let isError = lowerStatus == "error"
            || lowerStatus == "failed"
            || lowerStatus == "blocked"
            || response["ok"] == "false"

        let inboxAction = (payload["actionId"] ?? payload["action"] ?? "").lowercased()
        let isCorrection = lowerAction.hasPrefix("reject")
            || lowerAction.hasPrefix("cancel")
            || lowerAction == "deleteMemory".lowercased()
            || (lowerAction == "inboxaction" && ["reject", "deny", "dismiss"].contains(inboxAction))
        let isProviderFailure = lowerAction.contains("provider") && isError
        guard isCorrection || isProviderFailure else { return nil }

        let kind: CognitiveEventKind = isProviderFailure ? .providerFailure : .userCorrection
        let subject = remoteSubject(action: normalizedAction, payload: payload, response: response, kind: kind)
        let detail = response["message"] ?? response["error"] ?? response["detail"] ?? response["code"] ?? ""
        let safeDetail = bounded(redact(detail), max: 420)
        let summary = safeDetail.isEmpty
            ? "\(surface) \(normalizedAction) \(status)"
            : "\(surface) \(normalizedAction) \(status): \(safeDetail)"

        var metadata = selectedMetadata(
            surface: surface,
            action: normalizedAction,
            status: status,
            payload: payload,
            response: response
        )
        metadata["event_class"] = .string(kind.rawValue)

        return CognitiveEvent(
            id: "remote-action:\(surface):\(normalizedAction):\(subject.id):\(timestampID(now))",
            kind: kind,
            subject: subject,
            sourceClass: isCorrection ? .userStated : .observed,
            occurredAt: now,
            summary: bounded(summary, max: 700),
            importance: isCorrection ? 0.72 : 0.65,
            metadata: metadata
        )
    }

    /// Converts an existing owner's payload-free motor read model into
    /// resident attention. This is observation only: the domain owner keeps
    /// state and authority, and unknown external reality stays pending rather
    /// than being relabeled success or failure.
    static func motorActionState(
        _ model: MotorActionReadModel,
        now: Date = Date()
    ) -> CognitiveEvent? {
        let kind: CognitiveEventKind
        let importance: Double
        switch model.phase {
        case .succeeded:
            switch model.verification {
            case .satisfied, .notRequired:
                kind = .toolSucceeded
                importance = 0.7
            case .failed:
                kind = .toolFailed
                importance = 0.8
            case .notStarted, .pending, .unverified, .unknown:
                // Transport terminality is not lived success while the
                // claimed effect is still awaiting domain evidence.
                kind = .toolStarted
                importance = 0.62
            }
        case .failed, .blocked, .expired:
            kind = .toolFailed
            importance = 0.8
        case .running, .ready, .awaitingApproval, .awaitingHuman, .waitingExternal,
             .verifying, .proposed:
            kind = .toolStarted
            importance = model.phase == .waitingExternal ? 0.68 : 0.48
        case .cancelled:
            kind = .toolCancelled
            importance = 0.3
        case .unknown:
            return nil
        }

        guard let safeDomain = closedMotorToken(model.domain, maximum: 100),
              let safeIdentity = opaqueMotorIdentity(model.actionIdentity),
              let safeState = closedMotorToken(model.domainState, maximum: 100) else {
            return nil
        }
        let safeExpected = bounded(redact(model.expectedNextEvidence ?? ""), max: 240)
        var metadata: [String: JSONValue] = [
            "motorDomain": .string(safeDomain),
            "motorActionIdentity": .string(safeIdentity),
            "phase": .string(model.phase.rawValue),
            "status": .string(safeState),
            "verification": .string(model.verification.rawValue),
            "event_class": .string(kind.rawValue),
        ]
        if !safeExpected.isEmpty {
            metadata["expectedNextEvidence"] = .string(safeExpected)
        }
        let summary = safeExpected.isEmpty
            ? "\(safeDomain) action \(model.phase.rawValue) (\(safeState))"
            : "\(safeDomain) action \(model.phase.rawValue) (\(safeState)); next evidence: \(safeExpected)"
        let stateIdentity = CausalTransitionEvidence.opaqueIdentity([
            safeDomain,
            safeIdentity,
            model.phase.rawValue,
            safeState,
            model.verification.rawValue,
            model.updatedAt ?? "unknown",
        ].joined(separator: "|"))
        return CognitiveEvent(
            id: "motor:\(stateIdentity)",
            kind: kind,
            subject: CognitiveSubjectReference(
                type: "motor_action",
                id: safeIdentity,
                label: safeDomain
            ),
            sourceClass: .observed,
            occurredAt: now,
            summary: bounded(summary, max: 520),
            importance: importance,
            turnKind: .system,
            metadata: metadata
        )
    }

    /// Payload-free durable join fact. Free-form expected-evidence prose and
    /// owner timestamps are deliberately absent: historical settlement needs
    /// only the closed domain/state vocabulary and universal opaque identity.
    static func motorActionTrace(
        _ model: MotorActionReadModel,
        now: Date = Date()
    ) -> TurnTraceEvent? {
        guard let identity = opaqueMotorIdentity(model.actionIdentity),
              let domain = closedMotorToken(model.domain, maximum: 128),
              let domainState = closedMotorToken(model.domainState, maximum: 128) else {
            return nil
        }
        return TurnTraceEvent(
            turnId: "motor-\(identity)",
            ts: now,
            kind: "motor.state",
            payload: .object([
                "schema": .string("motor.action.read-model.v1"),
                "domain": .string(domain),
                "actionIdentity": .string(identity),
                "phase": .string(model.phase.rawValue),
                "domainState": .string(domainState),
                "verification": .string(model.verification.rawValue),
                "payloadFree": .bool(true),
                "controlAuthority": .bool(false),
            ])
        )
    }

    private static func opaqueMotorIdentity(_ raw: String) -> String? {
        let normalized = raw.lowercased()
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard normalized.count == 64,
              normalized.unicodeScalars.allSatisfy(hexadecimal.contains) else { return nil }
        return normalized
    }

    private static func closedMotorToken(_ raw: String, maximum: Int) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= maximum else { return nil }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._:")
        )
        guard raw.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return raw
    }

    private static func remoteSubject(
        action: String,
        payload: [String: String],
        response: [String: String],
        kind: CognitiveEventKind
    ) -> CognitiveSubjectReference {
        if kind == .providerFailure {
            let providerId = firstValue(
                keys: ["provider_id", "providerId"],
                payload: payload,
                response: response
            ) ?? action
            return CognitiveSubjectReference(type: "provider", id: providerId, label: providerId)
        }
        if let id = firstValue(keys: ["approvalId", "id"], payload: payload, response: response),
           action.lowercased().contains("approval") {
            return CognitiveSubjectReference(type: "approval", id: id, label: action)
        }
        if let executionId = firstValue(keys: ["missionId"], payload: payload, response: response) {
            let stepId = firstValue(keys: ["stepId"], payload: payload, response: response)
            return CognitiveSubjectReference(type: "mission_step", id: [executionId, stepId].compactMap { $0 }.joined(separator: ":"), label: action)
        }
        if let proposalId = firstValue(keys: ["proposalId"], payload: payload, response: response) {
            return CognitiveSubjectReference(type: "memory_proposal", id: proposalId, label: action)
        }
        if let candidateId = firstValue(keys: ["candidateId"], payload: payload, response: response) {
            return CognitiveSubjectReference(type: "promotion_candidate", id: candidateId, label: action)
        }
        if let itemId = firstValue(keys: ["itemId", "id"], payload: payload, response: response) {
            return CognitiveSubjectReference(type: "inbox_item", id: itemId, label: action)
        }
        if let sessionId = firstValue(keys: ["sessionId", "session_id"], payload: payload, response: response) {
            return CognitiveSubjectReference(type: "chat_session", id: sessionId, label: action)
        }
        return CognitiveSubjectReference(type: "remote_action", id: action, label: action)
    }

    private static func selectedMetadata(
        surface: String,
        action: String,
        status: String,
        payload: [String: String],
        response: [String: String]
    ) -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [
            "surface": .string(bounded(redact(surface), max: 80)),
            "action": .string(bounded(redact(action), max: 120)),
            "status": .string(bounded(redact(status), max: 80)),
        ]
        let keys = [
            "ok", "error", "code", "message", "detail",
            "provider_id", "providerId",
            "approvalId", "missionId", "stepId",
            "proposalId", "candidateId", "itemId", "actionId",
            "sessionId", "session_id", "sourceKey",
        ]
        for key in keys {
            if let value = response[key] ?? payload[key], !value.isEmpty {
                metadata[key] = .string(bounded(redact(value), max: 360))
            }
        }
        return metadata
    }

    private static func firstValue(
        keys: [String],
        payload: [String: String],
        response: [String: String]
    ) -> String? {
        for key in keys {
            if let value = response[key] ?? payload[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return bounded(redact(value), max: 180)
            }
        }
        return nil
    }

    private static func compactJSON(_ value: JSONValue, max: Int) -> String? {
        guard value != .null else { return nil }
        let serialized = (try? NativeAppSecretRedactor.redactValue(value).serialize(pretty: false))
            ?? String(describing: value)
        return bounded(serialized, max: max)
    }

    private static func redact(_ value: String) -> String {
        NativeAppSecretRedactor.redactText(value)
    }

    private static func bounded(_ value: String, max: Int) -> String {
        guard value.count > max else { return value }
        return String(value.prefix(max)) + "..."
    }

    fileprivate static func sessionKey(_ value: String?) -> String? {
        let safeSession = bounded(redact(value ?? "unknown"), max: 180)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safeSession.isEmpty || safeSession == "unknown" ? nil : safeSession
    }

    private static func timestampID(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970 * 1000))
    }
}

extension NativeCognitionRuntime {
    func inheritNonLiveTurnKind(
        for event: CognitiveEvent
    ) -> (event: CognitiveEvent, completedRunId: String?) {
        guard case .string(let rawRunId)? = event.metadata["runId"] else {
            return (event, nil)
        }
        let runId = rawRunId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runId.isEmpty else { return (event, nil) }

        var resolved = event
        if event.kind == .userMessageReceived {
            rememberNonLiveTurnKind(event.turnKind, runId: runId)
        } else if let inherited = nonLiveTurnKindByRunId[runId] {
            resolved.turnKind = inherited
            resolved.metadata["turnKind"] = .string(inherited.rawValue)
        }

        let completedRunId: String? = switch event.kind {
        case .assistantTurnCompleted, .providerFailure:
            runId
        default:
            nil
        }
        return (resolved, completedRunId)
    }

    func observeTurnMessage(
        surface: String,
        role: String,
        text: String,
        sessionId: String? = nil,
        messageId: String? = nil
    ) async {
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let safeSession = NativeCognitiveEventFactory.sessionKey(sessionId)
        let inheritedTurnKind: CognitiveTurnKind?
        if let safeSession, debugSessionIds.contains(safeSession) {
            inheritedTurnKind = .debug
        } else if normalizedRole == "assistant",
           let safeSession,
           pendingDebugReplySessionIds.remove(safeSession) != nil {
            inheritedTurnKind = .debug
        } else {
            inheritedTurnKind = nil
            if normalizedRole == "user", let safeSession {
                pendingDebugReplySessionIds.remove(safeSession)
            }
        }

        guard let event = NativeCognitiveEventFactory.turnMessage(
            surface: surface,
            role: role,
            text: text,
            sessionId: sessionId,
            messageId: messageId,
            turnKind: inheritedTurnKind
        ) else {
            return
        }
        if normalizedRole == "user",
           event.turnKind == .debug,
           let safeSession,
           Self.canTreatWholeSessionAsDebug(surface: normalizedSurface) {
            markSessionDebug(safeSession)
            pendingDebugReplySessionIds.insert(safeSession)
        }
        await observe(event)
    }

    func observeUserMessage(
        surface: String,
        text: String,
        sessionId: String? = nil,
        messageId: String? = nil
    ) async {
        await observeTurnMessage(
            surface: surface,
            role: "user",
            text: text,
            sessionId: sessionId,
            messageId: messageId
        )
    }

    func observeAssistantTurnCompleted(
        surface: String,
        text: String,
        sessionId: String? = nil,
        messageId: String? = nil
    ) async {
        await observeTurnMessage(
            surface: surface,
            role: "assistant",
            text: text,
            sessionId: sessionId,
            messageId: messageId
        )
    }

    func observeRemoteAction(
        surface: String,
        action: String,
        payload: [String: String],
        response: [String: String]
    ) async {
        guard let event = NativeCognitiveEventFactory.remoteAction(
            surface: surface,
            action: action,
            payload: payload,
            response: response
        ) else {
            return
        }
        await observe(event)
    }

    func observeMotorActionState(_ model: MotorActionReadModel) async {
        guard let event = NativeCognitiveEventFactory.motorActionState(model) else {
            return
        }
        guard await admitMotorConsequenceForResident(model, at: event.occurredAt) else { return }
        if dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL {
            Self.recordMotorActionTrace(model)
        }
        await observe(event)
    }

    nonisolated private static func recordMotorActionTrace(_ model: MotorActionReadModel) {
        guard let trace = NativeCognitiveEventFactory.motorActionTrace(model) else { return }
        TurnTraceBus.fire(trace)
    }

    private static func canTreatWholeSessionAsDebug(surface: String) -> Bool {
        surface == "chat" || surface == "codex_bridge" || surface.contains("codex")
    }
}

extension NativeCognitionRuntime: LLMCallLifecycleObserving {
    func observeProviderCall(_ event: LLMCallLifecycleEvent) async {
        await bootstrap()
        recordProviderLifecycleEvidence(event)
        // Provider-path evidence remains useful exact operational truth, but a
        // provider call caused by a Codex/debug bridge turn is not lived chat.
        // The matching user/tool/reply events are already excluded from the
        // somatic bus; excluding this parallel lifecycle edge prevents the
        // diagnostic call from changing agency, vigilance, or confidence by
        // itself while preserving the health belief above.
        if let session = NativeCognitiveEventFactory.sessionKey(event.sessionId),
           debugSessionIds.contains(session) || pendingDebugReplySessionIds.contains(session) {
            return
        }
        // INTEROCEPTION: passively feed the vitals sensor from the SAME lifecycle
        // event. Band transitions become graded felt sluggishness; sustained
        // degradation stages one approval card. Zero new provider calls.
        await feedProviderVitals(event)
        let kind: SomaticSignalKind
        let intensity: Double
        let valence: Double?
        switch event.phase {
        case .started:
            kind = .providerStarted
            intensity = 0.35
            valence = nil
        case .succeeded:
            kind = .providerSucceeded
            intensity = 0.55
            valence = 0.20
        case .failed:
            kind = .providerFailed
            intensity = 0.75
            valence = -0.45
        case .cancelled:
            kind = .providerCancelled
            intensity = 0.20
            valence = nil
        }

        var metadata: [String: JSONValue] = [
            "predictionCorrelationId": .string(event.id),
            "providerId": .string(event.providerId),
            "model": .string(event.model),
            "surface": .string(event.surface),
            "streaming": .bool(event.streaming),
            "phase": .string(event.phase.rawValue),
        ]
        if let sessionId = event.sessionId { metadata["sessionId"] = .string(sessionId) }
        if let turnId = event.turnId { metadata["turnId"] = .string(turnId) }

        // The router awaits only the in-memory organism mutation. Persistence
        // coalesces behind the actor and Context prewarm is intentionally absent:
        // provider lifecycle is body evidence, not new semantic context.
        await ingestOrganismSignal(
            kind: kind,
            sourceOrgan: "provider.\(event.providerId)",
            intensity: intensity,
            valence: valence,
            metadata: metadata,
            persistSynchronously: false,
            prewarmContext: false
        )
    }
}
