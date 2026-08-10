// CloudKitDeviceTransport.swift — CloudKit implementation of DeviceSyncTransport.
//
// Modeled CLOSELY on Modules/NativeAgentCore/Sources/MemoryV2/MemoryV2+CloudKit.swift
// (SystemCloudKitSync): CKContainer(identifier:).privateCloudDatabase,
// CKModifyRecordsOperation push (.ifServerRecordUnchanged), CKQuery pull
// (modificationDate predicate + cursor pagination), CKQuerySubscription with
// silent push (shouldSendContentAvailable), CKError mapping, and the
// withCKTimeout / withCKTimeoutThrowing timeout-race helpers.
//
// The timeout-race machinery below is a PARALLEL COPY of the memory-sync
// helpers (Device-prefixed). This is intentional: the memory-sync file is
// gpt-5.5-reviewed and load-bearing; a copy keeps CK-1 at zero risk to it and
// avoids coupling NativeAgentShared to NativeAgentCore (iOS only depends on
// NativeAgentShared). Keep the two copies in sync if the race logic changes.
//
// LWW is by modificationDate (CloudKit server-stamped), exactly like the
// memory framework. This wave lands the compiling, unit-testable transport;
// it is NOT wired into iCloudBridge and does not run at launch (the resolver
// defaults to .kvs). Live APNs push → pull wiring is CK-3.

import Foundation

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

// MARK: - Timeout-race machinery (parallel copy of MemoryV2+CloudKit helpers)

private enum DeviceCKTimeoutRace<T: Sendable>: Sendable {
    case success(T)
    case failure(String)
    case failureError(Error)
    case timedOut
    case cancelled
}

