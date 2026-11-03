// CloudKit delivers pairing material; PairingStore alone checks and commits it.
import Foundation
import NativeAgentShared
import Observation
import Security
import CryptoKit
import UIKit
// Blueprint: | `PairingStore.swift` | Device-local phone signing identity and sole pairing Keychain transaction owner; checked unavailable/removed/installed material controls sense and delivery retention |

/// One device-local signing identity, never synced through iCloud or restored
/// onto another phone. A failed read must not silently replace the identity.
actor PhoneSigningIdentity {
    static let shared = PhoneSigningIdentity()
    private var cachedKey: Curve25519.Signing.PrivateKey?

    func key() throws -> Curve25519.Signing.PrivateKey {
        if let cachedKey { return cachedKey }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "NativeAgent.phoneSigning",
            kSecAttrAccount as String: "ed25519.v1",
            kSecAttrSynchronizable as String: false,
        ]
        var read = query
        read[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            cachedKey = key
            return key
        }
        guard status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        let key = Curve25519.Signing.PrivateKey()
        var insert = query
        insert[kSecValueData as String] = key.rawRepresentation
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let saved = SecItemAdd(insert as CFDictionary, nil)
        guard saved == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(saved))
        }
        cachedKey = key
        return key
    }
    func signedActionData(
        _ action: InboxAction,
        secret: Data
    ) throws -> Data {
        let deviceKey = try self.key()
        guard action.clientId == DeviceApprovalSignature.deviceID(publicKey: deviceKey.publicKey.rawRepresentation) else {
            throw DeviceApprovalSignature.Failure.invalid
        }
        var signed = action
        signed.signature = nil
        signed.deviceSignature = nil
        signed.devicePublicKey = deviceKey.publicKey.rawRepresentation.base64EncodedString()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let deviceBody = try DeviceApprovalSignature.canonicalBody(encoder.encode(signed))
        signed.deviceSignature = try deviceKey.signature(for: deviceBody).base64EncodedString()
        let canonical = try BridgeMessage.innerActionCanonicalBody(encoder.encode(signed))
        signed.signature = BridgeMessage.hmacHex(of: canonical, secret: secret)
        return try encoder.encode(signed)
    }

}

@MainActor
final class PairingStore: ObservableObject {
    /// Unreadable authority is distinct from a checked absence. Sense and
    /// delivery owners retire retained state only for removed or a committed
    /// different key.
    enum Material: Equatable {
        case unavailable
        case removed
        case installed(Data)

        var secret: Data? {
            if case .installed(let data) = self { return data }
            return nil
        }
    }
    private enum Keys {
        // Older builds' installed-key flag did not prove Mac confirmation.
        static let iCloudPaired = "mobile.pairing.macConfirmed"
        // Legacy UserDefaults key — only read for one-time migration
        static let iCloudPairingSecretLegacy = "mobile.pairing.iCloudPairingSecret"
    }

    // MARK: - Keychain helpers (iCloudPairingSecret)

    private static let keychainAccount = "iCloudPairingSecret"
    private static let keychainService = "com.nativeagent.mobile"

