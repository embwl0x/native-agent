import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `APNSNotificationReadiness.swift` | SwiftNativeAPNSSender canonical registration reads, target/configuration validation and checked readiness |
extension SwiftNativeAPNSSender {
    func workActivityConfiguration(dataRoot: URL) -> (configured: Bool, usable: Bool, error: String?) {
        guard FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent("config/apns.json").path) else {
            return (false, false, nil)
        }
        do { _ = try APNSConfig.load(from: dataRoot); return (true, true, nil) }
        catch {
            let failure = error as NSError
            let missingKey = failure.domain == "NativeAgentAPNS" && [-2, -3, -4].contains(failure.code)
            return (!missingKey, false, error.localizedDescription)
        }
    }
    public func deliverableTargetCount(dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> Int {
        guard let config = try? APNSConfig.load(from: dataRoot) else { return 0 }
        return try await loadTokens(dataRoot: dataRoot, config: config).compactMap { config.target(for: $0) }.count
    }
    /// Pairing, current delivery targets and the newest outcome are one presentation read.
    /// `strict` (Doctor's reading) treats a malformed token record as a fault; pages and the sender keep tolerating it.
    public func notificationReadiness(dataRoot: URL, strict: Bool = false) async throws -> (supported: Bool, status: String, detail: String, paired: Int) {
        let paired: Int
        do { paired = try PairedPhoneAuthority.pairedCountChecked(at: dataRoot.appendingPathComponent("paired_phones.json")) }
        catch { throw Self.notificationReadFailure(error, path: dataRoot.appendingPathComponent("paired_phones.json")) }
        guard paired > 0 else { return (false, "not_paired", "No phone is paired.", paired) }
        // No config file means direct push was never set up here, not a read failure.
        guard FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent("config/apns.json").path) else {
            return (false, "not_configured", "Direct push notifications are not set up on this Mac.", paired)
        }
        let config: APNSConfig
        do { config = try APNSConfig.load(from: dataRoot) }
        catch { throw Self.notificationReadFailure(error, path: dataRoot.appendingPathComponent("config/apns.json")) }
        let targets = try await loadTokens(dataRoot: dataRoot, config: config, forDoctor: strict)
            .compactMap { config.target(for: $0) }
        guard !targets.isEmpty else { return (false, "needs_token", "A phone is paired, but no push token can receive notifications.", paired) }
        let path = dataRoot.appendingPathComponent("mobile_push/apns_outcomes.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else {
            return (false, "not_checked", "A phone is paired and push is configured; no delivery has been checked.", paired)
        }
        var unchecked = targets
        let lines: String
        do { lines = try String(contentsOf: path, encoding: .utf8) }
        catch { throw Self.notificationReadFailure(error, path: path) }
        for line in lines.split(whereSeparator: \.isNewline).reversed() {
            let value: JSONValue
            do { value = try JSONValue.parse(Data(line.utf8)) }
            catch { throw Self.notificationReadFailure(error, path: path) }
            guard case .object(let outcome) = value,
                  case .array(let receipts)? = outcome["receipts"] else {
                throw Self.notificationReadFailure(CocoaError(.propertyListReadCorrupt), path: path)
            }
            for receipt in receipts {
                guard case .object(let row) = receipt,
                      let device = Self.string(row["deviceId"]), let suffix = Self.string(row["tokenSuffix"]),
                      let index = unchecked.firstIndex(where: {
                          $0.token.deviceId == device && String($0.token.token.suffix(8)) == suffix
                              && row["tokenSource"] == .string($0.token.source)
                              && row["environment"] == .string($0.environment) && row["topic"] == .string($0.topic)
                      }) else { continue }
                // Only the newest receipt for each current sender target counts.
                unchecked.remove(at: index)
                if row["status"] == .string("ok"), case .int(let status)? = row["httpStatus"], (200..<300).contains(status) {
                    return (true, "ready", "The latest push was accepted for a current phone token.", paired)
                }
            }
            if unchecked.isEmpty { break }
            if case .array(let errors)? = outcome["errors"], !errors.isEmpty {
                return (false, "not_confirmed", "The latest push was not confirmed for a current phone token.", paired)
            }
        }
        return unchecked.count == targets.count
            ? (false, "not_checked", "A phone is paired and push is configured; no delivery has been checked.", paired)
            : (false, "not_confirmed", "The latest push was not confirmed for a current phone token.", paired)
    }
    private static func notificationReadFailure(_ error: Error, path: URL) -> NSError {
        NSError(domain: "NativeAgentAPNS", code: -5, userInfo: [
            NSFilePathErrorKey: path.path,
            NSLocalizedDescriptionKey: "Phone notification evidence could not be read from \(path.path)",
            NSUnderlyingErrorKey: error,
        ])
    }
    internal func loadTokens(dataRoot: URL, config: APNSConfig, forDoctor: Bool = false) async throws -> [APNSToken] {
        // An empty canonical registration set stays empty.
        return filteredTokens(try await loadSwiftTokens(dataRoot: dataRoot, forDoctor: forDoctor), config: config)
    }
    private func filteredTokens(_ tokens: [APNSToken], config: APNSConfig) -> [APNSToken] {
        var byToken: [String: APNSToken] = [:]
        for token in tokens {
            guard !token.token.isEmpty else { continue }
            if let configuredEnvironment = config.environment,
               let environment = token.environment,
               !environment.isEmpty,
               Self.normalizedEnvironment(environment) != Self.normalizedEnvironment(configuredEnvironment) {
                continue
            }
            if let configuredTopic = config.topic,
               let bundleId = token.bundleId,
               !bundleId.isEmpty,
               bundleId != configuredTopic {
                continue
            }
            byToken[token.token] = token
        }
        return Array(byToken.values).sorted { $0.deviceId < $1.deviceId }
    }
    private func loadSwiftTokens(dataRoot: URL, forDoctor: Bool = false) async throws -> [APNSToken] {
        let path = dataRoot.appendingPathComponent("notifications/push_tokens.json")
        let raw: JSONValue
        do { raw = try await SwiftNativePersistenceCore.readJSON(path, ifMissing: .object([:])) }
        catch {
            if forDoctor { throw Self.notificationReadFailure(error, path: path) }
            throw error
        }
        guard case .object(let root) = raw else {
            if forDoctor { throw Self.notificationReadFailure(CocoaError(.propertyListReadCorrupt), path: path) }
            return []
        }
        if forDoctor, !root.values.allSatisfy(Self.validTokenRecord) {
            throw Self.notificationReadFailure(CocoaError(.propertyListReadCorrupt), path: path)
        }
        return root.compactMap { key, value in
            guard case .object(let obj) = value else { return nil }
            guard let token = Self.string(obj["token"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { return nil }
            return APNSToken(
                deviceId: Self.string(obj["deviceId"]) ?? Self.string(obj["device_id"]) ?? key,
                pairedDeviceID: Self.string(obj["pairedDeviceID"]),
                token: token,
                environment: Self.string(obj["environment"]) ?? Self.string(obj["sandbox"]),
                bundleId: Self.string(obj["bundleId"]) ?? Self.string(obj["bundle_id"]),
                source: "swift_push_tokens",
                updatedAt: Self.string(obj["lastSeen"]) ?? Self.string(obj["updatedAt"])
            )
        }
    }
    /// Revoked records may retain metadata without a token; malformed records
    /// must not look like an empty receiving set in Doctor's reading.
    private static func validTokenRecord(_ value: JSONValue) -> Bool {
        guard case .object(let row) = value else { return false }
        guard let token = row["token"] else { return true }
        if case .string = token { return true }
        return false
    }
    internal static func normalizedEnvironment(_ value: String) -> String {
        let clean = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if clean == "prod" || clean == "production" { return "production" }
        return "development"
    }
    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string) = value else { return nil }
        return string
    }
    struct APNSConfig: Sendable {
        let teamId: String
        let keyId: String
        var keyPath: String
        let topic: String?
        let environment: String?

        internal func target(for token: APNSToken) -> APNSTarget? {
            guard !token.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            guard let resolvedTopic = Self.resolvedString(configured: topic, tokenValue: token.bundleId) else {
                return nil
            }
            let resolvedEnvironment = SwiftNativeAPNSSender.normalizedEnvironment(
                Self.resolvedString(configured: environment, tokenValue: token.environment) ?? "production"
            )
            return APNSTarget(
                token: token,
                topic: resolvedTopic,
                environment: resolvedEnvironment
            )
        }
        static func load(from dataRoot: URL) throws -> APNSConfig {
            let path = dataRoot
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("apns.json")
            guard let data = try? Data(contentsOf: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "NativeAgentAPNS", code: -2, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Direct APNS is not configured for this installation. "
                        + "Use the paired iCloud companion path or configure local APNS provider credentials."
                ])
            }
            var config = APNSConfig(
                teamId: Self.requiredString(obj, "team_id"),
                keyId: Self.requiredString(obj, "key_id"),
                keyPath: Self.requiredString(obj, "key_path"),
                topic: Self.optionalConfigString(obj, "topic"),
                environment: Self.optionalConfigString(obj, "environment")
            )
            try config.validateCredentialConfig()
            // Resolve the configured key path or a matching .p8 file beside the config.
            let configDir = path.deletingLastPathComponent()
            let configuredName = URL(fileURLWithPath: config.keyPath).lastPathComponent
            let candidates = [config.keyPath]
                + (["AuthKey_\(config.keyId).p8"] + (configuredName.contains(config.keyId) ? [configuredName] : []))
                    .map { configDir.appendingPathComponent($0).path }
            guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                throw NSError(domain: "NativeAgentAPNS", code: -3, userInfo: [
                    NSLocalizedDescriptionKey:
                        "The APNS key file is missing. Looked for \(config.keyPath) and for "
                        + "AuthKey_\(config.keyId).p8 in \(configDir.path). Put the .p8 key in one of those places."
                ])
            }
            config.keyPath = found
            return config
        }
        private static func requiredString(_ obj: [String: Any], _ key: String) -> String {
            (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        private static func optionalConfigString(_ obj: [String: Any], _ key: String) -> String? {
            guard let value = obj[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed.lowercased() == "auto" ? nil : trimmed
        }
        private static func resolvedString(configured: String?, tokenValue: String?) -> String? {
            if let configured {
                let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            guard let tokenValue else { return nil }
            let trimmed = tokenValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        private func validateCredentialConfig() throws {
            let missing = [
                ("team_id", teamId),
                ("key_id", keyId),
                ("key_path", keyPath),
            ].compactMap { key, value in
                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? key : nil
            }
            guard missing.isEmpty else {
                throw NSError(domain: "NativeAgentAPNS", code: -4, userInfo: [
                    NSLocalizedDescriptionKey: "APNS config missing required credential field(s): \(missing.joined(separator: ", "))."
                ])
            }
        }
    }
    internal struct APNSTarget: Sendable {
        let token: APNSToken
        let topic: String
        let environment: String

        var host: String {
            SwiftNativeAPNSSender.normalizedEnvironment(environment) == "production"
                ? "api.push.apple.com"
                : "api.sandbox.push.apple.com"
        }
    }
    internal struct APNSToken: Sendable {
        let deviceId: String
        let pairedDeviceID: String?
        let token: String
        let environment: String?
        let bundleId: String?
        let source: String
        let updatedAt: String?
    }
}
