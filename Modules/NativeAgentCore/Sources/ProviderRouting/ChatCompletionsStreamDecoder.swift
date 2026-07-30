import Foundation
import NativeAgentCore

// C1 / B2 / B8 (tightness sweep 2026-07-17): ONE decoder for the OpenAI-compatible
// Chat Completions SSE stream shape. Four adapters — Moonshot, OpenAI, OpenRouter,
// and xAI OAuth-direct — speak the identical wire protocol and used to hand-roll
// the identical delta loop four times, drifting apart bug-by-bug (the M-F1
// error-frame fix had two unpatched siblings; that IS B2). This owns the
// framing semantics once so a fix lands everywhere at once.

/// Shared decoder for the OpenAI-compatible Chat Completions SSE stream.
///
/// Each `data:` frame carries `choices[0].delta` (`content`,
/// `reasoning_content`, `tool_calls[]`), an optional root-level `usage` object
/// (on the dedicated final empty-choices frame from `stream_options.include_usage`
/// OR riding the last delta frame), an optional root-level `{"error":{…}}` frame,
/// and a terminal `[DONE]` sentinel.
///
/// This owns the bug-prone framing ONE place:
/// - `[DONE]` → `sawDone` (the adapter's guard against a wrong-cause
///   `streamTruncated`)
/// - root `error` frame → throw `LLMError.providerError` with the provider's
///   real message. This closes B2: OpenAI + OpenRouter previously treated an
///   error frame as a no-`choices` frame and `continue`d past it → `sawDone`
///   stayed false → the true cause (quota / overload / content-filter) surfaced
///   as a masking `streamTruncated`.
/// - root `usage` captured wherever it appears (B8 / M-F2)
/// - `tool_calls` delta accumulation by index (id / name / concatenated
///   arguments), finalized in first-seen order
///
/// The adapter keeps ONLY its own auth/header/body assembly and its own YIELD
/// policy (keepAlive cadence, ttft stamping, whether it surfaces tool calls at
/// all). Feed each SSE payload to `consume(payload:)`; it returns a
/// `DecodedFrame` describing what the adapter should surface, and mutates the
/// internal accumulators.
public struct ChatCompletionsStreamDecoder {
    /// Human-facing provider name used to prefix a mid-stream error message
    /// (e.g. "Moonshot: quota exceeded for kimi-k3").
    private let providerLabel: String

    private struct Accum { var id = ""; var name = ""; var arguments = "" }
    private var toolAccum: [Int: Accum] = [:]
    private var toolOrder: [Int] = []

    /// True once a `[DONE]` sentinel has been consumed. When the byte stream
    /// ends with this still false, the adapter throws `streamTruncated`.
    public private(set) var sawDone = false
    /// Non-empty `reasoning_content` accumulated across all frames (Moonshot's
    /// reasoning ledger consumes this after the stream completes).
    public private(set) var reasoning = ""
    /// Root-level usage captured from any frame that carried it, mapped to the
    /// telemetry shape. `nil` when the stream sent no usage frame — the recorder
    /// omits nil keys, so the row simply carries no token fields.
    public private(set) var usage: LLMUsage?

    public init(providerLabel: String) {
        self.providerLabel = providerLabel
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
        /// `reasoning`). Adapters that surface a thinking liveness signal yield
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
        if payload.isEmpty { return frame }
        if payload == "[DONE]" {
            sawDone = true
            frame.isDone = true
            return frame
        }
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return frame  // malformed JSON frame — skip
        }
        // Root error frame FIRST: it carries no `choices`, so a bare delta
        // guard swallows it (the B2 bug). Throw the provider's own message,
        // loud, before anything else touches the frame.
        if let errObj = root["error"] as? [String: Any] {
            let message = (errObj["message"] as? String)
                ?? (errObj["type"] as? String)
                ?? "unknown error"
            throw LLMError.providerError(message: "\(providerLabel): \(message)")
        }
        // Usage rides either the dedicated final empty-choices frame or the
        // last delta frame itself — capture it wherever it appears.
        if let usageObj = root["usage"] as? [String: Any] {
            usage = LLMUsage.fromOpenAIChatCompletions(usageObj)
        }
        guard let choices = root["choices"] as? [[String: Any]],
              let choice = choices.first else {
            return frame
        }
        frame.finishReason = choice["finish_reason"] as? String
        guard let delta = choice["delta"] as? [String: Any] else {
            return frame
        }
        if let thought = delta["reasoning_content"] as? String, !thought.isEmpty {
            reasoning += thought
            frame.reasoning = thought
        }
        if let content = delta["content"] as? String, !content.isEmpty {
            frame.content = content
        }
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            frame.toolCallDeltaCount = calls.count
            for raw in calls {
                let index = (raw["index"] as? Int) ?? toolOrder.count
                if toolAccum[index] == nil {
                    toolAccum[index] = Accum()
                    toolOrder.append(index)
                }
                var call = toolAccum[index]!
                if let id = raw["id"] as? String, !id.isEmpty { call.id = id }
                if let function = raw["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty { call.name = name }
                    if let args = function["arguments"] as? String { call.arguments += args }
                }
                toolAccum[index] = call
            }
        }
        return frame
    }

    /// Finalize the accumulated tool calls in first-seen order. Skips calls
    /// whose `name` never arrived; fills empty arguments with `{}`; synthesizes
    /// a stable id (`<idPrefix>_<index>_<name>`) when the provider omitted one.
    public func completedToolCalls(idPrefix: String) -> [ChatCompletionsToolCall] {
        var out: [ChatCompletionsToolCall] = []
        for index in toolOrder {
            guard let call = toolAccum[index] else { continue }
            let name = call.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let id = call.id.isEmpty ? "\(idPrefix)_\(index)_\(call.name)" : call.id
            let arguments = call.arguments.isEmpty ? "{}" : call.arguments
            out.append(ChatCompletionsToolCall(id: id, name: call.name, arguments: arguments))
        }
        return out
    }
}

