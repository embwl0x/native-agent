
import Foundation
import CryptoKit

#if canImport(CloudKit) && !os(Linux)
import CloudKit
import OSLog
// Blueprint: | `CloudKitDeviceTransport.swift` | `CloudKitDeviceTransport`: checked account, push and cursor ownership |

let devicePushLog = Logger(subsystem: "NativeAgent.DeviceSync", category: "subscription")

enum DeviceCloudKitSubscriptionID {
    static let chat = "NAChatMessage.incoming"
    static let visibleNotifications = "NANotification.visible"
    static let pairing = "NAPairingDevice.changes"
    static let status = "NAStatus.changes"

    static let current = [chat, visibleNotifications, pairing, status]
    static func recognizes(_ id: String) -> Bool {
        current.contains(id)
    }
}

/// CloudKit completion or cancellation settles the call; failures retain their original cause.
func withDeviceCKOperation<T: Sendable>(
    _ label: String,
    onFailure: (@Sendable (Error) async -> Void)? = nil,
    beforeDispatch: @Sendable () async throws -> Void = {},
    _ work: @Sendable @escaping () async throws -> T
) async throws -> T {
    try Task.checkCancellation()
    try await beforeDispatch()
    do { return try await work() }
    catch {
        await onFailure?(error)
        nativeLog("[ck-device] \(label) failed: \(error)")
        throw error
    }
}

/// Thread-safe accumulator for the retention sweep's recordMatchedBlock. Holds record NAMES (not `CKRecord.ID`s) so the page crosses the continuation
/// as a plain Sendable value; the delete op rebuilds the ids in the default zone, which is the zone every send writes into.
final class DeviceCKRecordNameHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    // Backlog means a full fetched page, regardless of how many records expired.
    private var fetched = 0
    private var failure: Error?
    func noteFetched() { lock.lock(); fetched += 1; lock.unlock() }
    func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if failure == nil { failure = error }
    }
    func snapshot() throws -> (names: [String], fetched: Int) {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        return (names, fetched)
    }
}

/// One oldest-page retention query. Confirmed deletions advance the next sweep; no server traversal cursor is retained or resumed.
struct DeviceCKSweepPage: Sendable {
    let names: [String]
    let fetched: Int
}

/// One record family's confirmed deletions and remaining backlog.
struct DeviceCKSweepOutcome {
    var deleted = 0
    var backlog = false
}

/// Thread-safe per-page accumulator for pull's recordMatchedBlock. The CK callback runs on CloudKit's own queue, so the holder locks its own appends.
final class DeviceCKPullPageHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [NAChatMessageFields] = []
    private var modificationDates: [String: Date?] = [:]
    private var firstError: Error?
    private var payloadError: DeviceSyncError?
    func add(_ r: NAChatMessageFields) { lock.lock(); items.append(r); lock.unlock() }
    func noteModificationDate(_ id: String, _ date: Date?) {
        lock.lock(); modificationDates.updateValue(date, forKey: id); lock.unlock()
    }
    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if firstError == nil { firstError = error }
    }
    func failPayload(_ error: DeviceSyncError) {
        lock.lock(); defer { lock.unlock() }
        if payloadError == nil { payloadError = error }
    }
    func snapshot() throws -> (records: [(fields: NAChatMessageFields, modDate: Date?)], payloadError: DeviceSyncError?, modificationDates: [Date?]) {
        lock.lock(); defer { lock.unlock() }
        if let firstError { throw firstError }
        return (items.map { ($0, modificationDates[$0.recordName] ?? nil) }, payloadError, Array(modificationDates.values))
    }
}

struct DeviceCKPullResult: Sendable {
    var records: [(fields: NAChatMessageFields, modDate: Date?)] = []
    var payloadError: DeviceSyncError?
}

// MARK: - CloudKitDeviceTransport

/// CloudKit-backed device transport. `@unchecked Sendable` with an internal NSLock for mutable state (handlers + last-pull cursor + seen ids).
public final class CloudKitDeviceTransport: @unchecked Sendable {
    public let role: NADeviceRole
    public let containerIdentifier: String

