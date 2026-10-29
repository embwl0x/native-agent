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
import Network
// Blueprint: | `iCloudBridge.swift` | Owns ChatRecord admission, reply binding, recovery, durable mutation and terminal retention interpretation for icloud/chat_transactions; rejected CloudKit envelopes have no local journal/quarantine copy. `setup`, `recordCloudKitPushEvidence` (data-root-scoped chat-subscription push proof persisted across launches; subscription failure or unannounced aged delivery revokes), `scheduleNextDeviceDrainFallback` (obligations or push unavailable/unproven; idle rests), `cloudKitActionResponseMessage` (sending and sizing), `failedReplyClaims` (startup snapshot or exact delivery event) |
// BridgeMessage, BridgeError, and all HMAC helpers are now in NativeAgentShared.
typealias KVSKey = NativeAgentICloudBridgeConstants.KVSKey
typealias DriveFolder = NativeAgentICloudBridgeConstants.DriveFolder
/// One serial authentication owner per bridge. No suspension inside a check;
/// cancellation checks can still run while delivery awaits a chat's reply.
@MainActor
public final class iCloudBridge: ObservableObject {
    static let pushLog = Logger(subsystem: "NativeAgent.DeviceSync", category: "push")
    enum DrainTrigger: String {
        case fallbackTimer, cloudKitPush, legacyKVS, coalesced, repair, wake, network
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
    /// Another Mac on this Apple Account holds the phone's pairing; this Mac
    /// stays quiet toward the phone until the person moves it here.
    @Published public internal(set) var phonePairedElsewhere = false {
        didSet { refreshPhoneConnection() }
    }
    /// Whether this Mac has read its claim on the account's pairing since
    /// setup. Until it has, it writes nothing the phone reads as the Mac's.
    var phonePairingSettled = false {
        didSet { refreshPhoneConnection() }
    }
    /// The phone's connection as this Mac knows it: pairing, transport and the
    /// last accepted exchange, each with its owner. Connectors › iPhone and
    /// Doctor say where the connection stands through this one value.
    @Published public internal(set) var phoneConnection = NAPhoneConnection(
        pairing: .init(.waiting, "Checking this Mac's pairing."),
        transport: .init(.waiting, "iCloud is not checked yet."),
        exchange: .init(.waiting, "No message from your iPhone yet."))
    /// Why this build has no CloudKit transport, when it was meant to.
    var transportRefusal: NAPhoneConnection.Fact? { didSet { refreshPhoneConnection() } }
    var pairingKeyUnreadable = false { didSet { refreshPhoneConnection() } }
    /// When the phone was last there, from a message this Mac accepted.
    var lastPhoneContactAt: Date? { didSet { refreshPhoneConnection() } }
    /// When this Mac last turned away a phone message signed with another key.
    var lastPhoneRejectedAt: Date? { didSet { refreshPhoneConnection() } }
    var pairedPhonesSubscription: AnyCancellable?
    var phonePairingRecheckDue = false
    /// This Mac speaks to the phone: it holds the account's pairing.
    var speaksToPhone: Bool { deviceTransport != nil && phonePairingSettled && !phonePairedElsewhere }
    nonisolated static let pairedElsewhereStatus =
        "Your iPhone is paired with another Mac (or an earlier install) on this Apple Account. Choose Use my iPhone with this Mac to move it here."
    /// This install changed its key and the account's pairing record has not
    /// taken it yet: owed, not lost. Per data root, like the key itself.
    var pairingPublicationOwedKey: String {
        let root = SHA256.hash(data: Data(sync.dataRoot.standardizedFileURL.path.utf8))
        return "NativeAgent.pairing.cloudKitPublicationOwed.v1." + root.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    var driveURL: URL?
    var metadataQuery: NSMetadataQuery?
    var messageHandler: ((BridgeMessage) async -> Bool)?
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
    // Push/receive deadlines coalesce; the transport owns message deduplication.
    var deviceDrainTask: Task<Bool, Never>?
    var deviceDrainGeneration: Int?
    var activeCloudKitChats = 0
    var deviceDrainQueued = false
    var deviceDrainTimerTask: Task<Void, Never>?
    var cloudKitPushProofAt: Date?
    var cloudKitPushProven: Bool { cloudKitPushProofAt != nil }
    var deviceDrainTriggeredByPush = false
    var cloudKitPushUnavailable = false
    var deviceDrainCadence: TimeInterval?
    var deviceNetworkMonitor: NWPathMonitor?
    var deviceNetworkSatisfied: Bool?
    // Retention has its own single-flight slot beside the delivery drain.
    var deviceRetentionSweepTask: Task<Void, Never>?
    /// Owns the receive deadline while delivery needs one.
    var drainPolicy = AdaptiveDrainPolicy()
    var lastDeviceDrainAt = Date.distantPast
    /// Last successfully published deterministic provider projection. Repeated
    /// UI refreshes often discover identical state; skip those CloudKit writes.
    var lastPublishedProviderCatalogStatus: String?
    // One owner spans the read and send. Callers join it and queue a fresh read,
    // including a return to the cached selection while a different send awaits.
    var providerCatalogPublicationTask: Task<Bool, Never>?
    var providerCatalogPublicationQueued = false
    var lastPublishedMobileSnapshotStatus: [NAMobileSnapshotGroup: String] = [:]
    // Insertion-ordered message identities remain bounded across launches.
    var seenMessageIDs: Set<String> = []
    var seenMessageIDsOrdered: [String] = []
    // N-mem fix: the on-disk processed-ids file is capped at `seenMessageIDsCap`
    // via .suffix() but the in-memory Set only ever .insert()d → unbounded
    // memory growth over a long-running session. Cap memory the same way so
    // memory and disk stay consistent (both insertion-ordered, oldest evicted).
    // nonisolated: an immutable Sendable constant read by the nonisolated static
    // saveProcessedMessageIDs off-main helper; no actor isolation needed.
    nonisolated static let seenMessageIDsCap = 2000
    var inFlightIncomingMessageIDs: Set<String> = []
    var inFlightReplyIDs: Set<String> = []
    var setupTask: Task<Void, Never>?
    // Monotonic token: bumped on every setup()/tearDown() so a stale off-main
    // container resolve that completes late can't re-register observers / start
    // the query for a superseded setup (it checks generation before applying).
    var setupGeneration: Int = 0
    /// CloudKitDeviceTransport currently has last-registration-wins observation but
    /// no cancellation token. Keep the callback itself lifecycle-gated so a
    /// retained transport cannot route work after this bridge has torn down.
    var incomingObserverGeneration: UInt64 = 0
    var incomingObserverTask: Task<Void, Never>?
    var incomingObserverTaskID = UUID()
    var transportSetupTask: Task<Void, Never>?
    var transportSetupTaskID = UUID()
    var incomingObserverInstalled = false
    var outboxScanTask: Task<Void, Never>?
    var outboxScanQueued = false
    /// Each admitted Drive backlog owns its settlement; teardown closes its
    /// next dispatch without cancelling the human turn already underway.
    var outboxBacklogTasks: [UUID: Task<Void, Never>] = [:]
    /// Makes a cancelled/retired detached scan unable to clear or replay work
    /// belonging to a newer bridge lifecycle.
    var outboxScanGeneration: UInt64 = 0
    // N10 fix: idempotency guard — track whether setup() has already run so
    // repeat calls don't stack additional KVS observers (each call added a
    // new addObserver which fired the handler multiple times per external change).
    var isSetUp: Bool = false
    let incomingVerifier = ICloudIncomingVerifier()
    var deliveryNudgeQueue: ICloudDeliveryNudgeQueue?
    var messageNudgeSender: ICloudConflatedSender?
    // Drive folder layout
    // <container>/Documents/outbox/mac/   — Mac writes here
    // <container>/Documents/outbox/ios/   — iOS writes here
    // <container>/Documents/processing/   — Mac claimed but has not acked yet
    // <container>/Documents/processed/    — read messages moved here (archive)
    init(sync: DeviceSync) {
        self.sync = sync
        let url = ICloudSyncStatePaths.accountFailure(dataRoot: sync.dataRoot)
        Task {
            let failure = await sync.storage.perform {
                try? JSONDecoder().decode(DeviceSyncAccountFailure.self, from: Data(contentsOf: url))
            }
            guard accountFailureGeneration == 0, let failure else { return }
            accountFailure = failure
            syncStatus = DeviceSyncAccountFailure.macMessage
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
        // A Mac whose phone is paired elsewhere says so once, as its receive
        // health; each refused write is that same fact, not a send failure.
        if case .pairedElsewhere? = error as? DeviceSyncError { return }
        doctorSendMeasured = true
        doctorSendFailures[operation] = error.map(Self.transportHealth)
        if let error, case .account(let failure) = error as? DeviceSyncError {
            await recordAccountFailure(failure)
        }
        if error == nil { onTransportSucceeded?() }
    }
    // Bound seen message IDs by insertion order, evicting the oldest first.
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
    // CK-3c: CK-consumed ids persist to UserDefaults — synchronous, ordered on
    // the main actor, atomic — so a restart within the transport cursor's 30s
    // re-pull window doesn't re-deliver a CK message. Separate key from the Drive
    // path's file store; both feed the unified in-memory seen-set on setup.
    // Mirrors the iOS bridge (which already persists its seen-set to UserDefaults).
    private static let ckProcessedIDsDefaultsKey = "NativeAgent.iCloud.ckProcessedIDs.v1"
    func persistCKSeenIDs() {
        ICloudSeenIDDefaultsStore.save(
            seenMessageIDsOrdered,
            defaults: .standard,
            key: Self.ckProcessedIDsDefaultsKey,
            cap: Self.seenMessageIDsCap
        )
    }
    func loadCKSeenIDs() {
        let ckIDs = ICloudSeenIDDefaultsStore.load(
            defaults: .standard,
            key: Self.ckProcessedIDsDefaultsKey,
            cap: Self.seenMessageIDsCap
        )
        for id in ckIDs where seenMessageIDs.insert(id).inserted {
            seenMessageIDsOrdered.append(id)
        }
        trimSeenMessageIDsIfNeeded()
    }
    @objc nonisolated func kvsDidChange(_ note: Notification) {
        let changedKeys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        Task { @MainActor in
            guard self.isSetUp else { return }
            let messageChanged = changedKeys == nil
                || changedKeys?.contains(KVSKey.newMessageInDrive) == true
            if messageChanged {
                if self.deviceTransport != nil {
                    _ = await self.drainDeviceTransport(trigger: .legacyKVS)
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
        // Cancel + invalidate any in-flight container resolve so a late
        // applyContainerResult can't re-register observers after teardown.
        setupTask?.cancel()
        setupTask = nil
        setupGeneration += 1
        incomingObserverGeneration &+= 1
        incomingObserverInstalled = false
        incomingObserverTask?.cancel()
        transportSetupTask?.cancel()
        outboxScanGeneration &+= 1
        outboxScanTask?.cancel()
        // The scanner keeps its slot until physical file work returns. Backlog
        // owners finish their accepted turn, then the lifecycle fence retires them.
        outboxScanQueued = false
        metadataQuery?.stop()
        metadataQuery = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        deviceNetworkMonitor?.cancel()
        deviceNetworkMonitor = nil
        deviceNetworkSatisfied = nil
        cloudKitPushProofAt = nil
        cloudKitPushUnavailable = false
        deviceDrainCadence = nil
        drainPolicy = AdaptiveDrainPolicy()
        messageHandler = nil
        deviceTransport = nil
        phonePairingSettled = false
        phonePairedElsewhere = false
        phonePairingRecheckDue = false
        lastPublishedProviderCatalogStatus = nil
        // Keep the owner until its awaited send returns; a new setup queues
        // behind it instead of overlapping the retired lifecycle's publication.
        providerCatalogPublicationQueued = false
        lastPublishedMobileSnapshotStatus = [:]
        deviceDrainTimerTask?.cancel()
        deviceDrainTimerTask = nil
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
        // N8 fix (R16): reset isSetUp so a subsequent setup() call can succeed.
        // Without this, tearDown() left isSetUp=true and setup() returned early
        // at the guard-!isSetUp check, leaving the bridge permanently stopped.
        isSetUp = false
        sync.engine.stop()
    }
}
// BridgeError is now in NativeAgentShared.
