// PATCH-2026-05-07: icloud-bridge app entry — iCloud-first transport wiring
import SwiftUI
import AppIntents
import CryptoKit
import UserNotifications
import UIKit
import NativeAgentShared
#if canImport(CloudKit)
import CloudKit
#endif

extension Notification.Name {
    /// Internal simulator/test hook. No public URL scheme can post this event;
    /// only explicit process launch arguments reach it.
    static let nativeagentDeepLinkSend = Notification.Name("nativeagent.chat.send")
    static let nativeagentOpenActivity = Notification.Name("nativeagent.open.activity")
}

enum NativeAgentNotificationLaunchIntent {
    private static let openActivityKey = "NativeAgentMobile.pendingOpenActivityFromNotification"
    private static let pendingScreenKey = "NativeAgentMobile.pendingNotificationScreen"

    /// Allowed screen values that route to a top-level tab.
    static let allowedScreens: Set<String> = [
        "activity", "approvals", "inbox", "chat", "memories", "skills", "more",
        "mac_integration", "macintegration", "mac-integration",
    ]

    static var hasPendingOpenActivity: Bool {
        UserDefaults.standard.bool(forKey: openActivityKey)
    }

    /// F7: returns whichever screen the notification asked for, or nil if no
    /// pending notification launch.  Defaults to "activity" when a launch is
    /// queued but no screen field was set.
    static var pendingScreen: String? {
        guard UserDefaults.standard.bool(forKey: openActivityKey) else { return nil }
        let raw = UserDefaults.standard.string(forKey: pendingScreenKey)?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, allowedScreens.contains(raw) { return raw }
        return "activity"
    }

    static func markOpenActivityPending(screen: String? = nil) {
        UserDefaults.standard.set(true, forKey: openActivityKey)
        let cleaned = screen?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleaned, allowedScreens.contains(cleaned) {
            UserDefaults.standard.set(cleaned, forKey: pendingScreenKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pendingScreenKey)
        }
    }

    static func consumeOpenActivityPending() -> Bool {
        guard UserDefaults.standard.bool(forKey: openActivityKey) else { return false }
        UserDefaults.standard.removeObject(forKey: openActivityKey)
        UserDefaults.standard.removeObject(forKey: pendingScreenKey)
        return true
    }

    /// F7: returns the screen requested (defaulting to "activity") and clears
    /// the pending flag in one step.
    static func consumePendingScreen() -> String? {
        guard let screen = pendingScreen else { return nil }
        UserDefaults.standard.removeObject(forKey: openActivityKey)
        UserDefaults.standard.removeObject(forKey: pendingScreenKey)
        return screen
    }
}

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

@main
struct NativeAgentMobileApp: App {
    @UIApplicationDelegateAdaptor(NativeAgentMobilePushDelegate.self) private var pushDelegate
    @StateObject private var pairingStore = PairingStore()
    @StateObject private var bridgeClient = MacBridgeClient()
    @StateObject private var voiceInput = VoiceInputController()
    @StateObject private var voiceOutput = VoiceOutputController()
    private let notificationDelegate = NativeAgentNotificationDelegate()
    @State private var bridgeNotificationObserverID: UUID?
    /// Fix-A: persisted flag so users can skip the pairing screen and return later.
    @AppStorage("NativeAgentMobile.pairingSkipped") private var pairingSkipped = false
    @AppStorage(NativeAgentAppearance.storageKey) private var appearanceRawValue = NativeAgentAppearance.system.rawValue

    init() {
        ChatRuntimeControls.primeDeviceSourceKey()
    }

    /// True when the user has either paired OR explicitly skipped the pairing screen.
    private var shouldShowMainApp: Bool {
        pairingStore.isPaired || pairingSkipped
    }

    // 2026-07-04 foreground-refresh fix: opening the app previously showed
    // whatever data the last poll tick left behind (new inbox cards written by
    // the Mac overnight didn't appear until a tab's 30s loop fired — or, with
    // the stale-replica read bug, until a full relaunch). Kick the shared
    // snapshot refresh the moment the scene becomes active.
    @Environment(\.scenePhase) private var scenePhase

