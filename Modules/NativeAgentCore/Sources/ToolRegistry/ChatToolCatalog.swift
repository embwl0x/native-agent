import Foundation
import PersistenceCore

// MARK: - The catalog as the Tools page reads it (S10, 2026-09-26)

/// One row of the full tool manifest (`SwiftToolDispatcher.toolManifest`): what the tool is (Core's row)
/// and whether it may run here right now (the Security gate's decision the app
/// wrapper stamps on each row).
public struct ChatCatalogTool: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var parametersPreview: String?
    public var dispatchableVia: String?
    public var loadState: String?
    public var effectiveAutonomy: String?
    public var availableNow: Bool?
    /// Typed runtime category emitted by the dispatcher registry. Unlike tags,
    /// this is the visible safety contract for every registered tool name.
    public var catalogBucket: String?
    /// Catalog-provided, presentation-only taxonomy. An absent tag is never
    /// inferred from a display name; callers keep it in the ordinary-tool
    /// bucket until a checked catalog (or canonical fallback) says otherwise.
    public var tags: Set<String>?

    public init(
        name: String,
        description: String,
        parametersPreview: String? = nil,
        dispatchableVia: String? = nil,
        loadState: String? = nil,
        effectiveAutonomy: String? = nil,
        availableNow: Bool? = nil,
        catalogBucket: String? = nil,
        tags: Set<String>? = nil
    ) {
        self.name = name
        self.description = description
        self.parametersPreview = parametersPreview
        self.dispatchableVia = dispatchableVia
        self.loadState = loadState
        self.effectiveAutonomy = effectiveAutonomy
        self.availableNow = availableNow
        self.catalogBucket = catalogBucket
        self.tags = tags
    }
}

/// The full tool manifest, typed: every row, what is loaded, and the
/// Full Mac lanes the Trust Center has open or locked.
public struct ChatToolCatalogSnapshot: Codable, Hashable, Sendable {
    public var tools: [ChatCatalogTool]
    public var currentlyLoaded: Set<String>
    public var builderAvailable: [String]
    public var builderPolicyLocked: [String]
    public var macAppAvailable: [String]
    public var macAppPolicyLocked: [String]
    public var fullMacActive: Bool
    public var fileOpsAllowed: Bool
    public var systemAllowed: Bool
    public var appControlAllowed: Bool
    public var builderModeDetail: String
    public var permissionLevel: String

