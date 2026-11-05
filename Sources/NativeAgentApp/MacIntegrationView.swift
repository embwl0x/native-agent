import AppKit
import SwiftUI
import EngineRuntime
import MacIntegration
import MacControl
import NativeAgentCore
import NativeAgentShared
import DeviceSync
// Blueprint: | `MacIntegrationView.swift` | Foreground macOS permission controls opened from Trust's face |

struct MacIntegrationView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    private var projection: MacIntegrationFacade { appModel.engine.macIntegration }
    private var tccStatuses: [String: String] { projection.systemStatuses }
    @State private var isRequestingAll = false
    @State private var requestingFramework: MacIntegrationFrameworkPermission?
    @State private var requestingApp: String?
    @State private var permissionRequestError: String?
    @State private var persistenceError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AdvancedSection(title: "System permissions") {
                    Text("Grant only the access you want to use. You can return here later; ordinary text chat needs none of these permissions.")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
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
                        .help("""
                            Fires every macOS privacy prompt that has not been answered yet. For permissions previously denied, opens System Settings to \
                            the right pane.
                            """)
                    }
                }

                Text("""
                    These are macOS privacy permissions, separate from Trust's read and write switches. Notifications, Spotlight and the scheduler need \
                    none of them. Mail, Messages, Notes and Music each ask for automation access the first time I check them.
                    """)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Open Accessibility") { openSystemSettings(.accessibility) }
                    Button("Open Automation") { openSystemSettings(.automation) }
                    Button("Open Full Disk Access") { openSystemSettings(.fullDiskAccess) }
                    Button("Open Screen Recording") { openSystemSettings(.screenRecording) }
                }
                Button("Refresh permissions") { Task { await projection.refresh(refreshWatches: false) } }

                if let permissionRequestError { Text(permissionRequestError).foregroundStyle(.red) }
                if let persistenceError { Text(persistenceError).foregroundStyle(.red) }
            }.padding(24)
        }
        .liveTask(id: scenePhase) {
            guard scenePhase == .active else { return }
            await projection.refresh(refreshWatches: false)
        }
    }

    private var allSystemPermissionsGranted: Bool {
        let keys = MacIntegrationFrameworkPermission.allCases.map(\.rawValue)
            + AppleScriptExecution.automationTargetApps.map { AppleScriptExecution.automationStatusKey(app: $0) }
        return keys.allSatisfy { tccStatuses[$0] == "granted" || tccStatuses[$0] == "authorized" }
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

    private static func statusBadgeColor(_ status: String) -> Color {
        switch status {
        case "granted", "authorized": return NativeAgentShell.calm
        case "limited", "denied", "restricted": return NativeAgentShell.trouble
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

    private func requestFrameworkGrant(_ permission: MacIntegrationFrameworkPermission) async {
        requestingFramework = permission
        defer { requestingFramework = nil }
        await requestPermissions(["privacy:" + permission.capability.rawValue])
    }

    /// Show failed Settings handoffs in the permission alert so a recovery click cannot falsely appear successful.
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

    private func requestAppleEventGrant(_ app: String) async {
        requestingApp = app
        defer { requestingApp = nil }
        guard let bundleID = AppleScriptExecution.automationTargetBundleIDs[app] else { return }
        await requestPermissions(["applescript:" + bundleID])
    }

    private func requestPermissions(_ ids: [String]) async {
        do {
            let problems = try await SystemPermissionPreflight.requestMacOSAccess(ids)
            permissionRequestError = problems.isEmpty ? nil : problems.joined(separator: " ")
        } catch { permissionRequestError = error.localizedDescription }
        await projection.refresh()
    }

 }
