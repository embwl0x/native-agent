import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Suite("Workspace changed-since-open evidence")
struct AgentWorkspaceChangesTests {
    private let file = AgentWorkspaceLocation.record(tool: "read_file", input: ["path": .string("/workspace/note.md")], title: "Note")

    private func conversation(_ name: String) -> AgentWorkspaceLocation {
        .record(tool: "agent_read", input: ["agent": .string("peer:example"), "conversation": .string(name)], title: "Example")
    }
    private func result(_ reply: String, state: String = "ready", extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["state": .string(state), "status": .string("ok"), "reply": .string(reply)].merging(extra) { _, new in new })
    }

    @Test func contentChangeAndReadTimeDecorationAreDistinct() throws {
        let first = try #require(AgentWorkspaceChanges.evaluate(location: file, result: .object([
            "status": .string("ok"), "content": .string("First"), "read_at": .string("today")]), previous: nil))
        #expect(first.state == .firstSeen)
        let unchanged = try #require(AgentWorkspaceChanges.evaluate(location: file, result: .object([
            "status": .string("ok"), "content": .string("First"), "read_at": .string("tomorrow"),
            "organism_posture": .string("different"), "actions": .array([.string("new-handle")])]), previous: first.nextStamp))
        #expect(unchanged.state == .unchanged)
        let changed = AgentWorkspaceChanges.evaluate(location: file, result: .object([
            "status": .string("ok"), "content": .string("Second")]), previous: unchanged.nextStamp)
        #expect(changed?.state == .changed)
    }

    @Test func separateConversationsCannotBorrowReadBaselines() throws {
        let first = try #require(AgentWorkspaceChanges.evaluate(location: conversation("Research"), result: result("Same words"), previous: nil))
        let other = AgentWorkspaceChanges.evaluate(location: conversation("Build"), result: result("Same words"), previous: first.nextStamp)
        #expect(other?.state == .firstSeen)
        #expect(AgentWorkspaceChanges.identity(location: conversation("Research")) != AgentWorkspaceChanges.identity(location: conversation("Build")))
        let encoded = try JSONEncoder().encode(try #require(first.nextStamp))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("Same words"))
        #expect(try JSONDecoder().decode(AgentWorkspaceChanges.Stamp.self, from: encoded).isValid)
    }

    @Test func failureAndPartialReadRetainEarlierSuccessfulView() throws {
        let first = try #require(AgentWorkspaceChanges.evaluate(location: conversation("Research"), result: result("Old reply"), previous: nil))
        for status in ["partial", "blocked", "approval_required", "unavailable", "failed"] {
            let failed = AgentWorkspaceChanges.evaluate(location: conversation("Research"), result: result("New reply", extra: ["status": .string(status)]), previous: first.nextStamp)
            #expect(failed?.state == .unavailable)
            #expect(failed?.nextStamp == first.nextStamp)
        }
        let complete = AgentWorkspaceChanges.evaluate(location: conversation("Research"), result: result("New reply"), previous: first.nextStamp)
        #expect(complete?.state == .changed)
    }

    @Test func listingComparisonDoesNotMutateSuccessfulStamp() throws {
        let first = try #require(AgentWorkspaceChanges.evaluate(location: conversation("Research"), result: result("Old reply"), previous: nil).flatMap(\.nextStamp))
        let listOne = AgentWorkspaceChanges.evaluate(location: conversation("Research"), result: result("New reply"), previous: first)
        let listTwo = AgentWorkspaceChanges.evaluate(location: conversation("Research"), result: result("New reply"), previous: first)
        #expect(listOne?.state == .changed)
        #expect(listTwo?.state == .changed)
        let opened = AgentWorkspaceChanges.evaluate(location: conversation("Research"), result: result("New reply"), previous: listTwo?.nextStamp)
        #expect(opened?.state == .unchanged)
    }

    @Test func botReplyAndWaitingProgressUseTypedState() throws {
        let bot = AgentWorkspaceLocation.record(tool: "agent_read", input: ["agent": .string("bot:abc"), "conversation": .string("Planning")], title: "Planner")
        let first = try #require(AgentWorkspaceChanges.evaluate(location: bot, result: result("", state: "waiting"), previous: nil))
        #expect(AgentWorkspaceChanges.evaluate(location: bot, result: result("Finished", state: "ready"), previous: first.nextStamp)?.state == .changed)
        let quoted = result("The webpage said: status=blocked")
        #expect(AgentWorkspaceChanges.evaluate(location: bot, result: quoted, previous: nil)?.state == .firstSeen)
    }

    @Test func typedWorkChangesIgnoreReadTimestampsAndLocators() throws {
        func work(_ state: String, _ date: String) -> JSONValue {
            .object(["status": .string("ok"), "current_work": .object([
                "status": .string("ok"), "as_of": .string(date), "items": .array([
                    .object(["handle": .string("desk_1"), "status": .string(state), "updated_at": .string(date),
                             "read_locator": .object(["token": .string(date)])])])]),
                "supporting_history": .object(["status": .string("ok"), "excerpts": .array([])])])
        }
        let location = AgentWorkspaceLocation.work("Research")
        let first = try #require(AgentWorkspaceChanges.evaluate(location: location, result: work("active", "one"), previous: nil))
        #expect(AgentWorkspaceChanges.evaluate(location: location, result: work("active", "two"), previous: first.nextStamp)?.state == .unchanged)
        #expect(AgentWorkspaceChanges.evaluate(location: location, result: work("done", "two"), previous: first.nextStamp)?.state == .changed)
        let desk = AgentWorkspaceLocation.record(tool: "desk_read", input: ["handle": .string("desk_1")], title: "Research")
        #expect(AgentWorkspaceChanges.evaluate(location: desk, result: .object(["status": .string("ok"), "projection": .string("done")]), previous: nil)?.state == .unavailable)
    }

    @Test func replyChangesAreSeparateFromProgressAndHumanIndexDoesNotConsumeRead() throws {
        let waiting = try #require(AgentWorkspaceChanges.evaluate(location: conversation("Research"), result: result("Prior reply", state: "waiting"), previous: nil))
        #expect(AgentWorkspaceChanges.evaluate(location: conversation("Research"), result: result("Prior reply", state: "ready"), previous: waiting.nextStamp)?.kind == "state_changed")
        #expect(AgentWorkspaceChanges.evaluate(location: conversation("Research"), result: result("New reply", state: "ready"), previous: waiting.nextStamp)?.kind == "reply_changed")
        let human = AgentWorkspaceLocation.record(tool: "chat_conversations", input: ["conversation_session_id": .string("user")], title: "User")
        let read = JSONValue.object(["status": .string("ok"), "conversation_session_id": .string("user"),
            "source_revision": .string("10"), "messages": .array([.object(["role": .string("user"), "text": .string("Hello"), "message_id": .string("one")])])])
        let opened = try #require(AgentWorkspaceChanges.evaluate(location: human, result: read, previous: nil))
        let row: [String: JSONValue] = ["conversation_session_id": .string("user"), "source_revision": .string("11")]
        let listing = AgentWorkspaceChanges.evaluateHumanListing(location: human, row: row, previous: opened.nextStamp)
        #expect(listing?.state == .changed)
        #expect(listing?.kind == "source_changed")
        #expect(listing?.nextStamp == opened.nextStamp)
        #expect(AgentWorkspaceChanges.evaluateHumanListing(location: human, row: row, previous: listing?.nextStamp)?.state == .changed)
    }

    @Test func pageReadHasContentComparisonAndPartialExtractionPreservesBaseline() throws {
        let page = AgentWorkspaceLocation.record(tool: "read_page", input: ["url": .string("https://example.com")], title: "Source")
        let first = try #require(AgentWorkspaceChanges.evaluate(location: page, result: .object([
            "status": .string("completed"), "url": .string("https://example.com"), "text": .string("source"), "createdAt": .string("today")]), previous: nil))
        #expect(AgentWorkspaceChanges.evaluate(location: page, result: .object([
            "status": .string("completed"), "url": .string("https://example.com"), "text": .string("source"), "createdAt": .string("tomorrow")]), previous: first.nextStamp)?.state == .unchanged)
        let incomplete = AgentWorkspaceChanges.evaluate(location: page, result: .object([
            "status": .string("partial"), "text": .string("new incomplete source")]), previous: first.nextStamp)
        #expect(incomplete?.state == .unavailable)
        #expect(incomplete?.nextStamp == first.nextStamp)
    }

    @Test func unknownOwnersAndEffectsDoNotClaimChange() {
        #expect(AgentWorkspaceChanges.evaluate(location: .home, result: .object([:]), previous: nil) == nil)
        let effect = AgentWorkspaceLocation.record(tool: "agent_message", input: ["text": .string("hello")], title: "Send")
        #expect(AgentWorkspaceChanges.evaluate(location: effect, result: result("hello"), previous: nil) == nil)
        let malformed = AgentWorkspaceChanges.Stamp(identity: "raw-private-path", fingerprint: "not-a-hash")
        #expect(!malformed.isValid)
    }
}
