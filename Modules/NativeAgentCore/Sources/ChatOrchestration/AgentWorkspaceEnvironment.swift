import Foundation
import PersistenceCore
import NativeAgentCore

/// A small destination card, not a second capability registry. The actual
/// schema/catalog and the normal dispatcher remain availability/authority owners.
struct AgentWorkspaceDestination: Sendable {
    let id: String
    let title: String
    let summary: String
    let tool: String?
    var input: [String: JSONValue] = [:]
    var searchField: String? = nil
    var tools: [String] = []
}

enum AgentWorkspaceEnvironment {
    static var destinations: [AgentWorkspaceDestination] {
        AgentWorkspaceKnowledge.destinations + AgentWorkspaceApps.destinations + AgentWorkspaceActivity.destinations + [
            .init(id: "app", title: "NativeAgent", summary: "The app itself: its pages and settings, read and changed quietly with receipts.",
                  tool: nil, tools: ["app_settings_list", "app_page_read", "app_page_screenshot", "app_setting_set"]),
            .init(id: "self", title: "My state", summary: "How things stand, current context and available abilities.",
                  tool: "inner_state", tools: ["agent_introspect", "context_lookup"])
        ]
    }

    static var readTools: Set<String> {
        AgentWorkspaceKnowledge.readTools.union(AgentWorkspaceApps.readTools).union(AgentWorkspaceActivity.readTools)
            .union(["app_settings_list", "app_page_read", "app_page_screenshot", "work_context", "artifact_find", "read_chat_message", "chat_conversations", "read_file", "agent_contacts", "agent_read", "inner_state", "agent_introspect", "context_lookup", "time_now", "search_chat_history"])
    }

    static func title(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ").capitalized
    }

    private static func browsable(_ schema: LLMToolSchema) -> Bool {
        !["workspace", "tool_load", "tool_unload", "tool_catalog", "tool_result_page"].contains(schema.name)
    }

    static func schema(_ name: String, catalog: AgentWorkspace.Catalog) async throws -> LLMToolSchema {
        let matches = try await catalog().filter { $0.name == name && browsable($0) }
        guard matches.count == 1, let schema = matches.first else {
            throw AgentWorkspaceForm.Failure(message: "This action is no longer uniquely available in this session. Nothing was run.")
        }
        return schema
    }

    static func outcome(_ value: JSONValue) -> JSONValue {
        guard case .object(let row) = value else { return .string("ok") }
        if row["ok"] == .bool(false) || row["error"] != nil || row["error_code"] != nil { return .string("failed") }
        return row["status"] ?? row["state"] ?? .string("ok")
    }

    static func retained(_ result: JSONValue) -> JSONValue {
        guard let serialized = try? result.serialize(pretty: false), serialized.utf8.count > 24_000 else { return result }
        return .object(["status": outcome(result), "excerpt": .string(String(serialized.prefix(12_000))),
            "truncated": .bool(true), "detail": .string("Bounded retained receipt. Open the capability's recorded result for further detail; this excerpt is not the full response.")])
    }

    /// Only a target reference survives a write, never its submitted contents.
    /// Reading it is a new gated owner operation, not proof the write succeeded.
    static func readback(tool: String, input: [String: JSONValue]) -> AgentWorkspaceLocation? {
        if tool.hasPrefix("browser.chrome_"), case .string(let lease)? = input["lease_id"] {
            return .record(tool: "browser.chrome_snapshot", input: ["lease_id": .string(lease), "max_nodes": .int(80), "max_text_chars": .int(10000)], title: "Selected browser page")
        }
        if ["desk_note", "desk_update_item", "desk_set_status", "desk_add_ref"].contains(tool), let handle = input["handle"] {
            return .record(tool: "desk_read", input: ["handle": handle, "structured": .bool(true)], title: "Updated work")
        }
        if tool == "messages_send", let thread = input["thread_id"] {
            return .record(tool: "messages_recent_threads", input: ["thread_id": thread], title: "Messages conversation")
        }
        if tool == "mail_reply", let id = input["message_id"], let expected = input["expected_message_id"] {
            return .record(tool: "mail_list_recent", input: ["message_id": id, "expected_message_id": expected], title: "Email conversation")
        }
        if tool == "save_skill", let name = input["name"] {
            return .record(tool: "read_skill", input: ["name": name], title: "Saved skill")
        }
        if ["bot_create", "bot_update", "bot_pause"].contains(tool) {
            return .record(tool: "bot_list", input: input["id"].map { ["id": $0] } ?? [:], title: "My helpers")
        }
        if tool.hasPrefix("mac_calendar_") { return .area("calendar") }
        if tool.hasPrefix("mac_reminders_") { return .area("reminders") }
        if tool == "chat_reply", let session = input["conversation_session_id"] {
            return .record(tool: "chat_conversations", input: ["conversation_session_id": session], title: "Conversation with you")
        }
        guard tool == "write_file", case .string(let path)? = input["path"], !path.isEmpty else { return nil }
        return .record(tool: "read_file", input: ["path": .string(path), "max_bytes": .int(12000)], title: "File: " + path)
    }

