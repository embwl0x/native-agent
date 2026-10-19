import Darwin
import Dispatch
import Foundation

/// kqueue-backed append-file watcher. Missing files are watched through their
/// nearest existing ancestors; directory creation and rename/delete events
/// re-arm the target vnode.
public final class FileChangeWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (URL) -> Void
    private struct Armed { let source: DispatchSourceFileSystemObject }
    private let paths: [URL]
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.nativeagent.persistence.file-watcher", qos: .utility)
    /// fix-watcher-deinit-race (2026-08-02): `sources`/`stopped` used to be
    /// bare stored properties mutated on `queue` (arm/install) but read and
    /// mutated OFF the queue by `deinit`. `deinit` runs on whatever thread drops
    /// the last reference, so it raced every in-flight re-arm: torn dictionary
    /// reads (crash) or a source armed after deinit's sweep, i.e. a vnode source
    /// that is never cancelled and an O_EVTONLY fd leaked for the process
    /// lifetime. The state now lives under `stateLock`, which every accessor —
    /// queue or not, deinit included — takes. Only the kqueue work stays on the
    /// queue; the lock is never held across a `cancel()`/`open()` call.
    private let stateLock = NSLock()
    private var sources: [URL: Armed] = [:]
    private var stopped = false
    private var pooledSubscription: SharedFileChangeWatcherRegistry.Subscription?

    public init(paths: [URL], handler: @escaping Handler) {
        self.paths = Array(Set(paths.map(\.standardizedFileURL)))
        self.handler = handler
        pooledSubscription = SharedFileChangeWatcherRegistry.shared.subscribe(paths: self.paths, handler: handler)
    }

    public static func armed(paths: [URL], handler: @escaping Handler) async -> FileChangeWatcher {
        await Task.detached(priority: .utility) { FileChangeWatcher(paths: paths, handler: handler) }.value
    }

    fileprivate init(unpooledPath: URL, handler: @escaping Handler) {
        // The registry's own key, already standardized: publish matches on it.
        self.paths = [unpooledPath]
        self.handler = handler
        // Return only after the vnode sources are armed. An asynchronous first
        // arm leaves a startup window where a CLI can create/replace the file
        // before any source exists, and that edge would remain invisible until
        // a later write.
        self.queue.sync { self.armAll() }
    }

    public func cancel() {
        tearDown()
    }

    /// Stops the watcher and cancels every armed source EXACTLY once, from
    /// whichever thread gets here first (queue, caller, or `deinit`).
    private func tearDown() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        let old = Array(sources.values)
        sources.removeAll()
        let pooledSubscription = self.pooledSubscription
        self.pooledSubscription = nil
        stateLock.unlock()
        pooledSubscription?.cancel()
        old.forEach { $0.source.cancel() }
    }

    deinit { tearDown() }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func armAll() { guard !isStopped else { return }; paths.forEach(arm) }

    private func arm(_ path: URL) {
        guard !isStopped else { return }
        stateLock.lock()
        let previous = sources.removeValue(forKey: path)
        stateLock.unlock()
        previous?.source.cancel()
        let fd = open(path.path, O_EVTONLY)
        if fd >= 0 {
            install(
                fd: fd,
                targetPath: path,
                directory: false,
                mask: [.write, .extend, .rename, .delete, .revoke, .attrib]
            )
            return
        }
        // A target that exists but cannot be opened for events (a Unix socket,
        // e.g. ~/.codex/ipc/ipc.sock) is watched through its directory only.
        // Re-arming it on "exists" recursed, opening the directory again each
        // pass until the process ran out of descriptors (10,000 on 2026-10-01,
        // which aborted SwiftUI's RenderBox at launch).
        let missing = errno == ENOENT
        var parent = path.deletingLastPathComponent()
        var child = path
        var parentFD = open(parent.path, O_EVTONLY)
        while parentFD < 0, errno == ENOENT {
            let ancestor = parent.deletingLastPathComponent()
            guard ancestor != parent else { return }
            child = parent
            parent = ancestor
            parentFD = open(parent.path, O_EVTONLY)
        }
        guard parentFD >= 0 else { return }
        install(
            fd: parentFD,
            targetPath: path,
            directory: true,
            mask: [.write, .rename, .delete, .revoke]
        )
        // The target can appear after open(target) failed but before the parent
        // vnode source was installed. A directory event for that creation may
        // already have been delivered by then, so close the race with an
        // immediate post-arm check and move onto the target vnode ourselves.
        if missing, FileManager.default.fileExists(atPath: child.path) {
            arm(path)
            if FileManager.default.fileExists(atPath: path.path) {
                queue.async { [self] in if !isStopped { handler(path) } }
            }
        }
    }

    private func install(
        fd: Int32,
        targetPath: URL,
        directory: Bool,
        mask: DispatchSource.FileSystemEvent
    ) {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, !self.isStopped else { return }
            let event = source.data
            if directory {
                // An intermediate directory may have appeared. Move onto the
                // nearest ancestor before waiting for the next creation edge.
                self.arm(targetPath)
                if FileManager.default.fileExists(atPath: targetPath.path) {
                    // Arm the new inode before publishing the edge. If a
                    // second atomic replacement lands while the consumer is
                    // reading the first edge, the newly armed vnode observes
                    // it instead of leaving a re-arm loss window.
                    self.handler(targetPath)
                }
            } else {
                if event.contains(.rename) || event.contains(.delete) || event.contains(.revoke) {
                    self.arm(targetPath)
                }
                self.handler(targetPath)
            }
        }
        // Publish under the lock, and never publish into a torn-down watcher:
        // a source installed after `tearDown` swept the table would never be
        // cancelled, leaking its O_EVTONLY fd for the process lifetime.
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            // This source was never resumed — discard it the suspended-safe way.
            discardUnresumed(source)
            return
        }
        let previous = sources.updateValue(Armed(source: source), forKey: targetPath)
        stateLock.unlock()
        previous?.source.cancel()
        // Unconditional: every source that reaches the table is resumed here,
        // so a concurrent `tearDown` that cancels it between publish and resume
        // still ends with a resumed (hence releasable, hence fd-closing) source.
        source.resume()
    }

    /// Discards a source that has been created but never resumed.
    ///
    /// `makeFileSystemObjectSource` returns a SUSPENDED source. Cancelling one
    /// while suspended is a double fault: the cancel handler is deferred until
    /// a resume that never comes (so the O_EVTONLY descriptor leaks), and
    /// releasing a dispatch object with a non-zero suspend count is a
    /// libdispatch client error — "BUG IN CLIENT OF LIBDISPATCH: Release of a
    /// suspended object" — which traps the process. Resume first, then cancel;
    /// the cancel handler then runs on the queue and closes the descriptor.
    /// The brief resumed window is harmless: the event handler bails on
    /// `isStopped`, and this is only reached once `stopped` is true.
    private func discardUnresumed(_ source: DispatchSourceFileSystemObject) {
        source.resume()
        source.cancel()
    }
}

