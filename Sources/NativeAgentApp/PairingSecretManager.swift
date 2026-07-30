// PATCH-2026-05-08: icloud-pairing-ui — single source of truth for the HMAC pairing secret
// Both MacSyncEngine (HMAC validation) and MacPairingView (QR display) go through here.
import Foundation
import Security
import NativeAgentShared

private enum PairingKVSPublishResult: Sendable {
    case skippedCurrent
    case published(version: Int, synced: Bool)
}

enum PairingSecretManager {
    private static var secretURL: URL {
        // Phase 11c: pairing secret goes into <repo>/data/ via shared resolver.
        let dir = NativeAgentPaths.dataRoot
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("icloud_pairing_secret.bin")
    }

    /// Loads the existing 32-byte secret from disk, or generates + persists a new one.
    /// Thread-safe: reading/writing a single small file is atomic enough for our use.
    static func loadOrGenerateSecret() -> Data {
        let url = secretURL
        if let existing = try? Data(contentsOf: url), existing.count == 32 {
            // PATCH-2026-05-08: review-fix-r2 Re-apply 0600 on existing files
            // — files migrated from older builds may have looser perms.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else {
            preconditionFailure("NativeAgent could not generate a secure iCloud pairing secret")
        }
        let secret = Data(bytes)
        try? secret.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return secret
    }

    /// Base-64 string of the current secret (for display / manual entry on iOS).
    static func currentSecretBase64() -> String {
        loadOrGenerateSecret().base64EncodedString()
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
    static func publishMaterialToKVS(forceBumpVersion: Bool = false) async {
        guard await CloudKitHealth.shared.likelyHealthy() else {
            return
        }
        let secretB64 = currentSecretBase64()

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
        case .published(let nextVersion, let synced):
            NSLog(
                "[PairingBootstrap] Published HMAC pairing_secret_version=%d to KVS (synchronize=%@)",
                nextVersion, synced ? "ok" : "deferred"
            )
        case nil:
            return
        }
    }

    /// Publishes the exact canonical Mac pairing secret through the selected
    /// device transport. This is the public-release CloudKit equivalent of the
    /// legacy KVS bootstrap; it does not create a second secret or pairing
    /// owner. Entitlement and account failures remain transport errors and do
    /// not fall back to unsigned material.
    @discardableResult
    static func publishMaterial(to transport: DeviceSyncTransport) async -> Bool {
        let secret = loadOrGenerateSecret()
        guard secret.count == 32 else {
            NSLog("[PairingBootstrap] Refusing to publish malformed canonical HMAC material")
            return false
        }
        do {
            try await transport.publishPairing(secret: secret)
            NSLog("[PairingBootstrap] Published canonical HMAC material through device transport")
            return true
        } catch {
            NSLog("[PairingBootstrap] Device-transport pairing publish failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Delete the secret file so the next call to loadOrGenerateSecret() creates a fresh one.
    static func deleteSecret() {
        try? FileManager.default.removeItem(at: secretURL)
    }
}
