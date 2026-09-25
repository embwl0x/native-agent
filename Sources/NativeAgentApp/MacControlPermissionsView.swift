// PATCH-2026-05-07: mac-control-ui-1 Mac Control Permissions panel — master toggle + category toggles + audit log
import AppKit
import MacControl
import NativeAgentShared
import SwiftUI

enum MacControlAdvancedDisclosurePresentation {
    static let preferenceKey = "macControl.showAdvancedControls"

    static func isExpanded(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: preferenceKey)
    }

    static func setExpanded(_ isExpanded: Bool, in defaults: UserDefaults) {
        defaults.set(isExpanded, forKey: preferenceKey)
    }

    static func savePathIsVisible(isExpanded: Bool) -> Bool {
        isExpanded
    }
}

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
        let snapshot = try MacControlPolicyWireSnapshot(from: decoder)
        enabled = snapshot.enabled
        applesScriptAllowed = snapshot.applesScriptAllowed
        jxaAllowed = snapshot.jxaAllowed
        shortcutsAllowed = snapshot.shortcutsAllowed
        accessibilityAllowed = snapshot.accessibilityAllowed
        systemControlAllowed = snapshot.systemControlAllowed
        fileOpsAllowed = snapshot.fileOpsAllowed
        shellAllowed = snapshot.shellAllowed
        notificationsAllowed = snapshot.notificationsAllowed
        spotlightAllowed = snapshot.spotlightAllowed
        approvalRequiredFor = snapshot.approvalRequiredFor
        remoteFromIosAllowed = snapshot.remoteFromIosAllowed
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
struct MacControlAuditEntry: Identifiable, Decodable, Sendable {
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

enum MacControlAuditLogRead: Sendable {
    case entries([MacControlAuditEntry], malformedLineCount: Int)
    case sourceAbsent
    case unreadable(String)

    static func read(from url: URL, limit: Int = 100) -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return .sourceAbsent }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            var malformed = 0
            let entries = content
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line -> MacControlAuditEntry? in
                    guard let data = line.data(using: .utf8) else {
                        malformed += 1
                        return nil
                    }
                    do {
                        return try JSONDecoder().decode(MacControlAuditEntry.self, from: data)
                    } catch {
                        malformed += 1
                        return nil
                    }
                }
            return .entries(Array(entries.suffix(limit).reversed()), malformedLineCount: malformed)
        } catch {
            return .unreadable(error.localizedDescription)
        }
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
        case .off: return "Read only"
        case .watch: return "Notifications and watches"
        case .assistant: return "Mac work, asks before risky steps"
        case .full: return "Files anywhere, shell"
        }
    }
}

/// Setup badges describe only a policy that was successfully read or saved.
/// The controls can still show an editable draft, but a draft must never make
/// the setup panel claim that Mac Control is already configured.
enum MacControlSetupStatusBadges {
    enum PolicyReadState: Equatable {
        case loading
        case available
        case unavailable
    }

    struct Badge: Equatable {
        let text: String
        let status: String
    }

    struct State: Equatable {
        let access: Badge
        let iOSRemote: Badge
        let receipts: Badge
        let detail: String
    }

