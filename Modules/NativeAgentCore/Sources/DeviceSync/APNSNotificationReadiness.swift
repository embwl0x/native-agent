import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `APNSNotificationReadiness.swift` | Checked paired-phone notification readiness, canonical optional APNS registration reads and provider configuration validation |
extension SwiftNativeAPNSSender {
    func workActivityConfiguration(dataRoot: URL) -> (configured: Bool, usable: Bool, error: String?) {
        do {
            guard try APNSConfig.loadIfPresent(from: dataRoot) != nil else { return (false, false, nil) }
            return (true, true, nil)
        }
        catch {
            return (true, false, error.localizedDescription)
        }
    }
    /// Ordinary notifications target paired phones through iCloud, independent
    /// of optional provider credentials, tokens or background-wake outcomes.
    public func deliverableTargetCount(dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> Int {
        let path = dataRoot.appendingPathComponent("paired_phones.json")
        do { return try PairedPhoneAuthority.pairedCountChecked(at: path) }
        catch { throw Self.notificationReadFailure(error, path: path) }
    }
    /// Readiness names the supported route, not proof of presentation. Delivery
    /// remains unconfirmed until the phone's signed receipt; it never proves display.
    public func notificationReadiness(dataRoot: URL) async throws -> (supported: Bool, status: String, detail: String, paired: Int) {
        let paired = try await deliverableTargetCount(dataRoot: dataRoot)
        guard paired > 0 else { return (false, "not_paired", "No phone is paired.", paired) }
        return (true, "ready", "A phone is paired for notifications through iCloud. iPhone notification settings and Focus govern alerts; delivery and display are not yet verified.", paired)
    }
    private static func notificationReadFailure(_ error: Error, path: URL) -> NSError {
        NSError(domain: "NativeAgentAPNS", code: -5, userInfo: [
            NSFilePathErrorKey: path.path,
            NSLocalizedDescriptionKey: "Phone notification evidence could not be read from \(path.path)",
            NSUnderlyingErrorKey: error,
        ])
    }
    internal func loadTokens(dataRoot: URL, config: APNSConfig) async throws -> (tokens: [APNSToken], errors: [String]) {
        // An empty canonical registration set stays empty.
        let read = try await loadSwiftTokens(dataRoot: dataRoot)
        return (filteredTokens(read.tokens, config: config), read.errors)
    }
    private func filteredTokens(_ tokens: [APNSToken], config: APNSConfig) -> [APNSToken] {
        var byToken: [String: APNSToken] = [:]
        for token in tokens {
            if let configuredEnvironment = config.environment, token.environment != configuredEnvironment {
                continue
            }
            if let configuredTopic = config.topic,
               token.bundleId != configuredTopic {
                continue
            }
            byToken[token.token] = token
        }
        return Array(byToken.values).sorted { $0.deviceId < $1.deviceId }
    }
    private func loadSwiftTokens(dataRoot: URL) async throws -> (tokens: [APNSToken], errors: [String]) {
        let path = dataRoot.appendingPathComponent("notifications/push_tokens.json")
        let raw: JSONValue
        do { raw = try await SwiftNativePersistenceCore.readJSON(path, ifMissing: .object([:])) }
        catch { throw Self.notificationReadFailure(error, path: path) }
        guard case .object(let root) = raw else {
            throw Self.notificationReadFailure(CocoaError(.propertyListReadCorrupt), path: path)
        }
        var tokens: [APNSToken] = []
        var errors: [String] = []
        for (key, value) in root.sorted(by: { $0.key < $1.key }) {
            do {
                guard case .object(let obj) = value else { throw CocoaError(.propertyListReadCorrupt) }
                // Revocation removes this device's alert token but retains its work activity.
                guard obj["token"] != nil else { continue }
                guard let token = Self.string(obj["token"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !token.isEmpty, let deviceID = Self.string(obj["deviceId"]), !deviceID.isEmpty,
                      deviceID == key, let environment = Self.string(obj["environment"]),
                      let bundleID = Self.string(obj["bundleId"]), !bundleID.isEmpty,
                      let lastSeen = Self.string(obj["lastSeen"]) else { throw CocoaError(.propertyListReadCorrupt) }
                tokens.append(APNSToken(
                    deviceId: deviceID, pairedDeviceID: Self.string(obj["pairedDeviceID"]),
                    token: token, environment: try Environment.checked(environment), bundleId: bundleID,
                    source: "swift_push_tokens", updatedAt: lastSeen))
            } catch {
                errors.append("APNS registration \(key) in \(path.path) is unavailable: \(error.localizedDescription)")
            }
        }
        return (tokens, errors)
    }
    enum Environment: String, Codable, Sendable {
        case production, development

        static func checked(_ value: String) throws -> Self {
            guard let environment = Self(rawValue: value) else {
                throw NSError(domain: "NativeAgentAPNS", code: -6, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid APNS environment '\(value)'; expected production or development."
                ])
            }
            return environment
        }

        var host: String {
            switch self {
            case .production: "api.push.apple.com"
            case .development: "api.sandbox.push.apple.com"
            }
        }
    }
    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string) = value else { return nil }
        return string
    }
    struct APNSConfig: Sendable {
        let teamId: String
        let keyId: String
        let keyPath: String
        let topic: String?
        let environment: Environment?

