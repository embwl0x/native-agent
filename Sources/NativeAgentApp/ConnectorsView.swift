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

enum ConnectorUIState: Equatable {
    case live
    case ready
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

    var statusColor: Color {
        switch self {
        case .live, .ready:
            return .green
        case .planned:
            return .blue
        case .needsAuth, .comingSoon, .unknown:
            return .secondary
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
                primaryTitle: state == .live ? "Manage" : "Configure",
                primaryAction: .openTelegramSettings,
                showsEnabledMutation: false
            )
        }
        let verifiedWizard = ConnectorWizardSetupRoute.resolve(provider: id) != .unavailable
        if verifiedWizard,
           state == .needsAuth || state == .planned || state == .live || state == .comingSoon {
            return Self(
                primaryTitle: (state == .needsAuth || state == .comingSoon) ? "Connect" : "Reconnect",
                primaryAction: .openWizard(provider: id),
                showsEnabledMutation: state == .live
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
        VStack(alignment: .leading, spacing: 12) {
            List {
                if let connectorStatusMessage {
                    Section {
                        Text(connectorStatusMessage.text)
                            .font(.caption)
                            .foregroundStyle(statusColor(for: connectorStatusMessage.tone))
                    }
                }

                Section("Registry") {
                    ForEach(registryRowsForDisplay) { connector in
                        let uiState = connectorUIState(connector)
                        let actionPolicy = connectorActionPolicy(connector)
                        let renderedStatusText = statusText(for: connector, uiState: uiState)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(connector.name)
                                    .font(.headline)
                                Spacer()
                                Text(renderedStatusText)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(uiState.statusColor)
                            }
                            Text(connector.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let runtimeStatus = connector.runtimeStatus,
                               !runtimeStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                let runtimeLabel: String = if let detail = connector.runtimeDetail {
                                    "Socket Mode: \(runtimeStatus) · \(detail)"
                                } else {
                                    "Socket Mode: \(runtimeStatus)"
                                }
                                let runtimeConnected = runtimeStatus == "connected"
                                Label(
                                    runtimeLabel,
                                    systemImage: runtimeConnected ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle"
                                )
                                .font(.caption)
                                .foregroundStyle(runtimeConnected ? Color.secondary : Color.orange)
                            }
                            HStack {
                                Label(connector.kind, systemImage: "tag")
                                Label(connector.riskClass ?? "standard", systemImage: "exclamationmark.shield")
                                Label(connector.enabled ? "Enabled" : "Disabled", systemImage: connector.enabled ? "checkmark.circle" : "circle")
                                Spacer()
                                if let primaryTitle = actionPolicy.primaryTitle {
                                    Button(primaryTitle) {
                                        handleConnectorAction(actionPolicy.primaryAction)
                                    }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                    .disabled(actionPolicy.primaryAction == nil)
                                }
                                if actionPolicy.showsEnabledMutation {
                                    Button(connector.enabled ? "Disable" : "Enable", systemImage: connector.enabled ? "pause.circle" : "play.circle") {
                                        Task {
                                            let outcome = await appModel.updateConnector(connector, enabled: !connector.enabled)
                                            connectorStatusMessage = ConnectorsStatusMessagePresentation.connectorUpdate(
                                                connectorName: connector.name,
                                                enabled: !connector.enabled,
                                                outcome: outcome
                                            )
                                        }
                                    }
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("File Workspaces") {
                    ForEach(appModel.workspaces) { workspace in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(workspace.name)
                                .font(.subheadline.weight(.semibold))
                            Text(workspace.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(workspace.permissions.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            GroupBox("Add Workspace") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name", text: $workspaceName)
                    TextField("Path", text: $workspacePath)
                    Toggle("Allow writes", isOn: $workspaceWritable)
                    Button(isAddingWorkspace ? "Adding…" : "Add Workspace", systemImage: isAddingWorkspace ? "hourglass" : "folder.badge.plus") {
                        Task { await addWorkspace() }
                    }
                    .disabled(isAddingWorkspace || cleanWorkspaceName.isEmpty || cleanWorkspacePath.isEmpty)
                }
            }

            GroupBox("Workspace Search") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Search", text: $workspaceQuery)
                        Button("Search", systemImage: "magnifyingglass") {
                            Task { await appModel.searchWorkspace(workspaceQuery) }
                        }
                        .disabled(workspaceQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    let searchPresentation = WorkspaceSearchPresentation.make(results: appModel.workspaceSearchResults)
                    ForEach(searchPresentation.visible) { result in
                        Text("\(result.workspaceName ?? "Workspace") · \(result.relativePath)")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if searchPresentation.remainingCount > 0 {
                        Text("\(searchPresentation.remainingCount) more matches — refine your search to narrow the list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
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
        case .planned: return 2
        case .needsAuth: return 3
        case .comingSoon: return 4
        case .unknown: return 5
        }
    }

    private func statusText(for connector: ConnectorRecord, uiState: ConnectorUIState) -> String {
        let health = connector.healthStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
        let auth = connector.authState?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch uiState {
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
        case .progress: return .secondary
        case .success: return NativeAgentTheme.ok
        case .failure: return NativeAgentTheme.warn
        }
    }
}
