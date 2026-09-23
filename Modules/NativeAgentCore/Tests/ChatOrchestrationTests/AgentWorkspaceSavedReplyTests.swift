import Foundation
import Testing
import PersistenceCore
import StandingBots
@testable import ChatOrchestration

private actor SavedReplyFixture {
    static let bot = "91B1C573-6281-4D41-A7DE-A3B13759FC4A"
    static let entry = "3CA75BD8-4A36-4474-ACD1-01F62CD70AAB"
    var answer = "Selected historical answer, not the newest reply."
    var readStatus = "ok"
    var throwSend = false
    var calls: [(String, [String: JSONValue])] = []
    func changeAnswer(_ value: String) { answer = value }
    func denyRead() { readStatus = "denied" }
    func uncertainSend() { throwSend = true }
    func snapshot() -> [(String, [String: JSONValue])] { calls }
    static func reply(_ answer: String) -> JSONValue {
        .object(["status": .string("ok"), "id": .string(entry), "botId": .string(bot),
            "agent_name": .string("Helper"), "headline": .string("Older answer"),
            "answer": .string(answer), "run_status": .string("completed"), "runAt": .int(42)])
    }
    func perform(_ tool: String, _ input: [String: JSONValue]) throws -> JSONValue {
        calls.append((tool, input))
        switch tool {
        case "shelf_read":
            return .object(["status": .string("ok"), "entries": .array([.object([
                "id": .string(Self.entry), "bot": .string(Self.bot), "headline": .string("Older answer")])])])
        case "shelf_entry":
            #expect(input == ["id": .string(Self.entry), "bot_id": .string(Self.bot)])
            return readStatus == "ok" ? Self.reply(answer) : .object(["status": .string(readStatus)])
        case "agent_message":
            if throwSend { throw AgentWorkspaceSavedReply.Failure(message: "Transport lost after admission") }
            return .object(["status": .string("pending"), "detail": .string("Accepted, not settled")])
        case "agent_read":
            return .object(["status": .string("pending")])
        default: throw AgentWorkspaceSavedReply.Failure(message: "Unexpected tool " + tool)
        }
    }
}

@Suite("Saved reply follow-up continuity")
struct AgentWorkspaceSavedReplyTests {
    private func object(_ value: JSONValue) -> [String: JSONValue] {
        if case .object(let row) = value { return row }; return [:]
    }
    private func action(_ value: JSONValue, _ label: String) throws -> JSONValue {
        let root = object(value)
        var actions: [JSONValue] = []
        if case .array(let rows)? = root["actions"] { actions += rows }
        if case .array(let rows)? = root["items"] {
            for row in rows { if case .array(let entries)? = object(row)["actions"] { actions += entries } }
        }
        let row = try #require(actions.first { object($0)["label"] == .string(label) })
        return try #require(object(row)["action"])
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("saved-reply-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func openList(root: URL, navigation: AgentWorkspaceNavigation) async throws {
        let key = root.path + "\u{0}ours"
        let operation = try await navigation.begin(key: key)
        try await navigation.navigate(.record(tool: "shelf_read", input: [:], title: "Saved replies"), key: key)
        await navigation.end(key: key, operation: operation)
    }
    private func call(_ input: [String: JSONValue] = [:], root: URL, navigation: AgentWorkspaceNavigation,
                      fixture: SavedReplyFixture, scope: String = "ours") async throws -> JSONValue {
        try await AgentWorkspace.dispatch(input: input, scope: scope, dataRoot: root, navigation: navigation,
            perform: { tool, args in try await fixture.perform(tool, args) })
    }

    @Test func readFollowUpAndReturnKeepExactHistoricalReplyWithoutResending() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let navigation = AgentWorkspaceNavigation(), fixture = SavedReplyFixture()
        try await openList(root: root, navigation: navigation)
        let list = try await call(root: root, navigation: navigation, fixture: fixture)
        let detail = try await call(["action": action(list, "Read reply")], root: root, navigation: navigation, fixture: fixture)
        let send = try action(detail, "Follow up")
        let receipt = try await call(["action": send, "text": .string("Explain the earlier answer")], root: root, navigation: navigation, fixture: fixture)
        #expect(object(receipt)["status"] == .string("pending"))
        _ = try await call(root: root, navigation: navigation, fixture: fixture) // refresh only retained receipt
        do {
            _ = try await call(["action": send, "text": .string("Do not duplicate")], root: root, navigation: navigation, fixture: fixture)
            Issue.record("Consumed follow-up was replayed")
        } catch {}
        let refreshed = try await call(root: root, navigation: navigation, fixture: fixture)
        let returned = try await call(["action": action(refreshed, "Return to saved reply")], root: root, navigation: navigation, fixture: fixture)
        #expect(object(try #require(object(returned)["content"]))["id"] == .string(SavedReplyFixture.entry))
        _ = try action(returned, "Follow up")
        let calls = await fixture.snapshot()
        let sends = calls.filter { $0.0 == "agent_message" }
        #expect(sends.count == 1)
        #expect(sends.first?.1["agent"] == .string("bot:" + SavedReplyFixture.bot))
        #expect(sends.first?.1["conversation"] == nil) // the helper's existing continuous session
        let text = try #require(sends.first?.1["text"])
        let serialized = try text.serialize(pretty: false)
        #expect(serialized.contains("Explain the earlier answer"))
        #expect(serialized.contains("Selected historical answer, not the newest reply."))
        #expect(serialized.contains(SavedReplyFixture.entry))
        #expect(calls.filter { $0.0 == "shelf_read" }.count == 1) // no list reconstruction
    }

