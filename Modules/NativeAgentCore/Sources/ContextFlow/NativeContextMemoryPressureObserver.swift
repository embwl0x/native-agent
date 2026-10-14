import Context
import Foundation

/// The platform event source is deliberately a tiny lifecycle owner. The
/// runtime owns the policy and the coordinator owns trimming; this bridge only
/// translates an OS pressure edge into the shared Context pressure value.
final class DispatchContextMemoryPressureObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var source: DispatchSourceMemoryPressure?
    private var pendingHandlers: [UUID: Task<Void, Never>] = [:]

    func start(
        handler: @escaping @Sendable (ContextArenaPressure) async -> Void
    ) {
        lock.lock()
        guard source == nil else {
            lock.unlock()
            return
        }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "NativeAgent.ContextFlow.MemoryPressure", qos: .utility)
        )
        // This queue is deliberately outside the runtime actor. The handler
        // crosses back through an async value boundary instead of inheriting
        // actor isolation into Dispatch's event closure.
        source.setEventHandler { @Sendable [weak self, weak source] in
            guard let self, let source else { return }
            let pressure = NativeContextFlowRuntime.memoryPressureLevel(
                hasCritical: source.data.contains(.critical),
                hasWarning: source.data.contains(.warning)
            )
            self.lock.withLock {
                guard self.source === source else { return }
                let id = UUID()
                self.pendingHandlers[id] = Task {
                    await handler(pressure)
                    self.lock.withLock { self.pendingHandlers[id] = nil }
                }
            }
        }
        self.source = source
        lock.unlock()
        source.resume()
    }

    func stop() async {
        let state = lock.withLock { () -> (
            source: DispatchSourceMemoryPressure?,
            handlers: [Task<Void, Never>]
        ) in
            defer {
                self.source = nil
                self.pendingHandlers.removeAll()
            }
            return (self.source, Array(self.pendingHandlers.values))
        }
        state.source?.cancel()
        for task in state.handlers { await task.value }
    }
}
