import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

struct WorkActivityPushRegistration: Codable, Equatable, Sendable {
    enum StartOutcome: String, Codable, Sendable {
        case unknown, accepted, observed, notObserved
    }
    struct StartReservation: Codable, Equatable, Sendable {
        var retainedAt: Date
        var expiresAt: Date
    }
    var pairing: String
    var environment: String
    var bundleID: String
    var enabled = false
    var startToken: String?
    var activityTokens: [String: String] = [:]
    var lastContents: [String: MobileWorkActivity.ContentState] = [:]
    var startedIDs: Set<String> = []
    // Optional so registrations saved before start reservations remain readable.
    var startOutcomes: [String: StartOutcome]?
    var startReservations: [String: StartReservation]?

    mutating func retireInactiveStarts(activeIDs: Set<String>, now: Date) {
        if startReservations == nil { startReservations = [:] }
        // Adopt legacy reservations into retention once; their start time is unknown.
        for id in startedIDs where startReservations?[id] == nil {
            startReservations?[id] = StartReservation(retainedAt: now,
                                                     expiresAt: lastContents[id]?.updatedAt.addingTimeInterval(5 * 60) ?? now)
        }
        let retired = (startReservations ?? [:]).filter {
            activityTokens[$0.key] == nil && !activeIDs.contains($0.key)
                && $0.value.retainedAt < now.addingTimeInterval(-86400) && $0.value.expiresAt < now
        }.map(\.key)
        for id in retired {
            lastContents.removeValue(forKey: id)
            startedIDs.remove(id)
            startOutcomes?.removeValue(forKey: id)
            startReservations?.removeValue(forKey: id)
        }
    }

