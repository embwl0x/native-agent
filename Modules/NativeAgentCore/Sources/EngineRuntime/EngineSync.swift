import Foundation
import Observation
import Combine
import DeviceSync
import NativeAgentShared
import TrustCenter
import NativeAgentCore
import PersistenceCore
// Blueprint: | `EngineSync.swift` | `SyncFacade`, `LatestRead`; Checked pairing and owed key publication |

/// Bridge the canonical sync owner’s published values directly, without another wire model.
@MainActor
@Observable
public final class SyncFacade {
    public nonisolated let owner: DeviceSync?
    public private(set) var status = "iCloud not checked"
    public private(set) var phones: [PairedPhoneStore.Phone] = []
    public private(set) var message: String?
    public private(set) var phonePairedElsewhere = false
    /// Use the bridge’s single phone-connection assessment.
    public private(set) var connection: NAPhoneConnection?
    /// Connected and can-approve, as the bridge says it; nil until observed.
    public private(set) var standing: NAPhoneStanding?
    public var pairingError: String?
    public private(set) var isCheckingPairing = false
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var isRotatingSecret = false
    @ObservationIgnored private let secretRead = LatestRead()

    public nonisolated init(owner: DeviceSync?) {
        self.owner = owner
    }

    /// Subscribe before the first read; core publishers deliver current values on their MainActor owner.
    public func observeStatus() {
        guard subscriptions.isEmpty, let owner else { return }
        owner.bridge.$syncStatus.sink { [weak self] in self?.status = $0 }
            .store(in: &subscriptions)
        owner.pairedPhones.$phones.sink { [weak self] in self?.phones = $0 }
            .store(in: &subscriptions)
        owner.pairedPhones.$message.sink { [weak self] in self?.message = $0 }
            .store(in: &subscriptions)
        owner.bridge.$phonePairedElsewhere.sink { [weak self] in self?.phonePairedElsewhere = $0 }
            .store(in: &subscriptions)
        owner.bridge.$phoneConnection.sink { [weak self] in self?.connection = $0 }
            .store(in: &subscriptions)
        owner.bridge.$phoneStanding.sink { [weak self] in self?.standing = $0 }
            .store(in: &subscriptions)
    }

    /// Moving phone ownership requires the person’s act, never launch.
    public func usePhoneHere() async {
        guard let owner else { return }
        if !(await owner.bridge.usePhoneHere()) {
            pairingError = "This Mac could not take the iPhone pairing. Check iCloud and try again."
        }
    }

    public func setStatus(_ status: PairedPhoneStore.Phone.Status, id: String) async {
        _ = await owner?.pairedPhones.setStatus(status, id: id)
    }

    /// Reconciliation must not deliberately replace another Mac’s pairing.
    public func checkPairingDelivery() async {
        guard let owner, !isCheckingPairing, !isRotatingSecret else { return }
        isCheckingPairing = true
        defer { isCheckingPairing = false }
        await owner.bridge.claimPhonePairing()
        await loadSecret(quiet: true)
    }

    public func loadSecret(quiet: Bool) async {
        guard !Task.isCancelled, !isRotatingSecret else { return }
        guard let owner else {
            secretRead.write { pairingError = "Pairing is unavailable." }
            return
        }
        let publicationOwed = owner.bridge.pairingPublicationOwed
        _ = await secretRead.read({
        let result = await Task.detached(priority: .utility) { () -> String? in
            do {
                if quiet { _ = try PairingSecret.existingSecretBase64() }
                else if publicationOwed { _ = try PairingSecret.requireExistingSecret() }
                else { _ = try PairingSecret.loadOrGenerateSecret() }
                return nil
            } catch { return error.localizedDescription }
        }.value
        return result
        }, publish: { result in
        pairingError = result.map { "Pairing is unavailable. \($0)" }
        })
    }

    public func regenerateSecret() async {
        guard let owner, !isRotatingSecret else { return }
        isRotatingSecret = true
        secretRead.write {}
        defer { isRotatingSecret = false }
        // Close admission before changing signing bytes; reopen with the exact read-back key before publication suspends.
        let publicationWasOwed = owner.bridge.pairingPublicationOwed
        owner.bridge.owePairingPublication(true)
        owner.engine.beginPairingSecretRotation()
        let persistedSecret: Data
        do {
            persistedSecret = try await Task.detached(priority: .utility) {
                try PairingSecret.rotateSecret()
            }.value
        } catch {
            let accepted: Bool
            if let failure = error as? DeviceSecretKeychain.Failure,
               case .acceptedButUnverified = failure { accepted = true }
            else { accepted = false }
            secretRead.write {
                pairingError = "Pairing key regeneration failed. \(error.localizedDescription)"
            }
            if accepted || publicationWasOwed {
                // A failed read cannot undo acceptance; reconcile that exact claim now or at the next sync.
                owner.engine.awaitPairingSecretVerification()
                nativeLog("[PairingBootstrap] Rotation requires exact-item reconciliation; pairing publication remains owed: \(error.localizedDescription)")
                await owner.bridge.claimPhonePairing()
            } else {
                owner.bridge.owePairingPublication(false)
                await owner.engine.finishPairingSecretRotation(with: nil)
            }
            return
        }
        await owner.engine.finishPairingSecretRotation(with: persistedSecret)
        // Unpublished pairing remains owed and visible in the shared assessment until iCloud accepts the key.
        async let kvsPublished = PairingSecret.publishMaterialToKVS(persistedSecret)
        async let cloudKitPublished = owner.bridge.publishPairingSecret(persistedSecret)
        _ = await (kvsPublished, cloudKitPublished)
        secretRead.write {
            pairingError = nil
        }
    }
}
