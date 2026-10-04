import Foundation
import PersistenceCore

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

    static let readTools: Set<String> = ["bot_list", "shelf_read", "shelf_entry", "desk_read", "task_ledger_list", "delegation_status", "mac_calendar_list_upcoming", "mac_reminders_list_due_today", "mac_reminders_query", "mac_reminders_read", "mail_list_recent", "mail_read_batch", "mail_search", "messages_recent_threads", "mac_calendar_calendars", "mac_calendar_free_busy"]

    static func project(tool: String, input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection? {
        switch tool {
        case "bot_list": return bots(input: input, result)
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
                guard let id = text(row["calendarId"]) else {
                    return .init(title: text(row["title"]) ?? "Calendar", content: .object(row), actions: [])
                }
                var actions = [read("Events", tool: "mac_calendar_list_upcoming", input: ["calendar_id": .string(id)]),
                    configure("Check availability", tool: "mac_calendar_free_busy", input: ["calendar_ids": .array([.string(id)])])]
                if row["writable"] == .bool(true) {
                    actions.append(configure("Create an event", tool: "mac_calendar_create_event", input: ["calendar_id": .string(id)]))
                }
                return .init(title: text(row["title"]) ?? id, content: .object(row), actions: actions)
            }
        case "mac_reminders_list_due_today", "mac_reminders_query", "mac_reminders_read":
            return reminders(tool: tool, input: input, result)
        case "mail_list_recent", "mail_search": return AgentWorkspaceMail.project(input: input, result: result)
        case "messages_recent_threads": return AgentWorkspaceMessages.project(input: input, result: result)
        default: return nil
        }
    }

    private static func bots(input: [String: JSONValue], _ result: JSONValue) -> AgentWorkspaceProjection {
        let selected = uuid(input["id"])
        var projection = list(title: "My helpers", result: result, key: "bots", actions: [
            configure("Create a helper", tool: "bot_create"), read("Saved replies", tool: "shelf_read", input: ["limit": .int(16), "include_read": .bool(true), "newest_first": .bool(true)])
        ]) { row in
            let name = text(row["name"]) ?? "Helper"
            var buttons: [AgentWorkspaceButton] = []
            // Definitions expose UUIDs; names can collide or change.
            if let id = uuid(row["id"]) {
                let agent = "bot:" + id
                buttons = [
                    read("Open helper", tool: "bot_list", input: ["id": .string(id)], title: name),
                    .init(label: "Talk", action: .message(agent: agent, conversation: nil, name: name), needsText: true),
                    read("Open conversation", tool: "agent_read", input: ["agent": .string(agent)], title: name),
                    effect("Run once", tool: "bot_run_once", input: ["id": .string(id)]),
                    configure("Settings", tool: "bot_update", input: ["id": .string(id)])
                ]
                if case .bool(let paused)? = row["paused"] {
                    buttons.append(effect(paused ? "Resume schedule" : "Pause schedule", tool: "bot_pause", input: ["id": .string(id), "paused": .bool(!paused)]))
                }
            }
            if selected != nil { buttons.removeAll { if case .open(.record("bot_list", _, _)) = $0.action { return true }; return false } }
            return .init(title: name, content: .object(row.filter { !["actions", "session_id", "cadence"].contains($0.key) }), actions: buttons)
        }
        if selected != nil, let helper = projection.items.first {
            projection.title = helper.title
            projection.actions = helper.actions + [read("All helpers", tool: "bot_list")]
            projection.content = helper.content
            projection.items = []
        }
        return projection
    }

    /// A joined view over two existing readers. Selecting Today is the only
    /// trigger; no background observer, model, scan or extra work ledger.
    static func today(perform: AgentWorkspace.Perform) async throws -> AgentWorkspaceProjection {
        var sections: [JSONValue] = []
        var items: [AgentWorkspaceItem] = []
        var overdue: [Date] = []
        for (name, tool, input) in [
            ("Calendar", "mac_calendar_list_upcoming", ["day": JSONValue.string("today"), "limit": .int(8)]),
            // The owner's most (100), oldest due first: overdue rows come off
            // below, so a small limit let old ones crowd out today's (Sol, walk 6).
            ("Reminders", "mac_reminders_list_due_today", ["limit": JSONValue.int(100)])
        ] {
            let value: JSONValue
            do { value = try await perform(tool, input) }
            catch is CancellationError { throw CancellationError() }
            catch { value = .object(["status": .string("unavailable"), "detail": .string(error.localizedDescription)]) }
            guard let view = project(tool: tool, input: input, result: value) else { continue }
            sections.append(.object(["area": .string(name), "result": view.content, "shown": .int(Int64(view.items.count))]))
            // Overdue is one plain line, not rows of today's plan (walk 6: June's
            // reminders listed as today). The reminders room still lists them.
            items += view.items.compactMap { item -> AgentWorkspaceItem? in
                if case .object(let row) = item.content, row["due_status"] == .string("overdue") {
                    overdue.append(text(row["dueAt"]).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date())
                    return nil
                }
                var item = item; item.title = name + ": " + item.title; return item
            }.prefix(8)
        }
        var content: [String: JSONValue] = ["status": .string("ok"), "sections": .array(sections),
            "scope": .string("At most eight appointments today and eight incomplete reminders due today; overdue ones are counted, not listed. Empty and unavailable sections are different. Open each area for more.")]
        if let oldest = overdue.min() {
            let month = DateFormatter()
            month.dateFormat = Calendar.current.isDate(oldest, equalTo: Date(), toGranularity: .year) ? "MMMM" : "MMMM yyyy"
            content["message"] = .string("\(overdue.count) overdue reminder\(overdue.count == 1 ? "" : "s"), oldest from \(month.string(from: oldest)) · today.due lists them")
        }
        return .init(title: "Today", content: .object(content),
            items: items, actions: [read("Today's calendar", tool: "mac_calendar_list_upcoming", input: ["day": .string("today"), "limit": .int(16)]),
                read("All due reminders", tool: "mac_reminders_list_due_today", input: ["limit": .int(16)]),
                // It opens the Desk room: named for what it opens (walk 4: `today.ongoing` landed on DESK).
                .init(label: "Desk (work in progress)", action: .open(.area("ongoing"))),
                .init(label: "Refresh today", action: .open(.area("today")))])
    }

    private static func replies(input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection {
        var actions: [AgentWorkspaceButton] = []
        if let cursor = text(object(result)["nextCursor"]) {
            let allowed: Set<String> = ["id", "bot_id", "bot", "name", "since", "topic", "limit", "include_read", "newest_first"]
            var next = input.filter { allowed.contains($0.key) }
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

    private static func reply(input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection {
        var actions: [AgentWorkspaceButton] = []
        let row = object(result)
        let title = AgentWorkspaceSavedReply.title(result)
        if let id = uuid(input["id"]), let bot = uuid(input["bot_id"]) {
            var selected = AgentWorkspaceSavedReply(entryID: id, botID: bot, title: title)
            if let evidence = selected.evidence(result) {
                selected.fingerprint = evidence.fingerprint
                actions = [
                    .init(label: "Follow up", action: .followUpSavedReply(selected), needsText: true),
                    read("Open conversation", tool: "agent_read", input: ["agent": .string(selected.agent)],
                         title: text(row["agent_name"]) ?? "Helper conversation")
                ]
            }
        }
        var content = row
        if !actions.isEmpty {
            content["follow_up_context"] = .string("Follow up carries this saved reply into the helper’s existing conversation. Its exact source is rechecked before sending; long answers are labeled excerpts. You can return to this reply afterward.")
        }
        return .init(title: title, content: content.isEmpty ? result : .object(content), items: [], actions: actions)
    }

    private static func tasks(input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection {
        if let id = text(input["task_id"]) {
            return .init(title: "Selected shared work", content: result, items: [], actions: [configure("Record an update", tool: "task_ledger_post", input: ["task_id": .string(id)])])
        }
        return list(title: "Shared work", result: result, key: "tasks", actions: [read("Include finished work", tool: "task_ledger_list", input: ["include_done": .bool(true)])]) { row in
            let title = text(row["title"]) ?? "Shared work"
            let buttons = text(row["taskId"]).map { [read("Open work", tool: "task_ledger_list", input: ["task_id": .string($0)], title: title)] } ?? []
            return .init(title: title, content: .object(row), actions: buttons)
        }
    }

    private static func calendar(_ result: JSONValue) -> AgentWorkspaceProjection {
        // A day by name in one call (the old "choose" form ran the default read).
        let day = AgentWorkspaceButton(label: "One day", action: .perform(tool: "mac_calendar_list_upcoming", input: ["limit": .int(16)],
            title: "One day", textField: "day", isEffect: false), needsText: true)
        var projection = list(title: "Calendar", result: result, key: "events", actions: [configure("Create an event", tool: "mac_calendar_create_event"),
            read("Calendars", tool: "mac_calendar_calendars"), configure("Check availability", tool: "mac_calendar_free_busy"), day]) { row in
            let title = text(row["title"]) ?? "Calendar event"
            var actions = text(row["id"]).map { [configure("Edit event", tool: "mac_calendar_modify_event", input: ["id": .string($0)])] } ?? []
            if let id = text(row["id"]), let title = text(row["title"]), let start = text(row["startAt"]) {
                actions.append(configure("Delete this event", tool: "mac_calendar_delete_event", input: [
                    "id": .string(id), "expected_title": .string(title), "expected_start": .string(start)]))
            }
            return .init(title: title, content: .object(row), actions: actions)
        }
        // An empty read says it read fine, so it is not taken for no access.
        if projection.items.isEmpty, object(result)["status"] == .string("completed"), case .object(var content) = projection.content {
            let hours: Int64 = if case .int(let n)? = object(result)["hoursAhead"] { n } else { 24 }
            let span = text(object(result)["day"]) ?? "in the next \(hours)h"
            content["message"] = .string("no events \(span) (calendar access ok)")
            projection.content = .object(content)
        }
        return projection
    }

    private static func reminders(tool: String, input: [String: JSONValue], _ result: JSONValue) -> AgentWorkspaceProjection {
        var source = object(result)
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
            let title = text(row["title"]) ?? "Reminder"
            if let due = text(row["dueAt"]), let date = ISO8601DateFormatter().date(from: due) {
                let today = Calendar.current.startOfDay(for: Date())
                row["due_status"] = .string(date < today ? "overdue" : Calendar.current.isDateInToday(date) ? "due_today" : "future")
            } else {
                row["due_status"] = .string("undated")
            }
            var actions: [AgentWorkspaceButton] = []
            // Some owner versions omit the identifier. Never guess it from a title.
            if let id = text(row["id"]) {
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
        if projection.items.isEmpty, object(result)["status"] == .string("completed"), case .object(var content) = projection.content {
            content["message"] = .string(tool == "mac_reminders_list_due_today"
                ? "nothing due today or overdue (reminders access ok)" : "no matching reminders (reminders access ok)")
            projection.content = .object(content)
        }
        return projection
    }

    private static func list(title: String, result: JSONValue, key: String, actions: [AgentWorkspaceButton], item: ([String: JSONValue]) -> AgentWorkspaceItem) -> AgentWorkspaceProjection {
        guard case .object(var content) = result, case .array(let values)? = content[key] else {
            return .init(title: title, content: result, items: [], actions: actions)
        }
        content.removeValue(forKey: key)
        content["returned_count"] = .int(Int64(values.count))
        return .init(title: title, content: .object(content), items: values.map { item(object($0)) }, actions: actions)
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

    private static func object(_ value: JSONValue) -> [String: JSONValue] {
        guard case .object(let row) = value else { return [:] }; return row
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func uuid(_ value: JSONValue?) -> String? {
        guard let value = text(value), UUID(uuidString: value) != nil else { return nil }
        return value
    }
}
