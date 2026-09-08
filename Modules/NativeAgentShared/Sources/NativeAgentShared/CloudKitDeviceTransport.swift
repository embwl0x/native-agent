// CloudKitDeviceTransport.swift — CloudKit implementation of DeviceSyncTransport.
//
// The live Mac/iPhone transport owns private-database writes, cursor-paginated
// reads, subscriptions, error mapping, and bounded CloudKit operations here.
// It remains independent of NativeAgentCore so both apps share the same
// device-sync contract. The retired MemoryV2 sync prototype is not a dependency.

import Foundation
import CryptoKit

#if canImport(CloudKit) && !os(Linux)
import CloudKit

enum DeviceCloudKitSubscriptionID {
    static let chat = "NAChatMessage.incoming"
    static let visibleNotifications = "NANotification.visible"
    static let pairing = "NAPairingDevice.changes"
    static let status = "NAStatus.changes"

    static let current = [chat, visibleNotifications, pairing, status]
    static let legacy = [
        "NAChatMessage.notifications.visible",
        "NAChatMessage.incoming.mac",
        "NAChatMessage.incoming.ios",
        "NAPairingDevice.mac",
        "NAPairingDevice.ios",
        "NAStatus.mac",
        "NAStatus.ios",
    ]

    static func recognizes(_ id: String) -> Bool {
        current.contains(id) || legacy.contains(id)
    }
}

// MARK: - Device timeout policies

private enum DeviceCKTimeoutRace<T: Sendable>: Sendable {
    case success(T)
    case failure(String)
    case failureError(Error)
    case timedOut
    case cancelled
}

private func formatDeviceCKTimeoutSeconds(_ seconds: TimeInterval) -> String {
    if seconds.rounded() == seconds { return "\(Int(seconds))s" }
    return String(format: "%.1fs", seconds)
}

struct DeviceCKLandmineTimeout: LocalizedError, Sendable {
    let label: String
    let seconds: TimeInterval
    var errorDescription: String? {
        "CK call \(label) timed out after \(seconds)s; cloudd unhealthy?"
    }
}

/// 2026-09-06: the container rejected a sort on the server modificationDate
/// (no sortable `___modTime` index). Signals the pull to retry once in the
/// legacy client-`createdAt` order rather than surfacing a sync failure.
struct DeviceCKUnsortableField: LocalizedError, Sendable {
    var errorDescription: String? {
        "CloudKit rejected the modificationDate sort for this record type."
    }
}

private func withDeviceCKTimeout<T: Sendable>(
    _ label: String,
    seconds: TimeInterval = 5,
    _ work: @Sendable @escaping () async throws -> T
) async -> T? {
    guard NADeviceSyncRecoveryBudget.hasTime else { return nil }
    let seconds = NADeviceSyncRecoveryBudget.seconds(upTo: seconds)
    let state = CloudKitTimeoutResultLatch<T>()
    let timeoutNanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
    let workTask = Task(priority: .utility) {
        do {
            guard NADeviceSyncRecoveryBudget.hasTime else { throw CancellationError() }
            await state.finish(.success(try await work()))
        }
        catch { await state.finish(.failure(error)) }
    }

    return await withTaskGroup(of: DeviceCKTimeoutRace<T>.self, returning: T?.self) { group in
        group.addTask {
            guard let result = await state.wait() else { return .cancelled }
            switch result {
            case .success(let value): return .success(value)
            case .failure(let error): return .failure(String(describing: error))
            }
        }
        group.addTask {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timedOut
            } catch { return .cancelled }
        }

        guard let first = await group.next() else {
            group.cancelAll(); workTask.cancel(); await state.cancelWaiter()
            return nil
        }
        group.cancelAll(); workTask.cancel(); await state.cancelWaiter()
        switch first {
        case .success(let value): return value
        case .failure(let error):
            NSLog("[ck-device] \(label) failed: \(error)"); return nil
        case .failureError(let error):
            NSLog("[ck-device] \(label) failed: \(error)"); return nil
        case .timedOut:
            NSLog("[ck-device] \(label) timed out after \(formatDeviceCKTimeoutSeconds(seconds)); cloudd unhealthy?")
            return nil
        case .cancelled:
            return nil
        }
    }
}

private func withDeviceCKTimeoutThrowing<T: Sendable>(
    _ label: String,
    seconds: TimeInterval = 5,
    _ work: @Sendable @escaping () async throws -> T
) async throws -> T {
    guard NADeviceSyncRecoveryBudget.hasTime else { throw CancellationError() }
    let seconds = NADeviceSyncRecoveryBudget.seconds(upTo: seconds)
    let state = CloudKitTimeoutResultLatch<T>()
    let timeoutNanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
    let workTask = Task(priority: .utility) {
        do {
            guard NADeviceSyncRecoveryBudget.hasTime else { throw CancellationError() }
            await state.finish(.success(try await work()))
        }
        catch { await state.finish(.failure(error)) }
    }

    return try await withThrowingTaskGroup(of: DeviceCKTimeoutRace<T>.self, returning: T.self) { group in
        group.addTask {
            guard let r = await state.wait() else { return .cancelled }
            switch r {
            case .success(let v): return .success(v)
            case .failure(let e): return .failureError(e)
            }
        }
        group.addTask {
            _ = try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            return .timedOut
        }
        guard let first = try await group.next() else {
            group.cancelAll(); workTask.cancel(); await state.cancelWaiter()
            throw DeviceCKLandmineTimeout(label: label, seconds: seconds)
        }
        group.cancelAll(); workTask.cancel(); await state.cancelWaiter()
        switch first {
        case .success(let v): return v
        case .failureError(let e): throw e
        case .failure(let msg): throw DeviceSyncError.transient(message: msg)
        case .timedOut:
            NSLog("[ck-device] \(label) timed out after \(formatDeviceCKTimeoutSeconds(seconds)); cloudd unhealthy?")
            throw DeviceCKLandmineTimeout(label: label, seconds: seconds)
        case .cancelled:
            throw CancellationError()
        }
    }
}

/// Thread-safe accumulator for the retention sweep's recordMatchedBlock. Holds
/// record NAMES (not `CKRecord.ID`s) so the page crosses the continuation as a
/// plain Sendable value; the delete op rebuilds the ids in the default zone,
/// which is the zone every send writes into.
private final class DeviceCKRecordNameHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    // 2026-09-06: every record the page returned, eligible or not. The backlog
    // signal is "the page came back full", which the deleted count cannot tell
    // us — in the createdAt fallback order most of a full page is often still
    // inside the retention window.
    private var fetched = 0
    func noteFetched() { lock.lock(); fetched += 1; lock.unlock() }
    func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    func snapshot() -> (names: [String], fetched: Int) {
        lock.lock(); defer { lock.unlock() }; return (names, fetched)
    }
}

/// One page of the retention sweep's query: the eligible record names, how many
/// records the page actually returned, and the server-side resume position.
/// `@unchecked Sendable` because a `CKQueryOperation.Cursor` is an opaque
/// position we only ever hand back to CloudKit — never read, never mutated.
private final class DeviceCKSweepPage: @unchecked Sendable {
    let names: [String]
    let fetched: Int
    let cursor: CKQueryOperation.Cursor?
    init(names: [String], fetched: Int, cursor: CKQueryOperation.Cursor?) {
        self.names = names
        self.fetched = fetched
        self.cursor = cursor
    }
}

/// What one record type's sweep achieved. `deleted` counts CONFIRMED deletions
/// only: a delete batch that timed out may or may not have been applied by the
/// server, so it is reported as unknown rather than as zero.
private struct DeviceCKSweepOutcome {
    var deleted = 0
    var backlog = false
    var deleteTimedOut = false
}

/// Thread-safe per-page accumulator for pull's recordMatchedBlock. The CK
/// callback runs on CloudKit's own queue, so the holder locks its own appends.
final class DeviceCKPullPageHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [NAChatMessageFields] = []
    private var firstError: Error?
    func add(_ r: NAChatMessageFields) { lock.lock(); items.append(r); lock.unlock() }
    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if firstError == nil { firstError = error }
    }
    func snapshot() throws -> [NAChatMessageFields] {
        lock.lock(); defer { lock.unlock() }
        if let firstError { throw firstError }
        return items
    }
}

private struct DeviceCKPullCheckpoint {
    var records: [(fields: NAChatMessageFields, modDate: Date?)]
    var cursor: CKQueryOperation.Cursor
}

// MARK: - CloudKitDeviceTransport

