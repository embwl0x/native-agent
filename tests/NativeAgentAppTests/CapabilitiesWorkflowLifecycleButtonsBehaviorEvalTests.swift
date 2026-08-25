import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Capabilities.workflowLifecycleButtons

@Suite("app.settings · Capabilities workflow lifecycle buttons")
struct CapabilitiesWorkflowLifecycleButtonsBehaviorEvalTests {
    @Test("each button follows the shared durable lifecycle preflight")
    func lifecycleButtonsExposeOnlyTheCurrentRunTransition() {
        let waiting = run(status: "waiting_approval", approvalID: "approval-1")
        let resume = WorkflowLifecycleButtonPresentation.eligibility(
            action: .resume,
            run: waiting,
            approvalDecision: "approved",
            isPerforming: false
        )
        #expect(resume.isEligible)

        let waitingWithoutDecision = WorkflowLifecycleButtonPresentation.eligibility(
            action: .resume,
            run: waiting,
            approvalDecision: nil,
            isPerforming: false
        )
        #expect(!waitingWithoutDecision.isEligible)
        #expect(waitingWithoutDecision.detail.contains("approval decision"))

        let running = run(status: "running")
        #expect(WorkflowLifecycleButtonPresentation.eligibility(
            action: .cancel, run: running, approvalDecision: nil, isPerforming: false
        ).isEligible)
        #expect(!WorkflowLifecycleButtonPresentation.eligibility(
            action: .rollback, run: running, approvalDecision: nil, isPerforming: false
        ).isEligible)

        let canceled = run(status: "canceled")
        #expect(WorkflowLifecycleButtonPresentation.eligibility(
            action: .rollback, run: canceled, approvalDecision: nil, isPerforming: false
        ).isEligible)
    }

    @Test("an in-flight lifecycle action blocks every sibling control")
    func buttonsCannotRaceTheCurrentMutation() {
        let blocked = run(status: "blocked")
        for action in [WorkflowLifecycleAction.resume, .cancel, .rollback] {
            let eligibility = WorkflowLifecycleButtonPresentation.eligibility(
                action: action,
                run: blocked,
                approvalDecision: nil,
                isPerforming: true
            )
            #expect(!eligibility.isEligible)
            #expect(eligibility.detail == "Workflow lifecycle action is in progress.")
        }
    }

    @Test("visible receipts distinguish persisted, refused, unconfirmed, and failed outcomes")
    func lifecycleOutcomeNoticeDoesNotTreatUnconfirmedWritesAsSuccess() {
        #expect(WorkflowLifecycleButtonPresentation.notice(
            for: .cancel,
            outcome: .persisted(status: "canceled")
        ) == .init(detail: "Cancel persisted as canceled.", status: "ok"))
        #expect(WorkflowLifecycleButtonPresentation.notice(
            for: .resume,
            outcome: .unavailable(detail: "Workflow resume unavailable: approval is pending.")
        ).status == "warn")
        #expect(WorkflowLifecycleButtonPresentation.notice(
            for: .rollback,
            outcome: .unconfirmed(detail: "Workflow rollback outcome is not visible after reload.")
        ).status == "warn")
        #expect(WorkflowLifecycleButtonPresentation.notice(
            for: .resume,
            outcome: .failed(detail: "Workflow resume failed: registry unavailable")
        ).status == "failed")
    }

    private func run(status: String, approvalID: String? = nil) -> WorkflowRun {
        WorkflowRun(
            id: "run-1",
            workflowId: "workflow-1",
            workflowName: "Lifecycle eval",
            objective: "Exercise controls",
            status: status,
            mode: "run",
            engineVersion: "2",
            steps: [],
            createdAt: nil,
            completedAt: nil,
            currentStepIndex: nil,
            approvalId: approvalID
        )
    }
}
