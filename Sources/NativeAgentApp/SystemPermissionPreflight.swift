import Connectors
import AttentionRouting
import Foundation
import AppKit
import ApplicationServices
import CoreBluetooth
import CoreGraphics
import EventKit
import Contacts
import AVFoundation
import MacIntegration
import MacControl
import NativeAgentCore
import NativeAgentShared
import Photos
import PersistenceCore
import UserNotifications

// Blueprint: | `SystemPermissionPreflight.swift` | Shared consent; scoped failures, bounded activation and Bluetooth waits, checked cleanup |

extension SystemPermissionPreflight {
    /// Request native grants only with the person present. Each unresolved item reports why; the first one in walk order has its Settings pane open.
    @MainActor
    static func askMacOSForCard(_ ids: [String], mode: InlineInteraction.AccessMode?) async throws -> [String] {
        try await requestMacOSAccess(ids, mode: mode)
    }

    /// Successful grants stay in-app; collect item failures while unrelated requests proceed.
    @MainActor
    static func requestMacOSAccess(
        _ ids: [String], mode: InlineInteraction.AccessMode? = nil
    ) async throws -> [String] {
        var problems: [String] = []
        var requestFailed = false
        var openedPanes: Set<SystemPermissionCapability> = []
        defer { NotificationCenter.default.post(name: permissionDidChange, object: nil) }
        for id in frictionOrder(ids) {
            guard let gate = cardSettingsCapability(id),
                  await cardBlockReason([id], mode: mode) != nil else { continue }
            if let problem = await activationProblem() {
                problems.append(problem)
                break
            }
            do {
            if let bundleID = AppleScriptExecution.automationTarget(id) {
                let result = await AppleScriptExecution.automationPermission(bundleID: bundleID, ask: true)
                if result.objectValue?["state"] == .string("unavailable") {
                    throw ToolFailureError(try result.serialize(pretty: false), effects: .none)
                }
            } else if gate == .notifications {
                if await NativeAgentNotifications.notificationSettings().authorizationStatus == .notDetermined {
                    if let error = await NativeAgentNotifications.requestAuthorizationError() {
                        throw ToolFailureError(error, effects: .none)
                    }
                }
            } else {
                switch gate {
                case .calendars where mode == .write:
                    _ = try await LocalPIMConnectorActions.requestCalendarWriteAccessIfNeeded(store: EKEventStore())
                case .calendars: _ = try await LocalPIMConnectorActions.requestCalendarAccess()
                case .reminders: _ = try await LocalPIMConnectorActions.requestReminderAccess()
                case .contacts where status(gate) == .notDetermined:
                    _ = try await CNContactStore().requestAccess(for: .contacts)
                case .speechRecognition: _ = await requestSpeechRecognitionIfNotDetermined()
                case .location: MacLocationReader.requestAuthorization()
                case .microphone where status(gate) == .notDetermined:
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                case .camera where status(gate) == .notDetermined:
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                case .photos where status(gate) == .notDetermined:
                    _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                case .bluetooth where status(gate) == .notDetermined:
                    if let unresolved = await BluetoothPrompt.ask() {
                        throw ToolFailureError(unresolved, effects: .none)
                    }
                // First requests register the app in Settings so the person has a switch to enable.
                case .accessibility: registerForAccessibility()
                case .screenRecording: _ = CGRequestScreenCaptureAccess()
                case .inputMonitoring: _ = CGRequestListenEventAccess()
                case .fullDiskAccess:
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                default: break
                }
            }
            } catch {
                let cause = "\(gate.displayName) (\(id)) permission request could not complete: \(error.localizedDescription)"
                // Cancellation must not open another pane; other failures keep both cause and remedy.
                let handoff = Task.isCancelled
                    || !openedPanes.isEmpty || !openedPanes.insert(gate).inserted ? nil : openSettings(gate, registered: true)
                let remedy = " Open System Settings > Privacy & Security > \(gate.displayName), allow NativeAgent, then return here and refresh."
                problems.append(cause + remedy + (handoff.map { " " + $0 } ?? ""))
                requestFailed = true
                if Task.isCancelled { break }
                continue
            }
            guard !Task.isCancelled else {
                problems.append("The macOS permission request was interrupted; its grant is unconfirmed.")
                break
            }
            if let reason = await cardBlockReason([id], mode: mode) {
                problems.append(reason)
                // Open only the first unresolved pane because each later pane hides the previous one.
                if openedPanes.isEmpty, openedPanes.insert(gate).inserted, let failure = openSettings(gate, registered: true) {
                    problems.append(failure)
                }
            }
        }
        if requestFailed {
            throw ToolFailureError(problems.joined(separator: " "), effects: .none,
                owner: "macOS permissions", tap: "System Settings",
                code: "system_permission_request_unresolved", instruction: """
                    For each unresolved permission, allow NativeAgent in the named pane, then return to the permission card or Settings and \
                    refresh.
                    """)
        }
        return problems
    }

    /// Activation may be declined; verify AppKit state on every exit before asking for a grant.
    @MainActor
    private static func activationProblem() async -> String? {
        guard !Task.isCancelled else { return "The macOS permission request was interrupted." }
        guard !NSApp.isActive else { return nil }
        let activated = ScopedWaiter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { _ in activated.resume() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            activated.resume()
        }
        defer { deadline.cancel() }
        NSApp.activate()
        await activated.park()
        guard !Task.isCancelled else { return "The macOS permission request was interrupted." }
        guard NSApp.isActive else {
            return "NativeAgent could not become active to request macOS permission. Bring NativeAgent to the front and try again."
        }
        return nil
    }

    /// The Accessibility list shows only apps that asked, so asking first gives the person NativeAgent's switch in the pane.
    @MainActor
    private static func registerForAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Keep a failed handoff visible in Settings instead of implying the request ran. Accessibility registers before its pane opens unless the caller
    /// just asked for it.
    @MainActor
    static func openSettings(_ capability: SystemPermissionCapability, registered: Bool = false) -> String? {
        if capability == .accessibility, !registered { registerForAccessibility() }
        guard let url = settingsURL(for: capability) else {
            return "NativeAgent could not find a System Settings privacy pane for \(capability.displayName)."
        }
        guard NSWorkspace.shared.open(url) else {
            return """
                NativeAgent could not open System Settings → Privacy & Security → \(capability.displayName). Open System Settings \
                manually, enable NativeAgent, then return here and refresh.
                """
        }
        SettingsDock.shared.show(for: capability)
        return nil
    }

}

/// Bluetooth prompts on central-manager creation; its state supplies the answer, not a request callback.
@MainActor
private final class BluetoothPrompt: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private let answered = ScopedWaiter()

    static func ask() async -> String? {
        let prompt = BluetoothPrompt()
        prompt.manager = CBCentralManager(delegate: prompt, queue: .main)
        let done = prompt.answered
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
            done.resume()
        }
        defer {
            deadline.cancel()
            prompt.manager?.delegate = nil
            prompt.manager = nil
        }
        await done.park()
        if Task.isCancelled { return "The Bluetooth permission wait was interrupted; macOS has not confirmed an answer." }
        guard CBManager.authorization != .notDetermined else {
            return "The Bluetooth permission wait ended without a macOS answer; access remains unconfirmed."
        }
        return nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard CBManager.authorization != .notDetermined else { return }
        answered.resume()
    }
}
