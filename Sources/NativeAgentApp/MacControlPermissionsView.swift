// PATCH-2026-05-07: mac-control-ui-1 Mac Control Permissions panel — master toggle + category toggles + audit log
import AppKit
import SwiftUI

// MARK: - TrustMacControlPolicy

// Codable mirror of the daemon's macControlPolicy block in trust_policy()
struct TrustMacControlPolicy: Codable, Hashable {
    var enabled: Bool = false
    var applesScriptAllowed: Bool = false
    var jxaAllowed: Bool = false
    var shortcutsAllowed: Bool = true
    var accessibilityAllowed: Bool = false
    var systemControlAllowed: Bool = false
    var fileOpsAllowed: Bool = false
    var shellAllowed: Bool = false
    var notificationsAllowed: Bool = true
    var spotlightAllowed: Bool = true
    var approvalRequiredFor: [String] = ["shell", "file_ops", "applescript", "jxa", "accessibility"]
    var remoteFromIosAllowed: Bool = false

    enum CodingKeys: String, CodingKey {
        case enabled
        case applesScriptAllowed = "applescript_allowed"
        case jxaAllowed = "jxa_allowed"
        case shortcutsAllowed = "shortcuts_allowed"
        case accessibilityAllowed = "accessibility_allowed"
        case systemControlAllowed = "system_control_allowed"
        case fileOpsAllowed = "file_ops_allowed"
        case shellAllowed = "shell_allowed"
        case notificationsAllowed = "notifications_allowed"
        case spotlightAllowed = "spotlight_allowed"
        case approvalRequiredFor = "approval_required_for"
        case remoteFromIosAllowed = "remote_from_ios_allowed"
    }

    init(
        enabled: Bool = false,
        applesScriptAllowed: Bool = false,
        jxaAllowed: Bool = false,
        shortcutsAllowed: Bool = true,
        accessibilityAllowed: Bool = false,
        systemControlAllowed: Bool = false,
        fileOpsAllowed: Bool = false,
        shellAllowed: Bool = false,
        notificationsAllowed: Bool = true,
        spotlightAllowed: Bool = true,
        approvalRequiredFor: [String] = ["shell", "file_ops", "applescript", "jxa", "accessibility"],
        remoteFromIosAllowed: Bool = false
    ) {
        self.enabled = enabled
        self.applesScriptAllowed = applesScriptAllowed
        self.jxaAllowed = jxaAllowed
        self.shortcutsAllowed = shortcutsAllowed
        self.accessibilityAllowed = accessibilityAllowed
        self.systemControlAllowed = systemControlAllowed
        self.fileOpsAllowed = fileOpsAllowed
        self.shellAllowed = shellAllowed
        self.notificationsAllowed = notificationsAllowed
        self.spotlightAllowed = spotlightAllowed
        self.approvalRequiredFor = approvalRequiredFor
        self.remoteFromIosAllowed = remoteFromIosAllowed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        applesScriptAllowed = try c.decodeIfPresent(Bool.self, forKey: .applesScriptAllowed) ?? false
        jxaAllowed = try c.decodeIfPresent(Bool.self, forKey: .jxaAllowed) ?? false
        shortcutsAllowed = try c.decodeIfPresent(Bool.self, forKey: .shortcutsAllowed) ?? true
        accessibilityAllowed = try c.decodeIfPresent(Bool.self, forKey: .accessibilityAllowed) ?? false
        systemControlAllowed = try c.decodeIfPresent(Bool.self, forKey: .systemControlAllowed) ?? false
        fileOpsAllowed = try c.decodeIfPresent(Bool.self, forKey: .fileOpsAllowed) ?? false
        shellAllowed = try c.decodeIfPresent(Bool.self, forKey: .shellAllowed) ?? false
        notificationsAllowed = try c.decodeIfPresent(Bool.self, forKey: .notificationsAllowed) ?? true
        spotlightAllowed = try c.decodeIfPresent(Bool.self, forKey: .spotlightAllowed) ?? true
        approvalRequiredFor = try c.decodeIfPresent([String].self, forKey: .approvalRequiredFor) ?? ["shell", "file_ops", "applescript", "jxa", "accessibility"]
        remoteFromIosAllowed = try c.decodeIfPresent(Bool.self, forKey: .remoteFromIosAllowed) ?? false
    }
}

// MARK: - Approval categories (Sweep R4 C9)

/// Human labels for the five `approvalRequiredFor` policy keys.
///
/// COPY ONLY. `key` is the persisted policy value and is written to
/// `TrustMacControlPolicy.approvalRequiredFor` unchanged — it must never be
/// edited to match a label. `title`/`detail` are the strings the user reads;
/// the key is still shown as a caption so support can name a specific row.
struct MacControlApprovalCategory: Identifiable, Hashable {
    let key: String
    let title: String
    let detail: String

