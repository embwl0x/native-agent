import Foundation
import PersistenceCore
import TurnTrace

// Blueprint: | `ToolNameAliases.swift` | `ToolNameAliases`: one spelling/argument translation owner across Trust, dispatch, receipts and visible app-call projection |

// MARK: - Tool-name aliases

/// The ONE table of alternate spellings for a tool name (2026-09-26). Trust,
/// dispatch, receipts, traces and the chat pill all resolve a requested name
/// here, so an alias can never be judged as one tool and executed as another
/// (`browser_navigate` used to be `browser.navigate` to the Trust Center and
/// `browser.open_url` to the app dispatcher).
///
/// Every canonical name is a real, model-visible tool name. An alias is never
/// a tool of its own: it adds nothing to a catalog or schema list, and the
/// model is only ever offered the canonical spelling. This is not the wire
/// encoder — `ProviderToolNameMap` still owns provider-safe names at ingress.
public enum ToolNameAliases {
    /// canonical name → the spellings that mean it. Both are matched trimmed
    /// and case-insensitively.
    static let aliasesByCanonical: [String: [String]] = [
        "mobile_notify": [
            "mobile.notify", "iphone.notify", "iphone_notify", "ios.notify", "ios_notify",
            "apns.notify", "apns_notify", "push.notify", "push_notify",
        ],
        "mac_notify": ["mac.notify", "native.notify", "native_notify"],
        "mac_spotlight_search": ["spotlight_search"],
        // The Trust Center speaks these tools' connector-action ids; a model
        // that read one called the dotted form (2026-08-22).
        "mac_look": ["mac.look"],
        "mac_view": ["mac.view"],
        "browser.status": ["browser_status", "browser.get_status", "browser_get_status"],
        "browser.open_url": [
            "browser_open_url", "browser.open", "browser_open",
            "browser.navigate", "browser_navigate", "navigate_browser",
        ],
        "browser.read_text": [
            "browser_read_text", "browser.text", "browser_text", "browser_get_text",
            "browser.dom_text", "browser_dom_text",
        ],
        "browser.read_links": ["browser_read_links", "browser.links", "browser_links"],
        "browser.screenshot": [
            "browser_screenshot", "browser.capture_screenshot", "browser_capture_screenshot",
        ],
        "browser.chrome_setup": ["browser_chrome_setup"],
        "browser.chrome_status": ["browser_chrome_status"],
    ].merging(Dictionary(uniqueKeysWithValues: [
        "close_tab", "navigate", "snapshot", "click", "fill", "type", "select",
        "keypress", "set_checked", "double_click", "drag", "wait", "scroll", "media",
    ].map { verb in
        ("browser.chrome_\(verb)", ["browser_chrome_\(verb)", "chrome.\(verb)", "chrome_\(verb)"])
    })) { $0 + $1 }

    /// The app's old per-area tools, retired for the one `app` door
    /// (2026-10-01). Not aliases: a call to one runs nothing, and its
    /// unknown-tool answer carries `retiredAppToolHint`.
    public static let retiredAppTools: Set<String> = [
        "inbox", "chat_session", "upkeep", "provider", "connections", "mind_run", "skill_manage", "ability_manage",
        "workshop_reject", "app_settings_list", "app_setting_set", "app_page_read", "app_page_screenshot",
        "interaction_act", "doctor_status", "telegram_status",
        "chat_conversations", "list_memories", "rewrite_memory",
        // 10-02: no headless Claude, and one way to send her: `claude.say`,
        // like every home name. A call runs nothing; its answer is that send (`appCall`).
        "invoke_claude", "claude_message",
        // 10-02: craft's three hard-coded methods are gone; a part runs as
        // authored.<id>. A call runs nothing and points to ability.list.
        "craft_run",
    ]
    /// Retired action ids → the retired tool each ran; a call answers as `appCall` translates it.
    public static let retiredActions = ["claude.message": "claude_message", "craft.run": "craft_run",
                                        "mac.screen": "screen", "mac.activity_query": "activity_query", "persona": "get_persona_doc"]
    public static let retiredAppToolHint = "Use app — {} is your home and every page."

