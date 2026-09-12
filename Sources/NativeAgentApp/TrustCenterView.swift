import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

/// The collapsed Trust Advanced header is the only visible surface for its
/// privacy-map and backup authority reads. Keep unavailable/stale data
/// distinguishable from a legitimately empty backup history before hiding the
/// panels behind the disclosure.
enum TrustCenterAdvancedDisclosurePresentation {
    enum ReadState: Equatable {
        case loading
        case available
        case stale
        case unavailable
    }

    struct Badge: Equatable {
        let text: String
        let status: String
    }

    struct State: Equatable {
        let policy: ReadState
        let privacyMap: ReadState
        let backups: ReadState
        let backupBeforeWriteEnabled: Bool?

        var collapsedBadge: Badge? {
            if policy == .unavailable || privacyMap == .unavailable || backups == .unavailable {
                return Badge(text: "Details unavailable", status: "warn")
            }
            if policy == .stale || privacyMap == .stale || backups == .stale {
                return Badge(text: "Details stale", status: "warn")
            }
            if backupBeforeWriteEnabled == false {
                return Badge(text: "Backups off", status: "warn")
            }
            if policy == .loading || privacyMap == .loading || backups == .loading {
                return Badge(text: "Loading", status: "info")
            }
            return nil
        }
    }

    static func resolve(
        hasPolicy: Bool,
        hasPrivacyMap: Bool,
        backupCount: Int,
        backupBeforeWriteEnabled: Bool?,
        hasRefreshAttempt: Bool,
        failedEndpoints: [String]
    ) -> State {
        let failures = Set(failedEndpoints.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return State(
            policy: readState(
                hasContent: hasPolicy,
                hasRefreshAttempt: hasRefreshAttempt,
                failed: failures.contains("trust policy")
            ),
            privacyMap: readState(
                hasContent: hasPrivacyMap,
                hasRefreshAttempt: hasRefreshAttempt,
                failed: failures.contains("privacy map")
            ),
            backups: readState(
                hasContent: backupCount > 0,
                hasRefreshAttempt: hasRefreshAttempt,
                failed: failures.contains("backups")
            ),
            backupBeforeWriteEnabled: backupBeforeWriteEnabled
        )
    }

    private static func readState(
        hasContent: Bool,
        hasRefreshAttempt: Bool,
        failed: Bool
    ) -> ReadState {
        if failed { return hasContent ? .stale : .unavailable }
        if !hasContent && !hasRefreshAttempt { return .loading }
        return .available
    }
}

/// One Trust mutation's typed outcome. This belongs to the Trust surface,
/// unlike `AppModel.statusText`, which is an app-wide activity line and may be
/// replaced by unrelated work before the view redraws.
enum TrustCenterActionOutcome: Equatable {
    case saved(String)
    case failed(String)
}

enum TrustCenterActionPresentation {
    struct State: Equatable {
        let label: String
        let text: String
        let badgeText: String
        let badgeStatus: String
        let systemImage: String
    }

