// PATCH-2026-05-07: icloud-bridge Mac side — iCloud KVS+Drive hybrid bridge
// Architecture: A+B hybrid
//   - iCloud KVS (NSUbiquitousKeyValueStore): short control messages, status pings, "new-message" triggers
//   - iCloud Drive (NSMetadataQuery): chat history, attachments, full message payloads
// No Apple Developer cert required. Works on free Apple ID.
// Container: configured by NativeAgentICloudBridgeConstants.
// CloudKit is the selected public transport; KVS/Drive remains an explicit
// diagnostic and compatibility fallback.

import Foundation
import CryptoKit
import AppKit
import Cognition
import Combine
import NativeAgentShared
import DeviceSyncState
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import OSLog

// MARK: - iCloudBridge (Mac)
// BridgeMessage, BridgeError, and all HMAC helpers are now in NativeAgentShared.
private typealias KVSKey = NativeAgentICloudBridgeConstants.KVSKey
private typealias DriveFolder = NativeAgentICloudBridgeConstants.DriveFolder

/// One serial authentication owner per bridge. No suspension inside a check;
/// cancellation checks can still run while delivery awaits a chat's reply.
private actor ICloudIncomingVerifier {
    enum ChatAdmission: Sendable {
        case reserved, completed, interrupted, unreadable, collision, stale, unavailable
    }

    /// Both transports reserve the same canonical envelope before a turn starts.
    func reserveChat(_ message: BridgeMessage, dataRoot: URL, canDispatch: Bool) -> ChatAdmission {
        do {
            let digest = MacSyncSnapshotIntegrity.digest(try message.canonicalBodyForSigning())
            let id = MacSyncSnapshotIntegrity.digest(Data(message.id.utf8))
            let directory = dataRoot.appendingPathComponent("icloud/chat_transactions", isDirectory: true)
            let url = directory.appendingPathComponent("\(id).json")
            switch MacSyncEngine.coordinatedReadOutcome(at: url) {
            case .data(let data):
                guard let row = try? JSONDecoder().decode(ICloudTransactionRecord.self, from: data) else { return .unreadable }
                guard row.id == id, row.msgId == message.id, row.actionDigest == digest,
                      row.direction == "ios_to_mac", row.action == "chat" else { return .collision }
                return row.state == "completed" ? .completed : .interrupted
            case .failed:
                return .unreadable
            case .missing:
                break
            }
            let age = Date().timeIntervalSince(message.timestamp)
            guard age <= 24 * 60 * 60, age >= -15 * 60 else { return .stale }
            guard canDispatch else { return .unavailable }
            let now = ISO8601DateFormatter().string(from: Date())
            let row = ICloudTransactionRecord(id: id, direction: "ios_to_mac", action: "chat",
                                             state: "running", createdAt: now, updatedAt: now,
                                             attempts: 1, msgId: message.id, actionDigest: digest)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(row)
            try data.write(to: url, options: .withoutOverwriting)
            guard case .data(let retained) = MacSyncEngine.coordinatedReadOutcome(at: url),
                  retained == data else { return .unavailable }
            return .reserved
        } catch {
            nativeLog("[iCloudBridge] chat reservation unavailable: %@", error.localizedDescription)
            return .unavailable
        }
    }

    func finishChat(_ message: BridgeMessage, dataRoot: URL, completed: Bool) -> Bool {
        do {
            let id = MacSyncSnapshotIntegrity.digest(Data(message.id.utf8))
            let url = dataRoot.appendingPathComponent("icloud/chat_transactions/\(id).json")
            guard case .data(let data) = MacSyncEngine.coordinatedReadOutcome(at: url) else { return false }
            var row = try JSONDecoder().decode(ICloudTransactionRecord.self, from: data)
            guard row.msgId == message.id,
                  row.actionDigest == MacSyncSnapshotIntegrity.digest(try message.canonicalBodyForSigning()) else { return false }
            row.state = completed ? "completed" : "unknown"
            row.updatedAt = ISO8601DateFormatter().string(from: Date())
            return MacSyncEngine.coordinatedWrite(data: try JSONEncoder().encode(row), to: url)
        } catch {
            nativeLog("[iCloudBridge] chat outcome could not be saved: %@", error.localizedDescription)
            return false
        }
    }

    func quarantine(_ message: BridgeMessage, dataRoot: URL) -> Bool {
        iCloudBridge.quarantineIncomingSender(message, dataRoot: dataRoot)
    }

    func classify(_ message: BridgeMessage, secret: Data?, probe: (@Sendable (Bool) -> Void)?) throws -> (ICloudIncomingMessageDisposition, Data) {
        probe?(Thread.isMainThread)
        let key = try secret ?? PairingSecretManager.loadOrGenerateSecret()
        return (ICloudIncomingMessageDisposition.classify(message, secret: key, now: Date()), key)
    }

    func admitsControl(_ message: BridgeMessage, secret: Data?) -> Bool {
        guard let key = try? secret ?? PairingSecretManager.loadOrGenerateSecret() else { return false }
        if message.metadata?["kind"] != "icloud_action",
           UserMessageIntentSignals.isControlHandoff(message.text),
           let session = message.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           NativeAgentChatSessionID.normalizedPathComponent(session) != nil,
           case .deliver = ICloudIncomingMessageDisposition.classify(message, secret: key, now: Date()) {
            return true
        }
        return iCloudBridge.isAuthenticatedControlAction(message, secret: key)
    }
}

/// Transport presence and CloudKit selection are not interchangeable: the
/// hermetic bridge constructor accepts any `DeviceSyncTransport`, while only
/// the entitlement-checked production resolver may activate the CloudKit lane.
enum ICloudDeviceTransportSelection: Equatable {
    case legacyKVS
    case cloudKit
    case injectedForTesting

    var isCloudKit: Bool { self == .cloudKit }
}

/// A chat receipt describes the furthest boundary this Mac actually observed.
/// Neither state implies that iOS fetched, displayed, or acknowledged the
/// message; that would require a separate signed return receipt from iOS.
enum ChatDeliveryReceiptStatus: String, Sendable {
    /// The Drive file exists locally and still depends on iCloud replication.
    case queuedForICloudSync = "queued_for_icloud_sync"
    /// CloudKit accepted the outbound record, but iOS has not acknowledged it.
    case acceptedByTransport = "accepted_by_transport"
    /// The Mac verified and delivered the inbound peer message to the runtime.
    case deliveredToMac = "delivered_to_mac"
    /// The peer later confirmed delivery of a Mac-originated notification.
    case confirmedByPeer = "confirmed_by_peer"

    var deliveryConfirmed: Bool {
        switch self {
        case .queuedForICloudSync, .acceptedByTransport:
            return false
        case .deliveredToMac, .confirmedByPeer:
            return true
        }
    }
}

@MainActor
public final class iCloudBridge: ObservableObject {
    private static let pushLog = Logger(subsystem: "NativeAgent.DeviceSync", category: "push")

    private enum DrainTrigger: String {
        case fallbackTimer, cloudKitPush, legacyKVS, coalesced
    }

    unowned let sync: DeviceSync
    /// Silent CloudKit pushes are best-effort, even after APNs registration
    /// succeeds. Keep the Mac-side safety pull responsive so one missed wake
    /// cannot strand an already-sent iPhone turn until the phone's 180-second
    /// watchdog fires. This is deliberately the same for development and
    /// distribution builds; successful registration proves capability, not
    /// delivery of every individual wake.
    nonisolated static let responsiveDeviceDrainFallbackSeconds: TimeInterval = 8

    // MARK: Published state

    @Published public internal(set) var available: Bool = false
    @Published public internal(set) var lastSyncAt: Date?
    @Published public internal(set) var syncStatus: String = "iCloud not checked" {
        didSet {
            if accountFailure != nil, syncStatus != DeviceSyncAccountFailure.macMessage {
                syncStatus = DeviceSyncAccountFailure.macMessage
            }
        }
    }
    @Published public private(set) var accountFailure: DeviceSyncAccountFailure?
    private var accountFailureGeneration: UInt64 = 0

    // MARK: Private

