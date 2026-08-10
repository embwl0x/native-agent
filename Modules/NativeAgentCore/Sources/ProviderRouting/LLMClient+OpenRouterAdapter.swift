import Foundation
import NativeAgentCore
import PersistenceCore

/// OpenRouter chat-completions adapter. OpenRouter speaks the OpenAI
/// chat-completions wire format at `https://openrouter.ai/api/v1/chat/completions`
/// and uses a Bearer api key resolved from env `OPENROUTER_API_KEY` or
/// `<dataRoot>/providers/openrouter.json::api_key`. Used by SwiftNativeLLMClient
/// for slash-namespaced model ids (`anthropic/claude-...`, `openai/...`,
/// `meta-llama/...`, etc.) — those are OpenRouter routing targets, not
/// first-party Anthropic / OpenAI calls.
public final class OpenRouterAdapter: LLMAdapter {
    public let providerId: String = "openrouter"
    private let session: URLSession
    private let endpoint: URL
    private let apiKeyOverride: String?
    private let dataRootOverride: URL?

    public init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
        apiKeyOverride: String? = nil,
        dataRootOverride: URL? = nil
    ) {
        self.session = session
        self.endpoint = endpoint
        self.apiKeyOverride = apiKeyOverride
        self.dataRootOverride = dataRootOverride
    }

    private func resolveKey() -> String? {
        if let k = apiKeyOverride, !k.isEmpty { return k }
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let includeEnvironment = dataRootOverride == nil
            || root.standardizedFileURL
                == PersistenceCore.defaultDataRoot().standardizedFileURL
        return LLMCredentialResolver.resolveAPIKey(
            envVar: "OPENROUTER_API_KEY",
            providerConfigFile: "openrouter.json",
            dataRoot: root,
            includeEnvironment: includeEnvironment
        )
    }

    public func complete(prompt: String, system: String?, model: String) async throws -> String {
        guard let key = resolveKey(), !key.isEmpty else {
            throw LLMError.notConfigured(provider: "openrouter")
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: String]] = []
        if let sys = system, !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        }
        messages.append(["role": "user", "content": prompt])
        let body: [String: Any] = ["model": model, "messages": messages]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw mapTransportError(error, fallback: .underlying(message: "connection refused: \(endpoint.host ?? "openrouter")"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
            _ = await OpenRouterModelCatalog.models(
                dataRoot: root,
                session: session,
                refresh: true
            )
            throw LLMError.modelUnavailable(provider: "openrouter", model: model)
        }
        try throwIfChatCompletionsError(status: status, data: data, mapping: Self.statusMapping, response: response)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse(status: status)
        }
        return content
    }

    public func stream(
        prompt: String,
        system: String?,
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        let session = self.session
        let endpoint = self.endpoint
        let keyResolved = self.resolveKey()
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let key = keyResolved, !key.isEmpty else {
                    continuation.finish(throwing: LLMError.notConfigured(provider: "openrouter"))
                    return
                }
                var req = URLRequest(url: endpoint)
                req.httpMethod = "POST"
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                applyStreamingLLMHeaders(to: &req)

                var messages: [[String: String]] = []
                if let sys = system, !sys.isEmpty {
                    messages.append(["role": "system", "content": sys])
                }
                messages.append(["role": "user", "content": prompt])
                let body: [String: Any] = ["model": model, "messages": messages, "stream": true]
                do {
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                } catch {
                    continuation.finish(throwing: LLMError.underlying(message: "encode: \(error)"))
                    return
                }
                let bytes: URLSession.AsyncBytes
                let response: URLResponse
                do {
                    (bytes, response) = try await session.bytes(for: req)
                } catch {
                    continuation.finish(throwing: mapTransportError(error, fallback: .underlying(message: "connection refused: \(endpoint.host ?? "openrouter")")))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if !(200..<300).contains(status) {
                    // F3-M4: mirror the non-streaming path's unified mapping
                    // (throwIfChatCompletionsError + Self.statusMapping) so the
                    // streaming lane matches: 401 → .authRejected, 429 & 5xx →
                    // .transient (retryable — was a blanket terminal
                    // .invalidResponse that terminally failed a retryable 5xx),
                    // any other 4xx → .invalidResponse. Drain a bounded slice of
                    // the error body so 429/5xx messages carry the provider cause.
                    // gpt-5.5 review (round 3): the drain is time-bounded and the
                    // status mapper ALWAYS runs afterward — a stalled or failed
                    // error-body read must never re-terminalize a retryable
                    // 429/5xx (the mapper works fine with a partial or empty
                    // body; the body is diagnostic garnish, not the verdict).
                    let body = await Self.drainErrorBody(
                        bytes, maxBytes: 4096, timeout: 2.0
                    )
                    if status == 404 {
                        let root = self.dataRootOverride ?? PersistenceCore.defaultDataRoot()
                        _ = await OpenRouterModelCatalog.models(
                            dataRoot: root,
                            session: session,
                            refresh: true
                        )
                        continuation.finish(throwing: LLMError.modelUnavailable(
                            provider: "openrouter",
                            model: model
                        ))
                        return
                    }
                    do {
                        try throwIfChatCompletionsError(
                            status: status, data: body, mapping: Self.statusMapping, response: response
                        )
                        // Unreachable: a non-2xx status always throws above.
                        continuation.finish(throwing: LLMError.invalidResponse(status: status))
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }
                do {
                    // C1: shared decoder owns framing semantics — [DONE]
                    // tracking and root error frames (B2: OpenRouter aggregates
                    // upstream providers, so a mid-stream `{"error":{…}}` from
                    // any of them previously surfaced as a masking
                    // streamTruncated instead of the real quota/overload cause).
                    // This loop keeps only OpenRouter's text-only yield policy.
                    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenRouter")
                    var sawContent = false
                    for try await sse in SSEEventStream(bytes) {
                        try Task.checkCancellation()
                        let frame = try decoder.consume(payload: sse.data)
                        if frame.isDone { break }
                        guard let content = frame.content else { continue }
                        sawContent = true
                        continuation.yield(content)
                    }
                    if !decoder.sawDone {
                        // EOF without the documented `[DONE]` sentinel — that's a
                        // truncated reply, not a clean end. Mirror the Anthropic
                        // adapter's behavior so partial replies don't masquerade
                        // as completed ones.
                        throw LLMError.streamTruncated(
                            message: "openrouter stream ended without [DONE]"
                        )
                    }
                    // A3.3: `[DONE]` but ZERO reply content AND zero tool calls is
                    // an empty-and-silent turn — throw streamTruncated instead of
                    // finishing clean. A tool-only turn is NOT empty.
                    if !sawContent && decoder.completedToolCalls(idPrefix: "openrouter").isEmpty {
                        throw LLMError.streamTruncated(
                            message: "openrouter stream produced no content ([DONE], empty)"
                        )
                    }
                    continuation.finish()
                } catch let err as LLMError {
                    continuation.finish(throwing: err)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: mapTransportError(error, fallback: .underlying(message: "stream: \(error)")))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// R-M1: shared status→error mapping for the OpenRouter Chat Completions
    /// path. 5xx is unified to `.transient` (was `.underlying`).
    /// Best-effort, time-bounded error-body drain (gpt-5.5 review, round 3).
    /// Returns whatever bytes arrived within `timeout` (up to `maxBytes`) — a
    /// stalled or failing body stream yields the partial body rather than
    /// blocking retry classification or surfacing a drain error as the verdict.
    private static func drainErrorBody(
        _ bytes: URLSession.AsyncBytes, maxBytes: Int, timeout: TimeInterval
    ) async -> Data {
        let drain = Task {
            var body = Data()
            do {
                for try await byte in bytes {
                    if body.count >= maxBytes { break }
                    body.append(byte)
                }
            } catch {}
            return body
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            drain.cancel()
        }
        let result = await drain.value
        watchdog.cancel()
        return result
    }

    private static let statusMapping = ChatCompletionsStatusMapping(
        provider: "openrouter",
        rateLimited: { String(data: $0, encoding: .utf8) ?? "rate limited" },
        serverError: { String(data: $0, encoding: .utf8) ?? "5xx" },
        otherwise: { status, _ in .invalidResponse(status: status) }
    )
}
