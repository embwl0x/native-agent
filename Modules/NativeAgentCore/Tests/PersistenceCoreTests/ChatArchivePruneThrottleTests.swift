import Foundation
import Testing
@testable import PersistenceCore

// Perf wave 2. `ChatSessionRetention.enforce` runs inside the sessions lock on
// EVERY message append, and its first act was to stat the whole archived-
// transcript tier (1530 files on the live root) plus lock and rewrite-scan the
// archived-sessions index — almost always to conclude that nothing had aged
// past a 180-day cutoff.
//
// Wave-1 FIX-C refused to throttle retention itself because archiving removes a
// row from `sessions.json`, which `SessionDigestProvider.latestPriorSession`
// renders into the next session's prompt. That reasoning stops at the archive
// tier's edge: nothing under `chat/archive/**` reaches a prompt. These tests
// pin BOTH halves — the skip happens, and the prune still fires whenever it has
// a reason to.
@Suite("Chat archive prune throttle", .serialized)
struct ChatArchivePruneThrottleTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatArchivePrune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ChatSessionRetention._resetArchivePruneThrottleForTesting()
        return root
    }

    private func archiveMessagesDir(_ root: URL) -> URL {
        root.appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
    }

    /// Writes an archived transcript whose mtime is `ageDays` old.
    @discardableResult
    private func makeArchivedTranscript(_ root: URL, name: String, ageDays: Double, now: Date) throws -> URL {
        let dir = archiveMessagesDir(root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).jsonl")
        try Data("{\"role\":\"user\"}\n".utf8).write(to: file)
        let stamp = now.addingTimeInterval(-ageDays * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        return file
    }

    /// An empty `chat/sessions.json` so `enforce` reaches the prune and then
    /// returns without touching the hot tier.
    private func writeEmptySessionsIndex(_ root: URL) throws {
        let chat = root.appendingPathComponent("chat", isDirectory: true)
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: chat.appendingPathComponent("sessions.json"))
    }

    @Test func firstPassOnAFreshRootPrunes() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try writeEmptySessionsIndex(root)
        let aged = try makeArchivedTranscript(root, name: "old", ageDays: 400, now: now)

        _ = try ChatSessionRetention.enforce(dataRoot: root, now: now)

        #expect(
            !FileManager.default.fileExists(atPath: aged.path),
            "the first pass this process makes against a root always prunes"
        )
    }

    // MUTATION TEST — the throttle must never turn the prune off. A file that
    // ages past the cutoff while the tier is otherwise IDLE (no archival, no
    // change signal at all) must still be deleted once the interval elapses.
    // This is the test that fails if the gate is ever narrowed to a pure
    // (mtime,size) change check, which time alone would never trip.
    @Test func aFileThatAgesPastTheCutoffIsStillPrunedAfterTheInterval() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try writeEmptySessionsIndex(root)

        // Young enough to survive the first pass.
        let file = try makeArchivedTranscript(root, name: "ageing", ageDays: 10, now: now)
        _ = try ChatSessionRetention.enforce(dataRoot: root, now: now)
        #expect(FileManager.default.fileExists(atPath: file.path), "not old enough yet")

        // The file did not change; the CLOCK did. Nothing about the tier's
        // (mtime,size) differs — only the interval has elapsed.
        let later = now.addingTimeInterval(
            ChatSessionRetention.archivedMessageRetentionSeconds
                + ChatSessionRetention.pruneMinIntervalSeconds + 60
        )
        _ = try ChatSessionRetention.enforce(dataRoot: root, now: later)

        #expect(
            !FileManager.default.fileExists(atPath: file.path),
            "an idle tier must still be pruned once the interval elapses — the throttle bounds latency, not behaviour"
        )
    }

    @Test func aSecondPassWithinTheIntervalOnAnUnchangedTierSkips() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try writeEmptySessionsIndex(root)
        try makeArchivedTranscript(root, name: "fresh", ageDays: 1, now: now)
        _ = try ChatSessionRetention.enforce(dataRoot: root, now: now)

        let afterFirst = ChatSessionRetention._archivePruneRunCountForTesting()
        #expect(afterFirst == 1)

        // Four more appends' worth of enforce passes, all inside the interval
        // with an untouched tier: the live shape is many messages per minute.
        for step in 1...4 {
            _ = try ChatSessionRetention.enforce(
                dataRoot: root,
                now: now.addingTimeInterval(Double(step))
            )
        }
        #expect(
            ChatSessionRetention._archivePruneRunCountForTesting() == afterFirst,
            "an unchanged tier inside the interval must not be re-scanned"
        )

        // …and the first pass past the interval scans again, so the skip is a
        // delay and never a stop.
        _ = try ChatSessionRetention.enforce(
            dataRoot: root,
            now: now.addingTimeInterval(ChatSessionRetention.pruneMinIntervalSeconds + 60)
        )
        #expect(ChatSessionRetention._archivePruneRunCountForTesting() == afterFirst + 1)
    }

    // A CHANGED tier prunes immediately, interval or not: an archival that just
    // landed is exactly when the cap and the age sweep want to run.
    @Test func aChangedArchiveTierPrunesInsideTheInterval() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try writeEmptySessionsIndex(root)
        try makeArchivedTranscript(root, name: "fresh", ageDays: 1, now: now)
        _ = try ChatSessionRetention.enforce(dataRoot: root, now: now)

        // A new archived transcript — the directory mtime moves.
        let aged = try makeArchivedTranscript(root, name: "landed", ageDays: 400, now: now)

        _ = try ChatSessionRetention.enforce(
            dataRoot: root,
            now: now.addingTimeInterval(1)
        )
        #expect(
            !FileManager.default.fileExists(atPath: aged.path),
            "a tier that changed must be pruned on the next pass regardless of the interval"
        )
    }

    @Test func rootsAreThrottledIndependently() async throws {
        let rootA = try tempRoot()
        let rootB = try tempRoot()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let now = Date()
        try writeEmptySessionsIndex(rootA)
        try writeEmptySessionsIndex(rootB)
        try makeArchivedTranscript(rootA, name: "a", ageDays: 1, now: now)
        let agedB = try makeArchivedTranscript(rootB, name: "b", ageDays: 400, now: now)

        _ = try ChatSessionRetention.enforce(dataRoot: rootA, now: now)
        _ = try ChatSessionRetention.enforce(dataRoot: rootB, now: now)

        #expect(
            !FileManager.default.fileExists(atPath: agedB.path),
            "root A's pass must not consume root B's first-pass credit"
        )
    }

    // Retention's documented "reject cleanly and leave no archive dir behind"
    // property must survive the gate — the throttle stats the tier, it never
    // conjures it.
    @Test func throttleNeverCreatesTheArchiveDirectory() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeEmptySessionsIndex(root)

        _ = try ChatSessionRetention.enforce(dataRoot: root, now: Date())

        let archive = root.appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: archive.path))
    }
}
