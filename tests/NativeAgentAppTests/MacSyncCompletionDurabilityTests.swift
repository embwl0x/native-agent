import Foundation
import Testing
import PersistenceCore
@testable import NativeAgentApp

// Sweep R4 items 1 + 2, Mac↔iOS sync engine.
//
// Item 1: an iOS command was dispatched, its response written, and only THEN
// were the processed-id list and the pending-file archive persisted — both with
// swallowed `try?`. A disk-full or iCloud-permission failure after execution
// therefore left the command looking unprocessed, and the next sweep or the
// next launch RAN THE REMOTE MAC ACTION AGAIN. `loadProcessedIds` starting from
// an empty set on an unreadable file widened the same window.
//
// Item 2: snapshot helpers returned nil per group with no signal, so the Mac
// published every healthy group while the phone silently held stale approvals.

/// A hermetic data root whose `icloud/` state directory can be made unwritable
/// to produce a REAL persistence failure — not a mocked one.
private func syncStateRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("macsync-durability-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(
        at: ICloudSyncStatePaths.completedUnarchivedDirectory(dataRoot: root),
        withIntermediateDirectories: true
    )
    return root
}

/// Denies new entries in `icloud/` while leaving the already-created
/// `completed-unarchived/` subdirectory writable — exactly the shape of a
/// partial failure: the id list can't be saved, the marker still can.
private func denyWritesToStateDirectory(_ root: URL) throws {
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500],
        ofItemAtPath: ICloudSyncStatePaths.stateDirectory(dataRoot: root).path
    )
}

private func restoreWrites(_ root: URL) {
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: ICloudSyncStatePaths.stateDirectory(dataRoot: root).path
    )
}

@Suite("MacSync completion durability")
struct MacSyncCompletionDurabilityTests {

    // MARK: - Item 1

    @Test("a post-response persistence failure leaves a marker, and a restart does not re-dispatch")
    func persistenceFailureLeavesMarkerAndRestartDoesNotRedispatch() throws {
        let root = syncStateRoot()
        defer { restoreWrites(root); try? FileManager.default.removeItem(at: root) }
        let msgId = "3B1C7E60-0000-0000-0000-00000000A001"

        // A REAL failure: the state directory rejects new files.
        try denyWritesToStateDirectory(root)
        #expect(
            MacSyncEngine.persistProcessedIds([msgId], dataRoot: root) == false,
            "the checked save must report the failure instead of swallowing it"
        )

        // The command already RAN and its response already landed, so the
        // bookkeeping transaction must fall back to a durable marker.
        let commit = MacSyncEngine.commitCompletionBookkeeping(
            dataRoot: root,
            msgId: msgId,
            processedSaved: false,
            archiveError: "No space left on device"
        )
        #expect(commit.clean == false)
        #expect(commit.markerWritten, "the fallback marker is the whole anti-replay guarantee")
        #expect(commit.transactionState == "completed_unarchived")
        let message = try #require(commit.syncError)
        #expect(message.contains(msgId))
        #expect(message.contains("will not run again"))
        #expect(message.contains("No space left on device"))

        // Doctor's durable evidence is on disk under the documented name.
        let marker = ICloudSyncStatePaths.completedUnarchivedMarker(dataRoot: root, msgId: msgId)
        #expect(marker.lastPathComponent == "\(msgId).completed-unarchived")
        #expect(FileManager.default.fileExists(atPath: marker.path))

