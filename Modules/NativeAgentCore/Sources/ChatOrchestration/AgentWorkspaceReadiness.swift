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

    static func card(_ place: AgentWorkspaceDestination, names: Set<String>, browser: JSONValue?) -> [String: JSONValue] {
        let available = place.tool.map { names.contains($0) } ?? place.tools.contains { names.contains($0) }
        var row: [String: JSONValue] = ["about": .string(place.summary)]
        func status(_ state: String, _ detail: String) -> [String: JSONValue] {
            row["availability"] = .string(state)
            row["readiness"] = .string(state)
            row["readiness_detail"] = .string(detail)
            return row
        }
        guard available else { return status("unavailable", "This place's capabilities are not available in this conversation.") }
        if ["calendar", "reminders", "mail", "messages"].contains(place.id) {
            guard let permissions = snapshot?.permissions else {
                return status("unknown", "Saved Mac permissions could not be checked. Actions stay unavailable until those settings can be read.")
            }
            if permissions.operatorReadOff.contains(place.id) {
                return status("needs_setup", "Reading is turned off by the operator. Ask the operator to change it if needed; opening this place does not grant access.")
            }
            if permissions.operatorWriteOff.contains(place.id) {
                row["about"] = .string(place.id == "mail" ? "Read recent email and find messages." : place.id == "messages" ? "Read recent message conversations." : place.summary)
                return status("read_only", "The operator turned writing off. Home checks saved permissions only; open this place for current contents and macOS access.")
            }
            return status("unknown", "The reader is available. Home checks saved permissions only; open this place for current contents and macOS access.")
        }
        if place.id == "browser" {
            guard case .object(let current)? = browser,
                  case .bool(let enabled)? = current["chrome_control_enabled"],
                  case .bool(let connected)? = current["connected"] else {
                return status("unknown", "Browser connection status is unavailable. Open Browser to inspect its current status.")
            }
            if !enabled { return status("needs_setup", "Chrome control is turned off. Open Browser to see setup and permission guidance.") }
            if connected { return status("ready", "The extension is connected now. Open Browser to select or resume a page; no page was read for this check.") }
            return status("needs_setup", "The extension is not connected now. Open Browser to reconnect or finish setup.")
        }
        switch place.id {
        case "computer": return status("unknown", "Computer controls are available. Current macOS access and the screen are checked when opened.")
        case "connections": return status("ready", "The contact list and connection setup are available. Each contact's route reports its own connection state; no agent was contacted.")
        case "research": return status("ready", "Source-reading capabilities are available. Network access and each source are checked when selected.")
        case "helpers": return status("ready", "Helper management is available. Individual helpers and their providers are checked when selected.")
        case "create": return status("ready", "Creation tools are available. Each selected tool checks its permissions and any provider it needs.")
        default: return status("ready", "This local place is available to open. Its owner supplies current contents when selected.")
        }
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
