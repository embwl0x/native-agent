import Darwin
import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `iCloudSyncEngine+Actions.swift` | Signed submissions, verified response settlement and event-held action waits |

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

    /// Capture pairing before off-main signing/I/O; unsigned actions must never enter transport.
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
        guard iCloudBridge.shared.usesCloudKitDeviceTransport else { throw SyncError.notSetup }
        let prepared = try await retainedCloudKitAction(
            deviceAction, secret: secret, intentionalNewRequest: intentionalNewRequest
        )
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
                throw SyncError.responseUnconfirmed("""
                    The original action remains unresolved, and its local receipt could not be saved: \(error.localizedDescription). Check the Mac before \
                    submitting new work.
                    """)
            }
            throw error
        }

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
                let message = """
                    Mac action delivery is not confirmed (\(sendError.localizedDescription)); its local receipt could not be saved \
                    (\(error.localizedDescription)). Keep the original request identity and check the Mac before submitting new work.
                    """
                syncError = message
                throw SyncError.responseUnconfirmed(message)
            }
            syncError = "Couldn't confirm it arrived — waiting for the original action's response. Retry keeps the same action."
            return action.msgId
        }
    }


    /// Receipt ACK proves process delivery only, never banner display or user attention; failed ACK leaves Mac prediction pending to expire.
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

    /// Automatic sends may settle previous-pairing responses without a UI warning; a missing response remains unavailable.
    func pollResponse(msgId: String, expectedAction: String? = nil,
                      settlesAnswersFromPreviousPairing: Bool = false, budget: OperationWaitBudget = .init()) async throws -> [String: String]? {
        do {
            return try await readActionResponse(msgId: msgId, expectedAction: expectedAction,
                settlesAnswersFromPreviousPairing: settlesAnswersFromPreviousPairing, budget: budget)
        } catch {
            let message = """
                Response evidence for \(msgId) is unavailable: \(error.localizedDescription). The action remains unresolved; check Connection in Settings and \
                the Mac before submitting new work.
                """
            syncError = message
            throw SyncError.responseUnconfirmed(message)
        }
    }

    private func readActionResponse(msgId: String, expectedAction: String?,
                                   settlesAnswersFromPreviousPairing: Bool, budget: OperationWaitBudget) async throws -> [String: String]? {
        let generation = lifecycleGeneration
        guard UUID(uuidString: msgId) != nil else { throw SyncError.persistence("Invalid response message identity.") }
        guard let responsesDir else { throw SyncError.notSetup }
        let fileURL = responsesDir.appendingPathComponent("\(msgId).json")
        let secret = pairingStore?.iCloudPairingSecret
        let response = try await VolumeIO.run(budget: budget) { () -> (decoded: [String: String], signatureVerified: Bool)? in
            guard let data = try Self.readActionMailboxFile(at: fileURL) else { return nil }
            let decoded = try JSONDecoder().decode([String: String].self, from: data)
            let signatureVerified: Bool
            if let secret, let signature = decoded["signature"] {
                signatureVerified = BridgeMessage.innerActionSignatureError(data: data, signature: signature, secret: { secret }) == nil
            } else {
                signatureVerified = false
            }
            return (decoded, signatureVerified)
        }
        guard generation == lifecycleGeneration else { throw CancellationError() }
        guard pairingStore?.isRepairingConnection != true else { throw SyncError.busy("Connection repair is in progress.") }
        guard let (decoded, signatureVerified) = response else { return nil }
        guard decoded["msgId"] == msgId,
              let transactionId = decoded["transactionId"], UUID(uuidString: transactionId) != nil,
              let responseAction = decoded["action"], !responseAction.isEmpty,
              expectedAction == nil || responseAction == expectedAction else {
            throw SyncError.persistence("Mac response omitted or mismatched its message, transaction or action identity.")
        }
        if let pending = try await pendingCloudKitAction(msgId: msgId, budget: budget) {
            guard pending.transactionId == transactionId, pending.action == responseAction else {
                throw SyncError.persistence("Mac response does not match the retained signed request.")
            }
        }
        guard generation == lifecycleGeneration else { throw CancellationError() }
        guard pairingStore?.isRepairingConnection != true else { throw SyncError.busy("Connection repair is in progress.") }
        guard secret == pairingStore?.iCloudPairingSecret else { throw CancellationError() }
        guard secret != nil else {
            throw SyncError.persistence("iCloud response could not be verified — pairing key is missing.")
        }
        guard decoded["signature"] != nil else {
            throw SyncError.persistence("Unsigned iCloud response rejected. Re-pair iPhone with the current Mac app.")
        }
        if !signatureVerified {
            if settlesAnswersFromPreviousPairing {
                // Mailbox responses were verified on arrival; replaced-key answers settle through the ledger without deleting bytes or changing retry identity.
                try await settleAnswerFromPreviousPairing(
                    msgId: msgId,
                    transactionId: transactionId,
                    action: responseAction,
                    budget: budget
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
                msgId: msgId,
                budget: budget
            )
        } catch {
            throw SyncError.persistence("iCloud response was verified but its transaction receipt could not be persisted: \(error.localizedDescription)")
        }
        // Verified response does not imply terminal execution; retain the original envelope until a terminal outcome arrives.
        if Self.isTerminalTransactionState(state) {
            do {
                try await retirePendingCloudKitAction(msgId: msgId, budget: budget)
            } catch {
                throw SyncError.persistence(
                    "The terminal action response was saved, but its pending envelope could not be retired: \(error.localizedDescription)")
            }
        }
        return verified
    }

    /// Await this exact request's response; return refusal unchanged because only the user can choose a new submission.
    func sendActionAndWait(
        _ action: InboxAction,
        intentionalNewRequest: Bool = false
    ) async throws -> [String: String] {
        let msgId = try await sendAction(action, intentionalNewRequest: intentionalNewRequest)
        return try await awaitResponse(msgId: msgId, expectedAction: action.action)
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
            throw SyncError.responseUnconfirmed(response["message"]
                ?? "The Mac has not confirmed this action's outcome. Check the Mac before submitting new work.")
        }
        if InboxAction.responseResultClass(response) != "succeeded" || explicitlyUnapplied {
            throw SyncError.macRejected(response["message"] ?? error ?? "Mac rejected the action.")
        }
        return response
    }

    /// Keep the exact request open until its signed response arrives or its owner cancels.
    func awaitResponse(
        msgId: String,
        expectedAction: String? = nil
    ) async throws -> [String: String] {
        let generation = lifecycleGeneration
        let waiters = ActionResponseWaiters.shared
        waiters.arm(msgId)
        defer { waiters.disarm(msgId) }
        await iCloudBridge.shared.pollIncomingNow()
        while true {
            if Task.isCancelled || generation != lifecycleGeneration { throw CancellationError() }
            waiters.consumeArrival(msgId)
            if let resp = try await pollResponse(msgId: msgId, expectedAction: expectedAction) {
                guard generation == lifecycleGeneration else { throw CancellationError() }
                return resp
            }
            // The wait belongs to whoever asked: a page row, a composer, a setting. Housekeeping has no one watching it.
            guard await waiters.wait(msgId) else { throw CancellationError() }
            try Task.checkCancellation()
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
        // Stop names only runs still holding this session; later turns must not inherit cancellation.
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
            await sendActionAndWait(action)
        )
        return result["status"] ?? result["result"] ?? ""
    }

    /// Steer targets the working turn through Mac control; only the Mac evidences acceptance and its eventual outcome.
    func steerChat(sessionId: String, runId: String, text: String) async throws -> Bool {
        let action = InboxAction.make(action: "steerChat", payload: [
            "sessionId": sessionId, "runId": runId, "text": text, "routeKey": ChatRuntimeControls.deviceSourceKey,
        ])
        let result = try requireSuccessfulActionResponse(
            await sendActionAndWait(action))
        return result["steered"] == "true"
    }

    /// Unpin through the signed Mac owner without archiving/deleting the underlying conversation.
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
            await sendActionAndWait(action)
        )
        return result["status"] ?? result["result"] ?? ""
    }
}
