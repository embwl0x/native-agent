import Foundation
import Testing
@testable import ChatOrchestration
import StandingBots
import PersistenceCore

@Test func botToolsKeepExplicitChoicesAndSameSessionOnUpdate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bot-tools-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    let input: [String: JSONValue] = ["name": .string("Chosen name"), "brief": .string("Chosen task"),
        "output_format": .string(""), "provider": .string("openai"), "model": .string("gpt-5.5"),
        "reasoning_effort": .string("high"), "fast": .bool(false), "cadence": .object(["manual": .object([:])]),
        "budget": .object(["tokens": .int(2000), "seconds": .int(30)]), "daily_token_ceiling": .int(8000)]
    _ = try await dispatcher.impl_standingBots(tool: "bot_create", input: input)
    let store = BotDefinitionStore(dataRoot: root)
    let created = try #require(store.list().first)
    #expect(created.provider == "openai" && created.model == "gpt-5.5" && created.fast == false)
    _ = try await dispatcher.impl_standingBots(tool: "bot_update", input: ["id": .string(created.id.uuidString),
        "fields": .object(["brief": .string("Changed task"), "daily_token_ceiling": .int(16000)])])
    let edited = try store.get(created.id)
    #expect(edited.sessionID == created.sessionID && edited.brief == "Changed task" && edited.dailyTokenCeiling == 16000)
    _ = try await dispatcher.impl_standingBots(tool: "bot_delete", input: ["id": .string(created.id.uuidString)])
    #expect(try store.list().isEmpty)
    #expect(try store.get(created.id).sessionID == created.sessionID)
}
