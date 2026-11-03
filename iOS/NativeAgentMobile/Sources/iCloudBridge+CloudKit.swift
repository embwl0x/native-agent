import Foundation
import UIKit
import NativeAgentShared
import CryptoKit
import SwiftUI
// Blueprint: | `iCloudBridge+CloudKit.swift` | Shared launch/foreground catch-up with pairing-bound status and retained incomplete refresh; pairing-only resync never waits on incoming setup; its warning shows only after a catch-up read failed, never for one skipped into the foreground receive or still running; fast foreground receive skips busy drains, generation-fenced account recovery and fetch/status cancellation on inactivity/teardown |

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

    /// CloudKit construction is checked; PairingStore alone commits pairing material.
    func configureDeviceTransportIfAvailable() throws {
        let resolvedProductionTransport: Bool
        if deviceTransport == nil {
            let transport = try DeviceSyncTransportResolver.makeCloudKitTransport(
                role: .ios,
                containerIdentifier: NativeAgentICloudBridgeConstants.containerID
            )
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
            NotificationCenter.default.addObserver(self,
                selector: #selector(cloudKitAppWillResignActive(_:)),
                name: UIApplication.willResignActiveNotification, object: nil)
        }

        resumeDeliveryNudges()
        Task {
            await transport.observePairing { [weak self = self] secret in
                guard await self?.setupGeneration == generation else { return false }
                return await self?.applyPairingMaterialFromTransport(secret) ?? false
            }
        }
        deviceIncomingSetupTask = Task {
            await iCloudSyncEngine.shared.enableCloudKitSnapshotCache()
            guard setupGeneration == generation else { return }
            _ = await transport.observeIncoming { [weak self = self] msg in
                guard await self?.setupGeneration == generation else { return false }
                return await self?.handleIncomingFromTransport(msg) ?? false
            }
            guard setupGeneration == generation else { return }
            let drainStartedAt = Date()
            _ = await transport.drainIncoming()
            guard setupGeneration == generation else { return }
            NSLog("[phone-pipe] incoming setup drain returned elapsedMs=%.0f", Date().timeIntervalSince(drainStartedAt) * 1000)
            // Claim the catalog only after successful application.
            transport.observeStatus(
                key: NAProviderCatalogStatusCodec.statusKey,
                pairingSecret: { [weak self] in await self?.pairingSecretForPhoneRequests },
                onApply: { @MainActor [weak self = self] value, writtenAt, originatingPairing in
                    guard self?.setupGeneration == generation else { return false }
                    let applied = await iCloudSyncEngine.shared.applyProviderCatalogStatus(value, originatingPairing: originatingPairing) {
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
                    pairingSecret: { [weak self] in await self?.pairingSecretForPhoneRequests },
                    onApply: { value, writtenAt, originatingPairing in
                        guard await self.setupGeneration == generation else { return false }
                        return await iCloudSyncEngine.shared.applyCloudKitSnapshotStatus(
                            value,
                            group: group,
                            originatingPairing: originatingPairing,
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
        }
        startForegroundReceiving()
        Task {
            guard setupGeneration == generation else { return }
            await self.catchUpCloudKit()
        }
    }

    /// Silent pushes can be dropped while suspended. Opening the phone pulls
    /// the same messages and status as launch, even when already paired.
    @objc private nonisolated func cloudKitAppDidBecomeActive(_ note: Notification) {
        Task { @MainActor in
            self.startForegroundReceiving()
            await self.catchUpCloudKit()
        }
    }

    @objc private nonisolated func cloudKitAppWillResignActive(_ note: Notification) {
        Task { @MainActor in
            if !TalkModeController.shared.isActive { self.stopForegroundReceiving() }
        }
    }

    func stopForegroundReceiving() {
        foregroundReceiveTask?.cancel()
        foregroundReceiveTask = nil
        foregroundPresenceTask?.cancel()
        foregroundPresenceTask = nil
    }

    /// Chat does not wait behind the many snapshot/status reads. Both push and
    /// this foreground deadline use the transport's existing single-flight drain.
    func startForegroundReceiving() {
        guard UIApplication.shared.applicationState == .active || TalkModeController.shared.isActive,
              let transport = deviceTransport else { return }
        let generation = setupGeneration
        if foregroundReceiveTask == nil {
            foregroundReceiveTask = Task { [weak self] in
                while !Task.isCancelled, let self, self.setupGeneration == generation,
                      (UIApplication.shared.applicationState == .active || TalkModeController.shared.isActive) {
                    let accountGeneration = self.accountFailureGeneration
                    let pairing = self.pairingStore?.iCloudPairingSecret
                    let result = await transport.drainIncoming(queueIfBusy: false)
                    guard !Task.isCancelled, self.setupGeneration == generation else { return }
                    if case .failure(.account(let failure), _) = result { self.recordAccountFailure(failure) }
                    self.clearAccountFailureAfterSuccessfulDrain(result, accountGeneration: accountGeneration, source: "foreground")
                    if case .success = result {
                        self.onTransportSucceeded?()
                        if iCloudSyncEngine.shared.cloudKitCatchUpIncomplete, !self.deviceDrainInFlight {
                            // A coalesced catch-up did not receive this completion.
                            // Finish its status/cache work with the actual read,
                            // without holding chat behind it or racing another read.
                            Task { @MainActor in
                                guard self.setupGeneration == generation,
                                      self.pairingStore?.iCloudPairingSecret == pairing,
                                      iCloudSyncEngine.shared.cloudKitCatchUpIncomplete,
                                      !self.deviceDrainInFlight else { return }
                                _ = await self.drainDeviceTransportResult(
                                    completedIncoming: (result, accountGeneration, pairing)
                                )
                            }
                        }
                    }
                    do { try await Task.sleep(for: .seconds(NAPhoneForegroundPresence.receiveInterval)) }
                    catch { return }
                }
            }
        }
        if foregroundPresenceTask == nil {
            foregroundPresenceTask = Task { [weak self] in
                while !Task.isCancelled, let self, self.setupGeneration == generation,
                      (UIApplication.shared.applicationState == .active || TalkModeController.shared.isActive) {
                    if let secret = self.pairingStore?.iCloudPairingSecret,
                       self.pairingStore?.isRepairingConnection != true {
                        do {
                            let value = try NAPhoneForegroundPresence.signedValue(secret: secret)
                            try await transport.setStatus(key: NAPhoneForegroundPresence.statusKey, value: value, pairingSecret: secret)
                        } catch {
                            NSLog("[iCloudBridge] foreground phone presence not accepted: %@", error.localizedDescription)
                        }
                    }
                    do { try await Task.sleep(for: .seconds(NAPhoneForegroundPresence.beat)) }
                    catch { return }
                }
            }
        }
    }

    private func catchUpCloudKit() async {
        guard pairingStore?.isRepairingConnection != true, let transport = deviceTransport else { return }
        let generation = setupGeneration
        resumeDeliveryNudges()
        await deviceIncomingSetupTask?.value
        guard generation == setupGeneration, !Task.isCancelled else { return }
        _ = await transport.ensurePushSubscriptions()
        guard generation == setupGeneration else { return }
        // The drain applies pairing before messages, including first pairing.
        _ = await drainDeviceTransportResult(refreshCachedSnapshots: true)
        guard generation == setupGeneration, !Task.isCancelled else { return }
        await readMacPresence()
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

    /// Pairing refresh can be requested by a message being delivered by the
    /// initial setup drain. Read only pairing here; waiting for incoming setup
    /// would await the very delivery that called us.
    @discardableResult
    func refreshPairingFromCloudKit() async -> Bool {
        guard pairingStore?.isRepairingConnection != true,
              let transport = deviceTransport else { return false }
        let generation = setupGeneration
        let changed = await transport.drainPairing()
        guard generation == setupGeneration else { return false }
        return changed
    }

    /// Drain active CloudKit pairing, messages and status; true means a message was dispatched.
    /// Overlapping drains coalesce into at most one queued rerun; the transport owns atomic delivery.
    @discardableResult
    func drainDeviceTransport() async -> Bool {
        (await drainDeviceTransportResult()).dispatchedCount > 0
    }

    private func drainDeviceTransportResult(
        refreshCachedSnapshots: Bool = false,
        completedIncoming: (result: DeviceSyncDrainResult, accountGeneration: UInt64, pairing: Data?)? = nil
    ) async -> DeviceSyncDrainResult {
        guard NADeviceSyncRecoveryBudget.hasTime, let ck = deviceTransport else { return .skipped(0) }
        let generation = setupGeneration
        await deviceIncomingSetupTask?.value
        guard generation == setupGeneration, NADeviceSyncRecoveryBudget.hasTime else { return .skipped(0) }
        let sync = iCloudSyncEngine.shared
        // Retain the requested catch-up before coalescing. The active or queued
        // drain can finish it; a skipped caller cannot lose the cache refresh.
        if refreshCachedSnapshots, pairingStore?.isPaired == true {
            sync.cloudKitCatchUpIncomplete = true
        }
        if deviceDrainInFlight { deviceDrainQueued = true; return .skipped(0) }
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
        let accountGeneration = completedIncoming?.accountGeneration ?? accountFailureGeneration
        // Read pairing before a new incoming pull. A completed foreground
        // read can serve this catch-up only while its pairing is still current.
        await ck.drainPairing()
        guard generation == setupGeneration, NADeviceSyncRecoveryBudget.hasTime else { return .skipped(0) }
        let result: DeviceSyncDrainResult
        if let completedIncoming {
            guard completedIncoming.pairing == pairingStore?.iCloudPairingSecret else { return .skipped(0) }
            // Foreground already delivered and reported these messages. Reuse
            // its outcome; a second pull could just coalesce again.
            result = completedIncoming.result
        } else {
            result = await ck.drainIncoming()
        }
        guard generation == setupGeneration else { return .skipped(0) }
        if case .failure(.account(let failure), _) = result {
            recordAccountFailure(failure)
        }
        if completedIncoming == nil, case .success = result { onTransportSucceeded?() }
        let dispatched = result.dispatchedCount
        if completedIncoming == nil, dispatched > 0 { NADeviceSyncRecoveryBudget.didApplyData?() }
        guard generation == setupGeneration, NADeviceSyncRecoveryBudget.hasTime else { return result }
        let statusResult = await ck.drainStatusResult()
        guard generation == setupGeneration else { return .skipped(0) }
        if case .success = result, case .success = statusResult {
            // Only a complete remote pull authorizes a cache read to clear the
            // stale warning. Partial status handlers cannot clear it meanwhile.
            if refreshCachedSnapshots || sync.cloudKitCatchUpIncomplete,
               pairingStore?.isPaired == true {
                guard NADeviceSyncRecoveryBudget.hasTime else { return result }
                let refreshed = await sync.refreshLightweightSnapshots()
                guard generation == setupGeneration else { return .skipped(0) }
                if refreshed { sync.cloudKitCatchUpIncomplete = false; sync.cloudKitCatchUpFailed = false }
            }
        } else if pairingStore?.isPaired == true {
            sync.cloudKitCatchUpIncomplete = true
            // Only a read that failed is a warning; a skipped one merged into another read and stays owed.
            if case .failure = result { sync.cloudKitCatchUpFailed = true }
            if case .failure = statusResult { sync.cloudKitCatchUpFailed = true }
        }
        if case .success = result, case .success = statusResult,
           accountGeneration == accountFailureGeneration, accountFailure != nil {
            clearAccountFailureAfterSuccessfulDrain(result, accountGeneration: accountGeneration, source: "refresh")
        }
        return result
    }

    /// Only a completed successful read can retire an older account failure.
    /// A failure reported by any concurrent CloudKit work remains authoritative.
    private func clearAccountFailureAfterSuccessfulDrain(_ result: DeviceSyncDrainResult, accountGeneration: UInt64, source: String) {
        guard case .success = result, accountGeneration == accountFailureGeneration, accountFailure != nil else { return }
        accountFailure = nil
        syncStatus = "CloudKit ready"
        NSLog("[phone-pipe] account recovered after successful incoming drain source=%@", source)
    }

    /// Drain only our device-sync subscription pushes while CloudKit is active.
    @discardableResult
    func drainIfDeviceSyncPush(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard deviceTransport != nil else { return false }
        #if canImport(CloudKit)
        guard CloudKitDeviceTransport.isDeviceSyncNotification(userInfo)
                || (userInfo["nativeAgentWake"] as? String) == "notification" else { return false }
        return await drainDeviceTransport()
        #else
        return false
        #endif
    }

}
