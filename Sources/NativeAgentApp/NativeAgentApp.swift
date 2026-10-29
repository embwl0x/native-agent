import Agents
import ChatToolRuntime
import ApprovalInbox
import MacIntegration
import Transcripts
import DeviceSync
import MemoryV2
import ProviderRouting
import MacControl
import TriggerScheduler
import Privacy
import SchedulerExecution
import Foundation
import AttentionRouting
import ChromeControl
import Cognition
import CognitiveSubstrate
import Context
import ContextFlow
import Desk
import TrustCenter
import ApprovalTransactions
import ActivityWatch
import AppToolRuntime
import SwiftUI
import UserNotifications
import ServiceManagement
import NativeAgentShared
// Runtime subsystems fail closed when an implementation is not wired.
import NativeAgentCore
import StandingBots
import WorkshopExecution
import ChatTurnRuntime
import ChatTurnContracts
import ChatSessionWork
import AgentConversations
import BackgroundLoops
import BackgroundWork
import DreamREMCycle
import PersistenceCore
import PersonaEngine
import TrustPersistence
import OSLog
@_exported import EngineRuntime
import Connectors
import DoctorChecks
import TelegramBot
#if canImport(BackgroundTasks)
import BackgroundTasks
import BackgroundTasks
// Blueprint: | `NativeAgentApp.swift` | SwiftUI app and scene declarations; coordinator-gated async restore/recovery before model and ingress, off-main engine/layout preparation; `NativeAgentEngine.installRuntimeObservationsAtLaunch` through `EngineLaunch` to `BackgroundWork.BodyReport` Swift crash/exit logging |
#endif

@MainActor
final class NativeAgentHotkeyBootstrap {
    static let shared = NativeAgentHotkeyBootstrap()

    private let voice = VoiceInputCapture.forChat()
    private var voiceTurn: GlobalHotkeyVoiceTurn?
    private var wakeObserverToken: NSObjectProtocol?

    func start(appModel: AppModel) {
        // Shotgun's ⌥Space is registered here too, independent of ⌘⇧J's setting.
        ShotgunController.shared.attach(appModel: appModel)
        let hotkeyManager = GlobalHotkey.shared
        let voice = self.voice
        let voiceTurn: GlobalHotkeyVoiceTurn
        if let existing = self.voiceTurn {
            voiceTurn = existing
        } else {
            voiceTurn = GlobalHotkeyVoiceTurn(
                requestPermission: { await voice.requestPermission() },
                isVoiceHoldCurrent: { hotkeyManager.isVoiceHoldCurrent() },
                beginCapture: {
                    voice.startListening()
                    return voice.isListening
                        ? nil
                        : (voice.errorMessage ?? "Voice capture could not start.")
                },
                stopCapture: { await voice.stopListeningResult() },
                discardCapture: { voice.discardListening() },
                submitTurn: { transcript in
                    await appModel.sendChat(transcript, attachments: voice.attachment.map { [$0] } ?? [])
                },
                reportUnavailable: { message in
                    appModel.statusText = "Voice input unavailable: \(message)"
                    NativeAgentNotifications.post(title: "Voice input unavailable", body: message)
                },
                reportRejectedTurn: { message in
                    appModel.statusText = "Voice message was not sent: \(message)"
                    NativeAgentNotifications.post(title: "Voice message was not sent", body: message)
                }
            )
            self.voiceTurn = voiceTurn
        }
        // Tapping the hotkey opens the app; holding it arms voice.
        hotkeyManager.onOpenWindow = {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows
                    .first { $0.identifier?.rawValue.contains("main") == true }?
                    .makeKeyAndOrderFront(nil)
                ApplicationLifetime.shared.request(.sidebar(.chat))
            }
        }
        hotkeyManager.onVoiceStart = {
            Task { @MainActor in
                _ = await voiceTurn.beginVoiceTurn()
            }
        }
        hotkeyManager.onVoiceEnd = {
            Task { @MainActor in
                _ = await voiceTurn.endVoiceTurn()
            }
        }
        hotkeyManager.onVoiceCancel = { voiceTurn.cancelVoiceTurn() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Re-read at execution time: Settings may change during launch.
            // `setEnabled` is idempotent, so two mounted AppStorage observers
            // cannot churn Carbon registration for the same value.
            let defaults = UserDefaults.standard
            let enabled = defaults.object(forKey: "globalHotkeyEnabled") as? Bool ?? true
            hotkeyManager.setEnabled(enabled)
        }

