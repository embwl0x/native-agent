import Foundation
import CryptoKit
import AppKit
import Combine
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import ProviderRouting
import OSLog
import Network
// Blueprint: | `iCloudBridge+Publication.swift` | Pairing-bound canonical status/catalog groups, presence and progress. |

extension iCloudBridge {
    /// Forced repair revokes accepted-byte suppression at the publication owner.
    func invalidateMobileSnapshotPublication() {
        lastPublishedMobileSnapshotStatus.removeAll()
    }

    /// CloudKit catalog projection carries no credentials; the Mac remains the sole provider configuration owner.
    @discardableResult
    public func publishProviderCatalogStatus() async -> Bool {
        guard speaksToPhone else { return false }
        providerCatalogPublicationQueued = true
        if let providerCatalogPublicationTask { return await providerCatalogPublicationTask.value }
        let publication = Task { await drainProviderCatalogPublication() }
        providerCatalogPublicationTask = publication
        return await publication.value
    }

    private func drainProviderCatalogPublication() async -> Bool {
        defer { providerCatalogPublicationTask = nil }
        var published = false
        repeat {
            providerCatalogPublicationQueued = false
            published = false
            guard let deviceTransport, speaksToPhone else { return false }
            let generation = setupGeneration
            do {
                let secret = try await sync.storage.perform { try PairingSecret.requireExistingSecret() }
                guard generation == setupGeneration, speaksToPhone else { continue }
                let snapshot = try await sync.owner.mobileProviderCatalogSnapshot()
                guard generation == setupGeneration, speaksToPhone else { continue }
                let catalog = NAProviderCatalogStatus(
                    providers: snapshot.providers,
                    surfaces: Self.providerSurfaceSelections(from: snapshot.routing),
                    routingRevision: snapshot.routing.revision
                )
                let value = try NAProviderCatalogStatusCodec.encode(catalog)
                if lastPublishedProviderCatalogStatus?.pairing != secret || lastPublishedProviderCatalogStatus?.value != value {
                    try await deviceTransport.setStatus(key: NAProviderCatalogStatusCodec.statusKey, value: value, pairingSecret: secret)
                    guard generation == setupGeneration, speaksToPhone else { continue }
                    lastPublishedProviderCatalogStatus = (secret, value)
                    // Recheck after each send so only a stable projection or unqueued failure ends ownership.
                    providerCatalogPublicationQueued = true
                    await recordSendResult(operation: NAProviderCatalogStatusCodec.statusKey)
                }
                published = true
            } catch {
                guard generation == setupGeneration, speaksToPhone else { continue }
                lastPublishedProviderCatalogStatus = nil
                await recordSendResult(operation: NAProviderCatalogStatusCodec.statusKey, error: error)
                nativeLog("[iCloudBridge] provider catalog publication failed: \(error.localizedDescription)")
            }
        } while providerCatalogPublicationQueued
        return published
    }

    /// Freeze one routing generation so a second picker read cannot split the phone tuple.
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

    /// Transport only exact snapshot-writer bytes; report failed groups, with nil reserved for no transport or a retired pass.
    @discardableResult
    func publishMobileSnapshotStatus(
        groups: Set<NAMobileSnapshotGroup>,
        snapshotDirectory: URL,
        committed: [String: Data] = [:],
        shouldPublish: @MainActor () -> Bool = { true }
    ) async -> [NAMobileSnapshotGroup: DeviceSyncError]? {
        guard let deviceTransport, speaksToPhone, !groups.isEmpty else { return nil }
        let generation = setupGeneration
        var failures: [NAMobileSnapshotGroup: DeviceSyncError] = [:]
        for group in NAMobileSnapshotGroup.allCases where groups.contains(group) {
            do {
                let secret = try await sync.storage.perform { try PairingSecret.requireExistingSecret() }
                guard generation == setupGeneration, speaksToPhone, shouldPublish() else { return nil }
                guard let value = try await MobileSnapshotBuilder.shared.status(
                    group: group, directory: snapshotDirectory, committed: committed
                ) else { throw DeviceSyncError.underlying(message: "Snapshot \(group.rawValue) is absent; it was not published.") }
                guard generation == setupGeneration, speaksToPhone, shouldPublish() else { return nil }
                if lastPublishedMobileSnapshotStatus[group]?.pairing == secret,
                   lastPublishedMobileSnapshotStatus[group]?.value == value {
                    continue
                }
                try await deviceTransport.setStatus(
                    key: group.statusKey,
                    value: value,
                    pairingSecret: secret
                )
                guard generation == setupGeneration, speaksToPhone, shouldPublish() else { return nil }
                lastPublishedMobileSnapshotStatus[group] = (secret, value)
                await recordSendResult(operation: group.statusKey)
            } catch {
                guard generation == setupGeneration, speaksToPhone, shouldPublish() else { return nil }
                failures[group] = error as? DeviceSyncError ?? .underlying(message: error.localizedDescription)
                await recordSendResult(operation: group.statusKey, error: error)
                // Revoke suppression for a group known absent on the phone so its next attempt cannot skip publication.
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

    enum MacPresencePublication {
        case published, ineligible, failed
    }

    /// Eligibility is distinct from failure of an eligible publication attempt.
    func publishMacPresence() async -> MacPresencePublication {
        guard let deviceTransport, speaksToPhone else { return .ineligible }
        let generation = setupGeneration
        do {
            let secret = try await sync.storage.perform { try PairingSecret.requireExistingSecret() }
            guard isSetUp, generation == setupGeneration, speaksToPhone else { return .ineligible }
            try await deviceTransport.setPresence(pairingSecret: secret)
            guard isSetUp, generation == setupGeneration, speaksToPhone else { return .ineligible }
            await recordSendResult(operation: "presence")
            nativeLog("[iCloudBridge] Mac presence accepted")
            return .published
        } catch {
            guard isSetUp, generation == setupGeneration else { return .ineligible }
            await recordSendResult(operation: "presence", error: error)
            nativeLog("[iCloudBridge] presence beat failed: %@", error.localizedDescription)
            return .failed
        }
    }

}
