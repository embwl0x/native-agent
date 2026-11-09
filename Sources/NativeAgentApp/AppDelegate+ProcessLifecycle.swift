import NativeAgentCore
import EngineRuntime
import NativeAgentShared
import Foundation
import AppKit
import ServiceManagement
import PersistenceCore
import os
// Blueprint: | `AppDelegate+ProcessLifecycle.swift` | `AppDelegate`: Single-instance checks, launch alerts and login registration |

extension AppDelegate {
    @MainActor private static var faceProcess: BodyFaceProcess?

    /// The body's one window process: it launches the window's app and answers it over the link.
    @MainActor
    static func installFaceProcess(dataRoot: URL, source: FaceFeedSource, handler: EngineFaceActs, services: BodySettingsActHandler) throws {
        try Task.checkCancellation()
        guard faceProcess == nil else {
            throw WireFailure(code: "face_process_already_installed", message: "The window process owner is already installed.",
                              cause: nil, effects: .none)
        }
        faceProcess = BodyFaceProcess(bodyBundle: Bundle.main.bundleURL, dataRoot: dataRoot, source: source, handler: handler,
            connected: { sink in
                guard let process = await MainActor.run(body: { faceProcess }) else { throw FaceWireError.disconnected }
                try await handler.attachRenderer(sink: sink, call: { request in try await process.call(request, connection: sink) })
                await services.rendererConnected(sink)
            }, disconnected: { connection, detail in
                do { try await handler.detachRenderer() }
                catch { ModuleLog.app("[face] release failed: %@", error.localizedDescription) }
                await services.rendererDisconnected(connection)
                ModuleLog.app("[face] connection closed: %@", detail)
                // Her window lives as long as she does: a window that ended without Quit comes back at once.
                await MainActor.run { reopenAfterLoss() }
            })
    }

    @MainActor
    private static func reopenAfterLoss() {
        guard !quitWaitingForTurns else { return }
        Task {
            do { try await openFaceWindow() }
            catch { ModuleLog.app("[face] window did not come back: %@", error.localizedDescription) }
        }
    }

    @MainActor
    static func openFaceWindow(destination: FaceDestination? = nil) async throws {
        guard let faceProcess else {
            throw WireFailure(code: "face_process_unattached", message: "The window process owner has not attached.",
                              cause: nil, effects: .none)
        }
        switch try await faceProcess.showWindow(destination: destination) {
        case .acknowledged, .navigation: return
        case .failed(let failure), .refused(let failure): throw failure
        default: throw FaceWireError.invalidFeedOrder
        }
    }

    @MainActor
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        guard Self.faceProcess != nil else { return false }
        Self.requestFaceWindowIfInstalled()
        return false
    }

    /// The body keeps running without a window; the person is told the window could not open, never shown the old one.
    @MainActor
    static func presentFaceUnavailable(_ error: Error) {
        NSApp.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = "The NativeAgent window could not open."
        alert.informativeText = "\(error.localizedDescription)\n\nI keep running. Reopen NativeAgent to try the window again."
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.setActivationPolicy(.accessory)
    }

    /// Termination waits on main-actor settlement, so it starts from the run loop, never inside the main-queue job that asked for it.
    nonisolated static func terminateFromRunLoop() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
        }
    }

    @MainActor
    static func requestFaceWindowIfInstalled(destination: FaceDestination? = nil) {
        guard faceProcess != nil else { return }
        Task {
            do { try await openFaceWindow(destination: destination) }
            catch {
                let alert = NSAlert()
                alert.messageText = "The NativeAgent window could not open."
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    @MainActor
    static func closeFaceProcess() async { await faceProcess?.close() }

    @MainActor
    static func claimSingleAppInstance() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return true }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first { $0.processIdentifier != currentPID && !$0.isTerminated }
        guard let existing else { return true }
        let existingPID = existing.processIdentifier
        let activated = existing.activate(options: [.activateAllWindows])
        if activated {
            ModuleLog.app("[launch] existing instance accepted activation (pid=\(existingPID)); exiting duplicate")
            return false
        }
        // Activation can race process replacement; only live processes prevent this launch.
        let remaining = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
        guard !remaining.isEmpty else {
            ModuleLog.app("[launch] previous instance exited before activation; continuing launch")
            return true
        }
        let detail = "macOS returned false for the activation request."
        ModuleLog.app("[launch] existing-instance activation unavailable: \(detail)")
        Self.presentSingleInstanceActivationError(pids: remaining.map(\.processIdentifier), detail: detail)
        return false
    }

    @MainActor
    static func presentSingleInstanceActivationError(pids: [pid_t], detail: String) {
        NSApp.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = "NativeAgent cannot activate the existing app instance."
        alert.informativeText = """
            \(detail) Running NativeAgent process IDs: \(pids.map { String($0) }.joined(separator: ", ")). This duplicate will exit. Open the existing \
            NativeAgent window from the Dock or inspect those processes in Activity Monitor.
            """
        alert.alertStyle = .critical
        alert.runModal()
    }

    @MainActor
    static func presentPublicReleaseDataRootError(_ detail: String) {
        ModuleLog.app("[paths] refusing to start NativeAgent after public-release data preparation failure: \(detail)")
        NSApp.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = "NativeAgent could not prepare a clean data directory."
        alert.informativeText = "For safety, NativeAgent will not start with existing pre-release data.\n\n\(detail)"
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    @MainActor
    static func presentBackupRestoreError(_ detail: String) {
        ModuleLog.app("[backup-restore] refusing to start after staged restore failure: \(detail)")
        NSApp.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = "NativeAgent could not safely finish the backup restore."
        alert.informativeText = """
            NativeAgent stopped before opening live state. If recovery is incomplete, the preserved safety rollback will resume on the next launch. The \
            details are in the log.
            """
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// Require a choice before continuing on the named root so missing data or SOUL.md cannot silently start an empty agent.
    @MainActor
    static func confirmLaunchWithMissingRoots(_ missing: [String]) -> Bool {
        ModuleLog.app("[paths] launch roots missing: %@", missing.joined(separator: " | "))
        NSApp.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "NativeAgent cannot find its data."
        alert.informativeText = missing.joined(separator: "\n\n")
            + "\n\nContinuing starts with what is named above, and anything missing is created empty."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Continue Anyway")
        let continued = alert.runModal() == .alertSecondButtonReturn
        if !continued { NSApp.terminate(nil) }
        return continued
    }

    // MARK: - Login item

    static func registerLoginItemInBackground() {
        if ProcessInfo.processInfo.environment["NATIVE_AGENT_SKIP_LOGIN_ITEM_REGISTER"] != "1" {
            Task.detached(priority: .background) {
                await AppDelegate.registerLoginItemIfNeeded()
            }
        }
    }

    /// Use SMAppService for sandbox-compatible login registration.
    @MainActor
    static func registerLoginItemIfNeeded() async {
        let bundlePath = Bundle.main.bundlePath
        guard InstallPaths.allowsLoginItem(bundlePath: bundlePath) else {
            print("[app] skipped login auto-start registration for non-installed bundle: \(bundlePath)")
            return
        }
        let service = SMAppService.mainApp
        if service.status == .enabled { return }
        do {
            try service.register()
            print("[app] registered for login auto-start")
        } catch {
            print("[app] login auto-start register failed: \(error.localizedDescription)")
        }
    }

}
