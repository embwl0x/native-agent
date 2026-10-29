import Foundation
import NativeAgentShared
import os
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `AsyncSerialQueue.swift` | FIFO completion and caller cancellation for shared single-use OAuth token refreshes |
/// Refreshes run FIFO through completion so a single-use token rotates once.
actor AsyncSerialQueue {
    private var tail: Task<Void, Never> = Task {}

    func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        // Capture the current tail, install ourselves as the new tail.
        let prev = tail
        // Create a task that waits for `prev` and then runs `body`.
        // The next caller will see this Task as their `prev`.
        let me = Task { () -> Result<T, Error> in
            await prev.value
            do {
                // Waiting for the predecessor does not observe cancellation.
                // A canceled queued refresh must never enter its body.
                try Task.checkCancellation()
                let v = try await body()
                return .success(v)
            } catch {
                return .failure(error)
            }
        }
        // Erase the typed result so the tail chain stays Task<Void, Never>.
        tail = Task { _ = await me.value }
        // Forward caller cancellation to the queued refresh.
        let result = await withTaskCancellationHandler {
            await me.value
        } onCancel: {
            me.cancel()
        }
        switch result {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }
}
