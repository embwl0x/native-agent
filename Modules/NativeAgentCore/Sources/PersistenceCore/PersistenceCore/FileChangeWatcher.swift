import Synchronization
import Darwin
import Dispatch
import Foundation

// Blueprint: | `FileChangeWatcher.swift` | `FileChangeWatcher`, `Entry`; Shared vnode, independent cancellation. |

/// Cancellation can arrive during a read; notification tokens retire once without sharing their non-Sendable storage with the reader task.
package final class ObservationNotifications: Sendable {
    private let center: NotificationCenter
    private let tokens: Mutex<[NSObjectProtocol]?>

    package init(center: NotificationCenter = .default, names: [Notification.Name], invalidate: @escaping @Sendable () -> Void) {
        self.center = center
        tokens = Mutex(names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in invalidate() }
        })
    }

    package func cancel() {
        let retired = tokens.withLock { $0.take() }
        retired?.forEach(center.removeObserver)
    }

    deinit { cancel() }
}

/// Independent subscription to shared vnode observation of canonical paths.
public final class FileChangeWatcher: Sendable {
    public typealias ChangedPathSink = @Sendable (URL) -> Void
    public typealias FileEventSink = @Sendable (URL, DispatchSource.FileSystemEvent) -> Void
    fileprivate typealias Delivery = @Sendable (URL, DispatchSource.FileSystemEvent) -> @Sendable () -> Void
    private let id = UUID()
    private let paths: [URL]
    private let cancelled = Atomic(false)

    public convenience init(paths: [URL], onFailure: ChangedPathSink? = nil, handler: @escaping ChangedPathSink) {
        self.init(paths: paths, onFailure: onFailure, eventHandler: { path, _ in handler(path) })
    }

    /// Target vnode flags; a target appearing through an ancestor emits `.write`.
    public convenience init(paths: [URL], onFailure: ChangedPathSink? = nil, eventHandler: @escaping FileEventSink) {
        self.init(paths: paths, onFailure: onFailure, delivery: { path, flags in
            // The flags cross into a sendable delivery by their raw value.
            let raw = flags.rawValue
            return { eventHandler(path, DispatchSource.FileSystemEvent(rawValue: raw)) }
        })
    }

    package convenience init(paths: [URL], observing root: URL?, onFailure: @escaping ChangedPathSink,
                             observed: @escaping @Sendable (URL, PhysiologySelfWriteRegistry.Observation?) -> Void) {
        self.init(paths: paths, onFailure: onFailure, delivery: { path, _ in
            let observation = root.map(PhysiologySelfWriteRegistry.shared.observe)
            return { observed(path, observation) }
        })
    }

    private init(paths: [URL], onFailure: ChangedPathSink?, delivery: @escaping Delivery) {
        self.paths = Array(Set(paths.map(\.standardizedFileURL)))
        SharedFileChangeWatcherRegistry.shared.subscribe(id: id, paths: self.paths, onFailure: onFailure, handler: delivery)
    }

    /// Wait for active arming; construction alone does not prove usable sources.
    public var unarmedPaths: [URL] {
        return cancelled.load(ordering: .acquiring) ? paths : SharedFileChangeWatcherRegistry.shared.unarmedPaths(id: id, paths: paths)
    }

    public var isArmed: Bool { !paths.isEmpty && unarmedPaths.isEmpty }

    public static func armed(paths: [URL], handler: @escaping ChangedPathSink) async -> FileChangeWatcher {
        await Task.detached(priority: .utility) { FileChangeWatcher(paths: paths, handler: handler) }.value
    }

    public func cancel() {
        guard !cancelled.exchange(true, ordering: .acquiringAndReleasing) else { return }
        SharedFileChangeWatcherRegistry.shared.remove(id: id, paths: paths)
    }

    deinit { cancel() }
}

/// Identical canonical paths share a descriptor; subscribers cancel independently.
private final class SharedFileChangeWatcherRegistry: Sendable {
    static let shared = SharedFileChangeWatcherRegistry()

    // The vnode dispatch source shares a condition with synchronous isArmed readers waiting for rearming.
    private final class Entry: @unchecked Sendable {
        struct Callbacks {
            let change: FileChangeWatcher.Delivery
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
             onFailure: FileChangeWatcher.ChangedPathSink?, handler: @escaping FileChangeWatcher.Delivery) {
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
            // Existing targets that cannot be opened (such as sockets) stay directory-watched; only a missing target triggers recursive arming.
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
                    let deliver = registry?.delivery(path: path, flags: .write)
                    queue.async { [self] in if !isStopped { deliver?() } }
                }
            }
        }

        private func install(fd: Int32, directory: Bool, mask: DispatchSource.FileSystemEvent) {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
            source.setCancelHandler { close(fd) }
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source, !self.isStopped else { return }
                let event = source.data
                let deliver = self.registry?.delivery(path: self.path, flags: directory ? .write : event)
                if directory {
                    // Move to the nearest existing ancestor or the target; arm the new inode before delivering its creation edge.
                    self.arm()
                    if FileManager.default.fileExists(atPath: self.path.path) {
                        deliver?()
                    }
                } else {
                    if event.contains(.rename) || event.contains(.delete) || event.contains(.revoke) {
                        self.arm()
                    }
                    deliver?()
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

    private let entries = Mutex<[URL: Entry]>([:])

    func subscribe(id: UUID, paths: [URL], onFailure: FileChangeWatcher.ChangedPathSink?, handler: @escaping FileChangeWatcher.Delivery) {
        for path in paths {
            add(id: id, path: path, onFailure: onFailure, handler: handler)
        }
    }

    private func add(id: UUID, path: URL, onFailure: FileChangeWatcher.ChangedPathSink?, handler: @escaping FileChangeWatcher.Delivery) {
        let (entry, start) = entries.withLock { entries in
            if let entry = entries[path] {
                entry.handlers[id] = Entry.Callbacks(change: handler, failure: onFailure)
                return (entry, false)
            }
            let entry = Entry(path: path, registry: self, id: id, onFailure: onFailure, handler: handler)
            entries[path] = entry
            return (entry, true)
        }
        guard start else { entry.armed.wait(); return }
        defer { entry.armed.leave() }
        entry.start()
    }

    /// Use the entry's original key; standardization can change after creation.
    private func delivery(path: URL, flags: DispatchSource.FileSystemEvent) -> @Sendable () -> Void {
        let handlers = entries.withLock { $0[path]?.handlers.values.map(\.change) ?? [] }
        let deliveries = handlers.map { $0(path, flags) }
        return { for deliver in deliveries { deliver() } }
    }

    private func publishFailure(path: URL) {
        let handlers = entries.withLock { $0[path]?.handlers.values.compactMap(\.failure) ?? [] }
        for handler in handlers { handler(path) }
    }

    func unarmedPaths(id: UUID, paths: [URL]) -> [URL] {
        let observations = entries.withLock { entries in
            paths.map { path -> Entry? in
                guard let entry = entries[path], entry.handlers[id] != nil else { return nil }
                return entry
            }
        }
        // Arming waits never hold subscription or registry locks.
        return zip(paths, observations).compactMap { path, entry in
            entry?.isArmed == true ? nil : path
        }
    }

    func remove(id: UUID, paths: [URL]) {
        var retired: [Entry] = []
        entries.withLock { entries in
            for path in paths {
                guard let entry = entries[path] else { continue }
                entry.handlers.removeValue(forKey: id)
                if entry.handlers.isEmpty {
                    entries.removeValue(forKey: path)
                    retired.append(entry)
                }
            }
        }
        retired.forEach { $0.cancel() }
    }
}
