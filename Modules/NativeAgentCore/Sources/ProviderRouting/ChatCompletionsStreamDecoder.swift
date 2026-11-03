import Foundation
import NativeAgentCore

// Blueprint: | `ChatCompletionsStreamDecoder.swift` | `ChatCompletionsStreamDecoder`: shared terminal decoding/receipts and SSE content/reasoning/tool fragments, usage and root errors; nonempty malformed JSON always fails; terminal/tool alignment validation preserves provider failures |

/// Shared decoder for OpenAI-compatible Chat Completions streams.
///
/// Consumes `choices[0].delta` content, reasoning, and indexed tool fragments;
/// captures root-level usage wherever it appears; and surfaces root error
/// frames before checking choices so the provider's actual error survives.
///
/// Tool calls accumulate in first-seen order. Finalization checks the DONE
/// sentinel, retained finish reason, complete tool batch, and nonempty output.
/// Adapters own authentication and request bodies; consumption owns stream events and receipts.
public struct ChatCompletionsStreamDecoder {
    /// Human-facing provider name used to prefix a mid-stream error message
    /// (e.g. "Moonshot: quota exceeded for kimi-k3").
    private let providerLabel: String
    private let retainReasoning: Bool

    private struct Accum { var id = ""; var name = ""; var arguments = "" }
    private var toolAccum: [Int: Accum] = [:]
    private var toolOrder: [Int] = []

    /// True once a `[DONE]` sentinel has been consumed. When the byte stream
    /// ends with this still false, the adapter throws `streamTruncated`.
    public private(set) var sawDone = false
    /// Accumulated only when the route needs reasoning replay (Moonshot).
    public private(set) var reasoning = ""
    /// Root-level usage captured from any frame that carried it, mapped to the
    /// telemetry shape. `nil` when the stream sent no usage frame — the recorder
    /// omits nil keys, so the row simply carries no token fields.
    public private(set) var usage: LLMUsage?
    public private(set) var reachedLengthLimit = false
    private var terminalBoundaryReason: LLMToolBoundaryReason?
    private var streamError: Error?
    private var refusalText = ""
    var errorDetail: String? { streamError.map(ProviderFailure.diagnosticDescription) }
    private var runaway = RunawayOutputDetector()
    public var toolBoundaryReason: LLMToolBoundaryReason? {
        reachedLengthLimit ? .outputLimit : terminalBoundaryReason ?? runaway.toolBoundaryReason
    }

    public init(providerLabel: String, retainReasoning: Bool = false, diagnosticDataRoot: URL? = nil) {
        self.providerLabel = providerLabel
        self.retainReasoning = retainReasoning
        self.runaway = RunawayOutputDetector(diagnosticDataRoot: diagnosticDataRoot)
    }


