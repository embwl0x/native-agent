import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `SwiftNativeAPNSSender.swift` | One APNs sender actor owns credential state, JWT reuse/expiry, rejection holds and signing |
public actor SwiftNativeAPNSSender {
    /// Reuse provider JWTs for 50 minutes to avoid `TooManyProviderTokenUpdates` and Apple's 60-minute expiry.
    static let providerTokenTTL: TimeInterval = 50 * 60

    private struct CachedProviderToken: Codable {
        let keyId: String
        let teamId: String
        let jwt: String
        let issuedAt: Date
    }
    /// Signed provider JWT, cached by (keyId, teamId). The actor's isolation
    /// serializes access, so concurrent sends can never double-mint.
    private var cachedProviderToken: CachedProviderToken?

    /// Rejected JWTs bypass the reusable 0600 cache beside the .p8 key so the next send mints a fresh token.
    private var providerTokenRejected = false
    private var providerTokenStoreURL: URL?

    /// After Apple rejects a push with `TooManyProviderTokenUpdates`, hold
    /// re-mints for this long — Apple's remedy is to stop updating the token
    /// and keep using the current one, not to sign a fresh JWT (which makes
    /// the rejection worse).
    static let providerTokenUpdateBackoff: TimeInterval = 10 * 60

    /// Absolute reuse ceiling while a hold is active: never serve a token old
    /// enough to cross Apple's 60-min hard expiry mid-flight.
    static let providerTokenHardCap: TimeInterval = 58 * 60

    /// End of the current re-mint hold, set by `noteRejection`, cleared by the
    /// next successful mint.
    private var providerTokenHoldUntil: Date?

    public init() {}

    /// Returns a signed provider token for the given credentials, minting only
    /// on first use, expiry, or a credential (keyId/teamId) change. A signing
    /// error propagates and leaves any prior cache untouched — no stale token is
    /// silently returned, and the failure surfaces to the caller.
    func providerToken(keyId: String, teamId: String, keyPath: String) throws -> String {
        let current = Date()
        let storeURL = URL(fileURLWithPath: keyPath).deletingLastPathComponent()
            .appendingPathComponent("apns_provider_token.json")
        if cachedProviderToken == nil, !providerTokenRejected,
           let data = try? Data(contentsOf: storeURL) {
            cachedProviderToken = try? JSONDecoder().decode(CachedProviderToken.self, from: data)
            providerTokenStoreURL = storeURL
        }
        if let cached = cachedProviderToken,
           cached.keyId == keyId,
           cached.teamId == teamId,
           current >= cached.issuedAt {
            let age = current.timeIntervalSince(cached.issuedAt)
            if age < Self.providerTokenTTL {
                return cached.jwt
            }
            // During a `TooManyProviderTokenUpdates` hold, keep serving
            // the cached token past its normal TTL instead of re-minting,
            // but never past the hard cap.
            if let hold = providerTokenHoldUntil, current < hold, age < Self.providerTokenHardCap {
                return cached.jwt
            }
        }
        let jwt = try Self.makeJWT(keyId: keyId, teamId: teamId, keyPath: keyPath, now: current)
        cachedProviderToken = CachedProviderToken(
            keyId: keyId,
            teamId: teamId,
            jwt: jwt,
            issuedAt: current
        )
        providerTokenHoldUntil = nil
        providerTokenRejected = false
        providerTokenStoreURL = storeURL
        if let data = try? JSONEncoder().encode(cachedProviderToken) {
            try CredentialFileLock.withLock(storeURL) {
                if !NativePrivateFile.write(data, to: storeURL) {
                    nativeLog("[APNS] could not persist provider token")
                }
            }
        }
        return jwt
    }
    /// Class-specific APNs rejection handling (C3). `TooManyProviderTokenUpdates`
    /// means the provider JWT was re-signed too often — the fix is to back off
    /// on minting and respect the cached token, so start a re-mint hold. Every
    /// other reason keeps its existing behavior. `ExpiredProviderToken` /
    /// `InvalidProviderToken` drop the token that was rejected (only that one:
    /// a late rejection must not discard a token minted since) so the next
    /// send mints.
    func noteRejection(reason: String?, jwt: String) throws {
        if reason == "ExpiredProviderToken" || reason == "InvalidProviderToken" {
            guard cachedProviderToken?.jwt == jwt else { return }
            cachedProviderToken = nil
            providerTokenRejected = true
            if let storeURL = providerTokenStoreURL {
                try CredentialFileLock.withLock(storeURL) {
                    let data: Data
                    do { data = try Data(contentsOf: storeURL) }
                    catch CocoaError.fileReadNoSuchFile { return }
                    let saved = try JSONDecoder().decode(CachedProviderToken.self, from: data)
                    guard saved.jwt == jwt else { return }
                    try FileManager.default.removeItem(at: storeURL)
                    try SwiftNativePersistenceCore.syncDirectory(storeURL.deletingLastPathComponent())
                }
            }
            return
        }
        guard reason == "TooManyProviderTokenUpdates" else { return }
        providerTokenHoldUntil = Date().addingTimeInterval(Self.providerTokenUpdateBackoff)
    }
    /// Parses the `reason` field from an APNs error response body,
    /// e.g. `{"reason":"BadDeviceToken"}`.
    static func rejectionReason(fromResponseBody data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = obj["reason"] as? String,
              !reason.isEmpty else { return nil }
        return reason
    }
    private static func makeJWT(keyId: String, teamId: String, keyPath: String, now: Date = Date()) throws -> String {
        let header = try base64URLJSON([
            "alg": "ES256",
            "kid": keyId,
        ])
        let claims = try base64URLJSON([
            "iss": teamId,
            "iat": Int(now.timeIntervalSince1970),
        ])
        let signingInput = "\(header).\(claims)"
        let pem = try String(contentsOf: URL(fileURLWithPath: keyPath), encoding: .utf8)
        let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
        return "\(signingInput).\(base64URL(signature))"
    }
    private static func base64URLJSON(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return base64URL(data)
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
