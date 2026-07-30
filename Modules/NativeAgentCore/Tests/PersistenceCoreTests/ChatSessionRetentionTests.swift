import Testing
import Foundation
import Darwin
@testable import PersistenceCore

@Suite("ChatSessionRetention")
struct ChatSessionRetentionTests {
    @Test func activeCap_archivesOldestSessionsAndMovesTranscripts() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try date("2026-06-16T12:00:00Z")
        try writeSessions(root: root, rows: [
            session("new-1", updatedAt: "2026-06-16T11:00:00Z", messageCount: 2),
            session("new-2", updatedAt: "2026-06-16T10:00:00Z", messageCount: 2),
            session("old-1", updatedAt: "2026-06-15T09:00:00Z", messageCount: 2),
            session("old-2", updatedAt: "2026-06-15T08:00:00Z", messageCount: 2),
        ])
        for id in ["new-1", "new-2", "old-1", "old-2"] {
            try writeTranscript(root: root, sessionId: id)
        }

        let report = try ChatSessionRetention.enforce(
            dataRoot: root,
            now: now,
            policy: ChatSessionRetentionPolicy(
                maxActiveSessions: 2,
                staleEmptySessionAgeSeconds: 24 * 60 * 60,
                includeMacPinnedSessions: false
            )
        )

        #expect(report.keptSessions == 2)
        #expect(report.archivedSessions == 2)
        #expect(report.archivedForCap == 2)
        #expect(activeSessionIds(root: root) == ["new-1", "new-2"])
        #expect(FileManager.default.fileExists(atPath: messagePath(root: root, sessionId: "old-1").path) == false)
        #expect(FileManager.default.fileExists(atPath: messagePath(root: root, sessionId: "old-2").path) == false)
        #expect(FileManager.default.fileExists(atPath: archiveMessagePath(root: root, sessionId: "old-1").path))
        #expect(FileManager.default.fileExists(atPath: archiveMessagePath(root: root, sessionId: "old-2").path))

