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
        let prev = tail
        let me = Task { () -> Result<T, Error> in
            await prev.value
            do {
                // A canceled queued refresh must not run; waiting for its predecessor does not observe cancellation.
                try Task.checkCancellation()
                let v = try await body()
                return .success(v)
            } catch {
                return .failure(error)
            }
        }
        // Erase the result to keep the shared tail Task<Void, Never>.
        tail = Task { _ = await me.value }
        // Caller cancellation must reach the queued refresh.
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
