import Foundation
import Testing
@testable import WorkshopExecution

@Suite("Workshop storage migration")
struct WorkshopStorageMigratorTests {
    @Test("moves live state, preserves backups, and writes a receipt")
    func movesStateAndArchivesLegacyTree() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("missions", isDirectory: true)
        try write("old-record", to: legacy.appendingPathComponent("queue/wsx-1/mission.json"))
        try write("old-trigger", to: legacy.appendingPathComponent("triggers.json"))
        try write("old-flat", to: legacy.appendingPathComponent("missions.json"))
        try write("backup", to: legacy.appendingPathComponent("queue.bak.pre-reap/wsx-old/mission.json"))

        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let report = try WorkshopStorageMigrator.migrateIfNeeded(dataRoot: root, now: stamp)

        #expect(report.didMigrate)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try read(root.appendingPathComponent("workshop/executions/wsx-1/mission.json")) == "old-record")
        #expect(try read(root.appendingPathComponent("workshop/triggers.json")) == "old-trigger")
        #expect(try read(root.appendingPathComponent("workshop/legacy_executions.json")) == "old-flat")
        let archive = try #require(report.archiveRelativePath)
        #expect(try read(root.appendingPathComponent(archive).appendingPathComponent("queue.bak.pre-reap/wsx-old/mission.json")) == "backup")
        let receipt = try #require(report.receiptRelativePath)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(receipt).path))
    }

    @Test("canonical Workshop state wins and conflicting legacy bytes remain archived")
    func mergesWithoutOverwritingCanonicalState() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("canonical", to: root.appendingPathComponent("workshop/executions/shared/mission.json"))
        try write("legacy", to: root.appendingPathComponent("missions/queue/shared/mission.json"))
        try write("same", to: root.appendingPathComponent("workshop/executions/shared/timeline.jsonl"))
        try write("same", to: root.appendingPathComponent("missions/queue/shared/timeline.jsonl"))

        let report = try WorkshopStorageMigrator.migrateIfNeeded(
            dataRoot: root,
            now: Date(timeIntervalSince1970: 1_700_000_001)
        )

        #expect(try read(root.appendingPathComponent("workshop/executions/shared/mission.json")) == "canonical")
        #expect(report.conflictsPreservedInArchive.contains("missions/queue/shared/mission.json"))
        #expect(report.deduplicated.contains("missions/queue/shared/timeline.jsonl"))
        let archive = try #require(report.archiveRelativePath)
        #expect(try read(root.appendingPathComponent(archive).appendingPathComponent("queue/shared/mission.json")) == "legacy")
    }

    @Test("a later launch is a no-op after the legacy root is archived")
    func idempotentAfterMigration() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("[]", to: root.appendingPathComponent("missions/triggers.json"))

        _ = try WorkshopStorageMigrator.migrateIfNeeded(dataRoot: root)
        let second = try WorkshopStorageMigrator.migrateIfNeeded(dataRoot: root)

        #expect(!second.didMigrate)
        #expect(second.moved.isEmpty)
    }

    @Test("early checkpoint directories join their canonical execution")
    func migratesEarlyCheckpointLayout() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("checkpoint", to: root.appendingPathComponent("missions/execution-2/checkpoints.jsonl"))

        _ = try WorkshopStorageMigrator.migrateIfNeeded(dataRoot: root)

        #expect(try read(root.appendingPathComponent("workshop/executions/execution-2/checkpoints.jsonl")) == "checkpoint")
    }

    @Test("repairs migrated absolute receipts paths even after the legacy root is gone")
    func repairsStaleReceiptsDirectory() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = root.appendingPathComponent("workshop/executions/execution-3/mission.json")
        let stale = root.appendingPathComponent("missions/queue/execution-3/receipts").path
        try write(#"{"id":"execution-3","receipts_dir":"\#(stale)"}"#, to: record)

        let report = try WorkshopStorageMigrator.migrateIfNeeded(
            dataRoot: root,
            now: Date(timeIntervalSince1970: 1_700_000_002)
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any]
        )
        let canonicalSuffix = "/workshop/executions/execution-3/receipts"
        let repairedPath = try #require(object["receipts_dir"] as? String)
        #expect(repairedPath.hasSuffix(canonicalSuffix))
        #expect(!repairedPath.contains("/missions/"))
        #expect(report.didMigrate)
        #expect(report.archiveRelativePath == nil)
        #expect(report.moved.contains { $0.contains("receipts_dir -> ") && $0.hasSuffix(canonicalSuffix) })
        #expect(report.receiptRelativePath != nil)

        let second = try WorkshopStorageMigrator.migrateIfNeeded(dataRoot: root)
        #expect(!second.didMigrate)
    }

    // A5.3 (W5#P1-3): once a normalization pass has stamped its version-marker,
    // a later launch must SKIP the O(all-executions) rescan entirely. Proven by
    // re-drifting a pointer after the marker exists: a skipped pass leaves the
    // fresh drift UNREPAIRED (a non-skipping pass would repair it every launch).
    @Test("done-marker makes a later launch skip the pointer rescan")
    func doneMarkerSkipsRescan() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = root.appendingPathComponent("workshop/executions/execution-9/mission.json")
        let stale = root.appendingPathComponent("missions/queue/execution-9/receipts").path

        // First launch: no marker → repair runs, marker gets stamped.
        try write(#"{"id":"execution-9","receipts_dir":"\#(stale)"}"#, to: record)
        let first = try WorkshopStorageMigrator.migrateIfNeeded(dataRoot: root)
        #expect(first.didMigrate)   // it repaired the drifted pointer
        #expect(WorkshopStorageMigrator.pointerNormalizationCompleted(
            workshopRoot: root.appendingPathComponent("workshop", isDirectory: true),
            fileManager: .default))

        // Re-drift the SAME pointer, then relaunch. Marker present → scan skipped.
        try write(#"{"id":"execution-9","receipts_dir":"\#(stale)"}"#, to: record)
        let second = try WorkshopStorageMigrator.migrateIfNeeded(dataRoot: root)
        #expect(!second.didMigrate)
        #expect(second.moved.isEmpty)
        // The re-drifted pointer was NOT touched — proof the rescan was skipped.
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        #expect(object["receipts_dir"] as? String == stale)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopStorageMigratorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
}
