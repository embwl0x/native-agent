import Foundation
#if canImport(CloudKit) && !os(Linux)
import CloudKit
#endif

// MARK: - Phase D: CloudKit sync framework for memory records.
//
// CARVED OUT (still the APP's responsibility, NOT this framework):
//   * The real CloudKit container identifier (e.g. "iCloud.com.example.NativeAgent")
//     plus the iCloud entitlements and .cloudkit-config file that ship with
//     the .app bundle. The framework accepts a containerIdentifier as an init
//     param and trusts the caller; it does not validate or create entitlements.
//   * Schema deployment to the production CloudKit dashboard.
//   * Database subscription / silent-push wiring so other-device changes
//     trigger a pull. Phase D is one-shot push/pull only.
//   * Conflict resolution here is intentionally simple last-write-wins by
//     updatedAt. The daemon's memory consolidation may want richer semantics
//     (merge text overlap, preserve correctionHistory) — deferred until
//     callers ask.
//   * Linux / CI without CloudKit: SystemCloudKitSync is unavailable behind
//     `#if canImport(CloudKit) && !os(Linux)`. Tests run against MockCloudKitSync.

// MARK: - Wire shape

public struct CloudKitMemoryRecord: Sendable, Codable, Equatable {
    public let id: String           // CKRecord recordName
    public let text: String
    public let kind: String?
    public let createdAt: String    // ISO 8601
    public let updatedAt: String    // ISO 8601 — used for last-write-wins conflict resolution
    public let modificationDate: Date?  // server-stamped CKRecord modificationDate (read-only)

    public init(
        id: String,
        text: String,
        kind: String? = nil,
        createdAt: String,
        updatedAt: String,
        modificationDate: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modificationDate = modificationDate
    }
}

public enum CloudKitSyncError: Error, LocalizedError {
    case notConfigured
    case unauthorized
    case quotaExceeded
    case conflict(serverRecord: CloudKitMemoryRecord)
    case transient(message: String)
    case underlying(message: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "CloudKit not configured (missing container or entitlements)"
        case .unauthorized: return "iCloud account unavailable"
        case .quotaExceeded: return "iCloud quota exceeded"
        case .conflict: return "CloudKit record conflict"
        case .transient(let m): return "transient CloudKit error: \(m)"
        case .underlying(let m): return "CloudKit error: \(m)"
        }
    }
}

// MARK: - Protocol

public protocol CloudKitMemorySync: Sendable {
    func push(_ records: [CloudKitMemoryRecord]) async throws -> [CloudKitMemoryRecord]
    func pullSince(_ timestamp: Date?) async throws -> [CloudKitMemoryRecord]
    func delete(ids: [String]) async throws
    func accountStatus() async -> String  // "available" | "noAccount" | "restricted" | "unknown"
    /// Register a query subscription on the private database so other-device
    /// changes notify back. Idempotent — duplicate-subscription errors are
    /// swallowed. Default-impl is a noop for backends without subscription
    /// support (MockCloudKitSync).
    func subscribeToChanges() async throws
}

extension CloudKitMemorySync {
    public func subscribeToChanges() async throws { /* default noop */ }
}

// MARK: - System backend (CKContainer / CKDatabase)
//
// One-shot push/pull only. Production use should layer database subscriptions
// on top so other-device changes notify back — out of Phase D scope.

#if canImport(CloudKit) && !os(Linux)
private enum MemoryCKTimeoutRace<T: Sendable>: Sendable {
    case success(T)
    case failure(String)
    // gpt-5.5 review fix: carry the original Error so the throwing variant
    // can re-throw it intact (push/pull/delete/subscribe need to distinguish
    // CK conflict / quota / unauthorized from a generic timeout). The
    // non-throwing variant still ignores this and just returns nil on
    // failure.
    case failureError(Error)
    case timedOut
    case cancelled
}

