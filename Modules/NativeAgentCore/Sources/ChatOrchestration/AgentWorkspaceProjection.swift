import Foundation
import PersistenceCore

/// A view of an owner's returned evidence. This layer neither reads sources nor
/// interprets prose as instructions, permissions, completion, or fresh state.
extension AgentWorkspaceProjection {
    static func project(location: AgentWorkspaceLocation, result: JSONValue) -> Self {
        // The actual owner receipt retains diagnostics. Navigation needs its
        // evidence, not a second copy of per-call organism instrumentation.
        var result = result
        if case .object(var row) = result {
            row.removeValue(forKey: "organism_posture")
            result = .object(row)
        }
        switch location {
        case .home:
            return .init(title: "Workspace", content: result, items: [], actions: [])
        case .work(let query):
            return workspaceWork(query: query, result: result)
        case .documents(let query):
            return workspaceDocuments(query: query, result: result)
        case .people(let page):
            return workspaceContacts(result: result, page: page)
        case .form(let form): return form.projection
        case .page(let source, let page):
            var view = project(location: source, result: result); view.page = page; return view
        case .area, .capabilities, .receipt, .openPlaces, .workOverview, .savedWorkspaces, .browserBookmark, .conversations, .arrivals, .find:
            return .init(title: location.title, content: result, items: [], actions: [])
        case .record(let tool, let input, _):
            let title = location.title
            if tool == "work_context", let query = workspaceText(input["query"]) {
                return workspaceWork(query: query, result: result, input: input)
            }
            if tool == "agent_contacts" { return workspaceContacts(result: result) }
            if tool == "chat_conversations" { return AgentWorkspaceHumanProjection.project(input: input, result: result) }
            if tool == "agent_read" { return AgentWorkspaceConversation.project(input: input, title: title, result: result) }
            if var projection = AgentWorkspaceKnowledge.project(tool: tool, input: input, result: result)
                ?? AgentWorkspaceApps.project(tool: tool, input: input, result: result)
                ?? AgentWorkspaceActivity.project(tool: tool, input: input, result: result) {
                projection.title = title
                return projection
            }
            var actions: [AgentWorkspaceButton] = []
            if tool == "read_file", let row = workspaceObject(result),
                      row["has_more"] == .bool(true), let next = workspaceObject(row["next"]),
                      next["path"] == input["path"],
                      let button = workspaceReadButton(tool: "read_file", arguments: next,
                                                       label: "Read more", title: title) {
                actions.append(button)
            } else if tool == "read_chat_message", let row = workspaceObject(result),
                      row["status"] == .string("ok"), row["has_more"] == .bool(true),
                      let session = workspaceText(input["session_id"]),
                      let message = workspaceText(input["message_id"]),
                      row["session_id"] == .string(session), row["message_id"] == .string(message),
                      let offset = row["next_offset"] {
                var next: [String: JSONValue] = ["session_id": .string(session),
                    "message_id": .string(message), "offset": offset]
                if let limit = input["limit"] { next["limit"] = limit }
                if let button = workspaceReadButton(tool: tool, arguments: next,
                                                     label: "Read more", title: title) {
                    actions.append(button)
                }
            }
            if tool == "read_chat_message", case .string(let session)? = input["session_id"] {
                actions.append(.init(label: "Open this conversation", action: .open(.record(
                    tool: "chat_conversations", input: ["conversation_session_id": .string(session)], title: "Conversation with you"))))
            }
            // In particular, desk_read may return plain rendered text. Never
            // discover actions by parsing that text or nested receipt content.
            if tool == "read_file", let path = workspaceText(input["path"]),
               AgentWorkspaceDocument.evidence(result) != nil {
                actions.append(.init(label: "Add to this file", action: .perform(tool: "write_file",
                    input: ["path": .string(path), "append": .bool(true)], title: "Add to " + title,
                    textField: "content", isEffect: true), needsText: true))
            }
            if tool == "read_file", let file = AgentWorkspaceFileRevision(input: input, title: title, result: result) {
                actions.append(.init(label: "Revise this file", action: .reviseFile(file)))
            }
            let links = tool == "read_file" ? documentLinks(result) : []
            return .init(title: title, content: result, items: links, actions: actions)
        }
    }

