import Testing
import PersistenceCore
@testable import ChatOrchestration

@Suite struct AgentConversationViewTests {
    @Test func botNameIsALabelWhileActionsKeepStableIdentity() {
        let agent = "bot:8C13534B-3C5F-4E38-AB11-06C90E3715F5"
        let raw: JSONValue = .object(["agent_name": .string("Plainspoken"), "reply": .string("ok"), "id": .string("41CC4647-A773-4015-9B1E-4D16A9B2B3C6")])
        guard case .object(let view) = AgentConversationView.read(raw, agent: agent, input: [:]), case .array(let rows)? = view["exchanges"], case .object(let first) = rows.first else { Issue.record("Missing exchange"); return }
        #expect(first["from"] == .string("Plainspoken"))
        #expect(first["conversation_id"] == .string(agent))
    }
    @Test func deliveryAssessmentIsNeverPresentedAsOriginalAgentText() {
        func read(_ reply: String?) -> [String: JSONValue] {
            var row: [String: JSONValue] = ["record_kind": .string("delivery_receipt"), "completion_text_head": .string("Agent says the reply arrived")]
            if let reply { row["agent_reply_text_head"] = .string(reply) }
            let raw: JSONValue = .object(["jobs": .array([.object(row)])])
            guard case .object(let view) = AgentConversationView.read(raw, agent: "codex", input: [:]), case .array(let rows)? = view["exchanges"], case .object(let first) = rows.first else { return [:] }
            return first
        }
        #expect(read(nil)["reply_state"] == .string("delivery_text_only"))
        #expect(read("Acknowledged")["text"] == .string("Acknowledged"))
        #expect(read("Acknowledged")["reply_state"] == .string("reply_received"))
    }
    @Test func codingReplyKeepsExactContinuationAndDoesNotPromoteAcknowledgement() throws {
        let raw: JSONValue = .object(["status": .string("ok"), "stores": .string("private paths"), "jobs": .array([
            .object(["id": .string("job"), "matched_message_id": .string("request"), "thread_id": .string("exact-old-thread"), "run_status": .string("completed"), "completion_text_head": .string("I’ll look into it."), "delivery_outcome": .string("delivered")])])])
        let input: [String: JSONValue] = ["agent": .string("codex"), "message_id": .string("request")]
        let result = AgentConversationView.read(raw, agent: "codex", input: input)
        guard case .object(let view) = result, case .array(let rows)? = view["exchanges"], case .object(let row) = rows.first else { Issue.record("Missing exchange"); return }
        #expect(view["stores"] == nil)
        #expect(row["text"] == .string("I’ll look into it."))
        #expect(row["reply_state"] == .string("reply_received"))
        #expect(row["text_kind"] == .string("retained_excerpt"))
        #expect(row["work_completion"] == .string("Not independently verified by this reader."))
        guard case .object(let action)? = row["reply_with"], case .object(let args)? = action["input"] else { Issue.record("Missing continuation"); return }
        #expect(args["conversation_id"] == .string("codex:exact-old-thread"))
        #expect(try AgentConversationRouting.route(tool: "agent_message", input: args)?.input["conversation_mode"] == .string("resume"))
        var detail = input; detail["details"] = .bool(true)
        #expect(AgentConversationView.read(raw, agent: "codex", input: detail) == raw)
    }

    @Test func missingEvidenceNeverInventsTextOrContinuation() {
        let raw: JSONValue = .object(["status": .string("partial"), "source_availability": .array([.string("unreadable")]), "jobs": .array([.object(["id": .string("job"), "state": .string("queued")])])])
        guard case .object(let view) = AgentConversationView.read(raw, agent: "claude", input: [:]), case .array(let rows)? = view["exchanges"], case .object(let row) = rows.first else { Issue.record("Missing exchange"); return }
        #expect(view["status"] == .string("partial"))
        #expect(view["source_availability"] != nil)
        #expect(row["text"] == nil)
        #expect(row["reply_with"] == nil)
        #expect(row["reply_state"] == .string("no_reply_observed"))
    }

    @Test func nativeReplyRetainsExactPagingAndUntrustedMarker() {
        let raw: JSONValue = .object(["status": .string("ok"), "untrusted_remote_data": .bool(true), "conversation_id": .string("session"), "message_id": .string("request"), "remote_evidence": .object(["reply": .string("Part one"), "has_more": .bool(true), "next_offset": .int(8000), "original_status": .string("ok")])])
        guard case .object(let view) = AgentConversationView.read(raw, agent: "peer:fixture", input: [:]), case .array(let rows)? = view["exchanges"], case .object(let row) = rows.first else { Issue.record("Missing exchange"); return }
        #expect(view["untrusted_remote_data"] == .bool(true))
        #expect(view["remote_evidence"] == nil)
        #expect(row["text"] == .string("Part one"))
        guard case .object(let action)? = row["read_more"], case .object(let args)? = action["input"] else { Issue.record("Missing paging"); return }
        #expect(args["offset"] == .int(8000))
        #expect(args["message_id"] == .string("request"))
        #expect(args["conversation_id"] == .string("session"))
    }

    @Test func detailFlagStaysOutsideExecutorAndMalformedFlagsFail() throws {
        let route = try AgentConversationRouting.route(tool: "agent_read", input: ["agent": .string("codex"), "details": .bool(true)])
        #expect(route?.input["details"] == nil)
        #expect(throws: AgentConversationRouting.InvalidRequest.self) {
            try AgentConversationRouting.route(tool: "agent_read", input: ["agent": .string("codex"), "details": .string("true")])
        }
    }
}
