import Testing
@testable import WorkshopExecution

@Test func workshopExecutionDefaultsKeepExternalSendsApprovalGatedAndReadsAutomatic() {
    for tool in ["slack.post_message", "agentmail.send"] {
        #expect(DefaultToolAutonomy.resolve(toolId: tool) == "send_approval")
        #expect(DefaultToolAutonomy.needsApproval(DefaultToolAutonomy.resolve(toolId: tool)))
    }
    for tool in [
        "slack.status", "slack.list_channels", "slack.search_messages", "slack.list_unreads",
        "agentmail.list_inbox", "agentmail.read", "agentmail.search",
    ] {
        #expect(DefaultToolAutonomy.resolve(toolId: tool) == "auto")
        #expect(!DefaultToolAutonomy.needsApproval(DefaultToolAutonomy.resolve(toolId: tool)))
    }
}
