import Foundation
import Testing
import NativeAgentCore

@Suite struct AgentCommandContinuityTests {
    let id = "6a742ea9-2952-4bf5-b902-a7aa8a7c3272"

    @Test func codexResumesExactEmittedIdentityAndKeepsPromptWhole() throws {
        let line = try #require(AgentHostCommandLines.byHostID["codex"])
        let event = "{\"type\":\"thread.started\",\"thread_id\":\"\(id)\"}"
        #expect(line.capturedThreadID(stdout: event) == id)
        #expect(line.capturedThreadID(stdout: event, expected: id.uppercased()) == id)
        let prompt = "--last ; $(touch not-a-command)"
        let args = line.argv(message: prompt, session: id, resuming: true, replyFilePath: "/tmp/reply.txt")
        #expect(Array(args.prefix(2)) == ["exec", "resume"])
        #expect(Array(args.suffix(3)) == ["--", id, prompt])
        #expect(args.contains("--json"))
        #expect(!args.contains("--last"))
        let first = line.argv(message: prompt, session: nil, resuming: false, replyFilePath: "/tmp/reply.txt")
        #expect(!first.contains("resume"))
        #expect(first.last == prompt)
    }

    @Test func missingMalformedConflictingAndWrongResumeIdentitiesStayUnverified() throws {
        let line = try #require(AgentHostCommandLines.byHostID["codex"])
        let event = "{\"type\":\"thread.started\",\"thread_id\":\"\(id)\"}"
        let other = "{\"type\":\"thread.started\",\"thread_id\":\"2da35c6f-0bfb-4d3f-9b51-34e6e9f794de\"}"
        #expect(line.capturedThreadID(stdout: "resume \(id)") == nil)
        #expect(line.capturedThreadID(stdout: "{\"type\":\"item.completed\",\"thread_id\":\"\(id)\"}") == nil)
        #expect(line.capturedThreadID(stdout: "{\"type\":\"thread.started\",\"thread_id\":\"not-a-uuid\"}") == nil)
        #expect(line.capturedThreadID(stdout: event + "\n" + other) == nil)
        #expect(line.capturedThreadID(stdout: other, expected: id) == nil)
        #expect(line.capturedThreadID(stdout: event + "\n{truncated") == id)
    }

    @Test func claudeRetainsItsCallerAssignedSessionContract() throws {
        let line = try #require(AgentHostCommandLines.byHostID["claude-code"])
        #expect(!line.capturesThreadID)
        #expect(line.argv(message: "hello", session: id, resuming: false, replyFilePath: nil)
            == ["-p", "--session-id", id, "--", "hello"])
        #expect(line.argv(message: "again", session: id, resuming: true, replyFilePath: nil)
            == ["-p", "--resume", id, "--", "again"])
    }
}
