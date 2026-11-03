import Foundation
import Observation
import Combine
import DeviceSync
import NativeAgentShared
import TrustCenter
import NativeAgentCore
import PersistenceCore
// Blueprint: | `EngineSync.swift` | `SyncFacade` class; shared pairing assessment and delivery repair; pairing availability reads publish through `LatestRead`; rotation retains accepted-write verification and publication obligations |

/// Settings' observable projection of the engine's canonical device-sync owner.
/// Combine subscriptions bridge the core's published values without wire models.
@MainActor
@Observable
public final class SyncFacade {
    public nonisolated let owner: DeviceSync?
    public private(set) var status = "iCloud not checked"
    public private(set) var phones: [PairedPhoneStore.Phone] = []
    public private(set) var message: String?
    /// Another Mac on this Apple Account holds the phone's pairing.
    public private(set) var phonePairedElsewhere = false
    /// The one assessment of the phone's connection, as the bridge holds it.
    public private(set) var connection: NAPhoneConnection?
    public var pairingError: String?
    public private(set) var isCheckingPairing = false
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var isRotatingSecret = false
    @ObservationIgnored private let secretRead = LatestRead()

    public nonisolated init(owner: DeviceSync?) {
        self.owner = owner
    }

    /// Mounting the page subscribes before its first read. Core publishers
    /// deliver on their MainActor owner, including their current values.
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
    }

    /// Move the phone to this Mac: the person's act, never a launch side effect.
    public func usePhoneHere() async {
        guard let owner else { return }
        if !(await owner.bridge.usePhoneHere()) {
            pairingError = "This Mac could not take the iPhone pairing. Check iCloud and try again."
        }
    }

    public func setStatus(_ status: PairedPhoneStore.Phone.Status, id: String) async {
        _ = await owner?.pairedPhones.setStatus(status, id: id)
    }

    /// Ask the existing delivery owner to reconcile the current key and claim.
    /// Checking never deliberately replaces another Mac's pairing.
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
        // Close admission before changing durable signing bytes, and reopen
        // with exactly the read-back key before either publication awaits.
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
                // Acceptance cannot be undone by a failed read. The normal
                // claim path reconciles this exact item now or at the next sync.
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
        // A publication that does not land stays owed and is the pairing fact
        // of the one connection assessment until iCloud takes the key.
        async let kvsPublished = PairingSecret.publishMaterialToKVS(persistedSecret)
        async let cloudKitPublished = owner.bridge.publishPairingSecret(persistedSecret)
        _ = await (kvsPublished, cloudKitPublished)
        secretRead.write {
            pairingError = nil
        }
    }
}