/// Process-wide vnode observation pool. Consumers retain independent callback
/// and cancellation lifecycles, but identical canonical paths share the one
/// O_EVTONLY descriptor the kernel actually needs.
private final class SharedFileChangeWatcherRegistry: @unchecked Sendable {
    static let shared = SharedFileChangeWatcherRegistry()

    final class Subscription: @unchecked Sendable {
        private let lock = NSLock()
        private weak var registry: SharedFileChangeWatcherRegistry?
        private let id: UUID
        private let paths: [URL]
        private var cancelled = false

        init(registry: SharedFileChangeWatcherRegistry, id: UUID, paths: [URL]) {
            self.registry = registry
            self.id = id
            self.paths = paths
        }

        func cancel() {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                return
            }
            cancelled = true
            let registry = self.registry
            self.registry = nil
            lock.unlock()
            registry?.remove(id: id, paths: paths)
        }

        deinit { cancel() }
    }

    private final class Entry {
        var handlers: [UUID: FileChangeWatcher.Handler]
        var watcher: FileChangeWatcher?
        let armed = DispatchGroup()

        init(id: UUID, handler: @escaping FileChangeWatcher.Handler) {
            handlers = [id: handler]
            armed.enter()
        }
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    func subscribe(
        paths: [URL],
        handler: @escaping FileChangeWatcher.Handler
    ) -> Subscription {
        let normalized = Array(Set(paths.map(\.standardizedFileURL)))
        let id = UUID()
        for path in normalized {
            add(id: id, path: path, handler: handler)
        }
        return Subscription(registry: self, id: id, paths: normalized)
    }

    private func add(
        id: UUID,
        path: URL,
        handler: @escaping FileChangeWatcher.Handler
    ) {
        lock.lock()
        if let entry = entries[path] {
            entry.handlers[id] = handler
            lock.unlock()
            entry.armed.wait()
            return
        }
        let entry = Entry(id: id, handler: handler)
        entries[path] = entry
        lock.unlock()
        defer { entry.armed.leave() }

        // Every subscriber waits for the shared inode to be armed before its
        // registration-race read, including one arriving during the first arm.
        let watcher = FileChangeWatcher(unpooledPath: path) { [weak self] changedPath in
            self?.publish(path: changedPath)
        }

        lock.lock()
        guard entries[path] === entry else {
            lock.unlock()
            watcher.cancel()
            return
        }
        entry.watcher = watcher
        lock.unlock()
    }

    /// `path` is the entry's own key. Standardizing it again here missed the
    /// entry once a watched file appeared: an existing path under /private/tmp
    /// or /private/var standardizes to /tmp or /var.
    private func publish(path: URL) {
        lock.lock()
        let handlers: [FileChangeWatcher.Handler]
        if let entry = entries[path] {
            handlers = Array(entry.handlers.values)
        } else {
            handlers = []
        }
        lock.unlock()
        for handler in handlers {
            handler(path)
        }
    }

    private func remove(id: UUID, paths: [URL]) {
        var retired: [FileChangeWatcher] = []
        lock.lock()
        for path in paths {
            guard let entry = entries[path] else { continue }
            entry.handlers.removeValue(forKey: id)
            if entry.handlers.isEmpty {
                entries.removeValue(forKey: path)
                if let watcher = entry.watcher { retired.append(watcher) }
            }
        }
        lock.unlock()
        retired.forEach { $0.cancel() }
    }
}
