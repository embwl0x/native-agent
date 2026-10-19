import Foundation
import ProviderRouting
import NativeAgentShared
import MacControl

public protocol MacChatRenderedMessage: MacChatRetryMessage {
    var sessionId: String? { get }
    var macChatHasMetadata: Bool { get }
    var macChatPartial: Bool { get }
    var macChatCancelled: Bool { get }
}

public struct MacChatStreamCompletion: Sendable {
    public let sessionId: String?
    public let text: String
    /// Where `text`'s working commentary ends, when the core's final reply is
    /// the text and it said so.
    public var workingCommentaryCharacters: Int? = nil
}

public enum MacChatStreamExit: Sendable {
    case exhausted
    case consumerCancelled
    case failed(cancellationShaped: Bool)
}

public struct MacChatStreamSettlement: Sendable {
    public let proof: MacChatTurnTranscriptTerminalProof
    public let state: MacChatTurnLifecycleState?
    public let signal: MacChatTurnObservedTerminalSignal

    public var hasCanonicalReceipt: Bool {
        switch proof {
        case .completed, .failed, .canceled: return true
        case .absent, .unavailable: return false
        }
    }

    public var hasAssistantReceipt: Bool {
        switch proof {
        case .completed, .failed: return true
        case .canceled, .absent, .unavailable: return false
        }
    }
}

public extension MacChatTurnPresentationPort {
    /// EOF is not settlement. Join the exact producer's canonical writes before
    /// admitting its result to either the final bubble or terminal proof reader.
    func completeMacChatStream(
        metaBox: MacChatStreamAdapter.MetaBox,
        sessionId: String,
        generation: Int,
        streamedText: String
    ) async throws -> MacChatStreamCompletion? {
        // AsyncThrowingStream cancellation may end iteration cleanly.
        try Task.checkCancellation()
        await metaBox.waitForProducerTermination()
        guard macChatTurns.taskGenerations[sessionId] == generation else { return nil }
        let final = metaBox.finalResponse()
        let reply = final.map(\.reply)
            .flatMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : value
            }
        return MacChatStreamCompletion(
            sessionId: final?.sessionId,
            text: reply ?? streamedText,
            workingCommentaryCharacters: reply == nil ? nil : final?.workingCommentaryCharacters
        )
    }

    /// A cancelled consumer still joins persistence. This deliberately does
    /// not throw on cancellation and never advances a replacement generation.
    func joinFailedMacChatStream(
        metaBox: MacChatStreamAdapter.MetaBox,
        sessionId: String,
        generation: Int
    ) async -> Bool {
        await metaBox.waitForProducerTermination()
        return macChatTurns.taskGenerations[sessionId] == generation
    }

    func settleMacChatStream(
        identity: MacChatTurnIdentity,
        metaBox: MacChatStreamAdapter.MetaBox,
        exit: MacChatStreamExit
    ) async -> MacChatStreamSettlement {
        let proof = await readCanonicalChatTurnTerminalProof(identity: identity)
        let signal: MacChatTurnObservedTerminalSignal
        switch exit {
        case .exhausted:
            signal = metaBox.observedTerminalSignal()
        case .consumerCancelled:
            signal = MacChatTurnLifecycleTerminalResolver
                .signalAfterConsumerCancellation(metaBox.observedTerminalSignal())
        case .failed(let cancellationShaped):
            // The consumer was not cancelled. A cancellation-shaped throw
            // cannot establish a real Stop; canonical evidence must decide.
            signal = cancellationShaped ? .ambiguousTermination : metaBox.observedTerminalSignal()
        }
        let state = await settleChatTurnLifecycle(
            identity: identity,
            kind: MacChatTurnLifecycleTerminalResolver.resolve(
                transcriptProof: proof, observedSignal: signal
            ),
            at: Date()
        )
        return MacChatStreamSettlement(proof: proof, state: state, signal: signal)
    }

    func migrateMacChatTurnRuntime(
        from requestSessionId: String,
        to sid: String,
        turnId: String
    ) async {
        await migrateQueuedChatTurns(from: requestSessionId, to: sid)
        if macChatTurns.streamingSessions.contains(requestSessionId) {
            macChatTurns.streamingSessions.remove(requestSessionId)
            macChatTurns.streamingSessions.insert(sid)
        }
        if macChatTurns.busySessions.contains(requestSessionId) {
            macChatTurns.busySessions.remove(requestSessionId)
            macChatTurns.busySessions.insert(sid)
        }
        presentMacChatTurn(.moveReplying(from: requestSessionId, to: sid))
        if let t = macChatTurns.tasks.removeValue(forKey: requestSessionId) {
            macChatTurns.tasks[sid] = t
        }
        if let g = macChatTurns.taskGenerations.removeValue(forKey: requestSessionId) {
            macChatTurns.taskGenerations[sid] = g
        }
        if let rebound = migrateChatTurnLifecycleIntake(
            from: requestSessionId, to: sid, turnId: turnId
        ) {
            let migrated = await persistChatTurnLifecycleMigration(
                state: rebound, from: requestSessionId
            )
            if !migrated {
                _ = applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
                    identity: rebound.identity,
                    kind: .outcomeUnknown(
                        reason: "I'm not sure that finished \u{2014} if my answer isn't here, say it again and I'll pick it up."
                    ),
                    occurredAt: Date()
                ))
            }
        }
    }
}

