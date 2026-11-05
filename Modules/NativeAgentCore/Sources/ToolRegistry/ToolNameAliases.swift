import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import NativeAgentShared

// Blueprint: | `ToolNameAliases.swift` | `ToolNameAliases`: one public argument/schema projection |

// MARK: - Tool-name aliases

/// Internal IDs and public actions share one explicit binding map; translation grants no visibility or catalog membership. Provider ingress owns wire-safe
/// names.
public enum ToolNameAliases {
    /// Folded calls re-enter their executor's gates; direct model calls receive only a hint. Duplicate names log instead of trapping.
    public static let foldedTools: [String: String] = {
        var out: [String: String] = [:]
        for (tool, id) in foldedEntries.map({ ($0.key, $0.value) })
            + chromeVerbs.map({ ("browser.chrome_\($0)", "chrome.\($0)") }) {
            if let kept = out[tool] {
                nativeLog("ToolNameAliases: %@ is folded twice; its first action, %@, is kept", tool, kept)
            } else {
                out[tool] = id
            }
        }
        return out
    }()

    private static let foldedEntries: KeyValuePairs<String, String> = [
        "time_now": "time.now", "context_expand": "context.expand", "inner_state": "mind.inner_state",
        "agent_introspect": "agent.introspect",
        "recent_trace_summary": "trace.recent",
        "desk_read": "desk.read", "desk_add_item": "desk.add", "desk_set_status": "desk.set_status", "desk_wait": "desk.wait",
        "desk_update_item": "desk.update", "desk_note": "desk.note", "desk_add_ref": "desk.add_ref",
        "desk_set_cadence": "desk.set_cadence", "desk_set_notify": "desk.set_notify", "desk_close": "desk.close",
        "desk_archive": "desk.archive", "desk_blocked_on": "desk.blocked_on", "desk_breakdown": "desk.breakdown",
        "desk_defer": "desk.defer", "desk_nag_control": "desk.nag", "desk_open_pursuit": "desk.open_pursuit",
        "desk_work_log": "desk.work_log", "task_ledger_post": "ledger.post", "task_ledger_list": "ledger.list",
        "scheduler_list_jobs": "schedule.list", "scheduler_create_job": "schedule.create",
        "scheduler_update_job": "schedule.update", "scheduler_pause_job": "schedule.pause",
        "scheduler_resume_job": "schedule.resume", "scheduler_cancel_job": "schedule.cancel",
        "recall_memory": "memory.recall", "commit_memory": "memory.commit",
        "forget_memory": "memory.forget", "memory_proposals_pending": "memory.proposals",
        "memory_proposal_review": "memory.review", "search_kg": "graph.search", "rebuild_knowledge_graph": "graph.rebuild",
        "scratchpad_read": "chat.scratch_read",
        "bot_list": "bot.list", "bot_create": "bot.create", "bot_update": "bot.update", "bot_pause": "bot.pause",
        "bot_delete": "bot.delete", "bot_run_once": "bot.run_once", "bot_ask": "bot.ask",
        "shelf_read": "bot.replies", "shelf_entry": "bot.reply",
        "get_persona_doc": "persona.doc", "persona_read": "persona.read", "persona_write": "persona.write",
        "persona_append_section": "persona.append",
        "studio_consult": "studio.consult", "studio_consult_read": "studio.consult_read",
        "studio_journal": "studio.journal", "studio_journal_amend": "studio.amend", "studio_recall": "studio.recall",
        "studio_shelf_read": "studio.shelf", "studio_shelf_set": "studio.shelf_set", "studio_canon": "studio.canon",
        "studio_canon_resolve": "studio.canon_resolve", "dream_diary_read": "mind.dream_diary",
        "agent_contacts": "agent.contacts", "agent_message": "agent.message", "agent_read": "agent.read",
        "agent_connect": "agent.connect", "agent_cancel": "agent.cancel", "delegation_status": "agent.jobs",
        "mail_list_recent": "mail.recent", "mail_read_batch": "mail.read", "mail_search": "mail.search", "mail_senders": "mail.senders",
        "mail_save_attachment": "mail.save_attachment",
        "mail_triage_batch": "mail.triage", "mail_mark_read": "mail.mark_read", "mail_archive": "mail.archive",
        "mail_delete": "mail.delete", "mail_send": "mail.send", "mail_reply": "mail.reply", "mail_draft": "mail.draft",
        "mac_calendar_list_upcoming": "calendar.upcoming", "mac_calendar_calendars": "calendar.calendars",
        "mac_calendar_free_busy": "calendar.free_busy", "mac_calendar_create_event": "calendar.create",
        "mac_calendar_modify_event": "calendar.modify", "mac_calendar_delete_event": "calendar.delete",
        "mac_reminders_list_due_today": "reminders.due_today", "mac_reminders_query": "reminders.query", "mac_reminders_lists": "reminders.lists",
        "mac_reminders_read": "reminders.read", "mac_reminders_create": "reminders.create",
        "mac_reminders_update": "reminders.update", "mac_reminders_complete": "reminders.complete",
        "mac_reminders_delete": "reminders.delete",
        "mac_reminders_list_rename": "reminders.list_rename", "mac_reminders_list_create": "reminders.list_create",
        "notes_search": "notes.search", "notes_create": "notes.create", "notes_update": "notes.update", "notes_delete": "notes.delete",
        "contacts_search": "contacts.search", "contacts_create_or_update": "contacts.save",
        "contacts_delete": "contacts.delete",
        "messages_recent_threads": "messages.recent", "messages_send": "messages.send",
        "mac_notify": "notify.mac", "mobile_notify": "notify.phone", "phone_request": "phone.request",
        "image_generate": "image.generate",
        "read_file": "files.read", "list_dir": "files.list", "file_info": "files.info", "file_excerpt": "files.excerpt", "grep": "files.grep",
        "write_file": "files.write", "move_file": "files.move", "copy_file": "files.copy", "trash_file": "files.trash", "apply_patch": "files.patch",
            "mac_spotlight_search": "files.spotlight",
        "shell": "shell.run", "bash": "shell.bash", "git": "git.run", "git_status": "git.status",
        "git_diff": "git.diff", "git_log": "git.log", "repo_dirty_summary": "git.summary",
        "swift_build": "swift.build", "swift_test": "swift.test",
        "remote_node_list": "node.list", "remote_node_execute": "node.run",
        "restart_app": "app.restart", "install_app": "app.install",
        "read_page": "web.read", "web_search": "web.search",
        "maps_route": "maps.route",
        "maps_search": "maps.search",
        "browser.status": "browser.status", "browser.open_url": "browser.open", "browser.read_text": "browser.text",
        "browser.read_links": "browser.links", "browser.screenshot": "browser.screenshot",
        "browser.chrome_setup": "chrome.setup", "browser.chrome_status": "chrome.status",
        "search_chat_history": "chat.search",
        "read_chat_message": "chat.message", "chat_reply": "chat.reply",
        "tool_result_page": "result.page",
        "screen": "mac.look", "act": "mac.act", "go": "mac.go", "wait": "mac.wait", "read": "mac.read",
        "menu": "mac.menu", "menu_press": "mac.menu_press", "clipboard_read": "mac.clipboard_read",
        "clipboard_write": "mac.clipboard_write", "system_info": "mac.system_info", "mac_volume": "mac.volume", "activity_query": "mac.activity",
        "mac_screenshot_save": "mac.screenshot_save", "mac_location": "mac.location",
        "music_now_playing": "music.now_playing", "music_control": "music.control", "mac_media": "mac.media",
        "music_search_library": "music.search", "music_list_library": "music.library",
        "music_list_playlists": "music.playlists",
        "context_lookup": "capabilities.lookup", "request_interaction": "card.request",
        "artifact_find": "artifact.find", "work_context": "work.context",
    ]