/// CloudKit-backed device transport. `@unchecked Sendable` with an internal
/// NSLock for mutable state (handlers + last-pull cursor + seen ids).
public final class CloudKitDeviceTransport: DeviceSyncTransport, @unchecked Sendable {
    public let role: NADeviceRole
    public let containerIdentifier: String

    /// Whether this process may safely touch `CKContainer`. Computed ONCE at
    /// init from the entitlement preflight (entitlements are fixed for a
    /// process's lifetime). When false, EVERY method short-circuits to
    /// `.notConfigured` / a safe default and NEVER constructs a `CKContainer` —
    /// this is the 2026-06-03 `_os_crash` guard. `CKContainer.__allocating_init`
    /// traps synchronously when CloudKit isn't entitled, so no timeout race can
    /// catch it; the only safe defense is to not reach the constructor at all.
    /// Injectable so tests can exercise the guard without real entitlements.
    private let configured: Bool

    private let lock = NSLock()
    private var incomingHandler: (@Sendable (BridgeMessage) async -> Bool)?
    private var cancellationAdmission: (@Sendable (BridgeMessage) async -> Bool)?
    private var cancellationDrainInFlight = false
    private var pairingHandler: (@Sendable (Data) async -> Bool)?
    private var statusWrites: [String: Task<Void, Error>] = [:]
    private var statusHandlers: [String: @Sendable (String) async -> Bool] = [:]
    private var visibleNotificationSubscriptionReady = false
    private var lastPullDate: Date?
    private var lastPullCursorPersistenceAt: Date?
    // CK-3c: transport-level drain serialization (guarded by `lock`). Concurrent
    // drains must NOT overlap — one drain's releaseClaim racing another's
    // cursor-advance can drop a record (gpt-5.5 CK-3c review P0). While a drain
    // body runs, concurrent callers set drainAgain and return; the active loop
    // re-runs once to service them.
    private var drainInFlight = false
    private var drainAgain = false
    // 2026-09-06: the status lane needs the same slot, for the same reason.
    // Two overlapping status drains could each claim a DIFFERENT generation of
    // the same key and then run their handlers concurrently, so the older
    // delivery could finish last and overwrite the newer bytes it raced.
    private var statusDrainInFlight = false
    private var statusDrainAgain = false
    // 2026-09-06: record types whose container index rejected a
    // modificationDate sort, so we stop paying for a rejected query every drain
    // and use the legacy createdAt order instead. PER RECORD TYPE: the sortable
    // `___modTime` index is declared per record type, and iOS pulls two of them
    // (chatMessage and notification) — one type's missing index must not demote
    // the other's pull to the createdAt order that the paging stop cannot trust.
    // Accepted as is (2026-09-06): the set lives on the transport instance, so a
    // teardown/setup cycle in the same process re-probes the rejected sort once
    // per type. That costs one rejected query and immediately re-latches.
    private var serverModDateSortRejected: Set<String> = []
    // Completed fallback pages survive a bounded pull. No records are returned
    // or acknowledged until the traversal completes. A restart safely rescans.
    private var fallbackPullCheckpoints: [String: DeviceCKPullCheckpoint] = [:]
    private var fallbackPullOwners: [String: UUID] = [:]
    // LWW/dedup cursors for the pairing + status singletons. Pairing is one
    // mutable record per peer role; status is one record per (peer role, key).
    // We only re-dispatch when the server modificationDate advances, so a redraw
    // triggered by a redundant push does not re-fire the same value.
    private var lastPairingModDate: Date?
    private var lastStatusModDates: [String: Date] = [:]
    // 2026-09-06: when the last retention sweep ran, so a Mac that drains every
    // eight seconds does not pay for a housekeeping query on every drain. In
    // memory only — a relaunch simply sweeps once more, which is harmless.
    private var lastRetentionSweepAt: Date?
    // True while the last sweep's query page came back full, i.e. there is more
    // of the collection to walk; the next sweep then comes back in a minute
    // instead of an hour.
    private var retentionBacklog = false
    // 2026-09-06: the resume position of the createdAt-order sweep, per record
    // type. In that fallback order the page is NOT sorted by the eligibility
    // clock, so the hundred oldest by createdAt can contain nothing older than
    // the cutoff — and with no resume position that same hundred came back on
    // every sweep, forever, deleting nothing. The cursor advances past each page
    // that has been examined; storing nil (a page that returned nothing, or a
    // cursor CloudKit did not hand back because the walk reached the end)
    // restarts the walk from the oldest record on the next sweep.
    private var retentionFallbackCursors: [String: CKQueryOperation.Cursor] = [:]
    // Insertion-ordered seen-id dedup, capped, mirroring iCloudBridge.
    private var seenMessageIDs: Set<String> = []
    private var seenMessageIDsOrdered: [String] = []
    private let seenMessageIDsCap = 2000

    public init(
        role: NADeviceRole,
        containerIdentifier: String,
        configured: Bool? = nil
    ) {
        self.role = role
        self.containerIdentifier = containerIdentifier
        self.configured = configured ?? (
            DeviceCloudKitPreflight.hasCloudKitEntitlement()
                && DeviceCloudKitPreflight.entitlementGrantsContainer(containerIdentifier)
        )
        // CK-3c: restore the persisted pull cursor so a cold start resumes from
        // where it left off instead of re-pulling every record from zero (which
        // would re-deliver old messages past the bridge seen-set cap). Keyed by
        // (role, container) so distinct devices/containers never share a cursor.
        if let ts = UserDefaults.standard.object(forKey: Self.cursorKey(role: role, container: containerIdentifier)) as? Double {
            self.lastPullDate = Date(timeIntervalSince1970: ts)
            self.lastPullCursorPersistenceAt = Date()
        }
    }

    public var presentsVisualNotifications: Bool {
        lock.lock()
        defer { lock.unlock() }
        return visibleNotificationSubscriptionReady
    }

    private static func cursorKey(role: NADeviceRole, container: String) -> String {
        "NADeviceSync.cursor.\(role.rawValue).\(container)"
    }

    /// Quiet successful pulls advance the in-memory high watermark on every
    /// drain, but do not need to dirty preferences on every fallback tick.
    static let emptyCursorPersistenceInterval: TimeInterval = 5 * 60

    static func shouldPersistPullCursor(
        immediately: Bool,
        lastPersistenceAt: Date?,
        now: Date
    ) -> Bool {
        immediately || lastPersistenceAt.map {
            now.timeIntervalSince($0) >= emptyCursorPersistenceInterval
        } ?? true
    }

