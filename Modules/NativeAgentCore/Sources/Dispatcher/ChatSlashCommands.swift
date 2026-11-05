import Foundation

// Blueprint: | `ChatSlashCommands.swift` | `ChatSlashCommandRegistry`: shared recognition and execution; local presentation |

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
        .init(route: .tools, command: "tools", description: "Open the Tools catalog", placeholder: ""),
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

@MainActor
public protocol ChatSlashCommandHost: AnyObject, Sendable {
    var activeChatSessionId: String { get }
    var chatModel: String { get set }
    var chatReasoningEffort: String { get set }
    var chatFastMode: Bool { get set }
    var chatPersona: String { get set }
    var chatSlashReasoningEfforts: [String] { get }
    func stageChatSlashBrain()
    func saveChatSlashBrain() async -> String
    func rememberChatSlashFact(_ text: String) async -> (succeeded: Bool, message: String)
    func commitChatSlashNote(_ text: String) async -> (succeeded: Bool, message: String)
    func writeChatSlashScratch(key: String, value: String, sessionId: String) async -> (succeeded: Bool, message: String)
}

public extension ChatSlashCommandRouting {
    enum CommandDisposition {
        case presentation(ChatSlashCommandRoute, argument: String)
        case consumed
        case deferred
        case refused(String)
    }

    @MainActor
    static func perform(
        _ raw: String,
        sessionId: String,
        host: any ChatSlashCommandHost,
        toast: @escaping @MainActor (String) -> Void,
        mutationFinished: @escaping @MainActor (Bool, String) -> Void
    ) -> CommandDisposition {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let command = parts.first?.lowercased() ?? ""
        let argument = parts.dropFirst().joined(separator: " ")
        guard let route = ChatSlashCommandRegistry.descriptor(named: command)?.route else {
            return .refused(unknownMessage(command: command))
        }
        switch route {
        case .new: return .presentation(.new, argument: argument)
        case .clear: return .presentation(.clear, argument: argument)
        case .help: return .presentation(.help, argument: argument)
        case .tools: return .presentation(.tools, argument: argument)
        case .export: return .presentation(.export, argument: argument)
        case .settings, .connect, .helpers, .agents, .today, .desk, .memory, .forget, .voice, .context:
            guard argument.isEmpty || route == .connect || route == .memory else {
                return .refused("/\(command) takes no arguments")
            }
            return .presentation(route, argument: argument)
        case .model:
            if !argument.isEmpty {
                host.chatModel = argument
                host.stageChatSlashBrain()
                Task { @MainActor in toast(await host.saveChatSlashBrain()) }
            }
        case .think:
            let effort = argument.lowercased()
            let valid = host.chatSlashReasoningEfforts
            guard valid.contains(effort) else {
                return .refused("Choose a supported level: \(valid.joined(separator: ", "))")
            }
            host.chatReasoningEffort = effort
            host.stageChatSlashBrain()
            Task { @MainActor in toast(await host.saveChatSlashBrain()) }
        case .fast:
            guard host.chatModel.lowercased().hasPrefix("gpt-") else {
                return .refused("Fast mode is only available for GPT models")
            }
            switch argument.lowercased() {
            case "on": host.chatFastMode = true
            case "off": host.chatFastMode = false
            default: return .refused("Usage: /fast <on|off>")
            }
            host.stageChatSlashBrain()
            Task { @MainActor in toast(await host.saveChatSlashBrain()) }
        case .persona:
            if !argument.isEmpty { host.chatPersona = argument }
        case .remember:
            guard !argument.isEmpty else { return .refused("/remember requires a fact") }
            Task { @MainActor in
                let result = await host.rememberChatSlashFact(argument)
                mutationFinished(result.succeeded, result.message)
            }
            return .deferred
        case .note:
            guard !argument.isEmpty else { return .refused("/note requires some text") }
            Task { @MainActor in
                let result = await host.commitChatSlashNote(argument)
                mutationFinished(result.succeeded, result.message)
            }
            return .deferred
        case .scratch:
            let scratch = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard scratch.count == 2 else {
                return .refused("/scratch requires a key and a value: /scratch <key> <value>")
            }
            toast("Writing scratch \(scratch[0])...")
            Task { @MainActor in
                let result = await host.writeChatSlashScratch(key: scratch[0], value: scratch[1], sessionId: sessionId)
                mutationFinished(result.succeeded, result.message)
            }
            return .deferred
        }
        return .consumed
    }
}
