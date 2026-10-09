import Foundation

/// Display copy only. Tool identifiers and execution payloads stay unchanged.
public enum ToolActivityPresentation {
    public static func title(_ name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title = titles[name.lowercased()] { return title }
        let words = name.split(whereSeparator: { $0 == "_" || $0 == "." || $0 == "-" })
            .joined(separator: " ")
        guard let first = words.first else { return "Use a tool" }
        return first.uppercased() + words.dropFirst()
    }

    /// What I'm doing, in a few plain words, for the turn card, Telegram and
    /// the iPhone. `args` are the call's string arguments; only a short plain
    /// name among them (an app, an agent, a page, a web host) reaches the words.
    public static func progress(_ name: String, args: [String: String] = [:]) -> String {
        switch name.lowercased() {
        case "app", "workspace":
            if let page = plainName(args["page"]) { return "Opening \(page)" }
            if let item = args["item"] {
                let head = item.split(separator: ".").first.map(String.init)
                return plainName(head).map { "Opening \($0)" } ?? "Opening it"
            }
            if args["find"] != nil { return "Looking it up" }
            if args["script"] != nil { return "Running a few steps" }
            return "Looking around"
        case "act": return plainName(args["app"]).map { "Working in \($0)" } ?? "Working on your Mac"
        case "screen": return plainName(args["app"]).map { "Looking at \($0)" } ?? "Looking at your screen"
        case "go": return opening(args["name"])
        case "wait": return plainName(args["agent"]).map { "Waiting on \($0)" } ?? "Waiting for the screen"
        case "agent_message": return plainName(args["agent"]).map { "Messaging \($0)" } ?? "Messaging an agent"
        case "agent_read": return plainName(args["agent"]).map { "Reading \($0)'s reply" } ?? "Reading a reply"
        case "time_now": return "Checking the time"
        case "tool_catalog", "tool_load", "list_tools": return "Looking up tools"
        case "read_skill": return "Loading skill"
        case "list_skills": return "Checking skills"
        case "git_log": return "Checking recent commits"
        case "git_status": return "Checking repo status"
        case "git_diff": return "Checking repo diff"
        case "repo_dirty_summary": return "Checking repo state"
        case "read_file", "file_excerpt": return "Reading file"
        case "list_dir": return "Listing folder"
        case "recall_memory", "recall_search": return "Searching memory"
        case "claude_message", "invoke_claude", "codex_message", "invoke_codex", "omp_message", "agent_swarm":
            return "Starting background work"
        case "search_kg": return "Searching knowledge graph"
        default:
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let words = titles[key] ?? actionLabelLock.withLock { actionLabels[key] }
            return words.flatMap(underway) ?? title(name)
        }
    }

    /// The app's own button words by `app` action id ("provider.test" → "Test
    /// the connection"), and by the folded tool a call is shown as
    /// (files.write → write_file), installed once at launch from the door's registry.
    public static func installActionLabels(_ labels: [String: String]) {
        actionLabelLock.withLock { actionLabels = labels }
    }

    private static let actionLabelLock = NSLock()
    nonisolated(unsafe) private static var actionLabels: [String: String] = [:]

    /// A label as something under way when its first word is a known verb
    /// ("Test the connection" → "Testing the connection"), else as it is;
    /// words after a "(", ";", ":" or "," are the model's notes and stay out.
    private static func underway(_ label: String) -> String? {
        let words = label.prefix { !"(;:,".contains($0) }.trimmingCharacters(in: .whitespaces)
        guard let first = words.split(separator: " ").first else { return nil }
        let verb = first.lowercased()
        guard underwayVerbs.contains(verb) else { return words }
        let ing = doubledVerbs.contains(verb) ? verb + String(verb.suffix(1)) + "ing"
            : verb.hasSuffix("e") && !verb.hasSuffix("ee") ? String(verb.dropLast()) + "ing"
            : verb + "ing"
        return ing.prefix(1).uppercased() + ing.dropFirst() + words.dropFirst(first.count)
    }

