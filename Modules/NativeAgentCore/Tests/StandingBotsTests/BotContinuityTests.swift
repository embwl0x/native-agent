import Foundation
import Testing
import StandingBots
import ChatOrchestration
import NativeAgentCore

@Test func followUpLandsInTheSameSession() async throws {
    let f = BotRuntimeFixture(); defer { f.clean() }
    let bot = try f.bot()
    let client = f.client(BotTestAdapter(scripts: [[.textDelta("Initial reply")], [.textDelta("Follow-up reply")]]))
    let runner = BotRunner(dataRoot: f.root, session: StandingBotContinuity.session(client: client, dataRoot: f.root))
    _ = try await runner.run(bot: bot.id)
    #expect(try await runner.ask(bot: bot.id, question: "Continue the earlier work") == "Follow-up reply")
    let transcript = try f.transcript(bot)
    #expect(transcript.contains("Initial reply") && transcript.contains("Continue the earlier work") && transcript.contains("Follow-up reply"))
    #expect(try ShelfStore(dataRoot: f.root).shelfRead(bot: bot.id).rows.count == 2)
}

@Test func migrationKeepsOldEntriesAndDefinitions() async throws {
    let f = BotRuntimeFixture(); defer { f.clean() }
    let bot = try f.bot()
    let path = f.root.appendingPathComponent("bots/definitions/" + bot.id.uuidString + ".json")
    var doc = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    var definition = try #require(doc["definition"] as? [String: Any])
    definition["sources"] = ["https://example.org/original", ["type": "tool", "name": "x_search"]] as [Any]
    doc["definition"] = definition
    var audit = try #require(doc["audit"] as? [[String: Any]])
    audit[0]["definition"] = definition; doc["audit"] = audit
    try JSONSerialization.data(withJSONObject: doc).write(to: path)
    let oldBytes = try Data(contentsOf: path)
    let migrated = try f.definitions.get(bot.id)
    #expect(migrated.brief == bot.brief + "\n\nSources: https://example.org/original, tool:x_search")
    #expect(migrated.sessionID == bot.sessionID)
    #expect(try Data(contentsOf: path) == oldBytes)
    let entry = ShelfEntry(botId: bot.id, briefVersion: 1, runAt: Date(), coverageStart: Date(timeIntervalSince1970: 0), coverageEnd: Date(),
        headline: "Old heading", findings: "The old saved work", changedSinceLastGood: "Old change", runHealth: .ok, spend: ShelfSpend(tokens: 5, seconds: 1))
    let shelf = ShelfStore(dataRoot: f.root)
    try shelf.append(entry)
    let client = f.client(BotTestAdapter(scripts: [[.textDelta("New reply")], [.textDelta("Another reply")]]))
    let runner = BotRunner(dataRoot: f.root, session: StandingBotContinuity.session(client: client, dataRoot: f.root))
    _ = try await runner.run(bot: bot.id)
    _ = try await runner.ask(bot: bot.id, question: "Continue")
    #expect(try shelf.entry(entry.id) == entry)
    let transcript = try f.transcript(bot)
    #expect(transcript.components(separatedBy: "The old saved work").count == 2)
    #expect(try f.definitions.get(bot.id).brief == migrated.brief)
}
