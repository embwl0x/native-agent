import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Slack runtime state")
struct SlackRuntimeStateEvalTests {
    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("slack-runtime-state-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("real state patches merge through the canonical Slack state path")
    func patchesMergeAndPersist() async throws {
        let dataRoot = try root("merge")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(await SlackRuntimeStateStore.apply(
            ["connected": .bool(true), "connectedAt": .string("2026-08-24T12:00:00Z")],
            dataRoot: dataRoot,
            now: now
        ) == .stored)
        #expect(await SlackRuntimeStateStore.apply(
            ["lastError": .string("network unavailable")],
            dataRoot: dataRoot,
            now: now
        ) == .stored)

        let bytes = try Data(contentsOf: SlackRuntimeStateStore.path(dataRoot: dataRoot))
        let value = try JSONValue.parse(bytes)
        guard case .object(let state) = value else {
            Issue.record("Slack state must be a JSON object")
            return
        }
        #expect(state["connected"] == .bool(true))
        #expect(state["connectedAt"] == .string("2026-08-24T12:00:00Z"))
        #expect(state["lastError"] == .string("network unavailable"))

        guard case .current(let feed) = SlackRuntimeStateFeed.read(dataRoot: dataRoot, now: now) else {
            Issue.record("the root-scoped Slack runtime state was not readable from its canonical path")
            return
        }
        #expect(feed.connected)
        #expect(feed.hasReportedError)
    }

    @Test("malformed existing state is preserved and reported unavailable")
    func malformedStateIsNotReplaced() async throws {
        let dataRoot = try root("malformed")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let statePath = SlackRuntimeStateStore.path(dataRoot: dataRoot)
        try FileManager.default.createDirectory(at: statePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{broken state".utf8)
        try original.write(to: statePath, options: .atomic)

        let outcome = await SlackRuntimeStateStore.apply(["connected": .bool(false)], dataRoot: dataRoot)

        #expect(outcome == .unavailableMalformedExistingState)
        #expect(try Data(contentsOf: statePath) == original)
    }

    @Test("a blocked Slack state directory reports write failure")
    func blockedStatePathIsUnavailable() async throws {
        let dataRoot = try root("blocked")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let blocker = dataRoot.appendingPathComponent("slack")
        try Data("not a directory".utf8).write(to: blocker, options: .atomic)

        let outcome = await SlackRuntimeStateStore.apply(["connected": .bool(false)], dataRoot: dataRoot)

        #expect(outcome == .unavailableWriteFailure)
        #expect(try Data(contentsOf: blocker) == Data("not a directory".utf8))
    }
}
