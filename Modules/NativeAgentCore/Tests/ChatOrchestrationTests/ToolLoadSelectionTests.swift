import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

@Suite struct ToolLoadSelectionTests {
    @Test func unloadingAliasRetractsTheLoadedToolInThisTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)
        let session = "alias-unload"
        let selection: [String: JSONValue] = [
            "session_id": .string(session), "names": .array([.string("workshop.status")]),
        ]
        _ = try await dispatcher.impl_tool_load(input: selection)
        #expect(await dispatcher.activeToolsStore.load(sessionId: session).activeTools == ["workshop_status"])
        try await LLMCallContext.$turnActiveTools.withValue(["workshop_status"]) {
            guard case .object(let result) = try await dispatcher.impl_tool_unload(input: selection) else {
                Issue.record("missing unload receipt"); return
            }
            #expect(result["dropped"] == .array([.string("workshop_status")]))
            #expect(await dispatcher.activeToolsStore.load(sessionId: session).activeTools.isEmpty)
            #expect(await dispatcher.activeToolsStore.turnUnloadedNames(sessionId: session) == ["workshop_status"])
            #expect(await dispatcher.lazyToolLoadingRefusal(
                tool: "workshop_status", input: ["__session_id": .string(session)]
            ) != nil)
            _ = try await dispatcher.impl_tool_load(input: selection)
            #expect(await dispatcher.lazyToolLoadingRefusal(
                tool: "workshop_status", input: ["__session_id": .string(session)]
            ) == nil)
        }
    }

    @Test func saveFailureDoesNotAskToUnloadTools() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "save-failure"
        let path = root.appendingPathComponent("chat/active_tools/\(session).json")
        // A directory at the save destination reliably refuses replacement,
        // including when the test process can bypass ordinary file permissions.
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        do {
            _ = try await dispatcher.impl_tool_load(input: [
                "session_id": .string(session), "names": .array([.string("workshop_status")]),
            ])
            Issue.record("A save failure must escape instead of reporting an offer limit")
        } catch {
            let failure = error as NSError
            #expect(failure.domain != "ActiveToolsStore" || failure.code != 4)
        }
        #expect(await dispatcher.activeToolsStore.load(sessionId: session).activeTools.isEmpty)
        #expect((try path.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
    }

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
