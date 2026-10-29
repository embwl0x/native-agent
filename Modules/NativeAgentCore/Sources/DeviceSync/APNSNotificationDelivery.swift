import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `APNSNotificationDelivery.swift` | SwiftNativeAPNSSender notification/work-activity delivery, fan-out deadline and capped outcome receipts |
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
            try noteRejection(reason: reason, jwt: jwt)
            return MacSyncMobileNotificationRelay.WorkActivityRejection(
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
        let eventID = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo)
        var targets: [APNSTarget] = []
        do {
            let config = try APNSConfig.load(from: dataRoot)
            let tokens = try await loadTokens(dataRoot: dataRoot, config: config)
            targets = tokens.compactMap { config.target(for: $0) }
            guard !targets.isEmpty else {
                let errors = ["No APNS device tokens are registered with enough topic/environment metadata."]
                await recordOutcome(eventID: eventID, targets: targets, receipts: [], errors: errors, dataRoot: dataRoot)
                return ([], errors)
            }
            let jwt = try providerToken(keyId: config.keyId, teamId: config.teamId, keyPath: config.keyPath)
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
            await recordOutcome(eventID: eventID, targets: targets, receipts: receipts, errors: errors, dataRoot: dataRoot)
            return (receipts, errors)
        } catch {
            await recordOutcome(eventID: eventID, targets: targets, receipts: [], errors: [error.localizedDescription], dataRoot: dataRoot)
            return ([], [error.localizedDescription])
        }
    }
    /// Record each fan-out outcome; prune only tokens Apple retires with HTTP 410.
    private func recordOutcome(
        eventID: String,
        targets: [APNSTarget],
        receipts: [SwiftNativeAPNSReceipt],
        errors: [String],
        dataRoot: URL
    ) async {
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
                nativeLog("[APNS] could not prune unregistered token for %@: %@", receipt.deviceId, error.localizedDescription)
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
                logLabel: "SwiftNativeAPNS.outcome"
            )
        } catch {
            nativeLog("[APNS] could not record outcome for %@: %@", eventID, error.localizedDescription)
        }
    }
    /// How many devices `sendNotification` would push to right now: the same
    /// config and token filter, local files only, nothing sent.
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
        let receipt: SwiftNativeAPNSReceipt

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
            try noteRejection(reason: reason, jwt: jwt)
            receipt = SwiftNativeAPNSReceipt(
                apnsId: apnsId,
                createdAt: createdAt,
                status: ok ? "ok" : "failed",
                httpStatus: status,
                response: responseText,
                tokenSuffix: String(token.token.suffix(8)),
                deviceId: token.deviceId,
                pairedDeviceID: token.pairedDeviceID,
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
                pairedDeviceID: token.pairedDeviceID,
                tokenSource: token.source,
                tokenUpdatedAt: token.updatedAt,
                tokenAgeSeconds: tokenAgeSeconds,
                environment: target.environment,
                topic: target.topic,
                error: error.localizedDescription
            )
        }
        // The fan-out records one capped outcome line.
        return receipt
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
    private static func tokenAgeSeconds(_ updatedAt: String?, now: Date) -> Int? {
        guard let updatedAt,
              let date = ISO8601DateFormatter().date(from: updatedAt) else {
            return nil
        }
        return max(0, Int(now.timeIntervalSince(date)))
    }
}
