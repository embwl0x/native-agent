import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

private final class SlackPagingProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var pages: [Data] = []
        var requests: [URLRequest] = []
        var holdAt: Int?
        var heldStops = 0
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()
    private var held = false
    static func reset(_ pages: [[String: Any]], holdAt: Int? = nil) throws {
        let bytes = try pages.map { try JSONSerialization.data(withJSONObject: $0) }
        lock.withLock { state = State(pages: bytes, holdAt: holdAt) }
    }
    static var requests: [URLRequest] { lock.withLock { state.requests } }
    static var heldStops: Int { lock.withLock { state.heldStops } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let bytes: Data? = Self.lock.withLock {
            let index = Self.state.requests.count
            Self.state.requests.append(request)
            if index == Self.state.holdAt { held = true; return nil }
            guard index < Self.state.pages.count else { return Data("{\"ok\":false}".utf8) }
            return Self.state.pages[index]
        }
        guard let bytes else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.withLock { if held { Self.state.heldStops += 1 } } }
}

private func historyPage(_ timestamps: [String], more: Bool = false, cursor: String = "") -> [String: Any] {
    ["ok": true, "has_more": more, "response_metadata": ["next_cursor": cursor],
     "messages": timestamps.map { ["ts": $0, "user": "U1", "text": "<@UBOT> message \($0)"] }]
}

private func pagingQuery(_ request: URLRequest, _ key: String) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value
}

private actor HistoryDeliveryRecorder {
    var generated: [String] = []
    var accepted: [String] = []
    var failAt: String?
    func generate(_ inbound: SlackInboundMessage) -> SlackSocketModeReply {
        generated.append(inbound.ts)
        return SlackSocketModeReply(text: "reply \(inbound.ts)")
    }
    func post(_ input: [String: JSONValue]) -> JSONValue {
        guard case .string(let text)? = input["text"], text.hasPrefix("reply ") else {
            return .object(["ok": .bool(false)])
        }
        let ts = String(text.dropFirst("reply ".count))
        if ts == failAt { return .object(["ok": .bool(false), "error": .string("ratelimited")]) }
        accepted.append(ts)
        return .object(["ok": .bool(true)])
    }
    func fail(_ ts: String?) { failAt = ts }
}

private struct HistoryHarness {
    let root: URL
    let session: URLSession
    let recorder = HistoryDeliveryRecorder()
    let loop: SlackSocketModeLoop
    let channel = SlackConversationRef(id: "C1", channelType: "channel")
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SlackPaging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlackPagingProtocol.self]
        session = URLSession(configuration: configuration)
        let recorder = self.recorder
        loop = SlackSocketModeLoop(config: SlackSocketModeConfig(
            botToken: "xoxb-fixture", appToken: "xapp-fixture", botUserId: "UBOT", teamId: "T1",
            enabled: true, historyPollEnabled: true, historyPollInterval: 60,
            historyConversationRefreshInterval: 600, allowedChannelIds: ["C1"], allowedUserIds: [], requireMention: true
        ), dataRoot: root, session: session,
        outbound: SlackSocketModeOutbound(postMessage: { await recorder.post($0) }, uploadFile: { await recorder.post($0) }),
        chatHandler: { await recorder.generate($0) })
    }
    func bootstrap(_ ts: String = "1.000000") async throws {
        try SlackPagingProtocol.reset([historyPage([ts], more: true, cursor: "old-history-never-followed")])
        try await loop.pollHistory(conversation: channel)
        #expect(SlackPagingProtocol.requests.count == 1)
        #expect(await recorder.generated.isEmpty)
    }
    func close() { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized)
struct SlackHistoryPaginationTests {
    @Test func emptyBootstrapAndNormalOnePageKeepNoReplayAndAdmissionContracts() async throws {
        let harness = try HistoryHarness()
        defer { harness.close() }
        try SlackPagingProtocol.reset([historyPage([])])
        try await harness.loop.pollHistory(conversation: harness.channel)
        try await harness.bootstrap()
        var page = historyPage(["2.000000"])
        page["messages"] = [
            ["ts": "4.000000", "user": "UBOT", "text": "<@UBOT> bot"],
            ["ts": "3.000000", "user": "U1", "text": "no mention"],
            ["ts": "2.000000", "user": "U1", "text": "<@UBOT> admitted"],
        ]
        try SlackPagingProtocol.reset([page])
        try await harness.loop.pollHistory(conversation: harness.channel)
        #expect(await harness.recorder.accepted == ["2.000000"])
        try SlackPagingProtocol.reset([historyPage([])])
        try await harness.loop.pollHistory(conversation: harness.channel)
        #expect(pagingQuery(SlackPagingProtocol.requests[0], "oldest") == "4.000000")
    }