    static func resolve(readState: PolicyReadState, savedPolicy: TrustMacControlPolicy?) -> State {
        switch readState {
        case .loading:
            return State(
                access: Badge(text: "Checking setup", status: "unknown"),
                iOSRemote: Badge(text: "iOS remote unknown", status: "unknown"),
                receipts: Badge(text: "receipts unknown", status: "unknown"),
                detail: "Checking your saved Mac control settings."
            )
        case .unavailable:
            return State(
                access: Badge(text: "Setup unavailable", status: "failed"),
                iOSRemote: Badge(text: "iOS remote unknown", status: "failed"),
                receipts: Badge(text: "receipts unknown", status: "failed"),
                detail: "I could not read your saved Mac control settings, so I am not claiming any of it is ready."
            )
        case .available:
            guard let savedPolicy else {
                return State(
                    access: Badge(text: "Setup unavailable", status: "failed"),
                    iOSRemote: Badge(text: "iOS remote unknown", status: "failed"),
                    receipts: Badge(text: "receipts unknown", status: "failed"),
                    detail: "Your saved Trust settings did not include Mac control."
                )
            }

            let access: Badge
            let detail: String
            if !savedPolicy.enabled {
                access = Badge(text: "Mac Control off", status: "disabled")
                detail = "I can read app data, but I cannot act on this Mac."
            } else if savedPolicy.shellAllowed && savedPolicy.fileOpsAllowed
                        && savedPolicy.accessibilityAllowed && savedPolicy.approvalRequiredFor.isEmpty {
                access = Badge(text: "Full Mac configured", status: "ready")
                detail = "I can work with files and apps anywhere on this Mac. Destructive shell and system actions still need developer mode."
            } else if savedPolicy.fileOpsAllowed || savedPolicy.shellAllowed || savedPolicy.systemControlAllowed
                        || savedPolicy.accessibilityAllowed || savedPolicy.applesScriptAllowed || savedPolicy.jxaAllowed {
                access = Badge(text: "Assistant configured", status: "ready")
                detail = "I can do workspace-safe Mac work and send results to your iPhone, and I ask before anything risky."
            } else {
                access = Badge(text: "Watch configured", status: "ready")
                detail = "I can post notifications, search with Spotlight and run background watches. No shell commands and no file writes."
            }

            return State(
                access: access,
                iOSRemote: Badge(
                    text: savedPolicy.remoteFromIosAllowed ? "iOS remote on" : "iOS remote off",
                    status: savedPolicy.remoteFromIosAllowed ? "ready" : "disabled"
                ),
                receipts: Badge(
                    text: savedPolicy.notificationsAllowed && savedPolicy.enabled ? "receipts on" : "receipts off",
                    status: savedPolicy.notificationsAllowed && savedPolicy.enabled ? "ready" : "disabled"
                ),
                detail: detail
            )
        }
    }
}