        // RESTART: the id list was never written, so before this fix the engine
        // would have started empty and re-dispatched. The marker carries it.
        restoreWrites(root)
        let restored = MacSyncEngine.restoreProcessedIds(dataRoot: root)
        #expect(
            Set(restored.ids).contains(msgId),
            "a completed-but-unarchived command must be known as processed after restart"
        )
        #expect(restored.message?.contains("will not be run again") == true)
    }

    @Test("a clean completion clears any marker left by an earlier attempt")
    func cleanCompletionClearsTheMarker() throws {
        let root = syncStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let msgId = "3B1C7E60-0000-0000-0000-00000000A002"
        #expect(MacSyncEngine.writeCompletedUnarchivedMarker(
            dataRoot: root, msgId: msgId, reason: "earlier failure"
        ))

        let commit = MacSyncEngine.commitCompletionBookkeeping(
            dataRoot: root, msgId: msgId, processedSaved: true, archiveError: nil
        )

        #expect(commit.clean)
        #expect(commit.syncError == nil)
        #expect(ICloudSyncStatePaths.completedUnarchivedMsgIds(dataRoot: root).isEmpty)
    }

    @Test("when even the marker cannot be written, the replay risk is stated, not swallowed")
    func markerFailureIsStatedPlainly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsync-nomarker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        // Nothing under the root can be created at all.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        let commit = MacSyncEngine.commitCompletionBookkeeping(
            dataRoot: root, msgId: "m-nomarker", processedSaved: false, archiveError: nil
        )

        #expect(commit.clean == false)
        #expect(commit.markerWritten == false)
        #expect(commit.syncError?.contains("could run again on restart") == true)
    }

    @Test("missing processed_ids.json is genesis; unreadable is not")
    func genesisIsNotTheSameAsUnreadable() throws {
        let root = syncStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Genesis: no file has ever been written.
        let genesis = MacSyncEngine.restoreProcessedIds(dataRoot: root)
        #expect(genesis.ids.isEmpty)
        #expect(genesis.unreadable == false)
        #expect(genesis.message == nil)

        // Unreadable: the window EXISTS and we cannot see it.
        try Data("{not json".utf8).write(
            to: ICloudSyncStatePaths.processedIds(dataRoot: root)
        )
        let corrupt = MacSyncEngine.restoreProcessedIds(dataRoot: root, inMemory: ["already-done"])
        #expect(corrupt.unreadable)
        #expect(corrupt.ids == ["already-done"], "an unreadable read must not erase what memory holds")
        #expect(corrupt.message?.contains("may be re-run") == true)
        #expect(
            FileManager.default.fileExists(
                atPath: ICloudSyncStatePaths.processedIdsCorruptBackup(dataRoot: root).path
            ),
            "the unreadable bytes are the recovery evidence and Doctor's durable signal"
        )
    }

    @Test("a readable list is merged with markers, not replaced by them")
    func storedWindowAndMarkersBothSurvive() throws {
        let root = syncStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode(["stored-1", "stored-2"]).write(
            to: ICloudSyncStatePaths.processedIds(dataRoot: root)
        )
        #expect(MacSyncEngine.writeCompletedUnarchivedMarker(
            dataRoot: root, msgId: "stranded-1", reason: "archive failed"
        ))

        let restored = MacSyncEngine.restoreProcessedIds(dataRoot: root)

        #expect(restored.ids == ["stored-1", "stored-2", "stranded-1"])
        #expect(restored.unreadable == false)
    }

    @Test("markers are pruned once nothing can re-present the command")
    func capTrimNeverEvictsActiveMarkerIds() throws {
        // gpt-5.5 review 2026-08-06 blocking #1: front-eviction used to hit
        // marker ids first, reopening the replay window the marker exists to
        // close. Mutation teeth: remove the markerIds exemption in
        // cappedPreservingMarkers and this fails.
        let root = syncStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let markerId = "marker-msg-1"
        #expect(MacSyncEngine.writeCompletedUnarchivedMarker(
            dataRoot: root, msgId: markerId, reason: "test"))
        // Marker near the FRONT, then a window far past the cap.
        var ids = [markerId]
        ids.append(contentsOf: (0..<50).map { "older-\($0)" })
        let capped = MacSyncEngine.cappedPreservingMarkers(ids, cap: 10, dataRoot: root)
        #expect(capped.count == 10)
        #expect(capped.contains(markerId),
            "cap trim evicted an active completed-unarchived marker — replay window reopened")
    }

    func staleMarkersArePruned() throws {
        let root = syncStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = ICloudSyncStatePaths.completedUnarchivedDirectory(dataRoot: root)
        #expect(MacSyncEngine.writeCompletedUnarchivedMarker(dataRoot: root, msgId: "old", reason: "x"))
        #expect(MacSyncEngine.writeCompletedUnarchivedMarker(dataRoot: root, msgId: "fresh", reason: "x"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-40 * 24 * 3600)],
            ofItemAtPath: dir.appendingPathComponent("old.completed-unarchived").path
        )

        MacSyncEngine.pruneCompletedUnarchivedMarkers(in: dir)

        #expect(ICloudSyncStatePaths.completedUnarchivedMsgIds(dataRoot: root) == ["fresh"])
    }

    // MARK: - Item 2

    @Test("a skipped snapshot group is named durably while the healthy groups publish")
    func skippedGroupIsNamedAndHealthyGroupsPublish() throws {
        let root = syncStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // One group fails to build; the others built fine and were published,
        // which is exactly why they must NOT appear in the skip record.
        let approvals = SnapshotGroupBuild.skipped("approval store unreadable: EIO")
        let inbox = SnapshotGroupBuild.built(Data("[]".utf8))
        #expect(approvals.data == nil)
        #expect(approvals.skipReason == "approval store unreadable: EIO")
        #expect(inbox.data != nil, "a healthy group still yields bytes to publish")
        #expect(inbox.skipReason == nil)

        MacSyncEngine.persistSnapshotSkipState(
            ["approvals": approvals.skipReason ?? ""],
            dataRoot: root
        )

        let url = ICloudSyncStatePaths.snapshotSkips(dataRoot: root)
        let recorded = try JSONDecoder().decode(
            [String: String].self, from: try Data(contentsOf: url)
        )
        #expect(recorded["approvals"]?.contains("unreadable") == true)
        #expect(recorded["inbox"] == nil, "a published group must never be reported as stale")
        #expect(recorded["_observedAt"] != nil)
    }

    @Test("a clean pass removes the skip record so a recovered group stops being reported")
    func cleanPassClearsTheSkipRecord() throws {
        let root = syncStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        MacSyncEngine.persistSnapshotSkipState(["approvals": "EIO"], dataRoot: root)
        #expect(FileManager.default.fileExists(
            atPath: ICloudSyncStatePaths.snapshotSkips(dataRoot: root).path
        ))

        MacSyncEngine.persistSnapshotSkipState([:], dataRoot: root)

        #expect(!FileManager.default.fileExists(
            atPath: ICloudSyncStatePaths.snapshotSkips(dataRoot: root).path
        ))
    }
}
