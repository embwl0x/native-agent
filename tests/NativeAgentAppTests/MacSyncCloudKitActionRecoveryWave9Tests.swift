import CryptoKit
import Foundation
@testable import NativeAgentShared
import PersistenceCore
import Testing
@testable import NativeAgentApp

private actor CloudKitActionDeliveryProbe {
    private(set) var calls = 0
    private(set) var durableResponseExistedBeforeSend = false

    func send(_ response: [String: String], correlationID: String, responseURL: URL) throws {
        calls += 1
        durableResponseExistedBeforeSend = FileManager.default.fileExists(atPath: responseURL.path)
        if calls == 1 {
            throw NSError(domain: "CloudKitActionRecovery", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "transport temporarily unavailable"])
        }
    }
}

private actor CloudKitCancellationProbe {
    private var stopped = false
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var chatWaiter: CheckedContinuation<Void, Never>?
    private(set) var chatCompletions = 0
    private(set) var stops = 0

    func waitForChat() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func receive(_ message: BridgeMessage) async -> Bool {
        if message.metadata?["kind"] == "icloud_action" {
            stops += 1
            stopped = true
            chatWaiter?.resume()
            chatWaiter = nil
        } else {
            started = true
            startWaiter?.resume()
            startWaiter = nil
            if !stopped { await withCheckedContinuation { chatWaiter = $0 } }
            chatCompletions += 1
        }
        return true
    }
}

@Suite("CloudKit action durable resend", .serialized)
@MainActor
struct MacSyncCloudKitActionRecoveryWave9Tests {
    private let secret = Data("cloudkit-action-fixture-secret-0123456789".utf8)

    private func signedAction(messageID: String, name: String = "getStatus", payload: [String: String] = [:]) throws -> InboxAction {
        var action = InboxAction(
            msgId: messageID,
            clientId: "ios-fixture",
            action: name,
            payload: payload,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            protocolVersion: 1,
            transactionId: messageID,
            signature: nil
        )
        let encoder = JSONEncoder()
        let unsigned = try encoder.encode(action)
        var body = try #require(JSONSerialization.jsonObject(with: unsigned) as? [String: Any])
        body.removeValue(forKey: "signature")
        let canonical = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        action.signature = BridgeMessage.hmacHex(of: canonical, secret: secret)
        return action
    }

    private func envelope(_ action: InboxAction) throws -> BridgeMessage {
        try BridgeMessage.make(
            id: UUID().uuidString, sender: "ios",
            text: String(decoding: JSONEncoder().encode(action), as: UTF8.self),
            metadata: ["kind": "icloud_action", "actionId": action.msgId]
        ).signed(with: secret)
    }

    @Test("only authenticated run-scoped cancellation bypasses chat admission")
    func cancellationAdmission() throws {
        let id = UUID().uuidString
        let payload = ["sessionId": "phone-session", "runId": UUID().uuidString]
        let valid = try signedAction(messageID: id, name: "cancelChat", payload: payload)
        #expect(iCloudBridge.isAuthenticatedRunScopedCancellation(try envelope(valid), secret: secret))
        var tampered = valid
        tampered.payload["runId"] = "different-run"
        #expect(!iCloudBridge.isAuthenticatedRunScopedCancellation(try envelope(tampered), secret: secret))
        #expect(!iCloudBridge.isAuthenticatedRunScopedCancellation(try envelope(valid), secret: Data("wrong-key".utf8)))
        let unscoped = try signedAction(messageID: id, name: "cancelChat", payload: ["sessionId": "phone-session"])
        #expect(!iCloudBridge.isAuthenticatedRunScopedCancellation(try envelope(unscoped), secret: secret))
        let other = try signedAction(messageID: id, payload: payload)
        #expect(!iCloudBridge.isAuthenticatedRunScopedCancellation(try envelope(other), secret: secret))
    }

    @Test("Stop reaches a suspended chat and same-batch Stop precedes chat", arguments: [false, true])
    func cancellationReachesChat(sameBatch: Bool) async throws {
        let transport = CloudKitDeviceTransport(role: .mac, containerIdentifier: "fixture-\(UUID())", configured: false)
        let probe = CloudKitCancellationProbe()
        let key = secret
        transport.setCancellationAdmission { message in
            await iCloudBridge.isAuthenticatedRunScopedCancellation(message, secret: key)
        }
        transport.setIncomingHandler { await probe.receive($0) }
        let chat = try BridgeMessage.make(id: UUID().uuidString, sender: "ios", text: "fixture").signed(with: secret)
        let stop = try envelope(signedAction(messageID: UUID().uuidString, name: "cancelChat",
                                            payload: ["sessionId": "phone-session", "runId": chat.id]))
        let chatRow = (fields: try NAChatMessageCodec.encode(chat), modDate: Optional<Date>.none)
        let stopRow = (fields: try NAChatMessageCodec.encode(stop), modDate: Optional<Date>.none)
        let drain = Task {
            await transport.deliverIncoming(sameBatch ? [chatRow, stopRow] : [chatRow],
                                            since: nil, queryStartedAt: Date())
        }
        if !sameBatch {
            await probe.waitForChat()
            #expect(await transport.deliverCancellations([stopRow]) == 1)
        }
        #expect(await drain.value == (sameBatch ? 2 : 1))
        #expect(await transport.deliverCancellations([stopRow]) == 0)
        #expect(await probe.stops == 1)
        #expect(await probe.chatCompletions == 1)
    }

