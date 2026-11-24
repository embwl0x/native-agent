import Foundation
import CryptoKit
import Security
import NativeAgentShared
import PersistenceCore

// Blueprint: | `PairingSecretManager.swift` | `PairingSecret`; Device-only secret, explicit rotation and readback. |

public enum PairingSecret {
    private static let secretService = "NativeAgent.icloud-pairing"

    private static func secretAccount(for url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    private static func secretURL(_ root: URL = PersistenceCore.defaultDataRoot()) -> URL {
        root.appendingPathComponent("icloud_pairing_secret.bin")
    }

    /// Only missing Keychain state permits creation; invalid existing authority stays untouched until explicit repair.
    public static func loadOrGenerateSecret() throws -> Data {
        try loadOrGenerateSecret(at: secretURL())
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
        try rotateSecret(at: secretURL())
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
        let status = unsafe SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "secure random generation failed"])
        }
        return Data(bytes)
    }

    /// Quiet reads must never mint pairing authority.
    public static func existingSecretBase64() throws -> String? {
        try existingSecret(at: secretURL())?.base64EncodedString()
    }

    /// Reconcile committed authority without creating a replacement if it is absent.
    public static func requireExistingSecret(dataRoot: URL = PersistenceCore.defaultDataRoot()) throws -> Data {
        guard let secret = try existingSecret(at: secretURL(dataRoot)) else {
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

    // The unsigned resync hint's shared wire schema requires the last published version, including zero before publication.
    private static let secretVersionKey = "NativeAgent.pairing.secretVersionLocal"

    static func currentSecretVersion() -> Int {
        UserDefaults.standard.integer(forKey: secretVersionKey)
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
