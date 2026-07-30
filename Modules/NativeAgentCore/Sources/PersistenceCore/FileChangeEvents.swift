import Foundation

/// One bounded async event stream over canonical file changes.
///
/// `FileChangeWatcher` owns the cross-process kqueue/vnode observation. This
/// wrapper only bridges those edges into structured concurrency and emits one
/// initial edge so callers can close the read-before-watch registration race.
/// It performs no polling and starts no timer.
public final class FileChangeEvents: @unchecked Sendable {
    public let stream: AsyncStream<URL>

    private let lock = NSLock()
    private let continuation: AsyncStream<URL>.Continuation
    private var watcher: FileChangeWatcher?
    private var stopped = false

    public init(paths: [URL], emitInitial: Bool = true) {
        let normalized = Array(Set(paths.map(\.standardizedFileURL)))
        let pair = AsyncStream<URL>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
        watcher = FileChangeWatcher(paths: normalized) { path in
            pair.continuation.yield(path.standardizedFileURL)
        }
        if emitInitial {
            normalized.forEach { pair.continuation.yield($0) }
        }
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
        continuation.finish()
    }

    deinit {
        cancel()
    }
}
