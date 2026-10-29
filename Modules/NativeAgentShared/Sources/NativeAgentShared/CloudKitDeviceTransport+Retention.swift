#if canImport(CloudKit) && !os(Linux)
import Foundation
import CloudKit
import CryptoKit
import OSLog
// Blueprint: | `CloudKitDeviceTransport+Retention.swift` | Bounded record retention and per-record-family sweep cursors |

extension CloudKitDeviceTransport {
    // MARK: retention sweep

    // The Mac alone sweeps expired chat/notification records by server modificationDate; pairing/status singletons are retained. Offline phones recover from transcript snapshots.
    public static let retentionWindow: TimeInterval = 14 * 24 * 60 * 60

    /// Deletions per sweep, per record type. Bounded so a first sweep over a
    /// large backlog cannot turn one drain into a long CloudKit transaction;
    /// the backlog clears over successive sweeps.
    public static let retentionSweepBatch = 100

    /// Minimum spacing between sweeps in the steady state. Drains run as often
    /// as every eight seconds; retention is housekeeping, not a per-drain cost.
    static let retentionSweepInterval: TimeInterval = 60 * 60

    /// Spacing while a sweep's page still comes back full. The first sweep on a
    /// container that has been accumulating since the cutover has a large
    /// backlog, and at one bounded batch an hour it would take weeks to clear.
    static let retentionBacklogSweepInterval: TimeInterval = 60

    static func shouldSweepRetention(
        role: NADeviceRole,
        lastSweepAt: Date?,
        backlog: Bool,
        now: Date
    ) -> Bool {
        guard role == .mac else { return false }   // the phone never deletes
        guard let lastSweepAt else { return true }
        let interval = backlog ? retentionBacklogSweepInterval : retentionSweepInterval
        return now.timeIntervalSince(lastSweepAt) >= interval
    }

    /// Delete chat + notification records past the retention window. Mac-only,
    /// rate-limited, and bounded per record type. Returns the number deleted.
    /// Safe to call on every drain — it self-throttles and no-ops on iOS.
    @discardableResult
    public func sweepExpiredRecords() async -> Int {
        guard !pairingHeldElsewhere else { return 0 }
        let now = Date()
        guard claimRetentionSweep(now: now) else { return 0 }
        let cutoff = now.addingTimeInterval(-Self.retentionWindow)
        var deleted = 0
        var backlog = false
        var timedOut = false
        for recordType in [
            NADeviceSyncRecordType.chatMessage,
            NADeviceSyncRecordType.notification,
        ] {
            let outcome = await sweepExpiredRecords(recordType: recordType, cutoff: cutoff)
            deleted += outcome.deleted
            // A full fetched page signals backlog regardless of its deletion count.
            if outcome.backlog { backlog = true }
            if outcome.deleteTimedOut { timedOut = true }
        }
        setRetentionBacklog(backlog)
        // Cancellation cannot prove the server rejected a timed-out batch.
        if timedOut {
            nativeLog(
                "[ck-device] retention sweep: %d confirmed deletion(s) before %@, plus a batch whose delete timed out — that batch's count is unknown",
                deleted,
                "\(cutoff)"
            )
        } else {
            nativeLog(
                "[ck-device] retention sweep deleted %d record(s) modified before %@",
                deleted,
                "\(cutoff)"
            )
        }
        return deleted
    }

    /// Claim the sweep slot under the lock. Doubles as the rate limiter and as
    /// the mutual exclusion between two concurrent drains.
    private func claimRetentionSweep(now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard Self.shouldSweepRetention(
            role: role,
            lastSweepAt: lastRetentionSweepAt,
            backlog: retentionBacklog,
            now: now
        ) else { return false }
        lastRetentionSweepAt = now
        return true
    }

    private func setRetentionBacklog(_ backlog: Bool) {
        lock.lock(); retentionBacklog = backlog; lock.unlock()
    }

