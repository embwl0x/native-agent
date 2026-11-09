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

    /// Derive permission request names from the capability owner so new capabilities cannot be omitted.
    public static let requestable = allCases.filter { $0 != .automation }.map(\.rawValue).joined(separator: ", ")

    public var displayName: String {
        switch self {
        case .speechRecognition: return "Speech Recognition"
        case .microphone: return "Microphone"
        case .accessibility: return MacFourVerbsReply.accessibilityGrantName
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
    /// In-process grant changes wake waiting cards so a Location answer can settle them.
    public static let permissionDidChange = MacIntegrationPermissionStore.didChange
    private static let logger = Logger(subsystem: "com.nativeagent.app", category: "permission-preflight")

    public typealias SpeechAuthorizationRequest = @Sendable (
        @escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void
    ) -> Void

    public static let settingsPanePrefix = "x-apple.systempreferences:com.apple.preference.security?"

    public static func settingsURL(for capability: SystemPermissionCapability) -> URL? {
        if capability == .notifications {
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        }
        guard let anchor = capability.settingsAnchor else { return nil }
        return URL(string: settingsPanePrefix + anchor)
    }

    /// A grant macOS hands a process only when it launches: System Settings itself offers "Quit & Reopen" for these. Accessibility takes effect live.
    public static let appliesAtLaunch: Set<SystemPermissionCapability> =
        [.fullDiskAccess, .screenRecording, .inputMonitoring]

    /// Capture launch-applied grants before later probes can observe settings this process has not acquired.
    public static let grantedAtLaunch = Set(appliesAtLaunch.filter { status($0) == .granted })

    /// A launch-applied grant enabled after startup still requires a restart, regardless of its current probe.
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

    /// The card target that asks for exactly this macOS grant. A bare name can also mean a Trust switch (accessibility, contacts…), so a grant is
    /// privacy:<grant>, or applescript:<bundle_id> for one app's Automation.
    public static func grantTarget(_ id: String) -> String? {
        guard let capability = cardSettingsCapability(id) else { return nil }
        return AppleScriptExecution.automationTarget(id).map { "applescript:" + $0 } ?? "privacy:" + capability.rawValue
    }

    public static func remedy(_ id: String, mode: InlineInteraction.AccessMode? = nil) -> JSONValue? {
        guard let capability = cardSettingsCapability(id), let target = grantTarget(id) else { return nil }
        let name = AppleScriptExecution.automationTarget(id).map { "Automation for " + $0 } ?? capability.displayName
        return MacFourVerbsReply.permissionRemedy(target, name: name, mode: mode)
    }

    // MARK: - Non-prompting reads

    /// Keep probe evidence with its status so an unreadable source cannot be presented as a denied grant.
    public static func snapshot(_ capability: SystemPermissionCapability) -> SystemPermissionSnapshot {
        if capability == .fullDiskAccess { return fullDiskAccessSnapshot() }
        return SystemPermissionSnapshot(capability: capability, status: status(capability))
    }

    /// Status reads must never prompt: a background consent request can resolve denied without presenting a usable prompt.
    public static func status(_ capability: SystemPermissionCapability) -> SystemPermissionStatus {
        switch capability {
        case .speechRecognition:
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
            // AX exposes only a boolean trust bit, so an untrusted process reads as denied without prompting.
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
            return snapshot(capability).status
        case .screenRecording:
            // Preflight screen capture without invoking the prompting request API.
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
            // Automation needs a running target and may prompt; its per-app probe belongs to MacIntegrationFacade.refresh, which Trust's macOS grants
            // rows draw. Notifications require an async bundled-app read.
            return .unknown
        }
    }

    /// Opening the protected directory reads no messages. Only access errors establish denial.
    public static func fullDiskAccessSnapshot() -> SystemPermissionSnapshot {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages").path
        guard let directory = opendir(path) else {
            let code = errno
            let denied = code == EACCES || code == EPERM
            let detail = "Full Disk Access probe at \(path) failed (POSIX \(code)): \(String(cString: strerror(code)))."
            logger.error("\(detail, privacy: .public)")
            return SystemPermissionSnapshot(capability: .fullDiskAccess, status: denied ? .denied : .unknown, detail: detail)
        }
        closedir(directory)
        return SystemPermissionSnapshot(capability: .fullDiskAccess, status: .granted)
    }

    private static func mapEKStatus(_ status: EKAuthorizationStatus) -> SystemPermissionStatus {
        switch status {
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        case .fullAccess: return .granted
        case .writeOnly:
            // Write-only access cannot satisfy calendar reads; readiness must match the read boundary in MacPIMConnectorActions.
            return .denied
        @unknown default: return .unknown
        }
    }

    /// The permission card owns acquisition; status reads never prompt.
    public static func warningSummary(for snapshot: SystemPermissionSnapshot) -> String {
        let name = snapshot.capability.displayName
        if snapshot.status == .unknown, !snapshot.detail.isEmpty { return snapshot.detail }
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

    /// TCC delivers Speech completion on an arbitrary queue. Keep the callback nonisolated to avoid a Swift 6 actor-isolation trap.
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

    /// Request Speech only in the foreground on the main actor while not determined: headless requests can resolve denied without showing consent.
    /// Already-denied grants require System Settings.
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
    /// Offer only the first switch still off so opening Settings does not hide an earlier required pane.
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
            } else if gate == .fullDiskAccess {
                let snapshot = Self.snapshot(gate)
                if snapshot.status == .unknown { return snapshot.detail }
                current = snapshot.status
            } else { current = cardStatus(gate, mode: mode) }
            if current == .granted { continue }
            if current == .unknown {
                return "macOS hasn't confirmed \(gate.displayName) yet."
            }
            return "macOS hasn't allowed \(gate.displayName) yet. Return after turning it on; I'll continue."
        }
        return nil
    }

    /// The order a card walks its grants, least friction first: what macOS asks in-app (Automation targets included), then Accessibility, which takes
    /// effect live, then the launch-applied grants one restart covers, Full Disk Access last. Ties keep the card's own order.
    public static func frictionOrder(_ ids: [String]) -> [String] {
        func rank(_ id: String) -> Int {
            switch cardSettingsCapability(id) {
            case .accessibility: return 1
            case .screenRecording, .inputMonitoring: return 2
            case .fullDiskAccess: return 3
            default: return 0
            }
        }
        return ids.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// What a card's grants wait on now, read live and never prompting: the first grant still off in friction order, else the one restart its
    /// launch-applied grants need, else nothing. A grant macOS has not confirmed is still waited on.
    public static func waitingOn(_ ids: [String], mode: InlineInteraction.AccessMode?) async -> InlineInteraction.WaitingOn? {
        for id in frictionOrder(ids) where cardSettingsCapability(id) != nil {
            if await cardBlockReason([id], mode: mode) != nil { return .target(id) }
        }
        return awaitingLaunch(ids).isEmpty ? nil : .restart
    }

    /// The launch-applied grants on a card that this process did not launch with, in walk order: one restart is what makes them take effect.
    public static func launchPending(_ ids: [String]) -> [SystemPermissionCapability] {
        var seen: Set<SystemPermissionCapability> = []
        return frictionOrder(ids).compactMap(cardSettingsCapability).filter {
            appliesAtLaunch.contains($0) && !grantedAtLaunch.contains($0) && seen.insert($0).inserted
        }
    }

    /// The walk has reached what one restart covers: the restart itself, or a launch-applied grant whose probe this process may not see until then.
    public static func waitsForRestart(_ waiting: InlineInteraction.WaitingOn?) -> Bool {
        switch waiting {
        case .some(.restart): return true
        case .some(.target(let id)): return cardSettingsCapability(id).map { appliesAtLaunch.contains($0) } ?? false
        case nil: return false
        }
    }

    /// Where the person turns a grant on, in System Settings' own names.
    public static func settingsPath(_ capability: SystemPermissionCapability) -> String {
        capability == .notifications ? "System Settings → Notifications → NativeAgent"
            : "System Settings → Privacy & Security → \(capability.displayName)"
    }

    /// Only a real grant counts. A Calendar WRITE card is satisfied by macOS's write-only access as well as full access.
    public static func cardStatus(
        _ gate: SystemPermissionCapability, mode: InlineInteraction.AccessMode?
    ) -> SystemPermissionStatus {
        guard gate == .calendars, mode == .write else { return status(gate) }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .writeOnly, .fullAccess: return .granted
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