    static func state(for outcome: TrustCenterActionOutcome) -> State {
        switch outcome {
        case .saved(let text):
            State(
                label: "Latest Trust action",
                text: bounded(text),
                badgeText: "Saved",
                badgeStatus: "ok",
                systemImage: "checkmark.circle.fill"
            )
        case .failed(let text):
            State(
                label: "Latest Trust action",
                text: bounded(text),
                badgeText: "Failed",
                badgeStatus: "warn",
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }

    private static func bounded(_ text: String) -> String {
        let maximumVisibleCharacters = 280
        guard text.count > maximumVisibleCharacters else { return text }
        return String(text.prefix(maximumVisibleCharacters)) + "…"
    }
}

/// Saved authority is the source of the active card and status.
enum TrustCenterPolicyStatusPresentation {
    static func preset(policy: TrustPolicy, accessMode: String?) -> TrustPolicyPreset? {
        TrustPolicyPreset.allCases.first {
            let plan = $0.plan
            return plan.agentAccessMode == accessMode
                && plan.permissionLevel == policy.permissionLevel
                && plan.autonomyDefault == (policy.autonomyDefault ?? "supervised")
                && plan.requireBackups == (policy.filePolicy?.requireBackupBeforeWrite ?? true)
                && plan.outsideDefault == (policy.filePolicy?.outsideWorkspaceDefault ?? "deny")
                && plan.developerMode == policy.developerMode
                && (policy.filePolicy?.allowDestructiveActions ?? false) == plan.developerMode
                && (policy.macControlPolicy?.shellAllowed ?? false) == plan.developerMode
                && (policy.macControlPolicy?.systemControlAllowed ?? false) == plan.developerMode
        }
    }

    static func line(
        policy: TrustPolicy?, accessMode: String?,
        permissionLevel: String, autonomyDefault: String,
        requireBackups: Bool, outsideDefault: String,
        isApplying: Bool = false, needsConfirmation: Bool = false,
        policyReadFailed: Bool = false
    ) -> String {
        guard !policyReadFailed, let policy else { return "Effective access unavailable · Reload Trust to check saved policy" }
        let access: String
        let matched = preset(policy: policy, accessMode: accessMode)
        if let preset = matched {
            access = preset.title
        } else {
            let mode: String
            switch accessMode {
            case "read_only": mode = "Read only"
            case "workspace": mode = "Workspace"
            case "full": mode = "Full Mac"
            default: mode = "Auto"
            }
            access = "Custom · \(mode) access"
        }
        let state = needsConfirmation ? "Confirmation required"
            : isApplying ? "Applying changes…"
            : "Saved"
        // 2026-09-10: Full Mac has no timer any more, and nothing on the page
        // said so. The saved line is the only place a person looks after
        // picking the card, so it carries the persistence — and only there.
        if matched == .fullMac, state == "Saved" {
            return "\(access) · \(state) · stays on until you change it"
        }
        return "\(access) · \(state)"
    }
}

struct TrustCenterView: View {
    @Environment(AppModel.self) private var appModel
    @State private var agentAccessMode = "auto"
    @State private var permissionLevel = "balanced"
    @State private var autonomyDefault = "supervised"
    @State private var requireBackups = true
    @State private var outsideDefault = "deny"
    @State private var simulationPath = "\(NSHomeDirectory())/Desktop"
    // PATCH-2026-05-06: bug-2 full-mac friction alert state
    @State private var showFullMacAlert = false
    // PATCH-2026-05-06: dev-mode local binding mirrors trustPolicy.developerMode
    @State private var developerMode = false
    @State private var isApplyingPolicy = false
    @State private var pendingRestore: BackupRecord?
    @State private var restoringBackupID: String?
    // 2026-07-22 trust-tighten: disclosure state persists across visits so a
    // power user who opens the Advanced group finds it open next time.
    @AppStorage("trustShowAdvanced") private var showAdvancedTrust = false
    private var loadsSecurityStatus = true

    init() {}

    #if DEBUG
    init(snapshotPolicy: TrustPolicy, expanded: Bool) {
        loadsSecurityStatus = false
        _permissionLevel = State(initialValue: snapshotPolicy.permissionLevel)
        _autonomyDefault = State(initialValue: snapshotPolicy.autonomyDefault ?? "supervised")
        _requireBackups = State(initialValue: snapshotPolicy.filePolicy?.requireBackupBeforeWrite ?? true)
        _outsideDefault = State(initialValue: snapshotPolicy.filePolicy?.outsideWorkspaceDefault ?? "deny")
        _developerMode = State(initialValue: snapshotPolicy.developerMode)
        _agentAccessMode = State(initialValue: AppModel.agentAccessMode(from: snapshotPolicy))
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 2026-07-22 trust-tighten: 16 stacked panels → 4 + one
                // collapsed Advanced group. Guardrail Summary deleted (its
                // five tiles restated the very controls the Access & Policy
                // panel edits); Policy Map demoted to a disclosure inside
                // Access & Policy; Presets + Agent Access + Policy merged;
                // feature permissions share a two-column grid; power-user
                // panels (boundaries, privacy map, simulator, backups)
                // collapsed by default.
                //
                // Sweep R4 C10 (2026-08-06): the summary is BACK, but derived.
                // The 2026-07-22 deletion was right about the old panel — five
                // hand-written tiles restating controls below them, which is a
                // trust claim that goes stale silently. TrustGuardrailSummary
                // is a pure function of `appModel.trustPolicy` plus the access
                // mode this page already resolved, so it cannot drift from the
                // switches underneath it. Read-only: it renders no controls.
                accessAndPolicyPanel

                TrustGuardrailSummaryPanel(accessMode: appModel.trustPolicy.map { accessMode(from: $0) } ?? "auto")

                NativeSecurityCenterPanel(loadsOnAppear: loadsSecurityStatus)

                TrustSection(title: "Feature permissions", carded: false) {
                    // Taste pass 2026-07-24: alignment .top — default cell
                    // alignment vertically centers each card against the
                    // tallest in its row, so the four cards floated at four
                    // different heights.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(TrustFeaturePermissionCards.all) { card in
                            featureGroup(title: card.title) {
                                card.content()
                            }
                        }
                    }
                }

                // PATCH-2026-05-07: mac-control-ui-1 Mac Control permissions panel
                // 2026-07-23 B2.5a: this tab is the one home for Mac Control
                // CAPABILITIES + policy (shell, AppleScript, Accessibility, file
                // ops, iOS remote, assistant watch). Per-app system (TCC) grants
                // and per-surface read/write toggles have their one home in the
                // Mac Integration tab — cross-linked here so a user answering
                // "what can it do on my Mac" knows where each control lives.
                Text("Per-app system permission grants (Calendar, Mail, Messages…) and per-surface read and write toggles live on the Mac integration page.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                MacControlPermissionsView()

                // W8 (2026-08-14) — the ambient activity watcher's consent
                // surface. Its own top-level panel rather than a cell in the
                // Feature Permissions grid: this is the only feature in the app
                // that records what the human does when they are not talking to
                // the agent, its controls do not fit a four-line card, and
                // burying the honest limits on title redaction inside a grid
                // cell would be the wrong kind of tidy.
                ActivityCapturePermissionsView()

                advancedSection

                if let outcome = appModel.trustCenterActionOutcome {
                    let status = TrustCenterActionPresentation.state(for: outcome)
                    HStack(alignment: .top, spacing: 8) {
                        TrustStatusChip(text: status.badgeText, tone: TrustTone.named(status.badgeStatus))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status.label)
                                .font(ShellType.captionSemibold)
                                .foregroundStyle(NativeAgentShell.secondary)
                            Text(status.text)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityLabel("\(status.label): \(status.text)")
                }
            }
            // Taste pass 2026-08-11 (User: "spread out... not centered with
            // eachother... sloppy"): the page frame pins one readable column,
            // so every section shares the same left edge instead of
            // stretching controls across the full window width.
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Trust")
        .task {
            if let policy = appModel.trustPolicy {
                applyPolicy(policy)
            }
        }
        .onChange(of: appModel.trustPolicy) { _, newPolicy in
            if let newPolicy {
                applyPolicy(newPolicy)
            }
        }
        .alert(item: $pendingRestore) { backup in
            Alert(
                title: Text("Restore backup?"),
                message: Text(restoreConfirmationMessage(for: backup)),
                primaryButton: .destructive(Text("Restore backup")) {
                    beginRestore(backup)
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Access & Policy (2026-07-22 trust-tighten: Presets + Agent
    // Access + Policy merged into one panel; Policy Map lives here as a
    // disclosure — it documents the modes rather than controlling anything).

    private var accessAndPolicyPanel: some View {
        TrustSection(title: "Access and policy") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                    TrustPresetButton(title: "Safe", subtitle: "Read files; no changes or Mac control", isSelected: activePreset == .safe) {
                        applyTrustPreset(.safe)
                    }
                    TrustPresetButton(title: "Work mode", subtitle: "Edit approved workspaces; no outside writes or shell", isSelected: activePreset == .work) {
                        applyTrustPreset(.work)
                    }
                    TrustPresetButton(title: "Builder", subtitle: "Edit workspaces; ask to write outside; no shell", isSelected: activePreset == .builder) {
                        applyTrustPreset(.builder)
                    }
                    TrustPresetButton(title: "Full Mac", subtitle: "Files anywhere, shell, system control, move or trash", isSelected: activePreset == .fullMac) {
                        applyTrustPreset(.fullMac)
                    }
                }
                Text(policyStatusLine)
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Create backup now") {
                    Task { await appModel.createBackup(reason: "manual Trust Center backup") }
                }
            }
            .alert(
                "Enable Full Mac access?",
                isPresented: $showFullMacAlert
            ) {
                Button("Enable Full Mac", role: .destructive) {
                    confirmPendingFullMacPolicy()
                }
                Button("Cancel", role: .cancel) {
                    cancelPendingFullMacPolicy()
                }
            } message: {
                Text("""
                The agent will be able to read and modify files anywhere, run shell commands, control the system, and move or trash files across app surfaces.

                Workspace actions run autonomously, and access outside workspaces is allowed. Pre-write backups stay on.

                Full Mac does not bypass macOS itself. Documents, Desktop, Downloads, and other protected folders still need their own approval in System Settings → Privacy & Security → Files and Folders (or Full Disk Access) before anything can read them.
                """)
            }
        }
    }

    private var policyStatusLine: String {
        TrustCenterPolicyStatusPresentation.line(
            policy: appModel.trustPolicy,
            accessMode: appModel.trustPolicy.map { accessMode(from: $0) },
            permissionLevel: permissionLevel,
            autonomyDefault: autonomyDefault,
            requireBackups: requireBackups,
            outsideDefault: outsideDefault,
            isApplying: isApplyingPolicy,
            needsConfirmation: showFullMacAlert,
            policyReadFailed: appModel.panelRefreshStatus[.trust]?.failedEndpoints.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "trust policy"
            } == true
        )
    }