    /// One-door phase 2 step 7 (User 10-02): `workspace` is `app`'s home, and
    /// discovery is `app {find}`. Their old calls answer translated; nothing
    /// is left to load.
    public static let mergedTools: Set<String> = ["workspace", "tool_catalog", "list_tools", "tool_load"]

    /// Tools folded into the `app` door (one-door phase 2): name → its action
    /// id. Their schemas leave the model's list, `tool_catalog` and
    /// `tool_load`; the executors stay, so internal callers (bridges, bots,
    /// the scheduler, workspace, the workshop allowlist) still call them by
    /// name, and the door re-enters under that name, so every gate binds the
    /// call as it did. A model call to one runs nothing and gets `foldedToolHint`.
    /// Built keeping the first entry for a repeated name (and logging it), so
    /// a duplicate here can never trap at launch the way a dictionary
    /// literal's does.
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
        // Step 2, her own state (User 10-02). recall_search is recall_memory's
        // old alias and folds with it.
        "desk_read": "desk.read", "desk_add_item": "desk.add", "desk_set_status": "desk.set_status",
        "desk_update_item": "desk.update", "desk_note": "desk.note", "desk_add_ref": "desk.add_ref",
        "desk_set_cadence": "desk.set_cadence", "desk_set_notify": "desk.set_notify", "desk_close": "desk.close",
        "desk_archive": "desk.archive", "desk_blocked_on": "desk.blocked_on", "desk_breakdown": "desk.breakdown",
        "desk_defer": "desk.defer", "desk_nag_control": "desk.nag", "desk_open_pursuit": "desk.open_pursuit",
        "desk_work_log": "desk.work_log", "task_ledger_post": "ledger.post", "task_ledger_list": "ledger.list",
        "workshop_submit": "workshop.submit", "workshop_status": "workshop.status",
        "scheduler_list_jobs": "schedule.list", "scheduler_create_job": "schedule.create",
        "scheduler_update_job": "schedule.update", "scheduler_pause_job": "schedule.pause",
        "scheduler_resume_job": "schedule.resume", "scheduler_cancel_job": "schedule.cancel",
        "scheduler_delete_job": "schedule.delete",
        "recall_memory": "memory.recall", "recall_search": "memory.recall", "commit_memory": "memory.commit",
        "forget_memory": "memory.forget", "memory_moments_pending": "memory.moments",
        "memory_moment_review": "memory.review", "search_kg": "graph.search", "rebuild_knowledge_graph": "graph.rebuild",
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
        "hold_view": "mind.hold_view", "release_view": "mind.release_view",
        // Step 3, agents (User 10-02): contacts, conversations and the coding
        // bridges, one action each.
        "agent_contacts": "agent.contacts", "agent_message": "agent.message", "agent_read": "agent.read",
        "agent_connect": "agent.connect", "agent_cancel": "agent.cancel", "delegation_status": "agent.jobs",
        "agent_swarm": "agent.swarm",
        "codex_message": "codex.message", "invoke_codex": "codex.invoke", "omp_message": "omp.message",
        // Step 4, integrations (User 10-02): Mail; Calendar; Reminders, Notes,
        // Contacts, Messages; the connectors; notifications, the phone and images.
        "mail_list_recent": "mail.recent", "mail_read_batch": "mail.read", "mail_search": "mail.search", "mail_senders": "mail.senders",
        "mail_save_attachment": "mail.save_attachment",
        "mail_triage_batch": "mail.triage", "mail_mark_read": "mail.mark_read", "mail_archive": "mail.archive",
        "mail_delete": "mail.delete", "mail_send": "mail.send", "mail_reply": "mail.reply", "mail_draft": "mail.draft",
        "mac_calendar_list_upcoming": "calendar.upcoming", "mac_calendar_calendars": "calendar.calendars",
        "mac_calendar_free_busy": "calendar.free_busy", "mac_calendar_create_event": "calendar.create",
        "mac_calendar_modify_event": "calendar.modify", "mac_calendar_delete_event": "calendar.delete",
        "mac_reminders_list_due_today": "reminders.due_today", "mac_reminders_query": "reminders.query",
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
        // Step 5 (User 10-02): files, shell, the web, the browser, chat search
        // and result paging. session_search is search_chat_history's alias and
        // folds with it.
        "read_file": "files.read", "list_dir": "files.list", "file_info": "files.info", "file_excerpt": "files.excerpt", "grep": "files.grep",
        "write_file": "files.write", "move_file": "files.move", "copy_file": "files.copy", "trash_file": "files.trash", "apply_patch": "files.patch", "mac_spotlight_search": "files.spotlight",
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
        "search_chat_history": "chat.search", "session_search": "chat.search",
        "read_chat_message": "chat.message", "chat_reply": "chat.reply",
        "tool_result_page": "result.page",
        // Step 6 (User 10-02): Mac control is the mac page, and the tools left
        // over fold onto the pages they belong to: music, capabilities, chat
        // (a setup card, a document by what it was for) and the Desk.
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

