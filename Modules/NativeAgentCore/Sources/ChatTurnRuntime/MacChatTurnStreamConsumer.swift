import Foundation

public extension MacChatTurnPresentationPort {
    /// Only changed frames cross to the app; lifecycle and exact generation
    /// admission stay here. The accumulator's intake/ticker remain off MainActor.
    func consumeMacChatStream(
        _ stream: AsyncThrowingStream<MacChatStreamUpdate, Error>,
        sessionId requestSessionId: String,
        bubbleId: String,
        generation: Int,
        activityIdentity: MacChatTurnIdentity
    ) async throws -> String {
        let accumulator = ChatStreamAccumulator()
        return try await accumulator.consume(
            stream, interval: ChatStreamAccumulator.publishInterval
        ) { @MainActor [self, requestSessionId] snapshot, length, settled in
            try Task.checkCancellation()
            // A superseded turn stops publishing; the post-stream guard returns.
            guard macChatTurns.taskGenerations[requestSessionId] == generation else { return }
            presentMacChatTurn(.streamFrame(
                sessionId: requestSessionId, bubbleId: bubbleId, text: snapshot
            ))
            _ = recordChatTurnStreamProgress(
                identity: activityIdentity,
                accumulatedUTF16Length: length,
                at: Date()
            )
            if let settled {
                _ = applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
                    identity: activityIdentity,
                    kind: .replyTextSettled(settled),
                    occurredAt: Date()
                ))
            }
        }
    }
}
