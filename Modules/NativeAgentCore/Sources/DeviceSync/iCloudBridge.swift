import Foundation
import CryptoKit
import AppKit
import Cognition
import Combine
import NativeAgentShared
import DeviceSyncState
import NativeAgentCore
import ChatTurnRuntime
import PersistenceCore
import ProviderRouting
import OSLog
// Blueprint: | `iCloudBridge.swift` | Canonical chat ledger; push/lifecycle receives never select a timed alternate reader. |
typealias KVSKey = NativeAgentICloudBridgeConstants.KVSKey
typealias DriveFolder = NativeAgentICloudBridgeConstants.DriveFolder
/// Serial checks never suspend; cancellation can still run while delivery awaits a chat reply.
@MainActor
public final class iCloudBridge: ObservableObject {
    static let pushLog = Logger(subsystem: "NativeAgent.DeviceSync", category: "push")
    enum DrainTrigger: String {
        case cloudKitPush, kvsNudge, coalesced, repair, wake, network
    }
    unowned let sync: DeviceSync
    @Published public internal(set) var available: Bool = false
    @Published public internal(set) var lastSyncAt: Date?
    @Published public internal(set) var syncStatus: String = "iCloud not checked" {
        didSet {
            if accountFailure != nil, syncStatus != DeviceSyncAccountFailure.macMessage {
                syncStatus = DeviceSyncAccountFailure.macMessage
            } else if accountFailure == nil, phonePairedElsewhere, syncStatus != Self.pairedElsewhereStatus {
                syncStatus = Self.pairedElsewhereStatus
            }
        }
    }
    @Published public internal(set) var accountFailure: DeviceSyncAccountFailure? {
        didSet { refreshPhoneConnection() }
    }
    var accountFailureGeneration: UInt64 = 0
    var accountFailureReadError: String? { didSet { refreshPhoneConnection() } }
    /// Another Mac's pairing suppresses phone writes until the person explicitly moves it here.
    @Published public internal(set) var phonePairedElsewhere = false {
        didSet { refreshPhoneConnection() }
    }
    /// Read the account claim before publishing anything the phone could treat as this Mac's.
    var phonePairingSettled = false {
        didSet { refreshPhoneConnection() }
    }
    /// Connectors and Doctor must share the owners' pairing, transport and accepted-contact evidence.
    @Published public internal(set) var phoneConnection = NAPhoneConnection(
        pairing: .init(.waiting, "Checking this Mac's pairing."),
        transport: .init(.waiting, "iCloud is not checked yet."),
        exchange: .init(.waiting, "No message from your iPhone yet."))
    /// Every surface reads this one standing: connected once the phone has spoken over the shared key, able to approve once its device key is paired.
    @Published public internal(set) var phoneStanding = NAPhoneStanding(connected: nil, waiting: 0, approvers: 0)
    var transportRefusal: NAPhoneConnection.Fact? { didSet { refreshPhoneConnection() } }
    var pairingKeyUnreadable = false { didSet { refreshPhoneConnection() } }
    var lastPhoneContactAt: Date? { didSet { refreshPhoneConnection() } }
    var phoneContactReadFailure: String? { didSet { refreshPhoneConnection() } }
    var lastPhoneRejectedAt: Date? { didSet { refreshPhoneConnection() } }
    var pairedPhonesSubscription: AnyCancellable?
    var phonePairingRecheckDue = false
    var speaksToPhone: Bool { deviceTransport != nil && phonePairingSettled && !phonePairedElsewhere }
    nonisolated static let pairedElsewhereStatus =
        "Your iPhone is paired with another Mac (or an earlier install) on this Apple Account. Choose Use my iPhone with this Mac to move it here."
    /// A local key change stays owed until the account accepts it; per-root authority is not lost meanwhile.
    var pairingPublicationOwedKey: String {
        let root = SHA256.hash(data: Data(sync.dataRoot.standardizedFileURL.path.utf8))
        return "NativeAgent.pairing.cloudKitPublicationOwed.v1." + root.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    var driveURL: URL?
    var metadataQuery: NSMetadataQuery?
    var messageHandler: ((BridgeMessage, ICloudPhoneRoute) async -> Bool)?
    // Only the entitlement-checked resolver installs this CloudKit transport.
    var deviceTransport: CloudKitDeviceTransport?
    var doctorTransportHealth: ICloudBridgeHealthSnapshot.Health = .unmeasured {
        didSet { refreshPhoneConnection() }
    }
    var doctorSendFailures: [String: ICloudBridgeHealthSnapshot.Health] = [:] {
        didSet { refreshPhoneConnection() }
    }
    var doctorSendMeasured = false
    var onTransportSucceeded: (() -> Void)?
    public lazy var phoneRequests = MacPhoneRequestChannel(bridge: self)
    var usesCloudKitDeviceTransport: Bool {
        isSetUp && deviceTransport != nil
    }
    // Receive events coalesce; the transport owns message deduplication.
    var deviceDrainTask: Task<Bool, Never>?
    var deviceDrainGeneration: Int?
    var deviceDrainQueued = false
    var cloudKitPushProofAt: Date?
    var deviceDrainTriggeredByPush = false
    var cloudKitPushUnavailable = false
    var deviceMetadataDrainTask: Task<Void, Never>?
    var nextDeviceMetadataDrainAt = Date.distantPast
    var deviceNetworkChanges: Task<Void, Never>?
    // Retention has its own single-flight slot beside the delivery drain.
    var deviceRetentionSweepTask: Task<Void, Never>?
    /// Deterministic projection equality suppresses redundant CloudKit writes from repeated UI refreshes.
    var lastPublishedProviderCatalogStatus: (pairing: Data, value: String)?
    // Retain one read/send owner; queue fresh reads even when a caller returns to the cached selection mid-send.
    var providerCatalogPublicationTask: Task<Bool, Never>?
    var providerCatalogPublicationQueued = false
    var lastPublishedMobileSnapshotStatus: [NAMobileSnapshotGroup: (pairing: Data, value: String)] = [:]
    var seenMessageIDs: Set<String> = []
    var seenMessageIDsOrdered: [String] = []
    // Bound disk and memory by the same insertion order to prevent unbounded replay-set growth. Immutable Sendable limits are nonisolated for off-main
    // persistence.
    nonisolated static let seenMessageIDsCap = 2000
    var inFlightIncomingMessageIDs: Set<String> = []
    var inFlightReplyIDs: Set<String> = []
    var setupTask: Task<Void, Never>?
    // Lifecycle identity prevents a late container resolve from rearming a superseded setup.
    var setupGeneration: Int = 0
    /// The transport has no observer cancellation token, so gate its retained last-writer-wins callback by lifecycle.
    var incomingObserverGeneration: UInt64 = 0
    var incomingObserverTask: Task<Void, Never>?
    /// Controls remain owned here until their signed publication and receipt land. This also retains the original envelope while ledger storage is unavailable.
    var pendingControlPublications: [String: BridgeMessage] = [:]
    /// Fair selection among owed outcomes; never evidence about delivery.
    var controlPublicationCursor = ""
    var incomingObserverTaskID = UUID()
    var transportSetupTask: Task<Void, Never>?
    var transportSetupTaskID = UUID()
    var outboxScanTask: Task<Void, Never>?
    var outboxScanQueued = false
    /// Teardown closes backlog dispatch without cancelling accepted human turns; each owner still settles.
    var outboxBacklogTasks: [UUID: Task<Void, Never>] = [:]
    /// Retired scans cannot clear or replay work belonging to a newer lifecycle.
    var outboxScanGeneration: UInt64 = 0
    // Idempotent setup prevents stacked observers from delivering each KVS change multiple times.
    var isSetUp: Bool = false
    let incomingVerifier = ICloudIncomingVerifier()
    var deliveryNudgeQueue: ICloudDeliveryNudgeQueue?
    var messageNudgeSender: ICloudConflatedSender?
    init(sync: DeviceSync) {
        self.sync = sync
        let url = ICloudSyncStatePaths.accountFailure(dataRoot: sync.dataRoot)
        Task {
            let restored = await sync.storage.perform { () -> Result<DeviceSyncAccountFailure?, Error> in
                do {
                    return .success(try JSONDecoder().decode(DeviceSyncAccountFailure.self, from: Data(contentsOf: url)))
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    return .success(nil)
                } catch { return .failure(error) }
            }
            guard accountFailureGeneration == 0 else { return }
            switch restored {
            case .success(let failure):
                if let failure {
                    accountFailure = failure
                    syncStatus = DeviceSyncAccountFailure.macMessage
                }
            case .failure(let error):
                let message = """
                    Saved iCloud account status could not be read (\(error.localizedDescription)); restore access to icloud/account_failure.json and check \
                    Connection.
                    """
                accountFailureReadError = message
                syncStatus = message
                doctorTransportHealth = .unavailable(message)
            }
        }
        ICloudBridgeHealthReader.register(dataRoot: sync.dataRoot) { [weak self] in
            self?.doctorHealthSnapshot
        }
        PhoneConnectionReader.register(dataRoot: sync.dataRoot) { [weak self] in
            self?.phoneConnection
        }
    }
    private var doctorHealthSnapshot: ICloudBridgeHealthSnapshot? {
        guard isSetUp || setupTask != nil else { return nil }
        if usesCloudKitDeviceTransport {
            let health: ICloudBridgeHealthSnapshot.Health
            if let accountFailure {
                health = .accountFailure(code: accountFailure.code, detail: accountFailure.detail)
            } else {
                health = doctorTransportHealth
            }
            return .init(transport: .cloudKit, health: health,
                         sendMeasured: doctorSendMeasured, sendFailures: doctorSendFailures)
        }
        guard deviceTransport == nil else { return nil }
        return .init(
            transport: .iCloudDrive,
            health: doctorTransportHealth,
            documentsURL: driveURL
        )
    }
    static func transportHealth(_ error: Error) -> ICloudBridgeHealthSnapshot.Health {
        switch error as? DeviceSyncError {
        case .unauthorized: return .signedOut
        case .notConfigured: return .notEntitled
        case .quotaExceeded: return .quotaExceeded
        case .account(let failure): return .accountFailure(code: failure.code, detail: failure.detail)
        case .pairedElsewhere: return .pairedElsewhere
        default: return .unavailable(error.localizedDescription)
        }
    }
    func recordSendResult(operation: String, error: Error? = nil) async {
        // A pairing held elsewhere is one receive-health fact, not a new send failure on every refused write.
        if case .pairedElsewhere? = error as? DeviceSyncError { return }
        doctorSendMeasured = true
        // A transient no is its retry's to answer: unmeasured until the retry meets it too.
        let retrying = if case .transient? = error as? DeviceSyncError { doctorSendFailures[operation] == nil } else { false }
        doctorSendFailures[operation] = error.map { retrying ? .unmeasured : Self.transportHealth($0) }
        if let error, case .account(let failure) = error as? DeviceSyncError {
            await recordAccountFailure(failure)
        }
        if error == nil { onTransportSucceeded?() }
    }
    func recordSeenMessageID(_ id: String) {
        guard !seenMessageIDs.contains(id) else { return }
        seenMessageIDs.insert(id)
        seenMessageIDsOrdered.append(id)
        trimSeenMessageIDsIfNeeded()
    }
    func trimSeenMessageIDsIfNeeded() {
        while seenMessageIDsOrdered.count > Self.seenMessageIDsCap {
            let oldest = seenMessageIDsOrdered.removeFirst()
            seenMessageIDs.remove(oldest)
        }
    }
    // Synchronous MainActor persistence prevents replay inside CloudKit's 30-second repull window. CloudKit and Drive stores remain separate but restore into
    // the same insertion-ordered set.
    private static let ckProcessedIDsDefaultsKey = "NativeAgent.iCloud.ckProcessedIDs.v1"
    func persistCKSeenIDs() {
        ICloudSeenIDDefaultsStore.save(
            seenMessageIDsOrdered,
            defaults: .standard,
            key: Self.ckProcessedIDsDefaultsKey,
            cap: Self.seenMessageIDsCap
        )
    }
    @discardableResult
    func loadCKSeenIDs() -> Bool {
        let ckIDs: [String]
        do {
            ckIDs = try ICloudSeenIDDefaultsStore.load(defaults: .standard,
                key: Self.ckProcessedIDsDefaultsKey, cap: Self.seenMessageIDsCap)
        } catch {
            available = false
            syncStatus = """
                The phone message replay window could not be read. Restore NativeAgent.iCloud.ckProcessedIDs.v1 in this app's preferences, then reconnect \
                the phone.
                """
            doctorTransportHealth = .unavailable(syncStatus)
            return false
        }
        for id in ckIDs where seenMessageIDs.insert(id).inserted {
            seenMessageIDsOrdered.append(id)
        }
        trimSeenMessageIDsIfNeeded()
        return true
    }
    @objc nonisolated func kvsDidChange(_ note: Notification) {
        let changedKeys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        Task { @MainActor in
            guard self.isSetUp else { return }
            let messageChanged = changedKeys == nil
                || changedKeys?.contains(KVSKey.newMessageInDrive) == true
            if messageChanged {
                if self.deviceTransport != nil {
                    _ = await self.drainDeviceTransport(trigger: .kvsNudge)
                } else {
                    self.syncStatus = "KVS trigger received — checking Drive…"
                    self.checkIosOutbox()
                }
            }
        }
    }
    public func tearDown() {
        // Close request admission before settling waiters or draining sends.
        isSetUp = false
        phoneRequests.stop()
        // Invalidate in-flight resolution before teardown so a late result cannot rearm observers.
        setupTask?.cancel()
        setupTask = nil
        setupGeneration += 1
        incomingObserverGeneration &+= 1
        incomingObserverTask?.cancel()
        transportSetupTask?.cancel()
        outboxScanGeneration &+= 1
        outboxScanTask?.cancel()
        // Retain the scanner slot until physical file work exits; backlog owners settle before lifecycle retirement.
        outboxScanQueued = false
        metadataQuery?.stop()
        metadataQuery = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        deviceNetworkChanges?.cancel()
        deviceNetworkChanges = nil
        deviceMetadataDrainTask?.cancel()
        nextDeviceMetadataDrainAt = .distantPast
        cloudKitPushProofAt = nil
        cloudKitPushUnavailable = false
        messageHandler = nil
        deviceTransport = nil
        phonePairingSettled = false
        phonePairedElsewhere = false
        phonePairingRecheckDue = false
        lastPublishedProviderCatalogStatus = nil
        // Keep send ownership through actual exit so new setup cannot overlap an earlier lifecycle's publication.
        providerCatalogPublicationQueued = false
        lastPublishedMobileSnapshotStatus = [:]
        // The drain and retention handles keep exclusion until actual exit.
        deviceDrainQueued = false
        deviceRetentionSweepTask?.cancel()
        if let deliveryNudgeQueue {
            Task { await deliveryNudgeQueue.cancelAll() }
            self.deliveryNudgeQueue = nil
        }
        if let sender = messageNudgeSender {
            sender.close()
            Task { await sender.finish() }
            messageNudgeSender = nil
        }
        // Clear setup ownership so teardown cannot leave all future setup calls permanently refused.
        isSetUp = false
        sync.engine.stop()
    }
}
