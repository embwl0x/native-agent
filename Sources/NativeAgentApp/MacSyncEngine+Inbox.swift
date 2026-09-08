// PATCH-2026-05-07: ios-sync MacSyncEngine — SnapshotWriter + InboxWatcher (Mac side)
// SnapshotWriter: every N seconds writes app-owned Swift runtime state to iCloud Drive `snapshots/`.
//   Touches KVS key `snapshot_updated` so iOS observes immediately.
// InboxWatcher: NSMetadataQuery on `inbox/`. When iOS drops an action JSON, dispatch to
//   the in-process Swift runtime, write response to `responses/<msg_id>.json`, touch KVS `inbox_response_<msg_id>`.

import CommonCrypto
import CryptoKit
import AppKit
import Foundation
import SwiftUI
import NativeAgentShared
import NativeAgentCore
import KnowledgeGraph
import PersistenceCore

extension MacSyncEngine {
    func authenticateInboxFile(data: Data, action: InboxAction, fileURL: URL, inboxDir: URL) async -> Bool {
        // The legacy validator writes upgrade responses for unsigned input;
        // an unauthenticated message must not claim that response path.
        let error: String?
        if action.signature == nil {
            error = "missing signature"
        } else {
            error = await validateInboxAction(data: data, action: action, enforceFreshness: false)
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
            await self.processInboxFiles()
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
        Task { @MainActor in
            self.inboxQuery?.disableUpdates()
            await self.processInboxFiles()
            self.inboxQuery?.enableUpdates()
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
                NSLog("[MacSyncEngine] Could not quarantine unauthenticated inbox file: %@", error.localizedDescription)
            }
        }.value
    }