        if let wakeObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserverToken)
        }
        let wakeThrottle = WakeResetThrottle()
        wakeObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            wakeThrottle.handleWake()
        }
    }
}

@main
enum NativeAgentAppMain {
    @MainActor
    static func main() {
        if AppRelaunch.runRelaunchHelperIfRequested() { return }
        if SwiftToolDispatcher.runScheduledInstallerHelperIfRequestedBlocking() { return }
        NativeAgentEngine.prepareProcessFileLimit()
        guard !NativeAgentLaunchPreflight.shouldSuppressGUIStart() else {
            NativeAgentLaunchPreflight.writeSuppressedLaunchReceipt()
            return
        }

        NativeAgentEnginePorts.installAppPorts(NativeAgentEnginePorts.mounted)

        // Mark public first launch in place before state owners initialize.
        InlineInteractionResolver.platform = AppInlineInteractionPlatformPort()
        // What macOS granted this process at launch, read before anything can change it.
        _ = SystemPermissionPreflight.grantedAtLaunch
        _ = NSApplication.shared
        guard AppDelegate.claimSingleAppInstance() else { return }
        let dataRoot = PersistenceCore.defaultDataRoot()
        NativeAgentEngine.installRuntimeObservationsAtLaunch(dataRoot: dataRoot)
        NativeAgentApp.main()
    }
}

private enum NativeAgentLaunchPreflight {
    static func shouldSuppressGUIStart(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executablePath: String = CommandLine.arguments.first ?? ""
    ) -> Bool {
        guard environment["CODEX_SHELL"] == "1" else { return false }
        return NSString(string: executablePath).standardizingPath
            .hasSuffix("/dist/NativeAgent.app/Contents/MacOS/NativeAgentApp")
    }

