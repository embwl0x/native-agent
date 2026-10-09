import AppToolRuntime
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
import ChatOrchestration
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
import TrustCenter
#endif

/// The Advanced tab's backup read. Keep unavailable/stale data
/// distinguishable from a legitimately empty backup history.
enum TrustCenterAdvancedDisclosurePresentation {
    enum ReadState: Equatable {
        case loading
        case available
        case stale
        case unavailable
    }

    struct State: Equatable {
        let backups: ReadState
    }

    static func resolve(
        backupCount: Int,
        hasRefreshAttempt: Bool,
        failedEndpoints: [String]
    ) -> State {
        let failures = Set(failedEndpoints.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return State(
            backups: readState(
                hasContent: backupCount > 0,
                hasRefreshAttempt: hasRefreshAttempt,
                failed: failures.contains("backups")
            )
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
        // FULL MAC IS THE FENCE, NOT THE DEVELOPER-MODE ROW. Turning Full Mac on
        // from the Mac Control page saves the access mode without a developer
        // mode, so `developerMode` stayed false and this matcher — which
        // required it true — fell through to "Custom · Full Mac access" on the
        // Trust card and in the chat header. Developer mode has its own row and
        // is its own axis; what makes this posture Full Mac is the permission
        // level plus writes allowed outside the workspace.
        let fullMac = TrustPolicyPreset.fullMac.plan
        if accessMode == fullMac.agentAccessMode,
           policy.permissionLevel == fullMac.permissionLevel,
           (policy.filePolicy?.outsideWorkspaceDefault ?? "deny") == fullMac.outsideDefault {
            return .fullMac
        }
        return TrustPolicyPreset.allCases.first {
            guard $0 != .fullMac else { return false }
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

/// The Trust page's tabs (Fluid Glass plan, 2026-10-04: one page of about
/// thirteen sections became tabs). Each raw value is the key `TrustRailPage`
/// stores; the first keeps "trust" so a remembered tab still lands.
enum TrustTab: String, CaseIterable {
    case access = "trust"
    case features
    case macAndBrowser = "control"
    case advanced
}

struct TrustCenterView: View {
    /// The tab on show. Nil is every section in one column, for the hosts
    /// with no tab row (Simple view's Trust card, Settings).
    private let tab: TrustTab?
    /// Mac control's unsaved edits, held by the tab row's page so a tab
    /// switch does not throw them away.
    private let macControlDraft: Binding<TrustMacControlPolicy?>?
    @Environment(AppModel.self) private var appModel
    @State private var agentAccessMode = "auto"
    @State private var permissionLevel = "balanced"
    @State private var autonomyDefault = "supervised"
    @State private var requireBackups = true
    @State private var outsideDefault = "deny"
    // PATCH-2026-05-06: bug-2 full-mac friction alert state
    @State private var showFullMacAlert = false
    // PATCH-2026-05-06: dev-mode local binding mirrors trustPolicy.developerMode
    @State private var developerMode = false
    @State private var isApplyingPolicy = false
    @State private var pendingRestore: BackupRecord?
    @State private var restoringBackupID: String?

    init(tab: TrustTab? = nil, macControlDraft: Binding<TrustMacControlPolicy?>? = nil) {
        self.tab = tab
        self.macControlDraft = macControlDraft
    }

    private func shows(_ section: TrustTab) -> Bool { tab == nil || tab == section }


    var body: some View {
        ScrollView {
            // Permission sections contain native controls and multiline text.
            // Measure them as they enter the viewport instead of repeatedly
            // laying out the entire long page on every scroll update.
            LazyVStack(alignment: .leading, spacing: 24) {
                if shows(.access) {
                    // Sweep R4 C10 (2026-08-06): the summary is derived — a
                    // pure function of `appModel.engine.trust.policy` plus the
                    // access mode this page resolved, so it cannot drift from
                    // the switches. Read-only: it renders no controls.
                    accessAndPolicyPanel
                    TrustGuardrailSummaryPanel(accessMode: appModel.engine.trust.policy.map { accessMode(from: $0) } ?? "auto")
                    NativeSecurityCenterPanel(modeTitle: activePreset?.title)
                    // A remote agent is never the person: the grant it asks
                    // for is per-peer, and it is the only switch that can raise
                    // an inbound peer off the restricted agent-bridge surface.
                    AgentPeerTrustView()
                }

                if shows(.features) {
                    // One eyebrow over one group card per feature. The
                    // unattended gate is read fresh on every tick
                    // (BackgroundLoopsAssembly.unattendedWorkAllowed), so
                    // nothing here waits for a restart.
                    ForEach(TrustFeaturePermissionCards.all.filter { $0.id != .chromeControl }) { card in
                        AdvancedSection(title: card.title, card: .bare) {
                            card.content()
                        }
                    }
                    Text("Background work picks up a change the next time it runs. Everything else applies right away, with no restart.")
                        .font(ShellType.rowDetail)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // W8 (2026-08-14): the only feature that records what the
                    // person does when they are not talking to me, with its
                    // honest limits on title redaction, so its own panel.
                    ActivityCapturePermissionsView()
                }

                if shows(.macAndBrowser) {
                    // On the rail this is Trust's one Mac tab
                    // (MacIntegrationView, with the per-app grants); here it
                    // serves the hosts with no tab row.
                    AdvancedSection(title: "Chrome control") {
                        ChromeControlPermissionsView()
                    }
                    MacControlPermissionsView(draft: macControlDraft)
                }

                if shows(.advanced) {
                    safetyBoundariesPanel
                    privacyMapPanel
                    backupsPanel
                }

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
        .quietReadTask {
            if let policy = appModel.engine.trust.policy {
                applyPolicy(policy)
            }
            if shows(.advanced) { await appModel.refreshPrivacyMap() }
        }
        .onChange(of: appModel.engine.trust.policy) { _, newPolicy in
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
        // The radios and their status line sit in one card, like every
        // other control on Trust; loose above the next card they floated.
        AdvancedSection(title: "Access and policy", card: .single) {
            VStack(alignment: .leading, spacing: 12) {
                // The Mac's own radio group (User 09-27: all controls native).
                Picker("Access", selection: Binding<TrustPolicyPreset?>(
                    get: { activePreset },
                    set: { if let preset = $0 { applyTrustPreset(preset) } }
                )) {
                    ForEach(TrustPolicyPreset.allCases, id: \.quietID) { preset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                            Text(preset.summary)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 3)
                        .tag(Optional(preset))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(isApplyingPolicy || appModel.engine.trust.policy == nil)
                HStack(spacing: 8) {
                    if isApplyingPolicy {
                        ProgressView().controlSize(.small)
                    }
                    Text(isApplyingPolicy ? "Saving access…" : policyStatusLine)
                        .font(ShellType.labelSemibold)
                        .foregroundStyle(NativeAgentShell.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 16, alignment: .leading)
                // "Back up now" lives on the "If I get something wrong" row of
                // What I can do right now, where it says what it copies.
            }
            .alert(
                MobileTrustAction.fullMacTitle,
                isPresented: $showFullMacAlert
            ) {
                Button(MobileTrustAction.fullMacButton, role: .destructive) {
                    confirmPendingFullMacPolicy()
                }
                Button("Cancel", role: .cancel) {
                    cancelPendingFullMacPolicy()
                }
            } message: {
                Text(MobileTrustAction.fullMacMessage)
            }
        }
    }

    private var policyStatusLine: String {
        TrustCenterPolicyStatusPresentation.line(
            policy: appModel.engine.trust.policy,
            accessMode: appModel.engine.trust.policy.map { accessMode(from: $0) },
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
        guard let policy = appModel.engine.trust.policy,
              appModel.panelRefreshStatus[.trust]?.failedEndpoints.contains("trust policy") != true else { return nil }
        return TrustCenterPolicyStatusPresentation.preset(policy: policy, accessMode: accessMode(from: policy))
    }

    // MARK: - Feature permission grouping (2026-07-22 trust-tighten)

    // MARK: - Advanced tab: safety boundaries, privacy map and backups.

    private var advancedPresentation: TrustCenterAdvancedDisclosurePresentation.State {
        let refresh = appModel.panelRefreshStatus[.trust]
        return TrustCenterAdvancedDisclosurePresentation.resolve(
            backupCount: appModel.engine.trust.backups.count,
            hasRefreshAttempt: refresh != nil,
            failedEndpoints: refresh?.failedEndpoints ?? []
        )
    }

    private var safetyBoundariesPanel: some View {
        AdvancedSection(title: "Safety boundaries", card: .single) {
            let state = TrustSafetyBoundariesPresentation.state(
                policy: appModel.engine.trust.policy,
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
        PrivacyMapPanel(privacyMap: appModel.privacyMap)
    }

    private var backupsPanel: some View {
        AdvancedSection(title: "Backups", card: .single) {
            if advancedPresentation.backups == .loading {
                Text("Loading backups…")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            } else if advancedPresentation.backups == .unavailable || advancedPresentation.backups == .stale {
                Text(appModel.engine.trust.backups.isEmpty
                     ? "Backups could not be loaded. Reopen Trust to try again."
                     : "Showing the last loaded backups. Reopen Trust to check for changes.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if appModel.engine.trust.backups.isEmpty, advancedPresentation.backups == .available {
                Text("No backups yet. Backups made here, and the ones taken before a workspace write, will be listed with their date and what they covered.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !appModel.engine.trust.backups.isEmpty {
                ForEach(appModel.engine.trust.backups.prefix(8)) { backup in
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
            agentAccessMode = appModel.engine.trust.policy.map { accessMode(from: $0) }
                ?? AppModel.normalizedAgentAccessMode(appModel.chatFileAccess)
            showFullMacAlert = true
        case .applied(let policy):
            applyPolicy(policy)
        case .failed:
            if let policy = appModel.engine.trust.policy {
                applyPolicy(policy)
            }
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
        let roots: [String]
        let categories: [Category]
    }

    enum State: Equatable {
        case pending
        case loaded(Loaded)
    }

    /// The roots head the paths listed under them: the data root the map was
    /// read from, then any category kept outside it (Persona lives beside
    /// the data folder, not in it).
    static func resolve(privacyMap: PrivacyMap?) -> State {
        guard let privacyMap else { return .pending }
        return .loaded(Loaded(
            roots: roots(privacyMap),
            categories: privacyMap.categories.map(Category.init(source:))
        ))
    }

    private static func roots(_ map: PrivacyMap) -> [String] {
        let data = (map.dataRoot as NSString).standardizingPath
        var roots = [map.dataRoot]
        for category in map.categories {
            let path = (category.path as NSString).standardizingPath
            guard path != data, !path.hasPrefix(data + "/"), !roots.contains(category.path) else { continue }
            roots.append(category.path)
        }
        return roots
    }
}

struct PrivacyMapPanel: View {
    let privacyMap: PrivacyMap?

    private var presentation: PrivacyMapPanelPresentation.State {
        PrivacyMapPanelPresentation.resolve(privacyMap: privacyMap)
    }

    var body: some View {
        AdvancedSection(title: "Privacy map", card: .single) {
            switch presentation {
            case .pending:
                Text("The privacy map has not loaded yet. It lists what I keep on this Mac and which of it can leave.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .loaded(let map):
                ForEach(map.roots, id: \.self) { root in
                    Text(UserDisplayFormatters.tildifyPath(root))
                        .font(ShellType.code)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(root)
                }
                // The map is read when the page is, so it carries no age.
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
/// owns the whole preset write — every axis in ONE patch — and refuses to
/// enter Full Mac without the explicit confirmation transition.
///
/// The single patch is the fence, not a tidy-up: separate access-mode,
/// autonomy and trust-policy writes leave gaps in which a person's downgrade
/// lands and is then overwritten by the rest of an in-flight preset write.
/// `guardedByLockedPolicy` lets a caller (the agent's own self-admin path)
/// check the locked generation inside the merge, so a posture that changed
/// underneath it refuses instead of applying.
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
        fullMacConfirmed: Bool = false,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async -> Outcome {
        let plan = preset.plan
        if case .confirmationRequired = TrustPolicyPresetTransition.request(preset), !fullMacConfirmed {
            return .confirmationRequired(plan)
        }

        let policy: TrustPolicy
        do {
            policy = try await NativeClient.saveTrustPreset(
                preset,
                dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                fullMacConfirmed: fullMacConfirmed,
                guardedByLockedPolicy: guardedByLockedPolicy
            )
        } catch {
            let detail = UserFacingError.message(error, action: "apply that trust preset")
            appModel.recordTrustActionFailure(detail)
            return .failed(detail)
        }
        appModel.applySavedTrustPolicy(
            policy, status: "Trust preset saved: \(preset.title)")
        appModel.chatFileAccess = AppModel.normalizedAgentAccessMode(plan.agentAccessMode)
        // Only the two-phase presets reloaded the rest of the app after their
        // trust-policy write; keep that, now that the write is one patch.
        if plan.commit == .accessModeThenTrustPolicy {
            await appModel.refreshAll()
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
struct TrustFold<Label: View, Trailing: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var label: Label
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The Mac's own disclosure (User 09-27: all controls native).
        DisclosureGroup(isExpanded: $isExpanded) {
            content
                .padding(.top, 12)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label
                Spacer(minLength: 8)
                trailing
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

// MARK: - Connected agents

/// The person's per-peer elevation grant — the ONLY thing that lets an inbound
/// agent-to-agent turn run with the authority of a turn the person took
/// themselves. Off for every peer until they say otherwise, here, by hand.
///
/// This is a Trust panel rather than a Connectors row on purpose: the question
/// it asks is not "is this peer configured" but "does this peer get to act as
/// me", and that is the question Trust Center exists to answer.
struct AgentPeerTrustView: View {
    @State private var peers: [AgentPeerContact] = []
    @State private var failure: String?
    /// Until the first read lands, "no agents" would be a guess.
    @State private var loaded = false
    /// Reads can finish out of order; only the newest one applies.
    @State private var reloadGeneration = 0

    private var store: AgentPeerStore { AgentPeerStore(dataRoot: NativeAgentPaths.dataRoot) }

    var body: some View {
        // An eyebrow over one group card, a hairline per peer.
        AdvancedSection(title: "Connected agents") {
            Text("Other agents can ask me for help. Anything that needs your permission comes to you as an approval request. Turning an agent on lets its requests use your existing permissions. Agents that connect over the network each need their own credential.")
                .font(ShellType.rowDetail)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if loaded && peers.isEmpty {
                Text("No agents are connected.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            } else {
                ForEach(peers, id: \.id) { peer in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(peer.name)
                                .font(ShellType.rowTitle)
                                .foregroundStyle(NativeAgentShell.text)
                            Text("\(Self.via(peer)) · \(peer.credentialKey == nil ? "no credential, so it can't be turned on" : "has its own credential")")
                                .font(ShellType.rowDetail)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Toggle(peer.name, isOn: binding(for: peer))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .hazeTinted()
                            .disabled(peer.credentialKey == nil)
                            .accessibilityIdentifier("trust.agent-peer.\(peer.id)")
                    }
                }
            }
            if let failure {
                Text(failure)
                    .font(ShellType.rowDetail)
                    .foregroundStyle(TrustTone.trouble.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The first file event is the appear read; Dot's readiness is asked
        // once, after it, when Dot is one of the peers.
        .task {
            let events = FileChangeEvents(paths: [store.fileURL], emitInitial: true)
            var askedDot = false
            await withTaskCancellationHandler {
                for await _ in events.stream {
                    if Task.isCancelled { break }
                    await reload()
                    if !askedDot, peers.contains(where: ChatGPTDotIPCTransport.owns) {
                        askedDot = true
                        let root = NativeAgentPaths.dataRoot
                        await Task.detached(priority: .userInitiated) {
                            _ = await SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false).chatGPTDotReadiness()
                        }.value
                        await reload()
                    }
                }
            } onCancel: { events.cancel() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ChatGPTDotIPCTransport.didChange)) { _ in
            Task { await reload() }
        }
    }

    /// How a peer reaches me, in words a person uses (the Simple view's words).
    private static func via(_ peer: AgentPeerContact) -> String {
        if AgentPeerStore.hostRowID(peer.endpoint).flatMap({ AgentHostDirectory.row(named: $0)?.format }) == .shellEnvironment {
            return ChatGPTDotIPCTransport.detail
        }
        return switch peer.transport {
        case .a2a: "Over the network (A2A)"
        case .nativeAgent: "Another NativeAgent"
        case .desktop: "Desktop app on this Mac"
        case .desktopChat: "Desktop app, through its chat window"
        case .mcpHost: "Through its settings on this Mac (MCP)"
        case .acp: "Runs on this Mac"
        case .grokBot: "Routine, replies come back here"
        }
    }

    private func binding(for peer: AgentPeerContact) -> Binding<Bool> {
        Binding(
            get: { peer.elevationAllowed },
            set: { allowed in
                do {
                    _ = try store.setElevation(peerID: peer.id, allowed: allowed)
                    failure = nil
                } catch {
                    failure = UserFacingError.message(error, action: "save that change")
                }
                Task { await reload() }
            }
        )
    }

    /// peers.json is read under its lock: off the main actor.
    private func reload() async {
        let store = store
        reloadGeneration += 1
        let generation = reloadGeneration
        let read = await Task.detached(priority: .userInitiated) {
            Result { try store.list().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
        }.value
        guard generation == reloadGeneration else { return }
        switch read {
        case .success(let list):
            peers = list
        case .failure(let error):
            peers = []
            failure = UserFacingError.message(error, action: "read the connected agents")
        }
        loaded = true
    }
}
