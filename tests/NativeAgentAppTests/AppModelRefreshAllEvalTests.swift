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

    @Test("refreshAll publishes fixture changes and preserves the last good inbox on corruption")
    func refreshAllPublishesAndRetainsRealFixtureState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appmodel-refresh-all-\(UUID().uuidString)", isDirectory: true)
        let inbox = root.appendingPathComponent("notifications/inbox.jsonl")
        try FileManager.default.createDirectory(
            at: inbox.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let card = """
        {"id":"refresh-card","created_at":"2026-08-26T12:00:00Z","source":"fixture","severity":"important","title":"Refresh fixture","summary":"published from the isolated root","actions":[],"status":"unread"}
        """
        try Data((card + "\n").utf8).write(to: inbox, options: .atomic)
        let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        await model.refreshAll()
        #expect(model.inboxItems.map(\.id) == ["refresh-card"])
        #expect(model.inboxItems.first?.title == "Refresh fixture")
        #expect(model.inboxItems.first?.summary == "published from the isolated root")

        let corruptBytes = Data("not a JSON inbox row\n".utf8)
        try corruptBytes.write(to: inbox, options: .atomic)
        await model.refreshAll()
        #expect(
            model.inboxItems.map(\.id) == ["refresh-card"],
            "a failed canonical inbox read must retain the last published projection"
        )
        let inboxFailure = try #require(
            model.refreshAllFailureDetails.first { $0.contains("getInboxItems:") }
        )
        #expect(inboxFailure.contains("bytes but no valid JSON rows"))
        #expect(model.lastRefreshError?.contains(inboxFailure) == true)
        #expect(try Data(contentsOf: inbox) == corruptBytes, "refresh must not rewrite corrupt authority bytes")

        try Data().write(to: inbox, options: .atomic)
        await model.refreshAll()
        #expect(model.inboxItems.isEmpty, "a successful empty read must publish an honest empty inbox")
        #expect(!model.refreshAllFailureDetails.contains { $0.contains("getInboxItems:") })
        #expect(model.lastRefreshError?.contains("getInboxItems:") != true)
    }

    private func beginPass(on model: AppModel) {
        model.refreshAllFailureDetails.removeAll(keepingCapacity: true)
        model.isRecordingRefreshAllFailures = true
        model.lastRefreshError = nil
    }
}