private actor DeviceCKTimeoutState<T: Sendable> {
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<Result<T, Error>?, Never>?

    func wait() async -> Result<T, Error>? {
        if let result { return result }
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

private func withDeviceCKTimeout<T: Sendable>(
    _ label: String,
    seconds: TimeInterval = 5,
    _ work: @Sendable @escaping () async throws -> T
) async -> T? {
    let state = DeviceCKTimeoutState<T>()
    let timeoutNanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
    let workTask = Task.detached(priority: .utility) {
        do { await state.finish(.success(try await work())) }
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
    let state = DeviceCKTimeoutState<T>()
    let timeoutNanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
    let workTask = Task.detached(priority: .utility) {
        do { await state.finish(.success(try await work())) }
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

/// Thread-safe per-page accumulator for pull's recordMatchedBlock. The CK
/// callback runs on CloudKit's own queue, so the holder locks its own appends.
private final class DeviceCKPullPageHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [NAChatMessageFields] = []
    func add(_ r: NAChatMessageFields) { lock.lock(); items.append(r); lock.unlock() }
    func snapshot() -> [NAChatMessageFields] { lock.lock(); defer { lock.unlock() }; return items }
}

// MARK: - CloudKitDeviceTransport

/// CloudKit-backed device transport. `@unchecked Sendable` with an internal
/// NSLock for mutable state (handlers + last-pull cursor + seen ids), mirroring
/// `SystemCloudKitSync`'s `final class ... @unchecked Sendable` shape.
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
    private var pairingHandler: (@Sendable (Data) async -> Bool)?
    private var statusHandlers: [String: @Sendable (String) async -> Void] = [:]
    private var visibleNotificationSubscriptionReady = false
    private var lastPullDate: Date?
    // CK-3c: transport-level drain serialization (guarded by `lock`). Concurrent
    // drains must NOT overlap — one drain's releaseClaim racing another's
    // cursor-advance can drop a record (gpt-5.5 CK-3c review P0). While a drain
    // body runs, concurrent callers set drainAgain and return; the active loop
    // re-runs once to service them.
    private var drainInFlight = false
    private var drainAgain = false
    // LWW/dedup cursors for the pairing + status singletons. Pairing is one
    // mutable record per peer role; status is one record per (peer role, key).
    // We only re-dispatch when the server modificationDate advances, so a redraw
    // triggered by a redundant push does not re-fire the same value.
    private var lastPairingModDate: Date?
    private var lastStatusModDates: [String: Date] = [:]
    // Insertion-ordered seen-id dedup, capped, mirroring iCloudBridge.
    private var seenMessageIDs: Set<String> = []
    private var seenMessageIDsOrdered: [String] = []
    private let seenMessageIDsCap = 2000

    public init(
        role: NADeviceRole,
        containerIdentifier: String,
        configured: Bool = DeviceCloudKitPreflight.hasCloudKitEntitlement()
    ) {
        self.role = role
        self.containerIdentifier = containerIdentifier
        self.configured = configured
        // CK-3c: restore the persisted pull cursor so a cold start resumes from
        // where it left off instead of re-pulling every record from zero (which
        // would re-deliver old messages past the bridge seen-set cap). Keyed by
        // (role, container) so distinct devices/containers never share a cursor.
        if let ts = UserDefaults.standard.object(forKey: Self.cursorKey(role: role, container: containerIdentifier)) as? Double {
            self.lastPullDate = Date(timeIntervalSince1970: ts)
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
        } catch is DeviceCKLandmineTimeout {
            if await existingMessageRecordMatches(fields) {
                return
            }
            throw DeviceSyncError.transient(message: "CloudKit send timed out")
        } catch let error as DeviceSyncError {
            if case .conflict = error, await existingMessageRecordMatches(fields) {
                return
            }
            throw error
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
        guard configured else { return 0 }  // crash-guard: pull() touches CKContainer
        // CK-3c: serialize via SYNC lock helpers (the codebase keeps every NSLock
        // use in a synchronous scope — never held across an await). The body's own
        // fine-grained locking still works since the slot flag isn't held here.
        guard beginDrainOrCoalesce() else { return 0 }
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
        if drainAgain { drainAgain = false; return true }
        drainInFlight = false
        return false
    }

    /// The drain body — always run serialized by `drainIncoming`; never call it
    /// directly (concurrent bodies can drop records, the P0 the wrapper prevents).
    private func drainIncomingBody() async -> Int {
        let (handler, since) = loadHandlerAndCursor()
        guard let handler else { return 0 }
        let queryStartedAt = Date()

        let inbound = role.inboundDirection.rawValue
        let fetched: [(fields: NAChatMessageFields, modDate: Date?)]
        do {
            var records = try await pull(
                recordType: NADeviceSyncRecordType.chatMessage,
                since: since
            )
            if role == .ios {
                records += try await pull(
                    recordType: NADeviceSyncRecordType.notification,
                    since: since
                )
            }
            fetched = records
        } catch {
            NSLog("[ck-device] drainIncoming pull failed: \(error)")
            return 0
        }

        // Deliver in chronological order — CloudKit query order is undefined.
        // Sort ascending by server modDate, then createdAt, then id.
        let sorted = fetched.sorted { a, b in
            let am = a.modDate ?? .distantPast, bm = b.modDate ?? .distantPast
            if am != bm { return am < bm }
            if a.fields.createdAt != b.fields.createdAt { return a.fields.createdAt < b.fields.createdAt }
            return a.fields.recordName < b.fields.recordName
        }

        var dispatched = 0
        // The cursor may only advance to the last point BEFORE the first
        // UNDELIVERED inbound record — a rejected message must never be skipped.
        // Delivered / already-seen / not-for-us records advance it; the first
        // handler rejection halts advancement (that record is retried next drain).
        var cursorAdvance: Date? = nil
        var halted = false
        for item in sorted {
            if halted { break }
            let m = item.modDate
            guard item.fields.direction == inbound else {
                if let m { cursorAdvance = m }   // our own outbound / other — safe to pass
                continue
            }
            let id = item.fields.recordName
            // Atomic check-and-claim under one lock so two concurrent drains
            // cannot both deliver the same id.
            guard claimIfUnseen(id) else {
                if let m { cursorAdvance = m }    // already delivered — safe to pass
                continue
            }
            guard let message = try? NAChatMessageCodec.decode(item.fields) else {
                NSLog("[ck-device] drainIncoming: undecodable payload for \(id)")
                if let m { cursorAdvance = m }    // poison — keep it claimed, pass
                continue
            }
            if await handler(message) {
                dispatched += 1
                if let m { cursorAdvance = m }
            } else {
                releaseClaim(id)                  // not delivered — retry next drain
                halted = true                     // do not advance past this record
            }
        }
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
            setLastPullDate(nextCursor)
        }
        return dispatched
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

    /// Pull the PEER's pairing singleton and dispatch to the registered handler
    /// iff it is newer than the last dispatched version (LWW by server
    /// modificationDate). Idempotent — a redundant drain does not re-fire the
    /// same secret. Returns true when the handler was invoked.
    @discardableResult
    public func drainPairing() async -> Bool {
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
        return true
    }

    // MARK: status

    public func setStatus(key: String, value: String) async throws {
        guard configured else { throw DeviceSyncError.notConfigured }  // crash-guard: no CKContainer
        let recordType = NADeviceSyncRecordType.status
        let recordName = "status.\(role.rawValue).\(key)"
        let updatedAt = isoNow()
        do {
            try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.setStatus", seconds: 3) {
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
        } catch is DeviceCKLandmineTimeout {
            throw DeviceSyncError.transient(message: "CloudKit setStatus timed out")
        }
    }

    public func observeStatus(key: String, onChange: @escaping @Sendable (String) async -> Void) async {
        guard configured else {
            NSLog("[ck-device] observeStatus: CloudKit entitlement absent — not subscribing (notConfigured).")
            return
        }
        setStatusHandler(key: key, onChange)
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
        guard configured else { return 0 }  // crash-guard: record(for:) touches CKContainer
        let handlers = loadStatusHandlers()
        guard !handlers.isEmpty else { return 0 }
        let peerRole: NADeviceRole = role == .mac ? .ios : .mac
        var dispatched = 0
        for (key, handler) in handlers {
            let recordName = "status.\(peerRole.rawValue).\(key)"
            let hit: PeerStatusHit? = await withDeviceCKTimeout("CloudKitDeviceTransport.drainStatus", seconds: 3) {
                let record = try await self.database.record(for: CKRecord.ID(recordName: recordName))
                guard let value = record["value"] as? String else { return nil }
                return PeerStatusHit(value: value, modDate: record.modificationDate)
            } ?? nil
            guard let hit else { continue }
            guard claimStatusIfNewer(key: key, hit.modDate) else { continue }
            await handler(hit.value)
            dispatched += 1
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

    // MARK: pull (cursor-paginated, mirrors SystemCloudKitSync.pullSince)

    private func pull(
        recordType: String,
        since: Date?
    ) async throws -> [(fields: NAChatMessageFields, modDate: Date?)] {
        guard configured else { throw DeviceSyncError.notConfigured }  // crash-guard: no CKContainer
        do {
            return try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.pull") {
                let predicate: NSPredicate
                if let ts = since {
                    predicate = NSPredicate(format: "modificationDate > %@", ts as NSDate)
                } else {
                    predicate = NSPredicate(value: true)
                }
                let query = CKQuery(recordType: recordType, predicate: predicate)

                var combined: [(fields: NAChatMessageFields, modDate: Date?)] = []
                var nextCursor: CKQueryOperation.Cursor? = nil
                var firstPage = true

                repeat {
                    let op: CKQueryOperation
                    if firstPage {
                        op = CKQueryOperation(query: query); firstPage = false
                    } else if let c = nextCursor {
                        op = CKQueryOperation(cursor: c)
                    } else {
                        break
                    }
                    op.qualityOfService = .userInitiated

                    let holder = DeviceCKPullPageHolder()
                    let modHolder = DeviceCKModDateHolder()
                    op.recordMatchedBlock = { _, result in
                        if case .success(let ck) = result {
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
                                    cont.resume(returning: (holder.snapshot(), cursor))
                                case .failure(let err):
                                    cont.resume(throwing: Self.mapError(err))
                                }
                            }
                            self.database.add(op)
                        }
                    for f in page.records {
                        combined.append((f, modHolder.get(f.recordName)))
                    }
                    nextCursor = page.cursor
                } while nextCursor != nil

                return combined
            }
        } catch is DeviceCKLandmineTimeout {
            throw DeviceSyncError.transient(message: "CloudKit pull timed out")
        }
    }

    // MARK: helpers

    // MARK: locked state accessors (synchronous — never call lock from an async
    // context; scoped critical sections only, matching MemoryV2+CloudKit).

    private func setIncomingHandler(_ h: @escaping @Sendable (BridgeMessage) async -> Bool) {
        lock.lock(); incomingHandler = h; lock.unlock()
    }

    private func setPairingHandler(_ h: @escaping @Sendable (Data) async -> Bool) {
        lock.lock(); pairingHandler = h; lock.unlock()
    }

    private func setStatusHandler(key: String, _ h: @escaping @Sendable (String) async -> Void) {
        lock.lock(); statusHandlers[key] = h; lock.unlock()
    }

    private func loadPairingHandler() -> (@Sendable (Data) async -> Bool)? {
        lock.lock(); defer { lock.unlock() }
        return pairingHandler
    }

    /// Snapshot copy of the status handlers so we never hold the lock across the
    /// awaits in drainStatus (matches the never-lock-across-await rule).
    private func loadStatusHandlers() -> [String: @Sendable (String) async -> Void] {
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

    /// Per-key LWW claim for status singletons (same rule as pairing).
    private func claimStatusIfNewer(key: String, _ modDate: Date?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let modDate, let last = lastStatusModDates[key] {
            guard modDate > last else { return false }
            lastStatusModDates[key] = modDate
            return true
        }
        if let modDate { lastStatusModDates[key] = modDate }
        return true
    }

    private func loadHandlerAndCursor() -> ((@Sendable (BridgeMessage) async -> Bool)?, Date?) {
        lock.lock(); defer { lock.unlock() }
        return (incomingHandler, lastPullDate)
    }

    private func setLastPullDate(_ date: Date) {
        lock.lock(); lastPullDate = date; lock.unlock()
        // CK-3c: persist so the cursor survives a restart (see init). role +
        // containerIdentifier are immutable lets — no lock needed; UserDefaults
        // is thread-safe.
        UserDefaults.standard.set(date.timeIntervalSince1970,
                                  forKey: Self.cursorKey(role: role, container: containerIdentifier))
    }

    /// Atomic check-and-claim: inserts `id` into the seen set and returns true
    /// iff it was newly claimed. Prevents two concurrent drains from both
    /// delivering the same message id (the check + insert are one locked op).
    private func claimIfUnseen(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
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
        hasEntitlement: () -> Bool = DeviceCloudKitPreflight.hasCloudKitEntitlement
    ) -> DeviceSyncTransport? {
        guard resolvedKind(environment: environment) == .cloudkit else { return nil }
        guard hasEntitlement() else {
            NSLog("[ck-device] NATIVE_AGENT_DEVICE_SYNC=cloudkit but the CloudKit entitlement is ABSENT — staying on the legacy KVS/ubiquity transport (no CKContainer is touched). This is the 2026-06-03 launch-crash guard.")
            return nil
        }
        if !DeviceCloudKitPreflight.entitlementGrantsContainer(containerIdentifier) {
            // Diagnostic only — container-id string formats vary across profiles,
            // so this does NOT disable CloudKit (the hard gate above already
            // passed). It just flags a likely-misconfigured container id.
            NSLog("[ck-device] note: entitlements do not visibly list container '\(containerIdentifier)' — proceeding on the CloudKit service grant; verify the container id if sync fails.")
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
