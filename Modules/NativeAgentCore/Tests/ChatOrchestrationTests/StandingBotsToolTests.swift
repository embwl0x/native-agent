import Foundation
import Testing
@testable import ChatOrchestration
import StandingBots
import PersistenceCore

@Test func botToolsKeepExplicitChoicesAndSameSessionOnUpdate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bot-tools-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    // 2026-09-13 review: a bot is made on a CONNECTED account with a model that
    // account offers, so the fixture connects one. Making a bot on an account
    // nobody signed into is refused now, by name.
    let providers = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["api_key": "sk-oai-test"])
        .write(to: providers.appendingPathComponent("openai.json"))
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    let input: [String: JSONValue] = ["name": .string("Chosen name"), "brief": .string("Chosen task"),
        "output_format": .string(""), "provider": .string("openai"), "model": .string("gpt-5.6-sol"),
        "reasoning_effort": .string("high"), "fast": .bool(false), "cadence": .object(["manual": .object([:])]),
        "budget": .object(["tokens": .int(2000), "seconds": .int(30)]), "daily_token_ceiling": .int(8000)]
    _ = try await dispatcher.impl_standingBots(tool: "bot_create", input: input)
    let store = BotDefinitionStore(dataRoot: root)
    let created = try #require(store.list().first)
    #expect(created.provider == "openai" && created.model == "gpt-5.6-sol" && created.fast == false)
    _ = try await dispatcher.impl_standingBots(tool: "bot_update", input: ["id": .string(created.id.uuidString),
        "fields": .object(["brief": .string("Changed task"), "daily_token_ceiling": .int(16000)])])
    let edited = try store.get(created.id)
    #expect(edited.sessionID == created.sessionID && edited.brief == "Changed task" && edited.dailyTokenCeiling == 16000)
    _ = try await dispatcher.impl_standingBots(tool: "bot_delete", input: ["id": .string(created.id.uuidString)])
    #expect(try store.list().isEmpty)
    #expect(try store.get(created.id).sessionID == created.sessionID)
}
