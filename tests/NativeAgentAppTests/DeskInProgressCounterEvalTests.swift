import Foundation
import Testing
@testable import WorkshopExecution
@testable import NativeAgentApp

// Eval coverage — fence `app.desk`, ledger row `desk.counters.inProgress`.
// The headline must use the bench's rendered population and must preserve an
// unreadable execution lane as unknown instead of reassuringly displaying 0.

private func executionRecord(_ id: String, status: String) -> WorkshopExecution.WorkshopExecutionRecord {
    WorkshopExecutionRecord(
        id: id,
        title: "execution \(id)",
        objective: "o",
        createdAt: "2026-08-01T00:00:00.000000+00:00",
        status: status,
        plan: [],
        stepsCompleted: [],
        receiptsDir: "/tmp/receipt",
        triggerSource: "manual",
        trustRequired: "none",
        expectedOutputs: [],
        currentStepId: "",
        updatedAt: "2026-08-01T00:00:00.000000+00:00",
        result: .null,
        rerunCount: 0)
}

@Test("in-progress counter uses the rendered bench and never turns an unreadable lane into zero")
func inProgressCounterHonorsBenchAndUnavailableExecutionLane() {
    let executions = [
        executionRecord("running", status: "running"),
        executionRecord("unknown", status: "waiting_on_provider"),
        executionRecord("approval", status: "blocked_on_approval"),
        executionRecord("done", status: "completed"),
    ]
    let renderedBenchCount = DeskExecutionPresentation.slice(executions).benchIDs.count

    let healthy = DeskExecutionInProgressCount(
        executionsLane: .rows(executions),
        renderedBenchCount: renderedBenchCount)
    #expect(healthy.value == renderedBenchCount)
    #expect(healthy.value == 2)
    #expect(healthy.unavailableReason == nil)

    let unreadable = DeskExecutionInProgressCount(
        executionsLane: .unavailable("Couldn't read the executions store — permission denied"),
        renderedBenchCount: renderedBenchCount)
    #expect(unreadable.value == nil)
    #expect(unreadable.unavailableReason == "Couldn't read the executions store — permission denied")
}
