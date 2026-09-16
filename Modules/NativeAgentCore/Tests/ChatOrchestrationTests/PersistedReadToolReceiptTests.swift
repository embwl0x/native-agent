import Foundation
import PersistenceCore
import Testing
@testable import ChatOrchestration

@Suite struct PersistedReadToolReceiptTests {
    private func receipt(_ tool: String, _ fields: [String: JSONValue]) throws -> (String, [String: JSONValue]) {
        let raw = try JSONValue.object(fields).serialize(pretty: false)
        let result = SwiftNativeChatOrchestrationClient.redactedPersistedToolResult(tool: tool, json: raw)
        #expect(result.count <= 8_000)
        guard case .object(let object) = try JSONValue.parse(Data(result.utf8)) else {
            throw NSError(domain: "receipt-fixture", code: 1)
        }
        return (result, object)
    }

    @Test func sourceCoverageSurvivesLongTextWithoutPromisingLaterRecovery() throws {
        let (_, result) = try receipt("read_page", [
            "text": .string(String(repeating: "source paragraph ", count: 5_000)),
            "status": .string("completed"), "id": .string("source-fixture"),
            "source_receipt": .object(["path": .string("/authorized-fixture/source-fixture.json"),
                "source_id": .string("source-fixture"), "retention": .string("Limited retention; may be removed."),
                "access": .string("Existing file permissions apply.")]),
            "coverage": .object(["complete": .bool(true), "http_status": .int(200),
                "extracted_characters": .int(85_000), "requested_url": .string("https://example.org/start"),
                "final_url": .string("https://example.org/final"), "extraction_status": .string("html_text"),
                "decoded_encoding": .string("windows-1252"), "encoding_source": .string("http_charset")]),
        ])
        #expect(result["original_result_class"] == .string("succeeded"))
        #expect(result["full_result_in_transcript"] == .bool(false))
        guard case .object(let evidence)? = result["evidence"], case .object(let coverage)? = evidence["coverage"] else {
            Issue.record("Missing factual source receipt"); return
        }
        #expect(evidence["id"] == .string("source-fixture"))
        #expect(coverage["complete"] == .bool(true))
        #expect(coverage["extracted_characters"] == .int(85_000))
        #expect(coverage["final_url"] == .string("https://example.org/final"))
        #expect(coverage["decoded_encoding"] == .string("windows-1252"))
        guard case .object(let source)? = evidence["source_receipt"] else { Issue.record("Missing existing source locator"); return }
        #expect(source["path"] == .string("/authorized-fixture/source-fixture.json"))
        #expect(source["retention"] == .string("Limited retention; may be removed."))
        #expect(result["result_handle"] == nil)
        #expect(result["verification_scope"] == .string("historical_tool_response_not_current_source_state"))
    }

    @Test func incompleteFileRetainsItsWindowAndVersionEvidence() throws {
        let (_, result) = try receipt("read_file", ["ok": .bool(true), "content": .string(String(repeating: "🌿", count: 9_000)),
            "path": .string("fixture.txt"), "version": .string("original-version"), "offset": .int(28),
            "bytes": .int(80_000), "returned_bytes": .int(36_000), "has_more": .bool(true), "truncated": .bool(true)])
        guard case .object(let evidence)? = result["evidence"] else { Issue.record("Missing window evidence"); return }
        #expect(evidence["version"] == .string("original-version"))
        #expect(evidence["bytes"] == .int(80_000))
        #expect(evidence["offset"] == .int(28))
        #expect(evidence["has_more"] == .bool(true))
        #expect(result["full_result_in_transcript"] == .bool(false))
    }

    @Test func redactsMetadataAndOmitsOversizedLocatorsWithoutClippingThem() throws {
        let token = "sk-" + String(repeating: "a", count: 30)
        let (text, result) = try receipt("read_page", ["text": .string(String(repeating: "x", count: 10_000)),
            "url": .string("https://example.org/" + String(repeating: "z", count: 900)),
            "coverage": .object(["complete": .bool(false), "http_status": .int(200),
                "final_url": .string("https://example.org/?key=" + token)])])
        #expect(!text.contains(token))
        guard case .object(let evidence)? = result["evidence"] else { Issue.record("Missing evidence"); return }
        #expect(evidence["url"] == nil)
        #expect(result["evidence_fields_omitted"] == .array([.string("url")]))
        #expect(result["original_result_class"] == .string("unknown"), "Coverage alone must not invent a tool status")
    }

    @Test func ordinaryAndNonReadReceiptsKeepTheirExistingContract() {
        let short = #"{"status":"completed","text":"small"}"#
        #expect(SwiftNativeChatOrchestrationClient.redactedPersistedToolResult(tool: "read_page", json: short) == short)
        let long = "{\"detail\":\"" + String(repeating: "x", count: 9_000) + "\",\"status\":\"queued\"}"
        #expect(PersistedReadToolReceipt.project(tool: "claude_message", json: long, maximumCharacters: 8_000) == nil)
        #expect(PersistedReadToolReceipt.project(tool: "read_file", json: String(repeating: "x", count: 9_000), maximumCharacters: 8_000) == nil)
    }
}
