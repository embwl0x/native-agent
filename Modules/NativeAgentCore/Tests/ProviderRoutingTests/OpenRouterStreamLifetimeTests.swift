import Foundation
import Testing
@testable import ProviderRouting

private final class OpenRouterLifetimeProbe: @unchecked Sendable {
    let status: Int
    let body: Data
    let keepsOpen: Bool
    private let lock = NSLock()
    private var starts = 0
    private var catalogStarts = 0
    private var stops = 0

    init(status: Int, body: String, keepsOpen: Bool = true) {
        self.status = status
        self.body = Data(body.utf8)
        self.keepsOpen = keepsOpen
    }

    func started(catalog: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if catalog { catalogStarts += 1 } else { starts += 1 }
    }

    func stopped() {
        lock.lock()
        defer { lock.unlock() }
        stops += 1
    }

    var counts: (starts: Int, catalogs: Int, stops: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (starts, catalogStarts, stops)
    }
}

private final class OpenRouterLifetimeProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var probe: OpenRouterLifetimeProbe!
    private var activeProbe: OpenRouterLifetimeProbe?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let probe = Self.probe!
        activeProbe = probe
        let catalog = request.url?.path.hasSuffix("/models") == true
        let status = catalog ? 200 : probe.status
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = catalog
            ? Data(#"{"data":[{"id":"test/model","name":"Test Model","context_length":8192}]}"#.utf8)
            : probe.body
        client?.urlProtocol(self, didLoad: body)
        probe.started(catalog: catalog)
        if catalog || !probe.keepsOpen { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() { activeProbe?.stopped() }
}

@Suite("OpenRouter owns streaming request cancellation", .serialized)
struct OpenRouterStreamLifetimeTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OpenRouterLifetime-\(UUID().uuidString)")
    }

    private func makeAdapter(root: URL, probe: OpenRouterLifetimeProbe) -> (OpenRouterAdapter, URLSession) {
        OpenRouterLifetimeProtocol.probe = probe
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterLifetimeProtocol.self]
        let session = URLSession(configuration: configuration)
        let adapter = OpenRouterAdapter(
            session: session, endpoint: URL(string: "https://openrouter.invalid/chat/completions")!,
            apiKeyOverride: "hermetic-test-key", dataRootOverride: root
        )
        return (adapter, session)
    }

    private func consume(_ adapter: OpenRouterAdapter, structured: Bool) -> Task<Result<String, Error>, Never> {
        Task {
            do {
                var text = ""
                if structured {
                    for try await event in adapter.streamMessages(messages: [.user("hi")], system: nil, model: "test/model", tools: nil) {
                        if case .textDelta(let delta) = event { text += delta }
                    }
                } else {
                    for try await delta in adapter.stream(prompt: "hi", system: nil, model: "test/model") { text += delta }
                }
                return .success(text)
            } catch { return .failure(error) }
        }
    }

    private func waitUntil(timeout: TimeInterval = 1, _ predicate: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        return predicate()
    }

    @Test(arguments: [false, true])
    func stopClosesHeldErrorBodyWithoutWaitingForDeadlineOrRefreshingCatalog(structured: Bool) async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = OpenRouterLifetimeProbe(status: 404, body: "partial provider error")
        let (adapter, session) = makeAdapter(root: root, probe: probe)
        defer { session.invalidateAndCancel() }
        let consumer = consume(adapter, structured: structured)
        #expect(await waitUntil { probe.counts.starts == 1 })
        // Let the supplied body enter the error drain before Stop. The
        // assertion below measures request shutdown, not stream cancellation
        // (AsyncThrowingStream can finish while its producer still lives).
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        _ = await consumer.value
        #expect(await waitUntil { probe.counts.stops == 1 })
        #expect(probe.counts.catalogs == 0)
    }

    @Test(arguments: [false, true])
    func terminalSSEClosesRequestWithoutWaitingForRemoteEOF(structured: Bool) async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = OpenRouterLifetimeProbe(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\ndata: [DONE]\n\n")
        let (adapter, session) = makeAdapter(root: root, probe: probe)
        defer { session.invalidateAndCancel() }
        let result = await consume(adapter, structured: structured).value
        #expect(try result.get() == "hello")
        #expect(await waitUntil { probe.counts.stops == 1 })
    }

    @Test(arguments: [false, true])
    func byteBudgetStopsAtExactLimitAndPreservesHTTPFailure(structured: Bool) async {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = OpenRouterLifetimeProbe(status: 500, body: String(repeating: "e", count: 4096))
        let (adapter, session) = makeAdapter(root: root, probe: probe)
        defer { session.invalidateAndCancel() }
        let consumer = consume(adapter, structured: structured)
        #expect(await waitUntil { probe.counts.stops == 1 })
        let result = await consumer.value
        guard case .failure(let error) = result, let llmError = error as? LLMError,
              case .transient(let message) = llmError else {
            Issue.record("Expected normal transient HTTP500 mapping"); return
        }
        #expect(message.count == 4096)
    }

    @Test func deadlineReleasesHeldBodyAndPreservesPartialHTTPFailure() async {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = OpenRouterLifetimeProbe(status: 500, body: "partial upstream failure")
        let (adapter, session) = makeAdapter(root: root, probe: probe)
        defer { session.invalidateAndCancel() }
        let consumer = consume(adapter, structured: true)
        #expect(await waitUntil(timeout: 4) { probe.counts.stops == 1 })
        let result = await consumer.value
        guard case .failure(let error) = result, let llmError = error as? LLMError,
              case .transient(let message) = llmError else {
            Issue.record("Deadline replaced retryable HTTP500 with a cancellation error"); return
        }
        #expect(message == "partial upstream failure")
    }

    @Test(arguments: [false, true])
    func uncancelled404StillRefreshesCatalogAndReportsUnavailableModel(structured: Bool) async {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = OpenRouterLifetimeProbe(status: 404, body: "model not found", keepsOpen: false)
        let (adapter, session) = makeAdapter(root: root, probe: probe)
        defer { session.invalidateAndCancel() }
        let result = await consume(adapter, structured: structured).value
        guard case .failure(let error) = result, let llmError = error as? LLMError,
              case .modelUnavailable(let provider, let model) = llmError else {
            Issue.record("Expected normal modelUnavailable mapping"); return
        }
        #expect(provider == "openrouter")
        #expect(model == "test/model")
        #expect(probe.counts.catalogs == 1)
    }
}
