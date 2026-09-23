import Foundation
import Testing
import PersistenceCore
import StandingBots
@testable import ChatOrchestration

@Test func botPlainSchedulesResolveWithoutGuessing() throws {
    #expect(try StandingBotSchedule.parse("manual") == .manual)
    #expect(try StandingBotSchedule.parse("every 30 minutes") == .interval(seconds: 1800))
    #expect(try StandingBotSchedule.parse("every 2 hours") == .interval(seconds: 7200))
    #expect(try StandingBotSchedule.parse("daily at 09:00", localTimezone: "America/Denver")
        == .cron(expression: "0 9 * * *", timeZone: "America/Denver"))
    #expect(try StandingBotSchedule.parse("weekdays at 17:45", timezone: "America/New_York")
        == .cron(expression: "45 17 * * 1-5", timeZone: "America/New_York"))
    #expect(StandingBotSchedule.describe(.interval(seconds: 3600)) == "every 1 hour")
    #expect(StandingBotSchedule.describe(.interval(seconds: 7200)) == "every 2 hours")
    for input in ["", "tomorrow morning", "daily at 9:00", "daily at 24:00", "daily at 09:60",
                  "every 1.5 hours", "every 0 minutes", "every 999999999999999999999 hours"] {
        #expect(throws: StandingBotsError.self) { try StandingBotSchedule.parse(input) }
    }
    #expect(throws: StandingBotsError.self) { try StandingBotSchedule.parse("manual", timezone: "UTC") }
    #expect(throws: StandingBotsError.self) { try StandingBotSchedule.parse("daily at 09:00", timezone: "Moon/Base") }
}

@Test func botSchedulePreflightAndNullUpdatesKeepExplicitModel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let providers = root.appendingPathComponent("providers")
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    try Data(#"{"api_key":"sk-oai-test"}"#.utf8).write(to: providers.appendingPathComponent("openai.json"))
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    var input: [String: JSONValue] = ["name": .string("Research"), "brief": .string("Read issues"),
        "provider": .string("openai"), "model": .string("gpt-5.6-sol"), "reasoning_effort": .string("high"),
        "schedule": .string("daily at 09:00"), "timezone": .string("America/Denver"), "cadence": .null,
        "budget": .null, "details": .null, "fast": .null]
    #expect(await dispatcher.standingBotsArgumentProblem(tool: "bot_create", input: input) == nil)
    let result = try await dispatcher.impl_standingBots(tool: "bot_create", input: input)
    let store = BotDefinitionStore(dataRoot: root)
    let bot = try #require(store.list().first)
    #expect(bot.cadence == .cron(expression: "0 9 * * *", timeZone: "America/Denver"))
    if case .object(let fields) = result {
        #expect(fields["operation"] == .string("created"))
        #expect(fields["schedule"] == .string("daily at 09:00"))
        #expect(fields["timezone"] == .string("America/Denver"))
    } else { Issue.record("Expected saved helper result") }
    let update: [String: JSONValue] = ["name": .string(bot.name), "id": .null, "bot_id": .null,
        "bot": .null, "details": .null, "fields": .object(["brief": .string("Read current issues"),
        "schedule": .null, "timezone": .null, "cadence": .null, "provider": .null, "model": .null,
        "reasoning_effort": .null, "fast": .null, "budget": .null, "output_format": .null])]
    #expect(await dispatcher.standingBotsArgumentProblem(tool: "bot_update", input: update) == nil)
    _ = try await dispatcher.impl_standingBots(tool: "bot_update", input: update)
    let updated = try store.get(bot.id)
    #expect(updated.brief == "Read current issues" && updated.sessionID == bot.sessionID)
    #expect(updated.provider == bot.provider && updated.model == bot.model && updated.reasoningEffort == bot.reasoningEffort)
    #expect(updated.cadence == bot.cadence)
    input["cadence"] = .object(["manual": .object([:])])
    #expect(await dispatcher.standingBotsArgumentProblem(tool: "bot_create", input: input)?.contains("not both") == true)
    input["cadence"] = .null
    input["model"] = .null
    #expect(await dispatcher.standingBotsArgumentProblem(tool: "bot_create", input: input) != nil)
    #expect(try store.list().count == 1)
}

@Test func botLatestReplyReadsAlreadyReadEntryAndOnlyAcknowledgesSelected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let definitions = BotDefinitionStore(dataRoot: root)
    let bot = try definitions.create(BotDefinition(name: "Research", brief: "Read issues", cadence: .manual,
        budget: BotBudget(tokens: 500, seconds: 30)))
    let shelf = ShelfStore(dataRoot: root)
    let older = ShelfEntry(botId: bot.id, briefVersion: 1, runAt: Date(), coverageStart: Date(),
        coverageEnd: Date(), headline: "Older", findings: "Older answer", changedSinceLastGood: "",
        sourceLinks: [], uncertainties: [], runHealth: .ok, spend: ShelfSpend(tokens: 20, seconds: 1))
    let latest = ShelfEntry(botId: bot.id, briefVersion: 1, runAt: Date(), coverageStart: Date(),
        coverageEnd: Date(), headline: "Latest", findings: "Full latest answer", changedSinceLastGood: "",
        sourceLinks: [], uncertainties: [], runHealth: .ok, spend: ShelfSpend(tokens: 20, seconds: 1))
    try shelf.append(older)
    try shelf.append(latest)
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    for _ in 0..<2 {
        let reply = try await dispatcher.impl_standingBots(tool: "shelf_entry", input: ["name": .string(bot.name), "id": .null, "bot_id": .null])
        guard case .object(let fields) = reply else { Issue.record("Expected latest reply"); continue }
        #expect(fields["id"] == .string(latest.id.uuidString))
        #expect(fields["answer"] == .string(latest.actualReply))
        #expect(fields["run_status"] == .string(latest.runtimeStatus.rawValue))
    }
    #expect(try shelf.shelfRead(bot: bot.id, readerId: SwiftToolDispatcher.standingBotReaderID).rows.map(\.id) == [older.id])
    let paused = try await dispatcher.impl_standingBots(tool: "bot_pause", input: ["bot": .string(bot.name), "paused": .bool(true)])
    if case .object(let fields) = paused {
        #expect(fields["scheduler_status"] == .string("paused"))
        #expect(fields["session_id"] == .string(bot.sessionID))
        if case .string(let detail)? = fields["detail"] { #expect(detail.contains("not cancelled")) }
    } else { Issue.record("Expected pause result") }
    #expect(try shelf.entry(latest.id).actualReply == latest.actualReply)
}
