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
                kept.append(row)
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
    private static func pruneArchive(dataRoot: URL, now: Date) {
        let fm = FileManager.default
        let archiveDir = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)

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
