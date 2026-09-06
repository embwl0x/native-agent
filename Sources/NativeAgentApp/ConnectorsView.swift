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
import Connectors
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

enum ConnectorUIState: Equatable {
    case live
    case ready
    /// Credential present, but no successful connector call has proven it
    /// inside the decay window (`ConnectorHealthDecay`). Never green — a
    /// sign-in that once completed is not evidence the integration works now.
    case unverified
    case planned
    case needsAuth
    case comingSoon
    case unknown

    static func resolve(authState: String?, healthStatus: String?) -> Self {
        let auth = authState?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let health = healthStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if auth == "coming_soon" || health == "coming_soon" {
            return .comingSoon
        }
        // Decay wins over the auth claim: a row can be `connected`/`configured`
        // and still be unproven, and that must not read as live.
        if health == ConnectorHealthDecay.unverifiedHealth {
            return .unverified
        }
        if auth == "connected" || auth == "configured" || health == "ok" {
            return .live
        }
        if health == "ready" {
            return auth == "planned" ? .planned : .ready
        }
        if auth == "not_required" {
            return .ready
        }
        if auth == "connected_unverified"
            || auth == "not_connected"
            || auth == "needs_auth"
            || health == "needs_auth"
            || health == "needs_probe"
            || health == "needs_permission"
            || health == "probe_needed" {
            return .needsAuth
        }
        return .unknown
    }

    /// Only two things on this page are tinted: something working (calm) and
    /// something that needs attention (trouble). Everything else is quiet.
    var statusColor: Color {
        switch self {
        case .live, .ready:
            return NativeAgentShell.calm
        case .unverified:
            return NativeAgentShell.trouble
        case .planned, .needsAuth, .comingSoon, .unknown:
            return NativeAgentShell.secondary
        }
    }
}

enum ConnectorPrimaryAction: Equatable {
    case showBrowser
    case openTelegramSettings
    case openWizard(provider: String)
}

struct ConnectorRowActionPolicy: Equatable {
    var primaryTitle: String?
    var primaryAction: ConnectorPrimaryAction?
    var showsEnabledMutation: Bool

    static func resolve(
        id rawID: String,
        authState: String?,
        healthStatus: String?
    ) -> Self {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let state = ConnectorUIState.resolve(authState: authState, healthStatus: healthStatus)

        if id == "browser" {
            return Self(primaryTitle: "Show Browser", primaryAction: .showBrowser, showsEnabledMutation: false)
        }
        if id == "telegram" {
            return Self(
                primaryTitle: (state == .live || state == .unverified) ? "Manage" : "Configure",
                primaryAction: .openTelegramSettings,
                showsEnabledMutation: false
            )
        }
        let verifiedWizard = ConnectorWizardSetupRoute.resolve(provider: id) != .unavailable
        if verifiedWizard,
           state == .needsAuth || state == .planned || state == .live
            || state == .unverified || state == .comingSoon {
            // An unverified row still holds a credential, so its route is
            // Reconnect (re-prove it), not Connect (start from nothing).
            return Self(
                primaryTitle: (state == .needsAuth || state == .comingSoon) ? "Connect" : "Reconnect",
                primaryAction: .openWizard(provider: id),
                showsEnabledMutation: state == .live || state == .unverified
            )
        }

        // Local connectors have no separate setup wizard. Local File
        // Workspaces' enabled bit is consumed by connector-action readiness;
        // the other runtime-derived rows are display-only here.
        if id == "local_files" {
            return Self(primaryTitle: nil, primaryAction: nil, showsEnabledMutation: true)
        }
        return Self(primaryTitle: nil, primaryAction: nil, showsEnabledMutation: false)
    }
}

struct ConnectorWizardPresentationState: Equatable {
    private(set) var provider: String?

    var isPresented: Bool {
        provider != nil
    }

    mutating func present(provider rawProvider: String) {
        let normalized = rawProvider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard ConnectorWizardSetupRoute.resolve(provider: normalized) != .unavailable else {
            provider = nil
            return
        }
        provider = normalized
    }

    mutating func dismiss() {
        provider = nil
    }
}

struct WorkspaceSearchPresentation: Equatable {
    let visible: [WorkspaceSearchResult]
    let remainingCount: Int

    static func make(results: [WorkspaceSearchResult], limit: Int = 8) -> Self {
        Self(visible: Array(results.prefix(limit)), remainingCount: max(0, results.count - limit))
    }
}

