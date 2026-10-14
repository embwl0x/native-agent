import MacControl
import ActivityWatch
import ApprovalTransactions
import Agents
import Foundation
import AppKit
import UserNotifications
import AppIntents
import NativeAgentCore
import EngineRuntime
import WorkshopExecution
import SelfImprovement
import ChatOrchestration
import ChromeControl
import ContextFlow
import BackgroundLoops
import MemoryV2
import NotificationInbox
import PersistenceCore
import Desk
import Transcripts
import TurnTrace
import PersonaEngine
import Skills
import MCPDispatcher
import GitHubConnector
import SlackConnector
import Connectors
import Browser
import Cognition
import OSLog
import os
import DeviceSync
import AppToolRuntime
import NativeAgentShared

extension AppDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            previousWorkApp = app
        }
        NSWorkspace.shared.notificationCenter.addObserver(self,
            selector: #selector(continuationAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // A clicked banner has to reach the app: without a delegate, the
        // identity a Desk reminder carries goes nowhere.
        UNUserNotificationCenter.current().delegate = self
        NativeAgentEngine.installActionLabelsAtLaunch()
        NativeAgentNotificationActions.register()
        TurnContinuationRuntime.installReplyMirror()
        Task { await finishLaunching() }
    }

    @MainActor @objc func continuationAppActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != getpid() else { return }
        previousWorkApp = app
    }

    @MainActor
    private func finishLaunching() async {
        do { try await NativeAgentAppCoordinator.shared.prepare() }
        catch {
            NSApp.terminate(nil)
            return
        }
        NativeAgentShortcuts.updateAppShortcutParameters()
        approvalNotificationTask = Task { await NativeAgentApprovalNotifications.observe() }
        // Wire restart before the migration suspension: SwiftUI can already
        // accept turns while Workshop prepares its execution records.
        await AppRestartCoordinator.shared.configure(
            scheduleTerminate: { graceSeconds in
                DispatchQueue.main.asyncAfter(deadline: .now() + graceSeconds) {
                    ModuleLog.app("[restart_app] grace elapsed — terminating for relaunch")
                    // Off this main-queue block: a held quit spins a nested run
                    // loop, and the main queue cannot drain while one of its own
                    // blocks is still on the stack — MainActor work would stall.
                    RunLoop.main.perform(inModes: [.common]) {
                        MainActor.assumeIsolated { AppDelegate.terminateForRestart() }
                    }
                }
            },
            spawnRelauncher: AppRestartCoordinator.spawnDetached(argv:)
        )
        // Finish updating the folder before the runtime can ask Chrome to reload it.
        await Task.detached(priority: .utility) { ChromeExtensionFolder.refreshIfPresent() }.value
        do {
            try await NativeAgentEngine.prepareExecutionStorageAtLaunch(dataRoot: PersistenceCore.defaultDataRoot())
        } catch {
            ModuleLog.app("%@", "[workshop-migration] failed: \(error)")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Desk execution storage migration failed"
            alert.informativeText = "NativeAgent stopped before starting background work so no task state is lost. "
                + UserFacingError.advice(for: error)
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        await NativeAgentEngine.reconcileConnectorCredentialsAtLaunch(
            dataRoot: PersistenceCore.defaultDataRoot(), github: { .shared })

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(contextFlowWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(contextFlowDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NativeAgentEngine.startContextFlowAtLaunch(dataRoot: PersistenceCore.defaultDataRoot())

        // PATCH-2026-05-07: use .regular activation policy
        // so the dock icon stays visible. The
        // applicationShouldTerminateAfterLastWindowClosed = false hook still
        // keeps the app and background runtime alive when the user closes the
        // main window, so background work (dream cycle, consolidation,
        // proactive triggers) keeps running.
        NSApp.setActivationPolicy(.regular)

        // Speech consent belongs to a voice action. Only reconcile an existing
        // grant here, including changes made in System Settings between launches.
        NativeAgentEngine.reconcileSpeechPermissionAtLaunch(dataRoot: PersistenceCore.defaultDataRoot())

        // Process-wide app services and route retention must not depend on the
        // main SwiftUI Window appearing. The coordinator is configured from
        // NativeAgentApp.init with the shared AppModel, then started exactly
        // once from this guaranteed application lifecycle callback.
        NativeAgentAppCoordinator.shared.applicationDidFinishLaunching()
        NativeAgentEngine.startResidentWorkAtLaunch(
            dataRoot: PersistenceCore.defaultDataRoot(),
            embeddingDescriptorURL: Bundle.main.url(forResource: "embedding-download", withExtension: "json"),
            storageUnavailable: {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Memory did not open"
                alert.informativeText = "NativeAgent is running without memory this session: nothing is recalled or saved. Doctor shows the details under Live memory store."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            },
            reindexMemory: { await MemorySpotlightBootstrap.shared.reindexAll() },
            registerBackgroundTasks: Self.registerBackgroundTaskHandlers,
            waitForSenses: { try await SensesAssembly.waitUntilReady() },
            resumeMacTurn: { checkpoint, runtime in
                guard let model = await NativeAgentAppCoordinator.shared.appModel else { throw MacChatTurnLifecycleStoreError.invalidRecord }
                try await model.resumeMacChatTurn(checkpoint) { progress in
                    try await runtime.resumeTurn(checkpoint, progress: progress)
                }
            },
            repairPresentation: AppMemoryRepairPresentation(),
            momentsEnabled: { MomentsLaneSetting.isEnabled() },
            approvals: .app())

        // W8 (2026-08-14) — the ambient activity watcher.
        //
        // Called UNCONDITIONALLY, and that is deliberate. The decision about
        // whether to capture lives in exactly one place: the policy read inside
        // `ActivityWatcher.start()`, which installs no AX observer, no
        // workspace observer and no lock observer, and opens no span, when the
        // Trust Center toggle is off. A second `if` here would be a second gate
        // that can disagree with the first, and the outer one is always the one
        // a later refactor forgets. Default is OFF, and an unreadable policy
        // file decodes to OFF, so a fresh install captures nothing.
        Task { @MainActor in
            ActivityWatchController.shared.startAtLaunch()
        }

        // PATCH-2026-05-06: wkwebview-browser Start browser IPC server on this install's fixed port (8766).
        Task { @MainActor in
            BrowserWindowController.shared.startIPCServer()
        }
        // PATCH-2026-05-07: mac-control-bridge Start Mac Control bridge on its
        // fixed port (8770), so local mac-control calls execute under NativeAgent.app's bundle
        // identity (TCC attributes Automation/Accessibility/etc. to NativeAgent).
        // PATCH-2026-05-07: bridge-off-main Start on a background queue so
        // we don't compete with iCloudBridge.setup()'s synchronous-but-slow
        // ubiquity container query for MainActor time.
        DispatchQueue.global(qos: .userInitiated).async {
            MacControlBridge.shared.start()
        }
        // ClaudeBridge: localhost HTTP on 8771 so Claude (Claude Code
        // CLI) can query Agent's state, fire chat turns, and run tools
        // without UI click-through. Sibling of MacControlBridge — started
        // in the SAME lifecycle hook so menu-bar/background launches
        // (which never show the main window and never fire SwiftUI .task
        // modifiers) still bring the bridge up. (Previously wired in
        // MainWindowContent's .task — silently never fired.) Synchronous
        // DispatchQueue dispatch (not Task.detached) so the actor isolation
        // can't defer it past application launch finish — mirrors
        // MacControlBridge above.
        ModuleLog.app("[claude-bootstrap] dispatching ClaudeBridge.startServer on dispatch queue")
        DispatchQueue.global(qos: .userInitiated).async {
            ClaudeBridgeRuntime.shared.startSyncForBootstrap()
            NativeAgentA2AGRPCListener.shared.start()
        }
        let forwarder = ICloudIncomingTurnForwarder(port: EngineICloudIncomingTurnPort(
            engine: .live, client: { AppDelegate.residentIOSChatClient },
            received: { MacChatUnreadSessions.shared.received(in: $0) },
            presentation: {
                guard let appModel = NativeAgentAppCoordinator.shared.appModel else {
                    throw NSError(domain: "NativeAgentControlHandoff", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Mac chat is not attached"])
                }
                return appModel
            }))
        NativeAgentEngine.startDeviceSyncAtLaunch(
            forward: { await forwarder.forwardToSwiftRuntime($0) },
            registerLoginItem: AppDelegate.registerLoginItemInBackground)

    }

    // PATCH-2026-05-07: app-owned runtime Don't quit when the user closes the
    // last window — the menu-bar app is still running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @MainActor
    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task {
            do { try await NativeAgentAppCoordinator.shared.prepare() } catch { return }
            NativeAgentEngine.liveDeviceSync.bridge.cloudKitPushRegistrationSucceeded()
        }
    }

    @MainActor
    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task {
            do { try await NativeAgentAppCoordinator.shared.prepare() } catch { return }
            NativeAgentEngine.liveDeviceSync.bridge.cloudKitPushRegistrationFailed(error)
        }
    }

    @MainActor
    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        let payload = Dictionary(uniqueKeysWithValues: userInfo.map {
            (AnyHashable($0.key), $0.value)
        })
        Task { @MainActor in
            do { try await NativeAgentAppCoordinator.shared.prepare() } catch { return }
            guard NativeAgentEngine.liveDeviceSync.bridge.recognizesCloudKitRemoteNotification(payload) else { return }
            await NativeAgentEngine.liveDeviceSync.bridge.handleCloudKitPushWake()
        }
    }

    /// Set while a restart_app quit is under way. Behind a lock, not the main
    /// actor: a held quit's waiter reads it while the main queue may be stuck.
    nonisolated private static let restartQuit = OSAllocatedUnfairLock(initialState: false)
    @MainActor private static var quitWaitingForTurns = false

    /// restart_app's quit waits for no turns: its grace was their allowance,
    /// and the relauncher reopens the bundle once we exit.
    /// A quit already held just stops waiting.
    @MainActor
    static func terminateForRestart() {
        restartQuit.withLock { $0 = true }
        if quitWaitingForTurns { return }
        NSApp.terminate(nil)
        // Reached only when the quit was refused (a modal vetoed it): a later
        // ordinary Quit must still wait for its turns.
        restartQuit.withLock { $0 = false }
    }

    /// Turn-safe quit. A Quit that lands mid-turn (menu, install_app.sh's
    /// AppleScript quit, logout, restart_app) used to kill the turn and lose
    /// its reply. Tool receipts are already durable as each tool finishes
    /// (appendToolMessage → appendJSONLDurable); this lets the turns running
    /// at Quit finish too. Bounded at 20s (none on restart_app): past it the quit
    /// goes ahead and a hung turn dies as before. Turns accepted after Quit
    /// are not waited on.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard NativeAgentAppCoordinator.shared.appModel != nil else { return .terminateNow }
        if Self.quitWaitingForTurns { return .terminateLater }
        let runs = NativeAgentEngine.live.turns.inFlightRunIDs()
        guard !runs.isEmpty, !Self.restartQuit.withLock({ $0 }) else { return .terminateNow }
        Self.quitWaitingForTurns = true
        ModuleLog.app("[quit] holding quit for %d in-flight turn(s), at most 20s", runs.count)
        Task.detached {
            await NativeAgentEngine.waitForInFlightTurnsBeforeQuit(runs,
                isRestarting: { Self.restartQuit.withLock { $0 } })
            // A run-loop block, not MainActor.run: if the Quit came from inside
            // a main-queue block (a MainActor task), the main queue cannot drain
            // until that block returns, and the reply would never be delivered.
            let main = CFRunLoopGetMain()
            CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            CFRunLoopWakeUp(main)
        }
        return .terminateLater
    }

    // runtime integration + background loops: drain Swift-native subsystems
    // before process exit.
    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        approvalNotificationTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        guard NativeAgentAppCoordinator.shared.appModel != nil else { return }
        // Stop the loopback bridges first, synchronously: once the listeners are
        // cancelled and their token/descriptor files are gone, no new request can
        // land mid-drain and no stale credential outlives the process.
        NativeAgentA2AGRPCListener.shared.stop()
        ClaudeBridgeRuntime.shared.stop()
        MacControlBridge.shared.stop()
        MainActor.assumeIsolated {
            BrowserWindowController.shared.stopIPCServer()
            MoodTintWeather.shared.stop()
            // The phone bridge and its snapshot projection are ingress too.
            // Stop them before cognition/loop drains: otherwise a late iCloud
            // action or cognition-change observation can start new snapshot
            // work while the process is trying to reach a terminal state.
            NativeAgentEngine.liveDeviceSync.bridge.tearDown()
        }

        NativeAgentEngine.drainResidentWorkForTermination(
            shutdownSenses: { await SensesAssembly.shutdown() },
            makeActivityWatchDrain: { ActivityWatchController.shared.makeTerminationDrain() })
    }

    @objc private func contextFlowWillSleep(_ notification: Notification) {
        NativeAgentEngine.prepareContextForSleep()
    }

    @objc private func contextFlowDidWake(_ notification: Notification) {
        NativeAgentEngine.reconcileContextAfterWake()
    }

}