    /// Read failures share EOF's finalizer; cancellation and provider verdicts
    /// remain errors rather than permission to execute retained calls.
    mutating func consume<Events: AsyncSequence>(
        _ events: Events, continuation: AsyncThrowingStream<LLMMessageStreamEvent, Error>.Continuation,
        request: URLRequest, providerID: String, model: String, idPrefix: String,
        started: UInt64, telemetry: LLMCallTraceRecorder,
        onCalls: ([LLMStreamToolCall], String) async -> Void = { _, _ in }
    ) async throws where Events.Element == SSEEvent {
        var ttftMs: Int?
        var sawContent = false
        do {
            for try await event in events {
                try Task.checkCancellation()
                let frame = try consume(payload: event.data)
                if frame.isDone { break }
                if ttftMs == nil, frame.content != nil || frame.toolCallDeltaCount > 0 {
                    ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)
                }
                if frame.reasoning != nil { continuation.yield(.keepAlive) }
                if providerID == "xai_oauth_direct" {
                    for _ in 0..<frame.toolCallDeltaCount { continuation.yield(.keepAlive) }
                }
                if let content = frame.content {
                    sawContent = true
                    continuation.yield(.textDelta(content))
                }
                if providerID != "xai_oauth_direct" {
                    for _ in 0..<frame.toolCallDeltaCount { continuation.yield(.keepAlive) }
                } else if frame.finishReason == "tool_calls" || frame.finishReason == "stop" {
                    continuation.yield(.keepAlive)
                }
                if toolBoundaryReason != nil { break }
            }
        } catch {
            try Task.checkCancellation()
            guard !(error is any ProviderFailureWrapping),
                  ProviderFailure.classify(error) == .network else { throw error }
            streamError = error
            terminalBoundaryReason = .interrupted
        }
        try Task.checkCancellation()
        let terminal = Result {
            try finalizedToolCalls(idPrefix: idPrefix, providerID: providerID, sawContent: sawContent)
        }
        if reachedLengthLimit {
            RunawayOutputDetector.writeDiagnostic(runaway.text, reason: "output_limit", dataRoot: telemetry.diagnosticDataRoot)
        }
        await telemetry.record(
            requestBody: request.httpBody, provider: providerID, model: model, streaming: true,
            usage: usage, ttftMs: ttftMs,
            durationMs: Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000),
            status: toolBoundaryReason != nil ? "incomplete" : (try terminal.chatCompletionsTerminalStatus()),
            stopReason: toolBoundaryReason?.rawValue, errorDetail: errorDetail
        )
        let completed = try terminal.get()
        for call in completed { continuation.yield(.toolCall(call)) }
        await onCalls(completed, reasoning)
        if let reason = toolBoundaryReason { continuation.yield(.toolBoundary(reason)) }
    }

    /// One decoded frame's surface-relevant content. Every field is
    /// empty/nil/zero for a frame the adapter should ignore (role-only delta,
    /// usage-only empty-choices frame, empty keep-alive).
    public struct DecodedFrame: Sendable, Equatable {
        /// This frame was the `[DONE]` sentinel — the adapter breaks its loop.
        public var isDone = false
        /// Non-empty assistant content delta to yield as `.textDelta`.
        public var content: String?
        /// Non-empty `reasoning_content` delta on this frame (also folded into
        /// `reasoning` when replay is enabled). Adapters that surface a thinking liveness signal yield
        /// `.keepAlive` when this is non-nil.
        public var reasoning: String?
        /// Count of raw `tool_calls` entries in this frame's delta. Moonshot
        /// yields one `.keepAlive` per entry so its idle clock survives long
        /// argument accumulation.
        public var toolCallDeltaCount = 0
        /// `finish_reason` on the first choice, if present (xAI liveness).
        public var finishReason: String?
    }

    /// Consume one SSE `data:` payload. Throws `LLMError.providerError` on a
    /// root-level error frame. Mutates the tool-call / reasoning / usage / done
    /// accumulators.
    public mutating func consume(payload: String) throws -> DecodedFrame {
        var frame = DecodedFrame()
        if toolBoundaryReason != nil {
            frame.isDone = true
            return frame
        }
        if payload.isEmpty { return frame }
        if payload == "[DONE]" {
            sawDone = true
            if !refusalText.isEmpty { terminalBoundaryReason = .refusal }
            frame.isDone = true
            return frame
        }
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFailure.Diagnostic(cause: .malformedResponse,
                detail: "\(providerLabel): malformed Chat Completions stream frame")
        }
        // Root error frames carry no choices; surface them before reading deltas.
        try throwIfChatCompletionsProviderError(root)
        // Usage rides either the dedicated final empty-choices frame or the
        // last delta frame itself — capture it wherever it appears.
        if let usageObj = root["usage"] as? [String: Any] {
            usage = LLMUsage.fromOpenAIChatCompletions(usageObj)
        }
        guard let choices = root["choices"] as? [[String: Any]],
              let choice = choices.first else {
            return frame
        }
        try throwIfChatCompletionsProviderError(choice)
        frame.finishReason = choice["finish_reason"] as? String
        if frame.finishReason == "length" { reachedLengthLimit = true }
        if frame.finishReason == "content_filter" { terminalBoundaryReason = .refusal }
        guard let delta = choice["delta"] as? [String: Any] else {
            return frame
        }
        if let thought = delta["reasoning_content"] as? String, !thought.isEmpty {
            if retainReasoning { reasoning += thought }
            frame.reasoning = thought
        }
        if let content = delta["content"] as? String, !content.isEmpty {
            _ = runaway.feed(content)
            let kept = runaway.takeCommittedText()
            frame.content = kept.isEmpty ? nil : kept
        }
        if let refusal = delta["refusal"] as? String, !refusal.isEmpty {
            refusalText += refusal
            frame.content = (frame.content ?? "") + refusal
        }
        if frame.finishReason != nil, !refusalText.isEmpty { terminalBoundaryReason = .refusal }
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            frame.toolCallDeltaCount = calls.count
            for raw in calls {
                let index = try slot(for: raw)
                if toolAccum[index] == nil {
                    toolAccum[index] = Accum()
                    toolOrder.append(index)
                }
                // Mutate in place so each fragment does not copy the growing arguments.
                if let id = raw["id"] as? String, !id.isEmpty {
                    guard toolAccum[index]?.id.isEmpty != false || toolAccum[index]?.id == id else {
                        throw LLMError.providerError(message: "\(providerLabel): tool index changed call identity")
                    }
                    toolAccum[index, default: Accum()].id = id
                }
                if let function = raw["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty {
                        guard toolAccum[index]?.name.isEmpty != false || toolAccum[index]?.name == name else {
                            throw LLMError.providerError(message: "\(providerLabel): tool call changed function name")
                        }
                        toolAccum[index, default: Accum()].name = name
                    }
                    if let args = function["arguments"] as? String { toolAccum[index, default: Accum()].arguments += args }
                }
            }
        }
        return frame
    }

    /// A wire index or call ID establishes association; array position never does.
    private mutating func slot(for raw: [String: Any]) throws -> Int {
        if let value = raw["index"] {
            guard let explicit = value as? Int, explicit >= 0 else {
                throw LLMError.providerError(message: "\(providerLabel): invalid tool index")
            }
            return explicit
        }
        let id = (raw["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let id, let known = toolOrder.first(where: { toolAccum[$0]?.id == id }) {
            return known
        }
        guard id != nil else {
            throw LLMError.providerError(message: "\(providerLabel): tool fragment has neither an index nor a call ID; repair the provider stream")
        }
        let (next, overflow) = (toolAccum.keys.max() ?? -1).addingReportingOverflow(1)
        guard !overflow else {
            throw LLMError.providerError(message: "\(providerLabel): tool index space exhausted")
        }
        return next
    }

    /// Return committed calls with their boundary, or retain the read failure
    /// when no calls survived. Wire provider IDs preserve existing diagnostics.
    mutating func finalizedToolCalls(
        idPrefix: String,
        providerID: String,
        sawContent: Bool
    ) throws -> [LLMStreamToolCall] {
        if !refusalText.isEmpty { terminalBoundaryReason = .refusal }
        if terminalBoundaryReason == .refusal {
            guard sawContent else {
                throw ProviderFailure.Diagnostic(cause: .refused,
                    detail: refusalText.isEmpty ? "\(providerID): content_filter" : refusalText)
            }
            return []
        }
        if !sawDone && toolBoundaryReason == nil {
            terminalBoundaryReason = .interrupted
            streamError = LLMError.streamTruncated(message: "\(providerID) stream ended without [DONE]")
        }
        var completed: [LLMStreamToolCall] = []
        for index in toolOrder {
            guard let call = toolAccum[index] else { continue }
            let name = call.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = call.id
            let arguments = call.arguments
            guard !id.isEmpty, !name.isEmpty,
                  (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) is [String: Any] else {
                if toolBoundaryReason == nil {
                    throw LLMError.providerError(message: "\(providerLabel): incomplete tool call (call ID, name and object arguments are required); repair the provider stream")
                }
                continue
            }
            completed.append(LLMStreamToolCall(id: id, name: call.name, inputJSON: Data(arguments.utf8)))
        }
        if completed.isEmpty, let streamError { throw streamError }
        if !sawContent && completed.isEmpty && toolBoundaryReason == nil {
            throw LLMError.streamTruncated(
                message: "\(providerID) stream produced no content ([DONE], empty)"
            )
        }
        return completed
    }
}