    private var driveURL: URL?
    private var metadataQuery: NSMetadataQuery?
    private var messageHandlers: [(BridgeMessage) async -> Bool] = []
    private var statusKeyHandlers: [String: [(String) -> Void]] = [:]
    private var cloudKitObservedStatusKeys: Set<String> = []
    // The device-sync transport seam. A non-nil transport may be the checked
    // production CloudKit owner or a hermetic injected transport; callers that
    // need CloudKit-specific behavior must consult `deviceTransportSelection`.
    private var deviceTransport: DeviceSyncTransport?
    private var doctorTransportHealth: ICloudBridgeHealthSnapshot.Health = .unmeasured
    private var doctorSendFailures: [String: ICloudBridgeHealthSnapshot.Health] = [:]
    private var doctorSendMeasured = false
    var onTransportSucceeded: (() -> Void)?
    public lazy var phoneRequests = MacPhoneRequestChannel(bridge: self)
    private(set) var deviceTransportSelection: ICloudDeviceTransportSelection = .legacyKVS
    var usesCloudKitDeviceTransport: Bool {
        deviceTransport != nil && deviceTransportSelection.isCloudKit
    }
    public private(set) var cloudKitVisualNotificationPeerReady: Bool = false
    // CK-3c: single-flight guard for the transport drain (timer + observe +
    // on-demand triggers coalesce; per-message delivery is already atomic in the
    // transport) + a dynamic fallback poll. APNs is the normal wake path when
    // registration succeeds; development/ad-hoc builds without APS retain the
    // fast poll rather than silently losing phone messages.
    private var deviceDrainInFlight = false
    private var activeCloudKitChats = 0
    private var deviceDrainQueued = false
    private var deviceDrainTimerTask: Task<Void, Never>?
    // 2026-09-06: the retention sweep's own single-flight slot. It runs beside
    // the drain, never inside it, so a slow or timing-out sweep cannot delay
    // message delivery; a sweep still running when the next drain finishes is
    // simply not started again.
    private var deviceRetentionSweepInFlight = false
    private var deviceRetentionSweepTask: Task<Void, Never>?
    /// E3: decides whether each fallback tick actually spends a CloudKit fetch.
    var drainPolicy = AdaptiveDrainPolicy()
    private var lastDeviceDrainAt = Date.distantPast
    /// Last successfully published deterministic provider projection. Repeated
    /// UI refreshes often discover identical state; skip those CloudKit writes.
    private var lastPublishedProviderCatalogStatus: String?
    private var lastPublishedMobileSnapshotStatus: [NAMobileSnapshotGroup: String] = [:]
    // fix-2026-06-10 sync-audit #2 (fix-R9-9 pattern from MacSyncEngine):
    // maintain insertion order alongside the set so eviction drops OLDEST ids
    // first. The previous .sorted().suffix(cap) trimmed lexicographically —
    // age-random eviction that could forget a recent id and replay its message.
    private var seenMessageIDs: Set<String> = []
    private var seenMessageIDsOrdered: [String] = []
    // N-mem fix: the on-disk processed-ids file is capped at `seenMessageIDsCap`
    // via .suffix() but the in-memory Set only ever .insert()d → unbounded
    // memory growth over a long-running session. Cap memory the same way so
    // memory and disk stay consistent (both insertion-ordered, oldest evicted).
    // nonisolated: an immutable Sendable constant read by the nonisolated static
    // saveProcessedMessageIDs off-main helper; no actor isolation needed.
    nonisolated private static let seenMessageIDsCap = 2000
    private var inFlightIncomingMessageIDs: Set<String> = []
    private var setupTask: Task<Void, Never>?
    // Monotonic token: bumped on every setup()/tearDown() so a stale off-main
    // container resolve that completes late can't re-register observers / start
    // the query for a superseded setup (it checks generation before applying).
    private var setupGeneration: Int = 0
    /// DeviceSyncTransport currently has last-registration-wins observation but
    /// no cancellation token. Keep the callback itself lifecycle-gated so a
    /// retained transport cannot route work after this bridge has torn down.
    private var incomingObserverGeneration: UInt64 = 0
    private(set) var incomingObserverInstalled = false
    private var outboxScanTask: Task<Void, Never>?
    private var outboxScanInFlight = false
    private var outboxScanQueued = false
    /// Makes a cancelled/retired detached scan unable to clear or replay work
    /// belonging to a newer bridge lifecycle.
    private var outboxScanGeneration: UInt64 = 0
    var outboxScanState: (inFlight: Bool, queued: Bool) {
        (outboxScanInFlight, outboxScanQueued)
    }
    // N10 fix: idempotency guard — track whether setup() has already run so
    // repeat calls don't stack additional KVS observers (each call added a
    // new addObserver which fired the handler multiple times per external change).
    private var isSetUp: Bool = false
    /// Hermetic evaluations may provide authority inputs explicitly. Production
    /// always leaves these nil and uses the canonical pairing/evidence stores.
    private var testPairingSecret: Data?
    private let incomingVerifier = ICloudIncomingVerifier()
    var testIncomingVerificationProbe: (@Sendable (Bool) -> Void)?
    private var testDataRoot: URL?
    private var testCKSeenIDDefaults: UserDefaults?
    private var testOutboxScanHook: (@Sendable () throws -> Void)?
    private var deliveryNudgeQueue: ICloudDeliveryNudgeQueue?

    // Drive folder layout
    // <container>/Documents/outbox/mac/   — Mac writes here
    // <container>/Documents/outbox/ios/   — iOS writes here
    // <container>/Documents/processing/   — Mac claimed but has not acked yet
    // <container>/Documents/processed/    — read messages moved here (archive)

    // MARK: - Init

    init(sync: DeviceSync) {
        self.sync = sync
        let url = ICloudSyncStatePaths.accountFailure(dataRoot: sync.dataRoot)
        if let data = try? Data(contentsOf: url),
           let failure = try? JSONDecoder().decode(DeviceSyncAccountFailure.self, from: data) {
            accountFailure = failure
            syncStatus = DeviceSyncAccountFailure.macMessage
        }
        ICloudBridgeHealthReader.register(dataRoot: sync.dataRoot) { [weak self] in
            self?.doctorHealthSnapshot
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

    private static func transportHealth(_ error: Error) -> ICloudBridgeHealthSnapshot.Health {
        switch error as? DeviceSyncError {
        case .unauthorized: return .signedOut
        case .notConfigured: return .notEntitled
        case .quotaExceeded: return .quotaExceeded
        case .account(let failure): return .accountFailure(code: failure.code, detail: failure.detail)
        default: return .unavailable(error.localizedDescription)
        }
    }

    private func recordSendResult(operation: String, error: Error? = nil) {
        doctorSendMeasured = true
        doctorSendFailures[operation] = error.map(Self.transportHealth)
        if let error, case .account(let failure) = error as? DeviceSyncError {
            recordAccountFailure(failure)
        }
        if error == nil { onTransportSucceeded?() }
    }

    // N-mem fix: insert a seen id and cap the in-memory set so it can't grow
    // without bound. fix-2026-06-10 sync-audit #2: insertion-ordered, evicting
    // oldest first (mirrors MacSyncEngine.recordProcessed / fix-R9-9).
    private func recordSeenMessageID(_ id: String) {
        guard !seenMessageIDs.contains(id) else { return }
        seenMessageIDs.insert(id)
        seenMessageIDsOrdered.append(id)
        trimSeenMessageIDsIfNeeded()
    }

    private func trimSeenMessageIDsIfNeeded() {
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

    private func persistCKSeenIDs() {
        ICloudSeenIDDefaultsStore.save(
            seenMessageIDsOrdered,
            defaults: testCKSeenIDDefaults ?? .standard,
            key: Self.ckProcessedIDsDefaultsKey,
            cap: Self.seenMessageIDsCap
        )
    }

    private func loadCKSeenIDs() {
        let ckIDs = ICloudSeenIDDefaultsStore.load(
            defaults: testCKSeenIDDefaults ?? .standard,
            key: Self.ckProcessedIDsDefaultsKey,
            cap: Self.seenMessageIDsCap
        )
        for id in ckIDs where seenMessageIDs.insert(id).inserted {
            seenMessageIDsOrdered.append(id)
        }
        trimSeenMessageIDsIfNeeded()
    }

    // MARK: - Setup

    public func setup() {
        // N10 fix: guard against repeat setup() calls stacking KVS observers.
        guard !isSetUp else { return }
        isSetUp = true
        doctorTransportHealth = .unmeasured
        doctorSendFailures.removeAll()
        doctorSendMeasured = false
        syncStatus = "iCloud connecting…"
        setupTask?.cancel()
        setupGeneration += 1
        let generation = setupGeneration

        // CloudKit-only starts do not pass through the Drive bootstrap below,
        // so restore their persisted replay filter before the first drain.
        loadCKSeenIDs()

        // CloudKit is independent of the ubiquity/Drive mount. Public
        // Developer ID builds may have the CloudKit service without
        // CloudDocuments, so establish the entitlement-checked transport
        // before resolving the legacy Documents container.
        configureDeviceTransportIfAvailable()

        // A successfully constructed CloudKit transport is the runtime
        // capability proof for the public lane. Keep KVS as a best-effort
        // control/progress nudge, but do not mount or scan the retired Drive
        // data plane. If CloudKit is unavailable (or the build selects KVS),
        // setup falls through to the complete legacy path unchanged.
        if deviceTransport != nil {
            sync.engine.startCloudKitSnapshotProjection()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(kvsDidChange(_:)),
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: nil
            )
            Task.detached(priority: .utility) {
                _ = await withCKTimeout("iCloudBridge.setup.cloudKitKVSNudge") {
                    NSUbiquitousKeyValueStore.default.synchronize()
                }
            }
            available = true
            syncStatus = "CloudKit ready"
            return
        }

        // 2026-05-28 fix: FileManager.default.url(forUbiquityContainerIdentifier:)
        // is SYNCHRONOUS and can block for many seconds (sometimes 30s+) on first
        // launch while the iCloud container mounts. Running it on the @MainActor
        // froze the UI thread long enough that runningboardd / the watchdog killed
        // the app. The iOS companion hit this exact bug; this ports that fix.
        //
        // Move the container resolve off the main actor; hop back to update
        // @Published state, register observers, and start the metadata query.
        let containerID = NativeAgentICloudBridgeConstants.containerID
        let sync = self.sync
        setupTask = Task.detached(priority: .utility) {
            // This is the call that was blocking — runs on a background thread now.
            let containerURL = FileManager.default.url(
                forUbiquityContainerIdentifier: containerID
            )
            await sync.bridge.applyContainerResult(containerURL, generation: generation)
        }
    }

    /// Applies the result of the off-main-actor container lookup back on the
    /// main actor. Split out from setup() so the Task.detached closure does not
    /// capture `self` directly (Swift-6 strict concurrency clean).
    @MainActor
    private func applyContainerResult(_ containerURL: URL?, generation: Int) async {
        // Ignore a stale resolve from a superseded setup()/tearDown().
        guard generation == setupGeneration, isSetUp else { return }
        guard let containerURL else {
            // Reset isSetUp so the caller can retry later once iCloud signs in.
            isSetUp = false
            available = false
            syncStatus = "iCloud container unavailable — sign into iCloud in System Settings"
            doctorTransportHealth = .unavailable(syncStatus)
            return
        }

        let docsURL = containerURL.appendingPathComponent("Documents")
        driveURL = docsURL

        // Create directory structure if needed (off-main, awaited before proceeding)
        await Task.detached(priority: .utility) { [docsURL] in
            Self.createDriveDirectories(docsURL: docsURL)
        }.value
        // Re-assert staleness AFTER the await: the off-main directory create is a
        // suspension point, so tearDown() (or a newer setup()) may have run while
        // we were suspended. Without this re-check we'd re-enable observers, the
        // metadata query, and the sync engine for a superseded/torn-down setup,
        // and leave isSetUp=false so a later setup() stacks duplicate observers.
        guard generation == setupGeneration, isSetUp else { return }
        // 2026-05-29 fix: loadProcessedMessageIDs does try? Data(contentsOf:) on a
        // file inside the iCloud ubiquitous container, which can trigger an
        // on-demand download and block the main thread — the same watchdog-kill
        // mode the container resolve above was moved off-main to avoid. Read it
        // off-main, awaited, then hop back to mutate state.
        let loaded = await Task.detached(priority: .utility) { [docsURL] in
            Self.loadProcessedMessageIDs(docsURL: docsURL)
        }.value
        // Re-assert staleness AFTER the new await suspension point (reentrancy):
        // tearDown() or a newer setup() may have run while we were suspended.
        guard generation == setupGeneration, isSetUp else { return }
        // fix-2026-06-10 sync-audit #2: restore the ordered array (disk order =
        // insertion order) so eviction stays oldest-first across restarts.
        seenMessageIDs = []
        seenMessageIDsOrdered = []
        for id in loaded where seenMessageIDs.insert(id).inserted {
            seenMessageIDsOrdered.append(id)
        }
        // CK-3c: also restore CK-consumed ids (UserDefaults) into the unified
        // seen-set so a restart doesn't re-deliver a CloudKit message.
        loadCKSeenIDs()
        trimSeenMessageIDsIfNeeded()

        available = true
        syncStatus = "iCloud ready"
        doctorTransportHealth = .available

        // PATCH-2026-05-07: ios-parity start snapshot writer + inbox watcher
        sync.engine.start(docsURL: docsURL)

        // Start KVS change observation
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(kvsDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil
        )
        _ = await withCKTimeout("iCloudBridge.setup.kvsSynchronize") {
            NSUbiquitousKeyValueStore.default.synchronize()
        }

        // Start NSMetadataQuery watching iOS outbox folder
        startMetadataQuery(docsURL: docsURL)
    }

    /// Starts the checked CloudKit transport without depending on iCloud Drive.
    /// The factory remains the sole entitlement/crash guard. Legacy KVS/Drive
    /// setup is retained only when this returns nil.
    private func configureDeviceTransportIfAvailable() {
        guard deviceTransport == nil else { return }
        let containerID = NativeAgentICloudBridgeConstants.containerID
        guard let transport = DeviceSyncTransportResolver.makeCloudKitTransport(
            role: .mac,
            containerIdentifier: containerID
        ) else {
            return
        }
        deviceTransport = transport
        (transport as? CloudKitDeviceTransport)?.useAssetSecret {
            guard let encoded = try? PairingSecretManager.existingSecretBase64() else { return nil }
            return Data(base64Encoded: encoded)
        }
        (transport as? CloudKitDeviceTransport)?.observeAccountFailures { [weak self] failure in
            await self?.recordAccountFailure(failure)
        }
        deviceTransportSelection = .cloudKit
        available = true
        syncStatus = "CloudKit connecting…"
        nativeLog("[iCloudBridge] device transport: CloudKit ACTIVE (role=mac)")

        registerIncomingTransportObserver(transport)
        Task {
            await transport.observeStatus(
                key: NAVisualNotificationCapability.statusKey,
                onChange: { [weak self] value in
                    await MainActor.run {
                        self?.cloudKitVisualNotificationPeerReady =
                            NAVisualNotificationCapability.isReady(value)
                    }
                }
            )
        }
        Task {
            let pairingPublished = await PairingSecretManager.publishMaterial(to: transport)
            self.recordSendResult(operation: "pairing", error: pairingPublished ? nil :
                DeviceSyncError.underlying(message: "Pairing publication failed; check the Mac pairing key and iCloud."))
            if !pairingPublished {
                self.syncStatus = "iPhone pairing unavailable — check the Mac pairing key and iCloud"
            }
            _ = await self.publishProviderCatalogStatus()
        }

        startDeviceDrainFallback(every: 8)
        NSApplication.shared.registerForRemoteNotifications(matching: [])
    }

    /// `interval` is the FAST cadence while a peer correlation is outstanding
    /// or the phone was recently active. The fallback is one-shot: after each
    /// drain it arms directly for the next policy deadline. Pushes drain
    /// immediately, and outbound state changes re-arm the deadline, so an idle
    /// Mac no longer wakes every eight seconds just to reject an early tick.
    func startDeviceDrainFallback(every interval: TimeInterval) {
        drainPolicy.fastInterval = interval
        scheduleNextDeviceDrainFallback()
    }

    private func scheduleNextDeviceDrainFallback() {
        deviceDrainTimerTask?.cancel()
        guard deviceTransport != nil else {
            deviceDrainTimerTask = nil
            return
        }
        let now = Date()
        drainPolicy.prune(now: now)
        let policyDelay = drainPolicy.nextDrainDelay(now: now, lastDrainAt: lastDeviceDrainAt)
        let delay = activeCloudKitChats > 0 ? min(policyDelay, drainPolicy.fastInterval) : policyDelay
        let delayNanoseconds = UInt64(delay * 1_000_000_000)
        deviceDrainTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            // The handle owns only the sleeping timer, never the drain it wakes.
            // Streaming output re-arms this timer while the drain awaits the
            // chat. Retaining this handle there cancelled the final reply's
            // owner as soon as its first delta was sent.
            self.deviceDrainTimerTask = nil
            await self.drainDeviceTransport(trigger: .fallbackTimer)
        }
    }

    /// APNs registration is a runtime capability, not per-message delivery
    /// proof. A VM missed a valid silent wake in production and the former
    /// five-minute fallback let an iPhone turn outlive its 180-second watchdog.
    /// Keep the responsive safety pull after registration as well as failure.
    public func cloudKitPushRegistrationSucceeded() {
        Self.pushLog.notice("APNs registration succeeded")
        guard deviceTransport != nil else { return }
        startDeviceDrainFallback(every: Self.responsiveDeviceDrainFallbackSeconds)
    }

    public func cloudKitPushRegistrationFailed(_ error: Error) {
        Self.pushLog.error("APNs registration failed: \(error.localizedDescription, privacy: .private)")
        guard deviceTransport != nil else { return }
        nativeLog("[iCloudBridge] CloudKit push unavailable; retaining polling fallback: %@",
              error.localizedDescription)
        startDeviceDrainFallback(every: Self.responsiveDeviceDrainFallbackSeconds)
    }

    public func recognizesCloudKitRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        let recognized = CloudKitDeviceTransport.isDeviceSyncNotification(userInfo)
        Self.pushLog.notice("Remote notification received deviceSync=\(recognized)")
        return recognized
    }

