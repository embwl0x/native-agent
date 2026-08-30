import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / slack.state.feed
@Suite("Slack state feed")
struct SlackStateFeedEvalTests {
    @Test("the canonical Socket Mode state feed distinguishes absent, current, stale, and malformed evidence")
    func feedReportsHonestEvidenceStates() async throws {
        let root = try makeRoot("states")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(SlackRuntimeStateFeed.read(dataRoot: root, now: now) == .absent)

        #expect(await SlackRuntimeStateStore.apply(
            ["connected": .bool(true), "lastError": .null],
            dataRoot: root,
            now: now
        ) == .stored)

        guard case .current(let current) = SlackRuntimeStateFeed.read(dataRoot: root, now: now) else {
            Issue.record("a freshly written canonical state was not observable as current")
            return
        }
        #expect(current.connected)
        #expect(!current.hasReportedError)

        guard case .stale(let stale) = SlackRuntimeStateFeed.read(
            dataRoot: root,
            now: now.addingTimeInterval(SlackRuntimeStateFeed.staleAfter + 1)
        ) else {
            Issue.record("an old heartbeat was not reported stale")
            return
        }
        #expect(stale.connected)

        let statePath = SlackRuntimeStateStore.path(dataRoot: root)
        try Data("{broken state".utf8).write(to: statePath, options: .atomic)
        guard case .unavailable = SlackRuntimeStateFeed.read(dataRoot: root, now: now) else {
            Issue.record("malformed state was misrepresented as an absent or healthy feed")
            return
        }

        try FileManager.default.removeItem(at: statePath)
        try FileManager.default.removeItem(at: statePath.deletingLastPathComponent())
        try Data("not a directory".utf8).write(
            to: statePath.deletingLastPathComponent(),
            options: .atomic
        )
        guard case .unavailable = SlackRuntimeStateFeed.read(dataRoot: root, now: now) else {
            Issue.record("a blocked state root was misrepresented as an absent feed")
            return
        }
    }

    @Test("the mounted connector reader exposes Socket Mode state without changing valid Slack credentials")
    func connectorOverlayShowsRuntimeEvidence() async throws {
        let root = try makeRoot("connector")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSlackRegistry(root: root)
        let token = root.appendingPathComponent("oauth_tokens/slack.json")
        try FileManager.default.createDirectory(at: token.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"access_token\":\"configured\"}".utf8).write(to: token, options: .atomic)

        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let unobserved = try #require(try await client.getConnectors().first { $0.id == "slack" })
        #expect(unobserved.authState == "connected")
        #expect(unobserved.healthStatus == "ok")
        #expect(unobserved.runtimeStatus == "unobserved")

        #expect(await SlackRuntimeStateStore.apply(
            ["connected": .bool(true), "lastError": .null],
            dataRoot: root
        ) == .stored)
        let live = try #require(try await client.getConnectors().first { $0.id == "slack" })
        #expect(live.authState == "connected")
        #expect(live.runtimeStatus == "connected")
        #expect(live.runtimeUpdatedAt != nil)

        let staleAt = Date().addingTimeInterval(-(SlackRuntimeStateFeed.staleAfter + 1))
        #expect(await SlackRuntimeStateStore.apply(
            ["connected": .bool(true), "lastError": .null],
            dataRoot: root,
            now: staleAt
        ) == .stored)
        let stale = try #require(try await client.getConnectors().first { $0.id == "slack" })
        #expect(stale.authState == "connected")
        #expect(stale.runtimeStatus == "stale")

        try Data("[\"not an object\"]".utf8).write(
            to: SlackRuntimeStateStore.path(dataRoot: root),
            options: .atomic
        )
        let malformed = try #require(try await client.getConnectors().first { $0.id == "slack" })
        #expect(malformed.authState == "connected")
        #expect(malformed.runtimeStatus == "unavailable")
    }

    @Test("durable recovery and intake pressure stay visible through the mounted Connectors status after a healthy hello")
    func connectorOverlayShowsDurableRecoveryWithoutChangingAuthority() async throws {
        let root = try makeRoot("recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSlackRegistry(root: root)
        let token = root.appendingPathComponent("oauth_tokens/slack.json")
        try FileManager.default.createDirectory(at: token.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"access_token\":\"configured\"}".utf8).write(to: token)
        let journal = SlackInboundDeliveryJournal(dataRoot: root, pendingCap: 2)
        func message(_ ts: String) -> SlackInboundMessage {
            SlackInboundMessage(eventId: "T1:C1:\(ts)", teamId: "T1", channelId: "C1", userId: "U1", eventType: "message", text: "PRIVATE MESSAGE BODY", ts: ts, threadTs: nil, channelType: "channel", isDirectMessage: false)
        }
        let first = message("1.000")
        _ = try await journal.claim(first)
        _ = try await journal.markOutcomeUnknown(eventId: first.eventId, detail: "manual recovery required")
        #expect(await SlackRuntimeStateStore.apply(["connected": .bool(true), "lastError": .null], dataRoot: root) == .stored)
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let recovering = try #require(try await client.getConnectors().first { $0.id == "slack" })
        #expect(recovering.authState == "connected")
        #expect(recovering.runtimeStatus == "recovery_required")
        #expect(recovering.runtimeDetail?.contains("1 replies have an unknown outcome") == true)
        #expect(recovering.runtimeDetail?.contains("PRIVATE MESSAGE BODY") == false)
        _ = try await journal.claim(message("2.000"))
        let paused = try #require(try await client.getConnectors().first { $0.id == "slack" })
        #expect(paused.authState == "connected")
        #expect(paused.runtimeStatus == "intake_paused")
        #expect(paused.runtimeDetail?.contains("2 pending replies") == true)
        #expect(paused.runtimeDetail?.contains("nothing is automatically discarded or resent") == true)
        #expect(try await journal.unresolved().count == 2)
    }

    private func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("slack-state-feed-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSlackRegistry(root: URL) throws {
        let path = root.appendingPathComponent("connectors/registry.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONValue.array([.object([
            "id": .string("slack"),
            "name": .string("Slack"),
            "enabled": .bool(true),
            "authState": .string("connected"),
            "healthStatus": .string("ok"),
        ])]).serializedData(pretty: false).write(to: path, options: .atomic)
    }
}
