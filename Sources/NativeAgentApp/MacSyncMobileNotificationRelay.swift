import Foundation
import NativeAgentShared
import PersistenceCore

enum MacSyncMobileNotificationRelay {
    static func storePushToken(
        deviceId: String,
        token: String,
        environment: String,
        bundleId: String
    ) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let path = NativeAgentPaths.dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("push_tokens.json")
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let current = await persistence.readJSON(path, defaultValue: .object([:]))
            var root: [String: JSONValue]
            if case .object(let object) = current {
                root = object
            } else {
                root = [:]
            }
            var entry: [String: JSONValue] = [:]
            entry["deviceId"] = .string(deviceId)
            entry["token"] = .string(token)
            entry["environment"] = .string(environment)
            entry["sandbox"] = .string(environment)
            entry["bundleId"] = .string(bundleId)
            entry["lastSeen"] = .string(now)
            root[deviceId] = .object(entry)
            try await persistence.writeJSON(.object(root), to: path)
        }

        let legacyPath = NativeAgentPaths.dataRoot
            .appendingPathComponent("mobile_push", isDirectory: true)
            .appendingPathComponent("tokens.json")
        try? FileManager.default.createDirectory(
            at: legacyPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await persistence.withFileLock(legacyPath) {
            let current = await persistence.readJSON(legacyPath, defaultValue: .array([]))
            var rows: [JSONValue]
            if case .array(let array) = current {
                rows = array
            } else {
                rows = []
            }
            let entry: [String: JSONValue] = [
                "deviceId": .string(deviceId),
                "token": .string(token),
                "environment": .string(environment),
                "bundleId": .string(bundleId),
                "updatedAt": .string(now),
            ]
            var replaced = false
            for index in rows.indices {
                guard case .object(let row) = rows[index] else { continue }
                let existingDeviceId = jsonString(row["deviceId"]) ?? jsonString(row["device_id"])
                let existingToken = jsonString(row["token"])
                if existingDeviceId == deviceId || existingToken == token {
                    rows[index] = .object(entry)
                    replaced = true
                }
            }
            if !replaced {
                rows.append(.object(entry))
            }
            try await persistence.writeJSON(.array(rows), to: legacyPath)
        }
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