    /// Ordinary hyperlinks in the returned text window, not instructions or
    /// inferred tasks. Nothing opens until its explicit button is selected.
    private static func documentLinks(_ result: JSONValue) -> [AgentWorkspaceItem] {
        guard let evidence = AgentWorkspaceDocument.evidence(result),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let text = String(evidence.text.prefix(12000))
        var seen = Set<String>()
        var links: [AgentWorkspaceItem] = []
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, url.user == nil, url.password == nil,
                  url.absoluteString.utf8.count <= 8192, seen.insert(url.absoluteString).inserted else { continue }
            let title = String((host + url.path).prefix(160))
            links.append(.init(title: title, content: .object(["kind": .string("link_in_document"), "url": .string(url.absoluteString)]), actions: [
                .init(label: "Read source", action: .open(.record(tool: "read_page", input: ["url": .string(url.absoluteString)], title: title))),
                .init(label: "Open in background browser", action: .perform(tool: "browser.chrome_acquire",
                    input: ["mode": .string("create"), "initial_url": .string(url.absoluteString)], title: title, textField: nil, isEffect: true))
            ]))
            if links.count == 6 { break }
        }
        return links
    }

    private static func workspaceWork(query: String, result: JSONValue, input: [String: JSONValue] = [:]) -> Self {
        guard var content = workspaceObject(result) else {
            return .init(title: "Work: " + query, content: result, items: [], actions: [])
        }
        var items: [AgentWorkspaceItem] = []
        var actions: [AgentWorkspaceButton] = [.init(label: "Related documents", action: .open(.documents(query)))]
        var request = input; request["query"] = .string(query)
        if var lane = workspaceObject(content["current_work"]),
           case .array(let records)? = lane["items"] {
            for record in records {
                let row = workspaceObject(record) ?? [:]
                let title = "Current work: " + (workspaceText(row["title"]) ?? "Recorded work")
                let actions = workspaceReadButton(row["read_locator"], label: "Open work", title: title,
                                                 expectedTool: "desk_read").map { [$0] } ?? []
                items.append(.init(title: title, content: record, actions: actions))
            }
            if let more = AgentWorkspaceWork.continuation(lane["next_read"], tool: "work_context", input: request,
                changing: "desk_offset", label: "More matching work", title: "Work: " + query) { actions.append(more) }
            lane.removeValue(forKey: "items")
            content["current_work"] = .object(lane)
        }
        if var lane = workspaceObject(content["supporting_history"]),
           case .array(let records)? = lane["excerpts"] {
            for record in records {
                let row = workspaceObject(record) ?? [:]
                let name = workspaceText(row["session_title"]) ?? "Conversation excerpt"
                let date = workspaceText(row["timestamp"]).map { " — " + $0 } ?? ""
                let title = "History: " + name + date
                let actions = workspaceReadButton(row["read_locator"], label: "Open source", title: title,
                                                 expectedTool: "read_chat_message").map { [$0] } ?? []
                items.append(.init(title: title, content: record, actions: actions))
            }
            if let more = AgentWorkspaceWork.continuation(lane["next_read"], tool: "work_context", input: request,
                changing: "history_offset", label: "More conversation evidence", title: "Work: " + query) { actions.append(more) }
            lane.removeValue(forKey: "excerpts")
            content["supporting_history"] = .object(lane)
        }
        // Lane metadata retains source, as-of time, meaning and coverage;
        // records appear once as selectable items rather than twice in output.
        return .init(title: "Work: " + query, content: .object(content), items: items,
                     actions: actions)
    }

    private static func workspaceDocuments(query: String, result: JSONValue) -> Self {
        guard var content = workspaceObject(result), case .array(let records)? = content["artifacts"] else {
            return .init(title: "Documents: " + query, content: result, items: [], actions: [])
        }
        let items = records.map { record -> AgentWorkspaceItem in
            let row = workspaceObject(record) ?? [:]
            let title = workspaceText(row["name"]) ?? "Recorded document"
            var actions: [AgentWorkspaceButton] = []
            if let button = workspaceReadButton(row["open_current_file"], label: "Open current file", title: title,
                                                expectedTool: "read_file") {
                actions.append(button)
            }
            if let source = workspaceObject(row["source_message"]),
               let button = workspaceReadButton(source["read"], label: "Open source conversation", title: title,
                                                expectedTool: "read_chat_message") {
                actions.append(button)
            }
            if let button = workspaceReadButton(row["read_context"], label: "Open source work", title: title,
                                                expectedTool: "desk_read") {
                actions.append(button)
            }
            return .init(title: title, content: record, actions: actions)
        }
        content.removeValue(forKey: "artifacts")
        return .init(title: "Documents: " + query, content: .object(content), items: items, actions: [])
    }

    private static func workspaceContacts(result: JSONValue, page: Int = 0) -> Self {
        guard var content = workspaceObject(result), case .array(let contacts)? = content["contacts"] else {
            return .init(title: "People", content: result, items: [], actions: [])
        }
        let offset = max(0, page) * 8
        let items = contacts.dropFirst(offset).prefix(8).map { contact -> AgentWorkspaceItem in
            let row = workspaceObject(contact) ?? [:]
            let title = workspaceText(row["name"]) ?? workspaceText(row["agent"]) ?? "Contact"
            var actions: [AgentWorkspaceButton] = []
            if let agent = workspaceText(row["agent"]), workspaceExactAgent(agent),
               case .array(let capabilities)? = row["capabilities"] {
                if capabilities.contains(.string("read")) {
                    actions.append(.init(label: "Open conversation", action: .open(.record(
                        tool: "agent_read", input: ["agent": .string(agent)], title: title))))
                }
                if capabilities.contains(.string("message")), row["can_start_turn"] != .bool(false) {
                    actions.append(.init(label: "Message", action: .message(agent: agent, conversation: nil, name: title), needsText: true))
                }
            }
            // Readiness, route limits and declared capabilities remain the
            // contact owner's words. A button is never a presence assertion.
            // 2026-09-22: an unchecked readiness says nothing; the owner receipt keeps the detail.
            let visible: Set<String> = ["name", "kind", "state", "readiness", "can_start_turn", "can_answer_back"]
            return .init(title: title, content: .object(row.filter {
                visible.contains($0.key) && !($0.key == "readiness" && $0.value == .string("not_checked")) }), actions: actions)
        }
        // Connection commands, endpoint/credential metadata and protocol
        // recipes stay in the discoverable agent_contacts owner receipt.
        // They are not necessary for choosing a person and talking.
        content = content.filter { ["status", "detail"].contains($0.key) }
        content["total_contacts"] = .int(Int64(contacts.count))
        content["page"] = .int(Int64(page))
        var actions: [AgentWorkspaceButton] = []
        if offset + 8 < contacts.count {
            actions.append(.init(label: "More people", action: .open(.people(page: page + 1))))
        }
        if page > 0 {
            actions.append(.init(label: "Previous people", action: .open(.people(page: page - 1))))
        }
        return .init(title: "People", content: .object(content), items: items, actions: actions)
    }

    private static func workspaceExactAgent(_ value: String) -> Bool {
        if ["codex", "claude", "omp"].contains(value) { return true }
        guard value.count <= 480 else { return false }
        for prefix in ["peer:", "bot:"] where value.hasPrefix(prefix) {
            let identifier = value.dropFirst(prefix.count)
            return !identifier.isEmpty && !identifier.contains(where: { $0.isWhitespace || $0.isNewline })
        }
        return false
    }

    /// Only called at explicitly owned locator fields, never recursively. A
    /// malformed or broader request is rejected rather than silently narrowed.
    private static func workspaceReadButton(_ locator: JSONValue?, label: String, title: String,
                                             expectedTool: String? = nil) -> AgentWorkspaceButton? {
        guard let locator = workspaceObject(locator),
              Set(locator.keys).isSubset(of: ["tool", "arguments", "input"]),
              let tool = workspaceText(locator["tool"]),
              expectedTool == nil || tool == expectedTool,
              (locator["arguments"] == nil) != (locator["input"] == nil),
              let arguments = workspaceObject(locator["arguments"] ?? locator["input"]) else { return nil }
        return workspaceReadButton(tool: tool, arguments: arguments, label: label, title: title)
    }

    private static func workspaceReadButton(tool: String, arguments: [String: JSONValue],
                                             label: String, title: String) -> AgentWorkspaceButton? {
        let required: Set<String>
        let strings: Set<String>
        let numbers: Set<String>
        switch tool {
        case "read_file":
            required = ["path"]; strings = ["path", "version"]; numbers = ["offset", "max_bytes"]
        case "read_chat_message":
            required = ["message_id", "session_id"]
            strings = required; numbers = ["offset", "limit"]
        case "desk_read":
            required = ["handle"]; strings = required; numbers = []
        default: return nil
        }
        guard Set(arguments.keys).isSubset(of: strings.union(numbers)),
              required.allSatisfy({ workspaceText(arguments[$0]) != nil }) else { return nil }
        for (key, value) in arguments {
            if strings.contains(key) {
                guard workspaceText(value) != nil else { return nil }
            } else {
                guard case .int(let number) = value, number >= 0 else { return nil }
                if key != "offset", number == 0 { return nil }
            }
        }
        if tool == "read_file", case .int(let offset)? = arguments["offset"], offset > 0,
           workspaceText(arguments["version"]) == nil { return nil }
        var input = arguments
        if tool == "read_file", input["max_bytes"] == nil { input["max_bytes"] = .int(12_000) }
        return .init(label: label, action: .open(.record(tool: tool, input: input, title: title)))
    }

    private static func workspaceObject(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let object)? = value else { return nil }
        return object
    }

    private static func workspaceText(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
