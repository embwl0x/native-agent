// PATCH-2026-05-07: icloud-bridge pairing store.
// v1: iCloudPairingSecret migrated from UserDefaults to Keychain
// AUTO-BOOTSTRAP (2026-05-11): reads HMAC secret from iCloud KVS on init and on live KVS
// change notifications so iOS pairs automatically when both devices share the same iCloud account.
import Foundation
import NativeAgentShared
import Observation
import Security
import CryptoKit
import UIKit

/// One device-local signing identity, never synced through iCloud or restored
/// onto another phone. A failed read must not silently replace the identity.
enum PhoneSigningIdentity {
    static func key() throws -> Curve25519.Signing.PrivateKey {
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
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
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
        return key
    }
}

enum PairingKVSRefreshResult {
    static func installedNewMaterial(applied: Bool, previousSecret: Data?, currentSecret: Data?) -> Bool {
        applied && currentSecret != previousSecret
    }
}

@MainActor
final class PairingStore: ObservableObject {
    private enum Keys {
        // Retired LAN/HTTP credentials. These names remain only so launch can
        // erase values written by older builds.
        static let retiredServerURL = "mobile.pairing.serverURL"
        static let retiredBearerToken = "mobile.pairing.bearerToken"
        // PATCH-2026-05-07: icloud-bridge iCloud pairing flag
        static let iCloudPaired = "mobile.pairing.iCloudPaired"
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

