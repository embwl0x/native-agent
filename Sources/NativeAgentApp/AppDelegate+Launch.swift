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
// Blueprint: | `AppDelegate+Launch.swift` | `AppDelegate`: Launch, turn-safe quit, ingress retirement and shared sleep settlement |

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
        // A notification delegate is required to deliver the Desk reminder's identity to the app.
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
        // Wire restart before migration suspends because SwiftUI can already accept turns.
        await AppRelaunch.shared.configure(
            scheduleTerminate: { graceSeconds in
                DispatchQueue.main.asyncAfter(deadline: .now() + graceSeconds) {
                    ModuleLog.app("[restart_app] settlement wait ended — terminating for relaunch")
                    // Leave the main-queue block before holding quit; its nested run loop cannot drain MainActor work while that block remains
                    // stacked.
                    RunLoop.main.perform(inModes: [.common]) {
                        MainActor.assumeIsolated { AppDelegate.terminateForRestart() }
                    }
                }
            },
            spawnRelauncher: { _ = try AppRelaunch.spawnDetached(argv: $0) }
        )
        guard !Task.isCancelled else { return }
        // Do not await folder preparation during launch; a reload request prepares the folder before using it.
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

        // Speech consent belongs to a voice action; launch only reconciles an existing grant.
        NativeAgentEngine.reconcileSpeechPermissionAtLaunch(dataRoot: PersistenceCore.defaultDataRoot())

        // Start process services independently of the window so background launches have the same runtime.
        ApplicationLifetime.shared.applicationDidFinishLaunching()
        NativeAgentEngine.startResidentWorkAtLaunch(
            dataRoot: PersistenceCore.defaultDataRoot(),
            embeddingDescriptorURL: Bundle.main.url(forResource: "embedding-download", withExtension: "json"),
            storageUnavailable: {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Memory did not open"
                alert.informativeText = """
                    NativeAgent is running without memory this session: nothing is recalled or saved. Doctor shows the details under Live \
                    memory store.
                    """
                alert.addButton(withTitle: "OK")
                alert.runModal()
            },
            registerBackgroundTasks: Self.registerBackgroundTaskHandlers,
            resumeMacTurn: { checkpoint, runtime in
                guard let model = await ApplicationLifetime.shared.appModel else { throw MacChatTurnLifecycleStoreError.invalidRecord }
                try await model.resumeMacChatTurn(checkpoint) { turn in
                    try await runtime.resumeTurn(checkpoint, turn: turn)
                }
            },
            approvals: .app())

        // Call unconditionally because ActivityWatcher owns the capture gate, including disabled and unreadable policy.
        NativeAgentEngine.live.activityWatch.startAtLaunch()

        BrowserWindowController.shared.startIPCServer()
        // Start the local bridge in the process lifecycle so background launches expose it too; launch cancellation closes newly installed listeners.
        ModuleLog.app("[claude-bootstrap] dispatching ClaudeBridge.startServer on dispatch queue")
        // A closure here inherits main-actor isolation and traps on the global queue; use a nonisolated reference for DispatchWorkItem.
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
            forward: { await forwarder.forwardToSwiftRuntime($0, route: $1) },
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

    // Closing the last window must leave the menu-bar runtime alive.
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

    /// A held quit may block the main queue, so its restart flag must be lock-protected rather than main-actor isolated.
    nonisolated private static let restartQuit = OSAllocatedUnfairLock(initialState: false)
    @MainActor private static var quitWaitingForTurns = false

    /// Restart has already bounded its origin's settlement; skip the turn wait and release any held quit so the relauncher can reopen.
    @MainActor
    static func terminateForRestart() {
        restartQuit.withLock { $0 = true }
        NotificationCenter.default.post(name: NativeAgentEngine.quitRestartWake, object: nil)
        if quitWaitingForTurns { return }
        NSApp.terminate(nil)
        // Clear restart intent after a modal veto so an ordinary Quit still waits for turns.
        restartQuit.withLock { $0 = false }
    }

    /// Bound the turn wait at 20 seconds so Quit remains responsive while active replies get time to finish.
    /// The retained sleep joins tracked turns before its final snapshot or dependency retirement.
    /// The async hold and termination drain share one joinable settlement; neither wait bound owns its lifetime.
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
            ModuleLog.app("[quit] the agent's sleep: %@", slept)
            // Use a run-loop block because MainActor.run cannot drain until an originating main-queue block returns.
            let main = CFRunLoopGetMain()
            CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            CFRunLoopWakeUp(main)
        }
        return .terminateLater
    }

    // Drain native subsystems before process exit.
    @MainActor
    private func closeQuitIngress() {
        Self.launchTask?.cancel()
        Self.launchStopping.withLock { $0 = true }
        Self.bridgeLaunchWork?.cancel()
        NativeAgentEngine.stopLaunchWork()
        approvalNotificationTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        guard ApplicationLifetime.shared.appModel != nil else { return }
        // Close ingress now, but defer Browser IPC's full stop until admitted operations join the retained quit settlement.
        NativeAgentA2AGRPCListener.shared.stop()
        ClaudeBridgeRuntime.shared.stop()
        MainActor.assumeIsolated {
            MoodTintWeather.shared.stop()
            // Stop phone ingress and snapshot observations before drains so late actions cannot start snapshot work during termination.
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
