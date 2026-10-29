import SwiftUI
import AppIntents
import CryptoKit
import UserNotifications
import UIKit
import NativeAgentShared
#if canImport(CloudKit)
import CloudKit
// Blueprint: | `NativeAgentMobileApp.swift` | `NativeAgentMobileApp` struct |
#endif

extension Notification.Name {
    /// Internal simulator/test hook. No public URL scheme can post this event;
    /// only explicit process launch arguments reach it.
    static let nativeagentDeepLinkSend = Notification.Name("nativeagent.chat.send")
    static let nativeagentOpenActivity = Notification.Name("nativeagent.open.activity")
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

    static func deliverPending(
        to store: ChatStore,
        client: MacBridgeClient,
        controls: ChatRuntimeControls,
        emitHaptic: Bool = true
    ) {
        guard let text = pendingText else { return }
        pendingText = nil
        store.send(
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

struct NativeAgentNotificationLaunchIntent: Codable, Identifiable, Hashable {
    var id = UUID()
    let screen: String
    let sessionID: String?
    let taskID: String?
    private static let key = "NativeAgentMobile.pendingNotificationDestination"
    private static let allowedScreens: Set<String> = [
        "activity", "approvals", "inbox", "chat", "memories", "desk", "skills", "more", "workshop",
        "mac_integration", "macintegration", "mac-integration",
    ]

    static var isPending: Bool { UserDefaults.standard.data(forKey: key) != nil }

    static func stage(screen: String?, sessionID: String? = nil, taskID: String? = nil) {
        let raw = screen?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "activity"
        let screen = raw == "missions" ? "workshop" : allowedScreens.contains(raw) ? raw : "activity"
        let session = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = Self(screen: screen, sessionID: screen == "chat" ? session.flatMap { $0.isEmpty ? nil : $0 } : nil,
                          taskID: ["desk", "workshop"].contains(screen) ? taskID.flatMap { $0.isEmpty ? nil : $0 } : nil)
        UserDefaults.standard.set(try? JSONEncoder().encode(intent), forKey: key)
    }

    static func consume() -> Self? {
        defer { UserDefaults.standard.removeObject(forKey: key) }
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Extract Sendable reply keys before actor hops; the notification dictionary never crosses isolation.
struct ChatReplyNotificationKeys: Sendable {
    let source: String?
    let correlationID: String?
    let sessionID: String?

    init(userInfo: [AnyHashable: Any]) {
        source = NativeAgentRemoteNotificationPayload.string(
            directKey: "source", cloudKitRecordKey: "notificationSource", in: userInfo)
        correlationID = NativeAgentRemoteNotificationPayload.string(
            directKey: "correlationId", cloudKitRecordKey: "notificationCorrelationId", in: userInfo)
        sessionID = NativeAgentRemoteNotificationPayload.string(
            directKey: "sessionId", cloudKitRecordKey: "notificationSessionId", in: userInfo)
    }
}

@MainActor
enum ChatReplyNotificationPresentation {
    static func isAlreadyDisplayed(userInfo: [AnyHashable: Any]) -> Bool {
        isAlreadyDisplayed(keys: ChatReplyNotificationKeys(userInfo: userInfo))
    }

    static func isAlreadyDisplayed(keys: ChatReplyNotificationKeys) -> Bool {
        guard keys.source == "icloud_chat_reply",
              let correlationID = keys.correlationID,
              let store = ChatStore.visibleStore
        else { return false }
        let notifiedSessionID = ChatStore.cleanSessionID(keys.sessionID)
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
    @State private var chatStore = ChatStore.shared
    // Observation controllers use @State and .environment.
    @State private var voiceInput = VoiceInputController()
    @StateObject private var voiceOutput = VoiceOutputController()
    private let notificationDelegate = NativeAgentNotificationDelegate()
    @State private var didApplyPairingSecretLaunchArgument = false
    @State private var didScheduleTestNotificationLaunchArgument = false
    /// Skipping pairing persists across launches and leaves the pairing path available.
    @AppStorage("NativeAgentMobile.pairingSkipped") private var pairingSkipped = false
    @AppStorage(NativeAgentAppearance.storageKey) private var appearanceRawValue = NativeAgentAppearance.system.rawValue

    init() {
        ChatRuntimeControls.primeDeviceSourceKey()
        MobileNotificationRouting.register()
        UNUserNotificationCenter.current().delegate = notificationDelegate
        NativeAgentMobileShortcuts.updateAppShortcutParameters()
        let pairing = PairingStore()
        _pairingStore = StateObject(wrappedValue: pairing)
        iCloudBridge.shared.pairingStore = pairing
        iCloudSyncEngine.shared.pairingStore = pairing
        // Location relaunches need their observer even without a visible scene.
        if pairing.usesICloudTransport { iCloudBridge.shared.setup() }
        PhonePlaces.shared.resume()
    }

    /// Pairing, an explicit skip or pending repair admits the main app; More retains the pairing action.
    private var shouldShowMainApp: Bool {
        pairingStore.isPaired || pairingSkipped || pairingStore.connectionRepairPending
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var foregroundRefreshTask: Task<Void, Never>?
    @State private var foregroundRefreshID: UUID?
    @State private var foregroundRefreshPairing: Data?

    private func refreshOnForeground() {
        PhoneTurnActivity.shared.resumeWorkActivities()
        guard pairingStore.usesICloudTransport else { return }
        let pairing = pairingStore.iCloudPairingSecret
        guard foregroundRefreshTask == nil || foregroundRefreshPairing != pairing else { return }
        foregroundRefreshTask?.cancel()
        let generation = UUID()
        foregroundRefreshID = generation
        foregroundRefreshPairing = pairing
        // The Mac's beat is re-read on activation (iCloudBridge); until it
        // lands, an old sighting reads as finding the Mac, not losing it.
        bridgeClient.connectingStartedAt = Date()
        bridgeClient.refreshConnection()
        PhonePlaces.shared.resume()
        foregroundRefreshTask = Task { @MainActor in
            defer { if foregroundRefreshID == generation { foregroundRefreshTask = nil } }
            await iCloudBridge.shared.deviceIncomingSetupTask?.value
            await iCloudBridge.shared.setupTask?.value
            guard !Task.isCancelled, pairing == pairingStore.iCloudPairingSecret else { return }
            let sync = iCloudSyncEngine.shared
            await sync.refreshLightweightSnapshots()
            guard !Task.isCancelled, pairing == pairingStore.iCloudPairingSecret else { return }
            let group = sync.foregroundSnapshotGroup
            if group == .advanced { _ = await sync.refreshCatalogSnapshot() }
            await sync.refreshSnapshotGroup(group)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if shouldShowMainApp {
                    ContentView()
                        .environmentObject(pairingStore)
                        .environmentObject(bridgeClient)
                        .environment(chatStore)
                        .environment(voiceInput)
                        .environmentObject(voiceOutput)
                        .onAppear {
                            // Resume durable queued sends when the phone's network path returns.
                            bridgeClient.onNetworkPathRestored = { [weak chatStore = chatStore] in
                                chatStore?.recoverQueuedSendTransport()
                                PhoneTurnActivity.shared.resumeWorkActivities()
                            }
                            iCloudBridge.shared.onTransportSucceeded = { [weak chatStore = chatStore] in
                                chatStore?.recoverQueuedSendTransport()
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
                            refreshOnForeground()
                        }
                        .onChange(of: pairingStore.iCloudPairingSecret) { _, _ in
                            configureTransport()
                            configureNotifications()
                            refreshOnForeground()
                        }
                        .onChange(of: scenePhase) { _, newPhase in
                            if newPhase != .active {
                                Task {
                                    do { try await chatStore.storage.flush() }
                                    catch { chatStore.errorBanner = error.localizedDescription }
                                }
                            }
                            if newPhase == .active { refreshOnForeground() }
                        }
                } else {
                    PairingView(onSkip: {
                        // Persist skipping without clearing pairing credentials.
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
            // Announce on launch and key changes; the Mac ignores repeats and re-lists removed phones as pending.
            .task { announcePhoneToMac() }
            .onChange(of: pairingStore.iCloudPairingSecret) { _, _ in announcePhoneToMac() }
            .preferredColorScheme(NativeAgentAppearance.resolved(appearanceRawValue).colorScheme)
        }
    }

    private func announcePhoneToMac() {
        guard pairingStore.iCloudPairingSecret != nil,
              !pairingStore.connectionRepairPending, !pairingStore.isRepairingConnection else { return }
        iCloudSyncEngine.shared.pairingStore = pairingStore
        Task {
            guard !pairingStore.connectionRepairPending, !pairingStore.isRepairingConnection else { return }
            _ = try? await iCloudSyncEngine.shared.sendAction(.make(action: "pairDevice", payload: [:]), intentionalNewRequest: true)
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

    // HMAC secret presence permits iCloud routing independently of the paired flag.
    private func configureTransport() {
        guard !pairingStore.isRepairingConnection else { return }
        // Inject pairingStore into both iCloud surfaces so they can sign messages:
        //   - iCloudSyncEngine: action channel (Mac control, Workshop, approvals)
        //   - iCloudBridge:     chat channel (BridgeMessage)
        iCloudSyncEngine.shared.pairingStore = pairingStore
        iCloudBridge.shared.pairingStore = pairingStore
        // Pairing lets the client distinguish an unreachable Mac from an unpaired bridge.
        bridgeClient.pairingStore = pairingStore
        PhonePlaces.shared.resume()
        PhoneTurnActivity.shared.resumeWorkActivities()
        // Use iCloud when either the paired flag is set OR the HMAC secret is present
        // (the secret survives app reinstalls and Skip flows via Keychain).
        if pairingStore.usesICloudTransport {
            bridgeClient.configureICloud()
        } else if pairingStore.connectionRepairPending {
            iCloudBridge.shared.setup()
        } else {
            bridgeClient.disconnect()
        }
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
        #if DEBUG
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
        #endif
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