    /// Reads a full manifest; nil when it is not an object.
    public init?(envelope value: JSONValue) {
        guard case .object(let obj) = value else { return nil }

        func stringArray(_ key: String) -> [String] {
            guard case .array(let arr)? = obj[key] else { return [] }
            return arr.compactMap { v in
                if case .string(let s) = v { return s }
                return nil
            }
        }
        func boolVal(_ key: String) -> Bool {
            if case .bool(let b)? = obj[key] { return b }
            return false
        }
        func stringVal(_ key: String) -> String {
            if case .string(let s)? = obj[key] { return s }
            return ""
        }

        var tools: [ChatCatalogTool] = []
        if case .array(let rows)? = obj["tools"] {
            for row in rows {
                guard case .object(let r) = row,
                      case .string(let name)? = r["name"] else { continue }
                let desc: String = {
                    if case .string(let s)? = r["description"] { return s }
                    return ""
                }()
                var dispatchVia: String?
                if case .string(let dv)? = r["dispatchable_via"] { dispatchVia = dv }
                var loadState: String?
                if case .string(let state)? = r["load_state"] { loadState = state }
                var effectiveAutonomy: String?
                if case .string(let autonomy)? = r["effective_autonomy"] {
                    effectiveAutonomy = autonomy
                }
                var availableNow: Bool?
                if case .bool(let available)? = r["available_now"] { availableNow = available }
                var catalogBucket: String?
                if case .string(let bucket)? = r["catalog_bucket"] {
                    catalogBucket = bucket
                }
                let tags: Set<String>
                if case .array(let values)? = r["tags"] {
                    tags = Set(values.compactMap { value in
                        guard case .string(let tag) = value else { return nil }
                        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                        return normalized.isEmpty ? nil : normalized
                    })
                } else {
                    tags = []
                }
                var paramsPreview: String?
                if case .object(let pobj)? = r["parameters"],
                   case .object(let props)? = pobj["properties"] {
                    let keys = props.keys.sorted()
                    if !keys.isEmpty {
                        paramsPreview = keys.prefix(6).joined(separator: ", ")
                            + (keys.count > 6 ? ", …" : "")
                    }
                }
                tools.append(ChatCatalogTool(
                    name: name,
                    description: desc,
                    parametersPreview: paramsPreview,
                    dispatchableVia: dispatchVia,
                    loadState: loadState,
                    effectiveAutonomy: effectiveAutonomy,
                    availableNow: availableNow,
                    catalogBucket: catalogBucket,
                    tags: tags
                ))
            }
        }

        self.tools = tools
        self.currentlyLoaded = Set(stringArray("currently_loaded"))
        self.builderAvailable = stringArray("builder_available_tools")
        self.builderPolicyLocked = stringArray("builder_policy_locked_tools")
        self.macAppAvailable = stringArray("mac_app_available_tools")
        self.macAppPolicyLocked = stringArray("mac_app_policy_locked_tools")
        self.fullMacActive = boolVal("full_mac_active")
        self.fileOpsAllowed = boolVal("file_ops_allowed")
        self.systemAllowed = boolVal("system_allowed")
        self.appControlAllowed = boolVal("app_control_allowed")
        self.builderModeDetail = stringVal("builder_mode_detail")
        self.permissionLevel = stringVal("permission_level")
    }
}
extension ChatCatalogTool {
    public static func toolDescription(_ id: String, catalogDescription: String? = nil) -> String {
        var name = id.split(separator: ":").last.map(String.init) ?? id
        if name.hasPrefix("mac_assistant.") || name.hasPrefix("mac_assistant_") {
            return "Choose what to watch for on your Mac."
        }
        // The chat catalog uses underscores; capability records also use dotted IDs.
        if name.hasPrefix("mac_") { name = "mac." + name.dropFirst(4) }
        switch name {
        case "git_status", "repo_dirty_summary": return "Check a project's uncommitted changes."
        case "git_diff": return "Show what changed in project files."
        case "git_log": return "Read a project's change history."
        case "git": return "Manage a project's version history."
        case "swift_build": return "Build a Swift project."
        case "swift_test": return "Run a project's tests."
        case "shell", "bash": return "Run commands on your Mac."
        case "apply_patch": return "Apply edits to project files."
        case "file_excerpt": return "Read part of a file."
        case "grep": return "Find text in files."
        case "system_info": return "Check information about your Mac."
        case "remote_node_list": return "List connected computers."
        case "remote_node_execute": return "Run a task on a connected computer."
        case "restart_app": return "Restart this app."
        case "install_app": return "Build and install an updated app."
        case "get_persona_doc": return "Read my personality notes."
        case "delegation_status": return "Check work assigned to other assistants."
        case "forget_memory": return "Remove a saved memory."
        case "rebuild_knowledge_graph": return "Refresh connections between saved memories, or clear out orphaned ones."
        case "read_chat_message": return "Read a complete earlier message."
        case "hold_view": return "Keep a considered opinion for future conversations."
        case "release_view": return "Let go of a previously held opinion."
        case "dream_diary_read": return "Read my dream journal."
        case "clipboard_read": return "Read what you have copied."
        case "clipboard_write": return "Copy text to the clipboard."
        case "menu": return "Read an app's menu."
        case "menu_press": return "Choose an item from an app's menu."
        case "read": return "Read text from a Mac app."
        case "mac.calendar_create_event": return "Add a calendar event."
        case "mac.calendar_modify_event": return "Change a calendar event."
        case "mac.calendar_delete_event": return "Delete a calendar event."
        case "mac.reminders_create": return "Create a reminder."
        case "mac.reminders_complete": return "Mark a reminder as complete."
        case "mac.nudge": return "Move the pointer on your Mac."
        case "mac.keystroke": return "Type text or press keys on your Mac."
        case "mac.click": return "Click on your Mac's screen."
        case "mac.scroll": return "Scroll in a Mac app."
        case "mac.ax_act", "mac.act": return "Use a control on your Mac's screen."
        case "mobile.notify", "mobile_notify": return "Send a notification to your iPhone."
        case "mac.notify", "mac_notify": return "Show a notification on your Mac."
        case "x.status", "x_status": return "Check your X connection."
        // Per-action copy: the family line below ("Find conversations and
        // exchange messages") was landing on every Slack row, status included.
        case "slack.status", "slack_status": return "Check your Slack connection."
        case "slack.list_channels", "slack_list_channels": return "List the Slack channels I can reach."
        case "slack.search_messages", "slack_search_messages": return "Search messages in Slack."
        case "slack.post_message", "slack_post_message": return "Post a message to a Slack channel."
        case "slack.list_unreads": return "See which Slack channels have unread messages."
        case "github.status", "github_status": return "Check your GitHub connection."
        case "gmail.status", "gmail_status": return "Check your Gmail connection."
        case "agentmail.status": return "Check my AgentMail connection."
        case "calendar.status": return "Check your Google Calendar connection."
        case "notion.status", "notion_status": return "Check your Notion connection."
        case "markets.status": return "Check which market data sources are ready."
        case "x.me", "x_me": return "Read your X profile."
        case "x.search_recent", "x_search": return "Search recent posts on X."
        case "x.post_tweet": return "Publish a post on X."
        case "x.timeline_home", "x.timeline_home_v1", "x_timeline": return "Read posts from people you follow on X."
        case "x.user_tweets", "x.user_tweets_v1", "x_user_tweets": return "Read someone's recent posts on X."
        case "local_files.search", "mac.spotlight_search", "mac_spotlight_search": return "Find files on your Mac."
        case "searxng.search": return "Search the web."
        case "searxng.fetch", "read_page": return "Read a web page."
        case "telegram.test": return "Send a test message to Telegram."
        case "mac.read_file", "read_file": return "Read a file."
        case "mac.write_file", "write_file": return "Save content to a file."
        case "mac.list_directory", "list_dir": return "List the files in a folder."
        case "mac.move_file": return "Move or rename a file."
        case "mac.trash_file": return "Move a file to the Trash."
        case "mac.run_shortcut": return "Run an Apple Shortcut."
        case "mac.list_shortcuts": return "List your Apple Shortcuts."
        case "mac.clipboard_read": return "Read what you have copied."
        case "mac.clipboard_write": return "Copy text to the clipboard."
        case "mac.mail_list_recent": return "Read recent messages in Mail."
        case "mac.calendar_list_upcoming", "mac_calendar_list_upcoming": return "See upcoming calendar events."
        case "mac.reminders_list_due_today", "mac_reminders_list_due_today": return "See reminders due today."
        case "mac.messages_list_recent": return "Read recent conversations in Messages."
        case "mac.notes_list_recent", "mac.notes_search": return "Find and read notes."
        case "mac.contacts_search": return "Find people in Contacts."
        case "mac.focus_app": return "Bring an app to the front."
        case "mac.quit_app": return "Quit an app."
        case "mac.running_apps": return "See which apps are running."
        case "mac.set_volume": return "Adjust your Mac's volume."
        case "mac.set_brightness": return "Adjust your screen's brightness."
        case "mac.set_focus_mode": return "Change your Mac's Focus setting."
        case "mac.sleep_display": return "Put the display to sleep."
        case "mac.lock_screen": return "Lock your Mac."
        case "mac.wake": return "Wake your Mac's display."
        case "mac.shell", "mac.applescript", "mac.jxa": return "Run commands to automate work on your Mac."
        case "mac.self_test": return "Check whether Mac controls are working."
        case "mac.ax_status": return "Check permission to use Mac controls."
        case "mac.ax_tree", "mac.ax_find", "mac.view", "mac.screen", "mac.read", "mac.look", "mac.attention", "screen": return "See what's on your Mac's screen."
        case "mac.menu": return "Read an app's menu."
        case "mac.wait", "wait": return "Wait for the screen to change."
        case "mac.go", "go": return "Open an app, file, or website."
        case "act": return "Use a control on your Mac's screen."
        case "image_generate": return "Create an image from a description."
        case "time_now": return "Check the current date and time."
        case "inner_state", "agent_introspect", "daemon_introspect": return "Check how I'm doing and what I'm working on."
        case "recall_memory", "recall_search", "search_kg": return "Find something I remember."
        case "commit_memory": return "Remember something for later."
        case "search_chat_history", "session_search": return "Find an earlier conversation."
        case "request_interaction": return "Ask you for a choice or an answer."
        case "list_skills", "read_skill", "save_skill": return "Find, review or save a task routine."
        case "agent_swarm": return "Ask other assistants for help."
        case "claude_message", "invoke_claude", "codex_message", "invoke_codex", "omp_message": return "Exchange messages with another assistant."
        default: break
        }
        let family = name.split(whereSeparator: { $0 == "." || $0 == "_" }).first.map(String.init) ?? name
        switch family {
        case "mac": return "Use your Mac's apps and controls."
        case "mac_assistant": return "Choose what to watch for on your Mac."
        case "markets", "market", "tradingview": return "Look up market prices and watchlists."
        case "github", "gh": return "Work with GitHub projects, issues, and pull requests."
        case "gmail", "email", "mail": return "Find, read, or prepare email messages."
        case "agentmail": return "Manage messages in the assistant's email account."
        case "calendar", "google": return "Check your calendar and manage events."
        case "notion": return "Find and work with your Notion pages."
        case "slack": return "Find conversations and exchange messages in Slack."
        case "telegram": return "Check or use your Telegram connection."
        case "scheduler": return "Manage tasks scheduled for later."
        case "activity": return "Look back at recent activity."
        case "codex", "agent": return "Coordinate work with other assistants."
        case "browser": return "Open and explore web pages."
        case "bot", "shelf": return "Manage your helpers and their work."
        case "desk": return "Keep track of tasks on your Desk."
        case "persona": return "Read or update my personality notes."
        case "tool", "list": return "Find and prepare tools for a task."
        case "context", "scratchpad", "recent": return "Look up details from my current work."
        case "contacts": return "Find or update contacts."
        case "messages": return "Read or send messages."
        case "notes": return "Find or write notes."
        case "music": return "See and control what's playing."
        case "voice": return "Turn text into speech."
        case "app", "interaction": return "Read or use controls in this app."
        case "doctor": return "Check the app's health."
        case "workshop": return "Submit work and check its progress."
        case "task": return "Read or share progress on tasks."
        case "studio": return "Explore ideas and keep creative notes."
        case "memory": return "Review moments to remember."
        default: return catalogDescription ?? "An additional tool I can use for your tasks."
        }
    }
}

