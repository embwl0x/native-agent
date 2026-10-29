import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import StandingBots
import Transcripts
// Blueprint: | `BotChatContract.swift` | Helper identity, personality, job/output instructions and checked provider choice; helpers follow Chat unless explicitly pinned |

/// Every door into a helper uses its current brief and the same checked choice.
public struct BotChatContract: Sendable, Equatable {
    public let name: String
    public let instructions: String
    public var model: String? { choice?.model }
    public var reasoningEffort: String? { choice?.reasoningEffort }
    /// Nil only when the choice is unavailable and the turn must be refused.
    public var choice: ProviderTurnChoice?
    /// What the bot still needs before it can run, or nil when it can.
    public var modelChoiceProblem: String? = nil

    public static func instructions(for bot: BotDefinition) throws -> String {
        let output = try bot.outputFormat.map {
            try completionPolicy("helper-rounds", section: "output", arguments: [$0])
        } ?? ""
        return try completionPolicy("helper-rounds", arguments: [
            bot.name, bot.personality.map { "\n\n" + $0 } ?? "", bot.name, bot.brief, output
        ])
    }

    public static func checked(
        _ sessionId: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> BotChatContract? {
        let owned = try? BotDefinitionStore(dataRoot: dataRoot).definition(forSession: sessionId)
        guard owned != nil || SessionConversation.isHelper(sessionId, dataRoot: dataRoot) else { return nil }
        guard let bot = owned, bot.deleted != true else {
            return BotChatContract(name: "Bot", instructions: "", choice: nil,
                                   modelChoiceProblem: "This helper's definition is unavailable or deleted. Choose an existing helper before continuing.")
        }
        var instructions = ""
        do {
            instructions = try Self.instructions(for: bot)
            let choice = try await choice(for: bot, dataRoot: dataRoot)
            return BotChatContract(name: bot.name, instructions: instructions, choice: choice)
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
            // Unpinned helpers inherit Chat's checked selection.
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
