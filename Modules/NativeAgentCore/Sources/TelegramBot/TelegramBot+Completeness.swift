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
    public static let version = "2026-09-01-telegram-command-registry-v5"

    /// The whole control panel, in one place. Only the first six are a
    /// SURFACE: they are the Telegram command menu and the whole of /help.
    /// Everything below `showInMenu: false` is a retired spelling kept
    /// dispatchable for one release so muscle memory doesn't hit a wall —
    /// the way to reach those settings now is to say what you want
    /// ("use opus", "think harder"), which lands on the same writers.
    public static let definitions: [TelegramSlashCommandDefinition] = [
        .init(name: "stop", aliases: ["cancel"], summary: "Stop what I'm doing", handler: .stop),
        .init(name: "new", aliases: ["start"], summary: "Start a fresh conversation", handler: .new),
        .init(name: "retry", aliases: ["again"], summary: "Try your last message again", handler: .retry),
        .init(name: "approve", aliases: ["approved", "allow"], summary: "Approve a pending request", args: "<id>", handler: .approve),
        .init(name: "deny", aliases: ["denied", "reject", "rejected"], summary: "Deny a pending request", args: "<id>", handler: .deny),
        .init(name: "help", aliases: ["h"], summary: "What you can type here", handler: .help),

        // Retired spellings — dispatchable, never advertised.
        .init(name: "status", aliases: ["stats"], summary: "Show what I'm doing", handler: .status, showInMenu: false),
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
        .init(name: "reset", summary: "Clear the active Telegram session", handler: .reset, showInMenu: false),
        .init(name: "clear", summary: "Clear current session messages", handler: .clear, showInMenu: false),
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
            "Anything else, just say it: \"use opus\", \"think harder\", \"go fast\", \"use the default persona\", \"what model are you on\".",
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

// MARK: - Preferences asked for in words

/// A preference User stated in ordinary words instead of a slash command.
/// Parsing is deliberately narrow: it only fires on a whole message that is
/// unambiguously a preference change, and a model request must still resolve
/// against the LIVE model menu before anything is written. Anything else is
/// ordinary conversation and goes to the chat turn untouched.
public enum TelegramSpokenPreference: Sendable, Equatable {
    /// "use opus", "switch to gpt-5.5"
    case model(query: String)
    /// "think harder", "think low"
    case effort(TelegramSpokenEffort)
    /// "go fast", "turn off fast mode"
    case fast(Bool)
    /// "use the Agent persona"
    case persona(String)
    /// "what model are you on"
    case whichModel

    private static let whichModelPhrases: Set<String> = [
        "what model are you on", "what model are you using", "what model is this",
        "which model are you on", "which model are you using", "which model is this",
        "what model", "which model", "what brain are you using", "what brain",
        "what provider are you on", "which provider are you on",
    ]

    private static let fastOnPhrases: Set<String> = [
        "go fast", "be fast", "fast mode", "fast mode on", "use fast mode",
        "turn on fast", "turn on fast mode", "turn fast mode on", "prioritize speed",
    ]

    private static let fastOffPhrases: Set<String> = [
        "fast mode off", "turn off fast", "turn off fast mode", "turn fast mode off",
        "stop going fast", "normal speed",
    ]

    private static let thinkHarderPhrases: Set<String> = [
        "think harder", "think deeper", "think more", "think longer", "think hard",
        "think really hard", "reason harder", "put more thought into it",
    ]

    private static let thinkLessPhrases: Set<String> = [
        "think less", "think faster", "think quicker", "stop thinking so hard",
        "dont think so hard", "don't think so hard", "less thinking",
    ]

    /// Canonical low-to-high ladder. Only levels a model actually supports
    /// are ever written; this is just the ordering.
    public static let effortLadder = ["low", "medium", "high", "xhigh", "max", "ultra"]

    private static let modelLeadIns = [
        "set the model to ", "set model to ", "change the model to ", "change model to ",
        "switch the model to ", "switch model to ", "use the model ", "use model ",
        "switch to ", "swap to ", "change to ", "run on ", "use ",
    ]

    private static let personaLeadIns = [
        "set the persona to ", "set persona to ", "switch the persona to ",
        "switch persona to ", "change the persona to ", "change persona to ",
        "use the persona ", "use persona ",
    ]

    public static func parse(text raw: String) -> TelegramSpokenPreference? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A short line is a request; a paragraph is a conversation.
        guard !text.isEmpty, text.count <= 80, !text.contains("\n") else { return nil }
        text = text.lowercased()
        while let last = text.last, ".!?,".contains(last) { text.removeLast() }
        for vocative in ["hey agent ", "ok agent ", "agent ", "hey ", "ok ", "please "] {
            if text.hasPrefix(vocative) {
                text.removeFirst(vocative.count)
                break
            }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        if whichModelPhrases.contains(text) { return .whichModel }
        if fastOnPhrases.contains(text) { return .fast(true) }
        if fastOffPhrases.contains(text) { return .fast(false) }
        if thinkHarderPhrases.contains(text) { return .effort(.highest) }
        if thinkLessPhrases.contains(text) { return .effort(.lowest) }

        for lead in ["think ", "set effort to ", "set the effort to ", "set reasoning to ",
                     "reasoning effort ", "effort "] where text.hasPrefix(lead) {
            let level = String(text.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
            if effortLadder.contains(level) { return .effort(.level(level)) }
        }

        // Persona needs the word "persona" — a bare "be X" is conversation.
        for lead in personaLeadIns where text.hasPrefix(lead) {
            let name = String(text.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
            if let name = validName(name) { return .persona(name) }
        }
        if text.hasPrefix("use the "), text.hasSuffix(" persona") {
            let name = String(text.dropFirst(8).dropLast(8)).trimmingCharacters(in: .whitespaces)
            if let name = validName(name) { return .persona(name) }
        }

        for lead in modelLeadIns where text.hasPrefix(lead) {
            var query = String(text.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
            for tail in [" instead", " for now", " model", " please"] where query.hasSuffix(tail) {
                query = String(query.dropLast(tail.count)).trimmingCharacters(in: .whitespaces)
            }
            if query.hasPrefix("the ") { query = String(query.dropFirst(4)) }
            // A model name is short. Three-plus words is a sentence about
            // something else ("switch to the branch I pushed").
            guard query.count >= 3, query.count <= 40,
                  query.split(separator: " ").count <= 3 else { return nil }
            return .model(query: query)
        }
        return nil
    }

    private static func validName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.count <= 40,
              trimmed.split(separator: " ").count <= 3 else { return nil }
        return trimmed
    }
}

public enum TelegramSpokenEffort: Sendable, Equatable {
    case highest
    case lowest
    case level(String)

    /// Resolve against what the CURRENT model actually supports; an
    /// unsupported ask resolves to nil rather than writing a level the
    /// provider will reject.
    public func resolved(supported: [String]) -> String? {
        let ordered = TelegramSpokenPreference.effortLadder.filter { supported.contains($0) }
        guard !ordered.isEmpty else { return nil }
        switch self {
        case .highest: return ordered.last
        case .lowest: return ordered.first
        case .level(let level): return ordered.contains(level) ? level : nil
        }
    }
}

/// One resolved model, in the exact shape /model's writer takes.
public struct TelegramSpokenModelMatch: Sendable, Equatable {
    public let providerId: String
    public let modelId: String
    /// Plain names, for copy User reads back ("Claude Sonnet 4.6 on Anthropic").
    public let label: String
    public let providerLabel: String

    public init(providerId: String, modelId: String, label: String, providerLabel: String) {
        self.providerId = providerId
        self.modelId = modelId
        self.label = label
        self.providerLabel = providerLabel
    }
}

public extension TelegramSpokenPreference {
    /// Resolve a spoken model name against the live menu. Nil means "that
    /// wasn't a model" — the message stays ordinary conversation.
    static func resolveModel(query: String, in menu: TelegramModelMenu) -> TelegramSpokenModelMatch? {
        let needle = telegramCompactKey(query)
        guard needle.count >= 3 else { return nil }
        var exact: [TelegramSpokenModelMatch] = []
        var partial: [TelegramSpokenModelMatch] = []
        var currentProviderHits: [TelegramSpokenModelMatch] = []
        for provider in menu.providers {
            for model in provider.models {
                let idKey = telegramCompactKey(model.id)
                let nameKey = telegramCompactKey(model.name)
                let plainName = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let match = TelegramSpokenModelMatch(
                    providerId: provider.id,
                    modelId: model.id,
                    label: plainName.isEmpty ? model.id : plainName,
                    providerLabel: provider.displayName.isEmpty ? provider.id : provider.displayName
                )
                if idKey == needle || nameKey == needle {
                    exact.append(match)
                } else if idKey.contains(needle) || nameKey.contains(needle) {
                    partial.append(match)
                    if telegramProviderIdsMatch(provider.id, menu.currentProvider) {
                        currentProviderHits.append(match)
                    }
                }
            }
        }
        if let first = exact.first { return first }
        // A partial match only counts when it is UNAMBIGUOUS. "opus" naming
        // the one Opus in the menu is a switch; "claude" naming three of them
        // is not, and picking the first would silently reroute User to a model
        // he never said. Current-provider hits are PREFERRED (they narrow the
        // field), but they still have to narrow it to exactly one — otherwise
        // this returns nil, the message stays ordinary conversation, and the
        // ordinary reply path asks which one he meant.
        let pool = currentProviderHits.isEmpty ? partial : currentProviderHits
        return pool.count == 1 ? pool[0] : nil
    }
}

private func telegramCompactKey(_ raw: String) -> String {
    String(raw.lowercased().unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0)
    }.map(Character.init))
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

// MARK: - Actor registry: ObjectIdentifier(bot) -> deps

public actor TelegramBotCompletenessRegistry {
    public static let shared = TelegramBotCompletenessRegistry()
    private var store: [ObjectIdentifier: TelegramBotCompletenessDeps] = [:]
    private var unregisterWaiters: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]

    private init() {}

    public func register(_ deps: TelegramBotCompletenessDeps, for id: ObjectIdentifier) {
        store[id] = deps
    }

    public func deps(for id: ObjectIdentifier) -> TelegramBotCompletenessDeps? {
        store[id]
    }

    public func unregister(_ id: ObjectIdentifier) {
        store.removeValue(forKey: id)
        if let waiters = unregisterWaiters.removeValue(forKey: id) {
            for waiter in waiters { waiter.resume() }
        }
    }

    public func registeredCount() -> Int {
        store.count
    }

    /// Snapshot of currently registered bot ids. Lets callers assert on the
    /// ids THEY own instead of a process-global count that other concurrent
    /// registrants perturb.
    public func registeredIDs() -> Set<ObjectIdentifier> {
        Set(store.keys)
    }

    /// Event-driven seam for the deinit's detached-Task unregister (mirrors
    /// the TurnTraceBus.drainForProcessExit drain pattern): suspend until
    /// `unregister(id)` has run for this id — resumed by `unregister` itself,
    /// no polling. Immediate resume when the id is not currently registered.
    /// Callers own the bound (e.g. a test `.timeLimit`); if the unregister
    /// never fires, that bound fails the wait loudly.
    public func waitForUnregister(_ id: ObjectIdentifier) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard store[id] != nil else {
                continuation.resume()
                return
            }
            unregisterWaiters[id, default: []].append(continuation)
        }
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

    /// What the CURRENT model can actually be asked for — the same lookup
    /// /think and /fast gate on, exposed so spoken phrases ("think harder")
    /// resolve against the same truth.
    public func telegramModelCapabilitiesForSurface(
        _ surface: String = "telegram"
    ) async -> (reasoningEfforts: [String], supportsFast: Bool)? {
        guard let routing = await telegramRouting() else { return nil }
        return await telegramModelCapabilities(routing: routing, surface: surface)
    }

    /// Current model in plain words ("Claude Opus 5 via anthropic"), for
    /// copy User reads. Nil when routing isn't wired.
    public func telegramPlainModelPhrase(_ surface: String = "telegram") async -> String? {
        guard let routing = await telegramRouting(),
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

    private func telegramRouting() async -> (any ProviderRoutingRef)? {
        if let routing = completenessDeps?.routing { return routing }
        return await TelegramBotCompletenessRegistry.shared
            .deps(for: ObjectIdentifier(self))?.routing
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
