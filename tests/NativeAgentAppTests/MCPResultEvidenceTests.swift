import Foundation
import Testing
@testable import NativeAgentApp
import PersistenceCore

private struct FailingMCPReceiptPersistence: PersistenceCoreProtocol {
    enum Failure: Error, LocalizedError {
        case denied
        var errorDescription: String? { "receipt append denied" }
    }

    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue { defaultValue }
    func writeJSON(_ value: JSONValue, to path: URL) async throws {}
    func appendJSONL(_ record: JSONValue, to path: URL) async throws { throw Failure.denied }
    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] { [] }
    func readJSONL(_ path: URL) async throws -> [JSONValue] { [] }
}

@Suite("MCP result evidence")
struct MCPResultEvidenceTests {
    @Test("projection redacts secret fields and secret-shaped text")
    func projectionRedactsSecrets() throws {
        let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
        let projection = try MCPResultEvidence.project(.object([
            "answer": .string("safe"),
            "token": .string("short-secret-value"),
            "nested": .object(["note": .string("credential \(secret)")]),
        ]))

        let rendered = try projection.result.serialize(pretty: false)
        #expect(rendered.contains("safe"))
        #expect(rendered.contains("[REDACTED_FIELD]"))
        #expect(rendered.contains("[REDACTED_OPENAI_KEY:"))
        #expect(!rendered.contains("short-secret-value"))
        #expect(!rendered.contains(secret))
        #expect(projection.truncated == false)
    }

    @Test("large projection is bounded and carries digest plus truncation truth")
    func largeProjectionIsBounded() throws {
        let projection = try MCPResultEvidence.project(.object([
            "content": .string(String(repeating: "result-value-", count: 2_000)),
        ]))
        let encoded = try projection.result.serializedData(pretty: false)

        #expect(projection.truncated == true)
        #expect(encoded.count <= MCPResultEvidence.maxProjectionBytes)
        #expect(projection.preview.utf8.count <= MCPResultEvidence.maxPreviewBytes)
        #expect(projection.originalByteCount > MCPResultEvidence.maxProjectionBytes)
        #expect(projection.digest.count == 64)
    }

    @Test("receipt append failure remains a separate evidence outcome")
    func receiptFailureIsSeparate() async throws {
        let projection = try MCPResultEvidence.project(.object(["ok": .bool(true)]))
        let receipt = MCPResultEvidence.activityReceipt(
            callID: "call-1",
            receiptID: "receipt-1",
            serverID: "server",
            toolName: "tool",
            status: "ok",
            durationSeconds: 0.1,
            createdAt: "2026-07-12T00:00:00Z",
            projection: projection
        )

        let outcome = await MCPResultEvidence.persist(
            receipt,
            to: URL(fileURLWithPath: "/unwritten/activity.jsonl"),
            using: FailingMCPReceiptPersistence()
        )

        #expect(outcome.status == "failed")
        #expect(outcome.error == "receipt append denied")
    }

    @Test("successful receipt uses existing bounded Activity feed")
    func successfulReceiptPersists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPResultEvidenceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("activity/events.jsonl")
        let projection = try MCPResultEvidence.project(.object(["value": .string("visible")]))
        let receipt = MCPResultEvidence.activityReceipt(
            callID: "call-2",
            receiptID: "receipt-2",
            serverID: "server",
            toolName: "tool",
            status: "ok",
            durationSeconds: 0.2,
            createdAt: "2026-07-12T00:00:00Z",
            projection: projection
        )

        let outcome = await MCPResultEvidence.persist(
            receipt,
            to: path,
            using: SwiftNativePersistenceCore()
        )
        let rows = try await SwiftNativePersistenceCore().readJSONL(path)

        #expect(outcome.status == "recorded")
        #expect(rows.count == 1)
        guard case .object(let row) = rows[0] else {
            Issue.record("expected activity object")
            return
        }
        #expect(row["id"] == .string("receipt-2"))
        #expect(row["kind"] == .string("mcp_tool"))
    }
}
