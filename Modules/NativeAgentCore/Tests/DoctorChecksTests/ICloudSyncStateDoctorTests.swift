import Testing
import Foundation
import PersistenceCore
@testable import DoctorChecks

// Sweep R4 items 1 + 2 reach the user HERE. The sync engine's durable failure
// state has to land on an existing Doctor row rather than a new reporting lane,
// so the iCloud Bridge State check now also reads `<dataRoot>/icloud/`.

private func doctorStateRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("icloud-doctor-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(
        at: ICloudSyncStatePaths.stateDirectory(dataRoot: root),
        withIntermediateDirectories: true
    )
    return root
}

@Suite("iCloud sync state in Doctor")
struct ICloudSyncStateDoctorTests {

    @Test("a clean state root adds no warnings")
    func cleanRootIsSilent() {
        let root = doctorStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ICloudBridgeStateCheck.localSyncStateWarnings(dataRoot: root).isEmpty)
    }

    @Test("stranded completed-but-unarchived commands are reported by id")
    func strandedCommandsAreReported() throws {
        let root = doctorStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = ICloudSyncStatePaths.completedUnarchivedDirectory(dataRoot: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("cmd-42.completed-unarchived"))

        let warnings = ICloudBridgeStateCheck.localSyncStateWarnings(dataRoot: root)

        #expect(warnings.count == 1)
        #expect(warnings[0].contains("cmd-42"))
        #expect(warnings[0].contains("will not run again"))
    }

    @Test("an unreadable processed-id window is reported as a replay risk")
    func corruptProcessedIdsAreReported() throws {
        let root = doctorStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{broken".utf8).write(
            to: ICloudSyncStatePaths.processedIdsCorruptBackup(dataRoot: root)
        )

        let warnings = ICloudBridgeStateCheck.localSyncStateWarnings(dataRoot: root)

        #expect(warnings.count == 1)
        #expect(warnings[0].contains("processed_ids.corrupt.json"))
        #expect(warnings[0].contains("re-run"))
    }

    @Test("skipped snapshot groups are named so the stale iPhone surface is identifiable")
    func skippedSnapshotGroupsAreNamed() throws {
        let root = doctorStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode([
            "approvals": "approval store unreadable",
            "model_preferences": "provider read failed",
            "_observedAt": "2026-08-06T00:00:00Z",
        ]).write(to: ICloudSyncStatePaths.snapshotSkips(dataRoot: root))

        let warnings = ICloudBridgeStateCheck.localSyncStateWarnings(dataRoot: root)

        #expect(warnings.count == 1)
        #expect(warnings[0].contains("approvals"))
        #expect(warnings[0].contains("model_preferences"))
        #expect(!warnings[0].contains("_observedAt"), "the bookkeeping key is not a group")
    }

    @Test("the existing iCloud bridge row carries the warning instead of a new lane")
    func warningsSurfaceOnTheExistingRow() async throws {
        let root = doctorStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        let dir = ICloudSyncStatePaths.completedUnarchivedDirectory(dataRoot: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("cmd-7.completed-unarchived"))

        // repair:true creates every bridge dir, so the directory verdict alone
        // would be "ok" — the warn must come from the sync state.
        let result = await ICloudBridgeStateCheck(
            docsURLProvider: { docs },
            dataRoot: root
        ).run(repair: true)

        #expect(result.id == "icloud_bridge_state")
        #expect(result.status == "warn")
        #expect(result.detail.contains("cmd-7"))
    }
}
