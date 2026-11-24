import Synchronization
import MindCore
import Foundation
import NativeAgentCore

// Blueprint: | `NativeContextMemoryPressureObserver.swift` | `DispatchContextMemoryPressureObserver`: cancellable shared memory-pressure subscription; ContextFlow retains policy |

/// Only translate pressure events here; runtime and coordinator retain policy and trimming ownership.
final class DispatchContextMemoryPressureObserver: Sendable {
    private struct State {
        var observation: Task<Void, Never>?
        var pending: [UUID: Task<Void, Never>] = [:]
    }
    private let state = Mutex(State())

    func start(
        handler: @escaping @Sendable (ContextArenaPressure) async -> Void
    ) {
        state.withLock { state in
            guard state.observation == nil else { return }
            let changes = MemoryPressureSense.changes
            state.observation = Task { [weak self] in
                for await level in changes {
                    guard !Task.isCancelled, let self else { return }
                    let pressure = NativeContextFlowRuntime.memoryPressureLevel(hasCritical: level == .critical, hasWarning: level == .warning)
                    self.state.withLock { state in
                        let id = UUID()
                        state.pending[id] = Task {
                            await handler(pressure)
                            self.state.withLock { $0.pending[id] = nil }
                        }
                    }
                }
            }
        }
    }

    func stop() async {
        let task = state.withLock { state in
            defer { state.observation = nil }
            return state.observation
        }
        task?.cancel()
        await task?.value
        // Joined after the observation ends, so no handler it admitted is missed.
        let handlers = state.withLock { state in
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        for handler in handlers { await handler.value }
    }
}
