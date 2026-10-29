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

    func load() -> Record? {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    func shouldSync(
        _ fingerprint: Fingerprint,
        now: Date = Date(),
        refreshInterval: TimeInterval = Self.tokenSyncRefreshInterval
    ) -> Bool {
        guard let record = load() else { return true }
        guard record.fingerprint == fingerprint else { return true }
        guard now.timeIntervalSince(record.syncedAt) >= 0 else { return true }
        return now.timeIntervalSince(record.syncedAt) >= refreshInterval
    }

    func markSynced(_ fingerprint: Fingerprint, now: Date = Date()) {
        let record = Record(fingerprint: fingerprint, registeredAt: now, syncedAt: now)
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
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
            if !cache.shouldSync(fingerprint) {
                NSLog("[NativeAgentMobile] APNS token sync skipped recently refreshed suffix=%@", String(token.suffix(8)))
                return
            }
            do {
                _ = try await iCloudSyncEngine.shared.registerPushToken(
                    token: token,
                    environment: environment,
                    bundleId: bundleId,
                    deviceId: deviceId
                )
                cache.markSynced(fingerprint)
                NSLog("[NativeAgentMobile] APNS token synced to Mac")
            } catch {
                NSLog("[NativeAgentMobile] APNS token sync failed: %@", error.localizedDescription)
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("[NativeAgentMobile] APNS registration failed: %@", error.localizedDescription)
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
                    let receipt = PushReceiptLedger.record(userInfo: userInfo)
                    if NADeviceSyncRecoveryBudget.hasTime,
                       await iCloudBridge.shared.drainIfDeviceSyncPush(userInfo) {
                        completionGate.noteAppliedData()
                    }
                    // Visible reply pushes nudge signed transport and its transcript backstop.
                    if NADeviceSyncRecoveryBudget.hasTime,
                       ["icloud_chat_reply", "requested_result"].contains(userInfo["source"] as? String ?? ""),
                       (userInfo["screen"] as? String) == "chat" {
                        if await iCloudBridge.shared.pollIncomingNow() { completionGate.noteAppliedData() }
                        if NADeviceSyncRecoveryBudget.hasTime {
                            _ = await withCKTimeout("NativeAgentMobile.push.chatSnapshot", seconds: max(0, deadline.timeIntervalSinceNow)) {
                                guard deadline.timeIntervalSinceNow > 0 else { return }
                                await iCloudSyncEngine.shared.refreshChatTranscriptsSnapshot()
                            }
                        }
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
                    if NADeviceSyncRecoveryBudget.hasTime, let eventID = receipt.eventId {
                        let remaining = deadline.timeIntervalSinceNow - 1
                        guard remaining > 0 else { return }
                        _ = await withCKTimeout("NativeAgentMobile.push.notificationReceipt", seconds: remaining) {
                            await iCloudSyncEngine.shared.sendNotificationReceipt(eventID: eventID, channel: "apns")
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
        // Suppress the alert when its reply is already displayed in the current chat.
        let keys = ChatReplyNotificationKeys(userInfo: notification.request.content.userInfo)
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            let shown = ChatReplyNotificationPresentation.isAlreadyDisplayed(keys: keys)
            done(shown ? [] : NativeAgentNotificationDelegatePresentation.foregroundPresentationOptions)
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
        let alert: UNNotificationContent
        do { alert = try await CommunicationNotification.decorate(categorized) }
        catch {
            NSLog("[NativeAgentMobile] Communication notification unavailable: %@", error.localizedDescription)
            alert = categorized
        }
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
        let deviceID = await MainActor.run {
            UIDevice.current.identifierForVendor?.uuidString ?? UIDevice.current.name
        }
        let acceptedDeviceIDs = metadata["directAlertDeviceIDs"].flatMap {
            try? JSONDecoder().decode([String].self, from: Data($0.utf8))
        } ?? []
        guard !acceptedDeviceIDs.contains(deviceID) else { return true }
        let agentName = await MainActor.run { iCloudSyncEngine.shared.agentDisplayName }
        let title = nonEmpty(metadata["title"]) ?? agentName
        let body = nonEmpty(metadata["body"])
            ?? nonEmpty(msg.text)
            ?? "New activity from Mac."
        var userInfo: [String: Any] = [:]
        for (key, value) in metadata where key.hasPrefix("userInfo.") {
            let cleanKey = String(key.dropFirst("userInfo.".count))
            guard !cleanKey.isEmpty else { continue }
            userInfo[cleanKey] = value
        }
        if userInfo["screen"] == nil {
            userInfo["screen"] = "activity"
        }
        let eventInfo = userInfo.compactMapValues { $0 as? String }
        let eventID = NativeAgentDeviceEventIdentity.notification(
            userInfo: eventInfo,
            fallback: msg.id
        )
        userInfo["eventId"] = eventID
        userInfo["messageId"] = msg.id
        userInfo["source"] = userInfo["source"] ?? "mac_icloud_bridge"

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
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
            return false
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
