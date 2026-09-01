import Foundation
import NativeAgentShared
import PersistenceCore
import Testing
@testable import NativeAgentApp

// evals-total-coverage — fences `app.bridges` and `app.runtimes`.
//
// These are executable, hermetic evaluations for rows that previously had only
// live-feed reports. Every file operation uses a fresh temporary root; the
// transport is an in-memory actor. No listener, Apple service, push service, or
// resident data root is touched.

private func wave3Root(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgentBridgeRuntimeWave3-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func readJSONLRows(at path: URL) throws -> [[String: Any]] {
    let data = try Data(contentsOf: path)
    let text = try #require(String(data: data, encoding: .utf8))
    return try text.split(whereSeparator: \.isNewline).map { line in
        try #require(JSONSerialization.jsonObject(with: Data(String(line).utf8)) as? [String: Any])
    }
}

private actor SnapshotStatusTransport: DeviceSyncTransport {
    nonisolated let role: NADeviceRole = .mac
    private var failingKeys: Set<String>
    private var attempts: [String: Int] = [:]
    private var values: [String: String] = [:]

    init(failingKeys: Set<String> = []) {
        self.failingKeys = failingKeys
    }

    func ensurePushSubscriptions() async -> Bool { false }
    func send(_ message: BridgeMessage) async throws {}
    func observeIncoming(_ onMessage: @escaping @Sendable (BridgeMessage) async -> Bool) async {}
    func publishPairing(secret: Data) async throws {}
    func observePairing(onChange: @escaping @Sendable (Data) async -> Bool) async {}
    func observeStatus(key: String, onChange: @escaping @Sendable (String) async -> Void) async {}

    func setStatus(key: String, value: String) async throws {
        attempts[key, default: 0] += 1
        if failingKeys.contains(key) {
            throw DeviceSyncError.transient(message: "injected status write failure")
        }
        values[key] = value
    }

    func allow(_ key: String) { failingKeys.remove(key) }
    func attemptCount(for key: String) -> Int { attempts[key, default: 0] }
    func value(for key: String) -> String? { values[key] }
}

private actor ChatMessageTransport: DeviceSyncTransport {
    nonisolated let role: NADeviceRole = .mac
    private let rejectsSends: Bool
    private var messages: [BridgeMessage] = []

    init(rejectsSends: Bool = false) {
        self.rejectsSends = rejectsSends
    }

    func ensurePushSubscriptions() async -> Bool { false }
    func send(_ message: BridgeMessage) async throws {
        guard !rejectsSends else {
            throw DeviceSyncError.transient(message: "injected chat send rejection")
        }
        messages.append(message)
    }
    func observeIncoming(_ onMessage: @escaping @Sendable (BridgeMessage) async -> Bool) async {}
    func publishPairing(secret: Data) async throws {}
    func observePairing(onChange: @escaping @Sendable (Data) async -> Bool) async {}
    func observeStatus(key: String, onChange: @escaping @Sendable (String) async -> Void) async {}
    func setStatus(key: String, value: String) async throws {}

    func sentMessages() -> [BridgeMessage] { messages }
}

@Suite("Bridge and runtime wave 3 persistence evaluations", .serialized)
struct BridgeRuntimeWave3PersistenceEvalTests {
    // app.bridges / icloud.processedMessageIDs
    @Test("iCloud Drive processed ids retain arrival order rather than lexicographic order")
    func processedIDsKeepArrivalOrder() throws {
        let docs = try wave3Root("processed-order")
        defer { try? FileManager.default.removeItem(at: docs) }

        iCloudBridge.saveProcessedMessageIDs(["z-newer", "a-newest"], docsURL: docs)

        #expect(iCloudBridge.loadProcessedMessageIDs(docsURL: docs) == ["z-newer", "a-newest"])
    }

    // app.bridges / icloud.processedMessageIDs
    @Test("iCloud Drive processed-id retention evicts the oldest exact ids")
    func processedIDsCapFromTheOldestEnd() throws {
        let docs = try wave3Root("processed-cap")
        defer { try? FileManager.default.removeItem(at: docs) }
        let ids = (0...2_000).map { "arrival-\($0)" }

        iCloudBridge.saveProcessedMessageIDs(ids, docsURL: docs)
        let restored = iCloudBridge.loadProcessedMessageIDs(docsURL: docs)

        #expect(restored.count == 2_000)
        #expect(restored.first == "arrival-1")
        #expect(restored.last == "arrival-2000")
    }

    // app.bridges / icloud.processedMessageIDs
    @Test("a missing iCloud Drive processed-id file is a clean first-run state")
    func missingProcessedIDsAreEmptyOnlyAtGenesis() throws {
        let docs = try wave3Root("processed-genesis")
        defer { try? FileManager.default.removeItem(at: docs) }

        #expect(!FileManager.default.fileExists(atPath: iCloudBridge.processedMessageIDsURL(docsURL: docs).path))
        #expect(iCloudBridge.loadProcessedMessageIDs(docsURL: docs).isEmpty)
    }

    // app.bridges / icloud.chatDeliveryReceipts
    @Test("a signed CloudKit chat receipt records transport acceptance, not iOS delivery")
    func signedChatReceiptPersistsTransportAndVerification() async throws {
        let root = try wave3Root("receipt-signed")
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = Data(repeating: 7, count: 32)
        let message = try BridgeMessage.make(
            id: "receipt-signed", sender: "mac", text: "hello phone",
            sessionID: "ios:42", correlationID: "turn-42",
            metadata: ["kind": "reply", "targetSourceKey": "iphone:42"]
        ).signed(with: secret)

        await iCloudBridge.appendChatDeliveryReceipt(
            message,
            direction: "mac_to_ios",
            transport: "cloudkit",
            status: .acceptedByTransport,
            secret: secret,
            dataRoot: root
        )
        let path = root.appendingPathComponent("icloud/chat_delivery_receipts.jsonl")
        let row = try #require(readJSONLRows(at: path).last)

        #expect(row["messageId"] as? String == "receipt-signed")
        #expect(row["transport"] as? String == "cloudkit")
        #expect(row["direction"] as? String == "mac_to_ios")
        #expect(row["status"] as? String == "accepted_by_transport")
        #expect(row["deliveryConfirmed"] as? Bool == false)
        #expect(row["signatureVerified"] as? Bool == true)
        #expect(row["targetSourceKey"] as? String == "iphone:42")
    }

    // app.bridges / icloud.sendChatMessage
    @Test("chat send persists only CloudKit acceptance and exposes a rejected handoff")
    @MainActor
    func chatSendMakesTransportBoundaryAndFailureVisible() async throws {
        let root = try wave3Root("chat-send-boundary")
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = Data(repeating: 9, count: 32)
        let transport = ChatMessageTransport()
        let bridge = iCloudBridge(
            testDeviceTransport: transport,
            testPairingSecret: secret,
            testDataRoot: root
        )

        let message = try await bridge.sendChatMessage(
            text: "hello iPhone",
            sessionID: "ios:99",
            correlationID: "turn-99",
            metadata: ["targetSourceKey": "iphone:99"],
            messageID: "chat-send-boundary"
        )
        #expect(message.verifySignature(secret: secret))
        #expect(await transport.sentMessages().map(\.id) == ["chat-send-boundary"])
        #expect(bridge.syncStatus == "CloudKit accepted message — waiting for iOS")

        let path = root.appendingPathComponent("icloud/chat_delivery_receipts.jsonl")
        let row = try #require(readJSONLRows(at: path).last)
        #expect(row["messageId"] as? String == "chat-send-boundary")
        #expect(row["status"] as? String == "accepted_by_transport")
        #expect(row["deliveryConfirmed"] as? Bool == false)

        let driveRoot = try wave3Root("chat-send-drive")
        defer { try? FileManager.default.removeItem(at: driveRoot) }
        let macOutbox = driveRoot.appendingPathComponent("outbox/mac", isDirectory: true)
        try FileManager.default.createDirectory(at: macOutbox, withIntermediateDirectories: true)
        let driveBridge = iCloudBridge(
            testDriveURL: driveRoot,
            testPairingSecret: secret,
            testDataRoot: driveRoot
        )
        _ = try await driveBridge.sendChatMessage(
            text: "wait for replication",
            messageID: "chat-send-drive"
        )
        #expect(FileManager.default.fileExists(
            atPath: macOutbox.appendingPathComponent("chat-send-drive.json").path
        ))
        #expect(driveBridge.syncStatus == "Queued for iCloud sync — waiting for iOS")
        let driveReceipt = try #require(readJSONLRows(
            at: driveRoot.appendingPathComponent("icloud/chat_delivery_receipts.jsonl")
        ).last)
        #expect(driveReceipt["status"] as? String == "queued_for_icloud_sync")
        #expect(driveReceipt["deliveryConfirmed"] as? Bool == false)

        let unavailableRoot = try wave3Root("chat-send-drive-unavailable")
        defer { try? FileManager.default.removeItem(at: unavailableRoot) }
        let nonDirectoryDriveURL = unavailableRoot.appendingPathComponent("not-a-drive")
        try Data("file, not a container".utf8).write(to: nonDirectoryDriveURL)
        let unavailableBridge = iCloudBridge(
            testDriveURL: nonDirectoryDriveURL,
            testPairingSecret: secret,
            testDataRoot: unavailableRoot
        )
        var queueFailed = false
        do {
            _ = try await unavailableBridge.sendChatMessage(text: "cannot queue")
        } catch {
            queueFailed = true
        }
        #expect(queueFailed)
        #expect(unavailableBridge.syncStatus.contains("Could not queue iCloud message"))
        #expect(!FileManager.default.fileExists(
            atPath: unavailableRoot.appendingPathComponent("icloud/chat_delivery_receipts.jsonl").path
        ))

        let rejectedRoot = try wave3Root("chat-send-rejected")
        defer { try? FileManager.default.removeItem(at: rejectedRoot) }
        let rejectedBridge = iCloudBridge(
            testDeviceTransport: ChatMessageTransport(rejectsSends: true),
            testPairingSecret: secret,
            testDataRoot: rejectedRoot
        )
        var rejected = false
        do {
            _ = try await rejectedBridge.sendChatMessage(text: "must not claim delivery")
        } catch {
            rejected = true
        }
        #expect(rejected)
        #expect(rejectedBridge.syncStatus.contains("did not accept message"))
        #expect(!FileManager.default.fileExists(
            atPath: rejectedRoot.appendingPathComponent("icloud/chat_delivery_receipts.jsonl").path
        ))
    }

    // app.bridges / icloud.chatDeliveryReceipts
    @Test("a receipt exposes an invalid signature instead of claiming a trusted send")
    func tamperedChatReceiptDoesNotClaimVerification() async throws {
        let root = try wave3Root("receipt-tampered")
        defer { try? FileManager.default.removeItem(at: root) }
        let signingSecret = Data(repeating: 3, count: 32)
        let message = try BridgeMessage.make(id: "receipt-tampered", sender: "mac", text: "original")
            .signed(with: signingSecret)
        let encoded = try JSONEncoder().encode(message)
        var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        payload["text"] = "changed after signing"
        let tamperedData = try JSONSerialization.data(withJSONObject: payload)
        let tampered = try JSONDecoder().decode(BridgeMessage.self, from: tamperedData)

        await iCloudBridge.appendChatDeliveryReceipt(
            tampered,
            direction: "mac_to_ios",
            transport: "icloud_drive",
            status: .queuedForICloudSync,
            secret: signingSecret,
            dataRoot: root
        )
        let path = root.appendingPathComponent("icloud/chat_delivery_receipts.jsonl")
        let row = try #require(readJSONLRows(at: path).last)

        #expect(row["signatureVerified"] as? Bool == false)
        #expect(row["textPreview"] as? String == "changed after signing")
    }

    // app.bridges / icloud.chatDeliveryReceipts
    @Test("verified inbound chat success records explicit ios_to_mac delivery evidence")
    func verifiedInboundChatSuccessUsesInboundDirection() async throws {
        let root = try wave3Root("receipt-inbound-chat")
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = Data(repeating: 5, count: 32)
        let message = try BridgeMessage.make(
            id: "inbound-chat-1",
            sender: "ios",
            text: "hello mac",
            sessionID: "ios:7",
            correlationID: "turn-7",
            metadata: ["kind": "reply"]
        ).signed(with: secret)

        await iCloudBridge.appendInboundSuccessReceipt(
            message,
            transport: "cloudkit",
            secret: secret,
            dataRoot: root
        )
        let row = try #require(readJSONLRows(at: root.appendingPathComponent("icloud/chat_delivery_receipts.jsonl")).last)

        #expect(row["direction"] as? String == "ios_to_mac")
        #expect(row["status"] as? String == "delivered_to_mac")
        #expect(row["deliveryConfirmed"] as? Bool == true)
        #expect(row["signatureVerified"] as? Bool == true)
    }

    // app.bridges / icloud.chatDeliveryReceipts
    @Test("action responses persist their transport-specific mac_to_ios receipt rows")
    func actionResponsesPersistAcrossBothDirections() async throws {
        let root = try wave3Root("receipt-action-response")
        defer { try? FileManager.default.removeItem(at: root) }

        await iCloudBridge.appendActionResponseDeliveryReceipt(
            response: ["status": "ok", "msgId": "action-1", "message": "saved"],
            correlationID: "action-1",
            transport: "cloudkit",
            status: .acceptedByTransport,
            dataRoot: root
        )
        await iCloudBridge.appendInboundActionSuccessReceipt(
            messageID: "action-1",
            action: "saveSettings",
            transport: "cloudkit",
            dataRoot: root
        )
        let rows = try readJSONLRows(at: root.appendingPathComponent("icloud/chat_delivery_receipts.jsonl"))
        let responseRow = try #require(rows.first { ($0["kind"] as? String) == "icloud_action_response" })
        let inboundRow = try #require(rows.first {
            ($0["kind"] as? String) == "icloud_action"
                && ($0["direction"] as? String) == "ios_to_mac"
        })

        #expect(responseRow["direction"] as? String == "mac_to_ios")
        #expect(responseRow["correlationId"] as? String == "action-1")
        #expect(responseRow["deliveryConfirmed"] as? Bool == false)
        #expect(inboundRow["messageId"] as? String == "action-1")
        #expect(inboundRow["deliveryConfirmed"] as? Bool == true)
    }

    // app.bridges / icloud.chatDeliveryReceipts
    @Test("peer notification confirmation upserts the existing event receipt by explicit direction")
    func peerNotificationConfirmationUpdatesExistingReceipt() async throws {
        let root = try wave3Root("receipt-confirmation")
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = Data(repeating: 4, count: 32)
        let message = try BridgeMessage.make(
            id: "notify-1",
            sender: "mac",
            text: "Heads up",
            metadata: ["kind": "notification", "userInfo.eventId": String(repeating: "a", count: 64)]
        ).signed(with: secret)

        await iCloudBridge.appendChatDeliveryReceipt(
            message,
            direction: "mac_to_ios",
            transport: "cloudkit",
            status: .acceptedByTransport,
            secret: secret,
            dataRoot: root
        )
        let updated = await iCloudBridge.confirmChatDeliveryReceipt(
            direction: "mac_to_ios",
            eventID: String(repeating: "a", count: 64),
            channel: "ios",
            dataRoot: root
        )
        let rows = try readJSONLRows(at: root.appendingPathComponent("icloud/chat_delivery_receipts.jsonl"))
        let row = try #require(rows.last)

        #expect(updated)
        #expect(rows.count == 1)
        #expect(row["status"] as? String == "confirmed_by_peer")
        #expect(row["deliveryConfirmed"] as? Bool == true)
        #expect(row["eventId"] as? String == String(repeating: "a", count: 64))
        #expect(row["confirmationChannel"] as? String == "ios")
    }

    // app.bridges / icloud.chatDeliveryReceipts
    @Test("one torn receipt line self-heals instead of blocking every later write")
    func tornReceiptLineSelfHealsAndPreservesTheDamagedStore() async throws {
        // The store was appended non-atomically for most of its life, so a torn
        // last line can already be on disk at upgrade time. A strict full-file
        // parse threw on it, every append swallowed the throw with `try?`, and
        // `confirmChatDeliveryReceipt` then answered false forever — the phone's
        // recordNotificationReceipt failed `receipt_persistence_failed` with no
        // way back. Skipping the bad line must not silently eat the bytes.
        let root = try wave3Root("receipt-torn-line")
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = Data(repeating: 7, count: 32)
        let eventID = String(repeating: "c", count: 64)
        let receiptsURL = root.appendingPathComponent("icloud/chat_delivery_receipts.jsonl")

        // A good row that must survive, followed by a torn trailing write.
        let survivor = try BridgeMessage.make(
            id: "pre-tear-1",
            sender: "mac",
            text: "Earlier reply",
            metadata: ["kind": "notification", "userInfo.eventId": eventID]
        ).signed(with: secret)
        await iCloudBridge.appendChatDeliveryReceipt(
            survivor,
            direction: "mac_to_ios",
            transport: "cloudkit",
            status: .acceptedByTransport,
            secret: secret,
            dataRoot: root
        )
        let intact = try Data(contentsOf: receiptsURL)
        var torn = intact
        torn.append(Data("{\"at\":\"2026-08-31T00:00:00Z\",\"messageId\":\"tor".utf8))
        try torn.write(to: receiptsURL)

        // A later append still lands, and the pre-existing row is still
        // confirmable — both were permanently dead before this fix.
        let follower = try BridgeMessage.make(
            id: "post-tear-1",
            sender: "mac",
            text: "Later reply",
            metadata: ["kind": "reply"]
        ).signed(with: secret)
        await iCloudBridge.appendChatDeliveryReceipt(
            follower,
            direction: "mac_to_ios",
            transport: "cloudkit",
            status: .acceptedByTransport,
            secret: secret,
            dataRoot: root
        )
        let confirmed = await iCloudBridge.confirmChatDeliveryReceipt(
            direction: "mac_to_ios",
            eventID: eventID,
            channel: "ios",
            dataRoot: root
        )

        let rows = try readJSONLRows(at: receiptsURL)
        #expect(confirmed)
        #expect(rows.count == 2)
        #expect(rows.contains { ($0["messageId"] as? String) == "pre-tear-1" })
        #expect(rows.contains { ($0["messageId"] as? String) == "post-tear-1" })
        #expect(rows.contains {
            ($0["messageId"] as? String) == "pre-tear-1"
                && ($0["status"] as? String) == "confirmed_by_peer"
        })

        // The damaged original is renamed aside, never deleted.
        let icloudDir = root.appendingPathComponent("icloud", isDirectory: true)
        let asides = try FileManager.default
            .contentsOfDirectory(atPath: icloudDir.path)
            .filter { $0.hasPrefix("chat_delivery_receipts.jsonl.stale-") }
        #expect(asides.count == 1)
        let preserved = try #require(asides.first)
        let preservedBytes = try Data(contentsOf: icloudDir.appendingPathComponent(preserved))
        #expect(preservedBytes == torn)
    }

    // app.bridges / icloud.chatDeliveryReceipts
    @Test("peer notification confirmation rejects missing or invalid explicit direction")
    func peerNotificationConfirmationRequiresExplicitDirection() async throws {
        let root = try wave3Root("receipt-confirmation-invalid")
        defer { try? FileManager.default.removeItem(at: root) }

        let missingDirection = await iCloudBridge.confirmChatDeliveryReceipt(
            direction: "",
            eventID: String(repeating: "b", count: 64),
            channel: "ios",
            dataRoot: root
        )
        let invalidEvent = await iCloudBridge.confirmChatDeliveryReceipt(
            direction: "mac_to_ios",
            eventID: "not-canonical",
            channel: "ios",
            dataRoot: root
        )

        #expect(missingDirection == false)
        #expect(invalidEvent == false)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("icloud/chat_delivery_receipts.jsonl").path
        ))
    }

    // app.bridges / icloud.chatDeliveryReceipts
    @Test("delivery receipt cap retains the newest 500 rows across append and upsert")
    func deliveryReceiptCapKeepsNewestRows() async throws {
        let root = try wave3Root("receipt-cap")
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = Data(repeating: 6, count: 32)

        for index in 0..<501 {
            let message = try BridgeMessage.make(
                id: "msg-\(index)",
                sender: "mac",
                text: "row \(index)",
                metadata: ["kind": "notification", "userInfo.eventId": String(format: "%064d", index)]
            ).signed(with: secret)
            await iCloudBridge.appendChatDeliveryReceipt(
                message,
                direction: "mac_to_ios",
                transport: "cloudkit",
                status: .acceptedByTransport,
                secret: secret,
                dataRoot: root
            )
        }
        _ = await iCloudBridge.confirmChatDeliveryReceipt(
            direction: "mac_to_ios",
            eventID: String(format: "%064d", 500),
            channel: "ios",
            dataRoot: root
        )
        let rows = try readJSONLRows(at: root.appendingPathComponent("icloud/chat_delivery_receipts.jsonl"))

        #expect(rows.count == 500)
        #expect(rows.first?["messageId"] as? String == "msg-1")
        #expect(rows.last?["messageId"] as? String == "msg-500")
        #expect(rows.last?["deliveryConfirmed"] as? Bool == true)
    }

    // app.bridges / icloud.chatDeliveryReceipts
    @Test("rejected CloudKit actions write their response row but never claim inbound ios_to_mac success")
    @MainActor
    func rejectedCloudKitActionExcludesInboundSuccessReceipt() async throws {
        let root = try wave3Root("receipt-rejected-action")
        defer { try? FileManager.default.removeItem(at: root) }
        let responses = root.appendingPathComponent("responses", isDirectory: true)
        try FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
        let actionID = "11111111-1111-1111-1111-111111111111"

        let action = InboxAction(
            msgId: actionID,
            clientId: "ios-fixture",
            action: "getStatus",
            payload: [:],
            createdAt: ISO8601DateFormatter().string(from: Date()),
            protocolVersion: 1,
            transactionId: actionID,
            signature: "bad-signature"
        )
        let actionData = try JSONEncoder().encode(action)
        let secret = Data("cloudkit-invalid-action-fixture-secret".utf8)
        let envelope = try BridgeMessage.make(
            id: UUID().uuidString,
            sender: "ios",
            text: try #require(String(data: actionData, encoding: .utf8)),
            metadata: ["kind": "icloud_action", "actionId": action.msgId]
        ).signed(with: secret)

        let engine = MacSyncEngine(stateDataRootOverride: root)
        engine.responsesDir = responses
        engine.transactionDir = root.appendingPathComponent("transactions", isDirectory: true)
        engine._pairingSecret = secret
        engine.pairingSecretRotationInProgress = false
        engine.cloudKitActionStateRootOverride = root
        engine.processedMsgIds = []
        engine.processedMsgIdsOrdered = []
        engine.cloudKitActionResponseSender = { _, _ in }

        #expect(await engine.processCloudKitActionMessage(envelope))
        #expect(
            FileManager.default.fileExists(
                atPath: responses.appendingPathComponent("\(actionID).json").path
            )
        )
        let receiptsURL = root.appendingPathComponent("icloud/chat_delivery_receipts.jsonl")
        let rows: [[String: Any]] = if FileManager.default.fileExists(atPath: receiptsURL.path) {
            try readJSONLRows(at: receiptsURL)
        } else {
            []
        }
        #expect(rows.contains {
            ($0["kind"] as? String) == "icloud_action"
                && ($0["direction"] as? String) == "ios_to_mac"
        } == false)
    }

    // app.bridges / icloud.publishMobileSnapshotStatus
    @Test("a failed snapshot status publication is retried rather than deduplicated away")
    @MainActor
    func failedSnapshotPublicationIsNotRememberedAsSuccess() async throws {
        let root = try wave3Root("snapshot-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("desk-state".utf8).write(to: root.appendingPathComponent("desk.json"))
        let transport = SnapshotStatusTransport(failingKeys: [NAMobileSnapshotGroup.desk.statusKey])
        let bridge = iCloudBridge(testDeviceTransport: transport)

        #expect(await bridge.publishMobileSnapshotStatus(groups: [.desk], snapshotDirectory: root) == false)
        #expect(await transport.attemptCount(for: NAMobileSnapshotGroup.desk.statusKey) == 1)
        await transport.allow(NAMobileSnapshotGroup.desk.statusKey)

        #expect(await bridge.publishMobileSnapshotStatus(groups: [.desk], snapshotDirectory: root))
        #expect(await transport.attemptCount(for: NAMobileSnapshotGroup.desk.statusKey) == 2)
        #expect(await transport.value(for: NAMobileSnapshotGroup.desk.statusKey) != nil)
    }

    // app.bridges / icloud.publishMobileSnapshotStatus
    @Test("an unchanged successfully published snapshot is not resent")
    @MainActor
    func unchangedSnapshotDeduplicatesOnlyAfterDurableSuccess() async throws {
        let root = try wave3Root("snapshot-dedupe")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("desk-state".utf8).write(to: root.appendingPathComponent("desk.json"))
        let transport = SnapshotStatusTransport()
        let bridge = iCloudBridge(testDeviceTransport: transport)

        #expect(await bridge.publishMobileSnapshotStatus(groups: [.desk], snapshotDirectory: root))
        #expect(await bridge.publishMobileSnapshotStatus(groups: [.desk], snapshotDirectory: root))
        #expect(await transport.attemptCount(for: NAMobileSnapshotGroup.desk.statusKey) == 1)
    }

    // app.bridges / icloud.publishMobileSnapshotStatus
    @Test("one failed snapshot group does not suppress a healthy group")
    @MainActor
    func snapshotGroupsKeepIndependentFailureAndReceiptPaths() async throws {
        let root = try wave3Root("snapshot-groups")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("desk-state".utf8).write(to: root.appendingPathComponent("desk.json"))
        try Data("tool-state".utf8).write(to: root.appendingPathComponent("tools_snapshot.json"))
        let transport = SnapshotStatusTransport(failingKeys: [NAMobileSnapshotGroup.desk.statusKey])
        let bridge = iCloudBridge(testDeviceTransport: transport)

        #expect(await bridge.publishMobileSnapshotStatus(groups: [.desk, .catalog], snapshotDirectory: root) == false)
        #expect(await transport.value(for: NAMobileSnapshotGroup.desk.statusKey) == nil)
        #expect(await transport.value(for: NAMobileSnapshotGroup.catalog.statusKey) != nil)
    }

    // app.bridges / macsync.transactions
    @Test("MacSync transaction writes preserve creation time and monotonic attempts")
    @MainActor
    func transactionStatePersistsAcrossLifecycleTransitions() async throws {
        let root = try wave3Root("transaction-transition")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MacSyncEngine.shared
        let oldDirectory = engine.transactionDir
        engine.transactionDir = root
        defer { engine.transactionDir = oldDirectory }

        let id = "d0d2d37e-1799-4fc1-81a4-5572ed798e51"
        await engine.writeTransaction(id: id, action: "chat", state: "received", attempts: 1)
        let path = root.appendingPathComponent("\(id).json")
        let initial = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        await engine.writeTransaction(id: id, action: "chat", state: "running", attempts: 0)
        let final = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])

        #expect(final["createdAt"] as? String == initial["createdAt"] as? String)
        #expect(final["state"] as? String == "running")
        #expect(final["attempts"] as? Int == 1)
    }

    // app.bridges / macsync.transactions
    @Test("MacSync transaction terminal response survives a later state write")
    @MainActor
    func transactionReceiptDoesNotLoseItsTerminalResponse() async throws {
        let root = try wave3Root("transaction-response")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MacSyncEngine.shared
        let oldDirectory = engine.transactionDir
        engine.transactionDir = root
        defer { engine.transactionDir = oldDirectory }

        let id = "3591307b-eb77-4c03-b37d-3aa57a0dd1ca"
        await engine.writeTransaction(
            id: id, action: "settings", state: "completed", attempts: 1,
            response: ["status": "ok", "value": "saved"]
        )
        await engine.writeTransaction(id: id, action: "settings", state: "archived", attempts: 1)
        let path = root.appendingPathComponent("\(id).json")
        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let response = try #require(record["response"] as? [String: String])

        #expect(record["state"] as? String == "archived")
        #expect(response == ["status": "ok", "value": "saved"])
    }

    // app.bridges / macsync.transactions
    @Test("MacSync rejects an unsafe transaction identity without creating a receipt")
    @MainActor
    func unsafeTransactionIDCannotEscapeTheTransactionDirectory() async throws {
        let root = try wave3Root("transaction-invalid")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MacSyncEngine.shared
        let oldDirectory = engine.transactionDir
        engine.transactionDir = root
        defer { engine.transactionDir = oldDirectory }

        await engine.writeTransaction(id: "../outside", action: "chat", state: "received")

        #expect((try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty)
    }

    // app.bridges / push delivery persistence
    @Test("push-token rotation by token replaces stale canonical and compatibility ownership")
    func pushTokenRotationDoesNotLeaveTwoDeviceOwners() async throws {
        let root = try wave3Root("push-token-rotation")
        defer { try? FileManager.default.removeItem(at: root) }
        try await MacSyncMobileNotificationRelay.storePushToken(
            deviceId: "iphone-old", token: "same-token", environment: "sandbox",
            bundleId: "com.example.agent", dataRoot: root
        )
        try await MacSyncMobileNotificationRelay.storePushToken(
            deviceId: "iphone-new", token: "same-token", environment: "production",
            bundleId: "com.example.agent", dataRoot: root
        )

        let canonicalData = try Data(contentsOf: root.appendingPathComponent("notifications/push_tokens.json"))
        let canonical = try #require(JSONSerialization.jsonObject(with: canonicalData) as? [String: Any])
        let legacyData = try Data(contentsOf: root.appendingPathComponent("mobile_push/tokens.json"))
        let legacy = try #require(JSONSerialization.jsonObject(with: legacyData) as? [[String: Any]])

        #expect(canonical["iphone-old"] == nil)
        #expect((canonical["iphone-new"] as? [String: Any])?["environment"] as? String == "production")
        #expect(legacy.count == 1)
        #expect(legacy[0]["deviceId"] as? String == "iphone-new")
    }

    // app.runtimes / client.chatStream.macTurnAdapter
    @Test("ambiguous provider text cannot masquerade as a cancellation receipt")
    func ambiguousCancellationTextStaysOutcomeUnknown() {
        let box = NativeClient.MetaBox()
        box.recordExplicitStreamError("cancelled")
        #expect(box.terminalEvidence() == .ambiguousTermination)
    }

    // app.runtimes / client.chatStream.macTurnAdapter
    @Test("explicit stream failure is preserved as terminal evidence")
    func explicitStreamFailureDoesNotBecomeASuccessfulBlankTurn() {
        let box = NativeClient.MetaBox()
        box.recordExplicitStreamError("upstream disconnected")
        #expect(box.terminalEvidence() == .explicitFailure("upstream disconnected"))
    }

    // app.runtimes / client.chatStream.macTurnAdapter
    @Test("producer completion unblocks the receipt waiter exactly once")
    func producerCompletionIsDurableForLateAndEarlyWaiters() async {
        let box = NativeClient.MetaBox()
        async let early: Void = box.waitForProducerTermination()
        box.recordProducerFinished()
        await early
        #expect(box.producerHasFinished)
        await box.waitForProducerTermination()
        #expect(box.producerHasFinished)
    }
}
