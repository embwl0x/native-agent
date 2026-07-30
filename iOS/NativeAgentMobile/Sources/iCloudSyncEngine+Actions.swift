// PATCH-2026-05-07: ios-parity iCloudSyncEngine — snapshot reader + inbox writer for iOS
// Architecture:
//   READ:  iCloud Drive `snapshots/*.json` — Mac's SnapshotWriter keeps these fresh.
//          KVS key `snapshot_updated` pings iOS when a snapshot changes.
//   WRITE: iOS drops an action envelope into `inbox/<msg_id>.json`.
//          MacSyncEngine validates it, dispatches into the in-process Swift runtime,
//          writes `responses/<msg_id>.json`, then pings `inbox_response_<msg_id>`.

import CryptoKit
import Foundation
import SwiftUI
import NativeAgentShared

private let decisionActionPollTimeoutSeconds: Double = 300
private let decisionActionPollIntervalSeconds: Double = 0.75

extension iCloudSyncEngine {
    private func beginSendAction() throws {
        _sendLock.lock()
        defer { _sendLock.unlock() }
        if _sendInFlight {
            throw SyncError.busy("Another iCloud send is in flight; retry shortly")
        }
        _sendInFlight = true
    }

    private func finishSendAction() {
        _sendLock.lock()
        _sendInFlight = false
        _sendLock.unlock()
    }

    // MARK: - Inbox writer (iOS → Mac action dispatch)

    /// Persist one already outer-HMAC-verified CloudKit action response into
    /// the existing local response mailbox. `pollResponse` remains the sole
    /// inner-HMAC/correlation verifier and transaction closer.
    func persistCloudKitActionResponse(
        _ text: String,
        actionID: String
    ) async -> Bool {
        guard UUID(uuidString: actionID) != nil,
              let responsesDir,
              let data = text.data(using: .utf8),
              (try? JSONDecoder().decode([String: String].self, from: data)) != nil else {
            return false
        }
        let url = responsesDir.appendingPathComponent("\(actionID).json")
        do {
            try await Task.detached(priority: .utility) {
                try data.write(to: url, options: .atomic)
            }.value
            return true
        } catch {
            syncError = "CloudKit action response could not be persisted: \(error.localizedDescription)"
            return false
        }
    }

    private func writeTransaction(
        id: String,
        action: String,
        state: String,
        attempts: Int = 0,
        error: String? = nil,
        response: [String: String]? = nil
    ) async throws {
        guard let transactionDir else {
            throw SyncError.persistence("iCloud transaction ledger is not initialized.")
        }
        let capturedTransactionDir = transactionDir
        let timeoutSeconds = max(0.05, transactionWriteTimeoutSeconds)
        let testHook = transactionWriteTestHook
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeBox = _ResumeBox()
            // Each transition is awaited by its caller, which preserves state
            // ordering without a global serial queue. A coordinator wedged on
            // one transaction therefore cannot queue every later action behind it.
            DispatchQueue.global(qos: .utility).async {
                do {
                    try testHook?(state)
                    guard resumeBox.isPending else { return }

                    let now = ISO8601DateFormatter().string(from: Date())
                    let url = capturedTransactionDir.appendingPathComponent("\(id).json")
                    let existingData = try Self.readCoordinatedTransaction(at: url)
                    let existing: ICloudTransactionRecord?
                    if let existingData {
                        do {
                            existing = try JSONDecoder().decode(ICloudTransactionRecord.self, from: existingData)
                        } catch {
                            throw SyncError.persistence(
                                "iCloud transaction \(id) could not decode existing state: \(error.localizedDescription)"
                            )
                        }
                    }
                    else {
                        existing = nil
                    }

                    let record = ICloudTransactionRecord(
                        id: id,
                        direction: "ios_to_mac",
                        action: action,
                        state: state,
                        createdAt: existing?.createdAt ?? now,
                        updatedAt: now,
                        attempts: max(attempts, existing?.attempts ?? 0),
                        lastError: error ?? existing?.lastError,
                        response: response ?? existing?.response
                    )
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                    let data = try encoder.encode(record)
                    try Self.writeAndVerifyTransaction(data, expected: record, to: url)
                    if resumeBox.tryResume() {
                        continuation.resume()
                    }
                } catch {
                    if resumeBox.tryResume() {
                        if let syncError = error as? SyncError {
                            continuation.resume(throwing: syncError)
                        } else {
                            continuation.resume(throwing: SyncError.persistence(
                                "iCloud transaction \(id) state \(state) was not persisted: \(error.localizedDescription)"
                            ))
                        }
                    }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                if resumeBox.tryResume() {
                    continuation.resume(throwing: SyncError.timeout(
                        "iCloud transaction \(id) state \(state) timed out after \(Self.timeoutLabel(timeoutSeconds))s"
                    ))
                }
            }
        }
    }

