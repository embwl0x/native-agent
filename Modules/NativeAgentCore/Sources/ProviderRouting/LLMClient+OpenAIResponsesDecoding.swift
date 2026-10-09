import Foundation
import NativeAgentCore
import PersistenceCore

extension OpenAIOAuthDirectAdapter {
    /// Shared Responses SSE execution; authentication and HTTP retries stay with each lane.
    static func consumeResponsesStream(
        bytes: URLSession.AsyncBytes,
        request req: URLRequest,
        model: String,
        providerId: String,
        telemetry: LLMCallTraceRecorder,
        requestStartNs: UInt64,
        substitutedFrom: String? = nil,
        providerLabel: String,
        errorPrefix: String,
        transport: OpenAIExecutionControls.Transport = .chatGPTOAuth,
        networkError: (Error) -> LLMError,
        continuation: AsyncThrowingStream<LLMMessageStreamEvent, Error>.Continuation
    ) async throws {
        var emittedProviderOutput = false
        struct PendingCall {
            var callId: String
            var name: String
            var args: String
        }
        var pendingByItemId: [String: PendingCall] = [:]
        var pendingOrder: [String] = []
        var replyTextSettled = false
        var sawFunctionCall = false
        var yieldedToolCall = false
        func resumeReply() {
            if replyTextSettled {
                replyTextSettled = false
                continuation.yield(.replyTextSettled(false))
            }
        }
        // U1 step 1 — streaming telemetry: TTFT stamped at
        // the FIRST meaningful output frame — text delta,
        // function_call output_item.added, or first argument
        // delta, whichever arrives first. Stamping only at
        // output_item.done (after the whole argument stream)
        // read materially too high for tool-call-first
        // responses (gpt-5.5 review blocker, 2026-06-10).
        // Usage rides on the terminal response.completed.
        var capturedUsage: LLMUsage?
        var ttftMs: Int?
        // User, 2026-09-06: set by a terminal
        // `response.incomplete` frame — see the buffered
        // sibling. Same omission, same misclassification.
        var incompleteReason: String?
        var refusalTextByPart: [String: String] = [:]
        // 2026-09-25: the loop guard every other streaming
        // adapter has. Without it a looping reply ran to the
        // model's own cap (no max_output_tokens is sent).
        var runaway = RunawayOutputDetector()
        var runawayTripped = false

        func stampTTFT() {
            emittedProviderOutput = true
            if ttftMs == nil {
                ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
            }
        }

        func yieldToolCall(id: String, name: String, args: String) throws {
            if transport == .publicAPI, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw LLMError.providerError(message: "streamed tool batch contains an empty tool name")
            }
            sawFunctionCall = true
            yieldedToolCall = true
            resumeReply()
            let body = args.isEmpty ? "{}" : args
            stampTTFT()
            continuation.yield(.toolCall(LLMStreamToolCall(
                id: id,
                name: name,
                inputJSON: Data(body.utf8)
            )))
        }

