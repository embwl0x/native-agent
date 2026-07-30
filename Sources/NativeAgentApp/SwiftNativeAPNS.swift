import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

struct MobileNotificationDeliveryReceipt: Sendable {
    let bridgeMessageID: String?
    let bridgeError: String?
    let apnsReceipts: [SwiftNativeAPNSReceipt]
    let apnsErrors: [String]
    let eventID: String?
    let cloudKitVisualPushEligible: Bool

    init(
        bridgeMessageID: String?,
        bridgeError: String?,
        apnsReceipts: [SwiftNativeAPNSReceipt],
        apnsErrors: [String],
        eventID: String? = nil,
        cloudKitVisualPushEligible: Bool = false
    ) {
        self.bridgeMessageID = bridgeMessageID
        self.bridgeError = bridgeError
        self.apnsReceipts = apnsReceipts
        self.apnsErrors = apnsErrors
        self.eventID = eventID
        self.cloudKitVisualPushEligible = cloudKitVisualPushEligible
    }

    var apnsSent: Bool {
        apnsReceipts.contains { $0.isSuccess }
    }

    var apnsAccepted: Bool {
        apnsSent
    }

    var bridgeQueued: Bool {
        bridgeMessageID != nil
    }

    var status: String {
        apnsAccepted ? "accepted" : (bridgeQueued ? "queued" : "failed")
    }

    var route: String {
        if apnsSent && bridgeQueued { return "apns_and_icloud_bridge" }
        if apnsSent { return "apns" }
        if bridgeQueued && cloudKitVisualPushEligible {
            return "cloudkit_visual_notification"
        }
        return "mac_icloud_bridge_notification"
    }

    var delivery: String {
        if apnsAccepted && bridgeQueued { return "accepted_by_apns_and_queued_to_icloud_bridge" }
        if apnsAccepted { return "accepted_by_apns" }
        if bridgeQueued && cloudKitVisualPushEligible {
            return "queued_to_cloudkit_visual_notification"
        }
        return "queued_to_icloud_bridge"
    }

    func deliveryFields() -> [String: JSONValue] {
        var obj: [String: JSONValue] = [
            "status": .string(status),
            "delivery": .string(delivery),
            "route": .string(route),
            "bridgeQueued": .bool(bridgeQueued),
            "apnsSent": .bool(apnsSent),
            "apnsAccepted": .bool(apnsAccepted),
            "apnsSemantics": .string("APNS 2xx means Apple accepted the request, not that the device displayed it."),
            "providerAcceptanceOnly": .bool(apnsAccepted),
            "lockScreenDisplayVerified": .bool(false),
            "deliveryVerification": .string(
                apnsAccepted
                    ? "provider_accepted_device_display_unverified"
                    : "device_display_unverified"
            ),
            "requiresIOSAppActiveForBridge": .bool(bridgeQueued && !cloudKitVisualPushEligible),
            "cloudKitVisualPushEligible": .bool(cloudKitVisualPushEligible),
        ]
        if let bridgeMessageID {
            obj["bridgeMessageId"] = .string(bridgeMessageID)
        }
        if let eventID {
            obj["eventId"] = .string(eventID)
        }
        if let bridgeError {
            obj["bridgeError"] = .string(bridgeError)
        }
        if !apnsReceipts.isEmpty {
            obj["apnsReceipts"] = .array(apnsReceipts.map { $0.toJSON() })
            obj["apnsReceiptCount"] = .int(Int64(apnsReceipts.count))
        }
        if !apnsErrors.isEmpty {
            obj["apnsErrors"] = .array(apnsErrors.map { .string($0) })
        }
        return obj
    }
}

struct SwiftNativeAPNSReceipt: Sendable {
    let apnsId: String
    let createdAt: String
    let status: String
    let httpStatus: Int?
    let response: String
    let tokenSuffix: String
    let deviceId: String
    let tokenSource: String
    let tokenUpdatedAt: String?
    let tokenAgeSeconds: Int?
    let environment: String
    let topic: String
    let error: String?

    var isSuccess: Bool {
        guard status == "ok", let httpStatus else { return false }
        return (200..<300).contains(httpStatus)
    }

