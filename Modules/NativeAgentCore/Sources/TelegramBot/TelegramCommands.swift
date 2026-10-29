import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import BackgroundLoops
import ProviderRouting
import ApprovalInbox
import NativeAgentShared
import ChatToolRuntime
import MemoryV2
import DeviceSync
import NotificationInbox

// Blueprint: | `TelegramCommands.swift` | Telegram command identities, aliases, menu visibility, slash parsing and bot dispatch for the destination's conversation |

public struct TelegramBotCommand: Sendable, Codable, Equatable {
    public let command: String
    public let description: String

    public init(command: String, description: String) {
        self.command = command
        self.description = description
    }
}

public enum TelegramSlashCommand: String, Sendable, Codable, Equatable {
    case status
    case new
    case session
    case compact
    case stop
    case retry
    case sessions
    case resume
    case provider
    case model
    case think
    case fast
    case brain
    case persona
    case remember
    case note
    case scratch
    case tools
    case approve
    case deny
    case restart
    case help
}

public struct TelegramSlashCommandDefinition: Sendable, Equatable {
    public let name: String
    public let aliases: [String]
    public let args: String?
    public let handler: TelegramSlashCommand
    public let showInMenu: Bool

    public init(
        name: String,
        aliases: [String] = [],
        args: String? = nil,
        handler: TelegramSlashCommand,
        showInMenu: Bool = true
    ) {
        self.name = name
        self.aliases = aliases
        self.args = args
        self.handler = handler
        self.showInMenu = showInMenu
    }

    public var usage: String {
        if let args, !args.isEmpty {
            return "/\(name) \(args)"
        }
        return "/\(name)"
    }

}

public struct TelegramParsedSlashCommand: Sendable, Equatable {
    public let definition: TelegramSlashCommandDefinition
    public let rawName: String
    public let args: [String]

    public init(
        definition: TelegramSlashCommandDefinition,
        rawName: String,
        args: [String]
    ) {
        self.definition = definition
        self.rawName = rawName
        self.args = args
    }
}

public enum TelegramCommandRegistry {
    public static let version = "2026-09-01-telegram-command-registry-v5"

    /// Only the first six controls appear in the menu and /help; hidden spellings remain dispatchable.
    public static let definitions: [TelegramSlashCommandDefinition] = [
        .init(name: "stop", aliases: ["cancel"], handler: .stop),
        // `/reset` and `/clear` start a new conversation without wiping the shared transcript.
        .init(name: "new", aliases: ["start", "reset", "clear"], handler: .new),
        .init(name: "retry", aliases: ["again"], handler: .retry),
        .init(name: "approve", aliases: ["approved", "allow"], args: "<id>", handler: .approve),
        .init(name: "deny", aliases: ["denied", "reject", "rejected"], args: "<id>", handler: .deny),
        .init(name: "help", aliases: ["h"], handler: .help),

        // Hidden commands remain dispatchable.
        .init(name: "status", aliases: ["stats"], handler: .status, showInMenu: false),
        .init(name: "model", args: "[number|provider model]", handler: .model, showInMenu: false),
        .init(name: "sessions", aliases: ["recent"], handler: .sessions, showInMenu: false),
        .init(name: "resume", aliases: ["switch"], args: "<id>", handler: .resume, showInMenu: false),
        .init(name: "provider", handler: .provider, showInMenu: false),
        .init(name: "brain", handler: .brain, showInMenu: false),
        .init(name: "think", args: "<low|medium|high|xhigh|max|ultra>", handler: .think, showInMenu: false),
        .init(name: "fast", args: "<on|off>", handler: .fast, showInMenu: false),
        .init(name: "persona", args: "[name]", handler: .persona, showInMenu: false),
        .init(name: "remember", args: "<text>", handler: .remember, showInMenu: false),
        .init(name: "note", args: "<text>", handler: .note, showInMenu: false),
        .init(name: "scratch", args: "<key> <value>", handler: .scratch, showInMenu: false),
        .init(name: "tools", handler: .tools, showInMenu: false),
        .init(name: "session", args: "status|new|reset", handler: .session, showInMenu: false),
        .init(name: "compact", handler: .compact, showInMenu: false),
        .init(name: "restart", args: "[reason]", handler: .restart, showInMenu: false),
    ]

    public static var menuCommandNames: [String] {
        definitions
            .filter(\.showInMenu)
            .map(\.name)
    }

