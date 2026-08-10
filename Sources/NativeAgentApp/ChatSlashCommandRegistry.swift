import Foundation

enum ChatSlashCommandRoute: String, Sendable, CaseIterable {
    case clear, compact, model, think, fast, persona, remember, note, scratch
    case help, tools, nextgen, export
}

struct ChatSlashCommandDescriptor: Identifiable, Equatable, Sendable {
    let route: ChatSlashCommandRoute
    let command: String
    let description: String
    let placeholder: String
    let developerOnly: Bool

    var id: String { command }
    var insertionText: String { placeholder.isEmpty ? command : command + " " }
    var displayedInvocation: String { "/" + (placeholder.isEmpty ? command : placeholder) }
    var helpLine: String { "\(displayedInvocation) — \(description)" }
}

enum ChatSlashCommandRegistry {
    static let all: [ChatSlashCommandDescriptor] = [
        .init(route: .clear, command: "clear", description: "Wipe all messages in this session", placeholder: "", developerOnly: false),
        .init(route: .compact, command: "compact", description: "Force-compact context window", placeholder: "", developerOnly: false),
        .init(route: .model, command: "model", description: "Set model", placeholder: "model <id>", developerOnly: false),
        .init(route: .think, command: "think", description: "Set reasoning effort", placeholder: "think <level>", developerOnly: false),
        .init(route: .fast, command: "fast", description: "Set GPT priority processing", placeholder: "fast <on|off>", developerOnly: false),
        .init(route: .persona, command: "persona", description: "Set active persona", placeholder: "persona <name>", developerOnly: false),
        .init(route: .remember, command: "remember", description: "Save a fact to memory", placeholder: "remember <fact>", developerOnly: false),
        .init(route: .note, command: "note", description: "Commit a note to agent memory", placeholder: "note <text>", developerOnly: false),
        .init(route: .scratch, command: "scratch", description: "Write ephemeral session scratchpad", placeholder: "scratch <key> <value>", developerOnly: false),
        .init(route: .tools, command: "tools", description: "Open the Tools catalog", placeholder: "", developerOnly: false),
        .init(route: .nextgen, command: "nextgen", description: "Open NextGen in Capabilities", placeholder: "", developerOnly: true),
        .init(route: .export, command: "export", description: "Export chat as Markdown to Downloads", placeholder: "", developerOnly: false),
        .init(route: .help, command: "help", description: "Show all slash commands", placeholder: "", developerOnly: false),
    ]

    static let commandNames = Set(all.map(\.command))

    static func descriptor(named command: String) -> ChatSlashCommandDescriptor? {
        all.first { $0.command == command.lowercased() }
    }

    static func visible(showDeveloperSurfaces: Bool) -> [ChatSlashCommandDescriptor] {
        all.filter { showDeveloperSurfaces || !$0.developerOnly }
    }

    static func helpText(showDeveloperSurfaces: Bool) -> String {
        let lines = visible(showDeveloperSurfaces: showDeveloperSurfaces).map(\.helpLine)
        return (["Slash commands:"] + lines + [
            "",
            "Available registered tool names also work as slash commands.",
        ]).joined(separator: "\n")
    }
}
