import CommonCrypto
import CryptoKit
import AppKit
import Cognition
import Foundation
import NativeAgentShared
import NativeAgentCore
import MemoryV2
import PersistenceCore
// Blueprint: | `MacSyncEngine+Inbox.swift` | CloudKit actions use ledger admission, replay, recovery and settlement. |

extension MacSyncEngine {

    /// CloudKit actions use ledger admission before freshness and reserve immediately before dispatch.
    private func inboxTransactionDecision(
        _ action: InboxAction, transactionId: String, digest: String?, envelopeFreshnessError: String? = nil
    ) async -> (record: ICloudTransactionRecord?, executed: Bool,
                refusal: (code: String, message: String)?, freshnessError: String?) {
        let lookup = await readTransaction(id: transactionId)
        let processed = processedMsgIds.contains(action.msgId)
        var prior: ICloudTransactionRecord?
        var refusal: (code: String, message: String)?
        switch lookup {
        case .absent:
            if processed {
                refusal = ("unknown_outcome", "Mac no longer has a verified result for this command, so it was not run again.")
            }
        case .unreadable:
            refusal = ("unknown_outcome", "Mac could not read the durable record for this command, so it was not run again.")
        case .present(var record):
            let processedBinding = record.id == transactionId && record.direction == "ios_to_mac"
                && record.msgId == action.msgId && digest != nil && record.actionDigest == digest
                && record.action == action.action && Self.inboxActionDidExecute(record.state)
            if Self.inboxLedgerRow(record, matchesMsgId: action.msgId, digest: digest, action: action.action),
               !processed || processedBinding {
                record.response = await retainedInboxResponse(action, record: record, digest: digest)
                prior = record
            } else {
                refusal = (
                    "transaction_id_collision",
                    """
                        This command carries a transaction id that already belongs to a different command, so it was refused rather than answered with that \
                        command's result.
                        """)
            }
        }
        let executed = prior.map { Self.inboxActionDidExecute($0.state) } ?? false
        return (prior, executed, refusal,
                refusal == nil && !executed ? inboxActionFreshnessError(action) ?? envelopeFreshnessError : nil)
    }

    /// Only a strictly bound executed row may recover its missing result from a signed response file.
    private func retainedInboxResponse(
        _ action: InboxAction, record: ICloudTransactionRecord, digest: String?
    ) async -> [String: String]? {
        if let response = record.response { return response }
        let transactionId = action.transactionId ?? action.msgId
        if record.id == transactionId, record.direction == "ios_to_mac",
           record.msgId == action.msgId, let digest, record.actionDigest == digest,
           record.action == action.action, Self.inboxActionDidExecute(record.state),
           let responsesDir, let transactionDir,
           let responseURL = InboxActionFileBoundary.jsonURL(in: responsesDir, validatedID: action.msgId) {
            let savedData = await Task.detached(priority: .utility) {
                Self.coordinatedRead(at: responseURL)
            }.value
            if let savedData,
               let saved = try? JSONDecoder().decode([String: String].self, from: savedData),
               saved["msgId"] == action.msgId, saved["transactionId"] == transactionId,
               saved["action"] == action.action, saved["status"] != nil,
               authenticateInboxResponse(saved) {
                await settleInboxAction(action, transactionId: transactionId, response: saved, directory: transactionDir)
                return saved
            }
        }
        return nil
    }

    /// The ledger owns replay; missing retained results remain uncertain and response files cannot override them.
    private func replayInboxResponse(
        _ action: InboxAction, record: ICloudTransactionRecord?, refusal: (code: String, message: String)?
    ) throws -> [String: String] {
        if refusal == nil, let response = record?.response { return response }
        let body = ["status": "error", "ok": "false",
                    "code": refusal?.code ?? "unknown_outcome",
                    "message": refusal?.message ?? "Mac could not confirm whether this command completed, so it was not retried automatically.",
                    "msgId": action.msgId, "transactionId": action.transactionId ?? action.msgId, "action": action.action]
        return try signedResponse(body)
    }