    private static let underwayVerbs: Set<String> = Set("""
        archive acknowledge dismiss mark repair act clean open withdraw approve deny show rename pin unpin
        stop regenerate steer send remove compact export close read go add make switch check set test refresh
        sign disconnect turn warm restart revoke back restore delete pause resume release consolidate rewrite
        run decline think reflect settle reset leave include clear enable disable roll quarantine write queue
        drop try save search list create update post find look ask message connect complete commit forget
        review rebuild append amend start cancel generate edit install break talk fetch get query hold
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    private static let doubledVerbs: Set<String> = ["pin", "unpin", "stop", "set", "run", "drop", "commit", "forget", "get"]

    /// `go`'s destination: a web page by its host, a file never by its path.
    private static func opening(_ destination: String?) -> String {
        let raw = destination?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://"), let host = URL(string: raw)?.host() {
            return "Opening " + (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        }
        if lower.hasPrefix("x-apple.systempreferences:") { return "Opening System Settings" }
        if raw.contains("/") || raw.hasPrefix("~") { return "Opening a file" }
        return plainName(raw).map { "Opening \($0)" } ?? "Opening it"
    }

    /// A short name a person would say ("Mail", "Codex", "inbox" → "Inbox");
    /// nil for anything longer or with a path, ref or query in it.
    private static func plainName(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 32,
              text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "'" })
        else { return nil }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    public static func finished(_ name: String, outcome: String? = nil, detail: String? = nil) -> String {
        if let outcome {
            let label: String
            switch outcome {
            case "succeeded": label = "Completed"
            case "failed": label = "Failed"
            case "cancelled": label = "Stopped"
            case "timeout": label = "Timed out"
            default: label = "Completion not confirmed"
            }
            return "\(label): \(title(name))" + (detail.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? "")
        }
        switch name.lowercased() {
        case "tool_catalog", "tool_load", "list_tools": return "Looking up tools"
        default: return "Finished: \(title(name))"
        }
    }

    /// Translate generated approval labels, preserving requesters and literal evidence.
    public static func approvalText(_ text: String, tool: String) -> String {
        guard !tool.isEmpty else { return text }
        let phrase = title(tool)
        let words = tool.split(whereSeparator: { $0 == "_" || $0 == "." }).joined(separator: " ")
        if text == "Allow me to use \(words)?" {
            return "Allow me to \(phrase.prefix(1).lowercased())\(phrase.dropFirst())?"
        }
        if text == "Approve \(tool)" { return "Approve \(phrase)" }
        let requesterSuffix = " asked: Approve \(tool)"
        if text.hasSuffix(requesterSuffix) {
            return String(text.dropLast(requesterSuffix.count)) + " asked: Approve \(phrase)"
        }
        return text
    }

    private static let titles = [
        "read": "Read a document", "apply_patch": "Edit files", "read_file": "Read a file",
        "codex_message": "Send a coding request", "restart_app": "Restart the app",
        "write_file": "Write a file", "git": "Work with version history", "install_app": "Install the app",
        "shell": "Run a command", "list_dir": "List files", "image_generate": "Create an image",
        "tool_load": "Looking up tools", "bash": "Run a command", "claude_message": "Send a helper request",
        "studio_journal": "Write a working note", "tool_catalog": "Looking up tools",
        "list_tools": "Looking up tools", "omp_message": "Send a helper request",
        "invoke_codex": "Ask a coding helper", "invoke_claude": "Ask a helper",
        "agent_swarm": "Start background work", "read_skill": "Read a skill", "list_skills": "Check skills",
        "desk_breakdown": "Break down a task", "mcp__notes__search": "Search notes",
        "mac_calendar_delete_event": "Delete a calendar event",
        "mac_calendar_create_event": "Create a calendar event",
        "mac_calendar_modify_event": "Update a calendar event",
        "mac_calendar_list_upcoming": "Read upcoming calendar events",
    ]

    public static let skillReaderToolNames: Set<String> = [
        "list_skills",
        "read_skill",
    ]

    public static func isSkillReaderTool(named name: String) -> Bool {
        skillReaderToolNames.contains(name)
    }
}