/// Status copy belongs to the connector operation that produced it, not to
/// AppModel's shared status line (which unrelated background work can replace
/// before this view renders it).
enum ConnectorsStatusMessagePresentation {
    enum Tone: Equatable {
        case progress
        case success
        case failure
    }

    struct Message: Equatable {
        let text: String
        let tone: Tone
    }

    static func connectorUpdate(
        connectorName: String,
        enabled: Bool,
        outcome: ConnectorUpdateOutcome
    ) -> Message {
        switch outcome {
        case .verified(let connector):
            let name = nonempty(connector.name, fallback: connectorName)
            return Message(
                text: "\(name) is \(connector.enabled ? "enabled" : "disabled").",
                tone: .success
            )
        case .failed(let detail):
            return Message(
                text: "Could not \(enabled ? "enable" : "disable") \(nonempty(connectorName, fallback: "connector")): \(nonempty(detail, fallback: "the connector registry did not confirm the change"))",
                tone: .failure
            )
        }
    }

    static func workspaceAdd(name: String, writable: Bool, outcome: WorkspaceAddOutcome) -> Message {
        switch outcome {
        case .verified(let workspace):
            return Message(
                text: "Added \(nonempty(workspace.name, fallback: name)) with \(writable ? "read and write" : "read-only") access.",
                tone: .success
            )
        case .failed(let detail):
            return Message(
                text: "Could not add \(nonempty(name, fallback: "workspace")): \(nonempty(detail, fallback: "the workspace was not saved"))",
                tone: .failure
            )
        }
    }

    static func browserOpening() -> Message {
        Message(text: "Opening Visible Browser…", tone: .progress)
    }

    static func browserOpened() -> Message {
        Message(text: "Visible Browser opened. The assistant can use browser actions in that window.", tone: .success)
    }

    private static func nonempty(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }
}

enum ConnectorUpdateOutcome: Equatable {
    case verified(ConnectorRecord)
    case failed(String)
}

enum WorkspaceAddOutcome: Equatable {
    case verified(WorkspaceRecord)
    case failed(String)
}

