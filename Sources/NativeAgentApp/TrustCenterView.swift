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
    @State private var pendingPermissionLevel = "balanced"
    @State private var pendingOutsideDefault = "deny"
    // PATCH-2026-05-06: dev-mode local binding mirrors trustPolicy.developerMode
    @State private var developerMode = false
    @State private var savingDeveloperMode = false
    @State private var isApplyingPolicy = false
    @State private var pendingRestore: BackupRecord?
    @State private var restoringBackupID: String?
    // 2026-07-22 trust-tighten: disclosure state persists across visits so a
    // power user who opens the Advanced group finds it open next time.
    @AppStorage("trustShowPolicyMap") private var showPolicyMap = false
    @AppStorage("trustShowAdvanced") private var showAdvancedTrust = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 2026-07-22 trust-tighten: 16 stacked panels → 4 + one
                // collapsed Advanced group. Guardrail Summary deleted (its
                // five tiles restated the very controls the Access & Policy
                // panel edits); Policy Map demoted to a disclosure inside
                // Access & Policy; Presets + Agent Access + Policy merged;
                // feature permissions share a two-column grid; power-user
                // panels (boundaries, privacy map, simulator, backups)
                // collapsed by default.
                NativeSecurityCenterPanel()

                accessAndPolicyPanel

                // Full Mac session window (2026-06-10): duration picker +
                // live expiry state mirroring the gate that sweeps the
                // agent's tool catalog (fullMacToolAccess →
                // MacControlGate.fullMacActive). Hidden while Full Mac has
                // never been confirmed — the Access picker / presets are the
                // entry path, and the panel appears once a session exists.
                if FullMacExpiry.state(appModel.trustPolicy) != .off {
                    FullMacSessionPanel()
                }

                NativePanel(title: "Feature Permissions", systemImage: "checklist") {
                    // Taste pass 2026-07-24: alignment .top — default cell
                    // alignment vertically centers each card against the
                    // tallest in its row, so the four cards floated at four
                    // different heights.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                        featureGroup(title: "Multimodal", systemImage: "sparkles", tint: .blue) {
                            MultimodalPermissionsView()
                        }
                        featureGroup(title: "Autonomous Training", systemImage: "brain", tint: .purple) {
                            TrainingPermissionsView()
                        }
                        featureGroup(title: "Workshop Autonomy", systemImage: "hammer.circle", tint: .cyan) {
                            WorkshopPermissionsView()
                        }
                        featureGroup(title: "Living Memory", systemImage: "brain.filled.head.profile", tint: .green) {
                            LivingMemoryPermissionsView()
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
                Label("Per-app system permission grants (Calendar, Mail, Messages…) and per-surface read/write toggles live in the Mac Integration tab.", systemImage: "macbook.and.iphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                MacControlPermissionsView()

                advancedSection

                Text(appModel.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding()
        }
        .padding()
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
                title: Text("Restore Backup?"),
                message: Text(restoreConfirmationMessage(for: backup)),
                primaryButton: .destructive(Text("Restore Backup")) {
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
        NativePanel(title: "Access & Policy", systemImage: "switch.2", tint: agentAccessMode == "full" ? .red : .blue) {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    TrustPresetButton(title: "Safe", subtitle: "Read only", systemImage: "lock", tint: .green) {
                        applyTrustPreset(.safe)
                    }
                    TrustPresetButton(title: "Work Mode", subtitle: "Workspace writes", systemImage: "folder.badge.gearshape", tint: .blue) {
                        applyTrustPreset(.work)
                    }
                    TrustPresetButton(title: "Builder", subtitle: "Power tools gated", systemImage: "hammer", tint: .orange) {
                        applyTrustPreset(.builder)
                    }
                    TrustPresetButton(title: "Full Mac YOLO", subtitle: "Full Mac access", systemImage: "flame", tint: .red) {
                        applyTrustPreset(.fullMac)
                    }
                }
                if isApplyingPolicy {
                    ProgressView("Applying policy...")
                        .controlSize(.small)
                }

                Divider()

                Picker("Agent access", selection: agentAccessBinding) {
                    Text("Auto").tag("auto")
                    Text("Read").tag("read_only")
                    Text("Workspace").tag("workspace")
                    Text("Full Mac").tag("full")
                }
                .pickerStyle(.segmented)
                Text(agentAccessDetail)
                    .font(.caption)
                    .foregroundStyle(agentAccessMode == "full" ? .red : .secondary)

                DisclosureGroup("What each mode allows", isExpanded: $showPolicyMap) {
                    PolicyMapView(policy: appModel.trustPolicy, activeMode: agentAccessMode)
                        .padding(.top, 8)
                }

                Divider()

                Picker("Permission level", selection: $permissionLevel) {
                    Text("Balanced").tag("balanced")
                    Text("Strict").tag("strict")
                    Text("Wide Open With Receipts").tag("wide_open_receipts")
                    Text("Full Mac YOLO").tag("full_mac_os")
                }
                Picker("Autonomy", selection: $autonomyDefault) {
                    Text("Supervised").tag("supervised")
                    Text("Autonomous App Data").tag("app_data_autonomous")
                    Text("Autonomous Workspaces").tag("workspace_autonomous")
                }
                HStack {
                    Toggle("Backup before workspace writes", isOn: $requireBackups)
                    EffectTimingTag(timing: .nextRun)
                    Spacer()
                }
                Picker("Outside workspaces", selection: $outsideDefault) {
                    Text("Deny").tag("deny")
                    Text("Ask").tag("ask")
                    Text("Allow").tag("allow")
                }
                HStack {
                    Toggle("Developer Mode", isOn: developerModeBinding)
                        .padding(.top, 8)
                        .disabled(savingDeveloperMode)
                    EffectTimingTag(timing: .restart)
                        .padding(.top, 8)
                    Spacer()
                }
                Text("Saves immediately; restart NativeAgent to apply. Operator-only escalation for destructive/system-level actions, including shell, system control, and file move/trash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if savingDeveloperMode {
                    ProgressView("Saving Developer Mode…")
                        .controlSize(.small)
                }
                HStack {
                    // PATCH-2026-05-06: bug-2 guard wide-open / outside-allow with confirmation alert
                    Button("Save Policy", systemImage: "checkmark.shield") {
                        // Full Mac and outside-Mac write permission require explicit confirmation.
                        let needsConfirm = (permissionLevel == "wide_open_receipts" || permissionLevel == "full_mac_os" || outsideDefault == "allow")
                        if needsConfirm {
                            pendingPermissionLevel = permissionLevel
                            pendingOutsideDefault = outsideDefault
                            showFullMacAlert = true
                        } else {
                            Task {
                                if permissionLevel == "full_mac_os" {
                                    await appModel.saveAgentAccessMode("full", developerMode: developerMode)
                                } else {
                                    await appModel.saveTrustPolicy(
                                        permissionLevel: permissionLevel,
                                        autonomyDefault: autonomyDefault,
                                        requireBackups: requireBackups,
                                        outsideDefault: outsideDefault,
                                        developerMode: developerMode
                                    )
                                }
                            }
                        }
                    }
                    .alert("Enable Full Mac access?", isPresented: $showFullMacAlert) {
                        Button("Enable Full Mac", role: .destructive) {
                            confirmPendingFullMacPolicy()
                        }
                        Button("Cancel", role: .cancel) {
                            cancelPendingFullMacPolicy()
                        }
                    } message: {
                        Text("The agent will be able to read and modify files outside workspaces across app surfaces. Shell, system control, and file move/trash still require Developer Mode.")
                    }
                    Button("Create Backup", systemImage: "externaldrive.badge.timemachine") {
                        Task { await appModel.createBackup(reason: "manual Trust Center backup") }
                    }
                }
            }
        }
    }

    // MARK: - Feature permission grouping (2026-07-22 trust-tighten)

    private func featureGroup<Content: View>(
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(NativeAgentFont.section)
                .foregroundStyle(tint)
            content()
        }
        .padding(NativeAgentSpacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(tint.opacity(0.05), in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
    }

    // MARK: - Advanced group (2026-07-22 trust-tighten: power-user panels
    // collapsed by default; styling mirrors the Advanced Mac Control
    // disclosure in MacControlPermissionsView for consistency).

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvancedTrust) {
            VStack(alignment: .leading, spacing: 16) {
                safetyBoundariesPanel
                privacyMapPanel
                simulatorPanel
                backupsPanel
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced")
                        .font(NativeAgentFont.section)
                    Text("Safety boundaries, privacy map, policy simulator, and backups.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(NativeAgentSpacing.lg)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var safetyBoundariesPanel: some View {
        NativePanel(title: "Safety Boundaries", systemImage: "exclamationmark.shield", tint: .orange) {
            TrustBoundaryRow(
                title: "Self-improvement",
                detail: "Automatic improvement writes inside NativeAgent-owned data and worktree paths. User-directed computer work uses the Trust Center workspace policy.",
                systemImage: "wand.and.stars"
            )
            TrustBoundaryRow(
                title: "Runnable tools",
                detail: "Generated tools stay proposed until validation passes. Failed or risky tools can be quarantined without loading them into every prompt.",
                systemImage: "hammer"
            )
            TrustBoundaryRow(
                title: "Receipts",
                detail: "Chat context, tool decisions, backups, and repair checks leave local receipts so the app can explain what happened later.",
                systemImage: "doc.text.magnifyingglass"
            )
        }
    }

    private var privacyMapPanel: some View {
        NativePanel(title: "Privacy Map", systemImage: "map") {
            if let root = appModel.trustPolicy?.appDataRoot ?? appModel.privacyMap?.dataRoot {
                // ui-taste-sweep 2026-06-07: was exposing the full
                // /Users/<home>/Library/... path. Tildify it; raw
                // path lives in tooltip for power users.
                Text(UserDisplayFormatters.tildifyPath(root))
                    .font(NativeAgentFont.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(root)
            }
            if let map = appModel.privacyMap {
                Text("Generated \(map.generatedAt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(map.categories) { category in
                    PrivacyCategoryRow(category: category)
                }
            } else {
                Text("Privacy map has not loaded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var simulatorPanel: some View {
        NativePanel(title: "Simulator", systemImage: "play.circle") {
            HStack {
                TextField("Path", text: $simulationPath)
                    .textFieldStyle(.roundedBorder)
                Button("Simulate Write", systemImage: "play.circle") {
                    Task { await appModel.simulatePolicy(action: "file_write", path: simulationPath) }
                }
            }
            if let simulation = appModel.policySimulation {
                HStack {
                    Label(
                        simulation.allowed ? (simulation.requiresApproval ? "Allowed With Approval" : "Allowed") : "Denied",
                        systemImage: simulation.allowed ? "checkmark.circle" : "xmark.octagon"
                    )
                    .foregroundStyle(simulation.allowed ? .green : .red)
                    StatusBadge(text: "Risk \(simulation.risk)", status: simulation.risk)
                }
                ForEach(simulation.reasons, id: \.self) { reason in
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var backupsPanel: some View {
        NativePanel(title: "Backups", systemImage: "externaldrive.badge.timemachine") {
            if appModel.backups.isEmpty {
                NativeEmptyState(
                    title: "No Backups Yet",
                    detail: "Manual and pre-write backups will appear here.",
                    systemImage: "externaldrive",
                    actionTitle: nil,
                    actionImage: nil,
                    action: nil
                )
                .frame(minHeight: 180)
            } else {
                ForEach(appModel.backups.prefix(8)) { backup in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(backup.reason)
                                .font(.subheadline.weight(.semibold))
                            Text("\(UserDisplayFormatters.humanizeISOTimestamp(backup.createdAt)) · \(backup.scope.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        if restoringBackupID == backup.id {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Restoring backup")
                        }
                        Button("Restore", systemImage: "arrow.counterclockwise") {
                            pendingRestore = backup
                        }
                        .disabled(restoringBackupID != nil)
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }

    private func restoreConfirmationMessage(for backup: BackupRecord) -> String {
        let scopes = backup.scope.isEmpty ? "no recorded scopes" : backup.scope.joined(separator: ", ")
        return "Reason: \(backup.reason)\nDate: \(backup.createdAt)\nAffected scopes: \(scopes)\n\nCurrent data in those scopes will be overwritten. NativeAgent will create a pre-restore safety backup before changing current data."
    }

    private func beginRestore(_ backup: BackupRecord) {
        guard restoringBackupID == nil else { return }
        restoringBackupID = backup.id
        Task { @MainActor in
            await appModel.restoreBackup(backup)
            restoringBackupID = nil
        }
    }

    private var agentAccessDetail: String {
        switch agentAccessMode {
        case "read_only":
            return "Read-only blocks writes and Mac Control. Use for inspection-only chats."
        case "workspace":
            return "Workspace mode allows workspace writes and safe Mac/iOS control, while outside-Mac writes still stay denied."
        case "full":
            return "Full Mac allows outside-workspace file access and Mac app control across surfaces. Shell, system control, and file move/trash require Developer Mode."
        default:
            return "Auto reads by default and escalates to workspace access only when the message clearly needs writes."
        }
    }

    private var agentAccessBinding: Binding<String> {
        Binding(
            get: { agentAccessMode },
            set: { newValue in
                setAgentAccessModeFromUser(newValue)
            }
        )
    }

    private var developerModeBinding: Binding<Bool> {
        Binding(
            get: { developerMode },
            set: { newValue in
                setDeveloperModeFromUser(newValue)
            }
        )
    }

    private func applyPolicy(_ policy: TrustPolicy) {
        isApplyingPolicy = true
        defer { isApplyingPolicy = false }
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

    private func fullMacGrantIsActive(_ policy: TrustPolicy) -> Bool {
        AppModel.fullMacGrantIsActive(policy)
    }

    private func tolerantISO8601Date(from value: String) -> Date? {
        AppModel.tolerantISO8601Date(from: value)
    }

    private func setAgentAccessModeFromUser(_ newValue: String) {
        guard !isApplyingPolicy else { return }
        let normalized = AppModel.normalizedAgentAccessMode(newValue)
        if normalized == "full" {
            if appModel.trustPolicy.map({ accessMode(from: $0) == "full" }) == true {
                agentAccessMode = "full"
                if appModel.chatFileAccess != "full" {
                    appModel.chatFileAccess = "full"
                }
                return
            }
            let prior = appModel.trustPolicy.map { accessMode(from: $0) } ?? AppModel.normalizedAgentAccessMode(appModel.chatFileAccess)
            agentAccessMode = prior == "full" ? "auto" : prior
            pendingPermissionLevel = "full_mac_os"
            pendingOutsideDefault = "allow"
            showFullMacAlert = true
            return
        }
        agentAccessMode = normalized
        Task { @MainActor in
            await appModel.saveAgentAccessMode(normalized)
            if let policy = appModel.trustPolicy {
                applyPolicy(policy)
            }
        }
    }

    private func setDeveloperModeFromUser(_ enabled: Bool) {
        guard !isApplyingPolicy else { return }
        developerMode = enabled
        savingDeveloperMode = true
        Task { @MainActor in
            do {
                let savedPolicy = try await appModel.client.saveDeveloperMode(enabled)
                appModel.applySavedTrustPolicy(
                    savedPolicy,
                    status: enabled
                        ? "Developer Mode saved. Restart NativeAgent to apply."
                        : "Developer Mode turned off. Restart NativeAgent to apply."
                )
            } catch {
                if developerMode == enabled {
                    developerMode = appModel.trustPolicy?.developerMode ?? false
                }
                appModel.statusText = "Developer Mode save failed: \(error.localizedDescription)"
            }
            savingDeveloperMode = false
        }
    }

    private func confirmPendingFullMacPolicy() {
        if pendingPermissionLevel == "full_mac_os" {
            let destructiveMode = developerMode
            agentAccessMode = "full"
            permissionLevel = "full_mac_os"
            autonomyDefault = "workspace_autonomous"
            requireBackups = false
            outsideDefault = "allow"
            developerMode = destructiveMode
            appModel.chatFileAccess = "full"
            Task { @MainActor in
                await appModel.saveAgentAccessMode("full", developerMode: destructiveMode)
                if let policy = appModel.trustPolicy {
                    applyPolicy(policy)
                }
            }
        } else {
            Task { @MainActor in
                await appModel.saveTrustPolicy(
                    permissionLevel: pendingPermissionLevel,
                    autonomyDefault: autonomyDefault,
                    requireBackups: requireBackups,
                    outsideDefault: pendingOutsideDefault,
                    developerMode: developerMode
                )
                if let policy = appModel.trustPolicy {
                    applyPolicy(policy)
                }
            }
        }
    }

    private func cancelPendingFullMacPolicy() {
        if let policy = appModel.trustPolicy {
            applyPolicy(policy)
        } else {
            agentAccessMode = AppModel.normalizedAgentAccessMode(appModel.chatFileAccess)
            permissionLevel = "balanced"
            outsideDefault = "deny"
        }
        pendingPermissionLevel = permissionLevel
        pendingOutsideDefault = outsideDefault
    }

    private func applyTrustPreset(_ preset: TrustPolicyPreset) {
        isApplyingPolicy = true
        switch preset {
        case .safe:
            agentAccessMode = "read_only"
            permissionLevel = "strict"
            autonomyDefault = "supervised"
            requireBackups = true
            outsideDefault = "deny"
            developerMode = false
        case .work:
            agentAccessMode = "workspace"
            permissionLevel = "balanced"
            autonomyDefault = "workspace_autonomous"
            requireBackups = true
            outsideDefault = "deny"
            developerMode = false
        case .builder:
            agentAccessMode = "workspace"
            permissionLevel = "balanced"
            autonomyDefault = "workspace_autonomous"
            requireBackups = true
            outsideDefault = "ask"
            developerMode = false
        case .fullMac:
            agentAccessMode = appModel.trustPolicy.map { accessMode(from: $0) } ?? AppModel.normalizedAgentAccessMode(appModel.chatFileAccess)
            permissionLevel = "full_mac_os"
            autonomyDefault = "workspace_autonomous"
            requireBackups = false
            outsideDefault = "allow"
            developerMode = false
            pendingPermissionLevel = "full_mac_os"
            pendingOutsideDefault = "allow"
            isApplyingPolicy = false
            showFullMacAlert = true
            return
        }
        let selectedMode = agentAccessMode
        isApplyingPolicy = false
        Task {
            if selectedMode == "full" || preset == .safe || preset == .work {
                await appModel.saveAgentAccessMode(selectedMode, developerMode: false)
            } else {
                await appModel.saveTrustPolicy(
                    permissionLevel: permissionLevel,
                    autonomyDefault: autonomyDefault,
                    requireBackups: requireBackups,
                    outsideDefault: outsideDefault,
                    developerMode: developerMode
                )
            }
            if let policy = appModel.trustPolicy {
                applyPolicy(policy)
            }
        }
    }
}

private enum TrustPolicyPreset {
    case safe
    case work
    case builder
    case fullMac
}

// MARK: - Full Mac session panel (2026-06-10)
//
// Renders, top to bottom:
//   1. LIVE expiry line (always visible, no hover needed) — "Full Mac
//      active — expires in 2h 13m" / "expires never" / "EXPIRED 3h ago —
//      reconfirm to restore file tools". Refreshes every minute via
//      TimelineView. Computed from the SAME fields the catalog-sweep gate
//      reads (FullMacExpiry mirrors MacControlGate.fullMacActive read-only).
//   2. Visible "Full Mac duration" label + segmented picker with exactly
//      four options (4 hours / 24 hours / 48 hours / Never expires).
//      Selection writes fullMacMaxDurationHours + fullMacNeverExpires
//      through the same trust-write chokepoint as every other save.
//   3. "Reconfirm Full Mac" button — stamps fullMacConfirmedAt as now via
//      the EXISTING saveAgentAccessMode("full") path (behind the same
//      destructive-confirmation alert the other Full Mac entry points use),
//      then re-applies the duration selection against the fresh stamp.
private struct FullMacSessionPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var showReconfirmAlert = false

    var body: some View {
        let policy = appModel.trustPolicy
        let state = FullMacExpiry.state(policy)
        NativePanel(title: "Full Mac Session", systemImage: "clock.badge.exclamationmark", tint: panelTint(state)) {
            VStack(alignment: .leading, spacing: 10) {
                // 1. Live expiry line — visible without hovering.
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    let liveState = FullMacExpiry.state(policy, now: timeline.date)
                    Label(
                        FullMacExpiry.statusLine(liveState, now: timeline.date),
                        systemImage: statusIcon(liveState)
                    )
                    .font(NativeAgentFont.section)
                    .foregroundStyle(statusColor(liveState, now: timeline.date))
                }

                // 2. Duration picker with an explicit, always-visible label
                // (taste gate: no anonymous segmented control).
                Text("Full Mac duration")
                    .font(.subheadline.weight(.semibold))
                Picker("Full Mac duration", selection: durationBinding) {
                    ForEach(FullMacDurationOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden() // label rendered explicitly above
                Text("Counted from the last Full Mac confirmation. When the window closes, file tools are swept from the agent's catalog until you reconfirm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // 3. Reconfirm — restamps fullMacConfirmedAt as now.
                HStack {
                    Button(reconfirmTitle(state), systemImage: "arrow.clockwise.circle") {
                        showReconfirmAlert = true
                    }
                    .disabled(policy == nil)
                    EffectTimingTag(timing: .now)
                    Spacer()
                }
            }
        }
        .alert("Reconfirm Full Mac access?", isPresented: $showReconfirmAlert) {
            Button("Reconfirm Full Mac", role: .destructive) {
                reconfirmFullMac()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restarts the Full Mac window from now using the selected duration. The agent keeps outside-workspace file access and Mac app control until the window closes.")
        }
    }

    private var durationBinding: Binding<FullMacDurationOption> {
        Binding(
            get: { FullMacDurationOption.from(appModel.trustPolicy) },
            set: { option in
                Task { @MainActor in
                    await appModel.saveFullMacDuration(option)
                }
            }
        )
    }

    /// Stamp fullMacConfirmedAt = now through the EXISTING confirm path,
    /// then re-apply the duration selection so Never / 48h survive the
    /// stamp write (saveAgentAccessMode("full") resets neverExpires and
    /// clears expiresAt; the follow-up restores them against the fresh
    /// confirmation stamp).
    private func reconfirmFullMac() {
        let option = FullMacDurationOption.from(appModel.trustPolicy)
        let developerMode = appModel.trustPolicy?.developerMode ?? false
        Task { @MainActor in
            await appModel.saveAgentAccessMode("full", developerMode: developerMode)
            await appModel.saveFullMacDuration(option)
        }
    }

    private func reconfirmTitle(_ state: FullMacExpiryState) -> String {
        switch state {
        case .off: return "Confirm Full Mac Now"
        default: return "Reconfirm Full Mac"
        }
    }

    private func panelTint(_ state: FullMacExpiryState) -> Color {
        switch state {
        case .expired, .unreadable: return .red
        case .active, .never: return .orange
        case .off: return .blue
        }
    }

    private func statusIcon(_ state: FullMacExpiryState) -> String {
        switch state {
        case .never: return "infinity.circle"
        case .active: return "clock.badge.checkmark"
        case .expired, .unreadable: return "exclamationmark.octagon.fill"
        case .off: return "circle.slash"
        }
    }

    private func statusColor(_ state: FullMacExpiryState, now: Date) -> Color {
        switch state {
        case .expired, .unreadable:
            return .red
        case .active(let expiresAt):
            return expiresAt.timeIntervalSince(now) <= FullMacExpiry.warningWindow
                ? .orange : .green
        case .never:
            return .green
        case .off:
            return .secondary
        }
    }
}

private struct TrustPresetButton: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(NativeAgentFont.section)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(NativeAgentSpacing.md)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// 2026-07-22 trust-tighten: no longer wraps itself in a NativePanel — it
// renders as plain rows inside the Access & Policy panel's "What each mode
// allows" disclosure.
private struct PolicyMapView: View {
    var policy: TrustPolicy?
    var activeMode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PolicyMapRow(mode: "auto", title: "Auto", activeMode: activeMode, files: "read", shell: false, macControl: policy?.macControlPolicy?.enabled == true, iosRemote: false, autonomy: "supervised")
            PolicyMapRow(mode: "read_only", title: "Read", activeMode: activeMode, files: "read", shell: false, macControl: false, iosRemote: false, autonomy: "supervised")
            PolicyMapRow(mode: "workspace", title: "Workspace", activeMode: activeMode, files: "workspace", shell: policy?.macControlPolicy?.shellAllowed == true, macControl: policy?.macControlPolicy?.enabled == true, iosRemote: policy?.macControlPolicy?.remoteFromIosAllowed == true, autonomy: "workspace")
            PolicyMapRow(mode: "full", title: "Full Mac", activeMode: activeMode, files: "all", shell: policy?.macControlPolicy?.shellAllowed == true, macControl: policy?.macControlPolicy?.enabled == true, iosRemote: policy?.macControlPolicy?.remoteFromIosAllowed == true, autonomy: "full")
        }
    }
}

private struct PolicyMapRow: View {
    var mode: String
    var title: String
    var activeMode: String
    var files: String
    var shell: Bool
    var macControl: Bool
    var iosRemote: Bool
    var autonomy: String

    private var isActive: Bool { AppModel.normalizedAgentAccessMode(activeMode) == mode }
    private var tint: Color { mode == "full" ? .red : (isActive ? .blue : .secondary) }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Label(title, systemImage: isActive ? "largecircle.fill.circle" : "circle")
                    .font(NativeAgentFont.section)
                    .foregroundStyle(tint)
                    .gridColumnAlignment(.leading)
                policyChip(files, systemImage: "folder")
                policyChip(shell ? "shell" : "no shell", systemImage: "terminal", enabled: shell)
                policyChip(macControl ? "mac" : "no mac", systemImage: "macbook", enabled: macControl)
                policyChip(iosRemote ? "iOS" : "no iOS", systemImage: "iphone", enabled: iosRemote)
                policyChip(autonomy, systemImage: "wand.and.stars")
            }
        }
        .padding(10)
        .background(isActive ? tint.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
    }

    private func policyChip(_ text: String, systemImage: String, enabled: Bool = true) -> some View {
        Label(text, systemImage: systemImage)
            .font(NativeAgentFont.tag)
            .foregroundStyle(enabled ? .primary : .secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((enabled ? tint : Color.secondary).opacity(0.10), in: Capsule())
    }
}
