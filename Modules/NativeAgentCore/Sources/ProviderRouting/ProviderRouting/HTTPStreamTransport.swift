import Foundation
import NativeAgentCore

// Blueprint: | `HTTPStreamTransport.swift` | Shared provider HTTP lifetime, bounded diagnostics and the three SSE wire codecs |

struct ProviderStreamInput: Sendable {
    let messages: [LLMMessage]
    let system: String?
    let model: String
    let tools: [LLMToolSchema]?
    let call: LLMCall
}

typealias ProviderEvents = SSEEventStream<ProviderHTTPBytes>
typealias ReplyStream = AsyncThrowingStream<LLMMessageStreamEvent, Error>

protocol ProviderWireCodec: Sendable {
    var request: URLRequest { get }
    func consume(_ events: ProviderEvents, _ continuation: ReplyStream.Continuation, started: UInt64) async throws
}

struct ChatCompletionsWire: ProviderWireCodec {
    let request: URLRequest
    let label: String
    let model: String
    let profile: any HTTPProviderProfile
    let call: LLMCall
    var reasoning: ToolCallReplayLedger<String>? = nil

    func consume(_ events: ProviderEvents, _ continuation: ReplyStream.Continuation, started: UInt64) async throws {
        var decoder = ChatCompletionsStreamDecoder(providerLabel: label, retainReasoning: reasoning != nil)
        try await decoder.consume(events, continuation: continuation, request: request, providerID: profile.providerId,
            model: model, started: started, telemetry: profile.telemetry, call: call) { calls, text in
            if let reasoning, !calls.isEmpty, !text.isEmpty {
                await reasoning.record(text, callIDs: calls.map(\.id))
            }
        }
    }
}

struct ResponsesWire: ProviderWireCodec {
    let request: URLRequest
    let model: String
    let profile: any HTTPProviderProfile
    let call: LLMCall
    let label: String
    let errorPrefix: String
    var substitutedFrom: String? = nil

    func consume(_ events: ProviderEvents, _ continuation: ReplyStream.Continuation, started: UInt64) async throws {
        try await ChatGPTTransport.consumeResponsesStream(events: events, request: request, model: model,
            providerId: profile.providerId, telemetry: profile.telemetry, requestStartNs: started,
            substitutedFrom: substitutedFrom, providerLabel: label, errorPrefix: errorPrefix,
            networkError: { profile.connectionError($0, request: request) },
            continuation: continuation, call: call)
    }
}

struct AnthropicMessagesWire: ProviderWireCodec {
    enum Payload: Sendable {
        case native(conversation: Data, ledger: ToolCallReplayLedger<AnthropicThinkingRecord>?)
        case markers(substitutedFrom: String?, cacheMarkers: [LLMCacheMarker])
    }

    let request: URLRequest
    let profile: any HTTPProviderProfile
    let model: String
    let call: LLMCall
    let payload: Payload
}

protocol HTTPProviderProfile: ProviderTransportCapabilities {
    var providerId: String { get }
    var session: URLSession { get }
    var telemetry: LLMCallTraceRecorder { get }
    func requestOutputTokens(model: String, call: LLMCall) throws -> Int
    func connectionError(_ error: Error, request: URLRequest) -> LLMError
}

extension HTTPProviderProfile {
    func connectionError(_ error: Error, request: URLRequest) -> LLMError {
        transientNetworkError(error, provider: providerId, host: request.url?.host, operation: "streamMessages")
    }
}

struct HTTPStreamTransport<Wire: ProviderWireCodec>: LLMTransport {
    let profile: any HTTPProviderProfile
    let prepare: @Sendable (ProviderStreamInput) async throws -> Wire
    var reject: @Sendable (Int, String) throws -> Void = { _, _ in }
    var diagnostic: @Sendable (Int, Data, String) throws -> Void = { _, _, _ in }
    var filter: (@Sendable (ReplyStream, ProviderStreamInput) -> ReplyStream)? = nil

    var providerId: String { profile.providerId }
    var telemetry: LLMCallTraceRecorder { profile.telemetry }
    func requestOutputTokens(model: String, call: LLMCall) throws -> Int {
        try profile.requestOutputTokens(model: model, call: call)
    }

    func streamMessages(messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?, call: LLMCall) -> ReplyStream {
        let started = DispatchTime.now().uptimeNanoseconds
        let input = ProviderStreamInput(messages: messages, system: system, model: model, tools: tools, call: call)
        let stream = ReplyStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let wire = try await prepare(input)
                    let (bytes, response): (ProviderHTTPBytes, URLResponse)
                    do {
                        (bytes, response) = try await ProviderWire.open(profile.session, wire.request, call: call)
                    } catch {
                        throw mapTransportError(error, fallback: profile.connectionError(error, request: wire.request))
                    }
                    defer { bytes.cancel() }
                    guard let http = response as? HTTPURLResponse else {
                        throw ProviderFailure.Diagnostic(cause: .malformedResponse, detail: "Provider response was not HTTP.")
                    }
                    if !(200..<300).contains(http.statusCode) {
                        try reject(http.statusCode, model)
                        let body = try await ProviderErrorBodyDrain.read(bytes, maxBytes: 4096)
                        try diagnostic(http.statusCode, body, model)
                        try throwIfChatCompletionsError(status: http.statusCode, data: body, response: http)
                    }
                    try await wire.consume(ProviderEvents(bytes, lifetime: call.lifetime), continuation, started: started)
                    bytes.complete()
                    continuation.finish()
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: mapTransportError(error, fallback: .underlying(message: "stream: \(error)")))
                }
            }
            call.replyWork?.own(task)
            continuation.onTermination = { _ in task.cancel() }
        }
        return filter?(stream, input) ?? stream
    }
}
