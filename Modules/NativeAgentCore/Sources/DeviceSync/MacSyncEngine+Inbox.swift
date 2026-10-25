// PATCH-2026-05-07: ios-sync MacSyncEngine — SnapshotWriter + InboxWatcher (Mac side)
// SnapshotWriter: source mutations write app-owned Swift runtime state to iCloud Drive `snapshots/`.
//   Touches KVS key `snapshot_updated` so iOS observes immediately.
// InboxWatcher: NSMetadataQuery on `inbox/`. When iOS drops an action JSON, dispatch to
//   the in-process Swift runtime, write response to `responses/<msg_id>.json`, touch KVS `inbox_response_<msg_id>`.

import CommonCrypto
import CryptoKit
import AppKit
import Cognition
import Foundation
import NativeAgentShared
import NativeAgentCore
import MemoryV2
import PersistenceCore
// Blueprint: | `MacSyncEngine+Inbox.swift` | MacSyncEngine: shared inner-action ledger decisions, freshness, response recovery, reservation and settlement; the ledger response wins, and strictly bound executed rows without one recover HMAC-verified matching response files through the same owner for both transports and stale pending files; transport acquisition, delivery and archival remain separate |

extension MacSyncEngine {

    /// Both transports consult the same bound ledger before freshness, then
    /// reserve immediately before dispatch. Transport acquisition and delivery stay outside.
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
                refusal = ("transaction_id_collision", "This command carries a transaction id that already belongs to a different command, so it was refused rather than answered with that command's result.")
            }
        }
        let executed = prior.map { Self.inboxActionDidExecute($0.state) } ?? false
        return (prior, executed, refusal,
                refusal == nil && !executed ? inboxActionFreshnessError(action) ?? envelopeFreshnessError : nil)
    }

    /// A retained ledger response wins. Otherwise, only a strictly bound executed
    /// row can recover a signed response file and settle its missing result.
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

    /// The ledger response owns replay; a response file never overrides it.
    private func replayInboxResponse(
        _ action: InboxAction, record: ICloudTransactionRecord?, refusal: (code: String, message: String)?
    ) throws -> [String: String] {
        if refusal == nil, let response = record?.response { return response }
        var body = ["status": "error", "ok": "false",
                    "message": refusal?.message ?? "Mac could not confirm whether this command completed, so it was not retried automatically.",
                    "msgId": action.msgId, "transactionId": action.transactionId ?? action.msgId, "action": action.action]
        body["code"] = refusal?.code
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
        let status = (response["status"] ?? "").lowercased()
        let state = status == "error" || status == "failed" || response["ok"] == "false"
            ? "failed" : (status == "pending_approval" ? "pending_approval" : "completed")
        await writeTransaction(id: transactionId, action: action.action, state: state,
                               attempts: 1, error: response["message"], response: response, directory: directory)
    }

    /// The admitted processor retains ownership through retirement cleanup.
    /// A rematerialized original may replace this claim only for the same envelope.
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
        // The legacy validator writes upgrade responses for unsigned input;
        // an unauthenticated message must not claim that response path.
        let error: String?
        if action.signature == nil {
            error = "missing signature"
        } else {
            error = await validateInboxAction(data: data, action: action)
        }
        guard let error else { return true }
        await quarantineUnauthenticatedInboxFile(data: data, fileURL: fileURL, inboxDir: inboxDir, reason: error)
        return false
    }

    // MARK: - KVS ping handler

    // 2026-05-09: nonisolated — KVS callbacks fire on com.apple.kvs.client.callback,
    // not main.  Body is a no-op (NSMetadataQuery does the real work) so we just
    // observe and return without touching @MainActor state.
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
        // PATCH-2026-05-08: review-fix-r8 Predicate also excludes archive
        // names so the query never re-fires on previously-processed files.
        // The directory-level filter still catches them, but excluding at
        // the query layer avoids spurious wake-ups on every iCloud sync.
        q.predicate = NSPredicate(
            format: "%K BEGINSWITH %@ AND NOT (%K CONTAINS '/_rejected/') AND NOT (%K BEGINSWITH 'processed_') AND NOT (%K BEGINSWITH 'rejected_') AND NOT (%K BEGINSWITH 'pending_') AND %K ENDSWITH '.json'",
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

    // 2026-05-09: nonisolated + MainActor hop — NSMetadataQuery posts on its
    // private worker queue; touching @MainActor state from there fatal-traps.
    @objc private nonisolated func inboxQueryUpdated(_ note: Notification) {
        let queryID = note.object.map { ObjectIdentifier($0 as AnyObject) }
        Task { @MainActor in
            guard let query = self.inboxQuery, ObjectIdentifier(query) == queryID else { return }
            self.requestInboxProcessing()
        }
    }

    /// Unauthenticated IDs must never reserve accepted-message IDs, responses,
    /// or transactions. Retain only the offending bytes, keyed by their digest.
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
        if validationError.contains("pairing secret unavailable") {
            // Local authority is unavailable, so this is not evidence
            // that the peer sent a bad action. Leave it untouched for
            // exact retry after deliberate local repair.
            return
        }
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
            // Do not consume an invalid remote action unless its
            // signed rejection durably exists for the peer to read.
            return
        }
        // Retain the signed rejection and archive this exact stale envelope,
        // without reserving its message or transaction identity.
        // PATCH-2026-05-08: fix-A.3 Use .done suffix so the file is no longer
        // matched by the `.json` filter on next query update or restart.
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

        // fix-KVS-quota: sweep stale inbox_response_* KVS keys every pass so the
        // 1024-key/1MB ubiquitous-store quota is never reached (which would kill
        // ALL iCloud sync silently). The per-key iCloud file stats inside run off
        // the main actor; awaited so eviction completes before we list the inbox.
        await sweepInboxResponseKVSKeys()
        guard isActive, generation == snapshotLifecycleGeneration else { return }

        // Directory listing — can block on iCloud-resident directories; do it off main.
        guard let files = await Task.detached(priority: .utility, operation: { [inboxDir] in
            try? FileManager.default.contentsOfDirectory(
                at: inboxDir, includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            )
        }).value else { return }

        guard isActive, generation == snapshotLifecycleGeneration else { return }

        // PATCH-2026-05-08: fix-A.3 Exclude already-processed/rejected archives so
        // restarts don't re-decode and re-dispatch them.  Archives use a `.done`
        // suffix (e.g. `processed_foo.json.done`) added below.  As belt-and-suspenders,
        // also skip any filename starting with "processed_" or "rejected_" even if the
        // suffix isn't .done (e.g. legacy `.json` archives from a previous build).
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
                guard let response = retainedResponse ?? (try? signedResponse([
                    "status": "error",
                    "message": "Mac could not confirm whether this command completed, so it was not retried automatically.",
                    "msgId": staleAction.msgId,
                    "transactionId": txId,
                    "action": staleAction.action,
                ])) else {
                    syncError = "Pairing secret unavailable; stale command \(staleAction.msgId) remains pending."
                    continue
                }
                // M3 (2026-07-09): the encode+write used to be stacked `try?` and
                // the pending file was archived regardless — an encode or iCloud
                // write failure silently consumed the command and the phone waited
                // forever for a response that no longer had a writer. Verify the
                // response actually landed (retry once), and only then consume the
                // pending file; otherwise leave it for the next sweep.
                let responseWritten = await writeInboxResponse(response, to: responseURL)
                guard responseWritten else {
                    syncError = "Could not write iCloud response for stale command \(staleAction.msgId); left pending for retry."
                    nativeLog("MacSyncEngine.processInboxFiles: %@", syncError ?? "")
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

        // Second directory listing (after stale-pending sweep) — off main.
        guard let refreshedFiles = await Task.detached(priority: .utility, operation: { [inboxDir] in
            try? FileManager.default.contentsOfDirectory(
                at: inboxDir, includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            )
        }).value else { return }

        let jsonFiles = refreshedFiles.filter {
            let name = $0.lastPathComponent
            guard $0.pathExtension == "json" else { return false }
            guard !name.hasPrefix("processed_") && !name.hasPrefix("rejected_") && !name.hasPrefix("pending_") else { return false }
            return true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        var didProcessMutation = false
        for fileURL in jsonFiles {
            guard isActive, generation == snapshotLifecycleGeneration else { return }
            // Coordinated read of iCloud inbox file — SEVERE blocking risk; do it off main.
            guard let data = await Task.detached(priority: .utility, operation: { [fileURL] in
                Self.coordinatedRead(at: fileURL)
            }).value else { continue }
            guard isActive, generation == snapshotLifecycleGeneration else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // R11-N26: On JSON decode failure, move the file to _rejected/ so it
            // doesn't re-trigger on every sync cycle (infinite retrigger bug).
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

            // C.1: Validate the HMAC signature before dispatching.
            // 2026-09-06: freshness NO LONGER runs here. Authenticity has to
            // come first — anything on the account can drop a file in this
            // folder — but an action whose response was lost and which arrives
            // again beyond the ±5-minute window is a REDELIVERY, and rejecting
            // it here meant its completed ledger row was never consulted and
            // the phone was told the command failed when it had run. Freshness
            // moves below the ledger, where it gates new work only.
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
                // Answer, never redispatch. A refusal deliberately writes no
                // ledger row: whatever is there belongs to the run we could not
                // read, or to the other action holding this id.
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
                // Only an action whose outcome IS known is closed out here; a
                // refusal leaves no processed id, because nothing ran.
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
            // The body may treat this as peer-presence evidence only after the
            // action's HMAC and timestamp have passed validation. Token and
            // pairing-file timestamps prove configuration, not contact.
            if let peerCreatedAt = ISO8601DateFormatter().date(from: action.createdAt) {
                do {
                    try await SignedPeerEvidenceStore.record(
                        eventID: action.msgId,
                        channel: .inboxAction,
                        peerCreatedAt: peerCreatedAt,
                        dataRoot: PersistenceCore.defaultDataRoot()
                    )
                    guard isActive, generation == snapshotLifecycleGeneration else { return }
                    sync.bridge.notePhoneContact(at: peerCreatedAt)
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

            // Write response (coordinated iCloud write) — SEVERE blocking risk; do it off main.
            guard let responseURL = InboxActionFileBoundary.jsonURL(
                in: responsesDir,
                validatedID: ids.messageID
            ) else { continue }
            let inboundActionVerified = true
            let responseWritten = await writeInboxResponse(response, to: responseURL)
            guard responseWritten else {
                let failure = "Could not write iCloud response for \(action.msgId); command left pending."
                if generation == snapshotLifecycleGeneration { syncError = failure }
                await writeTransaction(id: transactionId, action: action.action, state: "response_write_failed", attempts: 1, error: failure, directory: transactionDir)
                await Task.detached(priority: .utility) { [pendingURL] in
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: pendingURL.path)
                }.value
                continue
            }
            await iCloudBridge.appendActionResponseDeliveryReceipt(
                response: response,
                correlationID: action.msgId,
                transport: "icloud_drive",
                status: .queuedForICloudSync,
                dataRoot: PersistenceCore.defaultDataRoot()
            )
            if inboundActionVerified {
                await iCloudBridge.appendInboundActionSuccessReceipt(
                    messageID: action.msgId,
                    action: action.action,
                    transport: "icloud_drive",
                    dataRoot: PersistenceCore.defaultDataRoot()
                )
            }

            await settleInboxAction(action, transactionId: transactionId, response: response, directory: transactionDir)
            // Sweep R4 item 1: the action has now RUN and its response has
            // landed, so from here on the only correct outcome is "never
            // dispatch this again". Both bookkeeping steps used to be `try?`:
            // a disk-full or permission failure after execution left the
            // pending file in place with no processed id, and the next sweep
            // (or the next launch) re-ran the remote Mac action. Both steps are
            // now CHECKED, and if either fails we write a durable local marker
            // that restoreState reads back as "already processed".
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

            // KVS notification to iOS
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
            // Refresh once after a burst of iCloud actions so iOS sees updated
            // state without refetching heavyweight snapshots per command.
            await writeSnapshots(forceHeavy: true)
            guard isActive, generation == snapshotLifecycleGeneration else { return }
            NotificationCenter.default.post(name: .iCloudInboxDidProcess, object: nil)
        }
    }


    /// Encode + coordinated-write one inbox response, verifying it actually
    /// landed on disk and retrying once. Returns false when the response is NOT
    /// present afterwards — the caller must then leave the pending command in
    /// place for a later sweep rather than consuming it, because a phone that
    /// never sees a response waits forever (M3, honesty sweep 2026-07-09).
    /// Never silent: every failed attempt is logged.
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
            // 2026-09-06: check the write, then READ THE FILE BACK AND DECODE
            // it. `fileExists` passed for a zero-length or half-written file —
            // a phone that reads one of those gets a decode failure and waits
            // forever, which is exactly the outcome this function exists to
            // prevent. Only a response that decodes back into the same keys is
            // a landed response.
            let landed = await Task.detached(priority: .utility) { [responseURL, responseData] () -> Bool in
                guard Self.coordinatedWrite(data: responseData, to: responseURL) else { return false }
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

    /// Process the existing signed iPhone action envelope after CloudKit has
    /// verified the outer BridgeMessage. The action still passes the same
    /// inner-HMAC, freshness, idempotency, TrustCenter/router, receipt, and
    /// response-signing boundaries as the legacy Drive inbox.
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
        // Missing signatures must bypass the legacy upgrade-response writer.
        let authenticationError: String?
        if action.signature == nil {
            authenticationError = "missing signature"
        } else {
            authenticationError = await validateInboxAction(data: data, action: action)
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

        // Transport-only fast path: the shared ledger decision and response
        // projection still own replay; no response file can override them.
        if processedMsgIds.contains(action.msgId), alreadyExecuted {
            guard let response = try? replayInboxResponse(action, record: priorTransaction, refusal: nil) else { return false }
            do {
                try await sendCloudKitActionResponse(response, correlationID: action.msgId)
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
            // Deliberately no ledger write and no response file: whatever is at
            // either path belongs to the run we could not read, or to the other
            // action holding this id, and must not be clobbered.
            do {
                try await sendCloudKitActionResponse(signed, correlationID: action.msgId)
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
            inboundActionVerified = false
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
            if validationError.contains("pairing secret unavailable") {
                syncError = "Pairing secret unavailable; CloudKit action \(action.msgId) remains unacknowledged."
                return false
            }
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
            // A stale envelope has not executed. Return its authenticated
            // refusal without claiming either identity or a response-file slot.
            do {
                try await sendCloudKitActionResponse(signed, correlationID: action.msgId)
                return true
            } catch {
                syncError = "Could not send stale CloudKit action refusal \(action.msgId): \(error.localizedDescription)"
                return false
            }
        } else {
            inboundActionVerified = true
            if let peerCreatedAt = ISO8601DateFormatter().date(from: action.createdAt) {
                do {
                    try await SignedPeerEvidenceStore.record(
                        eventID: action.msgId,
                        channel: .inboxAction,
                        peerCreatedAt: peerCreatedAt,
                        dataRoot: actionStateRoot
                    )
                    guard isActive, generation == snapshotLifecycleGeneration else { return false }
                    sync.bridge.notePhoneContact(at: peerCreatedAt)
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

        // Persist before sending so a CloudKit delivery failure can retry the
        // response without repeating the already-authorized external effect.
        guard await writeInboxResponse(response, to: responseURL) else {
            if generation == snapshotLifecycleGeneration {
                syncError = "Could not persist CloudKit response for \(action.msgId); action will not be acknowledged."
            }
            return false
        }
        if inboundActionVerified {
            await iCloudBridge.appendInboundActionSuccessReceipt(
                messageID: action.msgId,
                action: action.action,
                transport: "cloudkit",
                dataRoot: actionStateRoot
            )
        }
        // Sweep R4 item 1 (CloudKit lane, same hazard as the Drive lane above):
        // the action has already executed. If the id window cannot be persisted
        // the in-process guard at the top of this function still holds, but a
        // restart would lose it — so leave the durable marker instead.
        recordProcessed(action.msgId)
        let processedSaved = await saveProcessedIds()
        let commit = await sync.storage.perform {
            Self.commitCompletionBookkeeping(dataRoot: actionStateRoot, msgId: action.msgId,
                processedSaved: processedSaved, archiveError: nil)
        }
        if !commit.clean, generation == snapshotLifecycleGeneration { syncError = commit.syncError }

        guard isActive, generation == snapshotLifecycleGeneration else { return false }
        do {
            try await sendCloudKitActionResponse(response, correlationID: action.msgId)
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

    private func sendCloudKitActionResponse(
        _ response: [String: String],
        correlationID: String
    ) async throws {
        if let cloudKitActionResponseSender {
            try await cloudKitActionResponseSender(response, correlationID)
        } else {
            try await sync.bridge.sendCloudKitActionResponse(
                response,
                correlationID: correlationID
            )
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
