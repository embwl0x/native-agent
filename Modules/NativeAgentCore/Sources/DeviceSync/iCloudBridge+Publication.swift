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
// Blueprint: | `iCloudBridge+Publication.swift` | Pairing-bound provider catalog and snapshot status publication under each group's canonical CloudKit key, explicit publication invalidation, presence and progress publication |

extension iCloudBridge {
    /// Forced repair revokes accepted-byte suppression at the publication owner.
    func invalidateMobileSnapshotPublication() {
        lastPublishedMobileSnapshotStatus.removeAll()
    }

    /// Publish the Mac-owned provider/model catalog to the paired phone without
    /// copying credentials or requiring the legacy iCloud Drive snapshot lane.
    /// The status record is a bounded LWW projection with one publication owner;
    /// the Mac remains the only provider configuration owner.
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
                guard let encoded = try PairingSecret.existingSecretBase64(),
                      let secret = Data(base64Encoded: encoded), secret.count == 32 else {
                    throw DeviceSyncError.notConfigured
                }
                let snapshot = try await sync.host.providerCatalogSnapshot()
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
                    // Reread current configuration after every send. Only a
                    // stable projection, or an unqueued failure, ends this owner.
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
        committed: [String: Data] = [:],
        shouldPublish: @MainActor () -> Bool = { true }
    ) async -> [NAMobileSnapshotGroup: DeviceSyncError]? {
        guard let deviceTransport, speaksToPhone, !groups.isEmpty else { return nil }
        var failures: [NAMobileSnapshotGroup: DeviceSyncError] = [:]
        for group in NAMobileSnapshotGroup.allCases where groups.contains(group) {
            do {
                guard let encoded = try PairingSecret.existingSecretBase64(),
                      let secret = Data(base64Encoded: encoded), secret.count == 32 else {
                    throw DeviceSyncError.notConfigured
                }
                guard let value = try await MobileSnapshotBuilder.shared.status(
                    group: group, directory: snapshotDirectory, committed: committed
                ) else { throw DeviceSyncError.underlying(message: "Snapshot \(group.rawValue) is absent; it was not published.") }
                guard shouldPublish() else { return nil }
                if lastPublishedMobileSnapshotStatus[group]?.pairing == secret,
                   lastPublishedMobileSnapshotStatus[group]?.value == value {
                    continue
                }
                try await deviceTransport.setStatus(
                    key: group.statusKey,
                    value: value,
                    pairingSecret: secret
                )
                guard shouldPublish() else { return nil }
                lastPublishedMobileSnapshotStatus[group] = (secret, value)
                await recordSendResult(operation: group.statusKey)
            } catch {
                guard shouldPublish() else { return nil }
                failures[group] = error as? DeviceSyncError ?? .underlying(message: error.localizedDescription)
                await recordSendResult(operation: group.statusKey, error: error)
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

    enum MacPresencePublication {
        case published, ineligible, failed
    }

    /// Eligibility is distinct from failure of an eligible publication attempt.
    func publishMacPresence() async -> MacPresencePublication {
        guard let deviceTransport, speaksToPhone else { return .ineligible }
        let generation = setupGeneration
        do {
            guard let encoded = try PairingSecret.existingSecretBase64(),
                  let secret = Data(base64Encoded: encoded) else { return .failed }
            try await deviceTransport.setPresence(pairingSecret: secret)
            guard isSetUp, generation == setupGeneration else { return .ineligible }
            await recordSendResult(operation: "presence")
            return .published
        } catch {
            guard isSetUp, generation == setupGeneration else { return .ineligible }
            await recordSendResult(operation: "presence", error: error)
            nativeLog("[iCloudBridge] presence beat failed: %@", error.localizedDescription)
            return .failed
        }
    }

    @discardableResult
    public func sendKVSChatProgress(
        text: String,
        sessionID: String,
        correlationID: String,
        metadata: [String: String],
        key: String = NativeAgentICloudBridgeConstants.KVSKey.chatProgressLatest
    ) async -> Bool {
        let msg: BridgeMessage
        do {
            msg = try await sync.storage.perform {
                let secret = try PairingSecret.loadOrGenerateSecret()
                let msg = try Self.makeKVSChatProgressMessage(text: text, sessionID: sessionID,
                    correlationID: correlationID, metadata: metadata, secret: secret)
                return msg
            }
        } catch {
            syncStatus = "iPhone pairing unavailable — repair the Mac pairing key"
            nativeLog("[iCloudBridge] failed to sign KVS progress msg=%@: %@", correlationID, "\(error)")
            return false
        }

        let data: Data
        do {
            data = try await sync.storage.perform {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return try encoder.encode(msg)
            }
        } catch {
            nativeLog("[iCloudBridge] failed to encode KVS progress msg=%@: %@", correlationID, "\(error)")
            return false
        }

        let delivery: ICloudKVSProgressDeliveryResult = await withCKTimeout(
            "iCloudBridge.sendKVSChatProgress",
            seconds: 3
        ) { () -> ICloudKVSProgressDeliveryResult in
            let kvs = NSUbiquitousKeyValueStore.default
            let existingKeys = Set(kvs.dictionaryRepresentation.keys)
            let admission = ICloudKVSProgressWriteAdmission.assess(
                keys: existingKeys,
                progressKey: key
            )
            guard admission.isAllowed else { return .blocked(admission) }
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
}