/// A finalized Chat-Completions tool call. Decoder-internal shape; the adapter
/// maps it to `LLMStreamToolCall` (with `inputJSON` bytes) when it yields.
public struct ChatCompletionsToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - Shared adapter helpers (C10)

/// Truncate an error-response body for inclusion in a thrown message. Plain
/// (non-redacting) — the OAuth-direct adapters keep their own redacting
/// `boundedBodyString` because their bodies can echo bearer tokens.
func boundedBody(_ data: Data, maxBytes: Int = 2_048) -> String {
    String(decoding: data.prefix(maxBytes), as: UTF8.self)
}

/// Apply the three streaming Chat-Completions content headers shared by every
/// chat-completions adapter's SSE request. `Authorization` is provider-specific
/// (api key vs. OAuth access token) and stays with the caller.
func applyStreamingLLMHeaders(to request: inout URLRequest) {
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("NativeAgent (Darwin)", forHTTPHeaderField: "User-Agent")
}

/// Map a URLSession transport error to the error the adapter should surface
/// (R-M2). Cancellation — either a Swift `CancellationError` or URLSession's
/// `NSURLErrorDomain` + `NSURLErrorCancelled` — becomes `CancellationError` so
/// structured-concurrency callers (e.g. the workshop runner) can distinguish a
/// cancelled request from a real network failure. Every other transport
/// failure becomes `fallback`, evaluated lazily so the per-provider message /
/// error shape stays with the caller. This was hand-rolled ~30× across 8
/// adapters (Moonshot had already extracted it as `rethrowNetwork`); this owns
/// the cancellation-detection prologue once.
///
/// Usage at a throwing site: `throw mapTransportError(error, fallback: …)`.
/// At a continuation site: `continuation.finish(throwing: mapTransportError(error, fallback: …)); return`.
func mapTransportError(_ error: Error, fallback: @autoclosure () -> LLMError) -> Error {
    if error is CancellationError { return CancellationError() }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
        return CancellationError()
    }
    return fallback()
}

/// Per-provider Chat-Completions HTTP error mapping (R-M1). `provider` names the
/// `.notConfigured` error; `rateLimited` builds the 429 message; `serverError`
/// builds the 5xx message; `otherwise` handles any remaining non-2xx status.
struct ChatCompletionsStatusMapping: Sendable {
    var provider: String
    var rateLimited: @Sendable (Data) -> String
    var serverError: @Sendable (Data) -> String
    var otherwise: @Sendable (Int, Data) -> LLMError
}

/// Throw the mapped `LLMError` for a non-2xx Chat-Completions HTTP status; a
/// return means the status was 2xx and the caller should proceed (R-M1). The
/// status→error mapping was duplicated and DIVERGENT across adapters: 5xx mapped
/// to `.transient` (retryable) in Moonshot but `.underlying` (terminal) in
/// OpenAI/OpenRouter. This unifies 5xx → `.transient` for EVERY provider — a
/// deliberate policy pick (5xx is retryable). 401/429/other keep each provider's
/// own message shape via the mapping's closures.
func throwIfChatCompletionsError(
    status: Int,
    data: Data,
    mapping: ChatCompletionsStatusMapping,
    response: URLResponse? = nil
) throws {
    if (200..<300).contains(status) { return }
    // A3.1: 401 is a positive credential rejection, NOT a missing key. Carry
    // the provider's own error-body message so the user sees the real cause.
    if status == 401 {
        throw LLMError.authRejected(provider: mapping.provider, detail: providerErrorDetail(data))
    }
    // A3.4: honor Retry-After when the provider sent one.
    if status == 429 {
        throw LLMError.rateLimited(
            message: mapping.rateLimited(data),
            retryAfterSeconds: parseRetryAfterSeconds(from: response)
        )
    }
    if (500..<600).contains(status) { throw LLMError.transient(message: mapping.serverError(data)) }
    throw mapping.otherwise(status, data)
}

/// Parse an HTTP `Retry-After` header into whole seconds (A3.4). Accepts the
/// two RFC 7231 forms — delta-seconds ("30") and an HTTP-date — and clamps the
/// result to `[0, LLMError.retryAfterMaxSeconds]`. Returns nil when the header
/// is absent or unparseable.
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

/// Best-effort extraction of a provider error-body message for `.authRejected`
/// detail (A3.1). Handles the shapes every Chat-Completions-family provider
/// uses: `{"error":{"message":"..."}}`, `{"error":"..."}`, `{"message":"..."}`.
/// Falls back to a bounded raw-body slice so nothing is silently dropped.
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
