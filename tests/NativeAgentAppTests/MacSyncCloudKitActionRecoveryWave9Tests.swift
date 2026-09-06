import CryptoKit
import Foundation
import NativeAgentShared
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

@Suite("CloudKit action durable resend", .serialized)
@MainActor
struct MacSyncCloudKitActionRecoveryWave9Tests {
    private let secret = Data("cloudkit-action-fixture-secret-0123456789".utf8)

    private func signedAction(messageID: String) throws -> InboxAction {
        var action = InboxAction(
            msgId: messageID,
            clientId: "ios-fixture",
            action: "getStatus",
            payload: [:],
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
