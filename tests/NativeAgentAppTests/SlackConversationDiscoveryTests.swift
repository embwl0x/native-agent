import Foundation
import Testing
@testable import NativeAgentApp

private final class SlackDiscoveryProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var responses: [Data] = []
        var requests: [URLRequest] = []
        var holdAt: Int?
        var stops = 0
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()
    private var held = false

    static func reset(_ responses: [[String: Any]], holdAt: Int? = nil) throws {
        let data = try responses.map { try JSONSerialization.data(withJSONObject: $0) }
        lock.withLock { state = State(responses: data, holdAt: holdAt) }
    }
    static var requests: [URLRequest] { lock.withLock { state.requests } }
    static var stops: Int { lock.withLock { state.stops } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response: Data? = Self.lock.withLock {
            let index = Self.state.requests.count
            Self.state.requests.append(request)
            if index == Self.state.holdAt {
                held = true
                return nil
            }
            guard index < Self.state.responses.count else { return Data("{\"ok\":false}".utf8) }
            return Self.state.responses[index]
        }
        guard let response else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.withLock { if held { Self.state.stops += 1 } }
    }
}

private func discoveryPage(_ channels: [[String: Any]], cursor: String = "") -> [String: Any] {
    ["ok": true, "channels": channels, "response_metadata": ["next_cursor": cursor]]
}

private func joinedChannel(_ id: String) -> [String: Any] { ["id": id, "is_member": true] }

private struct DiscoveryHarness {
    let root: URL
    let session: URLSession
    let loop: SlackSocketModeLoop

    init(allowedChannels: Set<String> = [], allowedUsers: Set<String> = ["U1"]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SlackDiscovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlackDiscoveryProtocol.self]
        session = URLSession(configuration: configuration)
        loop = SlackSocketModeLoop(
            config: SlackSocketModeConfig(
                botToken: "xoxb-fixture", appToken: "xapp-fixture", botUserId: "UBOT", teamId: "T1",
                enabled: true, historyPollEnabled: true, historyPollInterval: 60,
                historyConversationRefreshInterval: 600, allowedChannelIds: allowedChannels,
                allowedUserIds: allowedUsers, requireMention: true
            ),
            dataRoot: root, session: session,
            chatHandler: { _ in SlackSocketModeReply(text: "unused") }
        )
    }

    func close() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized)
