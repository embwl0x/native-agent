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

// Blueprint: | `SystemPermissionPreflight.swift` | Shared card and Settings consent acquisition collects item authorization errors and remedies while continuing unrelated grants; three-second foreground activation and task-cancellable thirty-second Bluetooth answer bounds release their observers/managers without inventing a grant verdict |

extension SystemPermissionPreflight {
    /// From a card tap, with the person there: fire macOS's own prompt where
    /// it has one, and open the right System Settings pane for what is still
    /// off. True when the card should wait for that pane.
    @MainActor
    static func askMacOSForCard(_ ids: [String], mode: InlineInteraction.AccessMode?) async throws -> Bool {
        !(try await requestMacOSAccess(ids, mode: mode)).isEmpty
    }

    /// Both permission cards and Settings request through this owner. A grant
    /// that succeeds stays in NativeAgent; only unresolved access opens a pane.
    /// Item failures are reported together after unrelated grants are requested.
    @MainActor
    static func requestMacOSAccess(
        _ ids: [String], mode: InlineInteraction.AccessMode? = nil
    ) async throws -> [String] {
        var problems: [String] = []
        var requestFailed = false
        var openedPanes: Set<SystemPermissionCapability> = []
        defer { NotificationCenter.default.post(name: permissionDidChange, object: nil) }
        for id in ids {
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
            } catch {
                let cause = "\(gate.displayName) (\(id)) permission request could not complete: \(error.localizedDescription)"
                // A cancelled caller never opens another pane. Other request
                // failures retain their cause alongside the existing remedy.
                let handoff = Task.isCancelled || TaskWaitDeadline.expired || !openedPanes.isEmpty || !openedPanes.insert(gate).inserted ? nil : openSettings(gate)
                let remedy = " Open System Settings > Privacy & Security > \(gate.displayName), allow NativeAgent, then return here and refresh."
                problems.append(cause + remedy + (handoff.map { " " + $0 } ?? ""))
                requestFailed = true
                if Task.isCancelled || TaskWaitDeadline.expired { break }
                continue
            }
            guard !Task.isCancelled else {
                problems.append("The macOS permission request was interrupted; its grant is unconfirmed.")
                break
            }
            if let reason = await cardBlockReason([id], mode: mode) {
                problems.append(reason)
                // One pane at a time, the first still off: System Settings shows only
                // the last pane opened, so a second would hide the one that matters.
                if openedPanes.isEmpty, openedPanes.insert(gate).inserted, let failure = openSettings(gate) {
                    problems.append(failure)
                }
            }
        }
        if requestFailed {
            throw ToolFailureError(problems.joined(separator: " "), effects: .none,
                owner: "macOS permissions", tap: "System Settings",
                code: "system_permission_request_unresolved", instruction: "For each unresolved permission, allow NativeAgent in the named pane, then return to the permission card or Settings and refresh.")
        }
        return problems
    }

    /// Activation is a request macOS may decline. Waking is not proof: read
    /// AppKit's current state before asking for any grant, on every exit.
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
