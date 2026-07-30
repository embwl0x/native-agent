import Foundation
import Testing
@testable import PersistenceCore

@Suite("RunLedger: native runs.json writer")
struct RunLedgerTests {
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func readRows(_ root: URL) throws -> [[String: Any]] {
        let path = root
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent("runs.json")
        let data = try Data(contentsOf: path)
        let parsed = try JSONSerialization.jsonObject(with: data)
        // Contract: BARE ARRAY — the shape getRunsStrict() decodes first.
        let rows = try #require(parsed as? [[String: Any]])
        return rows
    }

    @Test func appendWritesBareArrayRowWithRunRecordFields() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await RunLedger.append(
            id: "run-1",
            kind: "codex",
            status: "succeeded",
            model: "gpt-5.5",
            prompt: "do the thing",
            output: "did the thing",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 1.5,
            dataRoot: root
        )
        let rows = try readRows(root)
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row["id"] as? String == "run-1")
        #expect(row["kind"] as? String == "codex")
        #expect(row["status"] as? String == "succeeded")
        #expect(row["model"] as? String == "gpt-5.5")
        #expect(row["prompt"] as? String == "do the thing")
        #expect(row["output"] as? String == "did the thing")
        #expect(row["durationSeconds"] as? Double == 1.5)
        #expect((row["createdAt"] as? String)?.hasPrefix("2023-11-14") == true)
        #expect(row["error"] == nil)
    }

    @Test func appendInsertsNewestFirstAndBoundsTheLedger() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<(RunLedger.maxRetainedRuns + 25) {
            await RunLedger.append(
                id: "run-\(i)",
                kind: "mission",
                status: "succeeded",
                createdAt: Date(timeIntervalSince1970: Double(1_700_000_000 + i)),
                dataRoot: root
            )
        }
        let rows = try readRows(root)
        #expect(rows.count == RunLedger.maxRetainedRuns)
        // Newest-first: the last append is row 0; the oldest 25 fell off.
        #expect(rows.first?["id"] as? String == "run-\(RunLedger.maxRetainedRuns + 24)")
        #expect(rows.last?["id"] as? String == "run-25")
    }

    @Test func appendPreservesRowsFromDaemonEraWrapperObject() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runsDir = root.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        let legacy = ["runs": [["id": "legacy-1", "kind": "codex", "status": "succeeded", "createdAt": "2026-01-01T00:00:00Z"]]]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try data.write(to: runsDir.appendingPathComponent("runs.json"))

        await RunLedger.append(
            id: "run-new",
            kind: "swarm",
            status: "failed",
            error: "boom",
            createdAt: Date(),
            dataRoot: root
        )
        let rows = try readRows(root)
        #expect(rows.count == 2)
        #expect(rows[0]["id"] as? String == "run-new")
        #expect(rows[0]["error"] as? String == "boom")
        #expect(rows[1]["id"] as? String == "legacy-1")
    }

    @Test func longPayloadsAreClippedWithMarker() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bigPrompt = String(repeating: "p", count: RunLedger.promptCap + 500)
        let bigOutput = String(repeating: "o", count: RunLedger.outputCap + 500)
        await RunLedger.append(
            kind: "codex",
            status: "succeeded",
            prompt: bigPrompt,
            output: bigOutput,
            createdAt: Date(),
            dataRoot: root
        )
        let rows = try readRows(root)
        let prompt = try #require(rows[0]["prompt"] as? String)
        let output = try #require(rows[0]["output"] as? String)
        #expect(prompt.contains("[truncated 500 chars]"))
        #expect(prompt.count < RunLedger.promptCap + 100)
        #expect(output.contains("[truncated 500 chars]"))
    }

    @Test func corruptLedgerIsReplacedNotFatal() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runsDir = root.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: runsDir.appendingPathComponent("runs.json"))

        await RunLedger.append(
            kind: "claude",
            status: "succeeded",
            createdAt: Date(),
            dataRoot: root
        )
        let rows = try readRows(root)
        #expect(rows.count == 1)
        #expect(rows[0]["kind"] as? String == "claude")
    }

    @Test func corruptLedgerIsPreservedAsBackupBeforeRewrite() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runsDir = root.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: runsDir.appendingPathComponent("runs.json"))

        await RunLedger.append(kind: "codex", status: "succeeded", createdAt: Date(), dataRoot: root)

        // Audit 2026-07-21: the unreadable ledger must survive as a timestamped
        // sibling — the rewrite must not be the only copy of what was lost.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: runsDir.path)
        let backups = siblings.filter {
            $0.hasPrefix("runs.json.corrupt-") && $0.hasSuffix(".bak")
        }
        #expect(backups.count == 1)
        let backupData = try Data(contentsOf: runsDir.appendingPathComponent(backups[0]))
        #expect(String(decoding: backupData, as: UTF8.self) == "not json at all")

        // A healthy rewrite afterwards creates NO further backup.
        await RunLedger.append(kind: "codex", status: "failed", createdAt: Date(), dataRoot: root)
        let after = try FileManager.default.contentsOfDirectory(atPath: runsDir.path)
        #expect(after.filter { $0.hasPrefix("runs.json.corrupt-") }.count == 1)
        #expect(try readRows(root).count == 2)
    }

    @Test func corruptBackupsAreBoundedToNewestThree() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runsDir = root.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        // Four stale backups from prior incidents plus a freshly corrupted ledger.
        for i in 0..<4 {
            try Data("stale".utf8).write(to: runsDir.appendingPathComponent(
                "runs.json.corrupt-2020-01-0\(i)T00-00-00.bak"
            ))
        }
        try Data("garbage".utf8).write(to: runsDir.appendingPathComponent("runs.json"))

        await RunLedger.append(kind: "codex", status: "succeeded", createdAt: Date(), dataRoot: root)

        let backups = try FileManager.default.contentsOfDirectory(atPath: runsDir.path)
            .filter { $0.hasPrefix("runs.json.corrupt-") && $0.hasSuffix(".bak") }
        #expect(backups.count == 3, "corrupt backups must stay bounded, got \(backups.count)")
        #expect(!backups.contains("runs.json.corrupt-2020-01-00T00-00-00.bak"))
        #expect(!backups.contains("runs.json.corrupt-2020-01-01T00-00-00.bak"))
    }
}