private actor MemoryCKTimeoutState<T: Sendable> {
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<Result<T, Error>?, Never>?

    func wait() async -> Result<T, Error>? {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(_ result: Result<T, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func cancelWaiter() {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}

private func withCKTimeout<T: Sendable>(
    _ label: String,
    seconds: TimeInterval = 5,
    _ work: @Sendable @escaping () async throws -> T
) async -> T? {
    let state = MemoryCKTimeoutState<T>()
    let timeoutNanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
    let workTask = Task.detached(priority: .utility) {
        do {
            await state.finish(.success(try await work()))
        } catch {
            await state.finish(.failure(error))
        }
    }

    return await withTaskGroup(of: MemoryCKTimeoutRace<T>.self, returning: T?.self) { group in
        group.addTask {
            guard let result = await state.wait() else {
                return .cancelled
            }
            switch result {
            case .success(let value): return .success(value)
            case .failure(let error): return .failure(String(describing: error))
            }
        }
        group.addTask {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timedOut
            } catch {
                return .cancelled
            }
        }

        guard let first = await group.next() else {
            group.cancelAll()
            workTask.cancel()
            await state.cancelWaiter()
            return nil
        }

        switch first {
        case .success(let value):
            group.cancelAll()
            workTask.cancel()
            await state.cancelWaiter()
            return value
        case .failure(let error):
            group.cancelAll()
            workTask.cancel()
            await state.cancelWaiter()
            NSLog("[ck-landmine] \(label) failed: \(error)")
            return nil
        case .failureError(let error):
            group.cancelAll()
            workTask.cancel()
            await state.cancelWaiter()
            NSLog("[ck-landmine] \(label) failed: \(error)")
            return nil
        case .timedOut:
            group.cancelAll()
            workTask.cancel()
            await state.cancelWaiter()
            NSLog("[ck-landmine] \(label) timed out after \(formatMemoryCKTimeoutSeconds(seconds)); cloudd unhealthy?")
            return nil
        case .cancelled:
            group.cancelAll()
            workTask.cancel()
            await state.cancelWaiter()
            return nil
        }
    }
}

private func formatMemoryCKTimeoutSeconds(_ seconds: TimeInterval) -> String {
    if seconds.rounded() == seconds {
        return "\(Int(seconds))s"
    }
    return String(format: "%.1fs", seconds)
}

/// gpt-5.5 review fix: throwing variant of withCKTimeout that propagates the
/// work's thrown error instead of masking it to nil. Use this when the caller
/// needs to distinguish a real CloudKit error (conflict / quota / unauthorized)
/// from a "cloudd unhealthy" timeout so the existing conflict / retry paths
/// still run. On timeout, throws CKLandmineTimeout. On work failure, rethrows.
struct CKLandmineTimeout: LocalizedError, Sendable {
    let label: String
    let seconds: TimeInterval
    var errorDescription: String? {
        "CK call \(label) timed out after \(seconds)s; cloudd unhealthy?"
    }
}

private func withCKTimeoutThrowing<T: Sendable>(
    _ label: String,
    seconds: TimeInterval = 5,
    _ work: @Sendable @escaping () async throws -> T
) async throws -> T {
    let state = MemoryCKTimeoutState<T>()
    let timeoutNanoseconds = UInt64(max(0, seconds) * 1_000_000_000)

    let workTask = Task.detached(priority: .utility) {
        do {
            await state.finish(.success(try await work()))
        } catch {
            await state.finish(.failure(error))
        }
    }

    // Use MemoryCKTimeoutRace.cancelled to mean "timed out" in the throwing
    // variant — the enum is module-private so reusing avoids a nested-generic-
    // type declaration that Swift forbids inside generic functions.
    return try await withThrowingTaskGroup(of: MemoryCKTimeoutRace<T>.self, returning: T.self) { group in
        group.addTask {
            guard let r = await state.wait() else {
                return .cancelled
            }
            switch r {
            case .success(let v): return .success(v)
            // Use the typed-Error variant so the original CK error survives
            // the race and re-throws intact (conflict / quota / unauthorized
            // must reach the existing handlers, not collapse into .transient).
            case .failure(let e): return .failureError(e)
            }
        }
        group.addTask {
            _ = try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            return .timedOut
        }
        guard let first = try await group.next() else {
            group.cancelAll()
            workTask.cancel()
            await state.cancelWaiter()
            throw CKLandmineTimeout(label: label, seconds: seconds)
        }
        group.cancelAll()
        workTask.cancel()
        await state.cancelWaiter()
        switch first {
        case .success(let v):
            return v
        case .failureError(let e):
            throw e
        case .failure(let msg):
            // String-only fallback (the non-throwing variant uses this path).
            throw CloudKitSyncError.transient(message: msg)
        case .timedOut:
            NSLog("[ck-landmine] \(label) timed out after \(formatMemoryCKTimeoutSeconds(seconds)); cloudd unhealthy?")
            throw CKLandmineTimeout(label: label, seconds: seconds)
        case .cancelled:
            throw CancellationError()
        }
    }
}

/// Thread-safe per-page accumulator for pullSince's recordMatchedBlock. The
/// CK callback runs on CloudKit's own dispatch queue, not the actor's executor,
/// so the holder locks its own appends. Drained when the page's queryResult-
/// Block resolves — no cross-page sharing.
final class CKPullPageHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CloudKitMemoryRecord] = []
    func add(_ r: CloudKitMemoryRecord) {
        lock.lock(); items.append(r); lock.unlock()
    }
    func snapshot() -> [CloudKitMemoryRecord] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

public final class SystemCloudKitSync: CloudKitMemorySync, @unchecked Sendable {
    public let containerIdentifier: String
    private let recordType: String

    public init(containerIdentifier: String, recordType: String = "NAMemoryRecord") {
        self.containerIdentifier = containerIdentifier
        self.recordType = recordType
    }

    public func push(_ records: [CloudKitMemoryRecord]) async throws -> [CloudKitMemoryRecord] {
        guard !records.isEmpty else { return [] }
        // gpt-5.5 review fix: was using withCKTimeout (T?-return) which masked
        // real CK errors (conflict / quota / unauthorized) into nil and then
        // unconditionally re-threw .transient — the existing conflict-handling
        // path got bypassed. withCKTimeoutThrowing propagates the original
        // error; only an actual timeout maps to .transient.
        do {
            return try await withCKTimeoutThrowing("SystemCloudKitSync.push") {
                let database = CKContainer(identifier: self.containerIdentifier).privateCloudDatabase
                let ckRecords: [CKRecord] = records.map { rec in
                    let id = CKRecord.ID(recordName: rec.id)
                    let ck = CKRecord(recordType: self.recordType, recordID: id)
                    ck["text"] = rec.text as CKRecordValue
                    if let k = rec.kind { ck["kind"] = k as CKRecordValue }
                    ck["createdAt"] = rec.createdAt as CKRecordValue
                    ck["updatedAt"] = rec.updatedAt as CKRecordValue
                    return ck
                }
                let op = CKModifyRecordsOperation(recordsToSave: ckRecords, recordIDsToDelete: nil)
                op.savePolicy = .ifServerRecordUnchanged
                op.qualityOfService = .userInitiated

                return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[CloudKitMemoryRecord], Error>) in
                    op.modifyRecordsResultBlock = { result in
                        switch result {
                        case .success:
                            let stamped = ckRecords.map { ck in
                                CloudKitMemoryRecord(
                                    id: ck.recordID.recordName,
                                    text: (ck["text"] as? String) ?? "",
                                    kind: ck["kind"] as? String,
                                    createdAt: (ck["createdAt"] as? String) ?? "",
                                    updatedAt: (ck["updatedAt"] as? String) ?? "",
                                    modificationDate: ck.modificationDate
                                )
                            }
                            cont.resume(returning: stamped)
                        case .failure(let err):
                            cont.resume(throwing: Self.mapError(err))
                        }
                    }
                    database.add(op)
                }
            }
        } catch is CKLandmineTimeout {
            throw CloudKitSyncError.transient(message: "CloudKit push timed out")
        }
    }

    public func pullSince(_ timestamp: Date?) async throws -> [CloudKitMemoryRecord] {
        // gpt-5.5 review fix: previous version mutated a captured `var
        // collected: [CloudKitMemoryRecord]` from CKQueryOperation.recordMatched-
        // Block inside a @Sendable closure — Swift 6 strict-concurrency bug AND
        // a real callback data race (the op can keep firing after timeout).
        // Per-page lock'd holder + per-page continuation-collect now: each page
        // gets its own NSLock'd holder, drained synchronously when queryResult-
        // Block resolves the continuation. No shared mutable state crosses the
        // closure boundary. Also switched to withCKTimeoutThrowing so real CK
        // errors propagate instead of being masked into a generic timeout.
        do {
            return try await withCKTimeoutThrowing("SystemCloudKitSync.pullSince") {
                let database = CKContainer(identifier: self.containerIdentifier).privateCloudDatabase
                let predicate: NSPredicate
                if let ts = timestamp {
                    predicate = NSPredicate(format: "modificationDate > %@", ts as NSDate)
                } else {
                    predicate = NSPredicate(value: true)
                }
                let query = CKQuery(recordType: self.recordType, predicate: predicate)

                var combined: [CloudKitMemoryRecord] = []
                var nextCursor: CKQueryOperation.Cursor? = nil
                var firstPage = true

                repeat {
                    let op: CKQueryOperation
                    if firstPage {
                        op = CKQueryOperation(query: query)
                        firstPage = false
                    } else if let c = nextCursor {
                        op = CKQueryOperation(cursor: c)
                    } else {
                        break
                    }
                    op.qualityOfService = .userInitiated

                    let holder = CKPullPageHolder()
                    op.recordMatchedBlock = { _, result in
                        if case .success(let ck) = result {
                            holder.add(CloudKitMemoryRecord(
                                id: ck.recordID.recordName,
                                text: (ck["text"] as? String) ?? "",
                                kind: ck["kind"] as? String,
                                createdAt: (ck["createdAt"] as? String) ?? "",
                                updatedAt: (ck["updatedAt"] as? String) ?? "",
                                modificationDate: ck.modificationDate
                            ))
                        }
                    }

                    let pageResult: (records: [CloudKitMemoryRecord], cursor: CKQueryOperation.Cursor?) =
                        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(records: [CloudKitMemoryRecord], cursor: CKQueryOperation.Cursor?), Error>) in
                            op.queryResultBlock = { result in
                                switch result {
                                case .success(let cursor):
                                    cont.resume(returning: (holder.snapshot(), cursor))
                                case .failure(let err):
                                    cont.resume(throwing: Self.mapError(err))
                                }
                            }
                            database.add(op)
                        }
                    combined.append(contentsOf: pageResult.records)
                    nextCursor = pageResult.cursor
                } while nextCursor != nil

                return combined
            }
        } catch is CKLandmineTimeout {
            throw CloudKitSyncError.transient(message: "CloudKit pull timed out")
        }
    }

    public func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        // gpt-5.5 review fix: propagate real CK errors instead of masking via
        // T?-return + .transient catch-all.
        do {
            try await withCKTimeoutThrowing("SystemCloudKitSync.delete") {
                let database = CKContainer(identifier: self.containerIdentifier).privateCloudDatabase
                let recordIDs = ids.map { CKRecord.ID(recordName: $0) }
                let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: recordIDs)
                op.qualityOfService = .userInitiated
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    op.modifyRecordsResultBlock = { result in
                        switch result {
                        case .success: cont.resume()
                        case .failure(let err): cont.resume(throwing: Self.mapError(err))
                        }
                    }
                    database.add(op)
                }
            }
        } catch is CKLandmineTimeout {
            throw CloudKitSyncError.transient(message: "CloudKit delete timed out")
        }
    }

    public func subscribeToChanges() async throws {
        do {
            try await withCKTimeoutThrowing("SystemCloudKitSync.subscribeToChanges") {
                let database = CKContainer(identifier: self.containerIdentifier).privateCloudDatabase
                let subID = "NAMemoryRecord.changes"
                let predicate = NSPredicate(value: true)
                let sub = CKQuerySubscription(
                    recordType: self.recordType,
                    predicate: predicate,
                    subscriptionID: subID,
                    options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
                )
                let info = CKSubscription.NotificationInfo()
                info.shouldSendContentAvailable = true
                sub.notificationInfo = info
                do {
                    _ = try await database.save(sub)
                } catch let ck as CKError {
                    // Already-exists / duplicate-subscription errors are fine —
                    // the subscription is durable across launches.
                    switch ck.code {
                    case .serverRejectedRequest, .unknownItem:
                        return
                    default:
                        throw Self.mapError(ck)
                    }
                }
            }
        } catch is CKLandmineTimeout {
            throw CloudKitSyncError.transient(message: "CloudKit subscribe timed out")
        }
    }

    public func accountStatus() async -> String {
        await withCKTimeout("SystemCloudKitSync.accountStatus") {
            let s = try await CKContainer(identifier: self.containerIdentifier).accountStatus()
            switch s {
            case .available: return "available"
            case .noAccount: return "noAccount"
            case .restricted: return "restricted"
            case .temporarilyUnavailable: return "temporarilyUnavailable"
            case .couldNotDetermine: return "unknown"
            @unknown default: return "unknown"
            }
        } ?? "unknown"
    }

    private static func mapError(_ err: Error) -> CloudKitSyncError {
        if let ck = err as? CKError {
            switch ck.code {
            case .quotaExceeded: return .quotaExceeded
            case .notAuthenticated: return .unauthorized
            case .serverRecordChanged:
                if let server = ck.serverRecord {
                    let mapped = CloudKitMemoryRecord(
                        id: server.recordID.recordName,
                        text: (server["text"] as? String) ?? "",
                        kind: server["kind"] as? String,
                        createdAt: (server["createdAt"] as? String) ?? "",
                        updatedAt: (server["updatedAt"] as? String) ?? "",
                        modificationDate: server.modificationDate
                    )
                    return .conflict(serverRecord: mapped)
                }
                return .underlying(message: ck.localizedDescription)
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return .transient(message: ck.localizedDescription)
            default:
                return .underlying(message: ck.localizedDescription)
            }
        }
        return .underlying(message: err.localizedDescription)
    }
}
#endif

