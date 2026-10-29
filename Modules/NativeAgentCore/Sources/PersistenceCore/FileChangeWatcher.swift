import Darwin
import Dispatch
import Foundation

// Blueprint: | `FileChangeWatcher.swift` | `FileChangeWatcher`: independent subscription identity and cancellation; registry `Entry` owns one path's shared vnode, ancestor observation and replacement rearming with serialized teardown |

/// Cancellation can arrive during a read; notification tokens retire once
/// without sharing their non-Sendable storage with the reader task.
package final class ObservationNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol]

    package init(center: NotificationCenter = .default, names: [Notification.Name], invalidate: @escaping @Sendable () -> Void) {
        self.center = center
        tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in invalidate() }
        }
    }

    package func cancel() {
        let retired = lock.withLock {
            let retired = tokens
            tokens.removeAll()
            return retired
        }
        retired.forEach(center.removeObserver)
    }

    deinit { cancel() }
}

/// Independent subscription to shared vnode observation of canonical paths.
public final class FileChangeWatcher: @unchecked Sendable {
    public typealias ChangedPathSink = @Sendable (URL) -> Void
    public typealias FileEventSink = @Sendable (URL, DispatchSource.FileSystemEvent) -> Void
    private let lock = NSLock()
    private let id = UUID()
    private let paths: [URL]
    private var cancelled = false

    public convenience init(paths: [URL], onFailure: ChangedPathSink? = nil, handler: @escaping ChangedPathSink) {
        self.init(paths: paths, onFailure: onFailure, eventHandler: { path, _ in handler(path) })
    }

    /// Target vnode flags; a target appearing through an ancestor emits `.write`.
    public init(paths: [URL], onFailure: ChangedPathSink? = nil, eventHandler: @escaping FileEventSink) {
        self.paths = Array(Set(paths.map(\.standardizedFileURL)))
        SharedFileChangeWatcherRegistry.shared.subscribe(id: id, paths: self.paths, onFailure: onFailure, handler: eventHandler)
    }

    /// Wait for active arming; construction alone does not prove usable sources.
    public var unarmedPaths: [URL] {
        lock.lock()
        let cancelled = self.cancelled
        lock.unlock()
        return cancelled ? paths : SharedFileChangeWatcherRegistry.shared.unarmedPaths(id: id, paths: paths)
    }

    public var isArmed: Bool { !paths.isEmpty && unarmedPaths.isEmpty }

    public static func armed(paths: [URL], handler: @escaping ChangedPathSink) async -> FileChangeWatcher {
        await Task.detached(priority: .utility) { FileChangeWatcher(paths: paths, handler: handler) }.value
    }

    public func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        lock.unlock()
        SharedFileChangeWatcherRegistry.shared.remove(id: id, paths: paths)
    }

    deinit { cancel() }
}

/// Identical canonical paths share a descriptor; subscribers cancel independently.
private final class SharedFileChangeWatcherRegistry: @unchecked Sendable {
    static let shared = SharedFileChangeWatcherRegistry()

    private final class Entry: @unchecked Sendable {
        struct Callbacks {
            let change: FileChangeWatcher.FileEventSink
            let failure: FileChangeWatcher.ChangedPathSink?
        }
        var handlers: [UUID: Callbacks]
        let armed = DispatchGroup()
        private let path: URL
        private weak var registry: SharedFileChangeWatcherRegistry?
        private let queue = DispatchQueue(label: "com.nativeagent.persistence.file-watcher", qos: .utility)
        // All source/stopped access, including teardown, takes this lock.
        private let stateLock = NSCondition()
        private var source: DispatchSourceFileSystemObject?
        private var armingDepth = 0
        private var stopped = false

        init(path: URL, registry: SharedFileChangeWatcherRegistry, id: UUID,
             onFailure: FileChangeWatcher.ChangedPathSink?, handler: @escaping FileChangeWatcher.FileEventSink) {
            self.path = path
            self.registry = registry
            handlers = [id: Callbacks(change: handler, failure: onFailure)]
            armed.enter()
        }

        /// Synchronous first arming closes the create-before-registration window.
        func start() { queue.sync { arm() } }

        var isArmed: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            while !stopped && armingDepth > 0 { stateLock.wait() }
            return !stopped && source != nil
        }

        func cancel() {
            stateLock.lock()
            guard !stopped else { stateLock.unlock(); return }
            stopped = true
            let old = source
            source = nil
            stateLock.broadcast()
            stateLock.unlock()
            old?.cancel()
        }

        deinit { cancel() }

