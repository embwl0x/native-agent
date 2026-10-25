import Foundation
import NativeAgentCore
import Connectors
import PersistenceCore
import TrustCenter
// Blueprint: | `EngineConnectors.swift` | ConnectorStatusProjection workspace/action reads publish through LatestRead; committed workspace additions publish their own checked result through write; native connector execution supplies its engine root and originating `ToolsFacade.withPartDoor` before calling the domain; no second connector facade or account snapshot. |

extension NativeAgentEngine {
    /// Native connector entry; turns already carry their own door.
    public func runConnectorAction(id: String, dryRun: Bool, input: [String: JSONValue] = [:],
        origin: String, platform: any ConnectorActionPlatform) async throws -> ConnectorActionReceipt {
        try await tools.withPartDoor(envelope: .native(origin)) {
            try await ConnectorActions(platform: platform).runConnectorAction(
                id: id, dryRun: dryRun, input: input, dataRoot: self.dataRoot)
        }
    }
}

/// Workspace and action reads share the engine's connector owner.
@MainActor
extension ConnectorStatusProjection {
    @discardableResult
    public func refreshWorkspaces() async throws -> [WorkspaceRecord] {
        let result: Result<[WorkspaceRecord], Error> = await workspacesRead.read({
            do { return .success(try await ConnectorRegistryActions.listWorkspaces(root: root)) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let rows): workspaceSnapshot = rows; workspacesReadError = nil
            case .failure(let error): workspacesReadError = error.localizedDescription
            }
        })
        return try result.get()
    }

    @discardableResult
    public func refreshActions() async throws -> ConnectorActionRegistry {
        let result: Result<ConnectorActionRegistry, Error> = await actionsRead.read({
            do { return .success(try await ConnectorActionRegistry.read(dataRoot: root, platform: platform)) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let registry): actions = registry; actionsReadError = nil
            case .failure(let error): actionsReadError = error.localizedDescription
            }
        })
        return try result.get()
    }

    public func addWorkspace(name: String, path: String, writable: Bool) async throws -> (added: WorkspaceRecord, refreshed: [WorkspaceRecord], verified: Bool) {
        let result = try await ConnectorRegistryActions.addWorkspace(name: name, path: path,
            permissions: writable ? ["read", "write"] : ["read"], root: root)
        workspacesRead.write {
            workspaceSnapshot = result.refreshed
            workspacesReadError = nil
        }
        return result
    }

}
