#if canImport(CloudKit) && !os(Linux)
import Foundation
import CloudKit
import CryptoKit
import OSLog
// Blueprint: | `CloudKitDeviceTransport+Subscriptions.swift` | Visible alerts, silent chat/results and exact registration proof |

extension CloudKitDeviceTransport {
    // MARK: subscriptions (ordinary alerts and silent cross-device triggers)

    func subscribeToChatChanges() async throws {
        try await registerBroadSubscription(
            recordType: NADeviceSyncRecordType.chatMessage,
            subscriptionID: DeviceCloudKitSubscriptionID.chat,
            label: "subscribeToChatChanges"
        )
    }

    /// CloudKit builds the alert from the record even without app execution. Requested results are chat records, so they cannot match this
    /// subscription.
    func subscribeToVisibleNotifications() async throws {
        do {
            try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.subscribeToVisibleNotifications", onFailure: accountFailureReporter) {
                let sub = Self.makeVisibleNotificationSubscription()
                try await self.ensureSubscription(sub, id: sub.subscriptionID)
            }
        } catch is DeviceCKLandmineTimeout {
            throw DeviceSyncError.transient(message: "CloudKit visible notification subscription timed out")
        }
    }

    static func makeVisibleNotificationSubscription() -> CKQuerySubscription {
        let sub = CKQuerySubscription(
            recordType: NADeviceSyncRecordType.notification,
            // Only notification envelopes carry a direction in this family. Presence shares the type but has no direction or alert fields. direction
            // is queryable in Production; kind/title/eventId are not.
            predicate: NSPredicate(format: "direction == %@", NAChatDirection.mac2ios.rawValue),
            subscriptionID: DeviceCloudKitSubscriptionID.visibleNotifications,
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        info.shouldSendMutableContent = true
        info.alertLocalizationKey = "NATIVEAGENT_CLOUDKIT_NOTIFICATION_BODY_FORMAT"
        info.alertLocalizationArgs = ["text"]
        info.titleLocalizationKey = "NATIVEAGENT_CLOUDKIT_NOTIFICATION_TITLE_FORMAT"
        info.titleLocalizationArgs = ["notificationTitle"]
        info.soundName = "default"
        // CloudKit permits three desired keys. Title/body use localization args; routing can read the exact envelope in the notification extension.
        info.desiredKeys = [
            "notificationScreen",
            "notificationEventId",
            "kind",
        ]
        info.collapseIDKey = "notificationEventId"
        sub.notificationInfo = info
        return sub
    }

    /// Durable silent-push subscription for the peer's pairing writes. Same broad value:true predicate as the chat subscription (no
    /// queryable-field/index dependency); drainPairing() filters to the peer's record locally.
    public func subscribeToPairingChanges() async throws {
        try await registerBroadSubscription(
            recordType: NADeviceSyncRecordType.pairingDevice,
            subscriptionID: DeviceCloudKitSubscriptionID.pairing,
            label: "subscribeToPairingChanges"
        )
    }

    public func subscribeToStatusChanges() async throws {
        try await registerBroadSubscription(
            recordType: NADeviceSyncRecordType.status,
            subscriptionID: DeviceCloudKitSubscriptionID.status,
            label: "subscribeToStatusChanges"
        )
    }

    /// Broad subscriptions avoid query-index dependencies; registration failures remain visible to the caller.
    private func registerBroadSubscription(
        recordType: String,
        subscriptionID: String,
        label: String
    ) async throws {
        do {
            try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.\(label)", onFailure: accountFailureReporter) {
                let predicate = NSPredicate(value: true)
                let sub = CKQuerySubscription(
                    recordType: recordType,
                    predicate: predicate,
                    subscriptionID: subscriptionID,
                    options: [.firesOnRecordCreation, .firesOnRecordUpdate]
                )
                let info = CKSubscription.NotificationInfo()
                info.shouldSendContentAvailable = true
                sub.notificationInfo = info
                try await self.ensureSubscription(sub, id: subscriptionID)
            }
        } catch is DeviceCKLandmineTimeout {
            throw DeviceSyncError.transient(message: "CloudKit \(label) timed out")
        }
    }

    // Verify the complete subscription shape; after a racing save, accept only an exact readback. Every other failure is reported.
    private func ensureSubscription(_ subscription: CKSubscription, id: CKSubscription.ID) async throws {
        var verified = false
        defer {
            if verified {
                devicePushLog.notice("Subscription verified role=\(self.role.rawValue, privacy: .public) id=\(id, privacy: .public)")
            } else {
                devicePushLog.error("Subscription not verified role=\(self.role.rawValue, privacy: .public) id=\(id, privacy: .public)")
            }
        }
        do {
            let existing = try await database.subscription(for: id)
            if Self.subscription(existing, matches: subscription) {
                verified = true
                return
            }
            let zoneMatches = (existing as? CKQuerySubscription)?.zoneID
                == (subscription as? CKQuerySubscription)?.zoneID
            devicePushLog.notice("Subscription repair role=\(self.role.rawValue, privacy: .public) id=\(id, privacy: .public) zoneMatches=\(zoneMatches)")
            nativeLog("[ck-device] repairing stale subscription shape for \(id)")
            // A subscription is replaced, never overwritten: CloudKit refuses a changed shape saved over a live id.
            do { _ = try await database.deleteSubscription(withID: id) }
            catch let error as CKError where error.code == .unknownItem {}
        } catch let error as CKError where error.code == .unknownItem {
            // Absent is the only state that authorizes a create attempt.
        } catch {
            throw Self.mapError(error)
        }

        do {
            let saved = try await database.save(subscription)
            guard Self.subscription(saved, matches: subscription) else {
                throw DeviceSyncError.underlying(
                    message: "CloudKit saved subscription \(id) with an unexpected shape"
                )
            }
            verified = true
        } catch {
            if let existing = try? await database.subscription(for: id),
               Self.subscription(existing, matches: subscription) {
                verified = true
                return
            }
            if let syncError = error as? DeviceSyncError {
                throw syncError
            }
            throw Self.mapError(error)
        }
    }

    static func subscription(
        _ existing: CKSubscription,
        matches expected: CKSubscription
    ) -> Bool {
        guard existing.subscriptionID == expected.subscriptionID,
              let existingQuery = existing as? CKQuerySubscription,
              let expectedQuery = expected as? CKQuerySubscription,
              existingQuery.recordType == expectedQuery.recordType,
              // Sends use the default zone. A stale custom-zone subscription must not pass verification against our unscoped query.
              existingQuery.zoneID == expectedQuery.zoneID,
              existingQuery.predicate.predicateFormat == expectedQuery.predicate.predicateFormat,
              existingQuery.querySubscriptionOptions == expectedQuery.querySubscriptionOptions
        else {
            return false
        }

        switch (existing.notificationInfo, expected.notificationInfo) {
        case (nil, nil):
            return true
        case let (existingInfo?, expectedInfo?):
            return existingInfo.shouldSendContentAvailable
                    == expectedInfo.shouldSendContentAvailable
                && existingInfo.shouldSendMutableContent
                    == expectedInfo.shouldSendMutableContent
                && existingInfo.shouldBadge == expectedInfo.shouldBadge
                && existingInfo.alertBody == expectedInfo.alertBody
                && existingInfo.title == expectedInfo.title
                && existingInfo.alertLocalizationKey
                    == expectedInfo.alertLocalizationKey
                && existingInfo.alertLocalizationArgs
                    == expectedInfo.alertLocalizationArgs
                && existingInfo.titleLocalizationKey
                    == expectedInfo.titleLocalizationKey
                && existingInfo.titleLocalizationArgs
                    == expectedInfo.titleLocalizationArgs
                && existingInfo.soundName == expectedInfo.soundName
                && Set(existingInfo.desiredKeys ?? [])
                    == Set(expectedInfo.desiredKeys ?? [])
                && existingInfo.collapseIDKey == expectedInfo.collapseIDKey
        default:
            return false
        }
    }
}
#endif
