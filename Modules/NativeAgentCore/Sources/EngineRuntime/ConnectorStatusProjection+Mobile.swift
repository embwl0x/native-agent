import Foundation
import NativeAgentShared
import Connectors
import DeviceSync
import PersistenceCore
// Blueprint: | `ConnectorStatusProjection+Mobile.swift` | Credential-free mobile snapshots and checked mutations |

/// Share credential-free rows between snapshots and mutation receipts.
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

    @MainActor public func disconnectMobileConnector(id: String) async throws -> DeviceSyncSnapshotRows {
        guard MobileConnectorSnapshot.credentialProviders.contains(id),
              try await mobileConnectors().contains(where: { $0.id == id }) else {
            throw Self.connectorFailure("This connector cannot be disconnected here.")
        }
        try await ConnectorRegistryActions.disconnectSlack(root: root)
        // Fence earlier reads after revocation so the restart cannot republish the old account.
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