    let lock = NSLock()
    private var incomingHandler: (@Sendable (BridgeMessage) async -> Bool)?
    var controlAdmission: (@Sendable (BridgeMessage) async -> Bool)?
    var controlDrainInFlight = false
    private var pairingHandler: (@Sendable (Data) async -> Bool)?
    var statusWrites: [String: Task<Void, Never>] = [:]
    var pendingStatusWrites: [String: (work: @Sendable () async throws -> Void, completion: CheckedContinuation<Void, Error>)] = [:]
    private var statusHandlers: [String: DeviceStatusObserver] = [:]
    private var lastPullDate: Date?
    private var lastPullCursorPersistenceAt: Date?
    // One drain owns claims and cursor advancement; event callers queue another pass, while periodic callers can skip a busy slot without extending
    // it.
    var drainInFlight = false
    var drainAgain = false
    // Status delivery is serialized so an older handler cannot overwrite a newer value.
    var statusDrainInFlight = false
    var statusDrainAgain = false
    // LWW/dedup cursors per (pairing, peer role, key). We only re-dispatch when the server modificationDate advances, so a redraw triggered by a
    // redundant push does not re-fire the same value.
    private var lastStatusModDates: [String: Date] = [:]
    // Retention cadence is in-memory; a relaunch permits another sweep.
    var lastRetentionSweepAt: Date?
    // A full query page signals backlog and shortens the next sweep interval.
    var retentionBacklog = false
    private var seenMessageIDs: Set<String> = []
    private var seenMessageIDsOrdered: [String] = []
    private let seenMessageIDsCap = 2000
    private var accountFailureHandler: (@Sendable (DeviceSyncAccountFailure) async -> Void)?
    private var assetSecretProvider: (@Sendable () async -> Data?)?
    // A Mac may access phone records only after proving it holds the account's Mac pairing slot; an unread claim grants no access.
    var pairingClaim: PairingClaim = .unread
    // Counts this transport's own pairing publications, so a claim whose read began before one of them cannot undo it.
    var pairingPublications: UInt64 = 0

    public func useAssetSecret(_ provider: @escaping @Sendable () async -> Data?) {
        lock.lock(); defer { lock.unlock() }
        assetSecretProvider = provider
    }

    func loadAssetSecretProvider() -> (@Sendable () async -> Data?)? {
        lock.lock(); defer { lock.unlock() }
        return assetSecretProvider
    }

    static func assetContext(recordName: String, direction: String) -> Data {
        Data("NativeAgent.chat.asset.v1:\(recordName):\(direction)".utf8)
    }

