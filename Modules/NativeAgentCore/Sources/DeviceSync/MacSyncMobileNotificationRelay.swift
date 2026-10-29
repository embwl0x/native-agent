import Privacy
import Foundation
import Cognition
import NativeAgentShared
import PersistenceCore
// Blueprint: | `MacSyncMobileNotificationRelay.swift` | Sole notifications/push_tokens.json mutation owner: alert registration/pruning, work-activity registration and locked delivery reservations/outcomes; APNs supplies only the send effect; no duplicate mobile_push/tokens.json writes |

public struct MacSyncMobileNotificationRelay: Sendable {
    unowned let sync: DeviceSync

    private struct PushTokenStoreError: LocalizedError {
        let path: URL
        var errorDescription: String? {
            "Existing push-token store \(path.lastPathComponent) is not a JSON object; registration was not changed."
        }
    }

    static func storePushToken(
        deviceId: String,
        pairedDeviceID: String,
        token: String,
        environment: String,
        bundleId: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let path = dataRoot.appendingPathComponent("notifications/push_tokens.json")
        let registrationLock = dataRoot.appendingPathComponent("notifications/push-token-registration")
        try await SwiftNativePersistenceCore.withFileLock(registrationLock) {
            var root = try readObjectStore(path)
            // A push token is one device credential. When APNs reassigns or a
            // restored phone presents an existing token under a new device id,
            // retain only the newest owner in the canonical map.
            root = root.filter { existingDeviceID, value in
                guard existingDeviceID != deviceId,
                      case .object(let existing) = value else { return true }
                return existing["token"]?.stringValue != token
            }
            var entry: [String: JSONValue]
            if case .object(let existing)? = root[deviceId] { entry = existing } else { entry = [:] }
            entry["deviceId"] = .string(deviceId)
            entry["pairedDeviceID"] = .string(pairedDeviceID)
            entry["token"] = .string(token)
            entry["environment"] = .string(environment)
            entry["sandbox"] = .string(environment)
            entry["bundleId"] = .string(bundleId)
            entry["lastSeen"] = .string(now)
            root[deviceId] = .object(entry)
            try await SwiftNativePersistenceCore.writeJSON(.object(root), to: path)
        }
    }

    /// APNs answered 410 for this token: Apple last confirmed it dead at
    /// `unregisteredAt`. Under the registration lock, remove only that alert
    /// token (the entry's work-activity state stays), and only where it was
    /// registered before that moment: a phone that re-registered the same
    /// token since keeps it. A live phone re-registers on launch.
    static func prunePushToken(_ token: String, unregisteredAt: Date, dataRoot: URL) async throws {
        let path = dataRoot.appendingPathComponent("notifications/push_tokens.json")
        @Sendable func registeredBefore(_ stamp: JSONValue?) -> Bool {
            guard let text = stamp?.stringValue, let date = ISO8601DateFormatter().date(from: text) else { return false }
            return date < unregisteredAt
        }
        try await SwiftNativePersistenceCore.withFileLock(dataRoot.appendingPathComponent("notifications/push-token-registration")) {
            var root = try readObjectStore(path)
            var rootChanged = false
            for (deviceID, value) in root {
                guard case .object(var entry) = value, entry["token"]?.stringValue == token,
                      registeredBefore(entry["lastSeen"]) else { continue }
                entry.removeValue(forKey: "token")
                root[deviceID] = .object(entry)
                rootChanged = true
            }
            if rootChanged {
                try await SwiftNativePersistenceCore.writeJSON(.object(root), to: path)
            }
        }
    }

