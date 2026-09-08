import Foundation
import Testing
import StandingBots

private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("standing-bots-\(UUID().uuidString)")
    var definitions: BotDefinitionStore { BotDefinitionStore(dataRoot: root) }
    var shelf: ShelfStore { ShelfStore(dataRoot: root) }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func bot(_ name: String = "Research") throws -> BotDefinition {
        try definitions.create(BotDefinition(name: name, brief: "Check the configured sources", cadence: .interval(seconds: 3600),
                                             budget: BotBudget(tokens: 500, seconds: 30)))
    }
    func book(_ bot: BotDefinition, time: TimeInterval = 1000, headline: String = "Checked",
              health: ShelfRunHealth = .ok) -> ShelfEntry {
        ShelfEntry(botId: bot.id, briefVersion: bot.briefVersion, runAt: Date(timeIntervalSince1970: time),
                   coverageStart: Date(timeIntervalSince1970: time - 100), coverageEnd: Date(timeIntervalSince1970: time),
                   headline: headline, findings: "Evidence in **markdown**", changedSinceLastGood: "No material change",
                   sourceLinks: [ShelfSourceLink(url: "https://example.org/source", datedAt: Date(timeIntervalSince1970: time))],
                   uncertainties: ["Coverage is limited to configured sources"], runHealth: health,
                   spend: ShelfSpend(tokens: 20, seconds: 1))
    }
}

@Test func definitionCreateUpdatePauseAndAtomicAudit() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    #expect(try fixture.definitions.list().isEmpty)
    let original = try fixture.bot()
    var edit = original
    edit.name = "Custom name"
    edit.brief = "A revised brief"
    edit.sources = ["https://example.org"]
    edit.cadence = .cron(expression: "0 8 * * *", timeZone: "America/New_York")
    let changed = try fixture.definitions.update(edit)
    #expect(changed.briefVersion == 2)
    #expect(throws: StandingBotsError.staleDefinition(original.id)) { try fixture.definitions.update(edit) }
    let paused = try fixture.definitions.pause(original.id)
    #expect(paused.paused && paused.briefVersion == 2)
    let resumed = try fixture.definitions.pause(original.id, paused: false)
    #expect(!resumed.paused)
    #expect(try BotDefinitionStore(dataRoot: fixture.root).get(original.id) == resumed)
    let audit = try fixture.definitions.audit(original.id)
    #expect(audit.map(\.operation) == [.create, .update, .pause, .resume])
    #expect(audit.first?.definition == original)
    #expect(audit.last?.definition == resumed)
    #expect(throws: StandingBotsError.alreadyExists(original.id)) { try fixture.definitions.create(original) }
}

@Test func appendPaginateAndDrillDownKeepBackdatedCrossBotHistory() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    let a = try fixture.bot("A")
    let b = try fixture.bot("B")
    #expect(try fixture.shelf.shelfRead().rows.isEmpty)
    let first = fixture.book(a, time: 200_000, health: .nothingNew)
    let second = fixture.book(b, time: 100, health: .failed)
    let third = fixture.book(a, time: 50, headline: String(repeating: "x", count: 300), health: .partial)
    try fixture.shelf.append(first)
    try fixture.shelf.append(second)
    try fixture.shelf.append(third)
    let p1 = try fixture.shelf.shelfRead(limit: 1)
    #expect(p1.rows.map(\.id) == [first.id])
    #expect(p1.truncated)
    let p2 = try fixture.shelf.shelfRead(limit: 1, cursor: p1.nextCursor)
    #expect(p2.rows.map(\.id) == [second.id])
    let p3 = try fixture.shelf.shelfRead(limit: 1, cursor: p2.nextCursor)
    #expect(p3.rows.map(\.id) == [third.id])
    #expect(p3.rows.first?.headline.count == 240)
    #expect(p3.truncated)
    #expect(try fixture.shelf.entry(third.id) == third)
    #expect(try fixture.shelf.lastGood(bot: a.id) == first)
    #expect(try fixture.shelf.lastGood(bot: b.id) == nil)
    let late = fixture.book(b, time: 1)
    try fixture.shelf.append(late)
    #expect(try ShelfStore(dataRoot: fixture.root).shelfRead(cursor: p3.nextCursor).rows.map(\.id) == [late.id])
    #expect(try fixture.shelf.shelfRead(since: Date(timeIntervalSince1970: 100)).rows.map(\.id) == [first.id])
    #expect(throws: StandingBotsError.alreadyExists(first.id)) { try fixture.shelf.append(first) }
}

