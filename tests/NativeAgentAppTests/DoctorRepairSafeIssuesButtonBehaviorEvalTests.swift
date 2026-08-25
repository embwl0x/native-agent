import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Doctor.repairSafeIssuesButton

@Suite("app.settings · Doctor repair-safe-issues button")
struct DoctorRepairSafeIssuesButtonBehaviorEvalTests {
    @Test("the button stays disabled until a report explicitly offers an app-owned safe repair")
    func eligibilityDoesNotTreatHumanInstructionsAsSafeRepairTargets() {
        #expect(DoctorSafeRepairIssuesPresentation.state(report: nil, isRunning: false) == .needsDoctorReport)

        let report = DoctorReport(status: "warn", repaired: false, checks: [
            check("runtime_json_stores", status: "warn", repair: "Run Repair Safe Issues to create missing app-owned JSON stores."),
            check("live.providers", status: "warn", repair: "Open Providers and run Test Connection."),
            check("memory_store", status: "warn", repair: "Run MemoryV2 migration manually."),
        ])
        let state = DoctorSafeRepairIssuesPresentation.state(report: report, isRunning: false)

        #expect(state == .ready(.init(checkIDs: ["runtime_json_stores"])))
        #expect(state.canRun)
        #expect(state.detail.contains("1 reported app-owned issue") == true)
    }

    @Test("running and clean reports cannot start a second or vacuous repair")
    func adverseAndNoOpStatesRemainExplicit() {
        let clean = DoctorReport(status: "ok", repaired: false, checks: [
            check("storage", status: "ok", repair: nil),
        ])
        #expect(DoctorSafeRepairIssuesPresentation.state(report: clean, isRunning: false) == .noSafeIssues)
        #expect(!DoctorSafeRepairIssuesPresentation.state(report: clean, isRunning: false).canRun)
        #expect(DoctorSafeRepairIssuesPresentation.state(report: clean, isRunning: true) == .running)
    }

    @Test("the completed receipt distinguishes applied, partial, and non-applied repairs")
    func repairReceiptNeverClaimsSuccessFromAnInstructionOrFailedAttempt() {
        let applied = check("runtime_json_stores", status: "ok", repair: "Created providers/active.json.")
        let partial = check("chat_messages", status: "fail", repair: "Completed: reset one file.")
        let refused = check("coreml_embedder", status: "fail", repair: "Cannot repair: bundle resources are missing.")

        #expect(DoctorSafeRepairIssuesPresentation.appliedRepairCount(in: [applied, partial, refused]) == 2)

        let partialReport = DoctorReport(status: "fail", repaired: true, checks: [partial, refused])
        #expect(DoctorSafeRepairIssuesPresentation.completionMessage(report: partialReport)
            == "Doctor repair applied safe fixes, but 2 issues remain.")

        let noChangeReport = DoctorReport(status: "fail", repaired: false, checks: [refused])
        #expect(DoctorSafeRepairIssuesPresentation.completionMessage(report: noChangeReport)
            == "Doctor repair finished, but no safe fixes were applied.")
    }

    private func check(_ id: String, status: String, repair: String?) -> DoctorCheck {
        DoctorCheck(id: id, title: id, status: status, detail: "eval", repair: repair)
    }
}
