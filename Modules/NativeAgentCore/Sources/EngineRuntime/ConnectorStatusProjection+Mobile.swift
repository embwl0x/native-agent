import Foundation
import NativeAgentShared
import Connectors
import DeviceSync
import PersistenceCore
// Blueprint: | `ConnectorStatusProjection+Mobile.swift` | Credential-free mobile rows and commands use their own checked refresh result from ConnectorReadiness; Mac and phone toggles share update and its checked verification; committed disconnect fences earlier reads through write before lane restart and checked verification. |

/// Credential-free rows shared by the existing snapshot and mutation receipts.
extension MobileConnectorSnapshot {
    public static let credentialProviders: Set<String> = ["slack"]

    public init(_ row: ConnectorRecord) {
        let supportsSetup = Self.credentialProviders.contains(row.id)
        self.init(id: row.id, name: row.name, kind: row.kind, enabled: row.enabled,
                  healthStatus: row.healthStatus, updatedAt: row.updatedAt, authState: row.authState,
                  canToggle: row.canToggle,
                  canDisconnect: supportsSetup && ["connected", "configured", "connected_unverified", "failed"].contains(row.authState ?? ""),
                  supportsSetup: supportsSetup)
    }
}

extension ConnectorReadiness {
    @MainActor public func mobileConnectors() async throws -> [MobileConnectorSnapshot] {
        let checked = await refresh()
        return try checked.get().map { MobileConnectorSnapshot($0) }
    }

    @MainActor public func setMobileConnectorEnabled(id: String, enabled: Bool) async throws -> DeviceSyncSnapshotRows {
        guard let current = try await mobileConnectors().first(where: { $0.id == id }), current.canToggle == true else {
            throw Self.connectorFailure("This connector is controlled by its setup on the Mac.")
        }
        guard let recovered = try await update(id: id, enabled: enabled) else {
            throw Self.connectorFailure("The Mac could not confirm the connector change. Refresh before trying again.")
        }
        return MobileConnectorSnapshot(recovered)
    }

    @MainActor public func disconnectMobileConnector(id: String) async throws -> DeviceSyncSnapshotRows {
        guard MobileConnectorSnapshot.credentialProviders.contains(id),
              try await mobileConnectors().contains(where: { $0.id == id }) else {
            throw Self.connectorFailure("This connector cannot be disconnected here.")
        }
        try await ConnectorRegistryActions.disconnectSlack(root: root)
        // The revoke committed. Earlier reads cannot republish its old account
        // state while the lane restarts; the checked read below publishes it.
        snapshotRead.write {}
        await Self.restartSlackLane(root: root)
        guard let recovered = try await mobileConnectors().first(where: { $0.id == id }),
              recovered.enabled == false, recovered.authState == "not_connected" else {
            throw Self.connectorFailure("The Mac could not confirm disconnection. Refresh before trying again.")
        }
        return recovered
    }

    private static func connectorFailure(_ message: String) -> NSError {
        NSError(domain: "NativeAgentConnectorMutation", code: -409, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