struct ConnectorsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var workspaceName = ""
    @State private var workspacePath = ""
    @State private var workspaceWritable = false
    @State private var workspaceQuery = ""
    // PATCH-2026-05-07: connector-wizard-b ConnectorWizard sheet per card
    @State private var wizardPresentation = ConnectorWizardPresentationState()
    @State private var connectorStatusMessage: ConnectorsStatusMessagePresentation.Message?
    @State private var isAddingWorkspace = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let connectorStatusMessage {
                    ConnectorsNote(
                        text: connectorStatusMessage.text,
                        color: statusColor(for: connectorStatusMessage.tone)
                    )
                }

                ConnectorsSection(label: "Accounts") {
                    if registryRowsForDisplay.isEmpty {
                        ConnectorsCard {
                            ConnectorsNote(
                                text: "The accounts the agent can read and write will be listed here. Refresh to load them.",
                                color: NativeAgentShell.secondary
                            )
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(registryRowsForDisplay) { connector in
                                connectorRow(connector)
                            }
                        }
                    }
                }

                ConnectorsSection(label: "Folders the agent may open") {
                    if appModel.workspaces.isEmpty {
                        ConnectorsCard {
                            ConnectorsNote(
                                text: "No folder is shared yet. Add one below and the agent can read the files in it.",
                                color: NativeAgentShell.secondary
                            )
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(appModel.workspaces) { workspace in
                                ConnectorsCard {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(workspace.name)
                                            .font(ShellType.bodySemibold)
                                            .foregroundStyle(NativeAgentShell.text)
                                        Text(workspace.path)
                                            .font(ShellType.label)
                                            .foregroundStyle(NativeAgentShell.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(workspace.permissions.joined(separator: ", "))
                                            .font(ShellType.caption)
                                            .foregroundStyle(NativeAgentShell.tertiary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }

                ConnectorsSection(label: "Share a folder") {
                    ConnectorsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            ConnectorsField(title: "Name") {
                                TextField("", text: $workspaceName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(ShellType.label)
                            }
                            ConnectorsField(title: "Folder") {
                                TextField("", text: $workspacePath)
                                    .textFieldStyle(.roundedBorder)
                                    .font(ShellType.label)
                            }
                            Toggle("Let the agent write to it", isOn: $workspaceWritable)
                                .font(ShellType.label)
                            Button(isAddingWorkspace ? "Adding…" : "Share this folder") {
                                Task { await addWorkspace() }
                            }
                            .buttonStyle(.bordered)
                            .font(ShellType.labelMedium)
                            .disabled(isAddingWorkspace || cleanWorkspaceName.isEmpty || cleanWorkspacePath.isEmpty)
                        }
                    }
                }

                ConnectorsSection(label: "Search the shared folders") {
                    ConnectorsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                TextField("", text: $workspaceQuery)
                                    .textFieldStyle(.roundedBorder)
                                    .font(ShellType.label)
                                Button("Search") {
                                    Task { await appModel.searchWorkspace(workspaceQuery) }
                                }
                                .buttonStyle(.bordered)
                                .font(ShellType.labelMedium)
                                .disabled(workspaceQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            let searchPresentation = WorkspaceSearchPresentation.make(results: appModel.workspaceSearchResults)
                            if searchPresentation.visible.isEmpty {
                                ConnectorsNote(
                                    text: "Matching files from the shared folders will be listed here.",
                                    color: NativeAgentShell.secondary
                                )
                            } else {
                                ForEach(searchPresentation.visible) { result in
                                    Text("\(result.workspaceName ?? "Folder") · \(result.relativePath)")
                                        .font(ShellType.label)
                                        .foregroundStyle(NativeAgentShell.text)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                }
                                if searchPresentation.remainingCount > 0 {
                                    ConnectorsNote(
                                        text: "\(searchPresentation.remainingCount) more matches. Narrow the search to see them.",
                                        color: NativeAgentShell.secondary
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 32)
        }
        .navigationTitle("Connectors")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await appModel.refreshForSidebarItem(.connectors) }
            }
        }
        // PATCH-2026-05-07: connector-wizard-b Sheet for ConnectorWizardView
        .sheet(
            isPresented: Binding(
                get: { wizardPresentation.isPresented },
                set: { isPresented in
                    if !isPresented {
                        wizardPresentation.dismiss()
                    }
                }
            )
        ) {
            if let provider = wizardPresentation.provider {
                ConnectorWizardView(provider: provider) {
                    wizardPresentation.dismiss()
                }
                .environment(appModel)
            }
        }
    }

    /// One account: what it is called, how it stands, what it is for, and the
    /// one or two things you can do to it.
    @ViewBuilder
    private func connectorRow(_ connector: ConnectorRecord) -> some View {
        let uiState = connectorUIState(connector)
        let actionPolicy = connectorActionPolicy(connector)
        let renderedStatusText = Self.statusText(for: connector, uiState: uiState)
        ConnectorsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(connector.name)
                        .font(ShellType.bodySemibold)
                        .foregroundStyle(NativeAgentShell.text)
                    Spacer(minLength: 8)
                    Text(renderedStatusText)
                        .font(ShellType.captionSemibold)
                        .foregroundStyle(uiState.statusColor)
                }
                Text(connector.description)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let runtimeStatus = connector.runtimeStatus,
                   !runtimeStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let runtimeLabel: String = if let detail = connector.runtimeDetail {
                        "Live connection: \(runtimeStatus) · \(detail)"
                    } else {
                        "Live connection: \(runtimeStatus)"
                    }
                    let runtimeConnected = runtimeStatus == "connected"
                    Text(runtimeLabel)
                        .font(ShellType.caption)
                        .foregroundStyle(runtimeConnected ? NativeAgentShell.secondary : NativeAgentShell.trouble)
                }
                HStack(spacing: 12) {
                    Text(connector.kind)
                    Text(connector.riskClass ?? "standard")
                    Text(connector.enabled ? "On" : "Off")
                    Spacer(minLength: 8)
                    if let primaryTitle = actionPolicy.primaryTitle {
                        Button(primaryTitle) {
                            handleConnectorAction(actionPolicy.primaryAction)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(actionPolicy.primaryAction == nil)
                    }
                    if actionPolicy.showsEnabledMutation {
                        Button(connector.enabled ? "Turn off" : "Turn on") {
                            Task {
                                let outcome = await appModel.updateConnector(connector, enabled: !connector.enabled)
                                connectorStatusMessage = ConnectorsStatusMessagePresentation.connectorUpdate(
                                    connectorName: connector.name,
                                    enabled: !connector.enabled,
                                    outcome: outcome
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cleanWorkspaceName: String {
        workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanWorkspacePath: String {
        workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func addWorkspace() async {
        guard !isAddingWorkspace, !cleanWorkspaceName.isEmpty, !cleanWorkspacePath.isEmpty else { return }
        let name = cleanWorkspaceName
        let path = cleanWorkspacePath
        let writable = workspaceWritable
        isAddingWorkspace = true
        defer { isAddingWorkspace = false }

        let outcome = await appModel.addWorkspaceWithReceipt(name: name, path: path, writable: writable)
        if case .verified = outcome {
            workspaceName = ""
            workspacePath = ""
            workspaceWritable = false
        }
        connectorStatusMessage = ConnectorsStatusMessagePresentation.workspaceAdd(
            name: name,
            writable: writable,
            outcome: outcome
        )
    }

    private var registryRowsForDisplay: [ConnectorRecord] {
        appModel.connectors.sorted { lhs, rhs in
            let lhsRank = connectorDisplayRank(lhs)
            let rhsRank = connectorDisplayRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.enabled != rhs.enabled { return lhs.enabled && !rhs.enabled }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func connectorUIState(_ connector: ConnectorRecord) -> ConnectorUIState {
        ConnectorUIState.resolve(authState: connector.authState, healthStatus: connector.healthStatus)
    }

    private func connectorDisplayRank(_ connector: ConnectorRecord) -> Int {
        switch connectorUIState(connector) {
        case .live: return 0
        case .ready: return 1
        case .unverified: return 2
        case .planned: return 3
        case .needsAuth: return 4
        case .comingSoon: return 5
        case .unknown: return 6
        }
    }

    /// Pure projection of a record + its resolved state into the row's status
    /// copy. `nonisolated` so the rendering rule is assertable without a view.
    nonisolated static func statusText(
        for connector: ConnectorRecord,
        uiState: ConnectorUIState
    ) -> String {
        let health = connector.healthStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
        let auth = connector.authState?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch uiState {
        case .unverified:
            // "configured, unverified" — a credential is on file and nothing
            // has proven it. Anything else decayed from a proven state.
            return auth?.lowercased() == ConnectorHealthDecay.configuredAuth
                ? "configured, unverified"
                : ConnectorHealthDecay.unverifiedHealth
        case .planned:
            if let health, !health.isEmpty {
                return "planned / \(health)"
            }
            return "planned"
        case .ready:
            return health?.isEmpty == false ? health! : "ready"
        case .comingSoon:
            return "coming soon"
        case .live, .needsAuth, .unknown:
            return health?.isEmpty == false ? health! : (auth?.isEmpty == false ? auth! : "unknown")
        }
    }

    private func connectorActionPolicy(_ connector: ConnectorRecord) -> ConnectorRowActionPolicy {
        ConnectorRowActionPolicy.resolve(
            id: connector.id,
            authState: connector.authState,
            healthStatus: connector.healthStatus
        )
    }

    private func handleConnectorAction(_ action: ConnectorPrimaryAction?) {
        guard let action else { return }
        switch action {
        case .showBrowser:
            connectorStatusMessage = ConnectorsStatusMessagePresentation.browserOpening()
            Task { @MainActor in
                await appModel.showVisibleBrowser()
                connectorStatusMessage = ConnectorsStatusMessagePresentation.browserOpened()
            }
        case .openTelegramSettings:
            NativeAgentAppCoordinator.shared.request(.sidebar(.telegram))
        case .openWizard(let provider):
            wizardPresentation.present(provider: provider)
        }
    }

    private func statusColor(for tone: ConnectorsStatusMessagePresentation.Tone) -> Color {
        switch tone {
        case .progress: return NativeAgentShell.secondary
        case .success: return NativeAgentShell.calm
        case .failure: return NativeAgentShell.trouble
        }
    }
}

// MARK: - Page kit
//
// The page's own small vocabulary: an eyebrow over a run, the card a row or a
// group of controls sits in, and the two quiet line shapes.

private struct ConnectorsSection<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(ShellType.labelSemibold)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(NativeAgentShell.secondary)
            content
        }
    }
}

private struct ConnectorsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
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

private struct ConnectorsNote: View {
    let text: String
    var color: Color = NativeAgentShell.secondary

    var body: some View {
        Text(text)
            .font(ShellType.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct ConnectorsField<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ShellType.labelMedium)
                .foregroundStyle(NativeAgentShell.secondary)
            control
        }
    }
}
