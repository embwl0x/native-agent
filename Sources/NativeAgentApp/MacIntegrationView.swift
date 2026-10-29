import TrustCenter

// Blueprint: | `MacIntegrationView.swift` | `MacIntegrationView`: checked integration read/write controls, actual permission probes and truthful System Settings handoff outcomes |
// Per-integration read/write controls render this engine's checked projection.
import SwiftUI
import EngineRuntime
import MacIntegration
import MacControl
import DeviceSync

/// Presentation-level truth for the System Permissions card. These helpers
/// deliberately accept only the statuses the real probes can verify; cached,
/// stale, or invented values must keep the acquisition CTA visible.
enum MacIntegrationSystemPermissionPresentation {
    static func allGranted(_ statuses: [String: String]) -> Bool {
        let keys = MacIntegrationFrameworkPermission.allCases.map(\.rawValue)
            + AppleScriptExecution.automationTargetApps.map { AppleScriptExecution.automationStatusKey(app: $0) }
        return keys.allSatisfy { statuses[$0] == "granted" || statuses[$0] == "authorized" }
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
        AdvancedSection(title: "Permissions") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Permission controls unavailable")
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.trouble)
                Text(detail)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mac-integration.permissions.load-error.detail")
                Text("Mac integration is blocked because I could not read the saved permissions. The saved file has not been changed. After it is repaired, choose Retry to check again.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                retry()
            } label: {
                HStack(spacing: 8) {
                    if retrying {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(retrying ? "Rechecking saved permissions…" : "Retry")
                }
            }
            .disabled(retrying)
            .accessibilityIdentifier("mac-integration.permissions.load-error.retry")
            .help("Check saved permissions again without changing them.")
        }
        .accessibilityIdentifier("mac-integration.permissions.load-error")
    }
}