struct MacControlPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var policy = TrustMacControlPolicy()
    @State private var savedPolicy = TrustMacControlPolicy()
    @State private var policyReadState: MacControlSetupStatusBadges.PolicyReadState = .loading
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showAuditSheet = false
    @State private var auditEntries: [MacControlAuditEntry] = []
    @State private var auditReadProblem: String?
    @State private var isLoadingAudit = false
    @State private var testNotifStatus: String?
    @State private var isTestingNotif = false
    // The advanced group contains unsaved policy controls. Keep its expansion
    // across ordinary navigation so a return to this surface does not hide the
    // only Save path behind a collapsed card.
    @AppStorage(MacControlAdvancedDisclosurePresentation.preferenceKey) private var showAdvancedMacControls = false
    @State private var applyingPreset: MacIntegrationPreset?
    @State private var showFullMacConfirm = false
    @State private var isProbingAppleData = false
    @State private var appleDataProbeStatus: String?
    @State private var assistantWatchRefreshToken = 0
    private let loadsOnAppear: Bool

    init(loadsOnAppear: Bool = true) {
        self.loadsOnAppear = loadsOnAppear
    }

    private var hasUnsavedChanges: Bool {
        policy != savedPolicy
    }

    // Alive glass (2026-09-23): the setup, the watches and the Advanced fold
    // wear the Trust page's kit — an eyebrow over one group card per section,
    // hairline rows, switches, and no per-row timing pills. The one timing
    // fact left (Save, then restart for two switches) is the fold's footnote.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            macIntegrationSetupPanel
            MacAssistantWatchSetupView(refreshToken: assistantWatchRefreshToken)

            // An eyebrow like its sibling sections; the fold row is a row.
            VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                AliveEyebrow("Advanced Mac control")
                TrustFold(isExpanded: $showAdvancedMacControls) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Controls, commands and audit log")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(NativeAgentShell.text)
                        Text("Each kind of control, shell commands, what I ask about first, the workbench and the audit log.")
                            .font(.system(size: 12))
                            .foregroundStyle(NativeAgentShell.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("macControl.advanced.disclosure")
                } trailing: {
                    // Unsaved edits wait on him: the one teal word here.
                    if hasUnsavedChanges {
                        Text("Unsaved")
                            .font(ShellType.captionSemibold)
                            .foregroundStyle(NativeAgentShell.needsYou)
                    }
                } content: {
                    if MacControlAdvancedDisclosurePresentation.savePathIsVisible(
                        isExpanded: showAdvancedMacControls
                    ) {
                        advancedMacControlControls
                    }
                }
            }
        }
        .task {
            guard loadsOnAppear else { return }
            await loadPolicy()
        }
        .onChange(of: appModel.trustPolicy) { _, newPolicy in
            // Guard mirrors TrainingPermissionsView: a mid-save trustPolicy
            // refresh must not clobber unsaved toggle edits (2026-07-21 audit).
            guard !isSaving else { return }
            if let mp = newPolicy?.macControlPolicy {
                policy = mp
                savedPolicy = mp
                policyReadState = .available
            } else {
                policyReadState = .unavailable
            }
        }
        .sheet(isPresented: $showAuditSheet) {
            MacControlAuditSheet(
                entries: $auditEntries,
                isLoading: $isLoadingAudit,
                readProblem: $auditReadProblem
            )
        }
        .alert("Enable Full Mac access?", isPresented: $showFullMacConfirm) {
            Button("Enable Full Mac", role: .destructive) {
                Task { await applyIntegrationPreset(.full) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is the Full Mac preset: files anywhere, shell, system control, and file move or trash, the same as the Full Mac card in Trust.")
        }
    }

    /// The setup badges' words, said plainly. The presentation keeps its own
    /// strings (they are pinned); only what the person reads changes here.
    private static func plainSetupWord(_ text: String) -> String {
        switch text {
        case "Mac Control off": "Mac control is off"
        case "Full Mac configured": "Full Mac"
        case "Assistant configured": "Assistant"
        case "Watch configured": "Watch"
        case "Checking setup": "Checking…"
        case "Setup unavailable": "Setup unavailable"
        default:
            text.replacingOccurrences(of: "iOS remote", with: "iPhone remote control")
                .replacingOccurrences(of: "receipts", with: "notifications")
        }
    }

    @ViewBuilder
    private var macIntegrationSetupPanel: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow("Mac control")
            // The presets are cards themselves, so they sit above the group
            // card rather than inside it — a card in a card is a plate.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10, alignment: .top)], spacing: 10) {
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
            .padding(.bottom, 2)

            AliveGroupCard {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.plainSetupWord(setupBadges.access.text))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(setupBadges.access.status == "failed" ? NativeAgentShell.trouble : NativeAgentShell.text)
                        .accessibilityIdentifier("mac-control.setup.access")
                    Text(setupBadges.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(Self.plainSetupWord(setupBadges.iOSRemote.text))
                            .accessibilityIdentifier("mac-control.setup.ios-remote")
                        Text("·")
                        Text(Self.plainSetupWord(setupBadges.receipts.text))
                            .accessibilityIdentifier("mac-control.setup.receipts")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(NativeAgentShell.secondary)
                    if let applyingPreset {
                        ProgressView("Applying \(applyingPreset.title)…")
                            .controlSize(.small)
                            .padding(.top, 4)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button("Set up Mac access", systemImage: "switch.2") {
                            Task { await enableMacAccess() }
                        }
                        .buttonStyle(.borderedProminent)
                        .hazeTinted(.button)
                        .disabled(isSaving || isProbingAppleData)

                        Button("Check Calendar and Reminders", systemImage: "calendar.badge.checkmark") {
                            Task { await probeAppleDataAccess() }
                        }
                        .disabled(isSaving || isProbingAppleData)

                        if isProbingAppleData {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    Text("Set up Mac access picks the Assistant preset, then asks macOS for Calendar and Reminders.")
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let appleDataProbeStatus {
                        Text(appleDataProbeStatus)
                            .font(.system(size: 12))
                            .foregroundStyle(NativeAgentShell.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("macOS asks for these separately.")
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.secondary)
                    AliveFlow(spacing: 8, lineSpacing: 8) {
                        Button("Open Accessibility", systemImage: "cursorarrow.motionlines") {
                            openSystemSettings(.accessibility)
                        }
                        Button("Open Automation", systemImage: "gearshape.2") {
                            openSystemSettings(.automation)
                        }
                        Button("Open Full Disk Access", systemImage: "externaldrive.badge.checkmark") {
                            openSystemSettings(.fullDiskAccess)
                        }
                        Button("Send a test notification", systemImage: "bell") {
                            Task { await sendTestNotification() }
                        }
                        .disabled(isTestingNotif || !policy.enabled || !policy.notificationsAllowed)
                    }
                    if isSaving || isTestingNotif || testNotifStatus != nil {
                        HStack(spacing: 8) {
                            if isSaving || isTestingNotif {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            if let status = testNotifStatus {
                                Text(status)
                                    .font(.system(size: 12))
                                    .foregroundStyle(NativeAgentShell.secondary)
                            }
                        }
                    }
                }

                if let err = saveError {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func aliveSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow(title)
            AliveGroupCard { content() }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var advancedMacControlControls: some View {
        VStack(alignment: .leading, spacing: 24) {
            aliveSection("Mac control") {
                MacControlSwitchRow(
                    title: "Mac control",
                    detail: "I control this Mac with AppleScript, Accessibility, shell commands and more. The presets above choose safe defaults.",
                    isOn: Binding(
                        get: { policy.enabled },
                        set: { policy.enabled = $0 }
                    )
                )
                HStack(spacing: 10) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .buttonStyle(.borderedProminent)
                    .hazeTinted(.button)
                    .disabled(isSaving || !hasUnsavedChanges)
                    .accessibilityIdentifier("macControl.advanced.save")

                    if isSaving {
                        ProgressView("Saving…")
                            .controlSize(.small)
                    } else if hasUnsavedChanges {
                        Text("Unsaved changes. Save before using the workbench.")
                            .font(.system(size: 12))
                            .foregroundStyle(NativeAgentShell.needsYou)
                    }
                }
            }

            aliveSection("Kinds of control") {
                MacControlCategoryRow(
                    label: "Notifications",
                    detail: "I post notifications on this Mac.",
                    safeDefault: true,
                    masterEnabled: policy.enabled,
                    isOn: macControlBinding(\.notificationsAllowed)
                )
                MacControlCategoryRow(
                    label: "Spotlight search",
                    detail: "I search with Spotlight (read only).",
                    safeDefault: true,
                    masterEnabled: policy.enabled,
                    isOn: macControlBinding(\.spotlightAllowed)
                )
                MacControlUnavailableCategoryRow(
                    label: "macOS Shortcuts",
                    detail: "Not built yet: I can't run Shortcuts in this version, so there is nothing to switch on."
                )
                MacControlUnavailableCategoryRow(
                    label: "System control",
                    detail: "Not built yet: system actions like locking the screen or sleeping the display aren't in this version, so there is nothing to switch on."
                )
                MacControlCategoryRow(
                    label: "File operations",
                    detail: "I read and write files. The file rules in Access and policy still apply.",
                    safeDefault: false,
                    masterEnabled: policy.enabled,
                    isOn: macControlBinding(\.fileOpsAllowed)
                )
                MacControlCategoryRow(
                    label: "Accessibility",
                    detail: "I type, click and read the app in front. macOS must also allow it in System Settings → Privacy & Security → Accessibility.",
                    safeDefault: false,
                    masterEnabled: policy.enabled,
                    isOn: macControlBinding(\.accessibilityAllowed)
                )
                MacControlCategoryRow(
                    label: "AppleScript",
                    detail: "I run AppleScript. I ask you first by default.",
                    safeDefault: false,
                    masterEnabled: policy.enabled,
                    isOn: macControlBinding(\.applesScriptAllowed)
                )
                MacControlCategoryRow(
                    label: "JavaScript for Automation (JXA)",
                    detail: "I run JXA scripts. I ask you first by default.",
                    safeDefault: false,
                    masterEnabled: policy.enabled,
                    isOn: macControlBinding(\.jxaAllowed)
                )
            }

            aliveSection("Shell commands") {
                MacControlSwitchRow(
                    title: "Shell commands",
                    detail: "I can run any command, as if typed into Terminal. Powerful: keep this off unless you turned on developer mode on purpose.",
                    isOn: Binding(
                        get: { policy.shellAllowed },
                        set: {
                            if $0 { policy.enabled = true }
                            policy.shellAllowed = $0
                        }
                    )
                )
            }

            aliveSection("Ask me first about") {
                Text("I stop and ask for your approval before I do any of these, however I was asked to.")
                    .font(.system(size: 12))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Sweep R4 C9 — COPY ONLY. These were rendered as their raw
                // policy keys (shell, file_ops, applescript, jxa,
                // accessibility). The KEY is unchanged and still what gets
                // written to `approvalRequiredFor`; only the label the user
                // reads changed, with the key kept as a caption so a support
                // conversation can still name the exact row.
                ForEach(MacControlApprovalCategory.all) { category in
                    let isRequired = policy.approvalRequiredFor.contains(category.key)
                    MacControlSwitchRow(
                        title: category.title,
                        detail: category.detail,
                        caption: category.key,
                        isOn: Binding(
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
                        )
                    )
                }
            }

            aliveSection("iPhone remote control") {
                MacControlSwitchRow(
                    title: "Allow iPhone remote control",
                    detail: policy.enabled
                        ? "The paired iPhone app can ask me to run Mac control actions, through iCloud."
                        : "Turning this on also turns on Mac control.",
                    isOn: Binding(
                        get: { policy.remoteFromIosAllowed },
                        set: {
                            if $0 { policy.enabled = true }
                            policy.remoteFromIosAllowed = $0
                        }
                    )
                )
            }

            MacControlWorkbenchView(policy: policy, policySaved: !hasUnsavedChanges)

            aliveSection("Audit log") {
                HStack(spacing: 12) {
                    Text("Every Mac control action I ran or was blocked from running.")
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("View audit log") {
                        Task { await loadAudit() }
                        showAuditSheet = true
                    }
                }
            }

            Text("None of these settings change until you press Save. After that, the Mac control and shell command switches take effect at the next restart; the rest apply right away.")
                .font(.system(size: 12))
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Logic

    private var activePreset: MacIntegrationPreset {
        activePreset(for: policy)
    }

    private func activePreset(for policy: TrustMacControlPolicy) -> MacIntegrationPreset {
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

    private var setupBadges: MacControlSetupStatusBadges.State {
        MacControlSetupStatusBadges.resolve(
            readState: policyReadState,
            savedPolicy: policyReadState == .available ? savedPolicy : nil
        )
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
                policyReadState = .available
                testNotifStatus = "Applied \(preset.title)."
                assistantWatchRefreshToken += 1
            } else {
                policyReadState = .unavailable
                saveError = "Couldn't apply \(preset.title): saved Trust policy did not include Mac Control settings."
            }
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

    private func openSystemSettings(_ capability: SystemPermissionCapability) {
        guard let url = SystemPermissionPreflight.settingsURL(for: capability) else { return }
        _ = NSWorkspace.shared.open(url)
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
            policyReadState = .available
            return
        }
        // Fetch fresh from daemon
        do {
            let tp = try await appModel.getTrustPolicy()
            await MainActor.run { appModel.trustPolicy = tp }
            if let mp = tp.macControlPolicy {
                policy = mp
                savedPolicy = mp
                policyReadState = .available
            } else {
                policyReadState = .unavailable
                saveError = "Couldn't load Mac Control settings: saved Trust policy did not include Mac Control settings."
            }
        } catch {
            // Fall through with default-zeroed policy + show inline error
            saveError = "Couldn't load Mac Control settings: \(error.localizedDescription)"
            policyReadState = .unavailable
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
                    policyReadState = .available
                } else {
                    policyReadState = .unavailable
                    saveError = "Mac Control policy saved without a readable Mac Control settings block."
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
        auditReadProblem = nil
        let dataDir = appModel.health?.dataDir ?? ""
        let path = URL(fileURLWithPath: dataDir).appendingPathComponent("mac_control_audit.jsonl")
        // Read + parse the (potentially large, unbounded) audit file off the
        // MainActor; awaited so ordering vs. isLoadingAudit is preserved.
        let read = await Task.detached(priority: .utility) {
            MacControlAuditLogRead.read(from: path)
        }.value
        switch read {
        case .entries(let entries, let malformedLineCount):
            auditEntries = entries
            if malformedLineCount > 0 {
                auditReadProblem = "\(malformedLineCount) malformed audit \(malformedLineCount == 1 ? "line was" : "lines were") not shown."
            }
        case .sourceAbsent:
            auditEntries = []
            auditReadProblem = "Audit source is absent at \(path.path)."
        case .unreadable(let reason):
            auditEntries = []
            auditReadProblem = "Audit source could not be read: \(reason)"
        }
        isLoadingAudit = false
    }
}

// MARK: - Rows (Alive glass)

/// One switch row on a group card: the words on the left, the switch on the
/// right, and an optional support caption (a policy key) under the detail.
private struct MacControlSwitchRow: View {
    let title: String
    var detail: String? = nil
    var caption: String? = nil
    var note: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(NativeAgentShell.text)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.secondary)
                }
                if let caption {
                    Text(caption)
                        .font(NativeAgentFont.mono)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .textSelection(.enabled)
                        .help("Policy key for this row — quote it when asking for support.")
                }
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .hazeTinted()
        }
    }
}

private struct MacControlCategoryRow: View {
    let label: String
    let detail: String
    let safeDefault: Bool
    let masterEnabled: Bool
    @Binding var isOn: Bool

    var body: some View {
        let notes = [
            masterEnabled ? nil : "Turning this on also turns on Mac control.",
            safeDefault ? "Safe by default." : nil,
        ].compactMap { $0 }
        MacControlSwitchRow(
            title: label,
            detail: detail,
            note: notes.isEmpty ? nil : notes.joined(separator: " "),
            isOn: $isOn
        )
    }
}

/// A capability the Swift Mac Control runtime deliberately does not offer yet.
/// It is a status row rather than a disabled Toggle: a toggle suggests a user
/// can make the action available, while these actions would only return 501.
/// A state, not trouble: the word is quiet.
private struct MacControlUnavailableCategoryRow: View {
    let label: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(NativeAgentShell.text)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text("Not available")
                .font(.system(size: 12))
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One Mac integration preset as a selectable card, the same shape as Trust's
/// four presets: a quiet card, and a ring in the haze on the chosen one.
private struct MacIntegrationPresetButton: View {
    var preset: MacIntegrationPreset
    var active: Bool
    var disabled: Bool
    var action: () -> Void
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue

    var body: some View {
        let haze = HazeColor(stored: colorRaw).base
        let shape = RoundedRectangle(cornerRadius: AliveMetrics.cardRadius, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(preset.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(NativeAgentShell.text)
                    Spacer(minLength: 4)
                    // Not colour alone: the chosen one also carries a mark.
                    if active {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(haze)
                            .accessibilityHidden(true)
                    }
                }
                Text(preset.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .aliveCard()
            .overlay {
                if active {
                    shape.strokeBorder(haze, lineWidth: 2)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.naFeel)
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

// MARK: - Audit Sheet

private struct MacControlAuditSheet: View {
    @Binding var entries: [MacControlAuditEntry]
    @Binding var isLoading: Bool
    @Binding var readProblem: String?
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
            } else {
                VStack(spacing: 0) {
                    if let readProblem {
                        Label(readProblem, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    if entries.isEmpty {
                        ContentUnavailableView(
                            readProblem == nil ? "No Entries" : "Audit Log Needs Attention",
                            systemImage: readProblem == nil ? "doc.text" : "exclamationmark.triangle",
                            description: Text(readProblem == nil
                                ? "No mac_control_audit.jsonl entries found."
                                : "The audit source could not provide readable entries.")
                        )
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
            }
        }
        .frame(width: 520, height: 400)
    }
}

// MARK: - Live Workbench

enum MacControlWorkbenchAvailability: Equatable {
    case ready
    case disabled(String)
    case unavailable(String)

    var isEnabled: Bool {
        if case .ready = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .ready:
            nil
        case .disabled(let message), .unavailable(let message):
            message
        }
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// The only action routes the mounted workbench can invoke. Keeping route,
/// native action name, policy gate, and user-facing label together prevents a
/// button from quietly drifting onto an unsupported 501 action.
enum MacControlWorkbenchAction: String, CaseIterable {
    case shell
    case fileRead = "file/read"
    case fileWrite = "file/write"
    case notify

    var title: String {
        switch self {
        case .shell: "Run Shell"
        case .fileRead: "Read File"
        case .fileWrite: "Write File"
        case .notify: "Notify"
        }
    }

    var systemImage: String {
        switch self {
        case .shell: "terminal"
        case .fileRead: "doc.text.magnifyingglass"
        case .fileWrite: "square.and.pencil"
        case .notify: "bell"
        }
    }

    var path: String { "/v1/mac_control/\(rawValue)" }

    func availability(
        policy: TrustMacControlPolicy,
        policySaved: Bool,
        hasRequiredInput: Bool = true
    ) -> MacControlWorkbenchAvailability {
        guard !macControlUnsupportedActions.contains(rawValue) else {
            return .unavailable("This version of NativeAgent does not support this action.")
        }
        guard policySaved else {
            return .disabled("Save your Mac Control permissions before trying an action.")
        }
        guard policy.enabled else {
            return .disabled("Turn on Mac Control before using this action.")
        }
        guard categoryAllowed(by: policy) else {
            return .disabled("Enable \(categoryName) in Mac Control categories first.")
        }
        guard hasRequiredInput else {
            return .disabled("Enter the required input before running this action.")
        }
        return .ready
    }

    private var categoryName: String {
        switch self {
        case .shell: "Terminal commands"
        case .fileRead, .fileWrite: "File Operations"
        case .notify: "Notifications"
        }
    }

    private func categoryAllowed(by policy: TrustMacControlPolicy) -> Bool {
        switch self {
        case .shell: policy.shellAllowed
        case .fileRead, .fileWrite: policy.fileOpsAllowed
        case .notify: policy.notificationsAllowed
        }
    }
}

private enum MacControlWorkbenchMode: String, CaseIterable, Identifiable {
    case shell = "Shell"
    case files = "Files"
    case notification = "Notify"

    var id: String { rawValue }
}

struct MacControlWorkbenchView: View {
    @Environment(AppModel.self) private var appModel
    var policy: TrustMacControlPolicy
    var policySaved: Bool = true

    @State private var mode: MacControlWorkbenchMode = .shell
    @State private var shellCommand = "pwd"
    @State private var shellCWD = NSHomeDirectory()
    @State private var filePath = NSHomeDirectory()
    @State private var fileContent = ""
    @State private var fileAppend = false
    @State private var notificationTitle = "NativeAgent"
    @State private var notificationMessage = "Mac Control workbench test"
    @State private var isRunning = false
    @State private var resultTitle = "Idle"
    @State private var resultBody = "Try an action to see its results, any errors, and whether it needs your approval."

    var body: some View {
        // Alive glass: an eyebrow over one group card — the notes, the action
        // and its inputs, then the result, each a row.
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow("Workbench")
            AliveGroupCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Try one Mac control action by hand and see what happens. Shortcuts and system actions are not in this version.")
                    .font(.system(size: 12))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !policySaved {
                    // Waiting on him (an unsaved edit), so teal, not trouble.
                    Label("Save your Mac control settings before trying an action.", systemImage: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.needsYou)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Picker("Action", selection: $mode) {
                    ForEach(MacControlWorkbenchMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .hazeTinted(.segments)

                switch mode {
                case .shell:
                    let availability = MacControlWorkbenchAction.shell.availability(
                        policy: policy,
                        policySaved: policySaved,
                        hasRequiredInput: !shellCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    TextField("Working directory", text: $shellCWD)
                        .textFieldStyle(.roundedBorder)
                    TextField("Command", text: $shellCommand, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                    workbenchButton(.shell, availability: availability) {
                        await run(path: MacControlWorkbenchAction.shell.path, body: [
                            "command": shellCommand,
                            "cwd": shellCWD,
                            "timeout": 60,
                            "trigger": "user"
                        ])
                    }
                    availabilityHint(availability)
                case .files:
                    let readAvailability = MacControlWorkbenchAction.fileRead.availability(
                        policy: policy,
                        policySaved: policySaved,
                        hasRequiredInput: !filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    let writeAvailability = MacControlWorkbenchAction.fileWrite.availability(
                        policy: policy,
                        policySaved: policySaved,
                        hasRequiredInput: !filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !fileContent.isEmpty
                    )
                    TextField("Path", text: $filePath)
                        .textFieldStyle(.roundedBorder)
                    TextField("Write content", text: $fileContent, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Append instead of replace", isOn: $fileAppend)
                        .toggleStyle(.switch)
                        .hazeTinted()
                        .controlSize(.small)
                        .font(.system(size: 13))
                    HStack {
                        workbenchButton(.fileRead, availability: readAvailability) {
                            await run(path: MacControlWorkbenchAction.fileRead.path, body: [
                                "path": filePath,
                                "max_bytes": 200_000,
                                "trigger": "user"
                            ])
                        }
                        workbenchButton(.fileWrite, availability: writeAvailability) {
                            await run(path: MacControlWorkbenchAction.fileWrite.path, body: [
                                "path": filePath,
                                "content": fileContent,
                                "append": fileAppend,
                                "trigger": "user"
                            ])
                        }
                    }
                    availabilityHint(readAvailability)
                    if writeAvailability.message != readAvailability.message {
                        availabilityHint(writeAvailability)
                    }
                case .notification:
                    let availability = MacControlWorkbenchAction.notify.availability(
                        policy: policy,
                        policySaved: policySaved,
                        hasRequiredInput: !notificationMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    TextField("Notification title", text: $notificationTitle)
                        .textFieldStyle(.roundedBorder)
                    TextField("Notification message", text: $notificationMessage)
                        .textFieldStyle(.roundedBorder)
                    workbenchButton(.notify, availability: availability) {
                        await run(path: MacControlWorkbenchAction.notify.path, body: [
                            "title": notificationTitle,
                            "message": notificationMessage,
                            "trigger": "user"
                        ])
                    }
                    availabilityHint(availability)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: isRunning ? "hourglass" : "terminal")
                        .foregroundStyle(resultColor)
                    Text(resultTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(resultColor)
                    Spacer()
                    if isRunning {
                        ProgressView().controlSize(.small)
                    }
                }
                ScrollView {
                    Text(resultBody)
                        .font(NativeAgentFont.mono)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 90, maxHeight: 180)
                .padding(10)
                .background(NativeAgentShell.softFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Failed is trouble; waiting for approval waits on him; the rest is quiet.
    private var resultColor: Color {
        switch resultTitle {
        case "Failed": NativeAgentShell.trouble
        case "Pending Approval": NativeAgentShell.needsYou
        default: NativeAgentShell.secondary
        }
    }

    private func workbenchButton(_ actionTarget: MacControlWorkbenchAction, availability: MacControlWorkbenchAvailability, action: @escaping () async -> Void) -> some View {
        Button(actionTarget.title, systemImage: actionTarget.systemImage) {
            Task { await action() }
        }
        .buttonStyle(.bordered)
        .disabled(!availability.isEnabled || isRunning)
    }

    @ViewBuilder
    private func availabilityHint(_ availability: MacControlWorkbenchAvailability) -> some View {
        if let message = availability.message {
            Label(message, systemImage: availability.isUnavailable ? "exclamationmark.triangle.fill" : "lock.fill")
                .font(.caption)
                .foregroundStyle(NativeAgentShell.secondary)
        }
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