public extension MacChatTurnTranscriptPort {
    func reconcileMacChatStreamSession(
        from requestSessionId: String, to sid: String, turnId: String,
        dropPresentation: (String) -> Void,
        migratePresentation: (String, String) -> Void
    ) async -> Bool {
        let sidAlreadyPopulated = macChatMessageRows[sid] != nil
            || macChatTurns.streamingSessions.contains(sid)
            || macChatTurns.tasks[sid] != nil
        if sidAlreadyPopulated {
            // The real session may have an unrelated admitted turn. Drop only
            // the placeholder projection; its original generation owns cleanup.
            macChatMessageRows.removeValue(forKey: requestSessionId)
            dropPresentation(requestSessionId)
            _ = await settleChatTurnLifecycle(
                identity: MacChatTurnIdentity(sessionId: requestSessionId, turnId: turnId),
                kind: .outcomeUnknown(
                    reason: "I'm not sure that finished \u{2014} if my answer isn't here, say it again and I'll pick it up."
                ),
                at: Date()
            )
            return false
        }
        if let rows = macChatMessageRows.removeValue(forKey: requestSessionId) {
            macChatMessageRows[sid] = rows
        }
        migratePresentation(requestSessionId, sid)
        await migrateMacChatTurnRuntime(from: requestSessionId, to: sid, turnId: turnId)
        return true
    }

    func reconcileCompletedMacChatStream(
        identity: MacChatTurnIdentity, metaBox: MacChatStreamAdapter.MetaBox,
        producedNoContent: Bool, makeNoContentNotice: () -> MacChatMessage
    ) async -> (proceed: Bool, messagesRefreshed: Bool) {
        let sessionId = identity.sessionId
        var messagesRefreshed = false
        if let fresh = try? await loadMacChatMessages(sessionId: sessionId, cached: true), !fresh.isEmpty {
            macChatMessageRows[sessionId] = fresh
            messagesRefreshed = true
        }
        let settlement = await settleMacChatStream(identity: identity, metaBox: metaBox, exit: .exhausted)
        if settlement.state?.presentation.phase == .canceled { return (false, messagesRefreshed) }
        if producedNoContent, !settlement.hasAssistantReceipt {
            appendMacChatMessage(makeNoContentNotice(), to: sessionId)
        }
        macChatSessionRows = (try? await loadMacChatSessions()) ?? macChatSessionRows
        return (true, messagesRefreshed)
    }

    func reconcileCancelledMacChatStream(
        identity: MacChatTurnIdentity, metaBox: MacChatStreamAdapter.MetaBox
    ) async {
        if let fresh = try? await loadMacChatMessages(sessionId: identity.sessionId, cached: true), !fresh.isEmpty {
            macChatMessageRows[identity.sessionId] = fresh
        }
        _ = await settleMacChatStream(identity: identity, metaBox: metaBox, exit: .consumerCancelled)
    }