    var id: String { key }

    static let all: [MacControlApprovalCategory] = [
        MacControlApprovalCategory(
            key: "shell",
            title: "Running terminal commands",
            detail: "Commands run on your Mac the way you would type them into Terminal."
        ),
        MacControlApprovalCategory(
            key: "file_ops",
            title: "Creating, changing, or deleting files",
            detail: "Writing to files and folders on disk, including moving them to the Trash."
        ),
        MacControlApprovalCategory(
            key: "applescript",
            title: "Telling other apps what to do (AppleScript)",
            detail: "Driving apps like Mail, Calendar, or Music through macOS automation."
        ),
        MacControlApprovalCategory(
            key: "jxa",
            title: "Telling other apps what to do (JavaScript)",
            detail: "The same app automation as above, written in JavaScript instead."
        ),
        MacControlApprovalCategory(
            key: "accessibility",
            title: "Clicking buttons and typing for you",
            detail: "Moving through windows, menus, and controls the way your hands would."
        ),
    ]
}

// MARK: - Audit Entry

/// Decoder for one row of `<dataRoot>/mac_control_audit.jsonl`.
///
/// CANONICAL DAEMON-PARITY SHAPE — keep in sync with
/// `Modules/NativeAgentCore/Sources/MacControl/MacControl.swift` `emitBlockedAudit`
/// and the Python `MacControl._blocked_receipt` it byte-mirrors. The full
/// snake_case field set (in daemon insertion order) is:
///
///     id, method, category, args_hash, trigger, trigger_source,
///     approval_required, approved, exit_code, stdout, stderr,
///     duration_ms, executed_at, blocked, block_reason
///
/// `ts` / `action` / `detail` / `allowed` are the legacy summary fields the
/// audit sheet UI binds to; they're synthesized from the canonical fields
/// (executed_at, method, stderr|block_reason, blocked) at decode time so
/// older rows still render. `var id: String` is the SwiftUI `Identifiable`
/// row id and intentionally distinct from the canonical `id` field (the
/// receipt UUID), which is exposed as `receiptID`.
struct MacControlAuditEntry: Identifiable, Decodable {
    // Identifiable row id: stable per row but built from receiptID when
    // present so rows are deduped reliably in the List.
    var id: String { receiptID ?? "\(ts)-\(method)" }

    // Canonical fields (snake_case in the JSONL; camelCase in Swift via CodingKeys).
    var receiptID: String?
    var method: String
    var category: String?
    var argsHash: String?
    var trigger: String?
    var triggerSource: String?
    var approvalRequired: Bool?
    var approved: Bool?
    var exitCode: Int?
    var stdout: String?
    var stderr: String?
    var durationMs: Int?
    var executedAt: String?
    var blocked: Bool?
    var blockReason: String?

    // Legacy / UI-facing summary fields. Kept so the existing audit sheet
    // bindings (`entry.action`, `entry.ts`, `entry.detail`, `entry.allowed`)
    // keep working without churn.
    var ts: String
    var action: String
    var detail: String?
    var allowed: Bool?