    static func fingerprint(_ pairing: String) -> String {
        SHA256.hash(data: Data(pairing.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func read(_ value: JSONValue?) throws -> Self? {
        guard let value else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(value.serialize(pretty: false).utf8))
    }
}

public struct MobileNotificationDeliveryReceipt: Sendable {
    public let bridgeMessageID: String?
    public let bridgeError: String?
    public let apnsReceipts: [SwiftNativeAPNSReceipt]
    public let apnsErrors: [String]
    public let eventID: String?
    public let cloudKitVisualPushEligible: Bool

    public init(
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

    public var apnsSent: Bool {
        apnsReceipts.contains { $0.isSuccess }
    }

    public var apnsAccepted: Bool {
        apnsSent
    }

    public var bridgeQueued: Bool {
        bridgeMessageID != nil
    }

    public var status: String {
        apnsAccepted ? "accepted" : (bridgeQueued ? "queued" : "failed")
    }

    public var route: String {
        if apnsSent && bridgeQueued { return "apns_and_icloud_bridge" }
        if apnsSent { return "apns" }
        if bridgeQueued && cloudKitVisualPushEligible {
            return "cloudkit_visual_notification"
        }
        return "mac_icloud_bridge_notification"
    }

    public var delivery: String {
        if apnsAccepted && bridgeQueued { return "accepted_by_apns_and_queued_to_icloud_bridge" }
        if apnsAccepted { return "accepted_by_apns" }
        if bridgeQueued && cloudKitVisualPushEligible {
            return "queued_to_cloudkit_visual_notification"
        }
        return "queued_to_icloud_bridge"
    }

    public func deliveryFields() -> [String: JSONValue] {
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

public struct SwiftNativeAPNSReceipt: Sendable {
    public let apnsId: String
    public let createdAt: String
    public let status: String
    public let httpStatus: Int?
    public let response: String
    public let tokenSuffix: String
    public let deviceId: String
    public let tokenSource: String
    public let tokenUpdatedAt: String?
    public let tokenAgeSeconds: Int?
    public let environment: String
    public let topic: String
    public let error: String?

    public var isSuccess: Bool {
        guard status == "ok", let httpStatus else { return false }
        return (200..<300).contains(httpStatus)
    }

    public func toJSON() -> JSONValue {
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

public actor SwiftNativeAPNSSender {

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

    /// C3: after Apple rejects a push with `TooManyProviderTokenUpdates`, hold
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

    /// Injected clock — real path uses `Date()`; tests drive expiry directly.
    private let now: () -> Date

    /// Injected signer — real path signs the ES256 JWT off disk; tests count
    /// mints without a live key. Throwing here fails the send loud (unchanged).
    private let sign: (_ keyId: String, _ teamId: String, _ keyPath: String, _ iat: Date) throws -> String

    public init() {
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
           current >= cached.issuedAt {
            let age = current.timeIntervalSince(cached.issuedAt)
            if age < Self.providerTokenTTL {
                return cached.jwt
            }
            // C3: during a `TooManyProviderTokenUpdates` hold, keep serving
            // the cached token past its normal TTL instead of re-minting,
            // but never past the hard cap.
            if let hold = providerTokenHoldUntil, current < hold, age < Self.providerTokenHardCap {
                return cached.jwt
            }
        }
        let jwt = try sign(keyId, teamId, keyPath, current)
        cachedProviderToken = CachedProviderToken(
            keyId: keyId,
            teamId: teamId,
            jwt: jwt,
            issuedAt: current
        )
        providerTokenHoldUntil = nil
        return jwt
    }

    /// Class-specific APNs rejection handling (C3). `TooManyProviderTokenUpdates`
    /// means the provider JWT was re-signed too often — the fix is to back off
    /// on minting and respect the cached token, so start a re-mint hold. Every
    /// other reason keeps its existing behavior.
    func noteRejection(reason: String?) {
        guard reason == "TooManyProviderTokenUpdates" else { return }
        providerTokenHoldUntil = now().addingTimeInterval(Self.providerTokenUpdateBackoff)
    }

    /// Parses the `reason` field from an APNs error response body,
    /// e.g. `{"reason":"BadDeviceToken"}`.
    static func rejectionReason(fromResponseBody data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = obj["reason"] as? String,
              !reason.isEmpty else { return nil }
        return reason
    }

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

    func sendWorkActivities(_ rows: [MobileWorkActivity], dataRoot: URL) async -> [String] {
        do {
            let config = try APNSConfig.load(from: dataRoot)
            guard let pairing = try PairingSecretManager.existingSecretBase64() else { return [] }
            let fingerprint = WorkActivityPushRegistration.fingerprint(pairing)
            let path = dataRoot.appendingPathComponent("notifications/push_tokens.json")
            let lock = dataRoot.appendingPathComponent("notifications/push-token-registration")
            let value = try await persistence.readJSON(path, ifMissing: .object([:]))
            guard case .object(let root) = value else { throw CocoaError(.propertyListReadCorrupt) }
            let jwt = try providerToken(keyId: config.keyId, teamId: config.teamId, keyPath: config.keyPath)
            var errors: [String] = []
            for (deviceID, value) in root.sorted(by: { $0.key < $1.key }) {
                guard case .object(let entry) = value,
                      let original = try WorkActivityPushRegistration.read(entry["workActivity"]),
                      original.pairing == fingerprint else { continue }
                let ids = Set(rows.map(\.id))
                let eligibleStartIDs = Set(rows.filter { !$0.content.state.isTerminal && $0.staleDate > Date() }.map(\.id))
                // Cleanup also runs with no current rows or with opt-in revoked.
                try await persistence.withFileLock(lock) {
                    let latest = try await self.persistence.readJSON(path, ifMissing: .object([:]))
                    guard case .object(var root) = latest, case .object(var entry)? = root[deviceID],
                          var registration = try WorkActivityPushRegistration.read(entry["workActivity"]),
                          registration.pairing == fingerprint else { return }
                    registration.retireInactiveStarts(activeIDs: eligibleStartIDs, now: Date())
                    entry["workActivity"] = try JSONValue.parse(JSONEncoder().encode(registration))
                    root[deviceID] = .object(entry)
                    try await self.persistence.writeJSON(.object(root), to: path)
                }
                guard original.enabled else { continue }
                let removed = original.activityTokens.keys.filter { !ids.contains($0) }.compactMap { id -> MobileWorkActivity? in
                    guard var content = original.lastContents[id] else { return nil }
                    content.state = .unknown
                    content.status = "Tracking ended — open the app"
                    content.updatedAt = Date()
                    return MobileWorkActivity(id: id, sessionID: nil, startedAt: content.updatedAt, content: content)
                }
                for row in rows + removed {
                    if Task.isCancelled { return errors }
                    let failure: String? = try await persistence.withFileLock(lock) {
                        let latest = try await self.persistence.readJSON(path, ifMissing: .object([:]))
                        guard case .object(var root) = latest, case .object(var entry)? = root[deviceID],
                              var registration = try WorkActivityPushRegistration.read(entry["workActivity"]),
                              registration.enabled, registration.pairing == fingerprint,
                              let currentPairing = try PairingSecretManager.existingSecretBase64(),
                              WorkActivityPushRegistration.fingerprint(currentPairing) == fingerprint else { return nil }
                        if registration.lastContents[row.id] == row.content { return nil }
                        if let previous = registration.lastContents[row.id], previous.updatedAt > row.content.updatedAt { return nil }
                        let token: String
                        let event: String
                        if let activityToken = registration.activityTokens[row.id] {
                            token = activityToken
                            event = row.content.state.isTerminal || !ids.contains(row.id) ? "end" : "update"
                        } else {
                            guard ids.contains(row.id), !row.content.state.isTerminal, row.staleDate > Date(),
                                  !registration.startedIDs.contains(row.id), let startToken = registration.startToken else { return nil }
                            token = startToken; event = "start"
                        }
                        if event == "start" {
                            // Reserve before the external effect. A lost response or failed
                            // final write leaves an unknown start that must not be replayed.
                            registration.startedIDs.insert(row.id)
                            if registration.startOutcomes == nil { registration.startOutcomes = [:] }
                            registration.startOutcomes?[row.id] = .unknown
                            if registration.startReservations == nil { registration.startReservations = [:] }
                            registration.startReservations?[row.id] = .init(retainedAt: Date(), expiresAt: row.staleDate)
                            entry["workActivity"] = try JSONValue.parse(JSONEncoder().encode(registration))
                            root[deviceID] = .object(entry)
                            try await self.persistence.writeJSON(.object(root), to: path)
                        }
                        let failure = try await self.sendWorkActivity(row, event: event, token: token, registration: registration, jwt: jwt)
                        if let failure {
                            if event == "start" {
                                // Only an explicit provider rejection permits another start.
                                registration.startedIDs.remove(row.id)
                                registration.startOutcomes?.removeValue(forKey: row.id)
                                registration.startReservations?.removeValue(forKey: row.id)
                                entry["workActivity"] = try JSONValue.parse(JSONEncoder().encode(registration))
                                root[deviceID] = .object(entry)
                                try await self.persistence.writeJSON(.object(root), to: path)
                            } else if failure.tokenIsInvalid {
                                registration.activityTokens.removeValue(forKey: row.id)
                                // Keep the start reservation: an invalid update
                                // token does not authorize a duplicate start.
                                entry["workActivity"] = try JSONValue.parse(JSONEncoder().encode(registration))
                                root[deviceID] = .object(entry)
                                try await self.persistence.writeJSON(.object(root), to: path)
                            }
                            return failure.message
                        }
                        registration.lastContents[row.id] = row.content
                        if event == "start" { registration.startOutcomes?[row.id] = .accepted }
                        if event == "end" { registration.activityTokens.removeValue(forKey: row.id) }
                        registration.retireInactiveStarts(activeIDs: eligibleStartIDs, now: Date())
                        entry["workActivity"] = try JSONValue.parse(JSONEncoder().encode(registration))
                        root[deviceID] = .object(entry)
                        try await self.persistence.writeJSON(.object(root), to: path)
                        return nil
                    }
                    if let failure { errors.append(failure) }
                }
            }
            return errors
        } catch { return [error.localizedDescription] }
    }

    private struct WorkActivityRejection: Sendable {
        let message: String
        let tokenIsInvalid: Bool
    }

    private func sendWorkActivity(
        _ row: MobileWorkActivity, event: String, token: String,
        registration: WorkActivityPushRegistration, jwt: String
    ) async throws -> WorkActivityRejection? {
        let content = try JSONValue.parse(JSONEncoder().encode(row.content))
        var aps: [String: JSONValue] = [
            "timestamp": .int(Int64(Date().timeIntervalSince1970)), "event": .string(event),
            "content-state": content, "stale-date": .int(Int64(row.staleDate.timeIntervalSince1970)),
        ]
        if event == "start" {
            aps["attributes-type"] = .string("PhoneTurnAttributes")
            aps["attributes"] = .object([
                "workID": .string(row.id), "sessionID": row.sessionID.map(JSONValue.string) ?? .null,
                "pairingFingerprint": .string(registration.pairing),
                "agentName": .string(NativeAgentNotificationDefaults.agentDisplayName()),
                "startedAt": .double(row.startedAt.timeIntervalSinceReferenceDate),
            ])
            aps["input-push-token"] = .int(1)
            aps["alert"] = .object(["title": .string(row.content.title), "body": .string(row.content.status)])
        } else if event == "end" {
            aps["dismissal-date"] = .int(Int64(Date().addingTimeInterval(30).timeIntervalSince1970))
        }
        let host = Self.normalizedEnvironment(registration.environment) == "production"
            ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(token)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(registration.bundleID + ".push-type.liveactivity", forHTTPHeaderField: "apns-topic")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        request.setValue(event == "start" ? "10" : "5", forHTTPHeaderField: "apns-priority")
        request.setValue(String(Int(row.staleDate.timeIntervalSince1970)), forHTTPHeaderField: "apns-expiration")
        request.httpBody = try JSONValue.object(["aps": .object(aps)]).serializedData(pretty: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let status = response.statusCode
        guard status == 200 else {
            let reason = Self.rejectionReason(fromResponseBody: data)
            noteRejection(reason: reason)
            return WorkActivityRejection(
                message: "\(event): \(reason ?? "HTTP \(status)")",
                tokenIsInvalid: status == 410 || ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"].contains(reason ?? "")
            )
        }
        return nil
    }

    public func sendNotification(
        title: String,
        body: String,
        userInfo: [String: String],
        urgency: String? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> (receipts: [SwiftNativeAPNSReceipt], errors: [String]) {
        do {
            let config = try APNSConfig.load(from: dataRoot)
            let tokens = try await loadTokens(dataRoot: dataRoot, config: config)
            let targets = tokens.compactMap { config.target(for: $0) }
            guard !targets.isEmpty else {
                return ([], ["No APNS device tokens are registered with enough topic/environment metadata."])
            }
            let jwt = try providerToken(keyId: config.keyId, teamId: config.teamId, keyPath: config.keyPath)
            let eventID = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo)
            var eventUserInfo = userInfo
            eventUserInfo["eventId"] = eventID
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            let pushUserInfo = eventUserInfo
            let receipts = await withTaskGroup(of: SwiftNativeAPNSReceipt?.self) { group in
                group.addTask {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    return nil
                }
                for target in targets {
                    group.addTask {
                        await self.sendOne(
                            target: target,
                            jwt: jwt,
                            title: title,
                            body: body,
                            userInfo: pushUserInfo,
                            eventID: eventID,
                            urgency: urgency,
                            deadline: deadline
                        )
                    }
                }
                var receipts: [SwiftNativeAPNSReceipt] = []
                for await receipt in group {
                    guard let receipt else { break }
                    receipts.append(receipt)
                    if receipts.count == targets.count { break }
                }
                group.cancelAll()
                return receipts
            }
            var errors = receipts.compactMap(\.error)
            if receipts.count < targets.count {
                errors.append("APNS fan-out deadline exceeded for \(targets.count - receipts.count) target(s).")
            }
            return (receipts, errors)
        } catch {
            return ([], [error.localizedDescription])
        }
    }

    /// How many devices `sendNotification` would push to right now: the same
    /// config and token filter, local files only, nothing sent.
    public func deliverableTargetCount(dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> Int {
        guard let config = try? APNSConfig.load(from: dataRoot) else { return 0 }
        return try await loadTokens(dataRoot: dataRoot, config: config).compactMap { config.target(for: $0) }.count
    }

    private func sendOne(
        target: APNSTarget,
        jwt: String,
        title: String,
        body: String,
        userInfo: [String: String],
        eventID: String,
        urgency: String?,
        deadline: ContinuousClock.Instant
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
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            let endpoint = "https://\(target.host)/3/device/\(token.token)"
            guard let url = URL(string: endpoint) else {
                throw NSError(domain: "NativeAgentAPNS", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid APNS endpoint."
                ])
            }
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
            request.setValue(target.topic, forHTTPHeaderField: "apns-topic")
            let resultWake = userInfo["source"] == "requested_result"
            request.setValue(resultWake ? "background" : "alert", forHTTPHeaderField: "apns-push-type")
            request.setValue(resultWake ? "5" : "10", forHTTPHeaderField: "apns-priority")
            request.setValue(apnsId, forHTTPHeaderField: "apns-id")
            // iOS uses this as the remote UNNotificationRequest identifier,
            // matching CloudKit and the local request for the same reply.
            request.setValue(eventID, forHTTPHeaderField: "apns-collapse-id")
            request.httpBody = try Self.payload(title: title, body: body, userInfo: userInfo, urgency: urgency)

            let (data, response) = try await URLSession.shared.data(for: request)
            // A late acceptance cannot suppress the phone's local alert.
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            let status = (response as? HTTPURLResponse)?.statusCode
            let responseText = String(data: data, encoding: .utf8) ?? ""
            let ok = status.map { (200..<300).contains($0) } ?? false
            let reason = ok ? nil : Self.rejectionReason(fromResponseBody: data)
            noteRejection(reason: reason)
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
                error: ok ? nil : (
                    reason.map { "APNS rejected: \($0) (HTTP \(status ?? 0))." }
                        ?? (responseText.isEmpty ? "APNS returned HTTP \(status ?? 0)." : responseText)
                )
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

        // Sweep item 21 (2026-09-01): the `mobile_push/receipts.jsonl` append
        // is gone. 1,550 rows / 430 KB of APNs delivery evidence that no
        // production code ever read back — the receipt is RETURNED to the
        // caller, which is where every live decision about a send is made.
        // Existing rows stay on disk; the runtime just stops adding to them.
        return receipt
    }

    private func loadTokens(dataRoot: URL, config: APNSConfig) async throws -> [APNSToken] {
        let swiftTokens = filteredTokens(try await loadSwiftTokens(dataRoot: dataRoot), config: config)
        if !swiftTokens.isEmpty {
            return dedupedTokens(swiftTokens)
        }
        return dedupedTokens(filteredTokens(try await loadLegacyTokens(dataRoot: dataRoot), config: config))
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

    private func loadLegacyTokens(dataRoot: URL) async throws -> [APNSToken] {
        let path = dataRoot
            .appendingPathComponent("mobile_push", isDirectory: true)
            .appendingPathComponent("tokens.json")
        let raw = try await persistence.readJSON(path, ifMissing: .array([]))
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

    private func loadSwiftTokens(dataRoot: URL) async throws -> [APNSToken] {
        let path = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("push_tokens.json")
        let raw = try await persistence.readJSON(path, ifMissing: .object([:]))
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
            "mutable-content": 1,
        ]
        // Requested results alert from their signed, idempotent iCloud record.
        // APNS only wakes that reader, so even a timeout-after-acceptance retry
        // cannot repeat an already displayed banner.
        if userInfo["source"] == "requested_result" {
            aps = ["content-available": 1]
        } else if urgency?.lowercased() == "urgent" {
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

    private struct APNSConfig: Sendable {
        let teamId: String
        let keyId: String
        var keyPath: String
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
            var config = APNSConfig(
                teamId: Self.requiredString(obj, "team_id"),
                keyId: Self.requiredString(obj, "key_id"),
                keyPath: Self.requiredString(obj, "key_path"),
                topic: Self.optionalConfigString(obj, "topic"),
                environment: Self.optionalConfigString(obj, "environment")
            )
            try config.validateCredentialConfig()
            // 2026-09-22: a stale key_path (moved data root, other Mac) left push
            // dead while the key sat in config/; look there by name too.
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