extension String {
    public var withoutStaleNextGenPhaseCopy: String {
        var value = self
        value = value.replacingOccurrences(
            of: #"(?i)next-gen runtime phases?\s+52\s*[-–]\s*92"#,
            with: "Next-Gen Runtime",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)phases?\s+52\s*[-–]\s*92"#,
            with: "next-gen phases",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"phase-52[-–]92"#,
            with: "nextgen-phase",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"phase-73[-–]92"#,
            with: "nextgen-key-phase",
            options: .regularExpression
        )
        return value
    }
}

public struct ToolInputSchema: Decodable, Hashable, Sendable {
    // property name → its descriptor
    public let properties: [String: ToolInputProp]?
    // ordered list of required field names
    public let required: [String]?

    enum CodingKeys: String, CodingKey {
        case properties, required
    }
}

public struct ToolInputProp: Decodable, Hashable, Sendable {
    public let type: String?          // "string" | "integer" | "boolean" | "object" | "array"
    public let description: String?
    // We don't need "default" or "enum" for form rendering right now.
}

public struct ToolCapability: Identifiable, Decodable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let autonomy: String
    public let effectiveAutonomy: String
    public let autonomySource: String
    public let sideEffects: Bool
    public let providerConstraints: [String]?
    public let availableNow: Bool
    // PATCH-Phase7b: input schema for arg-plan resolution + form rendering
    public let inputSchema: ToolInputSchema?

    enum CodingKeys: String, CodingKey {
        case name, description, autonomy
        case effectiveAutonomy    = "effective_autonomy"
        case autonomySource       = "autonomy_source"
        case sideEffects          = "side_effects"
        case providerConstraints  = "provider_constraints"
        case availableNow         = "available_now"
        case inputSchema          = "input_schema"
    }
}

