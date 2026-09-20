import Testing
import PersistenceCore
@testable import ChatOrchestration

@Test func toolContractClaudeMatchingTopic() throws {
    let input: [String: JSONValue] = ["conversation_mode": .string("resume"),
        "conversation_id": .string("claude:bug-music-tcc"), "topic": .string("Bug Music TCC")]
    let selection = try SwiftToolDispatcher.builderConversationSelection(input: input,
        agent: .claude, topic: "Bug Music TCC", messageId: "reply").get()
    #expect(selection.topic == "bug-music-tcc")
    #expect(selection.conversationId == "claude:bug-music-tcc")
    let result = SwiftToolDispatcher.builderConversationSelection(input: input,
        agent: .claude, topic: "another-topic", messageId: "reply")
    guard case .failure(let error) = result else { Issue.record("Conflicting topic accepted"); return }
    guard case .object(let fields) = error.envelope, case .string(let fix)? = fields["fix"] else {
        Issue.record("Missing repair example"); return
    }
    #expect(fix.contains("topic: \"bug-music-tcc\""))
}
