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
    /// it (SwiftToolDispatcher+StandingBotsContinuity.swift:12). Without this the
    /// routing layer prefers the surface's configured model and the requested
    /// one is ignored (ChatOrchestration+TurnEngine.swift:223).
    ///
    /// nil ONLY when the bot has no usable tuple — and then `modelChoiceProblem`
    /// says why and the turn is refused. A bot never rides Chat's route
    /// (2026-09-13 review): that was the silent fallback this closes.
    var choice: ProviderTurnChoice?
    /// What the bot still needs before it can run, or nil when it can.
    var modelChoiceProblem: String? = nil
    /// Keeps the bot-specific approval rule on a continued turn.
    var surface: String { "bot" }

    /// The contract with the FULL gate applied — the same one the runner uses:
    /// the route is connected and still offers this model at this Think level,
    /// not merely that three fields are nonempty (2026-09-13, third review). A
    /// bot whose account was disconnected, or whose model left the catalog,
    /// refuses its turn here exactly as a scheduled run would.
    static func checked(
        _ sessionId: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> BotChatContract? {
        // ONE read of the definition, and both the contract and its gate come
        // from that one read (2026-09-13, fourth review). Reading twice meant a
        // definition edited in between produced a contract for one version gated
        // against another — and a second read that simply failed handed back the
        // first, ungated.
        guard let bot = definition(for: sessionId, dataRoot: dataRoot) else { return nil }
        return await contract(for: bot, dataRoot: dataRoot)
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

    private static func contract(
        for bot: BotDefinition,
        dataRoot: URL
    ) async -> BotChatContract {
        let problem = await BotRunGate.problem(for: bot, dataRoot: dataRoot)
        let choice: ProviderTurnChoice? = problem == nil
            ? ProviderTurnChoice(
                provider: bot.provider ?? "", model: bot.model ?? "",
                reasoningEffort: bot.reasoningEffort ?? "", fast: bot.fast ?? false
            )
            : nil
        return BotChatContract(name: bot.name, model: bot.model,
                               reasoningEffort: bot.reasoningEffort, choice: choice,
                               modelChoiceProblem: problem)
    }

    // There is deliberately no ungated accessor. A shape-only `forSession`
    // existed until 2026-09-13 and had no callers left once every turn path
    // moved to `checked` — an entry point that skips the gate is the trap this
    // review found twice, so it is gone rather than left for the next caller.
}
