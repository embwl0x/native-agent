
import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
import BackgroundLoops

// Blueprint: | `TelegramPollBackoff.swift` | `TelegramExponentialBackoff`, `TelegramErrorLog`: bounded locked rotation |

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

    public func shouldAttempt() -> Bool {
        guard let nextAttemptAt else { return true }
        return Date() >= nextAttemptAt
    }

    @discardableResult
    public func recordFailure() -> TimeInterval {
        consecutiveFailures += 1
        let delay = policy.delay(forConsecutiveFailures: consecutiveFailures) { Double.random(in: $0) }
        nextAttemptAt = Date().addingTimeInterval(delay)
        return delay
    }

    public func recordSuccess() {
        consecutiveFailures = 0
        nextAttemptAt = nil
    }

    public func failureCount() -> Int {
        consecutiveFailures
    }
}

// MARK: - TelegramErrorLog

/// Rotation and append are one locked transaction; failure prevents append.
public enum TelegramErrorLog {
    public static let maxBytes = 5 * 1024 * 1024

    public static func append(_ row: JSONValue, to logURL: URL) async throws {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try await SwiftNativePersistenceCore.withFileLock(logURL) {
            try rotateIfNeeded(logURL)
            try await SwiftNativePersistenceCore.appendJSONL(row, to: logURL)
        }
    }

    /// Only a checked missing live file needs no rotation. Caller holds its lock.
    static func rotateIfNeeded(_ logURL: URL) throws {
        var info = stat()
        guard lstat(logURL.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw PersistenceCoreError.ioFailure("Telegram error log must be a regular file: \(logURL.path)")
        }
        guard info.st_size >= Int64(maxBytes) else { return }
        let backup = logURL.appendingPathExtension("1")
        let fm = FileManager.default
        if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
        try fm.moveItem(at: logURL, to: backup)
    }
}
