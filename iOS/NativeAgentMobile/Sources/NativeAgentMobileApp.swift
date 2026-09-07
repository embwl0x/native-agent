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

/// Skipping initial pairing admits the user to the main app, but it must never
/// remove the path back to pairing. The More tab owns that recovery action.
enum PairingSkipPresentation {
    enum MainAppState: Equatable {
        case pairingRequired
        case skipped
        case paired
    }

    static func mainAppState(isPaired: Bool, pairingSkipped: Bool) -> MainAppState {
        if isPaired { return .paired }
        return pairingSkipped ? .skipped : .pairingRequired
    }

    static func showsRecoveryAffordance(isPaired: Bool) -> Bool {
        !isPaired
    }
}

/// Process-local simulator hook for a single launch-injected chat turn. The
/// pending value closes the observer-registration race: if the notification
/// posts before ChatView mounts, the mounted chat still consumes the exact
/// launch text once. This is not persisted and has no public URL route.
@MainActor
enum NativeAgentDeepLinkSendHook {
    private static var pendingText: String?
    private static var acceptedLaunchArgument = false

    static func stageLaunchArguments(
        _ arguments: [String],
        notificationCenter: NotificationCenter = .default
    ) {
        guard !acceptedLaunchArgument,
              let index = arguments.firstIndex(of: "-sendTestMessage"),
              index + 1 < arguments.count
        else { return }
        let text = arguments[index + 1]
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        acceptedLaunchArgument = true
        stage(text, notificationCenter: notificationCenter)
    }

    static func stage(
        _ text: String,
        notificationCenter: NotificationCenter = .default
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingText = text
        notificationCenter.post(name: .nativeagentDeepLinkSend, object: nil)
    }

    @discardableResult
    static func deliverPending(
        to store: ChatStore,
        client: MacBridgeClient,
        controls: ChatRuntimeControls,
        emitHaptic: Bool = true
    ) -> ChatSendDisposition? {
        guard let text = pendingText else { return nil }
        pendingText = nil
        return store.send(
            text: text,
            client: client,
            controls: controls,
            emitHaptic: emitHaptic
        )
    }
}

/// Parses explicit simulator/device test switches without exposing a URL or
/// notification route to production callers. Application lifecycle code owns
/// the one-shot execution of the returned values.
enum NativeAgentLaunchArgumentPresentation {
    struct TestNotification: Equatable {
        let title: String
        let body: String
    }

    static func pairingSecret(from arguments: [String]) -> Data? {
        guard let encoded = value(after: "-pairingSecretBase64", in: arguments),
              let secret = Data(base64Encoded: encoded),
              secret.count == 32
        else { return nil }
        return secret
    }

    static func testNotification(from arguments: [String]) -> TestNotification? {
        guard arguments.contains("-sendTestNotification") else { return nil }
        return TestNotification(
            title: value(after: "-notificationTitle", in: arguments) ?? "NativeAgent test notification",
            body: value(after: "-notificationBody", in: arguments) ?? "Local notifications are working on this iPhone."
        )
    }

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

enum NativeAgentNotificationLaunchIntent {
    private static let openActivityKey = "NativeAgentMobile.pendingOpenActivityFromNotification"
    private static let pendingScreenKey = "NativeAgentMobile.pendingNotificationScreen"

