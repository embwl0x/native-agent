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
import UserNotifications

// Blueprint: | `SystemPermissionPreflight.swift` | `SystemPermissionPreflight`: shared card and Settings consent acquisition, checked unresolved-grant handoff and Bluetooth prompt lifecycle |

extension SystemPermissionPreflight {
    /// From a card tap, with the person there: fire macOS's own prompt where
    /// it has one, and open the right System Settings pane for what is still
    /// off. True when the card should wait for that pane.
    @MainActor
    static func askMacOSForCard(_ ids: [String], mode: InlineInteraction.AccessMode?) async -> Bool {
        !(await requestMacOSAccess(ids, mode: mode)).isEmpty
    }

    /// Both permission cards and Settings request through this owner. A grant
    /// that succeeds stays in NativeAgent; only unresolved access opens a pane.
    @MainActor
    static func requestMacOSAccess(
        _ ids: [String], mode: InlineInteraction.AccessMode? = nil
    ) async -> [String] {
        var problems: [String] = []
        var openedPanes: Set<SystemPermissionCapability> = []
        defer { NotificationCenter.default.post(name: permissionDidChange, object: nil) }
        for id in ids {
            guard let gate = cardSettingsCapability(id),
                  await cardBlockReason([id], mode: mode) != nil else { continue }
            if !NSApp.isActive {
                let activation = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
                    nonisolated(unsafe) let token = NotificationCenter.default.addObserver(
                        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
                    ) { _ in continuation.yield(()); continuation.finish() }
                    continuation.onTermination = { _ in NotificationCenter.default.removeObserver(token) }
                }
                NSApp.activate(ignoringOtherApps: true)
                for await _ in activation {}
            }
            guard NSApp.isActive, !Task.isCancelled else {
                return problems + ["The macOS permission request was interrupted."]
            }
            if let bundleID = AppleScriptExecution.automationTarget(id) {
                _ = await AppleScriptExecution.automationPermission(bundleID: bundleID, ask: true)
            } else if gate == .notifications {
                if await NativeAgentNotifications.notificationSettings().authorizationStatus == .notDetermined {
                    _ = await NativeAgentNotifications.requestAuthorizationError()
                }
            } else {
                switch gate {
                case .calendars where mode == .write:
                    _ = try? await LocalPIMConnectorActions.requestCalendarWriteAccessIfNeeded(store: EKEventStore())
                case .calendars: _ = await LocalPIMConnectorActions.requestCalendarAccess()
                case .reminders: _ = await LocalPIMConnectorActions.requestReminderAccess()
                case .contacts where status(gate) == .notDetermined:
                    _ = try? await CNContactStore().requestAccess(for: .contacts)
                case .speechRecognition: _ = await requestSpeechRecognitionIfNotDetermined()
                case .location: MacLocationReader.requestAuthorization()
                case .microphone where status(gate) == .notDetermined:
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                case .camera where status(gate) == .notDetermined:
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                case .photos where status(gate) == .notDetermined:
                    _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                case .bluetooth where status(gate) == .notDetermined: await BluetoothPrompt.ask()
                // These two list the app in their pane on first ask, so the
                // person has a switch to turn on.
                case .accessibility:
                    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                case .screenRecording: _ = CGRequestScreenCaptureAccess()
                case .inputMonitoring: _ = CGRequestListenEventAccess()
                case .fullDiskAccess:
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                default: break
                }
            }
            if let reason = await cardBlockReason([id], mode: mode) {
                problems.append(reason)
                if openedPanes.insert(gate).inserted, let failure = openSettings(gate) {
                    problems.append(failure)
                }
            }
        }
        return problems
    }

    /// Retain a failed handoff as a visible request error in Settings.
    @MainActor
    static func openSettings(_ capability: SystemPermissionCapability) -> String? {
        guard let url = settingsURL(for: capability) else {
            return "NativeAgent could not find a System Settings privacy pane for \(capability.displayName)."
        }
        guard NSWorkspace.shared.open(url) else {
            return "NativeAgent could not open System Settings → Privacy & Security → \(capability.displayName). Open System Settings manually, enable NativeAgent, then return here and refresh."
        }
        return nil
    }

}

/// Bluetooth has no request call: macOS asks when the app first makes a
/// central manager, and the manager's state settles on the answer.
@MainActor
private final class BluetoothPrompt: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var answered: CheckedContinuation<Void, Never>?

    static func ask() async {
        let prompt = BluetoothPrompt()
        await withCheckedContinuation { continuation in
            prompt.answered = continuation
            prompt.manager = CBCentralManager(delegate: prompt, queue: .main)
        }
        prompt.manager = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard CBManager.authorization != .notDetermined else { return }
        answered?.resume()
        answered = nil
    }
}