    static func assetKey(_ secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data("NativeAgent.chat.asset.v1".utf8), info: Data("aes-256-gcm".utf8), outputByteCount: 32)
    }

    static func payload(in record: CKRecord, secret: Data?) throws -> String {
        if let asset = record["payloadAsset"] as? CKAsset {
            guard let url = asset.fileURL, let secret,
                  secret.count == 32,
                  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= NAChatMessageCodec.maxAssetPayloadBytes + 64 else {
                throw DeviceSyncError.underlying(message: "The encrypted chat attachment is unavailable. Check pairing and retry delivery.")
            }
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
            let bytes = try AES.GCM.open(box, using: assetKey(secret),
                authenticating: assetContext(recordName: record.recordID.recordName, direction: (record["direction"] as? String) ?? ""))
            guard bytes.count <= NAChatMessageCodec.maxAssetPayloadBytes,
                  let text = String(data: bytes, encoding: .utf8) else {
                throw DeviceSyncError.underlying(message: "The encrypted chat attachment is malformed.")
            }
            return text
        }
        guard let text = record["payloadJSON"] as? String, !text.isEmpty else {
            throw DeviceSyncError.underlying(message: "The chat payload is missing.")
        }
        return text
    }

    public func observeAccountFailures(_ handler: @escaping @Sendable (DeviceSyncAccountFailure) async -> Void) {
        lock.lock(); defer { lock.unlock() }
        accountFailureHandler = handler
    }

    private func loadAccountFailureHandler() -> (@Sendable (DeviceSyncAccountFailure) async -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return accountFailureHandler
    }

    private func reportAccountFailure(_ error: Error) async {
        guard case .account(let failure) = Self.mapError(error) else { return }
        await loadAccountFailureHandler()?(failure)
    }

    var accountFailureReporter: @Sendable (Error) async -> Void {
        { error in await self.reportAccountFailure(error) }
    }

    fileprivate init(
        role: NADeviceRole,
        containerIdentifier: String
    ) {
        self.role = role
        self.containerIdentifier = containerIdentifier
        // Restore the role/container cursor so restarts cannot replay messages beyond the seen-set cap.
        if let ts = UserDefaults.standard.object(forKey: Self.cursorKey(role: role, container: containerIdentifier)) as? Double {
            self.lastPullDate = Date(timeIntervalSince1970: ts)
            self.lastPullCursorPersistenceAt = Date()
        }
    }


    private static func cursorKey(role: NADeviceRole, container: String) -> String {
        "NADeviceSync.cursor.\(role.rawValue).\(container)"
    }

    /// Quiet successful pulls advance the in-memory high watermark on every drain, but do not need to dirty preferences on every repeated drain.
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

    /// Recognizes device-sync subscription pushes without constructing CKContainer.
    public static func isDeviceSyncNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo),
              let subID = note.subscriptionID else { return false }
        return DeviceCloudKitSubscriptionID.recognizes(subID)
    }

    /// A pairing push may mean another Mac took or released the phone.
    public static func isPairingNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let subID = CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID else { return false }
        return subID == DeviceCloudKitSubscriptionID.pairing || subID.hasPrefix("NAPairingDevice.")
    }

    public static func isChatNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == DeviceCloudKitSubscriptionID.chat
    }

    public static func isStatusNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == DeviceCloudKitSubscriptionID.status
    }

    // The database is reached only after entitlement preflight.
    var database: CKDatabase {
        CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    // MARK: account status

    public func accountStatus() async throws -> String {
        return try await withDeviceCKOperation("CloudKitDeviceTransport.accountStatus", onFailure: accountFailureReporter) {
            let s = try await CKContainer(identifier: self.containerIdentifier).accountStatus()
            switch s {
            case .available: return "available"
            case .noAccount: return "noAccount"
            case .restricted: return "restricted"
            case .temporarilyUnavailable: return "temporarilyUnavailable"
            case .couldNotDetermine: return "unknown"
            @unknown default: return "unknown"
            }
        }
    }

    // MARK: helpers

    // MARK: locked state accessors (synchronous — never call lock from an async
    // context; scoped critical sections only, matching MemoryV2+CloudKit).

    func setIncomingHandler(_ h: @escaping @Sendable (BridgeMessage) async -> Bool) {
        lock.lock(); incomingHandler = h; lock.unlock()
    }

    func setPairingHandler(_ h: @escaping @Sendable (Data) async -> Bool) {
        lock.lock(); pairingHandler = h; lock.unlock()
    }

    func setStatusHandler(key: String, _ h: DeviceStatusObserver) {
        lock.lock(); statusHandlers[key] = h; lock.unlock()
    }

    func loadPairingHandler() -> (@Sendable (Data) async -> Bool)? {
        lock.lock(); defer { lock.unlock() }
        return pairingHandler
    }

    /// Snapshot handlers before awaiting them so no lock spans suspension.
    func loadStatusHandlers() -> [String: DeviceStatusObserver] {
        lock.lock(); defer { lock.unlock() }
        return statusHandlers
    }

    /// Per-key LWW freshness check for status singletons. It does NOT consume the record: `commitStatusDate` is what marks it seen, and only a
    /// handler that applied it may call that.
    func statusIsNewer(key: String, _ modDate: Date?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let modDate, let last = lastStatusModDates[key] {
            return modDate > last
        }
        return true
    }

    func commitStatusDate(key: String, _ modDate: Date?) {
        guard let modDate else { return }
        lock.lock()
        if let last = lastStatusModDates[key] {
            if modDate > last { lastStatusModDates[key] = modDate }
        } else {
            lastStatusModDates[key] = modDate
        }
        lock.unlock()
    }

    func loadHandlerAndCursor() -> ((@Sendable (BridgeMessage) async -> Bool)?, Date?) {
        lock.lock(); defer { lock.unlock() }
        return (incomingHandler, lastPullDate)
    }

    func setLastPullDate(_ date: Date, persistImmediately: Bool) {
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
        // Cursor persistence is thread-safe; its role and container key components are immutable.
        UserDefaults.standard.set(date.timeIntervalSince1970,
                                  forKey: Self.cursorKey(role: role, container: containerIdentifier))
    }

    /// Transport acknowledgement applies to these bytes, never to an unauthenticated message identity. A corrected record remains eligible.
    static func deliveryClaimKey(_ fields: NAChatMessageFields) -> String {
        let digest = SHA256.hash(data: Data(fields.payloadJSON.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return fields.recordName + ":" + digest
    }

    /// Atomic check-and-claim: inserts `id` into the seen set and returns true iff it was newly claimed. Prevents two concurrent drains from both
    /// delivering the same message id (the check + insert are one locked op).
    func isSeen(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seenMessageIDs.contains(id)
    }

    func claimIfUnseen(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return claimWhileLocked(id)
    }

    func claimForSerialDrain(_ id: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard !controlDrainInFlight else { return nil }
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

    /// Release a claim taken by `claimIfUnseen` when delivery is rejected, so the message is retried on the next drain.
    func releaseClaim(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard seenMessageIDs.remove(id) != nil else { return }
        if let i = seenMessageIDsOrdered.lastIndex(of: id) {
            seenMessageIDsOrdered.remove(at: i)
        }
    }

    static func data(fromHex hex: String) -> Data? {
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

    func performModifyRecords(_ op: CKModifyRecordsOperation) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                op.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let err): cont.resume(throwing: Self.mapError(err))
                    }
                }
                self.database.add(op)
                if Task.isCancelled { op.cancel() }
            }
        } onCancel: { op.cancel() }
    }

    static func mapError(_ err: Error) -> DeviceSyncError {
        if let error = err as? DeviceSyncError { return error }
        if let failure = accountFailure(in: err) { return .account(failure) }
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

    private static func accountFailure(in error: Error) -> DeviceSyncAccountFailure? {
        guard let ck = error as? CKError else { return nil }
        switch ck.code {
        case .accountTemporarilyUnavailable, .notAuthenticated, .badContainer,
             .badDatabase, .missingEntitlement, .managedAccountRestricted, .permissionFailure:
            return DeviceSyncAccountFailure(code: ck.code.rawValue, detail: ck.localizedDescription)
        default:
            // A batch can wrap the actual account rejection in partialFailure.
            if let partial = ck.partialErrorsByItemID {
                for nested in partial.values {
                    if let failure = accountFailure(in: nested) { return failure }
                }
            }
            if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error {
                return accountFailure(in: underlying)
            }
            return nil
        }
    }
}

