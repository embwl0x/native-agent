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
// Blueprint: | `AppActionRegistry.swift` | One native/authored/guidance/sense inventory and policy bindings |

public enum AppActions {
    /// Put-away reasons ride the receipt so the decision remains attributable.
    public static var all: [AppAction] { get throws { try available(dataRoot: PersistenceCore.defaultDataRoot()) } }

    static func available(dataRoot: URL) throws -> [AppAction] {
        try seedActions
    }

    public static func action(_ id: String, dataRoot: URL = PersistenceCore.defaultDataRoot(), turn: Turn?) throws -> AppAction? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        let own = try checkedInventory(dataRoot: dataRoot, turn: turn).actions
        if let action = own.first(where: { $0.id == key }) { return action }
        // An ability dispatches under its own id: the tool its authored action binds. A part that answers verbs stands for its strictest verb, so a
        // judgment made by its id alone is never looser than one of its verbs; each call is judged by the verb it carries.
        return strictest(own.filter { $0.authored && $0.tool.lowercased() == key })
    }

    /// A bounded receipt projection pass resolves against one checked catalog, including misses. It never re-discovers parts for each historical row.
    static func policyCatalog(dataRoot: URL, turn: Turn?) throws -> [String: AppActionBinding] {
        let inventory = try checkedInventory(dataRoot: dataRoot, turn: turn)
        let actions = inventory.authored
        let base = inventory.actions.filter { !$0.authored }
        var bindings = Dictionary((base + actions).map { ($0.id.lowercased(), $0.binding) }, uniquingKeysWith: { first, _ in first })
        // Abilities run under their own id; that tool name resolves to its action too.
        for (tool, owned) in Dictionary(grouping: actions, by: { $0.tool.lowercased() }) where bindings[tool] == nil {
            bindings[tool] = strictest(owned)?.binding
        }
        return bindings
    }

    /// The strictest of one part's actions: highest class, irreversible first.
    static func strictest(_ actions: [AppAction]) -> AppAction? {
        actions.max { ($0.toolClass, $0.irreversible ? 1 : 0) < ($1.toolClass, $1.irreversible ? 1 : 0) }
    }

    // Leave synchronous file-backed discovery off the MainActor app door.
    static func resolvedAction(_ id: String, dataRoot: URL, turn: Turn?) async throws -> (action: AppAction, discovery: [String: JSONValue])? {
        guard let action = try action(id, dataRoot: dataRoot, turn: turn) else { return nil }
        return (action, try discovery(action, dataRoot: dataRoot).objectValue ?? [:])
    }

    static func pagePrefixedAction(_ id: String, dataRoot: URL = PersistenceCore.defaultDataRoot(), turn: Turn?) throws -> AppAction? {
        let parts = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let page = AppDoorNames.resolve(String(parts[0])), verb = String(parts[1])
        let actions = try on(page: page, dataRoot: dataRoot, turn: turn).filter { $0.page != "*" }
        if let action = try action(verb, dataRoot: dataRoot, turn: turn), actions.contains(where: { $0.id == action.id }) { return action }
        // A page-prefixed call names a family too: chat.read is never Make's read just because Make lives on the Chat page.
        let family = String(parts[0])
        let matches = actions.filter {
            let own = $0.id.split(separator: ".", maxSplits: 1)
            return own.last.map(String.init) == verb && own.first.map { [family, page].contains(String($0)) } == true
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Discovery ranking and pages_version must read the same complete action inventory.
    static func inventory(dataRoot: URL, turn: Turn?) async throws -> (actions: [AppAction], authored: [AppAction]) {
        try checkedInventory(dataRoot: dataRoot, turn: turn)
    }

    /// One checked snapshot for synchronous policy/lookup and asynchronous discovery. No consumer can publish a successful partial catalog.
    static func checkedInventory(dataRoot: URL, turn: Turn?) throws -> (actions: [AppAction], authored: [AppAction]) {
        let records = try FileSenseRegistry(dataRoot: dataRoot).presentationRecords()
        let own = try available(dataRoot: dataRoot), sense = try senses(records: records, catalog: own, dataRoot: dataRoot, turn: turn)
        let authored = try authored(dataRoot: dataRoot, catalog: own + sense,
            snapshot: try SwiftToolDispatcher.checkedAuthoredCatalog(dataRoot: dataRoot).get())
        // Built-in guidance resolves to ability.read, sharing the ability discovery route.
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

    public static func on(page: String, dataRoot: URL = PersistenceCore.defaultDataRoot(), turn: Turn?) throws -> [AppAction] {
        let page = AppDoorNames.resolve(page)
        let inventory = try checkedInventory(dataRoot: dataRoot, turn: turn)
        return inventory.actions.filter { $0.page == page || $0.page == "*" || ($0.authored && page == "tools") }
    }
}
