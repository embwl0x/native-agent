import Foundation
import Connectors
import DeviceSync
import PersistenceCore

/// Credential-free rows shared by the existing snapshot and mutation receipts.
public struct MobileConnectorSnapshot: Encodable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let enabled: Bool
    public let authState: String?
    public let healthStatus: String?
    public let updatedAt: String?
    public let canToggle: Bool
    public let canDisconnect: Bool
    public let supportsSetup: Bool

    public static let credentialProviders: Set<String> = ["github", "slack", "notion", "gmail", "gcal", "x"]

    public init(_ row: ConnectorRecord, canToggle: Bool) {
        id = row.id
        name = row.name
        kind = row.kind
        enabled = row.enabled
        authState = row.authState
        healthStatus = row.healthStatus
        updatedAt = row.updatedAt
        self.canToggle = canToggle
        supportsSetup = Self.credentialProviders.contains(row.id)
        canDisconnect = supportsSetup && ["connected", "configured", "connected_unverified"].contains(row.authState ?? "")
    }
}

extension ConnectorStatusProjection {
    public static func mobileConnectors(root: URL, platform: any ConnectorStatusPlatform, canToggle: @Sendable (ConnectorRecord) -> Bool) async throws -> [MobileConnectorSnapshot] {
        try await ConnectorStatusProjection.readConnectorRecords(
            root: root, platform: platform
        ).map { MobileConnectorSnapshot($0, canToggle: canToggle($0)) }
    }

    public static func setMobileConnectorEnabled(id: String, enabled: Bool, root: URL, platform: any ConnectorStatusPlatform, canToggle: @Sendable (ConnectorRecord) -> Bool) async throws -> DeviceSyncSnapshotRows {
        guard let current = try await mobileConnectors(root: root, platform: platform, canToggle: canToggle).first(where: { $0.id == id }), current.canToggle else {
            throw connectorFailure("This connector is controlled by its setup on the Mac.")
        }
        _ = try await ConnectorStatusProjection.updateConnector(
            id: id, enabled: enabled, root: root, platform: platform
        )
        guard let recovered = try await mobileConnectors(root: root, platform: platform, canToggle: canToggle).first(where: { $0.id == id }),
              recovered.enabled == enabled else {
            throw connectorFailure("The Mac could not confirm the connector change. Refresh before trying again.")
        }
        return recovered
    }

    public static func disconnectMobileConnector(id: String, root: URL, platform: any ConnectorStatusPlatform, canToggle: @Sendable (ConnectorRecord) -> Bool) async throws -> DeviceSyncSnapshotRows {
        guard MobileConnectorSnapshot.credentialProviders.contains(id),
              try await mobileConnectors(root: root, platform: platform, canToggle: canToggle).contains(where: { $0.id == id }) else {
            throw connectorFailure("This connector cannot be disconnected here.")
        }
        _ = try await SwiftNativeConnectorAuthClient(root: root).revokeConnector(provider: id)
        guard let recovered = try await mobileConnectors(root: root, platform: platform, canToggle: canToggle).first(where: { $0.id == id }),
              !recovered.enabled, recovered.authState == "not_connected" else {
            throw connectorFailure("The Mac could not confirm disconnection. Refresh before trying again.")
        }
        return recovered
    }

    private static func connectorFailure(_ message: String) -> NSError {
        NSError(domain: "NativeAgentConnectorMutation", code: -409, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
