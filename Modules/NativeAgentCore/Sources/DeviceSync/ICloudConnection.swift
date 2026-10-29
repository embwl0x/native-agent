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
// Blueprint: | `ICloudConnection.swift` | Account, connection, transport registration and receive cadence |
extension iCloudBridge {
    public func setup() {
        // N10 fix: guard against repeat setup() calls stacking KVS observers.
        guard !isSetUp else { return }
        isSetUp = true
        // A stored sentence from an earlier key change could never settle; the
        // owed publication (the pairing fact) says it now, and settles itself.
        UserDefaults.standard.removeObject(forKey: "NativeAgent.pairing.publicationWarning.v1")
        if pairedPhonesSubscription == nil {
            pairedPhonesSubscription = sync.pairedPhones.$phones.sink { [weak self] _ in
                Task { @MainActor in self?.refreshPhoneConnection() }
            }
        }
        lastPhoneContactAt = SignedPeerEvidenceStore.load(dataRoot: sync.dataRoot)?.contactAt
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
        recordCloudKitPushEvidence()
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
            setupTask = Task {
                let failure = await sync.engine.start()
                guard generation == setupGeneration, isSetUp, !Task.isCancelled else { return }
                if let failure { syncStatus = failure }
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
            }
            return
        }
        // Without the CloudKit transport, KVS is the pairing channel itself.
        Task.detached(priority: .userInitiated) { await PairingSecret.publishMaterialToKVS() }
        // Resolve the blocking Drive mount on the volume executor.
        let containerID = NativeAgentICloudBridgeConstants.containerID
        setupTask = Task {
            let containerURL = await VolumeIO.run {
                FileManager.default.url(forUbiquityContainerIdentifier: containerID)
            }
            await applyContainerResult(containerURL, generation: generation)
        }
    }
    /// Apply a container lookup only while its setup still owns the lifecycle.
    @MainActor
    func applyContainerResult(_ containerURL: URL?, generation: Int) async {
        // Ignore a stale resolve from a superseded setup()/tearDown().
        guard generation == setupGeneration, isSetUp else { return }
        guard let containerURL else {
            // Reset isSetUp so the caller can retry later once iCloud signs in.
            isSetUp = false
            available = false
            syncStatus = "iCloud container unavailable — sign into iCloud in System Settings"
            doctorTransportHealth = .unavailable(syncStatus)
            OrganPulse.recordOff("snapshot_integrity", because: "iCloud Drive unavailable")
            return
        }
        let docsURL = containerURL.appendingPathComponent("Documents")
        driveURL = docsURL
        let loaded = await VolumeIO.run { [docsURL] in
            Self.createDriveDirectories(docsURL: docsURL)
            return Self.loadProcessedMessageIDs(docsURL: docsURL)
        }
        // Only the current setup may publish the completed file batch.
        guard generation == setupGeneration, isSetUp else { return }
        // Restore insertion order so eviction remains oldest-first.
        seenMessageIDs = []
        seenMessageIDsOrdered = []
        for id in loaded where seenMessageIDs.insert(id).inserted {
            seenMessageIDsOrdered.append(id)
        }
        // CK-3c: also restore CK-consumed ids (UserDefaults) into the unified
        // seen-set so a restart doesn't re-deliver a CloudKit message.
        loadCKSeenIDs()
        trimSeenMessageIDsIfNeeded()
        let failure = await sync.engine.start(docsURL: docsURL)
        guard generation == setupGeneration, isSetUp else { return }
        available = failure == nil
        syncStatus = failure ?? "iCloud readiness not checked"
        doctorTransportHealth = failure.map { .unavailable($0) } ?? .unmeasured
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
        // Teardown can retire this setup during the final KVS suspension too.
        guard generation == setupGeneration, isSetUp, !Task.isCancelled else { return }
        // Start NSMetadataQuery watching iOS outbox folder
        startMetadataQuery(docsURL: docsURL)
    }
    /// Publication reports acceptance of the requested groups, not readiness.
    func notePublication(_ failures: [NAMobileSnapshotGroup: DeviceSyncError]?) {
        guard accountFailure == nil, !phonePairedElsewhere else { return }
        guard let failures else { syncStatus = "CloudKit publication unconfirmed"; return }
        syncStatus = failures.min(by: { $0.key.rawValue < $1.key.rawValue }).map {
            "CloudKit did not accept the phone's \($0.key.rawValue) snapshot: \($0.value.localizedDescription)"
        } ?? "CloudKit accepted the requested snapshots"
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
            recordTransportOrgansOff("no CloudKit transport")
            transportRefusal = Self.cloudKitRefusal(containerID: containerID)
            return
        }
        transportRefusal = nil
        deviceTransport = transport
        OrganPulse.recordStarting("presence_beat", cadence: NAMacPresence.beat)
        transport.useAssetSecret {
            guard let encoded = try? PairingSecret.existingSecretBase64() else { return nil }
            return Data(base64Encoded: encoded)
        }
        transport.observeAccountFailures { [weak self] failure in
            await self?.recordAccountFailure(failure)
        }
        available = true
        syncStatus = "CloudKit connecting…"
        nativeLog("[iCloudBridge] device transport: CloudKit ACTIVE (role=mac)")
        registerIncomingTransportObserver(transport)
        let generation = setupGeneration
        let previous = transportSetupTask
        previous?.cancel()
        let taskID = UUID()
        transportSetupTaskID = taskID
        transportSetupTask = Task {
            defer { if transportSetupTaskID == taskID { transportSetupTask = nil } }
            await previous?.value
            guard !Task.isCancelled, isSetUp, generation == setupGeneration else { return }
            await claimPhonePairing()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(deviceDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        let monitor = NWPathMonitor()
        deviceNetworkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.setupGeneration == generation else { return }
                let regained = self.deviceNetworkSatisfied == false && satisfied
                self.deviceNetworkSatisfied = satisfied
                if regained { _ = await self.drainDeviceTransport(trigger: .network) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "NativeAgent.DeviceSync.network"))
        scheduleNextDeviceDrainFallback()
        NSApplication.shared.registerForRemoteNotifications(matching: [])
    }
    @objc private func deviceDidWake() {
        Task { _ = await self.drainDeviceTransport(trigger: .wake) }
    }
    var deviceReceiveCadence: TimeInterval? {
        drainPolicy.interval(now: Date(), polling: !cloudKitPushProven,
            active: activeCloudKitChats > 0 || phoneRequests.hasPendingRequest)
    }
    var devicePollingNote: String {
        cloudKitPushProven ? "" : cloudKitPushUnavailable
            ? "polling: push unavailable" : "polling: push unproven"
    }
    /// A received push proves delivery across launches; an unannounced phone
    /// message older than two eight-second re-signals disproves it. This local
    /// scalar is separate from account failures, which a healthy pull clears.
    func recordCloudKitPushEvidence(received: Bool? = nil) {
        let url = sync.dataRoot.appendingPathComponent("icloud/chat_push_proof.json")
        do {
            if let received {
                cloudKitPushProofAt = received ? Date() : nil
                try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(cloudKitPushProofAt), to: url)
            } else if FileManager.default.fileExists(atPath: url.path) {
                cloudKitPushProofAt = try JSONDecoder().decode(Date?.self, from: Data(contentsOf: url))
            }
        } catch {
            nativeLog("[iCloudBridge] push evidence unavailable: %@", error.localizedDescription)
        }
    }
    func scheduleNextDeviceDrainFallback() {
        deviceDrainTimerTask?.cancel()
        deviceDrainTimerTask = nil
        guard isSetUp, deviceTransport != nil else {
            deviceDrainTimerTask = nil
            recordTransportOrgansOff("iPhone transport gone")
            return
        }
        guard !phonePairedElsewhere else {
            deviceDrainTimerTask = nil
            return
        }
        let now = Date()
        guard let delay = drainPolicy.nextDrainDelay(now: now, lastDrainAt: lastDeviceDrainAt,
            polling: !cloudKitPushProven, active: activeCloudKitChats > 0 || phoneRequests.hasPendingRequest) else {
            deviceDrainCadence = nil
            OrganPulse.recordOff("icloud_drain", because: "resting — waiting for change")
            return
        }
        let cadence = deviceReceiveCadence
        if deviceDrainCadence != cadence {
            deviceDrainCadence = cadence
            OrganPulse.record("icloud_drain", .skipped,
                note: devicePollingNote.isEmpty ? "starting" : devicePollingNote, cadence: cadence)
        }
        let delayNanoseconds = UInt64(delay * 1_000_000_000)
        let generation = setupGeneration
        deviceDrainTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self, self.isSetUp,
                  generation == self.setupGeneration else { return }
            // The handle owns only the sleeping timer, never the drain it wakes.
            // Streaming output re-arms this timer while the drain awaits the
            // chat. Retaining this handle there cancelled the final reply's
            // owner as soon as its first delta was sent.
            self.deviceDrainTimerTask = nil
            guard self.deviceReceiveCadence != nil else {
                self.scheduleNextDeviceDrainFallback()
                return
            }
            await self.drainDeviceTransport(trigger: .fallbackTimer)
        }
    }
    /// The drain and the presence beat run only over the transport: without it
    /// they are off, not overdue.
    func recordTransportOrgansOff(_ reason: String) {
        for organ in ["icloud_drain", "presence_beat"] { OrganPulse.recordOff(organ, because: reason) }
    }
    /// Registration alone does not prove the subscription can wake this process.
    public func cloudKitPushRegistrationSucceeded() {
        Self.pushLog.notice("APNs registration succeeded")
        guard deviceTransport != nil else { return }
        cloudKitPushUnavailable = false
        scheduleNextDeviceDrainFallback()
    }
    public func cloudKitPushRegistrationFailed(_ error: Error) {
        Self.pushLog.error("APNs registration failed: \(error.localizedDescription, privacy: .private)")
        guard deviceTransport != nil else { return }
        nativeLog("[iCloudBridge] CloudKit push unavailable; retaining polling fallback")
        recordCloudKitPushUnavailable()
    }
    func recordCloudKitPushUnavailable() {
        cloudKitPushUnavailable = true
        recordCloudKitPushEvidence(received: false)
        deviceDrainCadence = nil
        scheduleNextDeviceDrainFallback()
    }
    public func recognizesCloudKitRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        let recognized = CloudKitDeviceTransport.isDeviceSyncNotification(userInfo)
        if CloudKitDeviceTransport.isPairingNotification(userInfo) { phonePairingRecheckDue = true }
        Self.pushLog.notice("Remote notification received deviceSync=\(recognized)")
        return recognized
    }
    public func handleCloudKitPushWake(_ userInfo: [AnyHashable: Any]) async {
        if phonePairingRecheckDue || !phonePairingSettled {
            phonePairingRecheckDue = false
            await claimPhonePairing()
        }
        guard !phonePairedElsewhere else { return }
        if CloudKitDeviceTransport.isChatNotification(userInfo) {
            recordCloudKitPushEvidence(received: true)
            cloudKitPushUnavailable = false
        }
        // A push is peer activity; follow-up traffic keeps the fast cadence.
        drainPolicy.notePeerActivity(at: Date())
        _ = await drainDeviceTransport(trigger: .cloudKitPush)
    }
    nonisolated private static func createDriveDirectories(docsURL: URL) {
        let fm = FileManager.default
        for folder in [DriveFolder.outboxMac, DriveFolder.outboxIos, DriveFolder.processing, DriveFolder.processed] {
            let url = docsURL.appendingPathComponent(folder)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
