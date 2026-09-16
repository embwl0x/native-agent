import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Test func agentExperienceRawTextRecoveryPreservesTypedOutcomeAndAllContent() async throws {
    let turn = UUID().uuidString
    let content = String(repeating: "a", count: 35_000) + "RECOVER_THIS_MARKER" + String(repeating: "z", count: 5_000)
    let projected = await ProviderToolResultProjection.project(toolName: "read_file",
        content: content, sessionId: "ax-text", turnId: turn,
        originalResultClass: ChatToolOutcome.exactResultClass(.string(content)))
    guard case .object(let row) = try JSONValue.parse(Data(projected.utf8)) else {
        Issue.record("missing projection"); return
    }
    #expect(row["original_result_class"] == .string("succeeded"))
    #expect(row["full_result_retained"] == .bool(true))
    guard case .string(let handle)? = row["result_handle"],
          case .int(let count)? = row["page_count"] else {
        Issue.record("missing recovery locator"); return
    }
    var recovered = ""
    for index in 0..<Int(count) {
        let page = await ProviderToolResultRecoveryStore.shared.page(
            handle: handle, page: index, sessionId: "ax-text", turnId: turn)
        guard case .object(let value) = page, case .string(let text)? = value["content"] else {
            Issue.record("unreadable retained page"); return
        }
        #expect(value["original_result_class"] == .string("succeeded"))
        recovered += text
    }
    #expect(recovered == content)
    if let scope = ProviderToolResultRecoveryStore.Scope(sessionId: "ax-text", turnId: turn) {
        await ProviderToolResultRecoveryStore.shared.remove(scope: scope)
    }
}

@Test func agentExperienceRecoveryKeepsOriginalOutcomeSeparateFromPaging() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = ProviderToolResultRecoveryStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    for (status, expected) in [("queued", "unknown"), ("failed", "failed"), ("completed", "succeeded")] {
        let content = try JSONValue.object([
            "status": .string(status),
            "output": .string(String(repeating: "retained output 🦋\n", count: 2_000)),
        ]).serialize(pretty: false)
        let receipt = try #require(await store.store(content: content, toolName: "external_operation",
            sessionId: "session", turnId: "turn"))
        #expect(receipt.resultClass.rawValue == expected)
        let page = await store.page(handle: receipt.handle, page: 0, sessionId: "session", turnId: "turn")
        guard case .object(let row) = page else { Issue.record("missing page"); return }
        #expect(row["status"] == .string("completed"))
        #expect(row["original_result_class"] == .string(expected))
        #expect(row["recovery_only"] == .bool(true))
        let denied = await store.page(handle: receipt.handle, page: 0, sessionId: "another", turnId: "turn")
        guard case .object(let refusal) = denied else { Issue.record("missing refusal"); return }
        #expect(refusal["reason"] == .string("result_handle_unavailable"))
        #expect(refusal["original_result_class"] == nil)
        #expect(refusal["content"] == nil)
    }
}

@Test func agentExperienceProjectionPreservesFailureOutsideTruncatedPreview() async throws {
    let turn = UUID().uuidString
    let source = try JSONValue.object([
        "status": .string("failed"),
        "details": .string(String(repeating: "detail", count: 8_000)),
    ]).serialize(pretty: false)
    let projected = await ProviderToolResultProjection.project(toolName: "invoke_codex",
        content: source, sessionId: "ax-projection", turnId: turn)
    guard case .object(let row) = try JSONValue.parse(Data(projected.utf8)) else {
        Issue.record("missing projection"); return
    }
    #expect(row["original_result_class"] == .string("failed"))
    #expect(row["full_result_retained"] == .bool(true))
    #expect(projected.utf8.count <= ProviderToolResultProjection.compactMaxUTF8Bytes)
    if let scope = ProviderToolResultRecoveryStore.Scope(sessionId: "ax-projection", turnId: turn) {
        await ProviderToolResultRecoveryStore.shared.remove(scope: scope)
    }
}