    private func reserveAndRunInboxAction(
        _ action: InboxAction, transactionId: String, digest: String?, generation: UInt64, directory: URL
    ) async -> (reserved: Bool, response: [String: String]?)? {
        guard isActive, generation == snapshotLifecycleGeneration else { return nil }
        guard let reservation = await writeTransaction(id: transactionId, action: action.action, state: "running",
                                     attempts: 1, msgId: action.msgId, actionDigest: digest, directory: directory) else {
            guard isActive, generation == snapshotLifecycleGeneration else { return nil }
            return (false, nil)
        }
        guard isActive, generation == snapshotLifecycleGeneration else {
            await releaseUndispatchedInboxAction(reservation)
            return nil
        }
        let body = await dispatchAction(action)
        do { return (true, try deliverableActionResponse(body, for: action)) }
        catch {
            if generation == snapshotLifecycleGeneration { syncError = "Action response failed for \(action.msgId): \(error.localizedDescription)" }
            return (true, nil)
        }
    }

    private func settleInboxAction(_ action: InboxAction, transactionId: String, response: [String: String], directory: URL) async {
        await writeTransaction(id: transactionId, action: action.action, state: InboxAction.responseTransactionState(response),
                               attempts: 1, error: response["message"], response: response, directory: directory)
    }

    /// Failed response readback must keep the command pending.
    func writeInboxResponse(_ response: [String: String], to responseURL: URL) async -> Bool {
        let responseData: Data
        do {
            responseData = try JSONEncoder().encode(response)
        } catch {
            nativeLog("MacSyncEngine.writeInboxResponse: encode failed for %@: %@",
                  responseURL.lastPathComponent, String(describing: error))
            return false
        }
        for attempt in 1...2 {
            // A landed response decodes from disk to exactly the values written.
            let landed = await Task.detached(priority: .utility) { [responseURL, responseData] () -> Bool in
                guard Self.coordinatedWriteReturningError(data: responseData, to: responseURL) == nil else { return false }
                guard let readBack = Self.coordinatedRead(at: responseURL),
                      let decoded = try? JSONDecoder().decode([String: String].self, from: readBack)
                else { return false }
                return decoded == response
            }.value
            if landed { return true }
            nativeLog("MacSyncEngine.writeInboxResponse: attempt %d did not land %@",
                  attempt, responseURL.lastPathComponent)
        }
        return false
    }

