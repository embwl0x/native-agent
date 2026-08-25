import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.ProviderSettings.anthropicMCPStatusPanel
@Suite("Anthropic MCP status panel", .serialized)
struct AnthropicMCPStatusPanelEvalTests {
    @Test("the persistent-MCP claim requires a real Claude CLI presence probe")
    func availableClaudeCLIEnablesTheClaim() {
        let availability = AnthropicMCPCLIProbe.probe(
            environment: ["PATH": "/usr/local/bin:/usr/bin"],
            isExecutable: { $0 == "/usr/local/bin/claude" }
        )
        #expect(availability == .available(path: "/usr/local/bin/claude"))

        let presentation = AnthropicMCPStatusPresentation.make(
            availability: availability,
            userInfo: [
                "version": "2.1.0",
                "mode": "mcp_server",
                "mcp_process_alive": "true",
            ]
        )
        #expect(presentation.headline == "Persistent connection via Claude CLI")
        #expect(presentation.cliBadge == "Claude CLI available")
        #expect(presentation.mode == "MCP server")
        #expect(presentation.processStatus == .alive)
    }

    @Test("missing or malformed PATH never leaks a stale persistent-MCP claim")
    func unavailableAndMalformedClaudeCLIStateStayHonest() {
        let missing = AnthropicMCPCLIProbe.probe(
            environment: ["PATH": "/usr/local/bin:/usr/bin"],
            isExecutable: { _ in false }
        )
        let missingPresentation = AnthropicMCPStatusPresentation.make(
            availability: missing,
            userInfo: ["mcp_process_alive": "true", "mode": "mcp_server"]
        )
        #expect(missingPresentation.headline == nil)
        #expect(missingPresentation.cliBadge == "Claude CLI unavailable")
        #expect(missingPresentation.processStatus == nil)
        #expect(missingPresentation.detail?.contains("not found on PATH") == true)

        let stoppedPresentation = AnthropicMCPStatusPresentation.make(
            availability: .available(path: "/usr/local/bin/claude"),
            userInfo: ["mcp_process_alive": "false", "mode": "mcp_server"]
        )
        #expect(stoppedPresentation.headline == nil)
        #expect(stoppedPresentation.processStatus == .notRunning)
        #expect(stoppedPresentation.detail?.contains("no persistent MCP process") == true)

        let malformed = AnthropicMCPCLIProbe.probe(
            environment: ["PATH": "relative/bin::also-relative"],
            isExecutable: { _ in true }
        )
        let malformedPresentation = AnthropicMCPStatusPresentation.make(
            availability: malformed,
            userInfo: nil
        )
        #expect(malformedPresentation.headline == nil)
        #expect(malformedPresentation.detail?.contains("no absolute directories") == true)
    }
}
