// Scripted LLMClient for tests (moved out of DreamREMCycle — no production caller).

import Foundation
import NativeAgentCore

/// Sendable mock that returns scripted responses round-robin. Tracks call count
/// behind an NSLock so it's safe to share across async tasks.
public final class MockLLMClient: LLMClient, @unchecked Sendable {
    public let scriptedResponses: [String]
    private let lock = NSLock()
    private var _callCount: Int = 0

    public var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    public init(scriptedResponses: [String] = []) {
        self.scriptedResponses = scriptedResponses
    }

    public func complete(prompt: String, system: String?, model: String?) async throws -> String {
        let idx = nextIndex()
        if scriptedResponses.isEmpty { return "" }
        return scriptedResponses[idx % scriptedResponses.count]
    }

    private func nextIndex() -> Int {
        lock.lock(); defer { lock.unlock() }
        let idx = _callCount
        _callCount += 1
        return idx
    }
}