    private func readSecretFromKeychain() -> (status: OSStatus, data: Data?) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        return (status, item as? Data)
    }

    /// Transaction algorithm is closure-injected so failure boundaries are
    /// provable without mutating a developer's real Keychain in tests.
    static func persistSecretTransaction(
        _ data: Data,
        read: () -> (OSStatus, Data?),
        update: (Data) -> OSStatus,
        add: (Data) -> OSStatus
    ) -> OSStatus {
        guard data.count == 32 else { return errSecParam }
        let existing = read()
        let writeStatus: OSStatus
        switch existing.0 {
        case errSecSuccess:
            writeStatus = update(data)
        case errSecItemNotFound:
            let addStatus = add(data)
            // Another process may have created the item between read and add.
            writeStatus = addStatus == errSecDuplicateItem ? update(data) : addStatus
        default:
            return existing.0
        }
        guard writeStatus == errSecSuccess else { return writeStatus }
        let verified = read()
        guard verified.0 == errSecSuccess, verified.1 == data else { return errSecDecode }
        return errSecSuccess
    }

    @discardableResult
    private func saveSecretToKeychain(_ data: Data) -> OSStatus {
        Self.persistSecretTransaction(
            data,
            read: { self.readSecretFromKeychain() },
            update: { value in
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: Self.keychainService,
                    kSecAttrAccount as String: Self.keychainAccount,
                ]
                let attributes: [String: Any] = [
                    kSecValueData as String: value,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ]
                return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            },
            add: { value in
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: Self.keychainService,
                    kSecAttrAccount as String: Self.keychainAccount,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    kSecValueData as String: value,
                ]
                return SecItemAdd(query as CFDictionary, nil)
            }
        )
    }

    @Published var isICloudPaired: Bool {
        didSet { UserDefaults.standard.set(isICloudPaired, forKey: Keys.iCloudPaired) }
    }
    // The checked Keychain result is the one owner of availability and bytes.
    @Published private(set) var material: Material = .unavailable {
        didSet {
            if oldValue.secret != iCloudPairingSecret, iCloudSyncEngine.shared.pairingStore === self {
                iCloudSyncEngine.shared.invalidateSnapshots(pairing: iCloudPairingSecret)
            }
            if iCloudBridge.shared.pairingStore === self {
                switch material {
                case .unavailable: break
                case .removed:
                    iCloudBridge.shared.deliveryPairingDidChange()
                case .installed(let secret):
                    if !iCloudBridge.shared.deliveryPairingMatches(secret) {
                        iCloudBridge.shared.deliveryPairingDidChange()
                    } else {
                        iCloudBridge.shared.resumeDeliveryNudges()
                    }
                }
            }
            if oldValue != material, iCloudBridge.shared.pairingStore === self {
                PhonePlaces.shared.resume()
            }
        }
    }
    var iCloudPairingSecret: Data? { material.secret }

    /// All sense retention decisions read this checked result, never nil key
    /// bytes (which can also mean locked, unreadable or not yet restored).
    func sensePairingIdentity() throws -> String? {
        switch material {
        case .unavailable:
            throw DeviceSyncError.underlying(message: "The saved pairing key is unavailable. Retained phone senses and pending readings are unchanged; unlock the iPhone and check the Mac connection.")
        case .removed: return nil
        case .installed(let data):
            guard let identity = AgentNameCache.fingerprint(data) else {
                throw DeviceSyncError.notConfigured
            }
            return identity
        }
    }

    private func pairingUnavailable(_ message: String) {
        secretStorageError = message
        material = .unavailable
        NSLog("[PairingStore] %@", message)
    }
    @Published private(set) var connectionRepairPending = UserDefaults.standard.bool(forKey: "mobile.pairing.connectionRepairPending")
    @Published var isRepairingConnection = false
    @Published private(set) var secretStorageError: String?

    func clearPairingForConnectionRepair() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            pairingUnavailable("Pairing removal could not be verified (Keychain status \(status)). Retained sense state is unchanged.")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        let verified = readSecretFromKeychain()
        guard verified.status == errSecItemNotFound else {
            pairingUnavailable("Pairing removal could not be verified (Keychain status \(verified.status)). Retained sense state is unchanged.")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(verified.status == errSecSuccess ? errSecDecode : verified.status))
        }
        connectionRepairPending = true
        UserDefaults.standard.set(true, forKey: "mobile.pairing.connectionRepairPending")
        UserDefaults.standard.removeObject(forKey: Keys.iCloudPairingSecretLegacy)
        UserDefaults.standard.removeObject(forKey: Self.knownSecretVersionKey)
        isICloudPaired = false
        secretStorageError = nil
        material = .removed
    }

    func finishConnectionRepair() {
        connectionRepairPending = false
        UserDefaults.standard.removeObject(forKey: "mobile.pairing.connectionRepairPending")
    }

    /// True after the Mac confirms this phone, with signed transport configured.
    var isPaired: Bool {
        isICloudPaired && isICloudSigned
    }

    /// True when the 32-byte HMAC secret is present (messages can be signed)
    var isICloudSigned: Bool {
        iCloudPairingSecret != nil
    }

    /// True when iCloud should be used as the transport, even if the convenience
    /// paired flag lagged behind a Keychain/KVS bootstrap.
    var usesICloudTransport: Bool {
        isICloudPaired || iCloudPairingSecret != nil
    }

    private static let knownSecretVersionKey = "mobile.pairing.knownSecretVersion"

    /// The latest pairing_secret_version this device observed from KVS.
    /// Persisted in UserDefaults so a stale-version check survives relaunches.
    var knownSecretVersion: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: Self.knownSecretVersionKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: Self.knownSecretVersionKey) }
    }

    init() {
        isICloudPaired = UserDefaults.standard.bool(forKey: Keys.iCloudPaired)

        // Read Keychain first; migrate legacy UserDefaults only when no Keychain entry exists.
        let keychainRead = readSecretFromKeychain()
        if keychainRead.status == errSecSuccess,
           let keychainData = keychainRead.data, keychainData.count == 32 {
            material = .installed(keychainData)
        } else if keychainRead.status == errSecItemNotFound,
                  let b64 = UserDefaults.standard.string(forKey: Keys.iCloudPairingSecretLegacy),
                  let data = Data(base64Encoded: b64), data.count == 32 {
            // Clear legacy UserDefaults only after a successful Keychain write.
            let saveStatus = saveSecretToKeychain(data)
            if saveStatus == errSecSuccess {
                UserDefaults.standard.removeObject(forKey: Keys.iCloudPairingSecretLegacy)
                material = .installed(data)
            } else {
                // Keep legacy UserDefaults so we don't lose the secret.
                secretStorageError = "Pairing could not be saved in this iPhone's Keychain (status \(saveStatus)). The original key is retained. Unlock the iPhone and check Keychain access before trying Connect again."
                NSLog("[PairingStore] Pairing unavailable: Keychain migration failed (status=\(saveStatus)); source bytes retained. Repair iPhone Keychain access before pairing can resume.")
            }
        } else {
            if keychainRead.status == errSecItemNotFound,
               UserDefaults.standard.object(forKey: Keys.iCloudPairingSecretLegacy) == nil {
                material = .removed
                AgentNameCache.forget()
            } else {
                secretStorageError = "The saved pairing key could not be read or has an invalid shape (Keychain status \(keychainRead.status)). Its bytes are retained. Unlock the iPhone and repair Keychain access before reconnecting."
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(protectedDataBecameAvailable),
            name: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            iCloudBridge.shared.pairingStore = self
            iCloudBridge.shared.setup()
        }
    }

    // MARK: - Protected-data recovery and bounded KVS nudges

    @objc private nonisolated func protectedDataBecameAvailable() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = self.readSecretFromKeychain()
            if result.status == errSecSuccess, let data = result.data, data.count == 32 {
                self.secretStorageError = nil
                self.material = .installed(data)
            } else {
                self.pairingUnavailable("The saved pairing key could not be verified after unlock (Keychain status \(result.status)). Retained sense state is unchanged; check the Mac connection.")
            }
            _ = await self.refreshFromCloudKit()
        }
    }

    /// Runs NSUbiquitousKeyValueStore.synchronize() under a wall-clock timeout
    /// so a wedged cloudd / KVS subsystem can't freeze the caller.
    nonisolated static func synchronizeKVSWithTimeout() async {
        _ = await withCKTimeout("PairingStore.KVS.synchronize", seconds: 2) {
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    /// Receives pairing material from the CloudKit transport. Exact length is
    /// validated before the existing PairingStore transaction writes Keychain;
    /// no bridge or transport may become a second persistence owner. True only
    /// when a different key was installed.
    @discardableResult
    func applyCloudKitPairingSecret(
        _ data: Data,
        persist: ((Data) -> OSStatus)? = nil
    ) -> Bool {
        guard !isRepairingConnection, data.count == 32, iCloudPairingSecret != data else { return false }
        return installPairingSecret(data, source: "CloudKit", persist: persist)
    }

    /// Keychain-first pairing transaction. Published/UI state changes only
    /// after the durable write and exact read-back succeed.
    private func installPairingSecret(
        _ data: Data,
        source: String,
        persist: ((Data) -> OSStatus)? = nil
    ) -> Bool {
        guard data.count == 32 else {
            NSLog("[PairingStore] \(source) pairing rejected: expected 32 bytes, received \(data.count)")
            return false
        }
        let existing = readSecretFromKeychain()
        if existing.status == errSecSuccess, existing.data == data {
            secretStorageError = nil
            material = .installed(data)
            return true
        }
        let writeStatus = persist?(data) ?? saveSecretToKeychain(data)
        guard writeStatus == errSecSuccess else {
            pairingUnavailable("\(source) pairing Keychain write could not be verified (status \(writeStatus)). Unlock the iPhone and check the Mac connection; retained sense state is unchanged.")
            return false
        }
        isICloudPaired = false
        secretStorageError = nil
        material = .installed(data)
        NSLog("[PairingStore] \(source) pairing installed transactionally")
        return true
    }

    /// Refresh pairing through its transport owner, without re-entering message
    /// delivery: an incoming resync hint can call this during the setup drain.
    @discardableResult
    func refreshFromCloudKit() async -> Bool {
        guard !isRepairingConnection else { return false }
        let previousSecret = iCloudPairingSecret
        _ = await iCloudBridge.shared.refreshPairingFromCloudKit()
        return iCloudPairingSecret != previousSecret
    }

    // Only a successful pairDevice response completes pairing.
    func applyICloudPairing() {
        isICloudPaired = true
    }
}