    @Test(arguments: ["changed", "denied", "foreign"])
    func invalidatedOrForeignSelectionCannotSend(reason: String) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let navigation = AgentWorkspaceNavigation(), fixture = SavedReplyFixture()
        try await openList(root: root, navigation: navigation)
        let list = try await call(root: root, navigation: navigation, fixture: fixture)
        let detail = try await call(["action": action(list, "Read reply")], root: root, navigation: navigation, fixture: fixture)
        if reason == "changed" { await fixture.changeAnswer("Changed owner answer") }
        if reason == "denied" { await fixture.denyRead() }
        do {
            _ = try await call(["action": action(detail, "Follow up"), "text": .string("Follow up")], root: root,
                navigation: navigation, fixture: fixture, scope: reason == "foreign" ? "other" : "ours")
            Issue.record("Invalidated selection sent")
        } catch {}
        #expect(await fixture.snapshot().filter { $0.0 == "agent_message" }.isEmpty)
    }

    @Test func uncertainSendRetainsReturnAndCannotReplay() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let navigation = AgentWorkspaceNavigation(), fixture = SavedReplyFixture()
        try await openList(root: root, navigation: navigation)
        let list = try await call(root: root, navigation: navigation, fixture: fixture)
        await fixture.uncertainSend()
        do {
            _ = try await call(["action": action(list, "Follow up"), "text": .string("Question")], root: root, navigation: navigation, fixture: fixture)
            Issue.record("Expected uncertain transport")
        } catch {}
        let receipt = try await call(root: root, navigation: navigation, fixture: fixture)
        #expect(object(receipt)["status"] == .string("outcome_unknown"))
        _ = try action(receipt, "Open conversation")
        _ = try await call(["action": action(receipt, "Return to saved reply")], root: root, navigation: navigation, fixture: fixture)
        #expect(await fixture.snapshot().filter { $0.0 == "agent_message" }.count == 1)
    }

    @Test func detailRequiresMatchingOwnerIdentitiesAndNeverPromotesSourceRecipes() throws {
        let input: [String: JSONValue] = ["id": .string(SavedReplyFixture.entry), "bot_id": .string(SavedReplyFixture.bot)]
        let base = object(SavedReplyFixture.reply("Answer"))
        for field in ["id", "botId", "status"] {
            var row = base; row[field] = .string(field == "status" ? "denied" : UUID().uuidString)
            row["reply_with"] = .object(["tool": .string("shell_exec")])
            let view = try #require(AgentWorkspaceActivity.project(tool: "shelf_entry", input: input, result: .object(row)))
            #expect(view.actions.isEmpty)
        }
    }

    @Test func excerptIsBoundedButChangeBeyondExcerptStillInvalidates() throws {
        let selected = AgentWorkspaceSavedReply(entryID: SavedReplyFixture.entry, botID: SavedReplyFixture.bot, title: "Answer")
        let prefix = String(repeating: "a", count: 12_000)
        let first = try #require(selected.evidence(SavedReplyFixture.reply(prefix + "first")))
        let later = try #require(selected.evidence(SavedReplyFixture.reply(prefix + "second")))
        #expect(first.fingerprint != later.fingerprint)
        #expect(object(first.value)["answer"] == .string(prefix))
        #expect(object(first.value)["truncated"] == .bool(true))
    }

    @Test func savedAnswerTitleIsRecognizableWithoutCopyingTheAnswer() {
        let title = AgentWorkspaceSavedReply.title(.object(["agent_name": .string("Sideways"),
            "runAt": .string("2026-09-10T14:38:30Z"), "headline": .string(String(repeating: "paragraph ", count: 100))]))
        #expect(title == "Sideways — Sep 10, 14:38:30 UTC")
        #expect(title.count < 60)
    }

    @Test func unfilteredShelfNamesEachHelperAndKeepsMissingDefinitionsHonest() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let definitions = BotDefinitionStore(dataRoot: root)
        let first = try definitions.create(.init(name: "First helper", brief: "Fixture", cadence: .manual, budget: .init(tokens: 500, seconds: 30)))
        let second = try definitions.create(.init(name: "Second helper", brief: "Fixture", cadence: .manual, budget: .init(tokens: 500, seconds: 30)))
        let removed = try definitions.create(.init(name: "Removed helper", brief: "Fixture", cadence: .manual, budget: .init(tokens: 500, seconds: 30)))
        let missing = removed.id
        for id in [first.id, second.id, missing] {
            try ShelfStore(dataRoot: root).append(.init(botId: id, briefVersion: 1, runAt: Date(), coverageStart: Date(),
                coverageEnd: Date(), headline: "Same headline", findings: "Fixture answer", changedSinceLastGood: "",
                runHealth: .ok, spend: .init(tokens: 10, seconds: 1)))
        }
        try definitions.delete(missing)
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let response = try await dispatcher.impl_standingBots(tool: "shelf_read", input: ["include_read": .bool(true)])
        guard case .array(let rows)? = object(response)["entries"] else { Issue.record("No entries"); return }
        for (id, name) in [(first.id, JSONValue.string(first.name)), (second.id, .string(second.name)), (missing, .null)] {
            let row = try #require(rows.first { object($0)["bot"] == .string(id.uuidString) })
            #expect(object(row)["agent_name"] == name)
        }
        // History browsing does not consume unread state. Ordinary callers
        // retain the old unread/acknowledgement contract.
        let unread = try await dispatcher.impl_standingBots(tool: "shelf_read", input: [:])
        #expect(object(unread)["entries"] == .array(rows))
        let consumed = try await dispatcher.impl_standingBots(tool: "shelf_read", input: [:])
        #expect(object(consumed)["entries"] == .array([]))
        let history = try await dispatcher.impl_standingBots(tool: "shelf_read", input: ["include_read": .bool(true)])
        #expect(object(history)["entries"] == .array(rows))
        let firstPage = try await dispatcher.impl_standingBots(tool: "shelf_read", input: ["include_read": .bool(true), "limit": .int(1)])
        let cursor = try #require(object(firstPage)["nextCursor"])
        let page = try #require(AgentWorkspaceActivity.project(tool: "shelf_read", input: ["include_read": .bool(true), "limit": .int(1)], result: firstPage))
        guard case .open(.record(_, let next, _)) = page.actions[0].action else { Issue.record("No history continuation"); return }
        #expect(next["include_read"] == .bool(true) && next["cursor"] == cursor)
        let secondPage = try await dispatcher.impl_standingBots(tool: "shelf_read", input: next)
        #expect(object(secondPage)["status"] == .string("ok"))
        let source = AgentWorkspaceLocation.record(tool: "shelf_read", input: ["include_read": .bool(true)], title: "Saved replies")
        #expect(AgentWorkspaceDesktopStore.durable(source) == source)
    }
}
