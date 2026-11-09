import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `AgentScreenRooms+Core.swift` | `AgentScreen`: `familyRoom`, `coreAction`, `coreProjection` |

/// Named families expose action arguments when no dedicated room claims the name.
extension AgentScreen {
    struct Family { let name: String; let about: String; let tools: [String] }

    static let families: [Family] = [
        .init(name: "contacts", about: "people in Contacts", tools: ["contacts_"]),
        .init(name: "notes", about: "Apple Notes", tools: ["notes."]),
        .init(name: "music", about: "Music: playing, library, playlists", tools: ["music."]),
        .init(name: "clipboard", about: "the Mac clipboard", tools: ["clipboard_"]),
        .init(name: "images", about: "make a picture", tools: ["image_generate"]),
    ]

    static func familyRoom(workspace: WorkspaceOperation, _ raw: String, catalog: AgentWorkspace.Catalog) async throws -> String? {
        let name = AppDoorNames.resolve(raw)
        guard let family = families.first(where: { $0.name == name }) else { return nil }
        func member(_ tool: String) -> Bool {
            family.tools.contains { $0 == tool || (($0.hasSuffix("_") || $0.hasSuffix(".")) && tool.hasPrefix($0)) }
        }
        let schemas = try await catalog().filter { member($0.name) }
        let port = workspace.ports.tools
        let visible = port.modelVisibleCatalogToolNames(Set(schemas.map(\.name)))
        // Folded tools must retain their exact app action name.
        let tools = schemas.filter { visible.contains($0.name) || port.appAction($0.name) != nil }.sorted { $0.name < $1.name }
        let shown = tools.prefix(8)
        var rows: [String] = [], verbs: [(String, String)] = []
        for schema in shown {
            let args = try ToolSignature.argumentNames(schema.parametersJSON)
            rows.append(clip(sentence(schema.description), 90))
            let needs = args.required.isEmpty ? "needs nothing" : "needs " + args.required.joined(separator: ", ")
            let also = args.optional.isEmpty ? "" : " · also " + args.optional.prefix(4).joined(separator: ", ")
                + (args.optional.count > 4 ? " +\(args.optional.count - 4)" : "")
            let action = port.appAction(schema.name)
            rows.append("    " + clip((action.map { "app " + $0 } ?? schema.name) + " · " + needs + also, 100))
            let schemaValue = try JSONValue.parse(schema.parametersJSON)
            let example = try ToolSignature.example(schemaValue, name: "args").serialize(pretty: false)
            verbs.append((action.map { "app {\"action\":\"\($0)\",\"args\":\(example)}" } ?? schema.name + " " + example, "one call"))
        }
        if tools.count > shown.count {
            rows.append("+\(tools.count - shown.count) more · app {\"find\":\"\(family.name)\"}")
        }
        return screen([family.name.uppercased(), family.about, tools.isEmpty ? "not available here" : "\(tools.count) actions"],
            [tools.isEmpty ? ["no actions from this family are exposed in this session"] : rows],
            verbs: verbs.isEmpty ? [("home", "back to your home screen")] : verbs)
    }
}

/// Use app {find} for action discovery; rooms expose only their own offered verbs.
extension AgentScreen {
    static let coreDestinations: [AgentWorkspaceDestination] = [
        .init(id: "notify", title: "Notify", summary: "Send a notification now to this Mac or the paired phone; no read.",
              tool: nil, tools: ["mac_notify", "mobile_notify"]),
        .init(id: "status", title: "Status", summary: "Health: doctor, Telegram, Mac. Turns: app {action:\"trace.recent\"}; time: app {action:\"time.now\"}.",
              tool: nil, tools: ["system_info"]),
        // Home must not trigger activity reads.
        .init(id: "activity", title: "Activity", summary: "On-device app use and duration; read only when asked.",
              tool: nil, tools: ["activity_query"]),
    ]

    static let coreReadTools: Set<String> = ["system_info", "recent_trace_summary", "time_now", "activity_query"]

    /// Only explicitly supported reads become records; other results retain their full frame.
    static let coreRooms: [String: String] = ["app": "status", AgentWorkspaceKnowledge.webSearchTool: "research"]

    static func coreAction(tool: String) -> AgentWorkspaceButton? {
        func read(_ label: String) -> AgentWorkspaceButton { .init(label: label, action: .open(.record(tool: tool, input: [:], title: label))) }
        switch tool {
        case "mac_notify", "mobile_notify":
            let label = tool == "mac_notify" ? "Mac notification" : "Phone notification"
            return .init(label: label, action: .perform(tool: tool, input: ["title": .string("NativeAgent")], title: label,
                                                        textField: "message", isEffect: true), needsText: true)
        case "system_info": return read("System info for this Mac")
        case "activity_query":
            return .init(label: "Today", action: .open(.record(tool: tool, input: ["range": .string("today")], title: "Activity today")))
        default: return nil
        }
    }

    /// Show failed checks before healthy ones so the needed repair leads.
    static func coreProjection(tool: String, input: [String: JSONValue], result: JSONValue) -> WorkspacePage? {
        guard tool == "app", input["item"] == .string("doctor"), case .object(let read) = result,
              case .object(let row)? = read["item"], row["checks"] != nil else { return nil }
        func text(_ value: JSONValue?) -> String? { if case .string(let s)? = value, !s.isEmpty { return s }; return nil }
        let checks: [[String: JSONValue]] = { if case .array(let list)? = row["checks"] { return list.compactMap { if case .object(let o) = $0 { o } else { nil
            } } }; return [] }()
        let bad = checks.filter { text($0["status"]) != "ok" }
        let overall = text(row["overall_status"]) ?? text(row["active_path_status"]) ?? text(row["status"]) ?? "unknown"
        let items = (bad + checks.filter { text($0["status"]) == "ok" }).map { check in
            var content = check
            content["summary"] = check["repair_face"] ?? check["detail"] ?? .null
            var actions: [AgentWorkspaceButton] = []
            if case .object(let remedy)? = check["remedy"],
               case .object(let call)? = remedy["next_call"], let tool = text(call["tool"]),
               case .object(let input)? = call["input"] {
                actions.append(.init(label: "Repair", action: .perform(tool: tool, input: input,
                    title: text(check["title"]) ?? "Repair", textField: nil, isEffect: true)))
            }
            return AgentWorkspaceItem(title: (text(check["title"]) ?? text(check["id"]) ?? "Check") + " · " + (text(check["status"]) ?? "?")
                                   + (text(check["owner"]).map { " · owner " + $0 } ?? ""),
                               content: .object(content), actions: actions)
        }
        return .init(title: "Doctor", content: .object(["status": .string("ok"),
            "message": .string("Last report · Overall \(overall): \(checks.count - bad.count) of \(checks.count) checks ok.")]), items: items,
            actions: [.init(label: "Refresh report", action: .open(.record(tool: tool, input: input, title: "Doctor")))])
    }
}