        let archived = try archivedRows(root: root)
        #expect(archived.count == 2)
        #expect(archived.compactMap { string($0["id"]) } == ["old-1", "old-2"])
        #expect(archived.allSatisfy { string($0["retentionReason"]) == "active_cap" })
        #expect(archived.allSatisfy { string($0["archivedBy"]) == "chat_session_retention" })
    }

    @Test func staleEmptySession_archivesMetadataOnlySession() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try date("2026-06-16T12:00:00Z")
        try writeSessions(root: root, rows: [
            session("recent-empty", updatedAt: "2026-06-16T11:30:00Z", messageCount: 0),
            session("old-empty", updatedAt: "2026-06-14T11:30:00Z", messageCount: 0),
            session("old-nonempty", updatedAt: "2026-06-14T11:00:00Z", messageCount: 1),
        ])

        let report = try ChatSessionRetention.enforce(
            dataRoot: root,
            now: now,
            policy: ChatSessionRetentionPolicy(
                maxActiveSessions: 10,
                staleEmptySessionAgeSeconds: 24 * 60 * 60,
                includeMacPinnedSessions: false
            )
        )

        #expect(report.keptSessions == 2)
        #expect(report.archivedSessions == 1)
        #expect(report.archivedEmptySessions == 1)
        #expect(activeSessionIds(root: root) == ["recent-empty", "old-nonempty"])
        let archived = try archivedRows(root: root)
        #expect(archived.count == 1)
        #expect(string(archived[0]["id"]) == "old-empty")
        #expect(string(archived[0]["retentionReason"]) == "stale_empty")
        #expect(archived[0]["messagesArchivePath"] == nil)
    }

    @Test func archiveFailureLeavesHotIndexUnchanged() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try date("2026-06-16T12:00:00Z")
        try writeSessions(root: root, rows: [
            session("new", updatedAt: "2026-06-16T11:00:00Z", messageCount: 1),
            session("old", updatedAt: "2026-06-15T11:00:00Z", messageCount: 1),
        ])
        try writeTranscript(root: root, sessionId: "old")
        let archiveFile = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: archiveFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a directory".utf8).write(to: archiveFile)

        #expect(throws: (any Error).self) {
            _ = try ChatSessionRetention.enforce(
                dataRoot: root,
                now: now,
                policy: ChatSessionRetentionPolicy(
                    maxActiveSessions: 1,
                    staleEmptySessionAgeSeconds: 24 * 60 * 60,
                    includeMacPinnedSessions: false
                )
            )
        }
        #expect(activeSessionIds(root: root) == ["new", "old"])
        #expect(FileManager.default.fileExists(atPath: messagePath(root: root, sessionId: "old").path))
    }

    @Test func concurrentAppendAndRetentionKeepEveryRowReachableExactlyOnce() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try date("2026-06-16T12:00:00Z")
        try writeSessions(root: root, rows: [
            session("new", updatedAt: "2026-06-16T11:00:00Z", messageCount: 1),
            session("old", updatedAt: "2026-06-15T11:00:00Z", messageCount: 3),
        ])
        try writeTranscript(root: root, sessionId: "old")

        let transcriptPath = messagePath(root: root, sessionId: "old")
        let firstConcurrentRow = transcriptRow(id: "concurrent-1", sessionId: "old")
        let secondConcurrentRow = transcriptRow(id: "concurrent-2", sessionId: "old")
        let writerStarted = AsyncSignal()
        let persistence = SwiftNativePersistenceCore()
        let writer = Task.detached {
            try await persistence.withFileLock(transcriptPath) {
                try await persistence.appendJSONL(firstConcurrentRow, to: transcriptPath)
                await writerStarted.signal()
                // Hold the actual file lock for a deterministic wall-clock
                // interval. `Task.sleep` can resume after the production
                // two-second lock budget when this broad shard saturates the
                // cooperative executor, turning the test into a scheduler-load
                // lottery instead of a retention/append invariant.
                Darwin.usleep(200_000)
                try await persistence.appendJSONL(secondConcurrentRow, to: transcriptPath)
            }
        }
        await writerStarted.wait()

        let report: ChatSessionRetentionReport
        do {
            report = try await persistence.withFileLock(sessionsPath(root: root)) {
                try ChatSessionRetention.enforce(
                    dataRoot: root,
                    now: now,
                    policy: ChatSessionRetentionPolicy(
                        maxActiveSessions: 1,
                        staleEmptySessionAgeSeconds: 24 * 60 * 60,
                        includeMacPinnedSessions: false
                    )
                )
            }
        } catch {
            _ = await writer.result
            throw error
        }
        try await writer.value

        #expect(report.archivedSessions == 1)
        #expect(activeSessionIds(root: root) == ["new"])

        let archived = try archivedRows(root: root)
        let reachablePaths = Set(
            activeSessionIds(root: root)
                .map { messagePath(root: root, sessionId: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map(\.standardizedFileURL.path)
            + archived.compactMap { row -> String? in
                guard let relative = string(row["messagesArchivePath"]) else { return nil }
                return root.appendingPathComponent(relative).standardizedFileURL.path
            }
        )
        let transcriptFiles = try allTranscriptFiles(root: root)
        #expect(Set(transcriptFiles.map(\.standardizedFileURL.path)) == reachablePaths)

        let rowIds = try transcriptFiles.flatMap(transcriptRows).compactMap { string($0["id"]) }
        let expectedRowIds = ["seed-old", "concurrent-1", "concurrent-2"]
        #expect(rowIds.count == expectedRowIds.count)
        #expect(Set(rowIds) == Set(expectedRowIds))
    }

    @Test func protectedPinnedSessionsStayHotAndDoNotCountAgainstActiveCap() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try date("2026-06-16T12:00:00Z")
        try writeSessions(root: root, rows: [
            session("new-1", updatedAt: "2026-06-16T11:00:00Z", messageCount: 1),
            session("new-2", updatedAt: "2026-06-16T10:00:00Z", messageCount: 1),
            session("old-pinned", updatedAt: "2026-06-14T08:00:00Z", messageCount: 0),
            session("old-unpinned", updatedAt: "2026-06-14T07:00:00Z", messageCount: 1),
        ])
        for id in ["new-1", "new-2", "old-pinned", "old-unpinned"] {
            try writeTranscript(root: root, sessionId: id)
        }

        let report = try ChatSessionRetention.enforce(
            dataRoot: root,
            now: now,
            policy: ChatSessionRetentionPolicy(
                maxActiveSessions: 2,
                staleEmptySessionAgeSeconds: 24 * 60 * 60,
                protectedSessionIds: ["old-pinned"],
                includeMacPinnedSessions: false
            )
        )

        #expect(report.keptSessions == 3)
        #expect(report.archivedSessions == 1)
        #expect(activeSessionIds(root: root) == ["new-1", "new-2", "old-pinned"])
        #expect(FileManager.default.fileExists(atPath: messagePath(root: root, sessionId: "old-pinned").path))
        #expect(FileManager.default.fileExists(atPath: archiveMessagePath(root: root, sessionId: "old-unpinned").path))
        let archived = try archivedRows(root: root)
        #expect(archived.compactMap { string($0["id"]) } == ["old-unpinned"])
    }

    @Test func sharedPinnedSessionFileProtectsSessionFromRetention() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try date("2026-06-16T12:00:00Z")
        try writeSessions(root: root, rows: [
            session("new-1", updatedAt: "2026-06-16T11:00:00Z", messageCount: 1),
            session("new-2", updatedAt: "2026-06-16T10:00:00Z", messageCount: 1),
            session("old-shared-pin", updatedAt: "2026-06-14T08:00:00Z", messageCount: 0),
            session("old-unpinned", updatedAt: "2026-06-14T07:00:00Z", messageCount: 1),
        ])
        try ChatSessionRetention.saveMacPinnedChatSessionIds(["old-shared-pin"], dataRoot: root)

        let report = try ChatSessionRetention.enforce(
            dataRoot: root,
            now: now,
            policy: ChatSessionRetentionPolicy(
                maxActiveSessions: 2,
                staleEmptySessionAgeSeconds: 24 * 60 * 60,
                includeMacPinnedSessions: true
            )
        )

        #expect(report.keptSessions == 3)
        #expect(report.archivedSessions == 1)
        #expect(activeSessionIds(root: root) == ["new-1", "new-2", "old-shared-pin"])
        let archived = try archivedRows(root: root)
        #expect(archived.compactMap { string($0["id"]) } == ["old-unpinned"])
    }

    @Test func archivePrune_dropsAgedTranscriptsAndCapsSessionsIndex() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try date("2026-06-16T12:00:00Z")

        let archiveDir = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
        let archivedMessages = archiveDir.appendingPathComponent("messages", isDirectory: true)
        try FileManager.default.createDirectory(at: archivedMessages, withIntermediateDirectories: true)

        // One fresh archived transcript, one aged well past the 180-day window.
        let fresh = archivedMessages.appendingPathComponent("fresh.jsonl")
        let aged = archivedMessages.appendingPathComponent("aged.jsonl")
        try "{}\n".write(to: fresh, atomically: true, encoding: .utf8)
        try "{}\n".write(to: aged, atomically: true, encoding: .utf8)
        let old = now.addingTimeInterval(-(ChatSessionRetention.archivedMessageRetentionSeconds + 86_400))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: aged.path)

        // Archived sessions index over the line cap → trimmed to the newest N.
        let sessionsIndex = archiveDir.appendingPathComponent("sessions.jsonl")
        let overflow = ChatSessionRetention.archivedSessionsIndexMaxLines + 25
        var lines = ""
        for i in 0..<overflow { lines += "{\"id\":\"a-\(i)\"}\n" }
        try lines.write(to: sessionsIndex, atomically: true, encoding: .utf8)

        // enforce runs the prune even with no live sessions to archive.
        _ = try ChatSessionRetention.enforce(dataRoot: root, now: now)

        #expect(FileManager.default.fileExists(atPath: fresh.path), "fresh transcript must survive")
        #expect(!FileManager.default.fileExists(atPath: aged.path), "aged transcript must be pruned")

        let kept = try String(contentsOf: sessionsIndex, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(kept.count == ChatSessionRetention.archivedSessionsIndexMaxLines)
        // Newest row survived, oldest dropped.
        #expect(kept.joined().contains("\"a-\(overflow - 1)\""))
        #expect(!kept.joined().contains("\"a-0\""))
    }

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func session(_ id: String, updatedAt: String, messageCount: Int64) -> JSONValue {
        .object([
            "id": .string(id),
            "title": .string(id),
            "source": .string("app"),
            "createdAt": .string(updatedAt),
            "updatedAt": .string(updatedAt),
            "archived": .bool(false),
            "messageCount": .int(messageCount),
        ])
    }

    private func writeSessions(root: URL, rows: [JSONValue]) throws {
        let path = sessionsPath(root: root)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONValue.array(rows).serializedData(pretty: true).write(to: path)
    }

    private func writeTranscript(root: URL, sessionId: String) throws {
        try FileManager.default.createDirectory(
            at: messagePath(root: root, sessionId: sessionId).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let line = try transcriptRow(id: "seed-\(sessionId)", sessionId: sessionId).serialize(pretty: false)
        try (line + "\n").write(to: messagePath(root: root, sessionId: sessionId), atomically: true, encoding: .utf8)
    }

    private func transcriptRow(id: String, sessionId: String) -> JSONValue {
        .object([
            "id": .string(id),
            "sessionId": .string(sessionId),
            "role": .string("user"),
            "content": .string(id),
            "createdAt": .string("2026-06-16T00:00:00Z"),
        ])
    }

    private func activeSessionIds(root: URL) -> [String] {
        let path = sessionsPath(root: root)
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONValue.parse(data),
              case .array(let rows) = parsed else {
            return []
        }
        return rows.compactMap { row in
            guard case .object(let object) = row else { return nil }
            return string(object["id"])
        }
    }

    private func archivedRows(root: URL) throws -> [[String: JSONValue]] {
        let path = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent("sessions.jsonl")
        let text = try String(contentsOf: path, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            guard let data = String(raw).data(using: .utf8),
                  let parsed = try? JSONValue.parse(data),
                  case .object(let object) = parsed else {
                return nil
            }
            return object
        }
    }

    private func messagePath(root: URL, sessionId: String) -> URL {
        root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    private func sessionsPath(root: URL) -> URL {
        root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    private func allTranscriptFiles(root: URL) throws -> [URL] {
        let directories = [
            root
                .appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("messages", isDirectory: true),
            root
                .appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("archive", isDirectory: true)
                .appendingPathComponent("messages", isDirectory: true),
        ]
        return try directories.flatMap { directory in
            guard FileManager.default.fileExists(atPath: directory.path) else { return [URL]() }
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "jsonl" }
        }
    }

    private func transcriptRows(at path: URL) throws -> [[String: JSONValue]] {
        let text = try String(contentsOf: path, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            guard let data = String(raw).data(using: .utf8),
                  let parsed = try? JSONValue.parse(data),
                  case .object(let object) = parsed else {
                return nil
            }
            return object
        }
    }

    private func archiveMessagePath(root: URL, sessionId: String) -> URL {
        root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    private func string(_ value: JSONValue?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        return raw
    }

    private func date(_ raw: String) throws -> Date {
        guard let parsed = ISO8601DateFormatter().date(from: raw) else {
            throw NSError(domain: "ChatSessionRetentionTests", code: 1)
        }
        return parsed
    }
}

private actor AsyncSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !signaled else { return }
        signaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}