    private static func readObjectStore(_ path: URL) throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let value = try JSONValue.parse(Data(contentsOf: path))
        guard case .object(let object) = value else {
            throw PushTokenStoreError(path: path)
        }
        return object
    }

    static func storeWorkActivityRegistration(
        deviceID: String, enabled: Bool, environment: String, bundleID: String,
        startToken: String?, workID: String?, activityToken: String?,
        observedWorkIDs: Set<String>?, dataRoot: URL
    ) async throws {
        let path = dataRoot.appendingPathComponent("notifications/push_tokens.json")
        let lock = dataRoot.appendingPathComponent("notifications/push-token-registration")
        let pairing = try PairingSecret.existingSecretBase64()
        guard let pairing, !deviceID.isEmpty, !bundleID.isEmpty else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let fingerprint = WorkActivityPushRegistration.fingerprint(pairing)
        try await SwiftNativePersistenceCore.withFileLock(lock) {
            var root = try readObjectStore(path)
            var entry: [String: JSONValue]
            if case .object(let existing)? = root[deviceID] { entry = existing } else { entry = [:] }
            var registration = try WorkActivityPushRegistration.read(entry["workActivity"])
                ?? WorkActivityPushRegistration(pairing: fingerprint, environment: environment, bundleID: bundleID)
            if registration.pairing != fingerprint {
                registration = WorkActivityPushRegistration(pairing: fingerprint, environment: environment, bundleID: bundleID)
            }
            registration.enabled = enabled
            registration.environment = environment
            registration.bundleID = bundleID
            if !enabled {
                registration.startToken = nil
                registration.activityTokens.removeAll()
                registration.lastContents.removeAll()
                // Revoking opt-in does not establish whether an unknown start happened.
                registration.startOutcomes = registration.startOutcomes?.filter { $0.value == .unknown || $0.value == .notObserved }
                registration.startedIDs = Set(registration.startOutcomes?.keys.map { $0 } ?? [])
            } else {
                if let startToken { registration.startToken = startToken }
                if let observedWorkIDs {
                    for (id, outcome) in registration.startOutcomes ?? [:] where outcome == .unknown || outcome == .notObserved {
                        // Absence on foreground is an observation, not proof of rejection.
                        // Keep the reservation even when ActivityKit has no matching activity.
                        registration.startOutcomes?[id] = observedWorkIDs.contains(id) ? .observed : .notObserved
                    }
                }
                if let workID {
                    if let activityToken { registration.activityTokens[workID] = activityToken }
                    registration.startedIDs.insert(workID)
                    if registration.startOutcomes?[workID] != nil { registration.startOutcomes?[workID] = .observed }
                }
            }
            entry["workActivity"] = try JSONValue.parse(JSONEncoder().encode(registration))
            root[deviceID] = .object(entry)
            try await SwiftNativePersistenceCore.writeJSON(.object(root), to: path)
        }
    }

    func sendWorkActivities(_ rows: [MobileWorkActivity], dataRoot: URL) async -> [String] {
        do {
            let config = try SwiftNativeAPNSSender.APNSConfig.load(from: dataRoot)
            guard let pairing = try PairingSecret.existingSecretBase64() else { return [] }
            let fingerprint = WorkActivityPushRegistration.fingerprint(pairing)
            let path = dataRoot.appendingPathComponent("notifications/push_tokens.json")
            let lock = dataRoot.appendingPathComponent("notifications/push-token-registration")
            let value = try await SwiftNativePersistenceCore.readJSON(path, ifMissing: .object([:]))
            guard case .object(let root) = value else { throw CocoaError(.propertyListReadCorrupt) }
            let jwt = try await sync.apns.providerToken(keyId: config.keyId, teamId: config.teamId, keyPath: config.keyPath)
            var errors: [String] = []
            for (deviceID, value) in root.sorted(by: { $0.key < $1.key }) {
                guard case .object(let entry) = value,
                      let original = try WorkActivityPushRegistration.read(entry["workActivity"]),
                      original.pairing == fingerprint else { continue }
                let ids = Set(rows.map(\.id))
                let eligibleStartIDs = Set(rows.filter { !$0.content.state.isTerminal && $0.staleDate > Date() }.map(\.id))
                // Cleanup also runs with no current rows or with opt-in revoked.
                try await SwiftNativePersistenceCore.withFileLock(lock) {
                    let latest = try await SwiftNativePersistenceCore.readJSON(path, ifMissing: .object([:]))
                    guard case .object(var root) = latest, case .object(var entry)? = root[deviceID],
                          var registration = try WorkActivityPushRegistration.read(entry["workActivity"]),
                          registration.pairing == fingerprint else { return }
                    registration.retireInactiveStarts(activeIDs: eligibleStartIDs, now: Date())
                    entry["workActivity"] = try JSONValue.parse(JSONEncoder().encode(registration))
                    root[deviceID] = .object(entry)
                    try await SwiftNativePersistenceCore.writeJSON(.object(root), to: path)
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
                    let failure: String? = try await SwiftNativePersistenceCore.withFileLock(lock) {
                        let latest = try await SwiftNativePersistenceCore.readJSON(path, ifMissing: .object([:]))
                        guard case .object(var root) = latest, case .object(var entry)? = root[deviceID],
                              var registration = try WorkActivityPushRegistration.read(entry["workActivity"]),
                              registration.enabled, registration.pairing == fingerprint,
                              let currentPairing = try PairingSecret.existingSecretBase64(),
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
                            try await SwiftNativePersistenceCore.writeJSON(.object(root), to: path)
                        }
                        let failure = try await sync.apns.sendWorkActivity(row, event: event, token: token, registration: registration, jwt: jwt)
                        if let failure {
                            if event == "start" {
                                // Only an explicit provider rejection permits another start.
                                registration.startedIDs.remove(row.id)
                                registration.startOutcomes?.removeValue(forKey: row.id)
                                registration.startReservations?.removeValue(forKey: row.id)
                            } else if failure.tokenIsInvalid {
                                registration.activityTokens.removeValue(forKey: row.id)
                                // Keep the start reservation: an invalid update
                                // token does not authorize a duplicate start.
                            }
                            if event == "start" || failure.tokenIsInvalid {
                                entry["workActivity"] = try JSONValue.parse(JSONEncoder().encode(registration))
                                root[deviceID] = .object(entry)
                                try await SwiftNativePersistenceCore.writeJSON(.object(root), to: path)
                            }
                            return failure.message
                        }
                        registration.lastContents[row.id] = row.content
                        if event == "start" { registration.startOutcomes?[row.id] = .accepted }
                        if event == "end" { registration.activityTokens.removeValue(forKey: row.id) }
                        registration.retireInactiveStarts(activeIDs: eligibleStartIDs, now: Date())
                        entry["workActivity"] = try JSONValue.parse(JSONEncoder().encode(registration))
                        root[deviceID] = .object(entry)
                        try await SwiftNativePersistenceCore.writeJSON(.object(root), to: path)
                        return nil
                    }
                    if let failure { errors.append(failure) }
                }
            }
            return errors
        } catch { return [error.localizedDescription] }
    }

    struct WorkActivityRejection: Sendable {
        let message: String
        let tokenIsInvalid: Bool
    }

    @discardableResult
    /// `predictDelivery: false` is for callers that already opened (and own the
    /// failure side of) the delivery prediction for this same event identity —
    /// the iCloud chat reply path does. Double-ingesting one event's start
    /// would make one notification look like two.
    public func sendNotification(
        title: String,
        body: String,
        userInfo: [String: String] = [:],
        predictDelivery: Bool = true
    ) async throws -> MobileNotificationDeliveryReceipt {
        let notificationTitle = NativeAgentNotificationDefaults.title(title)
        let eventID = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo)
        if predictDelivery {
            await beginDeliveryPrediction(eventID: eventID, source: userInfo["source"] ?? "notification")
        }
        if userInfo["source"] == "requested_result" {
            return try await sendRequestedResult(title: notificationTitle, body: body, userInfo: userInfo, eventID: eventID)
        }
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

        let apns = await sync.apns.sendNotification(
            title: notificationTitle,
            body: body,
            userInfo: eventUserInfo,
            urgency: eventUserInfo["urgency"]
        )
        // Each phone chooses its alert path from its own APNS acceptance.
        let acceptedDeviceIDs = Set(apns.receipts.filter(\.isSuccess).map(\.deviceId)).sorted()
        metadata["directAlertDeviceIDs"] = String(
            decoding: try JSONEncoder().encode(acceptedDeviceIDs), as: UTF8.self
        )

        var bridgeMessageID: String?
        var bridgeError: String?
        do {
            let message = try await sync.bridge.sendChatMessage(
                text: body,
                sessionID: nil,
                correlationID: nil,
                metadata: metadata
            )
            bridgeMessageID = message.id
        } catch {
            bridgeError = error.localizedDescription
        }

        let receipt = MobileNotificationDeliveryReceipt(
            bridgeMessageID: bridgeMessageID,
            bridgeError: bridgeError,
            apnsReceipts: apns.receipts,
            apnsErrors: apns.errors,
            eventID: eventID
        )
        guard receipt.bridgeQueued || receipt.apnsSent else {
            if predictDelivery {
                await failDeliveryPrediction(eventID: eventID, source: userInfo["source"] ?? "notification")
            }
            throw NSError(domain: "NativeAgentMobileNotify", code: -1, userInfo: [
                NSLocalizedDescriptionKey: ([bridgeError] + apns.errors).compactMap { $0 }.joined(separator: " | ")
            ])
        }
        return receipt
    }

    /// One signed notification record owns the visible result. APNS wakes its
    /// reader after publication, and retries reuse identical signed bytes.
    private func sendRequestedResult(title: String, body: String, userInfo: [String: String],
                                     eventID: String) async throws -> MobileNotificationDeliveryReceipt {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let createdAt = userInfo["resultCreatedAt"], let timestamp = formatter.date(from: createdAt) else {
            throw NSError(domain: "RequestedResult", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The result has no valid settlement timestamp."])
        }
        var eventInfo = userInfo
        eventInfo["eventId"] = eventID
        var metadata = ["kind": "notification", "title": title, "body": body, "directAlertDeviceIDs": "[]"]
        for (key, value) in eventInfo { metadata["userInfo.\(key)"] = value }
        let message = try await sync.bridge.sendChatMessage(
            text: body, metadata: metadata, messageID: eventID, timestamp: timestamp
        )
        let wake = await sync.apns.sendNotification(title: title, body: body, userInfo: eventInfo)
        // A wake is not visual acceptance. The receipt truth is the signed
        // record queued for the phone's existing notification reader.
        return MobileNotificationDeliveryReceipt(bridgeMessageID: message.id, bridgeError: nil,
            apnsReceipts: [], apnsErrors: wake.errors, eventID: eventID)
    }

    public func beginDeliveryPrediction(eventID: String, source: String) async {
        guard NativeAgentDeviceEventIdentity.isCanonical(eventID) else { return }
        await sync.cognition.ingestOrganismSignal(
            kind: .phoneDeliveryStarted,
            sourceOrgan: "phone.\(eventID)",
            intensity: 0.30,
            metadata: [
                "predictionCorrelationId": .string(eventID),
                "eventId": .string(eventID),
                "source": .string(source),
            ],
            persistSynchronously: false
        )
    }

    func receiveDeliveryPrediction(eventID: String, channel: String) async {
        guard NativeAgentDeviceEventIdentity.isCanonical(eventID) else { return }
        await sync.cognition.ingestOrganismSignal(
            kind: .phoneDeliveryReceived,
            sourceOrgan: "phone.\(eventID)",
            intensity: 0.60,
            valence: 0.15,
            metadata: [
                "predictionCorrelationId": .string(eventID),
                "eventId": .string(eventID),
                "channel": .string(channel),
            ],
            persistSynchronously: false
        )
    }

    public func failDeliveryPrediction(eventID: String, source: String) async {
        guard NativeAgentDeviceEventIdentity.isCanonical(eventID) else { return }
        await sync.cognition.ingestOrganismSignal(
            kind: .phoneDeliveryFailed,
            sourceOrgan: "phone.\(eventID)",
            intensity: 0.65,
            valence: -0.35,
            metadata: [
                "predictionCorrelationId": .string(eventID),
                "eventId": .string(eventID),
                "source": .string(source),
            ],
            persistSynchronously: false
        )
    }

    @discardableResult
    public func sendICloudReplyPushNotification(
        text: String,
        sessionID: String?,
        correlationID: String,
        kind: String
    ) async -> Bool {
        let preparation = Self.iCloudReplyPushNotificationRequest(
            text: text,
            sessionID: sessionID,
            correlationID: correlationID,
            kind: kind
        )
        guard case .ready(let request) = preparation else {
            if case .rejected(let reason) = preparation {
                nativeLog("[iCloudBridge] APNS chat reply notification refused: %@", reason)
            }
            return false
        }

        await beginDeliveryPrediction(eventID: request.eventID, source: "icloud_chat_reply")
        var userInfo = request.userInfo
        if let urgency = request.urgency { userInfo["urgency"] = urgency }
        do {
            _ = try await sendNotification(title: request.title, body: request.body,
                userInfo: userInfo, predictDelivery: false)
            nativeLog("[iCloudBridge] chat reply notification accepted correlation=%@", correlationID)
            return true
        } catch {
            nativeLog("[iCloudBridge] chat reply notification not accepted correlation=%@: %@",
                correlationID, error.localizedDescription)
        }
        await failDeliveryPrediction(eventID: request.eventID, source: "icloud_chat_reply")
        return false
    }

    /// Builds the exact provider payload used by `sendICloudReplyPushNotification`.
    /// A missing correlation/kind is not allowed to collapse unrelated replies
    /// into one notification identity, and blank text never starts a prediction.
    static func iCloudReplyPushNotificationRequest(
        text: String,
        sessionID: String?,
        correlationID: String,
        kind: String
    ) -> ICloudReplyPushNotificationPreparation {
        let cleanText = NativeAppSecretRedactor.redactText(
            String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        )
        guard !cleanText.isEmpty else { return .rejected(reason: "empty_reply_text") }
        let cleanCorrelationID = correlationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCorrelationID.isEmpty else { return .rejected(reason: "missing_correlation_id") }
        let cleanKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKind.isEmpty else { return .rejected(reason: "missing_reply_kind") }
        var userInfo: [String: String] = [
            "screen": "chat",
            "source": "icloud_chat_reply",
            "correlationId": cleanCorrelationID,
            "kind": cleanKind,
            // `NativeAgentDeviceEventIdentity` recognizes `dedupKey`; without
            // it reply pushes fell through to a fresh UUID each time and APNS
            // could not collapse retry/duplicate delivery attempts.
            "dedupKey": "icloud_chat_reply:\(cleanCorrelationID):\(cleanKind)",
        ]
        if let sessionID,
           !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userInfo["sessionId"] = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let eventID = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo)
        userInfo["eventId"] = eventID
        return .ready(ICloudReplyPushNotificationRequest(
            title: NativeAgentNotificationDefaults.agentDisplayName(),
            body: cleanText,
            userInfo: userInfo,
            urgency: cleanKind == "error" ? "urgent" : nil,
            eventID: eventID
        ))
    }

}

/// The bounded, redacted notification request that crosses from an iCloud chat
/// reply into the APNS provider boundary. Provider acceptance is deliberately
/// not a claim that an iPhone displayed the notification.
struct ICloudReplyPushNotificationRequest: Sendable, Equatable {
    let title: String
    let body: String
    let userInfo: [String: String]
    let urgency: String?
    let eventID: String
}

enum ICloudReplyPushNotificationPreparation: Equatable {
    case ready(ICloudReplyPushNotificationRequest)
    case rejected(reason: String)
}