// MARK: - Shared adapter helpers

extension Result where Failure == Error {
    /// Length terminals retain their usage receipt without claiming success.
    /// Other parse failures keep their existing no-success-receipt behavior.
    func chatCompletionsTerminalStatus() throws -> String {
        switch self {
        case .success: return "ok"
        case .failure(let error):
            if case .outputLengthLimit = error as? LLMError { return "incomplete" }
            throw error
        }
    }
}

/// Both completion lanes reject provider errors before reading message/delta,
/// including errors carried by a choice rather than the root envelope.
private func throwIfChatCompletionsProviderError(_ object: [String: Any]) throws {
    if let error = object["error"] as? [String: Any] {
        throw ProviderFailure.wireError(error)
    }
    if object["error"] is String {
        throw ProviderFailure.wireError(object)
    }
    if object["finish_reason"] as? String == "error" {
        throw ProviderFailure.Diagnostic(cause: .overloaded,
            detail: "Provider ended this completion with finish_reason=error but supplied no error details. Check provider status before trying again.")
    }
}





/// Apply the three streaming Chat-Completions content headers shared by every
/// chat-completions adapter's SSE request. `Authorization` is provider-specific
/// (api key vs. OAuth access token) and stays with the caller.
func applyStreamingLLMHeaders(to request: inout URLRequest) {
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("NativeAgent (Darwin)", forHTTPHeaderField: "User-Agent")
}