    func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "apnsId": .string(apnsId),
            "createdAt": .string(createdAt),
            "status": .string(status),
            "response": .string(response),
            "tokenSuffix": .string(tokenSuffix),
            "deviceId": .string(deviceId),
            "tokenSource": .string(tokenSource),
            "environment": .string(environment),
            "topic": .string(topic),
        ]
        if let tokenUpdatedAt {
            obj["tokenUpdatedAt"] = .string(tokenUpdatedAt)
        }
        if let tokenAgeSeconds {
            obj["tokenAgeSeconds"] = .int(Int64(tokenAgeSeconds))
        }
        if let httpStatus {
            obj["httpStatus"] = .int(Int64(httpStatus))
        }
        if let error {
            obj["error"] = .string(error)
        }
        return .object(obj)
    }
}

actor SwiftNativeAPNSSender {
    static let shared = SwiftNativeAPNSSender()

    private let persistence = SwiftNativePersistenceCore()

    /// Apple rate-limits provider-token *minting*: re-signing the ES256 JWT on
    /// every push trips `TooManyProviderTokenUpdates` (observed on a 4-push
    /// burst, 2026-07-17). The contract is to sign once and reuse the token for
    /// 20–60 minutes. We reuse for 50 min — safely inside that window, with
    /// margin so a token never crosses Apple's 60-min hard expiry mid-flight.
    static let providerTokenTTL: TimeInterval = 50 * 60

    private struct CachedProviderToken {
        let keyId: String
        let teamId: String
        let jwt: String
        let issuedAt: Date
    }

    /// Signed provider JWT, cached by (keyId, teamId). The actor's isolation
    /// serializes access, so concurrent sends can never double-mint.
    private var cachedProviderToken: CachedProviderToken?

    /// Injected clock — real path uses `Date()`; tests drive expiry directly.
    private let now: () -> Date

    /// Injected signer — real path signs the ES256 JWT off disk; tests count
    /// mints without a live key. Throwing here fails the send loud (unchanged).
    private let sign: (_ keyId: String, _ teamId: String, _ keyPath: String, _ iat: Date) throws -> String

    init() {
        self.now = { Date() }
        self.sign = { keyId, teamId, keyPath, iat in
            try Self.makeJWT(keyId: keyId, teamId: teamId, keyPath: keyPath, now: iat)
        }
    }

    /// Test seam: inject a controllable clock and a mint-counting signer.
    init(
        now: @escaping () -> Date,
        sign: @escaping (_ keyId: String, _ teamId: String, _ keyPath: String, _ iat: Date) throws -> String
    ) {
        self.now = now
        self.sign = sign
    }

    /// Returns a signed provider token for the given credentials, minting only
    /// on first use, expiry, or a credential (keyId/teamId) change. A signing
    /// error propagates and leaves any prior cache untouched — no stale token is
    /// silently returned, and the failure surfaces to the caller.
    func providerToken(keyId: String, teamId: String, keyPath: String) throws -> String {
        let current = now()
        if let cached = cachedProviderToken,
           cached.keyId == keyId,
           cached.teamId == teamId,
           current >= cached.issuedAt,
           current.timeIntervalSince(cached.issuedAt) < Self.providerTokenTTL {
            return cached.jwt
        }
        let jwt = try sign(keyId, teamId, keyPath, current)
        cachedProviderToken = CachedProviderToken(
            keyId: keyId,
            teamId: teamId,
            jwt: jwt,
            issuedAt: current
        )
        return jwt
    }

    func sendNotification(
        title: String,
        body: String,
        userInfo: [String: String],
        urgency: String? = nil,
        dataRoot: URL = NativeAgentPaths.dataRoot
    ) async -> (receipts: [SwiftNativeAPNSReceipt], errors: [String]) {
        do {
            let config = try APNSConfig.load(from: dataRoot)
            let tokens = await loadTokens(dataRoot: dataRoot, config: config)
            let targets = tokens.compactMap { config.target(for: $0) }
            guard !targets.isEmpty else {
                return ([], ["No APNS device tokens are registered with enough topic/environment metadata."])
            }
            let jwt = try providerToken(keyId: config.keyId, teamId: config.teamId, keyPath: config.keyPath)
            var receipts: [SwiftNativeAPNSReceipt] = []
            for target in targets {
                let receipt = await sendOne(
                    target: target,
                    config: config,
                    jwt: jwt,
                    title: title,
                    body: body,
                    userInfo: userInfo,
                    urgency: urgency,
                    dataRoot: dataRoot
                )
                receipts.append(receipt)
            }
            return (receipts, receipts.compactMap(\.error))
        } catch {
            return ([], [error.localizedDescription])
        }
    }

    private func sendOne(
        target: APNSTarget,
        config: APNSConfig,
        jwt: String,
        title: String,
        body: String,
        userInfo: [String: String],
        urgency: String?,
        dataRoot: URL
    ) async -> SwiftNativeAPNSReceipt {
        let token = target.token
        let apnsId = UUID().uuidString
        let now = Date()
        let createdAt = ISO8601DateFormatter().string(from: now)
        let tokenAgeSeconds = Self.tokenAgeSeconds(token.updatedAt, now: now)
        var receipt = SwiftNativeAPNSReceipt(
            apnsId: apnsId,
            createdAt: createdAt,
            status: "failed",
            httpStatus: nil,
            response: "",
            tokenSuffix: String(token.token.suffix(8)),
            deviceId: token.deviceId,
            tokenSource: token.source,
            tokenUpdatedAt: token.updatedAt,
            tokenAgeSeconds: tokenAgeSeconds,
            environment: target.environment,
            topic: target.topic,
            error: nil
        )

        do {
            let endpoint = "https://\(target.host)/3/device/\(token.token)"
            guard let url = URL(string: endpoint) else {
                throw NSError(domain: "NativeAgentAPNS", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid APNS endpoint."
                ])
            }
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.httpMethod = "POST"
            request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
            request.setValue(target.topic, forHTTPHeaderField: "apns-topic")
            request.setValue("alert", forHTTPHeaderField: "apns-push-type")
            request.setValue("10", forHTTPHeaderField: "apns-priority")
            request.setValue(apnsId, forHTTPHeaderField: "apns-id")
            if let eventID = userInfo["eventId"], NativeAgentDeviceEventIdentity.isCanonical(eventID) {
                request.setValue(eventID, forHTTPHeaderField: "apns-collapse-id")
            }
            request.httpBody = try Self.payload(title: title, body: body, userInfo: userInfo, urgency: urgency)

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            let responseText = String(data: data, encoding: .utf8) ?? ""
            let ok = status.map { (200..<300).contains($0) } ?? false
            receipt = SwiftNativeAPNSReceipt(
                apnsId: apnsId,
                createdAt: createdAt,
                status: ok ? "ok" : "failed",
                httpStatus: status,
                response: responseText,
                tokenSuffix: String(token.token.suffix(8)),
                deviceId: token.deviceId,
                tokenSource: token.source,
                tokenUpdatedAt: token.updatedAt,
                tokenAgeSeconds: tokenAgeSeconds,
                environment: target.environment,
                topic: target.topic,
                error: ok ? nil : (responseText.isEmpty ? "APNS returned HTTP \(status ?? 0)." : responseText)
            )
        } catch {
            receipt = SwiftNativeAPNSReceipt(
                apnsId: apnsId,
                createdAt: createdAt,
                status: "failed",
                httpStatus: nil,
                response: "",
                tokenSuffix: String(token.token.suffix(8)),
                deviceId: token.deviceId,
                tokenSource: token.source,
                tokenUpdatedAt: token.updatedAt,
                tokenAgeSeconds: tokenAgeSeconds,
                environment: target.environment,
                topic: target.topic,
                error: error.localizedDescription
            )
        }

        await appendReceipt(receipt, dataRoot: dataRoot)
        return receipt
    }

    private func appendReceipt(_ receipt: SwiftNativeAPNSReceipt, dataRoot: URL) async {
        let path = dataRoot
            .appendingPathComponent("mobile_push", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
        try? await persistence.withFileLock(path) {
            try await persistence.appendJSONL(receipt.toJSON(), to: path)
        }
    }

    private func loadTokens(dataRoot: URL, config: APNSConfig) async -> [APNSToken] {
        let swiftTokens = filteredTokens(await loadSwiftTokens(dataRoot: dataRoot), config: config)
        if !swiftTokens.isEmpty {
            return dedupedTokens(swiftTokens)
        }
        let recoveredTokens = filteredTokens(await loadICloudProcessedTokens(), config: config)
        if !recoveredTokens.isEmpty {
            return dedupedTokens(recoveredTokens)
        }
        return dedupedTokens(filteredTokens(await loadLegacyTokens(dataRoot: dataRoot), config: config))
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

    private func dedupedTokens(_ tokens: [APNSToken]) -> [APNSToken] {
        var byToken: [String: APNSToken] = [:]
        for token in tokens {
            byToken[token.token] = token
        }
        return Array(byToken.values).sorted { $0.deviceId < $1.deviceId }
    }

    private func loadLegacyTokens(dataRoot: URL) async -> [APNSToken] {
        let path = dataRoot
            .appendingPathComponent("mobile_push", isDirectory: true)
            .appendingPathComponent("tokens.json")
        let raw = await persistence.readJSON(path, defaultValue: .array([]))
        guard case .array(let rows) = raw else { return [] }
        return rows.compactMap { row in
            guard case .object(let obj) = row else { return nil }
            guard let token = Self.string(obj["token"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { return nil }
            return APNSToken(
                deviceId: Self.string(obj["deviceId"]) ?? Self.string(obj["device_id"]) ?? "ios",
                token: token,
                environment: Self.string(obj["environment"]) ?? Self.string(obj["sandbox"]),
                bundleId: Self.string(obj["bundleId"]) ?? Self.string(obj["bundle_id"]),
                source: "legacy_mobile_push_tokens",
                updatedAt: Self.string(obj["updatedAt"]) ?? Self.string(obj["lastSeen"])
            )
        }
    }

    private func loadSwiftTokens(dataRoot: URL) async -> [APNSToken] {
        let path = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("push_tokens.json")
        let raw = await persistence.readJSON(path, defaultValue: .object([:]))
        guard case .object(let root) = raw else { return [] }
        return root.compactMap { key, value in
            guard case .object(let obj) = value else { return nil }
            guard let token = Self.string(obj["token"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { return nil }
            return APNSToken(
                deviceId: Self.string(obj["deviceId"]) ?? Self.string(obj["device_id"]) ?? key,
                token: token,
                environment: Self.string(obj["environment"]) ?? Self.string(obj["sandbox"]),
                bundleId: Self.string(obj["bundleId"]) ?? Self.string(obj["bundle_id"]),
                source: "swift_push_tokens",
                updatedAt: Self.string(obj["lastSeen"]) ?? Self.string(obj["updatedAt"])
            )
        }
    }

    private func loadICloudProcessedTokens() async -> [APNSToken] {
        let fm = FileManager.default
        var byDeviceId: [String: APNSToken] = [:]
        for inboxURL in Self.iCloudInboxCandidateURLs() {
            guard let files = try? fm.contentsOfDirectory(
                at: inboxURL,
                includingPropertiesForKeys: nil
            ) else {
                continue
            }
            for file in files where file.lastPathComponent.hasPrefix("processed_")
                && file.lastPathComponent.hasSuffix(".json.done") {
                let raw = await persistence.readJSON(file, defaultValue: .object([:]))
                guard case .object(let obj) = raw,
                      Self.string(obj["action"]) == "registerPushToken",
                      case .object(let payload)? = obj["payload"] else {
                    continue
                }
                guard let token = Self.string(payload["token"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !token.isEmpty else {
                    continue
                }
                let deviceId = Self.string(payload["deviceId"])
                    ?? Self.string(payload["device_id"])
                    ?? "ios"
                let updatedAt = Self.string(obj["createdAt"])
                let recovered = APNSToken(
                    deviceId: deviceId,
                    token: token,
                    environment: Self.string(payload["environment"]) ?? Self.string(payload["sandbox"]),
                    bundleId: Self.string(payload["bundleId"]) ?? Self.string(payload["bundle_id"]),
                    source: "icloud_processed_register_push_token",
                    updatedAt: updatedAt
                )
                if let existing = byDeviceId[deviceId],
                   !Self.isNewerToken(recovered, than: existing) {
                    continue
                }
                byDeviceId[deviceId] = recovered
            }
        }
        return Array(byDeviceId.values).sorted { $0.deviceId < $1.deviceId }
    }

    private static func iCloudInboxCandidateURLs() -> [URL] {
        // C10 (tightness-sweep 2026-07-17): resolve the container via
        // iCloudBridge's single owner (the `url(forUbiquityContainerIdentifier:)`
        // API) first, and fall back to the deterministic hand-built path — the
        // same fallback semantics this code had before (it used ONLY the
        // hand-built path). Both are safe to call here: this is an off-main
        // async token-load path, and the API resolver is `nonisolated`.
        // Runs oldest-behavior-preserving: the hand-built path is always
        // included so a signed-out/unmounted container still resolves.
        var candidates: [URL] = []
        var seenPaths: Set<String> = []
        func add(_ documentsURL: URL) {
            let inbox = documentsURL.appendingPathComponent("inbox", isDirectory: true)
            if seenPaths.insert(inbox.standardizedFileURL.path).inserted {
                candidates.append(inbox)
            }
        }
        if let apiDocuments = iCloudBridge.ubiquityDocumentsURL() {
            add(apiDocuments)
        }
        add(iCloudBridge.hardcodedDocumentsURL())
        return candidates
    }

    private static func payload(
        title: String,
        body: String,
        userInfo: [String: String],
        urgency: String?
    ) throws -> Data {
        var aps: [String: Any] = [
            "alert": [
                "title": title,
                "body": body,
            ],
            "sound": "default",
            "content-available": 1,
        ]
        if urgency?.lowercased() == "urgent" {
            aps["interruption-level"] = "time-sensitive"
        }

        var payload: [String: Any] = ["aps": aps, "nativeagent": userInfo]
        for (key, value) in userInfo {
            payload[key] = value
        }
        if payload["screen"] == nil {
            payload["screen"] = "activity"
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [])
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

    private static func normalizedEnvironment(_ value: String) -> String {
        let clean = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if clean == "prod" || clean == "production" { return "production" }
        return "development"
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string) = value else { return nil }
        return string
    }

    private static func tokenAgeSeconds(_ updatedAt: String?, now: Date) -> Int? {
        guard let updatedAt,
              let date = ISO8601DateFormatter().date(from: updatedAt) else {
            return nil
        }
        return max(0, Int(now.timeIntervalSince(date)))
    }

    private static func isNewerToken(_ lhs: APNSToken, than rhs: APNSToken) -> Bool {
        guard let lhsUpdatedAt = lhs.updatedAt,
              let lhsDate = ISO8601DateFormatter().date(from: lhsUpdatedAt) else {
            return false
        }
        guard let rhsUpdatedAt = rhs.updatedAt,
              let rhsDate = ISO8601DateFormatter().date(from: rhsUpdatedAt) else {
            return true
        }
        return lhsDate > rhsDate
    }

    private struct APNSConfig: Sendable {
        let teamId: String
        let keyId: String
        let keyPath: String
        let topic: String?
        let environment: String?

        func target(for token: APNSToken) -> APNSTarget? {
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
            let config = APNSConfig(
                teamId: Self.requiredString(obj, "team_id"),
                keyId: Self.requiredString(obj, "key_id"),
                keyPath: Self.requiredString(obj, "key_path"),
                topic: Self.optionalConfigString(obj, "topic"),
                environment: Self.optionalConfigString(obj, "environment")
            )
            try config.validateCredentialConfig()
            guard FileManager.default.fileExists(atPath: config.keyPath) else {
                throw NSError(domain: "NativeAgentAPNS", code: -3, userInfo: [
                    NSLocalizedDescriptionKey:
                        "The configured local APNS provider key is unavailable. "
                        + "Review the private APNS setup without placing credentials in a public build."
                ])
            }
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

    private struct APNSTarget: Sendable {
        let token: APNSToken
        let topic: String
        let environment: String

        var host: String {
            SwiftNativeAPNSSender.normalizedEnvironment(environment) == "production"
                ? "api.push.apple.com"
                : "api.sandbox.push.apple.com"
        }
    }

    private struct APNSToken: Sendable {
        let deviceId: String
        let token: String
        let environment: String?
        let bundleId: String?
        let source: String
        let updatedAt: String?
    }
}
