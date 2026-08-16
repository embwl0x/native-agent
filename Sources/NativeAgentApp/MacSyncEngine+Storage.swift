// PATCH-2026-05-07: ios-sync MacSyncEngine — SnapshotWriter + InboxWatcher (Mac side)
// SnapshotWriter: source mutations write app-owned Swift runtime state to iCloud Drive `snapshots/`.
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
        let dir = NativeAgentPaths.dataRoot.appendingPathComponent("icloud", isDirectory: true)
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

    func writeTransaction(
        id: String,
        action: String,
        state: String,
        attempts: Int = 0,
        error: String? = nil,
        response: [String: String]? = nil
    ) async {
        guard let transactionDir,
              let url = InboxActionFileBoundary.jsonURL(
                in: transactionDir,
                validatedID: id
              ) else {
            NSLog("[MacSyncEngine] Refused transaction write for invalid remote id")
            return
        }
        let now = ISO8601DateFormatter().string(from: Date())
        // Off-main read-modify-write, AWAITED so sequential state transitions for
        // the same transaction id (received -> running -> done) complete in order
        // and can't clobber each other under iCloud slowness.
        await Task.detached(priority: .utility) { [id, action, state, attempts, error, response, url, now] in
            let existing = Self.coordinatedRead(at: url).flatMap { try? JSONDecoder().decode(ICloudTransactionRecord.self, from: $0) }
            let record = ICloudTransactionRecord(
                id: id,
                direction: "ios_to_mac",
                action: action,
                state: state,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                attempts: max(attempts, existing?.attempts ?? 0),
                lastError: error ?? existing?.lastError,
                response: response ?? existing?.response
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            if let data = try? encoder.encode(record) {
                Self.coordinatedWrite(data: data, to: url)
            }
        }.value
    }

    /// Coordinated read of an iCloud-resident file. Returns nil if missing or unreadable.
    /// nonisolated static — safe to call from detached tasks off the main actor.
    nonisolated static func coordinatedRead(at url: URL) -> Data? {
        var data: Data?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        return data
    }

    /// Coordinated write of `data` to an iCloud-resident `url` with `.forReplacing` intent.
    /// nonisolated static — safe to call from detached tasks off the main actor.
    nonisolated static func coordinatedWrite(data: Data, to url: URL) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { writeURL in
            try? data.write(to: writeURL, options: .atomic)
        }
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
    private struct InboxResponseSweepEntry { let key: String; let modified: Date?; let exists: Bool }
    func sweepInboxResponseKVSKeys() async {
        let keyPrefix = inboxResponseKeyPrefix
        let keys = await withCKTimeout("MacSyncEngine.sweepInboxResponseKVSKeys.readKeys") {
            Array(NSUbiquitousKeyValueStore.default.dictionaryRepresentation.keys.filter { $0.hasPrefix(keyPrefix) })
        } ?? []
        guard !keys.isEmpty else { return }
        let now = Date()
        // The per-key file stats below hit the iCloud-resident responses dir and
        // can block (fileExists / resourceValues / attributesOfItem) — with up to
        // inboxResponseKeyMaxCount keys this is run on every inbox pass, so it must
        // NOT run on the main actor. Build the (key → exists/modified) array off
        // main, then hop back to @MainActor for the KVS mutations below.
        let keyPrefixCount = inboxResponseKeyPrefix.count
        let entries: [InboxResponseSweepEntry] = await Task.detached(priority: .utility) { [responsesDir, keys] in
            let fm = FileManager.default
            var entries: [InboxResponseSweepEntry] = []
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
                entries.append(InboxResponseSweepEntry(key: key, modified: modified, exists: exists))
            }
            return entries
        }.value
        var keysToRemove: [String] = []
        var survivors: [InboxResponseSweepEntry] = []
        for entry in entries {
            // Response file gone → consumed; safe to remove the KVS key.
            if !entry.exists {
                keysToRemove.append(entry.key)
                continue
            }
            // File still present but older than TTL → iOS had a full day to read it.
            if let modified = entry.modified, now.timeIntervalSince(modified) > inboxResponseKeyTTL {
                keysToRemove.append(entry.key)
                continue
            }
            survivors.append(entry)
        }
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
        if survivors.count > inboxResponseKeyMaxCount {
            // Only keys with no readable response file mtime (orphaned/unreadable)
            // are eligible — never a clean under-TTL pending response.
            let evictable = survivors.filter { !$0.exists || $0.modified == nil }
            let overflow = survivors.count - inboxResponseKeyMaxCount
            var evictedHere = 0
            if !evictable.isEmpty {
                let sorted = evictable.sorted {
                    ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast)
                }
                for entry in sorted.prefix(overflow) {
                    keysToRemove.append(entry.key)
                    evictedHere += 1
                }
            }
            if evictedHere < overflow {
                print("[MacSyncEngine] inbox_response_* KVS keys (\(survivors.count)) exceed backstop cap \(inboxResponseKeyMaxCount); \(overflow - evictedHere) under-TTL key(s) with present response files retained rather than dropping pending responses.")
            }
        }
        if !keysToRemove.isEmpty {
            // Sendable-capture: snapshot to a let so the @Sendable closure
            // doesn't capture the outer `var`.
            let snapshot = keysToRemove
            _ = await withCKTimeout("MacSyncEngine.sweepInboxResponseKVSKeys.removeKeys") {
                let kvs = NSUbiquitousKeyValueStore.default
                for key in snapshot {
                    kvs.removeObject(forKey: key)
                }
                return kvs.synchronize()
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
