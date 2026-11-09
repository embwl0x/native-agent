import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `LLMClient+OpenAIResponsesDecoding.swift` | `ChatGPTTransport`: `consumeResponsesStream`, `incompleteReasonText`, `incompleteNote` |

extension ChatGPTTransport {
    /// Authentication belongs to the adapter; this owner interprets the Responses stream.
    static func consumeResponsesStream(
        bytes: ProviderHTTPBytes,
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
        continuation: AsyncThrowingStream<LLMMessageStreamEvent, Error>.Continuation, call: LLMCall
    ) async throws {
        struct PendingCall {
            var callId: String
            var name: String
            var args: String
        }
        var pendingByItemId: [String: PendingCall] = [:]
        var replyTextSettled = false
        var sawFunctionCall = false
        var yieldedToolCall = false
        var hasAnswerText = false
        var completedResponse = false
        var refused = false
        func resumeReply() {
            if replyTextSettled {
                replyTextSettled = false
                continuation.yield(.replyTextSettled(false))
            }
        }
        // Text and tool output both establish TTFT; usage belongs to the terminal frame.
        var capturedUsage: LLMUsage?
        var ttftMs: Int?
        // Keep the provider's explicit incomplete reason.
        var incompleteReason: String?
        var refusalTextByPart: [String: String] = [:]

        func stampTTFT() {
            if ttftMs == nil {
                ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
            }
        }

        func yieldToolCall(id: String, name: String, args: String) throws {
            guard !id.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (try? JSONSerialization.jsonObject(with: Data(args.utf8))) is [String: Any] else {
                throw LLMError.providerError(
                    message: "\(providerLabel): incomplete function call; a call ID, name and object arguments are required. Repair the provider stream.")
            }
            sawFunctionCall = true
            yieldedToolCall = true
            resumeReply()
            stampTTFT()
            continuation.yield(.toolCall(LLMStreamToolCall(
                id: id,
                name: name,
                inputJSON: Data(args.utf8)
            )))
        }

        var lastRawDelta: ContinuousClock.Instant?
        func processPayload(_ payloadStr: String) throws -> Bool {
            if payloadStr.isEmpty { return false }
            if payloadStr == "[DONE]" { return true }
            guard let pdata = payloadStr.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any] else {
                throw ProviderFailure.Diagnostic(cause: .malformedResponse,
                    detail: "\(providerLabel): malformed Responses stream frame")
            }
            let etype = event["type"] as? String ?? ""
            if etype == "response.refusal.delta" || etype == "response.refusal.done" { refused = true }
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
                    hasAnswerText = hasAnswerText || delta.contains(where: { !$0.isWhitespace })
                    lastRawDelta = ContinuousClock.now
                    resumeReply()
                    stampTTFT()
                    continuation.yield(.textDelta(delta))
                }
            } else if etype == "response.output_item.added" {
                if let item = event["item"] as? [String: Any],
                   (item["type"] as? String) == "function_call" {
                    guard let id = item["id"] as? String, !id.isEmpty else {
                        throw LLMError.providerError(message: "\(providerLabel): function-call item has no item ID")
                    }
                    sawFunctionCall = true
                    resumeReply()
                    // A tool-first reply establishes TTFT before its item completes.
                    stampTTFT()
                    guard let callId = item["call_id"] as? String, !callId.isEmpty,
                          let name = item["name"] as? String, !name.isEmpty,
                          pendingByItemId[id] == nil else {
                        throw LLMError.providerError(message: "\(providerLabel): invalid or duplicate function-call identity in output_item.added")
                    }
                    let args = (item["arguments"] as? String) ?? ""
                    pendingByItemId[id] = PendingCall(callId: callId, name: name, args: args)
                }
            } else if etype == "response.function_call_arguments.delta" {
                sawFunctionCall = true
                resumeReply()
                if let id = event["item_id"] as? String,
                   let delta = event["delta"] as? String {
                    // Argument deltas establish output even if the item's added frame was unrecognized.
                    stampTTFT()
                    guard pendingByItemId[id] != nil else {
                        throw LLMError.providerError(message: "\(providerLabel): function-call arguments arrived before their item identity")
                    }
                    pendingByItemId[id]?.args.append(delta)
                    // A call's argument delta is movement that says what is being written and how much.
                    if let pending = pendingByItemId[id] {
                        continuation.yield(.callInput(LLMStreamCallInput(name: pending.name, input: pending.args.utf8)))
                    }
                } else {
                    throw LLMError.providerError(message: "\(providerLabel): function-call delta has no item ID or arguments")
                }
            } else if etype == "response.output_item.done" {
                if let item = event["item"] as? [String: Any],
                   (item["type"] as? String) == "message",
                   lastRawDelta != nil, !sawFunctionCall, !replyTextSettled {
                    replyTextSettled = true
                    continuation.yield(.replyTextSettled(true))
                }
                if let item = event["item"] as? [String: Any],
                   (item["type"] as? String) == "function_call" {
                    guard let id = item["id"] as? String, !id.isEmpty else {
                        throw LLMError.providerError(message: "\(providerLabel): function-call item has no item ID")
                    }
                    guard let pending = pendingByItemId[id],
                          let callID = item["call_id"] as? String, callID == pending.callId,
                          let name = item["name"] as? String, name == pending.name,
                          let arguments = item["arguments"] as? String,
                          pending.args.isEmpty || pending.args == arguments else {
                        throw LLMError.providerError(
                            message: "\(providerLabel): function-call completion lacks or contradicts its registered identity/arguments")
                    }
                    try yieldToolCall(id: callID, name: name, args: arguments)
                    pendingByItemId.removeValue(forKey: id)
                }
            } else if etype == "response.completed" || etype == "response.done" {
                let respObj = event["response"] as? [String: Any]
                let status = respObj?["status"]
                completedResponse = respObj != nil && (status as? String == "completed"
                    || (etype == "response.completed" && status == nil))
                if let usageObj = respObj?["usage"] as? [String: Any] {
                    capturedUsage = LLMUsage.fromOpenAIResponses(usageObj)
                }
                return true
            } else if etype == "response.incomplete" {
                // An output-limit terminal is incomplete output, not transport truncation; it must not trigger reconnect recovery.
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
                // Reasoning frames report movement without becoming reply text.
                continuation.yield(.keepAlive)
            }
            return false
        }

        // SSEEventStream owns line framing, multiline data and EOF flush; processPayload owns Responses semantics. Initial and mid-stream transport
        // failures share the same mapper.
        var shouldStop = false
        do {
            for try await sse in SSEEventStream(bytes, lifetime: call.lifetime) {
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
        guard shouldStop else {
            // A stream without a terminal event is truncated, never a complete reply.
            throw LLMError.streamTruncated(
                message: "\(providerLabel) stream ended without terminal event"
            )
        }
        if let reason = incompleteReason {
            await telemetry.record(call: call,
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
                continuation.yield(.toolBoundary(.outputLimit))
                return
            }
            throw LLMError.providerError(message: Self.incompleteNote(reason))
        }
        if !pendingByItemId.isEmpty {
            throw LLMError.providerError(message: "\(providerLabel): response ended before function-call completion; no unfinished call was emitted")
        }
        if refused, !hasAnswerText {
            throw ProviderFailure.Diagnostic(cause: .refused,
                detail: "\(providerLabel): response refused without answer text")
        }
        let silentCompletion = call.allowsSilentCompletion && completedResponse
        if !hasAnswerText, !yieldedToolCall, !silentCompletion {
            throw ProviderFailure.Diagnostic(cause: .malformedResponse,
                detail: "\(providerLabel) stream produced no content (terminal event, empty)"
            )
        }
        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
        await telemetry.record(call: call,
            requestBody: req.httpBody,
            provider: providerId,
            model: model,
            streaming: true,
            usage: capturedUsage,
            ttftMs: ttftMs,
            durationMs: durationMs,
            status: refused ? "incomplete" : "ok",
            substitutedFrom: substitutedFrom,
            stopReason: refused ? "refusal" : nil
        )
        if refused { continuation.yield(.toolBoundary(.refusal)) }
    }

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
