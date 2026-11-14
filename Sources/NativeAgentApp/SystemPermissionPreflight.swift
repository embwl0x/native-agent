import Connectors
import AttentionRouting
import ChatToolRuntime
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

// Blueprint: | `SystemPermissionPreflight.swift` | Shared consent; scoped failures, activation and Bluetooth event waits, checked cleanup |

extension SystemPermissionPreflight {
    /// The one walk through macOS grants, for the permission card's Allow and Continue, the person's return to the agent's window, and Trust's
    /// "Ask for every prompt not yet answered" (which files or continues the same card). First, every grant macOS can still ask in place is
    /// asked, in walk order (Notifications, Calendar, Reminders, Contacts, Microphone, Speech, Automation by an Apple Event to that app); a
    /// request that fails is said in the result and the walk goes on. Then the first grant still off that is not in `passed` (a pane the
    /// person already came back from) is registered where macOS has a request for it and its exact pane opens: Device Control, Screen
    /// Recording, Input Monitoring, Full Disk Access, or one the person declined. The walk stops there and goes on when the person comes back
    /// to the window (`InlineInteractionResolver.GrantWatch`). Returns what it waits on and what failed; empty when nothing is left to show.
    @MainActor
    static func requestMacOSAccess(
        _ ids: [String], mode: InlineInteraction.AccessMode? = nil, passed: Set<String> = []
    ) async throws -> [String] {
        let order = frictionOrder(ids)
        var lines: [String] = []
        var checked = false
        // The person is checked once, before the first ask: after a macOS prompt closes, the app is not yet back in front.
        func absent() async -> String? {
            guard !checked else { return nil }
            checked = true
            return await activationProblem()
        }
        for id in order {
            guard let gate = cardSettingsCapability(id), await asksInPlace(id, gate: gate) else { continue }
            if let problem = await absent() { return [problem] }
            do { try await askInPlace(id, gate: gate, mode: mode) }
            catch { lines.append("\(InlineInteractionRegistry.macCapabilityDisplayName(id)) could not be asked: \(error.localizedDescription)") }
            guard !Task.isCancelled else { return lines + ["The macOS permission request was interrupted; its grant is unconfirmed."] }
        }
        for id in order where !passed.contains(id) {
            guard let gate = cardSettingsCapability(id), let waiting = await cardBlockReason([id], mode: mode) else { continue }
            if let problem = await absent() { return lines + [problem] }
            register(gate)
            // The pane opens and the walk waits for the person's return; it posts no change of its own, so only their return goes on.
            return lines + [waiting] + ((await openSettings(gate, registered: true)).map { [$0] } ?? [])
        }
        NotificationCenter.default.post(name: permissionDidChange, object: nil)
        return lines
    }

    /// Whether macOS would ask for this grant in place now: it has never been answered. A grant kept in System Settings never asks in place.
    @MainActor
    private static func asksInPlace(_ id: String, gate: SystemPermissionCapability) async -> Bool {
        if let bundleID = AppleScriptExecution.automationTarget(id) {
            // Not asked yet, or not readable while the app is stopped: the ask opens the app and macOS asks.
            guard case .object(let probe) = await AppleScriptExecution.automationPermission(bundleID: bundleID) else { return true }
            return probe["code"] == .int(-1744) || probe["code"] == .int(-600)
        }
        guard !keptInSettings.contains(gate) else { return false }
        if gate == .notifications { return await NativeAgentNotifications.notificationSettings().authorizationStatus == .notDetermined }
        return status(gate) == .notDetermined
    }

    /// Ask macOS for one grant in place.
    @MainActor
    private static func askInPlace(_ id: String, gate: SystemPermissionCapability, mode: InlineInteraction.AccessMode?) async throws {
        if let bundleID = AppleScriptExecution.automationTarget(id) {
            let result = await AppleScriptExecution.automationPermission(bundleID: bundleID, ask: true)
            if result.objectValue?["state"] == .string("unavailable") {
                throw ToolFailureError(try result.serialize(pretty: false), effects: .none)
            }
            return
        }
        switch gate {
        case .notifications:
            if let error = await NativeAgentNotifications.requestAuthorizationError() { throw ToolFailureError(error, effects: .none) }
        case .calendars where mode == .write:
            _ = try await LocalPIMConnectorActions.requestCalendarWriteAccessIfNeeded(store: EKEventStore())
        case .calendars: _ = try await LocalPIMConnectorActions.requestCalendarAccess()
        case .reminders: _ = try await LocalPIMConnectorActions.requestReminderAccess()
        case .contacts: _ = try await CNContactStore().requestAccess(for: .contacts)
        case .speechRecognition: _ = await requestSpeechRecognitionIfNotDetermined()
        case .location: MacLocationReader.requestAuthorization()
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .camera: _ = await AVCaptureDevice.requestAccess(for: .video)
        case .photos: _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case .bluetooth:
            if let unresolved = await BluetoothPrompt.ask() { throw ToolFailureError(unresolved, effects: .none) }
        default: break
        }
    }

    /// Put NativeAgent's switch in the pane the walk opens: the pane lists only apps that asked.
    @MainActor
    private static func register(_ gate: SystemPermissionCapability) {
        switch gate {
        case .accessibility: registerForAccessibility()
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        case .inputMonitoring: _ = CGRequestListenEventAccess()
        case .fullDiskAccess: NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        default: break
        }
    }

    /// The person is present when this app is in front. The agent's window is its face, a process of its own inside this bundle; this
    /// process has no window and macOS never makes it the active app, so waiting to become active waited forever and no request was made.
    /// macOS shows its own permission requests whichever process asks.
    @MainActor
    private static func activationProblem() async -> String? {
        guard !Task.isCancelled else { return "The macOS permission request was interrupted." }
        guard !NSApp.isActive else { return nil }
        let own = Bundle.main.bundleURL.standardizedFileURL.path
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || front.bundleURL.map({ ($0.standardizedFileURL.path + "/").hasPrefix(own + "/") }) == true {
            return nil
        }
        return "NativeAgent is not in front, so macOS would show its permission request behind your work. "
            + "Bring NativeAgent to the front and allow again."
    }

    /// The Accessibility list shows only apps that asked, so asking first gives the person NativeAgent's switch in the pane.
    @MainActor
    private static func registerForAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Keep a failed handoff visible in Settings instead of implying the request ran. Accessibility registers before its pane opens unless the caller
    /// just asked for it.
    @MainActor
    static func openSettings(_ capability: SystemPermissionCapability, registered: Bool = false) async -> String? {
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
        do {
            guard let model = ApplicationLifetime.shared.appModel else { throw FaceWireError.disconnected }
            try await SettingsDock.shared.show(for: capability, face: BodyFacePresentation.current(model: model))
        } catch { return "System Settings opened, but its NativeAgent guidance could not open: " + error.localizedDescription }
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
        defer {
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
