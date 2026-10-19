import Foundation
import ProviderRouting

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
    public let summary: String
    public let args: String?
    public let handler: TelegramSlashCommandHandler
    public let showInMenu: Bool

    public init(
        name: String,
        aliases: [String] = [],
        summary: String,
        args: String? = nil,
        handler: TelegramSlashCommandHandler,
        showInMenu: Bool = true
    ) {
        self.name = name
        self.aliases = aliases
        self.summary = summary
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

    public var botCommand: TelegramBotCommand {
        TelegramBotCommand(command: name, description: summary)
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
        .init(name: "stop", aliases: ["cancel"], summary: "Stop the current task", handler: .stop),
        // `/reset` and `/clear` used to wipe the session file the Mac and
        // phone share; they now start a fresh conversation like `/new`.
        .init(name: "new", aliases: ["start", "reset", "clear"], summary: "Start a fresh conversation", handler: .new),
        .init(name: "retry", aliases: ["again"], summary: "Try your last message again", handler: .retry),
        .init(name: "approve", aliases: ["approved", "allow"], summary: "Approve a pending request", args: "<id>", handler: .approve),
        .init(name: "deny", aliases: ["denied", "reject", "rejected"], summary: "Deny a pending request", args: "<id>", handler: .deny),
        .init(name: "help", aliases: ["h"], summary: "What you can type here", handler: .help),

        // Retired spellings — dispatchable, never advertised.
        .init(name: "status", aliases: ["stats"], summary: "Show the agent's current activity", handler: .status, showInMenu: false),
        .init(name: "model", summary: "Show/select Telegram provider model", args: "[number|provider model]", handler: .model, showInMenu: false),
        .init(name: "sessions", aliases: ["recent"], summary: "List recent chat sessions", handler: .sessions, showInMenu: false),
        .init(name: "resume", aliases: ["switch"], summary: "Bind this chat to an existing session", args: "<id>", handler: .resume, showInMenu: false),
        .init(name: "provider", summary: "Show current Telegram provider", handler: .provider, showInMenu: false),
        .init(name: "brain", summary: "Show active model and provider", handler: .brain, showInMenu: false),
        .init(name: "think", summary: "Set reasoning effort", args: "<low|medium|high|xhigh|max|ultra>", handler: .think, showInMenu: false),
        .init(name: "fast", summary: "Toggle provider priority processing", args: "<on|off>", handler: .fast, showInMenu: false),
        .init(name: "persona", summary: "Show or set Telegram persona", args: "[name]", handler: .persona, showInMenu: false),
        .init(name: "remember", summary: "Save a durable memory", args: "<text>", handler: .remember, showInMenu: false),
        .init(name: "note", summary: "Save a note", args: "<text>", handler: .note, showInMenu: false),
        .init(name: "scratch", summary: "Write session scratchpad data", args: "<key> <value>", handler: .scratch, showInMenu: false),
        .init(name: "tools", summary: "Show tool/progress controls", handler: .tools, showInMenu: false),
        .init(name: "session", summary: "Show or change Telegram session state", args: "status|new|reset", handler: .session, showInMenu: false),
        .init(name: "compact", summary: "Compact current session context", handler: .compact, showInMenu: false),
        .init(name: "restart", summary: "Restart NativeAgent app (owner only)", args: "[reason]", handler: .restart, showInMenu: false),
    ]

    public static var commands: [TelegramBotCommand] {
        definitions
            .filter(\.showInMenu)
            .map(\.botCommand)
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

    /// /help lists the menu-visible set and nothing else, so it can never
    /// drift from the command menu Telegram shows.
    public static func helpText() -> String {
        let lines = definitions
            .filter(\.showInMenu)
            .map { "\($0.usage) - \($0.summary)" }
        return (lines + [
            "",
            "Anything else, just say it: \"use opus\", \"think harder\", \"go fast\", \"use the default persona\", \"what model\".",
        ]).joined(separator: "\n")
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

private struct TelegramResolvedModelSelection: Sendable, Equatable {
    let providerId: String?
    let providerDisplayName: String?
    let modelId: String
    let modelName: String?
    let isCurrent: Bool
}

private let telegramModelMenuMaxChoices = 30

private func telegramDisplayModelSelections(
    from menu: TelegramModelMenu
) -> [TelegramResolvedModelSelection] {
    var out: [TelegramResolvedModelSelection] = []
    var seen: Set<String> = []
    for provider in menu.providers {
        for model in provider.models {
            let key = "\(provider.id)\u{0}\(model.id)"
            guard !seen.contains(key) else { continue }
            if out.count < telegramModelMenuMaxChoices || model.isCurrent {
                seen.insert(key)
                out.append(TelegramResolvedModelSelection(
                    providerId: provider.id,
                    providerDisplayName: provider.displayName,
                    modelId: model.id,
                    modelName: model.name,
                    isCurrent: model.isCurrent || (
                        model.id == menu.currentModel
                        && telegramProviderIdsMatch(provider.id, menu.currentProvider)
                    )
                ))
            }
        }
    }
    return out
}

private func telegramAllModelSelections(
    from menu: TelegramModelMenu
) -> [TelegramResolvedModelSelection] {
    menu.providers.flatMap { provider in
        provider.models.map { model in
            TelegramResolvedModelSelection(
                providerId: provider.id,
                providerDisplayName: provider.displayName,
                modelId: model.id,
                modelName: model.name,
                isCurrent: model.isCurrent || (
                    model.id == menu.currentModel
                    && telegramProviderIdsMatch(provider.id, menu.currentProvider)
                )
            )
        }
    }
}

private func telegramRenderModelMenu(_ menu: TelegramModelMenu) -> String {
    let choices = telegramDisplayModelSelections(from: menu)
    guard !choices.isEmpty else {
        return "Surface: \(menu.surface)\nModel: \(menu.currentModel)\nProvider: \(menu.currentProvider)"
    }

    let currentProviderName = menu.providers.first {
        telegramProviderIdsMatch($0.id, menu.currentProvider)
    }?.displayName ?? menu.currentProvider
    var lines = [
        "Telegram model: \(telegramModelLabel(id: menu.currentModel, name: nil))",
        "Provider: \(currentProviderName) (\(menu.currentProvider))",
        "",
        "Choose with /model <number>:",
    ]

    for (idx, choice) in choices.enumerated() {
        let providerLabel = choice.providerDisplayName ?? choice.providerId ?? "Provider"
        let current = choice.isCurrent ? " (current)" : ""
        lines.append("\(idx + 1). \(providerLabel): \(telegramModelLabel(id: choice.modelId, name: choice.modelName))\(current)")
    }

    let total = telegramAllModelSelections(from: menu).count
    if total > choices.count {
        lines.append("+ \(total - choices.count) more; use /model <provider> <model-id>")
    }
    lines.append("")
    lines.append("Direct: /model <provider> <model-id>")
    return lines.joined(separator: "\n")
}

private func telegramResolveModelSelection(
    args: [String],
    menu: TelegramModelMenu?
) -> TelegramResolvedModelSelection? {
    guard let first = args.first?.trimmingCharacters(in: .whitespacesAndNewlines),
          !first.isEmpty else {
        return nil
    }

    if let menu {
        if let index = Int(first) {
            let choices = telegramDisplayModelSelections(from: menu)
            if index >= 1, index <= choices.count {
                return choices[index - 1]
            }
            return nil
        }

        if let provider = telegramProviderChoice(matching: first, in: menu) {
            if args.count == 1 {
                guard let model = provider.models.first else { return nil }
                return TelegramResolvedModelSelection(
                    providerId: provider.id,
                    providerDisplayName: provider.displayName,
                    modelId: model.id,
                    modelName: model.name,
                    isCurrent: model.isCurrent
                )
            }
            let rawModel = args.dropFirst().joined(separator: " ")
            if let model = telegramModelChoice(matching: rawModel, in: provider) {
                return TelegramResolvedModelSelection(
                    providerId: provider.id,
                    providerDisplayName: provider.displayName,
                    modelId: model.id,
                    modelName: model.name,
                    isCurrent: model.isCurrent
                )
            }
            return TelegramResolvedModelSelection(
                providerId: provider.id,
                providerDisplayName: provider.displayName,
                modelId: rawModel,
                modelName: nil,
                isCurrent: false
            )
        }

        let raw = args.joined(separator: " ")
        let matches = telegramAllModelSelections(from: menu).filter {
            telegramTextMatches(raw, $0.modelId)
                || telegramTextMatches(raw, $0.modelName ?? "")
        }
        if matches.count == 1 {
            return matches[0]
        }
    }

    return TelegramResolvedModelSelection(
        providerId: nil,
        providerDisplayName: nil,
        modelId: first,
        modelName: nil,
        isCurrent: false
    )
}

private func telegramProviderChoice(
    matching raw: String,
    in menu: TelegramModelMenu
) -> TelegramModelProviderChoice? {
    if let exact = menu.providers.first(where: {
        telegramTextMatches(raw, $0.id) || telegramTextMatches(raw, $0.displayName)
    }) {
        return exact
    }
    let normalized = telegramNormalizeProviderId(raw)
    let matches = menu.providers.filter { telegramNormalizeProviderId($0.id) == normalized }
    if matches.count == 1 { return matches[0] }
    return nil
}

private func telegramModelChoice(
    matching raw: String,
    in provider: TelegramModelProviderChoice
) -> TelegramModelChoice? {
    provider.models.first {
        telegramTextMatches(raw, $0.id) || telegramTextMatches(raw, $0.name)
    }
}

private func telegramModelLabel(id: String, name: String?) -> String {
    let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let name else {
        return id
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty,
          trimmedName != trimmedId else {
        return id
    }
    return "\(trimmedName) [\(trimmedId)]"
}

private func telegramTextMatches(_ lhs: String, _ rhs: String) -> Bool {
    lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
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
            if let selection = telegramResolveModelSelection(args: args, menu: menu) {
                do {
                    try await routing.saveModelSelection(
                        surface: surface,
                        provider: selection.providerId,
                        model: selection.modelId
                    )
                    let providerSuffix = selection.providerId.map { " @ \($0)" } ?? ""
                    return "Chat model set to \(selection.modelId)\(providerSuffix). Providers → Chat now uses this model for Mac, iPhone, Telegram, and Slack."
                } catch {
                    return "Failed to set Telegram model: \(error.localizedDescription)"
                }
            }
            if !args.isEmpty {
                return "Unknown model selection. Send /model to see available choices."
            }
            if let menu {
                return telegramRenderModelMenu(menu)
            }
            guard let info = await routing.modelForSurface(surface) else { return nil }
            return "Surface: \(surface)\nModel: \(info.model)\nProvider: \(info.provider)"

        case "think":
            guard let routing = deps?.routing else {
                return "Model routing is unavailable; reasoning was not changed."
            }
            guard let capabilities = await telegramModelCapabilities(
                routing: routing,
                surface: surface
            ) else {
                return "/think is unsupported for the selected model."
            }
            let valid = Set(capabilities.reasoningEfforts)
            guard let arg = args.first, valid.contains(arg.lowercased()) else {
                return "/think is unsupported for this model; choose one of \(valid.sorted().joined(separator: "|"))"
            }
            let effort = arg.lowercased()
            do {
                try await routing.saveModelConfig(surface: surface, key: "reasoning_effort", value: effort)
                return "Reasoning effort set to \(effort)"
            } catch {
                return "Failed to set reasoning effort: \(error.localizedDescription)"
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
            return TelegramCommandRegistry.helpText()

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
