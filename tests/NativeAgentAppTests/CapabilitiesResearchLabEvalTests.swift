import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Capabilities.researchLab

@Suite("Capabilities Research Lab")
struct CapabilitiesResearchLabEvalTests {
    @Test("a completed persisted receipt reports its measured source outcome")
    func completedRunHasAnOutcomeRatherThanGenericSuccess() {
        let run = researchRun(status: "completed", sourceCount: 2)
        let message = CapabilitiesResearchLabPresentation.message(for: .recorded(run))

        #expect(message == .init(
            text: "Research run completed",
            detail: "2 sources recorded.",
            tone: .success,
            systemImage: "checkmark.circle.fill"
        ))
        #expect(CapabilitiesResearchLabPresentation.list(rows: [run]) == .loaded([run]))
    }

    @Test("connector refusal and action failure do not take the completed path")
    func adverseOutcomesRemainActionable() {
        let connectorBlocked = researchRun(
            status: "needs_connector",
            sourceCount: 0,
            error: "SearXNG base URL is not configured"
        )
        let connectorMessage = CapabilitiesResearchLabPresentation.message(for: .recorded(connectorBlocked))
        let failedMessage = CapabilitiesResearchLabPresentation.message(for: .failed("writer denied receipt"))
        let rejectedMessage = CapabilitiesResearchLabPresentation.message(for: .rejected("Enter an objective."))

        #expect(connectorMessage.text == "Research needs a connector")
        #expect(connectorMessage.tone == .warning)
        #expect(connectorMessage.detail?.contains("not configured") == true)
        #expect(failedMessage.text == "Research lab failed")
        #expect(failedMessage.tone == .failure)
        #expect(rejectedMessage.text == "Research objective required")
        #expect(rejectedMessage.tone == .warning)
    }

    @Test("empty receipt history and unreadable receipt history remain distinct")
    func listAvailabilityDoesNotBecomeAVacuousEmptyState() {
        let retained = researchRun(status: "completed", sourceCount: 0)
        let unavailable = CapabilitiesResearchLabPresentation.unavailableList(
            detail: "runs store was malformed",
            retained: [retained]
        )

        #expect(CapabilitiesResearchLabPresentation.list(rows: []) == .empty)
        #expect(unavailable == .unavailable(
            detail: "runs store was malformed",
            retained: [retained]
        ))
    }

    private func researchRun(
        status: String,
        sourceCount: Int,
        error: String? = nil
    ) -> ResearchLabRun {
        ResearchLabRun(
            id: "run-1",
            objective: "Verify a research boundary",
            status: status,
            query: "research boundary",
            sources: (0..<sourceCount).map { index in
                ResearchResult(
                    title: "Source \(index)",
                    url: "https://example.test/\(index)",
                    snippet: "Evidence \(index)",
                    source: "fixture"
                )
            },
            brief: nil,
            connector: status == "needs_connector" ? "none" : "searxng",
            error: error,
            createdAt: "2026-08-24T00:00:00Z"
        )
    }
}
