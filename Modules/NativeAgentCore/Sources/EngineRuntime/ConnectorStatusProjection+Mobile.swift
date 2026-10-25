import Foundation
import Connectors
import DeviceSync
import PersistenceCore
// Blueprint: | `ConnectorStatusProjection+Mobile.swift` | Credential-free mobile rows and commands use their own checked refresh result from ConnectorStatusProjection; Mac and phone toggles share update and its checked verification; committed disconnect fences earlier reads through write before lane restart and checked verification. |

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

    public static let credentialProviders: Set<String> = ["slack"]

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
        canDisconnect = supportsSetup && ["connected", "configured", "connected_unverified", "failed"].contains(row.authState ?? "")
    }
}

extension ConnectorStatusProjection {
    @MainActor public func mobileConnectors(canToggle: @Sendable (ConnectorRecord) -> Bool) async throws -> [MobileConnectorSnapshot] {
        let checked = await refresh()
        return try checked.get().map { MobileConnectorSnapshot($0, canToggle: canToggle($0)) }
    }

    @MainActor public func setMobileConnectorEnabled(id: String, enabled: Bool, canToggle: @Sendable (ConnectorRecord) -> Bool) async throws -> DeviceSyncSnapshotRows {
        guard let current = try await mobileConnectors(canToggle: canToggle).first(where: { $0.id == id }), current.canToggle else {
            throw Self.connectorFailure("This connector is controlled by its setup on the Mac.")
        }
        guard let recovered = try await update(id: id, enabled: enabled) else {
            throw Self.connectorFailure("The Mac could not confirm the connector change. Refresh before trying again.")
        }
        return MobileConnectorSnapshot(recovered, canToggle: canToggle(recovered))
    }

    @MainActor public func disconnectMobileConnector(id: String, canToggle: @Sendable (ConnectorRecord) -> Bool) async throws -> DeviceSyncSnapshotRows {
        guard MobileConnectorSnapshot.credentialProviders.contains(id),
              try await mobileConnectors(canToggle: canToggle).contains(where: { $0.id == id }) else {
            throw Self.connectorFailure("This connector cannot be disconnected here.")
        }
        _ = try await SwiftNativeConnectorAuthClient(root: root).revokeConnector(provider: id)
        // The revoke committed. Earlier reads cannot republish its old account
        // state while the lane restarts; the checked read below publishes it.
        snapshotRead.write {}
        await Self.restartSlackLane(root: root)
        guard let recovered = try await mobileConnectors(canToggle: canToggle).first(where: { $0.id == id }),
              !recovered.enabled, recovered.authState == "not_connected" else {
            throw Self.connectorFailure("The Mac could not confirm disconnection. Refresh before trying again.")
        }
        return recovered
    }

    private static func connectorFailure(_ message: String) -> NSError {
        NSError(domain: "NativeAgentConnectorMutation", code: -409, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
