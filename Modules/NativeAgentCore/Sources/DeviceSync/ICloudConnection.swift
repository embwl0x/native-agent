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
// Blueprint: | `ICloudConnection.swift` | Checked CloudKit setup and account connection; push, wake and NetworkSense return events drain the one transport; unavailable registration is reported without a polling reader |
extension iCloudBridge {
    public func setup() {
        // N10 fix: guard against repeat setup() calls stacking KVS observers.
        guard !isSetUp else { return }
        isSetUp = true
        if pairedPhonesSubscription == nil {
            pairedPhonesSubscription = sync.pairedPhones.$phones.sink { [weak self] _ in
                Task { @MainActor in self?.refreshPhoneConnection() }
            }
        }
        do {
            lastPhoneContactAt = try SignedPeerEvidenceStore.load(dataRoot: sync.dataRoot)?.contactAt
            phoneContactReadFailure = nil
        } catch {
            phoneContactReadFailure = error.localizedDescription
        }
        doctorTransportHealth = .unmeasured
        doctorSendFailures.removeAll()
        doctorSendMeasured = false
        syncStatus = "iCloud connecting…"
        setupTask?.cancel()
        setupGeneration += 1
        let generation = setupGeneration
        // Restore the persisted replay window before the first receive event.
        guard loadCKSeenIDs() else { return }
        recordCloudKitPushEvidence()
        // CloudKit is independent of the ubiquity/Drive mount. Public
        // Developer ID builds may have the CloudKit service without
        // CloudDocuments; the required transport is entitlement-checked here.
        configureDeviceTransportIfAvailable()
        guard deviceTransport != nil else {
            available = false
            syncStatus = transportRefusal?.line ?? "CloudKit transport unavailable — repair this app's iCloud signing and container configuration."
            doctorTransportHealth = .unavailable(syncStatus)
            return
        }
        setupTask = Task {
            let failure = await sync.engine.start()
            guard generation == setupGeneration, isSetUp, !Task.isCancelled else { return }
            if let failure { syncStatus = failure }
            NotificationCenter.default.addObserver(
                self, selector: #selector(kvsDidChange(_:)),
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil)
            Task.detached(priority: .utility) {
                _ = await withCKTimeout("iCloudBridge.setup.cloudKitKVSNudge") {
                    NSUbiquitousKeyValueStore.default.synchronize()
                }
            }
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
        let loaded = await VolumeIO.result { [docsURL] in
            Self.createDriveDirectories(docsURL: docsURL)
            return try Self.loadProcessedMessageIDs(docsURL: docsURL)
        }
        // Only the current setup may publish the completed file batch.
        guard generation == setupGeneration, isSetUp else { return }
        let ids: [String]
        switch loaded {
        case .success(let value): ids = value
        case .failure(let error):
            available = false
            syncStatus = "Retained Drive replay evidence is unavailable: \(error.localizedDescription). Restore its processed-message store before resuming."
            return
        }
        // Restore insertion order so eviction remains oldest-first.
        seenMessageIDs = []
        seenMessageIDsOrdered = []
        for id in ids where seenMessageIDs.insert(id).inserted {
            seenMessageIDsOrdered.append(id)
        }
        // CK-3c: also restore CK-consumed ids (UserDefaults) into the unified
        // seen-set so a restart doesn't re-deliver a CloudKit message.
        guard loadCKSeenIDs() else { return }
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
    /// The factory remains the sole entitlement guard; refusal closes setup.
    private func configureDeviceTransportIfAvailable() {
        guard deviceTransport == nil else { return }
        let transport: CloudKitDeviceTransport
        do {
            transport = try DeviceSyncTransportResolver.makeCloudKitTransport(
                role: .mac, containerIdentifier: NativeAgentICloudBridgeConstants.containerID)
        } catch {
            recordTransportOrgansOff("CloudKit transport unavailable")
            transportRefusal = .init(.broken, error.localizedDescription, owner: .builder,
                lever: "Install a NativeAgent build configured and signed for its CloudKit container.")
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
        transport.observeStatus(key: NAPhoneForegroundPresence.statusKey, pairingSecret: {
            guard let encoded = try? PairingSecret.existingSecretBase64() else { return nil }
            return Data(base64Encoded: encoded)
        }) { [weak self] value, writtenAt, originatingPairing in
            await self?.acceptPhoneForegroundPresence(value, writtenAt: writtenAt,
                originatingPairing: originatingPairing, generation: generation) ?? false
        }
        let previous = transportSetupTask
        previous?.cancel()
        let taskID = UUID()
        transportSetupTaskID = taskID
        transportSetupTask = Task {
            defer { if transportSetupTaskID == taskID { transportSetupTask = nil } }
            await previous?.value
            guard !Task.isCancelled, isSetUp, generation == setupGeneration else { return }
            await claimPhonePairing()
            guard !Task.isCancelled, isSetUp, generation == setupGeneration else { return }
            do { try await transport.subscribeToStatusChanges() }
            catch { nativeLog("[iCloudBridge] phone presence subscription failed: %@", error.localizedDescription) }
            guard !Task.isCancelled, isSetUp, generation == setupGeneration else { return }
            await transport.drainStatus()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(deviceDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        let paths = NetworkSense.changes
        deviceNetworkChanges = Task { [weak self] in
            var receivedState = false
            for await up in paths {
                guard let self, !Task.isCancelled, self.isSetUp,
                      self.setupGeneration == generation else { return }
                // The first value is a replay; later up edges are returns even
                // if a busy drain coalesced the intervening offline value.
                let regained = receivedState && up
                receivedState = true
                if regained { _ = await self.drainDeviceTransport(trigger: .network) }
            }
        }
        NSApplication.shared.registerForRemoteNotifications(matching: [])
    }
    @objc private func deviceDidWake() {
        Task { _ = await self.drainDeviceTransport(trigger: .wake) }
    }
    private func acceptPhoneForegroundPresence(_ value: String, writtenAt: Date?, originatingPairing: Data, generation: Int) -> Bool {
        guard isSetUp, generation == setupGeneration, !phonePairedElsewhere,
              let encoded = try? PairingSecret.existingSecretBase64(),
              let secret = Data(base64Encoded: encoded),
              secret == originatingPairing,
              let contact = NAPhoneForegroundPresence.activityDate(value: value, writtenAt: writtenAt,
                  secret: secret, now: Date()) else { return false }
        notePhoneContact(at: contact)
        return true
    }
    var deviceReceiveNote: String {
        cloudKitPushUnavailable ? "push unavailable — repair APNs registration; receive resumes on push or an explicit refresh" : ""
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
    /// The drain and the presence beat run only over the transport: without it
    /// they are off, not overdue.
    func recordTransportOrgansOff(_ reason: String) {
        for organ in ["icloud_drain", "presence_beat"] { OrganPulse.recordOff(organ, because: reason) }
    }
    /// Registration alone does not prove the subscription can wake this process.
    public func cloudKitPushRegistrationSucceeded() {
        Self.pushLog.notice("APNs registration succeeded")
        // Registration alone cannot clear a failed subscription or prove an
        // end-to-end wake. A received chat push below proves that path works.
    }
    public func cloudKitPushRegistrationFailed(_ error: Error) {
        Self.pushLog.error("APNs registration failed: \(error.localizedDescription, privacy: .private)")
        guard deviceTransport != nil else { return }
        syncStatus = "CloudKit receive wake registration failed: \(error.localizedDescription). Repair APNs registration; open Connection to refresh explicitly."
        nativeLog("[iCloudBridge] CloudKit push unavailable; repair APNs registration to restore receive wakes")
        recordCloudKitPushUnavailable()
    }
    func recordCloudKitPushUnavailable() {
        cloudKitPushUnavailable = true
        OrganPulse.record("icloud_drain", .skipped, note: deviceReceiveNote)
        recordCloudKitPushEvidence(received: false)
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
        if CloudKitDeviceTransport.isStatusNotification(userInfo), let ck = deviceTransport {
            startDeviceMetadataDrainIfIdle(ck, force: true)
        }
        if CloudKitDeviceTransport.isChatNotification(userInfo) {
            recordCloudKitPushEvidence(received: true)
            cloudKitPushUnavailable = false
        }
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
