import CommonCrypto
import CryptoKit
import AppKit
import Cognition
import Foundation
import NativeAgentShared
import NativeAgentCore
import MemoryV2
import PersistenceCore
// Blueprint: | `MacSyncEngine+Inbox.swift` | Both transports share ledger admission, replay, recovery and settlement. |

extension MacSyncEngine {

    /// Both transports share ledger admission before freshness and reserve immediately before dispatch.
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
        return (true, try? deliverableActionResponse(body, for: action))
    }

    private func settleInboxAction(_ action: InboxAction, transactionId: String, response: [String: String], directory: URL) async {
        await writeTransaction(id: transactionId, action: action.action, state: InboxAction.responseTransactionState(response),
                               attempts: 1, error: response["message"], response: response, directory: directory)
    }

    /// Retain ownership through cleanup; a rematerialized claim may replace it only for the same envelope.
    private func releaseUndispatchedDriveClaim(pendingURL: URL, originalURL: URL, envelope: Data) async {
        await sync.storage.perform {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            coordinator.coordinate(writingItemAt: pendingURL, options: .forMoving,
                                   writingItemAt: originalURL, options: [], error: &coordinationError) { pending, original in
                do {
                    guard try Data(contentsOf: pending) == envelope else { return }
                    if FileManager.default.fileExists(atPath: original.path) {
                        guard try Data(contentsOf: original) == envelope else { return }
                        try FileManager.default.removeItem(at: pending)
                    } else {
                        try FileManager.default.moveItem(at: pending, to: original)
                        coordinator.item(at: pending, didMoveTo: original)
                    }
                } catch {
                    nativeLog("[MacSyncEngine] Could not release undispatched Drive claim: %@", error.localizedDescription)
                }
            }
            if let coordinationError {
                nativeLog("[MacSyncEngine] Could not coordinate undispatched Drive release: %@", coordinationError.localizedDescription)
            }
        }
    }

    func authenticateInboxFile(data: Data, action: InboxAction, fileURL: URL, inboxDir: URL) async -> Bool {
        let error: String?
        if let signature = action.signature {
            error = BridgeMessage.innerActionSignatureError(data: data, signature: signature, secret: pairingSecret)
        } else {
            error = "missing signature"
        }
        guard let error else { return true }
        await quarantineUnauthenticatedInboxFile(data: data, fileURL: fileURL, inboxDir: inboxDir, reason: error)
        return false
    }

    // MARK: - KVS ping handler

    // KVS callbacks hop to MainActor before requesting inbox processing.
    @objc nonisolated func kvsDidChange(_ note: Notification) {
        let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
        guard keys.contains(KVSKey.inboxPending) || keys.contains(where: { $0.hasPrefix("inbox_pending") }) else { return }
        Task { @MainActor in
            self.requestInboxProcessing()
        }
    }

    // MARK: - Inbox watcher (NSMetadataQuery on inbox/)

    func startInboxQuery(docsURL: URL) {
        guard let inboxDir else { return }
        let q = NSMetadataQuery()
        // Exclude archived and pending files at the query boundary to avoid spurious wake-ups.
        q.predicate = NSPredicate(
            format: """
                %K BEGINSWITH %@ AND NOT (%K CONTAINS '/_rejected/') AND NOT (%K BEGINSWITH 'processed_') AND NOT (%K BEGINSWITH 'rejected_') AND NOT (%K \
                BEGINSWITH 'pending_') AND %K ENDSWITH '.json'
                """,
            NSMetadataItemPathKey,
            inboxDir.path,
            NSMetadataItemPathKey,
            NSMetadataItemFSNameKey,
            NSMetadataItemFSNameKey,
            NSMetadataItemFSNameKey,
            NSMetadataItemFSNameKey
        )
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        inboxQuery = q

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inboxQueryUpdated(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: q
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inboxQueryUpdated(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: q
        )

        q.start()
    }

    // NSMetadataQuery callbacks hop from its worker queue to MainActor before accessing state.
    @objc private nonisolated func inboxQueryUpdated(_ note: Notification) {
        let queryID = note.object.map { ObjectIdentifier($0 as AnyObject) }
        Task { @MainActor in
            guard let query = self.inboxQuery, ObjectIdentifier(query) == queryID else { return }
            self.requestInboxProcessing()
        }
    }

    /// Unauthenticated IDs grant no reservation; retain offending bytes only by digest.
    func quarantineUnauthenticatedInboxFile(data: Data, fileURL: URL, inboxDir: URL, reason: String) async {
        syncError = "Rejected inbox file \(fileURL.lastPathComponent): \(reason)"
        if reason.contains("pairing secret unavailable") { return }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let rejectedDir = inboxDir.appendingPathComponent("_rejected", isDirectory: true)
        let archiveURL = rejectedDir.appendingPathComponent("\(digest).done")
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: rejectedDir, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: fileURL, to: archiveURL)
            } catch {
                nativeLog("[MacSyncEngine] Could not quarantine unauthenticated inbox file: %@", error.localizedDescription)
            }
        }.value
    }

    /// Refuse authenticated stale work only when it has never executed.
    func rejectInboxFile(
        action: InboxAction,
        fileURL: URL,
        inboxDir: URL,
        transactionId: String,
        actionDigest: String?,
        validationError: String
    ) async {
        syncError = "Rejected inbox message \(action.msgId): \(validationError)"
        switch await readTransaction(id: transactionId) {
        case .absent:
            break
        case .present(let record):
            guard record.id == transactionId, record.direction == "ios_to_mac", record.state == "received",
                  record.msgId == action.msgId, let actionDigest,
                  record.actionDigest == actionDigest, record.action == action.action else { return }
        case .unreadable:
            return
        }
        guard await writeRejectedResponseIfNeeded(
            action: action,
            transactionId: transactionId,
            message: validationError
        ) else {
            // Consume invalid actions only after their signed rejection is durable for the peer.
            return
        }
        // Archive rejected bytes without claiming identities; .done prevents the JSON query from dispatching them.
        let archiveURL = inboxDir.appendingPathComponent("rejected_\(fileURL.lastPathComponent).done")
        await Task.detached(priority: .utility) { [fileURL, archiveURL] in
            try? FileManager.default.moveItem(at: fileURL, to: archiveURL)
        }.value
    }

    private func requestInboxProcessing() {
        guard isActive, inboxDir != nil else { return }
        inboxProcessingQueued = true
        guard inboxProcessingTask == nil else { return }
        let generation = snapshotLifecycleGeneration
        inboxProcessingTask = Task {
            defer {
                inboxProcessingTask = nil
                if inboxProcessingQueued, isActive { requestInboxProcessing() }
            }
            while inboxProcessingQueued, isActive, generation == snapshotLifecycleGeneration {
                inboxProcessingQueued = false
                await processInboxFiles(generation: generation)
            }
        }
    }

    private func processInboxFiles(generation: UInt64) async {
        guard isActive, generation == snapshotLifecycleGeneration,
              let inboxDir, let responsesDir, let transactionDir else { return }
        let fm = FileManager.default
        // startDownloadingUbiquitousItem can block while iCloud contacts servers — do it off main.
        await Task.detached(priority: .utility) { [inboxDir] in
            try? FileManager.default.startDownloadingUbiquitousItem(at: inboxDir)
        }.value
        guard isActive, generation == snapshotLifecycleGeneration else { return }

        // Reclaim response keys before listing to preserve KVS's 1,024-key/1 MB headroom; blocking file stats stay off main.
        await sweepInboxResponseKVSKeys()
        guard isActive, generation == snapshotLifecycleGeneration else { return }

        // iCloud directory listing can block, so run it off main.
        let files: [URL]
        do {
            files = try await Task.detached(priority: .utility, operation: { [inboxDir] in
                try FileManager.default.contentsOfDirectory(at: inboxDir,
                    includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
            }).value
        } catch {
            syncError = """
                The iPhone action inbox could not be listed: \(error.localizedDescription). Restore the inbox folder's access and reconnect; no new command \
                was admitted.
                """
            return
        }

        guard isActive, generation == snapshotLifecycleGeneration else { return }

        // Exclude .done archives and processed_/rejected_ names, including .json archives, from dispatch.
        let now = Date()
        for pendingURL in files where pendingURL.lastPathComponent.hasPrefix("pending_") && pendingURL.pathExtension == "json" {
            guard isActive, generation == snapshotLifecycleGeneration else { return }
            let attrs = try? fm.attributesOfItem(atPath: pendingURL.path)
            let modified = attrs?[.modificationDate] as? Date
            guard let modified, now.timeIntervalSince(modified) > 120 else { continue }
            // Reading a pending (iCloud-resident) file may block — do it off main.
            let data = await Task.detached(priority: .utility) { [pendingURL] in
                try? Data(contentsOf: pendingURL)
            }.value
            guard isActive, generation == snapshotLifecycleGeneration else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let data,
               let staleAction = try? decoder.decode(InboxAction.self, from: data),
               let ids = InboxActionFileBoundary.validatedIDs(for: staleAction),
               let responseURL = InboxActionFileBoundary.jsonURL(
                in: responsesDir,
                validatedID: ids.messageID
               ) {
                let txId = ids.transactionID
                guard await authenticateInboxFile(
                    data: data, action: staleAction, fileURL: pendingURL, inboxDir: inboxDir
                ) else { continue }
                let actionDigest = Self.inboxActionDigest(envelope: data)
                var retainedResponse: [String: String]?
                switch await readTransaction(id: txId) {
                case .absent:
                    break
                case .unreadable:
                    syncError = "Could not read the durable record for stale command \(staleAction.msgId); left pending."
                    continue
                case .present(let record):
                    guard Self.inboxLedgerRow(record, matchesMsgId: staleAction.msgId, digest: actionDigest, action: staleAction.action) else {
                        await quarantineUnauthenticatedInboxFile(
                            data: data, fileURL: pendingURL, inboxDir: inboxDir, reason: "transaction identity collision"
                        )
                        continue
                    }
                    if Self.inboxActionDidExecute(record.state) {
                        retainedResponse = await retainedInboxResponse(staleAction, record: record, digest: actionDigest)
                    }
                }
                let response: [String: String]
                if let retainedResponse {
                    response = retainedResponse
                } else {
                    do {
                        response = try replayInboxResponse(staleAction, record: nil, refusal: nil)
                    } catch {
                        syncError = "Pairing secret unavailable; stale command \(staleAction.msgId) remains pending."
                        continue
                    }
                }
                // Consume only after response readback and both required receipts.
                let responseWritten = await writeInboxResponse(response, to: responseURL)
                guard responseWritten else {
                    syncError = "Could not write iCloud response for stale command \(staleAction.msgId); left pending for retry."
                    nativeLog("MacSyncEngine.processInboxFiles: %@", syncError ?? "")
                    continue
                }
                guard await iCloudBridge.appendActionResponseDeliveryReceipt(
                    response: response, correlationID: staleAction.msgId, transport: "icloud_drive",
                    status: .queuedForICloudSync, dataRoot: sync.dataRoot
                ) else {
                    syncError = "Stale action response receipt remains owed for \(staleAction.msgId); left pending."
                    continue
                }
                guard await iCloudBridge.appendInboundActionSuccessReceipt(
                    messageID: staleAction.msgId, action: staleAction.action,
                    transport: "icloud_drive", dataRoot: sync.dataRoot
                ) else {
                    syncError = "Stale action inbound receipt remains owed for \(staleAction.msgId); left pending."
                    continue
                }
                let msgId = staleAction.msgId
                _ = await withCKTimeout("MacSyncEngine.processInboxFiles.staleResponseKVS") {
                    let kvs = NSUbiquitousKeyValueStore.default
                    kvs.set(msgId, forKey: "inbox_response_\(msgId)")
                    return kvs.synchronize()
                }
                if retainedResponse == nil {
                    await writeTransaction(
                        id: txId, action: staleAction.action, state: "unknown", error: response["message"],
                        response: response, msgId: staleAction.msgId, actionDigest: actionDigest
                    )
                }
                recordProcessed(staleAction.msgId)
                await saveProcessedIds()
                let archiveURL = inboxDir.appendingPathComponent("processed_\(pendingURL.lastPathComponent).done")
                await Task.detached(priority: .utility) { [pendingURL, archiveURL] in
                    try? FileManager.default.moveItem(at: pendingURL, to: archiveURL)
                }.value
            } else if let data {
                await quarantineUnauthenticatedInboxFile(
                    data: data, fileURL: pendingURL, inboxDir: inboxDir, reason: "malformed envelope or invalid message identity"
                )
            }
        }

        // Re-list after pending-file cleanup off main because iCloud directories can block.
        let refreshedFiles: [URL]
        do {
            refreshedFiles = try await Task.detached(priority: .utility, operation: { [inboxDir] in
                try FileManager.default.contentsOfDirectory(at: inboxDir,
                    includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
            }).value
        } catch {
            syncError = """
                The iPhone action inbox could not be listed: \(error.localizedDescription). Restore the inbox folder's access and reconnect; no new command \
                was admitted.
                """
            return
        }

        let jsonFiles = refreshedFiles.filter {
            let name = $0.lastPathComponent
            guard $0.pathExtension == "json" else { return false }
            guard !name.hasPrefix("processed_") && !name.hasPrefix("rejected_") && !name.hasPrefix("pending_") else { return false }
            return true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        var didProcessMutation = false
        for fileURL in jsonFiles {
            guard isActive, generation == snapshotLifecycleGeneration else { return }
            // Coordinated iCloud reads can block, so keep them off main.
            guard let data = await Task.detached(priority: .utility, operation: { [fileURL] in
                Self.coordinatedRead(at: fileURL)
            }).value else { continue }
            guard isActive, generation == snapshotLifecycleGeneration else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // Quarantine malformed JSON so the same bytes cannot retrigger every sync cycle.
            guard let action = try? decoder.decode(InboxAction.self, from: data) else {
                syncError = "Rejected inbox file \(fileURL.lastPathComponent): malformed JSON"
                nativeLog("[MacSyncEngine] Rejected malformed inbox file: \(fileURL.lastPathComponent)")
                let rejectedDir = inboxDir.appendingPathComponent("_rejected")
                let rejectedURL = rejectedDir.appendingPathComponent(fileURL.lastPathComponent)
                await Task.detached(priority: .utility) { [rejectedDir, fileURL, rejectedURL] in
                    try? FileManager.default.createDirectory(at: rejectedDir, withIntermediateDirectories: true)
                    try? FileManager.default.moveItem(at: fileURL, to: rejectedURL)
                }.value
                continue
            }
            guard let ids = InboxActionFileBoundary.validatedIDs(for: action) else {
                syncError = "Rejected inbox file \(fileURL.lastPathComponent): invalid message identity"
                nativeLog("[MacSyncEngine] Rejected inbox file with non-UUID identity: %@", fileURL.lastPathComponent)
                let rejectedDir = inboxDir.appendingPathComponent("_rejected")
                let rejectedURL = rejectedDir.appendingPathComponent(fileURL.lastPathComponent)
                await Task.detached(priority: .utility) { [rejectedDir, fileURL, rejectedURL] in
                    try? FileManager.default.createDirectory(at: rejectedDir, withIntermediateDirectories: true)
                    try? FileManager.default.moveItem(at: fileURL, to: rejectedURL)
                }.value
                continue
            }
            let transactionId = ids.transactionID
            let actionDigest = Self.inboxActionDigest(envelope: data)

            // Authenticate before consulting the ledger; freshness gates only new work.
            guard await authenticateInboxFile(
                data: data,
                action: action,
                fileURL: fileURL,
                inboxDir: inboxDir
            ) else {
                continue
            }

            guard isActive, generation == snapshotLifecycleGeneration else { return }
            let decision = await inboxTransactionDecision(action, transactionId: transactionId, digest: actionDigest)
            guard isActive, generation == snapshotLifecycleGeneration else { return }
            let priorTransaction = decision.record
            let alreadyExecuted = decision.executed
            let ledgerRefusal = decision.refusal

            if ledgerRefusal == nil, !alreadyExecuted,
               let staleError = decision.freshnessError {
                await rejectInboxFile(
                    action: action,
                    fileURL: fileURL,
                    inboxDir: inboxDir,
                    transactionId: transactionId,
                    actionDigest: actionDigest,
                    validationError: staleError
                )
                continue
            }

            guard isActive, generation == snapshotLifecycleGeneration else { return }
            if ledgerRefusal != nil || alreadyExecuted {
                // Refusals cannot write ledger state owned by an unreadable or conflicting action; answer without redispatch.
                guard let response = try? replayInboxResponse(action, record: priorTransaction, refusal: ledgerRefusal) else {
                    syncError = "Pairing secret unavailable; iCloud command \(action.msgId) remains unanswered."
                    continue
                }
                guard let responseURL = InboxActionFileBoundary.jsonURL(
                    in: responsesDir,
                    validatedID: ids.messageID
                ), await writeInboxResponse(response, to: responseURL) else {
                    syncError = "Could not write iCloud response for redelivered command \(action.msgId); left in place for retry."
                    continue
                }
                guard await iCloudBridge.appendActionResponseDeliveryReceipt(response: response,
                    correlationID: action.msgId, transport: "icloud_drive", status: .queuedForICloudSync,
                    dataRoot: sync.dataRoot) else {
                    syncError = "Retained action response receipt remains owed for \(action.msgId)."
                    continue
                }
                if ledgerRefusal == nil {
                    guard await iCloudBridge.appendInboundActionSuccessReceipt(messageID: action.msgId,
                        action: action.action, transport: "icloud_drive", dataRoot: sync.dataRoot) else {
                        syncError = "Retained action inbound receipt remains owed for \(action.msgId)."
                        continue
                    }
                }
                if ledgerRefusal == nil, priorTransaction?.response == nil {
                    await writeTransaction(
                        id: transactionId,
                        action: action.action,
                        state: "unknown",
                        attempts: 1,
                        error: response["message"],
                        response: response,
                        msgId: action.msgId,
                        actionDigest: actionDigest
                    )
                }
                let redeliveredMsgId = action.msgId
                _ = await withCKTimeout("MacSyncEngine.processInboxFiles.redeliveredResponseKVS") {
                    let kvs = NSUbiquitousKeyValueStore.default
                    kvs.set(redeliveredMsgId, forKey: "inbox_response_\(redeliveredMsgId)")
                    return kvs.synchronize()
                }
                // Close out only known outcomes; refusals must not claim processed identity for work that never ran.
                if ledgerRefusal == nil {
                    recordProcessed(action.msgId)
                    await saveProcessedIds()
                }
                let archiveURL = inboxDir.appendingPathComponent("processed_\(fileURL.lastPathComponent).done")
                await Task.detached(priority: .utility) { [fileURL, archiveURL] in
                    try? FileManager.default.moveItem(at: fileURL, to: archiveURL)
                }.value
                continue
            }

            guard isActive, generation == snapshotLifecycleGeneration else { return }
            await writeTransaction(
                id: transactionId,
                action: action.action,
                state: "received",
                attempts: 1,
                msgId: action.msgId,
                actionDigest: actionDigest
            )

            guard isActive, generation == snapshotLifecycleGeneration else { return }
            // Only validated HMAC and time prove contact; pairing files and tokens prove configuration.
            if let peerCreatedAt = ISO8601DateFormatter().date(from: action.createdAt) {
                sync.bridge.notePhoneContact(at: peerCreatedAt)
                do {
                    try await SignedPeerEvidenceStore.record(
                        eventID: action.msgId,
                        channel: .inboxAction,
                        peerCreatedAt: peerCreatedAt,
                        dataRoot: PersistenceCore.defaultDataRoot()
                    )
                    guard isActive, generation == snapshotLifecycleGeneration else { return }
                } catch {
                    nativeLog("[MacSyncEngine] could not persist signed peer evidence for %@: %@",
                          action.msgId, error.localizedDescription)
                }
            }

            guard isActive, generation == snapshotLifecycleGeneration else { return }
            let pendingURL = inboxDir.appendingPathComponent("pending_\(fileURL.lastPathComponent)")
            let claimError = await Task.detached(priority: .utility) { [fileURL, pendingURL] () -> String? in
                do { try FileManager.default.moveItem(at: fileURL, to: pendingURL); return nil }
                catch { return error.localizedDescription }
            }.value
            guard isActive, generation == snapshotLifecycleGeneration else {
                if claimError == nil {
                    await releaseUndispatchedDriveClaim(pendingURL: pendingURL, originalURL: fileURL, envelope: data)
                }
                return
            }
            if let claimError {
                syncError = "Could not claim iCloud command \(action.msgId): \(claimError)"
                continue
            }

            guard let execution = await reserveAndRunInboxAction(action, transactionId: transactionId,
                digest: actionDigest, generation: generation, directory: transactionDir) else {
                await releaseUndispatchedDriveClaim(pendingURL: pendingURL, originalURL: fileURL, envelope: data)
                return
            }
            guard execution.reserved else {
                syncError = "Could not reserve iCloud command \(action.msgId) durably; it was not run and remains pending."
                await Task.detached(priority: .utility) { [pendingURL] in
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: pendingURL.path)
                }.value
                continue
            }
            guard let response = execution.response else {
                let failure = "Pairing secret unavailable after command \(action.msgId); command left pending without an unsigned response."
                if generation == snapshotLifecycleGeneration { syncError = failure }
                await writeTransaction(
                    id: transactionId,
                    action: action.action,
                    state: "response_write_failed",
                    attempts: 1,
                    error: failure,
                    directory: transactionDir
                )
                continue
            }

            // Await coordinated response writes off main; iCloud coordination can block.
            guard let responseURL = InboxActionFileBoundary.jsonURL(
                in: responsesDir,
                validatedID: ids.messageID
            ) else { continue }
            let inboundActionVerified = true
            let responseWritten = await writeInboxResponse(response, to: responseURL)
            guard responseWritten else {
                let failure = "Could not write iCloud response for \(action.msgId); command left pending."
                if generation == snapshotLifecycleGeneration { syncError = failure }
                await writeTransaction(
                    id: transactionId,
                    action: action.action,
                    state: "response_write_failed",
                    attempts: 1,
                    error: failure,
                    directory: transactionDir)
                await Task.detached(priority: .utility) { [pendingURL] in
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: pendingURL.path)
                }.value
                continue
            }
            guard await iCloudBridge.appendActionResponseDeliveryReceipt(
                response: response,
                correlationID: action.msgId,
                transport: "icloud_drive",
                status: .queuedForICloudSync,
                dataRoot: PersistenceCore.defaultDataRoot()
            ) else {
                syncError = "Action response is retained; its delivery receipt remains owed for \(action.msgId)."
                continue
            }
            if inboundActionVerified {
                guard await iCloudBridge.appendInboundActionSuccessReceipt(
                    messageID: action.msgId,
                    action: action.action,
                    transport: "icloud_drive",
                    dataRoot: PersistenceCore.defaultDataRoot()
                ) else {
                    syncError = "Action result is retained; its inbound receipt remains owed for \(action.msgId)."
                    continue
                }
            }

            await settleInboxAction(action, transactionId: transactionId, response: response, directory: transactionDir)
            recordProcessed(action.msgId)
            let processedSaved = await saveProcessedIds()
            let archiveURL = inboxDir.appendingPathComponent("processed_\(fileURL.lastPathComponent).done")
            let archiveError = await Task.detached(priority: .utility) { [pendingURL, archiveURL] () -> String? in
                do { try FileManager.default.moveItem(at: pendingURL, to: archiveURL); return nil }
                catch { return error.localizedDescription }
            }.value
            let root = sync.dataRoot
            let commit = await sync.storage.perform {
                Self.commitCompletionBookkeeping(dataRoot: root, msgId: action.msgId,
                    processedSaved: processedSaved, archiveError: archiveError)
            }
            if !commit.clean {
                if generation == snapshotLifecycleGeneration { syncError = commit.syncError }
                await writeTransaction(
                    id: transactionId,
                    action: action.action,
                    state: commit.transactionState ?? "completed_unarchived",
                    attempts: 1,
                    error: commit.syncError,
                    response: response,
                    directory: transactionDir
                )
            }

            let msgId = action.msgId
            _ = await withCKTimeout("MacSyncEngine.processInboxFiles.responseKVS") {
                let kvs = NSUbiquitousKeyValueStore.default
                kvs.set(msgId, forKey: "inbox_response_\(msgId)")
                return kvs.synchronize()
            }

            guard isActive, generation == snapshotLifecycleGeneration else { return }
            lastInboxAt = Date()
            didProcessMutation = true
        }

        if didProcessMutation {
            // Refresh once per burst so each command does not rebuild heavyweight phone projections.
            await writeSnapshots(forceHeavy: true)
            guard isActive, generation == snapshotLifecycleGeneration else { return }
            NotificationCenter.default.post(name: .iCloudInboxDidProcess, object: nil)
        }
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
        // Authenticate the inner envelope before consulting any ID-owned state.
        let authenticationError: String?
        if let signature = action.signature {
            authenticationError = BridgeMessage.innerActionSignatureError(data: data, signature: signature, secret: pairingSecret)
        } else {
            authenticationError = "missing signature"
        }
        guard isActive, generation == snapshotLifecycleGeneration else { return false }
        if let authenticationError {
            syncError = "Rejected CloudKit action: \(authenticationError)"
            if authenticationError.contains("pairing secret unavailable") { return false }
            return true
        }
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
                if generation == snapshotLifecycleGeneration {
                    syncError = "Pairing secret unavailable after CloudKit action \(action.msgId); action remains unacknowledged."
                }
                return false
            }
            response = signed
            await settleInboxAction(action, transactionId: transactionId, response: response, directory: transactionDir)
        }

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
            await writeSnapshots(forceHeavy: true)
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
