import SwiftUI
import CryptoKit
import UserNotifications
import UIKit
import NativeAgentShared
#if canImport(CloudKit)
import CloudKit
import CloudKit
// Blueprint: | `MobilePushNotifications.swift` | `NativeAgentPushTokenSyncCache` struct; `load`, `shouldSync` |
#endif

struct NativeAgentPushTokenSyncCache {
    struct PairingIdentity: Codable, Equatable {
        var secretHash: String?
        var secretVersion: Int64
    }

    struct Fingerprint: Codable, Equatable {
        var tokenHash: String
        var environment: String
        var bundleId: String
        var deviceId: String
        var pairing: PairingIdentity
    }

    struct Record: Codable, Equatable {
        var fingerprint: Fingerprint
        var registeredAt: Date
        var syncedAt: Date
    }

    static let defaultsKey = "NativeAgentMobile.lastSyncedAPNSToken"
    static let tokenSyncRefreshInterval: TimeInterval = 10 * 60

    var defaults: UserDefaults = .standard

    func load() throws -> Record? {
        guard let stored = defaults.object(forKey: Self.defaultsKey) else { return nil }
        guard let data = stored as? Data else {
            throw SyncError.persistence("The saved APNS registration cache is not data. Repair NativeAgentMobile.lastSyncedAPNSToken in the phone's preferences; its value is retained.")
        }
        return try JSONDecoder().decode(Record.self, from: data)
    }

    func shouldSync(
        _ fingerprint: Fingerprint,
        now: Date = Date(),
        refreshInterval: TimeInterval = Self.tokenSyncRefreshInterval
    ) throws -> Bool {
        guard let record = try load() else { return true }
        guard record.fingerprint == fingerprint else { return true }
        guard now.timeIntervalSince(record.syncedAt) >= 0 else { return true }
        return now.timeIntervalSince(record.syncedAt) >= refreshInterval
    }

