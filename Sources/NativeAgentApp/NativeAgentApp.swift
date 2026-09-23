import SwiftUI
import UserNotifications
// PATCH-2026-05-07: app-owned runtime SMAppService for login auto-start
import ServiceManagement
import NativeAgentShared
// PATCH-2026-05-30: Swift-native runtime integration anchor. Subsystems dispatch
// through AppDelegate.nativeAgentRuntime and fail closed when a Swift
// implementation is not wired.
import NativeAgentCore
import ProviderRouting
import StandingBots
import WorkshopExecution
import SelfImprovement
import ChatOrchestration
import MCPDispatcher
import BackgroundLoops
import MemoryV2
import DreamREMCycle
import PersistenceCore
import PersonaEngine
import OSLog
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

final class WakeResetThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFire: Date = .distantPast

    func shouldFire(now: Date = Date(), minimumInterval: TimeInterval = 30) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Wall-clock corrections can move backwards. Treat that as a new
        // epoch instead of permanently throttling sleep recovery until the
        // clock catches up with a timestamp that no longer exists.
        if now < lastFire {
            lastFire = now
            return true
        }
        guard now.timeIntervalSince(lastFire) >= minimumInterval else { return false }
        lastFire = now
        return true
    }

    @discardableResult
    func handleWake(
        resetEffect: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { completion in
            URLSession.shared.reset(completionHandler: completion)
        },
        resetCompleted: @escaping @Sendable () -> Void = {
            NSLog("[wake] URLSession.shared reset after sleep")
        }
    ) -> Bool {
        guard shouldFire() else {
            NSLog("[wake] throttled — last fire was <30s ago, skipping URLSession reset")
            return false
        }
        resetEffect(resetCompleted)
        return true
    }
}

@MainActor
private final class NativeAgentHotkeyBootstrap {
    static let shared = NativeAgentHotkeyBootstrap()

    private let voice = VoiceInputController()
    private var voiceTurn: GlobalHotkeyVoiceTurn?
    private var wakeObserverToken: NSObjectProtocol?

    func start(appModel: AppModel) {
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
        guard !NativeAgentLaunchPreflight.shouldSuppressGUIStart() else {
            NativeAgentLaunchPreflight.writeSuppressedLaunchReceipt()
            return
        }

        // Public first-run quarantine must finish before SwiftUI constructs
        // NativeAgentApp. App.init creates AppModel, which can initialize the
        // process-wide MemoryV2 SQLite owner. Moving the data root afterward
        // leaves that actor attached to the backup inode while later lazy
        // projections open the new root, splitting one memory commit across
        // two databases. Claim the process first so a second launch can never
        // move storage beneath an already-running app, then prepare the root
        // before any state owner exists.
        _ = NSApplication.shared
        guard AppDelegate.claimSingleAppInstance() else { return }
        if case .failed(let error) = NativeAgentPaths.preparePublicReleaseDataRootIfNeeded() {
            AppDelegate.presentPublicReleaseDataRootError(error)
            return
        }
        do {
            _ = try NativeClient.resumeStagedBackupRestoreAtLaunch(
                dataRoot: NativeAgentPaths.dataRoot
            )
        } catch {
            AppDelegate.presentBackupRestoreError(error.localizedDescription)
            return
        }
        NativeAgentApp.main()
    }
}

