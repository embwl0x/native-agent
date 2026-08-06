import Foundation
import Darwin
import NativeAgentCore

public struct ChatSessionRetentionPolicy: Sendable, Equatable {
    public var maxActiveSessions: Int
    public var staleEmptySessionAgeSeconds: TimeInterval
    public var protectedSessionIds: Set<String>
    public var includeMacPinnedSessions: Bool

    public init(
        maxActiveSessions: Int = 200,
        staleEmptySessionAgeSeconds: TimeInterval = 24 * 60 * 60,
        protectedSessionIds: Set<String> = [],
        includeMacPinnedSessions: Bool = true
    ) {
        self.maxActiveSessions = maxActiveSessions
        self.staleEmptySessionAgeSeconds = staleEmptySessionAgeSeconds
        self.protectedSessionIds = protectedSessionIds
        self.includeMacPinnedSessions = includeMacPinnedSessions
    }

    public static let `default` = ChatSessionRetentionPolicy()
}

public struct ChatSessionRetentionReport: Sendable, Equatable {
    public var keptSessions: Int
    public var archivedSessions: Int
    public var archivedForCap: Int
    public var archivedEmptySessions: Int

    public init(
        keptSessions: Int = 0,
        archivedSessions: Int = 0,
        archivedForCap: Int = 0,
        archivedEmptySessions: Int = 0
    ) {
        self.keptSessions = keptSessions
        self.archivedSessions = archivedSessions
        self.archivedForCap = archivedForCap
        self.archivedEmptySessions = archivedEmptySessions
    }
}

/// Bounds the hot chat session index without hard-deleting conversations.
///
/// Caller should hold the shared `chat/sessions.json` lock when running this
/// against the live data root. Archived rows are appended to
/// `chat/archive/sessions.jsonl`; transcript files move from `chat/messages/`
/// to `chat/archive/messages/`.
///
/// Lock order is `chat/sessions.json.lock` first, then the selected
/// `chat/messages/<session>.jsonl.lock`. Transcript writers take only the
/// transcript lock while appending, release it, and only then take the sessions
/// lock to update the index. No writer may hold those locks in the reverse
/// order. If retention cannot acquire a transcript lock within its bounded
/// wait, that session stays hot for a later pass.
public enum ChatSessionRetention {
    public static let macPinnedSessionIdsDefaultsKey = "NativeAgent.pinnedChatSessionIds"

    private static let transcriptLockWaitSeconds: TimeInterval = 2
    private static let transcriptLockRetrySeconds: TimeInterval = 0.02

    /// Archived transcripts (`chat/archive/messages/*.jsonl`) older than this are
    /// pruned. The archive tier was previously UNCAPPED — sessions moved in and
    /// never left. Conservative default so nothing recent is lost.
    public static let archivedMessageRetentionSeconds: TimeInterval = 180 * 24 * 60 * 60
    /// Newest N rows kept in the archived-sessions index
    /// (`chat/archive/sessions.jsonl`); older rows drop on the next pass. One
    /// line per archived session, so this bounds a long-lived, append-only index.
    public static let archivedSessionsIndexMaxLines = 20_000