    /// Rename only declared folded arguments so each concept keeps one name across app calls.
    public static let doorArgNames: [String: [String: String]] = [
        "list_dir": ["max_entries": "limit"], "grep": ["max_results": "limit"], "file_excerpt": ["max_lines": "limit"],
        "git_status": ["cwd": "path"], "git_log": ["cwd": "path"], "git_diff": ["cwd": "path", "path": "file"],
        "repo_dirty_summary": ["cwd": "path", "log_limit": "limit"],
        "agent_connect": ["name": "agent"],
    ]

    public static func doorArgs(_ tool: String, _ input: [String: JSONValue], reportShim: Bool = false) -> [String: JSONValue] {
        renamed(input, doorArgNames[tool] ?? [:], reportShim: reportShim)
    }

    public static func hostArgs(_ tool: String, _ args: [String: JSONValue], reportShim: Bool = false) -> [String: JSONValue] {
        renamed(args, Dictionary(uniqueKeysWithValues: (doorArgNames[tool] ?? [:]).map { ($0.value, $0.key) }), reportShim: reportShim)
    }

    /// Project the current executor schema, including its root form constraints. Argument names change only at this object level, never inside its data.
    public static func doorSchema(_ tool: String, _ schema: JSONValue) -> JSONValue {
        guard case .object(var fields) = schema else { return schema }
        let names = doorArgNames[tool] ?? [:]
        if case .object(let properties)? = fields["properties"] {
            fields["properties"] = .object(doorArgs(tool, properties))
        }
        if case .array(let required)? = fields["required"] {
            fields["required"] = .array(required.map { value in
                guard case .string(let name) = value else { return value }
                return .string(names[name] ?? name)
            })
        }
        for key in ["allOf", "anyOf", "oneOf"] {
            if case .array(let forms)? = fields[key] {
                fields[key] = .array(forms.map { doorSchema(tool, $0) })
            }
        }
        if let excluded = fields["not"] { fields["not"] = doorSchema(tool, excluded) }
        return .object(fields)
    }

