import SwiftUI
import CryptoKit
import UserNotifications
import UIKit
import NativeAgentShared
#if canImport(CloudKit)
import CloudKit
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
    static let registrationRefreshInterval: TimeInterval = 30 * 24 * 60 * 60
    static let tokenSyncRefreshInterval: TimeInterval = 10 * 60

    var defaults: UserDefaults = .standard

    func load() -> Record? {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    func hasFreshSyncedRegistration(
        pairing: PairingIdentity,
        now: Date = Date(),
        refreshInterval: TimeInterval = Self.registrationRefreshInterval
    ) -> Bool {
        guard let record = load(), record.fingerprint.pairing == pairing else { return false }
        guard now.timeIntervalSince(record.registeredAt) >= 0,
              now.timeIntervalSince(record.syncedAt) >= 0 else {
            return false
        }
        return now.timeIntervalSince(record.registeredAt) < refreshInterval
            && now.timeIntervalSince(record.syncedAt) < refreshInterval
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

struct NativeAgentAPNSEnvironmentResolution: Equatable {
    enum Source: Equatable {
        case embeddedProvisioningProfile
        case distributionWithoutEmbeddedProfile
    }

    var environment: NativeAgentAPNSEnvironment
    var source: Source
}

enum NativeAgentAPNSEnvironmentResolver {
    static func current(bundle: Bundle = .main) -> NativeAgentAPNSEnvironmentResolution? {
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
    ) -> NativeAgentAPNSEnvironmentResolution? {
        guard embeddedProfilePresent else {
            return NativeAgentAPNSEnvironmentResolution(
                environment: .production,
                source: .distributionWithoutEmbeddedProfile
            )
        }
        guard let embeddedProfileData,
              let entitlements = entitlements(in: embeddedProfileData),
              let rawValue = entitlements["aps-environment"] as? String,
              let environment = NativeAgentAPNSEnvironment(
                rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
              ) else {
            return nil
        }
        return NativeAgentAPNSEnvironmentResolution(
            environment: environment,
            source: .embeddedProvisioningProfile
        )
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

/// The remote-push fetch contract is deliberately separate from UIKit so the
/// completion result stays truthful under every transport outcome. Reporting
/// `.noData` after a successful inbox load or CloudKit drain causes iOS to
/// throttle later background wakes.
@MainActor
enum NativeAgentRemotePushProcessor {
    enum FetchOutcome: Equatable {
        case newData
        case noData

        var backgroundFetchResult: UIBackgroundFetchResult {
            switch self {
            case .newData: .newData
            case .noData: .noData
            }
        }
    }

    static func process(
        userInfo: [AnyHashable: Any],
        recordReceipt: ([AnyHashable: Any]) -> PushReceiptEntry,
        sendReceipt: (String) async throws -> Void,
        drainDeviceSyncPush: @MainActor @Sendable ([AnyHashable: Any]) async throws -> Bool,
        refreshChatReply: () async throws -> Bool = { false },
        refreshInbox: () async throws -> Bool,
        refreshActivity: () async throws -> Void
    ) async -> FetchOutcome {
        let pushReceipt = recordReceipt(userInfo)

        // Each lane is independently best-effort. A failed CloudKit drain
        // must not suppress the inbox/activity refreshes (and vice versa).
        let cloudKitDelivered = NADeviceSyncRecoveryBudget.hasTime
            ? ((try? await drainDeviceSyncPush(userInfo)) ?? false) : false
        if cloudKitDelivered { NADeviceSyncRecoveryBudget.didApplyData?() }
        // The Mac's visible reply notification is an ordinary APNS payload,
        // not the CloudKit subscription push recognized above. Treat its exact
        // source as a bounded transport nudge so an open Chat view receives the
        // signed reply record immediately instead of showing only the banner.
        let chatReplyLoaded = NADeviceSyncRecoveryBudget.hasTime && isChatReplyNudge(userInfo)
            ? ((try? await refreshChatReply()) ?? false)
            : false
        if chatReplyLoaded { NADeviceSyncRecoveryBudget.didApplyData?() }
        let inboxLoaded = NADeviceSyncRecoveryBudget.hasTime
            ? ((try? await refreshInbox()) ?? false) : false
        if inboxLoaded { NADeviceSyncRecoveryBudget.didApplyData?() }
        if NADeviceSyncRecoveryBudget.hasTime { try? await refreshActivity() }
        // 2026-09-06: the receipt used to be sent BEFORE any of the lanes above.
        // Its send can wait the full 30 s the iCloud action write allows, while
        // the background-push callback has to report at 25 s — so a missed reply
        // was never recovered on the very push that announced it. Recovery runs
        // first now; the acknowledgement takes whatever budget is left.
        if NADeviceSyncRecoveryBudget.hasTime, let eventID = pushReceipt.eventId {
            try? await sendReceipt(eventID)
        }
        return (inboxLoaded || cloudKitDelivered || chatReplyLoaded) ? .newData : .noData
    }

    static func isChatReplyNudge(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["source"] as? String) == "icloud_chat_reply"
            && (userInfo["screen"] as? String) == "chat"
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
        completionHandler(finalResult)
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
        guard let apnsResolution = NativeAgentAPNSEnvironmentResolver.current() else {
            NSLog("[NativeAgentMobile] APNS token sync skipped: signed aps-environment could not be resolved")
            return
        }
        let environment = apnsResolution.environment.rawValue
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
        // 2026-09-06: the wall clock the whole push has to finish inside. The
        // receipt lane races it so an acknowledgement can never eat the budget
        // the reply-recovery lanes need.
        let deadline = Date().addingTimeInterval(
            Double(Self.backgroundPushDeadlineNanoseconds) / 1_000_000_000
        )
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: Self.backgroundPushDeadlineNanoseconds)
            guard !Task.isCancelled else { return }
            completionGate.complete(.noData)
        }
        Task { @MainActor in
            // CK-3c: if this is a CloudKit silent push for our device-sync
            // subscription AND CloudKit is active, drain the transport. Both
            // guards live inside drainIfDeviceSyncPush; a flag-off build returns
            // immediately without parsing. Every other push — and the legacy
            // snapshot refresh below — is untouched.
            let outcome = await NADeviceSyncRecoveryBudget.$deadline.withValue(deadline) {
                await NADeviceSyncRecoveryBudget.$didApplyData.withValue({ completionGate.noteAppliedData() }) {
                    await NativeAgentRemotePushProcessor.process(
                userInfo: userInfo,
                // 2026-07-04: ledger every arrival so delivered-but-silenced
                // (Focus, Scheduled Summary) is distinguishable from never
                // delivered.
                recordReceipt: PushReceiptLedger.record(userInfo:),
                sendReceipt: { eventID in
                    let remaining = deadline.timeIntervalSinceNow - 1
                    guard remaining > 0 else { return }
                    _ = await withCKTimeout(
                        "NativeAgentMobile.push.notificationReceipt",
                        seconds: remaining
                    ) {
                        await iCloudSyncEngine.shared.sendNotificationReceipt(
                            eventID: eventID,
                            channel: "apns"
                        )
                    }
                },
                drainDeviceSyncPush: { userInfo in
                    await iCloudBridge.shared.drainIfDeviceSyncPush(userInfo)
                },
                refreshChatReply: {
                    let delivered = await iCloudBridge.shared.pollIncomingNow()
                    if delivered { completionGate.noteAppliedData() }
                    // The transport record is primary. The transcript snapshot
                    // is the independent missed-record backstop and publishes
                    // through ChatView's existing snapshot merge owner.
                    if NADeviceSyncRecoveryBudget.hasTime {
                        _ = await withCKTimeout("NativeAgentMobile.push.chatSnapshot", seconds: max(0, deadline.timeIntervalSinceNow)) {
                            guard deadline.timeIntervalSinceNow > 0 else { return }
                            await iCloudSyncEngine.shared.refreshChatTranscriptsSnapshot()
                        }
                    }
                    return delivered
                },
                refreshInbox: {
                    await withCKTimeout("NativeAgentMobile.push.inboxSnapshot", seconds: max(0, deadline.timeIntervalSinceNow)) {
                        guard deadline.timeIntervalSinceNow > 0 else { return false }
                        let loaded = await iCloudSyncEngine.shared.refreshInboxSnapshot()
                        if loaded { completionGate.noteAppliedData() }
                        return loaded
                    } ?? false
                },
                refreshActivity: {
                    _ = await withCKTimeout("NativeAgentMobile.push.activitySnapshot", seconds: max(0, deadline.timeIntervalSinceNow)) {
                        guard deadline.timeIntervalSinceNow > 0 else { return }
                        await iCloudSyncEngine.shared.refreshActivitySnapshot()
                    }
                }
            )
                }
            }
            timeoutTask.cancel()
            completionGate.complete(outcome.backgroundFetchResult)
        }
    }
}

final class NativeAgentNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // 2026-09-06: the reply this alert announces may already be rendered in
        // the chat the user is looking at. Alerting on top of it is noise.
        let keys = ChatReplyNotificationKeys(userInfo: notification.request.content.userInfo)
        if await ChatReplyNotificationPresentation.isAlreadyDisplayed(keys: keys) {
            return []
        }
        return NativeAgentNotificationDelegatePresentation.foregroundPresentationOptions
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard NativeAgentNotificationDelegatePresentation.shouldRouteUserResponse(
            actionIdentifier: response.actionIdentifier
        ) else { return }
        // F7: route per notification payload's `screen` field instead of always
        // landing on Activity. Allowed values: activity, chat, memories, desk, skills, more.
        let userInfo = response.notification.request.content.userInfo
        let screen = NativeAgentRemoteNotificationPayload.string(
            directKey: "screen",
            cloudKitRecordKey: "notificationScreen",
            in: userInfo
        )
        // 2026-09-06: a reply notification names the conversation that answered.
        // Routing on `screen` alone landed the tap on whichever chat was already
        // selected, which is not the one the user tapped.
        let sessionID = NativeAgentRemoteNotificationPayload.string(
            directKey: "sessionId",
            cloudKitRecordKey: "notificationSessionId",
            in: userInfo
        )
        await MainActor.run {
            // Persist before posting. ContentView consumes this intent from
            // UserDefaults on appearance, so a cold-launch view tree that has
            // not installed its ephemeral observer yet still receives the tap.
            MobileNotifiedChatSessionIntent.stage(screen == "chat" ? sessionID : nil)
            NativeAgentNotificationLaunchIntent.markOpenActivityPending(screen: screen)
            NotificationCenter.default.post(
                name: .nativeagentOpenActivity,
                object: nil,
                userInfo: ["screen": screen ?? "activity"]
            )
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

enum NativeAgentRemoteNotificationPayload {
    static func string(
        directKey: String,
        cloudKitRecordKey: String,
        in userInfo: [AnyHashable: Any]
    ) -> String? {
        if let direct = nonEmpty(userInfo[directKey] as? String) {
            return direct
        }
        #if canImport(CloudKit)
        if let query = CKNotification(
            fromRemoteNotificationDictionary: userInfo
        ) as? CKQueryNotification,
           let value = nonEmpty(query.recordFields?[cloudKitRecordKey] as? String) {
            return value
        }
        #endif
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

enum NativeAgentNotificationEventGate {
    static func add(
        content: UNNotificationContent,
        eventID: String,
        trigger: UNNotificationTrigger?,
        center: UNUserNotificationCenter = .current()
    ) async throws -> Bool {
        let identifier = "nativeagent.event.\(eventID)"
        // UserNotifications reference types are not Sendable. Keep the center
        // and returned request objects on this task instead of moving them into
        // `async let` child tasks. These reads are local and bounded, and the
        // second read still observes at least as fresh a notification snapshot.
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let existingRequests = pending + delivered.map(\.request)
        if existingRequests.contains(where: { request in
            request.identifier == identifier
                || Self.eventID(in: request.content.userInfo) == eventID
        }) {
            return false
        }
        try await center.add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        ))
        return true
    }

    static func eventID(in userInfo: [AnyHashable: Any]) -> String? {
        let direct = NativeAgentRemoteNotificationPayload.string(
            directKey: "eventId",
            cloudKitRecordKey: "notificationEventId",
            in: userInfo
        )
        let nested = (userInfo["nativeagent"] as? [String: Any])?["eventId"] as? String
        return [direct, nested]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { NativeAgentDeviceEventIdentity.isCanonical($0) }
    }
}

enum NativeAgentBridgeNotificationScheduler {
    static func schedule(_ msg: BridgeMessage) {
        Task {
            let metadata = msg.metadata ?? [:]
            let title = nonEmpty(metadata["title"]) ?? "NativeAgent"
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
            // 2026-07-04 (review): the iCloud-bridge fallback lane must match the
            // APNS lane — urgent pushes are time-sensitive so Focus (e.g. Sleep at
            // 3:30am dream time) shows them on the lock screen instead of
            // silencing them into Notification Center.
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
            } catch {
                NSLog("[NativeAgentMobile] bridge notification failed id=%@: %@", msg.id, error.localizedDescription)
            }
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
