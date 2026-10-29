import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `LLMClient+OpenAIResponsesDecoding.swift` | `ChatGPTTransport`: `consumeResponsesStream`, `incompleteReasonText`, `incompleteNote` |

extension ChatGPTTransport {
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
        // TTFT starts at the first text, function-call or argument frame; usage comes from response.completed.
        var capturedUsage: LLMUsage?
        var ttftMs: Int?
        // response.incomplete supplies the terminal incomplete reason.
        var incompleteReason: String?
        var refusalTextByPart: [String: String] = [:]
        var runaway = RunawayOutputDetector()

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
                // An unreadable frame after output starts is a retryable stream failure.
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
                    let boundary = runaway.feed(delta)
                    let kept = runaway.takeCommittedText()
                    if !kept.isEmpty { continuation.yield(.textDelta(kept)) }
                    if boundary { return true }
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
                    pendingByItemId[id]?.args.append(delta)
                }
                // Tool-argument deltas emit keepAlive because accumulated output still proves liveness.
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
                // Usage rides on the terminal frame.
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

        // SSEEventStream owns line framing, multiline data and EOF flush; processPayload owns Responses semantics.
        // Initial and mid-stream transport failures share the same mapper.
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
        if let reason = runaway.toolBoundaryReason {
            await telemetry.record(
                requestBody: req.httpBody,
                provider: providerId,
                model: model,
                streaming: true,
                usage: capturedUsage,
                ttftMs: ttftMs,
                durationMs: Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000),
                status: "ok",
                substitutedFrom: substitutedFrom,
                stopReason: "client_tool_boundary"
            )
            continuation.yield(.toolBoundary(reason))
            return
        }
        guard shouldStop else {
            // A stream without a terminal event is truncated, never a complete reply.
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
            if reason == "max_output_tokens" || reason == "max_tokens" {
                RunawayOutputDetector.writeDiagnostic(runaway.text, reason: "output_limit")
                continuation.yield(.toolBoundary(.outputLimit))
                return
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
        // Each successful stream records one llm.call row.
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
        case "content_filter":
            return "The provider stopped this response because of its content policy."
        default:
            return "The model did not finish its response. Please try again."
        }
    }
}
