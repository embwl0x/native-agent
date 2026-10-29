import Foundation
import Darwin
import NativeAgentShared
import NativeAgentCore
import Speech
import AVFoundation
import ApplicationServices
import CoreBluetooth
import CoreGraphics
import CoreLocation
import EventKit
import Contacts
import OSLog
import PersistenceCore
import Photos
import MacControl
import UserNotifications
// Blueprint: | `SystemPermissionPreflight.swift` | Observed OS grants, request admission and one capability vocabulary for permission cards |

/// A macOS privacy (TCC) capability the app depends on.
public enum SystemPermissionCapability: String, CaseIterable, Sendable {
    case speechRecognition
    case microphone
    case accessibility
    case location
    case fullDiskAccess
    case screenRecording
    case inputMonitoring
    case automation
    case calendars
    case reminders
    case contacts
    case notifications
    case bluetooth
    case camera
    case photos

    /// The names `permissions.request` takes, read off this list so a new class is offered the day it exists.
    public static let requestable = allCases.filter { $0 != .automation }.map(\.rawValue).joined(separator: ", ")

    public var displayName: String {
        switch self {
        case .speechRecognition: return "Speech Recognition"
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .location: return "Location Services"
        case .fullDiskAccess: return "Full Disk Access"
        case .screenRecording: return "Screen Recording"
        case .inputMonitoring: return "Input Monitoring"
        case .automation: return "Automation"
        case .calendars: return "Calendar"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        case .notifications: return "Notifications"
        case .bluetooth: return "Bluetooth"
        case .camera: return "Camera"
        case .photos: return "Photos"
        }
    }

    /// macOS Privacy & Security anchor; Notifications has its own pane.
    public var settingsAnchor: String? {
        switch self {
        case .speechRecognition: return "Privacy_SpeechRecognition"
        case .microphone: return "Privacy_Microphone"
        case .accessibility: return "Privacy_Accessibility"
        case .location: return "Privacy_LocationServices"
        case .fullDiskAccess: return "Privacy_AllFiles"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .automation: return "Privacy_Automation"
        case .calendars: return "Privacy_Calendars"
        case .reminders: return "Privacy_Reminders"
        case .contacts: return "Privacy_Contacts"
        case .notifications: return nil
        case .bluetooth: return "Privacy_Bluetooth"
        case .camera: return "Privacy_Camera"
        case .photos: return "Privacy_Photos"
        }
    }
}

public enum SystemPermissionStatus: String, Sendable {
    case granted
    case denied
    case restricted
    case notDetermined
    case unknown
}

public struct SystemPermissionSnapshot: Sendable, Equatable {
    public let capability: SystemPermissionCapability
    public let status: SystemPermissionStatus
    public let detail: String

    public init(capability: SystemPermissionCapability, status: SystemPermissionStatus, detail: String = "") {
        self.capability = capability
        self.status = status
        self.detail = detail
    }
}

public enum SystemPermissionPreflight {
    /// Posted by any permission source that learns of a change in-process (a Location answer); the card port re-checks its waiting cards on it.
    public static let permissionDidChange = Notification.Name("NativeAgent.SystemPermissionPreflight.permissionDidChange")
    private static let logger = Logger(subsystem: "com.nativeagent.app", category: "permission-preflight")

    public typealias SpeechAuthorizationRequest = @Sendable (
        @escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void
    ) -> Void

    public static let settingsPanePrefix = "x-apple.systempreferences:com.apple.preference.security?"

    /// Full System Settings deep link for a capability.
    public static func settingsURL(for capability: SystemPermissionCapability) -> URL? {
        if capability == .notifications {
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        }
        guard let anchor = capability.settingsAnchor else { return nil }
        return URL(string: settingsPanePrefix + anchor)
    }

    /// A grant macOS hands a process only when it launches: System Settings itself offers "Quit & Reopen" for these.
    public static let appliesAtLaunch: Set<SystemPermissionCapability> =
        [.accessibility, .fullDiskAccess, .screenRecording, .inputMonitoring]

    /// The launch-applied grants this process started with, read once at launch (the app touches it first thing).
    public static let grantedAtLaunch = Set(appliesAtLaunch.filter { status($0) == .granted })

    /// The grants among a card's ids that macOS shows on now but this process started without: it has them only after it restarts, whatever its probe says now.
    public static func awaitingLaunch(_ ids: [String]) -> [SystemPermissionCapability] {
        var seen: Set<SystemPermissionCapability> = []
        return ids.compactMap(cardSettingsCapability).filter {
            appliesAtLaunch.contains($0) && !grantedAtLaunch.contains($0)
                && status($0) == .granted && seen.insert($0).inserted
        }
    }