    private static func renamed(_ fields: [String: JSONValue], _ names: [String: String], reportShim: Bool = false) -> [String: JSONValue] {
        guard !names.isEmpty else { return fields }
        var result: [String: JSONValue] = [:]
        for key in fields.keys.sorted() {
            let name = names[key] ?? key
            let path = name.split(separator: ".").map(String.init)
            if name != key, path.count == 2 {
                var nested: [String: JSONValue]
                switch result[path[0]] ?? fields[path[0]] {
                case .object(let given)?: nested = given
                case nil, .null?: nested = [:]
                default: result[key] = fields[key]; continue
                }
                if let existing = nested[path[1]], existing != .null, existing != fields[key] {
                    result[key] = fields[key]; continue
                }
                nested[path[1]] = fields[key]
                result[path[0]] = .object(nested)
                continue
            }
            // Keep conflicting spellings visible for validation, never pick one arbitrarily.
            if name != key, let existing = fields[name], names[name] == nil, existing != .null, existing != fields[key] {
                result[key] = fields[key]
            } else if names.values.contains(where: { $0.hasPrefix(name + ".") }),
                      case .object(let nested)? = result[name], case .object(let given)? = fields[key] {
                result[name] = .object(given.merging(nested) { _, value in value })
            } else if fields[key] != .null || result[name] == nil { result[name] = fields[key] }
        }
        if reportShim, result != fields {
            // Pure name normalization holds no turn; this diagnostic uses trace-only correlation.
            TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("T05"), "site": .string("ToolNameAliases.swift:renamed")]),
                turn: nil)
        }
        return result
    }

    /// Browser action translation stays tied to the explicit Chrome verb map.
    public static let chromeVerbs = ["close_tab", "navigate", "snapshot", "look", "click", "fill", "type", "select",
                              "keypress", "set_checked", "double_click", "drag", "wait", "scroll", "media", "reload_extension"]

    /// Only active authored registry entries produce runnable actions.
    public static func authoredAction(_ tool: String) -> String { "authored." + tool }

    /// Authored action decoding must preserve the registered ID's case.
    public static func authoredTool(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("authored."), trimmed.count > 9 else { return nil }
        return String(trimmed.dropFirst(9))
    }

    public static func appAction(_ tool: String) -> String? { foldedTools[tool] }

    /// Policy lookup resolves executor routes without granting folded-tool status.
    public static func appAction(_ tool: String, input: [String: JSONValue]) -> String? {
        let tool = canonical(tool)
        if let id = appAction(tool) { return id }
        return AppActionBinding.actionID(tool: tool, input: input)
    }

    public static func isFoldedAction(_ id: String) -> Bool {
        AppActionBinding.declaredBinding(id)?.folded == true
    }

    /// Home-message and folded app calls must retain the underlying tool identity so send holds, debts and accounting share one owner.
    public static func ranTool(_ name: String, input: [String: JSONValue]) -> String {
        ranCall(name, input: input).tool
    }

    public static func ranCall(_ name: String, input: [String: JSONValue]) -> (tool: String, input: [String: JSONValue]) {
        let args: [String: JSONValue] = if case .object(let args)? = input["args"] { args } else { [:] }
        if name == "app", case .string(let item)? = input["action"] ?? input["item"],
           item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix(".say"),
           authoredTool(item) == nil {
            let page = (input["page"].flatMap { if case .string(let text) = $0 { text } else { nil } } ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if page.isEmpty || page == "home" { return ("agent_message", args) }
        }
        guard name == "app", case .string(let action)? = input["action"],
              let binding = AppActionBinding.declaredBinding(action), binding.folded else { return (name, input) }
        return (binding.tool, binding.arguments(args))
    }

    /// Batch app calls expose every underlying tool for policy and accounting.
    public static func ranTools(_ name: String, input: [String: JSONValue]) -> [String] {
        guard name == "app", case .array(let entries)? = input["actions"], !entries.isEmpty else { return [ranTool(name, input: input)] }
        return entries.flatMap { if case .object(let call) = $0 { ranTools(name, input: call) } else { [name] } }
    }

    /// Receipts project folded arguments back to the executor's own names.
    public static func ranInput(_ name: String, input: [String: JSONValue]) -> [String: JSONValue] {
        ranCall(name, input: input).input
    }

    /// Display folded actions by their executed tool identity while retaining each call's own arguments.
    public static func shown(_ name: String, input: JSONValue) -> (name: String, input: JSONValue) {
        guard name == "app", case .object(let fields) = input, case .string(let raw)? = fields["action"] else {
            return (name, input)
        }
        let action = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !action.isEmpty else { return (name, input) }
        // Historical generated labels survive unmounting or dropping their executable.
        let ran = authoredTool(raw) ?? ranTool(name, input: fields)
        return (ran == name ? action : ran, fields["args"] ?? .object([:]))
    }

    public static func shown(_ name: String, inputJSON: String?) -> (name: String, inputJSON: String?) {
        guard name == "app", let inputJSON, let value = try? JSONValue.parse(Data(inputJSON.utf8)) else {
            return (name, inputJSON)
        }
        let call = shown(name, input: value)
        guard call.name != name else { return (name, inputJSON) }
        return (call.name, (try? call.input.serialize(pretty: false)) ?? inputJSON)
    }

    /// Present internal executor calls through their declared public action.
    public static func appCall(_ name: String, input: [String: JSONValue]) -> [String: JSONValue]? {
        let args = input.filter { !$0.key.hasPrefix("__") }
        guard let id = appAction(name) else { return nil }
        return args.isEmpty ? ["action": .string(id)] : ["action": .string(id), "args": .object(doorArgs(name, args))]
    }

    public static func foldedToolHint(_ name: String, input: [String: JSONValue] = [:]) -> String {
        guard let call = appCall(name, input: input),
              let data = try? JSONValue.object(call).serializedData(pretty: false) else { return "Use app — {} is your home and every page." }
        return "Use app " + String(decoding: data, as: UTF8.self) + " — {} is your home and every page."
    }

    /// Fold tool names in their own descriptions so discovery agrees with the public call surface.
    private static let proseLock = NSLock()
    nonisolated(unsafe) private static var proseByText: [Data: String] = [:]

    public static func foldedProse(_ text: String) -> String {
        proseLock.withLock {
            let key = Data(text.utf8) // Preserve distinct Unicode spellings as well as their meaning.
            if let known = proseByText[key] { return known }
            let out = foldProse(text)
            if proseByText.count >= 4096 { proseByText.removeAll(keepingCapacity: true) }
            proseByText[key] = out
            return out
        }
    }

    private static func foldProse(_ text: String) -> String {
        guard let pattern = foldedNamePattern else { return text }
        var out = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out), let id = appAction(String(out[range])) else { continue }
            out.replaceSubrange(range, with: id)
        }
        return out
    }

    /// Rewrite only declared next-call pointers, never arbitrary payload fields.
    static func isPointerKey(_ key: String) -> Bool {
        ["read_more", "next_call", "read_with", "read_context", "reply_with", "inspect_receipt", "read_locator",
         "parent_read", "next_read", "blocking_items", "read", "open_current_file"].contains(key)
            || key.hasSuffix("_invitation") || foldedTools[key] != nil
    }

    /// Next-call pointers must present folded tools as public app calls without rewriting unrelated result data.
    public static func appCallPointers(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let items): return .array(items.map(appCallPointers))
        case .object(let fields):
            return .object(Dictionary(uniqueKeysWithValues: fields.map { key, value in
                (key, isPointerKey(key) ? appPointer(value) : appCallPointers(value))
            }))
        default: return value
        }
    }

    /// Preserve invitation prose beside the translated call.
    public static func appPointer(_ value: JSONValue) -> JSONValue {
        if case .array(let items) = value { return .array(items.map(appPointer)) }
        guard case .object(let fields) = value, case .string(let tool)? = fields["tool"],
              appAction(tool) != nil else { return value }
        let prose = fields.filter { foldedProseKeys.contains($0.key) }
        var args = fields.filter { $0.key != "tool" && prose[$0.key] == nil }
        for key in ["input", "arguments"] { if case .object(let given)? = args[key], args.count == 1 { args = given } }
        guard let call = appCall(tool, input: args) else { return value }
        return .object(prose.merging(["tool": .string("app"), "input": .object(call)]) { _, new in new })
    }

    /// Fold only the result's own sentences, never retrieved or saved content.
    public static let foldedProseKeys = ["detail", "message", "note", "hint", "instruction", "error", "reason", "fix",
                                         "content_note", "next_turn_note", "recovery_hint"]

    /// Ordinary words remain prose unless explicitly backticked as tool names.
    private static let foldedNamePattern = try? NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_./])(" + foldedTools.keys.filter { $0.contains("_") || $0.contains(".") }
            .sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
            + ")(?![A-Za-z0-9_])"
            + "|(?<=`)(" + foldedTools.keys.filter { !$0.contains("_") && !$0.contains(".") }
            .sorted().map(NSRegularExpression.escapedPattern).joined(separator: "|") + ")(?=`)")

    /// Normalize whitespace only; unknown IDs must stay unknown.
    public static func canonical(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

/// Result events lack input, so inherit their displayed name from calls in per-name arrival order.
public final class ShownToolNames: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: [(name: String, seq: Int)]] = [:]
    private var sequence = 0

    public init() {}

    public func use(_ name: String, input: JSONValue) -> (name: String, input: JSONValue, seq: Int) {
        let call = ToolNameAliases.shown(name, input: input)
        return lock.withLock {
            sequence += 1
            pending[name, default: []].append((call.name, sequence))
            return (call.name, call.input, sequence)
        }
    }

    public func result(_ name: String) -> (name: String, seq: Int?) {
        lock.withLock {
            guard var queue = pending[name], !queue.isEmpty else { return (name, nil) }
            let shown = queue.removeFirst()
            pending[name] = queue
            return shown
        }
    }
}
