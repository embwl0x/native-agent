import Testing
import Foundation
@testable import ChatOrchestration

/// The orphan sweep only ever visited `pathExtension == "json"`, so every
/// ended session left a permanent 0-byte `<id>.json.lock` behind: 7159 locks
/// against 2 live state files by 2026-07-25, oldest 2026-06-08 (Agent). Same
/// unbounded-directory class the loop-A sweep was written to stop, on the
/// extension it did not match. These tests pin the reap and — more important —
/// pin what it must NOT touch.
@Suite("ActiveToolsStore lock sidecar sweep")
struct ActiveToolsLockSweepTests {
    private func makeDirs() throws -> (root: URL, dir: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("active-tools-locksweep-\(UUID().uuidString)", isDirectory: true)
        let dir = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("active_tools", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (root, dir)
    }

    private func write(_ url: URL, _ contents: String, ageDays: Double) throws {
        try Data(contents.utf8).write(to: url)
        let mtime = Date().addingTimeInterval(-ageDays * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    @Test func staleOrphanLocksAreReapedAndLiveOnesAreNot() async throws {
        let (root, dir) = try makeDirs()

        // 1. Stale orphan: no sibling .json, old. MUST be reaped.
        let orphan = dir.appendingPathComponent("AAAAAAAA-0000-0000-0000-000000000001.json.lock")
        try write(orphan, "", ageDays: 47)

        // 2. Stale lock WITH a live sibling .json. MUST survive — a session
        //    whose state is still present still owns its lock.
        let livePaired = dir.appendingPathComponent("BBBBBBBB-0000-0000-0000-000000000002.json")
        try write(livePaired, #"{"sessionId":"BBBBBBBB-0000-0000-0000-000000000002","activeTools":[]}"#, ageDays: 0)
        let pairedLock = dir.appendingPathComponent("BBBBBBBB-0000-0000-0000-000000000002.json.lock")
        try write(pairedLock, "", ageDays: 47)

        // 3. Recent orphan lock — inside the TTL, so a session could still be
        //    mid-flight. MUST survive.
        let recentOrphan = dir.appendingPathComponent("CCCCCCCC-0000-0000-0000-000000000003.json.lock")
        try write(recentOrphan, "", ageDays: 0)

        // A fresh store has never swept, so load() triggers one pass.
        let store = ActiveToolsStore(dataRoot: root)
        _ = await store.load(sessionId: "DDDDDDDD-0000-0000-0000-000000000004")

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: orphan.path), "stale orphan lock must be reaped")
        #expect(fm.fileExists(atPath: pairedLock.path), "a lock whose sibling .json is live must survive")
        #expect(fm.fileExists(atPath: recentOrphan.path), "a lock inside the TTL must survive")
    }

    @Test func sweepReclaimsABacklogOfOrphanLocks() async throws {
        let (root, dir) = try makeDirs()
        for i in 0..<200 {
            let url = dir.appendingPathComponent(String(format: "EEEEEEEE-0000-0000-0000-%012d.json.lock", i))
            try write(url, "", ageDays: 47)
        }
        let store = ActiveToolsStore(dataRoot: root)
        _ = await store.load(sessionId: "FFFFFFFF-0000-0000-0000-000000000005")

        let remaining = (try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "lock" && $0.lastPathComponent.hasPrefix("EEEEEEEE") }
        #expect(remaining.isEmpty, "the whole stale backlog must clear in one pass, not one file per hour")
    }

    @Test func reapedLockDoesNotBreakASubsequentSessionWrite() async throws {
        let (root, dir) = try makeDirs()
        let sessionId = "12345678-0000-0000-0000-000000000006"
        let orphan = dir.appendingPathComponent("\(sessionId).json.lock")
        try write(orphan, "", ageDays: 47)

        // The same session id comes back to life after its lock was reaped —
        // the write path must simply re-create the sidecar and persist.
        let store = ActiveToolsStore(dataRoot: root)
        _ = await store.load(sessionId: sessionId)
        let state = try await store.addLoaded(sessionId: sessionId, names: ["bash"])
        #expect(state.activeTools.contains("bash"))
        let reloaded = await store.load(sessionId: sessionId)
        #expect(reloaded.activeTools.contains("bash"))
    }
}
