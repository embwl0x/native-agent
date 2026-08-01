import Testing
import Foundation
import PersistenceCore
@testable import ChatOrchestration

/// Two lifecycle defects where a LIVE session's state was destroyed by
/// machinery that believed the session was dead (2026-08-01).
///
/// 1. `saveLocked` deleted `active_tools/<id>.json` whenever the loadout went
///    empty — reachable on a running session via `tool_unload(all)`. The lock
///    reaper reads "sibling .json absent" as "no live session", and nothing
///    refreshes the lock's mtime, so it reaped an IN-USE sidecar.
/// 2. Retention's `staleEmpty` verdict came from a pre-lock `sessions.json`
///    snapshot and was never re-checked under the transcript lock, so a first
///    message that landed in between was archived out of the hot tier.
@Suite("Chat persistence lifecycle regressions")
struct ChatPersistenceLifecycleRegressionTests {

    // MARK: - 1. Empty loadout must not look dead to the lock reaper

    private func makeToolsRoot() throws -> (root: URL, dir: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("active-tools-liveness-\(UUID().uuidString)", isDirectory: true)
        let dir = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("active_tools", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (root, dir)
    }

    @Test func unloadingEveryToolKeepsTheSessionStateFile() async throws {
        let (root, dir) = try makeToolsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "AAAA0000-0000-0000-0000-0000000000A1"
        let statePath = dir.appendingPathComponent("\(sessionId).json")

        let store = ActiveToolsStore(dataRoot: root)
        _ = try await store.addLoaded(sessionId: sessionId, names: ["bash", "read_file"])
        #expect(FileManager.default.fileExists(atPath: statePath.path))

        let emptied = try await store.removeLoaded(sessionId: sessionId, names: [], all: true)
        #expect(emptied.activeTools.isEmpty)
        #expect(
            FileManager.default.fileExists(atPath: statePath.path),
            "an empty-but-live loadout must keep its .json sibling — the reaper's liveness premise depends on it"
        )

        // An empty-state file must read back exactly like an absent one.
        let reloaded = await store.load(sessionId: sessionId)
        #expect(reloaded.activeTools.isEmpty)
        #expect(reloaded.loadedAt.isEmpty)
        #expect(reloaded.sessionId == sessionId)
    }

    @Test func liveSessionWithEmptyLoadoutSurvivesAReaperPassWithoutAmnesia() async throws {
        let (root, dir) = try makeToolsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "AAAA0000-0000-0000-0000-0000000000A2"
        let statePath = dir.appendingPathComponent("\(sessionId).json")
        let lockPath = dir.appendingPathComponent("\(sessionId).json.lock")

        // A >24h session that unloaded everything: state file empty but fresh,
        // lock sidecar old because flock never touches its mtime.
        let writer = ActiveToolsStore(dataRoot: root)
        _ = try await writer.addLoaded(sessionId: sessionId, names: ["bash"])
        _ = try await writer.removeLoaded(sessionId: sessionId, names: [], all: true)
        #expect(FileManager.default.fileExists(atPath: lockPath.path))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-47 * 24 * 60 * 60)],
            ofItemAtPath: lockPath.path
        )

        // A fresh store has never swept, so this load() runs a full reaper pass.
        let sweeper = ActiveToolsStore(dataRoot: root)
        _ = await sweeper.load(sessionId: "BBBB0000-0000-0000-0000-0000000000B1")

