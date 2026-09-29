import Foundation
import Observation
import Combine
import DeviceSync

/// Settings' observable projection of the engine's canonical device-sync owner.
/// Combine subscriptions bridge the core's published values without wire models.
@MainActor
@Observable
public final class SyncFacade {
    public nonisolated let owner: DeviceSync?
    public private(set) var status = "iCloud not checked"
    public private(set) var phones: [PairedPhoneStore.Phone] = []
    public private(set) var message: String?
    public var secretBase64 = ""
    public var pairingError: String?
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []

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
    }

    public func setStatus(_ status: PairedPhoneStore.Phone.Status, id: String) {
        owner?.pairedPhones.setStatus(status, id: id)
    }

    public func loadSecret(quiet: Bool) async {
        guard owner != nil else {
            secretBase64 = ""
            pairingError = "Pairing is unavailable."
            return
        }
        let result = await Task.detached(priority: .utility) { () -> (String?, String?) in
            do {
                if quiet { return (try PairingSecretManager.existingSecretBase64() ?? "", nil) }
                return (try PairingSecretManager.currentSecretBase64(), nil)
            } catch { return (nil, error.localizedDescription) }
        }.value
        guard !Task.isCancelled else { return }
        if let secret = result.0 {
            pairingError = nil
            secretBase64 = secret
        } else {
            pairingError = "Pairing is unavailable. \(result.1 ?? "The Mac pairing key could not be loaded.")"
            secretBase64 = ""
        }
    }

    public func regenerateSecret() async {
        guard let owner else { return }
        // Close admission before changing durable signing bytes, and reopen
        // with exactly the read-back key before either publication awaits.
        owner.engine.beginPairingSecretRotation()
        let result = await Task.detached(priority: .utility) { () -> (Data?, String?) in
            do { return (try PairingSecretManager.rotateSecret(), nil) }
            catch { return (nil, error.localizedDescription) }
        }.value
        guard let persistedSecret = result.0 else {
            owner.engine.finishPairingSecretRotation(with: nil)
            let detail = result.1 ?? "The existing key was preserved."
            pairingError = "Pairing key regeneration failed. \(detail)"
            return
        }
        owner.engine.finishPairingSecretRotation(with: persistedSecret)
        async let kvsPublished = PairingSecretManager.publishMaterialToKVS(persistedSecret)
        async let cloudKitPublished = owner.bridge.publishPairingSecret(persistedSecret)
        let published = await (kvsPublished, cloudKitPublished)
        pairingError = nil
        _ = PairingPublicationHealth.record(kvsPublished: published.0, cloudKitPublished: published.1)
        secretBase64 = persistedSecret.base64EncodedString()
    }
}

public enum PairingPublicationPresentation {
    public static func error(kvsPublished: Bool, cloudKitPublished: Bool) -> String? {
        switch (kvsPublished, cloudKitPublished) {
        case (true, true):
            return nil
        case (false, true):
            return "The new key is saved and CloudKit updated, but KVS did not accept it. iPhones using KVS bootstrap may not receive the new pairing key until KVS recovers."
        case (true, false):
            return "The new key is saved and KVS updated, but CloudKit did not accept it. Paired iPhones may reject signed messages until CloudKit recovers."
        case (false, false):
            return "The new key is saved, but neither KVS nor CloudKit accepted it yet."
        }
    }
}

/// The pairing key is already rotated when either publication route fails, so
/// this warning must survive the settings view's local state. Otherwise a user
/// can navigate away and lose the only indication that every paired phone may
/// still hold the old key.
public enum PairingPublicationHealth {
    public static let warningDefaultsKey = "NativeAgent.pairing.publicationWarning.v1"

    @discardableResult
    public static func record(
        kvsPublished: Bool,
        cloudKitPublished: Bool,
        defaults: UserDefaults = .standard
    ) -> String? {
        let warning = PairingPublicationPresentation.error(
            kvsPublished: kvsPublished,
            cloudKitPublished: cloudKitPublished
        )
        if let warning {
            defaults.set(warning, forKey: warningDefaultsKey)
        } else {
            defaults.removeObject(forKey: warningDefaultsKey)
        }
        return warning
    }

    public static func currentWarning(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: warningDefaultsKey)
    }
}
