import Foundation
import PersistenceCore
import NativeAgentCore
import ChatToolParsing
// Blueprint: | `AgentWorkspaceEnvironment.swift` | Owner reader catalog, home rooms and existing app action discovery |

struct AgentWorkspaceDestination: Sendable {
    let id: String
    let title: String
    let summary: String
    let tool: String?
    var input: [String: JSONValue] = [:]
    var searchField: String? = nil
    var tools: [String] = []
    var searchLabel: String? = nil
}

package enum AgentWorkspaceEnvironment {
    static let destinations: [AgentWorkspaceDestination] =
        AgentWorkspaceKnowledge.destinations + AgentWorkspaceApps.destinations + AgentWorkspaceActivity.destinations + AgentWorkspaceBuild.destinations
            + AgentScreen.commsDestinations
            + AgentWorkspaceLife.destinations + AgentScreen.coreDestinations + [
            .init(id: "app", title: "NativeAgent",
                summary: "The app itself is its own door: call app {} directly for its pages, settings and actions, with receipts.",
                  tool: nil),
            .init(id: "self", title: "My state", summary: "How things stand, current context and available abilities.",
                  tool: "inner_state", tools: ["agent_introspect", "context_lookup"])
        ]

    package static let readTools: Set<String> =
        AgentWorkspaceKnowledge.readTools.union(AgentWorkspaceApps.readTools).union(AgentWorkspaceActivity.readTools).union(AgentWorkspaceBuild.readTools)
            .union(AgentScreen.commsReadTools)
            .union(AgentWorkspaceLife.readTools).union(AgentScreen.coreReadTools)
            .union(["work_context", "artifact_find", "read_chat_message", "chat_conversations", "read_file", "agent_contacts", "agent_read", "inner_state",
                "agent_introspect", "context_lookup", "time_now", "search_chat_history"])

    static func isStatusReader(_ tool: String) -> Bool {
        tool.hasSuffix("_status") && !tool.contains("set_")
    }

    static func title(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ").capitalized
    }

    static func optionalSchema(_ name: String, catalog: AgentWorkspace.Catalog) async throws -> LLMToolSchema? {
        let matches = try await catalog().filter { $0.name == name && $0.name != "tool_result_page" }
        guard matches.count <= 1 else {
            throw AgentWorkspaceFailure(message: "This action is no longer uniquely available in this session. Nothing was run.")
        }
        return matches.first
    }

    static func outcome(_ value: JSONValue) -> JSONValue {
        let reply = ToolResult(value)
        return .string(reply.outcome.receipt.status)
    }

    static func retained(_ result: JSONValue) -> JSONValue {
        if case .object(let row) = result, row["integration"] == .string("mail"),
           case .array(let items)? = row["items"], (1...10).contains(items.count),
           items.allSatisfy({ if case .object(let item) = $0 { item["body"] == nil } else { false } }) { return result }
        guard let serialized = try? result.serialize(pretty: false), serialized.utf8.count > 24_000 else { return result }
        return .object(["status": outcome(result), "excerpt": .string(String(serialized.prefix(12_000))),
            "truncated": .bool(true), "detail": .string(
                "Bounded retained receipt. Open the capability's recorded result for further detail; this excerpt is not the full response.")])
    }

    static func readback(tool: String, input: [String: JSONValue]) -> AgentWorkspaceLocation? {
        if tool.hasPrefix("browser.chrome_"), case .int(let tab)? = input["tab_id"] {
            return .record(tool: "browser.chrome_snapshot", input: ["tab_id": .int(tab)],
                title: "Selected browser page")
        }
        if ["desk_note", "desk_set_status"].contains(tool), let handle = input["handle"] {
            return .record(tool: "desk_read", input: ["handle": handle], title: "Updated work")
        }
        if tool == "messages.send", let thread = input["thread_id"] {
            return .record(tool: "messages.recent", input: ["thread_id": thread], title: "Messages conversation")
        }
        if tool == "mail.reply", let id = input["message_id"], let expected = input["expected_message_id"] {
            return .record(tool: "mail.recent", input: ["message_id": id, "expected_message_id": expected].merging(
                input.filter { ["expected_account", "expected_account_id", "position"].contains($0.key) }) { a, _ in a }, title: "Email conversation")
        }
        if tool == "bot_pause" {
            return .record(tool: "bot_list", input: input["id"].map { ["id": $0] } ?? [:], title: "My helpers")
        }
        if tool.hasPrefix("mac_reminders_") { return .area("reminders") }
        if tool == "chat_reply", let session = input["conversation_session_id"] {
            return .record(tool: "chat_conversations", input: ["conversation_session_id": session], title: "Conversation with you")
        }
        guard tool == "write_file", case .string(let path)? = input["path"], !path.isEmpty else { return nil }
        return .record(tool: "read_file", input: ["path": .string(path), "max_bytes": .int(12000)], title: "File: " + path)
    }

    static func read(workspace: WorkspaceOperation, location: AgentWorkspaceLocation, dataRoot: URL,
        perform: AgentWorkspace.Perform) async throws -> JSONValue {
        switch location {
        case .browserBookmark(let url, _, let tab):
            return try await perform(tab == nil ? "read_page" : "browser.chrome_snapshot",
                tab.map { ["tab_id": .int($0)] } ?? ["url": .string(url)])
        case .documents(let query): return try await perform("artifact_find", ["query": .string(query), "limit": .int(6)])
        case .people: return try await perform("agent_contacts", [:])
        case .record(let tool, let input, _):
            let appRead = tool == "app" && input["action"] == nil && input["script"] == nil
            guard appRead || readTools.contains(tool) || isStatusReader(tool) else {
                throw AgentWorkspaceFailure(message: "This item has no supported reader.")
            }
            return tool == "chat_conversations" ? try await HumanConversationRead.read(workspace: workspace, input, dataRoot: dataRoot)
                : try await perform(tool, input)
        default: throw AgentWorkspaceFailure(message: "This view is unavailable. Open app {}.")
        }
    }

    static func view(workspace: WorkspaceOperation, location: AgentWorkspaceLocation, dataRoot: URL, catalog: AgentWorkspace.Catalog,
                     perform: AgentWorkspace.Perform) async throws -> WorkspacePage? {
        switch location {
        case .area(let id):
            guard let place = destinations.first(where: { $0.id == id }) else { return nil }
            if id == "today" { return try await AgentWorkspaceActivity.today(workspace: workspace, dataRoot: dataRoot, perform: perform) }
            let schemas = try await catalog()
            let names = Set(schemas.map(\.name))
            var input = place.input
            if id == "files", input["path"] == .string("$workspace") {
                input["path"] = .string(NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot).path)
            }
            var projection = WorkspacePage(title: place.title, content: .object([
                "status": .string("ok"), "about": .string(place.summary)]), items: [], actions: [])
            if let tool = place.tool, names.contains(tool) {
                if let field = place.searchField {
                    projection.actions.append(.init(label: place.searchLabel ?? "Search " + place.title, action: .perform(tool: tool, input: input, title: place
                        .title, textField: field, isEffect: !readTools.contains(tool)), needsText: true))
                } else if readTools.contains(tool) {
                    let location = AgentWorkspaceLocation.record(tool: tool, input: input, title: place.title), value = try await perform(tool, input)
                    projection = await .project(workspace: workspace, location: location, result: value, dataRoot: dataRoot,
                        evidence: AgentWorkspaceDocument.evidence(
                        location: location, value: value))
                }
            } else if place.tool != nil {
                projection.content = .object(["status": .string("unavailable"), "message": .string(
                    "This place's reader is not advertised in this session. Available actions are shown below.")])
            }
            if id == "research", names.contains(AgentWorkspaceKnowledge.webSearchTool) {
                projection.actions.insert(.init(label: "Search the web", action: .searchWeb, needsText: true), at: 0)
            }
            if id == "status", names.contains("app") {
                for (label, page, item) in [("Doctor check of the whole app", "diagnostics", "doctor"), ("Telegram link", "telegram", "status")] {
                    projection.actions.append(.init(label: label, action: .open(.record(
                        tool: "app", input: ["page": .string(page), "item": .string(item)], title: label))))
                }
            }
            if id == "activity", names.contains("activity_query") {
                projection.actions.append(.init(label: "This week", action: .open(.record(
                    tool: "activity_query", input: ["range": .string("last_7_days")], title: "Activity this week"))))
            }
            for name in place.tools where name != place.tool && names.contains(name) {
                if projection.actions.contains(where: {
                    if case .open(.record("app", let input, _)) = $0.action { return name == input["find"]?.stringValue }
                    if case .perform(let tool, _, _, _, _) = $0.action { return name == tool }
                    return false
                }) { continue }
                projection.actions.append(AgentWorkspaceApps.quickAction(tool: name) ?? AgentScreen.coreAction(tool: name)
                    ?? .init(label: title(name), action: isStatusReader(name)
                        ? .open(.record(tool: name, input: [:], title: title(name)))
                        : .open(.record(tool: "app", input: ["find": .string(name), "args": .object([:])], title: title(name)))))
            }
            return projection
        case .receipt(let tool, let title, let value, let readback):
            let location = AgentWorkspaceLocation.record(tool: tool, input: [:], title: title)
            var projection = await WorkspacePage.project(workspace: workspace, location: location, result: value, dataRoot: dataRoot,
                evidence: AgentWorkspaceDocument.evidence(
                location: location, value: value))
            projection.title = title
            projection.content = .object(["status": outcome(value), "result": projection.content,
                "evidence": .string(
                    "Retained result of the selected action. Refresh does not execute it again and does not verify that an external state is still current.")])
            if let readback {
                if case .record("shelf_entry", let input, _) = readback {
                    projection.actions.insert(.init(label: "Return to saved reply", action: .open(readback)), at: 0)
                    if case .string(let bot)? = input["bot_id"], UUID(uuidString: bot) != nil {
                        projection.actions.append(.init(label: "Open conversation", action: .open(.record(
                            tool: "agent_read", input: ["agent": .string("bot:" + bot)], title: "Helper conversation"))))
                    }
                } else {
                    let label: String
                    if case .record("read_file", _, _) = readback { label = "Read current file" }
                    else { label = "Open " + readback.title }
                    projection.actions.insert(.init(label: label, action: .open(readback)), at: 0)
                }
            }
            if tool.hasPrefix("browser.chrome_"), case .object(let receipt) = value,
               receipt["tabClosed"] != .bool(true), case .int(let tab)? = receipt["tabId"] {
                projection.actions.insert(.init(label: "Read this browser page", action: .open(.record(tool: "browser.chrome_snapshot",
                    input: ["tab_id": .int(tab)], title: "Browser page"))), at: 0)
            }
            return projection
        default: return nil
        }
    }
}
