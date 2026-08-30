import Foundation
import NativeAgentShared
import PersistenceCore

enum MacSyncMobileNotificationRelay {
    private enum PushTokenStoreError: LocalizedError {
        case invalidTopLevel(path: URL, expected: String)

        var errorDescription: String? {
            switch self {
            case .invalidTopLevel(let path, let expected):
                return "Existing push-token store \(path.lastPathComponent) is not a \(expected); registration was not changed."
            }
        }
    }

    static func storePushToken(
        deviceId: String,
        token: String,
        environment: String,
        bundleId: String,
        dataRoot: URL = NativeAgentPaths.dataRoot
    ) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let path = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("push_tokens.json")
        let persistence = SwiftNativePersistenceCore()
        let legacyPath = dataRoot
            .appendingPathComponent("mobile_push", isDirectory: true)
            .appendingPathComponent("tokens.json")
        // One registration owns both projections. Separate per-file locks can
        // interleave two rotations of the same APNs token and leave canonical
        // and compatibility stores naming different devices. Reading both
        // before either write also makes malformed existing authority
        // fail-closed instead of silently replacing it with a one-row store.
        let registrationLock = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("push-token-registration")
        try await persistence.withFileLock(registrationLock) {
            var root = try readObjectStore(path)
            var rows = try readArrayStore(legacyPath)
            // A push token is one device credential. When APNs reassigns or a
            // restored phone presents an existing token under a new device id,
            // retain only the newest owner in BOTH canonical and compatibility
            // stores; otherwise fan-out can target a stale device identity.
            root = root.filter { existingDeviceID, value in
                guard existingDeviceID != deviceId,
                      case .object(let existing) = value else { return true }
                return jsonString(existing["token"]) != token
            }
            var entry: [String: JSONValue] = [:]
            entry["deviceId"] = .string(deviceId)
            entry["token"] = .string(token)
            entry["environment"] = .string(environment)
            entry["sandbox"] = .string(environment)
            entry["bundleId"] = .string(bundleId)
            entry["lastSeen"] = .string(now)
            root[deviceId] = .object(entry)
            let legacyEntry: [String: JSONValue] = [
                "deviceId": .string(deviceId),
                "token": .string(token),
                "environment": .string(environment),
                "bundleId": .string(bundleId),
                "updatedAt": .string(now),
            ]
            // Remove every stale match before appending the one current owner.
            // Replacing rows in place preserved pre-existing duplicates.
            rows.removeAll { value in
                guard case .object(let row) = value else { return false }
                let existingDeviceId = jsonString(row["deviceId"]) ?? jsonString(row["device_id"])
                let existingToken = jsonString(row["token"])
                return existingDeviceId == deviceId || existingToken == token
            }
            rows.append(.object(legacyEntry))

            try await persistence.writeJSON(.object(root), to: path)
            try await persistence.writeJSON(.array(rows), to: legacyPath)
        }
    }

    private static func readObjectStore(_ path: URL) throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let value = try JSONValue.parse(Data(contentsOf: path))
        guard case .object(let object) = value else {
            throw PushTokenStoreError.invalidTopLevel(path: path, expected: "JSON object")
        }
        return object
    }

    private static func readArrayStore(_ path: URL) throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let value = try JSONValue.parse(Data(contentsOf: path))
        guard case .array(let array) = value else {
            throw PushTokenStoreError.invalidTopLevel(path: path, expected: "JSON array")
        }
        return array
    }

    @discardableResult
    static func sendNotification(
        title: String,
        body: String,
        userInfo: [String: String] = [:]
    ) async throws -> MobileNotificationDeliveryReceipt {
        let notificationTitle = NativeAgentNotificationDefaults.title(title)
        let eventID = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo)
        await beginDeliveryPrediction(eventID: eventID, source: userInfo["source"] ?? "notification")
        var eventUserInfo = userInfo
        eventUserInfo["eventId"] = eventID
        var metadata: [String: String] = [
            "kind": "notification",
            "title": notificationTitle,
            "body": body,
        ]
        for (key, value) in eventUserInfo {
            metadata["userInfo.\(key)"] = value
        }

        var bridgeMessageID: String?
        var bridgeError: String?
        do {
            let message = try await iCloudBridge.shared.sendChatMessage(
                text: body,
                sessionID: nil,
                correlationID: nil,
                metadata: metadata
            )
            bridgeMessageID = message.id
        } catch {
            bridgeError = error.localizedDescription
        }

        let apns = await SwiftNativeAPNSSender.shared.sendNotification(
            title: notificationTitle,
            body: body,
            userInfo: eventUserInfo,
            urgency: eventUserInfo["urgency"]
        )
        let cloudKitVisualPushEligible =
            await iCloudBridge.shared.cloudKitVisualNotificationPeerReady
        let receipt = MobileNotificationDeliveryReceipt(
            bridgeMessageID: bridgeMessageID,
            bridgeError: bridgeError,
            apnsReceipts: apns.receipts,
            apnsErrors: apns.errors,
            eventID: eventID,
            cloudKitVisualPushEligible: cloudKitVisualPushEligible
        )
        guard receipt.bridgeQueued || receipt.apnsSent else {
            await failDeliveryPrediction(eventID: eventID, source: userInfo["source"] ?? "notification")
            throw NSError(domain: "NativeAgentMobileNotify", code: -1, userInfo: [
                NSLocalizedDescriptionKey: ([bridgeError] + apns.errors).compactMap { $0 }.joined(separator: " | ")
            ])
        }
        return receipt
    }

    static func beginDeliveryPrediction(eventID: String, source: String) async {
        guard NativeAgentDeviceEventIdentity.isCanonical(eventID) else { return }
        await NativeCognitionRuntime.shared.ingestOrganismSignal(
            kind: .phoneDeliveryStarted,
            sourceOrgan: "phone.\(eventID)",
            intensity: 0.30,
            metadata: [
                "predictionCorrelationId": .string(eventID),
                "eventId": .string(eventID),
                "source": .string(source),
            ],
            persistSynchronously: false,
            prewarmContext: false
        )
    }

    static func receiveDeliveryPrediction(eventID: String, channel: String) async {
        guard NativeAgentDeviceEventIdentity.isCanonical(eventID) else { return }
        await NativeCognitionRuntime.shared.ingestOrganismSignal(
            kind: .phoneDeliveryReceived,
            sourceOrgan: "phone.\(eventID)",
            intensity: 0.60,
            valence: 0.15,
            metadata: [
                "predictionCorrelationId": .string(eventID),
                "eventId": .string(eventID),
                "channel": .string(channel),
            ],
            persistSynchronously: false,
            prewarmContext: false
        )
    }

    static func failDeliveryPrediction(eventID: String, source: String) async {
        guard NativeAgentDeviceEventIdentity.isCanonical(eventID) else { return }
        await NativeCognitionRuntime.shared.ingestOrganismSignal(
            kind: .phoneDeliveryFailed,
            sourceOrgan: "phone.\(eventID)",
            intensity: 0.65,
            valence: -0.35,
            metadata: [
                "predictionCorrelationId": .string(eventID),
                "eventId": .string(eventID),
                "source": .string(source),
            ],
            persistSynchronously: false,
            prewarmContext: false
        )
    }

    private static func jsonString(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }
}