        private var isStopped: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return stopped
        }

        private func arm() {
            stateLock.lock()
            guard !stopped else { stateLock.unlock(); return }
            armingDepth += 1
            let previous = source
            source = nil
            stateLock.unlock()
            defer {
                stateLock.lock()
                armingDepth -= 1
                let failed = armingDepth == 0 && !stopped && source == nil
                stateLock.broadcast()
                stateLock.unlock()
                if failed { registry?.publishFailure(path: path) }
            }
            previous?.cancel()
            let fd = open(path.path, O_EVTONLY)
            if fd >= 0 {
                install(fd: fd, directory: false, mask: [.write, .extend, .rename, .delete, .revoke, .attrib, .link])
                return
            }
            // Existing targets that cannot be opened (such as sockets) stay
            // directory-watched; only a missing target triggers recursive arming.
            let missing = errno == ENOENT
            var parent = path.deletingLastPathComponent()
            var child = path
            var parentFD = open(parent.path, O_EVTONLY | O_DIRECTORY)
            while parentFD < 0, errno == ENOENT {
                let ancestor = parent.deletingLastPathComponent()
                guard ancestor != parent else { return }
                child = parent
                parent = ancestor
                parentFD = open(parent.path, O_EVTONLY | O_DIRECTORY)
            }
            guard parentFD >= 0 else { return }
            install(fd: parentFD, directory: true, mask: [.write, .rename, .delete, .revoke])
            // Catch creation between the failed target open and ancestor arming.
            if missing, FileManager.default.fileExists(atPath: child.path) {
                arm()
                if FileManager.default.fileExists(atPath: path.path) {
                    queue.async { [self] in if !isStopped { registry?.publish(path: path, flags: .write) } }
                }
            }
        }

        private func install(fd: Int32, directory: Bool, mask: DispatchSource.FileSystemEvent) {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
            source.setCancelHandler { close(fd) }
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source, !self.isStopped else { return }
                let event = source.data
                if directory {
                    // Move to the nearest existing ancestor or the target;
                    // arm the new inode before delivering its creation edge.
                    self.arm()
                    if FileManager.default.fileExists(atPath: self.path.path) {
                        self.registry?.publish(path: self.path, flags: .write)
                    }
                } else {
                    if event.contains(.rename) || event.contains(.delete) || event.contains(.revoke) {
                        self.arm()
                    }
                    self.registry?.publish(path: self.path, flags: event)
                }
            }
            stateLock.lock()
            guard !stopped else {
                stateLock.unlock()
                // A suspended source must resume before cancellation and release.
                source.resume()
                source.cancel()
                return
            }
            let previous = self.source
            self.source = source
            stateLock.unlock()
            previous?.cancel()
            // Resume even if cancellation won after publication, so it closes fd.
            source.resume()
        }
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    func subscribe(id: UUID, paths: [URL], onFailure: FileChangeWatcher.ChangedPathSink?, handler: @escaping FileChangeWatcher.FileEventSink) {
        for path in paths {
            add(id: id, path: path, onFailure: onFailure, handler: handler)
        }
    }

    private func add(id: UUID, path: URL, onFailure: FileChangeWatcher.ChangedPathSink?, handler: @escaping FileChangeWatcher.FileEventSink) {
        lock.lock()
        if let entry = entries[path] {
            entry.handlers[id] = Entry.Callbacks(change: handler, failure: onFailure)
            lock.unlock()
            entry.armed.wait()
            return
        }
        let entry = Entry(path: path, registry: self, id: id, onFailure: onFailure, handler: handler)
        entries[path] = entry
        lock.unlock()
        defer { entry.armed.leave() }
        entry.start()
    }

    /// Use the entry's original key; standardization can change after creation.
    private func publish(path: URL, flags: DispatchSource.FileSystemEvent) {
        lock.lock()
        let handlers = entries[path]?.handlers.values.map(\.change) ?? []
        lock.unlock()
        for handler in handlers { handler(path, flags) }
    }

    private func publishFailure(path: URL) {
        lock.lock()
        let handlers = entries[path]?.handlers.values.compactMap(\.failure) ?? []
        lock.unlock()
        for handler in handlers { handler(path) }
    }

    func unarmedPaths(id: UUID, paths: [URL]) -> [URL] {
        lock.lock()
        let observations = paths.map { path -> Entry? in
            guard let entry = entries[path], entry.handlers[id] != nil else { return nil }
            return entry
        }
        lock.unlock()
        // Arming waits never hold subscription or registry locks.
        return zip(paths, observations).compactMap { path, entry in
            entry?.isArmed == true ? nil : path
        }
    }

    func remove(id: UUID, paths: [URL]) {
        var retired: [Entry] = []
        lock.lock()
        for path in paths {
            guard let entry = entries[path] else { continue }
            entry.handlers.removeValue(forKey: id)
            if entry.handlers.isEmpty {
                entries.removeValue(forKey: path)
                retired.append(entry)
            }
        }
        lock.unlock()
        retired.forEach { $0.cancel() }
    }
}
