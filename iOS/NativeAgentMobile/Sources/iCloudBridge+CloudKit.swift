import Foundation
import UIKit
import NativeAgentShared
import CryptoKit
import SwiftUI
// Blueprint: | `iCloudBridge+CloudKit.swift` | Pairing-bound reads while the phone is open, presence beat and lifecycle-fenced recovery |

extension iCloudBridge {
    @objc nonisolated func cloudKitAccountDidChange(_ note: Notification) {
        Task { @MainActor in
            self.setup()
            self.startForegroundReceiving()
            await self.catchUpCloudKit()
        }
    }

    /// Read both presence and current pairing key: a beat under an old key cannot prove the Mac still uses this phone's key.
    func readMacPresence() async {
        guard pairingStore?.isRepairingConnection != true,
              let secret = pairingStore?.iCloudPairingSecret else { return }
        let generation = setupGeneration
        guard let transport = deviceTransport else { return }
        do {
            let seen = try await transport.peerPresence(pairingSecret: secret)
            guard setupGeneration == generation, pairingStore?.iCloudPairingSecret == secret,
                  pairingStore?.isRepairingConnection != true else { return }
            recordMacConfirmation(at: seen)
        } catch {
            guard setupGeneration == generation else { return }
            syncStatus = "Mac presence could not be read: \(error.localizedDescription)"
        }
        do {
            let published = try await transport.peekPairingSecret()
            guard setupGeneration == generation, pairingStore?.iCloudPairingSecret == secret else { return }
            macPairingKey = MacPairingKeyReading(recordKey: published, phoneKey: secret, failure: nil)
        } catch {
            guard setupGeneration == generation, pairingStore?.iCloudPairingSecret == secret else { return }
            let previousKey = macPairingKey.flatMap { $0.phoneKey == secret ? $0.recordKey : nil }
            let cause = "The Mac pairing key could not be read: \(error.localizedDescription)"
            macPairingKey = MacPairingKeyReading(recordKey: previousKey, phoneKey: secret, failure: cause)
            syncStatus = cause
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

        deliveryPairingDidChange()
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
        foregroundCatchUpTask?.cancel()
    }

    /// Silent pushes are hints Apple may drop, and CloudKit has no stream, so an open phone keeps reading: this is what makes the room live.
    func startForegroundReceiving() {
        guard UIApplication.shared.applicationState == .active || TalkModeController.shared.isActive,
              let transport = deviceTransport else { return }
        let generation = setupGeneration
        if foregroundReceiveTask == nil {
            foregroundReceiveTask = Task { [weak self] in
                while !Task.isCancelled, let self, self.setupGeneration == generation,
                      UIApplication.shared.applicationState == .active || TalkModeController.shared.isActive {
                    let accountGeneration = self.accountFailureGeneration
                    let pairing = self.pairingStore?.iCloudPairingSecret
                    let result = await transport.drainIncoming(queueIfBusy: false)
                    guard !Task.isCancelled, self.setupGeneration == generation else { return }
                    guard pairing == self.pairingStore?.iCloudPairingSecret else { continue }
                    if case .failure(.account(let failure), _) = result { self.recordAccountFailure(failure) }
                    self.clearAccountFailureAfterSuccessfulDrain(result, accountGeneration: accountGeneration, source: "foreground")
                    if case .success = result { self.onTransportSucceeded?() }
                    do { try await Task.sleep(for: .seconds(NAPhoneForegroundPresence.receiveInterval)) }
                    catch { return }
                }
            }
        }
        if foregroundPresenceTask == nil {
            foregroundPresenceTask = Task { [weak self] in
                while !Task.isCancelled, let self, self.setupGeneration == generation,
                      UIApplication.shared.applicationState == .active || TalkModeController.shared.isActive {
                    await self.readMacPresence()
                    guard !Task.isCancelled, self.setupGeneration == generation else { return }
                    if let secret = self.pairingStore?.iCloudPairingSecret, self.pairingStore?.isRepairingConnection != true {
                        do {
                            let value = try NAPhoneForegroundPresence.signedValue(secret: secret)
                            try await transport.setStatus(key: NAPhoneForegroundPresence.statusKey, value: value, pairingSecret: secret)
                        } catch {
                            guard self.setupGeneration == generation else { return }
                            self.syncStatus = "Phone presence was not accepted: \(error.localizedDescription)"
                        }
                    }
                    guard !Task.isCancelled, self.setupGeneration == generation else { return }
                    self.continueForegroundCatchUp()
                    do { try await Task.sleep(for: .seconds(NAPhoneForegroundPresence.beat)) }
                    catch { return }
                }
            }
        }
    }

    /// Only the presence beat admits owed catch-up; a slow read cannot hold chat or presence renewal.
    private func continueForegroundCatchUp() {
        guard iCloudSyncEngine.shared.cloudKitCatchUpIncomplete,
              !deviceDrainInFlight, foregroundCatchUpTask == nil else { return }
        foregroundCatchUpTask = Task {
            defer { foregroundCatchUpTask = nil }
            _ = await drainDeviceTransportResult(onlyIfCatchUpOwed: true)
        }
    }

    func catchUpCloudKit() async {
        guard pairingStore?.isRepairingConnection != true, let transport = deviceTransport else { return }
        let generation = setupGeneration
        deliveryPairingDidChange()
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
        let changed: Bool
        do { changed = try await transport.drainPairing() }
        catch { syncStatus = "Pairing could not be read: \(error.localizedDescription)"; return false }
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
        onlyIfCatchUpOwed: Bool = false,
        recovery: DeviceSyncRecovery = .init()
    ) async -> DeviceSyncDrainResult {
        guard recovery.isActive, let ck = deviceTransport else { return .skipped(0) }
        let generation = setupGeneration
        if let setup = deviceIncomingSetupTask { await setup.value }
        guard generation == setupGeneration, recovery.isActive else { return .skipped(0) }
        let sync = iCloudSyncEngine.shared
        if onlyIfCatchUpOwed {
            guard sync.cloudKitCatchUpIncomplete, pairingStore?.isPaired == true,
                  pairingStore?.isRepairingConnection != true else { return .skipped(0) }
        }
        // Retain catch-up before coalescing so a skipped caller cannot lose the owed cache refresh.
        if refreshCachedSnapshots, pairingStore?.isPaired == true {
            sync.cloudKitCatchUpIncomplete = true
        }
        if deviceDrainInFlight {
            // The presence beat never extends an active drain or changes its cadence.
            if !onlyIfCatchUpOwed { deviceDrainQueued = true }
            return .skipped(0)
        }
        deviceDrainInFlight = true
        defer {
            if generation == setupGeneration {
                deviceDrainInFlight = false
                if deviceDrainQueued {
                    deviceDrainQueued = false
                    if recovery.isActive {
                        Task { await self.drainDeviceTransport(recovery: recovery) }
                    }
                }
            }
        }
        return await receiveAndRefresh()

        @MainActor func receiveAndRefresh() async -> DeviceSyncDrainResult {
            let accountGeneration = accountFailureGeneration
            var pairingFailure: DeviceSyncError?
            do { _ = try await ck.drainPairing(recovery: recovery) }
            catch {
                syncStatus = "Pairing could not be read: \(error.localizedDescription)"
                pairingFailure = .underlying(message: error.localizedDescription)
            }
            guard generation == setupGeneration, recovery.isActive else { return .skipped(0) }
            let pairing = pairingStore?.iCloudPairingSecret
            let result = await ck.drainIncoming(queueIfBusy: !onlyIfCatchUpOwed, recovery: recovery)
            guard generation == setupGeneration, pairing == pairingStore?.iCloudPairingSecret else { return .skipped(0) }
            if case .failure(.account(let failure), _) = result {
                recordAccountFailure(failure)
            }
            if case .success = result { onTransportSucceeded?() }
            let dispatched = result.dispatchedCount
            if dispatched > 0 { recovery.didApplyData?() }
            guard generation == setupGeneration, recovery.isActive else { return result }
            let completed = await refreshDeviceStatus(after: result, transport: ck, generation: generation,
                pairing: pairing, accountGeneration: accountGeneration, recovery: recovery,
                source: onlyIfCatchUpOwed ? "presence" : "refresh")
            if let pairingFailure { return .failure(pairingFailure, dispatched: result.dispatchedCount) }
            return completed
        }
    }

    private func refreshDeviceStatus(after result: DeviceSyncDrainResult, transport: CloudKitDeviceTransport,
                                     generation: Int, pairing: Data?, accountGeneration: UInt64,
                                     recovery: DeviceSyncRecovery, source: String) async -> DeviceSyncDrainResult {
        guard generation == setupGeneration, pairing == pairingStore?.iCloudPairingSecret, recovery.isActive else { return .skipped(0) }
        let statusResult = await transport.drainStatusResult(recovery: recovery)
        guard generation == setupGeneration, pairing == pairingStore?.iCloudPairingSecret, recovery.isActive else { return .skipped(0) }
        let sync = iCloudSyncEngine.shared
        if case .success = result, case .success = statusResult {
            // Only a complete remote pull may clear stale-cache warning; partial status handlers cannot.
            if sync.cloudKitCatchUpIncomplete, pairingStore?.isPaired == true {
                let refreshed = await sync.refreshLightweightSnapshots()
                guard generation == setupGeneration, pairing == pairingStore?.iCloudPairingSecret, recovery.isActive else { return .skipped(0) }
                if refreshed, accountGeneration == accountFailureGeneration {
                    sync.cloudKitCatchUpIncomplete = false
                    sync.cloudKitCatchUpFailure = nil
                    NSLog("[phone-pipe] snapshot catch-up completed source=%@", source)
                }
            }
        } else if pairingStore?.isPaired == true {
            sync.cloudKitCatchUpIncomplete = true
            // Keep the actual failed-read cause; skipped/coalesced reads cannot erase it.
            if case .failure(let failure, _) = statusResult { sync.cloudKitCatchUpFailure = failure }
            else if case .failure(let failure, _) = result { sync.cloudKitCatchUpFailure = failure }
        }
        if case .success = result, case .success = statusResult,
           accountGeneration == accountFailureGeneration, accountFailure != nil {
            clearAccountFailureAfterSuccessfulDrain(result, accountGeneration: accountGeneration, source: source)
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
