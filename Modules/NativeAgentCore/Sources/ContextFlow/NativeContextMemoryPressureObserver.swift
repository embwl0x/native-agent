import Context
import Foundation
import NativeAgentCore

// Blueprint: | `NativeContextMemoryPressureObserver.swift` | `DispatchContextMemoryPressureObserver`: cancellable shared memory-pressure subscription; ContextFlow retains policy |

/// Only translate pressure events here; runtime and coordinator retain policy and trimming ownership.
final class DispatchContextMemoryPressureObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: Task<Void, Never>?
    private var pending: [UUID: Task<Void, Never>] = [:]

    func start(
        handler: @escaping @Sendable (ContextArenaPressure) async -> Void
    ) {
        lock.lock()
        guard observation == nil else {
            lock.unlock()
            return
        }
        let changes = MemoryPressureSense.changes
        // Each level is handled on its own, as it arrives: a warning never waits behind a normal level's reconciliation.
        observation = Task { [weak self] in
            for await level in changes {
                guard !Task.isCancelled, let self else { return }
                let pressure = NativeContextFlowRuntime.memoryPressureLevel(hasCritical: level == .critical, hasWarning: level == .warning)
                self.lock.withLock {
                    let id = UUID()
                    self.pending[id] = Task {
                        await handler(pressure)
                        self.lock.withLock { self.pending[id] = nil }
                    }
                }
            }
        }
        lock.unlock()
    }

    func stop() async {
        let task = lock.withLock {
            defer { observation = nil }
            return observation
        }
        task?.cancel()
        await task?.value
        // Joined after the observation ends, so no handler it admitted is missed.
        let handlers = lock.withLock {
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        for handler in handlers { await handler.value }
    }
}
