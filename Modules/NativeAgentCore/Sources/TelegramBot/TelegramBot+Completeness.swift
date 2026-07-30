import Foundation
import ProviderRouting

// MARK: - TelegramBot+Completeness
//
// Slash-command completeness wiring for SwiftNativeTelegramBot. Media,
// voice transcription, and progress notice helpers live in focused sibling files.

// MARK: - Dependency protocols (minimal stubs — real wiring at app layer)

/// Provides model/provider selection config for a named surface.
public protocol ProviderRoutingRef: Sendable {
    func modelForSurface(_ surface: String) async -> (model: String, provider: String)?
    func modelMenuForSurface(_ surface: String) async -> TelegramModelMenu?
    func saveModelConfig(surface: String, key: String, value: String) async throws
    func saveModelSelection(surface: String, provider: String?, model: String) async throws
}

public extension ProviderRoutingRef {
    func modelMenuForSurface(_ surface: String) async -> TelegramModelMenu? {
        nil
    }

    func saveModelSelection(surface: String, provider: String?, model: String) async throws {
        try await saveModelConfig(surface: surface, key: "model", value: model)
    }
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

/// Placeholder for the approval inbox — used as a dep handle only.
public protocol ApprovalInboxRef: Sendable {}

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
    public let inbox: (any ApprovalInboxRef)?
    public let memory: (any TelegramMemoryWriteRef)?
    public let restart: (any TelegramRestartRef)?

