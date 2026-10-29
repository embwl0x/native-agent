#if canImport(CloudKit) && !os(Linux)
import Foundation
import CloudKit
import CryptoKit
import OSLog
// Blueprint: | `CloudKitDeviceTransport+Subscriptions.swift` | Silent notification subscriptions and registration reconciliation |

extension CloudKitDeviceTransport {
    // MARK: subscription (silent push — the live cross-device trigger)

    public func subscribeToChanges() async throws {
        do {
            try await withDeviceCKTimeoutThrowing("CloudKitDeviceTransport.subscribeToChanges", onFailure: accountFailureReporter) {
                // Both peers repair the shared legacy visible subscription.
                // Direct APNS is the sole remote alert; CloudKit only wakes sync.
                try await self.ensureSilentNotificationSubscription()
                let sub = Self.makeSilentChatSubscription()
                try await self.ensureSubscription(sub, id: sub.subscriptionID)
            }
        } catch is DeviceCKLandmineTimeout {
            throw DeviceSyncError.transient(message: "CloudKit subscribe timed out")
        }
    }

    // Chat subscriptions use a schema-independent broad predicate; direct APNS owns alerts and CloudKit only wakes sync.
    static func makeSilentChatSubscription() -> CKQuerySubscription {
        let sub = CKQuerySubscription(
            recordType: NADeviceSyncRecordType.chatMessage,
            predicate: NSPredicate(value: true),
            subscriptionID: DeviceCloudKitSubscriptionID.chat,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        return sub
    }

    /// Wake sync for explicit notification records without a second alert.
    private func ensureSilentNotificationSubscription() async throws {
        let sub = Self.makeSilentNotificationSubscription()
        try await ensureSubscription(sub, id: sub.subscriptionID)
        try await retireSubscription(id: "NAChatMessage.notifications.visible")
    }

    static func makeSilentNotificationSubscription() -> CKQuerySubscription {
        let sub = CKQuerySubscription(
            recordType: NADeviceSyncRecordType.notification,
            predicate: NSPredicate(value: true),
            subscriptionID: DeviceCloudKitSubscriptionID.visibleNotifications,
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        // Preserve the deployed subscription ID so upgrades remove its alert.
        info.desiredKeys = [
            "notificationScreen",
            "notificationEventId",
            "kind",
        ]
        info.collapseIDKey = "notificationEventId"
        sub.notificationInfo = info
        return sub
    }

    /// Remove the pre-split visual projection. Leaving it installed would let
    /// legacy `NAChatMessage(kind=notification)` writes keep competing with the
    /// silent chat subscription on upgraded accounts.
    private func retireSubscription(id: CKSubscription.ID) async throws {
        do {
            _ = try await database.deleteSubscription(withID: id)
        } catch let error as CKError where error.code == .unknownItem {
            return
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Durable silent-push subscription for the peer's pairing writes. Same broad
    /// value:true predicate as the chat subscription (no queryable-field/index
    /// dependency); drainPairing() filters to the peer's record locally.
    public func subscribeToPairingChanges() async throws {
        try await registerBroadSubscription(
            recordType: NADeviceSyncRecordType.pairingDevice,
            subscriptionID: DeviceCloudKitSubscriptionID.pairing,
            label: "subscribeToPairingChanges"
        )
    }

    /// Durable silent-push subscription for the peer's status writes.
    public func subscribeToStatusChanges() async throws {
        try await registerBroadSubscription(
            recordType: NADeviceSyncRecordType.status,
            subscriptionID: DeviceCloudKitSubscriptionID.status,
            label: "subscribeToStatusChanges"
        )
    }

    /// Shared broad-subscription registration (value:true predicate,
    /// shouldSendContentAvailable). Fails loud — the caller NSLogs; nothing is
    /// swallowed with try?. Treats "already exists" as success (durable).
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
                info.shouldSendContentAvailable = true  // silent push
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
              // Sends use the default zone. A stale custom-zone subscription
              // must not pass verification against our unscoped query.
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
