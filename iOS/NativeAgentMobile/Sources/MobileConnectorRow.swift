import SwiftUI
import NativeAgentShared
// Blueprint: | `MobileConnectorRow.swift` | Connector destination, health presentation and rows share the sync projection; connector receipts update it |

enum ConnectorHealthPresentation {
    static func resolve(
        enabled: Bool?,
        status: String? = nil,
        healthStatus: String?
    ) -> String {
        if enabled == false { return "Off" }

        if let health = normalized(healthStatus) { return word(health) }

        // Published status alone does not prove live integration health.
        if let status = normalized(status) { return "Status: \(word(status))" }
        return "Health unknown"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    /// The Mac's words for the same states (Connectors on the Mac).
    static func word(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "needs_auth", "auth_required", "needs_sign_in": return "Needs sign-in"
        case "connected", "live", "ok", "healthy", "active": return "Connected"
        case "ready": return "Ready"
        case "connecting", "starting": return "Connecting"
        case "disconnected", "offline": return "Disconnected"
        case "disabled": return "Off"
        case "failed", "error", "unavailable": return "Unavailable"
        case "unverified": return "Not checked"
        case let other: return AliveWords.humanized(other)
        }
    }

}

struct ConnectorsView: View {
    @StateObject private var store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        _store = StateObject(wrappedValue: store)
    }

    private var presentation: SettingsSnapshotContentPresentation {
        .state(
            hasContent: !store.sync.connectors.isEmpty,
            fieldAvailable: store.availableFields.contains(.connectors),
            isLoading: store.isLoading,
            hasCompletedRefresh: store.hasCompletedRefresh
        )
    }

    var body: some View {
        AlivePage(title: "Connectors", line: "The services I can reach.") {
            switch presentation {
            case .loading:
                ProgressView("Loading connectors…")
                    .tint(AlivePalette.secondary)
                    .foregroundStyle(AlivePalette.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            case .unavailable:
                AliveCalmState(
                    title: "Not here yet",
                    line: "My connectors come over from the Mac. Keep the Mac app open and try again.",
                    actionTitle: "Try again",
                    action: { Task { await store.refresh() } }
                )
            case .empty:
                AliveCalmState(
                    title: "No connectors yet",
                    line: "Connect services in the Mac app's Connectors view and they show up here."
                )
            case .content, .stale:
                AliveSection(nil) {
                    if presentation == .stale {
                        AliveNote("Connectors could not be refreshed. Showing the last known rows.")
                        AliveDivider()
                    }
                    ForEach(Array(store.sync.connectors.enumerated()), id: \.element.id) { index, connector in
                        if index > 0 { AliveDivider() }
                        MobileConnectorRow(connector: connector)
                    }
                }
            }
        }
        .task { if MobileDesignSamples.screen == nil { await store.refresh() } }
        .refreshable { await store.refresh() }
    }
}

struct MobileConnectorRow: View {
    let connector: MobileConnectorSnapshot
    @EnvironmentObject private var pairingStore: PairingStore
    @ObservedObject private var bridge = iCloudBridge.shared
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showEnable = false
    @State private var showDisconnect = false

    private var row: MobileConnectorSnapshot { connector }
    private var canSend: Bool {
        pairingStore.isICloudSigned && bridge.available && bridgeClient.deviceIsOffline != true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MobileAdaptiveRow(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).foregroundStyle(AlivePalette.text)
                    if let kind = row.kind, !kind.isEmpty {
                        Text(AliveWords.humanized(kind)).font(.footnote).foregroundStyle(AlivePalette.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(ConnectorHealthPresentation.resolve(
                    enabled: row.enabled, status: row.authState, healthStatus: row.healthStatus
                ))
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
            }
            if row.canToggle == true, let enabled = row.enabled {
                Toggle("Enabled", isOn: Binding(get: { enabled }, set: { requested in
                    if requested {
                        showEnable = true
                    } else {
                        update(enabled: false)
                    }
                }))
                    .hazeTinted()
                    .disabled(isSaving || !canSend)
                    .accessibilityLabel("\(row.name): Enabled")
            }
            if row.supportsSetup == true {
                Text("Set up on your Mac")
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
            }
            if row.canDisconnect == true {
                Button("Disconnect", role: .destructive) { showDisconnect = true }
                    .disabled(isSaving || !canSend)
            }
            if isSaving { ProgressView("Waiting for your Mac…") }
            if !canSend && (row.canToggle == true || row.canDisconnect == true) {
                Text("Connect to your paired Mac to change this connector.")
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
            }
            if let saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(NativeAgentMobileTheme.Colors.trouble)
            }
        }
        .aliveRow()
        .confirmationDialog("Enable \(row.name)?", isPresented: $showEnable, titleVisibility: .visible) {
            Button("Enable") { update(enabled: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This allows the agent to use this connector on your Mac.")
        }
        .confirmationDialog("Disconnect \(row.name)?", isPresented: $showDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { update(enabled: nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved credential and disables this connector until new credentials are saved.")
        }
    }

    private func update(enabled: Bool?) {
        guard canSend, !isSaving else { return }
        isSaving = true
        saveError = nil
        Task { @MainActor in
            defer { isSaving = false }
            do {
                if let enabled {
                    _ = try await iCloudSyncEngine.shared.setConnectorEnabled(id: connector.id, enabled: enabled)
                } else {
                    _ = try await iCloudSyncEngine.shared.disconnectConnector(id: connector.id)
                }
            } catch {
                saveError = "Could not change \(connector.name): \(error.localizedDescription)"
            }
        }
    }
}
