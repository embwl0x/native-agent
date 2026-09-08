import Foundation
import Testing
import PersistenceCore
import StandingBots
import NativeAgentCore
@testable import ChatOrchestration
@testable import TrustCenter

@Suite("Standing bots tools")
struct StandingBotsToolTests {
    @Test func mailMarkReadCannotQualifyAsReadOnly() async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let envelope = await SwiftNativeSecurityCenter(dataRoot: root).evaluateTool(
            tool: "mail_mark_read", input: [:], origin: SecurityOriginContext(surface: "standing_bots"))
        #expect(envelope.hasSideEffects)
        #expect(ToolPreloadHeuristics.macIntegrationGates["mail_mark_read"]?.mode == .write)
        await #expect(throws: StandingBotsError.self) {
            try await StandingBotToolPolicy.validate(name: "mail_mark_read", input: [:], dataRoot: root)
        }
        try await StandingBotToolPolicy.validate(name: "mail_list_recent", input: [:], dataRoot: root)
    }

    @Test func botAdmissionReloadsKillSwitchAndHardStops() async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("trust")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("policy.json")
        func save(kill: Bool = false, autonomy: Bool = true, blocked: Bool = false) throws {
            let policy: [String: Any] = ["permissionLevel": "full_mac_os",
                "fullMacNeverExpires": true, "fullMacExpiresAt": "never", "enableAutonomy": autonomy,
                "securityPolicy": ["killSwitchEnabled": kill],
                "toolAutonomy": ["bot_run_once": blocked ? "blocked" : "auto", "bot_ask": blocked ? "blocked" : "auto"]]
            try JSONSerialization.data(withJSONObject: policy).write(to: path, options: .atomic)
        }
        for tool in ["bot_run_once", "bot_ask"] {
            try save()
            #expect(await StandingBotToolLoop.admitted(dataRoot: root, tool: tool))
            try save(kill: true)
            #expect(await !StandingBotToolLoop.admitted(dataRoot: root, tool: tool))
            try save(blocked: true)
            #expect(await !StandingBotToolLoop.admitted(dataRoot: root, tool: tool))
            try save(autonomy: false)
            #expect(await !StandingBotToolLoop.admitted(dataRoot: root, tool: tool))
            try Data("{".utf8).write(to: path)
            #expect(await !StandingBotToolLoop.admitted(dataRoot: root, tool: tool))
        }
    }

    @Test func invalidCronIsRefusedAndLegacyBadRowDoesNotStarveFleet() async throws {
        let (root, dispatcher) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid: JSONValue = .object(["cron": .object(["expression": .string("not cron"), "timeZone": .string("UTC")])])
        var input = createInput
        input["cadence"] = invalid
        let refusal = try object(await dispatcher.dispatch(tool: "bot_create", input: input, surface: "chat"))
        #expect(refusal["status"] == .string("failed"))
        #expect(String(describing: refusal["detail"]).contains("5 fields"))
        let store = BotDefinitionStore(dataRoot: root)
        #expect(try store.list().isEmpty)
        let old = Date().addingTimeInterval(-7200)
        let good = try store.create(BotDefinition(name: "Good", brief: "Check news", cadence: .interval(seconds: 900),
            sources: ["https://example.org"], budget: BotBudget(tokens: 8000, seconds: 10), createdAt: old))
        let update = try object(await dispatcher.dispatch(tool: "bot_update", input: ["id": .string(good.id.uuidString),
            "fields": .object(["cadence": invalid])], surface: "chat"))
        #expect(update["status"] == .string("failed"))
        #expect(try store.get(good.id).cadence == good.cadence)
        let bad = try store.create(BotDefinition(name: "Legacy", brief: "Check news",
            cadence: .cron(expression: "* * * * *", timeZone: "UTC"),
            sources: ["https://example.org"], budget: BotBudget(tokens: 8000, seconds: 10), createdAt: old))
        let path = root.appendingPathComponent("bots/definitions/\(bad.id.uuidString).json")
        let bytes = try String(contentsOf: path, encoding: .utf8).replacingOccurrences(of: "* * * * *", with: "not cron")
        try Data(bytes.utf8).write(to: path)
        let scheduler = BotRunnerScheduler(dataRoot: root, session: { _, _, _ in Self.unchangedBook },
            fetch: { _, _ in "No changes" }, admission: { true })
        #expect(await scheduler.nextDeadline(after: Date()) != nil)
        #expect(await scheduler.runDue() == ["bot:\(good.id.uuidString)"])
        let shelf = ShelfStore(dataRoot: root)
        let failed = try #require(shelf.shelfRead(bot: bad.id).rows.first)
        #expect(failed.runHealth == .failed)
        #expect(try shelf.entry(failed.id).uncertainties.contains(where: { $0.contains("5 fields") }))
        _ = await scheduler.nextDeadline(after: Date())
        #expect(try shelf.shelfRead(bot: bad.id).rows.count == 1)
    }
    @Test func keptShelfToolsAndAskUseBotMaterialWithoutResidentWrites() async throws {
        let (root, dispatcher) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Dispatcher construction opens its isolated memory database. Assert
        // bot operations preserve those pre-existing bytes, not an empty root.
        let residentBefore = try residentFiles(root)
        let bot = try BotDefinitionStore(dataRoot: root).create(BotDefinition(name: "Research", brief: "Keep research.md",
            cadence: .interval(seconds: 900), sources: ["https://example.org"], budget: BotBudget(tokens: 32_000, seconds: 20)))
        let runner = BotRunner(dataRoot: root, session: { _, _, _ in
            let book: JSONValue = .object([
                "headline": .string("Research saved"), "findings": .string("New discovery"),
                "changedSinceLastGood": .string("New discovery"), "sourceURLs": .array([.string("https://example.org")]),
                "uncertainties": .array([]), "runHealth": .string("ok"),
                "workingNotes": .string(String(repeating: "Older gathered evidence. ", count: 1_000) + "LATEST DISCOVERY"),
                "keptReports": .array([.object(["name": .string("research.md"), "content": .string("Kept discovery: blue moon.")])]),
            ])
            return String(decoding: try book.serializedData(pretty: false), as: UTF8.self)
        }, fetch: { _, _ in "New discovery" }, admission: { true }, compact: StandingBotContinuity.compact)
        _ = try await runner.run(bot: bot.id)
        let context = try BotContinuityStore(dataRoot: root).context(bot: bot.id)
        #expect(context.compacted)
        #expect(context.notes.utf8.count <= BotContinuityStore.maximumContextBytes)
        #expect(context.notes.contains("LATEST DISCOVERY"))
        let listed = try object(await dispatcher.dispatch(tool: "shelf_documents", input: ["bot": .string(bot.id.uuidString)], surface: "chat"))
        #expect(listed["documents"] != nil)
        let read = try object(await dispatcher.dispatch(tool: "shelf_document", input: ["bot": .string(bot.id.uuidString),
            "name": .string("research.md"), "limit": .int(4)], surface: "chat"))
        #expect(read["content"] == .string("Kept"))
        #expect(read["nextOffset"] == .int(4))
        let answer = try await StandingBotContinuity.ask(dataRoot: root, bot: bot.id, question: "What was kept?",
            session: { system, prompt, limit in
                #expect(system.contains("No sources"))
                #expect(prompt.contains("Kept discovery: blue moon."))
                #expect(limit > 0 && limit <= 2_048)
                return "research.md records a blue moon."
            }, admission: { true })
        #expect(answer.contains("blue moon"))
        #expect(try ShelfStore(dataRoot: root).readCursor(readerId: "agent").readEntryIds.isEmpty)
        #expect(try residentFiles(root) == residentBefore)
    }

    private func residentFiles(_ root: URL) throws -> [String: Data] {
        let root = root.resolvingSymlinksInPath()
        var files: [String: Data] = [:]
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let path as URL in enumerator {
            let path = path.resolvingSymlinksInPath()
            let relative = String(path.path.dropFirst(root.path.count + 1))
            if !relative.hasPrefix("bots/"), try path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[relative] = try Data(contentsOf: path)
            }
        }
        return files
    }
    @Test func writeSourceExplainsRefusalAndFormatPersists() async throws {
        let (root, dispatcher) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var input = createInput
        input["sources"] = .array([.object(["type": .string("tool"), "name": .string("write_file")])])
        let refused = try object(await dispatcher.dispatch(tool: "bot_create", input: input, surface: "chat"))
        let detail = String(describing: refused["detail"])
        #expect(detail.contains("tier"))
        #expect(detail.contains("read-only"))
        #expect(try BotDefinitionStore(dataRoot: root).list().isEmpty)
        input["sources"] = .array([.object(["type": .string("tool"), "name": .string("list_skills")])])
        input["output_format"] = .string("Two terse lines")
        _ = try await dispatcher.dispatch(tool: "bot_create", input: input, surface: "chat")
        let bot = try #require(BotDefinitionStore(dataRoot: root).list().first)
        #expect(bot.outputFormat == "Two terse lines")
        #expect(bot.sources == [.tool("list_skills")])
    }

    @Test func toolSourceUsesStructuredLoopAndLandsOneBook() async throws {
        try await proveToolSource(denyAtTool: false)
    }

    @Test func admissionDenialBeforeToolStopsAsNotPermitted() async throws {
        try await proveToolSource(denyAtTool: true)
    }

    private func proveToolSource(denyAtTool: Bool) async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = BotLoopFixture(denyAtTool: denyAtTool)
        let bot = try BotDefinitionStore(dataRoot: root).create(BotDefinition(name: "Own work", brief: "Check available skills",
            cadence: .interval(seconds: 900), sources: [.tool("list_skills")],
            budget: BotBudget(tokens: 32000, seconds: 20), outputFormat: "Two terse lines"))
        let runner = BotRunner(dataRoot: root, session: { _, _, _ in throw BotRunnerError.invalidBook },
            admission: { await fake.admitted() }, toolSession: { system, prompt, names, budget, admission in
                #expect(prompt.contains("Two terse lines"))
                return try await StandingBotToolLoop.run(dataRoot: root, tools: fake, llm: fake,
                    system: system, prompt: prompt, names: names, budget: budget, admission: admission)
            })
        let entry = try #require(await runner.run(bot: bot.id))
        let page = try ShelfStore(dataRoot: root).shelfRead(readerId: "test")
        #expect(page.rows.count == 1)
        #expect(await fake.providerCalls <= StandingBotToolLoop.maximumRounds)
        if denyAtTool {
            #expect(entry.runHealth == .failed)
            #expect(entry.uncertainties.contains("could not check: not permitted"))
            #expect(await fake.toolCalls == 0)
        } else {
            #expect(entry.runHealth == .nothingNew)
            #expect(entry.sourceLinks.map(\.url) == ["tool:list_skills"])
            #expect(await fake.toolCalls == 1)
            #expect(await fake.sawPairedEvidence)
        }
    }
    /// Fail a missing fixture signal instead of leaving the test suspended forever.
    private static func requireSignal(_ stream: AsyncStream<Void>) async throws {
        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
        try #require(received, "Fixture signal did not arrive within five seconds")
    }

    private let names: Set<String> = ["bot_create", "bot_update", "bot_pause", "bot_run_once", "bot_list", "shelf_read", "shelf_entry", "bot_ask", "shelf_documents", "shelf_document"]

    private func fixture() throws -> (URL, SwiftToolDispatcher) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StandingBotsTools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false, enforceLazyToolLoading: false))
    }

    private var createInput: [String: JSONValue] { [
        "name": .string("Release watch"), "brief": .string("Check release changes"),
        "cadence": .object(["interval": .object(["seconds": .int(3600)])]),
        "sources": .array([.string("https://example.com/releases")]),
        "budget": .object(["tokens": .int(1000), "seconds": .int(30)]),
    ] }

    private func object(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let object) = value else { throw StandingBotsError.invalidValue("expected object") }
        return object
    }

    private func ids(_ result: JSONValue) throws -> [UUID] {
        let output = try object(result)
        guard case .array(let entries) = output["entries"] else { throw StandingBotsError.invalidValue("expected entries") }
        return try entries.map {
            guard case .string(let id) = try object($0)["id"], let uuid = UUID(uuidString: id) else { throw StandingBotsError.invalidValue("entry id") }
            return uuid
        }
    }

    @Test func schemasAreLazyRegisteredAndDescribeValidation() throws {
        let schemas = BuiltInToolSchemaFactory(requestedNames: names).standingBotSchemas().compactMap { $0 }
        #expect(Set(schemas.map(\.name)) == names)
        #expect(names.isSubset(of: Set(SwiftToolDispatcher.builtInToolNames)))
        #expect(names.isDisjoint(with: SwiftToolDispatcher.alwaysOnCoreNames))
        #expect(names.isSubset(of: SwiftNativeSecurityCenter.builtinToolNames))
        #expect(names.isSubset(of: SwiftNativeSecurityCenter.notificationToolNames))
        for name in names {
            let profile = SwiftNativeSecurityCenter.profile(tool: name, input: [:], dataRoot: URL(fileURLWithPath: "/tmp/bots-profile"))
            #expect(profile.risk == .medium)
            #expect(profile.capabilities.contains("notification"))
            #expect(!profile.capabilities.contains("filesystem_write"))
            #expect(!profile.capabilities.contains("network_write"))
        }
        #expect(BuiltInToolSchemaFactory(requestedNames: ["time_now"]).standingBotSchemas().isEmpty)
        #expect(BuiltInToolSchemaFactory(requestedNames: ["shelf_entry"]).standingBotSchemas().compactMap { $0 }.count == 1)
        let create = try #require(schemas.first { $0.name == "bot_create" })
        let schema = try object(JSONDecoder().decode(JSONValue.self, from: create.parametersJSON))
        #expect(schema["required"] == .array(["name", "brief", "cadence", "sources", "budget"].map(JSONValue.string)))
        let properties = try object(#require(schema["properties"]))
        let budget = try object(#require(properties["budget"]))
        #expect(budget["additionalProperties"] == .bool(false))
        let cadence = try object(#require(properties["cadence"]))
        guard case .array(let choices) = cadence["oneOf"] else { Issue.record("Missing cadence alternatives"); return }
        #expect(choices.count == 2)
    }

    @Test func dispatcherRejectsInvalidInputsWithoutWriting() async throws {
        let (root, dispatcher) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let badValues: [(String, JSONValue?)] = [
            ("name", .string("  ")), ("brief", nil), ("sources", .string("not an array")),
            ("budget", .object(["tokens": .bool(true), "seconds": .int(30)])),
            ("budget", .object(["tokens": .int(0), "seconds": .int(30)])),
            ("budget", .object(["tokens": .int(1), "seconds": .int(-1)])),
            ("budget", .object(["tokens": .int(Int64(BotRunLimits.maximumTokens + 1)), "seconds": .int(30)])),
            ("budget", .object(["tokens": .int(1000), "seconds": .double(BotRunLimits.maximumSeconds + 1)])),
            ("cadence", .object(["interval": .object(["seconds": .int(0)])])),
            ("cadence", .object(["interval": .object(["seconds": .double(BotRunLimits.minimumInterval - 1)])])),
            ("cadence", .object(["cron": .object(["expression": .string("0 9 * * *"), "timeZone": .string("not/a/zone")])])),
            ("cadence", .object(["interval": .object(["seconds": .int(1)]), "cron": .object([:])])),
            ("unknown", .string("setting")),
        ]
        for (key, value) in badValues {
            var input = createInput
            input[key] = value
            let result = try await dispatcher.dispatch(tool: "bot_create", input: input, surface: "chat")
            #expect(try object(result)["status"] == .string("failed"))
        }
        #expect(try BotDefinitionStore(dataRoot: root).list().isEmpty)
    }

    @Test func createUpdatePauseAndListUseCanonicalStore() async throws {
        let (root, dispatcher) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try object(await dispatcher.dispatch(tool: "bot_create", input: createInput, surface: "chat"))
        let id = try #require(created["id"])
        let updated = try object(await dispatcher.dispatch(tool: "bot_update", input: ["id": id, "fields": .object(["brief": .string("Check stable releases"), "name": .null])], surface: "chat"))
        #expect(updated["briefVersion"] == .int(2))
        #expect(updated["name"] == createInput["name"])
        let paused = try object(await dispatcher.dispatch(tool: "bot_pause", input: ["id": id, "paused": .bool(true)], surface: "chat"))
        #expect(paused["paused"] == .bool(true))
        let invalid = try object(await dispatcher.dispatch(tool: "bot_update", input: ["id": id, "fields": .object(["paused": .bool(false)])], surface: "chat"))
        #expect(invalid["status"] == .string("failed"))
        let listed = try object(await dispatcher.dispatch(tool: "bot_list", input: [:], surface: "chat"))
        #expect(listed["bots"] == .array([.object(paused)]))
        let store = BotDefinitionStore(dataRoot: root)
        let bot = try #require(store.list().first)
        #expect(try store.audit(bot.id).map(\.operation) == [.create, .update, .pause])
    }

    @Test func pagingAndFilteredReadsAcknowledgeOnlyReturnedEntries() async throws {
        let (root, dispatcher) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let definitions = BotDefinitionStore(dataRoot: root)
        let first = try definitions.create(BotDefinition(name: "One", brief: "News", cadence: .interval(seconds: BotRunLimits.minimumInterval), budget: BotBudget(tokens: 100, seconds: 10)))
        let second = try definitions.create(BotDefinition(name: "Two", brief: "News", cadence: .interval(seconds: BotRunLimits.minimumInterval), budget: BotBudget(tokens: 100, seconds: 10)))
        let shelf = ShelfStore(dataRoot: root)
        let entries = try [first.id, second.id, first.id, second.id].enumerated().map { index, bot in
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            let entry = ShelfEntry(botId: bot, briefVersion: 1, runAt: date, coverageStart: date, coverageEnd: date,
                                   headline: "Result \(index)", findings: "Full evidence", changedSinceLastGood: String(repeating: "c", count: 300),
                                   runHealth: .ok, spend: ShelfSpend(tokens: 1, seconds: 1))
            try shelf.append(entry)
            return entry
        }
        let filtered: [String: JSONValue] = ["bot": .string(second.id.uuidString), "limit": .int(1)]
        let page = try await dispatcher.dispatch(tool: "shelf_read", input: filtered, surface: "chat")
        #expect(try ids(page) == [entries[1].id])
        #expect(try shelf.readCursor(readerId: "agent").readEntryIds == [entries[1].id])
        #expect(try object(page)["truncated"] == .bool(true))
        let token = try #require(object(page)["nextCursor"])
        let mismatch = try await dispatcher.dispatch(tool: "shelf_read", input: ["cursor": token], surface: "chat")
        #expect(try object(mismatch)["status"] == .string("failed"))
        #expect(try shelf.readCursor(readerId: "agent").readEntryIds == [entries[1].id])
        var next = filtered
        next["cursor"] = token
        let continued = try await dispatcher.dispatch(tool: "shelf_read", input: next, surface: "chat")
        #expect(try ids(continued) == [entries[3].id])
        // A new dispatcher/root owner still sees the earlier filtered-out holes.
        let reopened = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false, enforceLazyToolLoading: false)
        let holes = try await reopened.dispatch(tool: "shelf_read", input: ["limit": .int(1)], surface: "chat")
        #expect(try ids(holes) == [entries[0].id])
        #expect(try shelf.readCursor(readerId: "agent").readEntryIds == Set([entries[0].id, entries[1].id, entries[3].id]))
        #expect(try shelf.readCursor(readerId: "ui:user").readEntryIds.isEmpty)
        let invalidInputs: [[String: JSONValue]] = [["limit": .int(0)], ["limit": .int(101)], ["limit": .double(1.5)], ["since": .string("yesterday")], ["bot": .string("missing")]]
        for invalidInput in invalidInputs {
            let failed = try await reopened.dispatch(tool: "shelf_read", input: invalidInput, surface: "chat")
            #expect(try object(failed)["status"] == .string("failed"))
        }
        #expect(try shelf.readCursor(readerId: "agent").readEntryIds == Set([entries[0].id, entries[1].id, entries[3].id]))
        let full = try await reopened.dispatch(tool: "shelf_entry", input: ["id": .string(entries[2].id.uuidString)], surface: "chat")
        #expect(try object(full)["findings"] == .string("Full evidence"))
        #expect(try shelf.readCursor(readerId: "agent").readEntryIds == Set(entries.map(\.id)))
        let empty = try await reopened.dispatch(tool: "shelf_read", input: [:], surface: "chat")
        #expect(try ids(empty).isEmpty)
    }

    @Test func runOnceReturnsOnlyAnAcceptedLocalEnqueueReceipt() async throws {
        let (root, unbound) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = try BotDefinitionStore(dataRoot: root).create(BotDefinition(name: "One", brief: "News", cadence: .interval(seconds: BotRunLimits.minimumInterval), budget: BotBudget(tokens: 100, seconds: 10)))
        let args: [String: JSONValue] = ["id": .string(bot.id.uuidString)]
        let unavailable = try await unbound.dispatch(tool: "bot_run_once", input: args, surface: "chat")
        #expect(try object(unavailable)["reason"] == .string("run_queue_unavailable"))
        let receiptID = UUID()
        let file = root.appendingPathComponent("test-queue-receipt")
        let bound = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false, enforceLazyToolLoading: false,
                                       standingBotRunEnqueue: { id in
            try Data(id.uuidString.utf8).write(to: file, options: .atomic)
            return receiptID
        })
        let queued = try object(await bound.dispatch(tool: "bot_run_once", input: args, surface: "chat"))
        #expect(queued["status"] == .string("queued"))
        #expect(queued["requestId"] == .string(receiptID.uuidString))
        #expect(try String(contentsOf: file, encoding: .utf8) == bot.id.uuidString)
        #expect(try ShelfStore(dataRoot: root).shelfRead().rows.isEmpty)
        let refusing = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false, enforceLazyToolLoading: false,
                                          standingBotRunEnqueue: { _ in throw StandingBotsError.invalidValue("queue refused") })
        let failed = try await refusing.dispatch(tool: "bot_run_once", input: args, surface: "chat")
        #expect(try object(failed)["status"] == .string("failed"))
    }

    @Test func realQueueAdmissionAndSchedulerShareOneRun() async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotDefinitionStore(dataRoot: root)
        var bot = try store.create(BotDefinition(name: "News", brief: "Check news", cadence: .interval(seconds: 3600),
                                                sources: ["https://example.org"], budget: BotBudget(tokens: 8000, seconds: 10)))
        let queue = BotRunQueue(dataRoot: root)
        let dispatcher = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false, enforceLazyToolLoading: false,
                                            standingBotRunEnqueue: { try queue.enqueueRequest(bot: $0) })
        let args: [String: JSONValue] = ["id": .string(bot.id.uuidString)]
        let accepted = try object(await dispatcher.dispatch(tool: "bot_run_once", input: args, surface: "chat"))
        #expect(accepted["status"] == .string("queued"))
        let repeated = try object(await dispatcher.dispatch(tool: "bot_run_once", input: args, surface: "chat"))
        #expect(repeated["reason"] == .string("already_running"))
        #expect(try ShelfStore(dataRoot: root).shelfRead().rows.isEmpty)

        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish(); release.continuation.finish() }
        // Reconstructed scheduler reads the durable queue; enqueue has not run a provider.
        let scheduler = BotRunnerScheduler(dataRoot: root, session: { _, _, _ in
            started.continuation.yield(())
            try await Self.requireSignal(release.stream)
            return Self.unchangedBook
        }, fetch: { _, _ in "No changes" }, admission: { true })
        let now = Date()
        #expect(await scheduler.nextDeadline(after: now) == now)
        let task = Task { await scheduler.runDue() }
        defer { task.cancel() }
        try await Self.requireSignal(started.stream)
        let running = try queue.enqueue(bot: bot.id)
        #expect(!running.accepted && running.reason == "already_running")
        release.continuation.yield(())
        #expect(await task.value == ["bot:\(bot.id.uuidString)"])
        let entry = try #require(ShelfStore(dataRoot: root).shelfRead().rows.first)
        #expect(accepted["requestId"] == .string(entry.id.uuidString))
        let next = try #require(await scheduler.nextDeadline(after: Date()))
        #expect(next >= entry.coverageEnd.addingTimeInterval(3600))
        #expect(await scheduler.runDue().isEmpty)

        bot = try store.pause(bot.id)
        #expect(try queue.enqueue(bot: bot.id).reason == "paused")
        bot = try store.pause(bot.id, paused: false)
        bot.budget.tokens = 100
        _ = try store.update(bot)
        #expect(try queue.enqueue(bot: bot.id).reason == "over_budget")
        #expect(try ShelfStore(dataRoot: root).shelfRead().rows.count == 1)
    }

    private static let unchangedBook = """
    {"headline":"Checked, nothing new","findings":"No change","changedSinceLastGood":"None","sourceURLs":["https://example.org"],"uncertainties":[],"runHealth":"nothingNew"}
    """

    @Test func runnerBooksRoundTripThroughShelfTools() async throws {
        let (root, dispatcher) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = try BotDefinitionStore(dataRoot: root).create(BotDefinition(name: "News", brief: "Check news",
            cadence: .interval(seconds: 3600), sources: ["https://example.org"], budget: BotBudget(tokens: 8000, seconds: 10)))
        let runner = BotRunner(dataRoot: root, session: { _, _, _ in Self.unchangedBook }, fetch: { _, _ in "No changes" }, admission: { true })
        let good = try #require(await runner.run(bot: bot.id))
        let failedRunner = BotRunner(dataRoot: root, session: { _, _, _ in
            Issue.record("Unavailable evidence must not call a provider")
            return Self.unchangedBook
        }, fetch: { _, _ in throw BotRunnerError.unavailableSource }, admission: { true })
        let failed = try #require(await failedRunner.run(bot: bot.id))
        let index = try object(await dispatcher.dispatch(tool: "shelf_read", input: [:], surface: "chat"))
        guard case .array(let rows) = index["entries"] else { Issue.record("Missing shelf rows"); return }
        #expect(try rows.map { try object($0)["id"] } == [good, failed].map { .string($0.id.uuidString) })
        #expect(try rows.map { try object($0)["runHealth"] } == [.string("nothingNew"), .string("failed")])
        for book in [good, failed] {
            let detail = try await dispatcher.dispatch(tool: "shelf_entry", input: ["id": .string(book.id.uuidString)], surface: "chat")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(ShelfEntry.self, from: detail.serializedData(pretty: false))
            #expect(decoded.id == book.id)
            #expect(decoded.findings == book.findings)
            #expect(decoded.sourceLinks.map(\.url) == book.sourceLinks.map(\.url))
            #expect(decoded.runHealth == book.runHealth)
        }
        #expect(try ShelfStore(dataRoot: root).lastGood(bot: bot.id)?.id == good.id)
    }

    @Test func toolDefinitionChangesInvalidateExistingSchedule() async throws {
        let (root, dispatcher) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let scheduler = BotRunnerScheduler(dataRoot: root, session: { _, _, _ in
            Issue.record("Configuration changes must not execute a provider")
            return Self.unchangedBook
        }, admission: { true })
        #expect(await scheduler.nextDeadline(after: Date()) == nil)
        let changes = AsyncStream<Void>.makeStream()
        let observer = NotificationCenter.default.addObserver(forName: BotRunQueue.didChange, object: nil, queue: nil) { _ in
            changes.continuation.yield(())
        }
        defer { NotificationCenter.default.removeObserver(observer); changes.continuation.finish() }
        let created = try object(await dispatcher.dispatch(tool: "bot_create", input: createInput, surface: "chat"))
        let id = try #require(created["id"])
        try await Self.requireSignal(changes.stream)
        let first = try #require(await scheduler.nextDeadline(after: Date()))
        _ = try await dispatcher.dispatch(tool: "bot_update", input: ["id": id, "fields": .object([
            "cadence": .object(["interval": .object(["seconds": .double(BotRunLimits.minimumInterval)])])
        ])], surface: "chat")
        try await Self.requireSignal(changes.stream)
        #expect(try #require(await scheduler.nextDeadline(after: Date())) < first)
        _ = try await dispatcher.dispatch(tool: "bot_pause", input: ["id": id, "paused": .bool(true)], surface: "chat")
        try await Self.requireSignal(changes.stream)
        #expect(await scheduler.nextDeadline(after: Date()) == nil)
    }
}

