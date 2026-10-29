import Foundation
import UIKit
import NativeAgentShared
import CryptoKit
import SwiftUI
// Blueprint: | `iCloudBridge+CloudKit.swift` | CloudKit setup, pairing acquisition, presence and coalesced drains on iCloudBridge |

extension iCloudBridge {
    /// Reads the Mac's presence beat (nothing pushes it) into the confirmation,
    /// and the key the account's pairing record holds: a beat under this
    /// phone's key may be an old record of a Mac that has since changed keys.
    func readMacPresence() async {
        guard pairingStore?.isRepairingConnection != true,
              let secret = pairingStore?.iCloudPairingSecret else { return }
        let generation = setupGeneration
        if let seen = await deviceTransport?.peerPresence(pairingSecret: secret),
           setupGeneration == generation, pairingStore?.iCloudPairingSecret == secret,
           pairingStore?.isRepairingConnection != true {
            recordMacConfirmation(at: seen)
        }
        if let published = await deviceTransport?.peekPairingSecret(), setupGeneration == generation {
            macPairingKey = MacPairingKeyReading(recordKey: published, phoneKey: secret)
        }
    }

    /// Starts CloudKit before Drive lookup; PairingStore alone commits pairing material.
    func configureDeviceTransportIfAvailable() {
        let resolvedProductionTransport: Bool
        if deviceTransport == nil {
            guard let transport = DeviceSyncTransportResolver.makeCloudKitTransport(
                role: .ios,
                containerIdentifier: NativeAgentICloudBridgeConstants.containerID
            ) else { return }
            deviceTransport = transport
            resolvedProductionTransport = true
        } else {
            resolvedProductionTransport = false
        }
        guard let transport = deviceTransport else { return }
        transport.useAssetSecret { [weak self] in
            await self?.pairingSecretForPhoneRequests
        }
        let generation = setupGeneration
        transport.observeAccountFailures { [weak self] failure in
            guard await self?.setupGeneration == generation else { return }
            await self?.recordAccountFailure(failure)
        }
        available = true
        syncStatus = "CloudKit connecting…"
        NSLog("[iCloudBridge] device transport: CloudKit ACTIVE (role=ios)")

        // Register APNS before pairing so silent subscription pushes can arrive.
        if resolvedProductionTransport {
            UIApplication.shared.registerForRemoteNotifications()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(cloudKitAppDidBecomeActive(_:)),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
        }

        resumeDeliveryNudges()
        deviceIncomingSetupTask = Task {
            await iCloudSyncEngine.shared.enableCloudKitSnapshotCache()
            guard setupGeneration == generation else { return }
            _ = await transport.observeIncoming { [weak self = self] msg in
                guard await self?.setupGeneration == generation else { return false }
                return await self?.handleIncomingFromTransport(msg) ?? false
            }
            guard setupGeneration == generation else { return }
            _ = await transport.drainIncoming()
        }
        Task {
            await deviceIncomingSetupTask?.value
            _ = await transport.ensurePushSubscriptions()
            guard setupGeneration == generation else { return }
            await self.clearVisualNotificationCapability(using: transport)
        }
        Task {
            await transport.observePairing { [weak self = self] secret in
                guard await self?.setupGeneration == generation else { return false }
                return await self?.applyPairingMaterialFromTransport(secret) ?? false
            }
        }
        Task {
            // Claim the catalog only after successful application.
            transport.observeStatus(
                key: NAProviderCatalogStatusCodec.statusKey,
                onApply: { @MainActor [weak self = self] value, writtenAt in
                    guard self?.setupGeneration == generation else { return false }
                    let applied = await iCloudSyncEngine.shared.applyProviderCatalogStatus(value) {
                        self?.setupGeneration == generation
                    }
                    if applied, let writtenAt {
                        self?.recordMacConfirmation(at: writtenAt)
                    }
                    return applied
                }
            )
            for group in NAMobileSnapshotGroup.allCases {
                // Claim a snapshot generation only after durable application; failures remain eligible.
                transport.observeStatus(
                    key: group.statusKey,
                    onApply: { value, writtenAt in
                        guard await self.setupGeneration == generation else { return false }
                        return await iCloudSyncEngine.shared.applyCloudKitSnapshotStatus(
                            value,
                            group: group,
                            writtenAt: writtenAt
                        )
                    }
                )
            }
            do {
                try await transport.subscribeToStatusChanges()
            } catch {
                NSLog("[iCloudBridge] status subscription registration FAILED (no live push): \(error)")
            }
            guard setupGeneration == generation else { return }
            await transport.drainStatus()
        }
        Task {
            // Nothing pushes the Mac's presence beat; read it once now.
            guard self.setupGeneration == generation else { return }
            await self.readMacPresence()
        }
    }

