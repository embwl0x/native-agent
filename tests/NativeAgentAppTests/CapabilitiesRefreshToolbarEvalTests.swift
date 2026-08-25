import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Capabilities.refreshToolbar
@Suite("Capabilities refresh toolbar", .serialized)
struct CapabilitiesRefreshToolbarEvalTests {
    private func refreshStatus(_ failures: [String] = []) -> AppModel.PanelRefreshStatus {
        let now = Date(timeIntervalSince1970: 1_724_500_000)
        return AppModel.PanelRefreshStatus(
            lastAttemptAt: now,
            lastSuccessAt: failures.isEmpty ? now : nil,
            failedEndpoints: failures
        )
    }

    @Test("summary tiles never use zero as the un-loaded state")
    func summaryTilesMakeLoadingAndFailedReadsExplicit() {
        let initial = CapabilitiesRefreshPresentation.summary(
            capabilityCount: nil,
            workflowCount: 0,
            mcpCount: 0,
            nextGenReadyCount: 0,
            nextGenTotalCount: 0,
            approvalCount: 0,
            refresh: nil
        )
        #expect([initial.capabilities, initial.workflows, initial.mcp, initial.nextGen, initial.approvals]
            == ["—", "—", "—", "—", "—"])
        #expect(initial.notice == "Capability summary is loading.")

        let complete = CapabilitiesRefreshPresentation.summary(
            capabilityCount: 4,
            workflowCount: 2,
            mcpCount: 1,
            nextGenReadyCount: 3,
            nextGenTotalCount: 5,
            approvalCount: 6,
            refresh: refreshStatus()
        )
        #expect([complete.capabilities, complete.workflows, complete.mcp, complete.nextGen, complete.approvals]
            == ["4", "2", "1", "3/5", "6"])
        #expect(complete.notice == nil)

        let partial = CapabilitiesRefreshPresentation.summary(
            capabilityCount: nil,
            workflowCount: 2,
            mcpCount: 0,
            nextGenReadyCount: 0,
            nextGenTotalCount: 0,
            approvalCount: 0,
            refresh: refreshStatus(["capability summary", "mcp servers", "approvals"])
        )
        #expect(partial.capabilities == "—")
        #expect(partial.workflows == "2")
        #expect(partial.mcp == "—")
        #expect(partial.approvals == "—")
        #expect(partial.notice?.contains("marked —") == true)
    }

    @Test("the mounted Capabilities refresh path records a completed outcome on first navigation")
    @MainActor
    func firstNavigationRunsTheScopedRefresh() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capabilities-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await model.refreshForSidebarItem(.capabilities)
        let status = try #require(model.panelRefreshStatus[.capabilities])
        let tiles = CapabilitiesRefreshPresentation.summary(
            capabilityCount: model.capabilitySummary?.summary.total,
            workflowCount: model.workflows.count,
            mcpCount: model.mcpServers.count,
            nextGenReadyCount: model.nextGenPhases.filter { $0.status == "ready" }.count,
            nextGenTotalCount: model.nextGenPhases.count,
            approvalCount: model.approvals.filter { $0.status.lowercased() == "pending" }.count,
            refresh: status
        )
        #expect(tiles.notice != "Capability summary is loading.")
        #expect(tiles.capabilities != "0" || !status.failedEndpoints.contains("capability summary"))
    }
}
