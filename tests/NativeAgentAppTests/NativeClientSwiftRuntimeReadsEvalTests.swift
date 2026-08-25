import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / client.swiftRuntimeReads
@Suite("Native client Swift runtime reads")
struct NativeClientSwiftRuntimeReadsEvalTests {
    @Test("trace compatibility read returns the real canonical rows from the injected root")
    func healthyTraceReadUsesInjectedCanonicalLedger() async throws {
        let root = try temporaryRoot("healthy")
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = RuntimeTrace(
            id: "runtime-read-healthy",
            kind: "workflow.run",
            title: "Healthy runtime read",
            status: "ok",
            createdAt: "2026-08-24T12:00:00Z"
        )
        try write([try encoded(expected)], to: root)
        let client = NativeClient(baseURL: "", dataRootOverride: root)

        let traces = try await client.getTraces()

        #expect(traces.map(\.id) == [expected.id])
        #expect(client.getCapabilityTraceTimeline() == .current(traces))
    }

    @Test("missing evidence is empty, while malformed or partial evidence refuses a success-shaped trace result")
    func adverseTraceEvidenceIsNotCollapsedToEmpty() async throws {
        let missingRoot = try temporaryRoot("missing")
        defer { try? FileManager.default.removeItem(at: missingRoot) }
        let missingClient = NativeClient(baseURL: "", dataRootOverride: missingRoot)
        #expect(try await missingClient.getTraces().isEmpty)
        #expect(missingClient.getCapabilityTraceTimeline() == .sourceAbsent)

        let corruptRoot = try temporaryRoot("corrupt")
        defer { try? FileManager.default.removeItem(at: corruptRoot) }
        try write(["{not-json}"], to: corruptRoot)
        let corruptClient = NativeClient(baseURL: "", dataRootOverride: corruptRoot)
        await #expect(throws: NativeClientRuntimeReadError.traceEvidenceUnavailable(
            "trace feed contains 1 malformed row and no readable traces"
        )) {
            _ = try await corruptClient.getTraces()
        }

        let partialRoot = try temporaryRoot("partial")
        defer { try? FileManager.default.removeItem(at: partialRoot) }
        let valid = RuntimeTrace(
            id: "runtime-read-partial",
            kind: "workflow.run",
            title: "Partially readable runtime trace",
            status: "ok",
            createdAt: "2026-08-24T13:00:00Z"
        )
        try write([try encoded(valid), "{not-json}"], to: partialRoot)
        let partialClient = NativeClient(baseURL: "", dataRootOverride: partialRoot)
        #expect(partialClient.getCapabilityTraceTimeline() == .partial([valid], rejectedRows: 1))
        await #expect(throws: NativeClientRuntimeReadError.traceEvidencePartial(rejectedRows: 1)) {
            _ = try await partialClient.getTraces()
        }
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-client-runtime-reads-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func encoded(_ trace: RuntimeTrace) throws -> String {
        String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)
    }

    private func write(_ lines: [String], to root: URL) throws {
        let path = CapabilityTraceFeed.path(in: root)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: path)
    }
}
