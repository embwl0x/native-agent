import Foundation

enum ChatSlashCommandRoute: String, Sendable, CaseIterable {
    case clear, compact, model, think, fast, persona, remember, note, scratch
    case help, tools, nextgen, export, new
}

struct ChatSlashCommandDescriptor: Identifiable, Equatable, Sendable {
    let route: ChatSlashCommandRoute
    let command: String
    let description: String
    let placeholder: String

    var id: String { command }
    var displayedInvocation: String { "/" + (placeholder.isEmpty ? command : placeholder) }
    var helpLine: String { "\(displayedInvocation) — \(description)" }
}

enum ChatSlashCommandRegistry {
    static let all: [ChatSlashCommandDescriptor] = [
        .init(route: .new, command: "new", description: "Start a fresh chat", placeholder: ""),
        .init(route: .clear, command: "clear", description: "Wipe all messages in this session", placeholder: ""),
        .init(route: .compact, command: "compact", description: "Force-compact context window", placeholder: ""),
        .init(route: .model, command: "model", description: "Set model", placeholder: "model <id>"),
        .init(route: .think, command: "think", description: "Set reasoning effort", placeholder: "think <level>"),
        .init(route: .fast, command: "fast", description: "Set GPT priority processing", placeholder: "fast <on|off>"),
        .init(route: .persona, command: "persona", description: "Set active persona", placeholder: "persona <name>"),
        .init(route: .remember, command: "remember", description: "Save a fact to memory", placeholder: "remember <fact>"),
        .init(route: .note, command: "note", description: "Commit a note to agent memory", placeholder: "note <text>"),
        .init(route: .scratch, command: "scratch", description: "Write ephemeral session scratchpad", placeholder: "scratch <key> <value>"),
        .init(route: .tools, command: "tools", description: "Open the Tools catalog", placeholder: ""),
        .init(route: .nextgen, command: "nextgen", description: "Open NextGen in Capabilities", placeholder: ""),
        .init(route: .export, command: "export", description: "Export chat as Markdown to Downloads", placeholder: ""),
        .init(route: .help, command: "help", description: "Show all slash commands", placeholder: ""),
    ]

    static let commandNames = Set(all.map(\.command))

    static func descriptor(named command: String) -> ChatSlashCommandDescriptor? {
        all.first { $0.command == command.lowercased() }
    }

    static func helpText() -> String {
        let lines = all.map(\.helpLine)
        return (["Slash commands:"] + lines + [
            "",
            "Available registered tool names also work as slash commands.",
        ]).joined(separator: "\n")
    }
}
