import Foundation
import Testing
@testable import StandingBots

@Suite struct BotContinuityTests {
    @Test func botStorageRejectsSymlinkedDirectoriesAndReadTargets() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("bot-containment-\(UUID())")
        defer { try? fm.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("data")
        let outside = fixture.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let bot = try BotDefinitionStore(dataRoot: root).create(BotDefinition(name: "Research", brief: "Keep research.md",
            cadence: .interval(seconds: 900), sources: ["https://example.org"], budget: BotBudget(tokens: 8_000, seconds: 10)))
        let disk = StandingBotsDisk(dataRoot: root)
        let store = BotContinuityStore(dataRoot: root)
        try store.publish(bot: bot.id, runID: UUID(), notes: "local notes", compacted: false,
                          reports: [BotKeptReport(name: "research.md", content: "local report")])
        let botDirectory = disk.root.appendingPathComponent(bot.id.uuidString)
        let documents = botDirectory.appendingPathComponent("documents")
        let movedDocuments = outside.appendingPathComponent("documents")
        try fm.moveItem(at: documents, to: movedDocuments)
        try fm.createSymbolicLink(at: documents, withDestinationURL: movedDocuments)
        #expect(throws: StandingBotsError.self) { try store.read(bot: bot.id, name: "research.md") }
        #expect(throws: StandingBotsError.self) {
            try store.publish(bot: bot.id, runID: UUID(), notes: "changed", compacted: false,
                              reports: [BotKeptReport(name: "research.md", content: "outside write")])
        }
        #expect(try fm.contentsOfDirectory(atPath: movedDocuments.path).count == 1)
        try fm.removeItem(at: documents)
        try fm.moveItem(at: movedDocuments, to: documents)

        let movedBot = outside.appendingPathComponent("bot")
        try fm.moveItem(at: botDirectory, to: movedBot)
        try fm.createSymbolicLink(at: botDirectory, withDestinationURL: movedBot)
        #expect(throws: StandingBotsError.self) { try store.context(bot: bot.id) }
        #expect(throws: StandingBotsError.self) { try BotRunQueue(dataRoot: root).claim(bot: bot.id, requestID: nil) }
        #expect(!fm.fileExists(atPath: movedBot.appendingPathComponent("run.lock").path))
        try fm.removeItem(at: botDirectory)
        try fm.moveItem(at: movedBot, to: botDirectory)