    public static func enforce(
        dataRoot: URL,
        now: Date = Date(),
        policy: ChatSessionRetentionPolicy = .default
    ) throws -> ChatSessionRetentionReport {
        // Bound the archive tier every pass (independent of the hot index; runs
        // even when there are no sessions to archive). Best-effort: a prune
        // failure must never block retention.
        pruneArchive(dataRoot: dataRoot, now: now)

        let sessionsPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        guard FileManager.default.fileExists(atPath: sessionsPath.path) else {
            return ChatSessionRetentionReport()
        }
        let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
        guard !rows.isEmpty else {
            return ChatSessionRetentionReport()
        }

        let protectedSessionIds = resolvedProtectedSessionIds(policy, dataRoot: dataRoot)
        let reasons = plannedArchiveReasons(
            rows: rows,
            now: now,
            policy: policy,
            protectedSessionIds: protectedSessionIds
        )
        guard !reasons.isEmpty else {
            return ChatSessionRetentionReport(keptSessions: rows.count)
        }

        var kept: [[String: JSONValue]] = []
        kept.reserveCapacity(rows.count - reasons.count)
        var report = ChatSessionRetentionReport()
        var staleEmptyAborts = 0
        for (index, row) in rows.enumerated() {
            guard let reason = reasons[index] else {
                kept.append(row)
                continue
            }
            if try archive(row: row, reason: reason, dataRoot: dataRoot, now: now) {
                report.archivedSessions += 1
                switch reason {
                case .activeCap:
                    report.archivedForCap += 1
                case .staleEmpty:
                    report.archivedEmptySessions += 1
                }
            } else {
                if reason == .staleEmpty { staleEmptyAborts += 1 }
                kept.append(row)
            }
        }

        // Wave-2 deferral closed (wave 5): stale-empty candidates were
        // excluded from active-cap planning on the assumption they leave.
        // An ABORTED stale-empty archive (transcript grew non-empty under
        // the lock) re-enters the active population with no planned reason,
        // so the count can exceed the cap until some later sweep. One
        // bounded re-plan over the kept rows closes that window — aborted
        // rows are non-empty now and participate as ordinary active
        // sessions. Second pass executes activeCap only, so it terminates.
        if staleEmptyAborts > 0 {
            let secondReasons = plannedArchiveReasons(
                rows: kept,
                now: now,
                policy: policy,
                protectedSessionIds: protectedSessionIds
            )
            if secondReasons.contains(where: { $0.value == .activeCap }) {
                var secondKept: [[String: JSONValue]] = []
                secondKept.reserveCapacity(kept.count)
                for (index, row) in kept.enumerated() {
                    guard secondReasons[index] == .activeCap else {
                        secondKept.append(row)
                        continue
                    }
                    if try archive(row: row, reason: .activeCap, dataRoot: dataRoot, now: now) {
                        report.archivedSessions += 1
                        report.archivedForCap += 1
                    } else {
                        secondKept.append(row)
                    }
                }
                kept = secondKept
            }
        }

        if report.archivedSessions > 0 {
            let out = try ChatSessionIndexFile.serializedData(for: kept)
            try out.write(to: sessionsPath, options: .atomic)
        }
        report.keptSessions = kept.count
        return report
    }

    public static func saveMacPinnedChatSessionIds(
        _ ids: [String],
        dataRoot: URL = defaultDataRoot()
    ) throws {
        let clean = cleanedSessionIds(ids)
        let path = macPinnedSessionIdsPath(dataRoot: dataRoot)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = try JSONValue.array(clean.map { .string($0) }).serializedData(pretty: true)
        try payload.write(to: path, options: .atomic)
    }

    private enum ArchiveReason: String {
        case activeCap = "active_cap"
        case staleEmpty = "stale_empty"
    }

    private static func plannedArchiveReasons(
        rows: [[String: JSONValue]],
        now: Date,
        policy: ChatSessionRetentionPolicy,
        protectedSessionIds: Set<String>
    ) -> [Int: ArchiveReason] {
        var reasons: [Int: ArchiveReason] = [:]

        if policy.staleEmptySessionAgeSeconds > 0 {
            for (index, row) in rows.enumerated()
            where !isProtected(row, protectedSessionIds: protectedSessionIds)
                && isStaleEmpty(row, now: now, policy: policy) {
                reasons[index] = .staleEmpty
            }
        }

        let maxActive = max(1, policy.maxActiveSessions)
        let activeIndices = rows.indices.filter {
            reasons[$0] == nil && !isProtected(rows[$0], protectedSessionIds: protectedSessionIds)
        }
        if activeIndices.count > maxActive {
            let overflow = activeIndices.count - maxActive
            for index in activeIndices.suffix(overflow) where reasons[index] == nil {
                reasons[index] = .activeCap
            }
        }

        return reasons
    }

    private static func resolvedProtectedSessionIds(
        _ policy: ChatSessionRetentionPolicy,
        dataRoot: URL
    ) -> Set<String> {
        var protected = policy.protectedSessionIds
        if policy.includeMacPinnedSessions {
            protected.formUnion(macPinnedChatSessionIds(dataRoot: dataRoot))
        }
        return protected
    }

    private static func macPinnedChatSessionIds(dataRoot: URL) -> Set<String> {
        var protected = sharedMacPinnedChatSessionIds(dataRoot: dataRoot)
        let raw = (UserDefaults.standard.string(forKey: macPinnedSessionIdsDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return protected }
        let ids: [String]
        if let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            ids = decoded
        } else {
            ids = raw.split(separator: "|").map(String.init)
        }
        protected.formUnion(cleanedSessionIds(ids))
        return protected
    }

