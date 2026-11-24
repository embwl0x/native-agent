import Foundation
import Darwin
import Synchronization
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

    /// What the grant lets the agent do, in plain words, as a permission card's row says it after the grant's name.
    public var purpose: String {
        switch self {
        case .speechRecognition: return "turn what you say into words"
        case .microphone: return "hear you when you talk to me"
        case .accessibility: return "click, type and move windows on your Mac when you ask"
        case .location: return "know where this Mac is when you ask"
        case .fullDiskAccess: return "read your Messages history and other protected files when you ask"
        case .screenRecording: return "see your screen when you ask"
        case .inputMonitoring: return "tell when you're at the Mac, and your typing from mine"
        case .automation: return "work in your apps when you ask"
        case .calendars: return "read your calendar and add events"
        case .reminders: return "read your reminders and add new ones"
        case .contacts: return "look up the people you mention"
        case .notifications: return "let you know when something needs you"
        case .bluetooth: return "work with a Bluetooth device when you ask"
        case .camera: return "use the camera when you ask"
        case .photos: return "find photos in your library when you ask"
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
    public static let grantedAtLaunch = Set(appliesAtLaunch.filter(heldByThisProcess))

    static func heldByThisProcess(_ capability: SystemPermissionCapability) -> Bool {
        switch capability {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .inputMonitoring: CGPreflightListenEventAccess()
        default: status(capability) == .granted
        }
    }

    static let grantProbeArgument = "--nativeagent-grant-probe"
    /// The app's own executable, set by its entry point: only the app answers the grant probe, so only the app runs one.
    private static let grantProbeExecutable = Mutex<String?>(nil)

    /// Executable-only mode, before anything else starts. A fresh process of the app holds what the next launch will hold: it prints the
    /// launch-applied grants it holds and exits. Any other launch records this executable as the one that answers the probe.
    public static func runGrantProbeIfRequested() -> Bool {
        guard CommandLine.arguments.dropFirst().first == grantProbeArgument else {
            grantProbeExecutable.withLock { $0 = Bundle.main.executablePath }
            return false
        }
        let held = [SystemPermissionCapability.screenRecording, .inputMonitoring].filter(heldByThisProcess).map(\.rawValue)
        FileHandle.standardOutput.write(Data(held.joined(separator: "\n").utf8))
        return true
    }

    @concurrent private static func nextLaunchHeld() async -> Set<SystemPermissionCapability>? {
        guard let executable = grantProbeExecutable.withLock({ $0 }) else { return nil }
        let result: ProcessRunResult
        do {
            result = try await ProcessExecution().run(
                executable: executable,
                arguments: [grantProbeArgument],
                currentDirectory: nil,
                environment: ManagedProcess.agentEnvironment(),
                standardInput: nil,
                timeoutSeconds: nil
            )
        } catch is CancellationError {
            return nil
        } catch is ProcessRunCancellation {
            return nil
        } catch {
            logger.error("Grant probe failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard result.exitCode == 0, !result.stdoutTruncated else { return nil }
        let names = Set(result.stdout.split(separator: "\n").map(String.init))
        return Set([SystemPermissionCapability.screenRecording, .inputMonitoring].filter { names.contains($0.rawValue) })
    }

    private static func nextLaunchStatus(
        _ capability: SystemPermissionCapability,
        cached: inout Set<SystemPermissionCapability>??
    ) async -> SystemPermissionStatus {
        if heldByThisProcess(capability) { return .granted }
        if grantedAtLaunch.contains(capability) { return .denied }
        let held: Set<SystemPermissionCapability>?
        if let existing = cached {
            held = existing
        } else {
            let fresh = await nextLaunchHeld()
            cached = .some(fresh)
            held = fresh
        }
        guard let held else { return .unknown }
        return held.contains(capability) ? .granted : .denied
    }

    /// A launch-applied grant enabled after startup still requires a restart, regardless of its current probe.
    @concurrent public static func awaitingLaunch(_ ids: [String]) async -> [SystemPermissionCapability] {
        var cached: Set<SystemPermissionCapability>??
        var result: [SystemPermissionCapability] = []
        for capability in launchPending(ids) {
            if await statusAsync(capability, cached: &cached) == .granted {
                result.append(capability)
            }
        }
        return result
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

    /// The grants macOS never asks in place: their switch is only in System Settings, so a walk opens their pane. Any other grant the person already
    /// declined joins them, read live.
    public static let keptInSettings: Set<SystemPermissionCapability> = [.accessibility, .screenRecording, .inputMonitoring, .fullDiskAccess]

    /// One line per grant the card sends to System Settings; macOS asks the others in place.
    public static func cardSettingsInstructions(_ ids: [String]) -> [String] {
        var seen: Set<SystemPermissionCapability> = []
        return ids.compactMap { id in
            guard let pane = cardSettingsCapability(id), keptInSettings.contains(pane), seen.insert(pane).inserted else { return nil }
            return pane == .fullDiskAccess
                ? "\(pane.displayName): add NativeAgent from Finder to the pane that opens, then turn it on."
                : "\(pane.displayName): turn on NativeAgent in the pane that opens."
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
    @concurrent public static func snapshot(_ capability: SystemPermissionCapability) async -> SystemPermissionSnapshot {
        if capability == .fullDiskAccess { return fullDiskAccessSnapshot() }
        return SystemPermissionSnapshot(capability: capability, status: await statusAsync(capability))
    }

    @concurrent public static func statusAsync(_ capability: SystemPermissionCapability) async -> SystemPermissionStatus {
        var cached: Set<SystemPermissionCapability>??
        return await statusAsync(capability, cached: &cached)
    }

    private static func statusAsync(
        _ capability: SystemPermissionCapability,
        cached: inout Set<SystemPermissionCapability>??
    ) async -> SystemPermissionStatus {
        switch capability {
        case .screenRecording, .inputMonitoring:
            return await nextLaunchStatus(capability, cached: &cached)
        default:
            return status(capability)
        }
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
            return fullDiskAccessSnapshot().status
        case .screenRecording, .inputMonitoring:
            if heldByThisProcess(capability) { return .granted }
            return grantedAtLaunch.contains(capability) ? .denied : .unknown
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
            let detail = "Full Disk Access probe at \(path) failed (POSIX \(code)): \(unsafe String(cString: strerror(code)))."
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
        case .unknown:
            return "macOS hasn't confirmed \(name)."
        case .granted:
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
    @concurrent public static func cardBlockReason(
        _ ids: [String], mode: InlineInteraction.AccessMode?, requiresLaunch: Bool = false
    ) async -> String? {
        var cached: Set<SystemPermissionCapability>??
        let pending = requiresLaunch ? launchPending(ids) : []
        for id in ids {
            guard let gate = cardSettingsCapability(id) else { continue }
            let reading = await cardReading(id, gate: gate, mode: mode, cached: &cached)
            if reading.status == .granted {
                if pending.contains(gate) {
                    return "\(gate.displayName) is on, and it takes effect after I restart: use Restart on this card."
                }
                continue
            }
            if gate == .automation, !reading.detail.isEmpty { return reading.detail }
            if reading.status == .unknown { return warningSummary(for: reading) }
            return "macOS hasn't allowed \(gate.displayName) yet. Return after turning it on; I'll continue."
        }
        return nil
    }

    @concurrent public static func cardReadings(
        _ ids: [String], mode: InlineInteraction.AccessMode?
    ) async -> [(id: String, reading: SystemPermissionSnapshot)] {
        var cached: Set<SystemPermissionCapability>??
        var readings: [(id: String, reading: SystemPermissionSnapshot)] = []
        for id in ids {
            guard let gate = cardSettingsCapability(id) else { continue }
            readings.append((id, await cardReading(id, gate: gate, mode: mode, cached: &cached)))
        }
        return readings
    }

    private static func cardReading(
        _ id: String, gate: SystemPermissionCapability, mode: InlineInteraction.AccessMode?,
        cached: inout Set<SystemPermissionCapability>??
    ) async -> SystemPermissionSnapshot {
        if let bundleID = AppleScriptExecution.automationTarget(id) {
            let permission = await AppleScriptExecution.automationPermission(bundleID: bundleID)
            let status: SystemPermissionStatus = switch permission.objectValue?["state"] {
            case .string("allowed"): .granted
            case .string("denied"): .denied
            case .string("needs_consent"): .notDetermined
            default: .unknown
            }
            return .init(capability: gate, status: status, detail: (try? permission.serialize(pretty: false)) ?? "Automation consent unavailable.")
        }
        switch gate {
        case .notifications: return .init(capability: gate, status: await notificationStatus())
        case .fullDiskAccess: return fullDiskAccessSnapshot()
        default: return .init(capability: gate, status: await cardStatus(gate, mode: mode, cached: &cached))
        }
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

    /// What a card's grants wait on now, read live and never prompting: the first grant still off in friction order that the walk has not
    /// already shown the person (`passed`: its pane opened and the person came back without it reading on). Past those, the one restart when
    /// a launch-applied grant reads on, else the first unresolved grant, so the card can open it again; nothing when all are on.
    @concurrent public static func waitingOn(
        _ ids: [String], mode: InlineInteraction.AccessMode?, passed: Set<String> = []
    ) async -> InlineInteraction.WaitingOn? {
        var cached: Set<SystemPermissionCapability>??
        let pending = launchPending(ids)
        var restart = false
        var left: [String] = []
        for id in frictionOrder(ids) {
            guard let gate = cardSettingsCapability(id) else { continue }
            let reading = await cardReading(id, gate: gate, mode: mode, cached: &cached)
            if reading.status == .granted {
                if pending.contains(gate) { restart = true }
                continue
            }
            if !passed.contains(id) { return .target(id) }
            left.append(id)
        }
        if restart || left.contains(where: { cardSettingsCapability($0).map(appliesAtLaunch.contains) == true }) { return .restart }
        return left.first.map { .target($0) }
    }

    /// The launch-applied grants on a card that this process did not launch with, in walk order: one restart is what makes them take effect.
    public static func launchPending(_ ids: [String]) -> [SystemPermissionCapability] {
        var seen: Set<SystemPermissionCapability> = []
        return frictionOrder(ids).compactMap(cardSettingsCapability).filter {
            appliesAtLaunch.contains($0) && !grantedAtLaunch.contains($0) && seen.insert($0).inserted
        }
    }

    /// The macOS grants that make up the reach on this Mac, as the permission card names them; each app's Automation joins them from
    /// `AppleScriptExecution.automationTargetApps`.
    public static let reach: [SystemPermissionCapability] = [.notifications, .calendars, .reminders, .contacts, .microphone, .speechRecognition,
        .accessibility, .screenRecording, .inputMonitoring, .fullDiskAccess]

    /// The whole reach as it reads now, from the app's own grant reading and never the screen, never prompting: what a walk through System
    /// Settings reports after each pane, so it says what is granted rather than what it hoped landed.
    @concurrent public static func reachNow() async -> (text: String, detail: JSONValue) {
        var cached: Set<SystemPermissionCapability>??
        var granted: [String] = [], off: [String] = [], restart: [String] = [], unknown: [String] = []
        var fields: [String: JSONValue] = [:]
        for target in frictionOrder(reach.map { "privacy:" + $0.rawValue }) {
            guard let gate = cardSettingsCapability(target) else { continue }
            // An unreadable grant stays unknown with its cause; it is never reported as off.
            let reading = await cardReading(target, gate: gate, mode: nil, cached: &cached)
            switch reading.status {
            case .unknown:
                let cause = reading.detail.isEmpty ? "macOS gave no reading" : reading.detail
                unknown.append(gate.displayName + " (" + cause + ")")
                fields[gate.rawValue] = .object(["status": .string("unknown"), "cause": .string(cause)])
            case .granted where !launchPending([target]).isEmpty:
                restart.append(gate.displayName)
                fields[gate.rawValue] = .string("granted_after_restart")
            case .granted:
                granted.append(gate.displayName)
                fields[gate.rawValue] = .string("granted")
            case .denied, .notDetermined, .restricted:
                off.append(gate.displayName)
                fields[gate.rawValue] = .string(reading.status.rawValue)
            }
        }
        var automation: [String] = []
        for app in AppleScriptExecution.automationTargetApps {
            guard let bundleID = AppleScriptExecution.automationTargetBundleIDs[app] else { continue }
            guard case .object(let probe) = await AppleScriptExecution.automationPermission(bundleID: bundleID) else { continue }
            let (words, state): (String, String) = switch probe["code"] {
            case .int(0)?: ("granted", "granted")
            case .int(-1743)?: ("denied", "denied")
            case .int(-1744)?: ("not asked yet", "not_determined")
            case .int(-600)?: ("unread while \(app) is not running", "app_not_running")
            default: ("unknown (" + (probe["detail"]?.stringValue ?? "macOS gave no reading") + ")", "unknown")
            }
            automation.append(app + " " + words)
            fields["automation." + app.lowercased()] = .string(state)
        }
        func list(_ names: [String]) -> String { names.isEmpty ? "none" : names.joined(separator: ", ") }
        var text = "macOS grants now, read by the app itself: granted: \(list(granted)); not granted: \(list(off))"
        if !restart.isEmpty { text += "; granted, takes effect after one restart: \(list(restart))" }
        if !unknown.isEmpty { text += "; unknown: \(list(unknown))" }
        text += "; Automation: \(list(automation))."
        return (text, .object(fields))
    }

    /// The notification grant as macOS reports it for this app, never prompting.
    static func notificationStatus() async -> SystemPermissionStatus {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .unknown
        }
    }

    /// Where the person turns a grant on, in System Settings' own names.
    public static func settingsPath(_ capability: SystemPermissionCapability) -> String {
        capability == .notifications ? "System Settings → Notifications → NativeAgent"
            : "System Settings → Privacy & Security → \(capability.displayName)"
    }

    /// Only a real grant counts. A Calendar WRITE card is satisfied by macOS's write-only access as well as full access.
    private static func cardStatus(
        _ gate: SystemPermissionCapability,
        mode: InlineInteraction.AccessMode?,
        cached: inout Set<SystemPermissionCapability>??
    ) async -> SystemPermissionStatus {
        guard gate == .calendars, mode == .write else { return await statusAsync(gate, cached: &cached) }
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