    private func sweepExpiredRecords(recordType: String, cutoff: Date) async -> DeviceCKSweepOutcome {
        var outcome = DeviceCKSweepOutcome()
        let orderedByServerModDate = serverModDateSortAvailable(recordType: recordType)
        let page: DeviceCKSweepPage
        do {
            page = try await withDeviceCKTimeoutThrowing(
                "CloudKitDeviceTransport.sweep",
                seconds: 10,
                onFailure: accountFailureReporter
            ) {
                if orderedByServerModDate {
                    do {
                        return try await self.expiredRecordPage(
                            recordType: recordType,
                            cutoff: cutoff,
                            orderByServerModDate: true,
                            resumeCursor: nil
                        )
                    } catch is DeviceCKUnsortableField {
                        // Same missing `___modTime` index the pull depends on;
                        // latch it once so neither lane pays for a rejected
                        // query again.
                        self.markServerModDateSortRejected(recordType: recordType)
                    }
                }
                return try await self.expiredRecordPage(
                    recordType: recordType,
                    cutoff: cutoff,
                    orderByServerModDate: false,
                    resumeCursor: self.retentionFallbackCursor(recordType: recordType)
                )
            }
        } catch {
            nativeLog("[ck-device] retention sweep query failed for %@: %@", recordType, String(describing: error))
            // A stored cursor can go stale on the server; keeping it would make
            // every later sweep fail the same way. Drop it and walk again from
            // the oldest record next time.
            if !serverModDateSortAvailable(recordType: recordType) {
                setRetentionFallbackCursor(nil, recordType: recordType)
            }
            return outcome
        }
        // The order actually used: a first query rejected for its sort
        // descriptor latched the fallback above.
        let usedServerModDateOrder = orderedByServerModDate
            && serverModDateSortAvailable(recordType: recordType)
        if !usedServerModDateOrder {
            // Advance (or, on nil, reset) the walk before deleting: a delete
            // that fails leaves those records for the next full walk rather
            // than pinning the sweep on a page it cannot clear.
            setRetentionFallbackCursor(page.fetched == 0 ? nil : page.cursor, recordType: recordType)
        }
        // Continue a full fetched page even when no records in it expired.
        outcome.backlog = page.fetched >= Self.retentionSweepBatch
            && (!usedServerModDateOrder || page.names.count == page.fetched)
        let names = page.names
        guard !names.isEmpty else { return outcome }
        do {
            try await withDeviceCKTimeoutThrowing(
                "CloudKitDeviceTransport.sweepDelete",
                seconds: 15,
                onFailure: accountFailureReporter
            ) {
                let op = CKModifyRecordsOperation(
                    recordsToSave: nil,
                    recordIDsToDelete: names.map { CKRecord.ID(recordName: $0) }
                )
                op.qualityOfService = .utility
                try await self.performModifyRecords(op)
            }
        } catch is DeviceCKLandmineTimeout {
            // Keep the batch count unknown until server acceptance is proven.
            nativeLog(
                "[ck-device] retention sweep delete batch of %d timed out for %@; the server may still have applied it — count unknown",
                names.count,
                recordType
            )
            outcome.deleteTimedOut = true
            return outcome
        } catch {
            nativeLog("[ck-device] retention sweep delete failed for %@: %@", recordType, String(describing: error))
            return outcome
        }
        outcome.deleted = names.count
        return outcome
    }

    private func retentionFallbackCursor(recordType: String) -> CKQueryOperation.Cursor? {
        lock.lock(); defer { lock.unlock() }
        return retentionFallbackCursors[recordType]
    }

    private func setRetentionFallbackCursor(_ cursor: CKQueryOperation.Cursor?, recordType: String) {
        lock.lock()
        retentionFallbackCursors[recordType] = cursor
        lock.unlock()
    }

    /// One bounded page of the OLDEST records of `recordType`, filtered to those
    /// the cutoff has passed. In modificationDate order, ascending is what makes
    /// a single page enough: the page is either wholly eligible or contains the
    /// cutoff boundary, and deleting it moves the next sweep's page forward.
    /// Eligibility is ALWAYS the server modificationDate — the client
    /// `createdAt` is only a fallback sort key for a container whose
    /// `___modTime` index is not sortable. In THAT order the page is not sorted
    /// by the eligibility clock and nothing on it need be deletable, so the
    /// caller passes `resumeCursor` to continue past the records this page
    /// already examined instead of re-reading them forever. `desiredKeys = []`
    /// keeps the page to system fields, so a sweep never downloads payloads it
    /// is about to delete.
    private func expiredRecordPage(
        recordType: String,
        cutoff: Date,
        orderByServerModDate: Bool,
        resumeCursor: CKQueryOperation.Cursor?
    ) async throws -> DeviceCKSweepPage {
        let op: CKQueryOperation
        // Only a FRESH query carries the sort descriptor, so only a fresh query
        // can be rejected for it; an `.invalidArguments` on a cursor
        // continuation is a stale cursor and must not latch the fallback order.
        let carriesSortDescriptor = resumeCursor == nil
        if let resumeCursor {
            op = CKQueryOperation(cursor: resumeCursor)
        } else {
            // Use the queryable createdAt field to enumerate records when recordName is not queryable.
            let query = CKQuery(recordType: recordType, predicate: NSPredicate(
                format: "direction IN %@",
                [NAChatDirection.mac2ios.rawValue, NAChatDirection.ios2mac.rawValue]
            ))
            query.sortDescriptors = [
                NSSortDescriptor(key: orderByServerModDate ? "modificationDate" : "createdAt", ascending: true)
            ]
            op = CKQueryOperation(query: query)
        }
        op.qualityOfService = .utility
        op.resultsLimit = Self.retentionSweepBatch
        op.desiredKeys = []

        let holder = DeviceCKRecordNameHolder()
        op.recordMatchedBlock = { id, result in
            guard case .success(let ck) = result else { return }
            holder.noteFetched()
            guard let modDate = ck.modificationDate, modDate < cutoff else { return }
            holder.add(id.recordName)
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DeviceCKSweepPage, Error>) in
            op.queryResultBlock = { result in
                let page = holder.snapshot()
                switch result {
                case .success(let cursor):
                    cont.resume(returning: DeviceCKSweepPage(
                        names: page.names,
                        fetched: page.fetched,
                        cursor: cursor
                    ))
                case .failure(let err):
                    if carriesSortDescriptor,
                       orderByServerModDate,
                       Self.rejectsServerModDateSort(err) {
                        cont.resume(throwing: DeviceCKUnsortableField())
                    } else {
                        cont.resume(throwing: Self.mapError(err))
                    }
                }
            }
            self.database.add(op)
        }
    }

    // Only rejection naming the server-date field proves its sort is unsupported.
    static func rejectsServerModDateSort(_ error: Error) -> Bool {
        guard (error as? CKError)?.code == .invalidArguments else { return false }
        let text = String(describing: error)
        return text.contains("modTime") || text.contains("modificationDate")
    }
}
#endif