    public func handleCloudKitPushWake() async {
        // A push is peer activity; follow-up traffic keeps the fast cadence.
        drainPolicy.notePeerActivity(at: Date())
        _ = await drainDeviceTransport(trigger: .cloudKitPush)
    }

    /// Publish the exact bytes returned by the atomic rotation transaction.
    /// This avoids a second disk read becoming a different authority decision.
    @discardableResult
    public func publishPairingSecret(_ secret: Data) async -> Bool {
        guard let deviceTransport else { return false }
        let published = await PairingSecretManager.publishMaterial(secret, to: deviceTransport)
        recordSendResult(operation: "pairing", error: published ? nil :
            DeviceSyncError.underlying(message: "Pairing publication failed; check the Mac pairing key and iCloud."))
        return published
    }

    // MARK: - Drive directory bootstrap

    nonisolated private static func createDriveDirectories(docsURL: URL) {
        let fm = FileManager.default
        for folder in [DriveFolder.outboxMac, DriveFolder.outboxIos, DriveFolder.processing, DriveFolder.processed] {
            let url = docsURL.appendingPathComponent(folder)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Send chat message (Drive for payload + KVS trigger)

    public func sendChatMessage(
        text: String,
        sessionID: String? = nil,
        correlationID: String? = nil,
        metadata: [String: String]? = nil,
        attachments: [NativeAgentShared.MultimodalAttachment] = [],
        messageID: String = UUID().uuidString,
        timestamp: Date? = nil
    ) async throws -> BridgeMessage {
        let unsigned = BridgeMessage.make(
            id: messageID,
            sender: "mac",
            text: text,
            sessionID: sessionID,
            correlationID: correlationID,
            metadata: metadata,
            attachments: attachments.isEmpty ? nil : attachments,
            timestamp: timestamp ?? Date()
        )
        // Phase 14e-iCloud: sign with the pairing secret. PairingSecretManager
        // is the Mac-side single source of truth (used by MacSyncEngine for
        // the action channel) — same secret signs both channels so iOS can
        // verify with one key. Pairing state must be durable and checked before
        // any message is signed or published; an unavailable local secret may
        // never degrade into an unsigned transport message.
        let secret = try testPairingSecret ?? PairingSecretManager.loadOrGenerateSecret()
        let msg = try unsigned.signed(with: secret)
        let operation: String
        if let correlationID {
            operation = "chat turn \(correlationID)" + (metadata?["kind"] == "text_delta" ? " delta" : "")
        } else {
            operation = "message \(msg.id)"
        }

        // CK-3b: CloudKit transport path. The signed BridgeMessage rides verbatim
        // in the record's payloadJSON (lossless — signature preserved), so iOS
        // verifies with the same secret exactly as on the Drive path. The shared
        // codec rejects an oversized encoded record before CloudKit sees it,
        // producing a clear user-facing error instead of an opaque server failure.
        if let ck = deviceTransport {
            do {
                try await ck.send(msg)
                if metadata?["kind"] != "text_delta", let correlationID {
                    doctorSendFailures["chat turn \(correlationID) delta"] = nil
                }
                recordSendResult(operation: operation)
            } catch {
                // A previous success must not remain visible as the status for a
                // rejected message. No receipt is written because CloudKit never
                // accepted this handoff.
                syncStatus = "CloudKit did not accept message: \(error.localizedDescription)"
                recordSendResult(operation: operation, error: error)
                throw error
            }
            await recordChatDeliveryReceipt(
                msg,
                transport: "cloudkit",
                status: .acceptedByTransport,
                secret: secret
            )
            // CK-5: fire the lightweight KVS "new message" nudge so the peer drains
            // CloudKit IMMEDIATELY — an event-driven foreground trigger (fires on
            // send, not on a timer, so no idle churn / scroll bounce), and it works
            // in the foreground where iOS withholds the silent push. The public
            // build (no KVS) falls back to the CloudKit push. A no-op if KVS is
            // absent; wrapped in a timeout so a wedged KVS can't block the send.
            let triggerValue = "\(ISO8601DateFormatter().string(from: Date())):\(msg.id)"
            _ = await withCKTimeout("iCloudBridge.sendChatMessage.ckNudge", seconds: 3) {
                let kvs = NSUbiquitousKeyValueStore.default
                kvs.set(triggerValue, forKey: KVSKey.newMessageInDrive)
                return kvs.synchronize()
            }
            noteOutboundToPeer(correlationID: correlationID, metadata: metadata)
            lastSyncAt = Date()
            syncStatus = "CloudKit accepted message — waiting for iOS"
            return msg
        }

        // Explicit/fail-safe legacy KVS/ubiquity path.
        guard let docsURL = driveURL else {
            throw BridgeError.containerUnavailable
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(msg)

        let outboxURL = docsURL
            .appendingPathComponent(DriveFolder.outboxMac)
            .appendingPathComponent("\(msg.id).json")
        do {
            try await Task.detached(priority: .utility) { [data, outboxURL] in
                try data.write(to: outboxURL, options: .atomic)
            }.value
        } catch {
            syncStatus = "Could not queue iCloud message: \(error.localizedDescription)"
            throw error
        }
        await recordChatDeliveryReceipt(
            msg,
            transport: "icloud_drive",
            status: .queuedForICloudSync,
            secret: secret
        )

        // KVS trigger: notify iOS side that a new file is waiting in Drive
        let triggerValue = "\(ISO8601DateFormatter().string(from: Date())):\(msg.id)"
        _ = await withCKTimeout("iCloudBridge.sendChatMessage.kvsTrigger") {
            let kvs = NSUbiquitousKeyValueStore.default
            kvs.set(triggerValue, forKey: KVSKey.newMessageInDrive)
            return kvs.synchronize()
        }
        await scheduleDeliveryNudges(for: msg.id)

        noteOutboundToPeer(correlationID: correlationID, metadata: metadata)
        lastSyncAt = Date()
        syncStatus = "Queued for iCloud sync — waiting for iOS"
        return msg
    }

    /// E3: a delivered outbound message settles the drain cadence. Only a
    /// terminal message retires the correlation — a text_delta or progress
    /// frame proves the turn is still running, so it refreshes peer activity
    /// instead of declaring the reply sent.
    private func noteOutboundToPeer(correlationID: String?, metadata: [String: String]?) {
        defer { scheduleNextDeviceDrainFallback() }
        let now = Date()
        guard let correlationID, !correlationID.isEmpty else {
            drainPolicy.notePeerActivity(at: now)
            return
        }
        switch metadata?["kind"] {
        case "text_delta", "progress":
            drainPolicy.notePeerActivity(at: now)
        default:
            drainPolicy.resolve(correlationID, at: now)
        }
    }

    func cloudKitActionResponseMessage(_ response: [String: String], correlationID: String) throws -> BridgeMessage {
        let unsigned = BridgeMessage.make(
            sender: "mac",
            text: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
            correlationID: correlationID,
            metadata: ["kind": "icloud_action_response"]
        )
        let secret = try testPairingSecret ?? PairingSecretManager.loadOrGenerateSecret()
        return try unsigned.signed(with: secret)
    }

    /// Return the existing MacSyncEngine-signed action response over CloudKit.
    /// Trust/dispatch/receipt ownership stays in MacSyncEngine; BridgeMessage
    /// contributes transport HMAC, correlation, ordering, and retry semantics.
    func sendCloudKitActionResponse(
        _ response: [String: String],
        correlationID: String
    ) async throws {
        guard let deviceTransport else {
            throw BridgeError.containerUnavailable
        }
        do {
            let signed = try cloudKitActionResponseMessage(response, correlationID: correlationID)
            try await deviceTransport.send(signed)
            recordSendResult(operation: "action response \(correlationID)")
            await Self.appendActionResponseDeliveryReceipt(
                response: response,
                correlationID: correlationID,
                transport: "cloudkit",
                status: .acceptedByTransport,
                dataRoot: testDataRoot ?? PersistenceCore.defaultDataRoot()
            )
            drainPolicy.resolve(correlationID, at: Date())
            scheduleNextDeviceDrainFallback()
            lastSyncAt = Date()
            syncStatus = "Sent action response via CloudKit"
        } catch {
            // Do not leave a prior green send painted as current health. The
            // durable response remains available to MacSync for a restart-safe
            // resend, but the bridge state must say that this attempt failed.
            syncStatus = "CloudKit action response waiting to resend: \(error.localizedDescription)"
            recordSendResult(operation: "action response \(correlationID)", error: error)
            throw error
        }
    }

    private func recordChatDeliveryReceipt(
        _ message: BridgeMessage,
        transport: String,
        status: ChatDeliveryReceiptStatus,
        secret: Data,
        direction: String = "mac_to_ios"
    ) async {
        await Self.appendChatDeliveryReceipt(
            message,
            direction: direction,
            transport: transport,
            status: status,
            secret: secret,
            dataRoot: testDataRoot ?? PersistenceCore.defaultDataRoot()
        )
    }

    private func scheduleDeliveryNudges(for messageID: String) async {
        let queue: ICloudDeliveryNudgeQueue
        if let deliveryNudgeQueue {
            queue = deliveryNudgeQueue
        } else {
            queue = ICloudDeliveryNudgeQueue(
                isAvailable: { [weak self] in
                    await self?.available ?? false
                },
                sendNudge: { messageID in
                    let triggerValue = "\(ISO8601DateFormatter().string(from: Date())):\(messageID)"
                    return await withCKTimeout(
                        "iCloudBridge.deliveryNudge.kvsTrigger",
                        seconds: 3
                    ) {
                        let kvs = NSUbiquitousKeyValueStore.default
                        kvs.set(triggerValue, forKey: KVSKey.newMessageInDrive)
                        return kvs.synchronize()
                    } ?? false
                },
                observeOutcome: { [weak self] outcome in
                    await self?.recordDeliveryNudgeOutcome(outcome)
                }
            )
            deliveryNudgeQueue = queue
        }
        await queue.schedule(for: messageID)
    }

    private func recordDeliveryNudgeOutcome(_ outcome: ICloudDeliveryNudgeOutcome) {
        switch outcome.disposition {
        case .synchronized:
            break
        case .unavailable:
            syncStatus = "iCloud delivery nudge skipped: iCloud unavailable"
        case .synchronizeFailed:
            syncStatus = "iCloud delivery nudge failed: iOS will retry on its next sync"
        }
    }

    // MARK: - Status pings (KVS only — fast)

    func sendShortStatus(key: String, value: String) {
        // CK-3b: route status through the CloudKit transport when active.
        if let ck = deviceTransport {
            Task {
                do {
                    try await ck.setStatus(key: key, value: value)
                    recordSendResult(operation: key)
                } catch {
                    recordSendResult(operation: key, error: error)
                }
            }
            return
        }
        Task.detached(priority: .utility) {
            _ = await withCKTimeout("iCloudBridge.sendShortStatus.\(key)", seconds: 3) {
                let kvs = NSUbiquitousKeyValueStore.default
                kvs.set(value, forKey: key)
                return kvs.synchronize()
            }
        }
    }

    /// Publish the Mac-owned provider/model catalog to the paired phone without
    /// copying credentials or requiring the legacy iCloud Drive snapshot lane.
    /// The status record is a bounded LWW projection; the Mac remains the only
    /// provider configuration owner.
    @discardableResult
    public func publishProviderCatalogStatus() async -> Bool {
        guard let deviceTransport else { return false }
        do {
            let snapshot = try await sync.host.providerCatalogSnapshot()
            let catalog = NAProviderCatalogStatus(
                providers: snapshot.providers,
                surfaces: Self.providerSurfaceSelections(from: snapshot.routing)
            )
            let value = try NAProviderCatalogStatusCodec.encode(catalog)
            guard value != lastPublishedProviderCatalogStatus else { return true }
            try await deviceTransport.setStatus(key: NAProviderCatalogStatusCodec.statusKey, value: value)
            lastPublishedProviderCatalogStatus = value
            recordSendResult(operation: NAProviderCatalogStatusCodec.statusKey)
            return true
        } catch {
            recordSendResult(operation: NAProviderCatalogStatusCodec.statusKey, error: error)
            lastPublishedProviderCatalogStatus = nil
            nativeLog("[iCloudBridge] provider catalog publication failed: \(error.localizedDescription)")
            return false
        }
    }

    /// A credential-free projection of one frozen routing generation. Never
    /// reread a second picker file while constructing the phone's tuple.
    nonisolated static func providerSurfaceSelections(
        from snapshot: ProviderRoutingSnapshot
    ) -> [String: NAProviderSurfaceSelection] {
        snapshot.preferences.reduce(into: [:]) { surfaces, entry in
            let (surface, preference) = entry
            guard !surface.isEmpty, !preference.model.isEmpty else { return }
            surfaces[surface] = NAProviderSurfaceSelection(
                providerID: snapshot.activeProviders[surface],
                model: preference.model,
                reasoningEffort: preference.reasoningEffort.isEmpty ? nil : preference.reasoningEffort,
                serviceTier: preference.serviceTier
            )
        }
    }

    /// Publish selected rebuildable iOS read projections through the existing
    /// bounded CloudKit status seam. The snapshot writer remains the only
    /// projection compiler; this adapter only transports its exact file bytes.
    /// Returns each group that did not publish, with why; nil when there is no
    /// CloudKit transport or the pass was torn down.
    @discardableResult
    func publishMobileSnapshotStatus(
        groups: Set<NAMobileSnapshotGroup>,
        snapshotDirectory: URL,
        shouldPublish: @MainActor () -> Bool = { true }
    ) async -> [NAMobileSnapshotGroup: DeviceSyncError]? {
        guard let deviceTransport, !groups.isEmpty else { return nil }
        var failures: [NAMobileSnapshotGroup: DeviceSyncError] = [:]
        for group in NAMobileSnapshotGroup.allCases where groups.contains(group) {
            do {
                guard let value = try await MobileSnapshotBuilder.shared.status(
                    group: group, directory: snapshotDirectory
                ) else { continue }
                guard shouldPublish() else { return nil }
                if lastPublishedMobileSnapshotStatus[group] == value {
                    continue
                }
                try await deviceTransport.setStatus(
                    key: group.statusKey,
                    value: value
                )
                guard shouldPublish() else { return nil }
                lastPublishedMobileSnapshotStatus[group] = value
                recordSendResult(operation: group.statusKey)
            } catch {
                guard shouldPublish() else { return nil }
                failures[group] = error as? DeviceSyncError ?? .underlying(message: error.localizedDescription)
                recordSendResult(operation: group.statusKey, error: error)
                // Forget what was last published for this group: the retained
                // value is what suppresses the next attempt, and this group is
                // now known not to be on the phone as published.
                lastPublishedMobileSnapshotStatus[group] = nil
                nativeLog(
                    "[iCloudBridge] mobile snapshot %@ publication failed: %@",
                    group.rawValue,
                    error.localizedDescription
                )
            }
        }
        return failures
    }

    /// One presence beat (`NAMacPresence`).
    func publishMacPresence() async -> Bool {
        guard let deviceTransport else { return false }
        do {
            guard let encoded = try PairingSecretManager.existingSecretBase64(),
                  let secret = Data(base64Encoded: encoded) else { return false }
            try await deviceTransport.setPresence(pairingSecret: secret)
            recordSendResult(operation: "presence")
            return true
        } catch {
            recordSendResult(operation: "presence", error: error)
            nativeLog("[iCloudBridge] presence beat failed: %@", error.localizedDescription)
            return false
        }
    }

    @discardableResult
    public func sendKVSChatProgress(
        text: String,
        sessionID: String,
        correlationID: String,
        metadata: [String: String],
        key: String = NativeAgentICloudBridgeConstants.KVSKey.chatProgressLatest,
        mirrorKey: String? = nil
    ) async -> Bool {
        let msg: BridgeMessage
        let mirror: BridgeMessage?
        do {
            let secret = try testPairingSecret ?? PairingSecretManager.loadOrGenerateSecret()
            msg = try Self.makeKVSChatProgressMessage(
                text: text,
                sessionID: sessionID,
                correlationID: correlationID,
                metadata: metadata,
                secret: secret
            )
            if let mirrorKey, mirrorKey != key {
                // 2026-09-06: a phone that predates the notice key admits only
                // kind "progress", so the mirrored copy has to carry that kind
                // or it is dropped and the notice is lost on that phone. It
                // keeps the SAME message id — that is what an updated phone
                // dedupes on — and `noticeKind` rides along either way.
                var mirrorMetadata = metadata
                mirrorMetadata["kind"] = "progress"
                mirror = try Self.makeKVSChatProgressMessage(
                    id: msg.id,
                    text: text,
                    sessionID: sessionID,
                    correlationID: correlationID,
                    metadata: mirrorMetadata,
                    secret: secret
                )
            } else {
                mirror = nil
            }
        } catch {
            syncStatus = "iPhone pairing unavailable — repair the Mac pairing key"
            nativeLog("[iCloudBridge] failed to sign KVS progress msg=%@: %@", correlationID, "\(error)")
            return false
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        let mirrorData: Data?
        do {
            data = try encoder.encode(msg)
            mirrorData = try mirror.map { try encoder.encode($0) }
        } catch {
            nativeLog("[iCloudBridge] failed to encode KVS progress msg=%@: %@", correlationID, "\(error)")
            return false
        }

        let delivery: ICloudKVSProgressDeliveryResult = await withCKTimeout(
            "iCloudBridge.sendKVSChatProgress",
            seconds: 3
        ) { () -> ICloudKVSProgressDeliveryResult in
            let kvs = NSUbiquitousKeyValueStore.default
            var existingKeys = Set(kvs.dictionaryRepresentation.keys)
            let admission = ICloudKVSProgressWriteAdmission.assess(
                keys: existingKeys,
                progressKey: key
            )
            guard admission.isAllowed else { return .blocked(admission) }
            // 2026-09-06: the mirror carries the same message id, so a phone
            // that reads both keys drops the second copy, while a phone that
            // only knows the old key still receives the event.
            if let mirrorKey, let mirrorData, mirrorKey != key {
                // 2026-09-06: the mirror is admitted against the keyspace AS
                // IT WILL BE once the primary key is written. Assessing both
                // from one pre-write snapshot admitted two NEW keys at 959 and
                // pushed the store past its own 960 ceiling, after which every
                // later progress overwrite was rejected outright.
                existingKeys.insert(key)
                let mirrorAdmission = ICloudKVSProgressWriteAdmission.assess(
                    keys: existingKeys,
                    progressKey: mirrorKey
                )
                guard mirrorAdmission.isAllowed else { return .blocked(mirrorAdmission) }
                kvs.set(mirrorData, forKey: mirrorKey)
            }
            kvs.set(data, forKey: key)
            return kvs.synchronize() ? .synchronized : .synchronizeFailed
        } ?? .timedOut

        switch delivery {
        case .synchronized:
            lastSyncAt = Date()
            syncStatus = "Progress sent via iCloud KVS"
            return true
        case .blocked(let admission):
            let snapshot = admission.snapshot
            let detail = admission.failureDescription ?? "KVS keyspace unavailable"
            syncStatus = "iCloud KVS progress blocked: \(detail)"
            nativeLog(
                "[iCloudBridge] KVS progress blocked msg=%@ totalKeys=%d responseKeys=%d: %@",
                correlationID,
                snapshot.totalKeyCount,
                snapshot.inboxResponseKeyCount,
                detail
            )
        case .synchronizeFailed, .timedOut:
            syncStatus = delivery == .timedOut
                ? "iCloud KVS progress timed out"
                : "iCloud KVS progress sync failed"
            nativeLog("[iCloudBridge] KVS progress sync did not complete msg=%@", correlationID)
        }
        return false
    }

    nonisolated static func makeKVSChatProgressMessage(
        id: String = UUID().uuidString,
        text: String,
        sessionID: String,
        correlationID: String,
        metadata: [String: String],
        secret: Data
    ) throws -> BridgeMessage {
        var compactMetadata = metadata.mapValues { String($0.prefix(240)) }
        compactMetadata["ephemeral"] = "true"
        compactMetadata["transport"] = compactMetadata["transport"] ?? "icloud"
        compactMetadata["source"] = compactMetadata["source"] ?? "mac"

        let unsigned = BridgeMessage.make(
            id: id,
            sender: "mac",
            text: String(text.prefix(240)),
            sessionID: sessionID,
            correlationID: correlationID,
            metadata: compactMetadata
        )
        return try unsigned.signed(with: secret)
    }

    func observeStatusKey(_ key: String, onChange: @escaping (String) -> Void) {
        statusKeyHandlers[key, default: []].append(onChange)
        guard let transport = deviceTransport,
              cloudKitObservedStatusKeys.insert(key).inserted
        else { return }
        Task { [weak self] in
            await transport.observeStatus(key: key, onChange: { [weak self] value in
                await MainActor.run { self?.deliverObservedStatus(key: key, value: value) }
            })
        }
    }

    private func deliverObservedStatus(key: String, value: String) {
        for handler in statusKeyHandlers[key] ?? [] { handler(value) }
    }

    // MARK: - Observe incoming messages from iOS (Drive)

    public func observeIncomingMessages(onMessage: @escaping (BridgeMessage) async -> Bool) {
        // N-dedup fix: replace rather than append. A teardown→setup retry (or any
        // second call) previously stacked handlers, so each iOS message was
        // forwarded to the daemon once PER accumulated handler → duplicate turns.
        // There is exactly one logical forwarder, so idempotent single-slot
        // registration is correct.
        messageHandlers = [onMessage]
        // Keep the transport callback bound to this bridge as well as draining
        // records that arrived before the app-side forwarder. The production
        // setup path already installs this same callback, but registering here
        // is idempotent (the transport is last-registration-wins) and prevents
        // a late/recovered observer from becoming a green bridge with no route.
        if let ck = deviceTransport {
            registerIncomingTransportObserver(ck)
            return
        }
        checkIosOutbox()
    }

    private func acceptsIncomingObserver(generation: UInt64) -> Bool {
        generation == incomingObserverGeneration && deviceTransport != nil
    }

    private func registerIncomingTransportObserver(_ transport: DeviceSyncTransport) {
        incomingObserverGeneration &+= 1
        incomingObserverInstalled = false
        let observerGeneration = incomingObserverGeneration
        (transport as? CloudKitDeviceTransport)?.setControlAdmission { [weak self] message in
            guard let self else { return false }
            return await self.admitsPhoneControl(message, generation: observerGeneration)
        }
        Task { [weak self] in
            await transport.observeIncoming { [weak self] message in
                guard let self,
                      await self.acceptsIncomingObserver(generation: observerGeneration)
                else { return false }
                return await self.handleIncomingFromTransport(message, observerGeneration: observerGeneration)
            }
            guard let self,
                  self.acceptsIncomingObserver(generation: observerGeneration)
            else { return }
            self.incomingObserverInstalled = true
        }
    }

    private func admitsPhoneControl(_ message: BridgeMessage, generation: UInt64) async -> Bool {
        guard acceptsIncomingObserver(generation: generation) else { return false }
        let admitted = await incomingVerifier.admitsControl(message, secret: testPairingSecret)
        return admitted && acceptsIncomingObserver(generation: generation)
    }

    nonisolated static func isAuthenticatedControlAction(_ message: BridgeMessage, secret: Data) -> Bool {
        guard case .deliver = ICloudIncomingMessageDisposition.classify(message, secret: secret, now: Date()),
              message.metadata?["kind"] == "icloud_action",
              let data = message.text.data(using: .utf8),
              let action = try? JSONDecoder().decode(InboxAction.self, from: data),
              action.action == "cancelChat",
              let ids = InboxActionFileBoundary.validatedIDs(for: action),
              ids.messageID == message.metadata?["actionId"],
              let signature = action.signature,
              var body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        body.removeValue(forKey: "signature")
        guard let canonical = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return false }
        let supplied = Array(signature.lowercased().utf8)
        let expected = Array(BridgeMessage.hmacHex(of: canonical, secret: secret).utf8)
        guard supplied.count == expected.count else { return false }
        return zip(supplied, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// CK-3b: validate + forward a message pulled from the CloudKit transport,
    /// mirroring `scanIosOutboxFiles`' checks. Returns true when the message is
    /// HANDLED (delivered OR permanently rejected) so the transport advances its
    /// cursor; false only when transiently undeliverable (runtime unavailable) so
    /// the transport re-delivers next drain (the halt-on-undelivered contract).
    @MainActor
    func handleIncomingFromTransport(_ msg: BridgeMessage, observerGeneration: UInt64? = nil) async -> Bool {
        // A shared HMAC key proves pairing, not direction. Reject before the
        // ID cache or action dispatcher can claim an attacker-selected ID.
        guard msg.sender == "ios" else {
            let retained = await incomingVerifier.quarantine(msg, dataRoot: testDataRoot ?? PersistenceCore.defaultDataRoot())
            if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
            syncStatus = retained ? "Rejected iPhone message (CloudKit): sender_invalid"
                : "iPhone rejection quarantine unavailable — retaining message for retry"
            return retained
        }
        // Already handled (persistent seen-set; the transport also dedups by id).
        if seenMessageIDs.contains(msg.id) { return true }
        let disposition: ICloudIncomingMessageDisposition
        let secret: Data
        do {
            (disposition, secret) = try await incomingVerifier.classify(msg, secret: testPairingSecret, probe: testIncomingVerificationProbe)
        } catch {
            syncStatus = "iPhone pairing unavailable — repair the Mac pairing key"
            nativeLog("[iCloudBridge] deferring iOS→Mac CK msg %@: %@", msg.id, error.localizedDescription)
            return false
        }
        if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
        if disposition == .permanentlyRejected(reason: "signature_invalid") {
            let retained = await incomingVerifier.quarantine(msg, dataRoot: testDataRoot ?? PersistenceCore.defaultDataRoot())
            if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
            syncStatus = retained ? "Rejected iPhone message (CloudKit): signature_invalid"
                : "iPhone rejection quarantine unavailable — retaining message for retry"
            return retained
        }
        // Authentication suspended; a concurrent cancellation may have completed.
        if seenMessageIDs.contains(msg.id) { return true }
        switch disposition {
        case .permanentlyRejected(let reason):
            if reason == "stale_timestamp" {
                if msg.metadata?["kind"] != PhonePlaceEvent.messageKind,
                   msg.metadata?["kind"] != PhoneRequestResult.messageKind {
                    // Chat and action ledgers may already own this expired request.
                    break
                }
                guard await sendIncomingRejection(msg, reason: Date() > msg.timestamp ? "request_expired" : "clock_ahead") else { return false }
            }
            nativeLog("[iCloudBridge] dropping iOS→Mac CK msg %@: %@", msg.id, reason)
            guard await recordPermanentIncomingRejection(msg, reason: reason) else {
                syncStatus = "iPhone rejection receipt unavailable — retaining message for retry"
                return false
            }
            // The rejection receipt retains this envelope. Do not reserve its
            // caller-selected ID: a fresh authenticated envelope may reuse it.
            syncStatus = "Rejected iPhone message (CloudKit): \(reason)"
            return true  // permanently rejected: consume, never wedge transport
        case .deliver:
            break
        }
        if msg.metadata?["kind"] == PhonePlaceEvent.messageKind {
            guard let event = try? JSONDecoder().decode(PhonePlaceEvent.self, from: Data(msg.text.utf8)),
                  event.id == msg.id, event.isValid else {
                return await recordPermanentIncomingRejection(msg, reason: "invalid_place_event")
            }
            do {
                try PhonePlaceHistory.record(event, dataRoot: testDataRoot ?? PersistenceCore.defaultDataRoot())
                recordSeenMessageID(msg.id)
                persistCKSeenIDs()
                return true
            } catch {
                syncStatus = "iPhone place event could not be saved: \(error.localizedDescription)"
                return false
            }
        }
        if msg.metadata?["kind"] == PhoneRequestResult.messageKind {
            phoneRequests.receive(msg)
            recordSeenMessageID(msg.id)
            persistCKSeenIDs()
            return true
        }
        if msg.metadata?["kind"] == "icloud_action" {
            let handled = await sync.engine.processCloudKitActionMessage(msg)
            if handled {
                // E3: the action's signed response is owed on the same id.
                drainPolicy.noteOutstanding(msg.id, at: Date())
                recordSeenMessageID(msg.id)
                persistCKSeenIDs()
                lastSyncAt = Date()
                syncStatus = "Processed iPhone action (CloudKit)"
            }
            return handled
        }
        do {
            try await SignedPeerEvidenceStore.record(
                eventID: msg.id,
                channel: .chat,
                peerCreatedAt: msg.timestamp,
                dataRoot: testDataRoot ?? PersistenceCore.defaultDataRoot()
            )
        } catch {
            nativeLog("[iCloudBridge] could not persist signed peer evidence for %@: %@",
                  msg.id, error.localizedDescription)
        }
        activeCloudKitChats += 1
        defer { activeCloudKitChats -= 1 }
        drainPolicy.notePeerActivity(at: Date())
        scheduleNextDeviceDrainFallback()
        let delivery = await deliverIncomingChat(msg)
        if delivery != .deferred {
            // E3: this turn's reply is owed — hold the fast drain cadence until
            // it is sent (or the correlation ages out).
            drainPolicy.noteOutstanding(msg.id, at: Date())
            if delivery == .delivered {
                await Self.appendInboundSuccessReceipt(
                    msg,
                    transport: "cloudkit",
                    secret: secret,
                    dataRoot: testDataRoot ?? PersistenceCore.defaultDataRoot()
                )
            }
            if delivery != .rejected { recordSeenMessageID(msg.id) }
            // CK-3c: persist the CK-consumed id so a restart within the cursor's
            // 30s clock-skew re-pull window doesn't re-deliver it (gpt-5.5 CK-3c
            // review P1). Synchronous UserDefaults (ordered on the main actor,
            // atomic) — NOT a detached file write, which could reorder two rapid
            // saves or not flush before exit. Mirrors the iOS bridge's approach;
            // merged back into the seen-set on setup. Only the DELIVERED branch
            // needs it (a re-dropped bad-sig/stale is harmless).
            if delivery != .rejected { persistCKSeenIDs() }
            lastSyncAt = Date()
            syncStatus = "Processed iPhone request (CloudKit)"
            return true
        }
        markMacRuntimeUnavailable()
        return false  // transient — retry next drain
    }

    private func sendIncomingRejection(_ message: BridgeMessage, reason: String) async -> Bool {
        let text: String
        switch reason {
        case "request_expired":
            text = "Your Mac received this after its request window expired. It wasn't started."
        case "clock_ahead":
            text = "iPhone message rejected: its timestamp is in the future. Check both devices' clocks and try again."
        case "message_id_collision":
            text = "This message ID already belongs to a different request. This request wasn't started."
        default:
            text = "Mac could not confirm whether this request completed, so it was not started again. Check the conversation and any actions before sending a new request."
        }
        do {
            let isOutcomeError = reason == "unknown_outcome" || reason == "message_id_collision"
            _ = try await sendChatMessage(text: text, sessionID: message.sessionID, correlationID: message.id,
                                          metadata: ["kind": isOutcomeError ? "error" : "rejection", "reason": reason,
                                                     "errorDetail": text,
                                                     "targetSourceKey": message.metadata?["routeKey"]
                                                        ?? message.metadata?["deviceSourceKey"]
                                                        ?? message.metadata?["sourceKey"] ?? ""])
            return true
        } catch {
            syncStatus = "iPhone response could not be sent — retaining request for retry"
            return false
        }
    }

    private enum IncomingChatDelivery { case delivered, handled, rejected, deferred }

    private func deliverIncomingChat(_ message: BridgeMessage) async -> IncomingChatDelivery {
        guard !inFlightIncomingMessageIDs.contains(message.id) else { return .deferred }
        inFlightIncomingMessageIDs.insert(message.id)
        defer { inFlightIncomingMessageIDs.remove(message.id) }
        let dataRoot = testDataRoot ?? PersistenceCore.defaultDataRoot()
        switch await incomingVerifier.reserveChat(message, dataRoot: dataRoot, canDispatch: !messageHandlers.isEmpty) {
        case .completed:
            return .handled
        case .collision:
            return await sendIncomingRejection(message, reason: "message_id_collision") ? .rejected : .deferred
        case .stale:
            return await sendIncomingRejection(message, reason: Date() > message.timestamp ? "request_expired" : "clock_ahead") ? .rejected : .deferred
        case .unavailable:
            syncStatus = "iPhone request record unavailable — retaining request for retry"
            return .deferred
        case .interrupted:
            guard await sendIncomingRejection(message, reason: "unknown_outcome") else { return .deferred }
            return await incomingVerifier.finishChat(message, dataRoot: dataRoot, completed: false) ? .handled : .deferred
        case .unreadable:
            // Unknown authority stays byte-preserved and never authorizes dispatch.
            return await sendIncomingRejection(message, reason: "unknown_outcome") ? .handled : .deferred
        case .reserved:
            break
        }
        var delivered = false
        for handler in messageHandlers {
            if await handler(message) { delivered = true }
        }
        if !delivered {
            guard await sendIncomingRejection(message, reason: "unknown_outcome") else { return .deferred }
        }
        guard await incomingVerifier.finishChat(message, dataRoot: dataRoot, completed: delivered) else { return .deferred }
        return delivered ? .delivered : .handled
    }

    /// A terminal rejection advances the transport cursor only after this
    /// bounded receipt is durable. Otherwise a bad message remains retryable
    /// instead of disappearing without its reason/status evidence.
    private func recordPermanentIncomingRejection(
        _ message: BridgeMessage,
        reason: String
    ) async -> Bool {
        let row: JSONValue = .object([
            "at": .string(ISO8601DateFormatter().string(from: Date())),
            "messageId": .string(message.id),
            "sender": .string(message.sender),
            "direction": .string("ios_to_mac"),
            "transport": .string("cloudkit"),
            "status": .string("permanently_rejected"),
            "reason": .string(reason),
            "signaturePresent": .bool(message.signature != nil),
        ])
        let path = (testDataRoot ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("icloud", isDirectory: true)
            .appendingPathComponent("incoming_rejections.jsonl")
        do {
            try await appendJSONLCapped(
                row,
                to: path,
                using: SwiftNativePersistenceCore(),
                maxLines: 500,
                logLabel: "iCloudBridge.incomingRejection"
            )
            return true
        } catch {
            nativeLog("[iCloudBridge] could not persist rejection receipt for %@: %@", message.id, error.localizedDescription)
            return false
        }
    }

    private func markMacRuntimeUnavailable() {
        syncStatus = "iPhone message waiting — Mac runtime unavailable"
    }

    nonisolated static func quarantineIncomingSender(_ message: BridgeMessage, dataRoot: URL) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(message)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let directory = dataRoot.appendingPathComponent("icloud/_rejected", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("\(digest).done"), options: .atomic)
            return true
        } catch {
            nativeLog("[iCloudBridge] could not quarantine wrong-direction envelope: %@", error.localizedDescription)
            return false
        }
    }

    /// CK-3c: drain the CloudKit transport (incoming + pairing + status) if it is
    /// active; no-op when nil (flag-off). Single-flight — overlapping triggers
    /// (poll timer, initial observe, future push) coalesce into at most one queued
    /// re-run, so they don't fire redundant CloudKit round-trips. Per-message
    /// delivery is already atomic in the transport (claimIfUnseen), so this is an
    /// efficiency guard, not a correctness one. Returns true if any incoming
    /// message was dispatched.
    @discardableResult
    private func drainDeviceTransport(trigger: DrainTrigger) async -> Bool {
        guard let ck = deviceTransport else { return false }
        if deviceDrainInFlight {
            Self.pushLog.info("Drain coalesced trigger=\(trigger.rawValue, privacy: .public)")
            deviceDrainQueued = true
            lastDeviceDrainAt = Date()
            defer { scheduleNextDeviceDrainFallback() }
            let dispatched = await (ck as? CloudKitDeviceTransport)?.drainIncomingControls() ?? 0
            Self.pushLog.info("Cancellation drain trigger=\(trigger.rawValue, privacy: .public) dispatched=\(dispatched)")
            return dispatched > 0
        }
        lastDeviceDrainAt = Date()
        deviceDrainInFlight = true
        Self.pushLog.info("Drain started trigger=\(trigger.rawValue, privacy: .public)")
        // Keep missed-push recovery alive even when the stream emits no deltas.
        scheduleNextDeviceDrainFallback()
        defer {
            deviceDrainInFlight = false
            if deviceDrainQueued {
                deviceDrainQueued = false
                Task { await self.drainDeviceTransport(trigger: .coalesced) }
            } else {
                scheduleNextDeviceDrainFallback()
            }
            // 2026-09-06: kicked off AFTER the single-flight flag is released,
            // so the housekeeping sweep never sits in front of a drain.
            startDeviceRetentionSweepIfIdle(ck)
        }
        let accountGeneration = accountFailureGeneration
        let doctorGeneration = setupGeneration
        let result = await ck.drainIncoming()
        if doctorGeneration == setupGeneration {
            switch result {
            case .success:
                doctorTransportHealth = .available
                onTransportSucceeded?()
            case .skipped: break
            case .failure(let error, _): doctorTransportHealth = Self.transportHealth(error)
            }
        }
        Self.pushLog.info("Incoming drain completed trigger=\(trigger.rawValue, privacy: .public) dispatched=\(result.dispatchedCount)")
        if case .failure(.account(let failure), _) = result {
            recordAccountFailure(failure)
        }
        await ck.drainPairing()
        await ck.drainStatus()
        if case .success = result, accountGeneration == accountFailureGeneration {
            clearAccountFailure()
        }
        return result.dispatchedCount > 0
    }

    private func recordAccountFailure(_ failure: DeviceSyncAccountFailure) {
        accountFailureGeneration &+= 1
        let changed = accountFailure != failure
        accountFailure = failure
        syncStatus = DeviceSyncAccountFailure.macMessage
        let url = ICloudSyncStatePaths.accountFailure(dataRoot: sync.dataRoot)
        guard changed || !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(failure).write(to: url, options: .atomic)
        } catch {
            nativeLog("[iCloudBridge] could not persist account failure: %@", error.localizedDescription)
        }
    }

    private func clearAccountFailure() {
        let url = ICloudSyncStatePaths.accountFailure(dataRoot: sync.dataRoot)
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch {
                nativeLog("[iCloudBridge] could not clear account failure: %@", error.localizedDescription)
                return
            }
        }
        guard accountFailure != nil else { return }
        accountFailure = nil
        syncStatus = "CloudKit ready"
    }

    /// 2026-09-06: the Mac is the retention owner for the shared CloudKit
    /// records — it is the always-on device, and the phone never deletes. The
    /// sweep used to run INSIDE the drain's single-flight window, where its
    /// CloudKit round-trips (a 10 s query plus a 15 s delete, per record type)
    /// held off the next drain by up to 50 s in the worst timeout sequence and
    /// delayed message delivery by that much. It is housekeeping: it gets its
    /// own single-flight slot at low priority, and no drain ever waits on it.
    /// The transport still self-throttles (hourly) and bounds each run.
    private func startDeviceRetentionSweepIfIdle(_ ck: DeviceSyncTransport) {
        guard !deviceRetentionSweepInFlight else { return }
        deviceRetentionSweepInFlight = true
        deviceRetentionSweepTask = Task(priority: .utility) { [weak self] in
            await ck.sweepExpiredRecords()
            self?.deviceRetentionSweepInFlight = false
        }
    }

    // MARK: - Poll / flush iOS outbox (called by metadata query or on-demand)

    func checkIosOutbox() {
        guard let docsURL = driveURL else { return }
        guard !messageHandlers.isEmpty else {
            syncStatus = "iPhone message waiting — starting Mac receiver"
            return
        }
        if outboxScanInFlight {
            outboxScanQueued = true
            return
        }
        let seenSnapshot = seenMessageIDs
        let inFlightSnapshot = inFlightIncomingMessageIDs
        let secret: Data
        do {
            secret = try testPairingSecret ?? PairingSecretManager.loadOrGenerateSecret()
        } catch {
            syncStatus = "iPhone pairing unavailable — repair the Mac pairing key"
            nativeLog("[iCloudBridge] pairing authority unavailable during Drive scan: %@", error.localizedDescription)
            return
        }
        outboxScanInFlight = true
        outboxScanGeneration &+= 1
        let scanGeneration = outboxScanGeneration
        let testScanHook = testOutboxScanHook
        outboxScanTask = Task.detached(priority: .utility) { [docsURL, seenSnapshot, inFlightSnapshot, secret, testScanHook] in
            do {
                try testScanHook?()
                let scan = Self.scanIosOutboxFiles(
                    docsURL: docsURL,
                    seenMessageIDs: seenSnapshot,
                    inFlightMessageIDs: inFlightSnapshot,
                    secret: secret
                )
            await MainActor.run {
                guard self.outboxScanGeneration == scanGeneration else { return }
                self.outboxScanInFlight = false
                self.outboxScanTask = nil
                defer {
                    if self.outboxScanQueued {
                        self.outboxScanQueued = false
                        self.checkIosOutbox()
                    }
                }
                guard !Task.isCancelled else { return }
                for id in scan.seenIDs {
                    self.recordSeenMessageID(id)
                }
                if !scan.seenIDs.isEmpty {
                    let idsSnapshot = self.seenMessageIDsOrdered
                    Task.detached(priority: .utility) { [idsSnapshot, docsURL] in
                        Self.saveProcessedMessageIDs(idsSnapshot, docsURL: docsURL)
                    }
                }
                guard !scan.messages.isEmpty else { return }
                self.lastSyncAt = Date()
                self.syncStatus = "Received message from iOS"
                // fix-2026-06-10 sync-audit #3: process backlogged messages
                // SEQUENTIALLY in arrival order. The previous per-message
                // unstructured Task ran the whole backlog concurrently, and
                // forwardToSwiftRuntime's registerActiveChatTask cancels any
                // existing task per sessionID — so two same-session messages
                // queued offline cancelled each other mid-stream. The cancel
                // semantics (new LIVE message supersedes) are unchanged; the
                // backlog just no longer races itself.
                // Claim each id AS ITS TURN STARTS, not up front (gpt-5.5
                // review: an up-front claim strands every later message as
                // permanently in-flight if one handler hangs — defers never
                // run on a hang). With per-start claiming, a hung item leaves
                // the REST unclaimed for the next scan, and a later same-
                // session message unwedges the hang via the supersede-cancel.
                // Check-then-insert runs with no await in between (MainActor),
                // so duplicate ids within or across scans dispatch only once.
                // Explicit control messages must not wait behind a streaming turn.
                let handoffs = scan.messages.filter { UserMessageIntentSignals.isControlHandoff($0.message.text) }
                let ordinary = scan.messages.filter { !UserMessageIntentSignals.isControlHandoff($0.message.text) }
                let backlog = handoffs + ordinary
                Task { @MainActor in
                    for pending in backlog {
                        guard !self.seenMessageIDs.contains(pending.message.id),
                              !self.inFlightIncomingMessageIDs.contains(pending.message.id) else { continue }
                        do {
                            try await SignedPeerEvidenceStore.record(
                                eventID: pending.message.id,
                                channel: .chat,
                                peerCreatedAt: pending.message.timestamp,
                                dataRoot: self.testDataRoot ?? PersistenceCore.defaultDataRoot()
                            )
                        } catch {
                            nativeLog("[iCloudBridge] could not persist signed peer evidence for %@: %@",
                                  pending.message.id, error.localizedDescription)
                        }
                        let delivery = await self.deliverIncomingChat(pending.message)
                        if delivery != .deferred {
                            // E3: same owed-reply bookkeeping as the CloudKit lane.
                            self.drainPolicy.noteOutstanding(pending.message.id, at: Date())
                            if delivery == .delivered {
                                await Self.appendInboundSuccessReceipt(
                                    pending.message,
                                    transport: "icloud_drive",
                                    secret: secret,
                                    dataRoot: self.testDataRoot ?? PersistenceCore.defaultDataRoot()
                                )
                            }
                            await self.markIosMessageProcessed(pending, docsURL: docsURL, recordIdentity: delivery != .rejected)
                        } else {
                            self.markMacRuntimeUnavailable()
                        }
                    }
                }
            }
            } catch {
                await MainActor.run {
                    guard self.outboxScanGeneration == scanGeneration else { return }
                    self.outboxScanInFlight = false
                    self.outboxScanTask = nil
                    defer {
                        if self.outboxScanQueued {
                            self.outboxScanQueued = false
                            self.checkIosOutbox()
                        }
                    }
                    guard !Task.isCancelled else { return }
                    self.syncStatus = "iPhone inbox scan failed — retained claims will retry: \(error.localizedDescription)"
                }
            }
        }
    }

    struct PendingOutboxMessage: Sendable {
        var message: BridgeMessage
        var fileURL: URL
    }

    nonisolated static func processedMessageIDsURL(docsURL: URL) -> URL {
        docsURL
            .appendingPathComponent(DriveFolder.processed)
            .appendingPathComponent("ios_chat_processed_ids.json")
    }

    // fix-2026-06-10 sync-audit #2: load/save the ORDERED id array (oldest →
    // newest) so eviction is insertion-ordered, not the old lexicographic
    // .sorted().suffix() which evicted age-randomly.
    nonisolated static func loadProcessedMessageIDs(docsURL: URL) -> [String] {
        let url = processedMessageIDsURL(docsURL: docsURL)
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return ids
    }

    nonisolated static func saveProcessedMessageIDs(_ ids: [String], docsURL: URL) {
        let url = processedMessageIDsURL(docsURL: docsURL)
        let capped = Array(ids.suffix(seenMessageIDsCap))
        guard let data = try? JSONEncoder().encode(capped) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func markIosMessageProcessed(_ pending: PendingOutboxMessage, docsURL: URL, recordIdentity: Bool) async {
        let processedDir = docsURL.appendingPathComponent(DriveFolder.processed)
        if recordIdentity { recordSeenMessageID(pending.message.id) }
        let dest = processedDir.appendingPathComponent(pending.fileURL.lastPathComponent)
        let idsSnapshot = seenMessageIDsOrdered
        let sourceURL = pending.fileURL
        await Task.detached(priority: .utility) { [idsSnapshot, docsURL, dest, sourceURL] in
            Self.saveProcessedMessageIDs(idsSnapshot, docsURL: docsURL)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try? FileManager.default.moveItem(at: sourceURL, to: dest)
        }.value
        lastSyncAt = Date()
        syncStatus = "iPhone request processed"
    }

    nonisolated static func scanIosOutboxFiles(
        docsURL: URL,
        seenMessageIDs: Set<String>,
        inFlightMessageIDs: Set<String>,
        secret: Data
    ) -> (messages: [PendingOutboxMessage], seenIDs: [String]) {
        let iosOutbox = docsURL.appendingPathComponent(DriveFolder.outboxIos)
        let processingDir = docsURL.appendingPathComponent(DriveFolder.processing)
        let processedDir = docsURL.appendingPathComponent(DriveFolder.processed)
        let fm = FileManager.default
        var messages: [PendingOutboxMessage] = []
        var seenIDs: [String] = []

        try? fm.startDownloadingUbiquitousItem(at: iosOutbox)
        try? fm.createDirectory(at: processingDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: processedDir, withIntermediateDirectories: true)

        let outboxFiles = (try? fm.contentsOfDirectory(
            at: iosOutbox, includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        let processingFiles = (try? fm.contentsOfDirectory(
            at: processingDir, includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []

        let jsonFiles = (outboxFiles + processingFiles).filter { $0.pathExtension == "json" }
            .sorted { ($0.lastPathComponent) < ($1.lastPathComponent) }

        for fileURL in jsonFiles {
            var currentURL = fileURL
            if fileURL.deletingLastPathComponent().lastPathComponent != "processing" {
                let claimed = processingDir.appendingPathComponent(fileURL.lastPathComponent)
                if fm.fileExists(atPath: claimed.path) {
                    try? fm.removeItem(at: claimed)
                }
                do {
                    try fm.moveItem(at: fileURL, to: claimed)
                    currentURL = claimed
                } catch {
                    continue
                }
            }
            guard let data = try? Data(contentsOf: currentURL) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let msg = try? decoder.decode(BridgeMessage.self, from: data) else {
                let dest = processedDir.appendingPathComponent("malformed_\(currentURL.lastPathComponent).done")
                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: dest)
                }
                try? fm.moveItem(at: currentURL, to: dest)
                continue
            }
            // A metadata-query rescan can see the file while its first handler
            // is still awaiting the model. Leave it claimed in `processing` so
            // a transient handler failure remains retryable. Treating in-flight
            // as already-seen used to move it to duplicate_*.done and could drop
            // that retry permanently.
            if inFlightMessageIDs.contains(msg.id) {
                continue
            }
            if seenMessageIDs.contains(msg.id) || seenIDs.contains(msg.id) {
                let dest = processedDir.appendingPathComponent("duplicate_\(currentURL.lastPathComponent).done")
                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: dest)
                }
                try? fm.moveItem(at: currentURL, to: dest)
                continue
            }

            // The shared pairing key authenticates both directions. A signed
            // Mac reply copied into this directory is not iPhone input.
            guard msg.sender == "ios" else {
                nativeLog("[iCloudBridge] dropping wrong-direction iOS outbox message %@", msg.id)
                let dest = processedDir.appendingPathComponent("rejected_sender_\(currentURL.lastPathComponent).done")
                try? fm.moveItem(at: currentURL, to: dest)
                continue
            }

            // Require HMAC on chat as well as action sync. Without this, a file
            // dropped into iCloud Drive could bypass the signed action channel
            // and still reach the Mac chat runtime.
            if msg.signature == nil || !msg.verifySignature(secret: secret) {
                // Unauthenticated identity never earns an accepted ID or a
                // signed response. Preserve the exact bytes under their digest.
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let dest = processedDir.appendingPathComponent("rejected_signature_\(digest).done")
                do {
                    try data.write(to: dest, options: .atomic)
                    try fm.removeItem(at: currentURL)
                } catch {
                    nativeLog("[iCloudBridge] signature quarantine unavailable: %@", error.localizedDescription)
                }
                continue
            }
            messages.append(PendingOutboxMessage(message: msg, fileURL: currentURL))
        }
        messages.sort {
            if $0.message.timestamp != $1.message.timestamp {
                return $0.message.timestamp < $1.message.timestamp
            }
            return $0.fileURL.lastPathComponent < $1.fileURL.lastPathComponent
        }
        return (messages, seenIDs)
    }

    // MARK: - NSMetadataQuery (watches iOS outbox for new iCloud files)

    private func startMetadataQuery(docsURL: URL) {
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(
            format: "%K BEGINSWITH %@",
            NSMetadataItemPathKey,
            docsURL.appendingPathComponent(DriveFolder.outboxIos).path
        )
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        metadataQuery = q

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: q
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidUpdate(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: q
        )
        q.start()
    }

    // 2026-05-09: NotificationCenter posts these on whatever queue the
    // poster used (NSMetadataQuery: private worker queue; KVS daemon:
    // com.apple.kvs.client.callback).  iCloudBridge is @MainActor, so
    // calling self.* from a non-main queue trips the Swift executor
    // assertion (SIGTRAP/EXC_BREAKPOINT).  Mark the @objc selectors
    // nonisolated and hop to MainActor inside.
    @objc private nonisolated func metadataQueryDidUpdate(_ note: Notification) {
        Task { @MainActor in
            self.metadataQuery?.disableUpdates()
            self.checkIosOutbox()
            self.metadataQuery?.enableUpdates()
        }
    }

    // MARK: - KVS change handler

    @objc private nonisolated func kvsDidChange(_ note: Notification) {
        let changedKeys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        Task { @MainActor in
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
            for key in changedKeys ?? [] {
                guard let value = NSUbiquitousKeyValueStore.default.string(forKey: key) else { continue }
                self.deliverObservedStatus(key: key, value: value)
            }
        }
    }

    // MARK: - Cleanup

    public func tearDown() {
        // Cancel + invalidate any in-flight container resolve so a late
        // applyContainerResult can't re-register observers after teardown.
        setupTask?.cancel()
        setupTask = nil
        setupGeneration += 1
        incomingObserverGeneration &+= 1
        incomingObserverInstalled = false
        outboxScanGeneration &+= 1
        outboxScanTask?.cancel()
        outboxScanTask = nil
        outboxScanInFlight = false
        outboxScanQueued = false
        metadataQuery?.stop()
        metadataQuery = nil
        NotificationCenter.default.removeObserver(self)
        messageHandlers = []
        statusKeyHandlers = [:]
        cloudKitObservedStatusKeys = []
        deviceTransport = nil  // CK-3b: drop the transport; setup() re-resolves it
        deviceTransportSelection = .legacyKVS
        cloudKitVisualNotificationPeerReady = false
        lastPublishedProviderCatalogStatus = nil
        lastPublishedMobileSnapshotStatus = [:]
        deviceDrainTimerTask?.cancel()  // CK-3c: stop the poll
        deviceDrainTimerTask = nil
        deviceDrainInFlight = false
        deviceDrainQueued = false
        deviceRetentionSweepTask?.cancel()  // 2026-09-06: stop the retention sweep
        deviceRetentionSweepTask = nil
        deviceRetentionSweepInFlight = false
        if let deliveryNudgeQueue {
            Task { await deliveryNudgeQueue.cancelAll() }
            self.deliveryNudgeQueue = nil
        }
        // N8 fix (R16): reset isSetUp so a subsequent setup() call can succeed.
        // Without this, tearDown() left isSetUp=true and setup() returned early
        // at the guard-!isSetUp check, leaving the bridge permanently stopped.
        isSetUp = false
        // PATCH-2026-05-07: ios-parity stop sync engine
        sync.engine.stop()
    }
}

// BridgeError is now in NativeAgentShared.
