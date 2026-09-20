import Foundation
import Testing
import PersistenceCore
import StandingBots
@testable import ChatOrchestration

@Test func toolContractBotAskNullAndMatchingAliases() async throws {
    let schema = try #require(BuiltInToolSchemaFactory(requestedNames: ["bot_ask"])
        .standingBotSchemas().compactMap { $0 }.first)
    let parameters = try #require(JSONSerialization.jsonObject(with: schema.parametersJSON) as? [String: Any])
    #expect(parameters["required"] as? [String] == ["question"])
    let properties = try #require(parameters["properties"] as? [String: [String: Any]])
    #expect(Set(properties.keys) == Set(["id", "bot_id", "bot", "name", "question"]))
    for key in ["id", "bot_id", "bot", "name"] {
        #expect(properties[key]?["type"] as? [String] == ["string", "null"])
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var definition = BotDefinition(name: "Research", brief: "Read issues", cadence: .manual,
                                   budget: BotBudget(tokens: 500, seconds: 30))
    definition.provider = "openai"; definition.model = "gpt-5.6-sol"; definition.reasoningEffort = "high"
    let bot = try BotDefinitionStore(dataRoot: root).create(definition)
    let dispatcher = SwiftToolDispatcher(dataRoot: root, standingBotSession: { selected, question in
        #expect(selected.id == bot.id)
        #expect(question == "What changed?")
        return BotTurnReply(reply: "No new issues")
    })
    for aliases: [String: JSONValue] in [
        ["name": .string("Research")],
        ["id": .string(bot.id.uuidString)],
        ["bot_id": .string(bot.id.uuidString)],
        ["bot": .string("Research")],
        ["id": .null, "bot_id": .string(""), "bot": .string(" \n"), "name": .string("Research")],
        ["id": .string(bot.id.uuidString), "bot_id": .null, "bot": .null, "name": .null],
        ["id": .string(bot.id.uuidString), "bot_id": .string(bot.id.uuidString), "name": .string("Research")]
    ] {
        let result = try await dispatcher.impl_standingBots(tool: "bot_ask",
            input: aliases.merging(["question": .string("What changed?")]) { _, new in new })
        guard case .object(let fields) = result else { Issue.record("Missing reply"); return }
        #expect(fields["answer"] == .string("No new issues"))
    }
    let conflict = try await dispatcher.impl_standingBots(tool: "bot_ask", input: [
        "id": .string(bot.id.uuidString), "bot_id": .string(UUID().uuidString), "question": .string("What changed?")])
    #expect(String(describing: conflict).contains("Conflicting bot fields"))
}
