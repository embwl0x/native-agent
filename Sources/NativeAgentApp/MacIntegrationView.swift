// PATCH-2026-06-07: mac-integration-tab — per-integration READ/WRITE permission
// toggles for Calendar, Reminders, Contacts, Mail, Messages, Notes, Music,
// Notifications (mac + mobile), Spotlight, Scheduler. Binds against the W1
// substrate (MacIntegrationPermissionStore.shared). Changes persist to
// <dataRoot>/security/mac_integration_permissions.json.
import SwiftUI
import MacIntegration
import AVFoundation

/// Presentation-level truth for the System Permissions card. These helpers
/// deliberately accept only the statuses the real probes can verify; cached,
/// stale, or invented values must keep the acquisition CTA visible.
enum MacIntegrationSystemPermissionPresentation {
    static let speechRecognitionKey = "speech_recognition"
    static let microphoneKey = "microphone"
    static let calendarKey = "calendar"
    static let remindersKey = "reminders"
    static let contactsKey = "contacts"
    static let appleEventsMailKey = "apple_events_mail"
    static let appleEventsMessagesKey = "apple_events_messages"
    static let appleEventsNotesKey = "apple_events_notes"
    static let appleEventsMusicKey = "apple_events_music"

    static let statusKeys = [
        speechRecognitionKey, microphoneKey,
        calendarKey, remindersKey, contactsKey,
        appleEventsMailKey, appleEventsMessagesKey,
        appleEventsNotesKey, appleEventsMusicKey,
    ]

    static func allGranted(_ statuses: [String: String]) -> Bool {
        statusKeys.allSatisfy { statuses[$0] == "granted" || statuses[$0] == "authorized" }
    }

    static func cachedAppleEventStatuses(from raw: [String: Any]) -> [String: String] {
        raw.reduce(into: [:]) { result, item in
            guard item.key.hasPrefix("apple_events_"), let status = item.value as? String else { return }
            result[item.key] = status
        }
    }

    static func appleEventStatusesForCache(_ statuses: [String: String]) -> [String: String] {
        statuses.filter { $0.key.hasPrefix("apple_events_") }
    }

    static func loadAppleEventStatuses(from defaults: UserDefaults, key: String) -> [String: String] {
        cachedAppleEventStatuses(from: defaults.dictionary(forKey: key) ?? [:])
    }

    static func saveAppleEventStatuses(
        _ statuses: [String: String],
        to defaults: UserDefaults,
        key: String
    ) {
        defaults.set(appleEventStatusesForCache(statuses), forKey: key)
    }

    /// The cached paint is only a cold-start placeholder. A completed passive
    /// TCC probe owns the final visible truth, even when it changes a prior
    /// grant to a denial.
    static func mergingCachedAppleEvents(
        _ cached: [String: String],
        withProbed probed: [String: String]
    ) -> [String: String] {
        cached.merging(probed) { _, probeValue in probeValue }
    }
}

/// The only System Settings launch boundary for the Mac Integration panel.
/// A valid deep-link URL is not proof the handoff succeeded: `NSWorkspace.open`
/// can return false when the target pane is unavailable, so retain that result
/// and surface it through the panel's request-failure alert.
enum MacIntegrationSettingsDeepLink {
    enum Outcome: Equatable {
        case opened(SystemPermissionCapability)
        case unavailable(SystemPermissionCapability)
        case failed(SystemPermissionCapability)

        var failureMessage: String? {
            switch self {
            case .opened:
                return nil
            case .unavailable(let capability):
                return "NativeAgent could not find a System Settings privacy pane for \(capability.displayName)."
            case .failed(let capability):
                return "NativeAgent could not open System Settings → Privacy & Security → \(capability.displayName). Open System Settings manually, enable NativeAgent, then return here and refresh."
            }
        }
    }

    static func open(
        _ capability: SystemPermissionCapability,
        using opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Outcome {
        guard let url = SystemPermissionPreflight.settingsURL(for: capability) else {
            return .unavailable(capability)
        }
        return opener(url) ? .opened(capability) : .failed(capability)
    }
}

/// The persisted integration policy is an authority store, so an existing
/// damaged file is not an empty policy. Keep its panel visible during an
/// operator-initiated retry as well; otherwise the failure momentarily turns
/// into a benign-looking loading state with no explanation.
enum MacIntegrationPermissionLoadPresentation: Equatable {
    case loading
    case controlsAvailable
    case unavailable(detail: String, retrying: Bool)

    static func resolve(isLoading: Bool, loadError: String?) -> Self {
        if let loadError {
            let detail = loadError.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(
                detail: detail.isEmpty
                    ? "The saved Mac Integration permissions could not be loaded."
                    : detail,
                retrying: isLoading
            )
        }
        return isLoading ? .loading : .controlsAvailable
    }
}

private struct MacIntegrationPermissionLoadErrorPanel: View {
    let detail: String
    let retrying: Bool
    let retry: () -> Void