struct NativeAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel: AppModel
    // RELEASE-2026-05-06: Sparkle updater controller (Task 4.3)
    @State private var updateController = UpdateController.shared
    // PATCH-2026-05-06: wkwebview-browser Start IPC server at app launch
    @State private var browserController = BrowserWindowController.shared
    @AppStorage("nativeagent.darkMode") private var preferDarkAppearance = true
    @State private var appearance = AppearanceController.shared
    @AppStorage("showDeveloperSurfaces") private var showDeveloperSurfaces = false

    init() {
        // User, 2026-09-23: no way back to the classic sidebar; anyone left on
        // it lands in the current shell.
        UserDefaults.standard.removeObject(forKey: NativeAgentShellPreference.classicShellKey)
        // User, 2026-09-03: native text on this app looked heavy next to the
        // Claude desktop app's. That app is Chromium, which draws without
        // macOS font smoothing (stem darkening). Turn it off for this process
        // too; CoreGraphics reads the key from the app's own defaults domain
        // at start, so the first launch that sets it renders the old way and
        // every launch after renders thin and crisp.
        if !UserDefaults.standard.bool(forKey: "CGFontRenderingFontSmoothingDisabled") {
            UserDefaults.standard.set(true, forKey: "CGFontRenderingFontSmoothingDisabled")
        }
        // Writing to a dead subprocess's stdin pipe (MCP children, builder
        // tools, invoke_claude) delivers SIGPIPE, which kills the entire
        // app by default. With SIG_IGN the write fails with EPIPE instead
        // and surfaces as a normal error. App.init runs before any delegate
        // callback or subprocess spawn, so this is the earliest hook.
        signal(SIGPIPE, SIG_IGN)

        // User, 2026-09-13: "if you've missed anything, it needs to be up there
        // on Providers." The three Providers groups and the routed surface list
        // must cover each other exactly, or some lane resolves a model nobody
        // can see or change. Say so at launch rather than discovering it as a
        // lane that quietly follows Chat.
        // A bot runs on the tuple it was made with, and the check that its route
        // is connected and still offers that model lives where the catalogs are.
        // StandingBots owns scheduling, not provider catalogs, so the app hands
        // it the live check here (2026-09-13 review).
        // Early for bot_ask from chat; launch installs it again right before
        // the loops start so a due bot is never skipped on a lost race.
        Task { await installBotProviderCheck() }

        if let mismatch = ProviderSurfaceGroups.membershipMismatch() {
            FileHandle.standardError.write(Data(
                "[providers] surface groups and MODEL_SURFACES disagree — \(mismatch)\n".utf8
            ))
            assertionFailure("Providers group membership: \(mismatch)")
        }

        let appModel = AppModel()
        _appModel = State(initialValue: appModel)

        // The quiet self-administration tools read and set the app's own
        // pages, so they need the SAME model the window is bound to — a second
        // AppModel would read state the visible page never sees. Same handoff
        // DetachedChatWindowController gets below, done here because the tools
        // can be called before any detached chat is restored.
        QuietSelfAdmin.shared.attach(appModel: appModel)

        // A resolved card resumes the request it suspended, and it does that
        // through the SAME model the window is bound to — the continuation
        // lands in the conversation the person is looking at, not in a second
        // AppModel's idea of one. Same reason QuietSelfAdmin is handed this
        // instance directly above.
        //
        // The acceptance is REPORTED, not discarded: a rejected admission has
        // to reach the resolver, or the durable "resumed" claim stands over a
        // turn that never ran and the card is stranded for good.
        InlineInteractionResolver.startTurn = { prompt, sessionID, hideUserBubble in
            let acceptance = await appModel.sendChat(
                prompt, sessionId: sessionID, hideUserBubble: hideUserBubble
            )
            switch acceptance {
            case .accepted, .queued: return true
            case .rejected: return false
            }
        }

        // The blocked call, replayed with the arguments the model originally
        // wrote, through the ORDINARY gate: the same membrane a first call
        // passes, with no autonomy bypass and no approval inherited from the
        // card. Resolving "connect GitHub" is not permission to act as GitHub.
        //
        // It is the SAME dispatcher and the SAME approval inbox Mac chat uses.
        // A bare SwiftToolDispatcher cannot reach the app-owned tools at all,
        // and a nil filer makes every CONFIRM-tier call fail closed with no
        // request ever landing in front of the person — a card resolved into
        // silence.
        InlineInteractionResolver.replayBlockedTool = { toolName, argumentsJSON, sessionID, origin in
            guard case .object(let input)? = try? JSONValue.parse(Data(argumentsJSON.utf8))
            else { return .failed("the blocked call's arguments are no longer readable") }
            let dataRoot = PersistenceCore.defaultDataRoot()
            // The ORIGIN surface answers for this call, not the Mac.
            //
            // The replay used to build the Mac profile and dispatch under
            // surface "chat" whatever the card came from, so a card raised from
            // the phone with remote_from_ios_allowed false — or from a Telegram
            // chat that is not on the allowlist — replayed as a trusted local
            // call. The envelope the raising turn wrote on the card's own row is
            // bound here instead, and the profile comes from ITS surface.
            // Absent (a card older than the envelope) keeps the Mac default,
            // which is the only honest reading of a local-only transcript.
            let originSurface = origin?.surface ?? NativeAgentAppChatSurfaceProfile.mac.rawValue
            let profile = NativeAgentAppChatSurfaceProfile(rawValue: originSurface.lowercased())
                ?? NativeAgentAppChatSurfaceProfile.mac
            let approvalFiler = NativeAgentChatApprovalFiler(dataRoot: dataRoot)
            let gated = makeGatedToolDispatchClient(
                tools: makeNativeAgentAppToolDispatchClient(
                    includeEvolutionBridge: profile.includesEvolutionBridge,
                    denyExternalMcp: profile.deniesExternalMCP,
                    // The gate below resolves autonomy once, as it does for an
                    // ordinary Mac turn; the inner dispatcher must not re-run
                    // that decision from a reconstructed origin.
                    enforceAppAutonomy: false,
                    swarmApprovalFiler: approvalFiler,
                    dataRoot: dataRoot
                ),
                fileAccess: "auto",
                approvalFiler: approvalFiler,
                dataRoot: dataRoot
            )
            // Only the replayed tool is rehydrated: a lazy gate must not answer
            // `not_loaded` for the one call being replayed, and no sibling tool
            // gets an accidental capability out of it.
            do {
                let result = try await LLMCallContext.$turnActiveTools.withValue([toolName]) {
                    // The whole origin envelope — verified chat/user ids and
                    // the reply route included — so the gate resolves trust
                    // from the same identities the first attempt was judged on.
                    try await ChatToolSessionContext.$envelope.withValue(origin) {
                    try await ChatToolSessionContext.$verifiedChatId
                        .withValue(origin?.verifiedChatId) {
                    try await ChatToolSessionContext.$verifiedUserId
                        .withValue(origin?.verifiedUserId) {
                    try await ChatToolSessionContext.$commandSignatureVerified
                        .withValue(origin?.commandSignatureVerified) {
                    try await ChatToolSessionContext.$verifiedSessionId.withValue(sessionID) {
                        try await ChatToolSessionContext.$replyRoute
                            .withValue(origin?.deliveryRoute) {
                                try await gated.dispatch(
                                    tool: toolName, input: input, surface: originSurface
                                )
                            }
                    }
                    }
                    }
                    }
                    }
                }
                return .dispatched(try? result.serialize(pretty: false))
            } catch {
                // A throw means the call never completed. Reported as such so
                // the resolver does not record a replay that did not happen.
                return .failed("\(error)")
            }
        }

        // The pairing half of the card's signature receipt.
        //
        // A card raised by a signed iPhone turn has to be able to replay AS a
        // signed turn, and the persisted envelope must never carry that
        // verdict itself. So the continuation carries a MAC over its own row
        // identity, minted here from the live pairing secret and re-checked
        // here at replay. A rotated or missing secret simply stops verifying,
        // and the card says "sign in from the phone again" instead of
        // replaying with authority it can no longer prove.
        InlineInteractionSignatureWitness.install(
            mint: { canonical in
                guard let secret = try? PairingSecretManager.loadOrGenerateSecret()
                else { return nil }
                return BridgeMessage.hmacHex(of: Data(canonical.utf8), secret: secret)
            },
            verify: { canonical, receipt in
                guard let secret = try? PairingSecretManager.loadOrGenerateSecret()
                else { return false }
                let expected = BridgeMessage.hmacHex(of: Data(canonical.utf8), secret: secret)
                let a = Array(receipt.utf8), b = Array(expected.utf8)
                guard a.count == b.count else { return false }
                var diff: UInt8 = 0
                for i in 0..<a.count { diff |= a[i] ^ b[i] }
                return diff == 0
            }
        )

        NativeAgentAppCoordinator.shared.configureProcessBootstrap(.init(
            restoreDetachedChats: {
                DetachedChatWindowController.shared.attach(appModel: appModel)
                DetachedChatWindowController.shared.restoreFromPersist()
                Task { @MainActor in
                    await appModel.loadChatState()
                }
            },
            startPermissionSync: {
                MacIntegrationICloudBridge.shared.startObserving()
            },
            wireGlobalHotkey: {
                NativeAgentHotkeyBootstrap.shared.start(appModel: appModel)
            },
            warmEmbeddings: {
                Task.detached(priority: .utility) {
                    await maybeWarmEmbeddingsForFastMode()
                }
            }
        ))
    }

    var body: some Scene {
        // PATCH-2026-05-07: single-window-main Window (vs WindowGroup) is
        // single-instance — clicking the menu-bar "Open NativeAgent" item or
        // calling openWindow(id: "main") reuses the existing window instead
        // of stacking new copies on top.
        Window("NativeAgent", id: "main") {
            // PATCH-2026-05-29: restart-controls — MainWindowContent wraps
            // ContentView to add the ever-present top toolbar (runtime health dot +
            // Restart App).
            MainWindowContent()
                .environment(appModel)
                // 2026-09-15: the window carries the agent's NAME once it has
                // one. `Window(_:id:)` takes a static key, so the live title is
                // set here where `agentDisplayName` can be observed — which is
                // what makes the first conversation's "the name at the top of
                // this window" true on the very next frame after the rename.
                .navigationTitle(appModel.agentAddressName)
                // User, 2026-09-02: never a nil scheme. AppearanceController
                // answers dark or light for both layers; "off" follows the
                // system live. See AppearanceController.swift.
                .preferredColorScheme(appearance.colorScheme)
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
                    Task { await appModel.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            // PATCH-2026-05-06: wkwebview-browser Window > Browser menu item
            CommandGroup(after: .windowList) {
                Button("Browser") {
                    BrowserWindowController.shared.showWindow()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
            }
            CommandMenu("Navigate") {
                Button("Command palette…") {
                    NotificationCenter.default.post(name: .openCommandPaletteRequest, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Divider()
                // D7: derived from SidebarItem.primaryItems so ⌘N is whatever
                // the sidebar shows in position N. Do not hand-add entries here.
                ForEach(NavigateMenuPresentation.entries) { entry in
                    Button(entry.title) {
                        NativeAgentAppCoordinator.shared.request(.sidebar(entry.item))
                    }
                    .keyboardShortcut(entry.shortcut.map {
                        KeyboardShortcut(KeyEquivalent($0), modifiers: .command)
                    })
                }
                // B2.2 review fix (gpt-5.5 BLOCKING): Knowledge Graph is a
                // developer-gated surface — its menu entry hides with the gate
                // (explicit deep links still resolve). It carries no digit: the
                // digits belong to the sidebar's primary order.
                if NativeAgentShellPreference.developerSurfacesShown(showDeveloperSurfaces) {
                    Button("Knowledge graph") { NativeAgentAppCoordinator.shared.request(.sidebar(.knowledge)) }
                }
                Divider()
                Button("Approvals") { NativeAgentAppCoordinator.shared.request(.activity(.approvals)) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Inbox") { NativeAgentAppCoordinator.shared.request(.activity(.inbox)) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        // One Settings page: Command-comma opens the same SetupView the
        // sidebar's Settings opens. SlimSettingsView survives only as the
        // classic sidebar's Settings (ContentView).
        Settings {
            SetupView()
                .environment(appModel)
                // User, 2026-09-02: never a nil scheme. AppearanceController
                // answers dark or light for both layers; "off" follows the
                // system live. See AppearanceController.swift.
                .preferredColorScheme(appearance.colorScheme)
                .onChange(of: preferDarkAppearance, initial: true) { _, dark in
                    appearance.setPreferDark(dark)
                }
                .frame(width: 760, height: 720)
        }

        MenuBarExtra("NativeAgent", systemImage: "brain.head.profile") {
            // PATCH-2026-05-07: app-owned runtime Under .accessory activation
            // policy the dock icon is hidden, so we have to explicitly bring
            // the main window to front (or open it if all instances closed).
            MenuBarOpenButton()
            Button("Refresh status", systemImage: "arrow.clockwise") {
                Task { await appModel.refreshAll() }
            }
            Divider()
            Button("Run health checks", systemImage: "stethoscope") {
                Task {
                    await appModel.runDoctor(repair: false)
                    NativeAgentNotifications.post(title: "NativeAgent health checks", body: appModel.statusText)
                }
            }
            Button("Show browser window", systemImage: "safari") {
                BrowserWindowController.shared.showWindow()
            }
            Divider()
            // PATCH-2026-05-29: restart-controls — mirror the toolbar restart
            // controls in the menu bar so they're reachable when the main window
            // isn't focused (or is closed). Restart App relaunches directly here;
            // the in-window button keeps the confirmation alert.
            Button("Restart app", systemImage: "arrow.triangle.2.circlepath") {
                AppRelauncher.relaunchApp()
            }
            Divider()
            // D7: ONE truth line — see MenuBarStatusPresentation. The stacked
            // pair could contradict itself ("Ready" over "unavailable").
            Text(MenuBarStatusPresentation.line(
                statusText: appModel.statusText,
                health: appModel.health
            ))
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
            get: { ActivityWatchController.shared.isCapturing },
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
            controller.setCaptureEnabled(false)
        }
        Button("Activity settings…", systemImage: "gear") {
            NSApp.activate(ignoringOtherApps: true)
            NativeAgentAppCoordinator.shared.request(.sidebar(.trust))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// A click on a banner OPENS what the banner was about. It never approves,
    /// runs, or closes anything — a Desk reminder lands on its own item.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let handle = NativeAgentNotificationRoute.deskHandle(in: userInfo) {
            Task { @MainActor in
                _ = NativeAgentAppCoordinator.shared.request(.sidebar(.desk))
                // The handle WAITS on the model. Posting it here lost the click
                // whenever the Desk page was not already mounted (no
                // subscriber) or had not finished loading (nothing to scroll
                // to); the page takes it when it can actually show the item.
                QuietSelfAdmin.shared.appModel?.pendingDeskHandle = handle
            }
        }
        completionHandler()
    }

    /// Paired iPhone chat is the same resident mind with its own closed remote
    /// surface profile. Reuse never crosses into Mac/bridge-only evolution or
    /// approval policy.
    static let residentIOSChatClient = makeNativeAgentAppChatOrchestrationClient(
        profile: .ios
    )
}

/// The bot provider check (see App.init). Idempotent.
func installBotProviderCheck() async {
    await BotRunGate.installLiveCheck { bot, dataRoot in
        await SwiftNativeProviderRouting(dataRoot: dataRoot).botChoiceRejection(
            provider: bot.provider,
            model: bot.model,
            reasoningEffort: bot.reasoningEffort
        )
    }
}
