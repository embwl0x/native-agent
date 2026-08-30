import Foundation
import Testing
@testable import ProviderRouting

private enum APIKeyStreamShape: String, CaseIterable, Sendable {
    case openAIText, openAIMessages, moonshotText, moonshotMessages, anthropicText

    var isAnthropic: Bool { self == .anthropicText }
    var isStructured: Bool { self == .openAIMessages || self == .moonshotMessages }

    var delta: String {
        if isAnthropic {
            return "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}\n\n"
        }
        return "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n"
    }

    var terminal: String {
        isAnthropic ? "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n" : "data: [DONE]\n\n"
    }

    func adapter(session: URLSession, root: URL) -> any LLMAdapter {
        let endpoint = URL(string: "https://provider.invalid/reply")!
        switch self {
        case .openAIText, .openAIMessages:
            return OpenAIAdapter(session: session, endpoint: endpoint, apiKeyOverride: "hermetic-key", dataRootOverride: root)
        case .moonshotText, .moonshotMessages:
            return MoonshotAdapter(session: session, endpoint: endpoint, apiKeyOverride: "hermetic-key", dataRootOverride: root)
        case .anthropicText:
            return AnthropicAdapter(session: session, endpoint: endpoint, apiKeyOverride: "hermetic-key", dataRootOverride: root)
        }
    }
}

private final class APIKeyLifetimeProbe: @unchecked Sendable {
    let body: Data
    let status: Int
    private let lock = NSLock()
    private var starts: Set<String> = []
    private var stops: [String: Int] = [:]

    init(body: String, status: Int = 200) {
        self.body = Data(body.utf8)
        self.status = status
    }

    func started(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        starts.insert(path)
    }

    func stopped(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        stops[path, default: 0] += 1
    }

    func didStart(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return starts.contains(path)
    }

    func stopCount(_ path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stops[path, default: 0]
    }
}

// This suite owns its protocol class/state, independently of parallel suites.
// Every request is intercepted, and none finishes at the HTTP transport layer.
private final class APIKeyLifetimeProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var probe: APIKeyLifetimeProbe!
    private var activeProbe: APIKeyLifetimeProbe?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let probe = Self.probe!
        activeProbe = probe
        let path = request.url!.path
        let response = HTTPURLResponse(
            url: request.url!, statusCode: path == "/reply" ? probe.status : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream", "Retry-After": "7"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: path == "/reply" ? probe.body : Data("still open".utf8))
        probe.started(path)
    }

    override func stopLoading() { activeProbe?.stopped(request.url!.path) }
}

@Suite("API-key adapters retire only their streaming request", .serialized)
struct APIKeyStreamLifetimeTests {
    private func session(probe: APIKeyLifetimeProbe) -> URLSession {
        APIKeyLifetimeProtocol.probe = probe
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIKeyLifetimeProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func consume(_ adapter: any LLMAdapter, shape: APIKeyStreamShape) -> Task<Result<String, Error>, Never> {
        Task {
            do {
                var text = ""
                if shape.isStructured {
                    for try await event in adapter.streamMessages(messages: [.user("hi")], system: nil, model: "test-model", tools: nil) {
                        if case .textDelta(let delta) = event { text += delta }
                    }
                } else {
                    for try await delta in adapter.stream(prompt: "hi", system: nil, model: "test-model") { text += delta }
                }
                return .success(text)
            } catch { return .failure(error) }
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return predicate()
    }

    @Test(arguments: APIKeyStreamShape.allCases)
    fileprivate func terminalEventClosesExactRequestBeforeRemoteEOF(shape: APIKeyStreamShape) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("APIKeyLifetime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = APIKeyLifetimeProbe(body: shape.delta + shape.terminal)
        let session = session(probe: probe)
        defer { session.invalidateAndCancel() }
        let bystander = session.dataTask(with: URL(string: "https://provider.invalid/bystander")!)
        bystander.resume()
        defer { bystander.cancel() }
        #expect(await waitUntil { probe.didStart("/bystander") })
        let result = await consume(shape.adapter(session: session, root: root), shape: shape).value
        #expect(try result.get() == "hello")
        #expect(await waitUntil { probe.stopCount("/reply") == 1 })
        #expect(probe.stopCount("/bystander") == 0)
        #expect(bystander.state == .running)
    }

    @Test(arguments: APIKeyStreamShape.allCases)
    fileprivate func stopClosesHeldStreamWithoutCancellingSharedSession(shape: APIKeyStreamShape) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("APIKeyLifetime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = APIKeyLifetimeProbe(body: shape.delta)
        let session = session(probe: probe)
        defer { session.invalidateAndCancel() }
        let bystander = session.dataTask(with: URL(string: "https://provider.invalid/bystander")!)
        bystander.resume()
        defer { bystander.cancel() }
        #expect(await waitUntil { probe.didStart("/bystander") })
        let consumer = consume(shape.adapter(session: session, root: root), shape: shape)
        #expect(await waitUntil { probe.didStart("/reply") })
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        _ = await consumer.value
        #expect(await waitUntil { probe.stopCount("/reply") == 1 })
        #expect(probe.stopCount("/bystander") == 0)
        #expect(bystander.state == .running)
    }

    @Test func anthropicEarlyRateLimitClosesUnreadBodyAndPreservesRetryAfter() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("APIKeyLifetime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = APIKeyLifetimeProbe(body: "unread error body", status: 429)
        let session = session(probe: probe)
        defer { session.invalidateAndCancel() }
        let shape = APIKeyStreamShape.anthropicText
        let result = await consume(shape.adapter(session: session, root: root), shape: shape).value
        guard case .failure(let error) = result, let llmError = error as? LLMError,
              case .transient(let message) = llmError else {
            Issue.record("Expected unchanged rate limit mapping"); return
        }
        #expect(message == "rate limited [retry-after=7s]")
        #expect(llmError.retryAfterSeconds == 7)
        #expect(await waitUntil { probe.stopCount("/reply") == 1 })
    }
}
