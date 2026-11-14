import SwiftUI
import CryptoKit
import UserNotifications
import UIKit
import NativeAgentShared
#if canImport(CloudKit)
import CloudKit
// Blueprint: | `MobilePushNotifications.swift` | `NativeAgentPushTokenSyncCache` struct; `load`, `shouldSync` |
#endif

struct NativeAgentPushTokenSyncCache {
    struct PairingIdentity: Codable, Equatable, Sendable {
        var secretHash: String?
        var secretVersion: Int64
    }

    struct Fingerprint: Codable, Equatable, Sendable {
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
    var defaults: UserDefaults = .standard

    func load() throws -> Record? {
        guard let stored = defaults.object(forKey: Self.defaultsKey) else { return nil }
        guard let data = stored as? Data else {
            throw SyncError.persistence(
                """
                    The saved APNS registration cache is not data. Repair NativeAgentMobile.lastSyncedAPNSToken in the phone's \
                    preferences; its value is retained.
                    """)
        }
        return try JSONDecoder().decode(Record.self, from: data)
    }

    func shouldSync(_ fingerprint: Fingerprint) throws -> Bool {
        guard let record = try load() else { return true }
        return record.fingerprint != fingerprint
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

enum NativeAgentAPNSEnvironment: String, Equatable, Sendable {
    case development
    case production
}

enum NativeAgentAPNSEnvironmentResolver {
    static func current(bundle: Bundle = .main) -> NativeAgentAPNSEnvironment? {
        guard let profileURL = bundle.url(forResource: "embedded", withExtension: "mobileprovision") else {
            // App Store/TestFlight installs lack embedded profiles; their APNS tokens require production.
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

/// UIKit completion belongs to one recovery owner, including OS withdrawal of background execution.
@MainActor
final class NativeAgentRemotePushCompletionGate {
    private var completed = false
    private var appliedData = false
    private let completionHandler: (UIBackgroundFetchResult) -> Void

    init(_ completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        self.completionHandler = completionHandler
    }

    func noteAppliedData() { appliedData = true }

    func complete(_ result: UIBackgroundFetchResult) {
        guard !completed else { return }
        completed = true
        completionHandler(appliedData ? .newData : result)
    }
}

@MainActor
private final class NativeAgentPushRecovery {
    private let application: UIApplication
    private let completion: NativeAgentRemotePushCompletionGate
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var task: Task<Void, Never>?

    init(application: UIApplication, completion: NativeAgentRemotePushCompletionGate) {
        self.application = application
        self.completion = completion
    }

    func start(userInfo: [AnyHashable: Any]) {
        backgroundTask = application.beginBackgroundTask(
            withName: "NativeAgent push recovery", expirationHandler: Self.expirationHandler(for: self))
        guard backgroundTask != .invalid else {
            completion.complete(.noData)
            return
        }
        task = Task {
            let recovery = DeviceSyncRecovery(didApplyData: { [completion] in
                Task { @MainActor in completion.noteAppliedData() }
            })
            PushReceiptLedger.record(userInfo: userInfo)
            PhoneSenses.shared.wake()
            if recovery.isActive, await iCloudBridge.shared.drainIfDeviceSyncPush(userInfo, recovery: recovery) {
                completion.noteAppliedData()
            }
            if recovery.isActive { _ = await iCloudSyncEngine.shared.refreshActivitySnapshot(recovery: recovery) }
            completion.complete(.noData)
            endBackgroundExecution()
            task = nil
        }
    }

    private func expire() {
        task?.cancel()
        completion.complete(.noData)
        endBackgroundExecution()
    }

    private nonisolated static func expirationHandler(for owner: NativeAgentPushRecovery) -> @Sendable () -> Void {
        { [weak owner] in Task { @MainActor in owner?.expire() } }
    }

    private func endBackgroundExecution() {
        guard backgroundTask != .invalid else { return }
        application.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

final class NativeAgentMobilePushDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let bundleId = Bundle.main.bundleIdentifier ?? "io.github.embwl0x.nativeagent.ios"
        NSLog("[NativeAgentMobile] APNS token registered suffix=%@", String(token.suffix(8)))
        Task { @MainActor in
            guard let apnsEnvironment = await Task.detached(operation: { NativeAgentAPNSEnvironmentResolver.current() }).value else {
                iCloudSyncEngine.shared.syncError = "The signed APNS environment could not be read. Install the current signed iPhone app."
                return
            }
            let environment = apnsEnvironment.rawValue
            guard let pairingStore = iCloudSyncEngine.shared.pairingStore,
                  pairingStore.iCloudPairingSecret != nil else {
                NSLog("[NativeAgentMobile] APNS token sync deferred until iCloud pairing")
                return
            }
            let deviceId = UIDevice.current.identifierForVendor?.uuidString
                ?? UIDevice.current.name
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
                let needsSync = try await Task.detached { try NativeAgentPushTokenSyncCache().shouldSync(fingerprint) }.value
                if !needsSync {
                    return
                }
                _ = try await iCloudSyncEngine.shared.registerPushToken(
                    token: token,
                    environment: environment,
                    bundleId: bundleId,
                    deviceId: deviceId
                )
                try await Task.detached { try NativeAgentPushTokenSyncCache().markSynced(fingerprint) }.value
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
        let completion = NativeAgentRemotePushCompletionGate(completionHandler)
        NativeAgentPushRecovery(application: application, completion: completion).start(userInfo: userInfo)
    }
}

final class NativeAgentNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    // UIKit notification completion handlers must run on the main thread.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Visible conversations suppress their own alerts even before chat records arrive; other conversations retain alerts.
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
            // Persist before posting navigation so cold-launch views cannot miss a tap before their observer attaches.
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

    /// Only taps authorize navigation; dismissals and unknown actions must not guess a destination.
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
        // Check pending/delivered alerts to avoid duplicates. Keep non-Sendable UserNotifications objects in this task rather than async-let children.
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

        // CloudKit renders ordinary alerts; signed receipt acknowledgment must not post a duplicate local notification.
        if userInfo["source"] as? String != "requested_result" {
            await iCloudSyncEngine.shared.sendNotificationReceipt(eventID: eventID, channel: "icloud_bridge_record")
            return true
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                guard try await center.requestAuthorization(options: [.alert, .badge, .sound]) else {
                    await reportFailure(
                        "iPhone notifications are not allowed. Enable notifications for NativeAgent in iPhone Settings to receive this retained alert.")
                    return false
                }
            } catch {
                await reportFailure(
                    "iPhone notification permission could not be requested: \(error.localizedDescription). Check Notifications in iPhone Settings.")
                return false
            }
        } else if settings.authorizationStatus == .denied {
            await reportFailure("iPhone notifications are disabled. Enable notifications for NativeAgent in iPhone Settings to receive this retained alert.")
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle = nonEmpty(metadata["subtitle"]) { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
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
            await reportFailure(
                "The iPhone could not prepare this notification: \(error.localizedDescription). Check Notifications in iPhone Settings, then refresh Activity.")
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