    static func view(location: AgentWorkspaceLocation, dataRoot: URL, catalog: AgentWorkspace.Catalog,
                     perform: AgentWorkspace.Perform) async throws -> AgentWorkspaceProjection? {
        switch location {
        case .browserBookmark(let url, let title, let tabID):
            var actions: [AgentWorkspaceButton] = [
                .init(label: "Read current source", action: .open(.record(tool: "read_page", input: ["url": .string(url)], title: title))),
                .init(label: "Open in a new background tab", action: .perform(tool: "browser.chrome_acquire", input: ["mode": .string("create"), "initial_url": .string(url)], title: title, textField: nil, isEffect: true))
            ]
            if tabID != nil { actions.insert(.init(label: "Return to this browser tab", action: AgentWorkspaceNavigation.windowAction(location)), at: 0) }
            return .init(title: title, content: .object(["status": .string("saved_reference"),
                "url": .string(url), "message": .string(tabID == nil
                    ? "Saved page address without a recorded tab identity. Read the source or explicitly open a new background tab; no current page evidence was restored."
                    : "Saved tab reference, not live page evidence. Selecting this window checks its exact tab, URL and title through the browser owner before obtaining fresh controls. A missing or changed tab is refused; no substitute tab is opened.")]), items: [], actions: actions)
        case .home:
            let names = Set(try await catalog().map(\.name))
            // This status owner reads the existing extension connection and
            // local control policy only: it never opens Chrome, reads a page,
            // contacts a provider, or probes a remote agent.
            var browser: JSONValue?
            if names.contains("browser.chrome_status") {
                browser = try? await perform("browser.chrome_status", [:])
            }
            // Home is a glance: names, and a state only where one is in the
            // way. The explanations live inside each place, read on opening.
            return .init(title: "Workspace", content: .object(["status": .string("ok")]),
                items: destinations.map { place in
                    let card = AgentWorkspaceReadiness.card(place, names: names, browser: browser)
                    var content: [String: JSONValue] = [:]
                    if let state = card["availability"], ![.string("ready"), .string("unknown")].contains(state) {
                        content["state"] = state
                    }
                    return .init(title: place.title, content: .object(content),
                        actions: [.init(label: "Open " + place.title, action: .open(.area(place.id)))])
                }, actions: [])
        case .area(let id):
            guard let place = destinations.first(where: { $0.id == id }) else { return nil }
            if id == "today" { return try await AgentWorkspaceActivity.today(perform: perform) }
            let schemas = try await catalog()
            let names = Set(schemas.map(\.name))
            var input = place.input
            if id == "files", input["path"] == .string("$workspace") {
                input["path"] = .string(NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot).path)
            }
            var projection = AgentWorkspaceProjection(title: place.title, content: .object([
                "status": .string("ok"), "about": .string(place.summary)]), items: [], actions: [])
            if let tool = place.tool, names.contains(tool) {
                if let field = place.searchField {
                    projection.actions.append(.init(label: "Search " + place.title, action: .perform(tool: tool, input: input, title: place.title, textField: field, isEffect: !readTools.contains(tool)), needsText: true))
                } else if readTools.contains(tool) {
                    projection = .project(location: .record(tool: tool, input: input, title: place.title), result: try await perform(tool, input))
                }
            } else if place.tool != nil {
                projection.content = .object(["status": .string("unavailable"), "message": .string("This place's reader is not advertised in this session. Available actions are shown below.")])
            }
            if id == "research", names.contains("browser.chrome_acquire") {
                projection.actions.insert(.init(label: "Search the web", action: .searchWeb, needsText: true), at: 0)
            }
            if id == "create", names.contains("write_file") {
                projection.actions.append(.init(label: "Create a file named…", action: .createFile(
                    directory: NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot).path), needsText: true))
            }
            for name in place.tools where name != place.tool && names.contains(name) {
                if id == "create", name == "write_file" { continue }
                if projection.actions.contains(where: {
                    if case .configure(let tool, _, _) = $0.action { return name == tool }
                    if case .perform(let tool, _, _, _, _) = $0.action { return name == tool }
                    return false
                }) { continue }
                projection.actions.append(AgentWorkspaceApps.quickAction(tool: name)
                    ?? .init(label: title(name), action: .configure(tool: name, input: [:], title: title(name))))
            }
            return projection
        case .capabilities(let query):
            let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let schemas = try await catalog()
            var matches: [(schema: LLMToolSchema, score: Int)] = []
            for schema in schemas where browsable(schema) {
                let text = (schema.name + " " + schema.description).lowercased()
                let nameTerms = schema.name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                // An exact action name must outrank incidental words in another
                // action's description. This changes discovery, never dispatch.
                let exactName = !terms.isEmpty && terms == nameTerms
                let score = terms.reduce(0) { $0 + (text.contains($1) ? 1 : 0) + (nameTerms.contains($1) ? 4 : 0) }
                    + (exactName ? 1000 : 0)
                if terms.isEmpty || score > 0 { matches.append((schema, score)) }
            }
            matches.sort { left, right in
                if left.score == right.score { return left.schema.name < right.schema.name }
                return left.score > right.score
            }
            let items: [AgentWorkspaceItem] = matches.map { match in
                let schema = match.schema
                return AgentWorkspaceItem(title: title(schema.name),
                    content: .object(["about": .string(String(schema.description.prefix(260)))]),
                    actions: [AgentWorkspaceApps.quickAction(tool: schema.name)
                        ?? .init(label: "Open", action: .configure(tool: schema.name, input: [:], title: title(schema.name)))])
            }
            return .init(title: "Available actions", content: .object(["status": .string("ok"),
                "query": .string(query), "note": .string("Live capability catalog. Opening an action shows its current form; permission and connection checks happen at its owner.")]),
                items: items, actions: [])
        case .form(let form): return form.projection
        case .receipt(let tool, let title, let value, let readback):
            var projection = AgentWorkspaceProjection.project(location: .record(tool: tool, input: [:], title: title), result: value)
            projection.title = title
            projection.content = .object(["status": outcome(value), "result": projection.content,
                "evidence": .string("Retained result of the selected action. Refresh does not execute it again and does not verify that an external state is still current.")])
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
               case .string(let lease)? = receipt["leaseId"] {
                projection.actions.insert(.init(label: "Read this browser page", action: .open(.record(tool: "browser.chrome_snapshot", input: ["lease_id": .string(lease), "max_nodes": .int(80), "max_text_chars": .int(10_000)], title: "Browser page"))), at: 0)
            }
            return projection
        case .page(let source, let page):
            var projection: AgentWorkspaceProjection
            if let view = try await view(location: source, dataRoot: dataRoot, catalog: catalog, perform: perform) { projection = view }
            else {
                let value: JSONValue
                switch source {
                case .record(let tool, var input, _):
                    guard readTools.contains(tool) else { return nil }
                    if tool == "desk_read" { input["structured"] = .bool(true) }
                    value = try await perform(tool, input)
                case .work(let query): value = try await perform("work_context", ["query": .string(query)])
                case .documents(let query): value = try await perform("artifact_find", ["query": .string(query), "limit": .int(6)])
                case .people: value = try await perform("agent_contacts", [:])
                default: return nil
                }
                projection = .project(location: source, result: value)
            }
            projection.page = max(0, page)
            return projection
        default: return nil
        }
    }
}
