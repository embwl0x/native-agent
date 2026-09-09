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

    /// Wait for the *production* iOS action writer to commit an inbox envelope.
    /// The test then plays the paired Mac by writing the independently HMAC'd
    /// response into the durable response mailbox.  This is intentionally a
    /// full iPhone -> iCloud mailbox -> Mac response round-trip, not a direct
    /// call to `requireSuccessfulActionResponse` or an envelope fixture.
    private func nextSignedEnvelope(deadline: TimeInterval = 5) async throws -> [String: Any] {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            let files = try FileManager.default.contentsOfDirectory(
                at: engine.inboxDir!,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
            if let url = files.first {
                let object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
                )
                XCTAssertEqual(
                    try XCTUnwrap(object["signature"] as? String),
                    try oracleSignature(object),
                    "the Mac simulation must receive the same signed body production sends"
                )
                return object
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for the signed iOS action envelope")
        throw SyncError.timeout("test did not observe a signed action envelope")
    }

    private func clearInbox() throws {
        for url in try FileManager.default.contentsOfDirectory(
            at: engine.inboxDir!,
            includingPropertiesForKeys: nil
        ) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func successfulMacResponse(for envelope: [String: Any], result: String = "Mac committed", canonicalFields: [String: String] = [:]) throws {
        let msgID = try XCTUnwrap(envelope["msgId"] as? String)
        let action = try XCTUnwrap(envelope["action"] as? String)
        let transactionID = try XCTUnwrap(envelope["transactionId"] as? String)
        try writeResponse(
            [
                "msgId": msgID,
                "action": action,
                "transactionId": transactionID,
                "status": "completed",
                "ok": "true",
                "applied": "true",
                "result": result,
            ].merging(canonicalFields, uniquingKeysWith: { _, canonical in canonical }),
            as: "\(msgID).json"
        )
    }

    private func assertTerminalTransaction(
        for envelope: [String: Any],
        expectedAction: String,
        expectedState: String = "completed"
    ) throws {
        let transactionID = try XCTUnwrap(envelope["transactionId"] as? String)
        let record = try JSONDecoder().decode(
            ICloudTransactionRecord.self,
            from: Data(contentsOf: engine.transactionDir!.appendingPathComponent("\(transactionID).json"))
        )
        XCTAssertEqual(record.action, expectedAction)
        XCTAssertEqual(record.state, expectedState)
        XCTAssertEqual(record.direction, "ios_to_mac")
    }

    private func assertStringActionRoundTrip(
        action expectedAction: String,
        payload expectedPayload: [String: String],
        operation: @escaping @MainActor () async throws -> String
    ) async throws {
        try clearInbox()
        let call = Task { @MainActor in try await operation() }
        let envelope = try await nextSignedEnvelope()
        XCTAssertEqual(envelope["action"] as? String, expectedAction)
        XCTAssertEqual(envelope["payload"] as? [String: String], expectedPayload)
        try successfulMacResponse(for: envelope, result: "committed-\(expectedAction)")
        let result = try await call.value
        XCTAssertEqual(result, "committed-\(expectedAction)")
        try assertTerminalTransaction(for: envelope, expectedAction: expectedAction)
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
                engine.syncError?.contains("Pair with Mac on this phone and tap Check for Mac") == true,
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
            // `direction` is not decoration: the Mac router rejects a receipt
            // without it, so a payload that loses this key silently kills the
            // whole delivery-confirmation lane again.
            ["eventId": eventID, "channel": "apns", "direction": "mac_to_ios"]
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

    /// A durably-arrived response that `pollResponse` keeps REJECTING (bad
    /// signature, undecodable body, unpersistable receipt) used to busy-spin
    /// the main actor for the entire timeout — up to 300s on a decision
    /// action — because `wait` returns immediately once an arrival is
    /// recorded, so the loop paid no interval between retries.
    func test_pollWithTimeout_rejectedArrivalPacesRetriesInsteadOfSpinning() async throws {
        let msgId = UUID().uuidString
        try writeResponse(
            ["msgId": msgId, "action": "approveApproval", "status": "ok"],
            as: "\(msgId).json"
        )
        // Verifies, then fails to persist its receipt on every pass: each poll
        // returns nil, and the hook counts the passes.
        let passes = _PassCounter()
        engine.transactionWriteTestHook = { _ in
            passes.increment()
            throw SyncError.persistence("receipt write refused by test")
        }

        async let polled = engine.pollWithTimeout(
            msgId: msgId,
            timeout: 1,
            interval: 0.25,
            expectedAction: "approveApproval"
        )
        // Let the poll arm its waiter, then play the push that says the
        // response is durable locally.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        ActionResponseWaiters.shared.signal(msgId)
        let result = await polled

        XCTAssertNil(result, "a response whose receipt cannot persist is not a verified response")
        XCTAssertGreaterThanOrEqual(passes.value, 1, "the response must actually have been polled")
        XCTAssertLessThanOrEqual(
            passes.value, 8,
            "a rejected arrival must still pay the poll interval, not spin the main actor"
        )
    }

    private final class _PassCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
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

    // MARK: - Wave 4 durable iPhone <-> Mac action decisions
    //
    // Coverage-ledger rows exercised by real signed mailbox round trips:
    // ios.sync.remoteActions.deskAndWorkshop
    // ios.sync.remoteActions.macControl
    // ios.macIntegrationPermissions.defaultTable
    // ios.bridgeStatus / ios.macBridgeClient.bridgeStatus
    //
    // Each test starts at the public iOS helper, inspects the HMAC-protected
    // verb/payload the Mac actually receives, writes a separately-signed Mac
    // response, and requires the transaction ledger to reach its terminal
    // state.  The negative cases prove that pending/refused/replayed evidence
    // cannot turn an uncommitted Mac action into a completed phone action.

    func test_deskActionsRoundTripWithExactMacVocabularyAndDurableReceipts() async throws {
        let create = Task { @MainActor in
            try await self.engine.createDeskItem(
                kind: "task", project: "NativeAgent", title: "Review sync", summary: "Real mailbox proof"
            )
        }
        let createEnvelope = try await nextSignedEnvelope()
        XCTAssertEqual(createEnvelope["action"] as? String, "createDeskItem")
        XCTAssertEqual(
            createEnvelope["payload"] as? [String: String],
            ["kind": "task", "project": "NativeAgent", "title": "Review sync", "summary": "Real mailbox proof"]
        )
        try successfulMacResponse(for: createEnvelope, result: "desk-42")
        let createResponse = try await create.value
        XCTAssertEqual(createResponse?["result"], "desk-42")
        try assertTerminalTransaction(for: createEnvelope, expectedAction: "createDeskItem")

        try clearInbox()
        let status = Task { @MainActor in
            try await self.engine.setDeskItemStatus(handle: "desk-42", status: "blocked")
        }
        let statusEnvelope = try await nextSignedEnvelope()
        XCTAssertEqual(statusEnvelope["action"] as? String, "setDeskItemStatus")
        XCTAssertEqual(statusEnvelope["payload"] as? [String: String], ["handle": "desk-42", "status": "blocked"])
        try successfulMacResponse(for: statusEnvelope)
        let statusResponse = try await status.value
        XCTAssertEqual(statusResponse?["status"], "completed")
        try assertTerminalTransaction(for: statusEnvelope, expectedAction: "setDeskItemStatus")

        // The Mac dispatcher accepts six distinct Desk/Workshop vocabularies;
        // pin the remaining three successful verbs here while the approval
        // branch below covers `approveStep`'s nonterminal outcome.
        try await assertStringActionRoundTrip(
            action: "appendDeskItemNote",
            payload: ["handle": "desk-42", "text": "Waiting on the owner"]
        ) { [self] in
            let response = try await engine.appendDeskItemNote(handle: "desk-42", text: "Waiting on the owner")
            return response?["result"] ?? ""
        }
        try await assertStringActionRoundTrip(
            action: "submitWorkshopTask",
            payload: ["title": "Reconcile", "objective": "Prove iCloud action semantics"]
        ) { [self] in
            try await engine.submitWorkshopTask(title: "Reconcile", objective: "Prove iCloud action semantics")
        }
        try await assertStringActionRoundTrip(
            action: "rejectStep",
            payload: ["missionId": "execution-9", "stepId": "step-3"]
        ) { [self] in
            let response = try await engine.rejectStep(executionId: "execution-9", stepId: "step-3")
            return response?["result"] ?? ""
        }
    }

    func test_workshopDecisionRoundTripPreservesApprovalRequiredInsteadOfFakingSuccess() async throws {
        let task = Task { @MainActor in
            try await self.engine.approveStep(executionId: "execution-9", stepId: "step-3")
        }
        let envelope = try await nextSignedEnvelope()
        XCTAssertEqual(envelope["action"] as? String, "approveStep")
        XCTAssertEqual(envelope["payload"] as? [String: String], ["missionId": "execution-9", "stepId": "step-3"])
        let msgID = try XCTUnwrap(envelope["msgId"] as? String)
        let transactionID = try XCTUnwrap(envelope["transactionId"] as? String)
        try writeResponse(
            [
                "msgId": msgID,
                "action": "approveStep",
                "transactionId": transactionID,
                "status": "pending_approval",
                "ok": "true",
                "message": "Review this step on the Mac",
            ],
            as: "\(msgID).json"
        )

        do {
            _ = try await task.value
            XCTFail("a pending Mac approval must not become a completed workshop decision")
        } catch SyncError.approvalRequired(let message) {
            XCTAssertEqual(message, "Review this step on the Mac")
        }
        try assertTerminalTransaction(for: envelope, expectedAction: "approveStep", expectedState: "pending_approval")
    }

    func test_macControlDecisionTableReturnsOnlyCommittedResultAndPreservesRefusal() async throws {
        let success = Task { @MainActor in
            try await self.engine.macReadFile(path: "/workspace/README.md", maxBytes: 4096)
        }
        let successEnvelope = try await nextSignedEnvelope()
        XCTAssertEqual(successEnvelope["action"] as? String, "mac_control")
        XCTAssertEqual(
            successEnvelope["payload"] as? [String: String],
            ["method": "readFile", "path": "/workspace/README.md", "max_bytes": "4096"]
        )
        try successfulMacResponse(for: successEnvelope, result: "contents")
        let successResult = try await success.value
        XCTAssertEqual(successResult, "contents")
        try assertTerminalTransaction(for: successEnvelope, expectedAction: "mac_control")

        try clearInbox()
        let refusal = Task { @MainActor in
            try await self.engine.macRunShell(command: "echo should-not-run")
        }
        let refusalEnvelope = try await nextSignedEnvelope()
        let refusalID = try XCTUnwrap(refusalEnvelope["msgId"] as? String)
        let refusalTransactionID = try XCTUnwrap(refusalEnvelope["transactionId"] as? String)
        try writeResponse(
            [
                "msgId": refusalID,
                "action": "mac_control",
                "transactionId": refusalTransactionID,
                "status": "failed",
                "ok": "false",
                "blocked": "true",
                "message": "Shell control is disabled on this Mac.",
            ],
            as: "\(refusalID).json"
        )
        do {
            _ = try await refusal.value
            XCTFail("a refused Mac control response must never return a result")
        } catch SyncError.unsupported(let message) {
            XCTAssertEqual(message, "Shell control is disabled on this Mac.")
        }
        try assertTerminalTransaction(for: refusalEnvelope, expectedAction: "mac_control", expectedState: "failed")

        // A failed response without the optional `blocked` bit is still a
        // refusal, and an approval wait is never a completed Mac result.
        try clearInbox()
        let failed = Task { @MainActor in try await self.engine.macNotify(title: "T", message: "M") }
        let failedEnvelope = try await nextSignedEnvelope()
        let failedID = try XCTUnwrap(failedEnvelope["msgId"] as? String)
        try writeResponse([
            "msgId": failedID, "action": "mac_control",
            "transactionId": try XCTUnwrap(failedEnvelope["transactionId"] as? String),
            "status": "error", "ok": "false", "message": "Mac notification failed.",
        ], as: "\(failedID).json")
        do {
            _ = try await failed.value
            XCTFail("a failed Mac action without blocked=true must still throw")
        } catch SyncError.unsupported(let message) {
            XCTAssertEqual(message, "Mac notification failed.")
        }
        try assertTerminalTransaction(for: failedEnvelope, expectedAction: "mac_control", expectedState: "failed")

        try clearInbox()
        let pending = Task { @MainActor in try await self.engine.macLockScreen() }
        let pendingEnvelope = try await nextSignedEnvelope()
        let pendingID = try XCTUnwrap(pendingEnvelope["msgId"] as? String)
        try writeResponse([
            "msgId": pendingID, "action": "mac_control",
            "transactionId": try XCTUnwrap(pendingEnvelope["transactionId"] as? String),
            "status": "pending_approval", "ok": "true", "message": "Approve lock screen on the Mac.",
        ], as: "\(pendingID).json")
        do {
            _ = try await pending.value
            XCTFail("a pending approval cannot be represented as a finished Mac action")
        } catch SyncError.approvalRequired(let message) {
            XCTAssertEqual(message, "Approve lock screen on the Mac.")
        }
        try assertTerminalTransaction(for: pendingEnvelope, expectedAction: "mac_control", expectedState: "pending_approval")
    }

    func test_providerControlRejectsSecretBeforePersistenceAndCommitsFullSelectionTuple() async throws {
        let sentinel = "never-leave-this-phone"
        do {
            _ = try await engine.configureProvider(providerId: "openai", apiKey: sentinel)
            XCTFail("provider API keys must not enter the iCloud action channel")
        } catch SyncError.unsupported(let message) {
            XCTAssertTrue(message.contains("cannot be sent through iCloud"))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: engine.inboxDir!.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: engine.transactionDir!.path).isEmpty)
        XCTAssertFalse(engine.syncError?.contains(sentinel) == true)

        // A non-secret sentinel must survive the signed wire contract, while
        // the durable receipt remains an action/outcome record rather than a
        // second store for provider configuration material.
        let configure = Task { @MainActor in
            try await self.engine.configureProvider(
                providerId: "provider-\(sentinel)", authMode: "oauth-\(sentinel)"
            )
        }
        let configureEnvelope = try await nextSignedEnvelope()
        XCTAssertEqual(configureEnvelope["action"] as? String, "configure_provider")
        XCTAssertEqual(
            configureEnvelope["payload"] as? [String: String],
            ["providerId": "provider-\(sentinel)", "auth_mode": "oauth-\(sentinel)"]
        )
        try successfulMacResponse(for: configureEnvelope, result: "provider-configured")
        let configured = try await configure.value
        XCTAssertEqual(configured, "provider-configured")
        let configureTransactionID = try XCTUnwrap(configureEnvelope["transactionId"] as? String)
        let ledgerBytes = try Data(contentsOf: engine.transactionDir!.appendingPathComponent("\(configureTransactionID).json"))
        XCTAssertFalse(String(decoding: ledgerBytes, as: UTF8.self).contains(sentinel))
        XCTAssertFalse(engine.syncError?.contains(sentinel) == true)
        try clearInbox()

        let selection = Task { @MainActor in
            try await self.engine.configureSurfaceSelection(
                surface: "ios", providerId: "openai_oauth_direct", model: "gpt-5.6-sol",
                reasoningEffort: "high", serviceTier: "priority"
            )
        }
        let envelope = try await nextSignedEnvelope()
        XCTAssertEqual(envelope["action"] as? String, "configure_surface_selection")
        XCTAssertEqual(
            envelope["payload"] as? [String: String],
            [
                "surface": "ios", "provider_id": "openai_oauth_direct", "model": "gpt-5.6-sol",
                "reasoning_effort": "high", "service_tier": "priority",
            ]
        )
        try successfulMacResponse(for: envelope, canonicalFields: [
            "surface": "ios", "provider_id": "openai_oauth_direct", "model": "gpt-5.6-terra",
            "reasoning_effort": "low", "service_tier": "default",
        ])
        let selectionResult = try await selection.value
        XCTAssertEqual(selectionResult.model, "gpt-5.6-terra")
        XCTAssertEqual(selectionResult.reasoningEffort, "low")
        XCTAssertEqual(selectionResult.serviceTier, "default")
        let suite = "NativeAgentMobileTests.signed-selection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(7, forKey: ChatRuntimeControlPresentation.generationDefaultsKey)
        let adopted = try XCTUnwrap(ChatRuntimeControlPresentation.acceptReceipt(
            selectionResult, defaults: defaults, requestGeneration: 7
        ))
        XCTAssertEqual(adopted.providerID, "openai_oauth_direct")
        XCTAssertEqual(adopted.model, "gpt-5.6-terra")
        XCTAssertEqual(adopted.reasoningEffort, "low")
        XCTAssertFalse(adopted.fastMode)
        XCTAssertEqual(defaults.string(forKey: ChatRuntimeControlPresentation.modelDefaultsKey), "gpt-5.6-terra")
        let acknowledged = ChatSurfaceModelPreferenceAdoption.resolve(
            current: .init(providerID: adopted.providerID, model: adopted.model, reasoningEffort: adopted.reasoningEffort, fastMode: adopted.fastMode),
            preference: .init(model: "gpt-5.6-terra", reasoningEffort: "low", serviceTier: "default", providerId: "openai_oauth_direct"),
            awaitingAcknowledgement: true, selectableProviderIDs: ["openai_oauth_direct"]
        )
        XCTAssertFalse(acknowledged.awaitingAcknowledgement)
        try assertTerminalTransaction(for: envelope, expectedAction: "configure_surface_selection")

        try await assertStringActionRoundTrip(
            action: "clear_provider", payload: ["providerId": "openai_oauth_direct"]
        ) { [self] in try await engine.clearProvider(providerId: "openai_oauth_direct") }
        try await assertStringActionRoundTrip(
            action: "set_active_provider", payload: ["surface": "ios", "provider_id": "openai_oauth_direct"]
        ) { [self] in try await engine.setActiveProvider(surface: "ios", providerId: "openai_oauth_direct") }
        try await assertStringActionRoundTrip(
            action: "set_surface_model",
            payload: ["surface": "ios", "model": "gpt-5.6-sol", "reasoning_effort": "high", "service_tier": "priority"]
        ) { [self] in
            try await engine.setSurfaceModel(
                surface: "ios", model: "gpt-5.6-sol", reasoningEffort: "high", serviceTier: "priority"
            )
        }
    }

    func test_successfulSignedSelectionWithoutCanonicalTupleIsNotAnAdoptableReceipt() async throws {
        let selection = Task { @MainActor in
            try await self.engine.configureSurfaceSelection(
                surface: "ios", providerId: "openai_oauth_direct", model: "gpt-5.6-sol",
                reasoningEffort: "high", serviceTier: "priority"
            )
        }
        let envelope = try await nextSignedEnvelope()
        try successfulMacResponse(for: envelope, canonicalFields: [
            "surface": "ios", "provider_id": "openai_oauth_direct", "model": "gpt-5.6-sol",
            "service_tier": "priority",
        ])
        do {
            _ = try await selection.value
            XCTFail("An incomplete signed success cannot invent canonical reasoning state")
        } catch SyncError.persistence(let message) {
            XCTAssertTrue(message.contains("reasoning_effort"))
        }
        // The action transport really completed; only picker-state proof is
        // incomplete. Do not rewrite its durable terminal outcome or replay it.
        try assertTerminalTransaction(for: envelope, expectedAction: "configure_surface_selection")
    }

    func test_signatureRecoveryUsesNewActionIdentityAndLeavesBothDurableReceipts() async throws {
        let operation = Task { @MainActor in
            try await self.engine.testProvider(providerId: "openai_oauth_direct")
        }
        let first = try await nextSignedEnvelope()
        let firstID = try XCTUnwrap(first["msgId"] as? String)
        let firstTransactionID = try XCTUnwrap(first["transactionId"] as? String)
        try writeResponse(
            [
                "msgId": firstID,
                "action": "test_provider",
                "transactionId": firstTransactionID,
                "status": "failed",
                "ok": "false",
                "code": "signature_required",
                "error": "Mac requires a fresh signature",
            ],
            as: "\(firstID).json"
        )

        // The recovery attempt must be a new signed action, not a blind replay
        // of an effect whose first outcome could have been ambiguous.
        try clearInbox()
        let second = try await nextSignedEnvelope()
        let secondID = try XCTUnwrap(second["msgId"] as? String)
        XCTAssertNotEqual(secondID, firstID)
        XCTAssertEqual(second["action"] as? String, "test_provider")
        XCTAssertEqual(second["payload"] as? [String: String], ["providerId": "openai_oauth_direct"])
        try successfulMacResponse(for: second, result: "provider-ready")
        let operationResult = try await operation.value
        XCTAssertEqual(operationResult, "provider-ready")

        try assertTerminalTransaction(for: first, expectedAction: "test_provider", expectedState: "failed")
        try assertTerminalTransaction(for: second, expectedAction: "test_provider")
    }

    func test_macIntegrationResponseRequiresCanonicalMacReadBackBeforeReturningProjection() async throws {
        let operation = Task { @MainActor in
            try await self.engine.setMacIntegrationPermission(id: "calendar", read: false, write: true)
        }
        let envelope = try await nextSignedEnvelope()
        XCTAssertEqual(envelope["action"] as? String, "set_mac_integration_permission")
        XCTAssertEqual(envelope["payload"] as? [String: String], ["id": "calendar", "read": "false", "write": "true"])
        let msgID = try XCTUnwrap(envelope["msgId"] as? String)
        let transactionID = try XCTUnwrap(envelope["transactionId"] as? String)
        try writeResponse(
            [
                "msgId": msgID,
                "action": "set_mac_integration_permission",
                "transactionId": transactionID,
                "status": "completed",
                "ok": "true",
                "applied": "true",
                "read": "false",
                "write": "true",
            ],
            as: "\(msgID).json"
        )
        let projection = try await operation.value
        XCTAssertEqual(projection.read, false)
        XCTAssertEqual(projection.write, true)
        try assertTerminalTransaction(for: envelope, expectedAction: "set_mac_integration_permission")

        try clearInbox()
        let incomplete = Task { @MainActor in
            try await self.engine.setMacIntegrationPermission(id: "calendar", read: true, write: false)
        }
        let incompleteEnvelope = try await nextSignedEnvelope()
        let incompleteID = try XCTUnwrap(incompleteEnvelope["msgId"] as? String)
        try writeResponse([
            "msgId": incompleteID,
            "action": "set_mac_integration_permission",
            "transactionId": try XCTUnwrap(incompleteEnvelope["transactionId"] as? String),
            "status": "completed", "ok": "true", "applied": "true", "read": "true",
        ], as: "\(incompleteID).json")
        do {
            _ = try await incomplete.value
            XCTFail("an incomplete canonical read-back must not alter the visible projection")
        } catch SyncError.persistence(let message) {
            XCTAssertTrue(message.contains("omitted canonical write state"))
        }
        try assertTerminalTransaction(for: incompleteEnvelope, expectedAction: "set_mac_integration_permission")
    }

    func test_macIntegrationProjectionLoadsValidRowsButSurfacesMalformedAuthorityAndMatchesMacKey() throws {
        let valid = MacIntegrationPermissionsSync(
            projectionLoader: {
                ["calendar": ["read": false, "write": true]]
            },
            observesExternalChanges: false
        )
        XCTAssertNil(valid.projectionError)
        XCTAssertFalse(valid.get(id: "calendar", mode: "read"))
        XCTAssertTrue(valid.get(id: "calendar", mode: "write"))

        let malformed = MacIntegrationPermissionsSync(
            projectionLoader: {
                ["calendar": ["read": "not-a-bool"], "mail": "not-a-dictionary"]
            },
            observesExternalChanges: false
        )
        XCTAssertTrue(malformed.projectionError?.contains("calendar") == true)
        XCTAssertTrue(malformed.projectionError?.contains("mail") == true)
        XCTAssertFalse(malformed.get(id: "calendar", mode: "read"))
        XCTAssertFalse(malformed.get(id: "notes", mode: "read"), "malformed authority must fail closed instead of rendering defaults")

        let macWriter = try MobileEvalSources.repoFile("Sources/NativeAgentApp/MacIntegrationICloudBridge.swift")
        let keys = MobileEvalSources.matches(#"static let kvsKey\s*=\s*"([^"]+)""#, in: macWriter)
        XCTAssertEqual(keys, [MacIntegrationPermissionsSync.kvsKey])
    }

    func test_macIntegrationDefaultTableEnumeratesEveryMacIDWithMatchingAxes() throws {
        let expected: [String: (read: Bool, write: Bool)] = [
            "calendar": (true, false), "reminders": (true, false),
            "contacts": (true, false), "mail": (true, false),
            "messages": (true, false), "notes": (true, false),
            "music": (true, false), "notify_mac": (false, true),
            "notify_mobile": (false, true), "spotlight": (true, false),
            "scheduler": (false, true),
        ]
        let iosDefaults = MacIntegrationPermissionsSync(
            projectionLoader: { nil }, observesExternalChanges: false
        )
        for (id, axes) in expected {
            XCTAssertEqual(iosDefaults.get(id: id, mode: "read"), axes.read, "iOS read default for \(id)")
            XCTAssertEqual(iosDefaults.get(id: id, mode: "write"), axes.write, "iOS write default for \(id)")
        }

        let macAuthority = try MobileEvalSources.repoFile(
            "Modules/NativeAgentCore/Sources/MacIntegration/MacIntegrationPermissions.swift"
        )
        let macIDs = MobileEvalSources.matches(#"public static let\s+\w+\s*=\s*"([^"]+)""#, in: macAuthority)
        XCTAssertEqual(Set(macIDs), Set(expected.keys), "enumerate every MacIntegrationID.all row")
        XCTAssertTrue(macAuthority.contains("case notifyMac, notifyMobile, scheduler:\n            write = true"))
        XCTAssertTrue(macAuthority.contains("case notifyMac, notifyMobile, scheduler:\n            return false"))
        XCTAssertTrue(macAuthority.contains("case spotlight:\n            return false"))
    }

    func test_bridgeStatusDecisionTableUsesPairedMacUnreachableOnlyAfterTheExactBoundary() {
        let now = Date()
        XCTAssertEqual(
            MacBridgeClient.bridgeStatusDecision(
                bridgeAvailable: true, lastSeenAt: now.addingTimeInterval(-60),
                connectingStartedAt: nil, bridgeUnavailableSince: nil, isPaired: true, now: now
            ),
            .online
        )
        XCTAssertEqual(
            MacBridgeClient.bridgeStatusDecision(
                bridgeAvailable: true, lastSeenAt: now.addingTimeInterval(-61),
                connectingStartedAt: nil, bridgeUnavailableSince: nil, isPaired: true, now: now
            ),
            .stale(minutesAgo: 1)
        )
        XCTAssertEqual(
            MacBridgeClient.bridgeStatusDecision(
                bridgeAvailable: true, lastSeenAt: nil,
                connectingStartedAt: nil, bridgeUnavailableSince: nil, isPaired: true, now: now
            ),
            .awaitingMacActivity
        )
        XCTAssertEqual(
            MacBridgeClient.bridgeStatusDecision(
                bridgeAvailable: false, lastSeenAt: nil,
                connectingStartedAt: now.addingTimeInterval(-30), bridgeUnavailableSince: nil,
                isPaired: true, now: now
            ),
            .connecting
        )
        XCTAssertEqual(
            MacBridgeClient.bridgeStatusDecision(
                bridgeAvailable: false, lastSeenAt: nil,
                connectingStartedAt: nil, bridgeUnavailableSince: now.addingTimeInterval(-29.9),
                isPaired: true, now: now
            ),
            .offline
        )
        XCTAssertEqual(
            MacBridgeClient.bridgeStatusDecision(
                bridgeAvailable: false, lastSeenAt: nil,
                connectingStartedAt: nil, bridgeUnavailableSince: now.addingTimeInterval(-30),
                isPaired: true, now: now
            ),
            .macUnreachable
        )
        XCTAssertEqual(
            MacBridgeClient.bridgeStatusDecision(
                bridgeAvailable: false, lastSeenAt: nil,
                connectingStartedAt: nil, bridgeUnavailableSince: now.addingTimeInterval(-120),
                isPaired: false, now: now
            ),
            .offline
        )
    }

    func test_refreshBridgeStatusConsumesLiveAvailabilityPairingAndRecency() {
        let bridge = iCloudBridge.shared
        let savedAvailability = bridge.available
        let savedLastSyncAt = bridge.lastSyncAt
        let savedSyncStatus = bridge.syncStatus
        let statusPairing = PairingStore()
        let savedPaired = statusPairing.isICloudPaired
        let savedSecret = statusPairing.iCloudPairingSecret
        defer {
            bridge.available = savedAvailability
            bridge.lastSyncAt = savedLastSyncAt
            bridge.syncStatus = savedSyncStatus
            statusPairing.isICloudPaired = savedPaired
            statusPairing.iCloudPairingSecret = savedSecret
        }

        let client = MacBridgeClient()
        client.pairingStore = statusPairing
        let now = Date().addingTimeInterval(1)
        statusPairing.iCloudPairingSecret = nil
        statusPairing.isICloudPaired = false
        bridge.available = false
        client.lastSeenAt = nil
        client.connectingStartedAt = nil
        client.refreshBridgeStatus(now: now)
        XCTAssertEqual(client.bridgeStatus, .offline, "unavailable + unpaired stays generic offline")

        statusPairing.iCloudPairingSecret = Data(repeating: 9, count: 32)
        statusPairing.isICloudPaired = true
        client.refreshBridgeStatus(now: now.addingTimeInterval(30))
        XCTAssertEqual(client.bridgeStatus, .macUnreachable)

        statusPairing.iCloudPairingSecret = nil
        statusPairing.isICloudPaired = false
        client.connectingStartedAt = now
        client.refreshBridgeStatus(now: now)
        XCTAssertEqual(client.bridgeStatus, .connecting)

        bridge.available = true
        client.connectingStartedAt = nil
        client.lastSeenAt = now
        client.refreshBridgeStatus(now: now)
        XCTAssertEqual(client.bridgeStatus, .online, "available + unpaired remains online on fresh activity")

        client.lastSeenAt = now.addingTimeInterval(-61)
        client.refreshBridgeStatus(now: now)
        XCTAssertEqual(client.bridgeStatus, .stale(minutesAgo: 1), "available + unpaired still surfaces stale activity")

        statusPairing.iCloudPairingSecret = Data(repeating: 9, count: 32)
        statusPairing.isICloudPaired = true
        client.lastSeenAt = now
        client.refreshBridgeStatus(now: now)
        XCTAssertEqual(client.bridgeStatus, .online, "available + paired remains online on fresh activity")

        client.lastSeenAt = now.addingTimeInterval(-61)
        client.refreshBridgeStatus(now: now)
        XCTAssertEqual(client.bridgeStatus, .stale(minutesAgo: 1))
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

    // MARK: - ios.desk.statusPicker

    func test_mobileDeskStatusPickerMatchesTheMacRouterAndOnlyRetainsBlockedWhenCurrent() throws {
        let deskModels = try MobileEvalSources.repoFile(
            "Modules/NativeAgentCore/Sources/PersistenceCore/DeskModels.swift"
        )
        let deskStatusBody = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "DeskStatus", keyword: "enum", in: deskModels)
        )
        let statusLine = try XCTUnwrap(
            deskStatusBody.split(separator: "\n").first {
                String($0).trimmingCharacters(in: .whitespaces).hasPrefix("case ")
            }
        )
        let allDeskStatuses = Set(
            String(statusLine)
                .trimmingCharacters(in: .whitespaces)
                .dropFirst("case ".count)
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        )

        let macRouter = try MobileEvalSources.repoFile("Sources/NativeAgentApp/MacSyncActionRouter.swift")
        XCTAssertTrue(macRouter.contains("case \"setDeskItemStatus\":"), "the iOS picker must track the Mac action it invokes")
        XCTAssertTrue(
            macRouter.contains("let status = DeskStatus(rawValue: statusRaw), status != .blocked"),
            "the accepted vocabulary is every DeskStatus except blocked"
        )
        let acceptedByMacRouter = allDeskStatuses.subtracting(["blocked"])
        XCTAssertFalse(acceptedByMacRouter.isEmpty)

        for current in acceptedByMacRouter.union(["unexpected-status"]) {
            let pickerStatuses = MobileDeskStatusPickerPresentation.allowedStatuses(for: current)
            XCTAssertEqual(
                Set(pickerStatuses),
                acceptedByMacRouter,
                "the picker must offer exactly the statuses the Mac accepts"
            )
            XCTAssertEqual(pickerStatuses.count, acceptedByMacRouter.count)
            XCTAssertFalse(pickerStatuses.contains("blocked"))
        }

        let blockedItemStatuses = MobileDeskStatusPickerPresentation.allowedStatuses(for: "blocked")
        XCTAssertEqual(Set(blockedItemStatuses), acceptedByMacRouter.union(["blocked"]))
        XCTAssertEqual(blockedItemStatuses.count, acceptedByMacRouter.count + 1)
    }

    // MARK: - ios.activity.sections

    func test_activitySectionsCountIndependentlyAndKeepUnpublishedDistinctFromClear() throws {
        let memoryProposal = try JSONDecoder().decode(
            MemoryProposalRecord.self,
            from: Data(#"{"id":"memory","text":"Keep this","status":"pending"}"#.utf8)
        )
        let trainingProposal = try JSONDecoder().decode(
            TrainingProposalSummary.self,
            from: Data(#"{"id":"training","title":"Train this","status":"pending","proposed":"A concrete change","rationale":"Evidence supports it"}"#.utf8)
        )
        let oneInEverySection = ActivityScreenPresentation.counts(
            storedApprovals: 0,
            snapshotApprovals: [
                ApprovalRequest(
                    id: "approval", title: "Review", action: "shell", risk: "high", status: "pending"
                )
            ],
            storedInbox: 0,
            snapshotInbox: [
                InboxItemRecord(
                    id: "inbox", created_at: "2026-08-24T00:00:00Z", source: "eval", severity: "actionable",
                    title: "Read", summary: "One pending inbox item", detail: nil, relatedWorkshopExecutionId: nil,
                    related_approval_id: nil, related_paths: nil, related_groups: nil, actions: [], status: "unread", read_at: nil
                )
            ],
            memoryProposals: [memoryProposal],
            trainingProposals: [trainingProposal],
            promotionCandidates: []
        )
        XCTAssertEqual(oneInEverySection.approvals, 1)
        XCTAssertEqual(oneInEverySection.inbox, 1)
        XCTAssertEqual(oneInEverySection.memoryProposals, 1)
        XCTAssertEqual(oneInEverySection.selfImprovement, 1)

        let onlyInboxChanges = ActivityScreenPresentation.counts(
            storedApprovals: 0,
            snapshotApprovalsPending: 1,
            storedInbox: 0,
            snapshotInboxPending: 2,
            memoryProposalsPending: 1,
            trainingProposalsPending: 1,
            promotionCandidatesPending: 0
        )
        XCTAssertEqual(onlyInboxChanges.approvals, 1)
        XCTAssertEqual(onlyInboxChanges.inbox, 2)
        XCTAssertEqual(onlyInboxChanges.memoryProposals, 1)
        XCTAssertEqual(onlyInboxChanges.selfImprovement, 1)

        XCTAssertEqual(ActivityScreenPresentation.sectionCountState(for: nil), .unavailable)
        XCTAssertEqual(ActivityScreenPresentation.sectionCountState(for: 0), .clear)
        XCTAssertEqual(ActivityScreenPresentation.sectionCountState(for: 3), .pending(3))
    }

    // MARK: - ios.providers.surfaceModelMenu

    func test_everyCanonicalMacSurfaceRendersItsPublishedModelInsteadOfAnUnsetLabel() throws {
        let providerRouting = try MobileEvalSources.repoFile(
            "Modules/NativeAgentCore/Sources/ProviderRouting/ProviderRoutingContracts.swift"
        )
        guard let listStart = providerRouting.range(of: "public let MODEL_SURFACES: [String] = ["),
              let listEnd = providerRouting.range(of: "]", range: listStart.upperBound..<providerRouting.endIndex) else {
            return XCTFail("could not locate the Mac-owned MODEL_SURFACES catalog")
        }
        let macSurfaces = MobileEvalSources.matches(
            #""([a-z_]+)""#,
            in: String(providerRouting[listStart.upperBound..<listEnd.lowerBound])
        )
        XCTAssertFalse(macSurfaces.isEmpty)
        XCTAssertEqual(Set(ProviderSettingsView.canonicalSurfaces), Set(macSurfaces))

        let projectedPins = Dictionary(uniqueKeysWithValues: macSurfaces.map { surface in
            (
                surface,
                SurfaceModelPref(
                    model: "mac-pinned-\(surface)",
                    reasoningEffort: "high",
                    serviceTier: "default",
                    providerId: "mac-provider"
                )
            )
        })
        for surface in macSurfaces {
            let label = MobileProviderSurfaceModelMenuPresentation.label(
                for: surface,
                surfaceModels: projectedPins
            )
            XCTAssertEqual(label, "mac-pinned-\(surface)")
            XCTAssertNotEqual(label, "(not set)")
        }

        XCTAssertEqual(
            MobileProviderSurfaceModelMenuPresentation.label(for: "chat", surfaceModels: [:]),
            MobileProviderSurfaceModelMenuPresentation.unpublishedLabel
        )
    }

    // MARK: - ios.mactools.policyGate

    func test_missingMacPolicySnapshotDoesNotReadAsAnIntentionalPolicyDisable() {
        let missingSnapshot = MacToolsPolicyGatePresentation.disabledDescription(for: nil)

        var disabledPolicy = TrustMacControlPolicy()
        disabledPolicy.enabled = false
        let policyDisabled = MacToolsPolicyGatePresentation.disabledDescription(for: disabledPolicy)

        XCTAssertEqual(MacToolsPolicyGatePresentation.state(for: nil), .snapshotUnavailable)
        XCTAssertEqual(MacToolsPolicyGatePresentation.state(for: disabledPolicy), .macControlDisabled)
        XCTAssertNotEqual(missingSnapshot, policyDisabled)
        XCTAssertTrue(missingSnapshot.contains("snapshot"))
        XCTAssertFalse(missingSnapshot.localizedCaseInsensitiveContains("disabled by policy"))
        XCTAssertTrue(policyDisabled.localizedCaseInsensitiveContains("disabled by policy"))
    }

    // MARK: - ios.mactools.spotlight

    func test_emptySpotlightResponseIsDistinctFromMeasuredZeroAndLongResultsRemainReachable() throws {
        let emptyResponse = MacToolsSpotlightPresentation.outcome(from: "")
        let whitespaceOnlyResponse = MacToolsSpotlightPresentation.outcome(from: " \n\t ")
        let oneLineResponse = MacToolsSpotlightPresentation.outcome(from: "/Users/user/Notes/one.md")
        let fortyLineResponse = MacToolsSpotlightPresentation.outcome(
            from: (0..<40).map { "/Users/user/Notes/result-\($0).md" }.joined(separator: "\n")
        )

        XCTAssertEqual(emptyResponse, .emptyResponse)
        XCTAssertEqual(whitespaceOnlyResponse, .noResults)
        XCTAssertTrue(emptyResponse.statusText.localizedCaseInsensitiveContains("unavailable"))
        XCTAssertEqual(whitespaceOnlyResponse.statusText, "No Spotlight results.")
        XCTAssertEqual(emptyResponse.rows, [])
        XCTAssertEqual(whitespaceOnlyResponse.rows, [])
        XCTAssertEqual(oneLineResponse.resultCount, 1)
        XCTAssertEqual(oneLineResponse.visibleRows(showingAll: false), ["/Users/user/Notes/one.md"])
        XCTAssertNil(oneLineResponse.truncationText(showingAll: false))
        XCTAssertEqual(fortyLineResponse.resultCount, 40)
        XCTAssertEqual(fortyLineResponse.visibleRows(showingAll: false).count, 8)
        XCTAssertEqual(fortyLineResponse.hiddenResultCount, 32)
        XCTAssertEqual(fortyLineResponse.truncationText(showingAll: false), "Showing 8 of 40 Spotlight results.")
        XCTAssertEqual(fortyLineResponse.visibleRows(showingAll: true).count, 40)
        XCTAssertEqual(fortyLineResponse.truncationText(showingAll: true), "Showing all 40 Spotlight results.")

        let view = try MobileEvalSources.mobileSource("MacToolsView.swift")
        XCTAssertTrue(view.contains("spotlightResultPresentation(spotlightOutcome)"))
        XCTAssertTrue(view.contains("Show all Spotlight results"))
        XCTAssertTrue(view.contains("Show fewer Spotlight results"))
        XCTAssertTrue(view.contains("spotlightOutcome = nil"))
    }

    // MARK: - ios.kg.dualShapeDecoder

    func test_mobileSnapshotCacheCloneDecodesBothKnowledgeGraphShapesWithNamedTypedEntities() throws {
        let cache = tempRoot.appendingPathComponent("mobile_snapshot_cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let canonicalSnapshot = Data(#"""
        {
          "entities": [{"id": "person-agent", "name": "Agent", "type": "person"}],
          "edges": [],
          "total_entities": 1,
          "total_edges": 0,
          "page": 0
        }
        """#.utf8)
        let legacySnapshot = Data(#"""
        {
          "_commit_seq": 7,
          "entities": {"person-agent": {"name": "Agent", "type": "person"}},
          "edges": []
        }
        """#.utf8)

        for (name, snapshot) in [("canonical", canonicalSnapshot), ("legacy", legacySnapshot)] {
            let snapshotURL = cache.appendingPathComponent("\(name)-knowledge_graph.json")
            try snapshot.write(to: snapshotURL, options: .atomic)

            let decoded = try JSONDecoder().decode(
                KGEntityResponse.self,
                from: Data(contentsOf: snapshotURL)
            )
            XCTAssertFalse(decoded.entities.isEmpty, "\(name) snapshot clone must publish entities")
            for entity in decoded.entities {
                XCTAssertFalse(entity.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertFalse(entity.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }

        let shapeDrift = Data(#"""
        {"entities": [{"id": "person-agent"}], "edges": []}
        """#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KGEntityResponse.self, from: shapeDrift))
    }

    func test_knowledgeGraphEntityMetadataCoversEveryMacPublishedTypeAndNamesUnknowns() throws {
        let macCatalog = try MobileEvalSources.repoFile("Sources/NativeAgentApp/KnowledgeGraphPresentation.swift")
        guard let declaration = macCatalog.range(of: "static let entityTypes = ["),
              let closingBracket = macCatalog.range(of: "]", range: declaration.upperBound..<macCatalog.endIndex) else {
            return XCTFail("could not find the Mac Knowledge Graph entity type catalog")
        }
        let catalogBody = String(macCatalog[declaration.upperBound..<closingBracket.lowerBound])
        let macTypes = Set(MobileEvalSources.matches(#"\"([^\"]+)\""#, in: catalogBody)).subtracting(["all"])

        XCTAssertEqual(macTypes, Set(KGEntityMeta.knownTypes))
        for (type, label, icon) in [
            ("person", "Person", "person.circle"),
            ("organization", "Organization", "building.2"),
            ("project", "Project", "folder"),
            ("concept", "Concept", "lightbulb"),
            ("place", "Place", "mappin.circle"),
            ("event", "Event", "calendar"),
            ("tool", "Tool", "wrench.and.screwdriver"),
            ("fact", "Fact", "text.quote"),
        ] {
            let presentation = KGEntityMeta.presentation(for: type)
            XCTAssertTrue(presentation.isKnown, "\(type) fell through to unknown metadata")
            XCTAssertEqual(presentation.label, label)
            XCTAssertEqual(presentation.icon, icon)
        }

        let unknown = KGEntityMeta.presentation(for: "future_kind")
        XCTAssertFalse(unknown.isKnown)
        XCTAssertEqual(unknown.label, "Unrecognized type: future_kind")
        XCTAssertEqual(unknown.icon, "questionmark.circle")
        XCTAssertEqual(KGEntityMeta.presentation(for: "  ").label, "Type unavailable")

        let view = try MobileEvalSources.mobileSource("KnowledgeGraphView.swift")
        XCTAssertTrue(view.contains("let meta = KGEntityMeta.presentation(for: entity.type)"))
        XCTAssertTrue(view.contains("Text(meta.label)"))
        XCTAssertFalse(view.contains("KGEntityMeta.icon(entity.type)"))
    }

    // MARK: - ios.pairing.skip

    func test_skippedUnpairedMainAppKeepsAPairingRecoveryAffordanceInMore() throws {
        XCTAssertEqual(
            PairingSkipPresentation.mainAppState(isPaired: false, pairingSkipped: false),
            .pairingRequired
        )
        XCTAssertEqual(
            PairingSkipPresentation.mainAppState(isPaired: false, pairingSkipped: true),
            .skipped
        )
        XCTAssertEqual(
            PairingSkipPresentation.mainAppState(isPaired: true, pairingSkipped: true),
            .paired
        )
        XCTAssertTrue(PairingSkipPresentation.showsRecoveryAffordance(isPaired: false))
        XCTAssertFalse(PairingSkipPresentation.showsRecoveryAffordance(isPaired: true))

        let more = try MobileEvalSources.mobileSource("AdvancedView.swift")
        XCTAssertTrue(more.contains("PairingSkipPresentation.showsRecoveryAffordance"))
        XCTAssertTrue(more.contains("Label(\"Pair with Mac\""))
        XCTAssertTrue(more.contains("PairingView(onSkip:"))
    }

    // MARK: - ios.mactools.quickAction.unknownActionSilentSuccess

    func test_unknownQuickActionFailsWithoutSendingWhileKnownActionsCompleteAfterTheirSend() async {
        var sent: [MacSystemQuickAction] = []

        let lock = await MacSystemQuickActionExecution.execute(named: "lock_screen") { action in
            sent.append(action)
        }
        let sleep = await MacSystemQuickActionExecution.execute(named: "sleep_display") { action in
            sent.append(action)
        }
        let unknown = await MacSystemQuickActionExecution.execute(named: "not_a_mac_action") { action in
            sent.append(action)
        }

        XCTAssertEqual(sent, [.lockScreen, .sleepDisplay])
        XCTAssertEqual(lock.state, .ranOnMac)
        XCTAssertEqual(lock.status, "Done.")
        XCTAssertEqual(sleep.state, .ranOnMac)
        XCTAssertEqual(sleep.status, "Done.")
        XCTAssertEqual(unknown.state, .failed)
        XCTAssertNotEqual(unknown.status, "Done.")
        XCTAssertTrue(unknown.status.contains("Unsupported Mac system action"))
    }

    // MARK: - ios.mactools.shortcutRunner

    func test_shortcutNotFoundAndPolicyRefusalHaveDifferentRecoveryStatuses() {
        let missing = MacShortcutRunnerPresentation.failure(
            for: SyncError.unsupported("shortcut_not_found"),
            shortcutName: "Morning Brief"
        )
        let policyRefusal = MacShortcutRunnerPresentation.failure(
            for: SyncError.unsupported("mac_control_policy_denied: shortcuts"),
            shortcutName: "Morning Brief"
        )

        XCTAssertNotEqual(missing.status, policyRefusal.status)
        XCTAssertTrue(missing.status.localizedCaseInsensitiveContains("not found"))
        XCTAssertTrue(missing.detail.localizedCaseInsensitiveContains("exact"))
        XCTAssertTrue(policyRefusal.status.localizedCaseInsensitiveContains("policy"))
        XCTAssertTrue(policyRefusal.detail.localizedCaseInsensitiveContains("trust"))
    }
}
