import Foundation
import CryptoKit
import Security
import NativeAgentShared
import PersistenceCore

// Blueprint: | `PairingSecretManager.swift` | `PairingSecret`; Device-only secret, explicit rotation and readback. |

private enum PairingKVSPublishResult: Sendable {
    case skippedCurrent
    case versionExhausted
    case published(version: Int, synced: Bool)
}

public enum PairingSecret {
    private static let secretService = "NativeAgent.icloud-pairing"

    private static func secretAccount(for url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    private static var secretURL: URL {
        PersistenceCore.defaultDataRoot().appendingPathComponent("icloud_pairing_secret.bin")
    }

    /// Only missing Keychain state permits creation; invalid existing authority stays untouched until explicit repair.
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

    /// Accepted but unverified rotation stays committed and requires exact-item reconciliation.
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

    /// Quiet reads must never mint pairing authority.
    public static func existingSecretBase64() throws -> String? {
        try existingSecret(at: secretURL)?.base64EncodedString()
    }

    /// Reconcile committed authority without creating a replacement if it is absent.
    public static func requireExistingSecret() throws -> Data {
        guard let secret = try existingSecret(at: secretURL) else {
            throw DeviceSecretKeychain.Failure.unavailable
        }
        return secret
    }

    static func existingSecret(at url: URL) throws -> Data? {
        try CredentialFileLock.withLock(url) {
            let account = secretAccount(for: url)
            let current = try DeviceSecretKeychain.read(service: secretService, account: account)
            if let current, current.count != 32 { throw DeviceSecretKeychain.Failure.unavailable }
            return current
        }
    }

    // Monotonic pairing_secret_version lets the phone detect stale cached authority and fetch the Mac's exact secret.
    private static let secretVersionKey = "NativeAgent.pairing.secretVersionLocal"
    private static let synchronizationCheckpointKey = "NativeAgent.pairing.synchronizationCheckpoint"

    static func currentSecretVersion() -> Int {
        UserDefaults.standard.integer(forKey: secretVersionKey)
    }

    /// Publish even during signature-mismatch repair; only the caller decides when secretVersion must advance.
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
        // KVS reads include local unsynchronized writes; only a post-sync checkpoint proves publication.
        let result = await Task.detached(priority: .utility) {
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
            let (nextVersion, overflow) = version.addingReportingOverflow(1)
            guard !overflow else { return PairingKVSPublishResult.versionExhausted }
            defaults.removeObject(forKey: synchronizationCheckpointKey)
            kvs.set(secretB64, forKey: "NativeAgent.pairing.hmacSecret")
            kvs.set(Int64(nextVersion), forKey: "NativeAgent.pairing.secretVersion")
            let synced = kvs.synchronize()
            if synced {
                defaults.set(nextVersion, forKey: secretVersionKey)
                defaults.set(["digest": secretDigest, "version": nextVersion] as [String: Any], forKey: synchronizationCheckpointKey)
            }
            return PairingKVSPublishResult.published(version: nextVersion, synced: synced)
        }.value

        switch result {
        case .skippedCurrent:
            nativeLog("[PairingBootstrap] KVS already has current HMAC secret — skipping publish")
            return true
        case .versionExhausted:
            nativeLog("[PairingBootstrap] Pairing version exhausted; material and checkpoint left unchanged")
            return false
        case .published(let nextVersion, let synced):
            nativeLog(
                "[PairingBootstrap] Published HMAC pairing_secret_version=%d to KVS (synchronize=%@)",
                nextVersion, synced ? "ok" : "deferred"
            )
            return synced
        }
    }

    @discardableResult
    static func publishMaterial(_ secret: Data, to transport: CloudKitDeviceTransport) async -> Bool {
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

}
