
import Synchronization
import Foundation
import CryptoKit
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
final class DeviceCKRecordNameHolder: Sendable {
    private struct State {
        var names: [String] = []
        var fetched = 0
        var failure: Error?
    }
    private let state = Mutex(State())
    // Backlog means a full fetched page, regardless of how many records expired.
    func noteFetched() { state.withLock { $0.fetched += 1 } }
    func add(_ name: String) { state.withLock { $0.names.append(name) } }
    func fail(_ error: Error) {
        state.withLock { state in
            if state.failure == nil { state.failure = error }
        }
    }
    func snapshot() throws -> (names: [String], fetched: Int) {
        return try state.withLock { state in
            if let error = state.failure { throw error }
            return (state.names, state.fetched)
        }
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
final class DeviceCKPullPageHolder: Sendable {
    private struct State {
        var items: [NAChatMessageFields] = []
        var modificationDates: [String: Date?] = [:]
        var firstError: Error?
        var payloadError: DeviceSyncError?
    }
    private let state = Mutex(State())
    func add(_ r: NAChatMessageFields) { state.withLock { $0.items.append(r) } }
    func noteModificationDate(_ id: String, _ date: Date?) {
        state.withLock { _ = $0.modificationDates.updateValue(date, forKey: id) }
    }
    func fail(_ error: Error) {
        state.withLock { state in
            if state.firstError == nil { state.firstError = error }
        }
    }
    func failPayload(_ error: DeviceSyncError) {
        state.withLock { state in
            if state.payloadError == nil { state.payloadError = error }
        }
    }
    func snapshot() throws -> (records: [(fields: NAChatMessageFields, modDate: Date?)], payloadError: DeviceSyncError?, modificationDates: [Date?]) {
        return try state.withLock { state in
            if let error = state.firstError { throw error }
            return (state.items.map { ($0, state.modificationDates[$0.recordName] ?? nil) }, state.payloadError, Array(state.modificationDates.values))
        }
    }
}

struct DeviceCKPullResult: Sendable {
    var records: [(fields: NAChatMessageFields, modDate: Date?)] = []
    var payloadError: DeviceSyncError?
}

// MARK: - CloudKitDeviceTransport

public final class CloudKitDeviceTransport: Sendable {
    public let role: NADeviceRole
    public let containerIdentifier: String

    struct State {
        var incomingHandler: (@Sendable (BridgeMessage) async -> Bool)?
        var controlAdmission: (@Sendable (BridgeMessage) async -> Bool)?
        var controlDrainInFlight = false
        var pairingHandler: (@Sendable (Data, Date?) async -> Bool)?
        var statusWrites: [String: Task<Void, Never>] = [:]
        var pendingStatusWrites: [String: (work: @Sendable () async throws -> Void, completion: CheckedContinuation<Void, Error>)] = [:]
        var statusHandlers: [String: DeviceStatusObserver] = [:]
        var lastPullDate: Date?
        var lastPullCursorPersistenceAt: Date?
        var drainInFlight = false
        var drainAgain = false
        var statusDrainInFlight = false
        var statusDrainAgain = false
        var statusAcknowledgements: [String: (date: Date, changeTag: String?)] = [:]
        var lastRetentionSweepAt: Date?
        var retentionBacklog = false
        var seenMessageIDs: Set<String> = []
        var seenMessageIDsOrdered: [String] = []
        var bellEntries: [DeviceBellEntry] = []
        var accountFailureHandler: (@Sendable (DeviceSyncAccountFailure) async -> Void)?
        var assetSecretProvider: (@Sendable () async -> Data?)?
        var pairingClaim: PairingClaim = .unread
        var pairingPublications: UInt64 = 0
    }
    let state = Mutex(State())
    private let seenMessageIDsCap = 2000

    public func useAssetSecret(_ provider: @escaping @Sendable () async -> Data?) {
        state.withLock { state in
            state.assetSecretProvider = provider
        }
    }

    func loadAssetSecretProvider() -> (@Sendable () async -> Data?)? {
        return state.withLock { $0.assetSecretProvider }
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
        state.withLock { state in
            state.accountFailureHandler = handler
        }
    }

    private func loadAccountFailureHandler() -> (@Sendable (DeviceSyncAccountFailure) async -> Void)? {
        return state.withLock { $0.accountFailureHandler }
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
            state.withLock {
                $0.lastPullDate = Date(timeIntervalSince1970: ts)
                $0.lastPullCursorPersistenceAt = Date()
            }
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

    // MARK: helpers

    // MARK: locked state accessors (synchronous — never call lock from an async
    // context; scoped critical sections only, matching MemoryV2+CloudKit).

    func setIncomingHandler(_ h: @escaping @Sendable (BridgeMessage) async -> Bool) {
        state.withLock { $0.incomingHandler = h }
    }

    func setPairingHandler(_ h: @escaping @Sendable (Data, Date?) async -> Bool) {
        state.withLock { $0.pairingHandler = h }
    }

    func setStatusHandler(key: String, _ h: DeviceStatusObserver) {
        state.withLock { $0.statusHandlers[key] = h }
    }

    func loadPairingHandler() -> (@Sendable (Data, Date?) async -> Bool)? {
        return state.withLock { $0.pairingHandler }
    }

    /// Snapshot handlers before awaiting them so no lock spans suspension.
    func loadStatusHandlers() -> [String: DeviceStatusObserver] {
        return state.withLock { $0.statusHandlers }
    }

    func statusAcknowledgement(for recordName: String) -> (date: Date, changeTag: String?)? {
        state.withLock { $0.statusAcknowledgements[recordName] }
    }

    func acknowledgeStatus(_ record: CKRecord) {
        guard let date = record.modificationDate else { return }
        let name = record.recordID.recordName
        let changeTag = record.recordChangeTag
        state.withLock { state in
            if let last = state.statusAcknowledgements[name], date < last.date { return }
            state.statusAcknowledgements[name] = (date, changeTag)
        }
    }

    func loadHandlerAndCursor() -> ((@Sendable (BridgeMessage) async -> Bool)?, Date?) {
        return state.withLock { ($0.incomingHandler, $0.lastPullDate) }
    }

    /// Records the reader can never verify are not read at all: the phone raises its cursor to the publication of the Mac's current key (less
    /// the clock-skew overlap), since anything older was signed with an earlier key.
    public func raisePullCursor(toAtLeast date: Date) {
        let floor = date.addingTimeInterval(-Self.pullOverlap)
        let behind = state.withLock { $0.lastPullDate.map { $0 < floor } ?? true }
        guard behind else { return }
        nativeLog("[ck-device] pull cursor raised to the current key's publication %@", "\(floor)")
        setLastPullDate(floor, persistImmediately: true)
    }

    func setLastPullDate(_ date: Date, persistImmediately: Bool) {
        let shouldPersist = state.withLock { state in
            // The cursor only moves forward: a drain that began before a raise cannot pull it back.
            guard state.lastPullDate.map({ date > $0 }) ?? true else { return false }
            state.lastPullDate = date
            let now = Date()
            let persist = Self.shouldPersistPullCursor(
                immediately: persistImmediately,
                lastPersistenceAt: state.lastPullCursorPersistenceAt,
                now: now
            )
            if persist { state.lastPullCursorPersistenceAt = now }
            return persist
        }
        guard shouldPersist else { return }
        // Cursor persistence is thread-safe; its role and container key components are immutable.
        UserDefaults.standard.set(date.timeIntervalSince1970,
                                  forKey: Self.cursorKey(role: role, container: containerIdentifier))
    }

    /// Transport acknowledgement applies to these bytes, never to an unauthenticated message identity. A corrected record remains eligible.
    static func deliveryClaimKey(_ fields: NAChatMessageFields) -> String {
        let digest = SHA256Hex.of(utf8: fields.payloadJSON)
        return fields.recordName + ":" + digest
    }

    /// Atomic check-and-claim: inserts `id` into the seen set and returns true iff it was newly claimed. Prevents two concurrent drains from both
    /// delivering the same message id (the check + insert are one locked op).
    func isSeen(_ id: String) -> Bool {
        return state.withLock { $0.seenMessageIDs.contains(id) }
    }

    func claimIfUnseen(_ id: String) -> Bool {
        return state.withLock { claimWhileLocked(id, state: &$0) }
    }

    func claimForSerialDrain(_ id: String) -> Bool? {
        return state.withLock { state in
            guard !state.controlDrainInFlight else { return nil }
            return claimWhileLocked(id, state: &state)
        }
    }

    private func claimWhileLocked(_ id: String, state: inout State) -> Bool {
        guard !state.seenMessageIDs.contains(id) else { return false }
        state.seenMessageIDs.insert(id)
        state.seenMessageIDsOrdered.append(id)
        while state.seenMessageIDsOrdered.count > seenMessageIDsCap {
            let oldest = state.seenMessageIDsOrdered.removeFirst()
            state.seenMessageIDs.remove(oldest)
        }
        return true
    }

    /// The names among `names` whose record no delivery has claimed. A claim is keyed by name and payload digest; the bell knows names only.
    func unclaimedRecordNames(_ names: [String]) -> [String] {
        return state.withLock { state in
            let claimed = Set(state.seenMessageIDs.compactMap { id in id.lastIndex(of: ":").map { String(id[..<$0]) } })
            return names.filter { !claimed.contains($0) }
        }
    }

    /// Release a claim taken by `claimIfUnseen` when delivery is rejected, so the message is retried on the next drain.
    func releaseClaim(_ id: String) {
        state.withLock { state in
            guard state.seenMessageIDs.remove(id) != nil else { return }
            if let i = state.seenMessageIDsOrdered.lastIndex(of: id) {
                state.seenMessageIDsOrdered.remove(at: i)
            }
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

enum PairingSlot: Sendable { case empty, holds(Data) }
/// Where a Mac stands on the account's Mac pairing record.
enum PairingClaim: Sendable { case unread, held, elsewhere }
/// One sent record on a bell, with when its sender saw it saved (the sender's clock).
struct DeviceBellEntry: Codable, Sendable { let name: String; let sentAt: Date }
struct DeviceStatusObserver: Sendable {
    let pairingSecret: @Sendable () async -> Data?
    let apply: @Sendable (String, Date?, Data, DeviceSyncRecovery) async -> Bool
}
