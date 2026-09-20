import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

@Suite struct ConnectorFirstCallTests {
    @Test func disconnectedNotionParksOnlyNotionCalls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)
        let input: [String: JSONValue] = ["__session_id": .string("connector-first-call")]
        try await dispatcher.activeToolsStore.addLoaded(sessionId: "connector-first-call", names: ["notion_status", "notion_search", "gmail_status"])
        let slots = await SwiftNativeTurnEngine.runIterationDispatchGroups(
            prepared: ["notion_status", "time_now", "notion_status", "notion_search", "gmail_status"].enumerated().map {
                .init(pairedId: String($0.offset), internalName: $0.element, dispatchInput: input)
            }, modelId: "fixture", surface: "chat", tools: dispatcher, progress: nil,
            onToolUse: { _ in }, onOutcome: { _, _, _ in })
        #expect(slots.count == 5)
        guard case .object(let first) = slots[0].result else { Issue.record("Missing result"); return }
        #expect(first["status"] == .string("needs_input"))
        #expect(first["connected"] == .bool(false))
        #expect(!slots[0].isError)
        #expect(slots.filter { InlineInteractionNeed.interaction(in: $0.result)?.target == "notion" }.count == 1)
        #expect(!slots[1].isError)
        if case .object(let clock) = slots[1].result {
            #expect(clock["status"] != .string("skipped"))
        } else { Issue.record("Missing time result") }
        #expect(InlineInteractionNeed.interaction(in: slots[4].result)?.target == "gmail")
        for slot in slots[2...3] {
            guard case .object(let object) = slot.result else { Issue.record("Missing skipped result"); continue }
            #expect(object["status"] == .string("skipped"))
        }
        let state = await dispatcher.activeToolsStore.load(sessionId: "connector-first-call")
        #expect(state.activeTools.contains("notion_status"))
        #expect(state.activeTools.contains("notion_search"))
    }

}
