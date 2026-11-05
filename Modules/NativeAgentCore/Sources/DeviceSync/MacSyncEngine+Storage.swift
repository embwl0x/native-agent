import CommonCrypto
import AppKit
import Foundation
import DeviceSyncState
import Darwin
import NativeAgentShared
import NativeAgentCore
import MemoryV2
import PersistenceCore
// Blueprint: | `MacSyncEngine+Storage.swift` | `MacSyncEngine`, `DeviceSyncStorage`; Checked replay/digest and ledger storage. |

extension MacSyncEngine {
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
            var digestFailure: String?
            do {
                let data = try Data(contentsOf: Self.snapshotDigestsURL(dataRoot: dataRoot))
                digests = try JSONDecoder().decode([String: SnapshotFileDigest].self, from: data)
            } catch {
                digests = [:]
                if !Self.isNoSuchFileError(error) {
                    digestFailure = """
                        Snapshot digest cache is unavailable (\(error.localizedDescription)); preserve icloud/snapshot_digests.json and repair its read \
                        before restarting phone sync.
                        """
                    nativeLog("[MacSyncEngine] %@", digestFailure ?? "")
                }
            }
            return (processed, digests, digestFailure)
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
        if restored.0.unreadable { return false }
        if let message = restored.2 {
            syncError = message
            return false
        }
        if !retiringWriter, snapshotFileDigests == inMemoryDigests { snapshotFileDigests = restored.1 }
        return true
    }

    /// Eviction must protect markers and newly completed IDs; 30-day marker retention bounds that exemption.
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

    /// Missing means genesis; unreadable state retains memory, preserves bytes and reports the error. Completion markers prevent replay even when filing the
    /// response failed.
    nonisolated static func restoreProcessedIds(
        dataRoot: URL,
        inMemory: [String] = []
    ) -> (ids: [String], unreadable: Bool, message: String?, markerIds: Set<String>) {
        var ids = inMemory
        var messages: [String] = []
        func add(_ id: String) { if !ids.contains(id) { ids.append(id) } }

        let markers: [String]
        do { markers = try ICloudSyncStatePaths.completedUnarchivedMsgIds(dataRoot: dataRoot) }
        catch {
            let message = """
                Completed iPhone command evidence could not be read (\(error.localizedDescription)). Command admission is paused; restore access to \
                icloud/completed-unarchived and reconnect the phone.
                """
            nativeLog("[MacSyncEngine] %@", message)
            return (ids, true, message, [])
        }
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
            // Preserve stored insertion order before appending markers and in-memory completions.
            var merged = stored
            for id in ids where !stored.contains(id) { merged.append(id) }
            return (merged, false, messages.isEmpty ? nil : messages.joined(separator: " "), Set(markers))
        } catch {
            nativeLog("[MacSyncEngine] processed_ids.json UNREADABLE (%@) — keeping %d in-memory id(s); not trusting the empty read",
                  error.localizedDescription, ids.count)
            // Preserve damaged bytes before saving so recovery evidence and Doctor's durable signal survive.
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

    /// A completion marker prevents replay when bookkeeping fails; marker failure must surface the remaining replay risk.
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

    struct CompletionCommit: Sendable, Equatable {
        /// Both the processed-id save and pending-file archive must land before completion is clean.
        var clean: Bool
        /// A durable marker also forbids redispatch after incomplete bookkeeping.
        var markerWritten: Bool
        var syncError: String?
        /// Clean completion needs no ledger update because the caller already recorded the terminal state.
        var transactionState: String?
    }

    /// After a response lands, bookkeeping or its durable marker must forbid redispatch; failure of both exposes replay risk.
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
            : """
                Command \(msgId) finished but NEITHER its completion record NOR the fallback marker could be written (\(reason)). It could run again on \
                restart — free disk space and check iCloud permissions.
                """
        nativeLog("MacSyncEngine.commitCompletionBookkeeping: %@", message)
        return CompletionCommit(
            clean: false,
            markerWritten: marked,
            syncError: message,
            transactionState: "completed_unarchived"
        )
    }

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

    func readTransaction(id: String) async -> InboxTransactionLookup {
        guard let transactionDir,
              let url = InboxActionFileBoundary.jsonURL(
                in: transactionDir,
                validatedID: id
              ) else {
            // No ledger directory proves no outcome; admission must remain unknown rather than fresh.
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
                ), Self.hasCurrentInboxBinding(record, transactionID: id) else { return .unreadable }
                return .present(record)
            }
        }.value
    }

    /// Bind reservations to the envelope with SHA-256 over sorted-key JSON excluding signature, as the inner HMAC does.
    nonisolated static func inboxActionDigest(envelope: Data) -> String? {
        guard let canonical = try? BridgeMessage.innerActionCanonicalBody(envelope) else { return nil }
        return MacSyncSnapshotIntegrity.digest(canonical)
    }

    /// Exact envelope identity and digest bind the ledger; unbound rows authorize neither replay nor dispatch.
    nonisolated static func hasCurrentInboxBinding(_ record: ICloudTransactionRecord, transactionID: String) -> Bool {
        guard InboxActionFileBoundary.isCanonicalUUID(transactionID),
              record.id == transactionID, record.direction == "ios_to_mac",
              let msgId = record.msgId, InboxActionFileBoundary.isCanonicalUUID(msgId),
              let digest = record.actionDigest, digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        return true
    }

    /// Match both current bindings and the action to reject transaction-id collisions.
    static func inboxLedgerRow(
        _ record: ICloudTransactionRecord,
        matchesMsgId msgId: String,
        digest: String?,
        action: String
    ) -> Bool {
        guard let digest, !digest.isEmpty else { return false }
        return record.msgId == msgId && record.actionDigest == digest && record.action == action
    }

    /// Dispatched ledger states forbid rerunning a redelivered action.
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
        // Await off-main transitions in order so slow iCloud writes cannot overwrite a later transaction state.
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
                ), Self.hasCurrentInboxBinding(decoded, transactionID: id) else {
                    nativeLog("[MacSyncEngine] Ledger row for %@ unreadable or unbound; left intact rather than overwritten", id)
                    return nil
                }
                existing = decoded
            }
            if let existing {
                guard existing.action == action,
                      msgId == nil || msgId == existing.msgId,
                      actionDigest == nil || actionDigest == existing.actionDigest else {
                    nativeLog("[MacSyncEngine] Ledger binding collision for %@; existing evidence left intact", id)
                    return nil
                }
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
            guard Self.hasCurrentInboxBinding(record, transactionID: id),
                  let data = try? encoder.encode(record),
                  Self.coordinatedWriteReturningError(data: data, to: url) == nil else { return nil }
            return data
        }.value
        guard let written else {
            nativeLog("[MacSyncEngine] Transaction ledger write failed for %@ (state %@)", id, state)
            return nil
        }
        return InboxTransactionWrite(url: url, contents: written)
    }

    /// Release only this pre-dispatch reservation; coordinated comparison protects advanced rows.
    func releaseUndispatchedInboxAction(_ reservation: InboxTransactionWrite) async {
        await sync.storage.perform {
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: reservation.url, options: .forReplacing, error: &coordinationError
            ) { url in
                do {
                    guard try Data(contentsOf: url) == reservation.contents else { return }
                    var record = try JSONDecoder().decode(ICloudTransactionRecord.self, from: reservation.contents)
                    guard Self.hasCurrentInboxBinding(record, transactionID: url.deletingPathExtension().lastPathComponent),
                          record.state == "running" else { return }
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

    /// Missing is normal absence; failed reads leave file existence and outcome unknown.
    enum CoordinatedReadOutcome: Sendable {
        case data(Data)
        case missing
        case failed
    }

    /// Nonisolated coordinated reads run off main and preserve the distinction between missing and unreadable.
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

    /// Only no-such-file errors prove absence; other failures leave the outcome unknown.
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

    /// Nonisolated for detached reads; nil conflates missing and unreadable, so callers cannot infer absence.
    nonisolated static func coordinatedRead(at url: URL) -> Data? {
        guard case .data(let data) = coordinatedReadOutcome(at: url) else { return nil }
        return data
    }

    /// Nonisolated for detached writes; nil proves success and a description retains failure.
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
        // iCloud file stats may block: collect metadata off main before MainActor applies KVS mutations.
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
            print(
                """
                    [MacSyncEngine] inbox_response_* KVS keys (\(sweepPlan.retainedCount)) exceed backstop cap \(inboxResponseKeyMaxCount); recent readable \
                    response keys were retained rather than dropped.
                    """)
        }
        if !sweepPlan.keysToRemove.isEmpty {
            // Capture an immutable snapshot because the Sendable closure cannot share the outer var.
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

    /// Serialize scan/delete on the storage executor; exact metadata crossings and file events own future wakes. Failed deletion keeps its retry floor.
    /// Archives retain seven days/50 MB; replay markers retain 30 days to outlive pending files.
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
            // Keep the directory watch armed while discovering exact files, then register them before reading metadata or contents.
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
                // Without expiry or failed deletion, only exact file events owe a wake; empty archives need no sampling.
                guard let next = self.archiveRetentionRetryAfter ?? deadline else { return }
                let delay = next.timeIntervalSince(Date())
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                prune = true
            }
        }
    }

    /// Read only metadata; a crossing already handled by pruning must not re-arm itself.
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
            guard !Task.isCancelled, let items = try? fm.contentsOfDirectory(
                at: transactionDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
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

    // Last write is the row's updatedAt, so it owns the retention clock.
    nonisolated static func transactionRetentionCrossing(at url: URL) -> Date? {
        guard url.pathExtension == "json",
              let written = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return nil }
        return written.addingTimeInterval(30 * 24 * 60 * 60)
    }

    /// Keep active, uncertain and unreadable actions; recovered chats are terminal and retain 30 days. Read only local/current iCloud contents to avoid
    /// blocking; request downloads otherwise and let exact-file events resume pruning.
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
        guard let record = try? JSONDecoder().decode(ICloudTransactionRecord.self, from: data),
              hasCurrentInboxBinding(record, transactionID: url.deletingPathExtension().lastPathComponent) else { return false }
        return record.state == "completed" || record.state == "failed"
            || (record.action == "chat" && record.state == "unknown")
    }

    /// Thirty-day completion markers outlive the seven-day pending files that could replay a command.
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

    /// Nonisolated so blocking scan/delete work stays off the main actor.
    @discardableResult
    nonisolated static func pruneArchiveDirs(_ dirs: [URL], transactionDirectories: [URL] = []) -> Bool {
        let fm = FileManager.default
        let now = Date()
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        let maxBytes: Int = 50 * 1024 * 1024
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
            guard let items = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isDirectoryKey],
                options: []) else { continue }
            // Prune files only; recursive directory deletion could erase younger rejected entries.
            func isDir(_ u: URL) -> Bool { ((try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
            for url in items where !isDir(url) {
                if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff {
                    _ = remove(url)
                }
            }
            let remaining = ((try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isDirectoryKey],
                options: [])) ?? [])
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
            guard let items = try? fm.contentsOfDirectory(
                at: transactionDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) else { continue }
            for item in items {
                if let due = transactionRetentionCrossing(at: item), due <= now, isTerminalTransaction(at: item) {
                    _ = remove(item)
                }
            }
        }
        return failed
    }
}
