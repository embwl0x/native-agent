import SwiftUI
// PATCH-2026-05-07: app-owned runtime SMAppService for login auto-start
import ServiceManagement
import NativeAgentShared
// PATCH-2026-05-30: Swift-native runtime integration anchor. Subsystems dispatch
// through AppDelegate.nativeAgentRuntime and fail closed when a Swift
// implementation is not wired.
import NativeAgentCore
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

private final class WakeResetThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFire: Date = .distantPast

    func shouldFire(now: Date = Date(), minimumInterval: TimeInterval = 30) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now.timeIntervalSince(lastFire) >= minimumInterval else { return false }
        lastFire = now
        return true
    }
}

@MainActor
private final class NativeAgentHotkeyBootstrap {
    static let shared = NativeAgentHotkeyBootstrap()

    private let voice = VoiceInputController()
    private var wakeObserverToken: NSObjectProtocol?

    func start(appModel: AppModel) {
        let hotkeyManager = GlobalHotkeyManager.shared
        let voice = self.voice
        hotkeyManager.onOpenWindow = {
            Task { @MainActor in
                SpotlightOverlay.shared.toggle()
            }
        }
        hotkeyManager.onVoiceStart = {
            Task { @MainActor in
                let granted = await voice.requestPermission()
                guard granted else {
                    NativeAgentNotifications.post(
                        title: "Voice input unavailable",
                        body: voice.errorMessage ?? "Microphone or speech recognition permission was denied."
                    )
                    return
                }
                guard hotkeyManager.isVoiceHoldCurrent() else { return }
                voice.startListening()
            }
        }
        hotkeyManager.onVoiceEnd = {
            Task { @MainActor in
                let transcript = await voice.stopListening()
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                await appModel.sendChat(trimmed)
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
            guard wakeThrottle.shouldFire() else {
                NSLog("[wake] throttled — last fire was <30s ago, skipping URLSession reset")
                return
            }
            URLSession.shared.reset {
                NSLog("[wake] URLSession.shared reset after sleep")
            }
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
    @AppStorage("nativeagent.darkMode") private var preferDarkAppearance = false
    @AppStorage("showDeveloperSurfaces") private var showDeveloperSurfaces = false

    init() {
        // Writing to a dead subprocess's stdin pipe (MCP children, builder
        // tools, invoke_claude) delivers SIGPIPE, which kills the entire
        // app by default. With SIG_IGN the write fails with EPIPE instead
        // and surfaces as a normal error. App.init runs before any delegate
        // callback or subprocess spawn, so this is the earliest hook.
        signal(SIGPIPE, SIG_IGN)

        let appModel = AppModel()
        _appModel = State(initialValue: appModel)

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
            },
            runInitialDoctor: {
                Task(priority: .background) { @MainActor in
                    await appModel.runDoctor(repair: false)
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
                .preferredColorScheme(preferDarkAppearance ? .dark : nil)
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
                Button("Refresh Status") {
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
                Button("Command Palette…") {
                    NotificationCenter.default.post(name: .openCommandPaletteRequest, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Chat") { NativeAgentAppCoordinator.shared.request(.sidebar(.chat)) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Activity") { NativeAgentAppCoordinator.shared.request(.sidebar(.activity)) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Memories") { NativeAgentAppCoordinator.shared.request(.sidebar(.memories)) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Workshop") { NativeAgentAppCoordinator.shared.request(.sidebar(.workshop)) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Personality") { NativeAgentAppCoordinator.shared.request(.sidebar(.personality)) }
                    .keyboardShortcut("5", modifiers: .command)
                Button("Trust") { NativeAgentAppCoordinator.shared.request(.sidebar(.trust)) }
                    .keyboardShortcut("6", modifiers: .command)
                Button("Providers") { NativeAgentAppCoordinator.shared.request(.sidebar(.providers)) }
                    .keyboardShortcut("7", modifiers: .command)
                // B2.2 review fix (gpt-5.5 BLOCKING): Knowledge Graph is a
                // developer-gated surface — its menu entry hides with the gate
                // (Cmd+8 goes with it; explicit deep links still resolve).
                if showDeveloperSurfaces {
                    Button("Knowledge Graph") { NativeAgentAppCoordinator.shared.request(.sidebar(.knowledge)) }
                        .keyboardShortcut("8", modifiers: .command)
                }
                Button("Settings") { NativeAgentAppCoordinator.shared.request(.sidebar(.settings)) }
                    .keyboardShortcut("9", modifiers: .command)
                Divider()
                Button("Approvals") { NativeAgentAppCoordinator.shared.request(.activity(.approvals)) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Inbox") { NativeAgentAppCoordinator.shared.request(.activity(.inbox)) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        Settings {
            SlimSettingsView()
                .environment(appModel)
                .preferredColorScheme(preferDarkAppearance ? .dark : nil)
                .frame(width: 760, height: 720)
        }

        MenuBarExtra("NativeAgent", systemImage: "brain.head.profile") {
            // PATCH-2026-05-07: app-owned runtime Under .accessory activation
            // policy the dock icon is hidden, so we have to explicitly bring
            // the main window to front (or open it if all instances closed).
            MenuBarOpenButton()
            Button("Refresh Status", systemImage: "arrow.clockwise") {
                Task { await appModel.refreshAll() }
            }
            Divider()
            Button("Run Doctor", systemImage: "stethoscope") {
                Task {
                    await appModel.runDoctor(repair: false)
                    NativeAgentNotifications.post(title: "NativeAgent Doctor", body: appModel.statusText)
                }
            }
            Button("Show Browser Window", systemImage: "safari") {
                BrowserWindowController.shared.showWindow()
            }
            Divider()
            // PATCH-2026-05-29: restart-controls — mirror the toolbar restart
            // controls in the menu bar so they're reachable when the main window
            // isn't focused (or is closed). Restart App relaunches directly here;
            // the in-window button keeps the confirmation alert.
            Button("Restart App", systemImage: "arrow.triangle.2.circlepath") {
                AppRelauncher.relaunchApp()
            }
            Divider()
            Text(appModel.statusText)
            if let health = appModel.health {
                Text(health.ok ? "Native runtime online" : "Native runtime unavailable")
            }
        }
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Paired iPhone chat is the same resident mind with its own closed remote
    /// surface profile. Reuse never crosses into Mac/bridge-only evolution or
    /// approval policy.
    static let residentIOSChatClient = makeNativeAgentAppChatOrchestrationClient(
        profile: .ios
    )
}