    func reconcileFailedMacChatStream(
        identity: MacChatTurnIdentity, metaBox: MacChatStreamAdapter.MetaBox,
        error: Error, originalUser: MacChatMessage, predecessor: MacChatMessage?,
        hideUserBubble: Bool, syntheticPrefix: String,
        makeNotice: () -> MacChatMessage,
        markUnpersisted: (MacChatMessage) -> MacChatMessage
    ) async -> Bool {
        let sessionId = identity.sessionId
        let fresh = try? await loadMacChatMessages(sessionId: sessionId, cached: true)
        if let fresh, !fresh.isEmpty { macChatMessageRows[sessionId] = fresh }
        let settlement = await settleMacChatStream(
            identity: identity, metaBox: metaBox,
            exit: .failed(cancellationShaped: error is CancellationError)
        )
        // A marker-only Stop need not cancel the UI task. Canonical evidence
        // still decides whether a retry notice may be published.
        if settlement.state?.presentation.phase == .canceled { return false }
        if settlement.signal == .ambiguousTermination,
           settlement.state?.presentation.phase == .outcomeUnknown {
            presentMacChatTurn(.status("Turn stopped; its outcome could not be confirmed"))
            return false
        }
        if !settlement.hasAssistantReceipt {
            let notice = makeNotice()
            if !hideUserBubble, let fresh,
               let restored = MacChatTurnRuntime.restoredUnpersistedChatRequest(
                originalUser: originalUser, predecessor: predecessor,
                notice: notice, canonicalMessages: fresh, syntheticPrefix: syntheticPrefix,
                markUnpersisted: markUnpersisted
               ) {
                macChatMessageRows[sessionId] = restored
            } else {
                appendMacChatMessage(notice, to: sessionId)
            }
        }
        macChatSessionRows = (try? await loadMacChatSessions()) ?? macChatSessionRows
        return true
    }
}

public extension MacChatTurnRuntime {
    nonisolated static let syntheticErrorIDPrefix = "na-synthetic-error-"

    nonisolated static func restoredUnpersistedChatRequest<Message: MacChatRenderedMessage>(
        originalUser: Message, predecessor: Message?, notice: Message,
        canonicalMessages: [Message], syntheticPrefix: String,
        markUnpersisted: (Message) -> Message
    ) -> [Message]? {
        guard let sessionID = originalUser.sessionId, !sessionID.isEmpty,
              notice.sessionId == sessionID, originalUser.role == "user",
              notice.id.hasPrefix(syntheticPrefix), notice.macChatHasMetadata else { return nil }
        let unpersistedNotice = markUnpersisted(notice)
        let local = [predecessor].compactMap { $0 } + [originalUser, unpersistedNotice]
        guard let snapshot = MacChatRetrySnapshot.capture(
            target: unpersistedNotice, messages: local, sessionId: sessionID, isSyntheticNotice: true
        ), snapshot.matchesCanonical(canonicalMessages) else { return nil }
        return canonicalMessages + [originalUser, unpersistedNotice]
    }

    nonisolated static func isCompletedAssistant<Message: MacChatRenderedMessage>(_ message: Message?) -> Bool {
        guard let message, message.role == "assistant" else { return false }
        return !message.macChatPartial && !message.macChatCancelled
    }

    nonisolated static func normalizeStreamErrorForChat(_ error: Error, advice: (Error) -> String) -> String {
        if let person = ProviderRecoveryPolicy.personMessage(error) { return person }
        let raw = error.localizedDescription
        let text = ChatStreamErrorText.normalize(raw)
        return text == "Chat error: \(raw)" ? advice(error) : text
    }
}

public extension MacChatStreamAdapter {
    static func chatStream(
        client: SwiftNativeChatOrchestrationClient,
        text: String, attachments: [NativeAgentShared.MultimodalAttachment],
        sessionId: String, activityIdentity: MacChatTurnIdentity, replyRowId: String, metaBox: MetaBox,
        hideUserBubble: Bool, serviceTier: @escaping @Sendable () -> String?,
        onTurnActivity: @escaping @Sendable (MacChatTurnActivity) async -> Void,
        onScreenPreview: @escaping @Sendable (MacScreenPreviewUpdate) async -> Void
    ) -> AsyncThrowingStream<MacChatStreamUpdate, Error> {
        let message = text.isEmpty ? "(see attachments)" : text
        return stream(
            sessionId: sessionId, metaBox: metaBox, activityIdentity: activityIdentity,
            onTurnActivity: onTurnActivity, onScreenPreview: onScreenPreview
        ) {
            // The producer owns the service-tier binding for its whole life.
            client.chatStreamExecution(
                message: message, sessionId: sessionId,
                model: "", reasoningEffort: "", fileAccess: "auto",
                attachments: attachments, persona: nil, surface: "chat",
                suppressUserAppend: hideUserBubble, choice: nil, serviceTier: serviceTier(),
                consumerRendersInlineCards: true, replyRowID: replyRowId
            )
        }
    }
}