    func markSynced(_ fingerprint: Fingerprint, now: Date = Date()) throws {
        let record = Record(fingerprint: fingerprint, registeredAt: now, syncedAt: now)
        let data = try JSONEncoder().encode(record)
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func pairingIdentity(secret: Data?, secretVersion: Int64) -> PairingIdentity {
        PairingIdentity(
            secretHash: secret.map { sha256Hex($0) },
            secretVersion: secretVersion
        )
    }

    static func fingerprint(
        token: String,
        environment: String,
        bundleId: String,
        deviceId: String,
        pairing: PairingIdentity
    ) -> Fingerprint {
        Fingerprint(
            tokenHash: sha256Hex(Data(token.utf8)),
            environment: environment,
            bundleId: bundleId,
            deviceId: deviceId,
            pairing: pairing
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum NativeAgentAPNSEnvironment: String, Equatable {
    case development
    case production
}

enum NativeAgentAPNSEnvironmentResolver {
    static func current(bundle: Bundle = .main) -> NativeAgentAPNSEnvironment? {
        guard let profileURL = bundle.url(forResource: "embedded", withExtension: "mobileprovision") else {
            // App Store and TestFlight installs do not carry an embedded profile;
            // their APNS tokens use the production environment.
            return resolve(embeddedProfileData: nil, embeddedProfilePresent: false)
        }
        return resolve(
            embeddedProfileData: try? Data(contentsOf: profileURL),
            embeddedProfilePresent: true
        )
    }

    static func resolve(
        embeddedProfileData: Data?,
        embeddedProfilePresent: Bool
    ) -> NativeAgentAPNSEnvironment? {
        guard embeddedProfilePresent else { return .production }
        guard let embeddedProfileData,
              let entitlements = entitlements(in: embeddedProfileData),
              let rawValue = entitlements["aps-environment"] as? String,
              let environment = NativeAgentAPNSEnvironment(
                rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
              ) else {
            return nil
        }
        return environment
    }

    private static func entitlements(in profileData: Data) -> [String: Any]? {
        let xmlStart = Data("<?xml".utf8)
        let plistEnd = Data("</plist>".utf8)
        guard let startRange = profileData.range(of: xmlStart),
              let endRange = profileData.range(of: plistEnd, options: [], in: startRange.lowerBound..<profileData.endIndex) else {
            return nil
        }
        let plistData = profileData[startRange.lowerBound..<endRange.upperBound]
        guard let root = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
              let dictionary = root as? [String: Any] else {
            return nil
        }
        return dictionary["Entitlements"] as? [String: Any]
    }
}

/// UIKit requires the background-fetch completion callback exactly once. The
/// timeout and the normal async path race, so the gate is synchronized rather
/// than relying on either task being the first to return.
final class NativeAgentRemotePushCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var appliedData = false
    private let completionHandler: (UIBackgroundFetchResult) -> Void

    init(_ completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        self.completionHandler = completionHandler
    }

    func noteAppliedData() {
        lock.lock()
        appliedData = true
        lock.unlock()
    }

    func complete(_ result: UIBackgroundFetchResult) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let finalResult: UIBackgroundFetchResult = appliedData ? .newData : result
        lock.unlock()
        // UIKit requires the background-fetch completion callback on the main thread.
        if Thread.isMainThread {
            completionHandler(finalResult)
        } else {
            // UIKit hands this over from the main thread and only asks it back there.
            nonisolated(unsafe) let handler = completionHandler
            DispatchQueue.main.async { handler(finalResult) }
        }
    }
}

final class NativeAgentMobilePushDelegate: NSObject, UIApplicationDelegate {
    private static let backgroundPushDeadlineNanoseconds: UInt64 = 25_000_000_000
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let bundleId = Bundle.main.bundleIdentifier ?? "io.github.embwl0x.nativeagent.ios"
        guard let apnsEnvironment = NativeAgentAPNSEnvironmentResolver.current() else {
            NSLog("[NativeAgentMobile] APNS token sync skipped: signed aps-environment could not be resolved")
            return
        }
        let environment = apnsEnvironment.rawValue
        NSLog("[NativeAgentMobile] APNS token registered suffix=%@", String(token.suffix(8)))
        Task { @MainActor in
            guard let pairingStore = iCloudSyncEngine.shared.pairingStore,
                  pairingStore.iCloudPairingSecret != nil else {
                NSLog("[NativeAgentMobile] APNS token sync deferred until iCloud pairing")
                return
            }
            let deviceId = UIDevice.current.identifierForVendor?.uuidString
                ?? UIDevice.current.name
            let cache = NativeAgentPushTokenSyncCache()
            let pairing = NativeAgentPushTokenSyncCache.pairingIdentity(
                secret: pairingStore.iCloudPairingSecret,
                secretVersion: pairingStore.knownSecretVersion
            )
            let fingerprint = NativeAgentPushTokenSyncCache.fingerprint(
                token: token,
                environment: environment,
                bundleId: bundleId,
                deviceId: deviceId,
                pairing: pairing
            )
            do {
                if try !cache.shouldSync(fingerprint) {
                    NSLog("[NativeAgentMobile] APNS token sync skipped recently refreshed suffix=%@", String(token.suffix(8)))
                    return
                }
                _ = try await iCloudSyncEngine.shared.registerPushToken(
                    token: token,
                    environment: environment,
                    bundleId: bundleId,
                    deviceId: deviceId
                )
                try cache.markSynced(fingerprint)
                NSLog("[NativeAgentMobile] APNS token synced to Mac")
            } catch {
                iCloudSyncEngine.shared.syncError = "APNS token sync: \(error.localizedDescription)"
                NSLog("[NativeAgentMobile] APNS token sync failed: %@", error.localizedDescription)
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("[NativeAgentMobile] APNS registration failed: %@", error.localizedDescription)
        let detail = error.localizedDescription
        Task { @MainActor in iCloudSyncEngine.shared.syncError = "APNS registration failed: \(detail)" }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let completionGate = NativeAgentRemotePushCompletionGate(completionHandler)
        // Recovery and acknowledgement share one push deadline.
        let deadline = Date().addingTimeInterval(
            Double(Self.backgroundPushDeadlineNanoseconds) / 1_000_000_000
        )
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: Self.backgroundPushDeadlineNanoseconds)
            guard !Task.isCancelled else { return }
            completionGate.complete(.noData)
        }
        Task { @MainActor in
            await NADeviceSyncRecoveryBudget.$deadline.withValue(deadline) {
                await NADeviceSyncRecoveryBudget.$didApplyData.withValue({ completionGate.noteAppliedData() }) {
                    PushReceiptLedger.record(userInfo: userInfo)
                    PhoneSenses.shared.wake()
                    if NADeviceSyncRecoveryBudget.hasTime,
                       await iCloudBridge.shared.drainIfDeviceSyncPush(userInfo) {
                        completionGate.noteAppliedData()
                    }
                    // Activity publishes Inbox independently and reports its acceptance to the gate.
                    if NADeviceSyncRecoveryBudget.hasTime {
                        _ = await withCKTimeout("NativeAgentMobile.push.activitySnapshot", seconds: max(0, deadline.timeIntervalSinceNow)) {
                            guard deadline.timeIntervalSinceNow > 0 else { return }
                            await NADeviceSyncRecoveryBudget.$deadline.withValue(deadline) {
                                await NADeviceSyncRecoveryBudget.$didApplyData.withValue({ completionGate.noteAppliedData() }) {
                                    _ = await iCloudSyncEngine.shared.refreshActivitySnapshot()
                                }
                            }
                        }
                    }
                }
            }
            timeoutTask.cancel()
            completionGate.complete(.noData)
        }
    }
}

final class NativeAgentNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    // UIKit notification completion handlers must run on the main thread.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // The visible conversation owns its reply, even if its chat record
        // arrives after this notification. Other conversations keep their alert.
        let keys = ChatReplyNotificationKeys(userInfo: notification.request.content.userInfo)
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            let visible = ChatReplyNotificationPresentation.ownsVisibleConversation(keys: keys)
            done(visible ? [] : NativeAgentNotificationDelegatePresentation.foregroundPresentationOptions)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        nonisolated(unsafe) let done = completionHandler
        let action = MobileNotificationActions.Response(response)
        if action.isAction {
            Task { @MainActor in
                Task { await MobileNotificationActions.handle(action) }
                done()
            }
            return
        }
        guard NativeAgentNotificationDelegatePresentation.shouldRouteUserResponse(
            actionIdentifier: response.actionIdentifier
        ) else {
            DispatchQueue.main.async { done() }
            return
        }
        let userInfo = response.notification.request.content.userInfo
        let screen = NativeAgentRemoteNotificationPayload.string(
            directKey: "screen",
            cloudKitRecordKey: "notificationScreen",
            in: userInfo
        )
        let sessionID = NativeAgentRemoteNotificationPayload.string(
            directKey: "sessionId",
            cloudKitRecordKey: "notificationSessionId",
            in: userInfo
        )
        let taskID = NativeAgentRemoteNotificationPayload.string(
            directKey: "taskId", cloudKitRecordKey: "notificationTaskId", in: userInfo
        )
        DispatchQueue.main.async {
            // Persist before posting. ContentView consumes this intent from
            // UserDefaults on appearance, so a cold-launch view tree that has
            // not installed its ephemeral observer yet still receives the tap.
            NativeAgentNotificationLaunchIntent.stage(screen: screen, sessionID: sessionID, taskID: taskID)
            NotificationCenter.default.post(name: .nativeagentOpenActivity, object: nil)
            done()
        }
    }
}