        #expect(
            FileManager.default.fileExists(atPath: lockPath.path),
            "the lock of a live session that merely unloaded its tools must not be reaped"
        )
        #expect(FileManager.default.fileExists(atPath: statePath.path))

        // And the session keeps working: reload a tool, read it back.
        let state = try await writer.addLoaded(sessionId: sessionId, names: ["web_search"])
        #expect(state.activeTools == ["web_search"])
        let after = await writer.load(sessionId: sessionId)
        #expect(after.activeTools.contains("web_search"), "session tool amnesia after a reaper pass")
    }

    // MARK: - 2. staleEmpty retention must re-check under the transcript lock

    private func makeChatRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-retention-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sessionsPath(_ root: URL) -> URL {
        root.appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    private func messagePath(_ root: URL, _ id: String) -> URL {
        root.appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(id).jsonl")
    }

    /// One row per (id, updatedAt, messageCount) — written as raw JSON so this
    /// suite needs nothing from PersistenceCore's internals.
    private func writeSessions(_ root: URL, _ rows: [(String, String, Int)]) throws {
        let path = sessionsPath(root)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let objects: [[String: Any]] = rows.map { id, updatedAt, count in
            [
                "id": id,
                "title": id,
                "source": "app",
                "createdAt": updatedAt,
                "updatedAt": updatedAt,
                "archived": false,
                "messageCount": count,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: objects)
        try data.write(to: path, options: .atomic)
    }

    private func writeTranscript(_ root: URL, _ id: String) throws {
        let path = messagePath(root, id)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let row: [String: Any] = [
            "id": "m1-\(id)",
            "sessionId": id,
            "role": "user",
            "content": "the first message, written after retention selected this session",
            "createdAt": "2026-06-16T11:59:00Z",
        ]
        var line = String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8) ?? "{}"
        line += "\n"
        try line.write(to: path, atomically: true, encoding: .utf8)
    }

    private func activeSessionIds(_ root: URL) throws -> [String] {
        let data = try Data(contentsOf: sessionsPath(root))
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return rows.compactMap { $0["id"] as? String }
    }

    private func iso(_ raw: String) throws -> Date {
        guard let parsed = ISO8601DateFormatter().date(from: raw) else {
            throw NSError(domain: "ChatPersistenceLifecycleRegressionTests", code: 1)
        }
        return parsed
    }

    private var policy: ChatSessionRetentionPolicy {
        ChatSessionRetentionPolicy(
            maxActiveSessions: 10,
            staleEmptySessionAgeSeconds: 24 * 60 * 60,
            includeMacPinnedSessions: false
        )
    }

    @Test func staleEmptyArchiveAbortsWhenAMessageLandedAfterSelection() throws {
        let root = try makeChatRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try iso("2026-06-16T12:00:00Z")

        // The exact on-disk state after the race: the index still says
        // messageCount 0 (snapshot taken 25h-stale), but the writer already
        // appended the session's first message and released the transcript lock.
        try writeSessions(root, [("raced", "2026-06-15T11:00:00Z", 0)])
        try writeTranscript(root, "raced")

        let report = try ChatSessionRetention.enforce(dataRoot: root, now: now, policy: policy)

        #expect(report.archivedSessions == 0, "a session that stopped being empty must not be archived")
        #expect(report.archivedEmptySessions == 0)
        #expect(report.keptSessions == 1)
        #expect(try activeSessionIds(root) == ["raced"])
        #expect(
            FileManager.default.fileExists(atPath: messagePath(root, "raced").path),
            "the live session's first message must stay in the hot tier"
        )
        let hot = try String(contentsOf: messagePath(root, "raced"), encoding: .utf8)
        #expect(hot.contains("the first message"))
    }

    @Test func genuinelyStaleEmptySessionStillArchives() throws {
        let root = try makeChatRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try iso("2026-06-16T12:00:00Z")
        try writeSessions(root, [("really-empty", "2026-06-15T11:00:00Z", 0)])
        // No transcript at all — the normal stale-empty shape.

        let report = try ChatSessionRetention.enforce(dataRoot: root, now: now, policy: policy)

        #expect(report.archivedSessions == 1)
        #expect(report.archivedEmptySessions == 1)
        #expect(try activeSessionIds(root).isEmpty)
    }

    @Test func emptyTranscriptFileDoesNotBlockStaleEmptyArchival() throws {
        let root = try makeChatRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try iso("2026-06-16T12:00:00Z")
        try writeSessions(root, [("blank-file", "2026-06-15T11:00:00Z", 0)])
        // A transcript that exists but holds only blank lines is still empty.
        let path = messagePath(root, "blank-file")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "\n\n".write(to: path, atomically: true, encoding: .utf8)

        let report = try ChatSessionRetention.enforce(dataRoot: root, now: now, policy: policy)

        #expect(report.archivedEmptySessions == 1)
        #expect(FileManager.default.fileExists(atPath: path.path) == false)
    }

    @Test func activeCapArchivalIsUnaffectedByTheStaleEmptyGuard() throws {
        let root = try makeChatRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try iso("2026-06-16T12:00:00Z")
        try writeSessions(root, [
            ("keep", "2026-06-16T11:00:00Z", 3),
            ("overflow", "2026-06-16T10:00:00Z", 3),
        ])
        try writeTranscript(root, "keep")
        try writeTranscript(root, "overflow")

        let report = try ChatSessionRetention.enforce(
            dataRoot: root,
            now: now,
            policy: ChatSessionRetentionPolicy(
                maxActiveSessions: 1,
                staleEmptySessionAgeSeconds: 24 * 60 * 60,
                includeMacPinnedSessions: false
            )
        )

        #expect(report.archivedForCap == 1)
        #expect(try activeSessionIds(root) == ["keep"])
        #expect(FileManager.default.fileExists(atPath: messagePath(root, "overflow").path) == false)
    }
}
