import Foundation
import CryptoKit
@testable import NativeAgentShared
import NativeAgentSharedTestSupport
import Testing
@testable import NativeAgentApp

@Suite("Mac mobile inbox security boundary")
struct MacSyncInboxSecurityBoundaryTests {
    @Test @MainActor func authenticatedStaleChatDoesNotReserveItsID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CloudKitDeviceTransport(role: .mac, containerIdentifier: "fixture", configured: false)
        let bridge = iCloudBridge(testDeviceTransport: transport, testPairingSecret: secret, testDataRoot: root)
        defer { bridge.tearDown() }
        let original = BridgeMessage.make(sender: "ios", text: "fixture")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var body = try #require(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        body["timestamp"] = "2026-01-01T00:00:00Z"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stale = try decoder.decode(BridgeMessage.self, from: JSONSerialization.data(withJSONObject: body)).signed(with: secret)
        #expect(await bridge.handleIncomingFromTransport(stale))
        let fresh = try original.signed(with: secret)
        #expect(await !bridge.handleIncomingFromTransport(fresh))
        #expect(bridge.syncStatus == "iPhone message waiting — Mac runtime unavailable")
    }

    @Test func macResyncFactorySatisfiesPhoneEnvelope() {
        for correlation in [nil, "request"] as [String?] {
            for version in [0, 1, Int.max] {
                let hint = iCloudBridge.unsignedResyncHintMessage(correlationID: correlation,
                    targetSourceKey: "ios:fixture", publishedAt: "", secretVersion: version)
                #expect(hint.isUnsignedResyncHint)
                #expect(hint.metadata?["pairing_secret_version"] == String(version))
            }
        }
        #expect(!iCloudBridge.unsignedResyncHintMessage(correlationID: nil,
            targetSourceKey: "", publishedAt: "", secretVersion: 0).isUnsignedResyncHint)
    }
    private let secret = Data("inbox-boundary-test-pairing-secret".utf8)

    @Test @MainActor func authenticatedStaleActionDoesNotReserveMessageOrTransaction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = root.appendingPathComponent("inbox")
        let transactions = root.appendingPathComponent("transactions")
        let responses = root.appendingPathComponent("responses")
        for directory in [inbox, transactions, responses] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MacSyncEngine(stateDataRootOverride: root)
        engine.cloudKitActionStateRootOverride = root
        engine._pairingSecret = secret
        engine.transactionDir = transactions
        engine.responsesDir = responses
        engine.cloudKitActionResponseSender = { _, _ in }
        var stale = InboxAction(msgId: UUID().uuidString, clientId: "ios", action: "getStatus",
            payload: [:], createdAt: "2026-01-01T00:00:00Z", protocolVersion: 1,
            transactionId: UUID().uuidString, signature: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        stale.signature = BridgeMessage.hmacHex(of: try encoder.encode(stale), secret: secret)
        let bytes = try encoder.encode(stale)
        let envelope = try BridgeMessage.make(sender: "ios", text: String(decoding: bytes, as: UTF8.self),
            metadata: ["kind": "icloud_action", "actionId": stale.msgId]).signed(with: secret)
        #expect(await engine.processCloudKitActionMessage(envelope))
        #expect(engine.processedMsgIds.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: transactions.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: responses.path).isEmpty)
        let file = inbox.appendingPathComponent("\(stale.msgId).json")
        try bytes.write(to: file)
        await engine.rejectInboxFile(action: stale, fileURL: file, inboxDir: inbox,
            transactionId: try #require(stale.transactionId),
            actionDigest: MacSyncEngine.inboxActionDigest(envelope: bytes), validationError: "stale timestamp")
        #expect(engine.processedMsgIds.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: transactions.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test @MainActor func badChatSignaturesDoNotReserveIDsOnEitherTransport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outbox = root.appendingPathComponent("outbox/ios")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CloudKitDeviceTransport(role: .mac, containerIdentifier: "fixture-\(UUID())", configured: false)
        let bridge = iCloudBridge(testDeviceTransport: transport,
                                  testPairingSecret: secret, testDataRoot: root)
        defer { bridge.tearDown() }
        transport.setIncomingHandler { await bridge.handleIncomingFromTransport($0) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for signature in [nil, "invalid"] as [String?] {
            var bad = BridgeMessage.make(sender: "ios", text: "fixture")
            bad.signature = signature
            let badRow = (fields: try NAChatMessageCodec.encode(bad), modDate: Optional<Date>.none)
            #expect(await transport.deliverIncoming([badRow], since: nil, queryStartedAt: Date()) == 1)
            #expect(await transport.deliverIncoming([badRow], since: nil, queryStartedAt: Date()) == 0)
            let genuine = try BridgeMessage.make(id: bad.id, sender: "ios", text: "fixture").signed(with: secret)
            // No runtime is attached: reaching runtime admission returns false;
            // an ID poisoned by the invalid version would return true instead.
            #expect(await !bridge.handleIncomingFromTransport(genuine))
            let goodRow = (fields: try NAChatMessageCodec.encode(genuine), modDate: Optional<Date>.none)
            // Same CloudKit record name, corrected payload: the transport must
            // invoke the handler again, which reaches unavailable runtime.
            bridge.syncStatus = "fixture before corrected transport delivery"
            #expect(await transport.deliverIncoming([goodRow], since: nil, queryStartedAt: Date()) == 0)
            #expect(bridge.syncStatus == "iPhone message waiting — Mac runtime unavailable")
            let file = outbox.appendingPathComponent("\(bad.id).json")
            let bytes = try encoder.encode(bad)
            try bytes.write(to: file)
            let rejected = iCloudBridge.scanIosOutboxFiles(docsURL: root, seenMessageIDs: [], inFlightMessageIDs: [], secret: secret)
            #expect(rejected.messages.isEmpty)
            #expect(rejected.seenIDs.isEmpty)
            #expect(rejected.rejections.isEmpty)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            #expect(try Data(contentsOf: root.appendingPathComponent("processed/rejected_signature_\(digest).done")) == bytes)
            try encoder.encode(genuine).write(to: file)
            let accepted = iCloudBridge.scanIosOutboxFiles(docsURL: root, seenMessageIDs: Set(rejected.seenIDs), inFlightMessageIDs: [], secret: secret)
            #expect(accepted.messages.contains { $0.message.id == bad.id })
            for pending in accepted.messages { try FileManager.default.removeItem(at: pending.fileURL) }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("icloud/incoming_rejections.jsonl").path))
    }

    @Test @MainActor func cloudKitInnerAuthenticationQuarantinesWithoutClaimingIDs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transactions = root.appendingPathComponent("transactions")
        let responses = root.appendingPathComponent("responses")
        for directory in [transactions, responses] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MacSyncEngine(stateDataRootOverride: root)
        engine.cloudKitActionStateRootOverride = root
        engine._pairingSecret = secret
        engine.transactionDir = transactions
        engine.responsesDir = responses
        let existingID = UUID().uuidString
        let retained = Data("existing transaction".utf8)
        let transactionURL = transactions.appendingPathComponent("\(existingID).json")
        try retained.write(to: transactionURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        for transactionID in [existingID, UUID().uuidString] {
            for signature in [nil, "invalid", String(repeating: "0", count: 64)] as [String?] {
                var command = action(messageID: UUID().uuidString, transactionID: transactionID)
                command.signature = signature
                let message = try BridgeMessage.make(sender: "ios",
                    text: String(decoding: encoder.encode(command), as: UTF8.self),
                    metadata: ["kind": "icloud_action", "actionId": command.msgId]).signed(with: secret)
                #expect(message.verifySignature(secret: secret))
                #expect(await engine.processCloudKitActionMessage(message))
                #expect(engine.processedMsgIds.isEmpty)
                #expect(try Data(contentsOf: transactionURL) == retained)
                #expect(try FileManager.default.contentsOfDirectory(atPath: transactions.path).count == 1)
                #expect(try FileManager.default.contentsOfDirectory(atPath: responses.path).isEmpty)
                let bytes = try encoder.encode(message)
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                #expect(try Data(contentsOf: root.appendingPathComponent("icloud/_rejected/\(digest).done")) == bytes)
            }
        }
    }

    @Test @MainActor func cloudKitRejectsWrongSenderWithoutClaimingAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transactions = root.appendingPathComponent("transactions")
        let responses = root.appendingPathComponent("responses")
        for directory in [transactions, responses] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MacSyncEngine(stateDataRootOverride: root)
        engine.cloudKitActionStateRootOverride = root
        engine.transactionDir = transactions
        engine.responsesDir = responses
        let bridge = iCloudBridge(testDeviceTransport: MockDeviceSyncTransport(role: .mac, cloud: MockDeviceCloud()),
                                  testPairingSecret: secret, testDataRoot: root)
        defer { bridge.tearDown() }
        let transactionID = UUID().uuidString
        let retained = Data("existing transaction must remain byte-preserved".utf8)
        let transactionURL = transactions.appendingPathComponent("\(transactionID).json")
        try retained.write(to: transactionURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        for sender in ["mac", "IOS", "", "ios "] {
            var command = action(messageID: UUID().uuidString, transactionID: transactionID)
            command.signature = BridgeMessage.hmacHex(of: try encoder.encode(command), secret: secret)
            let message = try BridgeMessage.make(sender: sender,
                text: String(decoding: encoder.encode(command), as: UTF8.self),
                metadata: ["kind": "icloud_action", "actionId": command.msgId]).signed(with: secret)
            #expect(message.verifySignature(secret: secret))
            #expect(ICloudIncomingMessageDisposition.classify(message, secret: secret, now: Date())
                == .permanentlyRejected(reason: "sender_invalid"))
            #expect(await bridge.handleIncomingFromTransport(message))
            #expect(await engine.processCloudKitActionMessage(message))
            #expect(engine.processedMsgIds.isEmpty)
            #expect(try Data(contentsOf: transactionURL) == retained)
            #expect(try FileManager.default.contentsOfDirectory(atPath: transactions.path).count == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: responses.path).isEmpty)
            let bytes = try encoder.encode(message)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            #expect(try Data(contentsOf: root.appendingPathComponent("icloud/_rejected/\(digest).done")) == bytes)
            // A genuine delivery using that outer ID must still reach admission:
            // without a runtime handler it stays retryable, not already consumed.
            let retry = try BridgeMessage.make(id: message.id, sender: "ios", text: "fixture").signed(with: secret)
            #expect(await !bridge.handleIncomingFromTransport(retry))
        }
        let valid = try BridgeMessage.make(sender: "ios", text: "fixture").signed(with: secret)
        #expect(ICloudIncomingMessageDisposition.classify(valid, secret: secret, now: Date()) == .deliver)
        // Failure to retain the rejected bytes must leave transport delivery retryable.
        try FileManager.default.removeItem(at: root.appendingPathComponent("icloud/_rejected"))
        try Data().write(to: root.appendingPathComponent("icloud/_rejected"))
        let rejected = try BridgeMessage.make(sender: "mac", text: "fixture").signed(with: secret)
        #expect(await !bridge.handleIncomingFromTransport(rejected))
        #expect(await !engine.processCloudKitActionMessage(rejected))
    }

    @Test func driveOutboxRejectsSignedMacReflectionAndAcceptsIOS() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outbox = root.appendingPathComponent("outbox/ios")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for sender in ["mac", "ios", "IOS", ""] {
            let message = try BridgeMessage.make(sender: sender, text: "fixture instruction").signed(with: secret)
            #expect(message.verifySignature(secret: secret))
            try encoder.encode(message).write(to: outbox.appendingPathComponent("\(message.id).json"))
        }
        let scan = iCloudBridge.scanIosOutboxFiles(docsURL: root, seenMessageIDs: [], inFlightMessageIDs: [], secret: secret)
        #expect(scan.messages.map(\.message.sender) == ["ios"])
        #expect(scan.rejections.isEmpty)
        #expect(scan.seenIDs.isEmpty)
        let archived = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("processed").path)
        #expect(archived.filter { $0.hasPrefix("rejected_sender_") }.count == 3)
    }

    @Test @MainActor func authenticationFailuresPreserveTransactionAndGenuineRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = root.appendingPathComponent("inbox")
        let transactions = root.appendingPathComponent("transactions")
        let responses = root.appendingPathComponent("responses")
        for directory in [inbox, transactions, responses] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MacSyncEngine(stateDataRootOverride: root)
        engine._pairingSecret = secret
        engine.transactionDir = transactions
        engine.responsesDir = responses
        let txID = UUID().uuidString
        var genuine = action(messageID: UUID().uuidString, transactionID: txID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let canonical = try encoder.encode(genuine)
        genuine.signature = HMAC<SHA256>.authenticationCode(for: canonical, using: SymmetricKey(data: secret))
            .map { String(format: "%02x", $0) }.joined()
        let genuineData = try encoder.encode(genuine)
        let response = try engine.signedResponse(["ok": "true", "msgId": genuine.msgId, "result": "retained result"])
        #expect(await engine.writeTransaction(id: txID, action: genuine.action, state: "completed", response: response,
                                             msgId: genuine.msgId, actionDigest: MacSyncEngine.inboxActionDigest(envelope: genuineData)))
        let transactionURL = transactions.appendingPathComponent("\(txID).json")
        let before = try Data(contentsOf: transactionURL)

        for signature in [String(repeating: "0", count: 64), nil] {
            var forged = action(messageID: UUID().uuidString, transactionID: txID)
            forged.signature = signature
            let data = try encoder.encode(forged)
            let file = inbox.appendingPathComponent("\(forged.msgId).json")
            try data.write(to: file)
            #expect(await !engine.authenticateInboxFile(data: data, action: forged, fileURL: file, inboxDir: inbox))
            #expect(try Data(contentsOf: transactionURL) == before)
            #expect(engine.processedMsgIds.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: responses.path).isEmpty)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(try Data(contentsOf: inbox.appendingPathComponent("_rejected/\(digest).done")) == data)
        }

        // The same message ID must also remain available for authentic delivery.
        var tampered = genuine
        tampered.signature = String(repeating: "0", count: 64)
        let file = inbox.appendingPathComponent("\(genuine.msgId).json")
        let tamperedData = try encoder.encode(tampered)
        try tamperedData.write(to: file)
        #expect(await !engine.authenticateInboxFile(data: tamperedData, action: tampered, fileURL: file, inboxDir: inbox))
        try genuineData.write(to: file)
        #expect(await engine.authenticateInboxFile(data: genuineData, action: genuine, fileURL: file, inboxDir: inbox))
        #expect(!engine.processedMsgIds.contains(genuine.msgId))
        guard case .present(let retained) = await engine.readTransaction(id: txID) else {
            Issue.record("Completed transaction was lost")
            return
        }
        #expect(MacSyncEngine.inboxLedgerRow(retained, matchesMsgId: genuine.msgId,
                                           digest: MacSyncEngine.inboxActionDigest(envelope: genuineData), action: genuine.action))
        #expect(MacSyncEngine.inboxActionDidExecute(retained.state))
        #expect(retained.response == response)
        #expect(try Data(contentsOf: transactionURL) == before)

        await engine.rejectInboxFile(action: genuine, fileURL: file, inboxDir: inbox, transactionId: txID,
                                     actionDigest: MacSyncEngine.inboxActionDigest(envelope: genuineData), validationError: "message too old")
        #expect(try Data(contentsOf: transactionURL) == before)
        #expect(try Data(contentsOf: file) == genuineData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: responses.path).isEmpty)
        #expect(engine.processedMsgIds.isEmpty)
    }

    @Test func rejectionLedgerCreationNeverOverwritesExistingBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = ICloudTransactionRecord(id: UUID().uuidString, direction: "ios_to_mac", action: "getStatus",
                                            state: "rejected", createdAt: "fixture", updatedAt: "fixture")
        #expect(MacSyncEngine.writeRejectedTransactionIfAbsent(record, in: root))
        let file = root.appendingPathComponent("\(record.id).json")
        let before = try Data(contentsOf: file)
        #expect(!MacSyncEngine.writeRejectedTransactionIfAbsent(record, in: root))
        #expect(try Data(contentsOf: file) == before)
        let unreadable = Data("unreadable ledger fixture".utf8)
        try unreadable.write(to: file)
        #expect(!MacSyncEngine.writeRejectedTransactionIfAbsent(record, in: root))
        #expect(try Data(contentsOf: file) == unreadable)
    }

    private func action(messageID: String, transactionID: String?) -> InboxAction {
        InboxAction(
            msgId: messageID,
            clientId: "ios",
            action: "getStatus",
            payload: [:],
            createdAt: ISO8601DateFormatter().string(from: Date()),
            protocolVersion: 1,
            transactionId: transactionID,
            signature: nil
        )
    }

    @Test func canonicalUUIDsProduceChildrenOfTheOwnedDirectory() {
        let messageID = UUID().uuidString
        let transactionID = UUID().uuidString
        let ids = InboxActionFileBoundary.validatedIDs(
            for: action(messageID: messageID, transactionID: transactionID)
        )
        #expect(ids == ValidatedInboxActionIDs(
            messageID: messageID,
            transactionID: transactionID
        ))

        let directory = URL(fileURLWithPath: "/tmp/nativeagent-owned", isDirectory: true)
        let url = InboxActionFileBoundary.jsonURL(
            in: directory,
            validatedID: transactionID
        )
        #expect(url?.deletingLastPathComponent() == directory.standardizedFileURL)
        #expect(url?.lastPathComponent == "\(transactionID).json")
    }

    @Test func traversalAndNonUUIDIdentifiersAreRejectedBeforePathDerivation() {
        for value in ["../../escape", "../outside", "/tmp/absolute", "", "not-a-uuid"] {
            #expect(InboxActionFileBoundary.validatedIDs(
                for: action(messageID: value, transactionID: UUID().uuidString)
            ) == nil)
            #expect(InboxActionFileBoundary.validatedIDs(
                for: action(messageID: UUID().uuidString, transactionID: value)
            ) == nil)
            #expect(InboxActionFileBoundary.jsonURL(
                in: URL(fileURLWithPath: "/tmp/nativeagent-owned", isDirectory: true),
                validatedID: value
            ) == nil)
        }
    }
}
