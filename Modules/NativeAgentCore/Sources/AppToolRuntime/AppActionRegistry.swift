import AgentConversations
import AuthoredCapabilities
import ChatToolRuntime
import Foundation
import MacIntegration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import Senses
import ToolRegistry
import AgentWorkspace
import ChatTurnContracts
import ChromeControl
import MemoryV2
import NativeAgentShared
import StandingBots
import TrustCenter
import TurnTrace
// Blueprint: | `AppActionRegistry.swift` | AppActions registry lookup, page inventory and policy bindings; native, authored, built-in guidance and sense actions share one inventory |

public enum AppActions {
    /// Every button, and the settings rows behind `setting.set`. User's are his entries here. A `reason?` on a put-away action rides its
    /// receipt, so there is a record of why.
    public static var all: [AppAction] { available(dataRoot: PersistenceCore.defaultDataRoot()) }

    static func available(dataRoot: URL) -> [AppAction] {
        let peers = (try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []
        return seedActions.compactMap { action in
            guard let handle = ToolNameAliases.agentHandle(action.tool) ?? (action.tool == "claude_worklog" ? "claude" : nil) else { return action }
            guard let who = peers.first(where: { ($0.handles ?? []).contains(handle) }),
                  AgentConversationDelivery.lane(for: "peer:" + who.id, dataRoot: dataRoot) != nil else { return nil }
            if action.read {
                return AppAction(action.id, action.page, "Read \(who.name)'s worklog, newest first", action.args,
                    toolClass: action.toolClass, reach: action.reach, capabilities: action.capabilities, warn: action.warn, tool: action.tool, read: true)
            }
            return AppAction(action.id, action.page, "Message \(who.name)",
                ["text", "conversation?", "new_conversation?:bool", "expects_reply?:bool", "options?:object"],
                toolClass: action.toolClass, reach: action.reach, capabilities: action.capabilities, tool: "agent_message", input: ["agent": .string(handle)], schema: foldSchemas["agent_message"],
                folded: true)
        }
    }

    public static func integrationRoutes(_ integration: String) -> [JSONValue] {
        return all.compactMap { action in
            guard let gate = MacIntegrationGates.byTool[action.tool], gate.integration == integration else { return nil }
            return .object(["action": .string(action.id), "mode": .string(action.read ? "read" : "write"),
                            "required_permission": .string(gate.mode.rawValue)])
        }
    }

    public static func action(_ id: String, dataRoot: URL = PersistenceCore.defaultDataRoot()) -> AppAction? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        let own = available(dataRoot: dataRoot)
        if let action = own.first(where: { $0.id == key }) { return action }
        if let handle = ToolNameAliases.agentHandle(key),
           let alias = own.first(where: { $0.id.split(separator: ".").first.map(String.init) == handle && $0.tool == "agent_message" }) { return alias }
        let senses = senses()
        if let sense = senses.first(where: { $0.id.lowercased() == key }) { return sense }
        guard let snapshot = try? SwiftToolDispatcher.checkedAuthoredCatalog(dataRoot: dataRoot).get() else { return nil }
        return authored(dataRoot: dataRoot, catalog: own + senses, snapshot: snapshot, requested: key).first
    }

    /// A bounded receipt projection pass resolves against one checked catalog, including misses. It never re-discovers parts for each
    /// historical row.
    static func policyCatalog(dataRoot: URL) -> [String: AppActionBinding] {
        let base = available(dataRoot: dataRoot) + senses()
        let actions = (try? SwiftToolDispatcher.checkedAuthoredCatalog(dataRoot: dataRoot).get())
            .map { authored(dataRoot: dataRoot, catalog: base, snapshot: $0) } ?? []
        var bindings = Dictionary((base + actions).map { ($0.id.lowercased(), $0.binding) }, uniquingKeysWith: { first, _ in first })
        for action in actions where bindings[ToolNameAliases.authoredAction(action.tool)] == nil {
            bindings[ToolNameAliases.authoredAction(action.tool)] = action.binding
        }
        for action in base where action.tool == "agent_message" {
            let handle = String(action.id.prefix { $0 != "." })
            for alias in [handle + ".message", handle + "_message", handle + ".say", handle + "_say", "invoke_" + handle, "invoke." + handle]
                where bindings[alias] == nil && ToolNameAliases.agentHandle(alias) == handle { bindings[alias] = action.binding }
        }
        return bindings
    }

    // Leave synchronous file-backed discovery off the MainActor app door.
    static func resolvedAction(_ id: String, dataRoot: URL) async -> (action: AppAction, discovery: [String: JSONValue])? {
        guard let action = action(id, dataRoot: dataRoot) else { return nil }
        return (action, discovery(action, dataRoot: dataRoot).objectValue ?? [:])
    }

    static func pagePrefixedAction(_ id: String) -> AppAction? {
        let parts = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let page = AppDoorNames.resolve(String(parts[0])), verb = String(parts[1])
        let actions = on(page: page).filter { $0.page != "*" }
        if let action = action(verb), actions.contains(where: { $0.id == action.id }) { return action }
        let matches = actions.filter { $0.id.split(separator: ".", maxSplits: 1).last.map(String.init) == verb }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Every registered action: the app's own, the ones she wrote, and senses' verbs. What find ranks and `pages_version` hashes.
    static func inventory(dataRoot: URL) async throws -> (actions: [AppAction], authored: [AppAction]) {
        let records = try await FileSenseRegistry(dataRoot: dataRoot).all()
        let own = available(dataRoot: dataRoot), sense = senses(records: records, catalog: own)
        let authored = authored(dataRoot: dataRoot, catalog: own + sense,
            snapshot: try SwiftToolDispatcher.checkedAuthoredCatalog(dataRoot: dataRoot).get())
        // The persona's built-in guidance, each found as the ability.read that opens it.
        guard let read = own.first(where: { $0.id == "ability.read" }) else {
            throw ToolFailureError("The action registry is missing ability.read.", effects: .none, code: "missing_action")
        }
        let skills = try InstalledSkillInventory.entries(dataRoot: dataRoot).map { entry in
            AppAction(read.id, "skills", entry.name + ": " + entry.description, read.args,
                tool: read.tool, input: read.input.merging(["id": .string(entry.id)]) { _, bound in bound }, read: true)
        }
        let items = AppDoorNames.items.sorted { $0.key < $1.key }.flatMap { page, items in
            items.sorted { $0.key < $1.key }.filter { !$0.key.contains("<") }.map { item, title in
                AppAction(page + "/" + item, page, title,
                    tool: "app_page_read", input: ["page": .string(page), "item": .string(item)], read: true)
            }
        }
        return (items + own + authored + skills + sense, authored)
    }

    /// A page's actions: its own, and the ones on every page.
    public static func on(page: String, dataRoot: URL = PersistenceCore.defaultDataRoot()) -> [AppAction] {
        let page = AppDoorNames.resolve(page)
        let own = available(dataRoot: dataRoot), sense = senses(records: (try? FileSenseRegistry(dataRoot: dataRoot).presentationRecords()) ?? [], catalog: own)
        let parts = (try? SwiftToolDispatcher.checkedAuthoredCatalog(dataRoot: dataRoot).get())
            .map { authored(dataRoot: dataRoot, catalog: own + sense, snapshot: $0) } ?? []
        return own.filter { $0.page == page || $0.page == "*" }
            + parts.filter { $0.page == page || page == "tools" } + sense.filter { $0.page == page }
    }
}
