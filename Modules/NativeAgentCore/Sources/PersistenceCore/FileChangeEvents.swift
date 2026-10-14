import Foundation

/// One bounded async event stream over canonical file changes.
///
/// `FileChangeWatcher` owns the cross-process kqueue/vnode observation. This
/// wrapper only bridges those edges into structured concurrency and emits one
/// initial edge so callers can close the read-before-watch registration race.
/// It performs no polling and starts no timer.
public final class FileChangeEvents: @unchecked Sendable {
    public struct Stream: AsyncSequence, Sendable {
        public typealias Element = URL
        fileprivate let pending: PendingChanges

        public struct AsyncIterator: AsyncIteratorProtocol {
            fileprivate let pending: PendingChanges
            fileprivate var wake: AsyncStream<Void>.Iterator

            public mutating func next() async -> URL? {
                while !Task.isCancelled {
                    if let path = pending.takeNext() { return path }
                    guard await wake.next() != nil else { return nil }
                }
                return nil
            }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(pending: pending, wake: pending.wake.makeAsyncIterator())
        }
    }

    /// One pending edge per watched path; the wake stream carries no path data.
    fileprivate final class PendingChanges: @unchecked Sendable {
        let wake: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        private let lock = NSLock()
        private var paths: [URL] = []
        private var stopped = false
        private var armed = false

        init() {
            let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            wake = pair.stream
            continuation = pair.continuation
        }

        func insert(_ path: URL) {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped, !paths.contains(path) else { return }
            paths.append(path)
            if armed { continuation.yield(()) }
        }

        func takeNext() -> URL? {
            lock.lock()
            defer { lock.unlock() }
            return !armed || paths.isEmpty ? nil : paths.removeFirst()
        }

        func didArm() {
            lock.lock()
            armed = true
            let ready = !stopped && !paths.isEmpty
            lock.unlock()
            if ready { continuation.yield(()) }
        }

        func finish() {
            lock.lock()
            stopped = true
            paths.removeAll()
            lock.unlock()
            continuation.finish()
        }
    }

    public let stream: Stream

    private let lock = NSLock()
    private var watcher: FileChangeWatcher?
    private var stopped = false
    private var armingTask: Task<Void, Never>?

    public init(paths: [URL], emitInitial: Bool = true) {
        let normalized = Array(Set(paths.map(\.standardizedFileURL)))
        let pending = PendingChanges()
        stream = Stream(pending: pending)
        armingTask = Task.detached(priority: .utility) { [weak self] in
            let watcher = FileChangeWatcher(paths: normalized) { path in
                pending.insert(path.standardizedFileURL)
            }
            guard let self, self.adopt(watcher) else { watcher.cancel(); return }
            if emitInitial { normalized.forEach { pending.insert($0) } }
            pending.didArm()
        }
    }

    /// Consumers doing their own first read must await registration first.
    public func waitUntilArmed() async { await armingTask!.value }

    private func adopt(_ watcher: FileChangeWatcher) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        self.watcher = watcher
        return true
    }

    public func cancel() {
        let watcher: FileChangeWatcher?
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        watcher = self.watcher
        self.watcher = nil
        lock.unlock()

        watcher?.cancel()
        stream.pending.finish()
    }

    deinit {
        cancel()
    }
}
