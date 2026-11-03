import NativeAgentCore
import NativeAgentShared
import Foundation
import AppKit
import ServiceManagement
import PersistenceCore
import os
// Blueprint: | `AppDelegate+ProcessLifecycle.swift` | `AppDelegate`: checked single-instance activation with a bounded wait and process re-read; launch failure alerts and installed-app login registration |

extension AppDelegate {
    @MainActor
    static func claimSingleAppInstance() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return true }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first { $0.processIdentifier != currentPID && !$0.isTerminated }
        guard let existing else { return true }
        let existingPID = existing.processIdentifier
        let semaphore = DispatchSemaphore(value: 0)
        let activationResult = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        Task.detached(priority: .userInitiated) {
            let target = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .first(where: { $0.processIdentifier == existingPID && !$0.isTerminated })
            let activated = target?.activate(options: [.activateAllWindows])
            activationResult.withLock { $0 = activated }
            semaphore.signal()
        }
        let wait = semaphore.wait(timeout: .now() + 2.5)
        let activated = activationResult.withLock { $0 }
        if activated == true {
            ModuleLog.app("[launch] existing instance accepted activation (pid=\(existingPID)); exiting duplicate")
            return false
        }
        // A vanished process no longer owns the instance. Re-read the actual
        // running apps, including a replacement that started during the wait.
        let remaining = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
        guard !remaining.isEmpty else {
            ModuleLog.app("[launch] previous instance exited before activation; continuing launch")
            return true
        }
        let detail = wait == .timedOut
            ? "Activation did not return within 2.5 seconds; its outcome is unknown."
            : activated == false
                ? "macOS returned false for the activation request."
                : "The selected process exited before activation; another instance is still running."
        ModuleLog.app("[launch] existing-instance activation unavailable: \(detail)")
        Self.presentSingleInstanceActivationError(pids: remaining.map(\.processIdentifier), detail: detail)
        return false
    }

    @MainActor
    static func presentSingleInstanceActivationError(pids: [pid_t], detail: String) {
        NSApp.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = "NativeAgent cannot activate the existing app instance."
        alert.informativeText = "\(detail) Running NativeAgent process IDs: \(pids.map { String($0) }.joined(separator: ", ")). This duplicate will exit. Open the existing NativeAgent window from the Dock or inspect those processes in Activity Monitor."
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
        alert.informativeText = "NativeAgent stopped before opening live state. If recovery is incomplete, the preserved safety rollback will resume on the next launch. The details are in the log."
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// Missing data/ or SOUL.md at launch. Continuing starts on the root the
    /// alert names, so the person chooses that rather than finding an empty
    /// agent. Returns true to continue.
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

    /// Register the app to launch at login. Uses SMAppService (modern,
    /// sandboxable, replaces the old SMLoginItemSetEnabled API).
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
