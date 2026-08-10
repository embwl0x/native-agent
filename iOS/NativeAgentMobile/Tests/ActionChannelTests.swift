// R27 (2026-07-02): first coverage for the iOS→Mac action channel — the
// HMAC-signed envelope write, response verification (signature / msgId /
// action pinning), and timeout classification. This machinery carries every
// approval, mission decision, and mac-control call; before this file it had
// zero tests. Hermetic: engine dirs point at temp folders, the pairing
// secret is injected, and the HMAC oracle below is computed INDEPENDENTLY
// of the production hmacHex so canonicalization drift fails loudly.
import CryptoKit
import NativeAgentShared
import XCTest
@testable import NativeAgentMobile

@MainActor
final class ActionChannelTests: XCTestCase {
    private var engine: iCloudSyncEngine!
    private var tempRoot: URL!
    private var savedInboxDir: URL?
    private var savedResponsesDir: URL?
    private var savedTransactionDir: URL?
    private var savedPairingStore: PairingStore?
    private var savedSyncError: String?
    private var savedTransactionWriteTimeoutSeconds: TimeInterval = 0
    private var savedTransactionWriteTestHook: (@Sendable (_ state: String) throws -> Void)?
    private var pairing: PairingStore!
    private var priorKeychainSecret: Data?
    private let secret = Data("r27-test-secret".utf8)

