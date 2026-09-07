// PATCH-2026-05-07: ios-sync MacSyncEngine — SnapshotWriter + InboxWatcher (Mac side)
// SnapshotWriter: source mutations write app-owned Swift runtime state to iCloud Drive `snapshots/`.
//   Touches KVS key `snapshot_updated` so iOS observes immediately.
// InboxWatcher: NSMetadataQuery on `inbox/`. When iOS drops an action JSON, dispatch to
//   the in-process Swift runtime, write response to `responses/<msg_id>.json`, touch KVS `inbox_response_<msg_id>`.

import CommonCrypto
import AppKit
import Foundation
import SwiftUI
import NativeAgentShared
import NativeAgentCore
import KnowledgeGraph
import PersistenceCore

extension MacSyncEngine {
    /// Record a msgId as processed, capping the set at processedIdsCap (drops oldest first).
    func recordProcessed(_ msgId: String) {
        guard !processedMsgIds.contains(msgId) else { return }
        processedMsgIds.insert(msgId)
        processedMsgIdsOrdered.append(msgId)
        while processedMsgIdsOrdered.count > processedIdsCap {
            let oldest = processedMsgIdsOrdered.removeFirst()
            processedMsgIds.remove(oldest)
        }
    }

    // PATCH-2026-05-08: fix-A.3 Persist processed IDs so restarts don't replay
    // archived files. Path shape is owned by ICloudSyncStatePaths so Doctor
    // reads exactly what this writes.

    // fix-snapshot-digest-persist: persist snapshot content digests across
    // restarts so an iCloud reconnect / bridge teardown→setup doesn't re-write
    // every snapshot file (digest map starts empty → every write looks "changed"
    // → full read-storm on iOS). Stored alongside processed_ids.json.
    private var snapshotDigestsURL: URL? {
        let dir = (stateDataRootOverride ?? NativeAgentPaths.dataRoot)
            .appendingPathComponent("icloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snapshot_digests.json")
    }

    // PATCH-2026-05-08: fix-A.3 Persist processedMsgIds across restarts.
    // R10-N8: wrap decode in do/catch so corruption doesn't crash.
    //
    // Sweep R4 item 1: MISSING and UNREADABLE are no longer the same thing.
    // A missing file is genesis — first run, nothing has been processed, an
    // empty set is the truth. An unreadable one (corrupt, partial, permission
    // denied) means the id window EXISTS and we cannot see it; treating that as
    // "nothing has been processed" is precisely what re-dispatches an already
    // executed remote Mac action. On unreadable we keep whatever the in-memory
    // set holds, refuse to trust the empty read, raise syncError, and preserve
    // the bytes so the next save can't quietly destroy the evidence.
    func loadProcessedIds() {
        let restored = Self.restoreProcessedIds(
            dataRoot: NativeAgentPaths.dataRoot,
            inMemory: processedMsgIdsOrdered
        )
        // Re-apply the cap here, not just in recordProcessed: merging markers
        // into a full stored window can push the list past it, and an
        // uncapped window grows without bound across restarts. ACTIVE MARKER
        // ids are EXEMPT from the trim — their whole purpose is preventing a
        // replay while the pending file may still exist, and relying on list
        // ordering to protect them was wrong (markers land near the front;
        // front-eviction would drop them first — gpt-5.5 review 2026-08-06,
        // blocking #1). Markers are bounded by the 30-day prune, so the
        // exemption cannot grow without bound.
        let ids = Self.cappedPreservingMarkers(
            restored.ids,
            cap: processedIdsCap,
            dataRoot: NativeAgentPaths.dataRoot)
        processedMsgIdsOrdered = ids
        processedMsgIds = Set(ids)
        processedIdsUnreadable = restored.unreadable
        if let message = restored.message { syncError = message }
    }

