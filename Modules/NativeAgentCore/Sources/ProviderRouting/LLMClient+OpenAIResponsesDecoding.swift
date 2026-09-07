import Foundation
import NativeAgentCore
import PersistenceCore

extension OpenAIOAuthDirectAdapter {
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

    /// This lane has no finish-reason channel — `complete` / `completeMessages`
    /// return a bare String and the stream yields text deltas — so an
    /// output-limit stop rides out as a bracketed note, the same shape every
    /// other truncation note on this codepath uses. Without it an incomplete
    /// reply is indistinguishable from a finished one.
    static func incompleteNote(_ reason: String) -> String {
        "[response incomplete: \(reason)]"
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
        // arguments to dispatch. The note on the text says the reply was cut.
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
        if toolMarkers.isEmpty {
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
