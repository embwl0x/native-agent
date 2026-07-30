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

struct ConnectorsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var workspaceName = ""
    @State private var workspacePath = ""
    @State private var workspaceWritable = false
    @State private var workspaceQuery = ""
    // PATCH-2026-05-07: connector-wizard-b ConnectorWizard sheet per card
    @State private var wizardPresentation = ConnectorWizardPresentationState()
    @State private var connectorStatusMessage = ""
    @State private var isAddingWorkspace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                if !connectorStatusMessage.isEmpty {
                    Section {
                        Text(connectorStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Registry") {
                    ForEach(registryRowsForDisplay) { connector in
                        let uiState = connectorUIState(connector)
                        let actionPolicy = connectorActionPolicy(connector)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(connector.name)
                                    .font(.headline)
                                Spacer()
                                Text(statusText(for: connector, uiState: uiState))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(uiState.statusColor)
                            }
                            Text(connector.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                                            await appModel.updateConnector(connector, enabled: !connector.enabled)
                                            connectorStatusMessage = appModel.statusText
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
                    ForEach(appModel.workspaceSearchResults.prefix(8)) { result in
                        Text("\(result.workspaceName ?? "Workspace") · \(result.relativePath)")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
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

        if await appModel.addWorkspace(name: name, path: path, writable: writable) {
            workspaceName = ""
            workspacePath = ""
            workspaceWritable = false
            connectorStatusMessage = "Workspace added"
        } else {
            connectorStatusMessage = appModel.statusText
        }
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
            connectorStatusMessage = "Opening Visible Browser…"
            Task { @MainActor in
                await appModel.showVisibleBrowser()
                connectorStatusMessage = "Visible Browser is open. The assistant can navigate, read text, inspect links, and capture screenshots through browser actions."
            }
        case .openTelegramSettings:
            NativeAgentAppCoordinator.shared.request(.sidebar(.telegram))
        case .openWizard(let provider):
            wizardPresentation.present(provider: provider)
        }
    }
}
