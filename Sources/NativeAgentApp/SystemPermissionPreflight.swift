// PATCH-2026-08-18: system-permission preflight.
//
// Root cause this file exists for: commit 130dc377 made SFSpeechRecognizer
// load-bearing for a HEADLESS pipeline (inbound Telegram voice notes), but the
// ONLY code path that can raise the macOS SpeechRecognition TCC prompt is
// VoiceInputController.requestPermission(), reachable only when a human clicks
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
import Speech
import AVFoundation
import ApplicationServices
import CoreGraphics
import EventKit
import Contacts
import OSLog

/// A macOS privacy (TCC) capability the app depends on.
enum SystemPermissionCapability: String, CaseIterable, Sendable {
    case speechRecognition
    case microphone
    case accessibility
    case screenRecording
    case automation
    case calendars
    case reminders
    case contacts
    case notifications

    var displayName: String {
        switch self {
        case .speechRecognition: return "Speech Recognition"
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .automation: return "Automation"
        case .calendars: return "Calendar"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        case .notifications: return "Notifications"
        }
    }

    /// Anchor for the `com.apple.settings.PrivacySecurity.extension` pane.
    /// The Calendar / Reminders / Contacts values are the same literals
    /// `MacIntegrationView.FrameworkPermission.settingsAnchor` already uses —
    /// one vocabulary, not two. `notifications` is nil because it does not live
    /// under Privacy & Security at all (it has its own Settings extension), and
    /// returning a bogus Privacy anchor for it would deep-link to the wrong pane.
    var settingsAnchor: String? {
        switch self {
        case .speechRecognition: return "Privacy_SpeechRecognition"
        case .microphone: return "Privacy_Microphone"
        case .accessibility: return "Privacy_Accessibility"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .automation: return "Privacy_Automation"
        case .calendars: return "Privacy_Calendars"
        case .reminders: return "Privacy_Reminders"
        case .contacts: return "Privacy_Contacts"
        case .notifications: return nil
        }
    }

    /// True when a background/headless code path depends on this capability and
    /// there is NO guarantee an interactive acquisition ever runs. These are the
    /// grants that can silently stay unacquired forever — exactly the shape of
    /// the Telegram voice-note bug — so a non-granted state here is worth
    /// surfacing on a health panel. The rest (microphone, screen recording,
    /// calendars, reminders, contacts) are only reached from a user-initiated
    /// in-app action that fires their own prompt at the moment of use.
    var isHeadlessLoadBearing: Bool {
        switch self {
        case .speechRecognition, .accessibility, .automation, .notifications:
            return true
        case .microphone, .screenRecording, .calendars, .reminders, .contacts:
            return false
        }
    }
}

enum SystemPermissionStatus: String, Sendable {
    case granted
    case denied
    case restricted
    case notDetermined
    case unknown
}

struct SystemPermissionSnapshot: Sendable, Equatable {
    let capability: SystemPermissionCapability
    let status: SystemPermissionStatus
    let detail: String

    init(capability: SystemPermissionCapability, status: SystemPermissionStatus, detail: String = "") {
        self.capability = capability
        self.status = status
        self.detail = detail
    }
}

enum SystemPermissionPreflight {
    private static let logger = Logger(subsystem: "com.nativeagent.app", category: "permission-preflight")

    typealias SpeechAuthorizationRequest = @Sendable (
        @escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void
    ) -> Void

    static let settingsPanePrefix = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?"

    /// Full System Settings deep link for a capability, or nil when it has no
    /// Privacy & Security anchor.
    static func settingsURL(for capability: SystemPermissionCapability) -> URL? {
        guard let anchor = capability.settingsAnchor else { return nil }
        return URL(string: settingsPanePrefix + anchor)
    }

    // MARK: - Non-prompting reads

    /// Reads the current TCC state. **MUST NEVER PROMPT.** Every call below is
    /// the query-only variant of its framework's API; the requesting variants
    /// (`SFSpeechRecognizer.requestAuthorization`,
    /// `CGRequestScreenCaptureAccess`, `AXIsProcessTrustedWithOptions` with
    /// `kAXTrustedCheckOptionPrompt: true`,
    /// `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: true)`) are
    /// deliberately absent. A prompt fired from a background context is not just
    /// invisible — macOS resolves it to a hard `.denied` the user can never undo
    /// from inside the app, which is the exact bug this file exists to fix.
    static func status(_ capability: SystemPermissionCapability) -> SystemPermissionStatus {
        switch capability {
        case .speechRecognition:
            // Class-level READ. Not requestAuthorization.
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .accessibility:
            // AXIsProcessTrusted() is the no-prompt form; the prompting form is
            // AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt.
            // AX exposes no notDetermined/restricted distinction — it is a
            // boolean trust bit — so a non-trusted process reads as .denied.
            return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            // CGPreflightScreenCaptureAccess is the preflight (no prompt);
            // CGRequestScreenCaptureAccess is the prompting sibling.
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .calendars:
            return mapEKStatus(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return mapEKStatus(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .automation, .notifications:
            // No CHEAP non-prompting read exists here.
            // Automation: AEDeterminePermissionToAutomateTarget is per-target,
            // requires the target app to be running, and the only variant that
            // resolves a not-yet-determined grant is askUserIfNeeded:true —
            // which prompts. MacIntegrationView owns that per-app probe.
            // Notifications: UNUserNotificationCenter's settings read is async
            // and requires a bundled, registered app.
            // Reporting .unknown is honest; `healthWarnings` deliberately does
            // not warn on .unknown so an unreadable state never becomes a
            // permanent false alarm.
            return .unknown
        }
    }

    private static func mapEKStatus(_ status: EKAuthorizationStatus) -> SystemPermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        case .fullAccess: return .granted
        case .writeOnly:
            // NOT .granted. Write-only means the app may add events but cannot
            // READ them, and every calendar/reminder capability this app
            // surfaces (briefings, watch jobs, mac_calendar_list_upcoming) is a
            // read. Reporting .granted here would show a green row while those
            // reads keep failing — the same "looks fine, silently broken" shape
            // this whole file exists to kill. MacPIMConnectorActions already
            // treats write-only as not read-ready; match it.
            return .denied
        @unknown default: return .unknown
        }
    }

