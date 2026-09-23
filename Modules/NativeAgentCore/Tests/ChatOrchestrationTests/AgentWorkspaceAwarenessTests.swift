import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Suite("Workspace continuity and awareness")
struct AgentWorkspaceAwarenessTests {
    private func object(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let row)? = value { return row }; return [:]
    }

    @Test func comparisonSurvivesRestartWithoutSavingContentAndFailureDoesNotAcknowledge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = "awareness-fixture"
        let location = AgentWorkspaceLocation.record(tool: "read_file", input: ["path": .string("/workspace/notes.md")], title: "Notes")
        let store = AgentWorkspaceDesktopStore(dataRoot: root, scope: scope)
        try store.save(.init(current: location, places: [location]))
        let first = try await AgentWorkspace.dispatch(input: [:], scope: scope, dataRoot: root,
            navigation: AgentWorkspaceNavigation(persistenceEnabled: true), perform: { _, _ in .string("Original private contents") })
        #expect(object(object(first)["changes"])["state"] == .string("first_seen"))
        let saved = try #require(try store.load())
        #expect(saved.observations.count == 1)
        #expect(!String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self).contains("Original private contents"))
        let denied = try await AgentWorkspace.dispatch(input: [:], scope: scope, dataRoot: root,
            navigation: AgentWorkspaceNavigation(persistenceEnabled: true), perform: { _, _ in .object(["status": .string("blocked")]) })
        #expect(object(object(denied)["changes"])["state"] == .string("unavailable"))
        #expect(try store.load()?.observations == saved.observations)
        let reopened = try await AgentWorkspace.dispatch(input: [:], scope: scope, dataRoot: root,
            navigation: AgentWorkspaceNavigation(persistenceEnabled: true), perform: { _, _ in .string("Revised private contents") })
        #expect(object(object(reopened)["changes"])["state"] == .string("changed"))
        let again = try await AgentWorkspace.dispatch(input: [:], scope: scope, dataRoot: root,
            navigation: AgentWorkspaceNavigation(persistenceEnabled: true), perform: { _, _ in .string("Revised private contents") })
        #expect(object(object(again)["changes"])["state"] == .string("unchanged"))
    }

    @Test func humanReplyBindsExactOpenedSessionAndLatestMessageOnly() throws {
        let input: [String: JSONValue] = ["conversation_session_id": .string("human-chat")]
        let result: JSONValue = .object(["status": .string("ok"), "conversation_session_id": .string("human-chat"),
            "last_message_id": .string("last-123"), "reply_available": .bool(true)])
        let projection = AgentWorkspaceHumanProjection.project(input: input, result: result)
        let reply = try #require(projection.actions.first { $0.label == "Reply" })
        guard case .perform(let tool, let args, _, let textField, let effect) = reply.action else {
            Issue.record("Reply did not bind an effect"); return
        }
        #expect(tool == "chat_reply" && textField == "text" && effect)
        #expect(args == ["conversation_session_id": .string("human-chat"), "last_message_id": .string("last-123")])
        let mismatched = AgentWorkspaceHumanProjection.project(input: ["conversation_session_id": .string("other-chat")], result: result)
        #expect(!mismatched.actions.contains { $0.label == "Reply" })
    }
}
