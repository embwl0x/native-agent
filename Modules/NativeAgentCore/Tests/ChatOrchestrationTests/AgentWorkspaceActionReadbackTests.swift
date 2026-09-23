import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

private actor WorkspaceBrowserReadbackFixture {
    var calls: [(String, [String: JSONValue])] = []
    let snapshots: [JSONValue]
    var index = 0
    init(_ snapshots: [JSONValue]) { self.snapshots = snapshots }
    func perform(_ tool: String, _ input: [String: JSONValue]) throws -> JSONValue {
        calls.append((tool, input))
        if tool == "browser.chrome_wait" { return .object(["outcome": .string("succeeded")]) }
        guard tool == "browser.chrome_snapshot", index < snapshots.count else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { index += 1 }
        return snapshots[index]
    }
    func history() -> [(String, [String: JSONValue])] { calls }
}

@Suite("Workspace automatic action readback")
struct AgentWorkspaceActionReadbackTests {
    private let acquired: JSONValue = .object(["state": .string("active"), "leaseId": .string("ours"), "tabId": .int(41), "userSequence": .int(7)])
    private func snapshot(lease: String = "ours", sequence: Int64 = 7, loading: Bool = false) -> JSONValue {
        .object(["snapshotId": .string(UUID().uuidString), "leaseId": .string(lease), "tabId": .int(41),
            "userSequence": .int(sequence), "title": .string("Search results"),
            "nodes": .array([]), "summary": .object(["text": .string("Observed research result")]),
            "rendering": .object(["readyState": .string(loading ? "loading" : "complete")])])
    }
    private func object(_ value: JSONValue) -> [String: JSONValue] { if case .object(let row) = value { return row }; return [:] }