    /// A folded tool's arguments the door names otherwise, tool → its own
    /// name → the door's: one name per concept across `app` (limit is how
    /// many, path is where, agent is who).
    public static let doorArgNames: [String: [String: String]] = [
        "list_dir": ["max_entries": "limit"], "grep": ["max_results": "limit"], "file_excerpt": ["max_lines": "limit"],
        "git_status": ["cwd": "path"], "git_log": ["cwd": "path"], "git_diff": ["cwd": "path", "path": "file"],
        "repo_dirty_summary": ["cwd": "path", "log_limit": "limit"],
        "agent_connect": ["name": "agent"],
    ]

    private static let whom = ["contact": "agent", "to": "agent"]
    private static let argAliases: [String: [String: String]] = [
        // A reader that searches takes `find`; `query` is what the others call it.
        "*": ["max_rows": "max_nodes", "max_results": "limit", "query": "find"],
        "agent.swarm": ["prompt": "objective", "timeout_seconds": "timeoutSeconds"],
        "desk.close": ["outcome": "outcome_summary"],
        "memory.commit": ["content": "text"],
        // A part is named by id; a skill's name and a tool's tool_id were its older spellings.
        // Its code is `code`; her ability records call their outline `script` (10-21, ×2).
        "ability.read": ["name": "id", "tool_id": "id"], "ability.validate": ["name": "id", "tool_id": "id", "fixtures": "input"],
        "ability.enable": ["name": "id", "tool_id": "id", "digest": "version"], "ability.restore": ["name": "id", "tool_id": "id", "digest": "version"],
        "ability.disable": ["name": "id", "tool_id": "id"], "ability.rollback": ["name": "id", "tool_id": "id"],
        "ability.drop": ["name": "id", "tool_id": "id"], "ability.save": ["tool_id": "id", "tests": "fixtures", "script": "code"],
        // Fresh install 10-19: message for text ×4, contact for agent ×2, each a
        // refused round. Who and what run by their natural names.
        "agent.message": whom.merging(["message": "text"]) { $1 },
        "agent.read": whom.merging(["id": "message_id"]) { $1 }, "agent.cancel": whom, "agent.verify": whom,
        "agent.rename": whom, "agent.connect": whom, "agent.jobs": whom,
        // 10-17, Agent: "mac.go wants name, not app; shell.bash wants cmd, not command".
        "mac.go": ["app": "name"], "shell.run": ["command": "cmd"], "shell.bash": ["command": "cmd"],
    ]

    private static func argumentNames(_ tool: String, _ input: [String: JSONValue]) -> [String: String] {
        let action = appAction(tool) ?? tool
        var names = argAliases[action] ?? [:]
        if action == "agent.swarm", case .int? = input["workers"] { names["workers"] = "agentCount" }
        if action == "agent.jobs" { names["id"] = input["agent"] == .string("swarm") ? "run_id" : "message_id" }
        return names
    }

