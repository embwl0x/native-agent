import Foundation

// MARK: - ProgressNoticeChannel

/// Cross-surface progress notice channel. Real wiring (Telegram status + Mac SSE + iOS SSE)
/// happens at app level; this protocol is the uniform emit surface.
public protocol ProgressNoticeChannel: Sendable {
    func emit(_ message: String, correlationId: String?) async
}

// MARK: - MockProgressNoticeChannel

/// In-memory mock for testing. Thread-safe via NSLock.
public final class MockProgressNoticeChannel: ProgressNoticeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var _emitted: [(String, String?)] = []

    public init() {}

    public func emit(_ message: String, correlationId: String?) async {
        lock.withLock { _emitted.append((message, correlationId)) }
    }

    public var emitted: [(String, String?)] {
        lock.withLock { _emitted }
    }
}
