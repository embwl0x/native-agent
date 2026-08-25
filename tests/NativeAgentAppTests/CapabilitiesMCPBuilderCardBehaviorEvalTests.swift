import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Capabilities.mcpBuilderCard
@Suite("Capabilities MCP Builder card behavior")
struct CapabilitiesMCPBuilderCardBehaviorEvalTests {
    @Test("the MCP Builder does not call an unread registry empty")
    func registryStateDistinguishesLoadingEmptyAndUnavailable() {
        let loading = CapabilityMCPBuilderPresentation.resolve(
            serverCount: 0,
            sessionCount: 0,
            consentCount: 0,
            sessionErrorCount: 0,
            hasRefreshAttempt: false,
            failedEndpoints: []
        )
        #expect(loading.servers == .loading)
        #expect(loading.serverEmptyCopy == "MCP servers have not loaded yet.")

        let empty = CapabilityMCPBuilderPresentation.resolve(
            serverCount: 0,
            sessionCount: 0,
            consentCount: 0,
            sessionErrorCount: 0,
            hasRefreshAttempt: true,
            failedEndpoints: []
        )
        #expect(empty.servers == .empty)
        #expect(empty.serverEmptyCopy == "No MCP servers configured.")
        #expect(empty.collapsedAttentionBadge == nil)

        let unavailable = CapabilityMCPBuilderPresentation.resolve(
            serverCount: 0,
            sessionCount: 0,
            consentCount: 0,
            sessionErrorCount: 0,
            hasRefreshAttempt: true,
            failedEndpoints: [" mcp servers "]
        )
        #expect(unavailable.servers == .unavailable)
        #expect(unavailable.serverEmptyCopy == "MCP server registry is unavailable. Refresh Capabilities to try again.")
        #expect(unavailable.collapsedAttentionBadge == "MCP unavailable")
    }

    @Test("session failure and stale evidence remain visible while the card is collapsed")
    func sessionAndConsentAdversitySurvivesDisclosureCollapse() {
        let stale = CapabilityMCPBuilderPresentation.resolve(
            serverCount: 1,
            sessionCount: 1,
            consentCount: 2,
            sessionErrorCount: 0,
            hasRefreshAttempt: true,
            failedEndpoints: ["mcp sessions", "mcp consent"]
        )
        #expect(stale.sessions == .stale)
        #expect(stale.consents == .stale)
        #expect(stale.collapsedAttentionBadge == "MCP stale")
        #expect(stale.detailNotice == "Some MCP session or consent details are from the last successful refresh.")

        let sessionError = CapabilityMCPBuilderPresentation.resolve(
            serverCount: 1,
            sessionCount: 1,
            consentCount: 0,
            sessionErrorCount: 2,
            hasRefreshAttempt: true,
            failedEndpoints: []
        )
        #expect(sessionError.collapsedAttentionBadge == "2 errors")
    }
}
