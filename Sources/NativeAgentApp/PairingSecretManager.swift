// PATCH-2026-05-08: icloud-pairing-ui — single source of truth for the HMAC pairing secret
// Both MacSyncEngine (HMAC validation) and MacPairingView (QR display) go through here.
import Foundation
import Security
import NativeAgentShared
import PersistenceCore

private enum PairingKVSPublishResult: Sendable {
    case skippedCurrent
    case published(version: Int, synced: Bool)
}

enum PairingSecretManager {
    private static var secretURL: URL {
        NativeAgentPaths.dataRoot.appendingPathComponent("icloud_pairing_secret.bin")
    }

    /// Loads the exact regular 0600 32-byte secret, or durably creates one when
    /// and only when it is missing. Existing invalid state remains untouched
    /// and makes pairing unavailable until the user deliberately repairs it.
    static func loadOrGenerateSecret() throws -> Data {
        try loadOrGenerateSecret(at: secretURL)
    }

    /// Internal injection seam for exact persistence-boundary tests.
    static func loadOrGenerateSecret(at url: URL) throws -> Data {
        try CheckedFixedSizeSecretFile.loadOrCreate(at: url, byteCount: 32) {
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
            guard status == errSecSuccess else {
                throw NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey: "secure random generation failed"]
                )
            }
            return Data(bytes)
        }
    }

    /// Explicit, atomic rotation. The prior canonical bytes remain active if
    /// generation, persistence, verification, or cleanup fails.
    static func rotateSecret() throws -> Data {
        try rotateSecret(at: secretURL)
    }

    static func rotateSecret(at url: URL) throws -> Data {
        try CheckedFixedSizeSecretFile.replace(at: url, byteCount: 32) {
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
            guard status == errSecSuccess else {
                throw NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey: "secure random generation failed"]
                )
            }
            return Data(bytes)
        }
    }

    /// Base-64 string of the current secret (for display / manual entry on iOS).
    static func currentSecretBase64() throws -> String {
        try loadOrGenerateSecret().base64EncodedString()
    }

    // Phase 14e-iCloud HMAC self-heal: monotonic pairing_secret_version stamped
    // on every KVS publish. iOS uses it to detect when its cached secret has
    // gone stale relative to the Mac's authoritative copy and re-fetches.
    private static let secretVersionKey = "NativeAgent.pairing.secretVersionLocal"

    static func currentSecretVersion() -> Int {
        UserDefaults.standard.integer(forKey: secretVersionKey)
    }

    /// Publish current HMAC secret to KVS, bumping the secretVersion stamp so
    /// iOS can detect stale secrets and re-fetch. Always publishes (no skip)
    /// when called from the signature-mismatch self-heal path — caller controls
    /// when to bump.
    @discardableResult
    static func publishMaterialToKVS(forceBumpVersion: Bool = false) async -> Bool {
        let secret: Data
        do {
            secret = try loadOrGenerateSecret()
        } catch {
            NSLog("[PairingBootstrap] Pairing unavailable; refusing KVS publish: \(error.localizedDescription)")
            return false
        }
        return await publishMaterialToKVS(secret, forceBumpVersion: forceBumpVersion)
    }

    @discardableResult
    static func publishMaterialToKVS(
        _ secret: Data,
        forceBumpVersion: Bool = false
    ) async -> Bool {
        guard secret.count == 32 else { return false }
        let secretB64 = secret.base64EncodedString()
        guard await CloudKitHealth.shared.likelyHealthy() else {
            return false
        }

        // gpt-5.5 review fix (MED-3): the old order set local KVS keys AND
        // bumped secretVersionKey BEFORE synchronize(); a synchronize timeout
        // left local state showing "published" and the next non-forced launch
        // skipped the re-publish — iOS never saw the new secret. Fixed by:
        // (a) only writing local KVS keys after synchronize() returns,
        // (b) only bumping secretVersionKey on a confirmed sync,
        // so a timeout = next launch re-tries. forceBumpVersion still wins.
        let result = await withCKTimeout("PairingSecretManager.publishMaterialToKVS") {
            let kvs = NSUbiquitousKeyValueStore.default
            let existingB64 = kvs.string(forKey: "NativeAgent.pairing.hmacSecret") ?? ""
            if existingB64 == secretB64 && !forceBumpVersion {
                return PairingKVSPublishResult.skippedCurrent
            }
            let nextVersion = currentSecretVersion() + 1
            kvs.set(secretB64, forKey: "NativeAgent.pairing.hmacSecret")
            kvs.set(ISO8601DateFormatter().string(from: Date()), forKey: "NativeAgent.pairing.publishedAt")
            kvs.set(Int64(nextVersion), forKey: "NativeAgent.pairing.secretVersion")
            let synced = kvs.synchronize()
            if synced {
                UserDefaults.standard.set(nextVersion, forKey: secretVersionKey)
            }
            return PairingKVSPublishResult.published(version: nextVersion, synced: synced)
        }

        switch result {
        case .skippedCurrent:
            NSLog("[PairingBootstrap] KVS already has current HMAC secret — skipping publish")
            return true
        case .published(let nextVersion, let synced):
            NSLog(
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
            NSLog("[PairingBootstrap] Pairing unavailable; refusing device publish: \(error.localizedDescription)")
            return false
        }
        return await publishMaterial(secret, to: transport)
    }

    @discardableResult
    static func publishMaterial(_ secret: Data, to transport: DeviceSyncTransport) async -> Bool {
        guard secret.count == 32 else { return false }
        do {
            try await transport.publishPairing(secret: secret)
            NSLog("[PairingBootstrap] Published canonical HMAC material through device transport")
            return true
        } catch {
            NSLog("[PairingBootstrap] Device-transport pairing publish failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Delete only a currently valid canonical secret after explicit user
    /// confirmation. Invalid or non-regular state remains preserved.
    static func deleteSecret() throws {
        try deleteSecret(at: secretURL)
    }

    static func deleteSecret(at url: URL) throws {
        _ = try loadOrGenerateSecret(at: url)
        try FileManager.default.removeItem(at: url)
    }
}
