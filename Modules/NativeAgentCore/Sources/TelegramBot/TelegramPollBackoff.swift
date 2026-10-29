// Poll retries use a 1s base/60s cap; menu sync uses a 5s base/300s cap.
// Both double with ±20% jitter clamped to the cap and reset on success.

import Foundation
import NativeAgentCore
import PersistenceCore
import BackgroundLoops

// Blueprint: | `TelegramPollBackoff.swift` | `TelegramExponentialBackoff` and `TelegramErrorLog`: poll/menu failure cadence and locked bounded error-log rotation |

// MARK: - TelegramExponentialBackoff

/// Deadline-gated retries using LoopFailureBackoffPolicy; callers skip work until due.
public actor TelegramExponentialBackoff {
    private let policy: LoopFailureBackoffPolicy

    private var consecutiveFailures: Int = 0
    private var nextAttemptAt: Date?

    public init(
        baseDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 60
    ) {
        self.policy = LoopFailureBackoffPolicy(baseDelay: baseDelay, maxDelay: maxDelay)
    }

    /// True when no failure window is open (never failed, or the deadline
    /// from the last recorded failure has passed).
    public func shouldAttempt() -> Bool {
        guard let nextAttemptAt else { return true }
        return Date() >= nextAttemptAt
    }

    /// Record one failed attempt; arms the next deadline and returns the
    /// delay that was applied (post-jitter, post-clamp).
    @discardableResult
    public func recordFailure() -> TimeInterval {
        consecutiveFailures += 1
        let delay = policy.delay(forConsecutiveFailures: consecutiveFailures) { Double.random(in: $0) }
        nextAttemptAt = Date().addingTimeInterval(delay)
        return delay
    }

    /// One success resets the curve: counter to zero, no open window.
    public func recordSuccess() {
        consecutiveFailures = 0
        nextAttemptAt = nil
    }

    public func failureCount() -> Int {
        consecutiveFailures
    }
}

// MARK: - TelegramErrorLog

/// Appends to `<dataRoot>/telegram/errors.jsonl` under a sidecar flock.
/// At the size cap, replaces the single `<name>.1` backup before appending.
/// Append/rotation failures are logged without interrupting polling.
public enum TelegramErrorLog {

    /// Live-log rotation threshold: 5 MiB.
    public static let maxBytes = 5 * 1024 * 1024

    /// Appends under flock, rotating first at `maxBytes`; logs failures without throwing.
    public static func append(
        _ row: JSONValue,
        to logURL: URL
    ) async {
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await SwiftNativePersistenceCore.withFileLock(logURL) {
                rotateIfNeeded(logURL)
                try await SwiftNativePersistenceCore.appendJSONL(row, to: logURL)
            }
        } catch {
            FileHandle.standardError.write(
                Data("TelegramErrorLog: append failed (fail-open): \(error)\n".utf8)
            )
        }
    }

    /// Replaces `<name>.1` when the live log reaches `maxBytes`; caller holds the flock.
    /// A rotation error is logged and append proceeds on the live file.
    static func rotateIfNeeded(_ logURL: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size >= maxBytes
        else { return }
        let backup = logURL.appendingPathExtension("1")
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: backup.path) {
                try fm.removeItem(at: backup)
            }
            try fm.moveItem(at: logURL, to: backup)
        } catch {
            FileHandle.standardError.write(
                Data("TelegramErrorLog: rotation failed (fail-open): \(error)\n".utf8)
            )
        }
    }
}