@Test func readerAcknowledgementsPreserveUnseenHolesAndUIIndependence() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    let bot = try fixture.bot()
    let earlier = fixture.book(bot, headline: "Earlier")
    let later = fixture.book(bot, headline: "Later topic")
    try fixture.shelf.append(earlier)
    try fixture.shelf.append(later)
    let filtered = try fixture.shelf.shelfRead(topic: "TOPIC", limit: 1, readerId: "agent")
    #expect(filtered.rows.map(\.id) == [later.id])
    #expect(try fixture.shelf.readCursor(readerId: "agent").readEntryIds.isEmpty)
    #expect(throws: StandingBotsError.invalidCursor) {
        try fixture.shelf.shelfRead(cursor: filtered.nextCursor, readerId: "agent")
    }
    try fixture.shelf.acknowledge(readerId: "agent", entryIds: [later.id])
    try fixture.shelf.acknowledge(readerId: "agent", entryIds: [later.id])
    #expect(try ShelfStore(dataRoot: fixture.root).shelfRead(readerId: "agent").rows.map(\.id) == [earlier.id])
    #expect(try fixture.shelf.shelfRead(readerId: "ui:user").rows.map(\.id) == [earlier.id, later.id])
    let unknown = UUID()
    #expect(throws: StandingBotsError.notFound(unknown)) {
        try fixture.shelf.acknowledge(readerId: "agent", entryIds: [earlier.id, unknown])
    }
    #expect(try fixture.shelf.readCursor(readerId: "agent").readEntryIds == [later.id])
    #expect(throws: StandingBotsError.self) { try fixture.shelf.shelfRead(limit: 0) }
    #expect(throws: StandingBotsError.self) { try fixture.shelf.shelfRead(limit: 101) }
}

@Test func corruptStorageIsPreservedAndMutationsFail() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    let bot = try fixture.bot()
    let path = fixture.root.appendingPathComponent("bots/definitions/\(bot.id.uuidString).json")
    let corrupt = Data("{broken".utf8)
    try corrupt.write(to: path)
    #expect(throws: (any Error).self) { try fixture.definitions.pause(bot.id) }
    #expect(try Data(contentsOf: path) == corrupt)
    let other = try fixture.bot("Other")
    try fixture.shelf.append(fixture.book(other))
    let shelfDirectory = fixture.root.appendingPathComponent("bots/shelf-entries")
    let bookFile = try #require(FileManager.default.contentsOfDirectory(at: shelfDirectory, includingPropertiesForKeys: nil).first)
    var damaged = try Data(contentsOf: bookFile)
    damaged.append(Data("{partial".utf8))
    try damaged.write(to: bookFile)
    #expect(throws: (any Error).self) { try fixture.shelf.append(fixture.book(other)) }
    #expect(try Data(contentsOf: bookFile) == damaged)
    let cursors = fixture.root.appendingPathComponent("bots/cursors.json")
    try corrupt.write(to: cursors)
    #expect(throws: (any Error).self) { try fixture.shelf.shelfRead(readerId: "agent") }
    #expect(try Data(contentsOf: cursors) == corrupt)
}

@Test func independentStoreWritersDoNotLoseBooks() async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    let bot = try fixture.bot()
    let entries = (0..<12).map { fixture.book(bot, time: Double($0 + 1)) }
    let root = fixture.root
    try await withThrowingTaskGroup(of: Void.self) { group in
        for entry in entries {
            group.addTask { try ShelfStore(dataRoot: root).append(entry) }
        }
        try await group.waitForAll()
    }
    #expect(Set(try fixture.shelf.shelfRead().rows.map(\.id)) == Set(entries.map(\.id)))
}
