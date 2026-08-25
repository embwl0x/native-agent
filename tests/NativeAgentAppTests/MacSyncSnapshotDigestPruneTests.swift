import Foundation
import Testing
@testable import NativeAgentApp

/// Retiring a snapshot removed its FILE (R25 sweep) but left its DIGEST in
/// icloud/snapshot_digests.json — the phone diffs against that map, so a key
/// with no file reads as "already have it". Live: 29 keys vs 24 files.
@Test func snapshotDigests_dropKeysWhoseFileIsGone() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("digest-prune-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("x".utf8).write(to: dir.appendingPathComponent("runs.json"))
    let digests = ["runs.json": "a", "capabilities.json": "b", "missions.json": "c"]
    let pruned = MacSyncEngine.digestsPrunedToExistingFiles(digests, in: dir)
    #expect(pruned == ["runs.json": "a"])
}
