import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("app.settings · Doctor run button", .serialized)
struct DoctorRunDoctorButtonEvalTests {
    @Test("the Doctor action presenter reports unavailable and failing outcomes honestly")
    func runButtonOutcomePresentation() {
        let unavailable = DoctorRunButtonPresentation.notice(
            for: .unavailable("isolated Doctor store is unreadable"), repair: false
        )
        #expect(unavailable.status == "failed")
        #expect(unavailable.detail.contains("could not run"))

        let failed = DoctorRunButtonPresentation.notice(
            for: .completed(
                status: "fail",
                failingChecks: [DoctorCheck(id: "runtime.store", title: "Runtime store", status: "fail", detail: "missing", repair: nil)]
            ),
            repair: false
        )
        #expect(failed.status == "failed")
        #expect(failed.detail.contains("1 check is still failing"))
    }

    @Test("the real AppModel Doctor action writes an isolated report and clears its in-flight state")
    func runDoctorUsesTheInjectedRootAndReturnsAReport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-run-button-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        let outcome = await app.runDoctor(repair: false)
        guard case let .completed(status, failingChecks) = outcome else {
            Issue.record("the real Doctor action did not return a report: \(outcome)")
            return
        }
        #expect(app.doctorReport?.status == status)
        #expect(app.doctorReportCompletedAt != nil)
        #expect(!app.doctorRunning)
        #expect(failingChecks == (app.doctorReport?.checks.filter {
            ["fail", "error"].contains($0.status.lowercased())
        } ?? []))
    }

}