enum NativeAgentNotificationDelegatePresentation {
    static let foregroundPresentationOptions: UNNotificationPresentationOptions = [
        .banner, .list, .sound, .badge,
    ]

    /// Only a notification tap is navigation intent. A system dismiss is not a
    /// request to reopen the app, and an unknown action must not guess a route.
    static func shouldRouteUserResponse(actionIdentifier: String) -> Bool {
        actionIdentifier == UNNotificationDefaultActionIdentifier
    }
}

enum NativeAgentNotificationEventGate {
    static func requireAuthorization(center: UNUserNotificationCenter) async throws {
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        guard granted else {
            throw SyncError.persistence("iPhone notifications are not allowed. Enable NativeAgent notifications in iPhone Settings, then refresh.")
        }
    }

    static func add(
        content: UNNotificationContent,
        eventID: String,
        trigger: UNNotificationTrigger?,
        center: UNUserNotificationCenter = .current()
    ) async throws -> Bool {
        // Avoid reposting an already pending or delivered local event.
        // Remote/local route selection happens before this gate.
        // UserNotifications reference types are not Sendable. Keep the center
        // and returned request objects on this task instead of moving them into
        // `async let` child tasks. These reads are local and bounded, and the
        // second read still observes at least as fresh a notification snapshot.
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let existingRequests = pending + delivered.map(\.request)
        if existingRequests.contains(where: { request in
            NativeAgentRemoteNotificationPayload.matches(request, eventID: eventID)
        }) {
            return false
        }
        let categorized = try MobileNotificationRouting.categorized(content)
        let alert = try await CommunicationNotification.decorate(categorized)
        try await center.add(UNNotificationRequest(
            identifier: eventID,
            content: alert,
            trigger: trigger
        ))
        return true
    }

