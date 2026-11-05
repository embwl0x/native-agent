import Privacy
import Foundation
import Cognition
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `MacSyncMobileNotificationRelay.swift` | Sole registration writer; immutable publication intents keyed by the canonical event |

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
        _ = try SwiftNativeAPNSSender.Environment.checked(environment)
        let now = ISO8601DateFormatter().string(from: Date())
        let path = dataRoot.appendingPathComponent("notifications/push_tokens.json")
        let registrationLock = dataRoot.appendingPathComponent("notifications/push-token-registration")
        try await SwiftNativePersistenceCore.withFileLock(registrationLock) {
            var root = try readObjectStore(path)
            // One token is one device credential; reassignment must leave only its newest owner.
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
            entry["bundleId"] = .string(bundleId)
            entry["lastSeen"] = .string(now)
            root[deviceId] = .object(entry)
            try await SwiftNativePersistenceCore.writeJSON(.object(root), to: path)
        }
    }

    /// Under the registration lock, retire only alert tokens registered before Apple's 410 timestamp. Preserve newer registrations of the same token and the
    /// entry's independent work activity.
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
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
        let value = try JSONValue.parse(data)
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
        _ = try SwiftNativeAPNSSender.Environment.checked(environment)
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
                        // Foreground absence does not prove rejection; retain the unknown-start reservation.
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
            let root = try Self.readObjectStore(path)
            let jwt = try await sync.apns.providerToken(keyId: config.keyId, teamId: config.teamId, keyPath: config.keyPath)
            var errors: [String] = []
            for (deviceID, value) in root.sorted(by: { $0.key < $1.key }) {
                do {
                    guard case .object(let entry) = value else { throw CocoaError(.propertyListReadCorrupt) }
                    guard let original = try WorkActivityPushRegistration.read(entry["workActivity"]),
                          original.pairing == fingerprint else { continue }
                    let ids = Set(rows.map(\.id))
                    let eligibleStartIDs = Set(rows.filter { !$0.content.state.isTerminal && $0.staleDate > Date() }.map(\.id))
                    // Cleanup also runs with no current rows or with opt-in revoked.
                    try await SwiftNativePersistenceCore.withFileLock(lock) {
                        var root = try Self.readObjectStore(path)
                        guard let value = root[deviceID] else { return }
                        guard case .object(var entry) = value else { throw CocoaError(.propertyListReadCorrupt) }
                        guard var registration = try WorkActivityPushRegistration.read(entry["workActivity"]),
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
                            var root = try Self.readObjectStore(path)
                            guard let value = root[deviceID] else { return nil }
                            guard case .object(var entry) = value else { throw CocoaError(.propertyListReadCorrupt) }
                            guard var registration = try WorkActivityPushRegistration.read(entry["workActivity"]),
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
                                // Reserve before sending so lost responses or receipt failures cannot authorize a duplicate start.
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
                                    // An invalid update token cannot authorize a duplicate start; retain its reservation.
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
                } catch { errors.append("Live Activity registration \(deviceID) is unavailable: \(error.localizedDescription)") }
            }
            return errors
        } catch { return [error.localizedDescription] }
    }

    struct WorkActivityRejection: Sendable {
        let message: String
        let tokenIsInvalid: Bool
    }

    @discardableResult
    /// Callers owning this event's prediction set predictDelivery false so a single notification cannot count twice.
    public func sendNotification(
        title: String,
        body: String,
        userInfo: [String: String] = [:],
        predictDelivery: Bool = true
    ) async throws -> MobileNotificationDeliveryReceipt {
        guard !Task.isCancelled else {
            throw NotificationDeliveryFailure(.notDelivered(reason: "cancelled before dispatch"), "cancelled before dispatch")
        }
        let notificationTitle = NativeAgentNotificationDefaults.title(title)
        let eventID = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo)
        if predictDelivery {
            await beginDeliveryPrediction(eventID: eventID, source: userInfo["source"] ?? "notification")
        }
        do {
            return try await sendSignedNotification(title: notificationTitle, body: body,
                                                    userInfo: userInfo, eventID: eventID)
        } catch let unknown as DeviceSyncSendOutcomeUnknown {
            // Server acceptance is unknown: the prediction stays open, never a confirmed failure.
            throw NotificationDeliveryFailure(.unknown(sent: true, reason: unknown.localizedDescription), unknown.localizedDescription)
        } catch is CancellationError {
            throw NotificationDeliveryFailure(
                .unknown(sent: true, reason: "Phone publication was cancelled; acceptance unconfirmed"),
                "Phone publication was cancelled; acceptance unconfirmed")
        } catch let failure as ToolFailureError where failure.effects != .none {
            // Unreadable or conflicting retained intent may describe an earlier effect; preserve that uncertainty.
            throw NotificationDeliveryFailure(.unknown(sent: true, reason: failure.localizedDescription), failure.localizedDescription)
        } catch {
            if predictDelivery {
                await failDeliveryPrediction(eventID: eventID, source: userInfo["source"] ?? "notification")
            }
            throw NotificationDeliveryFailure(.notDelivered(reason: error.localizedDescription), error.localizedDescription)
        }
    }

    /// CloudKit renders ordinary alerts; signed readers deliver results. Transport failure cannot select another renderer.
    private func sendSignedNotification(title: String, body: String, userInfo: [String: String],
                                        eventID: String) async throws -> MobileNotificationDeliveryReceipt {
        var eventInfo = userInfo
        eventInfo["eventId"] = eventID
        let publication = try await retainPublication(
            title: title, body: body, userInfo: eventInfo, eventID: eventID, timestamp: Date())
        // The retained intent is what goes out on every attempt, byte for byte.
        var metadata = ["kind": "notification", "title": publication.title, "body": publication.body]
        for (key, value) in publication.userInfo { metadata["userInfo.\(key)"] = value }
        let message = try await sync.bridge.sendChatMessage(
            text: publication.body, metadata: metadata, messageID: eventID, timestamp: publication.timestamp
        )
        let push = await sync.apns.sendNotificationWake(userInfo: publication.userInfo, dataRoot: sync.dataRoot)
        let signedResult = userInfo["source"] == "requested_result"
        // Provider acceptance and signed record receipt are not display proof.
        return MobileNotificationDeliveryReceipt(bridgeMessageID: message.id,
            apnsReceipts: push.receipts, apnsErrors: push.errors, eventID: eventID,
            signedResult: signedResult)
    }

    private struct NotificationPublication: Codable, Sendable {
        let title: String
        let body: String
        let userInfo: [String: String]
        let timestamp: Date
    }

    /// Retain intent and time before sending; timeout, restart and concurrency must reuse them, while unreadable bytes remain failures.
    private func retainPublication(title: String, body: String, userInfo: [String: String],
                                   eventID: String, timestamp: Date) async throws -> NotificationPublication {
        let path = sync.dataRoot.appendingPathComponent("notifications/publications/\(eventID).json")
        do {
            return try await SwiftNativePersistenceCore.withFileLock(path, waitingAtMost: 5) {
                let data: Data
                do { data = try Data(contentsOf: path) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    let publication = NotificationPublication(title: title, body: body, userInfo: userInfo, timestamp: timestamp)
                    try SwiftNativePersistenceCore.writeDataAtomicDurable(try JSONEncoder().encode(publication), to: path)
                    return publication
                }
                let publication = try JSONDecoder().decode(NotificationPublication.self, from: data)
                // One event keeps its exact words and route; a retry reuses the first publication's time.
                guard publication.title == title, publication.body == body, publication.userInfo == userInfo else {
                    throw NSError(domain: "NativeAgentMobileNotify", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: """
                            This notification event already has different retained content. Preserve its publication and repair the producer's event \
                            identity; retrying must not replace the original alert.
                            """
                    ])
                }
                return publication
            }
        } catch {
            throw ToolFailureError("Notification publication \(path.path) is unavailable: \(error.localizedDescription)",
                effects: .unknown, owner: "phone notifications",
                nextCall: ToolFailureError.call("app", ["page": .string("pairing")]),
                code: "notification_publication_unavailable",
                instruction: """
                    Preserve the publication bytes and repair their read/write failure or the producer's conflicting event identity before retrying. An \
                    earlier attempt may already have reached the phone.
                    """,
                recovery: .repair)
        }
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

        var info = request.userInfo
        if let urgency = request.urgency { info["urgency"] = urgency }
        info["eventId"] = request.eventID
        guard NotificationChannelPreference.push() else { return false }
        do {
            // A reply's identity is its request's event: the retained publication and the phone's receipt keep it on repeat.
            let receipt = try await sendNotification(title: request.title, body: request.body, userInfo: info)
            return receipt.notificationOutcome == .delivered
        } catch {
            nativeLog("[iCloudBridge] chat reply notification remains owed correlation=%@: %@", correlationID, error.localizedDescription)
            return false
        }
    }

    /// Correlation and kind must bind reply identity; blank text cannot start a prediction.
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
            // dedupKey binds retry attempts to one event so APNs can collapse duplicates.
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

/// Only bounded, redacted reply requests cross the provider boundary; acceptance cannot prove phone display.
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
