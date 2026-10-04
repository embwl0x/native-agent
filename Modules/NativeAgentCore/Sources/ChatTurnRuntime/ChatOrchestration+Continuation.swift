import Foundation
import NativeAgentCore
import PersistenceCore
import Desk
import Transcripts

extension SwiftNativeTurnEngine {
    public func executeTurnWithStreamingToolLoop(
        surface: String = "chat", userMessage: String, sessionId: String? = nil,
        toolSessionId: String? = nil, runId: String? = nil, maxIterations: Int? = nil,
        turnWallClockSecondsOverride: TimeInterval? = nil, llm: any LLMClient,
        tools: any ToolDispatchClient, preBuiltContext: TurnContext? = nil,
        progress: ChatOrchestrationProgressHandler? = nil, rendersProse: Bool = true,
        cancelFlagPath: URL? = nil, providerAdmission: (@Sendable () async throws -> Void)? = nil,
        fileAccess: String = "auto", capabilityProfile: String? = nil
    ) async throws -> TurnEngineResult {
        let journal: DeskContinuationTurn?
        if let current = DeskContinuationScope.current { journal = current }
        else if let root = remPinsDataRoot, let runId, !runId.isEmpty {
            let envelope = TurnEnvelope.current(surface: surface)
            let metadata: [String: JSONValue]
            if case .object(let object) = envelope.persistedMetadata() { metadata = object }
            else { throw DeskContinuationError.unavailable }
            let route = ChatToolSessionContext.replyRoute ?? envelope.deliveryRoute
            var reply: [String: JSONValue] = ["surface": .string(route?.surface ?? surface)]
            for (key, value) in [("destinationId", route?.destinationId), ("threadId", route?.threadId),
                                 ("sourceKey", route?.sourceKey), ("replyTo", route?.replyTo),
                                 ("correlationId", route?.correlationId)] {
                if let value { reply[key] = .string(value) }
            }
            journal = DeskContinuationTurn(store: SwiftNativeDeskStore(dataRoot: root),
                record: DeskContinuation(runID: runId, sessionID: sessionId, surface: surface,
                    envelope: metadata, replyRoute: reply, remainingWork: userMessage, fileAccess: fileAccess,
                    peerSources: PeerDataTaint.current?.checkpointSources, capabilityProfile: capabilityProfile,
                    commandSignatureVerified: envelope.commandSignatureVerified, declaredRemote: envelope.declaredRemote,
                    helperDefinition: try StandingBotContinuity.currentBot.map { try JSONValue.fromEncodable($0) }))
        } else { journal = nil }
        let ownsJournal = await journal?.snapshot().runID == runId
        return try await DeskContinuationScope.$current.withValue(journal) {
            do {
                let result = try await executeContinuationTurnBody(
                    surface: surface, userMessage: userMessage, sessionId: sessionId,
                    toolSessionId: toolSessionId, runId: runId, maxIterations: maxIterations,
                    turnWallClockSecondsOverride: turnWallClockSecondsOverride, llm: llm, tools: tools,
                    preBuiltContext: preBuiltContext, progress: progress, rendersProse: rendersProse,
                    cancelFlagPath: cancelFlagPath, providerAdmission: providerAdmission)
                let reason = result.terminalReason ?? .incomplete
                let state: DeskContinuation.State
                switch reason {
                case .replyCompleted: state = .complete
                case .iterationLimit, .wallClockLimit, .outputLimit: state = .ready
                case .cancelled: state = .canceled
                default: state = .blocked
                }
                // A successor publishes completion only together with its full
                // ChatResponse, including attachments, in the client owner.
                let checkpoint = await journal?.snapshot()
                let completingSuccessor = state == .complete && (checkpoint?.resumeCount ?? 0) > 0
                    && checkpoint?.pending.isEmpty == true
                if ownsJournal && !completingSuccessor {
                    try await journal?.finish(state: state, reply: result.reply, reason: reason.rawValue,
                        peerSources: PeerDataTaint.current?.checkpointSources)
                }
                return result
            } catch {
                let canceled = Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath)
                if ownsJournal {
                    try await journal?.finish(state: canceled ? .canceled : .ready, reply: "",
                        reason: canceled ? "canceled" : "turn_interrupted",
                        peerSources: PeerDataTaint.current?.checkpointSources)
                }
                throw error
            }
        }
    }
}
