import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Doctor.reportFooter
@Suite("Doctor report footer behavior")
struct DoctorReportFooterBehaviorEvalTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("the footer reports fresh check evidence using check-level severity")
    func freshReportUsesTheActualCheckRollup() {
        let state = DoctorReportFooterPresentation.resolve(
            report: report([check("storage", "ok"), check("telegram", "warn")]),
            completedAt: now.addingTimeInterval(-30),
            isRunning: false,
            now: now
        )
        #expect(state?.title == "Doctor report completed 30 seconds ago")
        #expect(state?.detail.contains("2 areas checked") == true)
        #expect(state?.status == "warn")
    }

    @Test("in-flight, missing, stale, and future timestamps cannot look current")
    func adverseFreshnessStatesRemainExplicit() {
        let current = report([check("storage", "ok")])

        let running = DoctorReportFooterPresentation.resolve(
            report: current,
            completedAt: now.addingTimeInterval(-10),
            isRunning: true,
            now: now
        )
        #expect(running?.title == "Refreshing Doctor report")
        #expect(running?.detail.contains("not current") == true)

        let missing = DoctorReportFooterPresentation.resolve(
            report: current,
            completedAt: nil,
            isRunning: false,
            now: now
        )
        #expect(missing?.title == "Doctor report time unavailable")

        let stale = DoctorReportFooterPresentation.resolve(
            report: current,
            completedAt: now.addingTimeInterval(-AppModel.supportSnapshotDoctorReuseTTL - 1),
            isRunning: false,
            now: now
        )
        #expect(stale?.title.contains("older") == true)
        #expect(stale?.status == "warn")

        let future = DoctorReportFooterPresentation.resolve(
            report: current,
            completedAt: now.addingTimeInterval(DoctorReportFooterPresentation.maximumClockSkew + 1),
            isRunning: false,
            now: now
        )
        #expect(future?.title == "Doctor report time is invalid")
    }

    private func report(_ checks: [DoctorCheck]) -> DoctorReport {
        DoctorReport(status: "ok", repaired: false, checks: checks)
    }

    private func check(_ id: String, _ status: String) -> DoctorCheck {
        DoctorCheck(id: id, title: id, status: status, detail: "fixture", repair: nil)
    }
}
