import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import StandingBots
import Transcripts
// Blueprint: | `BotChatContract.swift` | Follow Chat unless pinned; reject conflicting settings. |

/// Every door into a helper uses its current brief and the same checked choice.
public struct BotChatContract: Sendable, Equatable {
    public let name: String
    public let instructions: String
    public var model: String? { choice?.model }
    public var reasoningEffort: String? { choice?.reasoningEffort }
    /// Nil only when the choice is unavailable and the turn must be refused.
    public var choice: ProviderTurnChoice?
    public var modelChoiceProblem: String? = nil
    public var outputBudgetTokens: Int? = nil

    public struct FollowingSettingsRefusal: Error, LocalizedError, Sendable {
        public let problems: [(field: String, message: String)]
        public var errorDescription: String? { problems.map(\.message).joined(separator: "\n") }
    }

    /// Compare submitted fields only; an unset pin flag follows Chat just as explicit false does.
    public static func followingSettings(
        for bot: BotDefinition, fields: [String: JSONValue], dataRoot: URL
    ) async throws -> [String] {
        guard bot.modelPinned != true else { return [] }
        let settings = [("provider", "provider"), ("model", "model"),
                        ("reasoning_effort", "Think"), ("fast", "Fast")]
            .filter { fields[$0.0] != nil && fields[$0.0] != .null }
        guard !settings.isEmpty else { return [] }
        let inherited = try await choice(for: bot, dataRoot: dataRoot)
        let values: [String: JSONValue] = [
            "provider": .string(inherited.provider), "model": .string(inherited.model),
            "reasoning_effort": .string(inherited.reasoningEffort), "fast": .bool(inherited.fast)
        ]
        var problems: [(field: String, message: String)] = []
        var notes: [String] = []
        for (field, label) in settings {
            if fields[field] == values[field] {
                notes.append("""
                    \(field) already matches Chat's \(label); \(bot.name) follows Providers, so it was accepted as a no-op without saving a \
                    per-helper value.
                    """)
            } else {
                problems.append((field, """
                    \(field) applies only to a pinned model; \(bot.name) follows Providers and uses Chat's \(label). Pin a model \
                    (model_pinned:true, model, provider) to set it.
                    """))
            }
        }
        guard problems.isEmpty else { throw FollowingSettingsRefusal(problems: problems) }
        return notes
    }

    public static func instructions(for bot: BotDefinition) throws -> String {
        return try completionPolicy("helper-rounds", arguments: [
            bot.name, bot.personality.map { "\n\n" + $0 } ?? "", bot.name, bot.brief
        ])
    }

    public static func checked(
        _ sessionId: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> BotChatContract? {
        let owned: BotDefinition?
        do {
            owned = try BotDefinitionStore(dataRoot: dataRoot).definition(forSession: sessionId)
            let helper = try SessionConversation.checkedIsHelper(sessionId, dataRoot: dataRoot)
            guard owned != nil || helper else { return nil }
        } catch {
            return BotChatContract(name: "Helper unavailable", instructions: "", choice: nil,
                modelChoiceProblem: """
                    This conversation's helper ownership could not be read: \(error.localizedDescription). Repair its saved helper definition or \
                    session index before continuing.
                    """)
        }
        guard let bot = owned, bot.deleted != true else {
            return BotChatContract(name: "Bot", instructions: "", choice: nil,
                                   modelChoiceProblem: "This helper's definition is unavailable or deleted. Choose an existing helper before continuing.")
        }
        var instructions = ""
        do {
            instructions = try Self.instructions(for: bot)
            let choice = try await choice(for: bot, dataRoot: dataRoot)
            return BotChatContract(name: bot.name, instructions: instructions, choice: choice,
                outputBudgetTokens: bot.budget.tokens)
        } catch {
            return BotChatContract(name: bot.name, instructions: instructions, choice: nil, modelChoiceProblem: String(describing: error))
        }
    }

    public static func choice(
        for bot: BotDefinition,
        dataRoot: URL
    ) async throws -> ProviderTurnChoice {
        if let problem = bot.modelChoiceProblem { throw BotRunnerError.cannotRun(problem) }
        let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
        let choice: ProviderTurnChoice
        if bot.modelPinned == true {
            choice = ProviderTurnChoice(
                provider: bot.provider ?? "", model: bot.model ?? "",
                reasoningEffort: bot.reasoningEffort ?? "", fast: bot.fast ?? false
            )
        } else {
            let snapshot = try await router.checkedRoutingSnapshot()
            if let notice = snapshot.unusablePickNotice(for: "chat") { throw BotRunnerError.cannotRun(notice) }
            guard let preference = snapshot.preferences["chat"],
                  let provider = snapshot.activeProviders["chat"], !preference.model.isEmpty else {
                throw BotRunnerError.cannotRun("Open Providers and choose an account and model for Chat.")
            }
            choice = ProviderTurnChoice(provider: provider, model: preference.model,
                reasoningEffort: preference.reasoningEffort, fast: preference.serviceTier == "priority")
        }
        if let problem = await router.botChoiceRejection(provider: choice.provider, model: choice.model,
                                                        reasoningEffort: choice.reasoningEffort) {
            throw BotRunnerError.cannotRun(problem)
        }
        return choice
    }
}
