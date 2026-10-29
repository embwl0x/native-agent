import Foundation
import PersistenceCore
// Blueprint: | `AgentWorkspaceActivity.swift` | Native Calendar/Reminders, shelf and shared-ledger adapters; ledger tasks and timelines carry More actions from the owner's next_offset; Today supplies checked reads and bound item/action keys to `workspace-readout.js`, including separate due-today and overdue count rows; helper selection/copy is owned by that part, not a Swift bot projection. Today starts independent Calendar and Reminders reads together in the requesting context. |

/// Native views over work, helpers and communication owners. Only typed fields
/// at known owner boundaries create actions; prose and embedded recipes do not.
enum AgentWorkspaceActivity {
    static let destinations: [AgentWorkspaceDestination] = [
        .init(id: "ongoing", title: "Ongoing work", summary: "The live Desk and shared work in progress.", tool: "desk_read", input: ["structured": .bool(true)], tools: ["task_ledger_list", "delegation_status", "desk_add_item"]),
        .init(id: "today", title: "Today", summary: "Today's appointments and reminders, with overdue work clearly marked.", tool: nil, tools: ["mac_calendar_list_upcoming", "mac_reminders_list_due_today"]),
        .init(id: "helpers", title: "My helpers", summary: "Talk to a helper, run its job, or adjust its settings.", tool: "bot_list", tools: ["bot_create", "shelf_read"]),
        .init(id: "replies", title: "Saved replies", summary: "Read helpers' newest saved answers and actual outcomes, including answers already read.", tool: "shelf_read", input: ["limit": .int(16), "include_read": .bool(true), "newest_first": .bool(true)]),
        .init(id: "calendar", title: "Calendar", summary: "Upcoming events and appointments.", tool: "mac_calendar_list_upcoming", input: ["limit": .int(16)], tools: ["mac_calendar_create_event"]),
        .init(id: "reminders", title: "Reminders", summary: "Open tasks across all dates, including undated reminders.", tool: "mac_reminders_query", input: ["limit": .int(16)], tools: ["mac_reminders_create", "mac_reminders_query"]),
        .init(id: "mail", title: "Mail", summary: "Recent email, search, and compose.", tool: "mail_list_recent", input: ["limit": .int(16)], tools: ["mail_search", "mail_send"]),
        .init(id: "messages", title: "Messages", summary: "Recent messages and a new message to a chosen recipient.", tool: "messages_recent_threads", input: ["limit": .int(16)], tools: ["messages_send"]),
        .init(id: "connections", title: "Connections", summary: "Find an agent or set up a connection.", tool: "agent_contacts", tools: ["agent_contacts", "agent_connect"])
    ]

    static let readTools: Set<String> = ["bot_list", "shelf_read", "shelf_entry", "desk_read", "task_ledger_list", "delegation_status", "mac_calendar_list_upcoming", "mac_reminders_list_due_today", "mac_reminders_query", "mac_reminders_read", "mail_list_recent", "mail_read_batch", "mail_search", "messages_recent_threads", "mac_calendar_calendars", "mac_calendar_free_busy", "mac_reminders_lists"]