    /// What a restart should believe about already-processed commands, computed
    /// from disk alone so it is provable without a running engine.
    ///
    /// Three inputs, in priority order:
    ///  - completed-but-unarchived MARKERS: the command ran and its response
    ///    landed; only bookkeeping failed. These are processed ids, full stop,
    ///    and folding them in here is what makes the existing duplicate guard
    ///    in `processInboxFiles` refuse to dispatch them again.
    ///  - a MISSING processed_ids.json: genesis. Empty really is the truth.
    ///  - an UNREADABLE processed_ids.json: the window exists and we cannot see
    ///    it. We keep what memory holds, flag it, and preserve the bytes.
    /// Oldest-first trim to `cap` that NEVER evicts an active
    /// completed-unarchived marker id — a trimmed marker id whose pending
    /// file still exists re-dispatches an already-executed remote action on
    /// restart (gpt-5.5 review 2026-08-06, blocking #1). Markers are bounded
    /// by the 30-day prune, so the exemption cannot grow unbounded. Static +
    /// dataRoot-injected so the hermetic tests can prove the exemption.
    nonisolated static func cappedPreservingMarkers(
        _ ids: [String], cap: Int, dataRoot: URL
    ) -> [String] {
        guard ids.count > cap else { return ids }
        let markerIds = Set(ICloudSyncStatePaths.completedUnarchivedMsgIds(dataRoot: dataRoot))
        var overflow = ids.count - cap
        var trimmed: [String] = []
        trimmed.reserveCapacity(cap)
        for id in ids {
            if overflow > 0, !markerIds.contains(id) {
                overflow -= 1
                continue
            }
            trimmed.append(id)
        }
        return trimmed
    }

