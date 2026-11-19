import Dispatch
import Foundation
import Synchronization

// Blueprint: | `MemoryPressureSense.swift` | One OS pressure source; ContextFlow and retained ACP conversations subscribe to observed levels |

public enum MemoryPressureSense {
    public enum Level: Sendable, Equatable { case normal, warning, critical }
    private static let owner = Owner()

    /// Unknown until the OS reports a level; silence never establishes normal pressure.
    public static var current: Level? { owner.current }
    public static var changes: AsyncStream<Level> { owner.changes() }

    private final class Owner: Sendable {
        private struct State: Sendable {
            var level: Level?
            var observers: [UUID: AsyncStream<Level>.Continuation] = [:]
        }
        private let state = Mutex(State())

        init() {
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.normal, .warning, .critical],
                queue: DispatchQueue(label: "NativeAgent.memoryPressure", qos: .utility)
            )
            // The handler holds its source for the life of the process: the body's one pressure sense is never released.
            source.setEventHandler { @Sendable [weak self] in
                let flags = source.data
                self?.receive(flags.contains(.critical) ? .critical : flags.contains(.warning) ? .warning : .normal)
            }
            source.resume()
        }

        var current: Level? { state.withLock { $0.level } }

        func changes() -> AsyncStream<Level> {
            let pair = AsyncStream<Level>.makeStream()
            let id = UUID()
            state.withLock {
                $0.observers[id] = pair.continuation
                if let level = $0.level { pair.continuation.yield(level) }
            }
            pair.continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
            }
            return pair.stream
        }

        private func receive(_ level: Level) {
            state.withLock { state in
                guard state.level != level else { return }
                state.level = level
                for observer in state.observers.values { observer.yield(level) }
            }
        }
    }
}
