import Foundation
import Testing
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
@testable import NativeAgentApp

// These exercise production value/file seams with fresh roots.  They do not
// infer behavior by reading source text and never start a listener, talk to an
// external service, or touch the resident app data root.

private func bridgeRuntimeWave2Root(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgentBridgeRuntimeWave2-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Bridge and runtime wave 2 behavior", .serialized)
struct BridgeRuntimeWave2EvalTests {
    @Test("unknown native dispatch is a typed non-executed receipt with a fresh run identity")
    func missingNativeDispatchIsNotSuccess() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["tool": "retired_tool"])
        let client = NativeClient(baseURL: "")

        let first = try await client._dispatchMissingNativeHandler(bodyData: body)
        let second = try await client._dispatchMissingNativeHandler(bodyData: body)

        #expect(!first.ok)
        #expect(!first.executed)
        #expect(first.status == "failed")
        #expect(first.tool == "retired_tool")
        #expect(first.error?.code == "native_handler_missing")
        #expect(first.error?.tool == "retired_tool")
        #expect(!first.runId.isEmpty)
        #expect(first.runId != second.runId)
    }

    @Test("clear only mutates the canonical selected transcript and removes its retired sibling")
    func clearChatTranscriptUsesCanonicalSafePath() async throws {
        let root = try bridgeRuntimeWave2Root("clear")
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("chat/messages/telegram:42.jsonl")
        let neighbour = root.appendingPathComponent("chat/messages/telegram:99.jsonl")
        let retired = root.appendingPathComponent("chat/sessions/telegram:42/messages.jsonl")
        try FileManager.default.createDirectory(at: selected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retired.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("selected".utf8).write(to: selected)
        try Data("neighbour".utf8).write(to: neighbour)
        try Data("retired".utf8).write(to: retired)

        _ = try await NativeClient.clearChatMessages(sessionId: "  telegram:42 ", dataRoot: root)

        #expect(try Data(contentsOf: selected).isEmpty)
        #expect(try Data(contentsOf: neighbour) == Data("neighbour".utf8))
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        await #expect(throws: (any Error).self) {
            _ = try await NativeClient.clearChatMessages(sessionId: "../other", dataRoot: root)
        }
    }

    @Test("stop writes exactly the canonical cancellation marker and refuses an unsafe id")
    func cancelChatSessionUsesSameSessionIdentityRule() async throws {
        let root = try bridgeRuntimeWave2Root("cancel")
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await NativeClient.cancelChatSession(sessionId: "  telegram:42 ", dataRoot: root)
        let marker = root.appendingPathComponent("chat/sessions/telegram:42/cancelled.flag")
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(!(try String(contentsOf: marker, encoding: .utf8)).isEmpty)
        await #expect(throws: (any Error).self) {
            _ = try await NativeClient.cancelChatSession(sessionId: "../other", dataRoot: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("other/cancelled.flag").path))
    }

    @Test("native action receipts are persisted once with their terminal outcome")
    func nativeActionReceiptIsDurableAndDecodable() async throws {
        let root = try bridgeRuntimeWave2Root("native-action")
        defer { try? FileManager.default.removeItem(at: root) }
        let action = try #require(NativeClient.swiftRunnableNativeAction(id: "time_now"))

        let receipt = try await NativeClient.appendNativeActionReceipt(
            action: action,
            status: "dry_run",
            dryRun: true,
            output: .object(["status": .string("dry_run")]),
            dataRoot: root
        )
        let path = NativeClient.nativeActionReceiptsPath(dataRoot: root)
        let rows = try String(contentsOf: path, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)

        #expect(rows.count == 1)
        let json = try #require(JSONSerialization.jsonObject(with: Data(rows[0].utf8)) as? [String: Any])
        #expect(json["id"] as? String == receipt.id)
        #expect(json["actionId"] as? String == "time_now")
        #expect(json["status"] as? String == "dry_run")
        #expect(json["dryRun"] as? Bool == true)
    }

    @Test("Slack conversation mapping remains stable under concurrent first ingress and creates one session row")
    func slackSessionMapIsAtomicAtFirstMessage() async throws {
        let root = try bridgeRuntimeWave2Root("slack-session")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbound = SlackInboundMessage(
            eventId: "event-1", teamId: "T1", channelId: "C1", userId: "U1",
            eventType: "message", text: "hello", ts: "1.0", threadTs: nil,
            channelType: "im", isDirectMessage: true
        )
        let store = SlackSessionStore(dataRoot: root)
        async let first = store.activeSessionId(for: inbound)
        async let second = store.activeSessionId(for: inbound)
        let ids = try await [first, second]

        #expect(ids[0] == ids[1])
        let mapPath = root.appendingPathComponent("slack/session_map.json")
        let sessionsPath = root.appendingPathComponent("chat/sessions.json")
        let map = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: mapPath)) as? [String: Any])
        let sessions = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sessionsPath)) as? [[String: Any]])
        let mapped = (((map["sessions"] as? [String: Any])?[inbound.sessionKey] as? [String: Any])?["activeSessionId"] as? String)
        #expect(mapped == ids[0])
        #expect(sessions.filter { $0["id"] as? String == ids[0] }.count == 1)
        #expect(sessions.first?["source"] as? String == "slack")
    }

    @Test("Slack liveness distinguishes a quiet healthy socket from stale and disconnected transport")
    func slackSocketHealthHasNoSilentHealthyDefault() async {
        let health = SlackSocketHealth()
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let initiallyHealthy = await health.isHealthy(now: now, grace: 30)
        #expect(!initiallyHealthy)
        await health.markConnected(now: now)
        let freshHealthy = await health.isHealthy(now: now.addingTimeInterval(29), grace: 30)
        #expect(freshHealthy)
        let staleHealthy = await health.isHealthy(now: now.addingTimeInterval(31), grace: 30)
        #expect(!staleHealthy)
        await health.markDisconnected()
        let disconnectedHealthy = await health.isHealthy(now: now, grace: 30)
        #expect(!disconnectedHealthy)
    }

    @Test("APNS configuration failure is explicit and does not attempt to mint or send")
    func missingAPNSConfigurationFailsClosed() async throws {
        let root = try bridgeRuntimeWave2Root("apns")
        defer { try? FileManager.default.removeItem(at: root) }
        let sender = SwiftNativeAPNSSender(
            now: { Date(timeIntervalSinceReferenceDate: 1) },
            sign: { _, _, _, _ in "must-not-be-called" }
        )

        let result = await sender.sendNotification(
            title: "test", body: "body", userInfo: [:], dataRoot: root
        )
        #expect(result.receipts.isEmpty)
        #expect(result.errors.count == 1)
        #expect(result.errors[0].contains("not configured"))
    }

    @Test("push-token registration replaces the same device in both canonical and compatibility stores")
    func pushTokenRegistrationMaintainsBothStores() async throws {
        let root = try bridgeRuntimeWave2Root("push-token")
        defer { try? FileManager.default.removeItem(at: root) }
        try await MacSyncMobileNotificationRelay.storePushToken(
            deviceId: "iphone-1", token: "old-token", environment: "sandbox",
            bundleId: "com.example.agent", dataRoot: root
        )
        try await MacSyncMobileNotificationRelay.storePushToken(
            deviceId: "iphone-1", token: "new-token", environment: "production",
            bundleId: "com.example.agent", dataRoot: root
        )

        let canonicalPath = root.appendingPathComponent("notifications/push_tokens.json")
        let legacyPath = root.appendingPathComponent("mobile_push/tokens.json")
        let canonical = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: canonicalPath)) as? [String: Any])
        let legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: legacyPath)) as? [[String: Any]])
        let canonicalEntry = try #require(canonical["iphone-1"] as? [String: Any])
        #expect(canonicalEntry["token"] as? String == "new-token")
        #expect(canonicalEntry["environment"] as? String == "production")
        #expect(legacy.count == 1)
        #expect(legacy[0]["token"] as? String == "new-token")
        #expect(legacy[0]["environment"] as? String == "production")
    }

    @Test("completion bookkeeping leaves a durable no-replay marker when normal filing fails")
    func iCloudCompletionFallbackIsExplicitAndRecoverable() throws {
        let root = try bridgeRuntimeWave2Root("completion-marker")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = MacSyncEngine.commitCompletionBookkeeping(
            dataRoot: root, msgId: "A0B1C2D3", processedSaved: false,
            archiveError: "iCloud unavailable"
        )
        let marker = ICloudSyncStatePaths.completedUnarchivedMarker(dataRoot: root, msgId: "A0B1C2D3")
        #expect(!result.clean)
        #expect(result.markerWritten)
        #expect(result.transactionState == "completed_unarchived")
        #expect(result.syncError?.contains("will not run again") == true)
        #expect(FileManager.default.fileExists(atPath: marker.path))

        let restored = MacSyncEngine.restoreProcessedIds(dataRoot: root)
        #expect(restored.ids == ["A0B1C2D3"])
        #expect(!restored.unreadable)
    }
}
