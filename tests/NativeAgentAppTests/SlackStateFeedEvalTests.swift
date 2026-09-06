// 2026-09-06: Connectors for ConnectorHealthDecay's canonical decayed
// auth/health spellings (7df7a4cd), used by the connector-overlay tests below.
import Connectors
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
        // 2026-09-06: the credential state this test holds constant is now
        // "configured, unverified", not "connected/ok". 7df7a4cd added
        // ConnectorHealthDecay to the list read
        // (NativeClient+LocalAPI.swift readConnectorRecords): the overlay still
        // derives connected/ok from the token file on disk, but a green whose
        // only proof is credential PRESENCE decays unless
        // connectors/actions/receipts.jsonl carries a real successful call.
        // This fixture writes a token and no receipts, so every read below is
        // `configured`/`unverified`. What the test pins is unchanged: the
        // Socket Mode feed moves runtimeStatus and never touches the
        // credential verdict.
        #expect(unobserved.authState == ConnectorHealthDecay.configuredAuth)
        #expect(unobserved.healthStatus == ConnectorHealthDecay.unverifiedHealth)
        #expect(unobserved.runtimeStatus == "unobserved")

        #expect(await SlackRuntimeStateStore.apply(
            ["connected": .bool(true), "lastError": .null],
            dataRoot: root
        ) == .stored)
        let live = try #require(try await client.getConnectors().first { $0.id == "slack" })
        // 2026-09-06: unchanged credential verdict, new spelling (7df7a4cd decay).
        #expect(live.authState == ConnectorHealthDecay.configuredAuth)
        #expect(live.runtimeStatus == "connected")
        #expect(live.runtimeUpdatedAt != nil)

        let staleAt = Date().addingTimeInterval(-(SlackRuntimeStateFeed.staleAfter + 1))
        #expect(await SlackRuntimeStateStore.apply(
            ["connected": .bool(true), "lastError": .null],
            dataRoot: root,
            now: staleAt
        ) == .stored)
        let stale = try #require(try await client.getConnectors().first { $0.id == "slack" })
        // 2026-09-06: a stale heartbeat still must not move the credential
        // verdict off the decayed value (7df7a4cd).
        #expect(stale.authState == ConnectorHealthDecay.configuredAuth)
        #expect(stale.runtimeStatus == "stale")

        try Data("[\"not an object\"]".utf8).write(
            to: SlackRuntimeStateStore.path(dataRoot: root),
            options: .atomic
        )
        let malformed = try #require(try await client.getConnectors().first { $0.id == "slack" })
        // 2026-09-06: a malformed runtime file still must not move the
        // credential verdict off the decayed value (7df7a4cd).
        #expect(malformed.authState == ConnectorHealthDecay.configuredAuth)
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
        // 2026-09-06: "without changing authority" now means the row keeps the
        // decayed credential verdict. 7df7a4cd's ConnectorHealthDecay downgrades
        // a green proved only by the token file when
        // connectors/actions/receipts.jsonl has no successful non-dry-run call,
        // and this fixture writes none. Delivery-journal pressure still must
        // not move it.
        #expect(recovering.authState == ConnectorHealthDecay.configuredAuth)
        #expect(recovering.runtimeStatus == "recovery_required")
        #expect(recovering.runtimeDetail?.contains("1 replies have an unknown outcome") == true)
        #expect(recovering.runtimeDetail?.contains("PRIVATE MESSAGE BODY") == false)
        _ = try await journal.claim(message("2.000"))
        let paused = try #require(try await client.getConnectors().first { $0.id == "slack" })
        // 2026-09-06: same decayed verdict under a paused intake (7df7a4cd).
        #expect(paused.authState == ConnectorHealthDecay.configuredAuth)
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
