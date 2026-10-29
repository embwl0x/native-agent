import Foundation
import NativeAgentCore

// Blueprint: | `ChatCompletionsStreamDecoder.swift` | `ChatCompletionsStreamDecoder`: shared buffered terminal decoding/receipts and SSE content/reasoning/tool fragments, usage and root errors; terminal/tool alignment validation preserves provider failures |

/// Shared decoder for buffered and streamed OpenAI-compatible Chat Completions.
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
    /// Slot most recently written to. Fallback anchor for an `index`-less
    /// fragment whose frame position has no counterpart in `previousFrameSlots`
    /// — see `slot(for:position:)`.
    private var currentToolIndex: Int?
    /// Slots touched by the PREVIOUS `tool_calls` frame, in that frame's array
    /// order. An id-less fragment at array position `p` of the current frame
    /// belongs to `previousFrameSlots[p]`: providers that omit `index` keep the
    /// per-frame array order stable across continuation frames. Reset (rebuilt)
    /// on every `tool_calls` frame, so it is a per-frame cursor and never a
    /// decoder-global one.
    private var previousFrameSlots: [Int] = []
    /// True while the CURRENT frame's array still lines up with
    /// `previousFrameSlots`. Cleared the moment an entry lands off-position (a
    /// new call opening mid-array, a frame that grew), after which id-less
    /// entries in that frame chain from the open call instead. Reset to true at
    /// the top of every `tool_calls` frame.
    private var frameAligned = true

    /// True once a `[DONE]` sentinel has been consumed. When the byte stream
    /// ends with this still false, the adapter throws `streamTruncated`.
    public private(set) var sawDone = false
    /// Accumulated only when the route needs reasoning replay (Moonshot).
    public private(set) var reasoning = ""
    /// Root-level usage captured from any frame that carried it, mapped to the
    /// telemetry shape. `nil` when the stream sent no usage frame — the recorder
    /// omits nil keys, so the row simply carries no token fields.
    public private(set) var usage: LLMUsage?
    /// Any text, reasoning or tool fragment activates the malformed-frame failure rule in consume.
    private var sawSemanticOutput = false
    public private(set) var reachedLengthLimit = false
    private var terminalBoundaryReason: LLMToolBoundaryReason?
    private var streamError: Error?
    private var refusalText = ""
    var errorDetail: String? { streamError.map(ProviderFailure.diagnosticDescription) }
    private var runaway = RunawayOutputDetector()
    public var toolBoundaryReason: LLMToolBoundaryReason? {
        reachedLengthLimit ? .outputLimit : terminalBoundaryReason ?? runaway.toolBoundaryReason
    }

    public init(providerLabel: String, retainReasoning: Bool = false) {
        self.providerLabel = providerLabel
        self.retainReasoning = retainReasoning
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
    /// usage-only empty-choices frame, malformed JSON, keep-alive comment).
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
            // Unreadable frames are skipped before output starts and fail the stream transiently afterward.
            guard sawSemanticOutput else { return frame }
            throw LLMError.transient(
                message: "\(providerLabel): malformed stream frame after content")
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
            sawSemanticOutput = true
        }
        if let content = delta["content"] as? String, !content.isEmpty {
            _ = runaway.feed(content)
            let kept = runaway.takeCommittedText()
            frame.content = kept.isEmpty ? nil : kept
            sawSemanticOutput = true
        }
        if let refusal = delta["refusal"] as? String, !refusal.isEmpty {
            refusalText += refusal
            frame.content = (frame.content ?? "") + refusal
            sawSemanticOutput = true
        }
        if frame.finishReason != nil, !refusalText.isEmpty { terminalBoundaryReason = .refusal }
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            frame.toolCallDeltaCount = calls.count
            sawSemanticOutput = true
            var touched: [Int] = []
            frameAligned = true
            for (position, raw) in calls.enumerated() {
                let index = try slot(for: raw, position: position)
                if toolAccum[index] == nil {
                    toolAccum[index] = Accum()
                    toolOrder.append(index)
                }
                currentToolIndex = index
                touched.append(index)
                // Mutate in place so each fragment does not copy the growing arguments.
                if let id = raw["id"] as? String, !id.isEmpty { toolAccum[index, default: Accum()].id = id }
                if let function = raw["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty { toolAccum[index, default: Accum()].name = name }
                    if let args = function["arguments"] as? String { toolAccum[index, default: Accum()].arguments += args }
                }
            }
            previousFrameSlots = touched
        }
        return frame
    }

    /// Resolve a tool fragment by explicit index, then by an already-seen ID.
    /// Index-less fragments at position p continue the slot at position p in
    /// the previous tool frame, while those arrays still align. A global
    /// last-written slot cannot pair interleaved multi-call fragments.
    ///
    /// Once frame alignment breaks, an unnamed fragment continues the current
    /// slot. A new ID or a conflicting function name opens a new slot rather
    /// than corrupting an existing call. Explicit indexes remain authoritative.
    private mutating func slot(for raw: [String: Any], position: Int) throws -> Int {
        if let value = raw["index"] {
            guard let explicit = value as? Int, explicit >= 0 else {
                throw LLMError.providerError(message: "\(providerLabel): invalid tool index")
            }
            noteAlignment(of: explicit, at: position)
            return explicit
        }
        let id = (raw["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let id, let known = toolOrder.first(where: { toolAccum[$0]?.id == id }) {
            noteAlignment(of: known, at: position)
            return known
        }
        if id == nil, frameAligned, position < previousFrameSlots.count {
            let candidate = previousFrameSlots[position]
            if continues(candidate, raw) { return candidate }
        } else if id == nil, let open = currentToolIndex, continues(open, raw) {
            // This frame's array no longer lines up with the previous one (an
            // entry addressed by id/index landed off-position, or the frame
            // grew): chain from the call this frame most recently opened or
            // touched rather than trusting a stale position.
            return open
        }
        // New id, a name that disagrees with the resolved slot, or the very
        // first fragment of the stream: allocate a slot that cannot collide
        // with an explicit index seen so far.
        frameAligned = false
        let (next, overflow) = (toolAccum.keys.max() ?? -1).addingReportingOverflow(1)
        guard !overflow else {
            throw LLMError.providerError(message: "\(providerLabel): tool index space exhausted")
        }
        return next
    }

    /// An id- or index-addressed entry that does NOT land where the previous
    /// frame's same position landed means this frame's array layout shifted, so
    /// every LATER id-less entry in it must chain from the open call instead of
    /// reading a stale position.
    private mutating func noteAlignment(of slot: Int, at position: Int) {
        guard position < previousFrameSlots.count, previousFrameSlots[position] == slot else {
            frameAligned = false
            return
        }
    }

    /// True when `raw` can be a continuation of the call already in `slot`. Only
    /// a fragment that names a DIFFERENT function is rejected — continuation
    /// fragments carry no `name` at all, and providers that repeat the name on
    /// every fragment repeat the same one.
    private func continues(_ slot: Int, _ raw: [String: Any]) -> Bool {
        guard let existing = toolAccum[slot]?.name, !existing.isEmpty else { return true }
        guard let name = (raw["function"] as? [String: Any])?["name"] as? String,
              !name.isEmpty else { return true }
        return name == existing
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
        if reachedLengthLimit {
            RunawayOutputDetector.writeDiagnostic(runaway.text, reason: "output_limit")
        }
        if !sawDone && toolBoundaryReason == nil {
            terminalBoundaryReason = .interrupted
            streamError = LLMError.streamTruncated(message: "\(providerID) stream ended without [DONE]")
        }
        var completed: [LLMStreamToolCall] = []
        for index in toolOrder {
            guard let call = toolAccum[index] else { continue }
            let name = call.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = call.id.isEmpty ? "\(idPrefix)_\(index)_\(call.name)" : call.id
            let arguments = call.arguments.isEmpty && toolBoundaryReason == nil ? "{}" : call.arguments
            guard !name.isEmpty,
                  (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) is [String: Any] else {
                if toolBoundaryReason == nil { terminalBoundaryReason = .incompleteCall }
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