    private var activePreset: TrustPolicyPreset? {
        guard let policy = appModel.trustPolicy,
              appModel.panelRefreshStatus[.trust]?.failedEndpoints.contains("trust policy") != true else { return nil }
        return TrustCenterPolicyStatusPresentation.preset(policy: policy, accessMode: accessMode(from: policy))
    }

    // MARK: - Feature permission grouping (2026-07-22 trust-tighten)

    private func featureGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .trustCard()
    }

    // MARK: - Advanced group (2026-07-22 trust-tighten: power-user panels
    // collapsed by default; styling mirrors the Advanced Mac Control
    // disclosure in MacControlPermissionsView for consistency).

    private var advancedPresentation: TrustCenterAdvancedDisclosurePresentation.State {
        let refresh = appModel.panelRefreshStatus[.trust]
        return TrustCenterAdvancedDisclosurePresentation.resolve(
            hasPolicy: appModel.trustPolicy != nil,
            hasPrivacyMap: appModel.privacyMap != nil,
            backupCount: appModel.backups.count,
            backupBeforeWriteEnabled: appModel.trustPolicy?.filePolicy?.requireBackupBeforeWrite,
            hasRefreshAttempt: refresh != nil,
            failedEndpoints: refresh?.failedEndpoints ?? []
        )
    }

