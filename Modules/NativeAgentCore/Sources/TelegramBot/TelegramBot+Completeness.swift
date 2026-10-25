import Foundation
import ProviderRouting

// Blueprint: | `TelegramBot+Completeness.swift` | `TelegramCommandRegistry` and completeness dependencies: slash parsing, provider/memory/restart ports and compatible model selection |

// MARK: - TelegramBot+Completeness
//
// Slash-command completeness wiring for SwiftNativeTelegramBot. Media and
// voice transcription helpers live in focused sibling files; turn progress
// lives in TelegramPollLoop+ChatProgress.swift.

// MARK: - Dependency protocols (minimal stubs — real wiring at app layer)

/// Provides model/provider selection config for a named surface.
public protocol ProviderRoutingRef: Sendable {
    func modelForSurface(_ surface: String) async -> (model: String, provider: String)?
    func modelMenuForSurface(_ surface: String) async -> TelegramModelMenu?
    func saveModelConfig(surface: String, key: String, value: String) async throws
    func saveModelSelection(surface: String, provider: String?, model: String) async throws
}

public struct TelegramModelMenu: Sendable, Equatable {
    public let surface: String
    public let currentModel: String
    public let currentProvider: String
    public let providers: [TelegramModelProviderChoice]

    public init(
        surface: String,
        currentModel: String,
        currentProvider: String,
        providers: [TelegramModelProviderChoice]
    ) {
        self.surface = surface
        self.currentModel = currentModel
        self.currentProvider = currentProvider
        self.providers = providers
    }
}

public struct TelegramModelProviderChoice: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let isCurrent: Bool
    public let models: [TelegramModelChoice]

    public init(
        id: String,
        displayName: String,
        isCurrent: Bool = false,
        models: [TelegramModelChoice]
    ) {
        self.id = id
        self.displayName = displayName
        self.isCurrent = isCurrent
        self.models = models
    }
}

public struct TelegramModelChoice: Sendable, Equatable {
    public let id: String
    public let name: String
    public let isCurrent: Bool
    public let supportedReasoningEfforts: [String]
    public let supportsFast: Bool

    public init(
        id: String,
        name: String,
        isCurrent: Bool = false,
        supportedReasoningEfforts: [String] = [],
        supportsFast: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isCurrent = isCurrent
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportsFast = supportsFast
    }
}

/// Writes Telegram-originated durable memory and notes through the app layer.
public protocol TelegramMemoryWriteRef: Sendable {
    func remember(text: String, source: String) async throws -> String
    func note(text: String, kind: String, source: String) async throws -> String
}

/// App-layer restart capability for /restart (2026-06-10). This module
/// cannot see AppKit (NSApp.terminate lives above it), so the app layer
/// injects the restart routine the same way the other refs are injected —
/// the bridge routes into AppRestartCoordinator, the SINGLE core restart
/// path shared with the chat `restart_app` tool (one cooldown, one audit
/// trail, one relauncher).
public protocol TelegramRestartRef: Sendable {
    /// Chat ids allowed to fire /restart. Empty set = owner unknown →
    /// the command fails closed.
    func ownerChatIds() async -> Set<Int64>
    /// Run the shared restart routine WITHOUT arming app termination.
    /// The outcome carries the user-facing reply plus, when the restart
    /// actually fired, an `armTerminate` closure the transport invokes
    /// AFTER the reply send attempt — so the reply never races the app
    /// exit.
    func requestRestart(reason: String) async -> TelegramRestartOutcome
}

/// Result of the shared restart routine for the Telegram surface.
public struct TelegramRestartOutcome: Sendable {
    /// User-facing reply text (success note, cooldown refusal, error).
    public let reply: String
    /// Non-nil ONLY when the restart fired (stamp written, relauncher
    /// spawned). The caller MUST invoke it after the reply send attempt —
    /// even on send failure, because the restart is already committed and
    /// skipping the terminate strands a live app behind a fired stamp.
    public let armTerminate: (@Sendable () -> Void)?

    public init(reply: String, armTerminate: (@Sendable () -> Void)? = nil) {
        self.reply = reply
        self.armTerminate = armTerminate
    }
}

/// Outcome of a slash-command dispatch: the reply text (nil = unsupported
/// command) plus an optional followup the transport layer invokes after the
/// reply send attempt completes. Only /restart populates the followup today
/// (terminate-arm sequencing); every other command returns reply-only.
public struct TelegramSlashDispatchOutcome: Sendable {
    public let reply: String?
    public let afterReplySent: (@Sendable () -> Void)?

    public init(reply: String?, afterReplySent: (@Sendable () -> Void)? = nil) {
        self.reply = reply
        self.afterReplySent = afterReplySent
    }
}

// MARK: - TelegramBotCompleteness deps bundle

public struct TelegramBotCompletenessDeps: Sendable {
    public let routing: (any ProviderRoutingRef)?
    public let memory: (any TelegramMemoryWriteRef)?
    public let restart: (any TelegramRestartRef)?

