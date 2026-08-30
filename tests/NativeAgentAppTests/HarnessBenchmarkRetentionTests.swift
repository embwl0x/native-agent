import Testing
import Foundation
@testable import NativeAgentApp
import PersistenceCore

@Suite("app.harness benchmark retention")
struct HarnessBenchmarkRetentionTests {
    @Test func persistedRunsAreCappedAtNewestWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-benchmark-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func makeRun(_ index: Int) -> HarnessBenchmarkRun {
            HarnessBenchmarkRun(
                id: "hb-\(index)",
                name: "bench-\(index)",
                status: "passed",
                checks: [
                    HarnessBenchmarkCheck(
                        id: "check-\(index)",
                        title: "Check \(index)",
                        passed: true,
                        detail: "ok"
                    ),
                ],
                durationSeconds: Double(index),
                schedule: "manual",
                manualRunnable: true,
                chatPathImpact: "none",
                createdAt: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(index)))
            )
        }

        let path = root
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent("benchmark", isDirectory: true)
            .appendingPathComponent("runs.jsonl")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let seededCount = JSONLLineCaps.harnessBenchmarkRuns + 1
        let seeded = try (0..<seededCount).map { index in
            String(decoding: try JSONEncoder().encode(makeRun(index)), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try Data(seeded.utf8).write(to: path)

        // One real production append crosses the boundary and restores the
        // newest exact window, dropping the two oldest seeded runs.
        let newestIndex = seededCount
        try await NativeClient.persistHarnessBenchmarkRun(makeRun(newestIndex), dataRoot: root)

        let text = try String(contentsOf: path, encoding: .utf8)
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true)
        let ids = try rows.map {
            try JSONDecoder().decode(HarnessBenchmarkRun.self, from: Data($0.utf8)).id
        }
        #expect(rows.count == JSONLLineCaps.harnessBenchmarkRuns)
        #expect(ids.first == "hb-2")
        #expect(!ids.contains("hb-0"))
        #expect(!ids.contains("hb-1"))
        #expect(ids.last == "hb-\(newestIndex)")
    }
}