    /// Refuse authenticated stale work only when no transaction owns the ID.
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
        guard case .absent = await readTransaction(id: transactionId) else { return }
        guard await writeRejectedResponseIfNeeded(
            action: action,
            transactionId: transactionId,
            message: validationError
        ) else {
            // Do not consume an invalid remote action unless its
            // signed rejection durably exists for the peer to read.
            return
        }
        guard let transactionDir else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let rejection = ICloudTransactionRecord(
            id: transactionId,
            direction: "ios_to_mac",
            action: action.action,
            state: "rejected",
            createdAt: now,
            updatedAt: now,
            attempts: 1,
            lastError: validationError,
            msgId: action.msgId,
            actionDigest: actionDigest
        )
        guard await Task.detached(priority: .utility, operation: {
            Self.writeRejectedTransactionIfAbsent(rejection, in: transactionDir)
        }).value else { return }
        // Only authenticated, durably rejected work enters accepted-ID storage.
        recordProcessed(action.msgId)  // fix-R9-9
        saveProcessedIds()
        // PATCH-2026-05-08: fix-A.3 Use .done suffix so the file is no longer
        // matched by the `.json` filter on next query update or restart.
        let archiveURL = inboxDir.appendingPathComponent("rejected_\(fileURL.lastPathComponent).done")
        await Task.detached(priority: .utility) { [fileURL, archiveURL] in
            try? FileManager.default.moveItem(at: fileURL, to: archiveURL)
        }.value
    }

    /// Exclusive creation also protects against a row appearing after the
    /// earlier lookup while the signed response is being persisted.
    nonisolated static func writeRejectedTransactionIfAbsent(_ record: ICloudTransactionRecord, in directory: URL) -> Bool {
        guard let url = InboxActionFileBoundary.jsonURL(in: directory, validatedID: record.id) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(record) else { return false }
        var wrote = false
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &error) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .withoutOverwriting)
                wrote = true
            } catch {
                NSLog("[MacSyncEngine] Rejection ledger creation refused: %@", error.localizedDescription)
            }
        }
        return wrote && error == nil
    }

    private func processInboxFiles() async {
        guard let inboxDir, let responsesDir else { return }
        if inboxProcessingInFlight {
            inboxProcessingQueued = true
            return
        }
        inboxProcessingInFlight = true
        defer {
            inboxProcessingInFlight = false
            if inboxProcessingQueued {
                inboxProcessingQueued = false
                Task { @MainActor in
                    await self.processInboxFiles()
                }
            }
        }
        let fm = FileManager.default
        // startDownloadingUbiquitousItem can block while iCloud contacts servers — do it off main.
        await Task.detached(priority: .utility) { [inboxDir] in
            try? FileManager.default.startDownloadingUbiquitousItem(at: inboxDir)
        }.value

        // fix-KVS-quota: sweep stale inbox_response_* KVS keys every pass so the
        // 1024-key/1MB ubiquitous-store quota is never reached (which would kill
        // ALL iCloud sync silently). The per-key iCloud file stats inside run off
        // the main actor; awaited so eviction completes before we list the inbox.
        await sweepInboxResponseKVSKeys()

        // Directory listing — can block on iCloud-resident directories; do it off main.
        guard let files = await Task.detached(priority: .utility, operation: { [inboxDir] in
            try? FileManager.default.contentsOfDirectory(
                at: inboxDir, includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            )
        }).value else { return }

        // PATCH-2026-05-08: fix-A.3 Exclude already-processed/rejected archives so
        // restarts don't re-decode and re-dispatch them.  Archives use a `.done`
        // suffix (e.g. `processed_foo.json.done`) added below.  As belt-and-suspenders,
        // also skip any filename starting with "processed_" or "rejected_" even if the
        // suffix isn't .done (e.g. legacy `.json` archives from a previous build).
        let now = Date()
        for pendingURL in files where pendingURL.lastPathComponent.hasPrefix("pending_") && pendingURL.pathExtension == "json" {
            let attrs = try? fm.attributesOfItem(atPath: pendingURL.path)
            let modified = attrs?[.modificationDate] as? Date
            guard let modified, now.timeIntervalSince(modified) > 120 else { continue }
            // Reading a pending (iCloud-resident) file may block — do it off main.
            let data = await Task.detached(priority: .utility) { [pendingURL] in
                try? Data(contentsOf: pendingURL)
            }.value
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
                guard let response = try? signedResponse([
                    "status": "error",
                    "message": "Mac could not confirm whether this command completed, so it was not retried automatically.",
                    "msgId": staleAction.msgId,
                    "transactionId": txId,
                    "action": staleAction.action,
                ]) else {
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
                    NSLog("MacSyncEngine.processInboxFiles: %@", syncError ?? "")
                    await writeTransaction(id: txId, action: staleAction.action, state: "response_write_failed", error: syncError)
                    continue
                }
                let msgId = staleAction.msgId
                _ = await withCKTimeout("MacSyncEngine.processInboxFiles.staleResponseKVS") {
                    let kvs = NSUbiquitousKeyValueStore.default
                    kvs.set(msgId, forKey: "inbox_response_\(msgId)")
                    return kvs.synchronize()
                }
                await writeTransaction(id: txId, action: staleAction.action, state: "unknown", error: response["message"], response: response)
                recordProcessed(staleAction.msgId)
                saveProcessedIds()
                let archiveURL = inboxDir.appendingPathComponent("processed_\(pendingURL.lastPathComponent).done")
                await Task.detached(priority: .utility) { [pendingURL, archiveURL] in
                    try? FileManager.default.moveItem(at: pendingURL, to: archiveURL)
                }.value
            } else {
                let archiveURL = inboxDir.appendingPathComponent("rejected_\(pendingURL.lastPathComponent).done")
                await Task.detached(priority: .utility) { [pendingURL, archiveURL] in
                    try? FileManager.default.moveItem(at: pendingURL, to: archiveURL)
                }.value
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
            // Coordinated read of iCloud inbox file — SEVERE blocking risk; do it off main.
            guard let data = await Task.detached(priority: .utility, operation: { [fileURL] in
                Self.coordinatedRead(at: fileURL)
            }).value else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // R11-N26: On JSON decode failure, move the file to _rejected/ so it
            // doesn't re-trigger on every sync cycle (infinite retrigger bug).
            guard let action = try? decoder.decode(InboxAction.self, from: data) else {
                syncError = "Rejected inbox file \(fileURL.lastPathComponent): malformed JSON"
                NSLog("[MacSyncEngine] Rejected malformed inbox file: \(fileURL.lastPathComponent)")
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
                NSLog("[MacSyncEngine] Rejected inbox file with non-UUID identity: %@", fileURL.lastPathComponent)
                let rejectedDir = inboxDir.appendingPathComponent("_rejected")
                let rejectedURL = rejectedDir.appendingPathComponent(fileURL.lastPathComponent)
                await Task.detached(priority: .utility) { [rejectedDir, fileURL, rejectedURL] in
                    try? FileManager.default.createDirectory(at: rejectedDir, withIntermediateDirectories: true)
                    try? FileManager.default.moveItem(at: fileURL, to: rejectedURL)
                }.value
                continue
            }
            guard !processedMsgIds.contains(ids.messageID) else {
                let duplicateURL = inboxDir.appendingPathComponent("duplicate_\(fileURL.lastPathComponent).done")
                await Task.detached(priority: .utility) { [fileURL, duplicateURL] in
                    try? FileManager.default.moveItem(at: fileURL, to: duplicateURL)
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

            // 2026-09-06: the same guarantee the CloudKit lane got this week.
            // Placed AFTER the signature check, unlike that lane's: a CloudKit
            // envelope arrived through a verified channel, while anything that
            // can write to the iCloud Drive folder can drop a file here, and
            // only a SIGNED envelope may be answered with a stored result.
            // Freshness is deliberately below this block, not above it.
            // The `pending_` rename claims a file, but a file is not a command:
            // iCloud can re-materialise `<msgId>.json` after the claim, and
            // `processedMsgIds` is only written AFTER execution — so a
            // redelivery following a crash mid-dispatch re-ran a non-idempotent
            // action. The ledger's "running" row is the durable "this already
            // began executing" marker, so consult it before doing anything with
            // this envelope.
            var priorTransaction: ICloudTransactionRecord?
            var alreadyExecuted = false
            // Set when this envelope cannot be shown to be fresh work. Such an
            // action is NEVER executed and NEVER served another action's
            // result — it gets a signed, honest outcome instead.
            var ledgerRefusal: (code: String, message: String)?
            switch await readTransaction(id: transactionId) {
            case .absent:
                break
            case .unreadable:
                // Unreadable is not absent: a row may exist and we cannot tell
                // what it says, so the outcome is unknown and an unknown
                // outcome is never re-executed.
                ledgerRefusal = (
                    "unknown_outcome",
                    "Mac could not read the durable record for this command, so it was not run again."
                )
            case .present(let record):
                guard Self.inboxLedgerRow(
                    record,
                    matchesMsgId: action.msgId,
                    digest: actionDigest,
                    action: action.action
                ) else {
                    // `transactionId` comes from the phone and only DEFAULTS to
                    // msgId, so two unrelated actions can collide on it. A
                    // colliding envelope is new work, not a redelivery.
                    ledgerRefusal = (
                        "transaction_id_collision",
                        "This command carries a transaction id that already belongs to a different command, so it was refused rather than answered with that command's result."
                    )
                    break
                }
                priorTransaction = record
                alreadyExecuted = Self.inboxActionDidExecute(record.state)
            }

            // 2026-09-06: freshness, at last — and only for work that has not
            // already run. A signed envelope whose ledger row says it executed
            // is answered from that row however old the redelivery is; a signed
            // envelope with no such row is new work, and new work still has to
            // arrive inside the ±5-minute window.
            if ledgerRefusal == nil, !alreadyExecuted,
               let staleError = inboxActionFreshnessError(action) {
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

            if ledgerRefusal != nil || alreadyExecuted {
                // Answer, never redispatch. A refusal deliberately writes no
                // ledger row: whatever is there belongs to the run we could not
                // read, or to the other action holding this id.
                let response: [String: String]
                if let retained = priorTransaction?.response, ledgerRefusal == nil {
                    // Already signed when the action completed; re-signing it
                    // would change nothing and could fail on a missing secret.
                    response = retained
                } else {
                    let body: [String: String] = ledgerRefusal.map { refusal in
                        [
                            "status": "error",
                            "ok": "false",
                            "code": refusal.code,
                            "message": refusal.message,
                            "msgId": action.msgId,
                            "transactionId": transactionId,
                            "action": action.action,
                        ]
                    } ?? [
                        // Executed, but its outcome was never signed — the same
                        // wording the stale-pending sweep uses.
                        "status": "error",
                        "ok": "false",
                        "message": "Mac could not confirm whether this command completed, so it was not retried automatically.",
                        "msgId": action.msgId,
                        "transactionId": transactionId,
                        "action": action.action,
                    ]
                    guard let signed = try? signedResponse(body) else {
                        syncError = "Pairing secret unavailable; iCloud command \(action.msgId) remains unanswered."
                        continue
                    }
                    response = signed
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
                    saveProcessedIds()
                }
                let archiveURL = inboxDir.appendingPathComponent("processed_\(fileURL.lastPathComponent).done")
                await Task.detached(priority: .utility) { [fileURL, archiveURL] in
                    try? FileManager.default.moveItem(at: fileURL, to: archiveURL)
                }.value
                continue
            }

            await writeTransaction(
                id: transactionId,
                action: action.action,
                state: "received",
                attempts: 1,
                msgId: action.msgId,
                actionDigest: actionDigest
            )

            // The body may treat this as peer-presence evidence only after the
            // action's HMAC and timestamp have passed validation. Token and
            // pairing-file timestamps prove configuration, not contact.
            if let peerCreatedAt = ISO8601DateFormatter().date(from: action.createdAt) {
                do {
                    try await SignedPeerEvidenceStore.record(
                        eventID: action.msgId,
                        channel: .inboxAction,
                        peerCreatedAt: peerCreatedAt,
                        dataRoot: NativeAgentPaths.dataRoot
                    )
                } catch {
                    NSLog("[MacSyncEngine] could not persist signed peer evidence for %@: %@",
                          action.msgId, error.localizedDescription)
                }
            }

            let pendingURL = inboxDir.appendingPathComponent("pending_\(fileURL.lastPathComponent)")
            let claimError = await Task.detached(priority: .utility) { [fileURL, pendingURL] () -> String? in
                do { try FileManager.default.moveItem(at: fileURL, to: pendingURL); return nil }
                catch { return error.localizedDescription }
            }.value
            if let claimError {
                syncError = "Could not claim iCloud command \(action.msgId): \(claimError)"
                continue
            }

            // Dispatch to the in-process Swift runtime.
            //
            // 2026-09-06: the reservation is CHECKED, like the CloudKit lane's.
            // This row is what the redelivery check above reads, and it was
            // fire-and-forget — an encode, coordination or disk failure left no
            // row and the lane dispatched anyway, so a redelivered envelope
            // read as fresh work and ran the action twice. If it does not land,
            // do not execute: touch the pending file so the stale sweep answers
            // the phone honestly, and leave the command alone. Sits immediately
            // before `dispatchAction` with no await between them on purpose.
            guard await writeTransaction(
                id: transactionId,
                action: action.action,
                state: "running",
                attempts: 1,
                msgId: action.msgId,
                actionDigest: actionDigest
            ) else {
                syncError = "Could not reserve iCloud command \(action.msgId) durably; it was not run and remains pending."
                await Task.detached(priority: .utility) { [pendingURL] in
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: pendingURL.path)
                }.value
                continue
            }
            var responseBody = await dispatchAction(action)
            responseBody["msgId"] = action.msgId
            responseBody["transactionId"] = transactionId
            responseBody["action"] = action.action
            guard let response = try? signedResponse(responseBody) else {
                syncError = "Pairing secret unavailable after command \(action.msgId); command left pending without an unsigned response."
                await writeTransaction(
                    id: transactionId,
                    action: action.action,
                    state: "response_write_failed",
                    attempts: 1,
                    error: syncError
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
                syncError = "Could not write iCloud response for \(action.msgId); command left pending."
                await writeTransaction(id: transactionId, action: action.action, state: "response_write_failed", attempts: 1, error: syncError)
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
                dataRoot: NativeAgentPaths.dataRoot
            )
            if inboundActionVerified {
                await iCloudBridge.appendInboundActionSuccessReceipt(
                    messageID: action.msgId,
                    action: action.action,
                    transport: "icloud_drive",
                    dataRoot: NativeAgentPaths.dataRoot
                )
            }

            let responseStatus = (response["status"] ?? "").lowercased()
            let completedState = responseStatus == "error" || responseStatus == "failed" || response["ok"] == "false"
                ? "failed"
                : (responseStatus == "pending_approval" ? "pending_approval" : "completed")
            await writeTransaction(id: transactionId, action: action.action, state: completedState, attempts: 1, error: response["message"], response: response)
            // Sweep R4 item 1: the action has now RUN and its response has
            // landed, so from here on the only correct outcome is "never
            // dispatch this again". Both bookkeeping steps used to be `try?`:
            // a disk-full or permission failure after execution left the
            // pending file in place with no processed id, and the next sweep
            // (or the next launch) re-ran the remote Mac action. Both steps are
            // now CHECKED, and if either fails we write a durable local marker
            // that loadProcessedIds() reads back as "already processed".
            recordProcessed(action.msgId)
            let processedSaved = saveProcessedIds()
            let archiveURL = inboxDir.appendingPathComponent("processed_\(fileURL.lastPathComponent).done")
            let archiveError = await Task.detached(priority: .utility) { [pendingURL, archiveURL] () -> String? in
                do { try FileManager.default.moveItem(at: pendingURL, to: archiveURL); return nil }
                catch { return error.localizedDescription }
            }.value
            let commit = Self.commitCompletionBookkeeping(
                dataRoot: NativeAgentPaths.dataRoot,
                msgId: action.msgId,
                processedSaved: processedSaved,
                archiveError: archiveError
            )
            if !commit.clean {
                syncError = commit.syncError
                await writeTransaction(
                    id: transactionId,
                    action: action.action,
                    state: commit.transactionState ?? "completed_unarchived",
                    attempts: 1,
                    error: commit.syncError,
                    response: response
                )
            }

            // KVS notification to iOS
            let msgId = action.msgId
            _ = await withCKTimeout("MacSyncEngine.processInboxFiles.responseKVS") {
                let kvs = NSUbiquitousKeyValueStore.default
                kvs.set(msgId, forKey: "inbox_response_\(msgId)")
                return kvs.synchronize()
            }

            lastInboxAt = Date()
            didProcessMutation = true
        }

        if didProcessMutation {
            // Refresh once after a burst of iCloud actions so iOS sees updated
            // state without refetching heavyweight snapshots per command.
            await writeSnapshots(forceHeavy: true)
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
            NSLog("MacSyncEngine.writeInboxResponse: encode failed for %@: %@",
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
            NSLog("MacSyncEngine.writeInboxResponse: attempt %d did not land %@",
                  attempt, responseURL.lastPathComponent)
        }
        return false
    }

    /// Process the existing signed iPhone action envelope after CloudKit has
    /// verified the outer BridgeMessage. The action still passes the same
    /// inner-HMAC, freshness, idempotency, TrustCenter/router, receipt, and
    /// response-signing boundaries as the legacy Drive inbox.
    func processCloudKitActionMessage(_ message: BridgeMessage) async -> Bool {
        let actionStateRoot = cloudKitActionStateRootOverride ?? NativeAgentPaths.dataRoot
        guard message.sender == "ios" else {
            return iCloudBridge.quarantineIncomingSender(message, dataRoot: actionStateRoot)
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
            authenticationError = await validateInboxAction(data: data, action: action, enforceFreshness: false)
        }
        if let authenticationError {
            syncError = "Rejected CloudKit action: \(authenticationError)"
            if authenticationError.contains("pairing secret unavailable") { return false }
            return iCloudBridge.quarantineIncomingSender(message, dataRoot: actionStateRoot)
        }
        guard let responsesDir,
              let responseURL = InboxActionFileBoundary.jsonURL(
                in: responsesDir,
                validatedID: ids.messageID
              ) else { return false }

        let transactionId = ids.transactionID
        let actionDigest = Self.inboxActionDigest(envelope: data)

        // A prior attempt may have executed successfully but lost its CloudKit
        // response send. Re-send the durable signed response; never redispatch.
        if processedMsgIds.contains(action.msgId) {
            let responseTask = Task<[String: String]?, Never>.detached(priority: .utility) {
                guard case .data(let data) = Self.coordinatedReadOutcome(at: responseURL) else { return nil }
                return try? JSONDecoder().decode([String: String].self, from: data)
            }
            var resolved = await responseTask.value
            if resolved == nil,
               case .present(let record) = await readTransaction(id: transactionId),
               Self.inboxLedgerRow(record, matchesMsgId: action.msgId, digest: actionDigest, action: action.action),
               let retained = record.response {
                // 2026-09-06: the response file is missing or does not decode.
                // The ledger kept a copy of the same signed response when the
                // action completed, so it — not the file — is authoritative
                // here. Without this the phone got nothing at all.
                resolved = retained
            }
            guard let response = resolved else {
                return false
            }
            do {
                try await sendCloudKitActionResponse(response, correlationID: action.msgId)
                return true
            } catch {
                syncError = "Could not resend CloudKit action response \(action.msgId): \(error.localizedDescription)"
                return false
            }
        }

        // 2026-09-06: processedMsgIds is only written AFTER execution, so a
        // CloudKit redelivery following a response-signing failure, a response
        // write failure, or a crash re-ran the action — createDeskItem and
        // appendDeskItemNote are not idempotent. The ledger records "running"
        // before dispatch, so consult it first: an action that already began
        // executing gets its stored response resent, never a second run.
        var priorTransaction: ICloudTransactionRecord?
        var alreadyExecuted = false
        // Set when we cannot prove this envelope is fresh work. Such an action
        // is NEVER executed and NEVER served another action's result: it gets a
        // signed, honest outcome and nothing in the ledger is overwritten.
        var refusal: (code: String, message: String)?
        switch await readTransaction(id: transactionId) {
        case .absent:
            break
        case .unreadable:
            // 2026-09-06: absence and unreadability used to collapse into the
            // same nil, so a corrupt or unreadable ledger row read as "fresh
            // work" and the action ran a second time. Unreadable means the
            // outcome is unknown, and an unknown outcome is not re-executed.
            refusal = (
                "unknown_outcome",
                "Mac could not read the durable record for this command, so it was not run again."
            )
        case .present(let record):
            guard Self.inboxLedgerRow(record, matchesMsgId: action.msgId, digest: actionDigest, action: action.action) else {
                // 2026-09-06: `transactionId` comes from the phone and only
                // DEFAULTS to msgId, so two unrelated actions can collide on it.
                // A colliding envelope is a new action, not a redelivery — it is
                // refused, never answered with the other action's response.
                refusal = (
                    "transaction_id_collision",
                    "This command carries a transaction id that already belongs to a different command, so it was refused rather than answered with that command's result."
                )
                break
            }
            priorTransaction = record
            alreadyExecuted = Self.inboxActionDidExecute(record.state)
        }

        if let refusal {
            guard let signed = try? signedResponse([
                "status": "error",
                "ok": "false",
                "code": refusal.code,
                "message": refusal.message,
                "msgId": action.msgId,
                "transactionId": transactionId,
                "action": action.action,
            ]) else {
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

        if !alreadyExecuted {
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
            if let storedResponse = priorTransaction.response {
                response = storedResponse
            } else {
                // Executed, but its outcome was never signed. Same wording the
                // Drive lane's stale-pending sweep uses.
                guard let signed = try? signedResponse([
                    "status": "error",
                    "ok": "false",
                    "message": "Mac could not confirm whether this command completed, so it was not retried automatically.",
                    "msgId": action.msgId,
                    "transactionId": transactionId,
                    "action": action.action,
                ]) else {
                    syncError = "Pairing secret unavailable; CloudKit action \(action.msgId) remains unacknowledged."
                    return false
                }
                response = signed
                await writeTransaction(
                    id: transactionId,
                    action: action.action,
                    state: "unknown",
                    attempts: 1,
                    error: response["message"],
                    response: response
                )
            }
        } else if let validationError = inboxActionFreshnessError(action) {
            inboundActionVerified = false
            if validationError.contains("pairing secret unavailable") {
                syncError = "Pairing secret unavailable; CloudKit action \(action.msgId) remains unacknowledged."
                return false
            }
            guard let signed = try? signedResponse([
                "status": "error",
                "ok": "false",
                "code": validationError.contains("signature") ? "signature_invalid" : "invalid_action",
                "message": validationError,
                "msgId": action.msgId,
                "transactionId": transactionId,
                "action": action.action,
            ]) else {
                syncError = "Pairing secret unavailable; CloudKit action \(action.msgId) remains unacknowledged."
                return false
            }
            response = signed
            await writeTransaction(
                id: transactionId,
                action: action.action,
                state: "rejected",
                attempts: 1,
                error: validationError,
                response: response
            )
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
                } catch {
                    NSLog("[MacSyncEngine] could not persist CloudKit action peer evidence for %@: %@",
                          action.msgId, error.localizedDescription)
                }
            }
            // 2026-09-06: the reservation is CHECKED. This write is the only
            // thing standing between a lost response and a second execution of
            // a non-idempotent action, and it used to be fire-and-forget — an
            // encode, coordination or disk failure left no row and the lane
            // dispatched anyway. If it does not land, do not execute: return a
            // retriable transport failure so CloudKit redelivers the action
            // later, when the ledger is writable again.
            //
            // 2026-09-06: this write sits IMMEDIATELY before `dispatchAction`
            // with no await between them on purpose. The crash window it leaves
            // — a stale "running" row whose action never ran — is now a crash
            // inside these few synchronous lines, and for that window "Mac
            // could not confirm whether this command completed" is the honest
            // answer. Deliberately NOT closed with a timeout-based
            // re-execution: re-running a non-idempotent action on a guess is
            // the worse failure.
            guard await writeTransaction(
                id: transactionId,
                action: action.action,
                state: "running",
                attempts: 1,
                msgId: action.msgId,
                actionDigest: actionDigest
            ) else {
                syncError = "Could not reserve CloudKit action \(action.msgId) durably; it was not run and remains unacknowledged."
                return false
            }
            var body = await dispatchAction(action)
            body["msgId"] = action.msgId
            body["transactionId"] = transactionId
            body["action"] = action.action
            guard let signed = try? signedResponse(body) else {
                syncError = "Pairing secret unavailable after CloudKit action \(action.msgId); action remains unacknowledged."
                return false
            }
            response = signed
            let status = (response["status"] ?? "").lowercased()
            let completedState = status == "error"
                    || status == "failed"
                    || response["ok"] == "false"
                ? "failed"
                : (status == "pending_approval" ? "pending_approval" : "completed")
            await writeTransaction(
                id: transactionId,
                action: action.action,
                state: completedState,
                attempts: 1,
                error: response["message"],
                response: response
            )
        }

        // Persist before sending so a CloudKit delivery failure can retry the
        // response without repeating the already-authorized external effect.
        guard await writeInboxResponse(response, to: responseURL) else {
            syncError = "Could not persist CloudKit response for \(action.msgId); action will not be acknowledged."
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
        let commit = Self.commitCompletionBookkeeping(
            dataRoot: actionStateRoot,
            msgId: action.msgId,
            processedSaved: cloudKitActionProcessedIDPersistence?() ?? saveProcessedIds(),
            archiveError: nil  // CloudKit lane has no pending file to archive.
        )
        if !commit.clean { syncError = commit.syncError }

        do {
            try await sendCloudKitActionResponse(response, correlationID: action.msgId)
            lastInboxAt = Date()
            await writeSnapshots(forceHeavy: true)
            NotificationCenter.default.post(name: .iCloudInboxDidProcess, object: nil)
            return true
        } catch {
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
            try await iCloudBridge.shared.sendCloudKitActionResponse(
                response,
                correlationID: correlationID
            )
        }
    }

    private func dispatchAction(_ action: InboxAction) async -> [String: String] {
        let router = MacSyncActionRouter(
            cancelChatTask: { [weak self] sessionId, runIDs in
                self?.cancelActiveChatTask(for: sessionId, runIDs: runIDs) ?? .noActiveTask
            }
        )
        return await router.dispatch(action)
    }
}