    static func eventID(in userInfo: [AnyHashable: Any]) -> String? {
        NativeAgentRemoteNotificationPayload.eventID(in: userInfo)
    }
}

enum NativeAgentBridgeNotificationScheduler {
    static func schedule(_ msg: BridgeMessage) async -> Bool {
        let metadata = msg.metadata ?? [:]
        guard let title = nonEmpty(metadata["title"]), let body = nonEmpty(metadata["body"]) else {
            await reportFailure("The Mac's notification has no title or body. Refresh Activity on the Mac to repair its notification publication.")
            return false
        }
        var userInfo: [String: Any] = [:]
        for (key, value) in metadata where key.hasPrefix("userInfo.") {
            let cleanKey = String(key.dropFirst("userInfo.".count))
            guard !cleanKey.isEmpty else { continue }
            userInfo[cleanKey] = value
        }
        if userInfo["screen"] == nil {
            userInfo["screen"] = "activity"
        }
        guard let eventID = userInfo["eventId"] as? String,
              NativeAgentDeviceEventIdentity.isCanonical(eventID) else {
            await reportFailure("The Mac's notification has no canonical event identity. Refresh Activity on the Mac to repair its notification publication.")
            return false
        }
        userInfo["messageId"] = msg.id
        userInfo["source"] = userInfo["source"] ?? "mac_icloud_bridge"

        // Ordinary notifications render through CloudKit's visible subscription.
        // Their signed record acknowledges receipt, regardless of transport
        // outcome, never posting a local alert. Requested results own that renderer.
        if userInfo["source"] as? String != "requested_result" {
            await iCloudSyncEngine.shared.sendNotificationReceipt(eventID: eventID, channel: "icloud_bridge_record")
            return true
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                guard try await center.requestAuthorization(options: [.alert, .badge, .sound]) else {
                    await reportFailure("iPhone notifications are not allowed. Enable notifications for NativeAgent in iPhone Settings to receive this retained alert.")
                    return false
                }
            } catch {
                await reportFailure("iPhone notification permission could not be requested: \(error.localizedDescription). Check Notifications in iPhone Settings.")
                return false
            }
        } else if settings.authorizationStatus == .denied {
            await reportFailure("iPhone notifications are disabled. Enable notifications for NativeAgent in iPhone Settings to receive this retained alert.")
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        // Urgent bridge notifications use time-sensitive interruption, matching APNS.
        if (metadata["urgency"] ?? (userInfo["urgency"] as? String))?.lowercased() == "urgent" {
            content.interruptionLevel = .timeSensitive
        }

        do {
            let added = try await NativeAgentNotificationEventGate.add(
                content: content,
                eventID: eventID,
                trigger: nil,
                center: center
            )
            NSLog("[NativeAgentMobile] bridge notification %@ event=%@ msg=%@",
                  added ? "scheduled" : "deduplicated", eventID, msg.id)
            await iCloudSyncEngine.shared.sendNotificationReceipt(
                eventID: eventID,
                channel: "icloud_bridge"
            )
            return true
        } catch {
            NSLog("[NativeAgentMobile] bridge notification failed id=%@: %@", msg.id, error.localizedDescription)
            await reportFailure("The iPhone could not prepare this notification: \(error.localizedDescription). Check Notifications in iPhone Settings, then refresh Activity.")
            return false
        }
    }

    private static func reportFailure(_ message: String) async {
        await MainActor.run { iCloudSyncEngine.shared.syncError = message }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
