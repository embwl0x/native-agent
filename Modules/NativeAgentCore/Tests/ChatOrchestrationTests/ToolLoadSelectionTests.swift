import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

@Suite struct ToolLoadSelectionTests {
    @Test(arguments: [false, true])
    func unknownNamesNeverReportSuccess(mixed: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let session = UUID().uuidString
        let names = ["nonexistent_ax_probe"] + (mixed ? ["market_status"] : [])
        guard case .object(let result) = try await dispatcher.impl_tool_load(input: [
            "session_id": .string(session), "names": .array(names.map(JSONValue.string)),
        ]) else { Issue.record("missing receipt"); return }
        #expect(result["status"] == .string(mixed ? "partial" : "unavailable"))
        #expect(result["unavailable"] == .array([.string("nonexistent_ax_probe")]))
        let state = await dispatcher.activeToolsStore.load(sessionId: session)
        #expect(state.activeTools == Set(mixed ? ["market_status"] : []))
        let schemas = try await dispatcher.listAvailableToolSchemas(activeTools: state.activeTools)
        #expect(schemas.contains { $0.name == "market_status" } == mixed)
    }

    @Test func emptySelectionHasExactRecoveryHint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        guard case .object(let result) = try await dispatcher.impl_tool_load(input: ["session_id": .string("empty")]) else {
            Issue.record("missing receipt"); return
        }
        #expect(result["status"] == .string("failed"))
        #expect(result["reason"] == .string("missing_tool_selection"))
    }

    @Test func sessionlessCategoryIsOnlyAPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        guard case .object(let result) = try await dispatcher.impl_tool_load(input: ["category": .string("memory")]) else {
            Issue.record("missing receipt"); return
        }
        #expect(result["status"] == .string("preview"))
        #expect(result["loaded"] == .array([]))
        #expect(result["reason"] == .string("missing_session_id"))
    }
}