    private nonisolated static func readCoordinatedTransaction(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var readError: Error?
        var data: Data?
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
            do {
                data = try Data(contentsOf: readURL)
            } catch {
                readError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        return data
    }

    private nonisolated static func writeAndVerifyTransaction(
        _ data: Data,
        expected: ICloudTransactionRecord,
        to url: URL
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinationError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
                let handle = try FileHandle(forWritingTo: writeURL)
                defer { try? handle.close() }
                try handle.synchronize()
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }

        guard let persistedData = try readCoordinatedTransaction(at: url) else {
            throw SyncError.persistence("iCloud transaction \(expected.id) disappeared after write.")
        }
        let persisted = try JSONDecoder().decode(ICloudTransactionRecord.self, from: persistedData)
        guard persisted.id == expected.id,
              persisted.direction == expected.direction,
              persisted.action == expected.action,
              persisted.state == expected.state,
              persisted.createdAt == expected.createdAt,
              persisted.updatedAt == expected.updatedAt,
              persisted.attempts == expected.attempts,
              persisted.lastError == expected.lastError,
              persisted.response == expected.response
        else {
            throw SyncError.persistence(
                "iCloud transaction \(expected.id) failed read-back verification for state \(expected.state)."
            )
        }
    }

    private nonisolated static func timeoutLabel(_ seconds: TimeInterval) -> String {
        seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.2f", seconds)
    }

