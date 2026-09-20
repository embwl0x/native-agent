import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

@Test func resultPageArgumentsPreserveTheRequestedPage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    let turn = UUID().uuidString
    let store = ProviderToolResultRecoveryStore.shared
    let receipt = try #require(await store.store(
        content: String(repeating: "a", count: 8_000) + "second page",
        toolName: "read_file", sessionId: turn, turnId: turn))
    await TurnTraceContext.$turnId.withValue(turn) {
        let base: [String: JSONValue] = [
            "session_id": .string(turn), "result_handle": .string(receipt.handle), "raw": .bool(true),
        ]
        for value in [JSONValue.int(1), .double(1), .string(" 1 ")] {
            var input = base
            input["page"] = value
            guard case .object(let result) = await dispatcher.impl_tool_result_page(input: input) else {
                Issue.record("Missing page"); continue
            }
            #expect(result["page"] == .int(1))
            #expect(result["content"] == .string("second page"))
        }
        for value in [JSONValue.null, .string(" "), .bool(false)] {
            var input = base
            input["page"] = value
            guard case .object(let result) = await dispatcher.impl_tool_result_page(input: input) else {
                Issue.record("Missing default page"); continue
            }
            #expect(result["page"] == .int(0))
        }
        for value in [JSONValue.double(1.5), .int(-1), .string("next"), .bool(true)] {
            var input = base
            input["page"] = value
            guard case .object(let result) = await dispatcher.impl_tool_result_page(input: input) else {
                Issue.record("Missing correction"); continue
            }
            #expect(result["reason"] == .string("invalid_page"))
            #expect(result["recovery_hint"] != nil)
            #expect(result["content"] == nil)
        }
        var input = base
        input["raw"] = .bool(false)
        input["page"] = .int(999)
        guard case .object(let result) = await dispatcher.impl_tool_result_page(input: input) else {
            Issue.record("Missing range correction"); return
        }
        #expect(result["reason"] == .string("page_out_of_range"))
        #expect(result["recovery_hint"] != nil)
    }
    if let scope = ProviderToolResultRecoveryStore.Scope(sessionId: turn, turnId: turn) {
        await store.remove(scope: scope)
    }
}