    /// Allowed screen values that route to a top-level tab.
    static let allowedScreens: Set<String> = [
        "activity", "approvals", "inbox", "chat", "memories", "desk", "skills", "more",
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

/// 2026-09-06: the conversation a tapped reply notification came from. Stored
/// the same way as the screen intent so a cold launch still routes: the view
/// tree that consumes it may not exist when the tap is handled.
enum MobileNotifiedChatSessionIntent {
    private static let key = "NativeAgentMobile.pendingNotificationChatSession"

    static func stage(_ sessionID: String?) {
        let clean = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let clean, !clean.isEmpty else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(clean, forKey: key)
    }

    static func consume() -> String? {
        guard let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return value
    }
}

/// 2026-09-06: a chat-reply push whose answer is already on screen is noise.
/// `willPresent` has no other way to know, so it asks the chat surface.
@MainActor
enum ChatReplyNotificationPresentation {
    static func isAlreadyDisplayed(userInfo: [AnyHashable: Any]) -> Bool {
        guard NativeAgentRemoteNotificationPayload.string(
                directKey: "source",
                cloudKitRecordKey: "notificationSource",
                in: userInfo
              ) == "icloud_chat_reply",
              let correlationID = NativeAgentRemoteNotificationPayload.string(
                directKey: "correlationId",
                cloudKitRecordKey: "notificationCorrelationId",
                in: userInfo
              ),
              let store = ChatStore.visibleStore
        else { return false }
        let notifiedSessionID = ChatStore.cleanSessionID(
            NativeAgentRemoteNotificationPayload.string(
                directKey: "sessionId",
                cloudKitRecordKey: "notificationSessionId",
                in: userInfo
            )
        )
        if let notifiedSessionID,
           notifiedSessionID != ChatStore.cleanSessionID(store.selectedSessionID) {
            return false
        }
        return store.resolvedICloudReplyIds.contains(correlationID)
    }
}


@main
struct NativeAgentMobileApp: App {
    @UIApplicationDelegateAdaptor(NativeAgentMobilePushDelegate.self) private var pushDelegate
    @StateObject private var pairingStore = PairingStore()
    @StateObject private var bridgeClient = MacBridgeClient()
    @StateObject private var chatStore = ChatStore()
    // PERF-2026-08-05: `@Observable` controller — `@State`/`.environment` is the
    // Observation idiom (`@StateObject`/`.environmentObject` require ObservableObject).
    @State private var voiceInput = VoiceInputController()
    @StateObject private var voiceOutput = VoiceOutputController()
    private let notificationDelegate = NativeAgentNotificationDelegate()
    @State private var bridgeNotificationObserverID: UUID?
    @State private var didApplyPairingSecretLaunchArgument = false
    @State private var didScheduleTestNotificationLaunchArgument = false
    /// Fix-A: persisted flag so users can skip the pairing screen and return later.
    @AppStorage("NativeAgentMobile.pairingSkipped") private var pairingSkipped = false
    @AppStorage(NativeAgentAppearance.storageKey) private var appearanceRawValue = NativeAgentAppearance.system.rawValue

    init() {
        ChatRuntimeControls.primeDeviceSourceKey()
    }

    /// True when the user has either paired OR explicitly skipped the pairing screen.
    private var shouldShowMainApp: Bool {
        PairingSkipPresentation.mainAppState(
            isPaired: pairingStore.isPaired,
            pairingSkipped: pairingSkipped
        ) != .pairingRequired
    }

    // Opening the app must refresh every Mac-published snapshot group, rather
    // than advancing freshness through Activity alone while other tabs retain
    // overnight data. The full engine refresh coalesces repeated activations
    // and performs its reads off the main actor.
    @Environment(\.scenePhase) private var scenePhase

    private func refreshOnForeground() {
        guard pairingStore.usesICloudTransport else { return }
        Task { @MainActor in
            await iCloudSyncEngine.shared.refreshSnapshots()
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if shouldShowMainApp {
                    ContentView()
                        .environmentObject(pairingStore)
                        .environmentObject(bridgeClient)
                        .environmentObject(chatStore)
                        .environment(voiceInput)
                        .environmentObject(voiceOutput)
                        .onAppear {
                            // E8: durable queued sends resume themselves when
                            // the phone's network path returns, instead of
                            // waiting for the user to notice and retry.
                            bridgeClient.onNetworkPathRestored = { [weak chatStore] in
                                chatStore?.resumeQueuedSends()
                            }
                            configureNotifications()
                            configureTransport()
                            checkLaunchArgsForTestSend()
                            checkLaunchArgsForTestNotification()
                            checkLaunchArgsForPairingSecret()
                            // `scenePhase` can already be active by the time
                            // this view mounts, so do not rely on its change
                            // callback to refresh the initial foreground view.
                            refreshOnForeground()
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
                        configureTransport()
                    }, onPaired: {
                        pairingSkipped = false
                        configureTransport()
                        // Registration may have been deferred while this first
                        // pairing screen was visible; retry it once signing is
                        // available so silent CloudKit pushes can arrive.
                        configureNotifications()
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
        NativeAgentDeepLinkSendHook.stageLaunchArguments(ProcessInfo.processInfo.arguments)
    }

    /// Launch-args test hook for simulator pairing without iCloud sync.
    /// Pass `-pairingSecretBase64 <base64>` to xcrun simctl launch — sim
    /// can't sign into a real iCloud, so KVS auto-bootstrap never fires
    /// there. This injects the secret directly into the PairingStore so
    /// we can verify the post-pair UI in headless tests.
    private func checkLaunchArgsForPairingSecret() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-pairingSecretBase64"), !didApplyPairingSecretLaunchArgument else { return }
        didApplyPairingSecretLaunchArgument = true
        guard let data = NativeAgentLaunchArgumentPresentation.pairingSecret(from: args) else {
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
        guard !didScheduleTestNotificationLaunchArgument,
              let notification = NativeAgentLaunchArgumentPresentation.testNotification(from: args)
        else { return }
        didScheduleTestNotificationLaunchArgument = true
        Task.detached {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            NSLog("[NativeAgentMobile] launch test notification authorization granted=%@", granted ? "true" : "false")
            let settings = await center.notificationSettings()
            NSLog("[NativeAgentMobile] launch test notification settings authorization=%ld alert=%ld", settings.authorizationStatus.rawValue, settings.alertSetting.rawValue)
            guard granted || settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
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

}