public enum DispatchPlanMode: Equatable {
    /// Tool has no required fields — dispatch immediately with input={}.
    case zeroArgs
    /// Tool has exactly one required string field — stuff freeText into it.
    case singleStringArg(field: String)
    /// Multiple/non-string required fields — open the ToolInputForm sheet.
    case formNeeded
}

public struct DispatchArgPlan {
    public let tool: ToolCapability
    public let mode: DispatchPlanMode
    /// Pre-filled values (populated for .singleStringArg when freeText is non-empty).
    public let prefilled: [String: Any]
    /// 2026-09-06: the conversation the command was typed into. Set by the
    /// caller when the command is accepted, not read later — a form-backed
    /// plan can sit on screen across a session switch, and the dispatch's
    /// placeholder and receipt belong where the command was typed.
    public var sessionId: String = ""

    public init(tool: ToolCapability, mode: DispatchPlanMode, prefilled: [String: Any]) {
        self.tool = tool; self.mode = mode; self.prefilled = prefilled
    }
}

/// The schema-owned conversion boundary between the visual form controls and
/// the dispatch transport. Every accepted value is JSON-shaped, so a sheet
/// cannot close and accidentally turn a malformed complex field into `{}`.
extension ChatToolCatalogSnapshot {
    public enum InputValidationError: LocalizedError, Equatable {
        case missingRequiredField(String)
        case missingSchemaForRequiredField(String)
        case invalidJSON(field: String, expected: String)
        case serializationFailed

