import Foundation
import Observation
import Combine
import DeviceSync
import NativeAgentShared
import TrustCenter
import NativeAgentCore
// Blueprint: | `EngineSync.swift` | `SyncFacade` class; `observeStatus`, `setStatus`; pairing-key snapshot reads publish through `LatestRead`, and rotation advances the same boundary |

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
    public var secretBase64 = ""
    public var pairingError: String?
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

    public func loadSecret(quiet: Bool) async {
        guard !Task.isCancelled, !isRotatingSecret else { return }
        guard owner != nil else {
            secretRead.write { secretBase64 = ""; pairingError = "Pairing is unavailable." }
            return
        }
        _ = await secretRead.read({
        let result = await Task.detached(priority: .utility) { () -> (String?, String?) in
            do {
                if quiet { return (try PairingSecret.existingSecretBase64() ?? "", nil) }
                return (try PairingSecret.currentSecretBase64(), nil)
            } catch { return (nil, error.localizedDescription) }
        }.value
        return result
        }, publish: { result in
        if let secret = result.0 {
            pairingError = nil
            secretBase64 = secret
        } else {
            pairingError = "Pairing is unavailable. \(result.1 ?? "The Mac pairing key could not be loaded.")"
            secretBase64 = ""
        }
        })
    }

    public func regenerateSecret() async {
        guard let owner, !isRotatingSecret else { return }
        isRotatingSecret = true
        secretRead.write {}
        defer { isRotatingSecret = false }
        // Close admission before changing durable signing bytes, and reopen
        // with exactly the read-back key before either publication awaits.
        owner.bridge.owePairingPublication(true)
        owner.engine.beginPairingSecretRotation()
        let result = await Task.detached(priority: .utility) { () -> (Data?, String?) in
            do { return (try PairingSecret.rotateSecret(), nil) }
            catch { return (nil, error.localizedDescription) }
        }.value
        guard let persistedSecret = result.0 else {
            owner.bridge.owePairingPublication(false)
            await owner.engine.finishPairingSecretRotation(with: nil)
            let detail = result.1 ?? "The existing key was preserved."
            pairingError = "Pairing key regeneration failed. \(detail)"
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
            secretBase64 = persistedSecret.base64EncodedString()
        }
    }
}
