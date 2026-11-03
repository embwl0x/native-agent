import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `APNSNotificationDelivery.swift` | SwiftNativeAPNSSender notification/work-activity delivery, transport-owned fan-out and checked capped unknown/final outcome receipts |
extension SwiftNativeAPNSSender {
    func sendWorkActivity(
        _ row: MobileWorkActivity, event: String, token: String,
        registration: WorkActivityPushRegistration, jwt: String
    ) async throws -> MacSyncMobileNotificationRelay.WorkActivityRejection? {
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
        let host = try Environment.checked(registration.environment).host
        guard let url = URL(string: "https://\(host)/3/device/\(token)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(registration.bundleID + ".push-type.liveactivity", forHTTPHeaderField: "apns-topic")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        request.setValue(event == "start" ? "10" : "5", forHTTPHeaderField: "apns-priority")
        request.setValue(String(Int(row.staleDate.timeIntervalSince1970)), forHTTPHeaderField: "apns-expiration")
        request.httpBody = try JSONValue.object(["aps": .object(aps)]).serializedData(pretty: false)
        let (data, response) = try await deliverySession.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let status = response.statusCode
        guard status == 200 else {
            let reason = Self.rejectionReason(fromResponseBody: data)
            try noteRejection(reason: reason, jwt: jwt)
            return MacSyncMobileNotificationRelay.WorkActivityRejection(
                message: "\(event): \(reason ?? "HTTP \(status)")",
                tokenIsInvalid: status == 410 || ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"].contains(reason ?? "")
            )
        }
        return nil
    }
    /// Optional sync acceleration. Neither event kind ever renders through APNS.
    public func sendNotificationWake(
        userInfo: [String: String],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> (receipts: [SwiftNativeAPNSReceipt], errors: [String]) {
        let eventID = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo)
        var targets: [APNSTarget] = []
        do {
            // Missing provider credentials are the normal public-install case.
            // An existing unreadable/invalid configuration still reports its error.
            guard let config = try APNSConfig.loadIfPresent(from: dataRoot) else { return ([], []) }
            let registrations = try await loadTokens(dataRoot: dataRoot, config: config)
            targets = registrations.tokens.map { config.target(for: $0) }
            guard !targets.isEmpty else {
                let errors = registrations.errors + ["No APNS device tokens are registered with enough topic/environment metadata."]
                do {
                    return ([], try await recordOutcome(eventID: eventID, targets: targets, receipts: [], errors: errors, dataRoot: dataRoot))
                } catch { return ([], errors + [error.localizedDescription]) }
            }
            let jwt = try providerToken(keyId: config.keyId, teamId: config.teamId, keyPath: config.keyPath)
            var eventUserInfo = userInfo
            eventUserInfo["eventId"] = eventID
            let pushUserInfo = eventUserInfo
            let admittedTargets = targets
            try Task.checkCancellation()
            // Once admitted, the effect and its receipt belong to this task.
            // Caller cancellation/deadline cannot cancel it; the wait joins the
            // bounded transport rather than imposing a second write deadline.
            return await Task.detached {
                await self.deliverWake(targets: admittedTargets, jwt: jwt,
                    userInfo: pushUserInfo, eventID: eventID, registrationErrors: registrations.errors, dataRoot: dataRoot)
            }.value
        } catch {
            var errors = [error.localizedDescription]
            do {
                errors = try await recordOutcome(eventID: eventID, targets: targets, receipts: [], errors: errors, dataRoot: dataRoot)
            } catch { errors.append(error.localizedDescription) }
            return ([], errors)
        }
    }

    private struct WakeAttempt: Sendable {
        let target: APNSTarget
        let apnsID = UUID().uuidString
        let startedAt = Date()

        func receipt(status: String, httpStatus: Int? = nil, response: String = "", error: String? = nil) -> SwiftNativeAPNSReceipt {
            let token = target.token
            return SwiftNativeAPNSReceipt(
                apnsId: apnsID, createdAt: ISO8601DateFormatter().string(from: startedAt),
                status: status, httpStatus: httpStatus, response: response,
                tokenSuffix: String(token.token.suffix(8)), deviceId: token.deviceId,
                pairedDeviceID: token.pairedDeviceID, tokenSource: token.source,
                tokenUpdatedAt: token.updatedAt, tokenAgeSeconds: SwiftNativeAPNSSender.tokenAgeSeconds(token.updatedAt, now: startedAt),
                environment: target.environment.rawValue, topic: target.topic, error: error)
        }
    }

    private func deliverWake(targets: [APNSTarget], jwt: String, userInfo: [String: String],
                             eventID: String, registrationErrors: [String], dataRoot: URL) async -> (receipts: [SwiftNativeAPNSReceipt], errors: [String]) {
        let attempts = targets.map { WakeAttempt(target: $0) }
        let pending = attempts.map { $0.receipt(status: "unknown") }
        do {
            // No external write without retained per-target uncertainty. A crash
            // or a failed final receipt leaves these same APNs IDs unsettled.
            try await recordOutcome(eventID: eventID, targets: targets, receipts: pending, errors: registrationErrors, dataRoot: dataRoot)
        } catch { return ([], registrationErrors + [error.localizedDescription]) }

        let receipts = await withTaskGroup(of: SwiftNativeAPNSReceipt.self) { group in
            for attempt in attempts {
                group.addTask {
                    await self.sendOne(attempt: attempt, jwt: jwt, userInfo: userInfo, eventID: eventID)
                }
            }
            var receipts: [SwiftNativeAPNSReceipt] = []
            for await receipt in group { receipts.append(receipt) }
            return receipts
        }
        var errors = registrationErrors + receipts.compactMap(\.error)
        do {
            errors = try await recordOutcome(eventID: eventID, targets: targets, receipts: receipts, errors: errors, dataRoot: dataRoot)
        } catch { errors.append(error.localizedDescription) }
        return (receipts, errors)
    }
    /// Record each fan-out outcome; prune only tokens Apple retires with HTTP 410.
    @discardableResult
    private func recordOutcome(
        eventID: String,
        targets: [APNSTarget],
        receipts: [SwiftNativeAPNSReceipt],
        errors: [String],
        dataRoot: URL
    ) async throws -> [String] {
        var errors = errors
        for receipt in receipts where receipt.httpStatus == 410 {
            // APNs stamps a 410 with when it last confirmed the token dead (ms).
            guard let body = try? JSONSerialization.jsonObject(with: Data(receipt.response.utf8)) as? [String: Any],
                  let millis = (body["timestamp"] as? NSNumber)?.doubleValue,
                  let target = targets.first(where: {
                      $0.token.deviceId == receipt.deviceId && $0.token.token.hasSuffix(receipt.tokenSuffix)
                  }) else { continue }
            do {
                try await MacSyncMobileNotificationRelay.prunePushToken(
                    target.token.token,
                    unregisteredAt: Date(timeIntervalSince1970: millis / 1000),
                    dataRoot: dataRoot
                )
            } catch {
                errors.append("Could not prune unregistered APNS token for \(receipt.deviceId): \(error.localizedDescription)")
            }
        }
        let row: JSONValue = .object([
            "at": .string(ISO8601DateFormatter().string(from: Date())),
            "eventId": .string(eventID),
            "targets": .int(Int64(targets.count)),
            "accepted": .int(Int64(receipts.filter(\.isSuccess).count)),
            "receipts": .array(receipts.map { $0.toJSON() }),
            "errors": .array(errors.map(JSONValue.string)),
        ])
        do {
            try await appendJSONLCapped(
                row,
                to: dataRoot.appendingPathComponent("mobile_push/apns_outcomes.jsonl"),
                maxLines: 500,
                logLabel: "SwiftNativeAPNS.outcome",
                durable: true
            )
        } catch {
            throw NSError(domain: "NativeAgentAPNS", code: -7, userInfo: [
                NSLocalizedDescriptionKey: "APNS outcome receipt remains unsettled for \(eventID): \(error.localizedDescription)",
                NSUnderlyingErrorKey: error,
            ])
        }
        return errors
    }
    /// One silent wake to one registered phone; acceptance is not display proof.
    private func sendOne(
        attempt: WakeAttempt,
        jwt: String,
        userInfo: [String: String],
        eventID: String
    ) async -> SwiftNativeAPNSReceipt {
        let target = attempt.target

        do {
            let endpoint = "https://\(target.host)/3/device/\(target.token.token)"
            guard let url = URL(string: endpoint) else {
                throw NSError(domain: "NativeAgentAPNS", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid APNS endpoint."
                ])
            }
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
            request.setValue(target.topic, forHTTPHeaderField: "apns-topic")
            request.setValue("background", forHTTPHeaderField: "apns-push-type")
            request.setValue("5", forHTTPHeaderField: "apns-priority")
            request.setValue(attempt.apnsID, forHTTPHeaderField: "apns-id")
            // Coalesce optional wakes for the same event, never an alert.
            request.setValue(eventID, forHTTPHeaderField: "apns-collapse-id")
            request.httpBody = try Self.payload(userInfo: userInfo)

            let (data, response) = try await deliverySession.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let status = response.statusCode
            let responseText = String(data: data, encoding: .utf8) ?? ""
            let ok = (200..<300).contains(status)
            let reason = ok ? nil : Self.rejectionReason(fromResponseBody: data)
            var errors: [String] = []
            if !ok { errors.append("APNS rejected: \(reason ?? responseText) (HTTP \(status)).") }
            do { try noteRejection(reason: reason, jwt: jwt) }
            catch { errors.append("Could not retain APNS credential rejection: \(error.localizedDescription)") }
            return attempt.receipt(status: ok ? "ok" : "failed", httpStatus: status,
                response: responseText, error: errors.isEmpty ? nil : errors.joined(separator: "; "))
        } catch {
            // A lost HTTP answer does not prove Apple rejected the write.
            return attempt.receipt(status: "unknown", error: error.localizedDescription)
        }
    }
    private static func payload(
        userInfo: [String: String]
    ) throws -> Data {
        var payload: [String: Any] = ["nativeagent": userInfo]
        for (key, value) in userInfo {
            payload[key] = value
        }
        // Keep the APS envelope owned here, never supplied by userInfo.
        payload["aps"] = ["content-available": 1]
        payload["nativeAgentWake"] = "notification"
        if payload["screen"] == nil {
            payload["screen"] = "activity"
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }
    private static func tokenAgeSeconds(_ updatedAt: String?, now: Date) -> Int? {
        guard let updatedAt,
              let date = ISO8601DateFormatter().date(from: updatedAt) else {
            return nil
        }
        return max(0, Int(now.timeIntervalSince(date)))
    }
}
