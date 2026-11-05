import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `SwiftNativeAPNSSender.swift` | One APNs sender actor owns bounded transport, credential state, JWT reuse/expiry, rejection holds and signing |
public actor SwiftNativeAPNSSender {
    /// A transport limit, never a race that cancels a write to stop observing it.
    let deliverySession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    /// Reuse provider JWTs for 50 minutes to avoid `TooManyProviderTokenUpdates` and Apple's 60-minute expiry.
    static let providerTokenTTL: TimeInterval = 50 * 60

    private struct CachedProviderToken: Codable {
        let keyId: String
        let teamId: String
        let jwt: String
        let issuedAt: Date
    }
    /// Actor isolation prevents concurrent sends from minting twice for the same key/team.
    private var cachedProviderToken: CachedProviderToken?

    /// Rejected JWTs bypass the reusable 0600 cache beside the .p8 key so the next send mints a fresh token.
    private var providerTokenRejected = false
    private var providerTokenStoreURL: URL?

    /// Apple's TooManyProviderTokenUpdates remedy is to hold minting and reuse the current token; re-signing worsens rejection.
    static let providerTokenUpdateBackoff: TimeInterval = 10 * 60

    /// Hold reuse must still leave enough margin to avoid Apple's 60-minute expiry in flight.
    static let providerTokenHardCap: TimeInterval = 58 * 60

    private var providerTokenHoldUntil: Date?

    public init() {}

    /// Mint only for first use, expiry or credential change; signing failure must surface without returning stale authority.
    func providerToken(keyId: String, teamId: String, keyPath: String) throws -> String {
        let current = Date()
        let storeURL = URL(fileURLWithPath: keyPath).deletingLastPathComponent()
            .appendingPathComponent("apns_provider_token.json")
        if cachedProviderToken == nil, !providerTokenRejected {
            do {
                let data = try Data(contentsOf: storeURL)
                cachedProviderToken = try JSONDecoder().decode(CachedProviderToken.self, from: data)
                providerTokenStoreURL = storeURL
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // Only a missing cache permits first mint; preserve all other read and decode failures.
            }
        }
        if let cached = cachedProviderToken,
           cached.keyId == keyId,
           cached.teamId == teamId,
           current >= cached.issuedAt {
            let age = current.timeIntervalSince(cached.issuedAt)
            if age < Self.providerTokenTTL {
                return cached.jwt
            }
            // A rejection hold extends normal reuse, never the hard expiry cap.
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
    /// TooManyProviderTokenUpdates holds minting; expired/invalid rejections evict only the rejected token so late replies cannot discard a newer one.
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