    /// CK-3c: true iff `userInfo` is a CloudKit silent push for one of the
    /// device-sync subscriptions (chat / pairing / status). The APNs push handler
    /// uses this to route ONLY our pushes to a drain — every other push passes
    /// through untouched. Pure parse of the push dictionary; constructs no
    /// `CKContainer`, so it's safe to call regardless of entitlement state.
    public static func isDeviceSyncNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo),
              let subID = note.subscriptionID else { return false }
        return DeviceCloudKitSubscriptionID.recognizes(subID)
    }

    /// The private CloudKit database. Constructing `CKContainer(identifier:)` is
    /// the 2026-06-03 `_os_crash` trap site — so this property MUST NOT be reached
    /// unless `configured` is true. Every PUBLIC entry point below opens with a
    /// `guard configured` that returns `.notConfigured` / a safe default, and the
    /// private helpers (`pull`, `registerBroadSubscription`) are only ever called
    /// from those guarded publics. That gate is what makes the cutover safe;
    /// completeness is pinned by the crash-guard tests, which exercise every
    /// method with `configured: false` and assert no `CKContainer` is touched.
    private var database: CKDatabase {
        CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    // MARK: send

    public func send(_ message: BridgeMessage) async throws {
        guard configured else { throw DeviceSyncError.notConfigured }  // crash-guard: no CKContainer
        let fields = try NAChatMessageCodec.encode(message)
        let recordType = Self.recordType(for: fields)
        do {
            try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.send") {
                let ck = CKRecord(
                    recordType: recordType,
                    recordID: CKRecord.ID(recordName: fields.recordName)
                )
                ck["direction"] = fields.direction as CKRecordValue
                if let s = fields.sessionId { ck["sessionId"] = s as CKRecordValue }
                ck["text"] = fields.text as CKRecordValue
                ck["payloadJSON"] = fields.payloadJSON as CKRecordValue
                ck["createdAt"] = fields.createdAt as CKRecordValue
                ck["senderDevice"] = fields.senderDevice as CKRecordValue
                if let k = fields.kind { ck["kind"] = k as CKRecordValue }
                if let title = fields.notificationTitle {
                    ck["notificationTitle"] = title as CKRecordValue
                }
                if let screen = fields.notificationScreen {
                    ck["notificationScreen"] = screen as CKRecordValue
                }
                if let eventID = fields.notificationEventID {
                    ck["notificationEventId"] = eventID as CKRecordValue
                }

                let op = CKModifyRecordsOperation(recordsToSave: [ck], recordIDsToDelete: nil)
                op.savePolicy = .ifServerRecordUnchanged
                op.qualityOfService = .userInitiated
                try await self.performModifyRecords(op)
            }
        } catch is DeviceCKLandmineTimeout {
            if await existingMessageRecordMatches(fields) {
                return
            }
            throw DeviceSyncSendOutcomeUnknown(message: "CloudKit send timed out; server acceptance is unknown")
        } catch let error as DeviceSyncError {
            if case .conflict = error, await existingMessageRecordMatches(fields) {
                // 2026-09-06: the caller is told this send succeeded, but the
                // server record still carries its ORIGINAL modificationDate —
                // the only clock the retention sweep judges eligibility by. A
                // replay of a record already past the window (stable ids come
                // from AgentBridgeCompletionRouter's idempotencyKey) was swept
                // away moments after the send reported success. Touch the
                // record so the replay is fresh for another full window.
                await touchExistingRecord(named: fields.recordName)
                return
            }
            switch error {
            case .transient, .underlying, .conflict:
                throw DeviceSyncSendOutcomeUnknown(message: error.localizedDescription)
            default:
                throw error
            }
        } catch {
            throw DeviceSyncSendOutcomeUnknown(message: error.localizedDescription)
        }
    }

    /// Re-save the server record unchanged so its `___modTime` advances. Only
    /// the retention clock moves — no field is written, and
    /// `.ifServerRecordUnchanged` means a record the peer changed underneath us
    /// is left alone. Best effort: a failed touch costs the record its
    /// refreshed clock, never the send's success.
    private func touchExistingRecord(named recordName: String) async {
        _ = await withDeviceCKTimeout("CloudKitDeviceTransport.sendReplayTouch") {
            let record = try await self.database.record(
                for: CKRecord.ID(recordName: recordName)
            )
            let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            op.savePolicy = .ifServerRecordUnchanged
            op.qualityOfService = .userInitiated
            try await self.performModifyRecords(op)
        }
    }

    /// Resolves timeout-after-commit and stable-id retries without weakening
    /// conflict handling. Only exact payloadJSON + direction equality converts
    /// the ambiguous write into success.
    static func recordType(for fields: NAChatMessageFields) -> String {
        fields.kind == "notification"
            ? NADeviceSyncRecordType.notification
            : NADeviceSyncRecordType.chatMessage
    }

    private func existingMessageRecordMatches(_ fields: NAChatMessageFields) async -> Bool {
        await withDeviceCKTimeout("CloudKitDeviceTransport.sendReplayProof") {
            let record = try await self.database.record(
                for: CKRecord.ID(recordName: fields.recordName)
            )
            return NAChatMessageCodec.isExactIdempotentReplay(
                existingPayloadJSON: record["payloadJSON"] as? String,
                existingDirection: record["direction"] as? String,
                intended: fields
            )
        } ?? false
    }

    // MARK: observeIncoming

    public func observeIncoming(_ onMessage: @escaping @Sendable (BridgeMessage) async -> Bool) async {
        guard configured else {
            NSLog("[ck-device] observeIncoming: CloudKit entitlement absent — not subscribing (notConfigured). Legacy transport should own delivery.")
            return
        }
        setIncomingHandler(onMessage)  // last registration wins (single forwarder)
        // Register the durable silent-push subscription so the peer's writes
        // notify this device, then do an initial drain to pick up anything
        // already waiting. Live push → drain wiring is CK-3; drainIncoming() is
        // the pull half and is exercisable now.
        _ = await ensurePushSubscriptions()
        await drainIncoming()
    }

    public func ensurePushSubscriptions() async -> Bool {
        guard configured else { return false }
        do {
            try await subscribeToChanges()
            return role != .ios || presentsVisualNotifications
        } catch {
            // Fail loud (no-silent-fallbacks): a failed subscription means no
            // live push wakeups — the drain still works when polled, but callers
            // must not describe the visual route as eligible.
            NSLog("[ck-device] subscription registration FAILED (no live push): \(error)")
            return false
        }
    }

    /// Pull incoming messages since the last cursor, decode, dispatch to the
    /// registered handler, and advance the cursor with a clock-skew overlap
    /// window. Idempotent per message id. Returns the count dispatched.
    @discardableResult
    public func drainIncoming() async -> Int {
        guard NADeviceSyncRecoveryBudget.hasTime else { return 0 }
        guard configured else { return 0 }  // crash-guard: pull() touches CKContainer
        // CK-3c: serialize via SYNC lock helpers (the codebase keeps every NSLock
        // use in a synchronous scope — never held across an await). The body's own
        // fine-grained locking still works since the slot flag isn't held here.
        guard beginDrainOrCoalesce() else { return await drainIncomingCancellations() }
        var total = 0
        while true {
            total += await drainIncomingBody()
            if endDrainOrContinue() { continue }  // a concurrent caller requested a re-run
            break
        }
        return total
    }

    /// Acquire the single drain slot. Returns true if acquired; false if a drain
    /// is already running (then flags a re-run so the active loop services us).
    private func beginDrainOrCoalesce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if drainInFlight { drainAgain = true; return false }
        drainInFlight = true
        return true
    }

    /// End a drain iteration. Returns true if a re-run is needed (clearing the
    /// request); false if the slot is now free.
    private func endDrainOrContinue() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if drainAgain && NADeviceSyncRecoveryBudget.hasTime { drainAgain = false; return true }
        drainAgain = false
        drainInFlight = false
        return false
    }

    /// The drain body — always run serialized by `drainIncoming`; never call it
    /// directly (concurrent bodies can drop records, the P0 the wrapper prevents).
    private func drainIncomingBody() async -> Int {
        let (handler, since) = loadHandlerAndCursor()
        guard handler != nil else { return 0 }
        let queryStartedAt = Date()

        let inbound = role.inboundDirection.rawValue
        let fetched: [(fields: NAChatMessageFields, modDate: Date?)]
        do {
            var records = try await pull(
                recordType: NADeviceSyncRecordType.chatMessage,
                since: since,
                inboundDirection: inbound
            )
            if role == .ios {
                records += try await pull(
                    recordType: NADeviceSyncRecordType.notification,
                    since: since,
                    inboundDirection: inbound
                )
            }
            fetched = records
        } catch {
            NSLog("[ck-device] drainIncoming pull failed: \(error)")
            return 0
        }

        return await deliverIncoming(fetched, since: since, queryStartedAt: queryStartedAt)
    }

    func deliverIncoming(_ fetched: [(fields: NAChatMessageFields, modDate: Date?)], since: Date?, queryStartedAt: Date) async -> Int {
        guard let handler = loadHandlerAndCursor().0 else { return 0 }
        let inbound = role.inboundDirection.rawValue
        // Deliver in chronological order — CloudKit query order is undefined.
        // Sort ascending by server modDate, then createdAt, then id.
        let sorted = fetched.sorted { a, b in
            let am = a.modDate ?? .distantPast, bm = b.modDate ?? .distantPast
            if am != bm { return am < bm }
            if a.fields.createdAt != b.fields.createdAt { return a.fields.createdAt < b.fields.createdAt }
            return a.fields.recordName < b.fields.recordName
        }

        // Stops in this very batch must reach the run registry before awaiting
        // a chat. The registry retains a scoped Stop during run acceptance.
        guard let cancellations = await deliverCancellations(fetched) else { return 0 }
        var dispatched = cancellations
        // The cursor may only advance to the last point BEFORE the first
        // UNDELIVERED inbound record — a rejected message must never be skipped.
        // Delivered / already-seen / not-for-us records advance it; the first
        // handler rejection halts advancement (that record is retried next drain).
        var cursorAdvance: Date? = nil
        var halted = false
        for item in sorted {
            // A concurrent cancellation has not yet earned acknowledgement.
            // Never advance the ordinary cursor past its temporary claim.
            if isCancellationDrainInFlight() { halted = true; break }
            if !NADeviceSyncRecoveryBudget.hasTime { halted = true; break }
            if halted && role != .ios { break }
            let m = item.modDate
            guard item.fields.direction == inbound else {
                if !halted, let m { cursorAdvance = m }   // our own outbound / other — safe to pass
                continue
            }
            let id = Self.deliveryClaimKey(item.fields)
            // Atomic check-and-claim under one lock so two concurrent drains
            // cannot both deliver the same id.
            guard let claimed = claimForSerialDrain(id) else { halted = true; break }
            guard claimed else {
                if !halted, let m { cursorAdvance = m }    // already delivered — safe to pass
                continue
            }
            guard let message = try? NAChatMessageCodec.decode(item.fields) else {
                NSLog("[ck-device] drainIncoming: undecodable payload for \(id)")
                if !halted, let m { cursorAdvance = m }    // poison — keep it claimed, pass
                continue
            }
            if await handler(message) {
                dispatched += 1
                NADeviceSyncRecoveryBudget.didApplyData?()
                if !halted, let m { cursorAdvance = m }
            } else {
                releaseClaim(id)                  // not delivered — retry next drain
                halted = true                     // do not advance past this record
                // iPhone replies are independent deliveries. Keep the failed
                // row unclaimed and the cursor pinned, but deliver later replies.
            }
        }
        if isCancellationDrainInFlight() { halted = true }
        // Keep a sliding 30s overlap (matches the memory framework). An idle
        // successful query must still move an established cursor forward;
        // otherwise a quiet bridge re-queries from the date of its last record
        // forever. A halted delivery never advances past the rejected row.
        if let nextCursor = Self.nextPullCursor(
            previousCursor: since,
            queryStartedAt: queryStartedAt,
            safeRecordDate: cursorAdvance,
            halted: halted
        ) {
            setLastPullDate(
                nextCursor,
                persistImmediately: cursorAdvance != nil || halted
            )
        }
        return dispatched
    }

    /// Mac-only admission; the bridge authenticates and requires an exact run.
    /// Ordinary chat delivery and its terminal receipt retain their original owner.
    public func setCancellationAdmission(_ admission: @escaping @Sendable (BridgeMessage) async -> Bool) {
        lock.lock(); defer { lock.unlock() }
        cancellationAdmission = admission
    }

    @discardableResult
    public func drainIncomingCancellations() async -> Int {
        guard configured, role == .mac, NADeviceSyncRecoveryBudget.hasTime,
              loadCancellationAdmission() != nil, beginCancellationDrain() else { return 0 }
        defer { endCancellationDrain() }
        let (_, since) = loadHandlerAndCursor()
        do {
            let records = try await pull(recordType: NADeviceSyncRecordType.chatMessage,
                                         since: since, inboundDirection: role.inboundDirection.rawValue)
            return await deliverAdmittedCancellations(records)
        } catch {
            NSLog("[ck-device] cancellation pull failed: \(error)")
            return 0
        }
    }

    private func isCancellationDrainInFlight() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancellationDrainInFlight
    }

    private func beginCancellationDrain() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancellationDrainInFlight else { return false }
        cancellationDrainInFlight = true
        return true
    }

    private func endCancellationDrain() {
        lock.lock(); defer { lock.unlock() }
        cancellationDrainInFlight = false
    }

    private func loadCancellationAdmission() -> (@Sendable (BridgeMessage) async -> Bool)? {
        lock.lock(); defer { lock.unlock() }
        return cancellationAdmission
    }

    func deliverCancellations(_ records: [(fields: NAChatMessageFields, modDate: Date?)]) async -> Int? {
        guard role == .mac, loadCancellationAdmission() != nil else { return 0 }
        guard beginCancellationDrain() else { return nil }
        defer { endCancellationDrain() }
        return await deliverAdmittedCancellations(records)
    }

    private func deliverAdmittedCancellations(_ records: [(fields: NAChatMessageFields, modDate: Date?)]) async -> Int {
        guard let admission = loadCancellationAdmission(),
              let handler = loadHandlerAndCursor().0 else { return 0 }
        var delivered = 0
        for record in records {
            guard NADeviceSyncRecoveryBudget.hasTime else { break }
            guard record.fields.direction == role.inboundDirection.rawValue,
                  let message = try? NAChatMessageCodec.decode(record.fields),
                  await admission(message), claimIfUnseen(Self.deliveryClaimKey(record.fields)) else { continue }
            if await handler(message) {
                delivered += 1
                NADeviceSyncRecoveryBudget.didApplyData?()
            } else {
                releaseClaim(Self.deliveryClaimKey(record.fields))
            }
        }
        // This path never writes the cursor. The serial drain accounts for
        // every intervening chat and any cancellation whose response failed.
        return delivered
    }

    static func nextPullCursor(
        previousCursor: Date?,
        queryStartedAt: Date,
        safeRecordDate: Date?,
        halted: Bool
    ) -> Date? {
        let overlap: TimeInterval = 30

        if halted {
            guard let safeRecordDate else { return previousCursor }
            let candidate = safeRecordDate.addingTimeInterval(-overlap)
            guard let previousCursor else { return candidate }
            return max(previousCursor, candidate)
        }

        // On a first-ever empty pull, retain nil so the next attempt still
        // performs a complete bootstrap read. Once a durable cursor exists (or
        // this pull saw a record), successful emptiness is an observed high
        // watermark and can slide the overlap window forward safely.
        guard previousCursor != nil || safeRecordDate != nil else { return nil }
        let highWatermark = max(queryStartedAt, safeRecordDate ?? queryStartedAt)
        let candidate = highWatermark.addingTimeInterval(-overlap)
        guard let previousCursor else { return candidate }
        return max(previousCursor, candidate)
    }

    // MARK: retention sweep

    /// 2026-09-06: every `send` wrote an `NAChatMessage`/`NANotification`
    /// record and nothing ever deleted one — draining advances a cursor and
    /// remembers seen ids, but acknowledged records stayed in the private
    /// database forever. The Mac is the deleting device (it is the always-on
    /// owner); the phone never sweeps.
    ///
    /// A record is eligible once its SERVER modificationDate is older than the
    /// window, whether or not the phone drained it. That is accepted: a phone
    /// offline for two weeks resyncs from the Mac's transcript snapshot, which
    /// is the source of truth. Pairing and status records are singletons that
    /// are overwritten in place, so they are never swept.
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
        guard configured else { return 0 }  // crash-guard: no CKContainer
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
            // 2026-09-06: the backlog signal is a FULL PAGE, not a full batch of
            // deletions — a page that fetched a hundred records and deleted two
            // still means there is more of the collection to walk.
            if outcome.backlog { backlog = true }
            if outcome.deleteTimedOut { timedOut = true }
        }
        setRetentionBacklog(backlog)
        // 2026-09-06: a delete batch that timed out may still have been applied
        // by the server — the timeout is on OUR wait, not on the operation. Say
        // the count is unknown rather than logging a confident zero.
        if timedOut {
            NSLog(
                "[ck-device] retention sweep: %d confirmed deletion(s) before %@, plus a batch whose delete timed out — that batch's count is unknown",
                deleted,
                "\(cutoff)"
            )
        } else {
            NSLog(
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
                seconds: 10
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
            NSLog("[ck-device] retention sweep query failed for %@: %@", recordType, String(describing: error))
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
        // 2026-09-06: a full page means there is more collection to walk. In
        // modificationDate order the page is sorted by the eligibility clock
        // itself, so a page that is only partly eligible IS the cutoff boundary
        // — nothing older remains, and claiming a backlog there would hold the
        // sweep at its one-minute cadence forever on any busy container.
        outcome.backlog = page.fetched >= Self.retentionSweepBatch
            && (!usedServerModDateOrder || page.names.count == page.fetched)
        let names = page.names
        guard !names.isEmpty else { return outcome }
        do {
            try await withDeviceCKTimeoutThrowing(
                "CloudKitDeviceTransport.sweepDelete",
                seconds: 15
            ) {
                let op = CKModifyRecordsOperation(
                    recordsToSave: nil,
                    recordIDsToDelete: names.map { CKRecord.ID(recordName: $0) }
                )
                op.qualityOfService = .utility
                try await self.performModifyRecords(op)
            }
        } catch is DeviceCKLandmineTimeout {
            // 2026-09-06: the timeout is on our WAIT, not on the operation —
            // cloudd may well apply the delete after we stop listening. Report
            // the batch as unknown; counting it as zero deletions understated
            // the sweep and, before the page-based backlog signal, also lied
            // about whether there was still a backlog.
            NSLog(
                "[ck-device] retention sweep delete batch of %d timed out for %@; the server may still have applied it — count unknown",
                names.count,
                recordType
            )
            outcome.deleteTimedOut = true
            return outcome
        } catch {
            NSLog("[ck-device] retention sweep delete failed for %@: %@", recordType, String(describing: error))
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
            let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
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
                       (err as? CKError)?.code == .invalidArguments {
                        cont.resume(throwing: DeviceCKUnsortableField())
                    } else {
                        cont.resume(throwing: Self.mapError(err))
                    }
                }
            }
            self.database.add(op)
        }
    }

    // MARK: pairing

    public func publishPairing(secret: Data) async throws {
        guard configured else { throw DeviceSyncError.notConfigured }  // crash-guard: no CKContainer
        let recordType = NADeviceSyncRecordType.pairingDevice
        let secretHex = secret.map { String(format: "%02x", $0) }.joined()
        let recordName = "pairing.\(role.rawValue)"
        let publishedAt = isoNow()
        do {
            try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.publishPairing") {
                let ck = CKRecord(
                    recordType: recordType,
                    recordID: CKRecord.ID(recordName: recordName)
                )
                ck["role"] = self.role.rawValue as CKRecordValue
                ck["secretHex"] = secretHex as CKRecordValue
                ck["publishedAt"] = publishedAt as CKRecordValue
                let op = CKModifyRecordsOperation(recordsToSave: [ck], recordIDsToDelete: nil)
                // Pairing is a mutable singleton per device — overwrite freely.
                op.savePolicy = .changedKeys
                op.qualityOfService = .userInitiated
                try await self.performModifyRecords(op)
            }
        } catch is DeviceCKLandmineTimeout {
            throw DeviceSyncError.transient(message: "CloudKit publishPairing timed out")
        }
    }

    public func observePairing(onChange: @escaping @Sendable (Data) async -> Bool) async {
        guard configured else {
            NSLog("[ck-device] observePairing: CloudKit entitlement absent — not subscribing (notConfigured).")
            return
        }
        setPairingHandler(onChange)  // last registration wins (single forwarder)
        // Register the durable silent-push subscription so the peer's pairing
        // writes notify this device, then do an initial drain to pick up a
        // secret already published. Live push → drain wiring is CK-3; drainPairing()
        // is the pull half and is exercisable now.
        do {
            try await subscribeToPairingChanges()
        } catch {
            NSLog("[ck-device] observePairing: subscription registration FAILED (no live push): \(error)")
        }
        await drainPairing()
    }

    /// 2026-09-06: read the PEER's currently published pairing secret without
    /// dispatching it, claiming it, or touching the last-writer-wins clock.
    /// A manually pasted recovery key has to be verified against the material
    /// the peer actually published, and on a build with no KVS entitlement
    /// this record is the only place that material exists.
    public func peekPairingSecret() async -> Data? {
        guard configured else { return nil }  // crash-guard: record(for:) touches CKContainer
        let peerRole: NADeviceRole = role == .mac ? .ios : .mac
        let recordName = "pairing.\(peerRole.rawValue)"
        return await withDeviceCKTimeout("CloudKitDeviceTransport.peekPairingSecret") {
            let record = try await self.database.record(for: CKRecord.ID(recordName: recordName))
            guard let hex = record["secretHex"] as? String else { return nil }
            return Self.data(fromHex: hex)
        } ?? nil
    }

    /// Pull the PEER's pairing singleton and dispatch to the registered handler
    /// iff it is newer than the last dispatched version (LWW by server
    /// modificationDate). Idempotent — a redundant drain does not re-fire the
    /// same secret. Returns true when the handler was invoked.
    @discardableResult
    public func drainPairing() async -> Bool {
        guard NADeviceSyncRecoveryBudget.hasTime else { return false }
        guard configured else { return false }  // crash-guard: record(for:) touches CKContainer
        guard let handler = loadPairingHandler() else { return false }
        let peerRole: NADeviceRole = role == .mac ? .ios : .mac
        let recordName = "pairing.\(peerRole.rawValue)"
        let hit: PeerPairingHit? = await withDeviceCKTimeout("CloudKitDeviceTransport.drainPairing") {
            let record = try await self.database.record(for: CKRecord.ID(recordName: recordName))
            guard let hex = record["secretHex"] as? String,
                  let data = Self.data(fromHex: hex) else { return nil }
            return PeerPairingHit(secret: data, modDate: record.modificationDate)
        } ?? nil
        guard let hit else { return false }
        guard pairingIsNewer(hit.modDate) else { return false }
        guard await handler(hit.secret) else { return false }
        commitPairingDate(hit.modDate)
        NADeviceSyncRecoveryBudget.didApplyData?()
        return true
    }

    // MARK: status

    public func setStatus(key: String, value: String) async throws {
        guard configured else { throw DeviceSyncError.notConfigured }  // crash-guard: no CKContainer
        let recordType = NADeviceSyncRecordType.status
        let recordName = "status.\(role.rawValue).\(key)"
        let updatedAt = isoNow()
        // The lane belongs to the actual CloudKit completion, not the caller's
        // bounded wait. A timed-out write must settle before a successor starts.
        let write = enqueueStatusWrite(key: key) {
                let ck = CKRecord(
                    recordType: recordType,
                    recordID: CKRecord.ID(recordName: recordName)
                )
                ck["key"] = key as CKRecordValue
                ck["value"] = value as CKRecordValue
                ck["role"] = self.role.rawValue as CKRecordValue
                ck["updatedAt"] = updatedAt as CKRecordValue
                let op = CKModifyRecordsOperation(recordsToSave: [ck], recordIDsToDelete: nil)
                op.savePolicy = .changedKeys
                op.qualityOfService = .utility
                try await self.performModifyRecords(op)
        }
        do {
            try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.setStatus", seconds: 3) {
                try await write.value
            }
        } catch is DeviceCKLandmineTimeout {
            throw DeviceSyncError.transient(message: "CloudKit setStatus timed out")
        }
    }

    private func enqueueStatusWrite(
        key: String,
        work: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        let previous = statusWrites[key]
        let write = Task.detached(priority: .utility) {
            _ = await previous?.result
            try await work()
        }
        statusWrites[key] = write
        return write
    }

    public func observeStatus(key: String, onChange: @escaping @Sendable (String) async -> Void) async {
        await observeStatus(key: key, onApply: { value in
            await onChange(value)
            return true
        })
    }

    /// 2026-09-06: the acknowledging registration. `onApply` returns true only
    /// once the value is durably applied; until it does, the peer's record keeps
    /// its place in the drain and is redelivered — the same claim/commit split
    /// the pairing lane has always used.
    public func observeStatus(key: String, onApply: @escaping @Sendable (String) async -> Bool) async {
        guard configured else {
            NSLog("[ck-device] observeStatus: CloudKit entitlement absent — not subscribing (notConfigured).")
            return
        }
        setStatusHandler(key: key, onApply)
        // Register the durable silent-push subscription for status writes, then
        // do an initial drain across all observed keys (picks up this key's
        // current value). Live push → drain wiring is CK-3.
        do {
            try await subscribeToStatusChanges()
        } catch {
            NSLog("[ck-device] observeStatus: subscription registration FAILED (no live push): \(error)")
        }
        await drainStatus()
    }

    /// Pull the PEER's status singleton for every observed key and dispatch each
    /// to its handler iff newer than the last dispatched value (LWW by server
    /// modificationDate, per key). Returns the number of handlers invoked.
    @discardableResult
    public func drainStatus() async -> Int {
        guard NADeviceSyncRecoveryBudget.hasTime else { return 0 }
        guard configured else { return 0 }  // crash-guard: record(for:) touches CKContainer
        // 2026-09-06: serialized, exactly as drainIncoming is. Unserialized,
        // two drains could claim two generations of one key and then apply them
        // concurrently — an older snapshot finishing last overwrites newer bytes.
        guard beginStatusDrainOrCoalesce() else { return 0 }
        var total = 0
        while true {
            total += await drainStatusBody()
            if endStatusDrainOrContinue() { continue }
            break
        }
        return total
    }

    /// Acquire the single status-drain slot. Mirrors `beginDrainOrCoalesce`.
    private func beginStatusDrainOrCoalesce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if statusDrainInFlight { statusDrainAgain = true; return false }
        statusDrainInFlight = true
        return true
    }

    /// End a status-drain iteration. Mirrors `endDrainOrContinue`.
    private func endStatusDrainOrContinue() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if statusDrainAgain && NADeviceSyncRecoveryBudget.hasTime { statusDrainAgain = false; return true }
        statusDrainAgain = false
        statusDrainInFlight = false
        return false
    }

    /// The status-drain body — always run serialized by `drainStatus`.
    private func drainStatusBody() async -> Int {
        let handlers = loadStatusHandlers()
        guard !handlers.isEmpty else { return 0 }
        let peerRole: NADeviceRole = role == .mac ? .ios : .mac
        var dispatched = 0
        for (key, handler) in handlers {
            guard NADeviceSyncRecoveryBudget.hasTime else { break }
            let recordName = "status.\(peerRole.rawValue).\(key)"
            let hit: PeerStatusHit? = await withDeviceCKTimeout("CloudKitDeviceTransport.drainStatus", seconds: 3) {
                let record = try await self.database.record(for: CKRecord.ID(recordName: recordName))
                guard let value = record["value"] as? String else { return nil }
                return PeerStatusHit(value: value, modDate: record.modificationDate)
            } ?? nil
            guard let hit else { continue }
            // 2026-09-06: check WITHOUT consuming, and commit only after the
            // handler reports the value durably applied. Claiming first meant a
            // snapshot generation the phone then failed to store was marked seen
            // and never redelivered.
            guard statusIsNewer(key: key, hit.modDate) else { continue }
            guard await handler(hit.value) else { continue }
            commitStatusDate(key: key, hit.modDate)
            dispatched += 1
            NADeviceSyncRecoveryBudget.didApplyData?()
        }
        return dispatched
    }

    // MARK: account status

    public func accountStatus() async -> String {
        guard configured else { return "notConfigured" }  // crash-guard: CKContainer init is the trap site
        return await withDeviceCKTimeout("CloudKitDeviceTransport.accountStatus") {
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

    // MARK: subscription (silent push — the live cross-device trigger)

    public func subscribeToChanges() async throws {
        guard configured else { throw DeviceSyncError.notConfigured }  // crash-guard: no CKContainer
        do {
            try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.subscribeToChanges") {
                // Register the visible lane first on iOS. A schema or migration
                // failure in silent sync must not prevent explicit alerts from
                // reaching APNS.
                if self.role == .ios {
                    try await self.ensureVisibleNotificationSubscription()
                }
                let sub = Self.makeSilentChatSubscription()
                try await self.ensureSubscription(sub, id: sub.subscriptionID)
            }
        } catch is DeviceCKLandmineTimeout {
            throw DeviceSyncError.transient(message: "CloudKit subscribe timed out")
        }
    }

    /// Broad silent sync trigger for chat/state records.
    ///
    /// Keep this predicate schema-independent. A production build using a
    /// compound optional-`kind` predicate stopped receiving alerts, and its
    /// serial registration order allowed any silent-lane failure to prevent
    /// visible registration. Explicit alerts use the visible subscription
    /// below; dependable repeated delivery is owned by direct APNS when
    /// configured.
    static func makeSilentChatSubscription() -> CKQuerySubscription {
        let sub = CKQuerySubscription(
            recordType: NADeviceSyncRecordType.chatMessage,
            predicate: NSPredicate(value: true),
            subscriptionID: DeviceCloudKitSubscriptionID.chat,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        return sub
    }

    /// A high-priority visual CloudKit notification for explicit
    /// `mobile.notify` records. The dedicated record type guarantees that a
    /// notification matches exactly one APNS-producing subscription rather
    /// than racing a silent chat projection that CloudKit may coalesce with it.
    private func ensureVisibleNotificationSubscription() async throws {
        let sub = Self.makeVisibleNotificationSubscription()
        try await ensureSubscription(sub, id: sub.subscriptionID)
        try await retireSubscription(id: "NAChatMessage.notifications.visible")
        markVisibleNotificationSubscriptionReady()
    }

    private func markVisibleNotificationSubscriptionReady() {
        lock.lock()
        visibleNotificationSubscriptionReady = true
        lock.unlock()
    }

    static func makeVisibleNotificationSubscription() -> CKQuerySubscription {
        let sub = CKQuerySubscription(
            recordType: NADeviceSyncRecordType.notification,
            predicate: NSPredicate(value: true),
            subscriptionID: DeviceCloudKitSubscriptionID.visibleNotifications,
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.alertLocalizationKey = "NATIVEAGENT_CLOUDKIT_NOTIFICATION_BODY_FORMAT"
        info.alertLocalizationArgs = ["text"]
        info.titleLocalizationKey = "NATIVEAGENT_CLOUDKIT_NOTIFICATION_TITLE_FORMAT"
        info.titleLocalizationArgs = ["notificationTitle"]
        info.soundName = "default"
        // Apple permits at most three desiredKeys. The alert/title localization
        // arguments already extract `text` and `notificationTitle`; the three
        // extra fields below are the bounded app-side routing/dedup projection.
        info.desiredKeys = [
            "notificationScreen",
            "notificationEventId",
            "kind",
        ]
        info.collapseIDKey = "notificationEventId"
        sub.notificationInfo = info
        return sub
    }

    /// Remove the pre-split visual projection. Leaving it installed would let
    /// legacy `NAChatMessage(kind=notification)` writes keep competing with the
    /// silent chat subscription on upgraded accounts.
    private func retireSubscription(id: CKSubscription.ID) async throws {
        do {
            _ = try await database.deleteSubscription(withID: id)
        } catch let error as CKError where error.code == .unknownItem {
            return
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Durable silent-push subscription for the peer's pairing writes. Same broad
    /// value:true predicate as the chat subscription (no queryable-field/index
    /// dependency); drainPairing() filters to the peer's record locally.
    public func subscribeToPairingChanges() async throws {
        try await registerBroadSubscription(
            recordType: NADeviceSyncRecordType.pairingDevice,
            subscriptionID: DeviceCloudKitSubscriptionID.pairing,
            label: "subscribeToPairingChanges"
        )
    }

    /// Durable silent-push subscription for the peer's status writes.
    public func subscribeToStatusChanges() async throws {
        try await registerBroadSubscription(
            recordType: NADeviceSyncRecordType.status,
            subscriptionID: DeviceCloudKitSubscriptionID.status,
            label: "subscribeToStatusChanges"
        )
    }

    /// Shared broad-subscription registration (value:true predicate,
    /// shouldSendContentAvailable). Fails loud — the caller NSLogs; nothing is
    /// swallowed with try?. Treats "already exists" as success (durable).
    private func registerBroadSubscription(
        recordType: String,
        subscriptionID: String,
        label: String
    ) async throws {
        guard configured else { throw DeviceSyncError.notConfigured }  // crash-guard: no CKContainer
        do {
            try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.\(label)") {
                let predicate = NSPredicate(value: true)
                let sub = CKQuerySubscription(
                    recordType: recordType,
                    predicate: predicate,
                    subscriptionID: subscriptionID,
                    options: [.firesOnRecordCreation, .firesOnRecordUpdate]
                )
                let info = CKSubscription.NotificationInfo()
                info.shouldSendContentAvailable = true  // silent push
                sub.notificationInfo = info
                try await self.ensureSubscription(sub, id: subscriptionID)
            }
        } catch is DeviceCKLandmineTimeout {
            throw DeviceSyncError.transient(message: "CloudKit \(label) timed out")
        }
    }

    /// Idempotently installs one subscription without confusing a production
    /// schema rejection with "already exists." CloudKit uses
    /// `serverRejectedRequest` when a subscription shape was never created in
    /// Development and promoted to Production, so accepting that code blindly
    /// leaves the silent-push lane dead while reporting success.
    ///
    /// Fetch first. An ID match alone is not success: an older/silent
    /// subscription under the visible-notification ID leaves records queued
    /// until foreground drain while falsely reporting that Apple owns visual
    /// presentation. Compare the complete shape and save the expected
    /// subscription when it drifted.
    ///
    /// If a concurrent process wins the create/repair race, fetch again after a
    /// failed save and accept only an exact shape match. Every other failure
    /// remains visible.
    private func ensureSubscription(_ subscription: CKSubscription, id: CKSubscription.ID) async throws {
        do {
            let existing = try await database.subscription(for: id)
            if Self.subscription(existing, matches: subscription) {
                return
            }
            NSLog("[ck-device] repairing stale subscription shape for \(id)")
        } catch let error as CKError where error.code == .unknownItem {
            // Absent is the only state that authorizes a create attempt.
        } catch {
            throw Self.mapError(error)
        }

        do {
            let saved = try await database.save(subscription)
            guard Self.subscription(saved, matches: subscription) else {
                throw DeviceSyncError.underlying(
                    message: "CloudKit saved subscription \(id) with an unexpected shape"
                )
            }
        } catch {
            if let existing = try? await database.subscription(for: id),
               Self.subscription(existing, matches: subscription) {
                return
            }
            if let syncError = error as? DeviceSyncError {
                throw syncError
            }
            throw Self.mapError(error)
        }
    }

    static func subscription(
        _ existing: CKSubscription,
        matches expected: CKSubscription
    ) -> Bool {
        guard existing.subscriptionID == expected.subscriptionID,
              let existingQuery = existing as? CKQuerySubscription,
              let expectedQuery = expected as? CKQuerySubscription,
              existingQuery.recordType == expectedQuery.recordType,
              existingQuery.predicate.predicateFormat == expectedQuery.predicate.predicateFormat,
              existingQuery.querySubscriptionOptions == expectedQuery.querySubscriptionOptions
        else {
            return false
        }

        switch (existing.notificationInfo, expected.notificationInfo) {
        case (nil, nil):
            return true
        case let (existingInfo?, expectedInfo?):
            return existingInfo.shouldSendContentAvailable
                    == expectedInfo.shouldSendContentAvailable
                && existingInfo.shouldSendMutableContent
                    == expectedInfo.shouldSendMutableContent
                && existingInfo.shouldBadge == expectedInfo.shouldBadge
                && existingInfo.alertLocalizationKey
                    == expectedInfo.alertLocalizationKey
                && existingInfo.alertLocalizationArgs
                    == expectedInfo.alertLocalizationArgs
                && existingInfo.titleLocalizationKey
                    == expectedInfo.titleLocalizationKey
                && existingInfo.titleLocalizationArgs
                    == expectedInfo.titleLocalizationArgs
                && existingInfo.soundName == expectedInfo.soundName
                && Set(existingInfo.desiredKeys ?? [])
                    == Set(expectedInfo.desiredKeys ?? [])
                && existingInfo.collapseIDKey == expectedInfo.collapseIDKey
        default:
            return false
        }
    }

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

    /// 2026-09-06: the paging stop compares each record's SERVER modificationDate
    /// against the durable watermark, so the page order has to be that same
    /// clock. Ordered by the client `createdAt`, a record created while the peer
    /// was offline and uploaded later sorts BEHIND records the stop already
    /// matched, so paging halted before reaching it and the advancing watermark
    /// made the miss permanent. Order by modificationDate; if the deployed
    /// container has no sortable index on `___modTime` the query is rejected
    /// once and we fall back to the previous createdAt order for the rest of the
    /// process, for that record type only.
    private func serverModDateSortAvailable(recordType: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !serverModDateSortRejected.contains(recordType)
    }

    private func markServerModDateSortRejected(recordType: String) {
        lock.lock(); serverModDateSortRejected.insert(recordType); lock.unlock()
    }

    private func pull(
        recordType: String,
        since: Date?,
        inboundDirection: String
    ) async throws -> [(fields: NAChatMessageFields, modDate: Date?)] {
        guard configured else { throw DeviceSyncError.notConfigured }  // crash-guard: no CKContainer
        do {
            return try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.pull") {
                if self.serverModDateSortAvailable(recordType: recordType) {
                    do {
                        return try await self.pullPages(
                            recordType: recordType,
                            since: since,
                            inboundDirection: inboundDirection,
                            orderByServerModDate: true
                        )
                    } catch is DeviceCKUnsortableField {
                        NSLog("[ck-device] pull: %@ has no sortable ___modTime index; falling back to createdAt order", recordType)
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
    ) async throws -> [(fields: NAChatMessageFields, modDate: Date?)] {
        let query = CKQuery(
            recordType: recordType,
            predicate: Self.makePullPredicate(inboundDirection: inboundDirection)
        )
        query.sortDescriptors = [
            NSSortDescriptor(key: orderByServerModDate ? "modificationDate" : "createdAt", ascending: false)
        ]

        let checkpointKey = recordType + ":" + inboundDirection
        let owner = UUID()
        let checkpoint = orderByServerModDate ? nil : beginFallbackPull(checkpointKey, owner: owner)
        var combined = checkpoint?.records ?? []
        var nextCursor = checkpoint?.cursor
        var firstPage = checkpoint == nil

        repeat {
            guard NADeviceSyncRecoveryBudget.hasTime else { throw CancellationError() }
            let op: CKQueryOperation
            // 2026-09-06: only the FIRST operation carries the sort descriptor,
            // so only the first operation can be rejected for it.
            let carriesSortDescriptor = firstPage
            if firstPage {
                op = CKQueryOperation(query: query); firstPage = false
            } else if let c = nextCursor {
                op = CKQueryOperation(cursor: c)
            } else {
                break
            }
            op.qualityOfService = .userInitiated
            op.resultsLimit = 200

            let holder = DeviceCKPullPageHolder()
            let modHolder = DeviceCKModDateHolder()
            op.recordMatchedBlock = { _, result in
                switch result {
                case .failure(let error):
                    holder.fail(error)
                case .success(let ck):
                    let fields = NAChatMessageFields(
                        recordName: ck.recordID.recordName,
                        direction: (ck["direction"] as? String) ?? "",
                        sessionId: ck["sessionId"] as? String,
                        text: (ck["text"] as? String) ?? "",
                        payloadJSON: (ck["payloadJSON"] as? String) ?? "",
                        createdAt: (ck["createdAt"] as? String) ?? "",
                        senderDevice: (ck["senderDevice"] as? String) ?? "",
                        kind: ck["kind"] as? String,
                        notificationTitle: ck["notificationTitle"] as? String,
                        notificationScreen: ck["notificationScreen"] as? String,
                        notificationEventID: ck["notificationEventId"] as? String
                    )
                    holder.add(fields)
                    modHolder.set(fields.recordName, ck.modificationDate)
                }
            }

            // Return BOTH page + cursor through the continuation (mirrors
            // MemoryV2's fix): never mutate the captured `nextCursor` from
            // inside the @Sendable queryResultBlock — that was a real
            // callback data race.
            let page: (records: [NAChatMessageFields], cursor: CKQueryOperation.Cursor?) =
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(records: [NAChatMessageFields], cursor: CKQueryOperation.Cursor?), Error>) in
                    op.queryResultBlock = { result in
                        switch result {
                        case .success(let cursor):
                            do {
                                cont.resume(returning: (try holder.snapshot(), cursor))
                            } catch {
                                cont.resume(throwing: Self.mapError(error))
                            }
                        case .failure(let err):
                            if !orderByServerModDate,
                               (err as? CKError)?.code == .invalidArguments {
                                self.saveFallbackPull(nil, key: checkpointKey, owner: owner)
                            }
                            // 2026-09-06: an .invalidArguments on a CURSOR
                            // continuation is a cursor failure (an expired or
                            // rejected cursor), NOT a missing sort index — the
                            // cursor operation never carried the descriptor.
                            // Classifying it as one restarted the whole pull in
                            // the createdAt order the paging stop cannot trust,
                            // and latched that order for the rest of the
                            // process. A cursor failure is surfaced as itself;
                            // the watermark has not advanced, so the next drain
                            // restarts the pull from it.
                            if carriesSortDescriptor,
                               orderByServerModDate,
                               (err as? CKError)?.code == .invalidArguments {
                                cont.resume(throwing: DeviceCKUnsortableField())
                            } else {
                                cont.resume(throwing: Self.mapError(err))
                            }
                        }
                    }
                    self.database.add(op)
                }
            guard NADeviceSyncRecoveryBudget.hasTime else { throw CancellationError() }
            for f in page.records {
                combined.append((f, modHolder.get(f.recordName)))
            }
            let crossedWatermark = Self.pullPageCrossesWatermark(
                orderByServerModDate: orderByServerModDate,
                since: since,
                modificationDates: page.records.map { modHolder.get($0.recordName) }
            )
            nextCursor = crossedWatermark ? nil : page.cursor
            if !orderByServerModDate {
                saveFallbackPull(nextCursor.map {
                    DeviceCKPullCheckpoint(records: combined, cursor: $0)
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

    // MARK: helpers

    // MARK: locked state accessors (synchronous — never call lock from an async
    // context; scoped critical sections only, matching MemoryV2+CloudKit).

    func setIncomingHandler(_ h: @escaping @Sendable (BridgeMessage) async -> Bool) {
        lock.lock(); incomingHandler = h; lock.unlock()
    }

    private func setPairingHandler(_ h: @escaping @Sendable (Data) async -> Bool) {
        lock.lock(); pairingHandler = h; lock.unlock()
    }

    private func setStatusHandler(key: String, _ h: @escaping @Sendable (String) async -> Bool) {
        lock.lock(); statusHandlers[key] = h; lock.unlock()
    }

    private func loadPairingHandler() -> (@Sendable (Data) async -> Bool)? {
        lock.lock(); defer { lock.unlock() }
        return pairingHandler
    }

    /// Snapshot copy of the status handlers so we never hold the lock across the
    /// awaits in drainStatus (matches the never-lock-across-await rule).
    private func loadStatusHandlers() -> [String: @Sendable (String) async -> Bool] {
        lock.lock(); defer { lock.unlock() }
        return statusHandlers
    }

    /// Checks freshness without consuming the record. The modification date is
    /// committed only after PairingStore reports a durable Keychain acceptance.
    private func pairingIsNewer(_ modDate: Date?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let modDate, let last = lastPairingModDate {
            return modDate > last
        }
        return true
    }

    private func commitPairingDate(_ modDate: Date?) {
        guard let modDate else { return }
        lock.lock()
        if lastPairingModDate == nil || modDate > lastPairingModDate! {
            lastPairingModDate = modDate
        }
        lock.unlock()
    }

    /// Per-key LWW freshness check for status singletons — the same rule as
    /// pairing, and like pairing it does NOT consume the record. `commitStatusDate`
    /// is what marks it seen, and only a handler that applied it may call that.
    private func statusIsNewer(key: String, _ modDate: Date?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let modDate, let last = lastStatusModDates[key] {
            return modDate > last
        }
        return true
    }

    private func commitStatusDate(key: String, _ modDate: Date?) {
        guard let modDate else { return }
        lock.lock()
        if let last = lastStatusModDates[key] {
            if modDate > last { lastStatusModDates[key] = modDate }
        } else {
            lastStatusModDates[key] = modDate
        }
        lock.unlock()
    }

    private func loadHandlerAndCursor() -> ((@Sendable (BridgeMessage) async -> Bool)?, Date?) {
        lock.lock(); defer { lock.unlock() }
        return (incomingHandler, lastPullDate)
    }

    private func setLastPullDate(_ date: Date, persistImmediately: Bool) {
        let shouldPersist: Bool = {
            lock.lock()
            defer { lock.unlock() }
            lastPullDate = date
            let now = Date()
            let persist = Self.shouldPersistPullCursor(
                immediately: persistImmediately,
                lastPersistenceAt: lastPullCursorPersistenceAt,
                now: now
            )
            if persist { lastPullCursorPersistenceAt = now }
            return persist
        }()
        guard shouldPersist else { return }
        // CK-3c: persist so the cursor survives a restart (see init). role +
        // containerIdentifier are immutable lets — no lock needed; UserDefaults
        // is thread-safe.
        UserDefaults.standard.set(date.timeIntervalSince1970,
                                  forKey: Self.cursorKey(role: role, container: containerIdentifier))
    }

    /// Transport acknowledgement applies to these bytes, never to an
    /// unauthenticated message identity. A corrected record remains eligible.
    private static func deliveryClaimKey(_ fields: NAChatMessageFields) -> String {
        let digest = SHA256.hash(data: Data(fields.payloadJSON.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return fields.recordName + ":" + digest
    }

    /// Atomic check-and-claim: inserts `id` into the seen set and returns true
    /// iff it was newly claimed. Prevents two concurrent drains from both
    /// delivering the same message id (the check + insert are one locked op).
    private func claimIfUnseen(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return claimWhileLocked(id)
    }

    private func claimForSerialDrain(_ id: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard !cancellationDrainInFlight else { return nil }
        return claimWhileLocked(id)
    }

    private func claimWhileLocked(_ id: String) -> Bool {
        guard !seenMessageIDs.contains(id) else { return false }
        seenMessageIDs.insert(id)
        seenMessageIDsOrdered.append(id)
        while seenMessageIDsOrdered.count > seenMessageIDsCap {
            let oldest = seenMessageIDsOrdered.removeFirst()
            seenMessageIDs.remove(oldest)
        }
        return true
    }

    /// Release a claim taken by `claimIfUnseen` when delivery is rejected, so
    /// the message is retried on the next drain.
    private func releaseClaim(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard seenMessageIDs.remove(id) != nil else { return }
        if let i = seenMessageIDsOrdered.lastIndex(of: id) {
            seenMessageIDsOrdered.remove(at: i)
        }
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private static func data(fromHex hex: String) -> Data? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var out = Data(capacity: clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }

    private func performModifyRecords(_ op: CKModifyRecordsOperation) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let err): cont.resume(throwing: Self.mapError(err))
                }
            }
            self.database.add(op)
        }
    }

    private static func mapError(_ err: Error) -> DeviceSyncError {
        if let ck = err as? CKError {
            if ck.code == .partialFailure,
               let partial = ck.partialErrorsByItemID {
                let nested = partial.values.compactMap { $0 as? CKError }
                if nested.contains(where: { $0.code == .serverRecordChanged }) {
                    return .conflict
                }
                if let first = nested.first {
                    return mapError(first)
                }
            }
            switch ck.code {
            case .quotaExceeded: return .quotaExceeded
            case .notAuthenticated: return .unauthorized
            case .serverRecordChanged: return .conflict
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return .transient(message: ck.localizedDescription)
            default:
                return .underlying(message: ck.localizedDescription)
            }
        }
        return .underlying(message: err.localizedDescription)
    }
}

// MARK: - Safe factory (the second half of the crash-guard)

public extension DeviceSyncTransportResolver {
    /// Build the CloudKit device transport for this role — honoring BOTH the
    /// `NATIVE_AGENT_DEVICE_SYNC` selection AND the CloudKit entitlement
    /// crash-guard. Returns:
    ///   • `nil` when the selected kind is `.kvs` (caller keeps the legacy
    ///     KVS/ubiquity bridge), OR
    ///   • `nil` when `.cloudkit` is selected but the CloudKit entitlement is
    ///     ABSENT — a loud `NSLog` + graceful degradation to the legacy path,
    ///     NEVER a `CloudKitDeviceTransport` that would trap on first use (the
    ///     2026-06-03 `_os_crash` guard), OR
    ///   • a live `CloudKitDeviceTransport` when `.cloudkit` is selected AND the
    ///     entitlement is granted.
    ///
    /// The transport ALSO guards itself internally (every method short-circuits
    /// when unconfigured), so a direct construction is safe too — this factory is
    /// the outer, graceful-degradation layer of a defense-in-depth pair.
    static func makeCloudKitTransport(
        role: NADeviceRole,
        containerIdentifier: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hasEntitlement: () -> Bool = DeviceCloudKitPreflight.hasCloudKitEntitlement,
        grantsContainer: (String) -> Bool = DeviceCloudKitPreflight.entitlementGrantsContainer
    ) -> DeviceSyncTransport? {
        guard resolvedKind(environment: environment) == .cloudkit else { return nil }
        guard hasEntitlement() else {
            NSLog("[ck-device] NATIVE_AGENT_DEVICE_SYNC=cloudkit but the CloudKit entitlement is ABSENT — staying on the legacy KVS/ubiquity transport (no CKContainer is touched). This is the 2026-06-03 launch-crash guard.")
            return nil
        }
        guard grantsContainer(containerIdentifier) else {
            NSLog("[ck-device] CloudKit service is granted but the exact container '\(containerIdentifier)' is absent — refusing to construct CKContainer and staying on the legacy transport.")
            return nil
        }
        return CloudKitDeviceTransport(
            role: role, containerIdentifier: containerIdentifier, configured: true)
    }
}

/// Sendable value carriers for the pairing/status singleton drains (returned
/// across the withDeviceCKTimeout race boundary).
private struct PeerPairingHit: Sendable { let secret: Data; let modDate: Date? }
private struct PeerStatusHit: Sendable { let value: String; let modDate: Date? }

/// Thread-safe recordName → modificationDate map for a single pull page (the
/// recordMatchedBlock fires on CloudKit's queue).
private final class DeviceCKModDateHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: Date?] = [:]
    func set(_ id: String, _ date: Date?) { lock.lock(); map[id] = date; lock.unlock() }
    func get(_ id: String) -> Date? { lock.lock(); defer { lock.unlock() }; return map[id] ?? nil }
}

#endif
