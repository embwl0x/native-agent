import Foundation

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