struct SlackConversationDiscoveryTests {
    @Test func followsAllPagesPastTwoHundredAndDeduplicates() async throws {
        let first = (0..<200).map { joinedChannel("C\($0)") }
        try SlackDiscoveryProtocol.reset([
            discoveryPage(first, cursor: "next+/="),
            discoveryPage([joinedChannel("C199"), joinedChannel("C200"), ["id": "Cunjoined"]]),
        ])
        let harness = try DiscoveryHarness()
        defer { harness.close() }
        let result = try await harness.loop.cachedPollableConversations()
        #expect(result.count == 201)
        #expect(result.last?.id == "C200")
        let requests = SlackDiscoveryProtocol.requests
        #expect(requests.count == 2)
        let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first(where: { $0.name == "cursor" })?.value == "next+/=")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer xoxb-fixture" })
        #expect(try await harness.loop.cachedPollableConversations() == result)
        #expect(SlackDiscoveryProtocol.requests.count == 2)
    }

    @Test func emptyVirtualPageStillFollowsCursorAndPreservesChannelOnlyAdmission() async throws {
        try SlackDiscoveryProtocol.reset([
            discoveryPage([], cursor: "page2"),
            discoveryPage([joinedChannel("Cdenied"), joinedChannel("Callowed"), ["id": "Ddenied", "is_im": true]]),
        ])
        let harness = try DiscoveryHarness(allowedChannels: ["Callowed"], allowedUsers: [])
        defer { harness.close() }
        #expect(try await harness.loop.cachedPollableConversations() == [.init(id: "Callowed", channelType: "channel")])
        #expect(SlackDiscoveryProtocol.requests.count == 2)
    }

    @Test(arguments: ["missing_channels", "bad_channel", "bad_metadata", "bad_cursor", "repeated_cursor", "api_failure"])
    func incompleteRefreshRetainsLastGoodWithoutCachingPartial(fault: String) async throws {
        let harness = try DiscoveryHarness()
        defer { harness.close() }
        let now = Date()
        try SlackDiscoveryProtocol.reset([discoveryPage([joinedChannel("Cold")])])
        let old = try await harness.loop.cachedPollableConversations(now: now)
        let failed: [String: Any]
        switch fault {
        case "missing_channels": failed = ["ok": true]
        case "bad_channel": failed = ["ok": true, "channels": [false]]
        case "bad_metadata": failed = ["ok": true, "channels": [], "response_metadata": false]
        case "bad_cursor": failed = ["ok": true, "channels": [], "response_metadata": ["next_cursor": 7]]
        case "repeated_cursor": failed = discoveryPage([joinedChannel("Cpartial2")], cursor: "repeat")
        default: failed = ["ok": false, "error": "ratelimited"]
        }
        try SlackDiscoveryProtocol.reset([discoveryPage([joinedChannel("Cpartial")], cursor: "repeat"), failed])
        #expect(try await harness.loop.cachedPollableConversations(now: now.addingTimeInterval(601)) == old)
        let errors = try String(contentsOf: harness.root.appendingPathComponent("slack/errors.jsonl"), encoding: .utf8)
        #expect(errors.contains("conversation_discovery"))
        let stateData = try Data(contentsOf: harness.root.appendingPathComponent("slack/state.json"))
        let state = try JSONSerialization.jsonObject(with: stateData) as? [String: Any]
        #expect(state?["conversationDiscoveryUsingLastGood"] as? Bool == true)
        // A failed refresh must not make the partial list fresh for ten minutes.
        try SlackDiscoveryProtocol.reset([discoveryPage([joinedChannel("Cnew")])])
        #expect(try await harness.loop.cachedPollableConversations(now: now.addingTimeInterval(602)) == [.init(id: "Cnew", channelType: "channel")])
        #expect(SlackDiscoveryProtocol.requests.count == 1)
        let recoveredData = try Data(contentsOf: harness.root.appendingPathComponent("slack/state.json"))
        let recovered = try JSONSerialization.jsonObject(with: recoveredData) as? [String: Any]
        #expect(recovered?["conversationDiscoveryUsingLastGood"] as? Bool == false)
    }

    @Test func malformedFirstDiscoveryDoesNotBecomeEmptySuccess() async throws {
        let harness = try DiscoveryHarness()
        defer { harness.close() }
        try SlackDiscoveryProtocol.reset([["ok": true]])
        do {
            _ = try await harness.loop.cachedPollableConversations()
            Issue.record("Missing channels must not be cached as an empty workspace")
        } catch { #expect(String(describing: error).contains("malformed channels")) }
        try SlackDiscoveryProtocol.reset([discoveryPage([joinedChannel("Ccomplete")])])
        #expect(try await harness.loop.cachedPollableConversations() == [.init(id: "Ccomplete", channelType: "channel")])
    }

    @Test func boundedPaginationFailsExplicitlyWithoutPublishingPartialList() async throws {
        let harness = try DiscoveryHarness()
        defer { harness.close() }
        try SlackDiscoveryProtocol.reset((0..<100).map { discoveryPage([joinedChannel("C\($0)")], cursor: "next\($0)") })
        do {
            _ = try await harness.loop.cachedPollableConversations()
            Issue.record("Incomplete bounded discovery must throw without a last-good list")
        } catch { #expect(String(describing: error).contains("exceeded 100 pages")) }
        #expect(SlackDiscoveryProtocol.requests.count == 100)
        try SlackDiscoveryProtocol.reset([discoveryPage([joinedChannel("Ccomplete")])])
        #expect(try await harness.loop.cachedPollableConversations() == [.init(id: "Ccomplete", channelType: "channel")])
    }

    @Test func cancellationStopsHeldPageAndNeverReturnsStaleOrPublishesPartial() async throws {
        let harness = try DiscoveryHarness()
        defer { harness.close() }
        let now = Date()
        try SlackDiscoveryProtocol.reset([discoveryPage([joinedChannel("Cold")])])
        _ = try await harness.loop.cachedPollableConversations(now: now)
        try SlackDiscoveryProtocol.reset([discoveryPage([joinedChannel("Cpartial")], cursor: "held")], holdAt: 1)
        let task = Task { try await harness.loop.cachedPollableConversations(now: now.addingTimeInterval(601)) }
        let deadline = Date().addingTimeInterval(2)
        while SlackDiscoveryProtocol.requests.count < 2 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(SlackDiscoveryProtocol.requests.count == 2)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation must not fall back to the old cache")
        } catch { #expect(error is CancellationError) }
        #expect(SlackDiscoveryProtocol.stops == 1)
        try SlackDiscoveryProtocol.reset([discoveryPage([joinedChannel("Cnew")])])
        #expect(try await harness.loop.cachedPollableConversations(now: now.addingTimeInterval(602)) == [.init(id: "Cnew", channelType: "channel")])
    }
}
