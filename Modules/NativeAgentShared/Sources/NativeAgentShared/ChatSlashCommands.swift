import Foundation

// Blueprint: | `ChatSlashCommands.swift` | `ChatSlashCommandRegistry`, `ChatSlashCommandRouting`: one immutable command vocabulary and recognition |

public enum ChatSlashCommandRoute: String, Sendable, CaseIterable {
    case clear, model, think, fast, persona, remember, note, scratch
    case help, tools, export, new
    case settings, connect, helpers, agents, today, desk, memory, forget, voice, context
}

public struct ChatSlashCommandDescriptor: Identifiable, Equatable, Sendable {
    public let route: ChatSlashCommandRoute
    public let command: String
    public let description: String
    public let placeholder: String

    public var id: String { command }
    public var selection: String { placeholder.isEmpty ? command : command + " " }
    public var displayedInvocation: String { "/" + (placeholder.isEmpty ? command : placeholder) }
    public var helpLine: String { "\(displayedInvocation) — \(description)" }
}

public enum ChatSlashCommandRegistry {
    public static let all: [ChatSlashCommandDescriptor] = [
        .init(route: .new, command: "new", description: "Start a fresh chat", placeholder: ""),
        .init(route: .clear, command: "clear", description: "Wipe all messages in this session", placeholder: ""),
        .init(route: .model, command: "model", description: "Set model", placeholder: "model <id>"),
        .init(route: .think, command: "think", description: "Set reasoning effort", placeholder: "think <level>"),
        .init(route: .fast, command: "fast", description: "Set GPT priority processing", placeholder: "fast <on|off>"),
        .init(route: .persona, command: "persona", description: "Set active persona", placeholder: "persona <name>"),
        .init(route: .remember, command: "remember", description: "Save a fact to memory", placeholder: "remember <fact>"),
        .init(route: .note, command: "note", description: "Commit a note to agent memory", placeholder: "note <text>"),
        .init(route: .scratch, command: "scratch", description: "Write ephemeral session scratchpad", placeholder: "scratch <key> <value>"),
        .init(route: .tools, command: "tools", description: "Open Capabilities: chat tools, abilities and senses", placeholder: ""),
        .init(route: .export, command: "export", description: "Export chat as Markdown to Downloads", placeholder: ""),
        .init(route: .settings, command: "settings", description: "Open Settings", placeholder: ""),
        .init(route: .connect, command: "connect", description: "Open connections or a service's setup", placeholder: "connect [service]"),
        .init(route: .helpers, command: "helpers", description: "Open Helpers", placeholder: ""),
        .init(route: .agents, command: "agents", description: "Open agent connections and threads", placeholder: ""),
        .init(route: .today, command: "today", description: "Open Today", placeholder: ""),
        .init(route: .desk, command: "desk", description: "Open Desk", placeholder: ""),
        .init(route: .memory, command: "memory", description: "Browse or search saved memories", placeholder: "memory [thing]"),
        .init(route: .forget, command: "forget", description: "Choose a saved memory to forget, with confirmation", placeholder: ""),
        .init(route: .voice, command: "voice", description: "Start or stop voice input", placeholder: ""),
        .init(route: .context, command: "context", description: "Open the last turn's context receipt", placeholder: ""),
        .init(route: .help, command: "help", description: "Show all slash commands", placeholder: ""),
    ]

    public static let commandNames = Set(all.map(\.command))

    public static func descriptor(named command: String) -> ChatSlashCommandDescriptor? {
        all.first { $0.command == command.lowercased() }
    }

    public static func helpText() -> String {
        (["Slash commands:"] + all.map(\.helpLine)).joined(separator: "\n")
    }
}


public enum ChatSlashCommandRouting {
    public enum Decision: Equatable, Sendable {
        /// Non-command slash text, including paths, must reach the agent unchanged.
        case sendAsMessage
        case dispatch(String)
        case unsupportedHere(String)
        case unknownCommand(String)
    }

    public static func decide(
        text: String,
        supportsDispatch: Bool
    ) -> Decision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return .sendAsMessage }
        let body = String(trimmed.dropFirst())
        let name = (body.components(separatedBy: .whitespacesAndNewlines).first ?? "")
            .lowercased()
        guard ChatSlashCommandRegistry.commandNames.contains(name) else {
            // Paths and slash prose remain messages; a command-shaped word must never silently start a turn.
            return name.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression) != nil
                ? .unknownCommand(name) : .sendAsMessage
        }
        return supportsDispatch ? .dispatch(body) : .unsupportedHere(name)
    }

    /// Name a supported surface so refusal also offers a way to run the command.
    public static func unsupportedMessage(command: String) -> String {
        "/\(command) only works in the main chat window."
    }

    public static func unknownMessage(command: String) -> String {
        "Unknown command /\(command). Type /help for the list."
    }
}