    public init(
        routing: (any ProviderRoutingRef)? = nil,
        memory: (any TelegramMemoryWriteRef)? = nil,
        restart: (any TelegramRestartRef)? = nil
    ) {
        self.routing = routing
        self.memory = memory
        self.restart = restart
    }
}

// MARK: - Telegram command registry

public struct TelegramBotCommand: Sendable, Codable, Equatable {
    public let command: String
    public let description: String

    public init(command: String, description: String) {
        self.command = command
        self.description = description
    }
}

public enum TelegramSlashCommandHandler: String, Sendable, Codable, Equatable {
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
    public let handler: TelegramSlashCommandHandler
    public let showInMenu: Bool

    public init(
        name: String,
        aliases: [String] = [],
        args: String? = nil,
        handler: TelegramSlashCommandHandler,
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

    /// The whole control panel, in one place. Only the first six are a
    /// SURFACE: they are the Telegram command menu and the whole of /help.
    /// Everything below `showInMenu: false` is a retired spelling kept
    /// dispatchable for one release so muscle memory doesn't hit a wall —
    /// the way to reach those settings now is to say what you want
    /// ("use opus", "think harder"), which lands on the same writers.
    public static let definitions: [TelegramSlashCommandDefinition] = [
        .init(name: "stop", aliases: ["cancel"], handler: .stop),
        // `/reset` and `/clear` used to wipe the session file the Mac and
        // phone share; they now start a fresh conversation like `/new`.
        .init(name: "new", aliases: ["start", "reset", "clear"], handler: .new),
        .init(name: "retry", aliases: ["again"], handler: .retry),
        .init(name: "approve", aliases: ["approved", "allow"], args: "<id>", handler: .approve),
        .init(name: "deny", aliases: ["denied", "reject", "rejected"], args: "<id>", handler: .deny),
        .init(name: "help", aliases: ["h"], handler: .help),

        // Retired spellings — dispatchable, never advertised.
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

    public static func definition(for rawName: String) -> TelegramSlashCommandDefinition? {
        let normalized = normalizeName(rawName)
        return definitions.first { definition in
            definition.name == normalized || definition.aliases.contains(normalized)
        }
    }

    public static func canonicalName(for rawName: String) -> String? {
        definition(for: rawName)?.name
    }

    public static func parse(text raw: String) -> TelegramParsedSlashCommand? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let parts = trimmed
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
        guard let first = parts.first else { return nil }
        let rawName = normalizeName(first)
        guard let definition = definition(for: rawName) else { return nil }
        return TelegramParsedSlashCommand(
            definition: definition,
            rawName: rawName,
            args: Array(parts.dropFirst())
        )
    }

    /// 2026-09-06: the `@bot` a slash command is addressed to, if any
    /// (`/stop@OtherBot` -> "OtherBot"). A group delivers every bot command to
    /// every bot in the room, so the poll loop compares this against its own
    /// username before running the command. Nil means the command named no bot
    /// and is addressed to whoever received it.
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


private func telegramProviderIdsMatch(_ lhs: String, _ rhs: String) -> Bool {
    telegramNormalizeProviderId(lhs) == telegramNormalizeProviderId(rhs)
}

private func telegramNormalizeProviderId(_ raw: String) -> String {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
        return "xai_oauth_direct"
    case "moonshot", "kimi":
        return "moonshot"
    default:
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - SwiftNativeTelegramBot: completeness slash commands

extension SwiftNativeTelegramBot {
    public func telegramModelMenuForSurface(_ surface: String = "telegram") async -> TelegramModelMenu? {
        await completenessDeps?.routing?.modelMenuForSurface(surface)
    }

    /// Current model in plain words ("Claude Opus 5 via anthropic"), for
    /// copy User reads. Nil when routing isn't wired.
    public func telegramPlainModelPhrase(_ surface: String = "telegram") async -> String? {
        guard let routing = completenessDeps?.routing,
              let info = await routing.modelForSurface(surface) else { return nil }
        var name = info.model
        if let menu = await routing.modelMenuForSurface(surface) {
            for provider in menu.providers where telegramProviderIdsMatch(provider.id, info.provider) {
                for model in provider.models
                where model.id.caseInsensitiveCompare(info.model) == .orderedSame {
                    let trimmed = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { name = trimmed }
                }
            }
        }
        return TelegramPollLoop._tgRedactToken("\(name) via \(info.provider)")
    }

    public func saveTelegramModelSelection(
        surface: String = "telegram",
        provider: String?,
        model: String
    ) async throws {
        guard let routing = completenessDeps?.routing else {
            throw TelegramBotError.notConfigured
        }
        try await routing.saveModelSelection(surface: surface, provider: provider, model: model)
    }

    /// Detailed variant of `dispatchCompletenessCommand`: same command set,
    /// but the outcome can carry a post-reply followup. /restart uses it so
    /// the transport sends the reply FIRST and only then arms the
    /// grace-period termination — the reply must not race the app exit.
    public func dispatchCompletenessCommandDetailed(
        _ command: String,
        args: [String],
        chatId: Int? = nil,
        fromUserId: Int? = nil,
        chatType: String? = nil
    ) async -> TelegramSlashDispatchOutcome {
        var cmd = command
        if cmd.hasPrefix("/") { cmd.removeFirst() }
        if let atIdx = cmd.firstIndex(of: "@") { cmd = String(cmd[..<atIdx]) }
        let lower = TelegramCommandRegistry.canonicalName(for: cmd) ?? cmd.lowercased()
        if lower == "restart" {
            return await dispatchRestartCommand(
                args: args,
                chatId: chatId, fromUserId: fromUserId, chatType: chatType
            )
        }
        let reply = await dispatchCompletenessCommand(lower, args: args)
        return TelegramSlashDispatchOutcome(reply: reply)
    }

    /// Owner-gated /restart (2026-06-10). Routes through the SAME core
    /// routine as the chat restart_app tool (one cooldown stamp, one audit
    /// trail, one relauncher) via the injected ref.
    private func dispatchRestartCommand(
        args: [String],
        chatId: Int?,
        fromUserId: Int?,
        chatType: String?
    ) async -> TelegramSlashDispatchOutcome {
        guard let restart = completenessDeps?.restart else {
            return TelegramSlashDispatchOutcome(
                reply: "restart is not wired in this build. Restart NativeAgent from the Mac app."
            )
        }
        // BLOCKER FIX (2026-06-10): the old gate compared chatId alone, so
        // an allowlisted GROUP chat let ANY member fire /restart — slash
        // commands run BEFORE the poll loop's group mention gate. Require a
        // PRIVATE chat: chat.type from the wire update when present, with
        // positive-chat-id as the fallback proxy (Telegram group/supergroup/
        // channel ids are negative; private chat id == the user's id).
        let isPrivate: Bool = {
            if let chatType { return chatType == "private" }
            if let chatId { return chatId > 0 }
            return false
        }()
        guard isPrivate else {
            return TelegramSlashDispatchOutcome(
                reply: "/restart only works in a private chat with the owner; group chats cannot restart the app."
            )
        }
        let owners = await restart.ownerChatIds()
        // Fail closed: no allowlist on disk → nobody is the owner; an
        // unidentified sender (nil chatId) is never the owner.
        guard let chatId, !owners.isEmpty, owners.contains(Int64(chatId)) else {
            return TelegramSlashDispatchOutcome(
                reply: "/restart is owner-gated; this chat is not authorized."
            )
        }
        // In a genuine private chat from.id == chat.id. A missing or
        // mismatched sender id fails closed (defense in depth against
        // synthetic/forwarded shapes that spoof a private chat id).
        guard let fromUserId, Int64(fromUserId) == Int64(chatId) else {
            return TelegramSlashDispatchOutcome(
                reply: "/restart is owner-gated; this chat is not authorized."
            )
        }
        let reasonText = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = await restart.requestRestart(
            reason: reasonText.isEmpty ? "telegram /restart" : reasonText
        )
        return TelegramSlashDispatchOutcome(
            reply: outcome.reply,
            afterReplySent: outcome.armTerminate
        )
    }

    private func dispatchCompletenessCommand(
        _ command: String,
        args: [String]
    ) async -> String? {
        let deps = completenessDeps
        let surface = "telegram"

        switch command {
        case "provider":
            guard let routing = deps?.routing else { return nil }
            guard let info = await routing.modelForSurface(surface) else { return nil }
            return "\(info.provider)"

        case "model":
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

        case "think":
            guard let routing = deps?.routing else {
                return "think_routing_unavailable: Think was not changed. Open Providers → Chat to check model routing."
            }
            guard let capabilities = await telegramModelCapabilities(
                routing: routing,
                surface: surface
            ) else {
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

        case "fast":
            guard let routing = deps?.routing else { return nil }
            guard let capabilities = await telegramModelCapabilities(
                routing: routing,
                surface: surface
            ), capabilities.supportsFast else {
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

        case "brain":
            guard let routing = deps?.routing else { return nil }
            guard let info = await routing.modelForSurface(surface) else { return nil }
            return "Brain: \(info.model)@\(info.provider)"

        case "help":
            do { return try await commandProjection().help }
            catch { return "Telegram commands part unavailable: \(error.localizedDescription)" }

        default:
            return nil
        }
    }
}

private func telegramModelCapabilities(
    routing: any ProviderRoutingRef,
    surface: String
) async -> (reasoningEfforts: [String], supportsFast: Bool)? {
    guard let current = await routing.modelForSurface(surface) else { return nil }
    if let menu = await routing.modelMenuForSurface(surface),
       let provider = menu.providers.first(where: {
           $0.id.caseInsensitiveCompare(current.provider) == .orderedSame
               || $0.isCurrent
       }),
       let model = provider.models.first(where: {
           $0.id.caseInsensitiveCompare(current.model) == .orderedSame
       }),
       !model.supportedReasoningEfforts.isEmpty || model.supportsFast {
        return (model.supportedReasoningEfforts, model.supportsFast)
    }
    guard let descriptor = FirstPartyModelCatalog.descriptor(
        for: current.model,
        providerID: current.provider
    ) else { return nil }
    return (descriptor.supportedReasoningEfforts, descriptor.supportsFast)
}
