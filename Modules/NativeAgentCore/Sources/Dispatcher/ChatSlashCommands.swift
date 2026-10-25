import Foundation

// Blueprint: | `ChatSlashCommands.swift` | `ChatSlashCommandRegistry` and routing: shared command recognition and execution host contract; surface presentation remains local |

public enum ChatSlashCommandRoute: String, Sendable, CaseIterable {
    case clear, compact, model, think, fast, persona, remember, note, scratch
    case help, tools, nextgen, export, new
}

public struct ChatSlashCommandDescriptor: Identifiable, Equatable, Sendable {
    public let route: ChatSlashCommandRoute
    public let command: String
    public let description: String
    public let placeholder: String

    public var id: String { command }
    public var displayedInvocation: String { "/" + (placeholder.isEmpty ? command : placeholder) }
    public var helpLine: String { "\(displayedInvocation) — \(description)" }
}

public enum ChatSlashCommandRegistry {
    public static let all: [ChatSlashCommandDescriptor] = [
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

    public static let commandNames = Set(all.map(\.command))

    public static func descriptor(named command: String) -> ChatSlashCommandDescriptor? {
        all.first { $0.command == command.lowercased() }
    }

    public static func helpText() -> String {
        let lines = all.map(\.helpLine)
        return (["Slash commands:"] + lines + [
            "",
            "Available registered tool names also work as slash commands.",
        ]).joined(separator: "\n")
    }
}


// All chat surfaces share recognition; presentation remains with the surface.
public enum ChatSlashCommandRouting {
    public enum Decision: Equatable, Sendable {
        /// Not a command (plain text, or `/tmp/foo` and other non-command
        /// slash text, which must reach the agent unchanged).
        case sendAsMessage
        /// A recognized command. The payload is the command line with the
        /// leading slash already dropped, matching `handleSlashCommand`.
        case dispatch(String)
        /// A recognized command on a surface that cannot run it. The payload
        /// is the bare command name, for the toast.
        case unsupportedHere(String)
    }

    /// `dynamicToolNames` carries the capability tools a surface can dispatch
    /// (empty on surfaces with no capabilities store). `supportsDispatch` is
    /// the surface's own answer to "can I run a slash command at all?".
    public static func decide(
        text: String,
        dynamicToolNames: Set<String> = [],
        supportsDispatch: Bool
    ) -> Decision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return .sendAsMessage }
        let body = String(trimmed.dropFirst())
        let name = (body.components(separatedBy: .whitespacesAndNewlines).first ?? "")
            .lowercased()
        guard ChatSlashCommandRegistry.commandNames.contains(name)
            || dynamicToolNames.contains(name)
        else {
            return .sendAsMessage
        }
        return supportsDispatch ? .dispatch(body) : .unsupportedHere(name)
    }

    /// Consumer-readable, and it names where the command DOES work rather than
    /// just refusing.
    public static func unsupportedMessage(command: String) -> String {
        "/\(command) only works in the main chat window."
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
    func compactChatSlashSession() async -> String
    func rememberChatSlashFact(_ text: String) async -> (succeeded: Bool, message: String)
    func commitChatSlashNote(_ text: String) async -> (succeeded: Bool, message: String)
    func writeChatSlashScratch(key: String, value: String, sessionId: String) async -> (succeeded: Bool, message: String)
}

public extension ChatSlashCommandRouting {
    enum CommandDisposition {
        case presentation(ChatSlashCommandRoute)
        case consumed
        case deferred
        case tool(name: String, argument: String)
        case refused(String)
    }

    @MainActor
    static func perform(
        _ raw: String,
        sessionId: String,
        tools: [(name: String, available: Bool)],
        host: any ChatSlashCommandHost,
        toast: @escaping @MainActor (String) -> Void,
        mutationFinished: @escaping @MainActor (Bool, String) -> Void
    ) -> CommandDisposition {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let command = parts.first?.lowercased() ?? ""
        let argument = parts.dropFirst().joined(separator: " ")
        switch ChatSlashCommandRegistry.descriptor(named: command)?.route {
        case .new: return .presentation(.new)
        case .clear: return .presentation(.clear)
        case .help: return .presentation(.help)
        case .tools: return .presentation(.tools)
        case .nextgen: return .presentation(.nextgen)
        case .export: return .presentation(.export)
        case .compact:
            if host.activeChatSessionId.isEmpty {
                toast("No active session to compact")
            } else {
                Task { @MainActor in toast(await host.compactChatSlashSession()) }
            }
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
        case nil:
            if let tool = tools.first(where: { $0.name == command }) {
                return tool.available ? .tool(name: command, argument: argument)
                    : .refused("/\(command) is not available now — check tool status in /tools")
            }
            return .refused("Unknown command /\(command). Type /help for the list.")
        }
        return .consumed
    }
}
