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

        // 2026-09-06 (24b6fed3, 91618a10): "an active-cap victim written during
        // the pass is not a victim". A writer commits its transcript row before
        // synchronizing sessions.json, and archiving in that gap deleted the
        // hot transcript while the writer's later index sync recreated an
        // active row with none of its history. This test IS that gap — the
        // concurrent writer appends while retention runs — so `old` is now
        // correctly skipped and archived next pass instead. The invariant the
        // test exists for is unchanged and asserted below: every row stays
        // reachable exactly once, through exactly one file.
        #expect(report.archivedSessions == 0)
        #expect(activeSessionIds(root: root) == ["new", "old"])

        let archived = try archivedRows(root: root)
        #expect(archived.isEmpty)
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

    // F6 (2026-08-28): orphaned chat/session_state/<id>/ dirs are pruned on
    // the archive-prune pass — no live index row AND nothing written for 30
    // days. Derived state only; transcripts live elsewhere and are untouched.
    @Test func sessionStatePrune_removesAgedOrphanKeepsLiveRecentAndTouched() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try date("2026-08-28T12:00:00Z")
        let old = now.addingTimeInterval(
            -(ChatSessionRetention.sessionStateRetentionSeconds + 86_400)
        )

        try writeSessions(root: root, rows: [
            session("live", updatedAt: "2026-08-27T12:00:00Z", messageCount: 2),
        ])
        // Live session: kept even though its state is old — liveness wins.
        let liveDir = try makeStateDir(root: root, id: "live", mtime: old)
        let agedOrphan = try makeStateDir(root: root, id: "aged-orphan", mtime: old)
        let freshOrphan = try makeStateDir(
            root: root, id: "fresh-orphan", mtime: now.addingTimeInterval(-3_600)
        )
        // Orphan whose dir is old but a child was written recently: kept —
        // the newest mtime across dir and children decides.
        let touchedOrphan = try makeStateDir(
            root: root, id: "touched-orphan", mtime: old,
            childMtime: now.addingTimeInterval(-3_600)
        )

        _ = try ChatSessionRetention.enforce(dataRoot: root, now: now)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: liveDir.path), "live session state must survive")
        #expect(!fm.fileExists(atPath: agedOrphan.path), "aged orphan must be removed")
        #expect(fm.fileExists(atPath: freshOrphan.path), "recent orphan must be kept")
        #expect(fm.fileExists(atPath: touchedOrphan.path), "recently written orphan must be kept")
    }

    @Test func sessionStatePrune_failsClosedWhenLiveIndexIsMissingOrMalformed() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try date("2026-08-28T12:00:00Z")
        let old = now.addingTimeInterval(
            -(ChatSessionRetention.sessionStateRetentionSeconds + 86_400)
        )
        let agedOrphan = try makeStateDir(root: root, id: "aged-orphan", mtime: old)

        // No sessions.json at all: nothing may be treated as an orphan.
        _ = try ChatSessionRetention.enforce(dataRoot: root, now: now)
        #expect(FileManager.default.fileExists(atPath: agedOrphan.path))

        // Malformed sessions.json: enforce throws, and the prune (which ran
        // first) must still have refused to treat the dir as an orphan.
        let sessionsPath = sessionsPath(root: root)
        try FileManager.default.createDirectory(
            at: sessionsPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not valid json".utf8).write(to: sessionsPath)
        let later = now.addingTimeInterval(ChatSessionRetention.pruneMinIntervalSeconds + 60)
        #expect(throws: (any Error).self) {
            _ = try ChatSessionRetention.enforce(dataRoot: root, now: later)
        }
        #expect(FileManager.default.fileExists(atPath: agedOrphan.path))
    }

    @Test func sessionStatePrune_boundsRemovalsPerPass() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try date("2026-08-28T12:00:00Z")
        let old = now.addingTimeInterval(
            -(ChatSessionRetention.sessionStateRetentionSeconds + 86_400)
        )
        try writeSessions(root: root, rows: [
            session("live", updatedAt: "2026-08-27T12:00:00Z", messageCount: 2),
        ])
        let overflow = 10
        for i in 0..<(ChatSessionRetention.sessionStatePruneMaxPerPass + overflow) {
            _ = try makeStateDir(root: root, id: "orphan-\(i)", mtime: old)
        }

        _ = try ChatSessionRetention.enforce(dataRoot: root, now: now)
        #expect(sessionStateDirCount(root: root) == overflow, "one pass removes at most the bound")

        // Next pass (outside the prune throttle window) clears the remainder.
        let later = now.addingTimeInterval(ChatSessionRetention.pruneMinIntervalSeconds + 60)
        _ = try ChatSessionRetention.enforce(dataRoot: root, now: later)
        #expect(sessionStateDirCount(root: root) == 0)
    }

    @Test func bestEffortLogsFailureInsteadOfSwallowingIt() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsPath = sessionsPath(root: root)
        try FileManager.default.createDirectory(
            at: sessionsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not valid json".utf8).write(to: sessionsPath)

        final class LogBox: @unchecked Sendable {
            var lines: [String] = []
        }
        let box = LogBox()
        let report = ChatSessionRetention.enforceBestEffort(
            dataRoot: root,
            now: try date("2026-06-16T12:00:00Z"),
            context: "ChatSessionRetentionTests.bestEffort",
            failureLogger: { box.lines.append($0) }
        )

        #expect(report == nil)
        #expect(box.lines.count == 1)
        let line = try #require(box.lines.first)
        #expect(line.contains("ChatSessionRetentionTests.bestEffort"))
        #expect(line.contains("ChatSessionRetention.enforce failed"))
        #expect(line.contains(root.path))
    }

    @Test func currentSwallowSitesUseBestEffortHelper() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sites: [(path: String, calls: Int, contexts: [String])] = [
            (
                "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+MessagePersistence.swift",
                1,
                ["ChatOrchestrationClient.syncSessionIndex"]
            ),
            (
                "Modules/NativeAgentCore/Sources/TelegramBot/TelegramSessionStore.swift",
                2,
                ["TelegramSessionStore.ensureSessionRow", "TelegramSessionStore.patchSessionRow"]
            ),
            (
                "Sources/NativeAgentApp/SlackSessionStore.swift",
                1,
                ["SlackSocketModeLoop.ensureSessionRow"]
            ),
            (
                "Sources/NativeAgentApp/NativeClient+ProviderTelegramSessions.swift",
                1,
                ["NativeClient.createChatSession"]
            ),
            (
                "Sources/NativeAgentApp/AppDelegate+ICloudRuntimeForwarding.swift",
                1,
                ["AppDelegate.upsertMobileChatSessionRow"]
            ),
        ]
        for site in sites {
            let source = try String(
                contentsOf: repoRoot.appendingPathComponent(site.path),
                encoding: .utf8
            )
            let helperCalls = source.components(
                separatedBy: "ChatSessionRetention.enforceBestEffort("
            ).count - 1
            #expect(
                helperCalls == site.calls,
                "\(site.path) must route all \(site.calls) swallowed calls through the logging helper"
            )
            #expect(
                !source.contains("try? ChatSessionRetention.enforce"),
                "\(site.path) must not silently swallow retention throws"
            )
            for context in site.contexts {
                #expect(source.contains("context: \"\(context)\""))
            }
        }
    }

    // MARK: - LEDGER: core.persistence.ChatSessionRetention.transcriptLockOrphaning
    //
    // THE LEAK. `withBoundedTranscriptLock` (ChatSessionRetention.swift:390) is a
    // SECOND, private lock-sidecar implementation — independent of
    // PersistenceCore+FileLock.swift — and it has no remove path. The archive
    // step MOVES the transcript out of chat/messages/ and leaves
    // `<transcript>.lock` behind forever, so the sidecar outlives the file it
    // guarded. Live measurement on User's data root (2026-08-23): 1799 lock files
    // under data/chat/messages, 1597 of them with NO sibling transcript — 67% of
    // every orphan lock in the whole data root traces to this one path. One
    // inode per archived session, forever, with no counter, no doctor check and
    // no log line anywhere.
    //
    // The contrast that proves it is a bug and not a policy: TurnTraceRetention
    // DOES sweep its locks (pinned at TurnTraceRetentionTests.swift:57) and
    // data/turn_traces shows zero orphans.
    //
    // WHY THIS TEST PINS THE LEAK INSTEAD OF FORBIDDING IT: the fix is a
    // production change and this wave is tests-only, so the honest move is exact
    // leak ACCOUNTING — one orphan per archived transcript, never more — which
    // makes the leak a build-visible number instead of an invisible one. It bites
    // in both directions: a regression that leaks MORE (e.g. a lock per retry)
    // goes red, and so does the day the sweep lands.
    //
    // WHEN THE SWEEP LANDS: change `orphanLocks.count == report.archivedSessions`
    // to `orphanLocks.isEmpty` and delete this paragraph.
    @Test func archivedTranscriptLeavesExactlyOneOrphanLockPerSession_knownLeak() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try date("2026-06-16T12:00:00Z")
        let ids = ["keep-1", "keep-2", "archive-1", "archive-2", "archive-3"]
        try writeSessions(root: root, rows: [
            session("keep-1", updatedAt: "2026-06-16T11:00:00Z", messageCount: 2),
            session("keep-2", updatedAt: "2026-06-16T10:00:00Z", messageCount: 2),
            session("archive-1", updatedAt: "2026-06-15T09:00:00Z", messageCount: 2),
            session("archive-2", updatedAt: "2026-06-15T08:00:00Z", messageCount: 2),
            session("archive-3", updatedAt: "2026-06-15T07:00:00Z", messageCount: 2),
        ])
        for id in ids { try writeTranscript(root: root, sessionId: id) }

        let messagesDir = messagePath(root: root, sessionId: "keep-1").deletingLastPathComponent()
        // Precondition: no sidecars before the pass, so every lock counted below
        // was minted by this run.
        #expect(lockFiles(in: messagesDir).isEmpty)

        let report = try ChatSessionRetention.enforce(
            dataRoot: root,
            now: now,
            policy: ChatSessionRetentionPolicy(
                maxActiveSessions: 2,
                staleEmptySessionAgeSeconds: 24 * 60 * 60,
                includeMacPinnedSessions: false
            )
        )
        #expect(report.archivedSessions == 3)

        // The transcripts really left the hot tier — otherwise "orphan" would be
        // measuring nothing.
        for id in ["archive-1", "archive-2", "archive-3"] {
            #expect(!FileManager.default.fileExists(atPath: messagePath(root: root, sessionId: id).path))
            #expect(FileManager.default.fileExists(atPath: archiveMessagePath(root: root, sessionId: id).path))
        }

        let locks = lockFiles(in: messagesDir)
        let orphanLocks = locks.filter { lock in
            let guarded = lock.deletingPathExtension()   // strip ".lock"
            return !FileManager.default.fileExists(atPath: guarded.path)
        }
        // EXACT accounting: one orphan per archived transcript, and no orphan
        // for a session that stayed hot.
        #expect(orphanLocks.count == report.archivedSessions)
        #expect(Set(orphanLocks.map { $0.deletingPathExtension().deletingPathExtension().lastPathComponent })
            == ["archive-1", "archive-2", "archive-3"])
        // Only ARCHIVED sessions ever take the transcript lock, so every sidecar
        // in the hot directory is an orphan and no kept session minted one.
        #expect(locks.count == 3)

        // The archive index's own lock is a different animal: its feed persists,
        // so that sidecar is not a leak. Counted separately so nobody "fixes"
        // this by sweeping the wrong directory.
        let archiveDir = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
        let archiveIndexOrphans = lockFiles(in: archiveDir).filter {
            !FileManager.default.fileExists(atPath: $0.deletingPathExtension().path)
        }
        #expect(archiveIndexOrphans.isEmpty)
    }

    /// The leak COMPOUNDS: a second archiving pass over fresh sessions adds one
    /// more orphan each and never reclaims the first pass's. This is the
    /// unbounded-growth half of the claim, stated as a delta so it cannot be
    /// satisfied by a one-shot coincidence.
    @Test func orphanLockCountGrowsMonotonicallyAcrossPasses_knownLeak() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = ChatSessionRetentionPolicy(
            maxActiveSessions: 1,
            staleEmptySessionAgeSeconds: 24 * 60 * 60,
            includeMacPinnedSessions: false
        )
        let messagesDir = messagePath(root: root, sessionId: "probe").deletingLastPathComponent()

        func runPass(_ pass: Int) throws -> Int {
            let ids = ["hot-\(pass)", "cold-\(pass)a", "cold-\(pass)b"]
            try writeSessions(root: root, rows: [
                session(ids[0], updatedAt: "2026-06-16T11:00:00Z", messageCount: 2),
                session(ids[1], updatedAt: "2026-06-15T09:00:00Z", messageCount: 2),
                session(ids[2], updatedAt: "2026-06-15T08:00:00Z", messageCount: 2),
            ])
            for id in ids { try writeTranscript(root: root, sessionId: id) }
            let report = try ChatSessionRetention.enforce(
                dataRoot: root,
                now: try date("2026-06-16T12:00:00Z"),
                policy: policy
            )
            #expect(report.archivedSessions == 2)
            return lockFiles(in: messagesDir).filter {
                !FileManager.default.fileExists(atPath: $0.deletingPathExtension().path)
            }.count
        }

        let afterFirst = try runPass(1)
        let afterSecond = try runPass(2)
        #expect(afterFirst == 2)
        #expect(afterSecond == afterFirst + 2, "each pass leaves its archived sessions' sidecars behind")
    }

    private func lockFiles(in directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { $0.pathExtension == "lock" }.sorted { $0.path < $1.path }
    }

    /// Creates `chat/session_state/<id>/` with a digest child, then pins the
    /// child's and (last, so the file writes don't refresh it) the dir's mtime.
    private func makeStateDir(
        root: URL,
        id: String,
        mtime: Date,
        childMtime: Date? = nil
    ) throws -> URL {
        let dir = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("session_state", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digest = dir.appendingPathComponent("digest.txt")
        try "digest".write(to: digest, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: childMtime ?? mtime], ofItemAtPath: digest.path
        )
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: dir.path)
        return dir
    }

    private func sessionStateDirCount(root: URL) -> Int {
        let stateDir = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("session_state", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix("orphan-") }.count
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

    /// 2026-09-06 (91618a10): retention refuses to archive a transcript that is
    /// NEWER than its own index row's `updatedAt` — that gap is a pending index
    /// sync, and archiving into it deleted the hot transcript while the
    /// writer's sync then recreated an active row with none of its history. A
    /// freshly written fixture file carries the wall-clock mtime of the test
    /// run, which is years after the synthetic `updatedAt` stamps these rows
    /// use, so every session looked like a writer mid-sync and nothing was ever
    /// a victim. Stamp the transcript as SYNCED: mtime at or before the index
    /// row, which is what a quiet, archivable session looks like on disk.
    private func writeTranscript(
        root: URL,
        sessionId: String,
        syncedAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) throws {
        try FileManager.default.createDirectory(
            at: messagePath(root: root, sessionId: sessionId).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let path = messagePath(root: root, sessionId: sessionId)
        let line = try transcriptRow(id: "seed-\(sessionId)", sessionId: sessionId).serialize(pretty: false)
        try (line + "\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: syncedAt], ofItemAtPath: path.path)
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
        // 2026-09-06: a pass that archives nothing writes no archive index, and
        // "no archive index" means "nothing archived" — not a read failure.
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
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
