import Agents
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
// PATCH-2026-05-07: app-owned runtime SMAppService for login auto-start
import ServiceManagement
import NativeAgentShared
// PATCH-2026-05-30: Swift-native runtime integration anchor. Subsystems dispatch
// through AppDelegate.nativeAgentRuntime and fail closed when a Swift
// implementation is not wired.
import NativeAgentCore
import StandingBots
import WorkshopExecution
import SelfImprovement
import ChatOrchestration
import MCPDispatcher
import BackgroundLoops
import BackgroundWork
import KnowledgeGraph
import DreamREMCycle
import PersistenceCore
import PersonaEngine
import TrustPersistence
import OSLog
@_exported import EngineRuntime
import Connectors
import DoctorChecks
import GitHubConnector
import TelegramBot
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

@MainActor
private final class NativeAgentHotkeyBootstrap {
    static let shared = NativeAgentHotkeyBootstrap()

    private let voice = VoiceInputCapture.forChat()
    private var voiceTurn: GlobalHotkeyVoiceTurn?
    private var wakeObserverToken: NSObjectProtocol?

    func start(appModel: AppModel) {
        // Shotgun's ⌥Space is registered here too, independent of ⌘⇧J's setting.
        ShotgunController.shared.attach(appModel: appModel)
        let hotkeyManager = GlobalHotkeyManager.shared
        let voice = self.voice
        let voiceTurn: GlobalHotkeyVoiceTurn
        if let existing = self.voiceTurn {
            voiceTurn = existing
        } else {
            voiceTurn = GlobalHotkeyVoiceTurn(
                requestPermission: { await voice.requestPermission() },
                permissionFailureMessage: { voice.errorMessage },
                isVoiceHoldCurrent: { hotkeyManager.isVoiceHoldCurrent() },
                beginCapture: {
                    voice.startListening()
                    return voice.isListening
                        ? nil
                        : (voice.errorMessage ?? "Voice capture could not start.")
                },
                stopCapture: { await voice.stopListening() },
                discardCapture: { voice.discardListening() },
                captureFailureMessage: { voice.errorMessage },
                submitTurn: { transcript in
                    await appModel.sendChat(transcript)
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
        // User authorized retiring the Spotlight overlay, 2026-09-01. The tap
        // half of ⌘⇧J now brings the real app forward instead of forking a
        // hidden `sessionId = "spotlight"` thread; the hold half still arms
        // voice, which is why the hotkey itself stays registered.
        hotkeyManager.onOpenWindow = {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows
                    .first { $0.identifier?.rawValue.contains("main") == true }?
                    .makeKeyAndOrderFront(nil)
                NativeAgentAppCoordinator.shared.request(.sidebar(.chat))
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
        NativeAgentEngine.prepareProcessFileLimit()
        guard !NativeAgentLaunchPreflight.shouldSuppressGUIStart() else {
            NativeAgentLaunchPreflight.writeSuppressedLaunchReceipt()
            return
        }

        NativeAgentEnginePorts.installAppPorts(NativeAgentEnginePorts.mounted)

        // Mark public first launch in place before state owners initialize.
        InlineInteractionResolver.platform = AppInlineInteractionPlatformPort()
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
    var attention: AttentionRouter { .shared }
    var backupHost: TrustBackupHost { .app }
    var approvals: ApprovalTransactionCoordinator { .app() }
    func postMacNotification(title: String, body: String, userInfo: [String: String], soundName: String?) async -> NativeAgentNotificationPostResult {
        await NativeAgentNotifications.postAndReport(
            title: title, body: body, userInfo: userInfo, soundName: soundName)
    }

    func notifyIfAttentionWorthy(dataRoot: URL, itemId: String, title: String, summary: String, source: String, severity: String) async {
        await AttentionRouter.shared.notifyIfAttentionWorthy(
            dataRoot: dataRoot, itemId: itemId, title: title, summary: summary,
            source: source, severity: severity)
    }

    func runAutoDoctor(checks: any DoctorChecksProtocol, dataRoot: URL) async throws -> [CheckResult] {
        try await AppDoctorPort(dataRoot: dataRoot).runtime.runDoctor(
            repair: true, repairScope: .automatic, checks: checks).checks
    }

    func wakeDoctorForPendingTransitions(dataRoot: URL) async {
        _ = await AppDoctorPort(dataRoot: dataRoot).runtime.wakeDoctorForPendingTransitions()
    }

    func runConnectorAction(id: String, dryRun: Bool, input: [String: JSONValue], externalSendIdempotencyKey: String) async throws -> (id: String, status: String) {
        let receipt = try await ConnectorActions(
            platform: AppConnectorActionPlatform(dataRoot: PersistenceCore.defaultDataRoot())
        ).runConnectorAction(id: id, dryRun: dryRun, input: input,
            externalSendIdempotencyKey: externalSendIdempotencyKey)
        return (receipt.id, receipt.status)
    }

    func makeCompletionSender(dataRoot: URL, silentTelegram: Bool, requestedResultDeliveryID: String?, authorizeTelegramReply: @escaping @Sendable (TelegramConfig, Int) -> Bool) -> any AgentBridgeCompletionSending {
        EngineAgentBridgeCompletionSender(engine: { .live }, router: { .shared }, dataRoot: dataRoot, silentTelegram: silentTelegram,
            requestedResultDeliveryID: requestedResultDeliveryID, authorizeTelegramReply: authorizeTelegramReply)
    }

    var speechPermission: SpeechPermissionSnapshot {
        let status = SystemPermissionPreflight.status(.speechRecognition)
        return SpeechPermissionSnapshot(rawValue: status.rawValue, isGranted: status == .granted,
            warningSummary: SystemPermissionPreflight.warningSummary(for:
                SystemPermissionSnapshot(capability: .speechRecognition, status: status)),
            settingsLink: SystemPermissionPreflight.settingsURL(for: .speechRecognition)?.absoluteString)
    }

    var voiceName: String { AgentVoice.live.name }
    var agentSubject: String { AgentVoice.live.subject }

    func githubRuntime(dataRoot: URL, shared: Bool) -> GitHubCommandRuntime {
        shared ? .shared : .live(dataRoot: dataRoot)
    }

    func evaluateGitHubApprovals(dataRoot: URL) async {
        await GitHubApprovalEdgeNotifier.shared.evaluateSnapshot(dataRoot: dataRoot)
    }

    var triggerNotifier: TriggerNotifier {
        { @Sendable note in
            await TriggerNotificationDelivery.notify(note, delivery: NativeAgentEngine.liveDeviceSync, router: { .shared })
        }
    }

    func mirrorTriggerFire(_ result: TriggerFireResult) async -> Bool {
        await TriggerNotificationInbox.mirrorNonNotifiedFire(result, dataRoot: PersistenceCore.defaultDataRoot(), delivery: NativeAgentEngine.liveDeviceSync)
    }
}

struct NativeAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = NativeAgentAppCoordinator.shared
    // RELEASE-2026-05-06: Sparkle updater controller (Task 4.3)
    @State private var updateController = UpdateController.shared
    @AppStorage("nativeagent.darkMode") private var preferDarkAppearance = true
    @State private var appearance = AppearanceController.shared
    /// Her haze colour is the app's tint, so every native control wears it.
    @AppStorage(HazeColor.key) private var hazeRaw = HazeColor.defaultValue.rawValue

    init() {
        // User, 2026-09-03: native text on this app looked heavy next to the
        // Claude desktop app's. That app is Chromium, which draws without
        // macOS font smoothing (stem darkening). Turn it off for this process
        // too; CoreGraphics reads the key from the app's own defaults domain
        // at start, so the first launch that sets it renders the old way and
        // every launch after renders thin and crisp.
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
            resources: Bundle.main.resourceURL, backupHost: .app,
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
            await started.task?.value
            switch started.acceptance {
            case .accepted, .queued: return true
            case .rejected: return false
            }
        })

        NativeAgentAppCoordinator.shared.configureProcessBootstrap(.init(
            restoreDetachedChats: {
                DetachedChatWindowController.shared.attach(appModel: appModel)
                DetachedChatWindowController.shared.restoreFromPersist()
                Task { @MainActor in
                    await appModel.loadChatState()
                }
            },
            wireGlobalHotkey: {
                NativeAgentHotkeyBootstrap.shared.start(appModel: appModel)
            },
            warmEmbeddings: {
                Task.detached(priority: .utility) {
                    await EmbeddingModelDownloadController.shared.start()
                    await SwiftNativeMemoryV2.shared.warmUpEmbeddingsAtLaunch()
                }
            }
        ))
        NativeAgentAppCoordinator.shared.appModel = appModel
        return true
    }

    var body: some Scene {
        // PATCH-2026-05-07: single-window-main Window (vs WindowGroup) is
        // single-instance — clicking the menu-bar "Open NativeAgent" item or
        // calling openWindow(id: "main") reuses the existing window instead
        // of stacking new copies on top.
        Window("NativeAgent", id: NativeAgentAppCoordinator.mainSceneID) {
            // PATCH-2026-05-29: restart-controls — MainWindowContent wraps
            // ContentView to add the ever-present top toolbar (runtime health dot +
            // Restart App).
            Group {
                if let appModel = coordinator.appModel {
                    MainWindowContent().environment(appModel)
                } else {
                    Color.clear
                }
            }
                // 2026-09-15: the window carries the agent's NAME once it has
                // one. `Window(_:id:)` takes a static key, so the live title is
                // set here where `agentDisplayName` can be observed — which is
                // what makes the first conversation's "the name at the top of
                // this window" true on the very next frame after the rename.
                .navigationTitle(coordinator.appModel?.agentAddressName ?? "NativeAgent")
                // User, 2026-09-02: never a nil scheme. AppearanceController
                // answers dark or light for both layers; "off" follows the
                // system live. See AppearanceController.swift.
                .preferredColorScheme(appearance.colorScheme)
                .tint((HazeColor(rawValue: hazeRaw) ?? .defaultValue).windowTint(dark: appearance.colorScheme == .dark))
                .onChange(of: preferDarkAppearance, initial: true) { _, dark in
                    appearance.setPreferDark(dark)
                }
                .frame(minWidth: 1040, minHeight: 680)
                // evalfix3/T1: ASWebAuthenticationSession custom-scheme
                // fallback — if the OS routes a nativeagent://oauth/... URL
                // to the app (e.g. user completed auth in their default
                // browser instead of the in-process sheet), forward it to
                // the OAuth flow's pending-callback registry.
                .onOpenURL { url in
                    if url.scheme == "nativeagent", url.host == "oauth" {
                        _ = NativeOAuthFlow.handleCallbackURL(url)
                    }
                }
        }
        // Agent, 2026-09-02: one material per column, top edge to bottom edge.
        // A titled window paints an opaque strip across the top of all three
        // glass columns, so the top-left reads as system chrome bolted onto the
        // room. Hidden title bar = transparent title bar over a full-size
        // content view: the rail's glass runs up under the traffic lights and
        // the room's glass runs up under the header, with no band and no
        // hairline between them. Same rule the composer already follows — no
        // painted strips on glass. Content position is preserved by the
        // titleBarInset safe area in MainWindowContent.
        .windowStyle(.hiddenTitleBar)
        .commands {
            ChatFocusedCommands()
            if let appModel = coordinator.appModel { ShellViewCommands(appModel: appModel) }
            // RELEASE-2026-05-06: "Check for Updates…" in app menu (Task 4.3)
            // A2.1 (2026-07-24): the item is always enabled and its TITLE carries the
            // truth. A disabled "Check for Updates…" is a dead affordance that explains
            // nothing; an enabled one over an unpublished feed is a spinner that 404s.
            // When no feed is published this reads "About Software Updates…" and opens
            // an immediate, honest explanation — no network call.
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
            // PATCH-2026-05-06: wkwebview-browser Window > Browser menu item
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
                // D7: derived from the rail's own order so ⌘N is whatever the
                // rail shows in position N. Do not hand-add entries here.
                ForEach(NavigateMenuPresentation.entries(SurfaceLayoutLive.shared.layout)) { entry in
                    Button(entry.title) {
                        NativeAgentAppCoordinator.shared.request(.sidebar(entry.item))
                    }
                    .keyboardShortcut(entry.shortcut.map {
                        KeyboardShortcut(KeyEquivalent($0), modifiers: .command)
                    })
                }
                // Knowledge graph carries no digit: the digits belong to the
                // rail's order.
                Button("Knowledge graph") { NativeAgentAppCoordinator.shared.request(.sidebar(.knowledge)) }
                Divider()
                Button("Approvals") { NativeAgentAppCoordinator.shared.request(.activity(.approvals)) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Inbox") { NativeAgentAppCoordinator.shared.request(.activity(.inbox)) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("NativeAgent", systemImage: "brain.head.profile") {
            // PATCH-2026-05-07: app-owned runtime Under .accessory activation
            // policy the dock icon is hidden, so we have to explicitly bring
            // the main window to front (or open it if all instances closed).
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
            // PATCH-2026-05-29: restart-controls — mirror the toolbar restart
            // controls in the menu bar so they're reachable when the main window
            // isn't focused (or is closed). Restart App relaunches directly here;
            // the in-window button keeps the confirmation alert.
            Button("Restart app", systemImage: "arrow.triangle.2.circlepath") {
                AppRestartCoordinator.relaunchApp(
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
            // D7: ONE truth line — see MenuBarStatusPresentation. The stacked
            // pair could contradict itself ("Ready" over "unavailable").
            if let appModel = coordinator.appModel {
                Text(MenuBarStatusPresentation.line(statusText: appModel.statusText, health: appModel.engine.doctor.health))
            }
        }

        // W8 (2026-08-14) — THE LIVE CAPTURE INDICATOR.
        //
        // A SECOND, separate menu-bar item rather than a line inside the one
        // above, and that is the whole point: Apple's mic/camera dot works
        // because its presence is the signal. Something you have to open a menu
        // to see is not an indicator, it is a log entry. This item exists in
        // the menu bar if and only if the watcher currently has observers
        // installed, so "is it recording right now" is answerable from across
        // the room without clicking anything.
        //
        // `isInserted` is bound to the controller's `isCapturing`, which is
        // read off the watcher itself rather than mirrored — it cannot say
        // "not recording" while capture is live, because it holds no belief of
        // its own to be wrong about.
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
            get: { coordinator.appModel != nil && ActivityWatchController.shared.isCapturing },
            set: { _ in }
        )
    }
}

/// The indicator's menu. Deliberately tiny: it states what is being recorded in
/// one line and offers the one action a person reaching for this actually wants
/// — stop.
private struct ActivityCaptureMenuBarContent: View {
    @State private var controller = ActivityWatchController.shared

    var body: some View {
        Text("Recording which apps you use — app name and duration"
             + (controller.policy.captureTitles && !controller.policy.appNameOnlyMode
                ? ", plus window titles." : ", no window titles."))
        Divider()
        Button("Stop recording", systemImage: "stop.circle") {
            Task { await controller.setCaptureEnabled(false) }
        }
        Button("Activity settings…", systemImage: "gear") {
            NSApp.activate(ignoringOtherApps: true)
            // Activity capture is on Trust's Features tab. The route lands on
            // the page's first tab, synchronously, so the tab is chosen after.
            NativeAgentAppCoordinator.shared.request(.sidebar(.trust))
            UserDefaults.standard.set(TrustTab.features.rawValue, forKey: ShellRailTab.storageKey(.trust))
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
        do { try await NativeAgentAppCoordinator.shared.prepare() } catch { return }
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
// NativeAgentShared and Core both ship a `MemoryRecord` (MemoryV2), a
// `MultimodalAttachment` and a `ChatSession` (ChatOrchestration's wire
// mirrors); the app's UI and decoding use the NativeAgentShared ones.
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
            browserRoutes: .app,
            cognitionHost: EngineCognitionHost(attention: .shared),
            deviceSyncHost: EngineDeviceSyncHost(engine: { .live }, router: { .shared }, platform: AppDeviceSyncPlatform()),
            macIntegration: MacIntegrationDeliveryActions(),
            agentBridge: AppAgentBridgePort(),
            completionSender: { EngineAgentBridgeCompletionSender(engine: { .live }, router: { .shared }, dataRoot: $0) },
            standingBotQueue: BotRunQueue(dataRoot: dataRoot),
            appTools: { AppToolExecutor(securityCenter: $0, enforceAutonomySecurity: $1) },
            interactions: AppToolInteractionResolver(),
            chatPlatform: ChatToolPlatformPort(
                grok: { await GrokBotConnection.perform(plan: $0, dataRoot: $1, inner: $2, surface: $3,
                                                       port: NativeAgentEngine.live.agents.desktop) },
                desktopChat: { await DesktopChatRoute.perform(plan: $0, dataRoot: $1) },
                desktop: { await NativeAgentEngine.live.agents.desktop.run(plan: $0, inner: $1, surface: $2) }
            ),
            connectorActionStatuses: { try await ConnectorActionRecord.checkedStatuses(root: dataRoot, platform: AppConnectorStatusPlatform()) }
        )
    }
}

private struct AppAgentBridgePort: EngineAgentBridgePort {
    func a2aPushConfiguration(for peer: AgentPeerContact) async -> JSONValue? {
        await a2aPushConfiguration(for: peer, activePort: ClaudeBridgeRuntime.shared.activePort)
    }
}

private struct AppDeviceSyncPlatform: EngineDeviceSyncPlatform {
    func memoryProposalRows(_ rows: [ProposalRecord]) -> DeviceSyncSnapshotRows { rows.map(MemoryProposalRecord.init) }
    func restartTelegram() async -> Bool { await NativeAgentEngine.restartBackgroundLoop(id: "telegram_poll").didRestart }
    var connectorStatus: any ConnectorStatusPlatform { AppConnectorStatusPlatform() }
    func connectorCanToggle(_ row: ConnectorRecord) -> Bool {
        ConnectorRowActionPolicy.resolve(id: row.id, authState: row.authState,
                                         healthStatus: row.healthStatus).showsEnabledMutation
    }
    @MainActor func settingsHost() throws -> any QuietSettingsHost {
        guard let appModel = NativeAgentAppCoordinator.shared.appModel else {
            throw QuietSettingError.unavailable("The Mac's settings are not loaded yet. Try again in a moment.")
        }
        return AppQuietSettingsHost(appModel)
    }
    @MainActor var oauthPlatform: any NativeOAuthPlatformPort.Type { NativeOAuthPlatform.self }
    @MainActor func adoptProvider(_ id: String) async { await NativeAgentAppCoordinator.shared.appModel?.adoptProviderForBlankSurfaces(id) }
    @MainActor func pinnedChatSessionIDs() -> [String] { ChatSessionRetention.load() }
    @MainActor func savePinnedChatSessionIDs(_ ids: [String]) throws { try ChatSessionRetention.save(ids) }
    func submitDeskTask(title: String, objective: String) async throws -> WorkshopDirectedTaskResult {
        try await NativeAgentEngine.submitDeskTask(title: title, objective: objective)
    }
    func resolveWorkshopStep(executionId: String, stepId: String, decision: String,
                             provenance: ApprovalResolutionProvenance) async throws -> WorkshopExecution.WorkshopExecutionRecord {
        try await ApprovalTransactionCoordinator.resolveWorkshopStep(executionId: executionId, stepId: stepId,
            decision: decision, provenance: provenance)
    }
    func resolveApproval(id: String, decision: String, provenance: ApprovalResolutionProvenance) async throws -> ApprovalRecord {
        try await ApprovalTransactionCoordinator.app().resolveApproval(id: id, decision: decision, provenance: provenance)
    }
    func inboxAction(_ id: String, action: String) async throws {
        try await InboxCardActions.perform(id, action: action,
            dataRootOverride: nil, effects: AppInboxCardActionEffects())
    }
    @MainActor func interactionAction(payload: [String: String], actionID: String, clientID: String) async throws -> [String: String] {
        try await InteractionCardDelivery.answer(payload: payload, actionID: actionID, clientID: clientID,
                                                dataRoot: PersistenceCore.defaultDataRoot())
    }
    @MainActor func runMacControl(path: String, bodyData: Data) async throws -> MacControlRunResult {
        try await TrustCenterMacControlPolicyProvider.run(path: path, bodyData: bodyData,
            dataRoot: PersistenceCore.defaultDataRoot(), localWorkbench: false)
    }
}

extension ClaudeBridgeRuntime {
    static let shared: ClaudeBridgeRuntime = NativeAgentEngine.makeAgentBridge(engine: { .live },
        grpcPort: { Agents.NativeAgentA2AGRPCListener.shared.port }, gitHubCommand: { .shared })
}
extension Agents.NativeAgentA2AGRPCListener {
    static let shared: Agents.NativeAgentA2AGRPCListener = NativeAgentEngine.makeA2AListener(engine: { .live }, bridge: { .shared })
}

extension AttentionRouter {
    static let shared = AttentionRouter(delivery: .engineDelivery(phone: { title, body, userInfo in
        try await NativeAgentEngine.liveDeviceSync.engine.sendNotificationToPairedDevices(
            title: title, body: body, userInfo: userInfo)
    }))
}