    enum CodingKeys: String, CodingKey {
        // Canonical (snake_case on disk).
        case receiptID = "id"
        case method
        case category
        case argsHash = "args_hash"
        case trigger
        case triggerSource = "trigger_source"
        case approvalRequired = "approval_required"
        case approved
        case exitCode = "exit_code"
        case stdout
        case stderr
        case durationMs = "duration_ms"
        case executedAt = "executed_at"
        case blocked
        case blockReason = "block_reason"
        // Legacy fields some pre-cutover rows may still carry.
        case ts
        case action
        case detail
        case allowed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Canonical fields.
        receiptID = try c.decodeIfPresent(String.self, forKey: .receiptID)
        let decodedMethod = try c.decodeIfPresent(String.self, forKey: .method)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        argsHash = try c.decodeIfPresent(String.self, forKey: .argsHash)
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger)
        triggerSource = try c.decodeIfPresent(String.self, forKey: .triggerSource)
        approvalRequired = try c.decodeIfPresent(Bool.self, forKey: .approvalRequired)
        approved = try c.decodeIfPresent(Bool.self, forKey: .approved)
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        stdout = try c.decodeIfPresent(String.self, forKey: .stdout)
        stderr = try c.decodeIfPresent(String.self, forKey: .stderr)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        executedAt = try c.decodeIfPresent(String.self, forKey: .executedAt)
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked)
        blockReason = try c.decodeIfPresent(String.self, forKey: .blockReason)

        // UI summary fields, synthesized from canonical if missing.
        // method falls back to legacy `action` so the SwiftUI row id stays
        // stable for pre-cutover rows that only carry the legacy keys (gpt-5.5
        // review LOW #7 — without this fallback every legacy row collapses to
        // id="<ts>-" and SwiftUI's List dedupes them).
        ts = try c.decodeIfPresent(String.self, forKey: .ts)
            ?? executedAt
            ?? ""
        let legacyAction = try c.decodeIfPresent(String.self, forKey: .action)
        method = decodedMethod ?? legacyAction ?? ""
        action = legacyAction ?? decodedMethod ?? "unknown"
        // detail prefers a NON-EMPTY block_reason, then NON-EMPTY stderr —
        // gpt-5.5 review MEDIUM #6: canonical successful rows can carry
        // `block_reason: ""`, which would otherwise mask a useful stderr.
        let decodedDetail = try c.decodeIfPresent(String.self, forKey: .detail)
        detail = Self.firstNonEmpty(decodedDetail, blockReason, stderr)
        if let explicit = try c.decodeIfPresent(Bool.self, forKey: .allowed) {
            allowed = explicit
        } else if let b = blocked {
            allowed = !b
        } else {
            allowed = nil
        }
    }

    /// Pick the first non-nil, non-empty string. Treats `""` as absent so the
    /// canonical-row pattern `block_reason: ""` (successful execution rows)
    /// doesn't mask a useful `stderr` underneath.
    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        for c in candidates {
            if let s = c, !s.isEmpty { return s }
        }
        return nil
    }

    init(ts: String, action: String, detail: String? = nil, allowed: Bool? = nil) {
        self.method = action
        self.ts = ts
        self.action = action
        self.detail = detail
        self.allowed = allowed
    }
}

// MARK: - MacControlPermissionsView

private enum MacIntegrationPreset: String, Identifiable {
    case off
    case watch
    case assistant
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .watch: return "Watch"
        case .assistant: return "Assistant"
        case .full: return "Full Mac"
        }
    }

    var subtitle: String {
        switch self {
        case .off: return "Read-only"
        case .watch: return "Receipts + watchers"
        case .assistant: return "Work mode"
        case .full: return "Full access"
        }
    }

    var systemImage: String {
        switch self {
        case .off: return "lock"
        case .watch: return "eye"
        case .assistant: return "macbook.and.iphone"
        case .full: return "flame"
        }
    }

    var tint: Color {
        switch self {
        case .off: return .secondary
        case .watch: return .teal
        case .assistant: return .blue
        case .full: return .red
        }
    }
}