    var body: some View {
        MacSection(title: "Permissions") {
            Text("Permission controls unavailable")
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.trouble)
            Text(detail)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mac-integration.permissions.load-error.detail")
            Text("Every Mac integration tool gate stays closed until the saved permission file is repaired. NativeAgent preserved the existing bytes.")
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                retry()
            } label: {
                HStack(spacing: 8) {
                    if retrying {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(retrying ? "Rechecking saved permissions…" : "Retry permission load")
                }
            }
            .disabled(retrying)
            .accessibilityIdentifier("mac-integration.permissions.load-error.retry")
            .help("Re-read the saved permission file after it has been repaired. This does not replace or rewrite it.")
        }
        .accessibilityIdentifier("mac-integration.permissions.load-error")
    }
}

enum MacIntegrationFrameworkPermission: String, CaseIterable {
    case calendar
    case reminders
    case contacts
    // Speech Recognition and Microphone share the framework-row grant path,
    // so failure copy must name them as specifically as Calendar et al.
    case speechRecognition = "speech_recognition"
    case microphone

    var label: String {
        switch self {
        case .speechRecognition: return "Speech Recognition"
        case .microphone: return "Microphone"
        default: return rawValue.capitalized
        }
    }

    /// Single source of truth for the pane anchors: the shared capability
    /// vocabulary, not a second hand-maintained copy.
    var capability: SystemPermissionCapability {
        switch self {
        case .calendar: return .calendars
        case .reminders: return .reminders
        case .contacts: return .contacts
        case .speechRecognition: return .speechRecognition
        case .microphone: return .microphone
        }
    }

    var settingsAnchor: String {
        capability.settingsAnchor ?? "Privacy_AllFiles"
    }
}

/// Pure state/copy boundary for the two visually similar permission alerts.
/// The save alert and a TCC-request failure are different user actions and
/// remain separately gated even when both errors exist at once.
enum MacIntegrationPermissionFailurePresentation {
    static let saveAlertTitle = "Permission save failed"
    static let requestAlertTitle = "Permission request failed"

    static func saveAlertIsPresented(
        persistenceError: String?,
        requestError: String?
    ) -> Bool {
        persistenceError != nil
    }

    static func requestAlertIsPresented(
        persistenceError: String?,
        requestError: String?
    ) -> Bool {
        requestError != nil
    }

    static func registrationFailureMessage(for permission: MacIntegrationFrameworkPermission) -> String {
        if permission == .calendar {
            return "macOS rejected the Calendar permission request. Quit and reopen NativeAgent, then try Grant once more. If it still fails, reinstall the current signed build; hardened-runtime builds must include Apple's Calendar entitlement."
        }
        return "macOS did not register the \(permission.label) permission request. Keep NativeAgent in the foreground and try Grant once more."
    }
}