    static func project(tool: String, input: [String: JSONValue], result: JSONValue) -> WorkspacePage? {
        switch tool {
        case "bot_list": return nil
        case "shelf_read": return replies(input: input, result: result)
        case "shelf_entry": return reply(input: input, result: result)
        case "desk_read":
            return AgentWorkspaceWork.desk(input: input, result: result)
        case "task_ledger_list": return tasks(input: input, result: result)
        case "delegation_status": return .init(title: "Delegated work", content: result, items: [], actions: [])
        case "mac_calendar_list_upcoming": return calendar(result)
        case "mac_calendar_calendars", "mac_calendar_free_busy":
            return list(title: "Calendar", result: result, key: "calendars", actions: [
                read("Calendars", tool: "mac_calendar_calendars"),
                configure("Check availability", tool: "mac_calendar_free_busy")
            ]) { row in
                guard let id = row["calendarId"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }) else {
                    return .init(title: row["title"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }) ?? "Calendar", content: .object(row), actions: [])
                }
                var actions = [read("Events", tool: "mac_calendar_list_upcoming", input: ["calendar_id": .string(id)]),
                    configure("Check availability", tool: "mac_calendar_free_busy", input: ["calendar_ids": .array([.string(id)])])]
                if row["writable"] == .bool(true) {
                    actions.append(configure("Create an event", tool: "mac_calendar_create_event", input: ["calendar_id": .string(id)]))
                }
                return .init(title: row["title"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }) ?? id, content: .object(row), actions: actions)
            }
        case "mac_reminders_list_due_today", "mac_reminders_query", "mac_reminders_read", "mac_reminders_lists":
            return reminders(tool: tool, input: input, result)
        case "mail_list_recent", "mail_search": return AgentWorkspaceMail.project(input: input, result: result)
        case "messages_recent_threads": return AgentWorkspaceMessages.project(input: input, result: result)
        default: return nil
        }
    }

    /// A joined view over two existing readers. Selecting Today is the only
    /// trigger; independent reads start together in the requesting context.
    static func today(dataRoot: URL, perform: AgentWorkspace.Perform) async throws -> WorkspacePage {
        var sections: [JSONValue] = [], facts: [JSONValue] = []
        var items: [String: AgentWorkspaceItem] = [:], actions: [String: AgentWorkspaceButton] = [:]
        let calendarSource: (String, String, [String: JSONValue]) =
            ("Calendar", "mac_calendar_list_upcoming", ["day": .string("today"), "limit": .int(8)])
        let remindersSource: (String, String, [String: JSONValue]) =
            ("Reminders", "mac_reminders_list_due_today", ["limit": .int(100)])
        func read(_ tool: String, _ input: [String: JSONValue]) async throws -> JSONValue {
            do { return try await perform(tool, input) }
            catch is CancellationError { throw CancellationError() }
            catch { return .object(["status":.string("unavailable"),"detail":.string(error.localizedDescription)]) }
        }
        async let calendar = read(calendarSource.1, calendarSource.2)
        async let reminders = read(remindersSource.1, remindersSource.2)
        let values = try await [calendar, reminders]
        for ((area, tool, input), result) in zip([calendarSource, remindersSource], values) {
            var value = result
            let field = area == "Calendar" ? "events" : "reminders"
            if value.objectValue?[field]?.arrayValue == nil {
                value = .object(["status": .string("unavailable"),
                    "detail": .string(area + " source did not supply its " + field + " array."), "source": value])
            }
            if area == "Reminders", ["completed", "ok"].contains(value.objectValue?["status"]?.stringValue ?? ""),
               ["today", "overdue"].contains(where: { value.objectValue?[$0]?.objectValue?["reminders"]?.arrayValue == nil }) {
                value = .object(["status": .string("unavailable"),
                    "detail": .string("Reminders source did not supply its today and overdue parts."), "source": value])
            }
            let available = ["completed", "ok"].contains(value.objectValue?["status"]?.stringValue ?? "")
            if let view = project(tool:tool,input:input,result:value) {
                let state = available ? (view.items.isEmpty ? "empty" : "available") : "unavailable"
                sections.append(.object(["area":.string(area),"state":.string(state),"result":view.content,"shown":.int(Int64(view.items.count))]))
                if area == "Reminders", available {
                    for part in ["today", "overdue"] {
                        guard let content = value.objectValue?[part]?.objectValue else { continue }
                        let key = "Reminders:" + part, actionKey = key + ":open"
                        let button = Self.read("Open due reminders", tool: tool, input: input)
                        items[key] = .init(title: part, content: .object(content), actions: [button])
                        actions[actionKey] = button
                        facts.append(.object(["key": .string(key), "reminder_part": .string(part),
                            "count": content["count"] ?? .null, "actions": .array([.string(actionKey)])]))
                    }
                }
                for (index,item) in view.items.enumerated() {
                    let key=area+":"+String(index), row=item.content.objectValue ?? [:]
                    items[key]=item
                    let keys=item.actions.enumerated().map { offset,button -> JSONValue in
                        let id=key+":"+String(offset); actions[id]=button; return .string(id)
                    }
                    let due=row["dueAt"]?.stringValue.flatMap { ISO8601DateFormatter().date(from:$0) }
                    let month=DateFormatter()
                    month.dateFormat=due.map { Calendar.current.isDate($0,equalTo:Date(),toGranularity:.year) } == true ? "MMMM" : "MMMM yyyy"
                    facts.append(.object(["key":.string(key),"area":.string(area),"title":.string(item.title),
                        "overdue":.bool(row["due_status"] == .string("overdue")),
                        "due":due.map { .double($0.timeIntervalSince1970) } ?? .null,
                        "month":due.map { .string(month.string(from:$0)) } ?? .null,"actions":.array(keys)]))
                }
            }
        }
        actions["calendar"]=Self.read("calendar",tool:"mac_calendar_list_upcoming",input:["day":.string("today"),"limit":.int(16)])
        actions["due"]=Self.read("due",tool:"mac_reminders_list_due_today",input:["limit":.int(16)])
        actions["desk"] = .init(label:"desk",action:.open(.area("ongoing")))
        actions["refresh"] = .init(label:"refresh",action:.open(.area("today")))
        let unavailable = sections.filter { $0.objectValue?["state"] == .string("unavailable") }.count
        let status = unavailable == 0 ? "ok" : unavailable == sections.count ? "unavailable" : "partial"
        return await WorkspaceReadout.project(input:.object(["mode":.string("today"),"sections":.array(sections),"rows":.array(facts)]),
            dataRoot:dataRoot,items:items,actions:actions,native:["status":.string(status),"sources":.array(sections)])
    }

    private static func replies(input: [String: JSONValue], result: JSONValue) -> WorkspacePage {
        var actions: [AgentWorkspaceButton] = []
        if let cursor = (result.objectValue ?? [:])["nextCursor"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }) {
            let allowed: Set<String> = ["id", "since", "topic", "limit", "include_read", "sort", "newest_first"]
            var next = input.filter { allowed.contains($0.key) }
            // A successful read has already checked that supplied references agree.
            next["id"] = ["id", "bot_id", "bot", "name"].compactMap { input[$0] }
                .first { $0 != .null && $0 != .string("") }
            next["cursor"] = .string(cursor)
            actions.append(read("More saved replies", tool: "shelf_read", input: next))
        }
        return list(title: "Saved replies", result: result, key: "entries", actions: actions) { row in
            let name = AgentWorkspaceSavedReply.title(.object(row))
            var buttons: [AgentWorkspaceButton] = []
            if let id = uuid(row["id"]), let bot = uuid(row["bot"]) {
                buttons.append(read("Read reply", tool: "shelf_entry", input: ["id": .string(id), "bot_id": .string(bot)],
                                    title: AgentWorkspaceSavedReply.title(.object(row), now: nil)))
                buttons.append(.init(label: "Follow up", action: .followUpSavedReply(.init(
                    entryID: id, botID: bot, title: name)), needsText: true))
            }
            // Preserve queued/failed/completed exactly as the shelf reports it.
            return .init(title: name, content: .object(row), actions: buttons)
        }
    }

    private static func reply(input: [String: JSONValue], result: JSONValue) -> WorkspacePage {
        var actions: [AgentWorkspaceButton] = []
        let row = (result.objectValue ?? [:])
        let title = AgentWorkspaceSavedReply.title(result)
        if let id = uuid(input["id"]), let bot = uuid(input["bot_id"]) {
            var selected = AgentWorkspaceSavedReply(entryID: id, botID: bot, title: title)
            if let evidence = selected.evidence(result) {
                selected.fingerprint = evidence.fingerprint
                actions = [
                    .init(label: "Follow up", action: .followUpSavedReply(selected), needsText: true),
                    read("Open conversation", tool: "agent_read", input: ["agent": .string(selected.agent)],
                         title: row["agent_name"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }) ?? "Helper conversation")
                ]
            }
        }
        var content = row
        if !actions.isEmpty {
            content["follow_up_context"] = .string("Follow up carries this saved reply into the helper’s existing conversation. Its exact source is rechecked before sending; long answers are labeled excerpts. You can return to this reply afterward.")
        }
        return .init(title: title, content: content.isEmpty ? result : .object(content), items: [], actions: actions)
    }

    private static func tasks(input: [String: JSONValue], result: JSONValue) -> WorkspacePage {
        let id = input["task_id"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 })
        let content = (result.objectValue ?? [:])
        var actions: [AgentWorkspaceButton] = []
        if content["has_more"] == .bool(true), case .int(let offset)? = content["next_offset"] {
            var next = input
            next["offset"] = .int(offset)
            actions.append(read(id == nil ? "More shared work" : "More timeline events", tool: "task_ledger_list", input: next))
        }
        if let id {
            actions.append(configure("Record an update", tool: "task_ledger_post", input: ["task_id": .string(id)]))
            return .init(title: "Selected shared work", content: result, items: [], actions: actions)
        }
        actions.append(read("Include finished work", tool: "task_ledger_list", input: ["include_done": .bool(true)]))
        return list(title: "Shared work", result: result, key: "tasks", actions: actions) { row in
            let title = row["title"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }) ?? "Shared work"
            let buttons = row["taskId"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }).map { [read("Open work", tool: "task_ledger_list", input: ["task_id": .string($0)], title: title)] } ?? []
            return .init(title: title, content: .object(row), actions: buttons)
        }
    }

    private static func calendar(_ result: JSONValue) -> WorkspacePage {
        // A day by name in one call (the old "choose" form ran the default read).
        let day = AgentWorkspaceButton(label: "One day", action: .perform(tool: "mac_calendar_list_upcoming", input: ["limit": .int(16)],
            title: "One day", textField: "day", isEffect: false), needsText: true)
        var projection = list(title: "Calendar", result: result, key: "events", actions: [configure("Create an event", tool: "mac_calendar_create_event"),
            read("Calendars", tool: "mac_calendar_calendars"), configure("Check availability", tool: "mac_calendar_free_busy"), day]) { row in
            let title = row["title"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }) ?? "Calendar event"
            var actions = row["id"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }).map { [configure("Edit event", tool: "mac_calendar_modify_event", input: ["id": .string($0)])] } ?? []
            if let id = row["id"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }), let title = row["title"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }), let start = row["startAt"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }) {
                actions.append(configure("Delete this event", tool: "mac_calendar_delete_event", input: [
                    "id": .string(id), "expected_title": .string(title), "expected_start": .string(start)]))
            }
            return .init(title: title, content: .object(row), actions: actions)
        }
        // An empty read says it read fine, so it is not taken for no access.
        if projection.items.isEmpty, (result.objectValue ?? [:])["status"] == .string("completed"), case .object(var content) = projection.content {
            let hours: Int64 = if case .int(let n)? = (result.objectValue ?? [:])["hoursAhead"] { n } else { 24 }
            let span = (result.objectValue ?? [:])["day"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }) ?? "in the next \(hours)h"
            content["message"] = .string("no events \(span) (calendar access ok)")
            projection.content = .object(content)
        }
        return projection
    }

    private static func reminders(tool: String, input: [String: JSONValue], _ result: JSONValue) -> WorkspacePage {
        var source = (result.objectValue ?? [:])
        if tool == "mac_reminders_read", let reminder = source["reminder"] { source["reminders"] = .array([reminder]) }
        var buttons = [configure("Create a reminder", tool: "mac_reminders_create"),
            configure("Find reminders", tool: "mac_reminders_query"),
            read("Due today and overdue", tool: "mac_reminders_list_due_today", input: ["limit": .int(16)])]
        if tool == "mac_reminders_query", case .int(let next)? = source["next_offset"] {
            var arguments = input
            arguments["offset"] = .int(next)
            buttons.append(read("Next page", tool: tool, input: arguments))
        }
        var projection = list(title: "Reminders", result: .object(source), key: "reminders", actions: buttons) { row in
            var row = row
            let title = row["title"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }) ?? "Reminder"
            if tool == "mac_reminders_list_due_today" {
                // Use the part's frozen local day, including across a midnight read.
                let dueToday = source["today"]?.objectValue?["reminders"]?.arrayValue ?? []
                row["due_status"] = .string(dueToday.contains(.object(row)) ? "due_today" : "overdue")
            } else if let due = row["dueAt"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }), let date = ISO8601DateFormatter().date(from: due) {
                let today = Calendar.current.startOfDay(for: Date())
                row["due_status"] = .string(date < today ? "overdue" : Calendar.current.isDateInToday(date) ? "due_today" : "future")
            } else {
                row["due_status"] = .string("undated")
            }
            var actions: [AgentWorkspaceButton] = []
            // Some owner versions omit the identifier. Never guess it from a title.
            if let id = row["id"]?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }) {
                if tool != "mac_reminders_read" {
                    actions.append(read("Open reminder", tool: "mac_reminders_read", input: ["id": .string(id)], title: title))
                }
                actions.append(configure("Edit reminder", tool: "mac_reminders_update", input: ["id": .string(id)]))
                if row["completed"] == .bool(false) {
                    actions.append(effect("Done (mark complete)", tool: "mac_reminders_complete", input: ["id": .string(id)]))
                }
            }
            return .init(title: title, content: .object(row), actions: actions)
        }
        if projection.items.isEmpty, (result.objectValue ?? [:])["status"] == .string("completed"), case .object(var content) = projection.content {
            content["message"] = .string(tool == "mac_reminders_list_due_today"
                ? "nothing due today or overdue (reminders access ok)" : "no matching reminders (reminders access ok)")
            projection.content = .object(content)
        }
        return projection
    }

    private static func list(title: String, result: JSONValue, key: String, actions: [AgentWorkspaceButton], item: ([String: JSONValue]) -> AgentWorkspaceItem) -> WorkspacePage {
        guard case .object(var content) = result, case .array(let values)? = content[key] else {
            return .init(title: title, content: result, items: [], actions: actions)
        }
        content.removeValue(forKey: key)
        content["returned_count"] = .int(Int64(values.count))
        return .init(title: title, content: .object(content), items: values.map { item(($0.objectValue ?? [:])) }, actions: actions)
    }

    private static func read(_ label: String, tool: String, input: [String: JSONValue] = [:], title: String? = nil) -> AgentWorkspaceButton {
        .init(label: label, action: .open(.record(tool: tool, input: input, title: title ?? label)))
    }

    private static func configure(_ label: String, tool: String, input: [String: JSONValue] = [:]) -> AgentWorkspaceButton {
        .init(label: label, action: .configure(tool: tool, input: input, title: label))
    }

    private static func effect(_ label: String, tool: String, input: [String: JSONValue]) -> AgentWorkspaceButton {
        .init(label: label, action: .perform(tool: tool, input: input, title: label, textField: nil, isEffect: true))
    }
    private static func uuid(_ value: JSONValue?) -> String? {
        guard let value = value?.stringValue.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }), UUID(uuidString: value) != nil else { return nil }
        return value
    }
}
