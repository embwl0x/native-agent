import Foundation
import DeviceSync

/// Credential-free rows shared by the existing snapshot and mutation receipts.
struct MobileConnectorSnapshot: Encodable, Sendable {
    let id: String
    let name: String
    let kind: String
    let enabled: Bool
    let authState: String?
    let healthStatus: String?
    let updatedAt: String?
    let canToggle: Bool
    let canDisconnect: Bool
    let supportsSetup: Bool

    static let credentialProviders: Set<String> = ["github", "slack", "notion", "gmail", "gcal", "x"]

    init(_ row: ConnectorRecord) {
        id = row.id
        name = row.name
        kind = row.kind
        enabled = row.enabled
        authState = row.authState
        healthStatus = row.healthStatus
        updatedAt = row.updatedAt
        let policy = ConnectorRowActionPolicy.resolve(id: row.id, authState: row.authState, healthStatus: row.healthStatus)
        canToggle = policy.showsEnabledMutation
        supportsSetup = Self.credentialProviders.contains(row.id)
        canDisconnect = supportsSetup && ["connected", "configured", "connected_unverified"].contains(row.authState ?? "")
    }
}

extension AppDeviceSyncHost {
    func mobileConnectors() async throws -> [MobileConnectorSnapshot] {
        try await NativeClient(baseURL: "").getConnectors().map(MobileConnectorSnapshot.init)
    }

    func setConnectorEnabled(id: String, enabled: Bool) async throws -> DeviceSyncSnapshotRows {
        let api = NativeClient(baseURL: "")
        guard let current = try await mobileConnectors().first(where: { $0.id == id }), current.canToggle else {
            throw connectorFailure("This connector is controlled by its setup on the Mac.")
        }
        _ = try await api.updateConnector(id: id, enabled: enabled)
        guard let recovered = try await mobileConnectors().first(where: { $0.id == id }),
              recovered.enabled == enabled else {
            throw connectorFailure("The Mac could not confirm the connector change. Refresh before trying again.")
        }
        return recovered
    }

    func disconnectConnector(id: String) async throws -> DeviceSyncSnapshotRows {
        guard MobileConnectorSnapshot.credentialProviders.contains(id),
              try await mobileConnectors().contains(where: { $0.id == id }) else {
            throw connectorFailure("This connector cannot be disconnected here.")
        }
        try await NativeClient(baseURL: "").revokeConnector(provider: id)
        guard let recovered = try await mobileConnectors().first(where: { $0.id == id }),
              !recovered.enabled, recovered.authState == "not_connected" else {
            throw connectorFailure("The Mac could not confirm disconnection. Refresh before trying again.")
        }
        return recovered
    }

    private func connectorFailure(_ message: String) -> NSError {
        NSError(domain: "NativeAgentConnectorMutation", code: -409, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