    private var advancedSection: some View {
        TrustFold(isExpanded: $showAdvancedTrust) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Advanced")
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text("Safety boundaries, privacy map, policy simulator, and backups.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
        } trailing: {
            if !showAdvancedTrust, let badge = advancedPresentation.collapsedBadge {
                TrustStatusChip(text: badge.text, tone: TrustTone.named(badge.status))
            }
        } content: {
            VStack(alignment: .leading, spacing: 24) {
                safetyBoundariesPanel
                privacyMapPanel
                simulatorPanel
                backupsPanel
            }
        }
    }

    private var safetyBoundariesPanel: some View {
        TrustSection(title: "Safety boundaries") {
            let state = TrustSafetyBoundariesPresentation.state(
                policy: appModel.trustPolicy,
                accessMode: agentAccessMode
            )
            if let unavailable = state.unavailableMessage {
                Text(unavailable)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(state.rows) { boundary in
                    TrustBoundaryRow(
                        title: boundary.title,
                        detail: boundary.detail,
                        systemImage: boundary.systemImage,
                        tone: boundary.tone
                    )
                }
            }
        }
    }

    private var privacyMapPanel: some View {
        PrivacyMapPanel(
            trustPolicyRoot: appModel.trustPolicy?.appDataRoot,
            privacyMap: appModel.privacyMap
        )
    }

