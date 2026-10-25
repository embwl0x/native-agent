import NativeAgentCore
import Foundation
import AppKit
import ServiceManagement
import DeviceSync
import PersistenceCore
// Blueprint: | `AppDelegate+ProcessLifecycle.swift` | `AppDelegate`: `claimSingleAppInstance`, `presentSingleInstanceWedgedAlert`, `presentPublicReleaseDataRootError` |

private final class SingleInstanceActivationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool?

    func set(_ value: Bool?) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

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
        let activationBox = SingleInstanceActivationBox()
        Task.detached(priority: .userInitiated) {
            let activated = await withCKTimeout("singleInstanceActivate", seconds: 2) {
                guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                    .first(where: { $0.processIdentifier == existingPID && !$0.isTerminated }) else {
                    return false
                }
                return target.activate(options: [.activateAllWindows])
            }
            activationBox.set(activated)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.5)
        guard activationBox.value != nil else {
            ModuleLog.app("[launch] existing pid wedged — cannot evict (kernel UE state); user must reboot")
            Self.presentSingleInstanceWedgedAlert(pid: existingPID)
            return false
        }
        ModuleLog.app("[launch] another NativeAgent instance is already running (pid=\(existing.processIdentifier)); activating it and exiting duplicate")
        return false
    }

    @MainActor
    static func presentSingleInstanceWedgedAlert(pid: pid_t) {
        NSApp.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = "NativeAgent cannot activate the existing app instance."
        alert.informativeText = "The existing NativeAgent process (pid \(pid)) appears wedged in a system iCloud/CloudKit state. NativeAgent will exit this duplicate instance cleanly. Reboot the Mac to clear the stuck system process."
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
        guard #available(macOS 13.0, *) else { return }
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
