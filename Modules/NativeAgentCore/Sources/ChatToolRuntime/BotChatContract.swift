import Foundation
import PersistenceCore
import ProviderRouting
import StandingBots

/// Every door into a helper uses its current brief and the same checked choice.
public struct BotChatContract: Sendable, Equatable {
    public let name: String
    public let instructions: String
    public let model: String?
    public let reasoningEffort: String?
    /// Nil only when the choice is unavailable and the turn must be refused.
    public var choice: ProviderTurnChoice?
    /// What the bot still needs before it can run, or nil when it can.
    public var modelChoiceProblem: String? = nil

    public static func instructions(for bot: BotDefinition) -> String {
        "Current standing instructions for \(bot.name):\n\(bot.brief)"
            + (bot.outputFormat.map { "\nRequested output: " + $0 } ?? "")
    }

    public static func checked(
        _ sessionId: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> BotChatContract? {
        guard sessionId.hasPrefix("bot-"),
              UUID(uuidString: String(sessionId.dropFirst(4))) != nil else { return nil }
        guard let bot = definition(for: sessionId, dataRoot: dataRoot) else {
            return BotChatContract(name: "Bot", instructions: "", model: nil, reasoningEffort: nil, choice: nil,
                                   modelChoiceProblem: "This helper's definition is unavailable or deleted. Choose an existing helper before continuing.")
        }
        do {
            let choice = try await choice(for: bot, dataRoot: dataRoot)
            return BotChatContract(name: bot.name, instructions: instructions(for: bot), model: choice.model,
                                   reasoningEffort: choice.reasoningEffort, choice: choice)
        } catch {
            return BotChatContract(name: bot.name, instructions: instructions(for: bot), model: nil,
                                   reasoningEffort: nil, choice: nil, modelChoiceProblem: String(describing: error))
        }
    }

    /// The bot behind a session id, or nil for an ordinary session. Cheap:
    /// `sessionID` is "bot-<uuid>", so one read.
    private static func definition(
        for sessionId: String,
        dataRoot: URL
    ) -> BotDefinition? {
        let prefix = "bot-"
        guard sessionId.hasPrefix(prefix),
              let id = UUID(uuidString: String(sessionId.dropFirst(prefix.count))),
              let bot = try? BotDefinitionStore(dataRoot: dataRoot).get(id),
              bot.deleted != true else { return nil }
        return bot
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
            // Helpers have always used Chat's selection when inheriting a route.
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
