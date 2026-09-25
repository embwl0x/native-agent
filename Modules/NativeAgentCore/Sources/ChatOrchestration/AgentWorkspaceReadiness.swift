import Foundation
import MacIntegration
import PersistenceCore

/// Presentation evidence only. Actual execution always re-enters the normal
/// tool admission chain. No background refresh, app launch or remote probe.
enum AgentWorkspaceReadiness {
    struct Snapshot: Sendable {
        let permissions: MacIntegrationPermissionReadiness?
    }

    @TaskLocal static var snapshot: Snapshot?

    /// Share one canonical permission read across the entire workspace action,
    /// including Home and its final action filtering. Never cache revocations
    /// across separate actions or write a second permission authority.
    static func withSnapshot<T: Sendable>(dataRoot: URL,
        operation: @Sendable () async throws -> T) async rethrows -> T {
        let permissions = try? await MacIntegrationPermissionStore(dataRoot: dataRoot).readinessChecked()
        return try await $snapshot.withValue(Snapshot(permissions: permissions), operation: operation)
    }

    /// Remove misleading active controls from every projected surface, including
    /// Mail reply items and generic capability forms. This never grants access;
    /// changes after presentation are still enforced by the actual dispatcher.
    static func filter(_ projection: AgentWorkspaceProjection) -> AgentWorkspaceProjection {
        var result = projection
        var hidden = 0
        func buttons(_ buttons: [AgentWorkspaceButton]) -> [AgentWorkspaceButton] {
            buttons.filter { button in
                guard let name = tool(button.action),
                      let gate = ToolPreloadHeuristics.macIntegrationGates[name]
                        ?? ToolPreloadHeuristics.macIntegrationGates[name.replacingOccurrences(of: ".", with: "_")] else { return true }
                let allowed: Bool
                if let permissions = snapshot?.permissions {
                    allowed = !(gate.mode == .read ? permissions.operatorReadOff : permissions.operatorWriteOff).contains(gate.integration)
                } else { allowed = false }
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
        if hidden > 0 {
            var content: [String: JSONValue]
            if case .object(let row) = result.content { content = row }
            else { content = ["result": result.content] }
            content["permission_note"] = .string(snapshot?.permissions == nil
                ? "Mac permission settings could not be read. Integration actions are hidden until those settings are available."
                : "Actions turned off by the operator are hidden. Existing drafts can still be kept or edited; no permission was changed.")
            content["hidden_permission_actions"] = .int(Int64(hidden))
            if content["preview_note"] != nil, snapshot?.permissions?.operatorWriteOff.contains("mail") == true {
                content["preview_note"] = .string("Open a recent message to read its body. Mail is read-only; sending and replying are turned off.")
            }
            if content["conversation_note"] != nil, snapshot?.permissions?.operatorWriteOff.contains("messages") == true {
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
        case .perform(let tool, _, _, _, _), .configure(let tool, _, _): return tool
        case .submit(let form): return form.tool
        case .open(.record(let tool, _, _)): return tool
        default: return nil
        }
    }
}
