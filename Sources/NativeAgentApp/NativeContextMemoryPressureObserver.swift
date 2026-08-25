import Context
import Foundation

/// The platform event source is deliberately a tiny lifecycle owner. The
/// runtime owns the policy and the coordinator owns trimming; this bridge only
/// translates an OS pressure edge into the shared Context pressure value.
protocol NativeContextMemoryPressureObserving: AnyObject, Sendable {
    var isRunning: Bool { get }
    func start(
        handler: @escaping @Sendable (ContextArenaPressure) async -> Void
    )
    func stop() async
}

/// Minimal Dispatch source surface. Keeping this beneath the observer lets the
/// real bridge be driven deterministically without inventing a process-wide
/// memory-pressure notification in an evaluator.
protocol NativeContextMemoryPressureDispatchSource: AnyObject, Sendable {
    var data: DispatchSource.MemoryPressureEvent { get }
    func setEventHandler(handler: @escaping @Sendable () -> Void)
    func resume()
    func cancel()
}

protocol NativeContextMemoryPressureDispatchSourceFactory: Sendable {
    func makeSource(queue: DispatchQueue) -> any NativeContextMemoryPressureDispatchSource
}

private final class SystemContextMemoryPressureDispatchSource:
    NativeContextMemoryPressureDispatchSource,
    @unchecked Sendable
{
    private let source: DispatchSourceMemoryPressure

    init(queue: DispatchQueue) {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: queue
        )
    }

    var data: DispatchSource.MemoryPressureEvent { source.data }

    func setEventHandler(handler: @escaping @Sendable () -> Void) {
        source.setEventHandler(handler: handler)
    }

    func resume() { source.resume() }
    func cancel() { source.cancel() }
}

struct SystemContextMemoryPressureDispatchSourceFactory:
    NativeContextMemoryPressureDispatchSourceFactory
{
    func makeSource(queue: DispatchQueue) -> any NativeContextMemoryPressureDispatchSource {
        SystemContextMemoryPressureDispatchSource(queue: queue)
    }
}

final class DispatchContextMemoryPressureObserver:
    NativeContextMemoryPressureObserving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let sourceFactory: any NativeContextMemoryPressureDispatchSourceFactory
    private var source: (any NativeContextMemoryPressureDispatchSource)?
    private var pendingHandlers: [Task<Void, Never>] = []

    init(
        sourceFactory: any NativeContextMemoryPressureDispatchSourceFactory
            = SystemContextMemoryPressureDispatchSourceFactory()
    ) {
        self.sourceFactory = sourceFactory
    }

    var isRunning: Bool {
        lock.withLock { source != nil }
    }

    func start(
        handler: @escaping @Sendable (ContextArenaPressure) async -> Void
    ) {
        lock.lock()
        guard source == nil else {
            lock.unlock()
            return
        }
        let source = sourceFactory.makeSource(
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
            let task = Task { await handler(pressure) }
            self.lock.withLock { self.pendingHandlers.append(task) }
        }
        self.source = source
        lock.unlock()
        source.resume()
    }

    func stop() async {
        let state = lock.withLock { () -> (
            source: (any NativeContextMemoryPressureDispatchSource)?,
            handlers: [Task<Void, Never>]
        ) in
            defer {
                self.source = nil
                self.pendingHandlers.removeAll()
            }
            return (self.source, self.pendingHandlers)
        }
        state.source?.cancel()
        for task in state.handlers { await task.value }
    }
}