    @Test func collectsMoreThanEightBeforeOldestFirstDeliveryAndDeduplicatesOverlap() async throws {
        let harness = try HistoryHarness()
        defer { harness.close() }
        try await harness.bootstrap()
        let newest = (4...11).reversed().map { "\($0).000000" }
        try SlackPagingProtocol.reset([
            historyPage(newest, more: true, cursor: "older"),
            historyPage(["4.000000", "3.000000", "2.000000", "1.000000"]),
        ])
        try await harness.loop.pollHistory(conversation: harness.channel, now: Date(timeIntervalSince1970: 100))
        let expected = (2...11).map { "\($0).000000" }
        #expect(await harness.recorder.generated == expected)
        #expect(await harness.recorder.accepted == expected)
        let requests = SlackPagingProtocol.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { pagingQuery($0, "oldest") == "1.000000" && pagingQuery($0, "latest") == "100.000000" })
        #expect(pagingQuery(requests[1], "cursor") == "older")
        try SlackPagingProtocol.reset([historyPage([])])
        try await harness.loop.pollHistory(conversation: harness.channel)
        #expect(pagingQuery(SlackPagingProtocol.requests[0], "oldest") == "11.000000")
    }

    @Test(arguments: ["api", "malformed", "repeat", "no_progress"])
    func failedCollectionNeverDeliversOrAdvancesAndRetryRecovers(fault: String) async throws {
        let harness = try HistoryHarness()
        defer { harness.close() }
        try await harness.bootstrap()
        let failure: [String: Any]
        switch fault {
        case "api": failure = ["ok": false, "error": "ratelimited"]
        case "malformed": failure = ["ok": true, "messages": [["ts": "bad"]]]
        case "repeat": failure = historyPage(["3.000000"], more: true, cursor: "older")
        default: failure = historyPage([], more: true)
        }
        try SlackPagingProtocol.reset([historyPage(["4.000000"], more: true, cursor: "older"), failure])
        do { try await harness.loop.pollHistory(conversation: harness.channel); Issue.record("Incomplete history must fail") }
        catch { #expect(await harness.recorder.generated.isEmpty) }
        try SlackPagingProtocol.reset([historyPage(["4.000000", "3.000000", "2.000000"])])
        try await harness.loop.pollHistory(conversation: harness.channel)
        #expect(pagingQuery(SlackPagingProtocol.requests[0], "oldest") == "1.000000")
        #expect(await harness.recorder.accepted == ["2.000000", "3.000000", "4.000000"])
    }

    @Test func cancellationDuringOlderPageHasNoGenerationOrWatermarkEffects() async throws {
        let harness = try HistoryHarness()
        defer { harness.close() }
        try await harness.bootstrap()
        try SlackPagingProtocol.reset([historyPage(["4.000000"], more: true, cursor: "held")], holdAt: 1)
        let task = Task { try await harness.loop.pollHistory(conversation: harness.channel) }
        let deadline = Date().addingTimeInterval(2)
        while SlackPagingProtocol.requests.count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(SlackPagingProtocol.requests.count == 2)
        task.cancel()
        do { try await task.value; Issue.record("Cancelled collection must throw") }
        catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        #expect(SlackPagingProtocol.heldStops == 1)
        #expect(await harness.recorder.generated.isEmpty)
        try SlackPagingProtocol.reset([historyPage(["2.000000"])])
        try await harness.loop.pollHistory(conversation: harness.channel)
        #expect(pagingQuery(SlackPagingProtocol.requests[0], "oldest") == "1.000000")
        #expect(await harness.recorder.accepted == ["2.000000"])
    }

    @Test func pageBudgetDoesNotAdvancePastUnreadOlderMessages() async throws {
        let harness = try HistoryHarness()
        defer { harness.close() }
        try await harness.bootstrap()
        try SlackPagingProtocol.reset((0..<100).map { historyPage(["\(200 - $0).000000"], more: true, cursor: "page\($0)") })
        do { try await harness.loop.pollHistory(conversation: harness.channel); Issue.record("Budget must fail explicitly") }
        catch { #expect(String(describing: error).contains("exceeded 100 pages")) }
        #expect(SlackPagingProtocol.requests.count == 100)
        #expect(await harness.recorder.generated.isEmpty)
        try SlackPagingProtocol.reset([historyPage([])])
        try await harness.loop.pollHistory(conversation: harness.channel)
        #expect(pagingQuery(SlackPagingProtocol.requests[0], "oldest") == "1.000000")
    }

    @Test func cursorlessTimePaginationPreservesExactDecimalBoundary() async throws {
        let harness = try HistoryHarness()
        defer { harness.close() }
        try await harness.bootstrap("1700000000.0000001")
        try SlackPagingProtocol.reset([
            historyPage(["1700000000.0000004", "1700000000.0000003"], more: true),
            historyPage(["1700000000.0000003", "1700000000.0000002"]),
        ])
        try await harness.loop.pollHistory(conversation: harness.channel)
        #expect(pagingQuery(SlackPagingProtocol.requests[1], "latest") == "1700000000.0000003")
        #expect(pagingQuery(SlackPagingProtocol.requests[1], "inclusive") == "false")
        #expect(await harness.recorder.accepted == ["1700000000.0000002", "1700000000.0000003", "1700000000.0000004"])
    }

    @Test func failedDeliveryStallsWatermarkAndPreparedRetryDoesNotRegenerate() async throws {
        let harness = try HistoryHarness()
        defer { harness.close() }
        try await harness.bootstrap()
        await harness.recorder.fail("3.000000")
        try SlackPagingProtocol.reset([historyPage(["4.000000", "3.000000", "2.000000"])])
        try await harness.loop.pollHistory(conversation: harness.channel)
        #expect(await harness.recorder.accepted == ["2.000000"])
        #expect(await harness.recorder.generated == ["2.000000", "3.000000"])
        await harness.recorder.fail(nil)
        try SlackPagingProtocol.reset([historyPage(["4.000000", "3.000000"])])
        try await harness.loop.pollHistory(conversation: harness.channel)
        #expect(pagingQuery(SlackPagingProtocol.requests[0], "oldest") == "2.000000")
        #expect(await harness.recorder.accepted == ["2.000000", "3.000000", "4.000000"])
        #expect(await harness.recorder.generated == ["2.000000", "3.000000", "4.000000"])
    }
}