struct MacIntegrationView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    private var projection: MacIntegrationFacade { appModel.engine.macIntegration }
    private var permissions: [String: MacIntegrationPermission] { projection.permissions }
    private var isLoading: Bool { projection.isLoading }
    private var permissionLoadError: String? { projection.permissionLoadError }
    private var tccStatuses: [String: String] { projection.systemStatuses }
    @State private var persistenceError: String?

    // Request system permissions up front for calendar, reminders, contacts and Apple events.
    @State private var isRequestingAll: Bool = false
    @State private var requestingFramework: MacIntegrationFrameworkPermission? = nil
    @State private var permissionRequestError: String?
    /// The AppleEvents target app whose per-row Grant button is mid-prompt
    /// (so we can show a spinner + disable the other Grant buttons).
    @State private var requestingApp: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AdvancedSection(title: "Chrome control") {
                    ChromeControlPermissionsView()
                }
                MacControlPermissionsView()
                Text("Choose which Mac apps and features I can read from or use. Contacts, Mail, Messages and Notes start with read on and write off; turn on write to let me send or change anything there. Changes apply right away.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                AdvancedSection(title: "System permissions") {
                    Text("Grant only the access you want to use. You can return here later; ordinary text chat needs none of these permissions.")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                    // Each TCC grant has its own row; Speech Recognition comes first for headless Telegram voice.
                    tccStatusRow(label: "Speech recognition", icon: "waveform", frameworkPermission: .speechRecognition)
                    tccStatusRow(label: "Microphone", icon: "mic", frameworkPermission: .microphone)
                    tccStatusRow(label: "Calendar", icon: "calendar", frameworkPermission: .calendar)
                    tccStatusRow(label: "Reminders", icon: "checklist", frameworkPermission: .reminders)
                    tccStatusRow(label: "Contacts", icon: "person.crop.circle", frameworkPermission: .contacts)
                    ForEach(Array(zip(AppleScriptExecution.automationTargetApps, ["envelope", "message", "note.text", "music.note"])), id: \.0) { app, icon in
                        tccStatusRow(label: app, icon: icon)
                    }

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

                Text("These are macOS privacy permissions, separate from the read and write switches below. Notifications, Spotlight and the scheduler need none of them. Mail, Messages, Notes and Music each ask for automation access the first time I check them.")
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
                    AdvancedSection(title: "Apps and features") {
                        ForEach(MacIntegrationID.all, id: \.self) { id in
                            integrationRow(for: id)
                        }
                    }
                }

                // This tab owns TCC grants and integration access; Mac control capabilities live in Trust.
                AdvancedSection(title: "Mac control capabilities") {
                    Text("Shell commands, AppleScript, clicking and typing, file operations, iPhone remote control and background watches live on the Trust page under Mac control.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("These permissions are checked before I read or change anything in the apps and services above.")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .liveTask(id: scenePhase) {
            guard scenePhase == .active else { return }
            await loadPermissions()
        }
        // Offscreen rendering uses the same engine publication, without prompts.
        .quietReadTask(live: false) {
            await loadPermissions()
        }
        // TCC changes happen outside NativeAgent in System Settings. Returning
        // to the app produces a real scene activation edge, so reread then
        // instead of waking the visible view every three seconds. The manual
        // toolbar refresh remains available while NativeAgent stays active.
        .pageActions {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        await loadPermissions()
                    }
                }
                .help("Check permissions again after changing them in System Settings.")
                .accessibilityLabel("Refresh Mac permissions")
        }
        .alert("Permission save failed",
               isPresented: Binding(
                get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } }
               )) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "")
        }
        .alert("Permission request failed",
               isPresented: Binding(
                get: { permissionRequestError != nil },
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
                .foregroundStyle(NativeAgentShell.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(MacIntegrationID.displayName(for: id))
                    .font(ShellType.rowTitle)
                    .foregroundStyle(NativeAgentShell.text)
                Text(MacIntegrationID.description(for: id))
                    .font(ShellType.rowDetail)
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
                .hazeTinted()
                .controlSize(.small)
                .disabled(!supportsRead)
                .accessibilityLabel("\(MacIntegrationID.displayName(for: id)) read permission")
                .help(supportsRead
                      ? "Allow the agent to read from \(MacIntegrationID.displayName(for: id))."
                      : "\(MacIntegrationID.displayName(for: id)) does not support reading.")

                Toggle(isOn: binding(for: id, mode: .write)) {
                    Text("Write")
                        .font(ShellType.label)
                        .foregroundStyle(supportsWrite ? NativeAgentShell.secondary : NativeAgentShell.tertiary)
                }
                .toggleStyle(.switch)
                .hazeTinted()
                .controlSize(.small)
                .disabled(!supportsWrite)
                .accessibilityLabel("\(MacIntegrationID.displayName(for: id)) write permission")
                .help(supportsWrite
                      ? "Allow the agent to send or change things in \(MacIntegrationID.displayName(for: id))."
                      : "\(MacIntegrationID.displayName(for: id)) does not support making changes.")
            }
            .frame(width: 104, alignment: .trailing)
        }
        .frame(minHeight: 48)
    }

    // MARK: - State

    private func loadPermissions() async {
        await projection.refresh()
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
                Task { @MainActor in
                    do {
                        try await projection.set(id, mode: mode, allowed: newValue)
                    } catch {
                        persistenceError = UserFacingError.message(error, action: "save the \(MacIntegrationID.displayName(for: id)) permission")
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
        frameworkPermission: MacIntegrationFrameworkPermission? = nil
    ) -> some View {
        let statusKey = frameworkPermission?.rawValue ?? AppleScriptExecution.automationStatusKey(app: label)
        let status = tccStatuses[statusKey] ?? "unknown"
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(ShellType.body)
                .frame(width: 24, height: 24)
                .foregroundStyle(NativeAgentShell.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(ShellType.rowTitle)
                    .foregroundStyle(NativeAgentShell.text)
                Text(frameworkPermission?.purpose ?? "Use \(label) with the read and write access you choose below.")
                    .font(ShellType.rowDetail)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            // Ask for this app's Automation consent through the shared owner;
            // a resolved denial needs the Automation pane instead.
            if frameworkPermission == nil {
                if status == "not_determined" || status == "unknown" || status == "app_not_running" {
                    Button {
                        Task { await requestAppleEventGrant(label) }
                    } label: {
                        if requestingApp == label {
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

    private func requestFrameworkGrant(_ permission: MacIntegrationFrameworkPermission) async {
        requestingFramework = permission
        defer { requestingFramework = nil }
        await requestPermissions(["privacy:" + permission.capability.rawValue])
    }

    /// Preserve a failed Settings handoff in the same visible alert used for a
    /// failed permission request. Opening a pane is a user-facing recovery
    /// action; returning false must never look like a successful click.
    private func openSystemSettings(_ capability: SystemPermissionCapability) {
        if let message = SystemPermissionPreflight.openSettings(capability) {
            permissionRequestError = message
        }
    }

    private func grantAllPermissions() async {
        isRequestingAll = true
        defer { isRequestingAll = false }

        let automation = AppleScriptExecution.automationTargetApps.compactMap {
            AppleScriptExecution.automationTargetBundleIDs[$0].map { "applescript:" + $0 }
        }
        await requestPermissions(MacIntegrationFrameworkPermission.allCases.map(\.rawValue) + automation)
    }

    /// The shared permission owner asks for just this app's Automation grant.
    private func requestAppleEventGrant(_ app: String) async {
        requestingApp = app
        defer { requestingApp = nil }
        guard let bundleID = AppleScriptExecution.automationTargetBundleIDs[app] else { return }
        await requestPermissions(["applescript:" + bundleID])
    }

    private func requestPermissions(_ ids: [String]) async {
        let problems = await SystemPermissionPreflight.requestMacOSAccess(ids)
        permissionRequestError = problems.isEmpty ? nil : problems.joined(separator: " ")
        await projection.refresh()
    }

    private static func statusBadgeColor(_ status: String) -> Color {
        switch status {
        case "granted", "authorized": return NativeAgentShell.calm
        case "limited": return NativeAgentShell.trouble
        case "denied", "restricted": return NativeAgentShell.trouble
        default: return NativeAgentShell.tertiary
        }
    }

    private static func statusBadgeText(_ status: String) -> String {
        switch status {
        case "granted", "authorized": return "Granted"
        case "app_not_running": return "Unverified — app not running"
        case "limited": return "Limited"
        case "denied": return "Denied"
        case "restricted": return "Restricted"
        case "not_determined": return "Not set"
        case "unknown": return "Unknown"
        default: return status.capitalized
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

// MARK: - Page kit

