import Foundation
import UIKit
import NativeAgentShared
import CryptoKit
import SwiftUI
// Blueprint: | `iCloudBridge+CloudKit.swift` | Pairing-bound catch-up/presence; retained incomplete reads, bounded receive and fenced recovery |

extension iCloudBridge {
    /// Read both presence and current pairing key: a beat under an old key cannot prove the Mac still uses this phone's key.
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
                onApply: { @MainActor [weak self = self] value, writtenAt, originatingPairing, _ in
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
                    onApply: { value, writtenAt, originatingPairing, recovery in
                        guard await self.setupGeneration == generation else { return false }
                        return await iCloudSyncEngine.shared.applyCloudKitSnapshotStatus(
                            value,
                            group: group,
                            originatingPairing: originatingPairing,
                            writtenAt: writtenAt,
                            recovery: recovery
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

    /// Foreground catch-up must read messages/status even when paired because iOS can drop silent pushes while suspended.
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

    /// Keep Chat independent of bulk snapshot reads; foreground/push receives share the transport's single-flight drain.
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
                            // Finish coalesced catch-up status/cache work with the actual read without holding Chat or racing another read.
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

    /// Pairing refresh may run inside initial message delivery; awaiting that setup drain would deadlock its caller.
    @discardableResult
    func refreshPairingFromCloudKit() async -> Bool {
        guard pairingStore?.isRepairingConnection != true,
              let transport = deviceTransport else { return false }
        let generation = setupGeneration
        let changed = await transport.drainPairing()
        guard generation == setupGeneration else { return false }
        return changed
    }

    /// Coalesce overlapping drains into at most one rerun; transport owns atomic message delivery.
    @discardableResult
    func drainDeviceTransport(recovery: DeviceSyncRecovery = .init()) async -> Bool {
        (await drainDeviceTransportResult(recovery: recovery)).dispatchedCount > 0
    }

    private func drainDeviceTransportResult(
        refreshCachedSnapshots: Bool = false,
        completedIncoming: (result: DeviceSyncDrainResult, accountGeneration: UInt64, pairing: Data?)? = nil,
        recovery: DeviceSyncRecovery = .init()
    ) async -> DeviceSyncDrainResult {
        guard recovery.hasTime, let ck = deviceTransport else { return .skipped(0) }
        let generation = setupGeneration
        if let setup = deviceIncomingSetupTask {
            if let deadline = recovery.deadline {
                do {
                    try await OperationWaitBudget.withDeadline(seconds: max(0, deadline.timeIntervalSinceNow)) { _ in
                        await setup.value
                    }
                } catch { return .skipped(0) } // Setup keeps its own task; expiry ends only this recovery wait.
            } else {
                await setup.value
            }
        }
        guard generation == setupGeneration, recovery.hasTime else { return .skipped(0) }
        let sync = iCloudSyncEngine.shared
        // Retain catch-up before coalescing so a skipped caller cannot lose the owed cache refresh.
        if refreshCachedSnapshots, pairingStore?.isPaired == true {
            sync.cloudKitCatchUpIncomplete = true
        }
        if deviceDrainInFlight { deviceDrainQueued = true; return .skipped(0) }
        deviceDrainInFlight = true
        defer {
            if generation == setupGeneration {
                deviceDrainInFlight = false
                saveSeenMacRecords()
                if deviceDrainQueued {
                    deviceDrainQueued = false
                    if recovery.hasTime {
                        Task { await self.drainDeviceTransport(recovery: recovery) }
                    }
                }
            }
        }
        let accountGeneration = completedIncoming?.accountGeneration ?? accountFailureGeneration
        // Reuse foreground read only while its pairing remains current; read pairing before a fresh pull.
        await ck.drainPairing(recovery: recovery)
        guard generation == setupGeneration, recovery.hasTime else { return .skipped(0) }
        let result: DeviceSyncDrainResult
        if let completedIncoming {
            guard completedIncoming.pairing == pairingStore?.iCloudPairingSecret else { return .skipped(0) }
            // Reuse the foreground delivery outcome so a second pull cannot merely coalesce again.
            result = completedIncoming.result
        } else {
            result = await ck.drainIncoming(recovery: recovery)
        }
        guard generation == setupGeneration else { return .skipped(0) }
        if case .failure(.account(let failure), _) = result {
            recordAccountFailure(failure)
        }
        if completedIncoming == nil, case .success = result { onTransportSucceeded?() }
        // The launch's first completed drain tries the records it holds once.
        if case .success = result { await retryHeldMacRecords() }
        let dispatched = result.dispatchedCount
        if completedIncoming == nil, dispatched > 0 { recovery.didApplyData?() }
        guard generation == setupGeneration, recovery.hasTime else { return result }
        let statusResult = await ck.drainStatusResult(recovery: recovery)
        guard generation == setupGeneration else { return .skipped(0) }
        if case .success = result, case .success = statusResult {
            // Only a complete remote pull may clear stale-cache warning; partial status handlers cannot.
            if refreshCachedSnapshots || sync.cloudKitCatchUpIncomplete,
               pairingStore?.isPaired == true {
                guard recovery.hasTime else { return result }
                let refreshed = await sync.refreshLightweightSnapshots()
                guard generation == setupGeneration else { return .skipped(0) }
                if refreshed { sync.cloudKitCatchUpIncomplete = false; sync.cloudKitCatchUpFailures = 0 }
            }
        } else if pairingStore?.isPaired == true {
            sync.cloudKitCatchUpIncomplete = true
            // Warn only on failed reads; skipped/coalesced reads remain owed work.
            if case .failure = result { sync.cloudKitCatchUpFailures += 1 }
            else if case .failure = statusResult { sync.cloudKitCatchUpFailures += 1 }
        }
        if case .success = result, case .success = statusResult,
           accountGeneration == accountFailureGeneration, accountFailure != nil {
            clearAccountFailureAfterSuccessfulDrain(result, accountGeneration: accountGeneration, source: "refresh")
        }
        return result
    }

    /// Only successful completed reads retire account failures; concurrent CloudKit failures remain authoritative.
    private func clearAccountFailureAfterSuccessfulDrain(_ result: DeviceSyncDrainResult, accountGeneration: UInt64, source: String) {
        guard case .success = result, accountGeneration == accountFailureGeneration, accountFailure != nil else { return }
        accountFailure = nil
        syncStatus = "CloudKit ready"
        NSLog("[phone-pipe] account recovered after successful incoming drain source=%@", source)
    }

    @discardableResult
    func drainIfDeviceSyncPush(_ userInfo: [AnyHashable: Any], recovery: DeviceSyncRecovery = .init()) async -> Bool {
        guard deviceTransport != nil else { return false }
        #if canImport(CloudKit)
        guard CloudKitDeviceTransport.isDeviceSyncNotification(userInfo)
                || (userInfo["nativeAgentWake"] as? String) == "notification" else { return false }
        return await drainDeviceTransport(recovery: recovery)
        #else
        return false
        #endif
    }

}