    /// Foreground activation retries uncommitted pairing without idle polling.
    @objc private nonisolated func cloudKitAppDidBecomeActive(_ note: Notification) {
        Task { @MainActor in
            guard let transport = self.deviceTransport else { return }
            self.resumeDeliveryNudges()
            _ = await transport.ensurePushSubscriptions()
            await self.clearVisualNotificationCapability(using: transport)
            // Nothing pushes the Mac's presence beat; it is read on opening.
            if self.pairingStore?.isPaired == true { await self.readMacPresence() }
            if self.pairingStore?.isPaired != true {
                let pairingApplied = await transport.drainPairing()
                // Re-drain held messages after the pairing secret commits.
                guard pairingApplied, self.pairingStore?.isPaired == true else { return }
                _ = await self.drainDeviceTransport()
            }
        }
    }

    // Overwrite older peers' visual-ready claim; CloudKit only wakes sync.
    private func clearVisualNotificationCapability(using transport: CloudKitDeviceTransport) async {
        do {
            try await transport.setStatus(
                key: "notification.visual.capability",
                value: "nanotification-v2-max-three-desired-keys:unavailable"
            )
        } catch {
            NSLog("[iCloudBridge] visual notification capability publish failed: \(error)")
        }
    }

    private func applyPairingMaterialFromTransport(_ secret: Data) -> Bool {
        guard secret.count == 32 else {
            NSLog("[iCloudBridge] Rejected malformed CloudKit pairing material (%d bytes)", secret.count)
            return false
        }
        guard let pairingStore else {
            NSLog("[iCloudBridge] Holding CloudKit pairing material until PairingStore is attached")
            return false
        }
        return pairingStore.applyCloudKitPairingSecret(secret)
    }

    /// Drain active CloudKit pairing, messages and status; true means a message was dispatched.
    /// Overlapping drains coalesce into at most one queued rerun; the transport owns atomic delivery.
    @discardableResult
    func drainDeviceTransport() async -> Bool {
        guard NADeviceSyncRecoveryBudget.hasTime, let ck = deviceTransport else { return false }
        let generation = setupGeneration
        await deviceIncomingSetupTask?.value
        guard generation == setupGeneration, NADeviceSyncRecoveryBudget.hasTime else { return false }
        if deviceDrainInFlight { deviceDrainQueued = true; return false }
        deviceDrainInFlight = true
        defer {
            if generation == setupGeneration {
                deviceDrainInFlight = false
                if deviceDrainQueued {
                    deviceDrainQueued = false
                    if NADeviceSyncRecoveryBudget.hasTime {
                        Task { await self.drainDeviceTransport() }
                    }
                }
            }
        }
        let accountGeneration = accountFailureGeneration
        // Pairing first: a reply signed with a key the Mac just published
        // verifies in this same drain instead of waiting for the next one.
        await ck.drainPairing()
        guard generation == setupGeneration, NADeviceSyncRecoveryBudget.hasTime else { return false }
        let result = await ck.drainIncoming()
        guard generation == setupGeneration else { return false }
        if case .failure(.account(let failure), _) = result {
            recordAccountFailure(failure)
        }
        if case .success = result { onTransportSucceeded?() }
        let dispatched = result.dispatchedCount
        if dispatched > 0 { NADeviceSyncRecoveryBudget.didApplyData?() }
        guard generation == setupGeneration, NADeviceSyncRecoveryBudget.hasTime else { return dispatched > 0 }
        await ck.drainStatus()
        guard generation == setupGeneration else { return false }
        if case .success = result, accountGeneration == accountFailureGeneration, accountFailure != nil {
            accountFailure = nil
            syncStatus = "CloudKit ready"
        }
        return dispatched > 0
    }

    /// Drain only our device-sync subscription pushes while CloudKit is active.
    @discardableResult
    func drainIfDeviceSyncPush(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard deviceTransport != nil else { return false }
        #if canImport(CloudKit)
        guard CloudKitDeviceTransport.isDeviceSyncNotification(userInfo) else { return false }
        return await drainDeviceTransport()
        #else
        return false
        #endif
    }

}