    @Test("failed cancellation response releases the receive claim for retry")
    func failedCancellationRemainsRetryable() async throws {
        let transport = CloudKitDeviceTransport(role: .mac, containerIdentifier: "fixture-\(UUID())", configured: false)
        let probe = CloudKitActionDeliveryProbe()
        let key = secret
        transport.setCancellationAdmission { message in
            await iCloudBridge.isAuthenticatedRunScopedCancellation(message, secret: key)
        }
        let absentResponse = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        transport.setIncomingHandler { message in
            do {
                try await probe.send([:], correlationID: message.id, responseURL: absentResponse)
                return true
            } catch { return false }
        }
        let stop = try envelope(signedAction(messageID: UUID().uuidString, name: "cancelChat",
                                            payload: ["sessionId": "phone-session", "runId": UUID().uuidString]))
        let row = (fields: try NAChatMessageCodec.encode(stop), modDate: Optional<Date>.none)
        #expect(await transport.deliverCancellations([row]) == 0)
        #expect(await transport.deliverCancellations([row]) == 1)
        #expect(await transport.deliverCancellations([row]) == 0)
        #expect(await probe.calls == 2)
    }

    @Test("signed CloudKit action persists response before a failed send and resends after marker-backed restart")
    func durableResponsePrecedesSendAndRestartResends() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudkit-action-recovery-\(UUID().uuidString)", isDirectory: true)
        let responses = root.appendingPathComponent("responses", isDirectory: true)
        try FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
        // 2026-09-06: the transaction ledger directory now has to exist.
        // 514deaa8 ("CloudKit action lane: the reservation is checked") made
        // writeTransaction return whether the row actually landed on disk, and
        // the lane refuses to dispatch when the "running" reservation does not
        // land — that reservation is the only thing standing between a lost
        // response and a second run of a non-idempotent action. The fixture
        // never created this directory; the write used to be fire-and-forget so
        // its failure was invisible, and now it correctly aborts the action
        // before it executes. Creating the directory restores the scenario the
        // test is actually about (a durable root that works).
        let transactions = root.appendingPathComponent("transactions", isDirectory: true)
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let messageID = UUID().uuidString
        let action = try signedAction(messageID: messageID)
        let actionData = try JSONEncoder().encode(action)
        let envelope = try BridgeMessage.make(
            id: UUID().uuidString,
            sender: "ios",
            text: try #require(String(data: actionData, encoding: .utf8)),
            metadata: ["kind": "icloud_action", "actionId": messageID]
        ).signed(with: secret)
        #expect(envelope.verifySignature(secret: secret))

        let responseURL = try #require(
            InboxActionFileBoundary.jsonURL(in: responses, validatedID: messageID)
        )
        let probe = CloudKitActionDeliveryProbe()
        let engine = MacSyncEngine(stateDataRootOverride: root)

        engine.responsesDir = responses
        engine.transactionDir = transactions
        engine._pairingSecret = secret
        engine.pairingSecretRotationInProgress = false
        engine.cloudKitActionStateRootOverride = root
        // Force the post-completion fallback marker after the response write;
        // this models a completed, unarchived action across a process restart.
        engine.cloudKitActionProcessedIDPersistence = { false }
        engine.processedMsgIds = []
        engine.processedMsgIdsOrdered = []
        engine.cloudKitActionResponseSender = { response, correlationID in
            try await probe.send(response, correlationID: correlationID, responseURL: responseURL)
        }

        #expect(await engine.processCloudKitActionMessage(envelope) == false)
        #expect(FileManager.default.fileExists(atPath: responseURL.path))
        #expect(await probe.durableResponseExistedBeforeSend)
        #expect(await probe.calls == 1)
        #expect(FileManager.default.fileExists(atPath: ICloudSyncStatePaths
            .completedUnarchivedMarker(dataRoot: root, msgId: messageID).path))

        // New memory, same durable root: marker restoration reaches the
        // duplicate branch, which reuses the stored signed response and never
        // dispatches the action again.
        let restored = MacSyncEngine.restoreProcessedIds(dataRoot: root)
        engine.processedMsgIds = Set(restored.ids)
        engine.processedMsgIdsOrdered = restored.ids
        engine.cloudKitActionProcessedIDPersistence = nil
        #expect(await engine.processCloudKitActionMessage(envelope))
        #expect(await probe.calls == 2)
        #expect(await probe.durableResponseExistedBeforeSend)
    }
}