    private static func sharedMacPinnedChatSessionIds(dataRoot: URL) -> Set<String> {
        let path = macPinnedSessionIdsPath(dataRoot: dataRoot)
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONValue.parse(data),
              case .array(let values) = parsed else {
            return []
        }
        return Set(values.compactMap { value in
            guard case .string(let id) = value else { return nil }
            let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        })
    }

    private static func macPinnedSessionIdsPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("pinned_session_ids.json")
    }

    private static func cleanedSessionIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { id -> String? in
            let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean).inserted else { return nil }
            return clean
        }
    }

    private static func isProtected(
        _ row: [String: JSONValue],
        protectedSessionIds: Set<String>
    ) -> Bool {
        guard case .string(let id)? = row["id"] else { return false }
        return protectedSessionIds.contains(id)
    }

    private static func archive(
        row: [String: JSONValue],
        reason: ArchiveReason,
        dataRoot: URL,
        now: Date
    ) throws -> Bool {
        guard case .string(let sessionId)? = row["id"],
              let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return false
        }

        let messagesPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        let archiveIndex = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent("sessions.jsonl")
        var baseArchivedRow = row
        baseArchivedRow["archived"] = .bool(true)
        baseArchivedRow["archivedBy"] = .string("chat_session_retention")
        baseArchivedRow["retentionArchivedAt"] = .string(iso8601(now))
        baseArchivedRow["retentionReason"] = .string(reason.rawValue)

        let archived = try withBoundedTranscriptLock(messagesPath) { () throws -> Bool in
            // Re-validate the staleEmpty PREMISE under the lock (2026-08-01).
            // The decision came from the pre-lock `sessions.json` snapshot; a
            // writer can append the session's first message and release the
            // transcript lock between that snapshot and here. The existence
            // check below only chose whether to COPY — it never aborted — so a
            // now-non-empty transcript was copied to the archive and the hot
            // file deleted, losing a live session's first message from the hot
            // tier. `.activeCap` archival is a size decision, not an emptiness
            // one, so it is deliberately left unchanged.
            if reason == .staleEmpty, transcriptIsNonEmpty(messagesPath) {
                return false
            }
            // Check existence only after locking: a writer may be creating the
            // first row while retention is selecting this session.
            var archivedMessagesPath: URL?
            if FileManager.default.fileExists(atPath: messagesPath.path) {
                let archiveDir = dataRoot
                    .appendingPathComponent("chat", isDirectory: true)
                    .appendingPathComponent("archive", isDirectory: true)
                    .appendingPathComponent("messages", isDirectory: true)
                try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
                let destination = try uniqueArchivePath(
                    directory: archiveDir,
                    safeSessionId: safeSessionId,
                    now: now
                )
                try FileManager.default.copyItem(at: messagesPath, to: destination)
                archivedMessagesPath = destination
            }

            var archivedRow = baseArchivedRow
            if let archivedMessagesPath {
                archivedRow["messagesArchivePath"] = .string(relativePath(archivedMessagesPath, under: dataRoot))
            }
            // Review round 2 (MED): the index has its own lock so concurrent
            // archivals of DIFFERENT sessions (each holding only their own
            // transcript lock) and the prune's cap rewrite cannot interleave
            // and drop a freshly appended row. Lock ordering is one-way
            // (transcript → index); the prune takes only the index lock.
            //
            // Round 3: a lock TIMEOUT (nil return) must not count as archived —
            // deleting the hot transcript with no index row written would
            // orphan the session. On timeout, undo the transcript copy and
            // report not-archived; retention simply retries on its next pass.
            let indexRowWritten = try withBoundedTranscriptLock(archiveIndex) {
                try appendJSONL(.object(archivedRow), to: archiveIndex)
                return true
            }
            guard indexRowWritten == true else {
                if let archivedMessagesPath {
                    try? FileManager.default.removeItem(at: archivedMessagesPath)
                }
                return false
            }

            if archivedMessagesPath != nil {
                try FileManager.default.removeItem(at: messagesPath)
            }
            return true
        }
        return archived ?? false
    }

    /// True when the transcript at `path` holds at least one non-blank JSONL
    /// line. Must be called while holding that transcript's lock. An unreadable
    /// file reads as EMPTY: a session with no transcript on disk is the normal
    /// stale-empty case, and failing closed there would park every such session
    /// hot forever.
    private static func transcriptIsNonEmpty(_ path: URL) -> Bool {
        guard let data = try? Data(contentsOf: path), !data.isEmpty else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return true }
        return text.split(separator: "\n").contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Synchronous, bounded counterpart to `PersistenceCoreProtocol.withFileLock`.
    /// `enforce` is intentionally synchronous because production callers invoke
    /// it while already inside the async sessions-file lock. This mirrors that
    /// helper's exact sidecar path, open mode, nonblocking flock, and retry
    /// cadence without parking the caller indefinitely.
    private static func withBoundedTranscriptLock<T>(
        _ targetPath: URL,
        _ body: () throws -> T
    ) throws -> T? {
        let lockPath = targetPath.path + ".lock"
        let parent = (lockPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let fd = Darwin.open(lockPath, O_CREAT | O_WRONLY, 0o600)
        if fd < 0 {
            throw NSError(
                domain: "FileLock",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "open lock failed: \(String(cString: strerror(errno)))"]
            )
        }
        var acquired = false
        defer {
            if acquired { _ = flock(fd, LOCK_UN) }
            Darwin.close(fd)
        }

        let deadline = ProcessInfo.processInfo.systemUptime + transcriptLockWaitSeconds
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                acquired = true
                break
            }
            let lockError = errno
            if lockError != EWOULDBLOCK && lockError != EINTR {
                throw NSError(
                    domain: "FileLock",
                    code: Int(lockError),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "flock LOCK_EX failed: \(String(cString: strerror(lockError)))",
                    ]
                )
            }

            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            Thread.sleep(forTimeInterval: min(transcriptLockRetrySeconds, remaining))
        }
        return try body()
    }

    /// Prune the archive tier: age-drop transcripts and line-cap the archived
    /// sessions index. Mirrors `InstalledPhysiologySoak.pruneOldDayFiles` (list,
    /// filter, drop) and never throws — pruning is opportunistic cleanup.
    ///
    /// PERF (wave 2): `enforce` runs inside the sessions lock on EVERY message
    /// append, and this pass used to `contentsOfDirectory` + per-file
    /// `resourceValues` the entire archive transcript tier every time (1530
    /// files on the live root) plus take the index lock and rewrite-scan a
    /// 20k-line cap file — all to learn that nothing had aged past a 180-day
    /// cutoff. It now runs when there is a REASON to:
    ///
    ///   • the archive tier CHANGED since the last pass (an archival landed —
    ///     new transcript file, new index row), or
    ///   • `pruneMinIntervalSeconds` has elapsed, which is what makes the
    ///     purely time-driven half (a file crossing the age cutoff, an index
    ///     that must re-cap) still happen on an idle tier, or
    ///   • this process has never pruned this root.
    ///
    /// Wave-1 FIX-C rejected throttling retention ITSELF because archiving
    /// removes a row from `sessions.json` and `SessionDigestProvider
    /// .latestPriorSession` renders the newest remaining row into the next
    /// session's prompt. That reasoning does not reach here: this function only
    /// ever touches `chat/archive/**`, which no prompt-assembly path reads. The
    /// bounded effect of the throttle is that an archived transcript already
    /// 180 days old may survive up to `pruneMinIntervalSeconds` longer, and the
    /// archived-sessions index may sit up to that long above its 20k-line cap.
    private static func pruneArchive(dataRoot: URL, now: Date) {
        let fm = FileManager.default
        let archiveDir = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)

        guard pruneIsDue(archiveDir: archiveDir, now: now) else { return }
        // Stamp the tier as it stood BEFORE the scan (gpt-5.5 wave-2
        // NEEDS_FIX): stamping after the pass would mark an archival that
        // landed mid-pass as already handled, delaying it up to the full
        // interval. Storing the pre-scan stamp means our own deletions read
        // as a change and cost one extra no-op scan next pass (≤1 per
        // interval) — a mid-pass landing is never missed.
        let preScanStamp = archiveTierStamp(archiveDir)
        defer { notePruneCompleted(archiveDir: archiveDir, now: now, stamp: preScanStamp) }

        // 1. Age-prune archived transcript files.
        let messagesDir = archiveDir.appendingPathComponent("messages", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(
            at: messagesDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let cutoff = now.addingTimeInterval(-archivedMessageRetentionSeconds)
            for file in files where file.pathExtension == "jsonl" {
                // Undatable files are LEFT (distantFuture) — never delete what we
                // cannot prove is old.
                let modified = (try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantFuture
                if modified < cutoff {
                    try? fm.removeItem(at: file)
                }
            }
        }

        // 2. Line-cap the archived sessions index to the newest N rows — via
        // the SHARED cap helper, under the same index lock the append path
        // takes (review round 2, MED: the unlocked read-suffix-write here
        // could drop a row appended by a concurrent archival).
        let sessionsIndex = archiveDir.appendingPathComponent("sessions.jsonl")
        // Guard BEFORE locking: the lock helper mkdir's the lock file's parent,
        // so taking the lock on a nonexistent index would conjure chat/archive/
        // as a side effect — and "retention rejected, nothing archived" must
        // leave no archive dir behind (pinned by ChatSessionIndexFileTests).
        guard FileManager.default.fileExists(atPath: sessionsIndex.path) else { return }
        _ = try? withBoundedTranscriptLock(sessionsIndex) {
            _ = try enforceJSONLLineCap(
                at: sessionsIndex,
                maxLines: archivedSessionsIndexMaxLines
            )
        }
    }

    // MARK: - Archive-prune throttle (perf wave 2)

    /// Longest an idle archive tier goes un-pruned. The tier is invisible to
    /// every prompt-assembly path, so this bounds only how late a 180-day-old
    /// transcript is deleted and how late the archived index is re-capped.
    public static let pruneMinIntervalSeconds: TimeInterval = 10 * 60

    /// The archive tier's cheap change signal: the (mtime, size) of the
    /// transcript directory and of the archived-sessions index. An archival
    /// mutates one or both — a new transcript file changes the directory's
    /// mtime, a new index row changes the index's mtime and size.
    private struct ArchiveTierStamp: Equatable {
        let messagesSeconds: Int
        let messagesNanoseconds: Int
        let messagesSize: Int64
        let indexSeconds: Int
        let indexNanoseconds: Int
        let indexSize: Int64
    }

    private struct PruneMark {
        let at: Date
        let stamp: ArchiveTierStamp
        /// How many passes have actually scanned this root. Lives inside the
        /// mark so the count is per-root — a process-global counter made the
        /// throttle tests racy under parallel suite execution, because every
        /// suite's temp-root prunes incremented one shared number.
        let runCount: Int
    }

    private static let pruneStateLock = NSLock()
    nonisolated(unsafe) private static var pruneMarks: [String: PruneMark] = [:]
    /// Bound on distinct data roots tracked at once — inserting a new root at
    /// the cap evicts the stalest mark, so a process that walks many temp
    /// roots (the test suite) cannot grow this map without limit, and live
    /// roots' marks survive the churn.
    private static let pruneMarksMax = 16

    private static func archiveTierStamp(_ archiveDir: URL) -> ArchiveTierStamp {
        func statOf(_ url: URL) -> (Int, Int, Int64) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return (-1, -1, -1) }
            return (info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec, Int64(info.st_size))
        }
        let messages = statOf(archiveDir.appendingPathComponent("messages", isDirectory: true))
        let index = statOf(archiveDir.appendingPathComponent("sessions.jsonl"))
        return ArchiveTierStamp(
            messagesSeconds: messages.0,
            messagesNanoseconds: messages.1,
            messagesSize: messages.2,
            indexSeconds: index.0,
            indexNanoseconds: index.1,
            indexSize: index.2
        )
    }

    /// True when the prune should actually run, and RECORDS the decision. The
    /// mark is stamped only when the answer is yes, so a skipped pass leaves
    /// the previous deadline in place rather than sliding it forward.
    private static func pruneIsDue(archiveDir: URL, now: Date) -> Bool {
        let key = archiveDir.resolvingSymlinksInPath().path
        let stamp = archiveTierStamp(archiveDir)
        pruneStateLock.lock()
        defer { pruneStateLock.unlock() }
        if let mark = pruneMarks[key],
           mark.stamp == stamp,
           now.timeIntervalSince(mark.at) < pruneMinIntervalSeconds,
           now >= mark.at {
            return false
        }
        evictStalestMarkIfAtCapLocked(insertingKey: key)
        let priorRuns = pruneMarks[key]?.runCount ?? 0
        pruneMarks[key] = PruneMark(at: now, stamp: stamp, runCount: priorRuns + 1)
        return true
    }

    /// Test seam: how many passes actually scanned THIS root's tier. Per-root
    /// so parallel suites pruning their own temp roots cannot perturb each
    /// other's readings.
    public static func _archivePruneRunCountForTesting(dataRoot: URL) -> Int {
        let key = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
            .resolvingSymlinksInPath().path
        pruneStateLock.lock()
        defer { pruneStateLock.unlock() }
        return pruneMarks[key]?.runCount ?? 0
    }

    /// Stamp with the tier as it stood BEFORE the scan (caller captures it).
    /// Our own deletions therefore read as a change next pass — one no-op
    /// rescan per real prune — in exchange for never missing an archival
    /// that lands while the pass is running.
    private static func notePruneCompleted(archiveDir: URL, now: Date, stamp: ArchiveTierStamp) {
        let key = archiveDir.resolvingSymlinksInPath().path
        pruneStateLock.lock()
        // If the key was evicted while the pass ran, the reinsert restarts the
        // run count at this pass — the history is gone with the mark. Accepted:
        // the count is a test seam, and product behaviour (when to prune) never
        // reads it.
        evictStalestMarkIfAtCapLocked(insertingKey: key)
        let priorRuns = pruneMarks[key]?.runCount ?? 1
        pruneMarks[key] = PruneMark(at: now, stamp: stamp, runCount: priorRuns)
        pruneStateLock.unlock()
    }

    /// Caller must hold `pruneStateLock`. Evicts the stalest root's mark when
    /// inserting a NEW key would exceed the cap. A blanket removeAll here
    /// wiped LIVE marks belonging to other roots mid-interval — under
    /// parallel test execution that re-armed another suite's prune inside its
    /// throttle window and made the skip tests flaky. Dropping a mark can
    /// only cause an extra prune, never a skip, so the throttle's latency
    /// bound is unchanged.
    private static func evictStalestMarkIfAtCapLocked(insertingKey key: String) {
        if pruneMarks[key] == nil, pruneMarks.count >= pruneMarksMax,
           let oldest = pruneMarks.min(by: { $0.value.at < $1.value.at })?.key {
            pruneMarks.removeValue(forKey: oldest)
        }
    }

    private static func isStaleEmpty(
        _ row: [String: JSONValue],
        now: Date,
        policy: ChatSessionRetentionPolicy
    ) -> Bool {
        guard messageCount(row) <= 0,
              let stamp = date(row["updatedAt"]) ?? date(row["createdAt"]) else {
            return false
        }
        return now.timeIntervalSince(stamp) >= policy.staleEmptySessionAgeSeconds
    }

    private static func messageCount(_ row: [String: JSONValue]) -> Int {
        switch row["messageCount"] {
        case .int(let value):
            return Int(value)
        case .double(let value):
            return Int(value)
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        default:
            return 0
        }
    }

    private static func date(_ value: JSONValue?) -> Date? {
        guard case .string(let raw)? = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: trimmed) { return parsed }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: trimmed)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func uniqueArchivePath(
        directory: URL,
        safeSessionId: String,
        now: Date
    ) throws -> URL {
        let preferred = directory.appendingPathComponent("\(safeSessionId).jsonl")
        guard FileManager.default.fileExists(atPath: preferred.path) else {
            return preferred
        }
        let stamp = iso8601(now)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        var candidate = directory.appendingPathComponent("\(safeSessionId).\(stamp).jsonl")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(safeSessionId).\(stamp).\(counter).jsonl")
            counter += 1
        }
        return candidate
    }

    private static func appendJSONL(_ record: JSONValue, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var line = try record.serialize(pretty: false)
        line += "\n"
        let bytes = Data(line.utf8)
        if FileManager.default.fileExists(atPath: path.path) {
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
        } else {
            try bytes.write(to: path, options: .atomic)
        }
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }
}
