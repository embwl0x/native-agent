import Foundation
import PersistenceCore

/// Work navigation binds only canonical handles and typed owner continuations.
/// Free text, archived claims and nested recipes never become executable work.
enum AgentWorkspaceWork {
    static func desk(input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection {
        var content = object(result)
        var actions = [open("Shared work", tool: "task_ledger_list"), open("Delegated work", tool: "delegation_status"),
                       configure("Add work", tool: "desk_add_item")]
        var items: [AgentWorkspaceItem] = []
        if content["status"] == .string("record_changed"), let handle = text(input["handle"]), content["handle"] == .string(handle) {
            actions.append(open("Reopen complete record", tool: "desk_read", input: ["handle": .string(handle), "detail_offset": .int(0)]))
        }
        guard content["status"] == .string("ok") else {
            return .init(title: "Ongoing work", content: result, items: [], actions: actions)
        }
        let record = object(content["record"])
        let selectedHandle = text(record["handle"])
        if let selectedHandle, input["handle"] != nil {
            actions += [configure("Add a note", tool: "desk_note", input: ["handle": .string(selectedHandle)]),
                        configure("Update work", tool: "desk_update_item", input: ["handle": .string(selectedHandle)]),
                        configure("Update status", tool: "desk_set_status", input: ["handle": .string(selectedHandle)]),
                        configure("Link evidence", tool: "desk_add_ref", input: ["handle": .string(selectedHandle)]),
                        configure("Add part", tool: "desk_add_item", input: ["parent": .string(selectedHandle)])]
            if let parent = recordRead(record["parent_read"], label: "Parent work", title: "Parent work") { actions.append(parent) }
            if input["detail_offset"] == nil {
                actions.append(open("Read complete record", tool: "desk_read", input: ["handle": .string(selectedHandle), "detail_offset": .int(0)], title: text(record["title"])))
            } else if content["has_more_details"] == .bool(true),
                      case .int(let next)? = content["next_detail_offset"], next > 0,
                      let version = text(content["detail_version"]), version.count == 64,
                      version.allSatisfy({ $0.isHexDigit }),
                      content["detail_offset"] == input["detail_offset"] {
                actions.append(open("Continue complete record", tool: "desk_read", input: ["handle": .string(selectedHandle), "detail_offset": .int(next), "detail_version": .string(version)], title: text(record["title"])))
            }
            let sequence = object(record["sequencing"])
            for locator in array(sequence["blocking_items"]) {
                if let button = recordRead(locator, label: "Open dependency", title: "Dependency") { actions.append(button) }
            }
        }
        for value in array(content["items"]) {
            let row = object(value)
            let title = text(row["title"]) ?? "Recorded work"
            let buttons = recordRead(row["read_locator"], label: "Open work", title: title).map { [$0] } ?? []
            items.append(.init(title: title, content: value, actions: buttons))
        }
        for value in array(content["linked_evidence"]) {
            let row = object(value)
            let title = text(row["label"]) ?? text(row["title"]) ?? text(row["path"]) ?? text(row["url"]) ?? "Linked evidence"
            var buttons: [AgentWorkspaceButton] = []
            switch text(row["kind"]) {
            case "file":
                if let path = text(row["path"]), path.count <= 4096, !path.contains("[truncated;") {
                    buttons.append(open("Open current file", tool: "read_file", input: ["path": .string(path), "max_bytes": .int(12_000)], title: title))
                }
            case "url":
                if let url = text(row["url"]), let parsed = URL(string: url),
                   ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil,
                   url.count <= 4096, !url.contains("[truncated;") {
                    buttons.append(open("Read source", tool: "read_page", input: ["url": .string(url)], title: title))
                }
            default: break
            }
            items.append(.init(title: title, content: value, actions: buttons))
        }
        // Preserve the selected canonical identity when its visible alias was
        // supplied. Only this owner response resolves aliases to handles.
        var pagingInput = input
        if let selectedHandle { pagingInput["handle"] = .string(selectedHandle) }
        for (field, offset, label) in [("next_read", "offset", selectedHandle == nil ? "More work" : "More parts"),
                                       ("next_notes", "notes_offset", "Earlier notes"), ("next_links", "refs_offset", "More linked evidence")] {
            if let button = continuation(content[field], tool: "desk_read", input: pagingInput, changing: offset, label: label, title: text(record["title"]) ?? "Ongoing work") { actions.append(button) }
        }
        content.removeValue(forKey: "items"); content.removeValue(forKey: "linked_evidence")
        return .init(title: text(record["title"]) ?? "Ongoing work", content: .object(content), items: items, actions: actions)
    }

    static func continuation(_ value: JSONValue?, tool: String, input: [String: JSONValue], changing: String, label: String, title: String) -> AgentWorkspaceButton? {
        let locator = object(value)
        guard Set(locator.keys) == ["tool", "arguments"], locator["tool"] == .string(tool),
              case .object(let next)? = locator["arguments"] else { return nil }
        let offsets: Set<String> = tool == "desk_read" ? ["offset", "notes_offset", "refs_offset"] : ["desk_offset", "history_offset"]
        let identities: Set<String> = tool == "desk_read" ? ["handle", "query"] : ["query", "session_id"]
        let allowed = offsets.union(identities).union(tool == "desk_read" ? ["structured"] : ["limit"])
        guard offsets.contains(changing), Set(next.keys).isSubset(of: allowed),
              identities.allSatisfy({ normalized(next[$0]) == normalized(input[$0]) }) else { return nil }
        if tool == "desk_read" { guard next["structured"] == .bool(true) else { return nil } }
        else {
            guard text(next["query"]) != nil,
                  next["limit"] == (normalized(input["limit"]) ?? .int(3)) else { return nil }
        }
        for key in offsets {
            guard case .int(let value)? = next[key], value >= 0, value <= 1_000_000 else { return nil }
            let prior: Int64
            if case .int(let old)? = input[key] { prior = old } else { prior = 0 }
            guard key == changing ? value > prior : value == prior else { return nil }
        }
        return open(label, tool: tool, input: next, title: title)
    }

    private static func recordRead(_ value: JSONValue?, label: String, title: String) -> AgentWorkspaceButton? {
        let locator = object(value), args = object(locator["arguments"])
        guard Set(locator.keys) == ["tool", "arguments"], locator["tool"] == .string("desk_read"),
              Set(args.keys) == ["handle"], let handle = text(args["handle"]) else { return nil }
        return open(label, tool: "desk_read", input: ["handle": .string(handle)], title: title)
    }
    private static func normalized(_ value: JSONValue?) -> JSONValue? { value == .null ? nil : value }
    private static func object(_ value: JSONValue?) -> [String: JSONValue] { if case .object(let row)? = value { return row }; return [:] }
    private static func array(_ value: JSONValue?) -> [JSONValue] { if case .array(let rows)? = value { return rows }; return [] }
    private static func text(_ value: JSONValue?) -> String? { if case .string(let s)? = value, !s.isEmpty { return s }; return nil }
    private static func open(_ label: String, tool: String, input: [String: JSONValue] = [:], title: String? = nil) -> AgentWorkspaceButton {
        .init(label: label, action: .open(.record(tool: tool, input: input, title: title ?? label)))
    }
    private static func configure(_ label: String, tool: String, input: [String: JSONValue] = [:]) -> AgentWorkspaceButton {
        .init(label: label, action: .configure(tool: tool, input: input, title: label))
    }
}
