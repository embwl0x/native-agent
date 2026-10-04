import Foundation
import NativeAgentCore
import PersistenceCore

/// Families on her screen (2026-09-24, tool discovery). Every capability is a
/// name she can open, the way a person opens an app: home's PLACES lists the
/// families, and a family with no room of its own opens as its actions, one
/// line per tool with the arguments it takes, so the next call is that tool.
/// tool_catalog was her discovery path (188 calls in September, half followed
/// by a separate tool_load); this is the one a person would use.
///
/// Rooms other slices build (mail, calendar, browser…) resolve first; this is
/// only what a name opens when nothing else claims it.
extension HerScreen {
    struct Family { let name: String; let about: String; let tools: [String] }

    /// A tool belongs when it is named here or starts with an entry ending in
    /// `_` or `.`.
    static let families: [Family] = [
        .init(name: "contacts", about: "people in Contacts", tools: ["contacts_"]),
        .init(name: "notes", about: "Apple Notes", tools: ["notes_"]),
        .init(name: "music", about: "Music: playing, library, playlists", tools: ["music_"]),
        .init(name: "markets", about: "quotes and watchlists", tools: ["market_", "tradingview_"]),
        .init(name: "x", about: "X (Twitter)", tools: ["x_"]),
        .init(name: "slack", about: "Slack", tools: ["slack_"]),
        .init(name: "notion", about: "Notion", tools: ["notion_"]),
        .init(name: "clipboard", about: "the Mac clipboard", tools: ["clipboard_"]),
        .init(name: "images", about: "make a picture", tools: ["image_generate"]),
    ]

    /// Words people use for a place under another name.
    static let familyAliases: [String: String] = [
        "bots": "helpers", "bot": "helpers", "twitter": "x",
        "stocks": "markets", "notifications": "notify", "health": "status", "doctor": "status",
    ]

    /// Home's PLACES row for this slice's families; the other slices' families
    /// sit on their own rows (and open here by name only if nothing claims them).
    static let familyLine = ["notify", "status", "activity", "app"].joined(separator: " · ")

    /// A family's actions as a text room, or nil when the name is not a family.
    static func familyRoom(_ raw: String, catalog: AgentWorkspace.Catalog) async throws -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let family = families.first(where: { $0.name == name }) else { return nil }
        func member(_ tool: String) -> Bool {
            family.tools.contains { $0 == tool || (($0.hasSuffix("_") || $0.hasSuffix(".")) && tool.hasPrefix($0)) }
        }
        let schemas = try await catalog().filter { member($0.name) }
        let port = AgentWorkspacePorts.current.tools
        let visible = port.modelVisibleCatalogToolNames(Set(schemas.map(\.name)))
        // A tool folded into app is that app action: the line names it so.
        let tools = schemas.filter { visible.contains($0.name) || port.appAction($0.name) != nil }.sorted { $0.name < $1.name }
        // A room, not a schema dump (desk walk 09-24): what each thing does in
        // words, what it needs, and the one call that does it.
        let shown = tools.prefix(8)
        var rows: [String] = [], verbs: [(String, String)] = []
        for schema in shown {
            let args = ToolSignature.argumentNames(schema.parametersJSON)
            rows.append(clip(sentence(schema.description), 90))
            let needs = args.required.isEmpty ? "needs nothing" : "needs " + args.required.joined(separator: ", ")
            let also = args.optional.isEmpty ? "" : " · also " + args.optional.prefix(4).joined(separator: ", ")
                + (args.optional.count > 4 ? " +\(args.optional.count - 4)" : "")
            let action = port.appAction(schema.name)
            rows.append("    " + clip((action.map { "app " + $0 } ?? schema.name) + " · " + needs + also, 100))
            let example = args.required.isEmpty ? "{}" : "{" + args.required.map { "\"\($0)\":…" }.joined(separator: ",") + "}"
            verbs.append((action.map { "app {\"action\":\"\($0)\",\"args\":\(example)}" } ?? schema.name + " " + example, "one call"))
        }
        if tools.count > shown.count {
            rows.append("+\(tools.count - shown.count) more · app {\"find\":\"\(family.name)\"}")
        }
        return screen([family.name.uppercased(), family.about, tools.isEmpty ? "not available here" : "\(tools.count) things to do"],
            [tools.isEmpty ? ["none of its tools are on in this session (a connection or a Trust setting is off)"] : rows],
            verbs: verbs.isEmpty ? [("home", "back to your home screen")] : verbs)
    }
}

/// Her own places as rooms like mail and music (desk walk 2, 09-24): notify
/// and status read as what the place is and its verbs in words
/// (`notify.mac`, `status.doctor`), never raw tool names. Finding an action
/// is app {find}; there is no tools room.
extension HerScreen {
    static let coreDestinations: [AgentWorkspaceDestination] = [
        .init(id: "notify", title: "Notify", summary: "Send a notification to this Mac or to the paired phone. Both send at once; nothing is read here.",
              tool: nil, tools: ["mac_notify", "mobile_notify"]),
        .init(id: "status", title: "Status", summary: "How the app and its links are doing: the doctor check, Telegram, this Mac. Recent turns and the time are app trace.recent and app time.now.",
              tool: nil, tools: ["system_info"]),
        // A room, not a tool listing (walk 4: "1 things to do"). Nothing is read until a verb asks.
        .init(id: "activity", title: "Activity", summary: "Which Mac apps were in use, and for how long, from the on-device activity record. Nothing is read until you ask.",
              tool: nil, tools: ["activity_query"]),
    ]

    /// activity_query: the activity family's read, which its room (buildRecordRoom) lays out.
    static let coreReadTools: Set<String> = ["system_info", "recent_trace_summary", "time_now", "activity_query"]

    /// A reading of these shows in its room; the rest keep their frame. The
    /// only `app` reads opened as records are Status's Doctor and Telegram.
    static let coreRooms: [String: String] = ["app": "status", AgentWorkspaceKnowledge.webSearchTool: "research"]

    /// The verb a room shows for one of its tools, in words.
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

    /// The doctor check as a room: the overall word, then what is not ok first.
    static func coreProjection(tool: String, input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection? {
        guard tool == "app", input["item"] == .string("doctor"), case .object(let read) = result,
              case .object(let row)? = read["item"] else { return nil }
        func text(_ value: JSONValue?) -> String? { if case .string(let s)? = value, !s.isEmpty { return s }; return nil }
        let checks: [[String: JSONValue]] = { if case .array(let list)? = row["checks"] { return list.compactMap { if case .object(let o) = $0 { o } else { nil } } }; return [] }()
        let bad = checks.filter { text($0["status"]) != "ok" }
        let overall = text(row["overall_status"]) ?? text(row["active_path_status"]) ?? text(row["status"]) ?? "unknown"
        let items = (bad + checks.filter { text($0["status"]) == "ok" }).map { check in
            AgentWorkspaceItem(title: (text(check["title"]) ?? text(check["id"]) ?? "Check") + " · " + (text(check["status"]) ?? "?"),
                               content: .object(["summary": check["detail"] ?? .null]), actions: [])
        }
        return .init(title: "Doctor", content: .object(["status": .string("ok"),
            "message": .string("Overall \(overall): \(checks.count - bad.count) of \(checks.count) checks ok.")]), items: items, actions: [])
    }
}
