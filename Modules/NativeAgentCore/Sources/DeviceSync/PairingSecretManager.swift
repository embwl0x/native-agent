// PATCH-2026-05-08: icloud-pairing-ui — single source of truth for the HMAC pairing secret
// Both MacSyncEngine (HMAC validation) and MacPairingView (QR display) go through here.
import Foundation
import CryptoKit
import Security
import NativeAgentShared
import PersistenceCore

private enum PairingKVSPublishResult: Sendable {
    case skippedCurrent
    case published(version: Int, synced: Bool)
}

public enum PairingSecretManager {
    private static let secretService = "NativeAgent.icloud-pairing"

    private static func secretAccount(for url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    private static var secretURL: URL {
        PersistenceCore.defaultDataRoot().appendingPathComponent("icloud_pairing_secret.bin")
    }

    /// Loads the exact device-only Keychain secret, or creates one when
    /// and only when it is missing. Existing invalid state remains untouched
    /// and makes pairing unavailable until the user deliberately repairs it.
    public static func loadOrGenerateSecret() throws -> Data {
        try loadOrGenerateSecret(at: secretURL)
    }

    static func loadOrGenerateSecret(at url: URL) throws -> Data {
        try CredentialFileLock.withLock(url) {
            if let existing = try existingSecret(at: url) { return existing }
            let secret = try generateSecret()
            try DeviceSecretKeychain.insert(secret, service: secretService, account: secretAccount(for: url))
            return secret
        }
    }

    /// Explicit Keychain rotation with read-back verification and rollback
    /// of the prior bytes if verification fails.
    public static func rotateSecret() throws -> Data {
        try rotateSecret(at: secretURL)
    }

    static func rotateSecret(at url: URL) throws -> Data {
        try CredentialFileLock.withLock(url) {
            guard try existingSecret(at: url) != nil else { throw DeviceSecretKeychain.Failure.unavailable }
            let secret = try generateSecret()
            try DeviceSecretKeychain.replace(secret, service: secretService, account: secretAccount(for: url))
            return secret
        }
    }

    private static func generateSecret() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "secure random generation failed"])
        }
        return Data(bytes)
    }

    /// Base-64 string of the current secret (for display / manual entry on iOS).
    public static func currentSecretBase64() throws -> String {
        try loadOrGenerateSecret().base64EncodedString()
    }

    /// The existing secret, migrating legacy disk material without generating.
    ///
    /// A read must not make the thing it reads. `currentSecretBase64()` goes
    /// through `loadOrGenerateSecret`, which CREATES the canonical pairing
    /// secret when storage is missing — fine for the page a person opened,
    /// wrong for a quiet offscreen read of Connectors, which would mint
    /// pairing authority nobody asked for.
    public static func existingSecretBase64() throws -> String? {
        try existingSecret(at: secretURL)?.base64EncodedString()
    }

    static func existingSecret(at url: URL) throws -> Data? {
        try CredentialFileLock.withLock(url) {
            let account = secretAccount(for: url)
            let legacy = try CheckedFixedSizeSecretFile.peekExisting(at: url, byteCount: 32)
            var current = try DeviceSecretKeychain.read(service: secretService, account: account)
            if let current, current.count != 32 { throw DeviceSecretKeychain.Failure.unavailable }
            if let legacy {
                if let current {
                    guard current == legacy else { throw DeviceSecretKeychain.Failure.unavailable }
                } else {
                    try DeviceSecretKeychain.insert(legacy, service: secretService, account: account)
                    current = legacy
                }
                // Insert verifies the exact Keychain bytes before legacy removal.
                guard try DeviceSecretKeychain.read(service: secretService, account: account) == legacy else {
                    throw DeviceSecretKeychain.Failure.unavailable
                }
                try FileManager.default.removeItem(at: url)
            }
            return current
        }
    }

    // Phase 14e-iCloud HMAC self-heal: monotonic pairing_secret_version stamped
    // on every KVS publish. iOS uses it to detect when its cached secret has
    // gone stale relative to the Mac's authoritative copy and re-fetches.
    private static let secretVersionKey = "NativeAgent.pairing.secretVersionLocal"
    private static let synchronizationCheckpointKey = "NativeAgent.pairing.synchronizationCheckpoint"

    static func currentSecretVersion() -> Int {
        UserDefaults.standard.integer(forKey: secretVersionKey)
    }

    /// Publish current HMAC secret to KVS, bumping the secretVersion stamp so
    /// iOS can detect stale secrets and re-fetch. Always publishes (no skip)
    /// when called from the signature-mismatch self-heal path — caller controls
    /// when to bump.
    @discardableResult
    public static func publishMaterialToKVS(forceBumpVersion: Bool = false) async -> Bool {
        let secret: Data
        do {
            secret = try loadOrGenerateSecret()
        } catch {
            nativeLog("[PairingBootstrap] Pairing unavailable; refusing KVS publish: \(error.localizedDescription)")
            return false
        }
        return await publishMaterialToKVS(secret, forceBumpVersion: forceBumpVersion)
    }

    @discardableResult
    public static func publishMaterialToKVS(
        _ secret: Data,
        forceBumpVersion: Bool = false
    ) async -> Bool {
        guard secret.count == 32 else { return false }
        let secretB64 = secret.base64EncodedString()
        let secretDigest = SHA256.hash(data: secret).map { String(format: "%02x", $0) }.joined()
        guard await CloudKitHealth.shared.likelyHealthy() else {
            return false
        }

        // KVS reads include unsynchronized local writes. Only a checkpoint
        // recorded after synchronization proves this secret/version was sent.
        let result = await withCKTimeout("PairingSecretManager.publishMaterialToKVS") {
            let kvs = NSUbiquitousKeyValueStore.default
            let defaults = UserDefaults.standard
            let existingB64 = kvs.string(forKey: "NativeAgent.pairing.hmacSecret") ?? ""
            let version = currentSecretVersion()
            let checkpoint = defaults.dictionary(forKey: synchronizationCheckpointKey)
            if !forceBumpVersion, existingB64 == secretB64, version > 0,
               kvs.longLong(forKey: "NativeAgent.pairing.secretVersion") == Int64(version),
               checkpoint?["digest"] as? String == secretDigest,
               checkpoint?["version"] as? Int == version {
                return PairingKVSPublishResult.skippedCurrent
            }
            let nextVersion = version + 1
            defaults.removeObject(forKey: synchronizationCheckpointKey)
            kvs.set(secretB64, forKey: "NativeAgent.pairing.hmacSecret")
            kvs.set(ISO8601DateFormatter().string(from: Date()), forKey: "NativeAgent.pairing.publishedAt")
            kvs.set(Int64(nextVersion), forKey: "NativeAgent.pairing.secretVersion")
            let synced = kvs.synchronize()
            if synced {
                defaults.set(nextVersion, forKey: secretVersionKey)
                defaults.set(["digest": secretDigest, "version": nextVersion] as [String: Any], forKey: synchronizationCheckpointKey)
            }
            return PairingKVSPublishResult.published(version: nextVersion, synced: synced)
        }

        switch result {
        case .skippedCurrent:
            nativeLog("[PairingBootstrap] KVS already has current HMAC secret — skipping publish")
            return true
        case .published(let nextVersion, let synced):
            nativeLog(
                "[PairingBootstrap] Published HMAC pairing_secret_version=%d to KVS (synchronize=%@)",
                nextVersion, synced ? "ok" : "deferred"
            )
            return synced
        case nil:
            return false
        }
    }

    /// Publishes the exact canonical Mac pairing secret through the selected
    /// device transport. This is the public-release CloudKit equivalent of the
    /// legacy KVS bootstrap; it does not create a second secret or pairing
    /// owner. Entitlement and account failures remain transport errors and do
    /// not fall back to unsigned material.
    @discardableResult
    static func publishMaterial(to transport: DeviceSyncTransport) async -> Bool {
        let secret: Data
        do {
            secret = try loadOrGenerateSecret()
        } catch {
            nativeLog("[PairingBootstrap] Pairing unavailable; refusing device publish: \(error.localizedDescription)")
            return false
        }
        return await publishMaterial(secret, to: transport)
    }

    @discardableResult
    static func publishMaterial(_ secret: Data, to transport: DeviceSyncTransport) async -> Bool {
        guard secret.count == 32 else { return false }
        do {
            try await transport.publishPairing(secret: secret)
            nativeLog("[PairingBootstrap] Published canonical HMAC material through device transport")
            return true
        } catch {
            nativeLog("[PairingBootstrap] Device-transport pairing publish failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Delete only a currently valid canonical Keychain secret after explicit
    /// user confirmation. Invalid legacy state remains preserved.
    static func deleteSecret() throws {
        try deleteSecret(at: secretURL)
    }

    static func deleteSecret(at url: URL) throws {
        try CredentialFileLock.withLock(url) {
            _ = try existingSecret(at: url)
            try DeviceSecretKeychain.delete(service: secretService, account: secretAccount(for: url))
        }
    }
}