    override func setUp() async throws {
        try await super.setUp()
        engine = iCloudSyncEngine.shared
        savedInboxDir = engine.inboxDir
        savedResponsesDir = engine.responsesDir
        savedTransactionDir = engine.transactionDir
        savedPairingStore = engine.pairingStore
        savedSyncError = engine.syncError
        savedTransactionWriteTimeoutSeconds = engine.transactionWriteTimeoutSeconds
        savedTransactionWriteTestHook = engine.transactionWriteTestHook

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("action-channel-tests-\(UUID().uuidString)", isDirectory: true)
        for sub in ["inbox", "responses", "transactions"] {
            try FileManager.default.createDirectory(
                at: tempRoot.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        engine.inboxDir = tempRoot.appendingPathComponent("inbox", isDirectory: true)
        engine.responsesDir = tempRoot.appendingPathComponent("responses", isDirectory: true)
        engine.transactionDir = tempRoot.appendingPathComponent("transactions", isDirectory: true)

        pairing = PairingStore()
        // Review fix (2026-07-02): the didSet persists to the REAL simulator
        // keychain — capture whatever was there (PairingStore's init loads
        // it) so tearDown can RESTORE rather than blind-delete, and pin the
        // injected value immediately so a KVS-bootstrap race surfaces as a
        // loud failure here instead of a mystery downstream.
        priorKeychainSecret = pairing.iCloudPairingSecret
        pairing.iCloudPairingSecret = secret
        XCTAssertEqual(pairing.iCloudPairingSecret, secret, "injected pairing secret did not take")
        engine.pairingStore = pairing
        engine.syncError = nil
        engine.transactionWriteTimeoutSeconds = 2
        engine.transactionWriteTestHook = nil
    }

    override func tearDown() async throws {
        // Restore the pre-test keychain secret (nil deletes), then restore
        // the engine's real wiring so other suites see untouched state.
        pairing.iCloudPairingSecret = priorKeychainSecret
        engine.inboxDir = savedInboxDir
        engine.responsesDir = savedResponsesDir
        engine.transactionDir = savedTransactionDir
        engine.pairingStore = savedPairingStore
        engine.syncError = savedSyncError
        engine.transactionWriteTimeoutSeconds = savedTransactionWriteTimeoutSeconds
        engine.transactionWriteTestHook = savedTransactionWriteTestHook
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try await super.tearDown()
    }

    // MARK: - Independent HMAC oracle (deliberately NOT the production hmacHex)

    private func oracleSignature(_ body: [String: Any]) throws -> String {
        var forSigning = body
        forSigning.removeValue(forKey: "signature")
        let canonical = try JSONSerialization.data(withJSONObject: forSigning, options: [.sortedKeys])
        let mac = HMAC<SHA256>.authenticationCode(for: canonical, using: SymmetricKey(data: secret))
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    /// Poll-with-deadline (hangproof convention — no blind sleeps).
    private func waitForFile(_ url: URL, deadline: TimeInterval = 5) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func sendIsInFlight() -> Bool {
        engine._sendLock.lock()
        defer { engine._sendLock.unlock() }
        return engine._sendInFlight
    }

    private func writeResponse(_ fields: [String: String], as filename: String, sign: Bool = true, tamper: Bool = false) throws {
        var body = fields
        if sign {
            var sig = try oracleSignature(fields)
            if tamper { sig = String(sig.reversed()) }
            body["signature"] = sig
        }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        try data.write(to: engine.responsesDir!.appendingPathComponent(filename), options: .atomic)
    }

    // MARK: - sendAction

    func test_sendAction_writesEnvelope_withValidSignature_andAllFields() async throws {
        let action = InboxAction.make(action: "approveApproval", payload: ["id": "appr-1"])
        let msgId = try await engine.sendAction(action)
        XCTAssertEqual(msgId, action.msgId)

        let envelopeURL = engine.inboxDir!.appendingPathComponent("\(msgId).json")
        let landed = await waitForFile(envelopeURL)
        XCTAssertTrue(landed, "signed envelope never landed in the inbox dir")

        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: envelopeURL)) as? [String: Any]
        )
        XCTAssertEqual(obj["msgId"] as? String, action.msgId)
        XCTAssertEqual(obj["clientId"] as? String, "ios")
        XCTAssertEqual(obj["action"] as? String, "approveApproval")
        XCTAssertEqual(obj["payload"] as? [String: String], ["id": "appr-1"])
        XCTAssertEqual(obj["protocolVersion"] as? Int, 2)
        XCTAssertEqual(obj["transactionId"] as? String, action.transactionId)
        // createdAt is a REQUIRED wire field (Mac-side validation) — pin it
        // explicitly; the oracle alone can't catch a dropped field because
        // it signs whatever was actually written (review MED #2).
        XCTAssertEqual(obj["createdAt"] as? String, action.createdAt)
        // The signature must verify against an INDEPENDENT canonicalization —
        // this is the cross-device contract with MacSyncEngine's validator.
        let signature = try XCTUnwrap(obj["signature"] as? String)
        XCTAssertEqual(signature, try oracleSignature(obj))
    }

    func test_sendAction_withoutPairingSecret_throwsNotSigned_andWritesNothing() async throws {
        pairing.iCloudPairingSecret = nil
        let action = InboxAction.make(action: "approveApproval", payload: [:])
        do {
            _ = try await engine.sendAction(action)
            XCTFail("expected SyncError.notSigned")
        } catch SyncError.notSigned {
            // expected — and the specific pairing guidance must be user-visible,
            // not just any stale error (review LOW #3)
            XCTAssertTrue(
                engine.syncError?.contains("pairing key not configured") == true,
                "expected pairing guidance, got: \(engine.syncError ?? "nil")"
            )
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: engine.inboxDir!.path)
        XCTAssertTrue(contents.isEmpty, "unsigned action must never reach the inbox")
    }

    func test_sendAction_recordsSentTransaction() async throws {
        let action = InboxAction.make(action: "submitWorkshopTask", payload: ["title": "t"])
        _ = try await engine.sendAction(action)
        let txURL = engine.transactionDir!
            .appendingPathComponent("\(action.transactionId ?? action.msgId).json")
        // sendAction is not allowed to return before the exact terminal receipt
        // is coordinated, synchronized, and read-back verified.
        let sent = try JSONDecoder().decode(
            ICloudTransactionRecord.self,
            from: Data(contentsOf: txURL)
        )
        XCTAssertEqual(sent.state, "sent")
        XCTAssertEqual(sent.action, "submitWorkshopTask")
        XCTAssertEqual(sent.direction, "ios_to_mac")
        XCTAssertFalse(sendIsInFlight())
    }

