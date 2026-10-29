// Mac device-sync storage and inbox bookkeeping.
// SnapshotWriter: source mutations write app-owned Swift runtime state to iCloud Drive `snapshots/`.
//   Touches KVS key `snapshot_updated` so iOS observes immediately.
// InboxWatcher: NSMetadataQuery on `inbox/`. When iOS drops an action JSON, dispatch to
//   the in-process Swift runtime, write response to `responses/<msg_id>.json`, touch KVS `inbox_response_<msg_id>`.

import CommonCrypto
import AppKit
import Foundation
import DeviceSyncState
import Darwin
import NativeAgentShared
import NativeAgentCore
import MemoryV2
import PersistenceCore
// Blueprint: | `MacSyncEngine+Storage.swift` | `MacSyncEngine`: `recordProcessed`, `restoreState`, `cappedPreservingMarkers`; consolidated replay/digest restoration and device bookkeeping await the shared `DeviceSyncStorage` actor in `DeviceSync.swift` before admission/acknowledgement |

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

    // Persist snapshot digests across restarts to avoid rewriting unchanged files on reconnect.
    nonisolated private static func snapshotDigestsURL(dataRoot: URL) -> URL {
        let dir = dataRoot
            .appendingPathComponent("icloud", isDirectory: true)
        return dir.appendingPathComponent("snapshot_digests.json")
    }

    func restoreState(generation: UInt64) async -> Bool {
        let dataRoot = sync.dataRoot
        let inMemory = processedMsgIdsOrdered
        let inMemoryDigests = snapshotFileDigests
        let retiringWriter = snapshotWriteInFlight || workActivityPublicationTask != nil
        let cap = processedIdsCap
        let restored = await sync.storage.perform {
            let processed = Self.restoreProcessedIds(dataRoot: dataRoot, inMemory: inMemory)
            let digests: [String: SnapshotFileDigest]
            do {
                let data = try Data(contentsOf: Self.snapshotDigestsURL(dataRoot: dataRoot))
                digests = try JSONDecoder().decode([String: SnapshotFileDigest].self, from: data)
            } catch {
                // Derived state is reseeded by the first snapshot pass.
                digests = [:]
            }
            return (processed, digests)
        }
        guard generation == snapshotLifecycleGeneration, !Task.isCancelled else { return false }
        // Retiring writes and command completions can settle while disk reads run.
        let completed = processedMsgIdsOrdered.filter { !inMemory.contains($0) }
        var ids = restored.0.ids
        ids.append(contentsOf: completed.filter { !ids.contains($0) })
        processedMsgIdsOrdered = Self.cappedPreservingMarkers(
            ids, cap: cap, markerIds: restored.0.markerIds.union(completed))
        processedMsgIds = Set(processedMsgIdsOrdered)
        if let message = restored.0.message { syncError = message }
        if !retiringWriter, snapshotFileDigests == inMemoryDigests { snapshotFileDigests = restored.1 }
        return true
    }

    /// Trim oldest first without evicting marker or newly completed ids; 30-day marker retention bounds the exemption.
    nonisolated static func cappedPreservingMarkers(
        _ ids: [String], cap: Int, markerIds: Set<String>
    ) -> [String] {
        guard ids.count > cap else { return ids }
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

    /// Missing means genesis; unreadable state retains memory, preserves bytes and reports the error.
    /// Completion markers prevent replay even when filing the response failed.
    nonisolated static func restoreProcessedIds(
        dataRoot: URL,
        inMemory: [String] = []
    ) -> (ids: [String], unreadable: Bool, message: String?, markerIds: Set<String>) {
        var ids = inMemory
        var messages: [String] = []
        func add(_ id: String) { if !ids.contains(id) { ids.append(id) } }

        let markers = ICloudSyncStatePaths.completedUnarchivedMsgIds(dataRoot: dataRoot)
        if !markers.isEmpty {
            for id in markers { add(id) }
            messages.append(
                "\(markers.count) iPhone command(s) completed but could not be filed; they will not be run again."
            )
            nativeLog("[MacSyncEngine] loaded %d completed-but-unarchived marker(s): %@",
                  markers.count, markers.joined(separator: ", "))
        }

        let url = ICloudSyncStatePaths.processedIds(dataRoot: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (ids, false, messages.isEmpty ? nil : messages.joined(separator: " "), Set(markers))
        }
        do {
            let data = try Data(contentsOf: url)
            let stored = try JSONDecoder().decode([String].self, from: data)
            // Preserve insertion order; append marker and in-memory ids after the stored window.
            var merged = stored
            for id in ids where !stored.contains(id) { merged.append(id) }
            return (merged, false, messages.isEmpty ? nil : messages.joined(separator: " "), Set(markers))
        } catch {
            nativeLog("[MacSyncEngine] processed_ids.json UNREADABLE (%@) — keeping %d in-memory id(s); not trusting the empty read",
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
            return (ids, true, messages.joined(separator: " "), Set(markers))
        }
    }

    /// False means the completion is not durable; callers must leave a replay-protection marker.
    @discardableResult
    func saveProcessedIds() async -> Bool {
        let ids = processedMsgIdsOrdered
        let root = sync.dataRoot
        return await sync.storage.perform { Self.persistProcessedIds(ids, dataRoot: root) }
    }

    nonisolated static func persistProcessedIds(_ ids: [String], dataRoot: URL) -> Bool {
        let url = ICloudSyncStatePaths.processedIds(dataRoot: dataRoot)
        do {
            let data = try JSONEncoder().encode(ids)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url)
            return true
        } catch {
            nativeLog("[MacSyncEngine] processed_ids.json save FAILED: %@", error.localizedDescription)
            return false
        }
    }

    /// Durably records that `msgId` completed even though its bookkeeping did
    /// not. Returns false when even the marker could not be written — the only
    /// case in which a replay is still possible, and one the caller surfaces
    /// rather than swallows.
    @discardableResult
    nonisolated static func writeCompletedUnarchivedMarker(
        dataRoot: URL,
        msgId: String,
        reason: String
    ) -> Bool {
        let url = ICloudSyncStatePaths.completedUnarchivedMarker(dataRoot: dataRoot, msgId: msgId)
        let payload: [String: String] = [
            "msgId": msgId,
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "reason": reason,
        ]
        do {
            let data = try JSONEncoder().encode(payload)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url)
            return true
        } catch {
            nativeLog("[MacSyncEngine] could not write completed-unarchived marker for %@: %@",
                  msgId, error.localizedDescription)
            return false
        }
    }

    /// Outcome of the post-response bookkeeping transaction for one command.
    struct CompletionCommit: Sendable, Equatable {
        /// True when the completion is durable through the NORMAL path
        /// (processed-id list saved AND pending file archived).
        var clean: Bool
        /// True when a durable completion marker guarantees no re-dispatch.
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
        nativeLog("MacSyncEngine.commitCompletionBookkeeping: %@", message)
        return CompletionCommit(
            clean: false,
            markerWritten: marked,
            syncError: message,
            transactionState: "completed_unarchived"
        )
    }

    /// Drops the marker once the completion is durable through the normal path.
    nonisolated static func clearCompletedUnarchivedMarker(dataRoot: URL, msgId: String) {
        let url = ICloudSyncStatePaths.completedUnarchivedMarker(dataRoot: dataRoot, msgId: msgId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func saveSnapshotDigests() async {
        let url = Self.snapshotDigestsURL(dataRoot: sync.dataRoot)
        let digests = snapshotFileDigests
        await sync.storage.perform {
            do {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(digests), to: url)
            } catch { nativeLog("[MacSyncEngine] could not save snapshot digests: %@", error.localizedDescription) }
        }
    }

    /// Absent means no ledger row; unreadable means an unknown outcome that must never be re-executed.
    enum InboxTransactionLookup: Sendable {
        case absent
        case unreadable
        case present(ICloudTransactionRecord)
    }

    /// Read the durable transaction ledger row for id.
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

    /// Bind reservations to the envelope with SHA-256 over sorted-key JSON excluding signature, as the inner HMAC does.
    nonisolated static func inboxActionDigest(envelope: Data) -> String? {
        guard let canonical = try? BridgeMessage.innerActionCanonicalBody(envelope) else { return nil }
        return MacSyncSnapshotIntegrity.digest(canonical)
    }

    /// Match bound fields, or action names for unbound rows, to reject transaction-id collisions.
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
        ["running", "completed", "failed", "pending_approval", "outcome_unknown",
         "response_write_failed", "completed_unarchived", "unknown"].contains(state)
    }

    struct InboxTransactionWrite: Sendable {
        let url: URL
        let contents: Data
    }

    /// Return the confirmed durable write; a running reservation must succeed before dispatch.
    @discardableResult
    func writeTransaction(
        id: String,
        action: String,
        state: String,
        attempts: Int = 0,
        error: String? = nil,
        response: [String: String]? = nil,
        msgId: String? = nil,
        actionDigest: String? = nil,
        directory: URL? = nil
    ) async -> InboxTransactionWrite? {
        guard let transactionDir = directory ?? transactionDir,
              let url = InboxActionFileBoundary.jsonURL(
                in: transactionDir,
                validatedID: id
              ) else {
            nativeLog("[MacSyncEngine] Refused transaction write for invalid remote id")
            return nil
        }
        let now = ISO8601DateFormatter().string(from: Date())
        // Off-main read-modify-write, AWAITED so sequential state transitions for
        // the same transaction id (received -> running -> done) complete in order
        // and can't clobber each other under iCloud slowness.
        let written = await Task.detached(priority: .utility) { [id, action, state, attempts, error, response, msgId, actionDigest, url, now] () -> Data? in
            // Preserve unreadable ledger bytes and fail the write so the outcome remains unknown.
            let existing: ICloudTransactionRecord?
            switch Self.coordinatedReadOutcome(at: url) {
            case .missing:
                existing = nil
            case .failed:
                nativeLog("[MacSyncEngine] Ledger row for %@ unreadable; left intact rather than overwritten", id)
                return nil
            case .data(let data):
                guard let decoded = try? JSONDecoder().decode(
                    ICloudTransactionRecord.self,
                    from: data
                ) else {
                    nativeLog("[MacSyncEngine] Ledger row for %@ did not decode; left intact rather than overwritten", id)
                    return nil
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
            guard let data = try? encoder.encode(record),
                  Self.coordinatedWriteReturningError(data: data, to: url) == nil else { return nil }
            return data
        }.value
        guard let written else {
            nativeLog("[MacSyncEngine] Transaction ledger write failed for %@ (state %@)", id, state)
            return nil
        }
        return InboxTransactionWrite(url: url, contents: written)
    }

    /// Retirement before dispatch releases only this write. Comparison and
    /// replacement share one coordinated access so an advanced row stays intact.
    func releaseUndispatchedInboxAction(_ reservation: InboxTransactionWrite) async {
        await sync.storage.perform {
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: reservation.url, options: .forReplacing, error: &coordinationError
            ) { url in
                do {
                    guard try Data(contentsOf: url) == reservation.contents else { return }
                    var record = try JSONDecoder().decode(ICloudTransactionRecord.self, from: reservation.contents)
                    guard record.state == "running" else { return }
                    record.state = "received"
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                    try encoder.encode(record).write(to: url, options: .atomic)
                } catch {
                    nativeLog("[MacSyncEngine] Could not release undispatched action reservation: %@", error.localizedDescription)
                }
            }
            if let coordinationError {
                nativeLog("[MacSyncEngine] Could not coordinate undispatched action release: %@", coordinationError.localizedDescription)
            }
        }
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
                let fd = Darwin.open(readURL.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else {
                    outcome = errno == ENOENT ? .missing : .failed
                    return
                }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                let maximumBytes = 64 * 1_048_576
                var metadata = stat()
                guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                      metadata.st_size <= maximumBytes else { return }
                var data = Data()
                while let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)),
                      !chunk.isEmpty {
                    data.append(chunk)
                    guard data.count <= maximumBytes else { return }
                }
                outcome = .data(data)
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
    public nonisolated static func isNoSuchFileError(_ error: Error) -> Bool {
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

    /// Coordinated write returning an optional error description (nil = success).
    /// nonisolated static — safe to call from detached tasks off the main actor.
    nonisolated static func coordinatedWriteReturningError(data: Data, to url: URL) -> String? {
        var writeError: String?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                writeError = error.localizedDescription
            }
        }
        if writeError == nil, let coordError {
            writeError = coordError.localizedDescription
        }
        if let writeError { nativeLog("[MacSyncEngine] coordinated write failed for %@: %@", url.lastPathComponent, writeError) }
        return writeError
    }


    // Reclaim missing/expired response keys within KVS's 1024-key/1 MB quota; pressure alone cannot discard recent readable replies.
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

    private var retainedTransactionDirectories: [URL] {
        [transactionDir, PersistenceCore.defaultDataRoot()
            .appendingPathComponent("icloud/chat_transactions", isDirectory: true)].compactMap { $0 }
    }

    /// One retention reconcile at a time, owned by this task: each request
    /// cancels its predecessor and awaits its end before scanning, and every
    /// scan and delete runs on the engine's storage executor. The loop prunes,
    /// finds the next exact crossing from metadata, sleeps until it, repeats.
    /// Directory and exact transaction-file events reconcile again (including
    /// downloads and readability changes); failed deletion keeps its floor.
    /// Rejected files get the same 7-day TTL and 50 MB cap as other archives.
    /// Completion markers must outlive any pending file that could re-present
    /// the same command (7-day archive TTL), so they keep 30 days.
    func reconcileArchiveRetention(pruneFirst: Bool) {
        let rejectedDir = inboxDir?.appendingPathComponent("_rejected")
        let dirs = [inboxDir, responsesDir, rejectedDir].compactMap { $0 }
        let transactionDirectories = retainedTransactionDirectories
        let markerDir = ICloudSyncStatePaths.completedUnarchivedDirectory(dataRoot: PersistenceCore.defaultDataRoot())
        guard isActive, !dirs.isEmpty else { return }
        let previous = pruneDeadlineTask
        let generation = snapshotLifecycleGeneration
        previous?.cancel()
        pruneDeadlineTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.isActive,
                  generation == self.snapshotLifecycleGeneration else { return }
            defer { if generation == self.snapshotLifecycleGeneration, !Task.isCancelled { self.pruneDeadlineTask = nil } }
            // Register before reading transaction metadata or contents. The
            // directory watch remains armed while this file set is discovered.
            let observing = await self.startArchiveRetentionWatcher(transactionDirectories: transactionDirectories)
            if !observing { return }
            var prune = pruneFirst && (self.archiveRetentionRetryAfter ?? .distantPast) <= Date()
            while !Task.isCancelled, self.isActive, generation == self.snapshotLifecycleGeneration {
                if prune {
                    let failed = await self.sync.storage.perform {
                        let markerFailed = Self.pruneCompletedUnarchivedMarkers(in: markerDir)
                        return Self.pruneArchiveDirs(dirs, transactionDirectories: transactionDirectories) || markerFailed
                    }
                    guard !Task.isCancelled, self.isActive, generation == self.snapshotLifecycleGeneration else { return }
                    self.archiveRetentionRetryAfter = failed ? Date().addingTimeInterval(60) : nil
                }
                let now = Date()
                let deadline = await self.sync.storage.perform {
                    Self.nextArchiveRetentionDeadline(in: dirs, after: now, transactionDirectories: transactionDirectories,
                                                     completionMarkerDirectory: markerDir)
                }
                guard !Task.isCancelled, self.isActive, generation == self.snapshotLifecycleGeneration else { return }
                // No expiry and no failed deletion: directory and exact-file
                // events own the next wake, including a deferred read becoming
                // available. Empty archives need no daily sampling pass.
                guard let next = self.archiveRetentionRetryAfter ?? deadline else { return }
                let delay = next.timeIntervalSince(Date())
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                prune = true
            }
        }
    }

    /// Metadata only, never file contents. A row past its crossing was
    /// decided by the prune that crossing armed and does not re-arm it.
    nonisolated static func nextArchiveRetentionDeadline(
        in dirs: [URL],
        after now: Date,
        transactionDirectories: [URL] = [],
        completionMarkerDirectory: URL? = nil
    ) -> Date? {
        let fm = FileManager.default
        let maxBytes = 50 * 1024 * 1024
        var deadlines: [Date] = []
        for dir in dirs {
            guard !Task.isCancelled, let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isDirectoryKey],
                options: []
            ) else { continue }
            var totalBytes = 0
            for item in items where !Task.isCancelled {
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
        for transactionDirectory in transactionDirectories {
            guard !Task.isCancelled, let items = try? fm.contentsOfDirectory(at: transactionDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for item in items where !Task.isCancelled {
                if let due = transactionRetentionCrossing(at: item), due > now {
                    deadlines.append(due)
                }
            }
        }
        if let completionMarkerDirectory,
           let items = try? fm.contentsOfDirectory(at: completionMarkerDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for item in items where item.pathExtension == ICloudSyncStatePaths.completedUnarchivedExtension {
                if let written = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    deadlines.append(max(written.addingTimeInterval(30 * 24 * 3600), now))
                }
            }
        }
        return deadlines.min()
    }

    /// A row's clock is its last write, which is when its updatedAt was set.
    nonisolated static func transactionRetentionCrossing(at url: URL) -> Date? {
        guard url.pathExtension == "json",
              let written = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return nil }
        return written.addingTimeInterval(30 * 24 * 60 * 60)
    }

    /// Keep active, uncertain action and unreadable rows. Recovered chats are
    /// terminal even with an unknown outcome; thirty days exceed their window.
    /// Contents are read only for a local file or an iCloud item whose
    /// metadata says it is current: a read of anything else blocks its thread
    /// until iCloud answers. Unreadable metadata is not readable yet; an item
    /// not yet current has its download asked for. Its exact file is already
    /// watched, so content or attribute changes wake the next prune.
    nonisolated static func isTerminalTransaction(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              let ubiquitous = values.isUbiquitousItem else { return false }
        if ubiquitous, values.ubiquitousItemDownloadingStatus != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return false
        }
        guard let data = try? Data(contentsOf: url) else { return false }
        if url.deletingLastPathComponent().lastPathComponent == "chat_transactions" {
            return iCloudBridge.isTerminalChatTransaction(data)
        }
        guard let record = try? JSONDecoder().decode(ICloudTransactionRecord.self, from: data) else { return false }
        return record.state == "completed" || record.state == "failed"
            || (record.action == "chat" && record.state == "unknown")
    }

    /// Drops completion markers older than the retention floor. A marker only
    /// matters while a pending file for the same command could still be seen,
    /// and those are gone after 7 days.
    @discardableResult
    nonisolated static func pruneCompletedUnarchivedMarkers(
        in dir: URL,
        olderThan retention: TimeInterval = 30 * 24 * 3600,
        now: Date = Date()
    ) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return fm.fileExists(atPath: dir.path) }
        var failed = false
        let cutoff = now.addingTimeInterval(-retention)
        for url in items
        where url.pathExtension == ICloudSyncStatePaths.completedUnarchivedExtension {
            guard let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate else { continue }
            if modified <= cutoff {
                do { try fm.removeItem(at: url) }
                catch { failed = true }
            }
        }
        return failed
    }

    /// nonisolated static — runs the prune scan/delete off the main actor.
    @discardableResult
    nonisolated static func pruneArchiveDirs(_ dirs: [URL], transactionDirectories: [URL] = []) -> Bool {
        let fm = FileManager.default
        let now = Date()
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        let maxBytes: Int = 50 * 1024 * 1024  // 50 MB
        var failed = false
        func remove(_ url: URL) -> Bool {
            do {
                try fm.removeItem(at: url)
                return true
            } catch {
                if isNoSuchFileError(error) { return true }
                failed = true
                nativeLog("[MacSyncEngine] Archive cleanup failed for %@: %@", url.lastPathComponent, error.localizedDescription)
                return false
            }
        }
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
                    _ = remove(url)
                }
            }
            // Cap at 50 MB — delete oldest first
            let remaining = ((try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isDirectoryKey], options: [])) ?? [])
                .compactMap { url -> (url: URL, created: Date, size: Int)? in
                    let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey, .isDirectoryKey])
                    guard values?.isDirectory != true else { return nil }
                    return (url, values?.creationDate ?? .distantFuture, values?.fileSize ?? 0)
                }.sorted { $0.created < $1.created }
            var totalSize = remaining.reduce(0) { $0 + $1.size }
            for file in remaining {
                guard totalSize > maxBytes else { break }
                if remove(file.url) { totalSize -= file.size }
            }
        }
        for transactionDirectory in transactionDirectories {
            guard let items = try? fm.contentsOfDirectory(at: transactionDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) else { continue }
            for item in items {
                if let due = transactionRetentionCrossing(at: item), due <= now, isTerminalTransaction(at: item) {
                    _ = remove(item)
                }
            }
        }
        return failed
    }
}
