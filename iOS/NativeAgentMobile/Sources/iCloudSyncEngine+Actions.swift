import Darwin
import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `iCloudSyncEngine+Actions.swift` | Signed action submission, send serialization and connection-repair admission; response verification, correlation, settlement and bounded arrival waiting |

private let decisionActionPollTimeoutSeconds: Double = 300
private let decisionActionPollIntervalSeconds: Double = 0.75

extension iCloudSyncEngine {
    private func beginSendAction(transaction: String) throws {
        guard pairingStore?.isRepairingConnection != true else {
            throw SyncError.busy("Connection repair is in progress.")
        }
        guard sendingTransactions.insert(transaction).inserted else {
            throw SyncError.busy("This Mac action is already sending; wait for its receipt.")
        }
    }

    func requireIdleActionForConnectionRepair() throws {
        guard sendingTransactions.isEmpty else {
            throw SyncError.busy("A Mac action is still sending. Wait for it to finish, then repair the connection.")
        }
    }

    /// Submit a signed envelope and return its message ID for response waiting.
    /// Capture pairing before off-main signing and I/O; unsigned actions are rejected.
    @discardableResult
    func sendAction(_ action: InboxAction, intentionalNewRequest: Bool = false) async throws -> String {
        let requestedTransaction = action.transactionId ?? action.msgId
        try beginSendAction(transaction: requestedTransaction)
        var retainedTransaction: String?
        defer {
            sendingTransactions.remove(requestedTransaction)
            if let retainedTransaction { sendingTransactions.remove(retainedTransaction) }
        }

        guard let secret = pairingStore?.iCloudPairingSecret else {
            let msg = IOSPairingPresentation.notSignedSyncMessage
            syncError = msg
            print("[iCloudSyncEngine] \(msg)")
            throw SyncError.notSigned
        }

        let lifecycle = lifecycleGeneration
        var deviceAction = action
        let deviceKey = try await PhoneSigningIdentity.shared.key()
        deviceAction.clientId = DeviceApprovalSignature.deviceID(publicKey: deviceKey.publicKey.rawRepresentation)
        deviceAction.devicePublicKey = deviceKey.publicKey.rawRepresentation.base64EncodedString()

        guard lifecycle == lifecycleGeneration, secret == pairingStore?.iCloudPairingSecret else { throw SyncError.notSigned }
        let usesCloudKit = iCloudBridge.shared.usesCloudKitDeviceTransport
        let prepared: (InboxAction, Data, Bool)
        if usesCloudKit {
            prepared = try await retainedCloudKitAction(
                deviceAction, secret: secret, intentionalNewRequest: intentionalNewRequest
            )
        } else {
            prepared = (deviceAction, try await PhoneSigningIdentity.shared.signedActionData(deviceAction, secret: secret), false)
        }
        guard lifecycle == lifecycleGeneration, secret == pairingStore?.iCloudPairingSecret else { throw SyncError.notSigned }
        let (action, signedData, wasRetained) = prepared
        let transactionId = action.transactionId ?? action.msgId
        if transactionId != requestedTransaction {
            try beginSendAction(transaction: transactionId)
            retainedTransaction = transactionId
        }
        do {
            try await writeTransaction(id: transactionId, action: action.action, state: "queued", attempts: 1, msgId: action.msgId)
        } catch {
            if wasRetained {
                throw SyncError.responseUnconfirmed("The original action remains unresolved, and its local receipt could not be saved: \(error.localizedDescription). Check the Mac before submitting new work.")
            }
            throw error
        }

        if usesCloudKit {
            if try await pollResponse(msgId: action.msgId, expectedAction: action.action) != nil {
                return action.msgId
            }
            var accepted = false
            do {
                try await iCloudBridge.shared.sendActionEnvelope(
                    signedData,
                    actionID: action.msgId
                )
                accepted = true
                try await writeTransaction(
                    id: transactionId,
                    action: action.action,
                    state: "sent",
                    attempts: 1
                )
                return action.msgId
            } catch {
                let sendError = error
                if !wasRetained && !accepted && !(sendError is DeviceSyncSendOutcomeUnknown) {
                    try await persistTerminalSendFailure(
                        transactionID: transactionId,
                        action: action.action,
                        sendError: sendError
                    )
                    try await retirePendingCloudKitAction(msgId: action.msgId)
                    throw sendError
                }
                do {
                    try await writeTransaction(
                        id: transactionId, action: action.action, state: "outcome_unknown",
                        attempts: 1, error: sendError.localizedDescription
                    )
                } catch {
                    let message = "Mac action delivery is not confirmed (\(sendError.localizedDescription)); its local receipt could not be saved (\(error.localizedDescription)). Keep the original request identity and check the Mac before submitting new work."
                    syncError = message
                    throw SyncError.responseUnconfirmed(message)
                }
                syncError = "Couldn't confirm it arrived — waiting for the original action's response. Retry keeps the same action."
                return action.msgId
            }
        }

        guard let inboxDir else { throw SyncError.notSetup }
        let result = action.msgId
        do {
            try await iCloudBridge.writeDataOffMain(signedData,
                to: inboxDir.appendingPathComponent("\(action.msgId).json"),
                timeoutSeconds: 30, operation: "iCloud sendAction")
        } catch {
            let sendError = error
            let message = "Mac action delivery is not confirmed: \(sendError.localizedDescription). Keep the original request identity and check the Mac before submitting new work."
            syncError = message
            throw SyncError.responseUnconfirmed(message)
        }
        // Publication has happened; local receipt failure cannot prove non-delivery.
        kvs.set(result, forKey: "inbox_pending")
        await PairingStore.synchronizeKVSWithTimeout()
        do {
            try await writeTransaction(id: transactionId, action: action.action, state: "sent", attempts: 1)
        } catch {
            throw SyncError.responseUnconfirmed("The action was published, but its local receipt could not be saved: \(error.localizedDescription). Check the Mac before submitting new work.")
        }
        return result
    }