/// Cancellation, wrapped failures and transport classification have one boundary.
/// Only otherwise unclassified errors use the caller's bounded contextual detail.
func mapTransportError(_ error: Error, fallback: @autoclosure () -> LLMError) -> Error {
    if error is CancellationError { return CancellationError() }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
        return CancellationError()
    }
    if error is any ProviderFailureWrapping { return error }
    if let failure = ProviderFailure.classify(error) {
        return ProviderFailure.Diagnostic(
            cause: failure,
            detail: ProviderFailure.diagnosticDescription(error),
            deadlineExpired: nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
        )
    }
    return ProviderFailure.normalize(fallback())
}

/// HTTP status and Retry-After remain structured data across adapters and surfaces.
func throwIfChatCompletionsError(
    status: Int,
    data: Data,
    response: URLResponse? = nil
) throws {
    guard !(200..<300).contains(status) else { return }
    let detail = ProviderFailure.wireDetail(data)
    throw ProviderFailure.Diagnostic(cause: .http(
        status: status,
        detail: detail,
        retryAfter: parseRetryAfterSeconds(from: response)
    ), detail: "HTTP \(status): \(detail)")
}

/// Retry-After accepts RFC 7231 seconds/date forms, clamps to 0...retryAfterMaxSeconds, or returns nil.
func parseRetryAfterSeconds(from response: URLResponse?, now: Date = Date()) -> Int? {
    guard let http = response as? HTTPURLResponse else { return nil }
    guard
        let raw = http.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty
    else { return nil }
    if let secs = Int(raw) { return max(0, min(secs, LLMError.retryAfterMaxSeconds)) }
    // HTTP-date form (e.g. "Wed, 21 Oct 2026 07:28:00 GMT").
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "GMT")
    fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let date = fmt.date(from: raw) {
        let delta = Int(date.timeIntervalSince(now).rounded())
        return max(0, min(delta, LLMError.retryAfterMaxSeconds))
    }
    return nil
}

/// Auth rejection detail uses error.message, error or message, otherwise a bounded raw-body slice.
func providerErrorDetail(_ data: Data, maxBytes: Int = 400) -> String? {
    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let err = obj["error"] as? [String: Any], let m = err["message"] as? String, !m.isEmpty {
            return String(m.prefix(maxBytes))
        }
        if let m = obj["error"] as? String, !m.isEmpty { return String(m.prefix(maxBytes)) }
        if let m = obj["message"] as? String, !m.isEmpty { return String(m.prefix(maxBytes)) }
    }
    let raw = String(decoding: data.prefix(maxBytes), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? nil : raw
}