// MARK: - In-memory mock for tests

public actor MockCloudKitSync: CloudKitMemorySync {
    public private(set) var stored: [String: CloudKitMemoryRecord] = [:]
    public var simulateAccountStatus: String = "available"
    public var simulateConflictOnPush: Bool = false
    // Monotonic stamp source. We don't use Date.now (workflow scripts ban it
    // in tests indirectly via determinism preference) — but in production
    // Swift code Date() is fine; the mock only needs strictly-increasing
    // modificationDate values across successive push calls so pullSince
    // filtering is testable.
    private var clockTick: Int = 0

    public init() {}

    public func setSimulateAccountStatus(_ s: String) { simulateAccountStatus = s }
    public func setSimulateConflictOnPush(_ b: Bool) { simulateConflictOnPush = b }

    public func push(_ records: [CloudKitMemoryRecord]) async throws -> [CloudKitMemoryRecord] {
        if simulateConflictOnPush, let first = records.first {
            // Surface the existing stored variant if any; else echo back with
            // a bumped updatedAt to represent "server has a newer copy."
            let server = stored[first.id] ?? CloudKitMemoryRecord(
                id: first.id,
                text: first.text + " [server-variant]",
                kind: first.kind,
                createdAt: first.createdAt,
                updatedAt: first.updatedAt,
                modificationDate: stampNext()
            )
            throw CloudKitSyncError.conflict(serverRecord: server)
        }
        var stamped: [CloudKitMemoryRecord] = []
        stamped.reserveCapacity(records.count)
        for rec in records {
            let modDate = stampNext()
            let s = CloudKitMemoryRecord(
                id: rec.id,
                text: rec.text,
                kind: rec.kind,
                createdAt: rec.createdAt,
                updatedAt: rec.updatedAt,
                modificationDate: modDate
            )
            stored[rec.id] = s
            stamped.append(s)
        }
        return stamped
    }

    public func pullSince(_ timestamp: Date?) async throws -> [CloudKitMemoryRecord] {
        let all = Array(stored.values)
        guard let ts = timestamp else { return all }
        return all.filter { rec in
            guard let m = rec.modificationDate else { return false }
            return m > ts
        }
    }

    public func delete(ids: [String]) async throws {
        for id in ids { stored.removeValue(forKey: id) }
    }

    public func accountStatus() async -> String { simulateAccountStatus }

    public func snapshot() async -> [String: CloudKitMemoryRecord] { stored }

    private func stampNext() -> Date {
        clockTick += 1
        // Anchor to a fixed epoch so values are deterministic per-actor instance.
        return Date(timeIntervalSinceReferenceDate: TimeInterval(clockTick))
    }
}

