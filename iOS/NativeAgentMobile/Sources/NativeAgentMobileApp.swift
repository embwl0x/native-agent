import SwiftUI
import AppIntents
import CryptoKit
import UserNotifications
import UIKit
import ActivityKit
import NativeAgentShared
#if canImport(CloudKit)
import CloudKit
// Blueprint: | `NativeAgentMobileApp.swift` | `NativeAgentMobileApp` struct |
#endif

extension Notification.Name {
    /// Restrict launch injection to process arguments; no public URL scheme may post it.
    static let nativeagentDeepLinkSend = Notification.Name("nativeagent.chat.send")
    static let nativeagentOpenActivity = Notification.Name("nativeagent.open.activity")
}

/// Retain launch text in-process to close the observer-registration race; consume once, without persistence or public URL routing.
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

/// Only process arguments may supply launch hooks; lifecycle code owns one-shot execution.
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
        "activity", "approvals", "inbox", "chat", "memories", "desk", "skills", "more",
        "mac_integration", "macintegration", "mac-integration",
    ]

    static var isPending: Bool { UserDefaults.standard.data(forKey: key) != nil }

    static func stage(screen: String?, sessionID: String? = nil, taskID: String? = nil) {
        let raw = screen?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "activity"
        let screen = allowedScreens.contains(raw) ? raw : "activity"
        let session = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = Self(screen: screen, sessionID: screen == "chat" ? session.flatMap { $0.isEmpty ? nil : $0 } : nil,
                          taskID: screen == "desk" ? taskID.flatMap { $0.isEmpty ? nil : $0 } : nil)
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
    static func ownsVisibleConversation(userInfo: [AnyHashable: Any]) -> Bool {
        ownsVisibleConversation(keys: ChatReplyNotificationKeys(userInfo: userInfo))
    }

    static func ownsVisibleConversation(keys: ChatReplyNotificationKeys) -> Bool {
        guard keys.source == "icloud_chat_reply",
              let store = ChatStore.visibleStore
        else { return false }
        guard let notifiedSessionID = ChatStore.cleanSessionID(keys.sessionID) else { return false }
        if notifiedSessionID == ChatStore.cleanSessionID(store.selectedSessionID) { return true }
        // The first reply may assign a Mac-created session while the visible exchange is still sessionless.
        guard ChatStore.cleanSessionID(store.selectedSessionID) == nil else { return false }
        guard let correlationID = keys.correlationID else { return false }
        return store.pendingExchanges[correlationID].map {
            $0.sessionID == ChatStore.cleanSessionID(store.selectedSessionID)
        } ?? false
    }
}


@main
struct NativeAgentMobileApp: App {
    @UIApplicationDelegateAdaptor(NativeAgentMobilePushDelegate.self) private var pushDelegate
    @StateObject private var pairingStore = PairingStore()
    @StateObject private var bridgeClient = MacBridgeClient()
    @State private var chatStore = ChatStore.shared
    @State private var voiceInput = VoiceInputController()
    @StateObject private var voiceOutput = VoiceOutputController()
    private let notificationDelegate = NativeAgentNotificationDelegate()
    @State private var didApplyPairingSecretLaunchArgument = false
    @State private var didScheduleTestNotificationLaunchArgument = false
    /// Skipping pairing persists across launches and leaves the pairing path available.
    @AppStorage("NativeAgentMobile.pairingSkipped") private var pairingSkipped = false
    @AppStorage(NativeAgentAppearance.storageKey) private var appearanceRawValue = NativeAgentAppearance.system.rawValue

