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
            var touched: [Int] = []
            frameAligned = true
            for (position, raw) in calls.enumerated() {
                let index = slot(for: raw, position: position)
                if toolAccum[index] == nil {
                    toolAccum[index] = Accum()
                    toolOrder.append(index)
                }
                currentToolIndex = index
                touched.append(index)
                var call = toolAccum[index]!
                if let id = raw["id"] as? String, !id.isEmpty { call.id = id }
                if let function = raw["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty { call.name = name }
                    if let args = function["arguments"] as? String { call.arguments += args }
                }
                toolAccum[index] = call
            }
            previousFrameSlots = touched
        }
        return frame
    }

    /// Resolve which accumulator a `tool_calls[]` fragment belongs to.
    ///
    /// `index` is authoritative when the provider sends it. When it is ABSENT
    /// the old rule keyed on `toolOrder.count`, which minted a NEW slot for
    /// every fragment: a stream emitting `{id,name,arguments:"{\"q\""}` then
    /// `{arguments:":\"x\"}"}` built two accumulators, and the second — having
    /// no name — was dropped by `completedToolCalls`, so the call surfaced with
    /// truncated arguments (or `{}` when the split fell before any argument
    /// text). Pre-existing, but live since the OpenAI api-key adapter began
    /// routing through this decoder (gpt-5.5 BLOCKING, 2026-08-02).
    ///
    /// The first fix keyed an id-less fragment to `currentToolIndex` — the
    /// decoder-GLOBAL last-written slot. That still corrupts INTERLEAVED
    /// multi-call streams (gpt-5.5 BLOCKING, 2026-08-02): frame 1 opens calls
    /// `A` and `B`, leaving the cursor on `B`; frame 2 carries the id-less
    /// fragments `[A_args, B_args]`, so BOTH landed on `B` — `A` surfaced
    /// truncated and `B` got both halves of the JSON.
    ///
    /// The rule is now POSITIONAL and per-frame: an id-less fragment at array
    /// position `p` belongs to the slot that position `p` addressed in the
    /// previous `tool_calls` frame (`previousFrameSlots`, rebuilt every frame).
    /// That is exactly the wire semantics `index` would have spelled out. A
    /// position with no previous counterpart (e.g. an id-less continuation
    /// riding behind a freshly-opened call in a mixed frame) falls back to the
    /// currently-open slot. A fragment carrying a NEW `id` still starts a call,
    /// a repeated `id` still rejoins its own, and an id-less fragment whose
    /// `function.name` disagrees with the slot it resolved to opens a new call
    /// rather than corrupting that one.
    private mutating func slot(for raw: [String: Any], position: Int) -> Int {
        if let explicit = raw["index"] as? Int {
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
        return (toolAccum.keys.max() ?? -1) + 1
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
