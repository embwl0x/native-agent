import Foundation
import Testing
import NativeAgentCore
@testable import ChatOrchestration

@Suite struct AntigravityCommandTests {
    let id = "055a398f-db14-4c5f-abbb-1bf03f8120a7"

    @Test func distinctHostUsesDocumentedMCPAndExactConversation() throws {
        let host = try #require(AgentHostDirectory.row(named: "agy"))
        #expect(host.id == "antigravity-cli")
        #expect(host.configPath == "~/.gemini/config/mcp_config.json")
        #expect(host.format == .jsonMCPServers)
        #expect(host.acp == nil)
        #expect(AgentHostDirectory.row(named: "gemini")?.id == "antigravity-cli")
        #expect(AgentHostDirectory.row(named: "Gemini CLI")?.id == "gemini-cli")
        #expect(AgentHostDirectory.row(named: "gemini-cli")?.displayName == "Gemini CLI (Legacy)")
        let line = try #require(host.commandLine)
        #expect(!line.automaticMCPProbe)
        #expect(AgentHostCommandLines.byHostID["codex"]?.automaticMCPProbe == true)
        #expect(AgentHostCommandLines.byHostID["claude-code"]?.automaticMCPProbe == true)
        let prompt = "--continue ; $(touch nope)\n/model"
        let arguments = line.argv(message: prompt, session: id, resuming: true, replyFilePath: nil)
        #expect(arguments.suffix(3) == ["--conversation", id, "--print=" + prompt])
        #expect(arguments.contains("--sandbox"))
        #expect(arguments.contains("--disable-slash-commands"))
        #expect(!arguments.contains("--dangerously-skip-permissions"))
        #expect(!arguments.contains("--continue"))
        let first = line.argv(message: prompt, session: nil, resuming: false, replyFilePath: nil)
        #expect(!first.contains("--conversation"))
    }

    @Test func replyAndIdentityComeOnlyFromCompleteDocumentedEnvelope() throws {
        let line = try #require(AgentHostCommandLines.byHostID["antigravity-cli"])
        let result = "{\"conversation_id\":\"\(id)\",\"status\":\"SUCCESS\",\"response\":\"hello\"}"
        #expect(line.resultReply(stdout: result) == "hello")
        #expect(line.capturedThreadID(stdout: result, expected: id) == id)
        #expect(line.capturedThreadID(stdout: result, expected: UUID().uuidString) == nil)
        #expect(line.capturedThreadID(stdout: "{\"conversation_id\":\"guess\"}") == nil)
        #expect(line.resultReply(stdout: result + "\n" + result) == nil)
        #expect(line.resultReply(stdout: "{\"status\":\"ERROR\",\"response\":\"not a completed reply\"}") == nil)
        #expect(line.resultReply(stdout: "{\"status\":\"SUCCESS\",\"response\":12}") == nil)
    }
}
