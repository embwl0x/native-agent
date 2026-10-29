import Foundation
import os
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import CryptoKit
import Darwin
// Blueprint: | `ChatSessionRetention+StateExpiry.swift` | Bounded orphan session-state expiry under the caller's locked index snapshot; one archive-tier change/interval admission mark, with canonical history never expired |

extension ChatSessionRetention {
    /// Expire orphaned `chat/session_state/<id>/` derived state, never transcripts.
    public static let sessionStateRetentionSeconds: TimeInterval = 30 * 24 * 60 * 60
    /// Bound each prune pass to this many orphan state dirs while holding the sessions lock.
    public static let sessionStatePruneMaxPerPass = 200

    /// Archive changes trigger disposable-state cleanup; canonical history never expires.
    static func pruneArchive(dataRoot: URL, now: Date, rows: [[String: JSONValue]]) {
        let archiveDir = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)

        guard pruneIsDue(archiveDir: archiveDir, now: now) else { return }

        pruneSessionState(dataRoot: dataRoot, now: now, rows: rows)
    }

    /// Remove only orphaned `chat/session_state/<id>/` dirs whose newest directory/child
    /// mtime predates retention. Best-effort and bounded; canonical history never expires.
    private static func pruneSessionState(dataRoot: URL, now: Date, rows: [[String: JSONValue]]) {
        let fm = FileManager.default
        let chatDir = dataRoot.appendingPathComponent("chat", isDirectory: true)
        let stateDir = chatDir.appendingPathComponent("session_state", isDirectory: true)
        guard fm.fileExists(atPath: stateDir.path) else { return }

        var liveDirNames = Set<String>()
        for row in rows {
            guard case .string(let id)? = row["id"],
                  let safe = NativeAgentChatSessionID.normalizedPathComponent(id) else { continue }
            liveDirNames.insert(safe)
        }

        guard let entries = try? fm.contentsOfDirectory(
            at: stateDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = now.addingTimeInterval(-sessionStateRetentionSeconds)
        var removed = 0
        for entry in entries {
            if removed >= sessionStatePruneMaxPerPass { break }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  !liveDirNames.contains(entry.lastPathComponent),
                  newestModification(in: entry) < cutoff,
                  (try? fm.removeItem(at: entry)) != nil else { continue }
            removed += 1
        }
    }

    /// Newest directory/child mtime; undatable entries stay protected as `distantFuture`.
    private static func newestModification(in directory: URL) -> Date {
        func mtime(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantFuture
        }
        var newest = mtime(directory)
        if let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) {
            for child in children {
                newest = max(newest, mtime(child))
            }
        }
        return newest
    }

    /// Longest derived state goes without an opportunistic cleanup pass.
    public static let pruneMinIntervalSeconds: TimeInterval = 10 * 60

    private struct PruneMark {
        let at: Date
        let stamps: [SnapshotTailOpLog.FileStamp]
    }

    private static let pruneMarks = OSAllocatedUnfairLock(initialState: [String: PruneMark]())
    /// At the cap, inserting a new root evicts only the stalest mark.
    private static let pruneMarksMax = 16

    /// Record only admitted passes, preserving skipped deadlines and the pre-scan
    /// stamp so mid-pass archivals remain visible to the next pass.
    private static func pruneIsDue(archiveDir: URL, now: Date) -> Bool {
        let key = archiveDir.resolvingSymlinksInPath().path
        guard let messages = SnapshotTailOpLog.fileStamp(archiveDir.appendingPathComponent("messages", isDirectory: true)),
              let index = SnapshotTailOpLog.fileStamp(archiveDir.appendingPathComponent("sessions.jsonl")) else { return true }
        let stamps = [messages, index]
        return pruneMarks.withLock { marks in
            if let mark = marks[key],
               mark.stamps == stamps,
               now.timeIntervalSince(mark.at) < pruneMinIntervalSeconds,
               now >= mark.at {
                return false
            }
            evictStalestMarkIfAtCap(&marks, insertingKey: key)
            marks[key] = PruneMark(at: now, stamps: stamps)
            return true
        }
    }

    private static func evictStalestMarkIfAtCap(_ pruneMarks: inout [String: PruneMark], insertingKey key: String) {
        if pruneMarks[key] == nil, pruneMarks.count >= pruneMarksMax,
           let oldest = pruneMarks.min(by: { $0.value.at < $1.value.at })?.key {
            pruneMarks.removeValue(forKey: oldest)
        }
    }

}
