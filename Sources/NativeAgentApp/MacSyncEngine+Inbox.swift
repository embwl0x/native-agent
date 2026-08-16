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
            await writeTransaction(id: transactionId, action: action.action, state: "received", attempts: 1)

            // C.1: Validate HMAC signature + timestamp freshness before dispatching.
            if let validationError = await validateInboxAction(data: data, action: action) {
                syncError = "Rejected inbox message \(action.msgId): \(validationError)"
                if validationError.contains("pairing secret unavailable") {
                    // Local authority is unavailable, so this is not evidence
                    // that the peer sent a bad action. Leave it untouched for
                    // exact retry after deliberate local repair.
                    continue
                }
                guard await writeRejectedResponseIfNeeded(
                    action: action,
                    transactionId: transactionId,
                    message: validationError
                ) else {
                    // Do not consume an invalid remote action unless its
                    // signed rejection durably exists for the peer to read.
                    continue
                }
                await writeTransaction(id: transactionId, action: action.action, state: "rejected", attempts: 1, error: validationError)
                // Still mark as processed so a replayed/tampered file isn't retried.
                recordProcessed(action.msgId)  // fix-R9-9
                saveProcessedIds()
                // PATCH-2026-05-08: fix-A.3 Use .done suffix so the file is no longer
                // matched by the `.json` filter on next query update or restart.
                let archiveURL = inboxDir.appendingPathComponent("rejected_\(fileURL.lastPathComponent).done")
                await Task.detached(priority: .utility) { [fileURL, archiveURL] in
                    try? FileManager.default.moveItem(at: fileURL, to: archiveURL)
                }.value
                continue
            }

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
            await writeTransaction(id: transactionId, action: action.action, state: "running", attempts: 1)
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
            let responseWritten = await writeInboxResponse(response, to: responseURL)
            guard responseWritten else {
                syncError = "Could not write iCloud response for \(action.msgId); command left pending."
                await writeTransaction(id: transactionId, action: action.action, state: "response_write_failed", attempts: 1, error: syncError)
                await Task.detached(priority: .utility) { [pendingURL] in
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: pendingURL.path)
                }.value
                continue
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
            // Writing to iCloud Drive may block — do it off the main actor.
            await Task.detached(priority: .utility) { [responseURL, responseData] in
                Self.coordinatedWrite(data: responseData, to: responseURL)
            }.value
            if FileManager.default.fileExists(atPath: responseURL.path) { return true }
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
        guard let responsesDir,
              let responseURL = InboxActionFileBoundary.jsonURL(
                in: responsesDir,
                validatedID: ids.messageID
              ) else { return false }

        // A prior attempt may have executed successfully but lost its CloudKit
        // response send. Re-send the durable signed response; never redispatch.
        if processedMsgIds.contains(action.msgId) {
            let responseTask = Task<[String: String]?, Never>.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: responseURL) else { return nil }
                return try? JSONDecoder().decode([String: String].self, from: data)
            }
            guard let response = await responseTask.value else {
                return false
            }
            do {
                try await iCloudBridge.shared.sendCloudKitActionResponse(
                    response,
                    correlationID: action.msgId
                )
                return true
            } catch {
                syncError = "Could not resend CloudKit action response \(action.msgId): \(error.localizedDescription)"
                return false
            }
        }

        let transactionId = ids.transactionID
        await writeTransaction(
            id: transactionId,
            action: action.action,
            state: "received",
            attempts: 1
        )

        let response: [String: String]
        if let validationError = await validateInboxAction(data: data, action: action) {
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
            if let peerCreatedAt = ISO8601DateFormatter().date(from: action.createdAt) {
                do {
                    try await SignedPeerEvidenceStore.record(
                        eventID: action.msgId,
                        channel: .inboxAction,
                        peerCreatedAt: peerCreatedAt,
                        dataRoot: NativeAgentPaths.dataRoot
                    )
                } catch {
                    NSLog("[MacSyncEngine] could not persist CloudKit action peer evidence for %@: %@",
                          action.msgId, error.localizedDescription)
                }
            }
            await writeTransaction(
                id: transactionId,
                action: action.action,
                state: "running",
                attempts: 1
            )
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
        // Sweep R4 item 1 (CloudKit lane, same hazard as the Drive lane above):
        // the action has already executed. If the id window cannot be persisted
        // the in-process guard at the top of this function still holds, but a
        // restart would lose it — so leave the durable marker instead.
        recordProcessed(action.msgId)
        let commit = Self.commitCompletionBookkeeping(
            dataRoot: NativeAgentPaths.dataRoot,
            msgId: action.msgId,
            processedSaved: saveProcessedIds(),
            archiveError: nil  // CloudKit lane has no pending file to archive.
        )
        if !commit.clean { syncError = commit.syncError }

        do {
            try await iCloudBridge.shared.sendCloudKitActionResponse(
                response,
                correlationID: action.msgId
            )
            lastInboxAt = Date()
            await writeSnapshots(forceHeavy: true)
            NotificationCenter.default.post(name: .iCloudInboxDidProcess, object: nil)
            return true
        } catch {
            syncError = "CloudKit action completed but its response is waiting to resend: \(error.localizedDescription)"
            return false
        }
    }

    private func dispatchAction(_ action: InboxAction) async -> [String: String] {
        let router = MacSyncActionRouter(
            cancelChatTask: { [weak self] sessionId in
                self?.cancelActiveChatTask(for: sessionId) ?? false
            }
        )
        return await router.dispatch(action)
    }
}
