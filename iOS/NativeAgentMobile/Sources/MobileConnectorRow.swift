import SwiftUI

struct MobileConnectorRow: View {
    let connector: ConnectorRecord
    @EnvironmentObject private var pairingStore: PairingStore
    @ObservedObject private var bridge = iCloudBridge.shared
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @State private var recovered: ConnectorRecord?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showEnable = false
    @State private var showDisconnect = false

    private var row: ConnectorRecord { recovered ?? connector }
    private var canSend: Bool {
        pairingStore.isICloudSigned && bridge.available && bridgeClient.bridgeStatus != .deviceOffline
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
                    enabled: row.enabled, status: row.authState ?? row.status, healthStatus: row.healthStatus
                ).displayText)
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
        .onChange(of: connector) { _, snapshot in
            guard let recovered else { return }
            // An older snapshot cannot undo a signed owner receipt. Once the
            // snapshot catches up, it owns this row again, including Mac edits.
            if (snapshot.enabled == recovered.enabled && snapshot.authState == recovered.authState)
                || (snapshot.updatedAt ?? "") > (recovered.updatedAt ?? "") {
                self.recovered = nil
            }
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
                    recovered = try await iCloudSyncEngine.shared.setConnectorEnabled(id: connector.id, enabled: enabled)
                } else {
                    recovered = try await iCloudSyncEngine.shared.disconnectConnector(id: connector.id)
                }
            } catch {
                saveError = "Could not change \(connector.name): \(error.localizedDescription)"
            }
        }
    }
}