    /// CloudKit outer verification cannot replace inner HMAC, freshness, idempotency, Trust, receipt or response-signing checks.
    func processCloudKitActionMessage(_ message: BridgeMessage) async -> Bool {
        guard isActive else { return false }
        let generation = snapshotLifecycleGeneration
        let actionStateRoot = PersistenceCore.defaultDataRoot()
        guard message.sender == "ios" else {
            return true
        }
        guard message.metadata?["kind"] == "icloud_action",
              let declaredID = message.metadata?["actionId"],
              let data = message.text.data(using: .utf8) else {
            return true
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let action = try? decoder.decode(InboxAction.self, from: data),
              let ids = InboxActionFileBoundary.validatedIDs(for: action),
              ids.messageID == declaredID else {
            return true
        }
        if let handled = await authenticateCloudKitAction(action, data: data, message: message, generation: generation) {
            return handled
        }
        return await processAuthenticatedCloudKitAction(
            action, ids: ids, data: data, message: message, generation: generation, actionStateRoot: actionStateRoot
        )
    }

    /// A terminal result is present only when authentication ends processing.
    private func authenticateCloudKitAction(
        _ action: InboxAction, data: Data, message: BridgeMessage, generation: UInt64
    ) async -> Bool? {
        // Authenticate the inner envelope before consulting any ID-owned state.
        let authenticationError: String?
        if let signature = action.signature {
            authenticationError = BridgeMessage.innerActionSignatureError(data: data, signature: signature, secret: pairingSecret)
        } else {
            authenticationError = "missing signature"
        }
        guard isActive, generation == snapshotLifecycleGeneration else { return false }
        if let authenticationError {
            // This Mac's own missing secret is its storage to repair; any other failure is the phone signing with a key this Mac does not hold.
            if authenticationError.contains("pairing secret unavailable") {
                syncError = "Rejected CloudKit action: \(authenticationError)"
                return false
            }
            await sync.bridge.notePhoneRejected(at: message.timestamp)
            await sync.bridge.answerUnverifiablePhoneMessage(message.id)
            return true
        }
        return nil
    }

    private func processAuthenticatedCloudKitAction(
        _ action: InboxAction, ids: ValidatedInboxActionIDs, data: Data, message: BridgeMessage,
        generation: UInt64, actionStateRoot: URL
    ) async -> Bool {
        guard isActive, generation == snapshotLifecycleGeneration, let responsesDir, let transactionDir,
              let responseURL = InboxActionFileBoundary.jsonURL(
                in: responsesDir,
                validatedID: ids.messageID
              ) else { return false }

        let transactionId = ids.transactionID
        let actionDigest = Self.inboxActionDigest(envelope: data)
        let envelopeAge = Date().timeIntervalSince(message.timestamp)
        let envelopeFreshnessError: String? = envelopeAge > 24 * 60 * 60
            ? "message too old: \(Int(envelopeAge))s"
            : (envelopeAge < -15 * 60 ? "timestamp is too far in the future: \(Int(-envelopeAge))s" : nil)
        let decision = await inboxTransactionDecision(action, transactionId: transactionId,
                                                      digest: actionDigest, envelopeFreshnessError: envelopeFreshnessError)
        guard isActive, generation == snapshotLifecycleGeneration else { return false }
        let priorTransaction = decision.record
        let alreadyExecuted = decision.executed
        let freshnessError = decision.freshnessError
        let refusal = decision.refusal

        // Transport may accelerate delivery, but only the shared ledger owns replay and response projection.
        if processedMsgIds.contains(action.msgId), alreadyExecuted {
            guard let response = try? replayInboxResponse(action, record: priorTransaction, refusal: nil) else { return false }
            guard await iCloudBridge.appendInboundActionSuccessReceipt(messageID: action.msgId,
                action: action.action, transport: "cloudkit", dataRoot: actionStateRoot) else {
                syncError = "Retained action inbound receipt remains owed for \(action.msgId)."
                return false
            }
            do {
                try await sync.bridge.sendCloudKitActionResponse(response, correlationID: action.msgId)
                return true
            } catch {
                syncError = "Could not resend CloudKit action response \(action.msgId): \(error.localizedDescription)"
                return false
            }
        }

        if let refusal {
            guard let signed = try? replayInboxResponse(action, record: nil, refusal: refusal) else {
                syncError = "Pairing secret unavailable; CloudKit action \(action.msgId) remains unacknowledged."
                return false
            }
            // Unreadable or conflicting identity owns both ledger and response paths; neither may be overwritten.
            do {
                try await sync.bridge.sendCloudKitActionResponse(signed, correlationID: action.msgId)
                return true
            } catch {
                syncError = "Could not send CloudKit action refusal \(action.msgId): \(error.localizedDescription)"
                return false
            }
        }

        return await settleCloudKitAction(
            action, transactionId: transactionId, actionDigest: actionDigest, generation: generation,
            actionStateRoot: actionStateRoot, transactionDir: transactionDir, responseURL: responseURL,
            alreadyExecuted: alreadyExecuted, priorTransaction: priorTransaction, freshnessError: freshnessError
        )
    }

    private func settleCloudKitAction(
        _ action: InboxAction, transactionId: String, actionDigest: String?, generation: UInt64,
        actionStateRoot: URL, transactionDir: URL, responseURL: URL, alreadyExecuted: Bool,
        priorTransaction: ICloudTransactionRecord?, freshnessError: String?
    ) async -> Bool {
        if !alreadyExecuted, freshnessError == nil {
            await writeTransaction(
                id: transactionId,
                action: action.action,
                state: "received",
                attempts: 1,
                msgId: action.msgId,
                actionDigest: actionDigest
            )
        }

        let response: [String: String]
        let inboundActionVerified: Bool
        if alreadyExecuted, let priorTransaction {
            inboundActionVerified = true
            guard let retained = try? replayInboxResponse(action, record: priorTransaction, refusal: nil) else {
                syncError = "Pairing secret unavailable; CloudKit action \(action.msgId) remains unacknowledged."
                return false
            }
            response = retained
            if priorTransaction.response == nil {
                await writeTransaction(id: transactionId, action: action.action, state: "unknown",
                    attempts: 1, error: response["message"], response: response)
            }
        } else if let validationError = freshnessError {
            inboundActionVerified = false
            guard let signed = try? signedResponse([
                "status": "error",
                "ok": "false",
                "code": validationError.hasPrefix("message too old:") ? "expired_before_execution" : "invalid_action",
                "message": validationError,
                "msgId": action.msgId,
                "transactionId": transactionId,
                "action": action.action,
            ]) else {
                syncError = "Pairing secret unavailable; CloudKit action \(action.msgId) remains unacknowledged."
                return false
            }
            // Refuse stale, unexecuted work without claiming its identities or response path.
            do {
                try await sync.bridge.sendCloudKitActionResponse(signed, correlationID: action.msgId)
                return true
            } catch {
                syncError = "Could not send stale CloudKit action refusal \(action.msgId): \(error.localizedDescription)"
                return false
            }
        } else {
            inboundActionVerified = true
            if let peerCreatedAt = ISO8601DateFormatter().date(from: action.createdAt) {
                sync.bridge.notePhoneContact(at: peerCreatedAt)
                do {
                    try await SignedPeerEvidenceStore.record(
                        eventID: action.msgId,
                        channel: .inboxAction,
                        peerCreatedAt: peerCreatedAt,
                        dataRoot: actionStateRoot
                    )
                    guard isActive, generation == snapshotLifecycleGeneration else { return false }
                } catch {
                    nativeLog("[MacSyncEngine] could not persist CloudKit action peer evidence for %@: %@",
                          action.msgId, error.localizedDescription)
                }
            }
            guard let execution = await reserveAndRunInboxAction(action, transactionId: transactionId,
                digest: actionDigest, generation: generation, directory: transactionDir) else { return false }
            guard execution.reserved else {
                syncError = "Could not reserve CloudKit action \(action.msgId) durably; it was not run and remains unacknowledged."
                return false
            }
            guard let signed = execution.response else {
                return false
            }
            response = signed
            await settleInboxAction(action, transactionId: transactionId, response: response, directory: transactionDir)
        }

        return await deliverCloudKitActionResponse(
            response, action: action, responseURL: responseURL, inboundActionVerified: inboundActionVerified,
            actionStateRoot: actionStateRoot, generation: generation
        )
    }

    private func deliverCloudKitActionResponse(
        _ response: [String: String], action: InboxAction, responseURL: URL,
        inboundActionVerified: Bool, actionStateRoot: URL, generation: UInt64
    ) async -> Bool {
        // Persist before delivery so a retry sends the response without repeating the external effect.
        guard await writeInboxResponse(response, to: responseURL) else {
            if generation == snapshotLifecycleGeneration {
                syncError = "Could not persist CloudKit response for \(action.msgId); action will not be acknowledged."
            }
            return false
        }
        if inboundActionVerified {
            guard await iCloudBridge.appendInboundActionSuccessReceipt(
                messageID: action.msgId,
                action: action.action,
                transport: "cloudkit",
                dataRoot: actionStateRoot
            ) else {
                syncError = "Action result is retained; its inbound receipt remains owed for \(action.msgId)."
                return false
            }
        }
        recordProcessed(action.msgId)
        let processedSaved = await saveProcessedIds()
        let commit = await sync.storage.perform {
            Self.commitCompletionBookkeeping(dataRoot: actionStateRoot, msgId: action.msgId,
                processedSaved: processedSaved, archiveError: nil)
        }
        if !commit.clean, generation == snapshotLifecycleGeneration { syncError = commit.syncError }

        guard isActive, generation == snapshotLifecycleGeneration else { return false }
        do {
            try await sync.bridge.sendCloudKitActionResponse(response, correlationID: action.msgId)
            guard isActive, generation == snapshotLifecycleGeneration else { return false }
            lastInboxAt = Date()
            if !["chat_history_page", "faceRead", "workActivityState"].contains(action.action) {
                await writeSnapshots(forceHeavy: true)
            }
            guard isActive, generation == snapshotLifecycleGeneration else { return false }
            NotificationCenter.default.post(name: .iCloudInboxDidProcess, object: nil)
            return true
        } catch {
            guard isActive, generation == snapshotLifecycleGeneration else { return false }
            syncError = "CloudKit action completed but its response is waiting to resend: \(error.localizedDescription)"
            return false
        }
    }

    private func dispatchAction(_ action: InboxAction) async -> [String: String] {
        let router = MacSyncActionRouter(
            sync: sync,
            cancelChatTask: { [weak self] sessionId, runIDs in
                self?.cancelActiveChatTask(for: sessionId, runIDs: runIDs) ?? .noActiveTask
            }
        )
        return await router.dispatch(action)
    }
}
