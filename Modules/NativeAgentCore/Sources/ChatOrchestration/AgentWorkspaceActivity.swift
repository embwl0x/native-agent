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
        .init(id: "reminders", title: "Reminders", summary: "Due today and overdue.", tool: "mac_reminders_list_due_today", input: ["limit": .int(16)], tools: ["mac_reminders_create"]),
        .init(id: "mail", title: "Mail", summary: "Recent email, search, and compose.", tool: "mail_list_recent", input: ["limit": .int(16)], tools: ["mail_search", "mail_send"]),
        .init(id: "messages", title: "Messages", summary: "Recent messages and a new message to a chosen recipient.", tool: "messages_recent_threads", input: ["limit": .int(16)], tools: ["messages_send"]),
        .init(id: "connections", title: "Connections", summary: "Find an agent or set up a connection.", tool: "agent_contacts", tools: ["agent_contacts", "agent_connect"])
    ]

    static let readTools: Set<String> = ["bot_list", "shelf_read", "shelf_entry", "desk_read", "task_ledger_list", "delegation_status", "mac_calendar_list_upcoming", "mac_reminders_list_due_today", "mail_list_recent", "mail_search", "messages_recent_threads"]

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
        case "mac_reminders_list_due_today": return reminders(result)
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
        for (name, tool, input) in [
            ("Calendar", "mac_calendar_list_upcoming", ["day": JSONValue.string("today"), "limit": .int(8)]),
            ("Reminders", "mac_reminders_list_due_today", ["limit": JSONValue.int(8)])
        ] {
            let value: JSONValue
            do { value = try await perform(tool, input) }
            catch is CancellationError { throw CancellationError() }
            catch { value = .object(["status": .string("unavailable"), "detail": .string(error.localizedDescription)]) }
            guard let view = project(tool: tool, input: input, result: value) else { continue }
            sections.append(.object(["area": .string(name), "result": view.content, "shown": .int(Int64(view.items.count))]))
            items += view.items.map { item in
                var item = item; item.title = name + ": " + item.title; return item
            }
        }
        return .init(title: "Today", content: .object(["status": .string("ok"), "sections": .array(sections),
            "scope": .string("At most eight appointments today and eight incomplete reminders due today or earlier. Empty and unavailable sections are different. Open each area for more.")]),
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
        var projection = list(title: "Calendar", result: result, key: "events", actions: [configure("Create an event", tool: "mac_calendar_create_event"), day]) { row in
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

    private static func reminders(_ result: JSONValue) -> AgentWorkspaceProjection {
        var projection = list(title: "Reminders", result: result, key: "reminders", actions: [configure("Create a reminder", tool: "mac_reminders_create")]) { row in
            var row = row
            let title = text(row["title"]) ?? "Reminder"
            if let due = text(row["dueAt"]), let date = ISO8601DateFormatter().date(from: due) {
                row["due_status"] = .string(date < Calendar.current.startOfDay(for: Date()) ? "overdue" : "due_today")
            }
            var actions: [AgentWorkspaceButton] = []
            // Some owner versions omit the identifier. Never guess it from a title.
            if row["completed"] == .bool(false), let id = text(row["id"]) {
                actions.append(effect("Done (mark complete)", tool: "mac_reminders_complete", input: ["id": .string(id)]))
            }
            return .init(title: title, content: .object(row), actions: actions)
        }
        if projection.items.isEmpty, object(result)["status"] == .string("completed"), case .object(var content) = projection.content {
            content["message"] = .string("nothing due today or overdue (reminders access ok)")
            projection.content = .object(content)
        }
        return projection
    }

    private static func mail(_ result: JSONValue) -> AgentWorkspaceProjection {
        list(title: "Mail", result: result, key: "messages", actions: [configure("Find email", tool: "mail_search"), configure("Compose email", tool: "mail_send")]) { row in
            // The current owner selects replies by subject and first match, not
            // immutable message identity. A preview must not imply an exact reply.
            .init(title: text(row["subject"]) ?? "Email", content: .object(row), actions: [])
        }
    }

    private static func messages(_ result: JSONValue) -> AgentWorkspaceProjection {
        var projection = list(title: "Messages", result: result, key: "threads", actions: [configure("Compose message", tool: "messages_send")]) { row in
            // `handle` here is the AppleScript chat ID, whereas messages_send
            // needs a recipient phone/email. They are not interchangeable.
            .init(title: text(row["handle"]) ?? "Conversation", content: .object(row), actions: [])
        }
        if case .object(var content) = projection.content {
            content["reply_context"] = .string("Choose a recipient when composing; these thread identifiers are not recipient addresses.")
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