// MARK: - Entitled construction

public extension DeviceSyncTransportResolver {
    static func makeCloudKitTransport(
        role: NADeviceRole,
        containerIdentifier: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hasEntitlement: () -> Bool = DeviceCloudKitPreflight.hasCloudKitEntitlement,
        grantsContainer: (String) -> Bool = DeviceCloudKitPreflight.entitlementGrantsContainer
    ) throws -> CloudKitDeviceTransport {
        try requireCloudKitConfiguration(environment: environment)
        guard hasEntitlement() else {
            throw DeviceSyncTransportConstructionFailure.missingEntitlement
        }
        guard grantsContainer(containerIdentifier) else {
            throw DeviceSyncTransportConstructionFailure.missingContainer(containerIdentifier)
        }
        return CloudKitDeviceTransport(role: role, containerIdentifier: containerIdentifier)
    }
}

/// Sendable results of pairing and status reads.
enum PairingSlot: Sendable { case empty, holds(Data) }
/// Where a Mac stands on the account's Mac pairing record.
enum PairingClaim: Sendable { case unread, held, elsewhere }
struct PeerStatusHit: Sendable { let value: String; let modDate: Date? }
struct DeviceStatusObserver: Sendable {
    let pairingSecret: @Sendable () async -> Data?
    let apply: @Sendable (String, Date?, Data, DeviceSyncRecovery) async -> Bool
}

#endif
