import Synchronization
import Foundation

// Blueprint: | `FileChangeEvents.swift` | `FileChangeEvents`: bounded cancellable async vnode event bridge with one initial edge only after successful arming |

/// Bridge vnode edges into bounded structured concurrency; an initial edge after arming closes read-before-watch races. Failed arming finishes without an edge,
/// polling or timers.
public final class FileChangeEvents: Sendable {
    public struct Change: Sendable {
        package let path: URL
        package var observation: PhysiologySelfWriteRegistry.Observation?
        package var mixed = false

        package var isSelfWrite: Bool {
            get async {
                guard !mixed, let observation else { return false }
                return await observation.isSelfWrite()
            }
        }
    }

    public struct Stream: AsyncSequence, Sendable {
        public typealias Element = URL
        fileprivate let pending: PendingChanges

        public struct AsyncIterator: AsyncIteratorProtocol {
            fileprivate let pending: PendingChanges
            fileprivate var wake: AsyncStream<Void>.Iterator

            public mutating func next() async -> URL? {
                await nextChange()?.path
            }

            package mutating func nextChange() async -> Change? {
                while !Task.isCancelled {
                    if let path = pending.takeNext() { return path }
                    guard await wake.next(isolation: #isolation) != nil else { return nil }
                }
                return nil
            }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(pending: pending, wake: pending.wake.makeAsyncIterator())
        }
    }

    fileprivate final class PendingChanges: Sendable {
        let wake: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        private struct State {
            var paths: [Change] = []
            var stopped = false
            var armed = false
        }
        private let state = Mutex(State())

        init() {
            let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            wake = pair.stream
            continuation = pair.continuation
        }

        func insert(_ path: URL, observation: PhysiologySelfWriteRegistry.Observation? = nil) {
            state.withLock { state in
                guard !state.stopped else { return }
                if let index = state.paths.lastIndex(where: { $0.path == path }) {
                    if state.paths[index].observation?.generation == observation?.generation { return }
                    if state.paths[..<index].contains(where: { $0.path == path }) {
                        state.paths[index].mixed = true
                        state.paths[index].observation = observation
                        return
                    }
                }
                state.paths.append(Change(path: path, observation: observation))
                if state.armed { continuation.yield(()) }
            }
        }

        func takeNext() -> Change? {
            return state.withLock { !$0.armed || $0.paths.isEmpty ? nil : $0.paths.removeFirst() }
        }

        func didArm() {
            let ready = state.withLock { state in
                guard !state.stopped else { return false }
                state.armed = true
                return !state.paths.isEmpty
            }
            if ready { continuation.yield(()) }
        }

        var isArmed: Bool {
            return state.withLock { $0.armed && !$0.stopped }
        }

        func finish() {
            state.withLock { state in
                state.stopped = true
                state.paths.removeAll()
            }
            continuation.finish()
        }
    }

    public let stream: Stream

    private struct State {
        var watcher: FileChangeWatcher?
        var stopped = false
        var armingTask: Task<Void, Never>?
    }
    private let state = Mutex(State())

    public init(paths: [URL], emitInitial: Bool = true, observingGenerationAt root: URL? = nil) {
        let pending = PendingChanges()
        stream = Stream(pending: pending)
        state.withLock { state in
            state.armingTask = Task.detached(priority: .utility) { [weak self] in
                let normalized = Array(Set(paths.map(\.standardizedFileURL)))
                let watcher = FileChangeWatcher(paths: normalized, observing: root, onFailure: { [weak self] _ in
                    pending.finish()
                    self?.cancel()
                }) { path, observation in
                    pending.insert(path, observation: observation)
                }
                guard !Task.isCancelled, watcher.isArmed, let self, self.adopt(watcher) else {
                    watcher.cancel()
                    pending.finish()
                    return
                }
                if emitInitial { normalized.forEach { pending.insert($0) } }
                pending.didArm()
            }
        }
    }

    /// Consumers doing their own first read must await registration first.
    @discardableResult
    public func waitUntilArmed() async -> Bool {
        let arming = state.withLock { $0.armingTask! }
        await arming.value
        return isArmed
    }

    /// False after failed initial arming, re-arming failure, or cancellation.
    public var isArmed: Bool {
        let watcher = state.withLock { !$0.stopped && stream.pending.isArmed ? $0.watcher : nil }
        // Readiness may wait for re-arming; cancellation keeps its own lock free.
        return watcher?.isArmed == true
    }

    private func adopt(_ watcher: FileChangeWatcher) -> Bool {
        return state.withLock { state in
            guard !state.stopped else { return false }
            state.watcher = watcher
            return true
        }
    }

    public func cancel() {
        let retired = state.withLock { state -> (watcher: FileChangeWatcher?, pending: PendingChanges)? in
            guard !state.stopped else { return nil }
            state.stopped = true
            state.armingTask?.cancel()
            let watcher = state.watcher
            state.watcher = nil
            return (watcher, stream.pending)
        }
        retired?.watcher?.cancel()
        retired?.pending.finish()
    }

    deinit {
        cancel()
    }
}