    static func writeSuppressedLaunchReceipt() {
        let message = "NativeAgent: refusing to launch the dist GUI bundle from a Codex shell; use script/install_app.sh and probe the installed app through the authenticated bridge.\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}

struct AppBackgroundWorkHost: EngineBackgroundWorkHost {
    @MainActor var activityWatch: ActivityWatchController { .shared }
    var attention: AttentionRouter { .shared }
    var approvals: ApprovalExecution { .app() }
    func postMacNotification(title: String, body: String, userInfo: [String: String], soundName: String?) async -> NativeAgentNotificationPostResult {
        await NativeAgentNotifications.postAndReport(
            title: title, body: body, userInfo: userInfo, soundName: soundName)
    }

    func runAutoDoctor(checks: SwiftNativeDoctorChecks, dataRoot: URL) async throws -> DoctorReport {
        try await AppDoctorPort(dataRoot: dataRoot).runtime.runDoctor(
            repair: true, repairScope: .automatic, checks: checks)
    }

    func makeCompletionSender(dataRoot: URL, silentTelegram: Bool, requestedResultDeliveryID: String?, authorizeTelegramReply: @escaping @Sendable (TelegramConfig, Int) -> Bool) -> any AgentBridgeCompletionSending {
        EngineAgentBridgeCompletionSender(engine: { .live }, router: { .shared }, dataRoot: dataRoot, silentTelegram: silentTelegram,
            requestedResultDeliveryID: requestedResultDeliveryID, authorizeTelegramReply: authorizeTelegramReply)
    }

    var speechPermission: SpeechPermissionSnapshot {
        Self.speechSnapshot(SystemPermissionPreflight.status(.speechRecognition))
    }

    func requestSpeechPermissionIfNotDetermined() async -> SpeechPermissionSnapshot {
        Self.speechSnapshot(await SystemPermissionPreflight.requestSpeechRecognitionIfNotDetermined())
    }

    private static func speechSnapshot(_ status: SystemPermissionStatus) -> SpeechPermissionSnapshot {
        SpeechPermissionSnapshot(rawValue: status.rawValue, isGranted: status == .granted,
            warningSummary: SystemPermissionPreflight.warningSummary(for:
                SystemPermissionSnapshot(capability: .speechRecognition, status: status)),
            settingsLink: SystemPermissionPreflight.settingsURL(for: .speechRecognition)?.absoluteString)
    }

    var voiceName: String { AgentVoice.live.name }
    var agentSubject: String { AgentVoice.live.subject }

    var triggerNotifier: TriggerNotifier {
        { @Sendable note, notify in
            await TriggerNotificationDelivery.notify(note, notify: notify, delivery: NativeAgentEngine.liveDeviceSync, router: { .shared })
        }
    }


}

struct NativeAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = ApplicationLifetime.shared
    @State private var updateController = UpdateController.shared
    @AppStorage("nativeagent.darkMode") private var preferDarkAppearance = true
    @State private var appearance = AppearanceController.shared
    /// Her haze colour is the app's tint, so every native control wears it.
    @AppStorage(HazeColor.key) private var hazeRaw = HazeColor.defaultValue.rawValue

    init() {
        // CoreGraphics reads this preference at process startup, so it takes effect next launch.
        if !UserDefaults.standard.bool(forKey: "CGFontRenderingFontSmoothingDisabled") {
            UserDefaults.standard.set(true, forKey: "CGFontRenderingFontSmoothingDisabled")
        }
        NativeAgentEngine.validateProvidersAtLaunch()
    }

    @MainActor
    static func prepare() async -> Bool {
        let dataRoot = PersistenceCore.defaultDataRoot()
        guard await NativeAgentEngine.prepareStateAtLaunch(
            dataRoot: dataRoot,
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            resources: Bundle.main.resourceURL,
            publicReleaseUnavailable: AppDelegate.presentPublicReleaseDataRootError,
            backupRestoreUnavailable: AppDelegate.presentBackupRestoreError,
            confirmMissingRoots: AppDelegate.confirmLaunchWithMissingRoots,
            macRecoveryUnavailable: {
                NSApp.setActivationPolicy(.regular)
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "NativeAgent could not recover interrupted Mac actions."
                alert.informativeText = "NativeAgent stopped before accepting actions. The details are in the log."
                alert.addButton(withTitle: "Quit")
                alert.runModal()
            }
        ) else { return false }
        SensesAssembly.install(dataRoot: dataRoot)
        await NativeAgentEngine.installBotProviderCheck()
        let appModel = AppModel()

        // The quiet self-administration tools read and set the app's own
        // pages, so they need the SAME model the window is bound to — a second
        // AppModel would read state the visible page never sees. Same handoff
        // DetachedChatWindowController gets below, done here because the tools
        // can be called before any detached chat is restored.

        // "Take over" from the phone or Telegram reads where User was the same
        // way the Mac chat does.
        MacWorkContinuation.capture = { text, taskReference in
            await appModel.captureMacWorkContinuation(text, taskReference: taskReference)
        }

        // A resolved card resumes the request it suspended, and it does that
        // through the SAME model the window is bound to — the continuation
        // lands in the conversation the person is looking at, not in a second
        // AppModel's idea of one. Same reason QuietSelfAdmin is handed this
        // instance directly above.
        //
        // The acceptance is REPORTED, not discarded: a rejected admission has
        // to reach the resolver, or the durable "resumed" claim stands over a
        // turn that never ran and the card is stranded for good.
        NativeAgentEngine.configureInlineInteractionsAtLaunch(startTurn: { prompt, sessionID, hideUserBubble in
            let envelope = ChatToolSessionContext.envelope
            var origin = ChatMessageOrigin(surface: envelope?.surface ?? "chat", agent: envelope?.agent)
            origin.peerSources = PeerDataTaint.current?.checkpointSources ?? []
            origin.elevatedPeerSources = PeerDataTaint.current?.elevatedSources ?? []
            // Queue admission must retain the steer after task-locals end.
            let started = await appModel.startChatTurn(
                prompt, attachments: [], sessionId: sessionID, hideUserBubble: hideUserBubble,
                requireActiveSession: false, origin: origin
            )
            if !hideUserBubble { appModel.publishConversationAnchor(for: started.acceptance) }
            switch started.acceptance {
            case .accepted, .queued: return true
            case .rejected: return false
            }
        })

        ApplicationLifetime.shared.appModel = appModel
        return true
    }

    var body: some Scene {
        // Window keeps the main scene single-instance across open requests.
        Window("NativeAgent", id: ApplicationLifetime.mainSceneID) {
            Group {
                if let appModel = coordinator.appModel {
                    MainWindowContent().environment(appModel)
                } else {
                    Color.clear
                }
            }
                // The window title follows the agent's live name.
                .navigationTitle(coordinator.appModel?.agentAddressName ?? "NativeAgent")
                // AppearanceController always supplies dark or light; Off follows the system.
                .preferredColorScheme(appearance.colorScheme)
                .tint((HazeColor(rawValue: hazeRaw) ?? .defaultValue).windowTint(dark: appearance.colorScheme == .dark))
                .onChange(of: preferDarkAppearance, initial: true) { _, dark in
                    appearance.setPreferDark(dark)
                }
                .frame(minWidth: 1040, minHeight: 680)
                // App-routed OAuth URLs go to the pending flow's callback registry.
                .onOpenURL { url in
                    if url.scheme == "nativeagent", url.host == "oauth" {
                        _ = NativeOAuthFlow.handleCallbackURL(url)
                    }
                }
        }
        // The hidden titlebar preserves continuous glass; MainWindowContent supplies the titleBarInset safe area.
        .windowStyle(.hiddenTitleBar)
        .commands {
            ChatFocusedCommands()
            if let appModel = coordinator.appModel { ShellViewCommands(appModel: appModel) }
            // The enabled item names its action; an unpublished feed opens an explanation without networking.
            CommandGroup(after: .appInfo) {
                Button(updateController.menuTitle) {
                    updateController.checkForUpdates()
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Refresh status") {
                    Task { await coordinator.appModel?.refreshAll() }
                }
                .disabled(coordinator.appModel == nil)
                .keyboardShortcut("r", modifiers: [.command])
            }
            // One Settings page: Command-comma opens the rail's Settings in
            // the main window, not a second copy in a window of its own.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsLink.open(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .windowList) {
                Button("Browser") {
                    BrowserWindowController.shared.showWindow()
                }
                .disabled(coordinator.appModel == nil)
                .keyboardShortcut("b", modifiers: [.command, .option])
            }
            CommandMenu("Navigate") {
                Button("Command palette…") {
                    NotificationCenter.default.post(name: .openCommandPaletteRequest, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Divider()
                // Navigate shortcuts derive from the rail's order, never a separate list.
                if let appModel = coordinator.appModel {
                    ForEach(NavigateMenuPresentation.entries(appModel.engine.layout.layout)) { entry in
                        Button(entry.title) {
                            ApplicationLifetime.shared.request(.sidebar(entry.item))
                        }
                        .keyboardShortcut(entry.shortcut.map {
                            KeyboardShortcut(KeyEquivalent($0), modifiers: .command)
                        })
                    }
                }
                // Knowledge graph carries no digit: the digits belong to the
                // rail's order.
                Button("Knowledge graph") { ApplicationLifetime.shared.request(.sidebar(.knowledge)) }
                Divider()
                Button("Approvals") { ApplicationLifetime.shared.request(.activity(.approvals)) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Inbox") { ApplicationLifetime.shared.request(.activity(.inbox)) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("NativeAgent", systemImage: "brain.head.profile") {
            // Accessory activation requires an explicit action to open or raise the main window.
            MenuBarOpenButton()
            Button("Refresh status", systemImage: "arrow.clockwise") {
                Task { await coordinator.appModel?.refreshAll() }
            }
            .disabled(coordinator.appModel == nil)
            Divider()
            Button("Run health checks", systemImage: "stethoscope") {
                Task {
                    guard let appModel = coordinator.appModel else { return }
                    await appModel.runDoctor(repair: false)
                    NativeAgentNotifications.post(title: "NativeAgent health checks", body: appModel.statusText)
                }
            }
            .disabled(coordinator.appModel == nil)
            Button("Show browser window", systemImage: "safari") {
                BrowserWindowController.shared.showWindow()
            }
            .disabled(coordinator.appModel == nil)
            Divider()
            // Menu-bar restart relaunches directly; the in-window action asks for confirmation.
            Button("Restart app", systemImage: "arrow.triangle.2.circlepath") {
                AppRelaunch.relaunchApp(
                    terminate: {
                        RunLoop.main.perform(inModes: [.common]) {
                            MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
                        }
                    },
                    onSpawnFailure: {
                        ModuleLog.app("[relaunch] failed to spawn relaunch helper for %@: %@", Bundle.main.bundlePath, "\($0)")
                    })
            }
            Divider()
            // MenuBarStatusPresentation owns the menu bar's single status line.
            if let appModel = coordinator.appModel {
                Text(MenuBarStatusPresentation.line(statusText: appModel.statusText, health: appModel.engine.doctor.health))
            }
        }

        // The separate capture indicator is present exactly while the watcher's observers are installed.
        MenuBarExtra(
            "Activity capture is recording",
            systemImage: "record.circle",
            isInserted: activityCaptureIndicatorBinding
        ) {
            ActivityCaptureMenuBarContent()
        }
    }

    /// Read-write binding because `MenuBarExtra(isInserted:)` demands one; the
    /// setter is deliberately inert. SwiftUI never writes to it (there is no UI
    /// affordance to remove a menu-bar item), and if it ever did, honouring the
    /// write would let the indicator be dismissed while capture kept running —
    /// which is precisely the failure this control exists to prevent.
    private var activityCaptureIndicatorBinding: Binding<Bool> {
        Binding(
            get: { coordinator.appModel?.engine.activityWatch.isCapturing == true },
            set: { _ in }
        )
    }
}

/// The indicator's menu. Deliberately tiny: it states what is being recorded in
/// one line and offers the one action a person reaching for this actually wants
/// — stop.
private struct ActivityCaptureMenuBarContent: View {
    private var controller: ActivityWatchController { NativeAgentEngine.live.activityWatch }

    var body: some View {
        Text("Recording which apps you use — app name and duration"
             + (controller.policy.captureTitles && !controller.policy.appNameOnlyMode
                ? ", plus window titles." : ", no window titles."))
        Divider()
        Button("Stop recording", systemImage: "stop.circle") {
            Task { await controller.setCaptureEnabled(false) }
        }
        Button("Activity settings…", systemImage: "gear") {
            SettingsLink.open(.trust, tab: TrustTab.features.rawValue)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var approvalNotificationTask: Task<Void, Never>?
    @MainActor var previousWorkApp: NSRunningApplication?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.categoryIdentifier
        guard category == NativeAgentNotificationActions.approvalCategory
                || category == NativeAgentNotificationActions.messageCategory else { return [] }
        return [.banner, .list, .sound]
    }

    /// Only explicit action buttons execute. An ordinary banner click opens
    /// its destination; dismissal does nothing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = NativeAgentNotificationActions.Response(response)
        do { try await ApplicationLifetime.shared.prepare() } catch { return }
        await NativeAgentNotificationActions.handle(action)
    }

    /// Paired iPhone chat is the same resident mind with its own closed remote
    /// surface profile and approval policy.
    static let residentIOSChatClient = NativeAgentEngine.live.chatClient(
        profile: .ios
    )
}

// Preserve the app transcript type when ChatOrchestration is also imported.
typealias ChatMessage = EngineRuntime.ChatMessage
// NativeAgentShared and Core both ship a `MemoryRecord` (MemoryV2) and a
// `ChatSession`; `MultimodalAttachment` is one shared value. The app's UI
// and decoding use the NativeAgentShared names.
typealias MemoryRecord = NativeAgentShared.MemoryRecord
typealias MultimodalAttachment = NativeAgentShared.MultimodalAttachment
typealias ChatSession = NativeAgentShared.ChatSession

extension NativeAgentEnginePorts {
    static func mounted(dataRoot: URL) -> Self {
        Task {
            await AgentContactHealth.shared.installGrokVerifier(dataRoot: dataRoot) { peer in
                do { try await NativeAgentEngine.live.agents.desktop.importGrokRoutine(peer: peer, dataRoot: dataRoot, waitForCreation: false) }
                catch let blocker as GrokRoutineAccessibility.Blocker { throw ToolFailureError(blocker.rawValue, effects: .unknown) }
            }
        }
        return Self(
            backgroundWork: AppBackgroundWorkHost(),
            connectorStatus: AppConnectorStatusPlatform(),
            cognitionHost: EngineCognitionHost(attention: .shared),
            deviceSyncHost: EngineDeviceSyncHost(engine: { .live }, router: { .shared }, platform: AppDeviceSyncPlatform()),
            macIntegration: MacIntegrationDeliveryActions(),
            a2aPushConfiguration: { peer in
                let port = await ClaudeBridgeRuntime.shared.activePort
                guard port != 0, let secret = try? AgentPeerCredentials.read(peerID: peer.id), !secret.isEmpty else { return nil }
                return .object(["url": .string("http://127.0.0.1:\(port)/a2a/notifications"),
                    "authentication": .object(["scheme": .string("Bearer"), "credentials": .string(secret)])])
            },
            completionSender: { EngineAgentBridgeCompletionSender(engine: { .live }, router: { .shared }, dataRoot: $0) },
            standingBotQueue: BotRunQueue(dataRoot: dataRoot),
            appTools: { AppToolExecutor(securityCenter: $0, enforceAutonomySecurity: $1) },
            chatPlatform: ChatToolPlatformPort(
                grok: { await GrokBotConnection.perform(plan: $0, dataRoot: $1, inner: $2, surface: $3,
                                                       port: NativeAgentEngine.live.agents.desktop) },
                desktopChat: { await DesktopChatRoute.perform(plan: $0, dataRoot: $1) },
                desktop: { await NativeAgentEngine.live.agents.desktop.run(plan: $0, inner: $1, surface: $2) }
            )
        )
    }
}

private struct AppDeviceSyncPlatform: EngineDeviceSyncPlatform {
    @MainActor func settingsHost() throws -> any QuietSettingsHost {
        guard let appModel = ApplicationLifetime.shared.appModel else {
            throw QuietSettingError.unavailable("The Mac's settings are not loaded yet. Try again in a moment.")
        }
        return AppQuietSettingsHost(appModel)
    }
    @MainActor var oauthPlatform: any NativeOAuthPlatformPort.Type { NativeOAuthPlatform.self }
    @MainActor func adoptProvider(_ id: String) async { await ApplicationLifetime.shared.appModel?.adoptProviderForBlankSurfaces(id) }
    func inboxAction(_ id: String, action: String) async throws {
        try await InboxCardActions.perform(id, action: action,
            dataRootOverride: nil, effects: AppInboxCardActionEffects(inbox: NativeAgentEngine.live.inbox))
    }
    @MainActor func interactionAction(payload: [String: String], actionID: String, clientID: String) async throws -> [String: String] {
        try await InteractionCardDelivery.answer(payload: payload, actionID: actionID, clientID: clientID,
                                                dataRoot: PersistenceCore.defaultDataRoot())
    }
    @MainActor func runMacControl(path: String, bodyData: Data) async throws -> JSONValue {
        try await TrustCenterMacControlPolicyProvider.run(path: path, bodyData: bodyData,
            dataRoot: PersistenceCore.defaultDataRoot())
    }
}

extension ClaudeBridgeRuntime {
    static let shared: ClaudeBridgeRuntime = NativeAgentEngine.makeAgentBridge(engine: { .live },
        grpcPort: { Agents.NativeAgentA2AGRPCListener.shared.port })
}
extension Agents.NativeAgentA2AGRPCListener {
    static let shared: Agents.NativeAgentA2AGRPCListener = NativeAgentEngine.makeA2AListener(engine: { .live }, bridge: { .shared })
}

extension AttentionRouter {
    static let shared = AttentionRouter(delivery: .engineDelivery(phone: { title, body, userInfo in
        try await NativeAgentEngine.liveDeviceSync.relay.sendNotification(
            title: title, body: body, userInfo: userInfo)
    }))
}