// MARK: - SwiftNativeMemoryCloudSync
//
// Composes a CloudKitMemorySync with a local sync-state file living next to
// the JSONL embedding store. State is just {lastPushAt, lastPullAt}; the
// caller is responsible for knowing what local records to push (this actor
// is a transport coordinator, not a record store).

public actor SwiftNativeMemoryCloudSync {
    private let sync: any CloudKitMemorySync
    private let storePath: URL  // directory housing .cloud_sync_state.json

    public init(sync: any CloudKitMemorySync, storePath: URL) {
        self.sync = sync
        self.storePath = storePath
    }

    private var statePath: URL {
        storePath.appendingPathComponent(".cloud_sync_state.json")
    }

    private struct State: Codable, Equatable {
        var lastPushAt: String?
        var lastPullAt: String?
    }

    public func loadSyncState() async throws -> (lastPushAt: Date?, lastPullAt: Date?) {
        let p = statePath
        guard FileManager.default.fileExists(atPath: p.path) else {
            return (nil, nil)
        }
        let data = try Data(contentsOf: p)
        let s = try JSONDecoder().decode(State.self, from: data)
        return (Self.parseISO8601(s.lastPushAt), Self.parseISO8601(s.lastPullAt))
    }

    public func recordSyncState(lastPushAt: Date?, lastPullAt: Date?) async throws {
        try FileManager.default.createDirectory(at: storePath, withIntermediateDirectories: true)
        let s = State(
            lastPushAt: lastPushAt.map { Self.formatISO8601($0) },
            lastPullAt: lastPullAt.map { Self.formatISO8601($0) }
        )
        let data = try JSONEncoder().encode(s)
        try data.write(to: statePath, options: .atomic)
    }

    public func syncPush(records: [CloudKitMemoryRecord]) async throws -> [CloudKitMemoryRecord] {
        let stamped = try await sync.push(records)
        let now = Date()
        let existing = try await loadSyncState()
        try await recordSyncState(lastPushAt: now, lastPullAt: existing.lastPullAt)
        return stamped
    }

    public func syncPull() async throws -> [CloudKitMemoryRecord] {
        let (lastPush, lastPull) = try await loadSyncState()
        let results = try await sync.pullSince(lastPull)
        // Empty results → do NOT advance lastPullAt; otherwise records modified
        // between the previous cursor and now would be silently skipped.
        if results.isEmpty {
            return results
        }
        let maxMod = results.compactMap { $0.modificationDate }.max()
        // 30-second overlap window mirrors the daemon's clock-skew tolerance:
        // safer to re-pull a record than to miss one written by another device
        // whose clock drifted slightly behind ours.
        let advance = maxMod.map { $0.addingTimeInterval(-30) }
        try await recordSyncState(lastPushAt: lastPush, lastPullAt: advance)
        return results
    }

    /// Phase D conflict policy: last-write-wins by updatedAt. If updatedAt
    /// strings parse unequally, the newer one wins; if equal/unparseable,
    /// server wins (safer default for a sync framework).
    public nonisolated func resolveConflict(
        local: CloudKitMemoryRecord,
        server: CloudKitMemoryRecord
    ) -> CloudKitMemoryRecord {
        let lD = Self.parseISO8601(local.updatedAt)
        let sD = Self.parseISO8601(server.updatedAt)
        switch (lD, sD) {
        case let (l?, s?):
            return l > s ? local : server
        case (.some, .none):
            return local
        case (.none, .some), (.none, .none):
            return server
        }
    }

    // MARK: ISO 8601 helpers (lock-free; the formatter is created per-call to
    // keep the actor isolation simple — these are not on a hot path).

    private static func parseISO8601(_ s: String?) -> Date? {
        guard let s = s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func formatISO8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}