struct MacControlPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var policy = TrustMacControlPolicy()
    @State private var savedPolicy = TrustMacControlPolicy()
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showAuditSheet = false
    @State private var auditEntries: [MacControlAuditEntry] = []
    @State private var isLoadingAudit = false
    @State private var testNotifStatus: String?
    @State private var isTestingNotif = false
    @State private var showAdvancedMacControls = false
    @State private var applyingPreset: MacIntegrationPreset?
    @State private var showFullMacConfirm = false
    @State private var isProbingAppleData = false
    @State private var appleDataProbeStatus: String?
    @State private var assistantWatchRefreshToken = 0

    private var hasUnsavedChanges: Bool {
        policy != savedPolicy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            macIntegrationSetupPanel
            MacAssistantWatchSetupView(refreshToken: assistantWatchRefreshToken)

            DisclosureGroup(isExpanded: $showAdvancedMacControls) {
                advancedMacControlControls
                    .padding(.top, 10)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Advanced Mac Control")
                            .font(NativeAgentFont.section)
                        Text("Category switches, shell, approvals, workbench, and audit log.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if hasUnsavedChanges {
                        StatusBadge(text: "Unsaved", status: "warn")
                    }
                }
            }
            .padding(NativeAgentSpacing.lg)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .task { await loadPolicy() }
        .onChange(of: appModel.trustPolicy) { _, newPolicy in
            // Guard mirrors TrainingPermissionsView: a mid-save trustPolicy
            // refresh must not clobber unsaved toggle edits (2026-07-21 audit).
            guard !isSaving else { return }
            if let mp = newPolicy?.macControlPolicy {
                policy = mp
                savedPolicy = mp
            }
        }
        .sheet(isPresented: $showAuditSheet) {
            MacControlAuditSheet(entries: $auditEntries, isLoading: $isLoadingAudit)
        }
        .alert("Enable Full Mac access?", isPresented: $showFullMacConfirm) {
            Button("Enable Full Mac", role: .destructive) {
                Task { await applyIntegrationPreset(.full) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This gives the agent outside-workspace file access and Mac app control. Shell, system control, and file move/trash still require Developer Mode.")
        }
    }

    @ViewBuilder
    private var macIntegrationSetupPanel: some View {
        NativePanel(title: "Mac Integration Setup", systemImage: "macbook.and.iphone", tint: macIntegrationTint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusBadge(text: macIntegrationLabel, status: macIntegrationStatus)
                    StatusBadge(text: policy.remoteFromIosAllowed ? "iOS remote on" : "iOS remote off", status: policy.remoteFromIosAllowed ? "ready" : "disabled")
                    StatusBadge(text: policy.notificationsAllowed && policy.enabled ? "receipts on" : "receipts off", status: policy.notificationsAllowed && policy.enabled ? "ready" : "disabled")
                    Spacer()
                    if hasUnsavedChanges {
                        StatusBadge(text: "Unsaved details", status: "warn")
                    }
                }

                Text(macIntegrationDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let applyingPreset {
                    ProgressView("Applying \(applyingPreset.title)...")
                        .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Button("Enable Mac Access", systemImage: "switch.2") {
                        Task { await enableMacAccess() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || isProbingAppleData)

                    Button("Probe Apple Data", systemImage: "calendar.badge.checkmark") {
                        Task { await probeAppleDataAccess() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving || isProbingAppleData)

                    if isProbingAppleData {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                    MacIntegrationPresetButton(preset: .off, active: activePreset == .off, disabled: isSaving) {
                        Task { await applyIntegrationPreset(.off) }
                    }
                    MacIntegrationPresetButton(preset: .watch, active: activePreset == .watch, disabled: isSaving) {
                        Task { await applyIntegrationPreset(.watch) }
                    }
                    MacIntegrationPresetButton(preset: .assistant, active: activePreset == .assistant, disabled: isSaving) {
                        Task { await applyIntegrationPreset(.assistant) }
                    }
                    MacIntegrationPresetButton(preset: .full, active: activePreset == .full, disabled: isSaving) {
                        showFullMacConfirm = true
                    }
                }

                HStack(spacing: 8) {
                    Button("Open Accessibility", systemImage: "cursorarrow.motionlines") {
                        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    }
                    .buttonStyle(.bordered)

                    Button("Open Automation", systemImage: "gearshape.2") {
                        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
                    }
                    .buttonStyle(.bordered)

                    Button("Open Full Disk Access", systemImage: "externaldrive.badge.checkmark") {
                        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                    }
                    .buttonStyle(.bordered)

                    Button("Test Notification", systemImage: "bell") {
                        Task { await sendTestNotification() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTestingNotif || !policy.enabled || !policy.notificationsAllowed)

                    if isSaving || isTestingNotif {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if let status = testNotifStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let appleDataProbeStatus {
                    Text(appleDataProbeStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let err = saveError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private var advancedMacControlControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            NativePanel(title: "Mac Control", systemImage: "macbook.and.iphone") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Enable Mac Control", isOn: Binding(
                            get: { policy.enabled },
                            set: { policy.enabled = $0 }
                        ))
                        .font(.headline)
                        EffectTimingTag(timing: .restart)
                        Spacer()
                    }
                    Text("Lets the app-owned Swift agent control this Mac via AppleScript, Shortcuts, Accessibility APIs, shell, and more. The quick setup above chooses safe defaults.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if hasUnsavedChanges {
                        Label("Unsaved changes. Save before using the workbench.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Save") {
                            Task { await save() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || !hasUnsavedChanges)

                        if isSaving {
                            ProgressView("Saving...")
                                .controlSize(.small)
                        }
                    }
                }
            }

            NativePanel(title: "Categories", systemImage: "slider.horizontal.3", tint: .blue) {
                VStack(alignment: .leading, spacing: 12) {
                    MacControlCategoryRow(
                        label: "Notifications",
                        detail: "Post system notifications from the agent.",
                        safeDefault: true,
                        masterEnabled: policy.enabled,
                        isOn: macControlBinding(\.notificationsAllowed)
                    )
                    MacControlCategoryRow(
                        label: "Spotlight Search",
                        detail: "Run Spotlight queries (read-only).",
                        safeDefault: true,
                        masterEnabled: policy.enabled,
                        isOn: macControlBinding(\.spotlightAllowed)
                    )
                    MacControlCategoryRow(
                        label: "macOS Shortcuts",
                        detail: "Run named macOS Shortcuts.",
                        safeDefault: false,
                        masterEnabled: policy.enabled,
                        isOn: macControlBinding(\.shortcutsAllowed)
                    )
                    MacControlCategoryRow(
                        label: "System Control",
                        detail: "Volume, brightness, sleep, lock screen, Focus mode.",
                        safeDefault: false,
                        masterEnabled: policy.enabled,
                        isOn: macControlBinding(\.systemControlAllowed)
                    )
                    MacControlCategoryRow(
                        label: "File Operations",
                        detail: "Read/write files. Also gated by the file policy in Trust Center.",
                        safeDefault: false,
                        masterEnabled: policy.enabled,
                        isOn: macControlBinding(\.fileOpsAllowed)
                    )
                    MacControlCategoryRow(
                        label: "Accessibility",
                        detail: "Keystroke injection, mouse clicks, read focused app. Requires System Settings > Privacy & Security > Accessibility.",
                        safeDefault: false,
                        masterEnabled: policy.enabled,
                        isOn: macControlBinding(\.accessibilityAllowed)
                    )
                    MacControlCategoryRow(
                        label: "AppleScript",
                        detail: "Run AppleScript programs. Approval required by default.",
                        safeDefault: false,
                        masterEnabled: policy.enabled,
                        isOn: macControlBinding(\.applesScriptAllowed)
                    )
                    MacControlCategoryRow(
                        label: "JavaScript for Automation (JXA)",
                        detail: "Run JXA programs. Approval required by default.",
                        safeDefault: false,
                        masterEnabled: policy.enabled,
                        isOn: macControlBinding(\.jxaAllowed)
                    )
                }
            }

            NativePanel(title: "Shell Commands", systemImage: "terminal", tint: .red) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Powerful - use with care")
                            .font(.headline)
                            .foregroundStyle(.orange)
                    }
                    Text("Allows arbitrary shell execution. Keep this off unless Developer Mode is intentionally enabled for the operator session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Toggle("Enable Shell Commands", isOn: Binding(
                            get: { policy.shellAllowed },
                            set: {
                                if $0 { policy.enabled = true }
                                policy.shellAllowed = $0
                            }
                        ))
                        EffectTimingTag(timing: .restart)
                        Spacer()
                    }
                }
            }

            NativePanel(title: "Ask Me First About", systemImage: "checkmark.shield") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("NativeAgent stops and asks for your approval before it does any of these, however it was asked to.")
                        .font(.caption).foregroundStyle(.secondary)
                    // Sweep R4 C9 — COPY ONLY. These were rendered as their raw
                    // policy keys (shell, file_ops, applescript, jxa,
                    // accessibility). The KEY is unchanged and still what gets
                    // written to `approvalRequiredFor`; only the label the user
                    // reads changed, with the key kept as a caption so a support
                    // conversation can still name the exact row.
                    ForEach(MacControlApprovalCategory.all) { category in
                        let isRequired = policy.approvalRequiredFor.contains(category.key)
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Toggle(category.title, isOn: Binding(
                                    get: { isRequired },
                                    set: { newVal in
                                        if newVal {
                                            if !policy.approvalRequiredFor.contains(category.key) {
                                                policy.approvalRequiredFor.append(category.key)
                                            }
                                        } else {
                                            policy.approvalRequiredFor.removeAll { $0 == category.key }
                                        }
                                    }
                                ))
                                Text(category.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(category.key)
                                    .font(NativeAgentFont.mono)
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                                    .help("Policy key for this row — quote it when asking for support.")
                            }
                            EffectTimingTag(timing: .now)
                            Spacer()
                        }
                    }
                }
            }

            NativePanel(title: "iOS Remote Control", systemImage: "iphone.and.arrow.forward", tint: .cyan) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Allow iOS remote control", isOn: Binding(
                            get: { policy.remoteFromIosAllowed },
                            set: {
                                if $0 { policy.enabled = true }
                                policy.remoteFromIosAllowed = $0
                            }
                        ))
                        EffectTimingTag(timing: .now)
                        Spacer()
                    }
                    if !policy.enabled {
                        Text("Turning this on also enables Mac Control.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Lets the paired iOS app trigger Mac Control actions remotely via iCloudBridge.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            MacControlWorkbenchView(policy: policy, policySaved: !hasUnsavedChanges)

            NativePanel(title: "Audit", systemImage: "doc.text.magnifyingglass") {
                Button("View Audit Log") {
                    Task { await loadAudit() }
                    showAuditSheet = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Logic

    private var activePreset: MacIntegrationPreset {
        if policy.enabled == false {
            return .off
        }
        if policy.shellAllowed && policy.fileOpsAllowed && policy.accessibilityAllowed && policy.approvalRequiredFor.isEmpty {
            return .full
        }
        if policy.fileOpsAllowed || policy.shellAllowed || policy.systemControlAllowed || policy.accessibilityAllowed || policy.applesScriptAllowed || policy.jxaAllowed {
            return .assistant
        }
        return .watch
    }

    private var macIntegrationLabel: String {
        switch activePreset {
        case .off: return "Off"
        case .watch: return "Watch ready"
        case .assistant: return "Assistant ready"
        case .full: return "Full Mac"
        }
    }

    private var macIntegrationStatus: String {
        switch activePreset {
        case .off: return "disabled"
        case .watch, .assistant, .full: return "ready"
        }
    }

    private var macIntegrationTint: Color {
        switch activePreset {
        case .off: return .secondary
        case .watch: return .teal
        case .assistant: return .blue
        case .full: return .red
        }
    }

    private var macIntegrationDetail: String {
        switch activePreset {
        case .off:
            return "Mac integration is read-only. The agent can inspect app data but Mac Control actions stay blocked."
        case .watch:
            return "Watch mode turns on the local Mac bridge for receipts, Spotlight, Shortcuts, and watch setup without shell or file writes."
        case .assistant:
            return "Assistant mode enables workspace-safe Mac work, iPhone remote receipts, and approvals for risky categories."
        case .full:
            return "Full Mac enables broad local file and app control. Destructive shell/system actions still require Developer Mode."
        }
    }

    private func applyIntegrationPreset(_ preset: MacIntegrationPreset) async {
        applyingPreset = preset
        isSaving = true
        saveError = nil
        testNotifStatus = nil
        defer {
            isSaving = false
            applyingPreset = nil
        }
        do {
            let result = try await appModel
                .saveMacIntegrationPreset(preset.rawValue, currentPolicy: appModel.trustPolicy)
            appModel.applySavedTrustPolicy(result, status: "Applied \(preset.title).")
            if let mp = result.macControlPolicy {
                policy = mp
                savedPolicy = mp
            } else {
                savedPolicy = policy
            }
            testNotifStatus = "Applied \(preset.title)."
            assistantWatchRefreshToken += 1
        } catch {
            saveError = "Couldn't apply \(preset.title): \(error.localizedDescription)"
        }
    }

    private func enableMacAccess() async {
        await applyIntegrationPreset(.assistant)
        guard saveError == nil else { return }
        await probeAppleDataAccess()
    }

    private func probeAppleDataAccess() async {
        isProbingAppleData = true
        appleDataProbeStatus = "Waiting for macOS Calendar and Reminders permission prompts..."
        defer { isProbingAppleData = false }

        do {
            let calendar = try await appModel.runConnectorAction(
                id: "mac.calendar_list_upcoming",
                dryRun: false,
                input: [
                    "hours_ahead": .int(24),
                    "limit": .int(5),
                ]
            )
            let reminders = try await appModel.runConnectorAction(
                id: "mac.reminders_list_due_today",
                dryRun: false,
                input: [
                    "include_completed": .bool(false),
                    "limit": .int(10),
                ]
            )
            appleDataProbeStatus = "Calendar \(calendar.status); Reminders \(reminders.status)."
            assistantWatchRefreshToken += 1
        } catch {
            appleDataProbeStatus = "Apple data probe failed: \(error.localizedDescription)"
            assistantWatchRefreshToken += 1
        }
    }

    private func openSystemSettings(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func macControlBinding(_ keyPath: WritableKeyPath<TrustMacControlPolicy, Bool>) -> Binding<Bool> {
        Binding(
            get: { policy[keyPath: keyPath] },
            set: { newValue in
                if newValue { policy.enabled = true }
                policy[keyPath: keyPath] = newValue
            }
        )
    }

    /// PATCH-2026-05-07: macctl-policy-fetch The earlier version only read
    /// from `appModel.trustPolicy` and bailed if nil. If this view loaded
    /// before any other surface had populated trustPolicy, the user saw
    /// every toggle as off (default) and any save would commit those
    /// defaults. Now we explicitly fetch /v1/trust on appear and seed
    /// AppModel so subsequent reads are correct too.
    private func loadPolicy() async {
        // Use cache if available
        if let mp = appModel.trustPolicy?.macControlPolicy {
            policy = mp
            savedPolicy = mp
            return
        }
        // Fetch fresh from daemon
        do {
            let tp = try await appModel.getTrustPolicy()
            await MainActor.run { appModel.trustPolicy = tp }
            if let mp = tp.macControlPolicy {
                policy = mp
                savedPolicy = mp
            }
        } catch {
            // Fall through with default-zeroed policy + show inline error
            saveError = "Couldn't load Mac Control settings: \(error.localizedDescription)"
        }
    }

    private func save() async {
        isSaving = true
        saveError = nil
        do {
            let result = try await appModel
                .saveMacControlPolicy(policy)
            await MainActor.run {
                appModel.applySavedTrustPolicy(result, status: "Mac Control policy saved")
                if let mp = result.macControlPolicy {
                    policy = mp
                    savedPolicy = mp
                } else {
                    savedPolicy = policy
                }
            }
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }

    private func sendTestNotification() async {
        isTestingNotif = true
        testNotifStatus = nil
        do {
            let ok = try await appModel
                .macControlNotify(title: "NativeAgent", message: "Mac Control test")
            testNotifStatus = ok ? "Sent." : "Swift app returned error."
        } catch {
            testNotifStatus = "Notification error: \(error.localizedDescription)"
        }
        isTestingNotif = false
    }

    private func loadAudit() async {
        isLoadingAudit = true
        let dataDir = appModel.health?.dataDir ?? ""
        let path = "\(dataDir)/mac_control_audit.jsonl"
        // Read + parse the (potentially large, unbounded) audit file off the
        // MainActor; awaited so ordering vs. isLoadingAudit is preserved.
        let parsed = await Task.detached(priority: .utility) { () -> [MacControlAuditEntry] in
            let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return Array(
                content
                    .components(separatedBy: "\n")
                    .compactMap { line -> MacControlAuditEntry? in
                        guard !line.isEmpty,
                              let data = line.data(using: .utf8),
                              let entry = try? JSONDecoder().decode(MacControlAuditEntry.self, from: data)
                        else { return nil }
                        return entry
                    }
                    .suffix(100)
                    .reversed()
            )
        }.value
        auditEntries = parsed
        isLoadingAudit = false
    }
}

// MARK: - Category Row

private struct MacControlCategoryRow: View {
    let label: String
    let detail: String
    let safeDefault: Bool
    let masterEnabled: Bool
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Toggle(label, isOn: $isOn)
                    .opacity(masterEnabled ? 1 : 0.85)
                    .font(.body.weight(.medium))
                EffectTimingTag(timing: .now)
                Spacer()
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !masterEnabled {
                Text("Turning this on also enables Mac Control.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if safeDefault {
                Text("Default safe")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
    }
}

private struct MacIntegrationPresetButton: View {
    var preset: MacIntegrationPreset
    var active: Bool
    var disabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: preset.systemImage)
                    .foregroundStyle(preset.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .font(NativeAgentFont.section)
                        .foregroundStyle(disabled ? .secondary : .primary)
                    Text(preset.subtitle)
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if active {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(preset.tint)
                }
            }
            .padding(NativeAgentSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(preset.tint.opacity(active ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                    .strokeBorder(preset.tint.opacity(active ? 0.35 : 0.12), lineWidth: active ? 1 : 0.8)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Audit Sheet

private struct MacControlAuditSheet: View {
    @Binding var entries: [MacControlAuditEntry]
    @Binding var isLoading: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Mac Control Audit Log")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            if isLoading {
                ProgressView("Loading audit log…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView("No Entries", systemImage: "doc.text", description: Text("No mac_control_audit.jsonl entries found."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.action)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            if let ok = entry.allowed {
                                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(ok ? .green : .red)
                                    .font(.caption)
                            }
                        }
                        Text(entry.ts)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let detail = entry.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(width: 520, height: 400)
    }
}

// MARK: - Live Workbench

private enum MacControlWorkbenchMode: String, CaseIterable, Identifiable {
    case shell = "Shell"
    case files = "Files"
    case shortcut = "Shortcut"
    case screen = "Screen"

    var id: String { rawValue }
}

private struct MacControlWorkbenchView: View {
    @Environment(AppModel.self) private var appModel
    var policy: TrustMacControlPolicy
    var policySaved: Bool = true

    @State private var mode: MacControlWorkbenchMode = .shell
    @State private var shellCommand = "pwd"
    @State private var shellCWD = NSHomeDirectory()
    @State private var filePath = NSHomeDirectory()
    @State private var fileContent = ""
    @State private var fileAppend = false
    @State private var shortcutName = ""
    @State private var screenAction = "lock_screen"
    @State private var notificationTitle = "NativeAgent"
    @State private var notificationMessage = "Mac Control workbench test"
    @State private var isRunning = false
    @State private var resultTitle = "Idle"
    @State private var resultBody = "Run a workbench action to see stdout, stderr, approval state, or Swift app errors here."

    var body: some View {
        NativePanel(title: "Mac Control Workbench", systemImage: "wrench.and.screwdriver", tint: .indigo) {
            VStack(alignment: .leading, spacing: 12) {
                if !policySaved {
                    Label("Workbench is disabled until the Mac Control policy is saved.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Picker("Action", selection: $mode) {
                    ForEach(MacControlWorkbenchMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .shell:
                    TextField("Working directory", text: $shellCWD)
                        .textFieldStyle(.roundedBorder)
                    TextField("Command", text: $shellCommand, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                    workbenchButton("Run Shell", systemImage: "terminal", enabled: policySaved && policy.enabled && policy.shellAllowed) {
                        await run(path: "/v1/mac_control/shell", body: [
                            "command": shellCommand,
                            "cwd": shellCWD,
                            "timeout": 60,
                            "trigger": "user"
                        ])
                    }
                case .files:
                    TextField("Path", text: $filePath)
                        .textFieldStyle(.roundedBorder)
                    TextField("Write content", text: $fileContent, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Append instead of replace", isOn: $fileAppend)
                    HStack {
                        workbenchButton("Read File", systemImage: "doc.text.magnifyingglass", enabled: policySaved && policy.enabled && policy.fileOpsAllowed) {
                            await run(path: "/v1/mac_control/file/read", body: [
                                "path": filePath,
                                "max_bytes": 200_000,
                                "trigger": "user"
                            ])
                        }
                        workbenchButton("Write File", systemImage: "square.and.pencil", enabled: policySaved && policy.enabled && policy.fileOpsAllowed && !fileContent.isEmpty) {
                            await run(path: "/v1/mac_control/file/write", body: [
                                "path": filePath,
                                "content": fileContent,
                                "append": fileAppend,
                                "trigger": "user"
                            ])
                        }
                    }
                case .shortcut:
                    TextField("Shortcut name", text: $shortcutName)
                        .textFieldStyle(.roundedBorder)
                    workbenchButton("Run Shortcut", systemImage: "square.stack.3d.up", enabled: policySaved && policy.enabled && policy.shortcutsAllowed && !shortcutName.isEmpty) {
                        await run(path: "/v1/mac_control/shortcut/run", body: [
                            "name": shortcutName,
                            "trigger": "user"
                        ])
                    }
                case .screen:
                    Picker("System action", selection: $screenAction) {
                        Text("Lock Screen").tag("lock_screen")
                        Text("Sleep Display").tag("sleep_display")
                    }
                    .pickerStyle(.segmented)
                    TextField("Notification title", text: $notificationTitle)
                        .textFieldStyle(.roundedBorder)
                    TextField("Notification message", text: $notificationMessage)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        workbenchButton("Run System Action", systemImage: "display", enabled: policySaved && policy.enabled && policy.systemControlAllowed) {
                            await run(path: "/v1/mac_control/system", body: [
                                "action": screenAction,
                                "trigger": "user"
                            ])
                        }
                        workbenchButton("Notify", systemImage: "bell", enabled: policySaved && policy.enabled && policy.notificationsAllowed && !notificationMessage.isEmpty) {
                            await run(path: "/v1/mac_control/notify", body: [
                                "title": notificationTitle,
                                "message": notificationMessage,
                                "trigger": "user"
                            ])
                        }
                    }
                }

                Divider()
                HStack {
                    Image(systemName: isRunning ? "hourglass" : "terminal")
                        .foregroundStyle(isRunning ? .orange : NativeAgentTheme.statusColor(resultTitle))
                    Text(resultTitle)
                        .font(NativeAgentFont.section)
                    Spacer()
                    if isRunning {
                        ProgressView().controlSize(.small)
                    }
                }
                ScrollView {
                    Text(resultBody)
                        .font(NativeAgentFont.mono)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 90, maxHeight: 180)
                .padding(10)
                .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func workbenchButton(_ title: String, systemImage: String, enabled: Bool, action: @escaping () async -> Void) -> some View {
        Button(title, systemImage: systemImage) {
            Task { await action() }
        }
        .buttonStyle(.bordered)
        .disabled(!enabled || isRunning)
    }

    private func run(path: String, body: [String: Any]) async {
        isRunning = true
        resultTitle = "Running"
        resultBody = path
        defer { isRunning = false }

        do {
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            let result = try await appModel
                .macControlRun(path: path, bodyData: bodyData, timeout: 90)
            let statusCode = result.statusCode
            let json = result.json
            let data = result.rawData
            if statusCode == 202 || (json?["status"] as? String) == "pending_approval" {
                resultTitle = "Pending Approval"
                resultBody = pretty(json) ?? String(data: data, encoding: .utf8) ?? "Approval required."
                NotificationCenter.default.post(name: .openApprovalsRequest, object: nil)
            } else if (200..<300).contains(statusCode) {
                resultTitle = "Done"
                resultBody = pretty(json) ?? String(data: data, encoding: .utf8) ?? "Done."
            } else {
                resultTitle = "Failed"
                resultBody = pretty(json) ?? String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            }
        } catch {
            resultTitle = "Failed"
            resultBody = error.localizedDescription
        }
    }

    private func pretty(_ json: [String: Any]?) -> String? {
        guard let json,
              let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