    public static func cardSettingsCapability(_ id: String) -> SystemPermissionCapability? {
        if id.hasPrefix("privacy:") {
            let capability = SystemPermissionCapability(rawValue: String(id.dropFirst(8)))
            return capability == .automation ? nil : capability
        }
        if AppleScriptExecution.automationTarget(id) != nil { return .automation }
        switch id {
        case "calendar": return .calendars
        case "reminders": return .reminders
        case "contacts": return .contacts
        case "accessibility": return .accessibility
        case "location": return .location
        case "screen_capture", "screen_recording": return .screenRecording
        case "input_monitoring": return .inputMonitoring
        case "full_disk_access", "messages": return .fullDiskAccess
        case "speech_recognition": return .speechRecognition
        case "microphone": return .microphone
        case "notifications", "notify_mac": return .notifications
        case "bluetooth": return .bluetooth
        case "camera": return .camera
        case "photos": return .photos
        default: return nil
        }
    }

    public static func cardSettingsInstructions(_ ids: [String]) -> [String] {
        var seen: Set<SystemPermissionCapability> = []
        return ids.compactMap { id in
            guard let pane = cardSettingsCapability(id), seen.insert(pane).inserted else { return nil }
            return pane == .fullDiskAccess
                ? "Add NativeAgent from Finder to the pane that opens, then turn it on."
                : "Allow \(pane.displayName) on this card; turn on NativeAgent in the pane that opens."
        }
    }

    public static func remedy(_ id: String, mode: InlineInteraction.AccessMode? = nil) -> JSONValue? {
        guard let capability = cardSettingsCapability(id) else { return nil }
        let target = AppleScriptExecution.automationTarget(id).map { "applescript:" + $0 }
            ?? capability.rawValue
        let name = AppleScriptExecution.automationTarget(id).map { "Automation for " + $0 } ?? capability.displayName
        var args: [String: JSONValue] = ["capability": .string(target), "why": .string("NativeAgent needs \(name) for this work. Allow?")]
        if let mode { args["mode"] = .string(mode.rawValue) }
        return Repair.remedy(owner: "macOS \(name) grant", nextCall: .object([
            "tool": .string("app"), "input": .object(["action": .string("permissions.request"), "args": .object(args)]),
        ]), tap: "Allow \(name) on the permission card in NativeAgent")
    }

    // MARK: - Non-prompting reads

