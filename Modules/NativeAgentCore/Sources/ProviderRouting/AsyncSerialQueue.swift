import Foundation
import NativeAgentShared
import os
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `AsyncSerialQueue.swift` | FIFO completion of shared single-use OAuth token refreshes; a stopped caller returns while its refresh settles |
/// Refreshes run FIFO through completion so a single-use token rotates once.
actor AsyncSerialQueue {
    private var tail: Task<Void, Never> = Task {}

    func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let prev = tail
        let me = Task {
            await prev.value
            return try await body()
        }
        tail = Task { _ = await me.result }
        let waiter = OSAllocatedUnfairLock<CheckedContinuation<T, Error>?>(initialState: nil)
        let take: @Sendable () -> CheckedContinuation<T, Error>? = { waiter.withLock { held in defer { held = nil }; return held } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.withLock { $0 = continuation }
                if Task.isCancelled { take()?.resume(throwing: CancellationError()) }
                Task { let result = await me.result; take()?.resume(with: result) }
            }
        } onCancel: { take()?.resume(throwing: CancellationError()) }
    }
}