    @Test func thrownBrowserActionReturnsFreshControlsWithoutReplayingEffect() async throws {
        let fixture = WorkspaceBrowserReadbackFixture([snapshot()])
        let input: [String: JSONValue] = ["lease_id": .string("ours"), "expected_user_sequence": .int(7)]
        let receipt = try await AgentWorkspaceActionReadback.dispatchEffect(tool: "browser.chrome_click", input: input,
            perform: { try await fixture.perform($0, $1) })
        #expect(object(receipt)["status"] == .string("outcome_unknown"))
        let fresh = try #require(try await AgentWorkspaceActionReadback.followUp(tool: "browser.chrome_click", input: input,
            receipt: receipt, title: "Selected page", perform: { try await fixture.perform($0, $1) }))
        #expect(object(fresh.result)["action_receipt"] == receipt)
        #expect(object(fresh.result)["snapshotId"] != nil)
        #expect(await fixture.history().map(\.0) == ["browser.chrome_click", "browser.chrome_snapshot"])
    }

    @Test func failedBrowserActionDoesNotBorrowATakenOverPage() async throws {
        let fixture = WorkspaceBrowserReadbackFixture([snapshot(sequence: 8)])
        let input: [String: JSONValue] = ["lease_id": .string("ours"), "expected_user_sequence": .int(7)]
        let receipt = try await AgentWorkspaceActionReadback.dispatchEffect(tool: "browser.chrome_click", input: input,
            perform: { try await fixture.perform($0, $1) })
        let fresh = try #require(try await AgentWorkspaceActionReadback.followUp(tool: "browser.chrome_click", input: input,
            receipt: receipt, title: "Selected page", perform: { try await fixture.perform($0, $1) }))
        #expect(object(fresh.result)["status"] == .string("readback_unavailable"))
        #expect(object(fresh.result)["snapshotId"] == nil)
        #expect(await fixture.history().map(\.0) == ["browser.chrome_click", "browser.chrome_snapshot"])
    }

    @Test func openingAWebsiteReturnsObservedPageAndKeepsReceipt() async throws {
        let observed = snapshot(), fixture = WorkspaceBrowserReadbackFixture([observed])
        let output = try #require(try await AgentWorkspaceActionReadback.followUp(tool: "browser.chrome_acquire",
            input: ["mode": .string("create"), "initial_url": .string("https://example.com")], receipt: acquired,
            title: "Research", perform: { try await fixture.perform($0, $1) }))
        guard case .record("browser.chrome_snapshot", let input, "Research") = output.location else {
            Issue.record("Expected the exact owned page"); return
        }
        #expect(input["lease_id"] == .string("ours"))
        #expect(object(output.result)["summary"] == object(observed)["summary"])
        #expect(object(output.result)["action_receipt"] == acquired)
        let calls = await fixture.history()
        #expect(calls.map(\.0) == ["browser.chrome_wait", "browser.chrome_snapshot"])
        #expect(calls.allSatisfy { $0.1["lease_id"] == .string("ours") })
    }

    @Test func loadingPageGetsOnlyOneBoundedAdditionalRead() async throws {
        let fixture = WorkspaceBrowserReadbackFixture([snapshot(loading: true), snapshot(loading: true)])
        let output = try #require(try await AgentWorkspaceActionReadback.followUp(tool: "browser.chrome_acquire",
            input: [:], receipt: acquired, title: "Research", perform: { try await fixture.perform($0, $1) }))
        let view = try #require(AgentWorkspaceApps.project(tool: "browser.chrome_snapshot", input: [:], result: output.result))
        #expect(object(view.content)["workspace_state"] == .string("loading"))
        #expect(await fixture.history().filter { $0.0 == "browser.chrome_snapshot" }.count == 2)
    }

    @Test(arguments: ["outcome_unknown", "failed", "partially_completed"])
    func uncertainActionIsNeverReadAsSuccessOrRetried(outcome: String) async throws {
        let fixture = WorkspaceBrowserReadbackFixture([])
        let output = try await AgentWorkspaceActionReadback.followUp(tool: "browser.chrome_click",
            input: ["lease_id": .string("ours")], receipt: .object(["outcome": .string(outcome)]),
            title: "Click", perform: { try await fixture.perform($0, $1) })
        #expect(output.map { _ in false } ?? true)
        #expect(await fixture.history().isEmpty)
    }

    @Test(arguments: ["foreign", "takeover", "missing"])
    func failedReadbackKeepsExactRecoveryAndNeverOffersForeignControls(failure: String) async throws {
        let rows: [JSONValue] = failure == "missing" ? [] : [snapshot(lease: failure == "foreign" ? "theirs" : "ours", sequence: failure == "takeover" ? 8 : 7)]
        let fixture = WorkspaceBrowserReadbackFixture(rows)
        let output = try #require(try await AgentWorkspaceActionReadback.followUp(tool: "browser.chrome_acquire",
            input: [:], receipt: acquired, title: "Research", perform: { try await fixture.perform($0, $1) }))
        #expect(object(output.result)["status"] == .string("readback_unavailable"))
        guard case .record(let tool, let input, _) = output.location else { Issue.record("Missing recovery"); return }
        let view = try #require(AgentWorkspaceApps.project(tool: tool, input: input, result: output.result))
        #expect(view.items.isEmpty)
        let action = try #require(view.actions.first)
        guard case .open(.record("browser.chrome_snapshot", let args, _)) = action.action else { Issue.record("Expected exact reader"); return }
        #expect(args["lease_id"] == .string("ours"))
        #expect(object(output.result)["action_receipt"] == acquired)
    }

    @Test func completedScrollReadsExactPageWithoutScrollingAgain() async throws {
        let fixture = WorkspaceBrowserReadbackFixture([snapshot()])
        let receipt: JSONValue = .object(["outcome": .string("succeeded"), "receipt": .object([
            "leaseId": .string("ours"), "userSequence": .int(7)])])
        _ = try await AgentWorkspaceActionReadback.followUp(tool: "browser.chrome_scroll",
            input: ["lease_id": .string("ours")], receipt: receipt, title: "Page down", perform: { try await fixture.perform($0, $1) })
        #expect(await fixture.history().map(\.0) == ["browser.chrome_snapshot"])
    }

    @Test func navigationBudgetExhaustionUsesAdvertisedMainContentWithoutIncreasingCaps() async throws {
        var full = object(snapshot())
        full["reading"] = .object(["scope": .string("page"), "mainContentAvailable": .bool(true)])
        full["summary"] = .object(["text": .string("Sidebar links"), "truncationReasons": .array([.string("node_limit")])])
        var main = object(snapshot())
        main["reading"] = .object(["scope": .string("main_content"), "mainContentAvailable": .bool(true)])
        main["summary"] = .object(["text": .string("Actual visible article")])
        let fixture = WorkspaceBrowserReadbackFixture([.object(full), .object(main)])
        let output = try #require(try await AgentWorkspaceActionReadback.followUp(tool: "browser.chrome_acquire",
            input: [:], receipt: acquired, title: "Article", perform: { try await fixture.perform($0, $1) }))
        #expect(object(output.result)["summary"] == main["summary"])
        guard case .record(let tool, let args, _) = output.location else { Issue.record("Missing main-content source"); return }
        #expect(args["scope"] == .string("main_content"))
        let calls = await fixture.history().filter { $0.0 == "browser.chrome_snapshot" }
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.1["max_nodes"] == .int(80) && $0.1["lease_id"] == .string("ours") })
        let projected = try #require(AgentWorkspaceApps.project(tool: tool, input: args, result: output.result))
        let whole = try #require(projected.actions.first { $0.label == "Read whole page" })
        guard case .open(.record(_, let wholeArgs, _)) = whole.action else { Issue.record("Expected whole-page reader"); return }
        #expect(wholeArgs["scope"] == .string("page"))
        #expect(wholeArgs["lease_id"] == .string("ours"))
    }

    @Test func computerActionReusesCanonicalObservedScreenWithoutAnotherAction() async throws {
        let fixture = WorkspaceBrowserReadbackFixture([])
        let receipt: JSONValue = .object(["ok": .bool(true), "text": .string("Messages opened. This is the fresh screen afterward.")])
        let output = try #require(try await AgentWorkspaceActionReadback.followUp(tool: "go", input: ["name": .string("Messages")],
            receipt: receipt, title: "Open Messages", perform: { try await fixture.perform($0, $1) }))
        guard case .record("screen", _, _) = output.location else { Issue.record("Expected computer"); return }
        #expect(object(output.result)["text"] == object(receipt)["text"])
        #expect(await fixture.history().isEmpty)
    }
}