    private func refreshOnForeground() {
        guard pairingStore.usesICloudTransport else { return }
        Task { @MainActor in
            await iCloudSyncEngine.shared.refreshActivitySnapshot()
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if shouldShowMainApp {
                    ContentView()
                        .environmentObject(pairingStore)
                        .environmentObject(bridgeClient)
                        .environmentObject(voiceInput)
                        .environmentObject(voiceOutput)
                        .onAppear {
                            configureNotifications()
                            configureTransport()
                            checkLaunchArgsForTestSend()
                            checkLaunchArgsForTestNotification()
                            checkLaunchArgsForPairingSecret()
                        }
                        .onChange(of: pairingStore.isICloudPaired) { _, _ in
                            configureTransport()
                            configureNotifications()
                        }
                        .onChange(of: pairingStore.iCloudPairingSecret) { _, _ in
                            configureTransport()
                            configureNotifications()
                        }
                        // 2026-07-04 foreground-refresh fix (see refreshOnForeground).
                        .onChange(of: scenePhase) { _, newPhase in
                            if newPhase == .active { refreshOnForeground() }
                        }
                } else {
                    PairingView(onSkip: {
                        // Fix-A: user tapped Skip — persist the flag and show the main app.
                        // Does NOT clear any existing pairing credentials.
                        pairingSkipped = true
                    }, onPaired: {
                        pairingSkipped = false
                        configureTransport()
                    })
                    .environmentObject(pairingStore)
                    .onAppear {
                        // Fresh-install pairing starts iCloudBridge from
                        // PairingView before configureTransport() can run. Bind
                        // both canonical consumers first so an immediately
                        // drained CloudKit pairing record can commit through
                        // PairingStore instead of being held forever.
                        iCloudSyncEngine.shared.pairingStore = pairingStore
                        iCloudBridge.shared.pairingStore = pairingStore
                        checkLaunchArgsForPairingSecret()
                    }
                }
            }
            .preferredColorScheme(NativeAgentAppearance.resolved(appearanceRawValue).colorScheme)
        }
    }

    private func configureNotifications() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        iCloudSyncEngine.shared.pairingStore = pairingStore

        guard pairingStore.usesICloudTransport else {
            NSLog("[NativeAgentMobile] notification registration deferred until iCloud pairing")
            return
        }

        // @Sendable: `register` is captured by the UNUserNotificationCenter
        // completion handlers below, which are themselves @Sendable. Hopping via
        // `Task { @MainActor in }` rather than DispatchQueue.main.async keeps the
        // MainActor-isolated UIApplication.shared access statically checked.
        let register: @Sendable () -> Void = {
            Task { @MainActor in
                UIApplication.shared.registerForRemoteNotifications()
            }
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                NSLog("[NativeAgentMobile] notification authorization granted=true")
                register()
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                    if let error {
                        NSLog("[NativeAgentMobile] notification authorization error: %@", error.localizedDescription)
                    }
                    NSLog("[NativeAgentMobile] notification authorization granted=%@", granted ? "true" : "false")
                    guard granted else { return }
                    register()
                }
            case .denied:
                NSLog("[NativeAgentMobile] notification authorization granted=false")
            @unknown default:
                NSLog("[NativeAgentMobile] notification authorization status unknown")
            }
        }
    }

    // PATCH-2026-05-07: icloud-bridge route to iCloud based on pairing type
    // PATCH-2026-05-11: fix-skip-icloud — also use iCloud when the HMAC secret is
    // present but isICloudPaired is false (e.g. user tapped Skip on pairing screen
    // after a previous iCloud pairing stored the Keychain secret, or if the flag
    // was cleared by a migration).  iCloudPairingSecret presence is sufficient to
    // route to iCloud; isICloudPaired is a convenience flag that can fall behind.
    private func configureTransport() {
        // Inject pairingStore into both iCloud surfaces so they can sign messages:
        //   - iCloudSyncEngine: action channel (Mac control, Workshop, approvals)
        //   - iCloudBridge:     chat channel (BridgeMessage)
        iCloudSyncEngine.shared.pairingStore = pairingStore
        iCloudBridge.shared.pairingStore = pairingStore
        // F4: bridgeClient needs pairingStore so it can pick the `.macUnreachable`
        // status when paired but the bridge has been offline for >30 s.
        bridgeClient.pairingStore = pairingStore
        // Use iCloud when either the paired flag is set OR the HMAC secret is present
        // (the secret survives app reinstalls and Skip flows via Keychain).
        if pairingStore.usesICloudTransport {
            bridgeClient.configureICloud()
            startBridgeNotificationObserver()
        } else {
            stopBridgeNotificationObserver()
            bridgeClient.disconnect()
        }
    }

    private func startBridgeNotificationObserver() {
        guard bridgeNotificationObserverID == nil else { return }
        bridgeNotificationObserverID = iCloudBridge.shared.observeNotifications { msg in
            NativeAgentBridgeNotificationScheduler.schedule(msg)
        }
    }

    private func stopBridgeNotificationObserver() {
        iCloudBridge.shared.removeNotificationObserver(bridgeNotificationObserverID)
        bridgeNotificationObserverID = nil
    }

    /// Explicit process-argument test hook. Pass
    /// `-sendTestMessage "your text"` to `xcrun simctl launch`; production apps
    /// cannot receive this from another app or a web page.
    private func checkLaunchArgsForTestSend() {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-sendTestMessage"),
              idx + 1 < args.count else { return }
        let text = args[idx + 1]
        guard !text.isEmpty else { return }
        // Slight delay so ChatView has installed its NotificationCenter observer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NotificationCenter.default.post(
                name: .nativeagentDeepLinkSend,
                object: nil,
                userInfo: ["text": text]
            )
        }
    }

    /// Launch-args test hook for simulator pairing without iCloud sync.
    /// Pass `-pairingSecretBase64 <base64>` to xcrun simctl launch — sim
    /// can't sign into a real iCloud, so KVS auto-bootstrap never fires
    /// there. This injects the secret directly into the PairingStore so
    /// we can verify the post-pair UI in headless tests.
    private func checkLaunchArgsForPairingSecret() {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-pairingSecretBase64"),
              idx + 1 < args.count else { return }
        let b64 = args[idx + 1]
        guard let data = Data(base64Encoded: b64), data.count == 32 else {
            NSLog("[NativeAgentMobile] -pairingSecretBase64: invalid (need 32 bytes base64)")
            return
        }
        Task { @MainActor in
            pairingStore.iCloudPairingSecret = data
            pairingStore.isICloudPaired = true
            NSLog("[NativeAgentMobile] -pairingSecretBase64: injected (\(data.count) bytes); isICloudPaired=true")
        }
    }

    /// Launch-args test hook for physical-device notification verification.
    /// Pass `-sendTestNotification` to schedule a local notification after 5 seconds.
    private func checkLaunchArgsForTestNotification() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-sendTestNotification") else { return }
        let title = value(after: "-notificationTitle", in: args) ?? "NativeAgent test notification"
        let body = value(after: "-notificationBody", in: args) ?? "Local notifications are working on this iPhone."
        Task.detached {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            NSLog("[NativeAgentMobile] launch test notification authorization granted=%@", granted ? "true" : "false")
            let settings = await center.notificationSettings()
            NSLog("[NativeAgentMobile] launch test notification settings authorization=%ld alert=%ld", settings.authorizationStatus.rawValue, settings.alertSetting.rawValue)
            guard granted || settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["screen": "activity", "source": "launch_test"]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            let request = UNNotificationRequest(
                identifier: "nativeagent.launch-test.\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
                NSLog("[NativeAgentMobile] launch test notification scheduled")
            } catch {
                NSLog("[NativeAgentMobile] launch test notification add failed: %@", error.localizedDescription)
            }
        }
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        let value = args[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

}

