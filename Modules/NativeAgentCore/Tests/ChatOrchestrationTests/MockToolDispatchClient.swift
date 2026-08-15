// MockToolDispatchClient.swift
//
// Relocated verbatim from ChatOrchestration+TurnEngine.swift (simplification
// sweep, 2026-08-14): a scripted test mock has no business shipping in the
// production module. Zero production instantiations, verified by grep.

import Foundation
import PersistenceCore
@testable import ChatOrchestration

/// Scripted-response mock. Tracks every dispatch behind an NSLock so it can be
/// shared across async tasks. Returns `.null` for any tool name not in the
/// scripted map. `listAvailableTools` returns the script keys in sorted order.
public final class MockToolDispatchClient: ToolDispatchClient, @unchecked Sendable {
    public struct Dispatch: Sendable, Equatable {
        public let tool: String
        public let input: [String: JSONValue]
        public let surface: String
    }

    private let scripted: [String: JSONValue]
    private let lock = NSLock()
    private var _dispatches: [Dispatch] = []

    public init(scripted: [String: JSONValue] = [:]) {
        self.scripted = scripted
    }

    public var dispatches: [Dispatch] {
        lock.lock(); defer { lock.unlock() }
        return _dispatches
    }

    public func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        recordDispatch(Dispatch(tool: tool, input: input, surface: surface))
        return scripted[tool] ?? .null
    }

    private func recordDispatch(_ d: Dispatch) {
        lock.lock(); defer { lock.unlock() }
        _dispatches.append(d)
    }

    public func listAvailableTools() async throws -> [String] {
        return scripted.keys.sorted()
    }
}

