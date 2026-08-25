import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Capabilities.traceTimeline
@Suite("Capabilities trace timeline", .serialized)
struct CapabilitiesTraceTimelineEvalTests {
    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capability-traces-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func row(_ index: Int) -> RuntimeTrace {
        let day = index / 24 + 1
        let hour = index % 24
        return RuntimeTrace(
            id: "trace-\(index)",
            kind: "workflow.run",
            title: "Trace \(index)",
            status: "ok",
            createdAt: String(format: "2026-08-%02dT%02d:00:00Z", day, hour)
        )
    }

    private func write(_ lines: [String], to root: URL) throws {
        let path = CapabilityTraceFeed.path(in: root)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: path)
    }

    private func encoded(_ trace: RuntimeTrace) throws -> String {
        String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)
    }

    @Test("missing, empty, and unreadable trace evidence remain distinct")
    func missingEmptyAndCorruptFeedsAreNotSilentZero() throws {
        let root = try root("states")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CapabilityTraceFeed.read(dataRoot: root) == .sourceAbsent)

        let path = CapabilityTraceFeed.path(in: root)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: path)
        #expect(CapabilityTraceFeed.read(dataRoot: root) == .empty)

        let corrupt = Data("{not-json}\n".utf8)
        try corrupt.write(to: path)
        guard case .unavailable(let detail) = CapabilityTraceFeed.read(dataRoot: root) else {
            Issue.record("a corrupt feed must not render as an empty timeline")
            return
        }
        #expect(detail.contains("malformed"))
        #expect(try Data(contentsOf: path) == corrupt)
    }

    @Test("canonical trace reader retains a bounded newest-first timeline and reports withheld rows")
    func canonicalTimelineIsBoundedOrderedAndPartialIsVisible() throws {
        let root = try root("timeline")
        defer { try? FileManager.default.removeItem(at: root) }
        var lines = try (0...204).map { try encoded(row($0)) }
        lines.append("{malformed")
        try write(lines, to: root)

        guard case .partial(let traces, let rejectedRows) = CapabilityTraceFeed.read(dataRoot: root) else {
            Issue.record("valid rows plus malformed evidence must remain a visible partial timeline")
            return
        }
        #expect(rejectedRows == 1)
        #expect(traces.count == CapabilityTraceFeed.maximumRows)
        #expect(traces.first?.id == "trace-204")
        #expect(traces.last?.id == "trace-5")
    }

    @Test("the mounted client reads traces/events.jsonl, not the retired runtime path")
    func clientUsesCanonicalTraceLedger() throws {
        let root = try root("client")
        defer { try? FileManager.default.removeItem(at: root) }
        try write([try encoded(row(9))], to: root)

        let retired = root.appendingPathComponent("runtime/traces.jsonl")
        try FileManager.default.createDirectory(at: retired.deletingLastPathComponent(), withIntermediateDirectories: true)
        let retiredLine = try encoded(row(1))
        try Data(retiredLine.utf8).write(to: retired)

        let client = NativeClient(baseURL: "", dataRootOverride: root)
        #expect(client.getCapabilityTraceTimeline().traces.map(\.id) == ["trace-9"])
    }
}
