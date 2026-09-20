import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Test func wholeResultPagesBoundLargeKeysAndKeepExactRecovery() async throws {
    let turn = UUID().uuidString
    let source = try JSONValue.object([
        String(repeating: "long key 🦋", count: 6_000): .object(["value": .string("Evidence")]),
        "small": .string("Still readable"),
    ]).serialize(pretty: false)
    for tool in ["read_file", "github_fixture"] {
        let projected = await ProviderToolResultProjection.project(toolName: tool, content: source,
            sessionId: turn, turnId: turn)
        #expect(projected.utf8.count <= ProviderToolResultProjection.maxUTF8Bytes(for: tool))
        guard case .object(let first) = try JSONValue.parse(Data(projected.utf8)),
              case .string(let handle)? = first["result_handle"],
              case .int(let count)? = first["raw_page_count"],
              case .array(let sections)? = first["sections"] else {
            Issue.record("Missing recovery page"); return
        }
        #expect(sections.contains { if case .object(let row) = $0 { return row["value"] == .string("Still readable") }; return false })
        #expect(sections.contains { if case .object(let row) = $0 { return row["raw_first_page"] == .int(0) && row["raw_last_page"] == .int(count - 1) }; return false })
        var recovered = ""
        for page in 0..<Int(count) {
            let result = await ProviderToolResultRecoveryStore.shared.page(handle: handle, page: page,
                sessionId: turn, turnId: turn)
            if case .object(let row) = result, case .string(let text)? = row["content"] { recovered += text }
        }
        #expect(recovered == source)
    }
    if let scope = ProviderToolResultRecoveryStore.Scope(sessionId: turn, turnId: turn) {
        await ProviderToolResultRecoveryStore.shared.remove(scope: scope)
    }
}

@Test func wholeResultPagesDeliverRelevantEvidenceAndRetainEveryParagraph() async throws {
    let turn = UUID().uuidString
    defer { Task {
        if let scope = ProviderToolResultRecoveryStore.Scope(sessionId: turn, turnId: turn) {
            await ProviderToolResultRecoveryStore.shared.remove(scope: scope)
        }
    } }
    let ordinary = String(repeating: "An ordinary page. ", count: 2_400)
    #expect(await ProviderToolResultProjection.project(toolName: "read_page", content: ordinary) == ordinary)
    let paragraphs = (0..<200).map { "Section \($0): " + String(repeating: "Complete evidence. ", count: 25) + "\n\n" }
        + ["The needle 证据 is in this final paragraph.\n\n"]
    let source = try JSONValue.object(["text": .string(paragraphs.joined()), "coverage": .bool(true)]).serialize(pretty: false)
    let initial = await ProviderToolResultProjection.project(toolName: "read_page", content: source,
        sessionId: turn, turnId: turn, query: "证据")
    guard case .object(let first) = try JSONValue.parse(Data(initial.utf8)),
          case .string(let handle)? = first["result_handle"],
          case .int(let count)? = first["page_count"],
          case .array(let sections)? = first["sections"],
          case .object(let leading)? = sections.first else { Issue.record("Missing first page"); return }
    #expect(leading["value"] == .string(paragraphs.last!))
    #expect(first["next_page"] == .int(1))
    var recovered: [Int: String] = [:]
    for index in 0..<Int(count) {
        let page = await ProviderToolResultRecoveryStore.shared.page(handle: handle, page: index,
            sessionId: turn, turnId: turn, query: "证据")
        let encoded = try page.serialize(pretty: false)
        #expect(await ProviderToolResultProjection.project(toolName: "tool_result_page", content: encoded) == encoded)
        guard case .object(let row) = page, case .array(let items)? = row["sections"] else { continue }
        for case .object(let item) in items {
            if case .int(let number)? = item["paragraph"], case .string(let text)? = item["value"] {
                recovered[Int(number)] = text
            }
        }
    }
    #expect(recovered.keys.sorted().compactMap { recovered[$0] }.joined() == paragraphs.joined())
    var raw = ""
    guard case .int(let rawCount)? = first["raw_page_count"] else { Issue.record("Missing raw count"); return }
    for index in 0..<Int(rawCount) {
        let page = await ProviderToolResultRecoveryStore.shared.page(handle: handle, page: index,
            sessionId: turn, turnId: turn)
        if case .object(let row) = page, case .string(let content)? = row["content"] { raw += content }
    }
    #expect(raw == source)
    let denied = await ProviderToolResultRecoveryStore.shared.page(handle: handle, page: 0,
        sessionId: "another", turnId: turn, query: "needle")
    guard case .object(let refusal) = denied else { Issue.record("Missing refusal"); return }
    #expect(refusal["reason"] == .string("result_handle_unavailable"))
}

@Test func wholeResultPagesKeepJSONRecordsUnicodeAndOversizedValuesHonest() throws {
    let records: [JSONValue] = (0..<80).map { .object([
        "url": .string("https://example.test/\($0)"),
        "text": .string(String(repeating: "Evidence 🦋 quoted \"text\". ", count: 80)),
    ]) }
    let source = try JSONValue.object(["results": .array(records)]).serialize(pretty: false)
    let pages = ToolResultSections.pages(content: source)
    var recovered: [JSONValue] = []
    for page in pages {
        #expect(try JSONValue.array(page).serialize(pretty: false).utf8.count <= ToolResultSections.pageBudget)
        for case .object(let row) in page { if let value = row["value"] { recovered.append(value) } }
    }
    #expect(recovered == records)
    let huge = String(repeating: "x", count: 80_000)
    let omitted = ToolResultSections.pages(content: huge)
    guard case .object(let row)? = omitted.first?.first else { Issue.record("Missing oversized value"); return }
    #expect(row["value"] == nil)
    #expect(row["omitted_bytes"] == .int(80_002))
    #expect(row["detail"] != nil)
}