struct MacIntegrationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var permissions: [String: MacIntegrationPermission] = [:]
    @State private var isLoading: Bool = true
    @State private var permissionLoadError: String?
    /// Refreshes can overlap on scene activation and the toolbar. Only the
    /// newest read may change what this safety panel claims about the store.
    @State private var permissionLoadGeneration = 0
    // gpt-5.5 review NEEDS_FIX: surface persistence errors instead of silently
    // swallowing them via try?. If set() throws, the toggle rolls back and the
    // alert tells the user what failed.
    @State private var persistenceError: String?

    // PATCH-2026-06-07: TCC permission wizard. Lets the user do the system-prompt
    // dance once up front instead of one-at-a-time when Agent first tries each
    // tool. Keys: "calendar" | "reminders" | "contacts" | "apple_events".
    @State private var tccStatuses: [String: String] = [:]
    @State private var isRequestingAll: Bool = false
    @State private var requestingFramework: MacIntegrationFrameworkPermission? = nil
    @State private var permissionRequestError: String?
    /// The AppleEvents target app whose per-row Grant button is mid-prompt
    /// (so we can show a spinner + disable the other Grant buttons).
    @State private var requestingApp: String? = nil

    /// Maps the shared `SystemPermissionStatus` onto the snake_case status
    /// strings this view's badges and Grant/Open-Settings branches already use.
    private static func badgeKey(_ status: SystemPermissionStatus) -> String {
        switch status {
        case .granted: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        case .unknown: return "unknown"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Choose which Mac apps and surfaces the agent can read from or act on. Sensitive surfaces — Contacts, Mail, Messages, Notes — start with read on and write off; turn on write to allow sending or changing anything. Changes take effect immediately.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                MacSection(title: "System permissions") {
                    // 2026-06-07 the user caught "only 4 system permission rows but
                    // way more tabs underneath." The collapsed "AppleEvents"
                    // row hid 4 distinct per-app TCC grants (Mail / Messages
                    // / Notes / Music) — couldn't tell which app was missing.
                    // Each integration that needs a real macOS TCC grant now
                    // gets its own row with its own badge.
                    // 2026-08-18: Speech Recognition first — it is the one the
                    // headless Telegram voice path silently depends on, and the
                    // one a user has no other way to discover is missing.
                    tccStatusRow(label: "Speech Recognition", icon: "waveform", statusKey: MacIntegrationSystemPermissionPresentation.speechRecognitionKey, frameworkPermission: .speechRecognition)
                    tccStatusRow(label: "Microphone", icon: "mic", statusKey: MacIntegrationSystemPermissionPresentation.microphoneKey, frameworkPermission: .microphone)
                    tccStatusRow(label: "Calendar", icon: "calendar", statusKey: MacIntegrationSystemPermissionPresentation.calendarKey, frameworkPermission: .calendar)
                    tccStatusRow(label: "Reminders", icon: "checklist", statusKey: MacIntegrationSystemPermissionPresentation.remindersKey, frameworkPermission: .reminders)
                    tccStatusRow(label: "Contacts", icon: "person.crop.circle", statusKey: MacIntegrationSystemPermissionPresentation.contactsKey, frameworkPermission: .contacts)
                    tccStatusRow(label: "Mail",     icon: "envelope",  statusKey: MacIntegrationSystemPermissionPresentation.appleEventsMailKey,     appleEventApp: "Mail")
                    tccStatusRow(label: "Messages", icon: "message",   statusKey: MacIntegrationSystemPermissionPresentation.appleEventsMessagesKey, appleEventApp: "Messages")
                    tccStatusRow(label: "Notes",    icon: "note.text", statusKey: MacIntegrationSystemPermissionPresentation.appleEventsNotesKey,    appleEventApp: "Notes")
                    tccStatusRow(label: "Music",    icon: "music.note",statusKey: MacIntegrationSystemPermissionPresentation.appleEventsMusicKey,    appleEventApp: "Music")

                    // Taste pass 2026-07-24: with every row above already
                    // granted, a prominent "Grant All" CTA is a dead button and
                    // the page's focal point — collapse it to a status line.
                    if allSystemPermissionsGranted {
                        Text("Every system permission is granted.")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.calm)
                            .padding(.top, 4)
                    } else {
                        Button {
                            Task { await grantAllPermissions() }
                        } label: {
                            HStack(spacing: 8) {
                                if isRequestingAll {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isRequestingAll ? "Requesting…" : "Grant every permission now")
                            }
                        }
                        .disabled(isRequestingAll)
                        .padding(.top, 4)
                        .help("Fires every macOS privacy prompt that has not been answered yet. For permissions previously denied, opens System Settings to the right pane.")
                    }
                }

                Text("These are macOS privacy permissions, separate from the read and write toggles below. Notifications, Spotlight and the scheduler need none of them. Mail, Messages, Notes and Music are automation grants — each app's first probe triggers its own prompt.")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch MacIntegrationPermissionLoadPresentation.resolve(
                    isLoading: isLoading,
                    loadError: permissionLoadError
                ) {
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading current permissions…")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                case .unavailable(let detail, let retrying):
                    MacIntegrationPermissionLoadErrorPanel(
                        detail: detail,
                        retrying: retrying,
                        retry: { Task { await loadPermissions() } }
                    )
                case .controlsAvailable:
                    MacSection(title: "Apps and surfaces") {
                        ForEach(MacIntegrationID.all, id: \.self) { id in
                            integrationRow(for: id)
                        }
                    }
                }

                // 2026-07-23 B2.5a cross-link: this tab owns per-app system
                // (TCC) grants + per-surface read/write. The Mac Control
                // CAPABILITY policy (shell, AppleScript, Accessibility, file
                // ops, iOS remote) and the assistant watch live in the Trust
                // tab — pointed to here so each control has one discoverable
                // home instead of the old two-tab split.
                MacSection(title: "Mac control capabilities") {
                    Text("Mac control capabilities — shell, AppleScript, accessibility, file operations, iOS remote and the assistant watch — live on the Trust page under Mac control.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Permissions are saved with the agent's own security files, and every NativeAgent tool consults that store before reading from or writing to any surface above.")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await loadPermissions()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await loadInitialTCCStatuses()
        }
        // TCC changes happen outside NativeAgent in System Settings. Returning
        // to the app produces a real scene activation edge, so reread then
        // instead of waking the visible view every three seconds. The manual
        // toolbar refresh remains available while NativeAgent stays active.
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        await loadPermissions()
                        await loadInitialTCCStatuses()
                    }
                }
                .help("Re-read macOS TCC permission status. Useful after granting via System Settings.")
            }
        }
        .alert(MacIntegrationPermissionFailurePresentation.saveAlertTitle,
               isPresented: Binding(
                get: {
                    MacIntegrationPermissionFailurePresentation.saveAlertIsPresented(
                        persistenceError: persistenceError,
                        requestError: permissionRequestError
                    )
                },
                set: { if !$0 { persistenceError = nil } }
               )) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "")
        }
        .alert(MacIntegrationPermissionFailurePresentation.requestAlertTitle,
               isPresented: Binding(
                get: {
                    MacIntegrationPermissionFailurePresentation.requestAlertIsPresented(
                        persistenceError: persistenceError,
                        requestError: permissionRequestError
                    )
                },
                set: { if !$0 { permissionRequestError = nil } }
               )) {
            Button("OK", role: .cancel) { permissionRequestError = nil }
        } message: {
            Text(permissionRequestError ?? "")
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func integrationRow(for id: String) -> some View {
        let supportsRead = MacIntegrationID.supportsRead(id)
        let supportsWrite = MacIntegrationID.supportsWrite(id)

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Self.iconName(for: id))
                .font(ShellType.body)
                .frame(width: 24, height: 24)
                .foregroundStyle(NativeAgentShell.tertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(MacIntegrationID.displayName(for: id))
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text(MacIntegrationID.description(for: id))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                Toggle(isOn: binding(for: id, mode: .read)) {
                    Text("Read")
                        .font(ShellType.label)
                        .foregroundStyle(supportsRead ? NativeAgentShell.secondary : NativeAgentShell.tertiary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!supportsRead)
                .accessibilityLabel("\(MacIntegrationID.displayName(for: id)) read permission")
                .help(supportsRead
                      ? "Allow the agent to read from \(MacIntegrationID.displayName(for: id))."
                      : "\(MacIntegrationID.displayName(for: id)) does not expose a read surface.")

                Toggle(isOn: binding(for: id, mode: .write)) {
                    Text("Write")
                        .font(ShellType.label)
                        .foregroundStyle(supportsWrite ? NativeAgentShell.secondary : NativeAgentShell.tertiary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!supportsWrite)
                .accessibilityLabel("\(MacIntegrationID.displayName(for: id)) write permission")
                .help(supportsWrite
                      ? "Allow the agent to send or change things in \(MacIntegrationID.displayName(for: id))."
                      : "\(MacIntegrationID.displayName(for: id)) does not expose a write surface.")
            }
            .frame(width: 104, alignment: .trailing)
        }
        .frame(minHeight: 48)
    }

    // MARK: - State

    private func loadPermissions() async {
        permissionLoadGeneration &+= 1
        let generation = permissionLoadGeneration
        isLoading = true
        do {
            // Only a missing store receives bootstrap defaults. Existing
            // damaged authority state is shown as unavailable while every hot
            // tool gate remains denied.
            let loadedPermissions = try await MacIntegrationPermissionStore.shared.currentChecked()
            guard generation == permissionLoadGeneration else { return }
            permissions = loadedPermissions
            permissionLoadError = nil
        } catch {
            guard generation == permissionLoadGeneration else { return }
            permissions = [:]
            permissionLoadError = error.localizedDescription
        }
        guard generation == permissionLoadGeneration else { return }
        isLoading = false
    }

    private func binding(for id: String, mode: MacIntegrationPermissionMode) -> Binding<Bool> {
        Binding(
            get: {
                guard let p = permissions[id] else { return false }
                switch mode {
                case .read:  return p.read
                case .write: return p.write
                }
            },
            set: { newValue in
                let previous = permissions[id] ?? MacIntegrationID.defaultPermission(for: id)
                var current = previous
                switch mode {
                case .read:  current.read = newValue
                case .write: current.write = newValue
                }
                permissions[id] = current
                // gpt-5.5 review NEEDS_FIX: persist + surface errors. If the
                // disk write fails, roll back the local toggle so the UI and
                // the on-disk state stay in sync, and show the user what
                // happened. Optimistic update for fast UI; rollback on error.
                Task { @MainActor in
                    do {
                        try await MacIntegrationPermissionStore.shared.set(
                            integrationId: id,
                            read: current.read,
                            write: current.write
                        )
                        // 2026-06-07 P4-C integration: push the change to
                        // iCloud KVS so the iPhone tab picks it up.
                        MacIntegrationICloudBridge.shared.push(
                            id: id,
                            read: current.read,
                            write: current.write
                        )
                    } catch {
                        permissions[id] = previous
                        persistenceError = "Failed to save \(MacIntegrationID.displayName(for: id)) permission: \(error.localizedDescription)"
                    }
                }
            }
        )
    }

    // MARK: - Icons

    // MARK: - TCC wizard

    // Every status key rendered as a System Permissions row above the
    // Grant All control; the CTA hides only when ALL of these are granted.
    private var allSystemPermissionsGranted: Bool {
        MacIntegrationSystemPermissionPresentation.allGranted(tccStatuses)
    }

    private func tccStatusRow(
        label: String,
        icon: String,
        statusKey: String,
        frameworkPermission: MacIntegrationFrameworkPermission? = nil,
        appleEventApp: String? = nil
    ) -> some View {
        let status = tccStatuses[statusKey] ?? "unknown"
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(ShellType.body)
                .frame(width: 24, height: 24)
                .foregroundStyle(NativeAgentShell.tertiary)
            Text(label)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
            Spacer(minLength: 8)
            if let permission = frameworkPermission {
                if status == "not_determined" || status == "unknown"
                    || (permission == .calendar && status == "limited") {
                    Button {
                        Task { await requestFrameworkGrant(permission) }
                    } label: {
                        if requestingFramework == permission {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(status == "limited" ? "Grant full" : "Grant")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(requestingFramework != nil || requestingApp != nil)
                } else if status == "denied" || status == "restricted" || status == "limited" {
                    Button("Open settings") {
                        openSystemSettings(permission.capability)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            // Per-app Automation control. The passive probe never prompts
            // (askUserIfNeeded:false) and the chat/bridge AppleScript path
            // can't surface the first-run prompt from its background queue —
            // so this button is the ONLY in-app way to fire a single app's
            // Automation consent. Surgical by design: grants exactly THIS
            // app, never the Mail/Music "Grant All" bazooka. For a state
            // that's already a hard denial, the prompt can't re-fire, so we
            // deep-link to the Automation pane instead.
            if let app = appleEventApp {
                if status == "not_determined" || status == "unknown" {
                    Button {
                        Task { await requestAppleEventGrant(app) }
                    } label: {
                        if requestingApp == app {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Grant")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(requestingApp != nil)
                } else if status == "denied" || status == "restricted" {
                    Button("Open settings") {
                        openSystemSettings(.automation)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            HStack(spacing: 4) {
                Circle()
                    .fill(Self.statusBadgeColor(status))
                    .frame(width: 8, height: 8)
                Text(Self.statusBadgeText(status))
                    .font(ShellType.captionMedium)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(NativeAgentShell.quietFill, in: Capsule())
        }
        .frame(minHeight: 48)
    }

    // 2026-06-07: persist AppleEvents per-app probe results across app
    // restarts. The OS-level TCC grants themselves are persistent — once
    // user clicks Allow on the macOS prompt, Mail/Messages/Notes/Music
    // stay authorized forever. But our UI badges are in-memory @State,
    // so they reset to "unknown" on every launch. We can't auto-probe at
    // launch because the probe IS the TCC prompt for never-asked apps,
    // and surprising the user with 4 prompts when they open the tab is
    // bad UX. Instead: cache the last-known result to UserDefaults and
    // restore it on launch. Stays accurate enough; user can hit Refresh
    // or Grant All to force a fresh probe any time.
    private static let aeStatusDefaultsKey = "nativeAgent.macIntegration.appleEvents.statusCache.v1"

    private static func loadCachedAppleEventsStatuses() -> [String: String] {
        MacIntegrationSystemPermissionPresentation.loadAppleEventStatuses(
            from: .standard,
            key: aeStatusDefaultsKey
        )
    }

    private static func saveCachedAppleEventsStatuses(_ statuses: [String: String]) {
        // Filter to ONLY apple_events_* keys — don't persist the framework
        // ones (those re-read from the OS on every launch, so caching them
        // would just be stale).
        MacIntegrationSystemPermissionPresentation.saveAppleEventStatuses(
            statuses,
            to: .standard,
            key: aeStatusDefaultsKey
        )
    }

    private func loadInitialTCCStatuses() async {
        // Cold-start cache improves the initial paint but cannot become the
        // truth source: the passive probes below overwrite it as they finish.
        let cachedAppleEvents = Self.loadCachedAppleEventsStatuses()
        tccStatuses.merge(cachedAppleEvents) { _, cachedValue in cachedValue }
        // Pure status queries; no prompts fired here. The three framework
        // backends (Calendar/Reminders/Contacts) are safe to query at any
        // time without triggering prompts.
        // Speech / Microphone: class-level READS only (SFSpeechRecognizer
        // .authorizationStatus / AVCaptureDevice.authorizationStatus). Neither
        // prompts, so they are safe on every appear and refresh tick.
        tccStatuses[MacIntegrationSystemPermissionPresentation.speechRecognitionKey] = Self.badgeKey(
            SystemPermissionPreflight.status(.speechRecognition))
        tccStatuses[MacIntegrationSystemPermissionPresentation.microphoneKey] = Self.badgeKey(
            SystemPermissionPreflight.status(.microphone))

        tccStatuses[MacIntegrationSystemPermissionPresentation.calendarKey] = MacPIMConnectorActions.currentCalendarAuthorizationStatus()
        tccStatuses[MacIntegrationSystemPermissionPresentation.remindersKey] = MacPIMConnectorActions.currentReminderAuthorizationStatus()
        tccStatuses[MacIntegrationSystemPermissionPresentation.contactsKey] = MacContactsAdapter.currentAuthorizationStatus()

        // 2026-06-07: AppleEvents per-app is now probed PASSIVELY here
        // using AEDeterminePermissionToAutomateTarget(askUserIfNeeded:
        // false) — that API checks the TCC state without firing a prompt,
        // so we can refresh on every view appear + auto-poll tick. The
        // probe returns the real state (granted / denied / not_determined
        // / unknown for apps not installed) every time. No more "unknown
        // until you click Grant All."
        var probedAppleEvents: [String: String] = [:]
        for app in Self.appleEventsTargetApps {
            let key = "apple_events_\(app.lowercased())"
            probedAppleEvents[key] = await Self.probeAppleEventApp(app)
        }
        tccStatuses.merge(
            MacIntegrationSystemPermissionPresentation.mergingCachedAppleEvents(
                cachedAppleEvents,
                withProbed: probedAppleEvents
            )
        ) { _, probeValue in probeValue }
        // Still persist the latest values so a cold launch shows correct
        // state even before the first probe completes (the cache acts as
        // a faster initial paint while the real probes run).
        Self.saveCachedAppleEventsStatuses(tccStatuses)
    }

    private func requestFrameworkGrant(_ permission: MacIntegrationFrameworkPermission) async {
        requestingFramework = permission
        defer { requestingFramework = nil }

        let status: String
        switch permission {
        case .calendar:
            status = await MacPIMConnectorActions.requestCalendarAccess()
        case .reminders:
            status = await MacPIMConnectorActions.requestReminderAccess()
        case .contacts:
            status = await MacContactsAdapter.requestAccess()
        case .speechRecognition:
            // This is the acquisition path the headless Telegram voice pipeline
            // never had. The call is a no-op unless the grant is still
            // notDetermined — macOS refuses to re-prompt a resolved grant, so a
            // denied state falls through to System Settings below instead of
            // leaving the user tapping a button that does nothing.
            status = Self.badgeKey(
                await SystemPermissionPreflight.requestSpeechRecognitionIfNotDetermined())
        case .microphone:
            status = await AVCaptureDevice.requestAccess(for: .audio)
                ? "granted"
                : Self.badgeKey(SystemPermissionPreflight.status(.microphone))
        }
        tccStatuses[permission.rawValue] = status

        if status == "denied" || status == "restricted" {
            // A resolved denial cannot be re-prompted. Say so AND open the pane,
            // rather than reporting a silent no-op.
            permissionRequestError = "\(permission.label) is already \(status) for NativeAgent, "
                + "and macOS will not ask again once a permission has been answered. "
                + "Opening System Settings → Privacy & Security → \(permission.label) — "
                + "switch NativeAgent on there, then hit Refresh."
            openSystemSettings(permission.capability)
        } else if status == "not_determined" || status == "unknown" {
            permissionRequestError = MacIntegrationPermissionFailurePresentation.registrationFailureMessage(for: permission)
        }
    }

    /// Preserve a failed Settings handoff in the same visible alert used for a
    /// failed permission request. Opening a pane is a user-facing recovery
    /// action; returning false must never look like a successful click.
    @discardableResult
    private func openSystemSettings(
        _ capability: SystemPermissionCapability,
        opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> MacIntegrationSettingsDeepLink.Outcome {
        let outcome = MacIntegrationSettingsDeepLink.open(capability, using: opener)
        if let message = outcome.failureMessage {
            permissionRequestError = message
        }
        return outcome
    }

    private func grantAllPermissions() async {
        isRequestingAll = true
        defer { isRequestingAll = false }

        // Speech Recognition — first, and BEFORE the microphone prompt, because
        // it is the grant with no other acquisition path in the whole app.
        let speech = Self.badgeKey(
            await SystemPermissionPreflight.requestSpeechRecognitionIfNotDetermined())
        tccStatuses["speech_recognition"] = speech

        // Microphone
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        let mic = micGranted ? "granted" : Self.badgeKey(SystemPermissionPreflight.status(.microphone))
        tccStatuses["microphone"] = mic

        // Calendar
        let cal = await MacPIMConnectorActions.requestCalendarAccess()
        tccStatuses["calendar"] = cal

        // Reminders
        let rem = await MacPIMConnectorActions.requestReminderAccess()
        tccStatuses["reminders"] = rem

        // Contacts
        let con = await MacContactsAdapter.requestAccess()
        tccStatuses["contacts"] = con

        let unresolvedFrameworks = [
            ("Speech Recognition", speech),
            ("Microphone", mic),
            ("Calendar", cal),
            ("Reminders", rem),
            ("Contacts", con),
        ].compactMap { label, status in
            (status == "not_determined" || status == "unknown") ? label : nil
        }
        if !unresolvedFrameworks.isEmpty {
            permissionRequestError = "macOS did not register: \(unresolvedFrameworks.joined(separator: ", ")). Keep NativeAgent in the foreground and use the individual Grant button. If Calendar remains unresolved, reinstall the current signed build."
        }

        // AppleEvents — request each target app independently so macOS creates
        // the real Automation rows for NativeAgent. The passive probe cannot
        // repair a nuked TCC table because it deliberately does not prompt.
        var aeStatuses: [String: String] = [:]
        for app in Self.appleEventsTargetApps {
            await ensureAppleEventsTargetLaunched(app)
            let s = await Self.requestAppleEventApp(app)
            aeStatuses[app] = s
            tccStatuses["apple_events_\(app.lowercased())"] = s
        }
        let anyAEDenied = aeStatuses.values.contains("denied")

        // Persist the probe results so the badges survive app restart.
        // OS-level TCC grants are persistent; we just need to remember
        // what the last probe told us so the badges show real state
        // without forcing a re-prompt on every launch.
        Self.saveCachedAppleEventsStatuses(tccStatuses)

        // 2026-06-07 the user caught "I hit grant all permissions now it does
        // nothing." Root cause: macOS only fires the TCC prompt when
        // status is .notDetermined. If a permission was previously
        // denied (user clicked "Don't Allow" once), the request* APIs
        // return silently — no UI feedback, nothing happens. Same for
        // already-granted: no prompt, just returns the existing status.
        //
        // For permissions stuck in denied/restricted state, open
        // System Settings directly to the right pane so the user can
        // toggle the switch manually. Each Apple framework has its own
        // pane URL — these are stable Apple-documented anchors. For
        // AppleEvents we open the Automation pane once if ANY of the
        // 4 target apps is denied (the pane lists all four under
        // NativeAgent so the user can fix them in one place).
        // 2026-06-07 macOS 13+ ships System Settings (not System Preferences)
        // and the URL scheme changed. Old `com.apple.preference.security`
        // works on macOS 12 and earlier; new
        // `com.apple.settings.PrivacySecurity.extension` works on 13+. We
        // try the new one first; NSWorkspace.open falls back gracefully if
        // the bundle isn't installed (returns false but doesn't throw).
        var needsManualGrant: [SystemPermissionCapability] = []
        if speech == "denied" || speech == "restricted" {
            needsManualGrant.append(.speechRecognition)
        }
        if mic == "denied" || mic == "restricted" {
            needsManualGrant.append(.microphone)
        }
        if cal == "denied" || cal == "restricted" {
            needsManualGrant.append(.calendars)
        }
        if rem == "denied" || rem == "restricted" {
            needsManualGrant.append(.reminders)
        }
        if con == "denied" || con == "restricted" {
            needsManualGrant.append(.contacts)
        }
        if anyAEDenied {
            needsManualGrant.append(.automation)
        }
        // Open one pane per stuck permission, spaced 400ms apart so the
        // user can see each window open instead of a single one stealing
        // focus. NSWorkspace.open is the standard way to open
        // x-apple.systempreferences: URLs.
        var settingsFailures: [String] = []
        for (i, capability) in needsManualGrant.enumerated() {
            try? await Task.sleep(nanoseconds: UInt64(i * 400_000_000))
            if let message = openSystemSettings(capability).failureMessage {
                settingsFailures.append(message)
            }
        }
        if !settingsFailures.isEmpty {
            permissionRequestError = settingsFailures.joined(separator: " ")
        }
    }

    /// Fires the REAL Automation consent prompt for ONE target app, then
    /// records the resulting state. This is the surgical counterpart to
    /// `grantAllPermissions()` — the user asked for exactly Messages + Notes, not
    /// the four-app bazooka. The target app must be running for the consent
    /// check to prompt (otherwise it returns procNotFound/-600 silently), so
    /// we launch it without stealing focus first.
    private func requestAppleEventGrant(_ app: String) async {
        requestingApp = app
        defer { requestingApp = nil }
        await ensureAppleEventsTargetLaunched(app)
        let status = await Self.requestAppleEventApp(app)
        tccStatuses["apple_events_\(app.lowercased())"] = status
        Self.saveCachedAppleEventsStatuses(tccStatuses)
    }

    private func ensureAppleEventsTargetLaunched(_ app: String) async {
        if let bundleID = Self.appleEventsTargetBundleIDs[app],
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        }
    }

    /// Same as `probeAppleEventApp` but passes `askUserIfNeeded: true` so the
    /// system PRESENTS the consent prompt when the grant is not yet
    /// determined. Must run off the main thread — the call blocks while the
    /// user answers. A previously-denied grant won't re-prompt (TCC respects
    /// the recorded "no"); use the row's Open Settings deep-link for that.
    private static func requestAppleEventApp(_ app: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let bundleID = appleEventsTargetBundleIDs[app] else {
                    continuation.resume(returning: "unknown")
                    return
                }
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                guard var desc = target.aeDesc?.pointee else {
                    continuation.resume(returning: "unknown")
                    return
                }
                let result: OSStatus = withUnsafePointer(to: &desc) { ptr in
                    AEDeterminePermissionToAutomateTarget(
                        ptr,
                        AEEventClass(typeWildCard),
                        AEEventID(typeWildCard),
                        true  // askUserIfNeeded — FIRE the consent prompt
                    )
                }
                switch result {
                case 0:
                    continuation.resume(returning: "granted")
                case OSStatus(-1743):
                    continuation.resume(returning: "denied")
                case OSStatus(-1744):
                    continuation.resume(returning: "not_determined")
                default:
                    continuation.resume(returning: "unknown")
                }
            }
        }
    }

    private static func statusBadgeColor(_ status: String) -> Color {
        switch status {
        case "granted", "authorized", "granted_offline": return NativeAgentShell.calm
        case "limited": return NativeAgentShell.trouble
        case "denied", "restricted": return NativeAgentShell.trouble
        default: return NativeAgentShell.tertiary
        }
    }

    private static func statusBadgeText(_ status: String) -> String {
        switch status {
        case "granted", "authorized": return "Granted"
        case "granted_offline": return "Granted"
        case "limited": return "Limited"
        case "denied": return "Denied"
        case "restricted": return "Restricted"
        case "not_determined": return "Not set"
        case "unknown": return "Unknown"
        default: return status.capitalized
        }
    }

    /// Fires a no-op AppleScript and inspects the result. -1743 is the
    /// AppleEvents TCC is PER-APP. The wizard's badge has to fire prompts
    /// for each of the 4 apps Agent drives (Mail/Messages/Notes/Music),
    /// not just System Events. Each app's first probe triggers its own
    /// system prompt; status is the aggregate (all granted → granted,
    /// any denied → denied, otherwise unknown). gpt-5.5 review NEEDS_FIX.
    nonisolated private static let appleEventsTargetApps = ["Mail", "Messages", "Notes", "Music"]

    private static func probeAppleEvents() async -> String {
        var grantedCount = 0
        var deniedCount = 0
        for app in appleEventsTargetApps {
            let status = await probeAppleEventApp(app)
            switch status {
            case "granted": grantedCount += 1
            case "denied":  deniedCount += 1
            default:        break
            }
        }
        if deniedCount > 0 { return "denied" }
        if grantedCount == appleEventsTargetApps.count { return "granted" }
        return "unknown"
    }

    /// Bundle IDs for the four target apps Agent drives via AppleScript.
    /// Used by `AEDeterminePermissionToAutomateTarget` — it identifies the
    /// target by bundle ID, not human-readable name.
    nonisolated private static let appleEventsTargetBundleIDs: [String: String] = [
        "Mail":     "com.apple.mail",
        "Messages": "com.apple.MobileSMS",
        "Notes":    "com.apple.Notes",
        "Music":    "com.apple.Music",
    ]

    /// 2026-06-07 the user was right: "It should show the true state this isn't
    /// hard." Was using `NSAppleScript` to probe, which doubles as the TCC
    /// prompt for never-asked apps — so we couldn't probe passively at
    /// launch without surprising the user with prompts. App-not-running
    /// returned "unknown" which was uninformative.
    ///
    /// The correct API is `AEDeterminePermissionToAutomateTarget` with
    /// `askUserIfNeeded: false`. It checks the Automation TCC grant
    /// state for a target bundle ID and returns:
    ///   noErr (0)                              → granted
    ///   errAEEventNotPermitted (-1743)         → denied
    ///   errAEEventWouldRequireUserConsent (-1744) → not_determined
    ///   procNotFound / other                   → unknown (app not installed)
    ///
    /// Critically: it does NOT trigger a prompt. Safe to call on every
    /// view appear and during the auto-refresh poll. App doesn't need to
    /// be running — TCC state is per-bundle, not per-process.
    private static func probeAppleEventApp(_ app: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let bundleID = appleEventsTargetBundleIDs[app] else {
                    continuation.resume(returning: "unknown")
                    return
                }
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                let aeDesc = target.aeDesc?.pointee
                guard var desc = aeDesc else {
                    continuation.resume(returning: "unknown")
                    return
                }
                let result: OSStatus = withUnsafePointer(to: &desc) { ptr in
                    AEDeterminePermissionToAutomateTarget(
                        ptr,
                        AEEventClass(typeWildCard),
                        AEEventID(typeWildCard),
                        false  // askUserIfNeeded — DO NOT prompt
                    )
                }
                let status: String
                switch result {
                case 0:
                    status = "granted"
                case OSStatus(-1743):
                    // errAEEventNotPermitted
                    status = "denied"
                case OSStatus(-1744):
                    // errAEEventWouldRequireUserConsent — never asked
                    status = "not_determined"
                case OSStatus(-600):
                    // procNotFound — target app not running. The probe API
                    // can't determine TCC state without a live target. But
                    // we DO have a useful signal: a -600 means the app
                    // exists (otherwise we'd get -1708) and isn't running.
                    // Most users in this state HAVE granted access (since
                    // System Settings shows NativeAgent + Mail/Messages/
                    // etc.); reporting "denied" or "unknown" lies. Use
                    // "granted_offline" as a hopeful state — visible in UI
                    // as "Likely granted (app not running)" so the user
                    // knows: probably fine, will confirm on first use.
                    status = "granted_offline"
                default:
                    status = "unknown"
                }
                NSLog("[mac-integration] AE probe \(app) bundle=\(bundleID) result=\(result) status=\(status)")
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Icons

    private static func iconName(for id: String) -> String {
        switch id {
        case MacIntegrationID.calendar:     return "calendar"
        case MacIntegrationID.reminders:    return "checklist"
        case MacIntegrationID.contacts:     return "person.crop.circle"
        case MacIntegrationID.mail:         return "envelope"
        case MacIntegrationID.messages:     return "message"
        case MacIntegrationID.notes:        return "note.text"
        case MacIntegrationID.music:        return "music.note"
        case MacIntegrationID.notifyMac:    return "bell"
        case MacIntegrationID.notifyMobile: return "iphone.radiowaves.left.and.right"
        case MacIntegrationID.spotlight:    return "magnifyingglass"
        case MacIntegrationID.scheduler:    return "clock"
        default:                            return "square.grid.2x2"
        }
    }
}

// MARK: - Page kit (2026-09-03 Advanced refinement)
//
// The page was a grouped `Form`: every row sat on its own inset slab, and on
// the shell's one sheet that read as a stack of plates rather than a page.
// A section is now the Advanced list's shape — an eyebrow, then one card.

/// One section of the page: the eyebrow the Advanced list uses, and the rows
/// under it on one card.
private struct MacSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ShellType.labelSemibold)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(NativeAgentShell.secondary)
                .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                        .fill(TodayPalette.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                        .strokeBorder(TodayPalette.cardStroke, lineWidth: 1)
                )
        }
    }
}