    func test_unpinChatSessionWritesSignedExactMutationAndRequiresMacReceipt() async throws {
        let call = Task { @MainActor in
            try await engine.unpinChatSession(sessionId: "pin-session-1")
        }

        let deadline = Date().addingTimeInterval(5)
        var envelopeURL: URL?
        while Date() < deadline, envelopeURL == nil {
            envelopeURL = try FileManager.default
                .contentsOfDirectory(at: engine.inboxDir!, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "json" })
            if envelopeURL == nil {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        let url = try XCTUnwrap(envelopeURL)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(object["action"] as? String, "unpinChatSession")
        XCTAssertEqual(object["payload"] as? [String: String], ["sessionId": "pin-session-1"])
        XCTAssertEqual(try XCTUnwrap(object["signature"] as? String), try oracleSignature(object))

        let msgID = try XCTUnwrap(object["msgId"] as? String)
        try writeResponse(
            [
                "msgId": msgID,
                "action": "unpinChatSession",
                "status": "ok",
                "ok": "true",
                "applied": "true",
            ],
            as: "\(msgID).json"
        )
        let result = try await call.value
        XCTAssertEqual(result, "ok")
    }

    func test_notificationReceiptWritesSignedPayloadFreeAction() async throws {
        let eventID = String(repeating: "a", count: 64)
        await engine.sendNotificationReceipt(eventID: eventID, channel: "apns")

        let files = try FileManager.default.contentsOfDirectory(
            at: engine.inboxDir!,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let envelopeURL = try XCTUnwrap(files.first)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: envelopeURL)) as? [String: Any]
        )
        XCTAssertEqual(object["action"] as? String, "recordNotificationReceipt")
        XCTAssertEqual(
            object["payload"] as? [String: String],
            ["eventId": eventID, "channel": "apns"]
        )
        XCTAssertEqual(try XCTUnwrap(object["signature"] as? String), try oracleSignature(object))
    }

    func test_notificationReceiptRejectsNonCanonicalEventWithoutWriting() async throws {
        await engine.sendNotificationReceipt(eventID: "not-canonical", channel: "apns")
        let contents = try FileManager.default.contentsOfDirectory(atPath: engine.inboxDir!.path)
        XCTAssertTrue(contents.isEmpty)
    }

    func test_sendAction_sentReceiptCoordinationFailureThrowsAndReleasesOwnership() async throws {
        engine.transactionWriteTestHook = { state in
            guard state == "sent" else { return }
            throw NSError(
                domain: "ActionChannelTests",
                code: 91,
                userInfo: [NSLocalizedDescriptionKey: "simulated coordination failure"]
            )
        }
        let action = InboxAction.make(action: "approveApproval", payload: ["approvalId": "appr-fail"])

        do {
            _ = try await engine.sendAction(action)
            XCTFail("expected transaction persistence failure")
        } catch SyncError.persistence(let message) {
            XCTAssertTrue(message.contains("simulated coordination failure"), message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertFalse(sendIsInFlight(), "failed transaction write must release send ownership")
        let envelopeURL = engine.inboxDir!.appendingPathComponent("\(action.msgId).json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: envelopeURL.path),
            "the test must fail only after the signed envelope has landed"
        )
        let transactionURL = engine.transactionDir!
            .appendingPathComponent("\(action.transactionId ?? action.msgId).json")
        let transaction = try JSONDecoder().decode(
            ICloudTransactionRecord.self,
            from: Data(contentsOf: transactionURL)
        )
        XCTAssertEqual(transaction.state, "queued", "failed sent receipt must never be reported as terminal success")
    }

    func test_terminalSendFailureNeverSwallowsLedgerPersistenceFailure() async throws {
        engine.transactionWriteTestHook = { state in
            guard state == "send_failed" else { return }
            throw NSError(
                domain: "ActionChannelTests",
                code: 92,
                userInfo: [NSLocalizedDescriptionKey: "terminal ledger unavailable"]
            )
        }
        let transportError = NSError(
            domain: "ActionChannelTests",
            code: 93,
            userInfo: [NSLocalizedDescriptionKey: "CloudKit transport unavailable"]
        )

        do {
            try await engine.persistTerminalSendFailure(
                transactionID: UUID().uuidString,
                action: "approveApproval",
                sendError: transportError
            )
            XCTFail("expected the unpersisted terminal receipt to fail closed")
        } catch SyncError.persistence(let message) {
            XCTAssertTrue(message.contains("CloudKit transport unavailable"), message)
            XCTAssertTrue(message.contains("terminal ledger unavailable"), message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_sendAction_transactionTimeoutReleasesOwnershipAndNextSendCanSucceed() async throws {
        let releaseStalledWrite = DispatchSemaphore(value: 0)
        defer { releaseStalledWrite.signal() }
        engine.transactionWriteTimeoutSeconds = 0.05
        engine.transactionWriteTestHook = { state in
            guard state == "queued" else { return }
            _ = releaseStalledWrite.wait(timeout: .now() + 2)
        }
        let stalled = InboxAction.make(action: "approveApproval", payload: ["approvalId": "appr-timeout"])

        do {
            _ = try await engine.sendAction(stalled)
            XCTFail("expected transaction timeout")
        } catch SyncError.timeout(let message) {
            XCTAssertTrue(message.contains("transaction"), message)
            XCTAssertTrue(message.contains("queued"), message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertFalse(sendIsInFlight(), "timed-out transaction write must release send ownership")

        engine.transactionWriteTestHook = nil
        engine.transactionWriteTimeoutSeconds = 2

        // The original worker remains blocked here. A successful second send
        // proves there is no global serial queue left for it to wedge.
        let recovery = InboxAction.make(action: "approveApproval", payload: ["approvalId": "appr-recovery"])
        _ = try await engine.sendAction(recovery)
        XCTAssertFalse(sendIsInFlight())
        let recoveryURL = engine.transactionDir!
            .appendingPathComponent("\(recovery.transactionId ?? recovery.msgId).json")
        let recoveryRecord = try JSONDecoder().decode(
            ICloudTransactionRecord.self,
            from: Data(contentsOf: recoveryURL)
        )
        XCTAssertEqual(recoveryRecord.state, "sent")
    }

    // MARK: - pollResponse verification

    func test_cloudKitActionResponse_persistsIntoExistingVerifiedMailbox() async throws {
        let msgId = UUID().uuidString
        var response = [
            "msgId": msgId,
            "action": "approveApproval",
            "status": "ok",
        ]
        response["signature"] = try oracleSignature(response)
        let data = try JSONEncoder().encode(response)
        let persisted = await engine.persistCloudKitActionResponse(
            String(decoding: data, as: UTF8.self),
            actionID: msgId
        )

        XCTAssertTrue(persisted)
        let verified = await engine.pollResponse(
            msgId: msgId,
            expectedAction: "approveApproval"
        )
        XCTAssertEqual(verified?["status"], "ok")
    }

    func test_cloudKitActionResponse_rejectsNonCanonicalActionID() async {
        let persisted = await engine.persistCloudKitActionResponse(
            #"{"status":"ok"}"#,
            actionID: "../escape"
        )

        XCTAssertFalse(persisted)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempRoot.appendingPathComponent("escape.json").path
            )
        )
    }

    func test_pollResponse_verifiedResponse_returnsFieldsWithoutSignature() async throws {
        let msgId = UUID().uuidString
        try writeResponse(
            ["msgId": msgId, "action": "approveApproval", "status": "ok"],
            as: "\(msgId).json"
        )
        let verified = await engine.pollResponse(msgId: msgId, expectedAction: "approveApproval")
        XCTAssertEqual(verified?["status"], "ok")
        XCTAssertEqual(verified?["msgId"], msgId)
        XCTAssertNil(verified?["signature"], "signature must be stripped from the verified dict")
    }

    func test_pollResponse_missingFile_returnsNilQuietly() async throws {
        let verified = await engine.pollResponse(msgId: UUID().uuidString)
        XCTAssertNil(verified)
    }

    func test_pollResponse_tamperedSignature_rejected() async throws {
        let msgId = UUID().uuidString
        try writeResponse(
            ["msgId": msgId, "action": "approveApproval", "status": "ok"],
            as: "\(msgId).json", tamper: true
        )
        let verified = await engine.pollResponse(msgId: msgId)
        XCTAssertNil(verified, "tampered response must be rejected")
        XCTAssertTrue(engine.syncError?.contains("signature mismatch") == true)
    }

    func test_pollResponse_unsignedResponse_rejected() async throws {
        let msgId = UUID().uuidString
        try writeResponse(
            ["msgId": msgId, "action": "approveApproval", "status": "ok"],
            as: "\(msgId).json", sign: false
        )
        let verified = await engine.pollResponse(msgId: msgId)
        XCTAssertNil(verified, "unsigned response must be rejected")
        XCTAssertTrue(engine.syncError?.contains("Unsigned") == true)
    }

    func test_pollResponse_msgIdMismatch_rejectedAsReplay() async throws {
        let polled = UUID().uuidString
        // Signed VALIDLY but carrying a different msgId — a stale/replayed
        // response dropped under the polled name must not verify.
        try writeResponse(
            ["msgId": "some-other-msg", "action": "approveApproval", "status": "ok"],
            as: "\(polled).json"
        )
        let verified = await engine.pollResponse(msgId: polled)
        XCTAssertNil(verified)
        XCTAssertTrue(engine.syncError?.contains("msgId mismatch") == true)
    }

    func test_pollResponse_actionMismatch_rejectedAsStale() async throws {
        let msgId = UUID().uuidString
        try writeResponse(
            ["msgId": msgId, "action": "rejectApproval", "status": "ok"],
            as: "\(msgId).json"
        )
        let verified = await engine.pollResponse(msgId: msgId, expectedAction: "approveApproval")
        XCTAssertNil(verified)
        XCTAssertTrue(engine.syncError?.contains("action mismatch") == true)
    }

    func test_successfulMutationBoundary_rejectsExplicitAppliedFalse() {
        XCTAssertThrowsError(
            try engine.requireSuccessfulActionResponse([
                "ok": "true",
                "status": "ok",
                "applied": "false",
                "message": "candidate was not changed",
            ])
        ) { error in
            guard case SyncError.unsupported(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(message, "candidate was not changed")
        }
    }

    func test_successfulMutationBoundary_acceptsExplicitAppliedTrue() throws {
        let response = try engine.requireSuccessfulActionResponse([
            "ok": "true",
            "status": "ok",
            "applied": "true",
        ])
        XCTAssertEqual(response["applied"], "true")
    }

    // MARK: - Timeout classification

    func test_isMacResponseTimeout_classification() {
        XCTAssertTrue(
            iCloudSyncEngine.isMacResponseTimeout(
                SyncError.timeout("Timed out waiting for Mac response to msg-1")
            )
        )
        XCTAssertFalse(
            iCloudSyncEngine.isMacResponseTimeout(
                SyncError.timeout("iCloud sendAction timed out after 30s")
            )
        )
        XCTAssertFalse(iCloudSyncEngine.isMacResponseTimeout(SyncError.notSigned))
        XCTAssertFalse(
            iCloudSyncEngine.isMacResponseTimeout(
                NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "waiting for Mac response"])
            )
        )
    }
}