private actor BotLoopFixture: LLMClient, ToolDispatchClient {
    let denyAtTool: Bool
    var providerCalls = 0
    var toolCalls = 0
    var sawPairedEvidence = false
    init(denyAtTool: Bool) { self.denyAtTool = denyAtTool }
    func admitted() -> Bool { !denyAtTool || providerCalls == 0 }
    func listAvailableTools() async throws -> [String] { ["list_skills"] }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        [LLMToolSchema(name: "list_skills", description: "List skills", parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8))]
    }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        toolCalls += 1
        return .object(["skills": .array([])])
    }
    func complete(prompt: String, system: String?, model: String?) async throws -> String { throw BotRunnerError.invalidBook }
    func completeMessages(messages: [LLMMessage], system: String?, model: String?, surface: String, tools: [LLMToolSchema]?) async throws -> String {
        providerCalls += 1
        if providerCalls == 1 {
            return #"{"tool_calls":[{"id":"c1","type":"function","function":{"name":"list_skills","arguments":"{}"}}]}"#
        }
        sawPairedEvidence = messages.contains { message in
            message.content.contains { if case .toolResult(_, let content, _) = $0 { return content.contains("untrustedEvidence") }; return false }
        }
        return #"{"headline":"Checked skills","findings":"No changes","changedSinceLastGood":"Unchanged","sourceURLs":["tool:list_skills"],"uncertainties":[],"runHealth":"nothingNew"}"#
    }
}
