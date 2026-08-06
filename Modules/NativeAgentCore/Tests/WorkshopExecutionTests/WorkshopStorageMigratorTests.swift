import Foundation
import Testing
@testable import WorkshopExecution

@Suite("Workshop storage migration")
struct WorkshopStorageMigratorTests {
    // De-mission P2-7: the `data/missions` absorption branch is DELETED. A
    // dataRoot that still carries one is now IGNORED — not read, not merged,
    // not archived. That is the honest behavior for a hypothetical unmigrated
    // install, and it is what this asserts: the tree survives byte-for-byte
    // and the Workshop side gains nothing from it.
    @Test("a legacy missions/ tree is ignored, not absorbed")
    func legacyMissionsTreeIsIgnored() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("missions", isDirectory: true)
        try write("old-record", to: legacy.appendingPathComponent("queue/wsx-1/mission.json"))
        try write("old-trigger", to: legacy.appendingPathComponent("triggers.json"))
        try write("old-flat", to: legacy.appendingPathComponent("missions.json"))
        try write("checkpoint", to: legacy.appendingPathComponent("execution-2/checkpoints.jsonl"))

        let report = try WorkshopStorageMigrator.migrateIfNeeded(
            dataRoot: root,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        // No crash, no migration, no receipt, no archive.
        #expect(!report.didMigrate)
        #expect(report.moved.isEmpty)
        #expect(report.deduplicated.isEmpty)
        #expect(report.conflictsPreservedInArchive.isEmpty)
        #expect(report.archiveRelativePath == nil)
        #expect(report.receiptRelativePath == nil)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("archive", isDirectory: true).path))

        // The legacy tree is untouched, in place, with its original bytes.
        #expect(try read(legacy.appendingPathComponent("queue/wsx-1/mission.json")) == "old-record")
        #expect(try read(legacy.appendingPathComponent("triggers.json")) == "old-trigger")
        #expect(try read(legacy.appendingPathComponent("missions.json")) == "old-flat")
        #expect(try read(legacy.appendingPathComponent("execution-2/checkpoints.jsonl")) == "checkpoint")

        // And nothing of it landed on the Workshop side.
        for absorbed in [
            "workshop/executions/wsx-1/execution.json",
            "workshop/executions/wsx-1/mission.json",
            "workshop/executions/execution-2/checkpoints.jsonl",
            "workshop/triggers.json",
            "workshop/legacy_executions.json",
        ] {
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent(absorbed).path), "absorbed \(absorbed)")
        }
    }

    @Test("repairs migrated absolute receipts paths even after the legacy root is gone")
    func repairsStaleReceiptsDirectory() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = root.appendingPathComponent("workshop/executions/execution-3/execution.json")
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
        let record = root.appendingPathComponent("workshop/executions/execution-9/execution.json")
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
