#if canImport(CloudKit) && !os(Linux)
import Foundation
import CloudKit
import CryptoKit
import OSLog
// Blueprint: | `CloudKitDeviceTransport+Pull.swift` | Cursor-paginated record pulls and retained traversal checkpoints |

extension CloudKitDeviceTransport {
    // MARK: pull (cursor-paginated)

    /// The deployed container does not permit range predicates on either the
    /// private `___modTime` field or our ISO-string `createdAt` field. Filter by
    /// the indexed direction, sort newest-first by the server modificationDate
    /// (the same clock as the watermark — see `pullPages`), and page until a
    /// page crosses the durable server-date watermark. This keeps quiet polls
    /// to one bounded page while still draining bursts larger than one page.
    static func makePullPredicate(inboundDirection: String) -> NSPredicate {
        NSPredicate(format: "direction == %@", inboundDirection)
    }

    // Paging watermarks compare server modificationDate, including records whose client clocks precede the saved cursor.
    func serverModDateSortAvailable(recordType: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !serverModDateSortRejected.contains(recordType)
    }

    func markServerModDateSortRejected(recordType: String) {
        lock.lock(); serverModDateSortRejected.insert(recordType); lock.unlock()
    }

    func pull(
        recordType: String,
        since: Date?,
        inboundDirection: String
    ) async throws -> DeviceCKPullResult {
        do {
            return try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.pull", onFailure: accountFailureReporter) {
                if self.serverModDateSortAvailable(recordType: recordType) {
                    do {
                        return try await self.pullPages(
                            recordType: recordType,
                            since: since,
                            inboundDirection: inboundDirection,
                            orderByServerModDate: true
                        )
                    } catch is DeviceCKUnsortableField {
                        nativeLog("[ck-device] pull: %@ has no sortable ___modTime index; falling back to createdAt order", recordType)
                        self.markServerModDateSortRejected(recordType: recordType)
                    }
                }
                return try await self.pullPages(
                    recordType: recordType,
                    since: since,
                    inboundDirection: inboundDirection,
                    orderByServerModDate: false
                )
            }
        } catch is DeviceCKLandmineTimeout {
            throw DeviceSyncError.transient(message: "CloudKit pull timed out")
        }
    }

    private func pullPages(
        recordType: String,
        since: Date?,
        inboundDirection: String,
        orderByServerModDate: Bool
    ) async throws -> DeviceCKPullResult {
        let query = CKQuery(
            recordType: recordType,
            predicate: Self.makePullPredicate(inboundDirection: inboundDirection)
        )
        query.sortDescriptors = [
            NSSortDescriptor(key: orderByServerModDate ? "modificationDate" : "createdAt", ascending: false)
        ]
        let assetSecret = await loadAssetSecretProvider()?()

        let checkpointKey = recordType + ":" + inboundDirection
        let owner = UUID()
        let checkpoint = orderByServerModDate ? nil : beginFallbackPull(checkpointKey, owner: owner)
        var combined = checkpoint?.result ?? DeviceCKPullResult()
        var nextCursor = checkpoint?.cursor
        var firstPage = checkpoint == nil

        repeat {
            guard NADeviceSyncRecoveryBudget.hasTime else { throw CancellationError() }
            let op: CKQueryOperation
            // Only the first query operation sets its sort; cursors carry subsequent ordering.
            let carriesSortDescriptor = firstPage
            if firstPage {
                op = CKQueryOperation(query: query); firstPage = false
            } else if let c = nextCursor {
                op = CKQueryOperation(cursor: c)
            } else {
                break
            }
            op.qualityOfService = .userInitiated
            // The container cannot filter by the watermark, so every poll's
            // first page is fetched whole; a quiet poll's first page almost
            // always reaches it. Keep that page small; a burst pages on at 200.
            op.resultsLimit = carriesSortDescriptor && orderByServerModDate ? 25 : 200

            let holder = DeviceCKPullPageHolder()
            op.recordMatchedBlock = { _, result in
                switch result {
                case .failure(let error):
                    holder.fail(error)
                case .success(let ck):
                    holder.noteModificationDate(ck.recordID.recordName, ck.modificationDate)
                    // Old records are paging evidence, not delivery candidates.
                    // A previous pairing key must not be needed to pass them.
                    if let since, let date = ck.modificationDate, date <= since { return }
                    do {
                        let fields = NAChatMessageFields(
                            recordName: ck.recordID.recordName,
                            direction: (ck["direction"] as? String) ?? "",
                            sessionId: ck["sessionId"] as? String,
                            text: (ck["text"] as? String) ?? "",
                            payloadJSON: try Self.payload(in: ck, secret: assetSecret),
                            createdAt: (ck["createdAt"] as? String) ?? "",
                            senderDevice: (ck["senderDevice"] as? String) ?? "",
                            kind: ck["kind"] as? String,
                            notificationTitle: ck["notificationTitle"] as? String,
                            notificationScreen: ck["notificationScreen"] as? String,
                            notificationEventID: ck["notificationEventId"] as? String
                        )
                        holder.add(fields)
                    } catch {
                        nativeLog("[ck-device] chat payload unavailable for %@: %@", ck.recordID.recordName, error.localizedDescription)
                        holder.failPayload(Self.mapError(error))
                    }
                }
            }

            // Return the page and cursor together without mutating captured traversal state.
            let page = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(records: [(fields: NAChatMessageFields, modDate: Date?)], payloadError: DeviceSyncError?, modificationDates: [Date?], cursor: CKQueryOperation.Cursor?), Error>) in
                op.queryResultBlock = { result in
                    switch result {
                    case .success(let cursor):
                        do {
                            let snapshot = try holder.snapshot()
                            cont.resume(returning: (snapshot.records, snapshot.payloadError, snapshot.modificationDates, cursor))
                        } catch {
                            cont.resume(throwing: Self.mapError(error))
                        }
                    case .failure(let err):
                        if !orderByServerModDate,
                           (err as? CKError)?.code == .invalidArguments {
                            self.saveFallbackPull(nil, key: checkpointKey, owner: owner)
                        }
                        // A cursor rejection does not prove that the initial server-date sort was unsupported.
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
            guard NADeviceSyncRecoveryBudget.hasTime else { throw CancellationError() }
            combined.records.append(contentsOf: page.records)
            combined.payloadError = combined.payloadError ?? page.payloadError
            let crossedWatermark = Self.pullPageCrossesWatermark(
                orderByServerModDate: orderByServerModDate,
                since: since,
                modificationDates: page.modificationDates
            )
            nextCursor = crossedWatermark ? nil : page.cursor
            if !orderByServerModDate {
                saveFallbackPull(nextCursor.map {
                    DeviceCKPullCheckpoint(result: combined, cursor: $0)
                }, key: checkpointKey, owner: owner)
            }
        } while nextCursor != nil

        return combined
    }

    static func pullPageCrossesWatermark(
        orderByServerModDate: Bool, since: Date?, modificationDates: [Date?]
    ) -> Bool {
        guard orderByServerModDate, let since else { return false }
        return modificationDates.contains { $0.map { $0 <= since } ?? false }
    }

    private func beginFallbackPull(_ key: String, owner: UUID) -> DeviceCKPullCheckpoint? {
        lock.lock(); defer { lock.unlock() }
        fallbackPullOwners[key] = owner
        return fallbackPullCheckpoints[key]
    }

    private func saveFallbackPull(_ checkpoint: DeviceCKPullCheckpoint?, key: String, owner: UUID) {
        lock.lock(); defer { lock.unlock() }
        // A timed-out or concurrent cancellation read cannot overwrite a newer pull.
        guard fallbackPullOwners[key] == owner else { return }
        fallbackPullCheckpoints[key] = checkpoint
    }
}
#endif