        var lastRawDelta: ContinuousClock.Instant?
        func processPayload(_ payloadStr: String) throws -> Bool {
            if payloadStr == "[DONE]" { return true }
            guard let pdata = payloadStr.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any] else {
                // User, 2026-09-06: an unparseable frame used to
                // vanish, so a corrupted transport mid-answer
                // silently dropped a chunk of the reply (or of
                // a function call's arguments) and the turn
                // still finished "successfully". Once output
                // has started, a frame we cannot read is a
                // stream failure the ladder should re-ask on.
                guard emittedProviderOutput else { return false }
                throw LLMError.transient(
                    message: "\(providerLabel): malformed stream frame after content")
            }
            let etype = event["type"] as? String ?? ""
            var textDelta: String?
            if etype == "response.output_text.delta" {
                textDelta = event["delta"] as? String
            } else if etype == "response.refusal.delta" || etype == "response.refusal.done",
                      let itemId = event["item_id"] as? String,
                      let contentIndex = event["content_index"] as? Int {
                let part = "\(itemId):\(contentIndex)"
                if etype == "response.refusal.delta", let delta = event["delta"] as? String {
                    refusalTextByPart[part, default: ""].append(delta)
                    textDelta = delta
                } else if let refusal = event["refusal"] as? String {
                    let streamed = refusalTextByPart[part] ?? ""
                    if refusal.hasPrefix(streamed) {
                        textDelta = String(refusal.dropFirst(streamed.count))
                    }
                    refusalTextByPart[part] = refusal
                }
            }
            if let delta = textDelta {
                if !delta.isEmpty {
                    lastRawDelta = ContinuousClock.now
                    resumeReply()
                    stampTTFT()
                    continuation.yield(.textDelta(delta))
                    if runaway.feed(delta) {
                        runawayTripped = true
                        return true
                    }
                }
            } else if etype == "response.output_item.added" {
                if let item = event["item"] as? [String: Any],
                   (item["type"] as? String) == "function_call",
                   let id = item["id"] as? String {
                    sawFunctionCall = true
                    resumeReply()
                    // First model-output frame for a
                    // tool-call-first response — stamp TTFT
                    // here, not at output_item.done.
                    stampTTFT()
                    let callId = (item["call_id"] as? String) ?? id
                    let name = (item["name"] as? String) ?? ""
                    let args = (item["arguments"] as? String) ?? ""
                    pendingByItemId[id] = PendingCall(callId: callId, name: name, args: args)
                    pendingOrder.append(id)
                }
            } else if etype == "response.function_call_arguments.delta" {
                sawFunctionCall = true
                resumeReply()
                if let id = event["item_id"] as? String,
                   let delta = event["delta"] as? String {
                    // Argument deltas are model output even
                    // when the item wasn't registered by a
                    // recognized `added` frame — stamp
                    // unconditionally.
                    stampTTFT()
                    if pendingByItemId[id] != nil {
                        pendingByItemId[id]!.args.append(delta)
                    }
                }
                // Liveness: tool-arg deltas are model output but are
                // accumulated (not yielded as content), so emit
                // `.keepAlive` to keep ProviderStreamGuard's idle
                // clock alive through a long tool-argument stream —
                // parity with the Anthropic input_json_delta path
                // (pre-existing gap, gpt-5.5 review 2026-06-15).
                continuation.yield(.keepAlive)
            } else if etype == "response.output_item.done" {
                if let item = event["item"] as? [String: Any],
                   (item["type"] as? String) == "message",
                   lastRawDelta != nil, !sawFunctionCall, !replyTextSettled {
                    replyTextSettled = true
                    continuation.yield(.replyTextSettled(true))
                }
                if let item = event["item"] as? [String: Any],
                   (item["type"] as? String) == "function_call",
                   let id = item["id"] as? String {
                    var pending = pendingByItemId[id] ?? PendingCall(callId: id, name: "", args: "")
                    if let callId = item["call_id"] as? String { pending.callId = callId }
                    if pending.name.isEmpty, let name = item["name"] as? String { pending.name = name }
                    if pending.args.isEmpty, let args = item["arguments"] as? String { pending.args = args }
                    try yieldToolCall(id: pending.callId, name: pending.name, args: pending.args)
                    pendingByItemId.removeValue(forKey: id)
                }
            } else if etype == "response.completed" || etype == "response.done" {
                // U1 step 1: usage rides on the terminal frame.
                let respObj = event["response"] as? [String: Any]
                if let usageObj = respObj?["usage"] as? [String: Any] {
                    capturedUsage = LLMUsage.fromOpenAIResponses(usageObj)
                }
                return true
            } else if etype == "response.incomplete" {
                // Terminal: the model stopped at a limit, the
                // transport did not drop. Without this the
                // stream ended `shouldStop == false` and threw
                // `.streamTruncated`, sending an output-limit
                // completion into the reconnect ladder.
                let respObj = event["response"] as? [String: Any]
                if let usageObj = respObj?["usage"] as? [String: Any] {
                    capturedUsage = LLMUsage.fromOpenAIResponses(usageObj)
                }
                incompleteReason = Self.incompleteReasonText(from: event)
                return true
            } else if etype == "response.failed" {
                let detail = Self.backendErrorDescription(
                    from: event,
                    fallback: "response failed"
                )
                throw Self.classifiedBackendError(
                    "\(errorPrefix) response failed: \(detail)"
                )
            } else if etype == "error" {
                let detail = Self.backendErrorDescription(
                    from: event,
                    fallback: "unknown backend error"
                )
                throw Self.classifiedBackendError(
                    "\(errorPrefix) error: \(detail)"
                )
            } else if etype.hasPrefix("response.reasoning") {
                // Liveness: extended-reasoning frames
                // (response.reasoning_text.delta /
                // reasoning_summary_text.delta / …) carry no
                // user-visible content but ARE real model activity.
                // Emit `.keepAlive` so a long reasoning phase
                // doesn't trip the guard's idle timeout — parity
                // with the Anthropic thinking_delta path. Reasoning
                // is NOT surfaced as reply text (no content yield).
                continuation.yield(.keepAlive)
            }
            return false
        }

        // R15: SSEEventStream owns framing (LF-only terminator
        // with CR strip — audit #14 — multi-line `data:` joins,
        // EOF flush of an unterminated trailing event);
        // processPayload owns the Responses-API semantics.
        //
        // Mid-stream transport errors (resource timeout,
        // connection lost, ...) thrown by the byte stream must
        // route through the SAME transientNetworkError mapping
        // the initial session.bytes(for:) connect uses —
        // without this wrapper they fell through to the
        // generic catch below and surfaced as raw URLErrors,
        // so mid-stream URLError.timedOut never classified
        // transient (Anthropic OAuth parity, gpt-5.5 review
        // 2026-07-02). Intentional LLMErrors from
        // processPayload (providerError, ...) and
        // cancellation re-throw untouched.
        var shouldStop = false
        do {
            for try await sse in SSEEventStream(bytes) {
                try Task.checkCancellation()
                shouldStop = try processPayload(sse.data)
                if shouldStop { break }
            }
        } catch let err as LLMError {
            throw err
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as any ProviderFailureWrapping {
            throw error
        } catch {
            throw mapTransportError(error, fallback: networkError(error))
        }
        if runawayTripped {
            await telemetry.record(
                requestBody: req.httpBody,
                provider: providerId,
                model: model,
                streaming: true,
                usage: capturedUsage,
                ttftMs: ttftMs,
                durationMs: Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000),
                status: "incomplete",
                substitutedFrom: substitutedFrom,
                stopReason: "client_runaway"
            )
            throw runaway.stopError
        }
        guard shouldStop else {
            // Byte stream ended WITHOUT a terminal event
            // ([DONE]/response.completed): a proxy/LB closing
            // the response mid-reply otherwise rendered the
            // partial as complete and persisted it. Every
            // other adapter throws streamTruncated here —
            // match the contract (audit 2026-06-09).
            throw LLMError.streamTruncated(
                message: "\(providerLabel) stream ended without terminal event"
            )
        }
        if let reason = incompleteReason {
            await telemetry.record(
                requestBody: req.httpBody,
                provider: providerId,
                model: model,
                streaming: true,
                usage: capturedUsage,
                ttftMs: ttftMs,
                durationMs: Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000),
                status: "incomplete",
                substitutedFrom: substitutedFrom,
                stopReason: reason
            )
            if reason == "max_output_tokens" {
                throw LLMError.outputLengthLimit(partial: runaway.text)
            }
            throw LLMError.providerError(message: Self.incompleteNote(reason))
        }
        for id in pendingOrder {
            if let pending = pendingByItemId[id] {
                try yieldToolCall(
                    id: pending.callId.isEmpty ? id : pending.callId,
                    name: pending.name,
                    args: pending.args
                )
            }
        }
        if lastRawDelta == nil, !yieldedToolCall {
            throw LLMError.streamTruncated(
                message: "\(providerLabel) stream produced no content (terminal event, empty)"
            )
        }
        // U1 step 1: one llm.call row per successful stream.
        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
        await telemetry.record(
            requestBody: req.httpBody,
            provider: providerId,
            model: model,
            streaming: true,
            usage: capturedUsage,
            ttftMs: ttftMs,
            durationMs: durationMs,
            substitutedFrom: substitutedFrom
        )
    }
    // MARK: - SSE parser (responses-API)

    /// Result of SSE parsing: either accumulated text or a mid-stream
    /// provider error frame the caller should throw on.
    enum SSEParseResult {
        case text(String)
        case providerError(String)
    }

    /// Parse result + provider usage (U1 step 1). `usage` is non-nil when a
    /// `response.completed`/`response.done` frame carried a usage object.
    struct SSEParsed {
        let result: SSEParseResult
        let usage: LLMUsage?
        /// 2026-09-06: true when a terminal frame (`[DONE]`,
        /// `response.completed`/`.done`, or a `response.failed`/`error`
        /// frame) was actually seen. False means the buffer was cut short —
        /// the buffered path must NOT treat that as a completed response,
        /// because the defensive pending-call flush below substitutes `{}`
        /// for arguments that never finished arriving and the tool loop
        /// would dispatch them. The streaming sibling already throws
        /// `.streamTruncated` in this case.
        let sawTerminal: Bool
        /// User, 2026-09-06: the `incomplete_details.reason` carried by a
        /// terminal `response.incomplete` frame ("max_output_tokens",
        /// "content_filter", …). Non-nil means the reply is COMPLETE as far as
        /// the transport is concerned and CUT as far as the model is concerned
        /// — a legitimate reply the caller must be told about, not a truncated
        /// stream to reconnect.
        var incompleteReason: String? = nil
    }

    /// The reason a `response.incomplete` frame gives for stopping.
    static func incompleteReasonText(from event: [String: Any]) -> String {
        let response = event["response"] as? [String: Any]
        let details = response?["incomplete_details"] as? [String: Any]
        if let reason = details?["reason"] as? String, !reason.isEmpty { return reason }
        return "unspecified"
    }

    /// Technical stop reasons stay in telemetry, never in the reply.
    static func incompleteNote(_ reason: String) -> String {
        switch reason {
        case "max_output_tokens", "max_tokens":
            return LLMError.outputLengthLimitNotice
        case "content_filter":
            return "The provider stopped this response because of its content policy."
        default:
            return "The model did not finish its response. Please try again."
        }
    }

    /// Back-compat shim — existing callers/tests that only need the text.
    static func parseResponsesSSE(from data: Data) -> SSEParseResult {
        parseResponsesSSEDetailed(from: data).result
    }

    /// Parse a buffer of SSE bytes containing `response.output_text.delta`
    /// events and concatenate the `.delta` text fields in stream order.
    /// Mirrors the Python `chat_stream` accumulator at L1008-L1012 +
    /// `response.failed`/`error` handling at L1058-L1063. Ignores frames
    /// the adapter doesn't currently surface (reasoning, ping, etc). Also
    /// captures `response.usage` from the terminal `response.completed`
    /// frame (input/output tokens + input_tokens_details.cached_tokens).
    static func parseResponsesSSEDetailed(from data: Data) -> SSEParsed {
        var capturedUsage: LLMUsage?
        var incompleteReason: String?
        var deltas: [String] = []
        var refusalTextByPart: [String: String] = [:]
        // HOTFIX 2026-06-03 tool-wire: accumulate function_call items so they
        // can be emitted as `<tool_use name="X">{args}</tool_use>` markers at
        // the end of the response, in stream order with text. Without this,
        // function_call events were being silently dropped at the catch-all
        // `else` below and ToolCallParser had nothing to parse.
        struct PendingCall { var name: String; var args: String }
        var pendingByItemId: [String: PendingCall] = [:]
        var pendingOrder: [String] = []
        var toolMarkers: [String] = []
        // Shared payload processor for in-loop frames AND the trailing
        // unterminated buffer (review nit 2026-06-10: the trailing drain
        // previously only handled text deltas, so a final response.completed
        // frame without a blank-line terminator dropped its usage object).
        // Returns true to stop parsing; a provider-error frame is surfaced
        // via `failure`.
        var failure: SSEParsed?
        func processPayload(_ payloadStr: String) -> Bool {
            if payloadStr == "[DONE]" { return true }
            guard let pdata = payloadStr.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any] else {
                return false
            }
            let etype = event["type"] as? String ?? ""
            if etype == "response.output_text.delta" {
                if let d = event["delta"] as? String, !d.isEmpty {
                    deltas.append(d)
                }
            } else if etype == "response.refusal.delta" || etype == "response.refusal.done",
                      let itemId = event["item_id"] as? String,
                      let contentIndex = event["content_index"] as? Int {
                let part = "\(itemId):\(contentIndex)"
                if etype == "response.refusal.delta", let delta = event["delta"] as? String {
                    refusalTextByPart[part, default: ""].append(delta)
                    deltas.append(delta)
                } else if let refusal = event["refusal"] as? String {
                    let streamed = refusalTextByPart[part] ?? ""
                    if refusal.hasPrefix(streamed) {
                        deltas.append(String(refusal.dropFirst(streamed.count)))
                    }
                    refusalTextByPart[part] = refusal
                }
            } else if etype == "response.output_item.added" {
                // New output item — if it's a function_call, register it.
                if let item = event["item"] as? [String: Any],
                   (item["type"] as? String) == "function_call",
                   let id = item["id"] as? String {
                    let name = (item["name"] as? String) ?? ""
                    let args = (item["arguments"] as? String) ?? ""
                    pendingByItemId[id] = PendingCall(name: name, args: args)
                    pendingOrder.append(id)
                }
            } else if etype == "response.function_call_arguments.delta" {
                // Streamed args chunks.
                if let id = event["item_id"] as? String,
                   let d = event["delta"] as? String,
                   pendingByItemId[id] != nil {
                    pendingByItemId[id]!.args.append(d)
                }
            } else if etype == "response.output_item.done" {
                // Finalize: emit <tool_use> marker now. Fold name/args
                // from item if present (some streams omit deltas).
                if let item = event["item"] as? [String: Any],
                   (item["type"] as? String) == "function_call",
                   let id = item["id"] as? String {
                    var name = pendingByItemId[id]?.name ?? ""
                    var args = pendingByItemId[id]?.args ?? ""
                    if name.isEmpty, let n = item["name"] as? String { name = n }
                    if args.isEmpty, let a = item["arguments"] as? String { args = a }
                    let body = args.isEmpty ? "{}" : args
                    // Pull the provider-issued call_id (function_call
                    // items carry both an item id and a call_id; the
                    // call_id is what subsequent function_call_output
                    // items reference). Fall back to item.id when
                    // call_id is missing so the marker always carries
                    // *some* id.
                    let callId = (item["call_id"] as? String) ?? id
                    toolMarkers.append("<tool_use id=\"\(callId)\" name=\"\(name)\">\(body)</tool_use>")
                    pendingByItemId.removeValue(forKey: id)
                }
            } else if etype == "response.completed" || etype == "response.done" {
                // U1 step 1: usage rides on the terminal frame.
                let respObj = event["response"] as? [String: Any]
                if let usageObj = respObj?["usage"] as? [String: Any] {
                    capturedUsage = LLMUsage.fromOpenAIResponses(usageObj)
                }
                return true
            } else if etype == "response.incomplete" {
                // User, 2026-09-06: a DOCUMENTED terminal frame. The model hit a
                // limit (max_output_tokens, a content filter) — the transport
                // delivered everything there was. Leaving it unrecognized left
                // `sawTerminal` false, so an output-limit completion was thrown
                // as `.streamTruncated` and entered the reconnect ladder, which
                // reissued the identical request to hit the identical limit.
                let respObj = event["response"] as? [String: Any]
                if let usageObj = respObj?["usage"] as? [String: Any] {
                    capturedUsage = LLMUsage.fromOpenAIResponses(usageObj)
                }
                incompleteReason = incompleteReasonText(from: event)
                return true
            } else if etype == "response.failed" {
                let detail = backendErrorDescription(
                    from: event,
                    fallback: "response failed"
                )
                failure = SSEParsed(
                    result: .providerError("chatgpt-backend response failed: \(detail)"),
                    usage: nil,
                    sawTerminal: true
                )
                return true
            } else if etype == "error" {
                let detail = backendErrorDescription(
                    from: event,
                    fallback: "unknown backend error"
                )
                failure = SSEParsed(
                    result: .providerError("chatgpt-backend error: \(detail)"),
                    usage: nil,
                    sawTerminal: true
                )
                return true
            }
            // Other event types (reasoning, ping) are ignored.
            return false
        }

        // R15: SSEEventParser owns framing, including the EOF flush of a
        // trailing unterminated event — so a trailing response.completed
        // keeps its usage and a trailing item.done still emits its marker
        // BEFORE the defensive pending flush below (no double-emit). The
        // old splitter treated a bare CR as its own terminator, which
        // flushed a phantom blank line inside CRLF streams and split
        // multi-line payloads (audit-#14 shape, buffered path) — fixed by
        // the shared parser.
        var sawTerminal = false
        for sse in SSEEventParser.parse(data: data) {
            if processPayload(sse.data) {
                if let failure { return failure }
                sawTerminal = true
                break
            }
        }
        // Flush any pending calls that never got a `done` event (defensive).
        // User, 2026-09-06: NOT on a `response.incomplete` — there the un-`done`
        // calls are known half-arrived (the limit cut them mid-arguments), so
        // the `{}` substitution below would hand the tool loop invented
        // arguments to dispatch. The caller rejects the incomplete response.
        if incompleteReason == nil {
            for id in pendingOrder {
                if let c = pendingByItemId[id] {
                    let body = c.args.isEmpty ? "{}" : c.args
                    // Defensive flush (no item.done was seen): pendingByItemId
                    // is keyed by item_id; if we never got a call_id from a
                    // matching `output_item.added` event, fall back to item_id
                    // as the marker id so the round-trip still has SOMETHING
                    // unique to echo back as the tool_result's tool_use_id.
                    toolMarkers.append("<tool_use id=\"\(id)\" name=\"\(c.name)\">\(body)</tool_use>")
                }
            }
        }
        // Combine text + tool markers. Order: text first, then tool markers
        // (since OpenAI Responses streams text deltas before function_call
        // items in our observed traces — putting markers after lets
        // ToolCallParser see them at the end of the response). Empty text +
        // tool markers is a tool-call-only response, which the parser handles.
        let textPart = deltas.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if toolMarkers.isEmpty || incompleteReason != nil {
            return SSEParsed(
                result: .text(textPart),
                usage: capturedUsage,
                sawTerminal: sawTerminal,
                incompleteReason: incompleteReason
            )
        }
        if textPart.isEmpty {
            return SSEParsed(
                result: .text(toolMarkers.joined(separator: "\n")),
                usage: capturedUsage,
                sawTerminal: sawTerminal,
                incompleteReason: incompleteReason
            )
        }
        return SSEParsed(
            result: .text(textPart + "\n" + toolMarkers.joined(separator: "\n")),
            usage: capturedUsage,
            sawTerminal: sawTerminal,
            incompleteReason: incompleteReason
        )
    }

    /// Legacy text-only shim — used by tests that only care about the
    /// happy-path text accumulation.
    static func collectResponsesSSE(from data: Data) -> String {
        if case .text(let s) = parseResponsesSSE(from: data) { return s }
        return ""
    }

}