    /// Repair only one possible spelling; conflicting names stay for validation.
    public static func argumentName(_ name: String, tool: String, input: [String: JSONValue], known: Set<String>) -> (name: String, shimID: String)? {
        let declared = argumentNames(tool, input)
        let aliases = known.contains(name) ? declared : declared.merging(doorArgNames[tool] ?? [:]) { first, _ in first }
        if let alias = aliases[name] { return known.contains(alias.split(separator: ".").first.map(String.init) ?? alias) ? (alias, "T05") : nil }
        guard !known.contains(name) else { return nil }
        if let alias = argAliases["*"]?[name] { return known.contains(alias) ? (alias, "T05") : nil }
        func stem(_ text: String) -> String { text.lowercased().split(separator: "_").map { $0.hasSuffix("s") ? String($0.dropLast()) : String($0) }.joined(separator: "_") }
        let matches = known.filter { candidate in
            if stem(name) == stem(candidate) || name == "id" && candidate.hasSuffix("_id") { return true }
            let a = Array(name.lowercased()), b = Array(candidate.lowercased())
            guard min(a.count, b.count) >= 4, abs(a.count - b.count) <= 1 else { return false }
            var row = Array(0...b.count)
            for (i, character) in a.enumerated() {
                var next = [i + 1]
                for (j, other) in b.enumerated() { next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (character == other ? 0 : 1))) }
                row = next
            }
            return row[b.count] <= 1
        }
        return matches.count == 1 ? matches.first.map { ($0, "T06") } : nil
    }

    /// A folded tool's input with its arguments by the door's names.
    public static func doorArgs(_ tool: String, _ input: [String: JSONValue], reportShim: Bool = false) -> [String: JSONValue] {
        renamed(renamed(input, doorArgNames[tool] ?? [:]), argumentNames(tool, input), reportShim: reportShim)
    }

    /// Door args with the folded tool's own names.
    public static func hostArgs(_ tool: String, _ args: [String: JSONValue], reportShim: Bool = false) -> [String: JSONValue] {
        renamed(renamed(args, argumentNames(tool, args), reportShim: reportShim), Dictionary(uniqueKeysWithValues: (doorArgNames[tool] ?? [:]).map { ($0.value, $0.key) }))
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
            TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("T05"), "site": .string("ToolNameAliases.swift:renamed")]))
        }
        return result
    }

    /// Chrome's verbs on her own tab: `browser.chrome_<verb>` is `chrome.<verb>`.
    public static let chromeVerbs = ["close_tab", "navigate", "snapshot", "click", "fill", "type", "select",
                              "keypress", "set_checked", "double_click", "drag", "wait", "scroll", "media", "reload_extension"]

    /// A tool she wrote, active in her registry, as the action that runs it:
    /// `authored.<id>`, generated from the registry.
    public static func authoredAction(_ tool: String) -> String { "authored." + tool }

    /// `authored.<id>` back to the tool's own id, its case kept.
    public static func authoredTool(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("authored."), trimmed.count > 9 else { return nil }
        return String(trimmed.dropFirst(9))
    }

    /// The action a folded tool is: its registry id.
    public static func appAction(_ tool: String) -> String? { foldedTools[tool] }

    /// Policy lookup also resolves app-executor routes without making them folded tools.
    public static func appAction(_ tool: String, input: [String: JSONValue]) -> String? {
        let tool = canonical(tool)
        if let id = appAction(tool) { return id }
        return AppActionBinding.actionID(tool: tool, input: input)
    }

    /// A name the model no longer calls: a folded tool, a merged one
    /// (`workspace`, `tool_catalog`) or a retired one.
    public static func isAppDoorName(_ tool: String) -> Bool {
        appAction(tool) != nil || mergedTools.contains(tool) || retiredAppTools.contains(tool)
    }

    /// An action that only passes the call on to the tool it folds.
    public static func isFoldedAction(_ id: String) -> Bool {
        AppActionBinding.binding(id)?.folded == true
    }

    /// The tool a call ran: an `app` call of a folded action is that tool,
    /// and a home name that messages someone (`claude.say`), as item or
    /// given as an action (the door opens it as the item), is agent_message,
    /// so its send is held, owed and counted like one.
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
              let binding = AppActionBinding.binding(action), binding.folded else { return (name, input) }
        return (binding.tool, binding.arguments(args))
    }

    /// The tools a call runs: each entry's of an `app {actions}` list, else its one.
    public static func ranTools(_ name: String, input: [String: JSONValue]) -> [String] {
        guard name == "app", case .array(let entries)? = input["actions"], !entries.isEmpty else { return [ranTool(name, input: input)] }
        return entries.flatMap { if case .object(let call) = $0 { ranTools(name, input: call) } else { [name] } }
    }

    /// The input a call ran with: a folded `app` action's args, by the tool's own names.
    public static func ranInput(_ name: String, input: [String: JSONValue]) -> [String: JSONValue] {
        ranCall(name, input: input).input
    }

    /// A call as a person is shown it: a folded `app` action as the tool it
    /// runs, any other `app` action by its id, each with its own args; a
    /// page read and every other tool as they are.
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

    /// `shown` over a call's recorded input JSON.
    public static func shown(_ name: String, inputJSON: String?) -> (name: String, inputJSON: String?) {
        guard name == "app", let inputJSON, let value = try? JSONValue.parse(Data(inputJSON.utf8)) else {
            return (name, inputJSON)
        }
        let call = shown(name, input: value)
        guard call.name != name else { return (name, inputJSON) }
        return (call.name, (try? call.input.serialize(pretty: false)) ?? inputJSON)
    }

    /// Her call to a folded tool, as the `app` call that runs it. `workspace`
    /// is app's home: no args is `{}`, a name or ref is `item` (its text and
    /// fields in args), a query is the home's find; a catalog query is `find`.
    public static func appCall(_ name: String, input: [String: JSONValue]) -> [String: JSONValue]? {
        let args = input.filter { !$0.key.hasPrefix("__") }
        if name == "workspace" {
            if case .string(let item)? = args["action"] {
                let extra = args.filter { ["text", "fields", "conversation"].contains($0.key) && $0.value != .null }
                return extra.isEmpty ? ["item": .string(item)] : ["item": .string(item), "args": .object(extra)]
            }
            if case .string(let query)? = args["query"] { return ["page": .string("home"), "find": .string(query)] }
            return [:]
        }
        if ["tool_catalog", "list_tools"].contains(name) {
            if case .string(let query)? = args["query"] { return ["find": .string(query)] }
            return [:]
        }
        if let handle = agentHandle(name) {
            var extra = args
            var options: [String: JSONValue] = if case .object(let options)? = args["options"] { options } else { [:] }
            for key in ["working_directory", "topic", "model", "reasoning_effort", "fast", "pair_reviewer", "timeout_seconds", "priority", "desk_item", "completion_mode", "repository"] {
                if let value = extra.removeValue(forKey: key) { options[key] = value }
            }
            if let cwd = extra.removeValue(forKey: "cwd") { options["working_directory"] = cwd }
            if !options.isEmpty { extra["options"] = .object(options) }
            if case .string(let context)? = extra.removeValue(forKey: "context"), case .string(let text)? = extra["text"] { extra["text"] = .string(context + "\n\n" + text) }
            if extra["conversation_mode"] == .string("new") { extra.removeValue(forKey: "conversation_mode"); extra["new_conversation"] = .bool(true) }
            if extra["conversation_mode"] == .string("resume"), extra["conversation_id"] != nil { extra.removeValue(forKey: "conversation_mode") }
            extra["agent"] = .string(handle)
            return ["action": .string("agent.message"), "args": .object(extra)]
        }
        // Its arguments were a hard-coded method's; a part takes its own.
        if name == "craft_run" { return ["action": .string("ability.list")] }
        guard let id = appAction(name) else { return nil }
        return args.isEmpty ? ["action": .string(id)] : ["action": .string(id), "args": .object(doorArgs(name, args))]
    }

    /// Legacy send spellings supply a target, never an identity or a grant.
    public static func agentHandle(_ name: String) -> String? {
        let parts = name.replacingOccurrences(of: ".", with: "_").split(separator: "_").map(String.init)
        guard parts.count == 2 else { return nil }
        if ["message", "say"].contains(parts[1]), ["claude", "claude", "codex", "omp"].contains(parts[0]) { return parts[0] }
        if parts[0] == "invoke", ["claude", "codex"].contains(parts[1]) { return parts[1] }
        return nil
    }

    /// The answer to a call of a folded tool by its old name: the same call,
    /// already translated.
    public static func foldedToolHint(_ name: String, input: [String: JSONValue] = [:]) -> String {
        guard let call = appCall(name, input: input),
              let data = try? JSONValue.object(call).serializedData(pretty: false) else { return retiredAppToolHint }
        return "Use app " + String(decoding: data, as: UTF8.self) + " — {} is your home and every page."
    }

    /// Text that names folded tools, with each name as its action id: a
    /// folded tool's own description, read through the door.
    public static func foldedProse(_ text: String) -> String {
        guard let pattern = foldedNamePattern else { return text }
        var out = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out), let id = appAction(String(out[range])) else { continue }
            out.replaceSubrange(range, with: id)
        }
        return out
    }

    /// Where a result names its next call: a pointer key, or the called
    /// tool's own name (`shelf_entry: {tool: "shelf_entry", id}`).
    static func isPointerKey(_ key: String) -> Bool {
        ["read_more", "next_call", "read_with", "read_context", "reply_with", "inspect_receipt", "read_locator",
         "parent_read", "next_read", "blocking_items", "read", "open_current_file"].contains(key)
            || key.hasSuffix("_invitation") || foldedTools[key] != nil
    }

    /// Each next call a result names by a folded tool, under a pointer key,
    /// as that tool's app call. Everything else is left as it is. Any tool's
    /// result reaches her this way (`work_context` points at `desk_read`).
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

    /// `{tool: <folded>, …}` → `{tool: "app", input: {action, args}}`; a
    /// sentence beside the call (an invitation's message) stays beside it.
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

    /// A result's own sentences, never what it read or saved.
    public static let foldedProseKeys = ["detail", "message", "note", "hint", "instruction", "error", "reason", "fix",
                                         "content_note", "next_turn_note", "recovery_hint"]

    /// A name that reads as a word (git, shell, screen, act) is left alone in
    /// prose unless it is in backticks (`screen`).
    private static let foldedNamePattern = try? NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_./])(" + foldedTools.keys.filter { $0.contains("_") || $0.contains(".") }
            .sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
            + ")(?![A-Za-z0-9_])"
            + "|(?<=`)(" + foldedTools.keys.filter { !$0.contains("_") && !$0.contains(".") }
            .sorted().map(NSRegularExpression.escapedPattern).joined(separator: "|") + ")(?=`)")

    /// alias → canonical. Built with `uniqueKeysWithValues` on purpose: one
    /// spelling naming two tools is the bug this table exists to end.
    public static let table: [String: String] = Dictionary(uniqueKeysWithValues:
        aliasesByCanonical.flatMap { canonical, aliases in aliases.map { ($0, canonical) } })

    /// The canonical name for `name`. A name `known` already knows stays as
    /// it is. A table alias resolves to its tool. Anything else comes back
    /// exactly as given — an alias, not a fuzzy match.
    public static func canonical(
        _ name: String,
        known: (String) -> Bool = { _ in false }
    ) -> String {
        if known(name) { return name }
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return table[key] ?? (aliasesByCanonical[key] != nil ? key : name)
    }
}

/// One turn's tool events as a person is shown them (`ToolNameAliases.shown`).
/// A result carries no input, so it takes the name its call was shown by:
/// results arrive in the order their calls did, per name.
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