    private func loadSecretFromKeychain() -> Data? {
        let result = readSecretFromKeychain()
        guard result.status == errSecSuccess else { return nil }
        return result.data
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

    // PATCH-2026-05-07: icloud-bridge true when user connected via iCloud (no bearer token needed)
    @Published var isICloudPaired: Bool {
        didSet { UserDefaults.standard.set(isICloudPaired, forKey: Keys.iCloudPaired) }
    }
    // 32-byte HMAC key shared with the Mac; nil until user scans or pastes the pairing key.
    // v1: stored in Keychain (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly — device-local, no iCloud sync).
    // Persistence is owned only by installPairingSecret. Keeping
    // the published value free of a side-effecting observer prevents a failed
    // Keychain mutation from being represented as committed UI/runtime state.
    @Published var iCloudPairingSecret: Data? = nil

    /// True when signed iCloud pairing is configured.
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

    // MARK: - KVS auto-bootstrap key namespace (must match Mac side exactly)

    private enum KVSPairingKey {
        static let hmacSecret   = "NativeAgent.pairing.hmacSecret"
        // Phase 14e-iCloud HMAC self-heal: monotonic pairing_secret_version
        // stamped by Mac on every re-publish. iOS uses it to detect a stale
        // cached secret and force a re-fetch.
        static let secretVersion = "NativeAgent.pairing.secretVersion"
    }

    private static let knownSecretVersionKey = "mobile.pairing.knownSecretVersion"

    /// The latest pairing_secret_version this device observed from KVS.
    /// Persisted in UserDefaults so a stale-version check survives relaunches.
    var knownSecretVersion: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: Self.knownSecretVersionKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: Self.knownSecretVersionKey) }
    }

    init() {
        // HTTP/LAN transport is retired. Purge credentials from older builds
        // rather than carrying an inert bearer token indefinitely. Repeating
        // these idempotent removals also covers an upgrade after a downgrade.
        UserDefaults.standard.removeObject(forKey: Keys.retiredServerURL)
        UserDefaults.standard.removeObject(forKey: Keys.retiredBearerToken)
        isICloudPaired = UserDefaults.standard.bool(forKey: Keys.iCloudPaired)

        // Load from Keychain (v1). If absent, attempt one-time migration from legacy UserDefaults (v0).
        let keychainRead = readSecretFromKeychain()
        if keychainRead.status == errSecSuccess,
           let keychainData = keychainRead.data, keychainData.count == 32 {
            iCloudPairingSecret = keychainData
        } else if keychainRead.status == errSecItemNotFound,
                  let b64 = UserDefaults.standard.string(forKey: Keys.iCloudPairingSecretLegacy),
                  let data = Data(base64Encoded: b64), data.count == 32 {
            // PATCH-2026-05-08: review-fix-r4 Only clear legacy UserDefaults
            // AFTER confirming the Keychain write succeeded. Otherwise a
            // failed SecItemAdd (e.g. Keychain locked) would lose the secret
            // entirely.
            let saveStatus = saveSecretToKeychain(data)
            if saveStatus == errSecSuccess {
                // Fresh add succeeded — safe to clear legacy storage now.
                UserDefaults.standard.removeObject(forKey: Keys.iCloudPairingSecretLegacy)
            } else {
                // Keep legacy UserDefaults so we don't lose the secret.
                NSLog("[PairingStore] Keychain migration failed (status=\(saveStatus)); keeping legacy storage")
            }
            iCloudPairingSecret = data
        } else {
            iCloudPairingSecret = nil
        }

        // AUTO-BOOTSTRAP: attempt to pull pairing material from iCloud KVS
        // immediately on init. This covers the case where the Mac has already
        // published the secret before the iOS app first launched.
        // KVS.synchronize() can block when cloudd is wedged, so we defer it
        // off the init's caller path and run it through withCKTimeout so a
        // hung KVS subsystem can't freeze launch.
        Task { [weak self] in
            await Self.synchronizeKVSWithTimeout()
            self?.applyKVSPairingMaterialIfNeededAsync()
        }

        // Register for live KVS change notifications so if the Mac publishes
        // AFTER this app is already running (e.g. on the pairing screen), the
        // pairing screen dismisses automatically within one KVS sync cycle.
        // Pattern follows iCloudBridge's @objc nonisolated selector convention
        // (KVS callbacks fire on com.apple.kvs.client.callback, not main).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(kvsDidChangeForPairing(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(protectedDataBecameAvailable),
            name: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil
        )

        // A standalone App Store build can use CloudKit even when iCloud Drive
        // is unavailable. Start the existing bridge during the unpaired screen
        // so it can receive the Mac's canonical secret; KVS personal mode
        // remains unchanged.
        if DeviceSyncTransportResolver.resolvedKind() == .cloudkit {
            Task { @MainActor [weak self] in
                guard let self else { return }
                iCloudBridge.shared.pairingStore = self
                iCloudBridge.shared.setup()
            }
        }
    }

    // MARK: - KVS auto-bootstrap helpers

    @objc private nonisolated func protectedDataBecameAvailable() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.isICloudPaired,
               let data = self.loadSecretFromKeychain(), data.count == 32 {
                self.iCloudPairingSecret = data
            }
            self.applyKVSPairingMaterialIfNeededAsync()
        }
    }

    /// Runs NSUbiquitousKeyValueStore.synchronize() under a wall-clock timeout
    /// so a wedged cloudd / KVS subsystem can't freeze the caller.
    private nonisolated static func synchronizeKVSWithTimeout() async {
        _ = await withCKTimeout("PairingStore.KVS.synchronize", seconds: 2) {
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    /// MainActor-bridging wrapper so the detached init Task can invoke the
    /// MainActor-isolated applyKVSPairingMaterialIfNeeded().
    @MainActor
    private func applyKVSPairingMaterialIfNeededAsync() {
        _ = applyKVSPairingMaterialIfNeeded()
    }

    /// Reads the HMAC secret from iCloud KVS and, if it differs from (or is newer than)
    /// the value currently in Keychain, writes it to Keychain and sets isICloudPaired.
    /// Safe to call repeatedly — no-ops when everything is already current.
    @discardableResult
    func applyKVSPairingMaterialIfNeeded() -> Bool {
        let kvs = NSUbiquitousKeyValueStore.default
        guard let secretData = Self.validatedKVSPairingSecret(
            base64: kvs.string(forKey: KVSPairingKey.hmacSecret)
        ) else {
            // KVS has no pairing material yet — nothing to do.
            return false
        }

        // Phase 14e-iCloud HMAC self-heal: stamp the observed secret version
        // even when we end up no-op'ing the write below, so a freshly-paired
        // device tracks the Mac's current version from the first launch.
        let observedVersion = Int64(kvs.longLong(forKey: KVSPairingKey.secretVersion))
        if observedVersion > knownSecretVersion {
            knownSecretVersion = observedVersion
        }

        // Idempotency: compare KVS secret to what's already in Keychain.
        // Only write if different (avoids unnecessary Keychain writes on every launch).
        let existing = loadSecretFromKeychain()
        if existing == secretData && isICloudPaired {
            iCloudPairingSecret = secretData
            return false
        }

        // Write the new secret to Keychain via the existing save path.
        return installPairingSecret(secretData, source: "KVS")
    }

    static func validatedKVSPairingSecret(base64: String?) -> Data? {
        guard let base64, let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        return data
    }

    /// Receives pairing material from the CloudKit transport. Exact length is
    /// validated before the existing PairingStore transaction writes Keychain;
    /// no bridge or transport may become a second persistence owner.
    @discardableResult
    func applyCloudKitPairingSecret(
        _ data: Data,
        persist: ((Data) -> OSStatus)? = nil
    ) -> Bool {
        guard data.count == 32 else { return false }
        if iCloudPairingSecret == data, isICloudPaired {
            return true
        }
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
        if loadSecretFromKeychain() == data, isICloudPaired {
            iCloudPairingSecret = data
            return true
        }
        let writeStatus = persist?(data) ?? saveSecretToKeychain(data)
        guard writeStatus == errSecSuccess else {
            NSLog("[PairingStore] \(source) pairing Keychain write failed (status=\(writeStatus))")
            return false
        }
        iCloudPairingSecret = data
        isICloudPaired = true
        NSLog("[PairingStore] \(source) pairing installed transactionally")
        return true
    }

    /// Re-read HMAC material from KVS. Returns true only when a different
    /// secret is durably installed in Keychain.
    @discardableResult
    func refreshFromKVS() async -> Bool {
        // Synchronize first so we get the freshest KVS state — but under the
        // same timeout wrapper the launch path uses: this self-heal fires
        // precisely when KVS/cloudd is misbehaving (signature resync), and a
        // bare synchronize() on the MainActor freezes the whole UI behind a
        // wedged cloudd (2026-07-21 audit).
        await Self.synchronizeKVSWithTimeout()
        // Drop the cached in-memory copy so the next applyKVSPairingMaterialIfNeeded
        // pass writes the new Keychain entry rather than no-op'ing on equality.
        let previousSecret = iCloudPairingSecret
        let applied = applyKVSPairingMaterialIfNeeded()
        if PairingKVSRefreshResult.installedNewMaterial(
            applied: applied,
            previousSecret: previousSecret,
            currentSecret: iCloudPairingSecret
        ) {
            NSLog("[PairingStore] refreshFromKVS: new HMAC secret installed")
            return true
        }
        return false
    }

    /// KVS change observer for auto-bootstrap.  Follows the nonisolated + MainActor-hop
    /// pattern required for @MainActor classes (see NativeAgent skill notes).
    @objc private nonisolated func kvsDidChangeForPairing(_ note: Notification) {
        guard let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
              changed.contains(KVSPairingKey.hmacSecret) else { return }
        Task { @MainActor in
            let applied = self.applyKVSPairingMaterialIfNeeded()
            if applied {
                NSLog("[PairingStore] auto-bootstrap: live KVS update applied — pairing screen should dismiss")
            }
        }
    }

    // PATCH-2026-05-07: icloud-bridge set iCloud as the active transport
    func applyICloudPairing() {
        isICloudPaired = true
    }
}