    public init(
        routing: (any ProviderRoutingRef)? = nil,
        inbox: (any ApprovalInboxRef)? = nil,
        memory: (any TelegramMemoryWriteRef)? = nil,
        restart: (any TelegramRestartRef)? = nil
    ) {
        self.routing = routing
        self.inbox = inbox
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
    case reset
    case session
    case clear
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
    public static let version = "2026-07-09-telegram-command-registry-v4"

    public static let definitions: [TelegramSlashCommandDefinition] = [
        .init(name: "help", aliases: ["h"], summary: "Show Telegram command help", handler: .help),
        .init(name: "status", aliases: ["stats"], summary: "Show runtime, model, session, and task status", handler: .status),
        .init(name: "model", summary: "Show/select Telegram provider model", args: "[number|provider model]", handler: .model),
        .init(name: "new", aliases: ["start"], summary: "Start a fresh Telegram chat session", handler: .new),
        .init(name: "stop", aliases: ["cancel"], summary: "Cancel the current Telegram turn", handler: .stop),
        .init(name: "retry", aliases: ["again"], summary: "Retry the last Telegram user message", handler: .retry),
        .init(name: "sessions", aliases: ["recent"], summary: "List recent chat sessions", handler: .sessions),
        .init(name: "resume", aliases: ["switch"], summary: "Bind this chat to an existing session", args: "<id>", handler: .resume),
        .init(name: "approve", aliases: ["approved", "allow"], summary: "Approve a pending request", args: "<id>", handler: .approve),
        .init(name: "deny", aliases: ["denied", "reject", "rejected"], summary: "Deny a pending request", args: "<id>", handler: .deny),
        .init(name: "provider", summary: "Show current Telegram provider", handler: .provider),
        .init(name: "brain", summary: "Show active model and provider", handler: .brain),
        .init(name: "think", summary: "Set reasoning effort", args: "<low|medium|high|xhigh|max|ultra>", handler: .think),
        .init(name: "fast", summary: "Toggle provider priority processing", args: "<on|off>", handler: .fast),
        .init(name: "persona", summary: "Show or set Telegram persona", args: "[name]", handler: .persona),
        .init(name: "remember", summary: "Save a durable memory", args: "<text>", handler: .remember),
        .init(name: "note", summary: "Save a note", args: "<text>", handler: .note),
        .init(name: "scratch", summary: "Write session scratchpad data", args: "<key> <value>", handler: .scratch),
        .init(name: "tools", summary: "Show tool/progress controls", handler: .tools),
        .init(name: "session", summary: "Show or change Telegram session state", args: "status|new|reset", handler: .session),
        .init(name: "reset", summary: "Clear the active Telegram session", handler: .reset),
        .init(name: "clear", summary: "Clear current session messages", handler: .clear),
        .init(name: "compact", summary: "Compact current session context", handler: .compact),
        .init(name: "restart", summary: "Restart NativeAgent app (owner only)", args: "[reason]", handler: .restart),
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

    public static func helpText() -> String {
        let lines = definitions.map { definition -> String in
            let aliasText: String
            if definition.aliases.isEmpty {
                aliasText = ""
            } else {
                aliasText = " (aliases: " + definition.aliases.map { "/\($0)" }.joined(separator: ", ") + ")"
            }
            return "\(definition.usage) - \(definition.summary)\(aliasText)"
        }
        return ([
            "Telegram commands:",
            "Slash commands are handled locally before chat."
        ] + lines).joined(separator: "\n")
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
    case "anthropic", "anthropic_oauth_direct", "anthropic_mcp":
        return "anthropic"
    case "openai", "openai_oauth_direct":
        return "openai"
    case "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
        return "xai"
    case "moonshot", "kimi":
        return "moonshot"
    case "openrouter":
        return "openrouter"
    case "codex":
        return "codex"
    default:
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Actor registry: ObjectIdentifier(bot) -> deps

public actor TelegramBotCompletenessRegistry {
    public static let shared = TelegramBotCompletenessRegistry()
    private var store: [ObjectIdentifier: TelegramBotCompletenessDeps] = [:]

    private init() {}

    public func register(_ deps: TelegramBotCompletenessDeps, for id: ObjectIdentifier) {
        store[id] = deps
    }

    public func deps(for id: ObjectIdentifier) -> TelegramBotCompletenessDeps? {
        store[id]
    }
}

// MARK: - SwiftNativeTelegramBot: completeness slash commands

extension SwiftNativeTelegramBot {
    /// Register dependency providers so completeness commands can resolve live data.
    public func registerCompletenessDeps(_ deps: TelegramBotCompletenessDeps) async {
        await TelegramBotCompletenessRegistry.shared.register(deps, for: ObjectIdentifier(self))
    }

    public func telegramModelMenuForSurface(_ surface: String = "telegram") async -> TelegramModelMenu? {
        if let routing = completenessDeps?.routing {
            return await routing.modelMenuForSurface(surface)
        }
        let deps = await TelegramBotCompletenessRegistry.shared.deps(for: ObjectIdentifier(self))
        return await deps?.routing?.modelMenuForSurface(surface)
    }

    public func saveTelegramModelSelection(
        surface: String = "telegram",
        provider: String?,
        model: String
    ) async throws {
        if let routing = completenessDeps?.routing {
            try await routing.saveModelSelection(surface: surface, provider: provider, model: model)
            return
        }
        let deps = await TelegramBotCompletenessRegistry.shared.deps(for: ObjectIdentifier(self))
        guard let routing = deps?.routing else {
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
        depsOverride: TelegramBotCompletenessDeps? = nil,
        chatId: Int? = nil,
        fromUserId: Int? = nil,
        chatType: String? = nil
    ) async -> TelegramSlashDispatchOutcome {
        var cmd = command
        if cmd.hasPrefix("/") { cmd.removeFirst() }
        if let atIdx = cmd.firstIndex(of: "@") { cmd = String(cmd[..<atIdx]) }
        let lower = TelegramCommandRegistry.canonicalName(for: cmd) ?? cmd.lowercased()
        if lower == "restart" {
            let deps: TelegramBotCompletenessDeps?
            if let depsOverride {
                deps = depsOverride
            } else {
                deps = await TelegramBotCompletenessRegistry.shared.deps(for: ObjectIdentifier(self))
            }
            return await dispatchRestartCommand(
                args: args, deps: deps,
                chatId: chatId, fromUserId: fromUserId, chatType: chatType
            )
        }
        let reply = await dispatchCompletenessCommand(
            lower, args: args, depsOverride: depsOverride,
            chatId: chatId, fromUserId: fromUserId, chatType: chatType
        )
        return TelegramSlashDispatchOutcome(reply: reply)
    }

    /// Owner-gated /restart (2026-06-10). Routes through the SAME core
    /// routine as the chat restart_app tool (one cooldown stamp, one audit
    /// trail, one relauncher) via the injected ref.
    private func dispatchRestartCommand(
        args: [String],
        deps: TelegramBotCompletenessDeps?,
        chatId: Int?,
        fromUserId: Int?,
        chatType: String?
    ) async -> TelegramSlashDispatchOutcome {
        guard let restart = deps?.restart else {
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

    /// Dispatch additional slash commands not handled by the base `dispatchSwiftSlashCommand`.
    /// Returns a reply string, or nil for an unsupported command.
    /// `chatId` is the verified sender chat — required by owner-gated
    /// commands (/restart); nil (legacy callers/tests) fails those closed.
    /// `fromUserId`/`chatType` likewise feed the /restart gate (private
    /// chat + sender == chat); nil fails it closed.
    public func dispatchCompletenessCommand(
        _ command: String,
        args: [String],
        depsOverride: TelegramBotCompletenessDeps? = nil,
        chatId: Int? = nil,
        fromUserId: Int? = nil,
        chatType: String? = nil
    ) async -> String? {
        var cmd = command
        if cmd.hasPrefix("/") { cmd.removeFirst() }
        if let atIdx = cmd.firstIndex(of: "@") { cmd = String(cmd[..<atIdx]) }
        let lower = TelegramCommandRegistry.canonicalName(for: cmd) ?? cmd.lowercased()

        let deps: TelegramBotCompletenessDeps?
        if let depsOverride {
            deps = depsOverride
        } else {
            deps = await TelegramBotCompletenessRegistry.shared.deps(for: ObjectIdentifier(self))
        }
        let surface = "telegram"

        switch lower {
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
                    return "Telegram model set to \(selection.modelId)\(providerSuffix). Providers tab will reflect this under Telegram."
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

        case "restart":
            // Legacy single-string path (tests/programmatic callers): the
            // gate logic lives ONCE in dispatchRestartCommand. This wrapper
            // can't sequence reply-then-arm, so any followup runs
            // immediately; the poll loop goes through
            // dispatchCompletenessCommandDetailed for correct ordering.
            let outcome = await dispatchRestartCommand(
                args: args, deps: deps,
                chatId: chatId, fromUserId: fromUserId, chatType: chatType
            )
            outcome.afterReplySent?()
            return outcome.reply

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

// MARK: - Free dispatch helper (usable from tests without a bot instance)

/// Stateless dispatch helper. Resolves deps via the registry for the given bot,
/// then falls through to nil for unknown commands. Tests can call this directly.
public func dispatchSwiftSlashCommand(
    bot: SwiftNativeTelegramBot,
    command: String,
    args: [String],
    chatId: Int? = nil,
    fromUserId: Int? = nil,
    chatType: String? = nil
) async -> String? {
    await bot.dispatchCompletenessCommand(
        command, args: args, chatId: chatId,
        fromUserId: fromUserId, chatType: chatType
    )
}
