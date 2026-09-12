import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import StandingBots

// "Continue in Chat" (BotsShelfView.swift:113) opens a bot's OWN transcript in
// ordinary Chat. Before this type, the next Mac send carried the transcript and
// nothing else: the Chat model picker, the Chat reasoning effort and a hardcoded
// `surface: "chat"` replaced the bot's saved provider choice and its
// bot-specific approval rule (lane1 finding 4 — the prose-editor bot saves
// codex/gpt-5.5/medium and none of it was consulted).
//
// What a continued turn carries now: the bot's model and reasoning effort, and
// surface "bot", which is what the extra visible-desktop/sound approval
// requirement keys on (ChatOrchestrationClient+DispatchWrappers.swift:968). The
// brief needs no carrying — every run persists it as the session's user row, so
// it is already in the transcript the continuation reads. Per-run claim and
// daily allowance stay with BotRunner: a person typing in the bot's session is
// an attended turn, not scheduled spend.
struct BotChatContract: Sendable, Equatable {
    let name: String
    let model: String?
    let reasoningEffort: String?
    /// The bot's saved provider tuple, exactly as StandingBotContinuity builds
    /// it (SwiftToolDispatcher+StandingBotsContinuity.swift:12). nil when the bot
    /// deliberately rides the agent's own route. Without this the routing layer
    /// prefers the surface's configured model and the requested one is ignored
    /// (ChatOrchestration+TurnEngine.swift:223).
    let choice: ProviderTurnChoice?
    /// Keeps the bot-specific approval rule on a continued turn.
    var surface: String { "bot" }

    /// The contract for a chat session that belongs to a bot, or nil for an
    /// ordinary session. Cheap: `sessionID` is "bot-<uuid>", so one read.
    static func forSession(
        _ sessionId: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> BotChatContract? {
        let prefix = "bot-"
        guard sessionId.hasPrefix(prefix),
              let id = UUID(uuidString: String(sessionId.dropFirst(prefix.count))),
              let bot = try? BotDefinitionStore(dataRoot: dataRoot).get(id),
              bot.deleted != true else { return nil }
        var choice: ProviderTurnChoice?
        if let provider = bot.provider, let model = bot.model, let effort = bot.reasoningEffort {
            choice = ProviderTurnChoice(provider: provider, model: model,
                                       reasoningEffort: effort, fast: bot.fast ?? false)
        }
        return BotChatContract(name: bot.name, model: bot.model,
                               reasoningEffort: bot.reasoningEffort, choice: choice)
    }
}
