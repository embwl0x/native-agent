import Foundation
import MacIntegration
import PersistenceCore
// Blueprint: | `AgentWorkspaceReadiness.swift` | Per-call permission evidence and named owner action filtering |

package enum AgentWorkspaceReadiness {
    struct Snapshot: Sendable {
        let permissions: Result<MacIntegrationPermissionReadiness, Error>
    }

    package static func withSnapshot<T: Sendable>(workspace: WorkspaceOperation, dataRoot: URL,
        operation: @Sendable (WorkspaceOperation) async throws -> T) async rethrows -> T {
        let permissions: Result<MacIntegrationPermissionReadiness, Error>
        do { permissions = .success(try await MacIntegrationPermissionStore(dataRoot: dataRoot).readinessChecked()) }
        catch { permissions = .failure(error) }
        var workspace = workspace
        workspace.readiness = Snapshot(permissions: permissions)
        return try await operation(workspace)
    }

    static func allows(workspace: WorkspaceOperation, tool name: String) -> Bool {
        guard let gate = workspace.ports.tools.macIntegrationAccess(name)
            ?? workspace.ports.tools.macIntegrationAccess(name.replacingOccurrences(of: ".", with: "_")) else { return true }
        guard case .success(let permissions)? = workspace.readiness?.permissions else { return false }
        return !(gate.mode == .read ? permissions.operatorReadOff : permissions.operatorWriteOff).contains(gate.integration)
    }

    static func allows(workspace: WorkspaceOperation, _ action: AgentWorkspaceAction) -> Bool {
        return tool(action).map { allows(workspace: workspace, tool: $0) } ?? true
    }

    static func filter(workspace: WorkspaceOperation, _ projection: WorkspacePage) -> WorkspacePage {
        var result = projection
        var hidden = 0
        func buttons(_ buttons: [AgentWorkspaceButton]) -> [AgentWorkspaceButton] {
            buttons.filter { button in
                let allowed = allows(workspace: workspace, button.action)
                if !allowed { hidden += 1 }
                return allowed
            }
        }
        result.actions = buttons(result.actions)
        result.items = result.items.map { item in
            var item = item
            item.actions = buttons(item.actions)
            return item
        }
        let permissions: MacIntegrationPermissionReadiness?
        let cause: String?
        switch workspace.readiness?.permissions {
        case .success(let value)?: permissions = value; cause = nil
        case .failure(let error)?: permissions = nil; cause = error.localizedDescription
        case nil: permissions = nil; cause = nil
        }
        if hidden > 0 || cause != nil {
            var content: [String: JSONValue]
            if case .object(let row) = result.content { content = row }
            else { content = ["result": result.content] }
            content["permission_note"] = .string(permissions == nil
                ? "Mac permission settings could not be read. Integration actions are hidden until those settings are available."
                : "Actions turned off by the operator are hidden; no permission was changed.")
            if let cause {
                content["permission_note"] = .string(
                    "Mac permission settings are unavailable: \(cause) Integration actions are hidden until the saved authority is repaired.")
                content["permission_remedy"] = Repair.why(owner: "security/mac_integration_permissions.json", tap: "Trust > Mac",
                    instruction: "Preserve the saved permission bytes and repair the authority before continuing.")
            }
            content["hidden_permission_actions"] = .int(Int64(hidden))
            if content["preview_note"] != nil, permissions?.operatorWriteOff.contains("mail") == true {
                content["preview_note"] = .string("Open a recent message to read its body. Mail is read-only; sending and replying are turned off.")
            }
            if content["conversation_note"] != nil, permissions?.operatorWriteOff.contains("messages") == true {
                let history = content["history_status"] == .string("available")
                    ? "This conversation shows bounded local history; any unavailable message formats are labeled."
                    : "Open a conversation for bounded local history when available; its current history status explains any limitation."
                content["conversation_note"] = .string("\(history) Messages is read-only; sending and replying are turned off.")
            }
            result.content = .object(content)
        }
        return result
    }

    private static func tool(_ action: AgentWorkspaceAction) -> String? {
        switch action {
        case .perform(let tool, _, _, _, _): return tool
        case .open(.record(let tool, _, _)): return tool
        default: return nil
        }
    }
}
