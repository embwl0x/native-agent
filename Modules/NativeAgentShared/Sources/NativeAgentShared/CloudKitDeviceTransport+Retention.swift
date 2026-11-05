#if canImport(CloudKit) && !os(Linux)
import Foundation
import CloudKit
import CryptoKit
import OSLog
// Blueprint: | `CloudKitDeviceTransport+Retention.swift` | Bounded oldest-page record retention; subsequent sweeps advance through confirmed deletions |

extension CloudKitDeviceTransport {
    // MARK: retention sweep

    // The Mac alone sweeps expired chat/notification records by server modificationDate; pairing/status singletons are retained. Offline phones
    // recover from transcript snapshots.
    public static let retentionWindow: TimeInterval = 14 * 24 * 60 * 60

    /// Deletions per sweep, per record type. Bounded so a first sweep over a large backlog cannot turn one drain into a long CloudKit transaction;
    /// the backlog clears over successive sweeps.
    public static let retentionSweepBatch = 100

    /// Minimum spacing between sweeps in the steady state. Drains run as often at subsecond cadence during phone contact; retention is housekeeping,
    /// not a per-drain cost.
    static let retentionSweepInterval: TimeInterval = 60 * 60

    /// Full pages need a shorter cadence so a large backlog clears without increasing each sweep's bounded work.
    static let retentionBacklogSweepInterval: TimeInterval = 60

    static func shouldSweepRetention(
        role: NADeviceRole,
        lastSweepAt: Date?,
        backlog: Bool,
        now: Date
    ) -> Bool {
        guard role == .mac else { return false }
        guard let lastSweepAt else { return true }
        let interval = backlog ? retentionBacklogSweepInterval : retentionSweepInterval
        return now.timeIntervalSince(lastSweepAt) >= interval
    }

    /// Mac-only and self-throttled so every drain may request bounded retention work.
    @discardableResult
    public func sweepExpiredRecords() async -> Int {
        guard holdsPairing else { return 0 }
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

    /// Claim the sweep slot under the lock. Doubles as the rate limiter and as the mutual exclusion between two concurrent drains.
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
        let page: DeviceCKSweepPage
        do {
            page = try await withDeviceCKTimeoutThrowing(
                "CloudKitDeviceTransport.sweep",
                seconds: 10,
                onFailure: accountFailureReporter
            ) {
                return try await self.expiredRecordPage(
                    recordType: recordType,
                    cutoff: cutoff
                )
            }
        } catch {
            nativeLog("[ck-device] retention sweep query failed for %@: %@", recordType, String(describing: error))
            return outcome
        }
        // The oldest page advances only by confirmed deletion.
        outcome.backlog = page.fetched >= Self.retentionSweepBatch
            && page.names.count == page.fetched
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

    /// One bounded page of the OLDEST records of `recordType`, filtered to those the cutoff has passed. In modificationDate order, ascending is what
    /// makes a single page enough: the page is either wholly eligible or contains the cutoff boundary, and deleting it moves the next sweep's page
    /// forward. Eligibility and ordering use server modificationDate. `desiredKeys = []` keeps the page to system fields, so a sweep never downloads
    /// payloads it is about to delete.
    private func expiredRecordPage(
        recordType: String,
        cutoff: Date
    ) async throws -> DeviceCKSweepPage {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(
            format: "direction IN %@",
            [NAChatDirection.mac2ios.rawValue, NAChatDirection.ios2mac.rawValue]
        ))
        query.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: true)]
        let op = CKQueryOperation(query: query)
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
                case .success:
                    cont.resume(returning: DeviceCKSweepPage(
                        names: page.names,
                        fetched: page.fetched
                    ))
                case .failure(let err):
                    cont.resume(throwing: Self.mapError(err))
                }
            }
            self.database.add(op)
        }
    }

}
#endif