    nonisolated static func restoreProcessedIds(
        dataRoot: URL,
        inMemory: [String] = []
    ) -> (ids: [String], unreadable: Bool, message: String?) {
        var ids = inMemory
        var messages: [String] = []
        func add(_ id: String) { if !ids.contains(id) { ids.append(id) } }

        let markers = ICloudSyncStatePaths.completedUnarchivedMsgIds(dataRoot: dataRoot)
        if !markers.isEmpty {
            for id in markers { add(id) }
            messages.append(
                "\(markers.count) iPhone command(s) completed but could not be filed; they will not be run again."
            )
            NSLog("[MacSyncEngine] loaded %d completed-but-unarchived marker(s): %@",
                  markers.count, markers.joined(separator: ", "))
        }

        let url = ICloudSyncStatePaths.processedIds(dataRoot: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Genesis: no file has ever been written. Nothing to distrust.
            return (ids, false, messages.isEmpty ? nil : messages.joined(separator: " "))
        }
        do {
            let data = try Data(contentsOf: url)
            let stored = try JSONDecoder().decode([String].self, from: data)
            // fix-R9-9 Restore ordered array so insertion-order eviction is
            // preserved; marker ids append after the stored window.
            var merged = stored
            for id in ids where !stored.contains(id) { merged.append(id) }
            return (merged, false, messages.isEmpty ? nil : messages.joined(separator: " "))
        } catch {
            NSLog("[MacSyncEngine] processed_ids.json UNREADABLE (%@) — keeping %d in-memory id(s); not trusting the empty read",
                  error.localizedDescription, ids.count)
            // Preserve the bytes before any later save overwrites them: this is
            // both the recovery evidence and the durable signal Doctor reports.
            let backup = ICloudSyncStatePaths.processedIdsCorruptBackup(dataRoot: dataRoot)
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: url, to: backup)
            }
            messages.append(
                "Could not read the processed-command list (\(error.localizedDescription)); "
                + "iPhone commands may be re-run. The unreadable file was kept as processed_ids.corrupt.json."
            )
            return (ids, true, messages.joined(separator: " "))
        }
    }

    /// Returns false when the id window could NOT be persisted. Callers must
    /// treat that as "this completion is not durable yet" and leave a marker —
    /// the swallowed `try?` this replaced is half of the replay window.
    @discardableResult
    func saveProcessedIds() -> Bool {
        let saved = Self.persistProcessedIds(processedMsgIdsOrdered, dataRoot: NativeAgentPaths.dataRoot)
        if saved { processedIdsUnreadable = false }
        return saved
    }

    nonisolated static func persistProcessedIds(_ ids: [String], dataRoot: URL) -> Bool {
        let url = ICloudSyncStatePaths.processedIds(dataRoot: dataRoot)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // fix-R9-9 Save ordered array (already capped by recordProcessed).
            let data = try JSONEncoder().encode(ids)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("[MacSyncEngine] processed_ids.json save FAILED: %@", error.localizedDescription)
            return false
        }
    }

    /// Durably records that `msgId` completed even though its bookkeeping did
    /// not. Returns false when even the marker could not be written — the only
    /// case in which a replay is still possible, and one the caller surfaces
    /// rather than swallows.
    @discardableResult
    func writeCompletedUnarchivedMarker(msgId: String, reason: String) -> Bool {
        Self.writeCompletedUnarchivedMarker(
            dataRoot: NativeAgentPaths.dataRoot,
            msgId: msgId,
            reason: reason
        )
    }

    @discardableResult
    nonisolated static func writeCompletedUnarchivedMarker(
        dataRoot: URL,
        msgId: String,
        reason: String
    ) -> Bool {
        let dir = ICloudSyncStatePaths.completedUnarchivedDirectory(dataRoot: dataRoot)
        let url = ICloudSyncStatePaths.completedUnarchivedMarker(dataRoot: dataRoot, msgId: msgId)
        let payload: [String: String] = [
            "msgId": msgId,
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "reason": reason,
        ]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("[MacSyncEngine] could not write completed-unarchived marker for %@: %@",
                  msgId, error.localizedDescription)
            return false
        }
    }

    /// Outcome of the post-response bookkeeping transaction for one command.
    struct CompletionCommit: Sendable, Equatable {
        /// True when the completion is durable through the NORMAL path
        /// (processed-id list saved AND pending file archived).
        var clean: Bool
        /// True when a fallback marker now guarantees no re-dispatch.
        var markerWritten: Bool
        /// nil only when `clean`.
        var syncError: String?
        /// Transaction state to record; nil when `clean` (the caller already
        /// wrote the completed/failed state).
        var transactionState: String?
    }

    /// The post-response half of processing an iOS command, as ONE decision.
    ///
    /// By the time this runs the action has executed and its response has
    /// landed, so the only acceptable outcome is "never dispatch this again".
    /// If either bookkeeping step failed, a durable local marker takes over
    /// that job; if even the marker fails, that is the one case where a replay
    /// is still possible and it is stated plainly instead of swallowed.
    nonisolated static func commitCompletionBookkeeping(
        dataRoot: URL,
        msgId: String,
        processedSaved: Bool,
        archiveError: String?
    ) -> CompletionCommit {
        guard !processedSaved || archiveError != nil else {
            clearCompletedUnarchivedMarker(dataRoot: dataRoot, msgId: msgId)
            return CompletionCommit(clean: true, markerWritten: false, syncError: nil, transactionState: nil)
        }
        var reasons: [String] = []
        if !processedSaved { reasons.append("processed-id list could not be saved") }
        if let archiveError { reasons.append("pending file could not be archived: \(archiveError)") }
        let reason = reasons.joined(separator: "; ")
        let marked = writeCompletedUnarchivedMarker(dataRoot: dataRoot, msgId: msgId, reason: reason)
        let message = marked
            ? "Command \(msgId) finished but its completion record could not be filed (\(reason)). It is marked completed and will not run again."
            : "Command \(msgId) finished but NEITHER its completion record NOR the fallback marker could be written (\(reason)). It could run again on restart — free disk space and check iCloud permissions."
        NSLog("MacSyncEngine.commitCompletionBookkeeping: %@", message)
        return CompletionCommit(
            clean: false,
            markerWritten: marked,
            syncError: message,
            transactionState: "completed_unarchived"
        )
    }

    /// Drops the marker once the completion is durable through the normal path.
    func clearCompletedUnarchivedMarker(msgId: String) {
        Self.clearCompletedUnarchivedMarker(dataRoot: NativeAgentPaths.dataRoot, msgId: msgId)
    }

    nonisolated static func clearCompletedUnarchivedMarker(dataRoot: URL, msgId: String) {
        let url = ICloudSyncStatePaths.completedUnarchivedMarker(dataRoot: dataRoot, msgId: msgId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func loadSnapshotDigests() {
        guard let url = snapshotDigestsURL else { return }
        do {
            let data = try Data(contentsOf: url)
            snapshotFileDigests = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            // Missing or corrupt — start empty; first pass re-writes snapshots
            // and re-seeds the map. Not fatal.
            snapshotFileDigests = [:]
        }
    }

    func saveSnapshotDigests() {
        guard let url = snapshotDigestsURL else { return }
        if let data = try? JSONEncoder().encode(snapshotFileDigests) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// What the durable ledger says about one transaction id.
    /// 2026-09-06: `absent` and `unreadable` are DIFFERENT answers and the
    /// caller must not conflate them. Absent means no row was ever written, so
    /// the action is fresh work. Unreadable means a row may exist and we cannot
    /// tell what it says — the outcome is unknown, and an unknown outcome may
    /// never be re-executed.
    enum InboxTransactionLookup: Sendable {
        case absent
        case unreadable
        case present(ICloudTransactionRecord)
    }

    /// Read the durable transaction ledger row for `id`.
    /// 2026-09-06: the CloudKit action lane needs a durable "this already began
    /// executing" marker that survives a signing/response-write failure and a
    /// restart; the ledger's "running" state is written before dispatch, so it
    /// is that marker. The Drive lane gets the same guarantee from its
    /// `pending_` file rename.
    func readTransaction(id: String) async -> InboxTransactionLookup {
        guard let transactionDir,
              let url = InboxActionFileBoundary.jsonURL(
                in: transactionDir,
                validatedID: id
              ) else {
            // No ledger directory (or a path we refuse to derive) means we
            // cannot prove the action has not already run. Unknown, not fresh.
            return .unreadable
        }
        return await Task.detached(priority: .utility) { [url] () -> InboxTransactionLookup in
            switch Self.coordinatedReadOutcome(at: url) {
            case .missing:
                return .absent
            case .failed:
                return .unreadable
            case .data(let data):
                guard let record = try? JSONDecoder().decode(
                    ICloudTransactionRecord.self,
                    from: data
                ) else { return .unreadable }
                return .present(record)
            }
        }.value
    }

    /// SHA-256 over the same canonical body the inner HMAC covers: the action
    /// envelope re-encoded with sorted keys and the `signature` key removed.
    /// 2026-09-06: the ledger is keyed by `transactionId`, which the PHONE
    /// supplies and which is only defaulted to `msgId`. Two different actions
    /// can therefore arrive under one transaction id, so the reservation has to
    /// be bound to the envelope itself, not just to its id.
    nonisolated static func inboxActionDigest(envelope: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any]
        else { return nil }
        var withoutSignature = object
        withoutSignature.removeValue(forKey: "signature")
        guard let canonical = try? JSONSerialization.data(
            withJSONObject: withoutSignature,
            options: [.sortedKeys]
        ) else { return nil }
        return MacSyncSnapshotIntegrity.digest(canonical)
    }

    /// True when `record` is the reservation for THIS envelope rather than for
    /// a different action that happens to carry the same transaction id.
    /// 2026-09-06: a row written before the binding fields existed records
    /// neither, so the transaction id was its only evidence and ANY envelope
    /// carrying that id was served that row's outcome. Such a row still names
    /// the action it was written for: an unbound row belongs to this envelope
    /// only when the action names agree, and otherwise it is a collision.
    static func inboxLedgerRow(
        _ record: ICloudTransactionRecord,
        matchesMsgId msgId: String,
        digest: String?,
        action: String
    ) -> Bool {
        if let storedMsgId = record.msgId, storedMsgId != msgId { return false }
        if let storedDigest = record.actionDigest, let digest, storedDigest != digest { return false }
        let bound = record.msgId != nil || (record.actionDigest != nil && digest != nil)
        if !bound, record.action != action { return false }
        return true
    }

    /// True when the ledger state proves the action's effect has already been
    /// dispatched to the router, so a redelivery must never run it again.
    static func inboxActionDidExecute(_ state: String) -> Bool {
        switch state {
        case "running", "completed", "failed", "pending_approval",
             "response_write_failed", "completed_unarchived", "unknown":
            return true
        default:
            return false
        }
    }

    /// Returns true when the ledger row is durably on disk afterwards.
    /// 2026-09-06: this used to return Void and swallow every encode,
    /// coordination and write failure, so the "running" reservation the
    /// CloudKit action lane relies on could silently never land while the lane
    /// dispatched anyway. Callers that depend on the reservation must check it.
    @discardableResult
    func writeTransaction(
        id: String,
        action: String,
        state: String,
        attempts: Int = 0,
        error: String? = nil,
        response: [String: String]? = nil,
        msgId: String? = nil,
        actionDigest: String? = nil
    ) async -> Bool {
        guard let transactionDir,
              let url = InboxActionFileBoundary.jsonURL(
                in: transactionDir,
                validatedID: id
              ) else {
            NSLog("[MacSyncEngine] Refused transaction write for invalid remote id")
            return false
        }
        let now = ISO8601DateFormatter().string(from: Date())
        // Off-main read-modify-write, AWAITED so sequential state transitions for
        // the same transaction id (received -> running -> done) complete in order
        // and can't clobber each other under iCloud slowness.
        let wrote = await Task.detached(priority: .utility) { [id, action, state, attempts, error, response, msgId, actionDigest, url, now] () -> Bool in
            // 2026-09-06: this read used to collapse "no row yet" and "the row
            // is there and unreadable" into the same nil, and then wrote a
            // fresh record over the top — so a rejection (or any other state
            // transition) taken while the ledger was unreadable DESTROYED the
            // prior row, including a completed action's stored response. A row
            // that cannot be read is left exactly as it is; the caller sees the
            // write fail and the lane treats the outcome as unknown.
            let existing: ICloudTransactionRecord?
            switch Self.coordinatedReadOutcome(at: url) {
            case .missing:
                existing = nil
            case .failed:
                NSLog("[MacSyncEngine] Ledger row for %@ unreadable; left intact rather than overwritten", id)
                return false
            case .data(let data):
                guard let decoded = try? JSONDecoder().decode(
                    ICloudTransactionRecord.self,
                    from: data
                ) else {
                    NSLog("[MacSyncEngine] Ledger row for %@ did not decode; left intact rather than overwritten", id)
                    return false
                }
                existing = decoded
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
                response: response ?? existing?.response,
                msgId: msgId ?? existing?.msgId,
                actionDigest: actionDigest ?? existing?.actionDigest
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            guard let data = try? encoder.encode(record) else { return false }
            return Self.coordinatedWrite(data: data, to: url)
        }.value
        if !wrote {
            NSLog("[MacSyncEngine] Transaction ledger write failed for %@ (state %@)", id, state)
        }
        return wrote
    }

    /// Why a coordinated read produced no data. `missing` is a normal answer;
    /// `failed` means the file may exist and we could not read it.
    enum CoordinatedReadOutcome: Sendable {
        case data(Data)
        case missing
        case failed
    }

    /// Coordinated read of an iCloud-resident file, distinguishing "there is no
    /// such file" from "the read failed". nonisolated static — safe to call
    /// from detached tasks off the main actor.
    nonisolated static func coordinatedReadOutcome(at url: URL) -> CoordinatedReadOutcome {
        var outcome: CoordinatedReadOutcome = .failed
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            do {
                outcome = .data(try Data(contentsOf: readURL))
            } catch {
                outcome = Self.isNoSuchFileError(error) ? .missing : .failed
            }
        }
        if let coordError {
            outcome = Self.isNoSuchFileError(coordError) ? .missing : .failed
        }
        return outcome
    }

    /// True only for "no such file or directory" — the one error that means
    /// absence rather than an unknown outcome.
    nonisolated static func isNoSuchFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isNoSuchFileError(underlying)
        }
        return false
    }

    /// Coordinated read of an iCloud-resident file. Returns nil if missing or unreadable.
    /// nonisolated static — safe to call from detached tasks off the main actor.
    nonisolated static func coordinatedRead(at url: URL) -> Data? {
        guard case .data(let data) = coordinatedReadOutcome(at: url) else { return nil }
        return data
    }

    /// Coordinated write of `data` to an iCloud-resident `url` with `.forReplacing` intent.
    /// Returns true only when both the coordination and the write succeeded.
    /// nonisolated static — safe to call from detached tasks off the main actor.
    @discardableResult
    nonisolated static func coordinatedWrite(data: Data, to url: URL) -> Bool {
        var wrote = false
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
                wrote = true
            } catch {
                NSLog("[MacSyncEngine] coordinated write failed for %@: %@",
                      writeURL.lastPathComponent, String(describing: error))
            }
        }
        if let coordError {
            NSLog("[MacSyncEngine] file coordination failed for %@: %@",
                  url.lastPathComponent, coordError.localizedDescription)
            return false
        }
        return wrote
    }

    // fix-KVS-quota: NSUbiquitousKeyValueStore is hard-capped at 1024 keys / 1 MB.
    // Each processed iOS command writes a unique `inbox_response_<msgId>` key and
    // nothing ever removed them → after ~1000 commands the store fills and ALL
    // sync (snapshots, inbox triggers, pairing) silently dies. Sweep stale keys:
    //   - drop a key whose corresponding `responses/<msgId>.json` file is gone
    //     (iOS already read + the prune pass deleted it) — safe, response consumed.
    //   - drop a key whose response file is older than the TTL (24h) — iOS has had
    //     ample time to read it; keep recent ones so a just-written response that
    //     iOS hasn't observed yet is preserved.
    //   - hard cap: ONLY if still dangerously close to the 1024-key quota after
    //     the missing-file + TTL passes. The backstop NEVER drops an under-TTL key
    //     whose response file still exists (that would lose a pending, possibly
    //     unread notification — see FIX (D)); it only evicts orphaned keys with no
    //     readable response file, and logs if real pressure remains. The cap is set
    //     high (800, well under the 1024 ceiling) so this branch effectively never
    //     fires in normal operation; the missing-file + TTL passes are the real
    //     quota-protection mechanism.
    // Backstop ceiling kept well below the hard 1024-key KVS quota.
    // Map each key → (modificationDate of its response file, fileExists).
    // A missing file means the response was already consumed + pruned.
    func sweepInboxResponseKVSKeys() async {
        let keyPrefix = inboxResponseKeyPrefix
        let maybeKeys = await withCKTimeout("MacSyncEngine.sweepInboxResponseKVSKeys.readKeys") {
            Array(NSUbiquitousKeyValueStore.default.dictionaryRepresentation.keys.filter { $0.hasPrefix(keyPrefix) })
        }
        guard let keys = maybeKeys else {
            syncError = "Could not read iCloud inbox response keys for cleanup; retrying before the next inbox scan."
            print("[MacSyncEngine] inbox_response_* KVS sweep could not read keys; cleanup will retry.")
            return
        }
        guard !keys.isEmpty else { return }
        let now = Date()
        // The per-key file stats below hit the iCloud-resident responses dir and
        // can block (fileExists / resourceValues / attributesOfItem) — with up to
        // inboxResponseKeyMaxCount keys this is run on every inbox pass, so it must
        // NOT run on the main actor. Build the (key → exists/modified) array off
        // main, then hop back to @MainActor for the KVS mutations below.
        let keyPrefixCount = inboxResponseKeyPrefix.count
        let entries: [MacSyncInboxResponseSweep.Entry] = await Task.detached(priority: .utility) { [responsesDir, keys] in
            let fm = FileManager.default
            var entries: [MacSyncInboxResponseSweep.Entry] = []
            for key in keys {
                let msgId = String(key.dropFirst(keyPrefixCount))
                var modified: Date?
                var exists = false
                if let responsesDir {
                    let url = responsesDir.appendingPathComponent("\(msgId).json")
                    if fm.fileExists(atPath: url.path) {
                        exists = true
                        modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                        if modified == nil {
                            modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                        }
                    }
                }
                entries.append(MacSyncInboxResponseSweep.Entry(key: key, modified: modified, exists: exists))
            }
            return entries
        }.value
        let sweepPlan = MacSyncInboxResponseSweep.plan(
            entries: entries,
            now: now,
            ttl: inboxResponseKeyTTL,
            cap: inboxResponseKeyMaxCount
        )
        // FIX (D): Hard cap backstop. After the missing-file + TTL passes, every
        // remaining survivor is by definition under-TTL AND has a present
        // response file — i.e. a still-pending, possibly-unread notification.
        // The previous backstop evicted the oldest survivors purely to hit a
        // count cap, which could silently drop a pending response (data loss).
        // We now NEVER evict an under-TTL key whose response file still exists
        // just to satisfy a count cap. The only keys eligible here are ones with
        // no readable response file mtime (orphaned/unreadable) — provably odd,
        // never a clean pending response. If genuine pressure remains we log it
        // (observable) rather than dropping pending responses; the missing-file +
        // TTL passes are the real quota-protection mechanism.
        if sweepPlan.exceedsCap {
            print("[MacSyncEngine] inbox_response_* KVS keys (\(sweepPlan.retainedCount)) exceed backstop cap \(inboxResponseKeyMaxCount); recent readable response keys were retained rather than dropped.")
        }
        if !sweepPlan.keysToRemove.isEmpty {
            // Sendable-capture: snapshot to a let so the @Sendable closure
            // doesn't capture the outer `var`.
            let snapshot = sweepPlan
            let didSynchronize = await withCKTimeout("MacSyncEngine.sweepInboxResponseKVSKeys.removeKeys") {
                let kvs = NSUbiquitousKeyValueStore.default
                MacSyncInboxResponseSweep.apply(snapshot) { key in
                    kvs.removeObject(forKey: key)
                }
                return kvs.synchronize()
            }
            if didSynchronize != true {
                syncError = "Could not sweep stale iCloud inbox response keys; retrying before the next inbox scan."
                print("[MacSyncEngine] inbox_response_* KVS sweep was not synchronized; stale key cleanup will retry.")
            }
        }
    }

    // R11-N30: Delete archive/response files older than 7 days; cap directory at 50 MB.
    func pruneOldArchiveFiles() {
        // Capture the iCloud dirs on main, then do the listing + deletes OFF the
        // main actor — contentsOfDirectory on an iCloud-resident dir can block,
        // and this runs from a recurring timer. Fire-and-forget: best-effort
        // cleanup with no state mutation and no ordering dependency.
        // Include the malformed-file archive (inbox/_rejected/) in the sweep so
        // rejected files get the same 7-day TTL + 50 MB cap as other archives —
        // otherwise they accumulate unbounded. pruneArchiveDirs no-ops on a
        // missing dir, so it's safe to list even before _rejected is created.
        // Sweep R4 item 1: completion markers are state, so they get a cleanup
        // path like every other add. They must outlive the pending files that
        // could still re-present the same command (7-day archive TTL), so 30
        // days is a deliberate multiple of that, not a guess.
        let markerDir = ICloudSyncStatePaths.completedUnarchivedDirectory(
            dataRoot: NativeAgentPaths.dataRoot
        )
        Task.detached(priority: .background) {
            Self.pruneCompletedUnarchivedMarkers(in: markerDir)
        }
        let rejectedDir = inboxDir?.appendingPathComponent("_rejected")
        let dirs = [inboxDir, responsesDir, rejectedDir].compactMap { $0 }
        guard !dirs.isEmpty else { return }
        pruneDeadlineTask?.cancel()
        pruneDeadlineTask = Task { [weak self] in
            await Task.detached(priority: .background) {
                Self.pruneArchiveDirs(dirs)
            }.value
            guard !Task.isCancelled else { return }
            self?.rescheduleArchiveRetentionDeadline()
        }
    }

    /// Recompute the earliest exact seven-day crossing from canonical iCloud
    /// file metadata. Directory events call this after new/renamed files; the
    /// prune path calls it after deletes. A daily integrity fallback remains
    /// only when the directories are empty or metadata is unreadable.
    func rescheduleArchiveRetentionDeadline(now: Date = Date()) {
        let rejectedDir = inboxDir?.appendingPathComponent("_rejected")
        let dirs = [inboxDir, responsesDir, rejectedDir].compactMap { $0 }
        guard isActive, !dirs.isEmpty else { return }
        pruneDeadlineTask?.cancel()
        pruneDeadlineTask = Task { [weak self] in
            let deadline = await Task.detached(priority: .background) {
                Self.nextArchiveRetentionDeadline(in: dirs, after: now)
            }.value
            guard !Task.isCancelled, let self, self.isActive else { return }
            let next = deadline ?? now.addingTimeInterval(24 * 60 * 60)
            let delay = max(0, next.timeIntervalSince(Date()))
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, self.isActive else { return }
            self.pruneOldArchiveFiles()
        }
    }

    nonisolated static func nextArchiveRetentionDeadline(
        in dirs: [URL],
        after now: Date
    ) -> Date? {
        let fm = FileManager.default
        let maxBytes = 50 * 1024 * 1024
        var deadlines: [Date] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isDirectoryKey],
                options: []
            ) else { continue }
            var totalBytes = 0
            for item in items {
                let values = try? item.resourceValues(forKeys: [
                    .creationDateKey, .fileSizeKey, .isDirectoryKey,
                ])
                guard values?.isDirectory != true else { continue }
                totalBytes += values?.fileSize ?? 0
                if let created = values?.creationDate {
                    let due = created.addingTimeInterval(7 * 24 * 60 * 60)
                    deadlines.append(max(due, now))
                }
            }
            if totalBytes > maxBytes { deadlines.append(now) }
        }
        return deadlines.min()
    }

    /// Drops completion markers older than the retention floor. A marker only
    /// matters while a pending file for the same command could still be seen,
    /// and those are gone after 7 days.
    nonisolated static func pruneCompletedUnarchivedMarkers(
        in dir: URL,
        olderThan retention: TimeInterval = 30 * 24 * 3600,
        now: Date = Date()
    ) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = now.addingTimeInterval(-retention)
        for url in items
        where url.pathExtension == ICloudSyncStatePaths.completedUnarchivedExtension {
            guard let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate else { continue }
            if modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// nonisolated static — runs the prune scan/delete off the main actor.
    nonisolated static func pruneArchiveDirs(_ dirs: [URL]) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let maxBytes: Int = 50 * 1024 * 1024  // 50 MB
        for dirURL in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isDirectoryKey], options: []) else { continue }
            // Prune FILES ONLY — never delete subdirectories. inboxDir's listing
            // includes the `_rejected` subdir as an item; removeItem on it would
            // recursively wipe newer rejected files by the folder's own date. The
            // _rejected dir is pruned as its own entry in `dirs`.
            func isDir(_ u: URL) -> Bool { ((try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
            // Delete files older than 7 days
            for url in items where !isDir(url) {
                if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff {
                    try? fm.removeItem(at: url)
                }
            }
            // Cap at 50 MB — delete oldest first
            let remaining = ((try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isDirectoryKey], options: [])) ?? []).filter { !isDir($0) }
            let sorted = remaining.sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
                let d2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
                return d1 < d2
            }
            var totalSize = sorted.reduce(0) { acc, url in
                acc + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            for url in sorted {
                guard totalSize > maxBytes else { break }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                try? fm.removeItem(at: url)
                totalSize -= size
            }
        }
    }
}
