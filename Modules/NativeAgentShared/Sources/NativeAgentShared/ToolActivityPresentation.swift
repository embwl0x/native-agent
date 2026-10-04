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

    public static func progress(_ name: String) -> String {
        switch name.lowercased() {
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
        default: return title(name)
        }
    }

    public static func finished(_ name: String) -> String {
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
