import Foundation
import NativeAgentShared
// Blueprint: | `ChatSlashCommands.swift` | `ChatSlashCommandHost`: body-window command execution and presentation admission |

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
