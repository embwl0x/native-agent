import Connectors
// PATCH-2026-08-18: system-permission preflight.
//
// Root cause this file exists for: commit 130dc377 made SFSpeechRecognizer
// load-bearing for a HEADLESS pipeline (inbound Telegram voice notes), but the
// ONLY code path that can raise the macOS SpeechRecognition TCC prompt is
// VoiceInputCapture.requestPermission(), reachable only when a human clicks
// the in-app mic button. A Telegram-only user never traverses it, so
// kTCCServiceSpeechRecognition stays notDetermined forever — and worse, the
// headless transcriber's own SFSpeechRecognizer.requestAuthorization call runs
// where macOS cannot render a prompt, so the system resolves it .denied.
//
// This type supplies the three things that were missing: a NON-PROMPTING status
// read, a foreground acquisition path, and a pure judgement seam
// (`healthWarnings(from:)` / `warningSummary(for:)`) that tests can drive from
// hand-built fixtures instead of host TCC state.
import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import EventKit
import Contacts
import MacIntegration
import NativeAgentShared

extension SystemPermissionPreflight {
    /// From a card tap, with the person there: fire macOS's own prompt where
    /// it has one, and open the right System Settings pane for what is still
    /// off. True when the card should wait for that pane.
    @MainActor
    static func askMacOSForCard(_ ids: [String], mode: InlineInteraction.AccessMode?) async -> Bool {
        for id in ids {
            guard let gate = cardGate(id, mode: mode), cardStatus(gate, mode: mode) != .granted else { continue }
            switch gate {
            case .calendars where mode == .write:
                if cardStatus(gate, mode: mode) == .notDetermined {
                    _ = try? await EKEventStore().requestWriteOnlyAccessToEvents()
                }
            case .calendars: _ = await LocalPIMConnectorActions.requestCalendarAccess()
            case .reminders: _ = await LocalPIMConnectorActions.requestReminderAccess()
            case .contacts where status(gate) == .notDetermined:
                _ = try? await CNContactStore().requestAccess(for: .contacts)
            // These two list the app in their pane on first ask, so the
            // person has a switch to turn on.
            case .accessibility:
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            case .screenRecording: _ = CGRequestScreenCaptureAccess()
            default: break
            }
            guard cardStatus(gate, mode: mode) != .granted, let url = settingsURL(for: gate) else { continue }
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }

}