final class NativeAgentMobilePushDelegate: NSObject, UIApplicationDelegate {
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
        // 2026-07-04: ledger every arrival so delivered-but-silenced (Focus,
        // Scheduled Summary) is distinguishable from never-delivered.
        let pushReceipt = PushReceiptLedger.record(userInfo: userInfo)
        Task { @MainActor in
            if let eventID = pushReceipt.eventId {
                await iCloudSyncEngine.shared.sendNotificationReceipt(
                    eventID: eventID,
                    channel: "apns"
                )
            }
            // CK-3c: if this is a CloudKit silent push for our device-sync
            // subscription AND CloudKit is active, drain the transport. Both
            // guards live inside drainIfDeviceSyncPush; a flag-off build returns
            // immediately without parsing. Every other push — and the legacy
            // snapshot refresh below — is untouched.
            let ckDelivered = await iCloudBridge.shared.drainIfDeviceSyncPush(userInfo)
            let inboxLoaded = await iCloudSyncEngine.shared.refreshInboxSnapshot()
            await iCloudSyncEngine.shared.refreshActivitySnapshot()
            completionHandler((inboxLoaded || ckDelivered) ? .newData : .noData)
        }
    }
}

final class NativeAgentNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // F7: route per notification payload's `screen` field instead of always
        // landing on Activity. Allowed values: activity, chat, memories, skills, more.
        let screen = NativeAgentRemoteNotificationPayload.string(
            directKey: "screen",
            cloudKitRecordKey: "notificationScreen",
            in: response.notification.request.content.userInfo
        )
        NativeAgentNotificationLaunchIntent.markOpenActivityPending(screen: screen)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            NotificationCenter.default.post(
                name: .nativeagentOpenActivity,
                object: nil,
                userInfo: ["screen": screen ?? "activity"]
            )
        }
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
            let body = nonEmpty(metadata["body"]) ?? msg.text
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
