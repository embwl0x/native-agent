import Testing
import PersistenceCore
@testable import ChatOrchestration

@Suite("Workspace human app conversations")
struct AgentWorkspaceMessagesTests {
    @Test func messagesListOpensExactConversationAndDetailBindsParticipants() throws {
        let id = "iMessage;+;chat42"
        let row: JSONValue = .object(["thread_id": .string(id), "name": .string("Family"), "participants": .array([
            .object(["handle": .string("one@example.invalid"), "name": .string("One")]),
            .object(["handle": .string("two@example.invalid"), "name": .string("Two")])])])
        let result: JSONValue = .object(["status": .string("completed"), "threads": .array([row])])
        let list = AgentWorkspaceMessages.project(input: [:], result: result)
        #expect(list.items[0].title == "Family")
        guard case .open(.record(let tool, let bound, _)) = list.items[0].actions[0].action else { Issue.record("Exact detail missing"); return }
        #expect(tool == "messages_recent_threads")
        #expect(bound == ["thread_id": .string(id)])
        let detail = AgentWorkspaceMessages.project(input: bound, result: result)
        guard case .perform(let send, let input, _, let field, let effect) = detail.items[0].actions[0].action else { Issue.record("Reply missing"); return }
        #expect(send == "messages_send" && effect && field == "body")
        #expect(input["thread_id"] == .string(id))
        #expect(input["to"] == nil)
        #expect(input["expected_participants"] == .array([.string("one@example.invalid"), .string("two@example.invalid")]))
    }

    @Test func missingValueNamesFallBackToKnownParticipants() {
        let view = AgentWorkspaceMessages.project(input: [:], result: .object(["status": .string("completed"), "threads": .array([
            .object(["thread_id": .string("chat42"), "name": .string("missing value"), "participants": .array([
                .object(["name": .string("missing value"), "handle": .string("one@example.invalid")])])])])]))
        #expect(view.items[0].title == "one@example.invalid")
    }

    @Test func mailContinuationRetainsSearchAndOfferedOffset() throws {
        let view = AgentWorkspaceMail.project(input: ["query": .string("invoice"), "offset": .int(4)], result: .object([
            "status": .string("completed"), "messages": .array([]), "next_offset": .int(9)]))
        guard case .open(.record(let tool, let input, _)) = view.actions[0].action else { Issue.record("Missing next page"); return }
        #expect(tool == "mail_search")
        #expect(input == ["query": .string("invoice"), "offset": .int(9)])
    }

    @Test func mismatchedOrLegacyMessageIdentityCannotBecomeReply() {
        let rows: [JSONValue] = [.object(["handle": .string("chat42")]), .object(["thread_id": .string("other"), "participants": .array([.object(["handle": .string("recipient")])])])]
        for row in rows {
            let view = AgentWorkspaceMessages.project(input: ["thread_id": .string("requested")], result: .object(["status": .string("completed"), "threads": .array([row])]))
            #expect(view.items[0].actions.count == 1)
            #expect(view.items[0].actions[0].label == "Open Messages view")
        }
    }

    @Test func mailReplyRequiresMatchingReadLocatorNotSubjectOrSender() throws {
        let row: JSONValue = .object(["message_id": .int(42), "expected_message_id": .string("rfc@example.invalid"), "subject": .string("Repeated"), "sender": .string("Display <sender@example.invalid>")])
        let result: JSONValue = .object(["status": .string("completed"), "detail": .bool(true), "messages": .array([row])])
        let bound: [String: JSONValue] = ["message_id": .int(42), "expected_message_id": .string("rfc@example.invalid")]
        let detail = AgentWorkspaceMail.project(input: bound, result: result)
        guard case .perform(let tool, let input, _, _, _) = detail.items[0].actions[0].action else { Issue.record("Reply missing"); return }
        #expect(tool == "mail_reply" && input == bound)
        let mismatch = AgentWorkspaceMail.project(input: ["message_id": .int(99)], result: result)
        #expect(mismatch.items[0].actions.count == 1)
        #expect(mismatch.items[0].actions[0].label == "Open Mail view")
    }
}