    /// Best-effort signed acknowledgement that one exact notification event
    /// reached the iOS process (APNS) or its signed iCloud bridge reader. This does
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
                // The Mac router requires the direction of the delivery this phone acknowledges.
                "direction": "mac_to_ios",
            ]
        )
        do {
            _ = try await sendAction(action)
        } catch {
            NSLog("[NativeAgentMobile] notification receipt send failed event=%@: %@",
                  cleanID, error.localizedDescription)
        }
    }

    /// Poll responses directory for a reply to msgId. Returns nil if not yet available.
    /// `settlesAnswersFromPreviousPairing`: the automatic sends' settle paths,
    /// which have no one to warn.
    func pollResponse(msgId: String, expectedAction: String? = nil,
                      settlesAnswersFromPreviousPairing: Bool = false) async throws -> [String: String]? {
        do {
            return try await readActionResponse(msgId: msgId, expectedAction: expectedAction,
                settlesAnswersFromPreviousPairing: settlesAnswersFromPreviousPairing)
        } catch {
            let message = "Response evidence for \(msgId) is unavailable: \(error.localizedDescription). The action remains unresolved; check Connection in Settings and the Mac before submitting new work."
            syncError = message
            throw SyncError.responseUnconfirmed(message)
        }
    }

    private func readActionResponse(msgId: String, expectedAction: String?,
                                   settlesAnswersFromPreviousPairing: Bool) async throws -> [String: String]? {
        let generation = lifecycleGeneration
        guard UUID(uuidString: msgId) != nil else { throw SyncError.persistence("Invalid response message identity.") }
        guard let responsesDir else { throw SyncError.notSetup }
        let fileURL = responsesDir.appendingPathComponent("\(msgId).json")
        let data = try await VolumeIO.run {
            try Self.readActionMailboxFile(at: fileURL)
        }
        guard generation == lifecycleGeneration else { throw CancellationError() }
        guard pairingStore?.isRepairingConnection != true else { throw SyncError.busy("Connection repair is in progress.") }
        guard let data else { return nil }
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        guard decoded["msgId"] == msgId,
              let transactionId = decoded["transactionId"], UUID(uuidString: transactionId) != nil,
              let responseAction = decoded["action"], !responseAction.isEmpty,
              expectedAction == nil || responseAction == expectedAction else {
            throw SyncError.persistence("Mac response omitted or mismatched its message, transaction or action identity.")
        }
        if let pending = try await pendingCloudKitAction(msgId: msgId) {
            guard pending.transactionId == transactionId, pending.action == responseAction else {
                throw SyncError.persistence("Mac response does not match the retained signed request.")
            }
        }
        guard let secret = pairingStore?.iCloudPairingSecret else {
            throw SyncError.persistence("iCloud response could not be verified — pairing key is missing.")
        }
        guard let signature = decoded["signature"] else {
            throw SyncError.persistence("Unsigned iCloud response rejected. Re-pair iPhone with the current Mac app.")
        }
        if BridgeMessage.innerActionSignatureError(data: data, signature: signature, secret: { secret }) != nil {
            if settlesAnswersFromPreviousPairing, prefersCloudKitSnapshotCache {
                // The CloudKit mailbox holds only responses this phone
                // verified on arrival, with the key it held then. One that
                // no longer verifies was answered under a pairing this
                // phone has since replaced: the ledger settles it, never a
                // re-pair warning about an exchange that works. Nothing is
                // deleted, so a request still waiting on it reads exactly
                // what it read before, and its retry keeps its identity.
                try await settleAnswerFromPreviousPairing(
                    msgId: msgId,
                    transactionId: transactionId,
                    action: responseAction
                )
                return nil
            } else {
                throw SyncError.persistence("iCloud response signature mismatch. Re-pair iPhone with the current Mac app.")
            }
        }
        var verified = decoded
        verified.removeValue(forKey: "signature")
        if let createdAt = verified["createdAt"],
           let timestamp = ISO8601DateFormatter().date(from: createdAt) {
            iCloudBridge.shared.recordMacConfirmation(at: timestamp)
        }
        verified["result_class"] = InboxAction.responseResultClass(verified)
        let state = InboxAction.responseTransactionState(verified)
        do {
            try await writeTransaction(
                id: transactionId,
                action: responseAction,
                state: state,
                error: verified["error"] ?? verified["message"],
                response: verified,
                msgId: msgId
            )
        } catch {
            throw SyncError.persistence("iCloud response was verified but its transaction receipt could not be persisted: \(error.localizedDescription)")
        }
        // A verified response can still leave execution unsettled. Keep its
        // original signed envelope until the Mac supplies a terminal outcome.
        if Self.isTerminalTransactionState(state) {
            do {
                try await retirePendingCloudKitAction(msgId: msgId)
            } catch {
                throw SyncError.persistence("The terminal action response was saved, but its pending envelope could not be retired: \(error.localizedDescription)")
            }
        }
        return verified
    }

    /// Submit exactly this request and await its original response. A refusal
    /// is returned unchanged; only the person can choose a new submission.
    func sendActionAndWait(
        _ action: InboxAction,
        intentionalNewRequest: Bool = false,
        pollTimeoutSeconds: Double = 30,
        pollIntervalSeconds: Double = 0.5
    ) async throws -> [String: String] {
        let msgId = try await sendAction(action, intentionalNewRequest: intentionalNewRequest)
        return try await pollWithTimeout(msgId: msgId, timeout: pollTimeoutSeconds,
                                         interval: pollIntervalSeconds, expectedAction: action.action)
    }

    func sendDecisionActionAndWait(_ action: InboxAction) async throws -> [String: String] {
        try await sendActionAndWait(
            action, pollTimeoutSeconds: decisionActionPollTimeoutSeconds,
            pollIntervalSeconds: decisionActionPollIntervalSeconds)
    }

    func requireSuccessfulActionResponse(_ response: [String: String]) throws -> [String: String] {
        let status = (response["status"] ?? "").lowercased()
        let error = response["error"] ?? response["code"]
        let explicitlyUnapplied = response["applied"]?.lowercased() == "false"
        if status == "orphaned" {
            throw SyncError.macRejected(
                response["message"]
                    ?? "This privileged Mac action was orphaned before it could run. Re-run it from iPhone."
            )
        }
        if status == "pending_approval" || status == "approval_required" {
            throw SyncError.approvalRequired(
                response["message"] ?? error ?? "This action is waiting for approval on the Mac.",
                approvalID: response["approvalId"] ?? response["approval_id"]
            )
        }
        if InboxAction.responseResultClass(response) == "unknown" {
            throw SyncError.responseUnconfirmed(response["message"] ?? "The Mac has not confirmed this action's outcome. Check the Mac before submitting new work.")
        }
        if InboxAction.responseResultClass(response) != "succeeded" || explicitlyUnapplied {
            throw SyncError.macRejected(response["message"] ?? error ?? "Mac rejected the action.")
        }
        return response
    }

    /// Waits on local arrival with bounded transport backstops. Unreadable or
    /// rejected evidence ends this wait explicitly and remains retained.
    func pollWithTimeout(
        msgId: String,
        timeout: Double,
        interval: Double,
        expectedAction: String? = nil
    ) async throws -> [String: String] {
        let generation = lifecycleGeneration
        guard timeout.isFinite, timeout >= 0, interval.isFinite, interval > 0,
              UInt64(exactly: (timeout * 1_000_000_000).rounded(.towardZero)) != nil,
              UInt64(exactly: (interval * 1_000_000_000).rounded(.towardZero)) != nil else {
            throw SyncError.persistence("The Mac response waiting interval is invalid.")
        }
        let deadline = Date().addingTimeInterval(timeout)
        let waiters = ActionResponseWaiters.shared
        let backstop = ActionResponseWaiters.backstopInterval
        var lastDrainAt = Date.distantPast
        waiters.arm(msgId)
        defer { waiters.disarm(msgId) }
        while Date() < deadline {
            if Task.isCancelled || generation != lifecycleGeneration { throw CancellationError() }
            if let resp = try await pollResponse(msgId: msgId, expectedAction: expectedAction) {
                guard generation == lifecycleGeneration else { throw CancellationError() }
                return resp
            }
            let now = Date()
            // A signalled arrival is already durable locally, so only an
            // unpushed backstop window has to pay for a drain.
            if iCloudBridge.shared.usesCloudKitDeviceTransport,
               !waiters.hasArrived(msgId),
               now.timeIntervalSince(lastDrainAt) >= backstop {
                lastDrainAt = now
                await iCloudBridge.shared.pollIncomingNow()
                continue
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            let delay = iCloudBridge.shared.usesCloudKitDeviceTransport
                ? (waiters.hasArrived(msgId) ? backstop : max(0, backstop - now.timeIntervalSince(lastDrainAt))) : interval
            let tick = min(delay, remaining)
            if waiters.hasArrived(msgId) {
                // An arrival signal can outlive its file. Pay the interval
                // rather than spin on the retained signal; bad bytes already
                // leave this wait through the checked reader above.
                guard let delay = UInt64(exactly: (max(0, tick) * 1_000_000_000).rounded(.towardZero)) else {
                    throw SyncError.persistence("The Mac response waiting interval is invalid.")
                }
                try await Task.sleep(nanoseconds: delay)
            } else {
                // Wakes early on a push; otherwise ticks the cheap local read.
                _ = await waiters.wait(msgId, timeout: tick)
            }
            try Task.checkCancellation()
        }
        guard generation == lifecycleGeneration else { throw CancellationError() }
        try Task.checkCancellation()
        do {
            let pending = try await pendingCloudKitAction(msgId: msgId)
            throw SyncError.responseUnconfirmed(pending != nil
                ? "Your Mac hasn't confirmed this yet. The original request is retained; check the Mac before submitting new work."
                : "The Mac response is not confirmed after \(Self.timeoutLabel(timeout))s. Check the Mac before submitting new work.")
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.responseUnconfirmed("The Mac response is not confirmed, and the retained request could not be read: \(error.localizedDescription). Check the Mac before submitting new work.")
        }
    }

    @discardableResult
    func cancelChat(
        sessionId: String?,
        source: String? = nil,
        sourceKey: String?,
        runIDs: [String] = []
    ) async throws -> String {
        var payload: [String: String] = [:]
        if let sessionId, !sessionId.isEmpty {
            payload["sessionId"] = sessionId
        }
        // The runs this Stop is for. The Mac cancels a named run only while it
        // still holds the session; a later turn is not this Stop's business.
        let namedRuns = runIDs.filter { !$0.isEmpty }
        if !namedRuns.isEmpty {
            payload["runId"] = namedRuns.joined(separator: ",")
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
            await sendActionAndWait(
                action,
                pollTimeoutSeconds: 8,
                pollIntervalSeconds: 0.35
            )
        )
        return result["status"] ?? result["result"] ?? ""
    }

    /// The phone's Steer, on the Mac's control lane. True when the turn
    /// working in that chat took it; the Mac then says how it ended.
    func steerChat(sessionId: String, runId: String, text: String) async throws -> Bool {
        let action = InboxAction.make(action: "steerChat", payload: [
            "sessionId": sessionId, "runId": runId, "text": text, "routeKey": ChatRuntimeControls.deviceSourceKey,
        ])
        let result = try requireSuccessfulActionResponse(
            await sendActionAndWait(action, pollTimeoutSeconds: 8, pollIntervalSeconds: 0.35))
        return result["steered"] == "true"
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
            await sendActionAndWait(
                action,
                pollTimeoutSeconds: 8,
                pollIntervalSeconds: 0.35
            )
        )
        return result["status"] ?? result["result"] ?? ""
    }
}
