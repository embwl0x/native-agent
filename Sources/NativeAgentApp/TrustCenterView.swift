import BackgroundWork
import TrustPersistence
import AppToolRuntime
import Privacy
import AgentConversations
import SwiftUI
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `TrustCenterView.swift` | `TrustCenterView`; confirmation states a normal backup is kept before scope replacement, failure replaces nothing, and previous-life work stays stopped until fresh Resume |

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
        let tone: TrustTone
    }

    static func state(for outcome: TrustCenterActionOutcome) -> State {
        switch outcome {
        case .saved(let text):
            State(
                label: "Latest Trust action",
                text: bounded(text),
                badgeText: "Saved",
                tone: .calm
            )
        case .failed(let text):
            State(
                label: "Latest Trust action",
                text: bounded(text),
                badgeText: "Failed",
                tone: .trouble
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
    static func line(
        policy: TrustPolicy?, accessMode: String?,
        isApplying: Bool = false, needsConfirmation: Bool = false,
        policyReadFailed: Bool = false
    ) -> String {
        guard !policyReadFailed, let policy else { return "Effective access unavailable · Reload Trust to check saved policy" }
        let access: String
        let matched = MobileTrustAction.Preset.matching(policy: policy, accessMode: accessMode)
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
        // Full Mac remains active until the person changes it.
        if matched == .fullMac, state == "Saved" {
            return "\(access) · \(state) · stays on until you change it"
        }
        return "\(access) · \(state)"
    }
}

/// Raw values are persisted TrustRailPage keys; the first remains "trust" for saved selections.
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
    @Environment(AppModel.self) private var appModel
    @State private var showFullMacAlert = false
    @State private var isApplyingPolicy = false
    @State private var pendingRestore: BackupRecord?
    @State private var restoringBackupID: String?

    init(tab: TrustTab? = nil) {
        self.tab = tab
    }

    private func shows(_ section: TrustTab) -> Bool { tab == nil || tab == section }


    var body: some View {
        ScrollView {
            // Permission sections contain native controls and multiline text.
            // Measure them as they enter the viewport instead of repeatedly
            // laying out the entire long page on every scroll update.
            LazyVStack(alignment: .leading, spacing: 24) {
                if shows(.access) {
                    // The read-only summary derives from the loaded Trust policy.
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
                    // (WorkshopBackgroundWork.unattendedWorkAllowed), so
                    // nothing here waits for a restart.
                    AdvancedSection(title: "Multimodal", card: .bare) {
                        MultimodalPermissionsView()
                    }
                    AdvancedSection(title: "Self-Improvement", card: .bare) {
                        TrainingPermissionsView()
                    }
                    AdvancedSection(title: "Desk Autonomy", card: .bare) {
                        WorkshopPermissionsView()
                    }
                    AdvancedSection(title: "Living Memory", card: .bare) {
                        AliveGroupCard(waiting: appModel.engine.memory.proposals.contains { $0.status == "pending" }) {
                            LivingMemoryPermissionsView()
                        }
                    }
                    Text("Background work picks up a change the next time it runs. Everything else applies right away, with no restart.")
                        .font(ShellType.rowDetail)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Activity recording has its own panel to state title-redaction limits.
                    ActivityCapturePermissionsView()
                }

                if shows(.macAndBrowser) {
                    // On the rail this is Trust's one Mac tab
                    // (MacIntegrationView, with the per-app grants); here it
                    // serves the hosts with no tab row.
                    AdvancedSection(title: "Chrome control") {
                        ChromeControlPermissionsView()
                    }
                    MacControlPermissionsView()
                }

                if shows(.advanced) {
                    privacyMapPanel
                    backupsPanel
                }

                if let outcome = appModel.trustCenterActionOutcome {
                    let status = TrustCenterActionPresentation.state(for: outcome)
                    HStack(alignment: .top, spacing: 8) {
                        TrustStatusChip(text: status.badgeText, tone: status.tone)
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
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Trust")
        .task { await appModel.engine.trust.observeSecurity() }
        .quietReadTask {
            if let policy = appModel.engine.trust.policy {
                applyPolicy(policy)
            }
            if shows(.advanced) { await appModel.engine.trust.refreshPrivacyMap() }
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

    // MARK: - Access & Policy

    private var accessAndPolicyPanel: some View {
        // The radios and their status line sit in one card, like every
        // other control on Trust; loose above the next card they floated.
        AdvancedSection(title: "Access and policy", card: .single) {
            VStack(alignment: .leading, spacing: 12) {
                // Trust postures use the Mac's native radio group.
                Picker("Access", selection: Binding<MobileTrustAction.Preset?>(
                    get: { activePreset },
                    set: { if let preset = $0 { applyTrustPreset(preset) } }
                )) {
                    ForEach(MobileTrustAction.Preset.allCases, id: \.rawValue) { preset in
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
                if appModel.engine.trust.policy == nil || appModel.panelRefreshStatus[.trust]?.failedEndpoints.contains("trust policy") == true {
                    Button("Preserve damaged policy and authorize Safe") {
                        isApplyingPolicy = true
                        Task { @MainActor in
                            defer { isApplyingPolicy = false }
                            do {
                                let policy = try await SwiftNativeTrustCenter(dataRoot: appModel.engine.dataRoot).reauthorizeSafePolicy()
                                appModel.engine.trust.publishPolicy(policy)
                                applyPolicy(policy)
                                appModel.statusText = "The damaged policy was preserved beside trust/policy.json. Safe is now authorized; choose any further access here."
                            } catch {
                                appModel.statusText = UserFacingError.message(error, action: "reauthorize Safe access")
                            }
                        }
                    }
                    .disabled(isApplyingPolicy)
                }
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
            isApplying: isApplyingPolicy,
            needsConfirmation: showFullMacAlert,
            policyReadFailed: appModel.panelRefreshStatus[.trust]?.failedEndpoints.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "trust policy"
            } == true
        )
    }

    private var activePreset: MobileTrustAction.Preset? {
        guard let policy = appModel.engine.trust.policy,
              appModel.panelRefreshStatus[.trust]?.failedEndpoints.contains("trust policy") != true else { return nil }
        return MobileTrustAction.Preset.matching(policy: policy, accessMode: accessMode(from: policy))
    }

    // MARK: - Advanced tab: safety boundaries, privacy map and backups.

    private var advancedPresentation: TrustCenterAdvancedDisclosurePresentation.State {
        let refresh = appModel.panelRefreshStatus[.trust]
        return TrustCenterAdvancedDisclosurePresentation.resolve(
            backupCount: appModel.engine.trust.backups.count,
            hasRefreshAttempt: refresh != nil,
            failedEndpoints: refresh?.failedEndpoints ?? []
        )
    }

    private var privacyMapPanel: some View {
        PrivacyMapPanel(privacyMap: appModel.engine.trust.privacyMap)
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
        return "Reason: \(backup.reason)\nDate: \(created)\nAffected scopes: \(scopes)\n\nNativeAgent will first keep a normal backup of current data before replacing these scopes. If that backup cannot be written, nothing will be replaced. Only selected readable current data needed for continuity will be carried forward. Work from the previous life stays stopped; Resume starts it fresh."
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
        let agentAccessMode = accessMode(from: policy)
        if appModel.chatFileAccess != agentAccessMode {
            appModel.chatFileAccess = agentAccessMode
        }
    }

    private func accessMode(from policy: TrustPolicy) -> String {
        TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy, fallback: appModel.chatFileAccess)
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
        showFullMacAlert = false
    }

    private func applyTrustPreset(_ preset: MobileTrustAction.Preset) {
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
            guard NativeAgentWorkspaceRoot.relativePath(path, under: data) == nil, !roots.contains(category.path) else { continue }
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
    typealias Outcome = MobileTrustAction.Preset.Outcome

    static func apply(
        _ preset: MobileTrustAction.Preset,
        appModel: AppModel,
        fullMacConfirmed: Bool = false,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async -> Outcome {
        let plan = preset.plan
        let policy: TrustPolicy
        do {
            let outcome = try await preset.apply(
                dataRoot: appModel.firstRunDataRoot,
                fullMacConfirmed: fullMacConfirmed,
                guardedByLockedPolicy: guardedByLockedPolicy
            )
            guard case .applied(let savedPolicy) = outcome else { return outcome }
            policy = savedPolicy
        } catch {
            let detail = UserFacingError.message(error, action: "apply that trust preset")
            appModel.recordTrustActionFailure(detail)
            return .failed(detail)
        }
        appModel.applySavedTrustPolicy(
            policy, status: "Trust preset saved: \(preset.title)")
        appModel.chatFileAccess = TrustAccessModeCapabilityCatalog.normalizedMode(plan.agentAccessMode)
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


// MARK: - Page kit

/// The room tone carried by a Trust status.
enum TrustTone: Equatable {
    case calm
    case trouble
    case quiet

    var color: Color {
        switch self {
        case .calm: NativeAgentShell.calm
        case .trouble: NativeAgentShell.trouble
        case .quiet: NativeAgentShell.secondary
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

    var body: some View {
        // The Mac's native disclosure.
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

// MARK: - Connected agents

/// The person's per-peer elevation grant — the ONLY thing that lets an inbound
/// agent-to-agent turn run with the authority of a turn the person took
/// themselves. Off for every peer until they say otherwise, here, by hand.
///
/// This is a Trust panel rather than a Connectors row on purpose: the question
/// it asks is not "is this peer configured" but "does this peer get to act as
/// me", and that is the question Trust Center exists to answer.
struct AgentPeerTrustView: View {
    @Environment(AppModel.self) private var appModel
    @State private var failure: String?
    private var contacts: ContactListFacade { appModel.engine.contacts }
    private var rows: [AgentContactRow] { contacts.doors.filter { $0.contact != nil } }
    private var readFailure: String? { contacts.loadError }
    private var dataRoot: URL { appModel.engine.dataRoot }
    private var store: AgentPeerStore { AgentPeerStore(dataRoot: dataRoot) }

    var body: some View {
        // An eyebrow over one group card, a hairline per peer.
        AdvancedSection(title: "Connected agents") {
            Text("Other agents can ask me for help. Anything that needs your permission comes to you as an approval request. Your grant lets requests authenticated with this connection's own key use your existing permissions. You can always turn your grant off. Delivery is checked separately.")
                .font(ShellType.rowDetail)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if contacts.loaded && rows.isEmpty && readFailure == nil {
                Text("No agents are connected.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            } else {
                ForEach(rows) { row in
                    if let peer = row.contact {
                        let eligible = row.elevationFailure == nil
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.displayName)
                                    .font(ShellType.rowTitle)
                                    .foregroundStyle(NativeAgentShell.text)
                                Text("\(row.route)\nYour grant: \(peer.elevationAllowed ? "on" : "off") · Authority now: \(peer.elevationAllowed && eligible ? "on" : "off")\n\(row.pillWord) · \(row.status)")
                                    .font(ShellType.rowDetail)
                                    .foregroundStyle(NativeAgentShell.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let reason = row.elevationFailure {
                                    Text("Its own key isn't available, so your grant can't take effect. " + (reason.tap.map { "Fix: " + $0 } ?? "Ask me to reconnect it."))
                                        .font(ShellType.rowDetail)
                                        .foregroundStyle(TrustTone.trouble.color)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 12)
                            Toggle(peer.name, isOn: binding(for: peer))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .hazeTinted()
                                .disabled(readFailure != nil || (!peer.elevationAllowed && !eligible))
                                .accessibilityIdentifier("trust.agent-peer.\(peer.id)")
                        }
                    }
                }
            }
            if let readFailure {
                AgentContactReadFailure(message: readFailure, dataRoot: dataRoot) { Task { _ = try? await contacts.refresh() } }
            }
            if let failure {
                Text(failure)
                    .font(ShellType.rowDetail)
                    .foregroundStyle(TrustTone.trouble.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { contacts.watch() }
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
                Task { _ = try? await contacts.refresh() }
            }
        )
    }

}
