import Foundation
import Testing
import BackgroundLoops
import Context
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

@Suite("feeds.logs maintenance sweep", .serialized)
struct MaintenanceSweepFeedEvalTests {
    @Test("mounted maintenance writes one root-relative audit row per removal and a pass summary")
    func mountedMaintenanceSweepProjectsRemovedArtifactsToFeed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaintenanceSweepFeedEval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let traces = root.appendingPathComponent("turn_traces", isDirectory: true)
        try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)
        let oldDay = dayName(30, before: now)
        let oldTrace = traces.appendingPathComponent("\(oldDay).jsonl")
        let oldTraceLock = oldTrace.appendingPathExtension("lock")
        try Data("{\"event\":\"fixture\"}\n".utf8).write(to: oldTrace)
        try Data().write(to: oldTraceLock)

        // This stale orphan is outside the trace directory, so it exercises
        // the generic bounded lock-sidecar sweep in the same mounted pass.
        let orphanLock = root.appendingPathComponent("abandoned-receipt.json.lock")
        try Data().write(to: orphanLock)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-2 * 24 * 60 * 60)],
            ofItemAtPath: orphanLock.path
        )

        let contextDirectory = root.appendingPathComponent("context", isDirectory: true)
        try FileManager.default.createDirectory(at: contextDirectory, withIntermediateDirectories: true)
        let legacyReceipt = contextDirectory.appendingPathComponent("unreferenced-old.json")
        try Data("{\"runId\":\"unreferenced-old\"}".utf8).write(to: legacyReceipt)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-LegacyContextReceiptFeed.maximumUnprotectedAge - 1)],
            ofItemAtPath: legacyReceipt.path
        )

        let loop: any LoopRunner = BackgroundLoopsAssembly.makeTurnTraceRetentionLoop(dataRoot: root)
        let outcome = await loop.tickOutcome()
        guard case .completed = outcome else {
            Issue.record("maintenance pass did not complete: \(outcome)")
            return
        }

        let feed = root.appendingPathComponent("logs/maintenance_sweep.jsonl")
        let rows = try String(contentsOf: feed, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { line -> [String: Any] in
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            }

        let removalRows = rows.filter { $0["event"] as? String == "maintenance_sweep.removed" }
        #expect(removalRows.count == 4)
        let removalPaths = Set(removalRows.compactMap { $0["path"] as? String })
        #expect(removalPaths == Set([
            "turn_traces/\(oldDay).jsonl",
            "turn_traces/\(oldDay).jsonl.lock",
            "abandoned-receipt.json.lock",
            "context/unreferenced-old.json",
        ]))
        #expect(removalRows.allSatisfy { !($0["path"] as? String ?? "").hasPrefix(root.path) })

        let summary = rows.first { $0["event"] as? String == "maintenance_sweep.completed" }
        #expect(summary != nil)
        #expect((summary?["removed"] as? NSNumber)?.intValue == 3)
        #expect((summary?["turnTraceDaysRemoved"] as? NSNumber)?.intValue == 1)
        #expect((summary?["turnTraceLocksRemoved"] as? NSNumber)?.intValue == 1)
        #expect((summary?["orphanLockSidecarsReaped"] as? NSNumber)?.intValue == 1)

        let contextSummary = rows.first {
            $0["event"] as? String == "maintenance_sweep.completed"
                && $0["source"] as? String == "legacy_context_receipt_retention"
        }
        #expect((contextSummary?["removed"] as? NSNumber)?.intValue == 1)
        #expect((contextSummary?["discovered"] as? NSNumber)?.intValue == 1)
        #expect((contextSummary?["failedRemovals"] as? NSNumber)?.intValue == 0)
    }

    private func dayName(_ days: Int, before now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }
}
