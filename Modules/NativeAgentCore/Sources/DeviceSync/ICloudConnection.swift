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
// Blueprint: | `ICloudConnection.swift` | Checked CloudKit/account setup; push and lifecycle events own drains. |
extension iCloudBridge {
    public func setup() {
        // Idempotent setup prevents duplicate KVS observers.
        guard !isSetUp else { return }
        isSetUp = true
        if pairedPhonesSubscription == nil {
            pairedPhonesSubscription = sync.pairedPhones.$phones.sink { [weak self] _ in
                Task { @MainActor in self?.refreshPhoneConnection() }
            }
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
        setupTask = Task {
            let root = sync.dataRoot
            await phoneContactRead.read({
                await sync.storage.perform { Result<Date?, Error> { try SignedPeerEvidenceStore.load(dataRoot: root)?.contactAt } }
            }, publish: { result in
                guard generation == setupGeneration, isSetUp else { return }
                switch result {
                case .success(let contact):
                    if let contact, contact > (lastPhoneContactAt ?? .distantPast) { lastPhoneContactAt = contact }
                    phoneContactReadFailure = nil
                case .failure(let error): phoneContactReadFailure = error.localizedDescription
                }
            })
            guard generation == setupGeneration, isSetUp, !Task.isCancelled else { return }
            await recordCloudKitPushEvidence()
            guard generation == setupGeneration, isSetUp, !Task.isCancelled else { return }
            // CloudKit can be entitled without CloudDocuments; validate its transport independently of the Drive mount.
            configureDeviceTransportIfAvailable()
            guard deviceTransport != nil else {
                available = false
                syncStatus = transportRefusal?.line ?? "CloudKit transport unavailable — repair this app's iCloud signing and container configuration."
                doctorTransportHealth = .unavailable(syncStatus)
                return
            }
            let failure = await sync.engine.start()
            guard generation == setupGeneration, isSetUp, !Task.isCancelled else { return }
            if let failure { syncStatus = failure }
            NotificationCenter.default.addObserver(
                self, selector: #selector(kvsDidChange(_:)),
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil)
            Task { [weak self] in
                let synchronized = await Task.detached(priority: .utility) {
                    NSUbiquitousKeyValueStore.default.synchronize()
                }.value
                guard let self, generation == self.setupGeneration, self.isSetUp else { return }
                if !synchronized {
                    self.syncStatus = "iCloud KVS setup synchronization was not accepted; its remote state is unconfirmed."
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
        // Restore consumed CloudKit IDs before receiving so a restart cannot redeliver them.
        guard loadCKSeenIDs() else { return }
        trimSeenMessageIDsIfNeeded()
        let failure = await sync.engine.start(docsURL: docsURL)
        guard generation == setupGeneration, isSetUp else { return }
        available = failure == nil
        syncStatus = failure ?? "iCloud readiness not checked"
        doctorTransportHealth = failure.map { .unavailable($0) } ?? .unmeasured
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(kvsDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil
        )
        let synchronized = await Task.detached(priority: .utility) {
            NSUbiquitousKeyValueStore.default.synchronize()
        }.value
        // Teardown can retire this setup during the final KVS suspension too.
        guard generation == setupGeneration, isSetUp, !Task.isCancelled else { return }
        if !synchronized { syncStatus = "iCloud KVS setup synchronization was not accepted; its remote state is unconfirmed." }
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
    /// The factory's entitlement guard must admit CloudKit without depending on a Drive mount.
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
        startDeviceReceiveBeat()
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
        }) { [weak self] value, writtenAt, originatingPairing, _ in
            // The Mac's presence read runs no push recovery: its recovery budget is the phone's.
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
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(deviceActivityChanged), name: name, object: nil)
        }
        let paths = NetworkSense.changes
        deviceNetworkChanges = Task { [weak self] in
            var receivedState = false
            for await up in paths {
                guard let self, !Task.isCancelled, self.isSetUp,
                      self.setupGeneration == generation else { return }
                // The first value is replay; later up edges count even if a busy drain coalesced the offline edge.
                let regained = receivedState && up
                receivedState = true
                if regained {
                    self.sync.engine.requestPresencePublication()
                    _ = await self.drainDeviceTransport(trigger: .network)
                }
            }
        }
        NSApplication.shared.registerForRemoteNotifications(matching: [])
    }
    @objc private func deviceDidWake() {
        sync.engine.requestPresencePublication()
        Task { _ = await self.drainDeviceTransport(trigger: .wake) }
    }
    @objc private func deviceActivityChanged() {
        sync.engine.requestPresencePublication()
    }
    private func acceptPhoneForegroundPresence(_ value: String, writtenAt: Date?, originatingPairing: Data, generation: Int) async -> Bool {
        guard isSetUp, generation == setupGeneration, !phonePairedElsewhere else { return false }
        let secret: Data
        do {
            secret = try await sync.storage.perform { try PairingSecret.requireExistingSecret() }
        } catch {
            guard isSetUp, generation == setupGeneration else { return false }
            pairingKeyUnreadable = true
            syncStatus = "Phone contact could not check the Mac pairing key: \(error.localizedDescription). Repair the pairing key."
            refreshPhoneConnection()
            return false
        }
        guard isSetUp, generation == setupGeneration, !phonePairedElsewhere, secret == originatingPairing else { return false }
        let contact: Date
        do {
            contact = try await sync.storage.perform {
                try NAPhoneForegroundPresence.activityDate(value: value, writtenAt: writtenAt, secret: secret)
            }
        } catch {
            guard isSetUp, generation == setupGeneration else { return false }
            syncStatus = "Phone contact could not be read: \(error.localizedDescription). Repair the signed phone contact."
            return false
        }
        guard isSetUp, generation == setupGeneration, !phonePairedElsewhere else { return false }
        notePhoneContact(at: contact)
        return true
    }
    var deviceReceiveNote: String {
        cloudKitPushUnavailable ? "push unavailable — repair APNs registration; incoming reads continue independently" : ""
    }
    /// Actual push receipt or APNs refusal owns wake evidence; silence has no verdict.
    func recordCloudKitPushEvidence(received: Bool? = nil) async {
        let url = sync.dataRoot.appendingPathComponent("icloud/chat_push_proof.json")
        let generation = setupGeneration
        let observedAt = Date()
        let previous = cloudKitPushEvidenceTask
        let task = Task {
            await previous?.value
            guard generation == setupGeneration, isSetUp else { return }
            if let received {
                let proof: Date? = received ? observedAt : nil
                do {
                    try await sync.storage.perform {
                        let data = try JSONEncoder().encode(proof)
                        do { if try Data(contentsOf: url) == data { return } }
                        catch CocoaError.fileReadNoSuchFile { /* A first observation needs its own durable record. */ }
                        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url)
                    }
                    guard generation == setupGeneration, isSetUp else { return }
                    cloudKitPushProofRead.write { cloudKitPushProofAt = proof }
                } catch { nativeLog("[iCloudBridge] push evidence unavailable: %@", error.localizedDescription) }
            } else {
                await cloudKitPushProofRead.read({
                    await sync.storage.perform { Result<Date?, Error> {
                        do { return try JSONDecoder().decode(Date?.self, from: Data(contentsOf: url)) }
                        catch CocoaError.fileReadNoSuchFile { return nil }
                    } }
                }, publish: { outcome in
                    guard generation == setupGeneration, isSetUp else { return }
                    switch outcome {
                    case .success(let proof): cloudKitPushProofAt = proof
                    case .failure(let error): nativeLog("[iCloudBridge] push evidence unavailable: %@", error.localizedDescription)
                    }
                })
            }
        }
        cloudKitPushEvidenceTask = task
        await task.value
    }
    /// Drain and presence are off without a transport, never overdue.
    func recordTransportOrgansOff(_ reason: String) {
        for organ in ["icloud_drain", "presence_beat"] { OrganPulse.recordOff(organ, because: reason) }
    }
    /// Registration alone does not prove the subscription can wake this process.
    public func cloudKitPushRegistrationSucceeded() {
        Self.pushLog.notice("APNs registration succeeded")
        // Registration cannot clear subscription failure; only a received chat push proves end-to-end wake.
    }
    public func cloudKitPushRegistrationFailed(_ error: Error) async {
        Self.pushLog.error("APNs registration failed: \(error.localizedDescription, privacy: .private)")
        guard deviceTransport != nil else { return }
        syncStatus = """
            CloudKit receive wake registration failed: \(error.localizedDescription). Repair APNs registration; open Connection to refresh explicitly.
            """
        nativeLog("[iCloudBridge] CloudKit push unavailable; repair APNs registration to restore receive wakes")
        await recordCloudKitPushUnavailable()
    }
    func recordCloudKitPushUnavailable() async {
        cloudKitPushUnavailable = true
        OrganPulse.record("icloud_drain", .held, note: deviceReceiveNote)
        await recordCloudKitPushEvidence(received: false)
    }
    public func recognizesCloudKitRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        let recognized = CloudKitDeviceTransport.isDeviceSyncNotification(userInfo)
        if CloudKitDeviceTransport.isPairingNotification(userInfo) { phonePairingRecheckDue = true }
        Self.pushLog.notice("Remote notification received deviceSync=\(recognized)")
        return recognized
    }
    public func handleCloudKitPushWake(_ userInfo: [AnyHashable: Any]) async {
        let generation = setupGeneration
        if phonePairingRecheckDue || !phonePairingSettled {
            phonePairingRecheckDue = false
            await claimPhonePairing()
        }
        guard isSetUp, generation == setupGeneration, !phonePairedElsewhere else { return }
        if CloudKitDeviceTransport.isStatusNotification(userInfo), let ck = deviceTransport {
            startDeviceMetadataDrainIfIdle(ck)
        }
        if CloudKitDeviceTransport.isChatNotification(userInfo) {
            await recordCloudKitPushEvidence(received: true)
            guard isSetUp, generation == setupGeneration else { return }
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
