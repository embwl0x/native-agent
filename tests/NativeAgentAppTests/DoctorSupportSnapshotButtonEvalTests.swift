import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("app.settings · Doctor support snapshot button", .serialized)
struct DoctorSupportSnapshotButtonEvalTests {
    @Test("the Support Snapshot presenter reports unavailable, failed, and warning outcomes honestly")
    func supportSnapshotOutcomePresentation() {
        let unavailable = DoctorSupportSnapshotPresentation.notice(
            for: .unavailable("Doctor is currently running.")
        )
        #expect(unavailable.status == "warn")
        #expect(unavailable.detail.contains("unavailable"))

        let failed = DoctorSupportSnapshotPresentation.notice(
            for: .failed("isolated diagnostics store is unreadable")
        )
        #expect(failed.status == "failed")
        #expect(failed.detail.contains("failed"))

        let warning = DoctorSupportSnapshotPresentation.notice(
            for: .loaded(
                SupportDiagnostics(app: "NativeAgent", version: "test", doctorStatus: "warn", generatedAt: "2026-08-24T00:00:00Z"),
                reusedDoctorReport: true
            )
        )
        #expect(warning.status == "warn")
        #expect(warning.detail.contains("recent Doctor report"))
    }

    @Test("the real support snapshot uses the injected root and clears its loading state")
    func supportSnapshotUsesInjectedRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-support-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        let outcome = await app.loadSupportDiagnostics()
        guard case let .loaded(diagnostics, reusedDoctorReport) = outcome else {
            Issue.record("the real Support Snapshot did not produce diagnostics: \(outcome)")
            return
        }
        #expect(app.supportDiagnostics == diagnostics)
        #expect(!reusedDoctorReport)
        #expect(!app.supportDiagnosticsLoading)

        app.doctorRunning = true
        let unavailable = await app.loadSupportDiagnostics()
        #expect(unavailable == .unavailable("Doctor is currently running. Wait for it to finish before preparing a Support Snapshot."))
        #expect(!app.supportDiagnosticsLoading)
    }

}
