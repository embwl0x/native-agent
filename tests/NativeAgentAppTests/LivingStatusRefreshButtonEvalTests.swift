import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.livingStatus.button.refresh

@MainActor
@Suite("Living Status manual refresh")
struct LivingStatusRefreshButtonEvalTests {
    @Test("a failed approvals read retains the previous snapshot and publishes an unavailable receipt")
    func failedManualRefreshIsVisibleAndDoesNotReplaceTheLastSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("living-status-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let retained = LivingStatusSnapshot(
            enabled: false,
            posture: "Quiet",
            postureStatus: "ok",
            bodyState: "body kernel off",
            behaviorLine: "behavior posture off",
            homeLine: "NativeAgent is quiet.",
            whyLine: "No action needed.",
            carryLine: "carrying no organism state",
            innerLine: "steady",
            deskSummary: "no desk items",
            approvalsSummary: "no approvals pending",
            lastDreamSummary: "no dreams yet",
            needsText: "needs nothing",
            showsOrganismDetails: false
        )

        enum ApprovalReadFailure: Error { case unreadable }
        let outcome = await LivingStatusRefreshOperation.run(
            appModel: app,
            dataRoot: root,
            approvalsOverride: { throw ApprovalReadFailure.unreadable }
        )
        let status = outcome.status(previous: nil, at: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(outcome.snapshot?.homeLine == nil)
        #expect(outcome.failedEndpoints.contains("Approvals"))
        #expect(outcome.applying(to: retained) == retained)
        #expect(status.isStale)
        #expect(status.failedEndpoints.contains("Approvals"))
        #expect(LivingStatusRefreshPresentation.resolve(
            hasSnapshot: false,
            status: status
        ) == .unavailable)
        #expect(LivingStatusRefreshPresentation.resolve(
            hasSnapshot: false,
            status: status
        ).adverseMessage?.contains("Refresh couldn't complete") == true)
    }

    @Test("a partial manual refresh with a retained snapshot is labelled as retained, not current")
    func retainedSnapshotGetsAStaleReceipt() {
        let status = AppModel.nextRefreshStatus(
            previous: nil,
            failedEndpoints: ["Approvals"],
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let presentation = LivingStatusRefreshPresentation.resolve(
            hasSnapshot: true,
            status: status
        )
        #expect(presentation == .retainedFailure)
        #expect(presentation.adverseMessage == "Refresh couldn't complete — showing the last known state.")
    }
}
