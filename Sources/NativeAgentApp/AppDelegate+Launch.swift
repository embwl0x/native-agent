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
import ChatTurnRuntime
import ChatToolRuntime
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
import Connectors
import Browser
import Cognition
import OSLog
import os
import DeviceSync
import AppToolRuntime
import NativeAgentShared
// Blueprint: | `AppDelegate+Launch.swift` | `AppDelegate`: launch and turn-safe quit; closes external ingress, retains launch/approval observation settlement, joins the engine's shared quit sleep, retires browser IPC after tracked turns and wake runs |

extension AppDelegate {
    @MainActor private static var launchTask: Task<Void, Never>?
    @MainActor private static var bridgeLaunchWork: DispatchWorkItem?
    nonisolated private static let launchStopping = OSAllocatedUnfairLock(initialState: false)
    @MainActor private static var launchDidStart = false

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.launchDidStart else { return }
        Self.launchDidStart = true
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
        Self.launchTask = Task {
            defer { Self.launchTask = nil }
            await finishLaunching()
        }
    }

    @MainActor @objc func continuationAppActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != getpid() else { return }
        previousWorkApp = app
    }

    @MainActor
    private func finishLaunching() async {
        do { try await ApplicationLifetime.shared.prepare() }
        catch {
            guard !Task.isCancelled else { return }
            NSApp.terminate(nil)
            return
        }
        guard !Task.isCancelled else { return }
        NativeAgentShortcuts.updateAppShortcutParameters()
        approvalNotificationTask = Task { await NativeAgentApprovalNotifications.observe() }
        // Wire restart before the migration suspension: SwiftUI can already
        // accept turns while Workshop prepares its execution records.
        await AppRelaunch.shared.configure(
            scheduleTerminate: { graceSeconds in
                DispatchQueue.main.asyncAfter(deadline: .now() + graceSeconds) {
                    ModuleLog.app("[restart_app] settlement wait ended — terminating for relaunch")
                    // Off this main-queue block: a held quit spins a nested run
                    // loop, and the main queue cannot drain while one of its own
                    // blocks is still on the stack — MainActor work would stall.
                    RunLoop.main.perform(inModes: [.common]) {
                        MainActor.assumeIsolated { AppDelegate.terminateForRestart() }
                    }
                }
            },
            spawnRelauncher: { _ = try AppRelaunch.spawnDetached(argv: $0) }
        )
        guard !Task.isCancelled else { return }
        // Housekeeping, never awaited by launch: an older extension without
        // extension.reload, or a same-version resource change, still gets the
        // new copy. A reload request prepares the folder itself first.
        Task.detached(priority: .utility) { ChromeExtensionFolder.refreshIfPresent() }
        guard !Task.isCancelled else { return }
        await NativeAgentEngine.reconcileConnectorCredentialsAtLaunch(dataRoot: PersistenceCore.defaultDataRoot())
        guard !Task.isCancelled else { return }

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

        // Regular activation keeps the Dock icon visible while window closure leaves the runtime alive.
        NSApp.setActivationPolicy(.regular)

        // Speech consent belongs to a voice action. Only reconcile an existing
        // grant here, including changes made in System Settings between launches.
        NativeAgentEngine.reconcileSpeechPermissionAtLaunch(dataRoot: PersistenceCore.defaultDataRoot())

        // Process services start once launch and the shared model are ready,
        // independently of the main SwiftUI Window appearing.
        ApplicationLifetime.shared.applicationDidFinishLaunching()
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
            registerBackgroundTasks: Self.registerBackgroundTaskHandlers,
            waitForSenses: { try await SensesAssembly.waitUntilReady() },
            resumeMacTurn: { checkpoint, runtime in
                guard let model = await ApplicationLifetime.shared.appModel else { throw MacChatTurnLifecycleStoreError.invalidRecord }
                try await model.resumeMacChatTurn(checkpoint) { progress in
                    try await runtime.resumeTurn(checkpoint, progress: progress)
                }
            },
            approvals: .app())

        // ActivityWatcher owns the capture gate; call unconditionally and leave disabled or unreadable policy off.
        NativeAgentEngine.live.activityWatch.startAtLaunch()

        BrowserWindowController.shared.startIPCServer()
        // ClaudeBridge: localhost HTTP on 8771 so Claude (Claude Code
        // CLI) can query Agent's state, fire chat turns, and run tools
        // without UI click-through. Started
        // in the SAME lifecycle hook so menu-bar/background launches
        // (which never show the main window and never fire SwiftUI .task
        // modifiers) still bring the bridge up. The launch owns this work;
        // cancellation after either start closes anything it just installed.
        ModuleLog.app("[claude-bootstrap] dispatching ClaudeBridge.startServer on dispatch queue")
        // A closure written here would inherit main-actor isolation
        // (DispatchWorkItem's block is not @Sendable) and trap on the global
        // queue; the nonisolated function reference runs off main as intended.
        let bridgeWork = DispatchWorkItem(block: Self.startBridgesAtLaunch)
        Self.bridgeLaunchWork = bridgeWork
        DispatchQueue.global(qos: .userInitiated).async(execute: bridgeWork)
        let forwarder = ICloudIncomingTurnForwarder(sync: NativeAgentEngine.liveDeviceSync, port: EngineICloudIncomingTurnPort(
            engine: .live, client: { AppDelegate.residentIOSChatClient },
            received: { MacChatUnreadSessions.shared.received(in: $0) },
            presentation: {
                guard let appModel = ApplicationLifetime.shared.appModel else {
                    throw NSError(domain: "NativeAgentControlHandoff", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Mac chat is not attached"])
                }
                return appModel
            }))
        NativeAgentEngine.startDeviceSyncAtLaunch(
            forward: { await forwarder.forwardToSwiftRuntime($0) },
            registerLoginItem: AppDelegate.registerLoginItemInBackground)

    }

    nonisolated private static func startBridgesAtLaunch() {
        guard !launchStopping.withLock({ $0 }) else { return }
        ClaudeBridgeRuntime.shared.startSyncForBootstrap()
        guard !launchStopping.withLock({ $0 }) else { ClaudeBridgeRuntime.shared.stop(); return }
        NativeAgentA2AGRPCListener.shared.start()
        if launchStopping.withLock({ $0 }) {
            NativeAgentA2AGRPCListener.shared.stop()
            ClaudeBridgeRuntime.shared.stop()
        }
    }

    // Closing the last window leaves the menu-bar app running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @MainActor
    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task {
            do { try await ApplicationLifetime.shared.prepare() } catch { return }
            NativeAgentEngine.liveDeviceSync.bridge.cloudKitPushRegistrationSucceeded()
        }
    }

    @MainActor
    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task {
            do { try await ApplicationLifetime.shared.prepare() } catch { return }
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
            do { try await ApplicationLifetime.shared.prepare() } catch { return }
            guard NativeAgentEngine.liveDeviceSync.bridge.recognizesCloudKitRemoteNotification(payload) else { return }
            await NativeAgentEngine.liveDeviceSync.bridge.handleCloudKitPushWake(payload)
        }
    }

    /// Set while a restart_app quit is under way. Behind a lock, not the main
    /// actor: a held quit's waiter reads it while the main queue may be stuck.
    nonisolated private static let restartQuit = OSAllocatedUnfairLock(initialState: false)
    @MainActor private static var quitWaitingForTurns = false

    /// restart_app's quit waits for no turns: its origin already settled or hit its bound,
    /// and the relauncher reopens the bundle once we exit.
    /// A quit already held just stops waiting.
    @MainActor
    static func terminateForRestart() {
        restartQuit.withLock { $0 = true }
        NotificationCenter.default.post(name: NativeAgentEngine.quitRestartWake, object: nil)
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
    /// at Quit finish too. Bounded at 20s (restart_app has already waited for
    /// its origin's settlement): past it the quit goes ahead. The retained sleep
    /// still joins tracked turns before its final snapshot or dependency retirement.
    ///
    /// Then her sleep (`NativeAgentEngine.sleepMind`): one joinable settlement
    /// shared by this async hold and the termination drain. Neither bound
    /// owns the lifetime of that retained settlement.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ApplicationLifetime.shared.appModel != nil else { return .terminateNow }
        if Self.quitWaitingForTurns { return .terminateLater }
        closeQuitIngress()
        let producerDrain = NativeAgentEngine.beginQuitProducerSettlement(appLaunch: Self.launchTask,
            appObservers: [approvalNotificationTask].compactMap { $0 })
        let runs = NativeAgentEngine.live.turns.inFlightRunIDs()
        let settlement = NativeAgentEngine.beginQuitSleep(after: producerDrain, runs: runs,
            retireBrowser: { BrowserWindowController.shared.stopIPCServer() })
        let waitsForTurns = !runs.isEmpty && !Self.restartQuit.withLock({ $0 })
        Self.quitWaitingForTurns = true
        if waitsForTurns {
            ModuleLog.app("[quit] holding quit for %d in-flight turn(s), at most 20s", runs.count)
        }
        Task.detached {
            if waitsForTurns {
                await NativeAgentEngine.waitForInFlightTurnsBeforeQuit(runs,
                    isRestarting: { Self.restartQuit.withLock { $0 } })
            }
            let slept = await NativeAgentEngine.sleepMind(after: settlement)
            ModuleLog.app("[quit] her sleep: %@", slept)
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
    private func closeQuitIngress() {
        Self.launchTask?.cancel()
        Self.launchStopping.withLock { $0 = true }
        Self.bridgeLaunchWork?.cancel()
        NativeAgentEngine.stopLaunchWork()
        approvalNotificationTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        guard ApplicationLifetime.shared.appModel != nil else { return }
        // Close these ingress listeners now. Browser IPC also owns admitted
        // operations, so its full stop waits for the retained quit settlement.
        NativeAgentA2AGRPCListener.shared.stop()
        ClaudeBridgeRuntime.shared.stop()
        MainActor.assumeIsolated {
            MoodTintWeather.shared.stop()
            // The phone bridge and its snapshot projection are ingress too.
            // Stop them before cognition/loop drains: otherwise a late iCloud
            // action or cognition-change observation can start new snapshot
            // work while the process is trying to reach a terminal state.
            NativeAgentEngine.liveDeviceSync.bridge.tearDown()
        }
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        closeQuitIngress()
        guard ApplicationLifetime.shared.appModel != nil else { return }
        NativeAgentEngine.drainResidentWorkForTermination(
            shutdownSenses: { await SensesAssembly.shutdown() },
            retireBrowser: { BrowserWindowController.shared.stopIPCServer() })
    }

    @MainActor @objc private func contextFlowWillSleep(_ notification: Notification) {
        NativeAgentEngine.prepareContextForSleep()
    }

    @MainActor @objc private func contextFlowDidWake(_ notification: Notification) {
        NativeAgentEngine.reconcileContextAfterWake()
    }

}
