import Foundation
import CloudKit
import CryptoKit
import OSLog
// Blueprint: | `CloudKitDeviceTransport+Pull.swift` | Paginated record pulls with call-local traversal cursors up to the durable server-date watermark |

extension CloudKitDeviceTransport {
    // MARK: pull (cursor-paginated)

    /// The deployed container does not permit range predicates on either the private `___modTime` field or our ISO-string `createdAt` field. Filter
    /// by the indexed direction, sort newest-first by the server modificationDate (the same clock as the watermark — see `pullPages`), and page until
    /// a page crosses the durable server-date watermark. This keeps quiet polls to one bounded page while still draining bursts larger than one page.
    static func makePullPredicate(inboundDirection: String) -> NSPredicate {
        NSPredicate(format: "direction == %@", inboundDirection)
    }

    func pull(
        recordType: String,
        since: Date?,
        inboundDirection: String,
        assetSecret: Data?,
        recovery: DeviceSyncRecovery
    ) async throws -> DeviceCKPullResult {
        return try await withDeviceCKOperation("CloudKitDeviceTransport.pull", onFailure: accountFailureReporter) {
            return try await self.pullPages(
                recordType: recordType,
                since: since,
                inboundDirection: inboundDirection,
                assetSecret: assetSecret,
                recovery: recovery
            )
        }
    }

    private func pullPages(
        recordType: String,
        since: Date?,
        inboundDirection: String,
        assetSecret: Data?,
        recovery: DeviceSyncRecovery
    ) async throws -> DeviceCKPullResult {
        let query = CKQuery(
            recordType: recordType,
            predicate: Self.makePullPredicate(inboundDirection: inboundDirection)
        )
        query.sortDescriptors = [
            NSSortDescriptor(key: "modificationDate", ascending: false)
        ]

        // The Mac holds the pairing key: a payload that does not open under it was sealed under another pairing and can never be read here.
        let keyHolder = role == .mac
        var combined = DeviceCKPullResult()
        var nextCursor: CKQueryOperation.Cursor?
        var firstPage = true

        let pageSizes = [1, 4, 16, 64, 200]
        var pageIndex = 0
        repeat {
            guard recovery.isActive else { throw CancellationError() }
            let op: CKQueryOperation
            // Only the first query operation sets its sort; cursors carry subsequent ordering.
            if firstPage {
                op = CKQueryOperation(query: query); firstPage = false
            } else if let c = nextCursor {
                op = CKQueryOperation(cursor: c)
            } else {
                break
            }
            op.qualityOfService = .userInitiated
            // Page growth reaches the server-date watermark without reading more than 200 records at once.
            op.resultsLimit = pageSizes[min(pageIndex, pageSizes.count - 1)]
            pageIndex += 1

            let holder = DeviceCKPullPageHolder()
            op.recordMatchedBlock = { _, result in
                switch result {
                case .failure(let error):
                    holder.fail(error)
                case .success(let ck):
                    holder.noteModificationDate(ck.recordID.recordName, ck.modificationDate)
                    // Old records are paging evidence, not delivery candidates. A previous pairing key must not be needed to pass them.
                    if let since, let date = ck.modificationDate, date <= since { return }
                    do {
                        holder.add(try Self.chatFields(in: ck, assetSecret: assetSecret))
                    } catch CryptoKitError.authenticationFailure where keyHolder {
                        // Passed like an old record, so it never holds newer messages behind it until retention deletes it.
                        nativeLog("[ck-device] %@ was sealed under another pairing; passed", ck.recordID.recordName)
                    } catch {
                        nativeLog("[ck-device] chat payload unavailable for %@: %@", ck.recordID.recordName, error.localizedDescription)
                        holder.failPayload(Self.mapError(error))
                    }
                }
            }

            // Return traversal state rather than mutating captured state across the continuation.
            let page = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(records: [(fields: NAChatMessageFields, modDate: Date?)],
                    payloadError: DeviceSyncError?,
                    modificationDates: [Date?],
                    cursor: CKQueryOperation.Cursor?), Error>) in
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
                            cont.resume(throwing: Self.mapError(err))
                        }
                    }
                    self.database.add(op)
                    if Task.isCancelled { op.cancel() }
                }
            } onCancel: { op.cancel() }
            guard recovery.isActive else { throw CancellationError() }
            combined.records.append(contentsOf: page.records)
            combined.payloadError = combined.payloadError ?? page.payloadError
            let crossedWatermark = Self.pullPageCrossesWatermark(
                since: since,
                modificationDates: page.modificationDates
            )
            nextCursor = crossedWatermark ? nil : page.cursor
        } while nextCursor != nil

        return combined
    }

    /// The one decoding of a chat or notification record, whether the query or the bell found it.
    static func chatFields(in ck: CKRecord, assetSecret: Data?) throws -> NAChatMessageFields {
        guard let direction = ck["direction"] as? String,
              let text = ck["text"] as? String,
              let createdAt = ck["createdAt"] as? String,
              let sender = ck["senderDevice"] as? String else {
            throw DeviceSyncError.underlying(message:
                "CloudKit record \(ck.recordID.recordName) has unreadable message fields.")
        }
        return NAChatMessageFields(
            recordName: ck.recordID.recordName,
            direction: direction,
            sessionId: ck["sessionId"] as? String,
            text: text,
            payloadJSON: try payload(in: ck, secret: assetSecret),
            createdAt: createdAt,
            senderDevice: sender,
            kind: ck["kind"] as? String,
            notificationTitle: ck["notificationTitle"] as? String,
            notificationScreen: ck["notificationScreen"] as? String,
            notificationEventID: ck["notificationEventId"] as? String
        )
    }

    static func pullPageCrossesWatermark(
        since: Date?, modificationDates: [Date?]
    ) -> Bool {
        guard let since else { return false }
        return modificationDates.contains { $0.map { $0 <= since } ?? false }
    }

}
