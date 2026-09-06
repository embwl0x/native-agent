import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

// MARK: - THE READ ORGAN PAGES THROUGH THE EXISTING HANDLE (fable51 item 33)
//
// `read` deliberately applies no display cap of its own: it hands back the
// whole document and lets the turn's ALREADY EXISTING lossless spill carry it.
// That is the load-bearing claim of the item — "reuse, never a new store" — and
// it is only true if `read`'s big result actually lands in
// `ProviderToolResultRecoveryStore` behind a `tool_result_page` handle rather
// than being head-and-tailed away.
//
// So this pins the wiring, not a second pager: project a `read`-sized result
// through the SAME function every tool result goes through, and read it back
// page by page.

@Test
func readResultTooBigForOneMessage_isRetainedWholeBehindToolResultPage() async throws {
    let session = "mac-read-fixture:\(UUID().uuidString)"
    let turn = "mac-read-turn-\(UUID().uuidString)"
    let scope = try #require(ProviderToolResultRecoveryStore.Scope(sessionId: session, turnId: turn))
    defer { Task { await ProviderToolResultRecoveryStore.shared.remove(scope: scope) } }

    // A contract-sized document: well past the provider ceiling for `read`.
    let clauses = (1...4_000).map { "Clause \($0): the party of the \($0)th part agrees to the terms herein." }
    let document = clauses.joined(separator: "\n")
    #expect(document.utf8.count > ProviderToolResultProjection.maxUTF8Bytes(for: "read"))

    let projected = await ProviderToolResultProjection.project(
        toolName: "read",
        content: document,
        sessionId: session,
        turnId: turn
    )
    let value = try JSONValue.parse(Data(projected.utf8))
    guard case .object(let fields) = value else {
        Issue.record("projection was not an object: \(projected)")
        return
    }

    // `read` gets the ORDINARY ceiling, not a compact one — it is a document
    // tool, and a 12 KB budget would page a contract three times as often.
    #expect(ProviderToolResultProjection.maxUTF8Bytes(for: "read")
        == ProviderToolResultProjection.defaultMaxUTF8Bytes)
    #expect(fields["full_result_retained"] == .bool(true), "\(fields)")
    #expect(fields["recovery_tool"] == .string("tool_result_page"), "\(fields)")
    guard case .string(let handle)? = fields["result_handle"] else {
        Issue.record("no result handle: \(fields)")
        return
    }
    guard case .int(let pageCount)? = fields["page_count"], pageCount > 1 else {
        Issue.record("a document this size must span pages: \(fields)")
        return
    }

    // AND IT IS LOSSLESS. Walk every page and reassemble the contract.
    var reassembled = ""
    for page in 0..<Int(pageCount) {
        let result = await ProviderToolResultRecoveryStore.shared.page(
            handle: handle, page: page, sessionId: session, turnId: turn
        )
        guard case .object(let object) = result,
              case .string(let content)? = object["content"] else {
            Issue.record("page \(page) came back unreadable: \(result)")
            return
        }
        #expect(content.utf8.count <= ProviderToolResultRecoveryStore.pageUTF8Bytes)
        reassembled += content
    }
    #expect(reassembled == document, "the document did not survive paging")
}

@Test
func readIsSurfacedAndRoutedAsItsOwnOrgan_neitherReadNorInjection() {
    #expect(SwiftToolDispatcher.macReadToolNames == ["read"])
    // Not folded into a neighbour's list — that is what keeps it out of the
    // four-verb cutover boundary and visible to the model.
    #expect(!SwiftToolDispatcher.fullMacAccessibilityReadToolNames.contains("read"))
    #expect(!SwiftToolDispatcher.fullMacAccessibilityInjectionToolNames.contains("read"))
    #expect(!SwiftToolDispatcher.legacyMacModelToolNames.contains("read"))
    // Reserved, so a registry custom tool can never publish a "read" schema the
    // dispatcher would not execute.
    #expect(SwiftToolDispatcher.reservedBuiltInNames.contains("read"))
    #expect(SwiftToolDispatcher.dottedAliasCanonicalToolNames.contains("read"))
}