        internal func target(for token: APNSToken) -> APNSTarget {
            APNSTarget(
                token: token,
                topic: topic ?? token.bundleId,
                environment: environment ?? token.environment
            )
        }
        static func load(from dataRoot: URL) throws -> APNSConfig {
            guard let config = try loadIfPresent(from: dataRoot) else {
                throw NSError(domain: "NativeAgentAPNS", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "Direct APNS is not configured for this installation."
                ])
            }
            return config
        }

        /// Only an absent file means no optional provider was configured.
        /// Existing unreadable or malformed bytes never become a missing config.
        static func loadIfPresent(from dataRoot: URL) throws -> APNSConfig? {
            let path = dataRoot
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("apns.json")
            let data: Data
            do { data = try Data(contentsOf: path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "NativeAgentAPNS", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "The existing APNS configuration is not a JSON object."
                ])
            }
            let config = APNSConfig(
                teamId: try Self.requiredString(obj, "team_id"),
                keyId: try Self.requiredString(obj, "key_id"),
                keyPath: try Self.requiredString(obj, "key_path"),
                topic: try Self.optionalConfigString(obj, "topic"),
                environment: try Self.optionalConfigString(obj, "environment").map(Environment.checked)
            )
            // The configured path owns the credential. Never search for a
            // different key after that path becomes unavailable.
            // A checked read preserves missing/permission/encoding causes; an
            // existence probe cannot establish that this exact key is usable.
            _ = try P256.Signing.PrivateKey(pemRepresentation:
                String(contentsOf: URL(fileURLWithPath: config.keyPath), encoding: .utf8))
            return config
        }
        private static func requiredString(_ obj: [String: Any], _ key: String) throws -> String {
            guard let value = obj[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "NativeAgentAPNS", code: -4, userInfo: [
                    NSLocalizedDescriptionKey: "APNS config requires a nonempty string for \(key)."
                ])
            }
            return value
        }
        private static func optionalConfigString(_ obj: [String: Any], _ key: String) throws -> String? {
            guard let raw = obj[key] else { return nil }
            guard let value = raw as? String, !value.isEmpty else {
                throw NSError(domain: "NativeAgentAPNS", code: -4, userInfo: [
                    NSLocalizedDescriptionKey: "APNS config field \(key) must be a nonempty string when present."
                ])
            }
            return value
        }
    }
    internal struct APNSTarget: Sendable {
        let token: APNSToken
        let topic: String
        let environment: Environment

        var host: String {
            environment.host
        }
    }
    internal struct APNSToken: Sendable {
        let deviceId: String
        let pairedDeviceID: String?
        let token: String
        let environment: Environment
        let bundleId: String
        let source: String
        let updatedAt: String?
    }
}
