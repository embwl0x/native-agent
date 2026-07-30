// PATCH-2026-06-07: mac-integration-tab — per-integration READ/WRITE permission
// toggles for Calendar, Reminders, Contacts, Mail, Messages, Notes, Music,
// Notifications (mac + mobile), Spotlight, Scheduler. Binds against the W1
// substrate (MacIntegrationPermissionStore.shared). Changes persist to
// <dataRoot>/security/mac_integration_permissions.json.
import SwiftUI
import MacIntegration

struct MacIntegrationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var permissions: [String: MacIntegrationPermission] = [:]
    @State private var isLoading: Bool = true
    @State private var permissionLoadError: String?
    // gpt-5.5 review NEEDS_FIX: surface persistence errors instead of silently
    // swallowing them via try?. If set() throws, the toggle rolls back and the
    // alert tells the user what failed.
    @State private var persistenceError: String?

    // PATCH-2026-06-07: TCC permission wizard. Lets the user do the system-prompt
    // dance once up front instead of one-at-a-time when Agent first tries each
    // tool. Keys: "calendar" | "reminders" | "contacts" | "apple_events".
    @State private var tccStatuses: [String: String] = [:]
    @State private var isRequestingAll: Bool = false
    @State private var requestingFramework: FrameworkPermission? = nil
    @State private var permissionRequestError: String?
    /// The AppleEvents target app whose per-row Grant button is mid-prompt
    /// (so we can show a spinner + disable the other Grant buttons).
    @State private var requestingApp: String? = nil

    private enum FrameworkPermission: String {
        case calendar
        case reminders
        case contacts

        var label: String {
            rawValue.capitalized
        }

        var settingsAnchor: String {
            switch self {
            case .calendar: return "Privacy_Calendars"
            case .reminders: return "Privacy_Reminders"
            case .contacts: return "Privacy_Contacts"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose which Mac apps and surfaces the assistant can read from or act on. Sensitive surfaces (Contacts, Mail, Messages, Notes) default to READ ON / WRITE OFF — flip the write toggle to give permission to send or modify. Changes take effect immediately.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Mac Integration")
                }

                Section {
                    // 2026-06-07 the user caught "only 4 system permission rows but
                    // way more tabs underneath." The collapsed "AppleEvents"
                    // row hid 4 distinct per-app TCC grants (Mail / Messages
                    // / Notes / Music) — couldn't tell which app was missing.
                    // Each integration that needs a real macOS TCC grant now
                    // gets its own row with its own badge.
                    tccStatusRow(label: "Calendar", icon: "calendar", statusKey: "calendar", frameworkPermission: .calendar)
                    tccStatusRow(label: "Reminders", icon: "checklist", statusKey: "reminders", frameworkPermission: .reminders)
                    tccStatusRow(label: "Contacts", icon: "person.crop.circle", statusKey: "contacts", frameworkPermission: .contacts)
                    tccStatusRow(label: "Mail",     icon: "envelope",  statusKey: "apple_events_mail",     appleEventApp: "Mail")
                    tccStatusRow(label: "Messages", icon: "message",   statusKey: "apple_events_messages", appleEventApp: "Messages")
                    tccStatusRow(label: "Notes",    icon: "note.text", statusKey: "apple_events_notes",    appleEventApp: "Notes")
                    tccStatusRow(label: "Music",    icon: "music.note",statusKey: "apple_events_music",    appleEventApp: "Music")

                    // Taste pass 2026-07-24: with every row above already
                    // granted, a prominent "Grant All" CTA is a dead button and
                    // the page's focal point — collapse it to a status line.
                    if allSystemPermissionsGranted {
                        Label("All system permissions granted", systemImage: "checkmark.seal.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    } else {
                        Button {
                            Task { await grantAllPermissions() }
                        } label: {
                            HStack(spacing: 8) {
                                if isRequestingAll {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isRequestingAll ? "Requesting…" : "Grant All Permissions Now")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRequestingAll)
                        .help("Fires every macOS TCC prompt that hasn't been answered yet. For permissions you've previously denied, opens System Settings → Privacy & Security to the right pane.")
                    }
                } header: {
                    Text("System Permissions")
                } footer: {
                    Text("These are macOS-level (TCC) permissions, separate from the assistant's read/write toggles below. Notifications, Spotlight, and Scheduler don't need TCC grants. Mail / Messages / Notes / Music are Automation grants — each app's first probe triggers its own prompt.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isLoading {
                    Section {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading current permissions…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let permissionLoadError {
                    Section {
                        Label("Permission controls unavailable", systemImage: "exclamationmark.shield.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text(permissionLoadError)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("All Mac Integration tool gates remain closed until the saved permission file is repaired. NativeAgent preserved the existing bytes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text("Permissions")
                    }
                } else {
                    ForEach(MacIntegrationID.all, id: \.self) { id in
                        Section {
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
                Section {
                    Label("Mac Control capabilities — shell, AppleScript, Accessibility, file operations, iOS remote, and the assistant watch — live in the Trust tab under Mac Control.", systemImage: "checkmark.shield")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Mac Control Capabilities")
                }

                Section {
                    Text("Permissions persist to `<dataRoot>/security/mac_integration_permissions.json`. NativeAgent tools consult this store before reading from or writing to any of the surfaces above.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("About")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Mac Integration")
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
        .alert("Permission Save Failed",
               isPresented: Binding(
                get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } }
               )) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "")
        }
        .alert("Permission Request Failed",
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
                .font(.title2)
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(MacIntegrationID.displayName(for: id))
                    .font(.headline)
                Text(MacIntegrationID.description(for: id))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                Toggle(isOn: binding(for: id, mode: .read)) {
                    Text("Read")
                        .font(.caption)
                        .foregroundStyle(supportsRead ? .secondary : .tertiary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!supportsRead)
                .accessibilityLabel("\(MacIntegrationID.displayName(for: id)) read permission")
                .help(supportsRead
                      ? "Allow the assistant to read from \(MacIntegrationID.displayName(for: id))."
                      : "\(MacIntegrationID.displayName(for: id)) does not expose a read surface.")

                Toggle(isOn: binding(for: id, mode: .write)) {
                    Text("Write")
                        .font(.caption)
                        .foregroundStyle(supportsWrite ? .secondary : .tertiary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!supportsWrite)
                .accessibilityLabel("\(MacIntegrationID.displayName(for: id)) write permission")
                .help(supportsWrite
                      ? "Allow the assistant to send or modify on \(MacIntegrationID.displayName(for: id))."
                      : "\(MacIntegrationID.displayName(for: id)) does not expose a write surface.")
            }
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    // MARK: - State

    private func loadPermissions() async {
        isLoading = true
        do {
            // Only a missing store receives bootstrap defaults. Existing
            // damaged authority state is shown as unavailable while every hot
            // tool gate remains denied.
            permissions = try await MacIntegrationPermissionStore.shared.currentChecked()
            permissionLoadError = nil
        } catch {
            permissions = [:]
            permissionLoadError = error.localizedDescription
        }
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
    private static let systemPermissionStatusKeys = [
        "calendar", "reminders", "contacts",
        "apple_events_mail", "apple_events_messages",
        "apple_events_notes", "apple_events_music",
    ]

    private var allSystemPermissionsGranted: Bool {
        Self.systemPermissionStatusKeys.allSatisfy { key in
            switch tccStatuses[key] ?? "unknown" {
            case "granted", "authorized", "granted_offline": return true
            default: return false
            }
        }
    }

    private func tccStatusRow(
        label: String,
        icon: String,
        statusKey: String,
        frameworkPermission: FrameworkPermission? = nil,
        appleEventApp: String? = nil
    ) -> some View {
        let status = tccStatuses[statusKey] ?? "unknown"
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.body)
            Spacer()
            if let permission = frameworkPermission {
                if status == "not_determined" || status == "unknown"
                    || (permission == .calendar && status == "limited") {
                    Button {
                        Task { await requestFrameworkGrant(permission) }
                    } label: {
                        if requestingFramework == permission {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(status == "limited" ? "Grant Full" : "Grant")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(requestingFramework != nil || requestingApp != nil)
                } else if status == "denied" || status == "restricted" || status == "limited" {
                    Button("Open Settings") {
                        let prefix = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?"
                        if let url = URL(string: prefix + permission.settingsAnchor) {
                            NSWorkspace.shared.open(url)
                        }
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
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(Self.statusBadgeColor(status))
                    .frame(width: 8, height: 8)
                Text(Self.statusBadgeText(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Self.statusBadgeColor(status).opacity(0.12), in: Capsule())
        }
        .padding(.vertical, 2)
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
        let raw = UserDefaults.standard.dictionary(forKey: aeStatusDefaultsKey) ?? [:]
        var out: [String: String] = [:]
        for (k, v) in raw {
            if let s = v as? String { out[k] = s }
        }
        return out
    }

    private static func saveCachedAppleEventsStatuses(_ statuses: [String: String]) {
        // Filter to ONLY apple_events_* keys — don't persist the framework
        // ones (those re-read from the OS on every launch, so caching them
        // would just be stale).
        let aeOnly = statuses.filter { $0.key.hasPrefix("apple_events_") }
        UserDefaults.standard.set(aeOnly, forKey: aeStatusDefaultsKey)
    }

    private func loadInitialTCCStatuses() async {
        // Pure status queries; no prompts fired here. The three framework
        // backends (Calendar/Reminders/Contacts) are safe to query at any
        // time without triggering prompts.
        tccStatuses["calendar"] = MacPIMConnectorActions.currentCalendarAuthorizationStatus()
        tccStatuses["reminders"] = MacPIMConnectorActions.currentReminderAuthorizationStatus()
        tccStatuses["contacts"] = MacContactsAdapter.currentAuthorizationStatus()

        // 2026-06-07: AppleEvents per-app is now probed PASSIVELY here
        // using AEDeterminePermissionToAutomateTarget(askUserIfNeeded:
        // false) — that API checks the TCC state without firing a prompt,
        // so we can refresh on every view appear + auto-poll tick. The
        // probe returns the real state (granted / denied / not_determined
        // / unknown for apps not installed) every time. No more "unknown
        // until you click Grant All."
        for app in Self.appleEventsTargetApps {
            let key = "apple_events_\(app.lowercased())"
            tccStatuses[key] = await Self.probeAppleEventApp(app)
        }
        // Still persist the latest values so a cold launch shows correct
        // state even before the first probe completes (the cache acts as
        // a faster initial paint while the real probes run).
        Self.saveCachedAppleEventsStatuses(tccStatuses)
    }

    private func requestFrameworkGrant(_ permission: FrameworkPermission) async {
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
        }
        tccStatuses[permission.rawValue] = status

        if status == "not_determined" || status == "unknown" {
            permissionRequestError = registrationFailureMessage(for: permission)
        }
    }

    private func registrationFailureMessage(for permission: FrameworkPermission) -> String {
        if permission == .calendar {
            return "macOS rejected the Calendar permission request. Quit and reopen NativeAgent, then try Grant once more. If it still fails, reinstall the current signed build; hardened-runtime builds must include Apple's Calendar entitlement."
        }
        return "macOS did not register the \(permission.label) permission request. Keep NativeAgent in the foreground and try Grant once more."
    }

    private func grantAllPermissions() async {
        isRequestingAll = true
        defer { isRequestingAll = false }

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
        func privacyPaneURL(_ anchor: String) -> String {
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        }
        var needsManualGrant: [String] = []
        if cal == "denied" || cal == "restricted" {
            needsManualGrant.append(privacyPaneURL("Privacy_Calendars"))
        }
        if rem == "denied" || rem == "restricted" {
            needsManualGrant.append(privacyPaneURL("Privacy_Reminders"))
        }
        if con == "denied" || con == "restricted" {
            needsManualGrant.append(privacyPaneURL("Privacy_Contacts"))
        }
        if anyAEDenied {
            needsManualGrant.append(privacyPaneURL("Privacy_Automation"))
        }
        // Open one pane per stuck permission, spaced 400ms apart so the
        // user can see each window open instead of a single one stealing
        // focus. NSWorkspace.open is the standard way to open
        // x-apple.systempreferences: URLs.
        for (i, urlStr) in needsManualGrant.enumerated() {
            try? await Task.sleep(nanoseconds: UInt64(i * 400_000_000))
            if let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
            }
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
        case "granted", "authorized", "limited", "granted_offline": return .green
        case "denied", "restricted": return .red
        case "not_determined", "unknown": return .gray
        default: return .gray
        }
    }

    private static func statusBadgeText(_ status: String) -> String {
        switch status {
        case "granted", "authorized": return "Granted"
        case "granted_offline": return "Granted"
        case "limited": return "Limited"
        case "denied": return "Denied"
        case "restricted": return "Restricted"
        case "not_determined": return "Not Set"
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
