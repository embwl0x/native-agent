import Foundation
import SenseCore
import NativeAgentCore
import ProviderRouting
import MindCore
// Blueprint: | `ModelRoundKernel.swift` | Shared request fitting, stream consumption and incremental prose release for resident and helper turns |

enum ModelRoundKernel {
    class Stream {
        var iterAccumulated = ""
        var pendingProtocolDelta = ""

        func visiblePartial(_ codec: ToolCallCodec) -> String { codec.visiblePrefix(in: iterAccumulated) }

        func release(_ event: LLMMessageStreamEvent, codec: ToolCallCodec) -> String {
            guard case .textDelta(let delta) = event else { return "" }
            iterAccumulated += delta
            pendingProtocolDelta += delta
            return codec.releasableProse(holding: &pendingProtocolDelta)
        }
    }

    static func fitAndMeasure(_ messages: [LLMMessage], codec: ToolCallCodec, records: [ToolDispatchRecord],
                              context: TurnContext, system: String?, tools: [LLMToolSchema]?, window: Int,
                              root: URL, surface: String, session: String?, owner: String,
                              turn: Turn, call: LLMCall) async throws -> (conversation: [LLMMessage], wire: [LLMMessage]) {
        @Sendable func request(_ wire: [LLMMessage]) throws -> SessionContextRequest {
            try SessionContextRequest(messages: wire, system: system, tools: tools ?? [], historyCharacters: 0)
        }
        let fitted = try await TurnToolResultPointers.fit(messages, window: window, dataRoot: root,
            surface: surface, sessionID: session, turn: turn) { candidate in
            let wire = try codec.providerMessages(candidate, records: records, schemas: context.toolSchemas, turn: turn)
            return try await SessionContextMeasurement.measure(request(wire), sessionId: owner, model: context.modelId,
                providerID: context.providerId, dataRoot: root, windowTokens: window, call: call)
        }
        let wire = try codec.providerMessages(fitted, records: records, schemas: context.toolSchemas, turn: turn)
        try await SessionContextMeasurement.requireFits(request(wire), sessionId: owner, model: context.modelId,
            providerID: context.providerId, dataRoot: root, windowTokens: window, call: call)
        return (fitted, wire)
    }

    @discardableResult
    static func streamRound(llm: any LLMClient, messages: [LLMMessage], system: String?, model: String,
                            tools: [LLMToolSchema]?, call: LLMCall, codec: ToolCallCodec, round: Stream,
                            stop: URL?, hearing: (arrivals: AsyncStream<ChatTurnSteering.Offer>,
                                                  onHearCut: (ChatTurnSteering.Offer) async throws -> Bool)? = nil,
                            isolation: isolated (any Actor)? = #isolation,
                            receive: (LLMMessageStreamEvent, String) async throws -> Void) async throws -> Bool {
        let stream = llm.streamMessages(messages: messages, system: system, model: model, tools: tools, call: call)
        func checkStop() throws {
            try Task.checkCancellation()
            if let stop, ChatCancelFlag.isRaised(stop) { throw CancellationError() }
        }
        if let hearing {
            let merged = TurnRoundEvents(provider: stream, arrivals: hearing.arrivals)
            defer { merged.cancel() }
            for try await event in merged.stream {
                try checkStop()
                switch event {
                case .arrival(let offer):
                    if try await hearing.onHearCut(offer) {
                        try checkStop()
                        return true
                    }
                case .provider(let value): try await receive(value, round.release(value, codec: codec))
                }
            }
        } else {
            for try await event in stream {
                try checkStop()
                try await receive(event, round.release(event, codec: codec))
            }
        }
        try checkStop()
        return false
    }
}