    static func snapshotAll() -> [SystemPermissionSnapshot] {
        SystemPermissionCapability.allCases.map { capability in
            let status = status(capability)
            return SystemPermissionSnapshot(
                capability: capability,
                status: status,
                detail: "\(capability.displayName): \(status.rawValue)"
            )
        }
    }

    // MARK: - Pure judgement seam (the tested surface)

    /// The subset of `snapshots` worth telling the human about: a capability a
    /// headless path depends on that is NOT granted.
    ///
    /// `.unknown` is excluded on purpose — it means "we could not read this
    /// without prompting," not "it is missing." Warning on unreadable state
    /// would put a permanent, unresolvable card in front of the user (the
    /// dead-end-alert bug class), which is worse than staying quiet.
    static func healthWarnings(from snapshots: [SystemPermissionSnapshot]) -> [SystemPermissionSnapshot] {
        snapshots.filter { snapshot in
            snapshot.capability.isHeadlessLoadBearing
                && snapshot.status != .granted
                && snapshot.status != .unknown
        }
    }

    /// User-facing copy for one warning. Names the capability AND the System
    /// Settings pane, because the whole point of the card is that the user can
    /// get from the message to the switch.
    static func warningSummary(for snapshot: SystemPermissionSnapshot) -> String {
        let name = snapshot.capability.displayName
        let pane = "System Settings → Privacy & Security → \(name)"
        switch snapshot.status {
        case .notDetermined:
            return "\(name) has never been approved for NativeAgent. "
                + "Background features that need it will fail silently until it is granted in \(pane)."
        case .denied:
            return "\(name) is denied for NativeAgent. macOS will not re-prompt once denied — "
                + "turn it back on in \(pane)."
        case .restricted:
            return "\(name) is restricted on this Mac (device management or parental controls). "
                + "Check \(pane)."
        case .granted, .unknown:
            // Not reachable via healthWarnings; kept total so the function has
            // no crashing branch if a caller passes an arbitrary snapshot.
            return "\(name) status: \(snapshot.status.rawValue). See \(pane)."
        }
    }

    // MARK: - Foreground acquisition

    /// Bridges Speech's callback without inheriting the caller's actor.
    ///
    /// `SFSpeechRecognizer.requestAuthorization` is invoked from the main actor
    /// so macOS can present its consent sheet, but TCC delivers the completion
    /// on an arbitrary dispatch queue. Defining the continuation bridge as
    /// `nonisolated` is essential: otherwise Swift 6 actor inference makes the
    /// callback main-actor isolated and traps when TCC calls it off-main.
    nonisolated static func awaitSpeechAuthorization(
        using request: SpeechAuthorizationRequest = { completion in
            SFSpeechRecognizer.requestAuthorization(completion)
        }
    ) async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            request { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Fires the macOS Speech Recognition consent prompt — but ONLY from the
    /// main actor, and ONLY when the grant is still `.notDetermined`.
    ///
    /// Why main-actor/foreground is not a style preference:
    /// `SFSpeechRecognizer.requestAuthorization` from a headless context (a
    /// background poll loop, a detached utility task with no active app) cannot
    /// render its prompt. macOS does not queue it for later — it resolves the
    /// request `.denied` immediately, WITHOUT writing a real user decision into
    /// the TCC database. The user is then stuck: the app looks denied, the
    /// system never asked, and no in-app button can re-ask, because TCC will not
    /// re-prompt a resolved grant. That is precisely how the Telegram voice-note
    /// path bricked itself (`data/telegram/errors.jsonl`,
    /// context=voice_transcription, speechPermissionDenied("denied")).
    ///
    /// Reading first is the other half of the guard: calling request on an
    /// already-denied grant is a silent no-op, so callers must route those to
    /// System Settings instead of showing a button that appears to do nothing.
    @MainActor
    static func requestSpeechRecognitionIfNotDetermined() async -> SystemPermissionStatus {
        let current = status(.speechRecognition)
        guard current == .notDetermined else {
            logger.info(
                "speech-recognition preflight: already resolved (\(current.rawValue, privacy: .public)); no prompt fired"
            )
            return current
        }
        let resolved = await awaitSpeechAuthorization()
        let mapped: SystemPermissionStatus
        switch resolved {
        case .authorized: mapped = .granted
        case .denied: mapped = .denied
        case .restricted: mapped = .restricted
        case .notDetermined: mapped = .notDetermined
        @unknown default: mapped = .unknown
        }
        logger.info(
            "speech-recognition preflight: prompt resolved \(mapped.rawValue, privacy: .public)"
        )
        return mapped
    }
}
