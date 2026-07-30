// U5 W-D "comms resilience" (2026-06-11): poll backoff + errors.jsonl cap.
//
// Before this file existed there was NO backoff machinery anywhere in the
// TelegramBot module (plan audit, grep-verified): an offline Mac meant the
// 2s-interval poll loop hammered a dead network every tick and appended a
// row to errors.jsonl each time, and a failed setMyCommands re-attempted on
// EVERY tick forever. Two pieces fix that:
//
//   * `TelegramExponentialBackoff` — deadline-gate backoff state. No sleeps:
//     callers ask `shouldAttempt()` and simply skip the work while a failure
//     window is open, so the scheduler keeps its cheap cadence and a tick
//     during the window costs one timestamp comparison. Clock and jitter RNG
//     are injectable so tests run on virtual time.
//   * `TelegramErrorLog` — flock'd append with size-cap rotation for
//     errors.jsonl, mirroring the MemoryV2 dedup_shadow recipe (5MB cap,
//     single `.1` backup, rotate inside the same critical section as the
//     append so a concurrent appender can't write between the move and the
//     append; fail-open on rotation errors).

import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - TelegramExponentialBackoff

/// Exponential backoff state for transient failures in the Telegram poll
/// loop (and its command-menu sync). Curve: `base * multiplier^(n-1)`,
/// capped at `maxDelay`, then jittered by a uniform factor from
/// `jitterRange`; the jittered delay is re-clamped to `maxDelay` so the
/// documented cap is a hard ceiling (at the cap, jitter spreads attempts
/// DOWNWARD — that still de-synchronizes multiple instances without ever
/// exceeding the cap). One success resets the curve to zero.
public actor TelegramExponentialBackoff {
    private let baseDelay: TimeInterval
    private let maxDelay: TimeInterval
    private let multiplier: Double
    private let jitterRange: ClosedRange<Double>
    private let now: @Sendable () -> Date
    private let random: @Sendable (ClosedRange<Double>) -> Double

    private var consecutiveFailures: Int = 0
    private var nextAttemptAt: Date?

    /// Defaults are the poll-loop curve from the u5-reliability plan:
    /// 1s → 60s cap, doubling, ±20% jitter, reset on success.
    public init(
        baseDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 60,
        multiplier: Double = 2,
        jitterRange: ClosedRange<Double> = 0.8...1.2,
        now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) {
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.multiplier = max(1, multiplier)
        self.jitterRange = jitterRange
        self.now = now
        self.random = random
    }

    /// True when no failure window is open (never failed, or the deadline
    /// from the last recorded failure has passed).
    public func shouldAttempt() -> Bool {
        guard let nextAttemptAt else { return true }
        return now() >= nextAttemptAt
    }

    /// Record one failed attempt; arms the next deadline and returns the
    /// delay that was applied (post-jitter, post-clamp).
    @discardableResult
    public func recordFailure() -> TimeInterval {
        consecutiveFailures += 1
        // Exponent clamp keeps pow() finite for absurd failure counts; the
        // min() with maxDelay is what actually bounds the curve.
        let exponent = Double(min(consecutiveFailures - 1, 64))
        let raw = min(maxDelay, baseDelay * pow(multiplier, exponent))
        let delay = min(maxDelay, raw * random(jitterRange))
        nextAttemptAt = now().addingTimeInterval(delay)
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

    /// The instant the current failure window closes (nil → no window).
    public func currentDeadline() -> Date? {
        nextAttemptAt
    }
}

// MARK: - TelegramErrorLog

/// Flock'd, size-capped append for `<dataRoot>/telegram/errors.jsonl`.
/// At/over the cap the live file moves to a single `<name>.1` backup
/// (replacing any previous backup)
/// and a fresh file starts — worst case on disk ≈ 2× the cap. Crash-safety
/// reasoning is the same: the move happens inside the file's flock critical
/// section (the lock is a sidecar `.lock` file, so moving the log itself
/// under the lock is safe), and every failure is fail-open — an error-log
/// problem must never take down the poll loop that's trying to report.
public enum TelegramErrorLog {

    /// Size cap for the live errors.jsonl (same 5MB figure as the
    /// dedup_shadow ledger).
    public static let maxBytes = 5 * 1024 * 1024

    /// Append one row under flock, rotating first when the live file has
    /// reached `rotateAtBytes`. FAIL-OPEN: never throws.
    /// `rotateAtBytes` is test-injectable; production uses `maxBytes`.
    public static func append(
        _ row: JSONValue,
        to logURL: URL,
        rotateAtBytes: Int = maxBytes
    ) async {
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let persistence = SwiftNativePersistenceCore()
            try await persistence.withFileLock(logURL) {
                rotateIfNeeded(logURL, cap: rotateAtBytes)
                try await persistence.appendJSONL(row, to: logURL)
            }
        } catch {
            FileHandle.standardError.write(
                Data("TelegramErrorLog: append failed (fail-open): \(error)\n".utf8)
            )
        }
    }

    /// Rotate once the live file has reached `cap` bytes: replace any
    /// existing `<name>.1` backup with the live file; the caller's append
    /// then recreates a fresh live log. Call ONLY inside the log's flock
    /// critical section. FAIL-OPEN: a rotation error is logged and the
    /// append proceeds on the un-rotated file (worst case the log keeps
    /// growing until a later rotation succeeds).
    static func rotateIfNeeded(_ logURL: URL, cap: Int) {
        guard cap > 0,
              let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size >= cap
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
