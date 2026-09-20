import Foundation
import Testing
import PersistenceCore
import StandingBots
@testable import ChatOrchestration

@Test func toolContractBotCreateNullOptionals() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let providers = root.appendingPathComponent("providers")
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    try Data(#"{"api_key":"sk-oai-test"}"#.utf8).write(to: providers.appendingPathComponent("openai.json"))
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    let input: [String: JSONValue] = ["name": .string("Research"), "brief": .string("Read issues"),
        "provider": .string("openai"), "model": .string("gpt-5.6-sol"), "reasoning_effort": .string("high"),
        "cadence": .null, "budget": .null, "fast": .null, "daily_token_ceiling": .null, "output_format": .null]
    #expect(await dispatcher.standingBotsArgumentProblem(tool: "bot_create", input: input) == nil)
    _ = try await dispatcher.impl_standingBots(tool: "bot_create", input: input)
    let bot = try #require(BotDefinitionStore(dataRoot: root).list().first)
    #expect(bot.name == "Research" && bot.cadence == .manual && bot.fast == nil)
    var invalid = input; invalid["fast"] = .string("yes")
    let problem = await dispatcher.standingBotsArgumentProblem(tool: "bot_create", input: invalid)
    #expect(problem?.contains("fast: false") == true)
}
