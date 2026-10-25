import PersistenceCore
import Foundation
import NativeAgentCore
// Blueprint: | `HumanPresenceStamp.swift` | `HumanPresenceStamp` enum; durable present/away crossings at `ActivityWatchPaths.presenceTransitionURL`, shared with the scheduler through `transitionURL` |

/// Publishes present/away crossings for the trigger scheduler without app metadata.
public enum HumanPresenceStamp {
    public static func transitionURL(dataRoot: URL) -> URL {
        ActivityWatchPaths.presenceTransitionURL(dataRoot: dataRoot)
    }

    /// Touch the present <-> away crossing file. One line of state, written
    /// only at a crossing, so a background loop can watch it without waking
    /// on each capture heartbeat.
    @discardableResult
    public static func writeTransition(present: Bool, at date: Date, to url: URL) -> Bool {
        atomicallyPublish([
            "at": formatTimestamp(date),
            "state": present ? "present" : "away",
        ], to: url)
    }

    /// 2026-09-06: was `Data.write(.atomic)`, which leaves the mode to the
    /// process umask — 0644 on a default Mac. Use the canonical writer: 0600
    /// temp, fsync, rename, 0600 target.
    private static func atomicallyPublish(_ body: [String: Any], to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: body, options: [.sortedKeys]
        ) else { return false }
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        do {
            try SwiftNativePersistenceCore.atomicWrite(data, to: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Timestamps

    static func formatTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.fractionalZulu(date)
    }
}
