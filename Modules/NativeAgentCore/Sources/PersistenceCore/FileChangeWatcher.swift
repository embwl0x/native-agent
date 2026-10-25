import Darwin
import Dispatch
import Foundation

// Blueprint: | `FileChangeWatcher.swift` | `FileChangeWatcher`: pooled file/directory vnode subscriptions, ancestor watches and replacement rearming with serialized teardown |

/// Pooled vnode watcher for files and directories. Missing targets follow their
/// nearest existing ancestors; creation and replacement re-arm the target vnode.
public final class FileChangeWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (URL) -> Void
    public typealias EventHandler = @Sendable (URL, DispatchSource.FileSystemEvent) -> Void
    private struct Armed { let source: DispatchSourceFileSystemObject }
    private let paths: [URL]
    private let handler: EventHandler
    private let onFailure: Handler?
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
    private let stateLock = NSCondition()
    private var sources: [URL: Armed] = [:]
    // Arming runs on `queue` and can recurse when a missing target appears.
    private var armingDepth = 0
    private var stopped = false
    private var pooledSubscription: SharedFileChangeWatcherRegistry.Subscription?

    public convenience init(paths: [URL], onFailure: Handler? = nil, handler: @escaping Handler) {
        self.init(paths: paths, onFailure: onFailure, eventHandler: { path, _ in handler(path) })
    }

    /// Target vnode flags; a target appearing through an ancestor emits `.write`.
    public init(paths: [URL], onFailure: Handler? = nil, eventHandler: @escaping EventHandler) {
        self.paths = Array(Set(paths.map(\.standardizedFileURL)))
        self.handler = eventHandler
        self.onFailure = onFailure
        pooledSubscription = SharedFileChangeWatcherRegistry.shared.subscribe(paths: self.paths, onFailure: onFailure, handler: eventHandler)
    }

    /// A registration can fail (for example, descriptor exhaustion). Inspect
    /// this after construction; returning from initialization alone is no proof.
    /// Wait for an active arm attempt rather than exposing its source-table gap.
    public var unarmedPaths: [URL] {
        stateLock.lock()
        if !stopped, let pooledSubscription {
            stateLock.unlock()
            return pooledSubscription.unarmedPaths
        }
        while !stopped && armingDepth > 0 { stateLock.wait() }
        let unarmed = stopped ? paths : paths.filter { sources[$0] == nil }
        stateLock.unlock()
        return unarmed
    }

    public var isArmed: Bool { !paths.isEmpty && unarmedPaths.isEmpty }

    public static func armed(paths: [URL], handler: @escaping Handler) async -> FileChangeWatcher {
        await Task.detached(priority: .utility) { FileChangeWatcher(paths: paths, handler: handler) }.value
    }

    fileprivate init(unpooledPath: URL, onFailure: Handler?, handler: @escaping EventHandler) {
        // The registry's own key, already standardized: publish matches on it.
        self.paths = [unpooledPath]
        self.handler = handler
        self.onFailure = onFailure
        // Return only after attempting to arm. An asynchronous first
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
        stateLock.broadcast()
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
        stateLock.lock()
        guard !stopped else { stateLock.unlock(); return }
        armingDepth += 1
        let previous = sources.removeValue(forKey: path)
        stateLock.unlock()
        defer {
            stateLock.lock()
            armingDepth -= 1
            let failed = armingDepth == 0 && !stopped && sources[path] == nil
            stateLock.broadcast()
            stateLock.unlock()
            if failed { onFailure?(path) }
        }
        previous?.source.cancel()
        let fd = open(path.path, O_EVTONLY)
        if fd >= 0 {
            install(
                fd: fd,
                targetPath: path,
                directory: false,
                mask: [.write, .extend, .rename, .delete, .revoke, .attrib, .link]
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
                queue.async { [self] in if !isStopped { handler(path, .write) } }
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
                    self.handler(targetPath, .write)
                }
            } else {
                if event.contains(.rename) || event.contains(.delete) || event.contains(.revoke) {
                    self.arm(targetPath)
                }
                self.handler(targetPath, event)
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

        var unarmedPaths: [URL] {
            lock.lock()
            let registry = cancelled ? nil : self.registry
            lock.unlock()
            return registry?.unarmedPaths(id: id, paths: paths) ?? paths
        }

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
        struct Callbacks {
            let change: FileChangeWatcher.EventHandler
            let failure: FileChangeWatcher.Handler?
        }
        var handlers: [UUID: Callbacks]
        var watcher: FileChangeWatcher?
        let armed = DispatchGroup()

        init(id: UUID, onFailure: FileChangeWatcher.Handler?, handler: @escaping FileChangeWatcher.EventHandler) {
            handlers = [id: Callbacks(change: handler, failure: onFailure)]
            armed.enter()
        }
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    func subscribe(
        paths: [URL],
        onFailure: FileChangeWatcher.Handler?,
        handler: @escaping FileChangeWatcher.EventHandler
    ) -> Subscription {
        let normalized = Array(Set(paths.map(\.standardizedFileURL)))
        let id = UUID()
        for path in normalized {
            add(id: id, path: path, onFailure: onFailure, handler: handler)
        }
        return Subscription(registry: self, id: id, paths: normalized)
    }

    private func add(
        id: UUID,
        path: URL,
        onFailure: FileChangeWatcher.Handler?,
        handler: @escaping FileChangeWatcher.EventHandler
    ) {
        lock.lock()
        if let entry = entries[path] {
            entry.handlers[id] = Entry.Callbacks(change: handler, failure: onFailure)
            lock.unlock()
            entry.armed.wait()
            return
        }
        let entry = Entry(id: id, onFailure: onFailure, handler: handler)
        entries[path] = entry
        lock.unlock()
        defer { entry.armed.leave() }

        // Every subscriber waits for the shared arm attempt before its
        // registration-race read, including one arriving during the first arm.
        let watcher = FileChangeWatcher(unpooledPath: path, onFailure: { [weak self] failedPath in
            self?.publishFailure(path: failedPath)
        }) { [weak self] changedPath, flags in
            self?.publish(path: changedPath, flags: flags)
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
    private func publish(path: URL, flags: DispatchSource.FileSystemEvent) {
        lock.lock()
        let handlers: [FileChangeWatcher.EventHandler]
        if let entry = entries[path] {
            handlers = entry.handlers.values.map(\.change)
        } else {
            handlers = []
        }
        lock.unlock()
        for handler in handlers {
            handler(path, flags)
        }
    }

    private func publishFailure(path: URL) {
        lock.lock()
        let handlers = entries[path]?.handlers.values.compactMap(\.failure) ?? []
        lock.unlock()
        for handler in handlers { handler(path) }
    }

    fileprivate func unarmedPaths(id: UUID, paths: [URL]) -> [URL] {
        lock.lock()
        let watchers = paths.map { path -> FileChangeWatcher? in
            guard let entry = entries[path], entry.handlers[id] != nil else { return nil }
            return entry.watcher
        }
        lock.unlock()
        // Waiting on one path must not block failure delivery or cancellation.
        return zip(paths, watchers).compactMap { path, watcher in
            watcher?.isArmed == true ? nil : path
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