        public var errorDescription: String? {
            switch self {
            case .missingRequiredField(let field):
                return "Field \"\(field)\" is required."
            case .missingSchemaForRequiredField(let field):
                return "Required field \"\(field)\" has no usable schema."
            case .invalidJSON(let field, let expected):
                return "Field \"\(field)\" must be valid JSON \(expected)."
            case .serializationFailed:
                return "Tool input could not be encoded for dispatch."
            }
        }
    }

    public static func serializedInput(
        schema: ToolInputSchema?,
        stringValues: [String: String],
        boolValues: [String: Bool],
        intValues: [String: Int]
    ) throws -> Data {
        guard let schema else {
            return try JSONSerialization.data(withJSONObject: [:])
        }
        guard let properties = schema.properties else {
            if let required = schema.required, let field = required.first {
                throw InputValidationError.missingSchemaForRequiredField(field)
            }
            return try JSONSerialization.data(withJSONObject: [:])
        }

        let required = Set(schema.required ?? [])
        for field in required where properties[field] == nil {
            throw InputValidationError.missingSchemaForRequiredField(field)
        }

        var collected: [String: Any] = [:]
        for (name, prop) in properties {
            let type = (prop.type ?? "string").lowercased()
            switch type {
            case "boolean":
                if required.contains(name) || boolValues[name] != nil {
                    collected[name] = boolValues[name] ?? false
                }
            case "integer":
                if let value = intValues[name] {
                    collected[name] = value
                } else if let raw = stringValues[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
                          let value = Int(raw) {
                    collected[name] = value
                }
            case "object", "array":
                guard let raw = nonblank(stringValues[name]) else { continue }
                guard let data = raw.data(using: .utf8),
                      let decoded = try? JSONSerialization.jsonObject(with: data) else {
                    throw InputValidationError.invalidJSON(field: name, expected: "\(type) text")
                }
                if type == "object", let object = decoded as? [String: Any] {
                    collected[name] = object
                } else if type == "array", let array = decoded as? [Any] {
                    collected[name] = array
                } else {
                    throw InputValidationError.invalidJSON(field: name, expected: "\(type) text")
                }
            default:
                if let value = nonblank(stringValues[name]) {
                    collected[name] = value
                }
            }
        }

        for field in required where collected[field] == nil {
            throw InputValidationError.missingRequiredField(field)
        }
        guard JSONSerialization.isValidJSONObject(collected) else {
            throw InputValidationError.serializationFailed
        }
        do {
            return try JSONSerialization.data(withJSONObject: collected)
        } catch {
            throw InputValidationError.serializationFailed
        }
    }

    private static func nonblank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
