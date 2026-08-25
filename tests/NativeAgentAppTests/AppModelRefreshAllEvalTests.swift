import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / appmodel.refreshAll
@MainActor
@Suite("AppModel refresh-all failure projection", .serialized)
struct AppModelRefreshAllEvalTests {
    private struct LaneFailure: Error, LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    @Test("failed lanes retain prior values, successful empties apply, and every failure remains surfaced")
    func refreshFailureProjectionPreservesTruthAcrossPasses() async throws {
        let model = AppModel(dataRootOverride: FileManager.default.temporaryDirectory, startBackgroundTasks: false)
        beginPass(on: model)

        let priorRuns = ["confirmed-run"]
        let retainedRuns = await model.refreshPreserving("getRuns", current: priorRuns) {
            throw LaneFailure(detail: "runs ledger unreadable")
        }
        let emptySkills = await model.refreshPreserving("getSkills", current: ["old-skill"]) {
            [String]()
        }
        let retainedTools = await model.refreshPreserving("getTools", current: ["confirmed-tool"]) {
            throw LaneFailure(detail: "tool registry unreadable")
        }

        #expect(retainedRuns == priorRuns)
        #expect(emptySkills.isEmpty, "a successful empty response must remain an honest empty state")
        #expect(retainedTools == ["confirmed-tool"])
        let firstPassError = try #require(model.lastRefreshError)
        #expect(firstPassError.contains("getRuns: runs ledger unreadable"))
        #expect(firstPassError.contains("getTools: tool registry unreadable"))
        #expect(!firstPassError.contains("getSkills"))

        // The next pass starts with no stale error. A genuinely empty success
        // is therefore distinguishable from the previous pass's failures.
        beginPass(on: model)
        let secondPassEmpty = await model.refreshPreserving("getRuns", current: priorRuns) {
            [String]()
        }
        #expect(secondPassEmpty.isEmpty)
        #expect(model.lastRefreshError == nil)
    }

    private func beginPass(on model: AppModel) {
        model.refreshAllFailureDetails.removeAll(keepingCapacity: true)
        model.isRecordingRefreshAllFailures = true
        model.lastRefreshError = nil
    }
}