    /// Reads the current TCC state. **MUST NEVER PROMPT.** Every call below is the query-only variant of its framework's API; the requesting variants (`SFSpeechRecognizer.requestAuthorization`, `CGRequestScreenCaptureAccess`,
    /// `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt: true`, `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: true)`) are deliberately absent. A prompt fired from a background context is not just invisible —
    /// macOS resolves it to a hard `.denied` the user can never undo from inside the app, which is the exact bug this file exists to fix.
    public static func status(_ capability: SystemPermissionCapability) -> SystemPermissionStatus {
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
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .photos:
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized, .limited: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .accessibility:
            // AXIsProcessTrusted() is the no-prompt form; the prompting form is AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt. AX exposes no notDetermined/restricted distinction — it is a boolean trust bit — so a non-
            // trusted process reads as .denied.
            return AXIsProcessTrusted() ? .granted : .denied
        case .location:
            guard CLLocationManager.locationServicesEnabled() else { return .denied }
            switch MacLocationReader.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .fullDiskAccess:
            return MacMessagesHistory.hasAccess ? .granted : .denied
        case .screenRecording:
            // CGPreflightScreenCaptureAccess is the preflight (no prompt); CGRequestScreenCaptureAccess is the prompting sibling.
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .inputMonitoring:
            return CGPreflightListenEventAccess() ? .granted : .denied
        case .calendars:
            return mapEKStatus(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return mapEKStatus(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return .granted
            case .limited: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .automation, .notifications:
            // No CHEAP non-prompting read exists here. Automation: AEDeterminePermissionToAutomateTarget is per-target, requires the target app to be running, and the only variant that resolves a not-yet-determined grant is
            // askUserIfNeeded:true — which prompts. MacIntegrationView owns that per-app probe. Notifications: UNUserNotificationCenter's settings read is async and requires a bundled, registered app.
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
            // NOT .granted. Write-only means the app may add events but cannot READ them, and every calendar/reminder capability this app surfaces (briefings, watch jobs, mac_calendar_list_upcoming) is a read. Reporting .granted here would
            // show a green row while those reads keep failing — the same "looks fine, silently broken" shape this whole file exists to kill. MacPIMConnectorActions already treats write-only as not read-ready; match it.
            return .denied
        @unknown default: return .unknown
        }
    }

    /// The permission card owns acquisition; status reads never prompt.
    public static func warningSummary(for snapshot: SystemPermissionSnapshot) -> String {
        let name = snapshot.capability.displayName
        switch snapshot.status {
        case .notDetermined, .denied:
            return "NativeAgent needs \(name). Allow it on the permission card."
        case .restricted:
            return "\(name) is restricted by this Mac's administrator. Ask them to allow NativeAgent."
        case .granted, .unknown:
            return "\(name): \(snapshot.status.rawValue)."
        }
    }

    // MARK: - Foreground acquisition

    /// Bridges Speech's callback without inheriting the caller's actor.  `SFSpeechRecognizer.requestAuthorization` is invoked from the main actor so macOS can present its consent sheet, but TCC delivers the completion on an arbitrary
    /// dispatch queue. Defining the continuation bridge as `nonisolated` is essential: otherwise Swift 6 actor inference makes the callback main-actor isolated and traps when TCC calls it off-main.
    public nonisolated static func awaitSpeechAuthorization(
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

    /// Fires the macOS Speech Recognition consent prompt — but ONLY from the main actor, and ONLY when the grant is still `.notDetermined`.  Why main-actor/foreground is not a style preference: `SFSpeechRecognizer.requestAuthorization`
    /// from a headless context (a background poll loop, a detached utility task with no active app) cannot render its prompt. macOS does not queue it for later — it resolves the request `.denied` immediately, WITHOUT writing a real user
    /// decision into the TCC database. The user is then stuck: the app looks denied, the system never asked, and no in-app button can re-ask, because TCC will not re-prompt a resolved grant. That is precisely how the Telegram voice-note
    /// path bricked itself (`data/telegram/errors.jsonl`, context=voice_transcription, speechPermissionDenied("denied")).  Reading first is the other half of the guard: calling request on an already-denied grant is a silent no-op, so
    /// callers must route those to System Settings instead of showing a button that appears to do nothing.
    @MainActor
    public static func requestSpeechRecognitionIfNotDetermined() async -> SystemPermissionStatus {
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

// MARK: - Setup cards

extension SystemPermissionPreflight {
    /// The first macOS switch still off for these ids, as the one sentence of what to click; nil when macOS has nothing against it.
    public static func cardBlockReason(_ ids: [String], mode: InlineInteraction.AccessMode?) async -> String? {
        for id in ids {
            guard let gate = cardSettingsCapability(id) else { continue }
            if let bundleID = AppleScriptExecution.automationTarget(id) {
                let permission = await AppleScriptExecution.automationPermission(bundleID: bundleID)
                guard case .object(let fields) = permission, fields["state"] == .string("allowed") else {
                    return (try? permission.serialize(pretty: false)) ?? "Automation consent unavailable."
                }
                continue
            }
            let current: SystemPermissionStatus
            if gate == .notifications {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                switch settings.authorizationStatus {
                case .authorized, .provisional: current = .granted
                case .notDetermined: current = .notDetermined
                case .denied: current = .denied
                default: current = .unknown
                }
            } else { current = cardStatus(gate, mode: mode) }
            if current == .granted { continue }
            if current == .unknown {
                return "macOS hasn't confirmed \(gate.displayName) yet."
            }
            return "macOS hasn't allowed \(gate.displayName) yet. Return after turning it on; I'll continue."
        }
        return nil
    }

    /// Only a real grant counts. A Calendar WRITE card is satisfied by macOS's write-only access as well as full access.
    public static func cardStatus(
        _ gate: SystemPermissionCapability, mode: InlineInteraction.AccessMode?
    ) -> SystemPermissionStatus {
        guard gate == .calendars, mode == .write else { return status(gate) }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .writeOnly, .fullAccess, .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }

}

public enum MacIntegrationFrameworkPermission: String, CaseIterable {
    case speechRecognition = "speech_recognition"
    case microphone
    case calendar
    case reminders
    case contacts

    public var label: String {
        switch self {
        case .speechRecognition: return "Speech Recognition"
        case .microphone: return "Microphone"
        default: return rawValue.capitalized
        }
    }

    public var purpose: String {
        switch self {
        case .speechRecognition: return "Turn voice messages and dictation into text."
        case .microphone: return "Record your voice when you use the microphone."
        case .calendar: return "Read and manage events in Mac Calendar."
        case .reminders: return "Read and manage your reminders."
        case .contacts: return "Find people in your address book."
        }
    }

    /// Single source of truth for the pane anchors: the shared capability vocabulary, not a second hand-maintained copy.
    public var capability: SystemPermissionCapability {
        switch self {
        case .calendar: return .calendars
        case .reminders: return .reminders
        case .contacts: return .contacts
        case .speechRecognition: return .speechRecognition
        case .microphone: return .microphone
        }
    }

    public var settingsAnchor: String {
        capability.settingsAnchor ?? "Privacy_AllFiles"
    }
}
