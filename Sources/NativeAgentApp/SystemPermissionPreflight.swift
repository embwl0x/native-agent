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

// Blueprint: | `SystemPermissionPreflight.swift` | `SystemPermissionPreflight`: person-initiated macOS permission prompts before System Settings handoff, including Bluetooth prompt lifecycle |

extension SystemPermissionPreflight {
    /// From a card tap, with the person there: fire macOS's own prompt where
    /// it has one, and open the right System Settings pane for what is still
    /// off. True when the card should wait for that pane.
    @MainActor
    static func askMacOSForCard(_ ids: [String], mode: InlineInteraction.AccessMode?) async -> Bool {
        for id in ids {
            guard let gate = cardSettingsCapability(id), let url = settingsURL(for: gate) else { continue }
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
            guard NSApp.isActive, !Task.isCancelled else { return true }
            // Settings must not take focus before macOS receives the request.
            defer {
                let opened = NSWorkspace.shared.open(url)
                ModuleLog.app("[permission-card] \(opened ? "Opened" : "Could not open") \(url.absoluteString)")
            }
            if let bundleID = SystemAppleScriptAdapter.automationTarget(id) {
                _ = await SystemAppleScriptAdapter.automationPermission(bundleID: bundleID, ask: true)
                continue
            }
            if gate == .notifications {
                if await NativeAgentNotifications.notificationSettings().authorizationStatus == "not_determined" {
                    _ = await NativeAgentNotifications.requestAuthorizationError()
                }
                continue
            }
            guard cardStatus(gate, mode: mode) != .granted else { continue }
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
        NotificationCenter.default.post(name: permissionDidChange, object: nil)
        return await cardBlockReason(ids, mode: mode) != nil
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
