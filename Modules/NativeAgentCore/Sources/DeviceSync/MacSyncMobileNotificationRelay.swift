import Privacy
import Foundation
import Cognition
import NativeAgentShared
import PersistenceCore

public struct MacSyncMobileNotificationRelay: Sendable {
    unowned let sync: DeviceSync

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
        dataRoot: URL = PersistenceCore.defaultDataRoot()
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
            var entry: [String: JSONValue]
            if case .object(let existing)? = root[deviceId] { entry = existing } else { entry = [:] }
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

    static func storeWorkActivityRegistration(
        deviceID: String, enabled: Bool, environment: String, bundleID: String,
        startToken: String?, workID: String?, activityToken: String?,
        observedWorkIDs: Set<String>?, dataRoot: URL
    ) async throws {
        let path = dataRoot.appendingPathComponent("notifications/push_tokens.json")
        let lock = dataRoot.appendingPathComponent("notifications/push-token-registration")
        let pairing = try PairingSecretManager.existingSecretBase64()
        guard let pairing, !deviceID.isEmpty, !bundleID.isEmpty else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let fingerprint = WorkActivityPushRegistration.fingerprint(pairing)
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(lock) {
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
            try await persistence.writeJSON(.object(root), to: path)
        }
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
            eventID: eventID,
            cloudKitVisualPushEligible: false
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
            persistSynchronously: false,
            prewarmContext: false
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
            persistSynchronously: false,
            prewarmContext: false
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
            persistSynchronously: false,
            prewarmContext: false
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
                NSLog("[iCloudBridge] APNS chat reply notification refused: %@", reason)
            }
            return false
        }

        await beginDeliveryPrediction(eventID: request.eventID, source: "icloud_chat_reply")
        let providerResult = await replyPushProviderResult(request)
        let outcome = Self.iCloudReplyPushNotificationOutcome(providerResult: providerResult)
        switch outcome {
        case .providerAccepted:
            NSLog("[iCloudBridge] APNS chat reply notification provider-accepted correlation=%@", correlationID)
            return true
        case .providerNotAccepted(let reason):
            await failDeliveryPrediction(eventID: request.eventID, source: "icloud_chat_reply")
            NSLog("[iCloudBridge] APNS chat reply notification not accepted correlation=%@: %@",
                  correlationID, reason)
            return false
        }
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

    static func iCloudReplyPushNotificationOutcome(
        providerResult: ICloudReplyPushNotificationProviderResult
    ) -> ICloudReplyPushNotificationOutcome {
        let attemptedTargets = max(0, providerResult.attemptedTargets)
        // The live sender derives both values from the same receipt array, but
        // normalize the boundary anyway: an inconsistent adapter result must
        // not transform zero provider receipts into an acceptance claim.
        let acceptedTargets = min(max(0, providerResult.acceptedTargets), attemptedTargets)
        guard acceptedTargets > 0 else {
            let reason: String
            if !providerResult.errors.isEmpty {
                reason = providerResult.errors.joined(separator: " | ")
            } else if attemptedTargets > 0 {
                reason = "APNS returned \(attemptedTargets) non-accepted provider receipt(s)."
            } else {
                reason = "APNS returned no provider receipts."
            }
            return .providerNotAccepted(reason: reason)
        }
        return .providerAccepted(
            attemptedTargets: attemptedTargets,
            acceptedTargets: acceptedTargets
        )
    }

    private func replyPushProviderResult(
        _ request: ICloudReplyPushNotificationRequest
    ) async -> ICloudReplyPushNotificationProviderResult {
        // The record wakes sync; direct APNS alone owns the remote alert.
        // A phone without an APNS token schedules the record locally using
        // the same event ID. Session identity stays intact for tap navigation.
        var userInfo = request.userInfo
        if let urgency = request.urgency { userInfo["urgency"] = urgency }
        do {
            let receipt = try await sendNotification(
                title: request.title,
                body: request.body,
                userInfo: userInfo,
                // This caller already opened the prediction for `eventID`.
                predictDelivery: false
            )
            // A queued CloudKit notification record is a real delivery
            // route, not a silent failure, so it counts as one target.
            let bridgeTargets = receipt.bridgeQueued ? 1 : 0
            return ICloudReplyPushNotificationProviderResult(
                attemptedTargets: receipt.apnsReceipts.count + bridgeTargets,
                acceptedTargets: receipt.apnsReceipts.filter(\.isSuccess).count + bridgeTargets,
                errors: receipt.apnsErrors + [receipt.bridgeError].compactMap { $0 }
            )
        } catch {
            return ICloudReplyPushNotificationProviderResult(
                attemptedTargets: 0,
                acceptedTargets: 0,
                errors: [error.localizedDescription]
            )
        }
    }

    private static func jsonString(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
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

/// APNS's provider-side outcome, reduced to the facts this bridge can honestly
/// observe. `acceptedTargets` means Apple accepted the request, not that a
/// device received or rendered it.
struct ICloudReplyPushNotificationProviderResult: Sendable, Equatable {
    let attemptedTargets: Int
    let acceptedTargets: Int
    let errors: [String]
}

enum ICloudReplyPushNotificationOutcome: Equatable {
    case providerAccepted(attemptedTargets: Int, acceptedTargets: Int)
    case providerNotAccepted(reason: String)
}

enum ICloudReplyPushNotificationPreparation: Equatable {
    case ready(ICloudReplyPushNotificationRequest)
    case rejected(reason: String)
}
