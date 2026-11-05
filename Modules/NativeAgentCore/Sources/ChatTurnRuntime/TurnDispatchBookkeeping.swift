import Foundation
import ChatSessionWork
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// Blueprint: | `TurnDispatchBookkeeping.swift` | Joined dispatch bookkeeping on success, failure and Stop |

extension SwiftNativeTurnEngine {
    nonisolated static func preparePrefixTelemetry(_ seed: ConversationPrefixSeeding.Seed) async
        -> (snapshot: ConversationPrefixTelemetrySnapshot, milliseconds: Int64) {
        let start = DispatchTime.now().uptimeNanoseconds
        let snapshot = ConversationPrefixSeeding.telemetry(seed,
            toolSchemaFingerprint: toolSchemaFingerprint(seed.context.toolSchemas))
        return (snapshot, Int64((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
    }

    nonisolated static func recordDispatchBookkeeping(
        seed: ConversationPrefixSeeding.Seed,
        telemetry: Task<(snapshot: ConversationPrefixTelemetrySnapshot, milliseconds: Int64), Never>,
        sink: ConversationPrefixTelemetrySink?, surface: String, sessionId: String?, runId: String?,
        userMessageID: String?, dataRoot: URL?, turn: Turn
    ) async {
        var trace = ContextStageTrace(turn: turn)
        let persistStart = DispatchTime.now().uptimeNanoseconds
        if let sessionId, !sessionId.isEmpty, let runId, !runId.isEmpty {
            // Stop cannot cancel the evidence for a request already sent.
            await settle {
                await seed.sentContext.persist(sessionID: sessionId, runID: runId,
                    userMessageID: userMessageID, dataRoot: dataRoot)
            }
        }
        trace.record(.sentContextPersist, since: persistStart)
        let prefix = await telemetry.value
        sink?.set(prefix.snapshot)
        trace.setTiming(.prefixTelemetry, milliseconds: prefix.milliseconds)
        trace.setFlag("parallelWithDispatch", true)
        trace.emit(kind: "turn.bookkeeping.summary", surface: surface)
    }

    nonisolated static func recordWireSnapshot(
        request: ConversationPrefixSeeding.Request, messages: [LLMMessage],
        publication: ContextFedRecord.Publication?, prefix: ConversationPrefixTelemetrySnapshot?,
        surface: String, sessionId: String?, runId: String?, turn: Turn
    ) async {
        var trace = ContextStageTrace(turn: turn)
        let start = DispatchTime.now().uptimeNanoseconds
        fireContextSnapshotEvent(surface: surface, request: request, messages: messages,
            publication: publication, prefix: prefix, turn: turn, sessionId: sessionId, runId: runId, emitReady: false)
        fireAssemblyStageEvent(surface: surface, context: request.seed.context, turn: turn)
        trace.record(.contextSnapshot, since: start)
        trace.setFlag("parallelWithDispatch", true)
        trace.emit(kind: "turn.bookkeeping.summary", surface: surface)
    }
}
