import Foundation
import Testing
import NativeAgentCore
@testable import ProviderRouting

// R-M1 (tightness round 2): the HTTP-status→LLMError mapping for the three
// api-key Chat-Completions adapters (Moonshot / OpenAI / OpenRouter) was
// duplicated AND divergent — a 5xx mapped to `.transient` (retryable) in
// Moonshot but `.underlying` (terminal) in OpenAI/OpenRouter. It's now one
// shared helper with 5xx unified to `.transient` EVERYWHERE. These pins prove a
// 500 from each of the three surfaces yields `.transient`.

/// URLProtocol that answers every request with HTTP 500 + a small body.
private final class Status500Protocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.test")!,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("upstream 500 boom".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func status500Session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Status500Protocol.self]
    return URLSession(configuration: config)
}

private func expectTransient(
    _ body: () async throws -> String,
    _ label: String
) async {
    do {
        _ = try await body()
        Issue.record("\(label): expected a throw on HTTP 500, got a value")
    } catch let error as LLMError {
        guard case .transient = error else {
            Issue.record("\(label): expected .transient, got \(error)")
            return
        }
    } catch {
        Issue.record("\(label): expected LLMError.transient, got \(error)")
    }
}

@Test func moonshot500MapsToTransient() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ms-500-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = MoonshotAdapter(
        session: status500Session(),
        apiKeyOverride: "k",
        dataRootOverride: root,
        telemetryDataRootOverride: root
    )
    await expectTransient(
        { try await adapter.complete(prompt: "hi", system: nil, model: "kimi-k3") },
        "moonshot"
    )
}

@Test func openAI500MapsToTransient() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("oa-500-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = OpenAIAdapter(
        session: status500Session(),
        apiKeyOverride: "k",
        telemetryDataRootOverride: root
    )
    // Previously .underlying (terminal); R-M1 unifies to .transient (retryable).
    await expectTransient(
        { try await adapter.complete(prompt: "hi", system: nil, model: "gpt-5.5") },
        "openai"
    )
}

@Test func openRouter500MapsToTransient() async throws {
    let adapter = OpenRouterAdapter(
        session: status500Session(),
        apiKeyOverride: "k"
    )
    // Previously .underlying (terminal); R-M1 unifies to .transient (retryable).
    await expectTransient(
        { try await adapter.complete(prompt: "hi", system: nil, model: "anthropic/claude-3.5-sonnet") },
        "openrouter"
    )
}

// MARK: - Streaming 5xx pins (2026-07-21 audit)
//
// The STREAMING paths of Moonshot / OpenAI / xAI hand-checked the HTTP status
// before the SSE loop and mapped every non-401/429 failure to terminal
// .invalidResponse — divergent from the deliberate non-streaming policy
// (throwIfChatCompletionsError: 5xx → .transient for EVERY provider) — and
// discarded the provider's error body. The streaming guards now drain a
// bounded error-body chunk and route through the same 5xx→transient mapping.

private func expectStreamTransientPreservesBody(
    _ label: String,
    _ makeStream: @escaping @Sendable () -> AsyncThrowingStream<String, Error>
) async {
    do {
        for try await _ in makeStream() {}
        Issue.record("\(label): expected a throw on HTTP 500, stream completed")
    } catch let error as LLMError {
        guard case .transient(let message) = error else {
            Issue.record("\(label): expected .transient, got \(error)")
            return
        }
        #expect(
            message.contains("upstream 500 boom"),
            "\(label): the provider error body must survive the drain: \(message)"
        )
    } catch {
        Issue.record("\(label): expected LLMError.transient, got \(error)")
    }
}

@Test func moonshotStream500MapsToTransientAndPreservesBody() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ms-stream-500-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = MoonshotAdapter(
        session: status500Session(),
        apiKeyOverride: "k",
        dataRootOverride: root,
        telemetryDataRootOverride: root
    )
    // Previously terminal .invalidResponse(status: 500) with the body dropped.
    await expectStreamTransientPreservesBody("moonshot-stream") {
        adapter.stream(prompt: "hi", system: nil, model: "kimi-k3")
    }
}

@Test func openAIStream500MapsToTransientAndPreservesBody() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("oa-stream-500-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = OpenAIAdapter(
        session: status500Session(),
        apiKeyOverride: "k",
        telemetryDataRootOverride: root
    )
    // Previously terminal .invalidResponse(status: 500) with the body dropped.
    await expectStreamTransientPreservesBody("openai-stream") {
        adapter.stream(prompt: "hi", system: nil, model: "gpt-5.5")
    }
}

@Test func xAIStream500MapsToTransientAndPreservesBody() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("xai-stream-500-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Non-JWT fixture tokens read as non-expiring, so no refresh call fires.
    let tokenFile = root.appendingPathComponent("xai-token.json")
    try Data(#"{"access_token":"test-access","refresh_token":"test-refresh"}"#.utf8)
        .write(to: tokenFile)
    let adapter = XAIOAuthDirectAdapter(
        session: status500Session(),
        tokenPathOverride: tokenFile,
        telemetryDataRootOverride: root
    )
    // Previously terminal .invalidResponse(status: 500) with the body dropped.
    await expectStreamTransientPreservesBody("xai-stream") {
        adapter.stream(prompt: "hi", system: nil, model: "grok-4.5")
    }
}