    init() {
        PhoneTalkCommands.handle = { callID, command in
            let talk = TalkModeController.shared
            guard talk.acceptsCommand(callID: callID) else { return false }
            switch command {
            case .mute: talk.toggleMute()
            case .end: talk.end()
            }
            return true
        }
        // Cold launch must retire old call islands: a terminated process cannot own a microphone.
        Task { await TalkModeController.endTalkActivities(callID: nil) }
        ChatRuntimeControls.primeDeviceSourceKey()
        MobileNotificationRouting.register()
        UNUserNotificationCenter.current().delegate = notificationDelegate
        NativeAgentMobileShortcuts.updateAppShortcutParameters()
        let pairing = PairingStore()
        _pairingStore = StateObject(wrappedValue: pairing)
        iCloudBridge.shared.pairingStore = pairing
        iCloudSyncEngine.shared.pairingStore = pairing
        // Install location observers even when relaunch has no visible scene.
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
        // Await activation's presence read before treating an old Mac sighting as lost contact.
        bridgeClient.isConnecting = true
        bridgeClient.refreshConnection()
        PhonePlaces.shared.resume()
        foregroundRefreshTask = Task { @MainActor in
            defer { if foregroundRefreshID == generation { foregroundRefreshTask = nil } }
            await iCloudBridge.shared.deviceIncomingSetupTask?.value
            guard !Task.isCancelled, pairing == pairingStore.iCloudPairingSecret else { return }
            let sync = iCloudSyncEngine.shared
            await sync.refreshLightweightSnapshots()
            guard !Task.isCancelled, pairing == pairingStore.iCloudPairingSecret else { return }
            let group = sync.foregroundSnapshotGroup
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
                            checkLaunchArgsForSnapshotFixture()
                            // Refresh on mount because scenePhase may already be active and never emit an initial change.
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
                            if newPhase == .background {
                                voiceOutput.stop()
                                VoiceNoteBubble.stopPlayback()
                            }
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
                        // Persist the skip without deleting pairing credentials.
                        pairingSkipped = true
                        configureTransport()
                    }, onPaired: {
                        pairingSkipped = false
                        configureTransport()
                        // Retry deferred push registration once signing exists so the first pairing screen cannot prevent silent CloudKit delivery.
                        configureNotifications()
                    })
                    .environmentObject(pairingStore)
                    .onAppear {
                        // Bind canonical consumers before pairing starts the bridge so immediately drained pairing records can commit through PairingStore.
                        iCloudSyncEngine.shared.pairingStore = pairingStore
                        iCloudBridge.shared.pairingStore = pairingStore
                        checkLaunchArgsForPairingSecret()
                    }
                }
            }
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
            do {
                _ = try await iCloudSyncEngine.shared.sendAction(.make(action: "pairDevice", payload: [:]), intentionalNewRequest: true)
            } catch {
                iCloudSyncEngine.shared.syncError = "Phone announcement: \(error.localizedDescription)"
                iCloudBridge.shared.syncStatus = "Phone announcement: \(error.localizedDescription)"
                NSLog("[NativeAgentMobile] Phone announcement failed: %@", error.localizedDescription)
            }
        }
    }

    private func configureNotifications() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        iCloudSyncEngine.shared.pairingStore = pairingStore

        guard pairingStore.usesICloudTransport else {
            NSLog("[NativeAgentMobile] notification registration deferred until iCloud pairing")
            return
        }

        // Keep register @Sendable for notification callbacks; hop with a MainActor Task so UIApplication access stays statically checked.
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
        // Inject one pairing owner into action and chat transports so both sign with authoritative material.
        iCloudSyncEngine.shared.pairingStore = pairingStore
        iCloudBridge.shared.pairingStore = pairingStore
        bridgeClient.pairingStore = pairingStore
        PhonePlaces.shared.resume()
        PhoneTurnActivity.shared.resumeWorkActivities()
        // Route through iCloud when a paired flag or HMAC secret exists; Keychain survives reinstalls and Skip.
        if pairingStore.usesICloudTransport {
            bridgeClient.configureICloud()
        } else if pairingStore.connectionRepairPending {
            iCloudBridge.shared.setup()
        } else {
            bridgeClient.disconnect()
        }
    }

    /// Only explicit -sendTestMessage launch arguments inject chat; apps and web pages cannot invoke it.
    private func checkLaunchArgsForTestSend() {
        NativeAgentDeepLinkSendHook.stageLaunchArguments(ProcessInfo.processInfo.arguments)
    }

    /// Simulator launch pairing still commits through PairingStore with checked readback; simulator KVS cannot bootstrap from a real iCloud account.
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
            guard pairingStore.applyCloudKitPairingSecret(data) else { return }
            pairingStore.applyICloudPairing()
            NSLog("[NativeAgentMobile] -pairingSecretBase64: installed through PairingStore; isICloudPaired=true")
        }
        #endif
    }

    /// Process-local fixture: a copy of the Mac's published snapshot files in Documents/fixture is read as if just delivered, so a real
    /// conversation opens in the simulator without a paired account. Sends stay off: nothing here is paired.
    private func checkLaunchArgsForSnapshotFixture() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-snapshotFixture") else { return }
        Task { @MainActor in
            let sync = iCloudSyncEngine.shared
            sync.snapshotDir = URL.documentsDirectory.appendingPathComponent("fixture", isDirectory: true)
            for group in [NAMobileSnapshotGroup.core, .chat, .faces] { _ = await sync.refreshSnapshotGroup(group) }
            let main = sync.chatTranscripts.max { a, b in
                a.value.messages.filter { $0.role == .user }.count < b.value.messages.filter { $0.role == .user }.count
            }?.key
            ChatStore.shared.setSelectedSessionID(main)
            NSLog("[NativeAgentMobile] -snapshotFixture: read %d conversations, opened one of %d rows", sync.chatTranscripts.count,
                  main.flatMap { sync.chatTranscripts[$0]?.messages.count } ?? 0)
            // A launch's replay of retained live records: one finished turn whose saved reply is here, one older than the window.
            guard ProcessInfo.processInfo.arguments.contains("-replayOldLive"), let main,
                  let saved = sync.chatTranscripts[main]?.records.first(where: { $0.role == "assistant" && $0.runId != nil && !$0.content.isEmpty }),
                  let savedRun = saved.runId
            else { return }
            let hourAgo = Date().addingTimeInterval(-3600)
            for run in [savedRun, "replayed-older-run"] {
                for seq in 1...12 {
                    let text = String(saved.content.prefix(saved.content.count * seq / 12))
                    await ChatStore.shared.receiveICloudReply(BridgeMessage.make(
                        id: "live-\(run)-\(seq)", sender: "mac", text: text, sessionID: main, correlationID: run,
                        metadata: ["live": "true", "kind": "text_delta", "seq": String(seq), "source": "mac"],
                        timestamp: hourAgo.addingTimeInterval(Double(seq))))
                }
            }
            NSLog("[NativeAgentMobile] -replayOldLive: replayed 24 old live deltas")
        }
        #endif
    }

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
            NSLog("[NativeAgentMobile] launch test notification settings authorization=%ld alert=%ld", settings.authorizationStatus.rawValue,
                settings.alertSetting.rawValue)
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