    public static func parse(text raw: String) -> TelegramParsedSlashCommand? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let parts = trimmed
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
        guard let first = parts.first else { return nil }
        let rawName = normalizeName(first)
        guard let definition = definitions.first(where: {
            $0.name == rawName || $0.aliases.contains(rawName)
        }) else { return nil }
        return TelegramParsedSlashCommand(
            definition: definition,
            rawName: rawName,
            args: Array(parts.dropFirst())
        )
    }

    /// The slash command's `@bot` suffix, or nil when it names no bot.
    public static func addressedBotUsername(text raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        guard let first = trimmed
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .first else { return nil }
        guard let atIdx = first.firstIndex(of: "@") else { return nil }
        let suffix = String(first[first.index(after: atIdx)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix
    }

    private static func normalizeName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("/") { name.removeFirst() }
        if let atIdx = name.firstIndex(of: "@") {
            name = String(name[..<atIdx])
        }
        return name.lowercased()
    }
}

extension SwiftNativeTelegramBot {
    /// Session commands act on the destination's conversation, including its forum topic.
    public func dispatchSwiftSlashCommandDetailed(
        _ command: TelegramParsedSlashCommand,
        destination: TelegramDestination,
        fromUserId: Int? = nil,
        chatType: String? = nil
    ) async throws -> TelegramSlashDispatchOutcome {
        let args = command.args
        let deps = completenessDeps
        let surface = "telegram"
        var afterReplySent: (@Sendable () -> Void)?
        let reply = try await { () async throws -> String? in
        switch command.definition.handler {
        case .status:
            // Programmatic status reports the selected model and connection; the poll loop owns live-turn status.
            let s = try await self.getStatus()
            let up = (s.enabled ?? false) && (s.tokenConfigured ?? false)
            guard let partFace else { return "Telegram progress part unavailable: the originating app door is not bound." }
            let model = await telegramPlainModelPhrase()
            let approvals = await approvalStatus(destination: destination)
            let face = await TelegramProgressFace(dataRoot: dataRoot, call: partFace)
            let reply = await face.text(input: .object([
                "kind": .string("connection"), "connected": .bool(up),
                "model": .object(["status": .string(model == nil ? "unavailable" : "available"),
                    "phrase": model.map(JSONValue.string) ?? .null]),
                "approvals": approvals
            ]), row: "status")
            await face.close()
            return reply + (up && model == nil ? " Next-turn model is unavailable." : "")
                + (up && approvals.objectValue?["status"] == .string("unavailable")
                ? " Approval status is unavailable; check the pending buttons or Desk in the Mac app." : "")
        case .new:
            let sessionId = try await TelegramSessionStore(dataRoot: dataRoot).startNewSession(destination: destination)
            return "Started new Telegram conversation: \(sessionId)"
        case .session:
            return try await dispatchSessionCommand(args: args, destination: destination)
        case .compact:
            guard let compactionHandler else { return "Compaction is unavailable here." }
            let sessionId = try await TelegramSessionStore(dataRoot: dataRoot).activeSessionId(destination: destination)
            do {
                let result = try await compactionHandler(sessionId)
                if result.compacted {
                    return "Compacted Telegram conversation \(result.sessionId): \(result.messagesBefore) -> \(result.messagesAfter) messages."
                }
                return "Telegram conversation \(result.sessionId) not compacted: \(result.reason)."
            } catch {
                return "Telegram conversation \(sessionId) not compacted: \(error.localizedDescription)."
            }
        case .stop:
            return "No Telegram turn is running for this chat."
        case .retry:
            return "Retry is handled by the live Telegram poll loop."
        case .sessions:
            let sessions = try await TelegramSessionStore(dataRoot: dataRoot)
                .recentSessions(destination: destination, fromUserId: fromUserId, limit: 8)
            if sessions.isEmpty {
                return "No conversations found."
            }
            let lines = sessions.map { session -> String in
                let updated = session.updatedAt.map { ", updated \($0)" } ?? ""
                return "\(session.id) - \(session.title) (\(session.source), \(session.messageCount) message(s)\(updated))"
            }
            return (["Recent conversations:"] + lines + ["Use /resume <id> to bind this Telegram chat."])
                .joined(separator: "\n")
        case .resume:
            let requested = args.first ?? ""
            let status = try await TelegramSessionStore(dataRoot: dataRoot)
                .bindSession(destination: destination, requestedSessionId: requested, fromUserId: fromUserId)
            return """
            Resumed Telegram conversation: \(status.sessionId)
            Persona: \(status.persona)
            Messages: \(status.messageCount)
            """
        case .persona:
            let store = TelegramSessionStore(dataRoot: dataRoot)
            let persona = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if persona.isEmpty {
                let current = try await store.persona(destination: destination) ?? "NativeAgent"
                return "Persona: \(current)"
            }
            let saved = try await store.setPersona(destination: destination, persona: persona)
            return "Persona set to \(saved) for all conversations."
        case .remember, .note:
            return await memoryCommandReply(command: command.definition.name, args: args)
        case .scratch:
            guard let key = args.first else { return "/scratch requires <key> <value>" }
            let value = args.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return "/scratch requires <key> <value>" }
            let sessionId = try await TelegramSessionStore(dataRoot: dataRoot)
                .writeScratch(destination: destination, key: key, value: value)
            return "Wrote scratch \(key) for Telegram conversation \(sessionId)"
        case .tools:
            return """
            Telegram tools use the same Swift chat tool loop and app-wide permissions as the Mac app.
            Tool and skill progress is surfaced in Telegram while the assistant works.
            Available controls: \(TelegramCommandRegistry.menuCommandNames.map { "/\($0)" }.joined(separator: " "))
            """
        case .provider:
            guard let routing = deps?.routing else { return nil }
            guard let menu = await routing.modelMenuForSurface(surface) else { return nil }
            return menu.currentProvider

        case .model:
            guard let routing = deps?.routing else { return nil }
            let menu = await routing.modelMenuForSurface(surface)
            let decision: TelegramModelPickerDecision
            do { decision = try await modelPicker("command", menu: menu, args: args) }
            catch { return "Telegram model picker failed: \(error.localizedDescription)" }
            do {
                if let selection = decision.selection {
                    try Task.checkCancellation()
                    try await routing.saveModelSelection(
                        surface: surface,
                        provider: selection.providerId,
                        model: selection.modelId
                    )
                }
                return decision.reply
            } catch {
                return "Failed to set Telegram model: \(error.localizedDescription)"
            }

        case .think:
            guard let routing = deps?.routing else {
                return "think_routing_unavailable: Think was not changed. Open Providers → Chat to check model routing."
            }
            guard let capabilities = await routing.modelMenuForSurface(surface)?.currentCapabilities else {
                return "think_capabilities_unavailable: The selected model's Think controls are unknown. Open Providers → Chat to check the selected model."
            }
            let valid = Set(capabilities.reasoningEfforts)
            if valid.isEmpty {
                return "think_unsupported: The selected model has no Think control. Send /model to choose a model with Think."
            }
            guard let arg = args.first, valid.contains(arg.lowercased()) else {
                return "think_invalid: Choose a supported Think level. Send /think <\(valid.sorted().joined(separator: "|"))>."
            }
            let effort = arg.lowercased()
            do {
                try await routing.saveModelConfig(surface: surface, key: "reasoning_effort", value: effort)
                return "Think set to \(effort)"
            } catch {
                return "think_save_failed: \(error.localizedDescription). Open Providers → Chat to check the saved Think level."
            }

        case .fast:
            guard let routing = deps?.routing else { return nil }
            guard let capabilities = await routing.modelMenuForSurface(surface)?.currentCapabilities, capabilities.supportsFast else {
                return "/fast is unsupported for the selected model."
            }
            guard let arg = args.first?.lowercased(), ["on", "off"].contains(arg) else {
                return "Usage: /fast <on|off>"
            }
            let tier = arg == "on" ? "priority" : "default"
            do {
                try await routing.saveModelConfig(surface: surface, key: "service_tier", value: tier)
                return "Fast mode \(arg == "on" ? "enabled" : "disabled") for Telegram."
            } catch {
                return "Failed to set Fast mode: \(error.localizedDescription)"
            }

        case .brain:
            guard let routing = deps?.routing else { return nil }
            guard let menu = await routing.modelMenuForSurface(surface) else { return nil }
            return "Brain: \(menu.currentModel)@\(menu.currentProvider)"

        case .help:
            do { return try await commandProjection().help }
            catch { return "Telegram commands part unavailable: \(error.localizedDescription)" }

        case .restart:
            let outcome = await dispatchRestartCommand(
                args: args, chatId: destination.chatId, fromUserId: fromUserId, chatType: chatType
            )
            afterReplySent = outcome.afterReplySent
            return outcome.reply
        case .approve, .deny:
            return nil
        }
        }()
        return TelegramSlashDispatchOutcome(reply: reply, afterReplySent: afterReplySent)
    }

    private func dispatchSessionCommand(args: [String], destination: TelegramDestination) async throws -> String {
        let store = TelegramSessionStore(dataRoot: dataRoot)
        let subcommand = args.first?.lowercased() ?? "status"
        switch subcommand {
        // `reset`/`clear` start a new session while preserving the shared transcript.
        case "new", "reset", "clear":
            let sessionId = try await store.startNewSession(destination: destination)
            return "Started new Telegram conversation: \(sessionId)"
        case "status", "current":
            let status = try await store.status(destination: destination)
            return """
            Telegram conversation: \(status.sessionId)
            Persona: \(status.persona)
            Messages: \(status.messageCount)
            """
        default:
            return "/session supports status|new|reset"
        }
    }
}