        // Every shared disk entry point rejects existing and dangling links,
        // including links that happen to point back inside the configured root.
        for destination in [outside, root, outside.appendingPathComponent("missing")] {
            let link = disk.root.appendingPathComponent("linked")
            try fm.createSymbolicLink(at: link, withDestinationURL: destination)
            #expect(throws: StandingBotsError.self) { try disk.bytes(at: link) }
            #expect(throws: StandingBotsError.self) { try disk.files(at: link, extension: "json") }
            #expect(throws: StandingBotsError.self) { try disk.write("blocked", at: link.appendingPathComponent("new.json")) }
            try fm.removeItem(at: link)
        }
        let lock = disk.root.appendingPathComponent("store.lock")
        try fm.removeItem(at: lock)
        try fm.createSymbolicLink(at: lock, withDestinationURL: outside.appendingPathComponent("lock"))
        #expect(throws: StandingBotsError.self) { try disk.locked {} }
        #expect(!fm.fileExists(atPath: outside.appendingPathComponent("lock").path))
    }

    @Test func consecutiveRunsKeepContextVersionReportsAndNeverPush() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bot-continuity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let definitions = BotDefinitionStore(dataRoot: root)
        let bot = try definitions.create(BotDefinition(name: "Research", brief: "Keep a running research report named research.md",
            cadence: .interval(seconds: 900), sources: ["https://example.org"], budget: BotBudget(tokens: 16_000, seconds: 10)))
        let fake = ContinuityProvider()
        let runner = BotRunner(dataRoot: root, session: { try await fake.complete($0, $1, $2) },
            fetch: { _, _ in await fake.fetch() }, admission: { true })
        let first = try #require(await runner.run(bot: bot.id))
        let store = BotContinuityStore(dataRoot: root)
        let v1 = try store.read(bot: bot.id, name: "research.md")
        #expect(v1.content == "Alpha discovered.")
        #expect(v1.document.previousVersion == nil)

        // A fresh runner/store represents a restart, not an in-memory session.
        let restarted = BotRunner(dataRoot: root, session: { try await fake.complete($0, $1, $2) },
            fetch: { _, _ in await fake.fetch() }, admission: { true })
        let second = try #require(await restarted.run(bot: bot.id))
        #expect(second.findings == "Beta discovered.")
        #expect(!second.findings.contains("Alpha"))
        #expect(await fake.sawPriorMaterial)
        let v2 = try store.read(bot: bot.id, name: "research.md", limit: 5)
        #expect(v2.content == "Alpha")
        #expect(v2.document.previousVersion == v1.document.version)
        #expect(v2.document.version != v1.document.version)
        let tail = try store.read(bot: bot.id, name: "research.md", version: v2.document.version,
                                  offset: #require(v2.nextOffset))
        #expect(v2.content + tail.content == "Alpha discovered. Beta discovered.")
        #expect(try store.read(bot: bot.id, name: "research.md", version: v1.document.version).content == v1.content)
        #expect(try store.list(bot: bot.id, limit: 1).documents.count == 1)
        #expect(try store.context(bot: bot.id).notes.contains("Reported: Beta"))
        #expect(try ShelfStore(dataRoot: root).shelfRead(bot: bot.id).rows.map(\.id) == [first.id, second.id])

        // Ask sees kept material, runs no sources, and writes spend plus claim metadata.
        let before = try files(root)
        let answer = try await restarted.ask(bot: bot.id, question: "What does research.md say?")
        #expect(answer == "research.md: Alpha and Beta discovered.")
        #expect(await fake.fetches == 2)
        let after = try files(root)
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
        #expect(Set(changed) == Set(["bots/daily-spend.json", "bots/\(bot.id.uuidString)/run.lock"]))
        #expect(after.keys.allSatisfy { $0.hasPrefix("bots/") })
        #expect(try ShelfStore(dataRoot: root).readCursor(readerId: "agent").readEntryIds.isEmpty)

        let other = try definitions.create(BotDefinition(name: "Other", brief: "Check separately",
            cadence: .interval(seconds: 900), sources: ["https://example.org"], budget: bot.budget))
        #expect(try store.context(bot: other.id).notes.isEmpty)
        #expect(try store.list(bot: other.id).documents.isEmpty)
        #expect(throws: StandingBotsError.self) { try store.read(bot: bot.id, name: "../research.md") }
    }

    @Test func failedRunsDoNotPublishContinuityAndAskHonorsAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bot-continuity-denied-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = try BotDefinitionStore(dataRoot: root).create(BotDefinition(name: "Research", brief: "Keep research.md",
            cadence: .interval(seconds: 900), sources: ["https://example.org"], budget: BotBudget(tokens: 8_000, seconds: 10)))
        let fake = ContinuityProvider()
        let denied = BotRunner(dataRoot: root, session: { try await fake.complete($0, $1, $2) },
            fetch: { _, _ in await fake.fetch() }, admission: { false })
        await #expect(throws: BotRunnerError.self) { try await denied.ask(bot: bot.id, question: "What changed?") }
        #expect(try await denied.run(bot: bot.id)?.runHealth == .failed)
        #expect(await fake.calls == 0)
        #expect(await fake.fetches == 0)
        #expect(try BotContinuityStore(dataRoot: root).context(bot: bot.id).lastRunID == nil)
        #expect(try BotContinuityStore(dataRoot: root).list(bot: bot.id).documents.isEmpty)
    }

    private func files(_ root: URL) throws -> [String: Data] {
        let root = root.resolvingSymlinksInPath()
        var result: [String: Data] = [:]
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let path as URL in enumerator {
            let path = path.resolvingSymlinksInPath()
            if try path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(path.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: path)
            }
        }
        return result
    }
}

private actor ContinuityProvider {
    var calls = 0
    var fetches = 0
    var sawPriorMaterial = false
    func fetch() -> String { fetches += 1; return fetches == 1 ? "Alpha discovered." : "Alpha discovered. Beta discovered." }
    func complete(_ system: String, _ prompt: String, _ limit: Int) throws -> String {
        calls += 1
        #expect(limit >= 128 && limit < 16_000)
        #expect(system.contains("UNTRUSTED EVIDENCE"))
        if calls == 3 {
            #expect(prompt.contains("Alpha discovered. Beta discovered."))
            #expect(system.contains("No sources"))
            return "research.md: Alpha and Beta discovered."
        }
        if calls == 2 {
            sawPriorMaterial = prompt.contains("Alpha discovered.") && prompt.contains("Reported: Alpha")
                && prompt.contains("research.md") && prompt.contains("Gathered:")
        }
        let fact = calls == 1 ? "Alpha" : "Beta"
        let report = calls == 1 ? "Alpha discovered." : "Alpha discovered. Beta discovered."
        let book = BotRunnerBook(headline: fact, findings: fact + " discovered.", changedSinceLastGood: fact + " is new.",
            sourceURLs: ["https://example.org"], uncertainties: [], runHealth: .ok,
            workingNotes: fact + " discovered.", keptReports: [.init(name: "research.md", content: report)])
        return String(decoding: try JSONEncoder().encode(book), as: UTF8.self)
    }
}