    /// Compute HMAC-SHA256 over a canonical JSON body (lowercase hex, matching Mac's hmacSHA256).
    /// The canonical body is `JSONSerialization.data(withJSONObject: body, options:[.sortedKeys])`
    /// with the "signature" key excluded — identical to what MacSyncEngine validates.
    private func hmacHex(body: [String: Any], secret: Data) throws -> String {
        var forSigning = body
        forSigning.removeValue(forKey: "signature")
        let canonical = try JSONSerialization.data(withJSONObject: forSigning, options: [.sortedKeys])
        let key = SymmetricKey(data: secret)
        let mac = HMAC<SHA256>.authenticationCode(for: canonical, using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    /// Drop a signed action into the iCloud inbox and return the msgId for response polling.
    /// If no HMAC secret is configured, logs an error and throws SyncError.notSigned
    /// (unsigned messages are hard-rejected by the Mac).
    ///
    /// The HMAC computation and file write are executed off the main actor in a
    /// userInitiated detached task to avoid blocking the UI for large payloads
    /// (e.g. mac_run_shell, mac_run_applescript). The pairing secret is captured
    /// on the main actor before the detached work begins.
    @discardableResult
    func sendAction(_ action: InboxAction) async throws -> String {
        // S.4: Serialise concurrent callers. A second send while one is in-flight
        // fails fast with .busy so the caller can surface a "retry" prompt.
        try beginSendAction()
        defer { finishSendAction() }

        guard let secret = pairingStore?.iCloudPairingSecret else {
            let msg = "iCloud sync paused — pairing key not configured. Scan the QR code from Mac Settings → Pair iPhone / iPad."
            syncError = msg
            print("[iCloudSyncEngine] \(msg)")
            throw SyncError.notSigned
        }

        let transactionId = action.transactionId ?? action.msgId
        try await writeTransaction(id: transactionId, action: action.action, state: "queued", attempts: 1)

        let signedData = try Self.signedActionData(action, secret: secret)
        if iCloudBridge.shared.usesCloudKitDeviceTransport {
            do {
                try await iCloudBridge.shared.sendActionEnvelope(
                    signedData,
                    actionID: action.msgId
                )
                try await writeTransaction(
                    id: transactionId,
                    action: action.action,
                    state: "sent",
                    attempts: 1
                )
                return action.msgId
            } catch {
                try? await writeTransaction(
                    id: transactionId,
                    action: action.action,
                    state: "send_failed",
                    attempts: 1,
                    error: error.localizedDescription
                )
                throw error
            }
        }

        guard let inboxDir else { throw SyncError.notSetup }
        let capturedInboxDir = inboxDir

        // PATCH-2026-05-08: review-fix-r4 Move heavy work OFF the main actor.
        // `Task(priority:)` inherits the @MainActor context, so use detached
        // for true off-main execution. To propagate parent cancellation, the
        // detached Task is created OUTSIDE the cancellation handler and
        // explicitly cancelled in onCancel.
        // PATCH-2026-05-08: review-fix-r7 Real timeout via background-queue +
        // continuation. TaskGroup-with-cancel doesn't actually bound a sync
        // file write — `data.write(.atomic)` ignores cancellation. Run the
        // blocking write on a global queue and resume the continuation when
        // either the write completes OR the timeout fires; whichever wins.
        let result: String
        do {
            result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            // Resume guard so we never resume twice
            let resumeBox = _ResumeBox()

            // Background work
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let fileURL = capturedInboxDir.appendingPathComponent("\(action.msgId).json")
                    let stagedURL = capturedInboxDir.appendingPathComponent(".\(action.msgId).\(UUID().uuidString).tmp")
                    // R11-N31: Wrap inbox write in NSFileCoordinator to match Mac-side reads.
                    var writeError: NSError?
                    var writeException: Error?
                    NSFileCoordinator().coordinate(writingItemAt: stagedURL, options: .forReplacing, error: &writeError) { coordinatedURL in
                        do {
                            try signedData.write(to: coordinatedURL, options: .atomic)
                        } catch {
                            writeException = error
                        }
                    }
                    if let err = writeError ?? writeException {
                        try? FileManager.default.removeItem(at: stagedURL)
                        throw err
                    }

                    if resumeBox.tryResume() {
                        do {
                            if FileManager.default.fileExists(atPath: fileURL.path) {
                                try FileManager.default.removeItem(at: fileURL)
                            }
                            try FileManager.default.moveItem(at: stagedURL, to: fileURL)
                            cont.resume(returning: action.msgId)
                        } catch {
                            try? FileManager.default.removeItem(at: stagedURL)
                            cont.resume(throwing: error)
                        }
                    } else {
                        try? FileManager.default.removeItem(at: stagedURL)
                    }
                } catch {
                    if resumeBox.tryResume() {
                        cont.resume(throwing: error)
                    }
                }
            }

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                if resumeBox.tryResume() {
                    cont.resume(throwing: SyncError.timeout("iCloud sendAction timed out after 30s"))
                }
                // Note: the work goroutine may still be hung on data.write —
                // we leak a thread until the OS unblocks it. Acceptable: the
                // user gets a clean error and retries.
            }
            }
        } catch {
            let sendError = error
            do {
                try await writeTransaction(
                    id: transactionId,
                    action: action.action,
                    state: "send_failed",
                    attempts: 1,
                    error: sendError.localizedDescription
                )
            } catch {
                throw SyncError.persistence(
                    "iCloud send failed (\(sendError.localizedDescription)) and its terminal receipt could not be persisted (\(error.localizedDescription))."
                )
            }
            throw sendError
        }
        if Task.isCancelled {
            try await writeTransaction(id: transactionId, action: action.action, state: "cancelled", attempts: 1)
            throw CancellationError()
        }
        kvs.set(result, forKey: "inbox_pending")
        kvs.synchronize()
        try await writeTransaction(id: transactionId, action: action.action, state: "sent", attempts: 1)
        return result
    }

    nonisolated private static func signedActionData(
        _ action: InboxAction,
        secret: Data
    ) throws -> Data {
        var body: [String: Any] = [
            "msgId": action.msgId,
            "clientId": action.clientId,
            "action": action.action,
            "payload": action.payload,
            "createdAt": action.createdAt,
        ]
        if let protocolVersion = action.protocolVersion {
            body["protocolVersion"] = protocolVersion
        }
        if let transactionId = action.transactionId {
            body["transactionId"] = transactionId
        }
        let canonical = try JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys]
        )
        let key = SymmetricKey(data: secret)
        let mac = HMAC<SHA256>.authenticationCode(for: canonical, using: key)
        body["signature"] = Data(mac).map { String(format: "%02x", $0) }.joined()
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Best-effort signed acknowledgement that one exact notification event
    /// reached the iOS process (APNS) or its iCloud bridge scheduler. This does
    /// not claim banner display or that the user saw it. Failure is intentionally
    /// non-blocking; the Mac prediction remains pending and can expire honestly.
    func sendNotificationReceipt(eventID: String, channel: String) async {
        let cleanID = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeAgentDeviceEventIdentity.isCanonical(cleanID) else { return }
        let action = InboxAction.make(
            action: "recordNotificationReceipt",
            payload: [
                "eventId": cleanID,
                "channel": String(channel.prefix(80)),
            ]
        )
        do {
            _ = try await sendAction(action)
        } catch {
            NSLog("[NativeAgentMobile] notification receipt send failed event=%@: %@",
                  cleanID, error.localizedDescription)
        }
    }

    // PATCH-2026-05-08: review-fix-r7 Single-resume guard.
    private final class _ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        var isPending: Bool {
            lock.lock(); defer { lock.unlock() }
            return !resumed
        }
        func tryResume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    /// Poll responses directory for a reply to msgId. Returns nil if not yet available.
    func pollResponse(msgId: String, expectedAction: String? = nil) async -> [String: String]? {
        guard let responsesDir else { return nil }
        let fileURL = responsesDir.appendingPathComponent("\(msgId).json")
        let data = await Self.readCoordinatedData(fileURL)
        guard let data else { return nil }
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        guard let secret = pairingStore?.iCloudPairingSecret else {
            syncError = "iCloud response could not be verified — pairing key is missing."
            return nil
        }
        guard let signature = decoded["signature"] else {
            syncError = "Unsigned iCloud response rejected. Re-pair iPhone with the current Mac app."
            return nil
        }
        do {
            let expected = try hmacHex(body: decoded, secret: secret)
            if signature.lowercased() != expected {
                if pairingStore?.applyKVSPairingMaterialIfNeeded() == true,
                   let refreshedSecret = pairingStore?.iCloudPairingSecret,
                   refreshedSecret != secret {
                    let refreshedExpected = try hmacHex(body: decoded, secret: refreshedSecret)
                    guard signature.lowercased() == refreshedExpected else {
                        syncError = "iCloud response signature mismatch. Re-pair iPhone with the current Mac app."
                        return nil
                    }
                } else {
                    syncError = "iCloud response signature mismatch. Re-pair iPhone with the current Mac app."
                    return nil
                }
            }
        } catch {
            syncError = "iCloud response verification failed: \(error.localizedDescription)"
            return nil
        }
        var verified = decoded
        verified.removeValue(forKey: "signature")
        guard (verified["msgId"] ?? msgId) == msgId else {
            syncError = "iCloud response msgId mismatch. Ignoring stale or replayed response."
            return nil
        }
        if let expectedAction,
           let responseAction = verified["action"],
           responseAction != expectedAction {
            syncError = "iCloud response action mismatch. Ignoring stale or replayed response."
            return nil
        }
        let transactionId = verified["transactionId"] ?? msgId
        let status = (verified["status"] ?? "").lowercased()
        let state = (status == "error" || status == "failed" || verified["ok"] == "false")
            ? "failed"
            : (status == "pending_approval" ? "pending_approval" : "completed")
        do {
            try await writeTransaction(
                id: transactionId,
                action: verified["action"] ?? "unknown",
                state: state,
                error: verified["error"] ?? verified["message"],
                response: verified
            )
        } catch {
            syncError = "iCloud response was verified but its transaction receipt could not be persisted: \(error.localizedDescription)"
            return nil
        }
        return verified
    }

    // R10-C3: iOS approval recovery after `signature_required` rejection.
    //
    // When the Mac writes a response with `code == "signature_required"` it means
    // the action was sent without a valid HMAC (e.g. old iOS build, or a race
    // where the pairing secret was regenerated on the Mac).
    //
    // Recovery:
    //   (a) Re-sign the original action body with the current HMAC key (a NEW
    //       InboxAction is created so msgId and createdAt are refreshed).
    //   (b) Resubmit ONCE.
    //   (c) On second failure surface a user-visible error via `syncError`.
    //
    // Cap retry at 1 to prevent infinite loops.

    /// Send an action and poll for the response, retrying once on `signature_required`.
    /// Returns the final response dict, or nil if timed out.
    /// On `signature_required` after retry, sets `syncError` and returns the error response.
    nonisolated static func isMacResponseTimeout(_ error: Error) -> Bool {
        guard case SyncError.timeout(let message) = error else { return false }
        return message.localizedCaseInsensitiveContains("waiting for Mac response")
    }

    func sendActionWithSignatureRetry(
        _ action: InboxAction,
        pollTimeoutSeconds: Double = 30,
        pollIntervalSeconds: Double = 0.5
    ) async -> [String: String]? {
        // First attempt
        let msgId: String
        do {
            msgId = try await sendAction(action)
        } catch {
            syncError = "iCloud action send failed: \(error.localizedDescription)"
            return nil
        }
        // Poll for response
        if let resp = await pollWithTimeout(
            msgId: msgId,
            timeout: pollTimeoutSeconds,
            interval: pollIntervalSeconds,
            expectedAction: action.action
        ) {
            if resp["code"] == "signature_required" || resp["code"] == "signature_invalid" {
                // (a)(b) Re-sign with new msgId/createdAt and resubmit once
                let retryAction = InboxAction.make(action: action.action, payload: action.payload)
                let retryMsgId: String
                do {
                    retryMsgId = try await sendAction(retryAction)
                } catch {
                    syncError = "Resubmit after signature recovery failed: \(error.localizedDescription)"
                    return resp
                }
                // (c) Poll retry response; on second failure surface error
                if let retryResp = await pollWithTimeout(
                    msgId: retryMsgId,
                    timeout: pollTimeoutSeconds,
                    interval: pollIntervalSeconds,
                    expectedAction: retryAction.action
                ) {
                    if retryResp["code"] == "signature_required" || retryResp["code"] == "signature_invalid" || retryResp["ok"] == "false" {
                        let errMsg = retryResp["error"] ?? "Signature validation failed. Re-scan the pairing QR from Mac Settings → Pair iPhone / iPad."
                        syncError = errMsg
                    }
                    return retryResp
                }
                syncError = "Retry after signature recovery timed out — check iCloud Drive connectivity."
                return nil
            }
            return resp
        }
        syncError = "iCloud action timed out waiting for Mac response after \(Int(pollTimeoutSeconds))s."
        return nil
    }

    private func sendDecisionActionWithSignatureRetry(_ action: InboxAction) async -> [String: String]? {
        await sendActionWithSignatureRetry(
            action,
            pollTimeoutSeconds: decisionActionPollTimeoutSeconds,
            pollIntervalSeconds: decisionActionPollIntervalSeconds
        )
    }

    func requireSuccessfulActionResponse(
        _ response: [String: String]?,
        timeoutMessage: String = "Mac did not return a response."
    ) throws -> [String: String] {
        guard let response else {
            throw SyncError.timeout(syncError ?? timeoutMessage)
        }
        let status = (response["status"] ?? "").lowercased()
        let error = response["error"] ?? response["code"]
        let explicitlyUnapplied = response["applied"]?.lowercased() == "false"
        if response["ok"] == "false"
            || status == "error"
            || status == "failed"
            || explicitlyUnapplied
            || !(error?.isEmpty ?? true)
        {
            throw SyncError.unsupported(response["message"] ?? error ?? "Mac rejected the action.")
        }
        return response
    }

    /// Poll the responses directory for `msgId` until the file appears or timeout elapses.
    func pollWithTimeout(
        msgId: String,
        timeout: Double,
        interval: Double,
        expectedAction: String? = nil
    ) async -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return nil }
            if iCloudBridge.shared.usesCloudKitDeviceTransport {
                await iCloudBridge.shared.pollIncomingNow()
            }
            if let resp = await pollResponse(msgId: msgId, expectedAction: expectedAction) { return resp }
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return nil
            }
        }
        return nil
    }

    private nonisolated static func readCoordinatedData(_ fileURL: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return nil
            }
            let coordinator = NSFileCoordinator(filePresenter: nil)
            // 2026-05-14: kick iCloud download proactively so the coordinator
            // below doesn't eat a cold-fetch stall on first poll on fresh devices.
            try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
            var coordError: NSError?
            var data: Data?
            coordinator.coordinate(readingItemAt: fileURL, options: [.withoutChanges], error: &coordError) { url in
                data = try? Data(contentsOf: url)
            }
            return data
        }.value
    }

    // MARK: - Higher-level mutation helpers

    // Route Workshop submission through signature retry so a
    // signature_required rejection auto-retries with a fresh signature.
    @discardableResult
    func submitWorkshopTask(title: String, objective: String) async throws -> String {
        let action = InboxAction.make(action: "submitWorkshopTask", payload: [
            "title": title, "objective": objective
        ])
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action))
        return result["result"] ?? result["status"] ?? "submitted"
    }

    // C3: Approval helpers now route through sendActionWithSignatureRetry so that a
    // `signature_required` rejection from the Mac triggers an automatic re-sign + resubmit
    // (one retry) before surfacing an error to the caller.

    @discardableResult
    func approveStep(executionId: String, stepId: String) async throws -> [String: String]? {
        let action = InboxAction.make(action: "approveStep", payload: [
            // Compatibility wire key; the Mac maps it to the Workshop execution.
            "missionId": executionId, "stepId": stepId
        ])
        return try requireSuccessfulActionResponse(await sendDecisionActionWithSignatureRetry(action))
    }

    @discardableResult
    func rejectStep(executionId: String, stepId: String) async throws -> [String: String]? {
        let action = InboxAction.make(action: "rejectStep", payload: [
            // Compatibility wire key; the Mac maps it to the Workshop execution.
            "missionId": executionId, "stepId": stepId
        ])
        return try requireSuccessfulActionResponse(await sendDecisionActionWithSignatureRetry(action))
    }

    @discardableResult
    func approveApproval(id: String) async throws -> [String: String]? {
        let action = InboxAction.make(action: "approveApproval", payload: ["approvalId": id])
        return try requireSuccessfulActionResponse(await sendDecisionActionWithSignatureRetry(action))
    }

    @discardableResult
    func rejectApproval(id: String) async throws -> [String: String]? {
        let action = InboxAction.make(action: "rejectApproval", payload: ["approvalId": id])
        return try requireSuccessfulActionResponse(await sendDecisionActionWithSignatureRetry(action))
    }

    @discardableResult
    func cancelApproval(id: String) async throws -> [String: String]? {
        let action = InboxAction.make(action: "cancelApproval", payload: ["approvalId": id])
        return try requireSuccessfulActionResponse(await sendDecisionActionWithSignatureRetry(action))
    }

    @discardableResult
    func approveMemoryProposal(proposalId: String) async throws -> [String: String]? {
        let action = InboxAction.make(action: "approveMemoryProposal", payload: ["proposalId": proposalId])
        return try requireSuccessfulActionResponse(await sendDecisionActionWithSignatureRetry(action))
    }

    @discardableResult
    func rejectMemoryProposal(proposalId: String) async throws -> [String: String]? {
        let action = InboxAction.make(action: "rejectMemoryProposal", payload: ["proposalId": proposalId])
        return try requireSuccessfulActionResponse(await sendDecisionActionWithSignatureRetry(action))
    }

    @discardableResult
    func deleteMemory(id: String) async throws -> [String: String]? {
        let action = InboxAction.make(action: "deleteMemory", payload: ["memoryId": id])
        return try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action))
    }

    @discardableResult
    func approvePromotion(candidateId: String) async throws -> [String: String]? {
        let action = InboxAction.make(action: "approvePromotion", payload: ["candidateId": candidateId])
        return try requireSuccessfulActionResponse(await sendDecisionActionWithSignatureRetry(action))
    }

    @discardableResult
    func rejectPromotion(candidateId: String) async throws -> [String: String]? {
        let action = InboxAction.make(action: "rejectPromotion", payload: ["candidateId": candidateId])
        return try requireSuccessfulActionResponse(await sendDecisionActionWithSignatureRetry(action))
    }

    @discardableResult
    func approveOrganismReflex(candidateId: String) async throws -> [String: String]? {
        let action = InboxAction.make(action: "approveOrganismReflex", payload: ["candidateId": candidateId])
        let response = try requireSuccessfulActionResponse(await sendDecisionActionWithSignatureRetry(action))
        await refreshHealthSnapshot()
        return response
    }

    @discardableResult
    func retireOrganismReflex(candidateId: String) async throws -> [String: String]? {
        let action = InboxAction.make(action: "retireOrganismReflex", payload: ["candidateId": candidateId])
        let response = try requireSuccessfulActionResponse(await sendDecisionActionWithSignatureRetry(action))
        await refreshHealthSnapshot()
        return response
    }

    @discardableResult
    func inboxAction(itemId: String, actionId: String) async throws -> [String: String]? {
        let action = InboxAction.make(action: "inboxAction", payload: [
            "itemId": itemId,
            "actionId": actionId,
        ])
        let response = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action))
        await refreshActivitySnapshot()
        schedulePostMutationActivityRefresh()
        return response
    }

    private func schedulePostMutationActivityRefresh() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            await self.refreshActivitySnapshot()
        }
    }

    @discardableResult
    func registerPushToken(token: String, environment: String, bundleId: String, deviceId: String = "ios") async throws -> [String: String]? {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else { return ["status": "error", "message": "Missing APNS device token"] }
        let action = InboxAction.make(action: "registerPushToken", payload: [
            "token": cleanToken,
            "environment": environment,
            "bundleId": bundleId,
            "deviceId": deviceId,
        ])
        return try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action, pollTimeoutSeconds: 45))
    }

    // MARK: - Mac Control (iOS → Mac remote actions)
    // PATCH-2026-05-07: mac-control iOS bridge helpers — gated by macControlPolicy.remote_from_ios_allowed on Mac

    // R11-N7: Mac control helpers route through sendActionWithSignatureRetry.
    private func macControlResult(_ action: InboxAction, pollTimeoutSeconds: Double = 120) async throws -> String {
        guard let result = await sendActionWithSignatureRetry(action, pollTimeoutSeconds: pollTimeoutSeconds) else {
            throw SyncError.timeout(syncError ?? "Mac did not return a response.")
        }
        if result["ok"] == "false" || result["status"] == "error" || result["status"] == "failed" || result["blocked"] == "true" {
            throw SyncError.unsupported(result["message"] ?? result["error"] ?? result["code"] ?? "Mac control denied.")
        }
        if result["status"] == "pending_approval" {
            throw SyncError.unsupported(result["message"] ?? "Approval required on the Mac before this action runs.")
        }
        return result["result"] ?? result["message"] ?? result["status"] ?? "ok"
    }

    private func sendMacControl(_ payload: [String: String]) async throws -> String {
        let action = InboxAction.make(action: "mac_control", payload: payload)
        return try await macControlResult(action)
    }

    /// Run a named macOS Shortcut on the Mac.
    func macRunShortcut(name: String, input: String? = nil) async throws -> String {
        var payload: [String: String] = ["method": "runShortcut", "name": name]
        if let i = input { payload["input"] = i }
        return try await sendMacControl(payload)
    }

    /// Run a shell command on the Mac. Requires mac.shell_allowed + approval gate on Mac side.
    func macRunShell(command: String, cwd: String? = nil) async throws -> String {
        var payload: [String: String] = ["method": "runShell", "command": command]
        if let c = cwd { payload["cwd"] = c }
        return try await sendMacControl(payload)
    }

    /// Read a file from the Mac filesystem.
    func macReadFile(path: String, maxBytes: Int = 1_000_000) async throws -> String {
        return try await sendMacControl(["method": "readFile", "path": path, "max_bytes": "\(maxBytes)"])
    }

    /// Post a macOS notification on the Mac.
    // N7: route through sendActionWithSignatureRetry so signature_required auto-retries.
    func macNotify(title: String, message: String, sound: String? = nil) async throws -> String {
        var payload: [String: String] = ["method": "notify", "title": title, "message": message]
        if let s = sound { payload["sound"] = s }
        let action = InboxAction.make(action: "mac_control", payload: payload)
        return try await macControlResult(action)
    }

    /// Lock the Mac screen.
    // N7: route through sendActionWithSignatureRetry.
    func macLockScreen() async throws -> String {
        let action = InboxAction.make(action: "mac_control", payload: ["method": "system", "action": "lock_screen"])
        return try await macControlResult(action)
    }

    /// Sleep the Mac display.
    // N7: route through sendActionWithSignatureRetry.
    func macSleepDisplay() async throws -> String {
        let action = InboxAction.make(action: "mac_control", payload: ["method": "system", "action": "sleep_display"])
        return try await macControlResult(action)
    }

    /// Set Mac output volume (0–100).
    // N7: route through sendActionWithSignatureRetry.
    func macSetVolume(percent: Int) async throws -> String {
        let action = InboxAction.make(action: "mac_control", payload: [
            "method": "system", "action": "volume", "value": "\(percent)"
        ])
        return try await macControlResult(action)
    }

    /// Run AppleScript on the Mac. Requires mac.applescript_allowed + approval gate.
    // N7: route through sendActionWithSignatureRetry.
    func macRunAppleScript(script: String, timeout: Int = 30) async throws -> String {
        let action = InboxAction.make(action: "mac_control", payload: [
            "method": "runAppleScript", "script": script, "timeout": "\(timeout)"
        ])
        return try await macControlResult(action, pollTimeoutSeconds: Double(max(timeout, 30)) + 90)
    }

    /// Run a self-test on the Mac control surface (safe read-only ops only).
    // N7: route through sendActionWithSignatureRetry.
    func macSelfTest() async throws -> String {
        let action = InboxAction.make(action: "mac_control", payload: ["method": "selfTest"])
        return try await macControlResult(action)
    }

    // Phase 13 (item 4): macSpotlight and macShortcut iCloud routing helpers.
    // These mirror the existing macNotify / macLockScreen pattern:
    //   - HMAC-signed via sendActionWithSignatureRetry
    //   - mac_control action envelope → MacSyncEngine → Swift Mac-control dispatcher
    // MacSyncEngine already maps "runShortcut" to the Swift shortcut handler.
    // The Mac-side Spotlight handler runs mdfind through the native action path.

    /// Run a Spotlight search on the Mac and return a newline-separated list of result paths.
    /// The response arrives asynchronously via the iCloud inbox/responses flow.
    // Route: "mac_control" action, method="runSpotlight", query=<query>
    // Mac dispatch: MacSyncEngine maps "runSpotlight" to the Swift Spotlight handler.
    func macSpotlight(query: String, hoursAhead: Int? = nil, limit: Int? = nil) async throws -> String {
        var payload: [String: String] = ["method": "runSpotlight", "query": query]
        if let h = hoursAhead { payload["hours_ahead"] = "\(h)" }
        if let l = limit { payload["limit"] = "\(l)" }
        let action = InboxAction.make(action: "mac_control", payload: payload)
        return try await macControlResult(action)
    }

    /// Run a named macOS Shortcut on the Mac (alias for macRunShortcut for parity naming).
    /// Prefer macRunShortcut(name:input:) for full control; this is a convenience wrapper.
    func macShortcut(name: String, input: String? = nil) async throws -> String {
        return try await macRunShortcut(name: name, input: input)
    }

    // MARK: - Provider control (iOS → Mac inbox-routed; keys never leave the Mac)
    // PATCH-2026-05-07: leftover-1 provider inbox helpers — API keys stored on Mac only

    /// Configure a provider on the Mac (e.g. save an API key). The key travels via iCloud inbox → Mac only.
    // N7: route through sendActionWithSignatureRetry.
    @discardableResult
    func configureProvider(providerId: String, apiKey: String? = nil, authMode: String? = nil) async throws -> String {
        var payload: [String: String] = ["providerId": providerId]
        if let k = apiKey, !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SyncError.unsupported("API keys cannot be sent through iCloud. Open NativeAgent on the Mac to save provider keys locally.")
        }
        if let m = authMode { payload["auth_mode"] = m }
        let action = InboxAction.make(action: "configure_provider", payload: payload)
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action))
        return result["result"] ?? result["status"] ?? ""
    }

    /// Run a connection test for a provider on the Mac. Result arrives in responses/<msgId>.json.
    // N7: route through sendActionWithSignatureRetry.
    @discardableResult
    func testProvider(providerId: String) async throws -> String {
        let action = InboxAction.make(action: "test_provider", payload: ["providerId": providerId])
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action))
        return result["result"] ?? result["status"] ?? ""
    }

    /// Remove credentials for a provider on the Mac.
    // N7: route through sendActionWithSignatureRetry.
    @discardableResult
    func clearProvider(providerId: String) async throws -> String {
        let action = InboxAction.make(action: "clear_provider", payload: ["providerId": providerId])
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action))
        return result["result"] ?? result["status"] ?? ""
    }

    /// Set the active provider for a surface on the Mac.
    // N7: route through sendActionWithSignatureRetry.
    @discardableResult
    func setActiveProvider(surface: String, providerId: String) async throws -> String {
        let action = InboxAction.make(action: "set_active_provider", payload: [
            "surface": surface, "provider_id": providerId
        ])
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action))
        return result["result"] ?? result["status"] ?? ""
    }

    @discardableResult
    func setSurfaceModel(
        surface: String,
        model: String,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil
    ) async throws -> String {
        var payload: [String: String] = [
            "surface": surface,
            "model": model
        ]
        if let reasoningEffort {
            payload["reasoning_effort"] = reasoningEffort
        }
        if let serviceTier {
            payload["service_tier"] = serviceTier
        }
        let action = InboxAction.make(action: "set_surface_model", payload: payload)
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action))
        return result["result"] ?? result["status"] ?? ""
    }

    /// Atomically commit the complete execution tuple to the Mac-owned
    /// ProviderRouting transaction. Chat metadata is not routing authority.
    @discardableResult
    func configureSurfaceSelection(
        surface: String,
        providerId: String,
        model: String,
        reasoningEffort: String,
        serviceTier: String
    ) async throws -> String {
        let action = InboxAction.make(action: "configure_surface_selection", payload: [
            "surface": surface,
            "provider_id": providerId,
            "model": model,
            "reasoning_effort": reasoningEffort,
            "service_tier": serviceTier,
        ])
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action))
        return result["result"] ?? result["status"] ?? ""
    }

    /// Mutate Mac integration authority through the signed action ledger and
    /// return the canonical read-back tuple from the Mac owner.
    func setMacIntegrationPermission(
        id: String,
        read: Bool,
        write: Bool
    ) async throws -> (read: Bool, write: Bool) {
        let action = InboxAction.make(action: "set_mac_integration_permission", payload: [
            "id": id,
            "read": String(read),
            "write": String(write),
        ])
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action))
        func exactBool(_ key: String) throws -> Bool {
            switch result[key]?.lowercased() {
            case "true": return true
            case "false": return false
            default:
                throw SyncError.persistence("Mac integration response omitted canonical \(key) state")
            }
        }
        return (try exactBool("read"), try exactBool("write"))
    }

    @discardableResult
    func cancelChat(sessionId: String?, source: String? = nil, sourceKey: String?) async throws -> String {
        var payload: [String: String] = [:]
        if let sessionId, !sessionId.isEmpty {
            payload["sessionId"] = sessionId
        }
        if let source, !source.isEmpty {
            payload["source"] = source
        }
        if let sourceKey, !sourceKey.isEmpty {
            payload["sourceKey"] = sourceKey
        }
        guard !payload.isEmpty else {
            throw SyncError.unsupported("No chat session or device source key is available to cancel")
        }
        let action = InboxAction.make(action: "cancelChat", payload: payload)
        let result = try requireSuccessfulActionResponse(
            await sendActionWithSignatureRetry(
                action,
                pollTimeoutSeconds: 8,
                pollIntervalSeconds: 0.35
            )
        )
        return result["status"] ?? result["result"] ?? ""
    }

    /// Remove a tab through the signed Mac-owned pin mutation seam. This does
    /// not archive or delete the underlying chat session.
    @discardableResult
    func unpinChatSession(sessionId: String) async throws -> String {
        let clean = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw SyncError.unsupported("No pinned chat session is available to close")
        }
        let action = InboxAction.make(
            action: "unpinChatSession",
            payload: ["sessionId": clean]
        )
        let result = try requireSuccessfulActionResponse(
            await sendActionWithSignatureRetry(
                action,
                pollTimeoutSeconds: 8,
                pollIntervalSeconds: 0.35
            )
        )
        return result["status"] ?? result["result"] ?? ""
    }
}