    private var simulatorPanel: some View {
        TrustSection(title: "Policy simulator") {
            HStack(spacing: 8) {
                TextField("Path", text: $simulationPath)
                    .textFieldStyle(.roundedBorder)
                    .font(ShellType.label)
                Button("Simulate write") {
                    Task { await appModel.simulatePolicy(action: "file_write", path: simulationPath) }
                }
            }
            if let failure = appModel.policySimulationFailure {
                Text("Simulation unavailable")
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.trouble)
                Text(failure)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let simulation = appModel.policySimulation {
                let verdict = PolicySimulationVerdict(simulation: simulation)
                HStack(spacing: 8) {
                    Text(verdict.title)
                        .font(ShellType.labelSemibold)
                        .foregroundStyle(verdictColor(verdict))
                    TrustStatusChip(
                        text: "Risk \(simulation.risk.lowercased())",
                        tone: TrustTone.named(simulation.risk)
                    )
                }
                ForEach(simulation.reasons, id: \.self) { reason in
                    Text(reason)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("This is a saved-policy decision only. It does not execute a write or verify macOS privacy access.")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var backupsPanel: some View {
        TrustSection(title: "Backups") {
            if appModel.backups.isEmpty {
                Text("No backups yet. Backups made here, and the ones taken before a workspace write, will be listed with their date and what they covered.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(appModel.backups.prefix(8)) { backup in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(backup.reason)
                                .font(ShellType.bodySemibold)
                                .foregroundStyle(NativeAgentShell.text)
                            Text("\(UserDisplayFormatters.humanizeISOTimestamp(backup.createdAt)) · \(backup.scope.joined(separator: ", "))")
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        if restoringBackupID == backup.id {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Restoring backup")
                        }
                        Button("Restore") {
                            pendingRestore = backup
                        }
                        .disabled(restoringBackupID != nil)
                    }
                    .frame(minHeight: 48)
                    .textSelection(.enabled)
                }
            }
        }
    }

    /// The simulator's verdict in the room's three state colours: the teal is
    /// worn only where the decision actually waits on a person.
    private func verdictColor(_ verdict: PolicySimulationVerdict) -> Color {
        switch verdict {
        case .allowed: NativeAgentShell.calm
        case .approvalRequired: NativeAgentShell.needsYou
        case .denied, .unavailable: NativeAgentShell.trouble
        }
    }

    private func restoreConfirmationMessage(for backup: BackupRecord) -> String {
        let scopes = backup.scope.isEmpty ? "no recorded scopes" : backup.scope.joined(separator: ", ")
        let created = UserDisplayFormatters.humanizeISOTimestamp(backup.createdAt)
        return "Reason: \(backup.reason)\nDate: \(created)\nAffected scopes: \(scopes)\n\nCurrent data in those scopes will be overwritten. NativeAgent will create a pre-restore safety backup before changing current data."
    }

    private func beginRestore(_ backup: BackupRecord) {
        guard restoringBackupID == nil else { return }
        restoringBackupID = backup.id
        Task { @MainActor in
            await appModel.restoreBackup(backup)
            restoringBackupID = nil
        }
    }

    private func applyPolicy(_ policy: TrustPolicy) {
        permissionLevel = policy.permissionLevel
        autonomyDefault = policy.autonomyDefault ?? "supervised"
        requireBackups = policy.filePolicy?.requireBackupBeforeWrite ?? true
        outsideDefault = policy.filePolicy?.outsideWorkspaceDefault ?? "deny"
        developerMode = policy.developerMode
        agentAccessMode = accessMode(from: policy)
        if appModel.chatFileAccess != agentAccessMode {
            appModel.chatFileAccess = agentAccessMode
        }
    }

    private func accessMode(from policy: TrustPolicy) -> String {
        AppModel.agentAccessMode(from: policy, fallback: appModel.chatFileAccess)
    }

    private func confirmPendingFullMacPolicy() {
        isApplyingPolicy = true
        Task { @MainActor in
            settleTrustPreset(await TrustPolicyPresetAction.apply(
                .fullMac, appModel: appModel, fullMacConfirmed: true
            ))
        }
    }

    private func cancelPendingFullMacPolicy() {
        TrustPolicyPresetTransition.cancelConfirmation(isPresented: &showFullMacAlert)
    }

    private func applyTrustPreset(_ preset: TrustPolicyPreset) {
        guard !isApplyingPolicy else { return }
        if preset == .fullMac {
            showFullMacAlert = true
            return
        }
        isApplyingPolicy = true
        Task {
            settleTrustPreset(await TrustPolicyPresetAction.apply(preset, appModel: appModel))
        }
    }

    @MainActor
    private func settleTrustPreset(_ outcome: TrustPolicyPresetAction.Outcome) {
        isApplyingPolicy = false
        appModel.statusText = TrustPolicyPresetActionPresentation.statusText(for: outcome)
        switch outcome {
        case .confirmationRequired:
            agentAccessMode = appModel.trustPolicy.map { accessMode(from: $0) }
                ?? AppModel.normalizedAgentAccessMode(appModel.chatFileAccess)
            showFullMacAlert = true
        case .applied(let policy):
            applyPolicy(policy)
        case .failed:
            if let policy = appModel.trustPolicy {
                applyPolicy(policy)
            }
        }
    }
}

enum TrustPolicyPreset: CaseIterable, Equatable {
    case safe
    case work
    case builder
    case fullMac

    var title: String {
        switch self {
        case .safe: "Safe"
        case .work: "Work mode"
        case .builder: "Builder"
        case .fullMac: "Full Mac"
        }
    }

    var plan: TrustPolicyPresetPlan {
        switch self {
        case .safe:
            TrustPolicyPresetPlan(
                agentAccessMode: "read_only", permissionLevel: "strict",
                autonomyDefault: "supervised", requireBackups: true,
                outsideDefault: "deny", developerMode: false,
                commit: .accessModeOnly, requiresFullMacConfirmation: false
            )
        case .work:
            TrustPolicyPresetPlan(
                agentAccessMode: "workspace", permissionLevel: "balanced",
                autonomyDefault: "workspace_autonomous", requireBackups: true,
                outsideDefault: "deny", developerMode: false,
                commit: .accessModeOnly, requiresFullMacConfirmation: false
            )
        case .builder:
            TrustPolicyPresetPlan(
                agentAccessMode: "workspace", permissionLevel: "balanced",
                autonomyDefault: "workspace_autonomous", requireBackups: true,
                outsideDefault: "ask", developerMode: false,
                commit: .accessModeThenTrustPolicy, requiresFullMacConfirmation: false
            )
        case .fullMac:
            TrustPolicyPresetPlan(
                agentAccessMode: "full", permissionLevel: "full_mac_os",
                autonomyDefault: "workspace_autonomous", requireBackups: true,
                outsideDefault: "allow", developerMode: true,
                commit: .accessModeOnly, requiresFullMacConfirmation: true
            )
        }
    }
}

/// The privacy map's visible state is derived only from the root-scoped map
/// returned by Trust's reader. It keeps a pending read distinct from a loaded
/// map whose categories happen to be empty.
enum PrivacyMapPanelPresentation {
    struct Category: Identifiable, Equatable {
        let source: PrivacyCategory

        var id: String { source.id }
        var protectionLabel: String { source.exportable ? "Exportable" : "Protected" }
    }

    struct Loaded: Equatable {
        let root: String
        let generatedAt: String
        let categories: [Category]
    }

    enum State: Equatable {
        case pending
        case loaded(Loaded)
    }

    static func resolve(trustPolicyRoot: String?, privacyMap: PrivacyMap?) -> State {
        guard let privacyMap else { return .pending }
        return .loaded(Loaded(
            root: trustPolicyRoot ?? privacyMap.dataRoot,
            generatedAt: privacyMap.generatedAt,
            categories: privacyMap.categories.map(Category.init(source:))
        ))
    }
}

struct PrivacyMapPanel: View {
    let trustPolicyRoot: String?
    let privacyMap: PrivacyMap?

    private var presentation: PrivacyMapPanelPresentation.State {
        PrivacyMapPanelPresentation.resolve(
            trustPolicyRoot: trustPolicyRoot,
            privacyMap: privacyMap
        )
    }

    var body: some View {
        TrustSection(title: "Privacy map") {
            switch presentation {
            case .pending:
                Text("The privacy map has not loaded yet. It lists what the agent keeps on this Mac and which of it can leave.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .loaded(let map):
                Text(UserDisplayFormatters.tildifyPath(map.root))
                    .font(ShellType.code)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(map.root)
                Text("Generated \(UserDisplayFormatters.humanizeISOTimestamp(map.generatedAt))")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                ForEach(map.categories) { category in
                    PrivacyMapPanelCategoryRow(category: category)
                }
            }
        }
    }
}

private struct PrivacyMapPanelCategoryRow: View {
    let category: PrivacyMapPanelPresentation.Category

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(category.source.title)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                TrustStatusChip(
                    text: category.protectionLabel,
                    tone: category.source.exportable ? .quiet : .trouble
                )
            }
            Text(category.source.contains)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(UserDisplayFormatters.tildifyPath(category.source.path))
                .font(ShellType.code)
                .foregroundStyle(NativeAgentShell.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

struct TrustPolicyPresetPlan: Equatable {
    enum Commit: Equatable {
        case accessModeOnly
        case accessModeThenTrustPolicy
    }

    let agentAccessMode: String
    let permissionLevel: String
    let autonomyDefault: String
    let requireBackups: Bool
    let outsideDefault: String
    let developerMode: Bool
    let commit: Commit
    let requiresFullMacConfirmation: Bool
}

enum TrustPolicyPresetTransition: Equatable {
    case apply(TrustPolicyPresetPlan)
    case confirmationRequired(TrustPolicyPresetPlan)

    static func cancelConfirmation(isPresented: inout Bool) {
        isPresented = false
    }

    static func request(_ preset: TrustPolicyPreset) -> Self {
        let plan = preset.plan
        return plan.requiresFullMacConfirmation
            ? .confirmationRequired(plan)
            : .apply(plan)
    }
}

/// One authoritative preset action for Trust's visible buttons. The action
/// owns both write phases for Builder and refuses to enter Full Mac without
/// the explicit confirmation transition.
@MainActor
enum TrustPolicyPresetAction {
    enum Outcome {
        case confirmationRequired(TrustPolicyPresetPlan)
        case applied(TrustPolicy)
        case failed(String)
    }

    static func apply(
        _ preset: TrustPolicyPreset,
        appModel: AppModel,
        fullMacConfirmed: Bool = false
    ) async -> Outcome {
        let plan = preset.plan
        if case .confirmationRequired = TrustPolicyPresetTransition.request(preset), !fullMacConfirmed {
            return .confirmationRequired(plan)
        }

        guard await appModel.saveAgentAccessMode(
            plan.agentAccessMode,
            developerMode: plan.developerMode
        ) else {
            return .failed(appModel.statusText)
        }
        if plan.commit == .accessModeThenTrustPolicy {
            let trustPolicySaved = await appModel.saveTrustPolicy(
                permissionLevel: plan.permissionLevel,
                autonomyDefault: plan.autonomyDefault,
                requireBackups: plan.requireBackups,
                outsideDefault: plan.outsideDefault,
                developerMode: plan.developerMode
            )
            guard trustPolicySaved else {
                return .failed(appModel.statusText)
            }
        }
        guard let policy = appModel.trustPolicy else {
            return .failed("The preset write completed without a readable Trust policy.")
        }
        return .applied(policy)
    }
}

enum TrustPolicyPresetActionPresentation {
    static func statusText(for outcome: TrustPolicyPresetAction.Outcome) -> String {
        switch outcome {
        case .confirmationRequired:
            return "Full Mac access needs confirmation."
        case .applied:
            return "Trust preset applied."
        case .failed(let detail):
            return detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Trust preset could not be applied."
                : detail
        }
    }
}

private struct TrustPresetButton: View {
    var title: String
    var subtitle: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text(subtitle)
                    .font(ShellType.caption)
                    .foregroundStyle(TrustPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .fill(TrustPalette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .strokeBorder(isSelected ? NativeAgentShell.text : TrustPalette.border, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.naFeel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// 2026-07-22 trust-tighten: no longer wraps itself in a NativePanel — it
// renders as plain rows inside the Access & Policy panel's "What each mode
// allows" disclosure.
private struct PolicyMapView: View {
    var policy: TrustPolicy?
    var activeMode: String

    var body: some View {
        switch TrustPolicyMapPresentation.resolve(policy: policy, activeMode: activeMode) {
        case .policyUnavailable:
            Text("The current policy is unavailable, so NativeAgent cannot safely describe what these modes allow yet.")
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.trouble)
                .fixedSize(horizontal: false, vertical: true)
        case let .rows(rows):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(rows) { row in
                    PolicyMapRow(row: row)
                }
            }
        }
    }
}

private struct PolicyMapRow: View {
    let row: TrustPolicyMapRow

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            GridRow {
                Text(row.title)
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(row.isActive ? NativeAgentShell.text : NativeAgentShell.secondary)
                    .gridColumnAlignment(.leading)
                policyChip(row.files)
                policyChip(row.shellAllowed ? "shell" : "no shell", enabled: row.shellAllowed)
                policyChip(row.macControlAllowed ? "mac" : "no mac", enabled: row.macControlAllowed)
                policyChip(row.iosRemoteAllowed ? "iOS" : "no iOS", enabled: row.iosRemoteAllowed)
                policyChip(row.autonomy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                .fill(row.isActive ? NativeAgentShell.softFill : Color.clear)
        )
    }

    private func policyChip(_ text: String, enabled: Bool = true) -> some View {
        Text(text)
            .font(ShellType.caption)
            .foregroundStyle(enabled ? NativeAgentShell.text : NativeAgentShell.tertiary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(NativeAgentShell.quietFill, in: Capsule())
    }
}

// MARK: - Page kit (2026-09-03 Advanced refinement)
//
// Trust used to be a stack of `NativePanel`s: a thin-material slab each, an
// icon and a tint per title, and rules drawn between the controls inside. On
// the shell's one sheet that read as a dozen plates dropped on the glass. A
// section is now the Advanced list's own shape — an eyebrow, then one card —
// and the only colours left are the room's four roles.

/// The tone a status word carries. Three states and a quiet default, no raw
/// colours.
private enum TrustTone {
    case calm
    case trouble
    case needsYou
    case quiet

    var color: Color {
        switch self {
        case .calm: NativeAgentShell.calm
        case .trouble: NativeAgentShell.trouble
        case .needsYou: NativeAgentShell.needsYou
        case .quiet: NativeAgentShell.secondary
        }
    }

    /// The tone behind one of the status words the Trust presentations return.
    static func named(_ status: String?) -> TrustTone {
        switch status?.lowercased() {
        case "ok", "done", "passed", "active", "valid", "ready", "low", "saved":
            return .calm
        case "warn", "warning", "blocked", "needs_setup", "medium", "high",
             "fail", "failed", "error", "critical", "timeout":
            return .trouble
        default:
            return .quiet
        }
    }
}

/// One section of the page: the eyebrow the Advanced list uses, and the
/// controls under it on one card.
private struct TrustSection<Content: View>: View {
    let title: String
    /// A section whose content is already a grid of cards carries no card of
    /// its own — a card inside a card is the plate this pass removed.
    var carded: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ShellType.labelSemibold)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(TrustPalette.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(TrustPalette.card, in: RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, 2)
            if carded {
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .trustCard()
            } else {
                VStack(alignment: .leading, spacing: 12) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A short status word beside the thing it describes.
private struct TrustStatusChip: View {
    let text: String
    let tone: TrustTone

    var body: some View {
        Text(text)
            .font(ShellType.captionSemibold)
            .foregroundStyle(tone.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tone.color.opacity(0.16), in: Capsule())
    }
}

/// A bare fold: a chevron, the words, and one gesture. No plate, no material,
/// and the shell's one fold animation with Reduce Motion honoured.
private struct TrustFold<Label: View, Trailing: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var label: Label
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(NativeAgentMotion.respecting(ShellFoldMotion.open, reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(ShellType.captionSemibold)
                        .foregroundStyle(NativeAgentShell.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    label
                    Spacer(minLength: 8)
                    trailing
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content
                    .transition(ShellFoldMotion.transition(reduceMotion: reduceMotion))
            }
        }
    }
}

extension TrustFold where Trailing == EmptyView {
    init(
        isExpanded: Binding<Bool>,
        @ViewBuilder label: () -> Label,
        @ViewBuilder content: () -> Content
    ) {
        self.init(isExpanded: isExpanded, label: label, trailing: { EmptyView() }, content: content)
    }
}

private extension View {
    /// The room's one content card: a quiet fill, one hairline, radius 12.
    func trustCard() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .fill(TrustPalette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .strokeBorder(TrustPalette.border, lineWidth: 1)
            )
    }
}

private enum TrustPalette {
    // Resolve in SwiftUI. The shell overlays its warm lamp after page content;
    // keep dark surfaces deep enough for the final composited text contrast.
    struct AdaptiveColor: ShapeStyle {
        let light: Color
        let dark: Color

        func resolve(in environment: EnvironmentValues) -> Color {
            environment.colorScheme == .dark ? dark : light
        }
    }

    static let secondary = AdaptiveColor(
        light: Color(.sRGB, red: 0.28, green: 0.30, blue: 0.34),
        dark: Color(.sRGB, red: 0.80, green: 0.82, blue: 0.85)
    )
    /// The same glass every other card in the room wears.
    static let card = TodayPalette.cardFill
    static let border = TodayPalette.cardStroke
}
