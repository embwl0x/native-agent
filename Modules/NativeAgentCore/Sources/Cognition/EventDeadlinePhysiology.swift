import BackgroundLoops
import Darwin
import Foundation
import NativeAgentShared
import PersistenceCore

// Blueprint: | `EventDeadlinePhysiology.swift` | `EventDeadlinePhysiology`. |

/// Events invalidate only; runners reread canonical stores.
public enum EventDeadlinePhysiology {
    /// Suppress self-write echoes only while every path matches the loop's completed generation.
    /// Without a loop ID deliver all events; system clock notifications always bypass suppression.
    public static func storeAndFileEvents(
        paths: [URL],
        stores: Set<StoreChange.Store> = [],
        notifications: [Notification.Name] = [],
        loopId: String? = nil,
        selfWrites: PhysiologySelfWriteRegistry = .shared
    ) -> AsyncStream<Void> {
        let normalized = Set(paths.map(\.standardizedFileURL))
        if let loopId {
            selfWrites.register(loopId: loopId, paths: Array(normalized))
        }
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Evaluate suppression at delivery because delayed filesystem events must be compared with the consumer's current read.
        let deliver: @Sendable () -> Void = { [continuation = pair.continuation] in
            if let loopId, selfWrites.isSelfWriteEcho(loopId: loopId) { return }
            continuation.yield(())
        }
        let watcher = FileChangeWatcher(paths: Array(normalized)) { _ in
            deliver()
        }
        let changes = StoreChangeBus.shared.changes()
        let busTask = Task {
            for await change in changes {
                guard !Task.isCancelled else { return }
                if stores.contains(change.store) || normalized.contains(change.path.standardizedFileURL) {
                    deliver()
                }
            }
        }
        let notificationTokens = ObservationNotifications(
            center: .default, names: notifications
        ) { [continuation = pair.continuation] in
            continuation.yield(())
        }
        pair.continuation.onTermination = { _ in
            watcher.cancel()
            busTask.cancel()
            notificationTokens.cancel()
        }
        return pair.stream
    }

    /// The source owner selects the files and traversal directories its directory read depends on, without reading their bodies.
    public typealias DirectoryFiles = @Sendable (URL) throws -> [URL]
    /// A file shared with unrelated state can supply the exact value the page reads; nil uses filesystem identity.
    public typealias FileReading = @Sendable (URL) throws -> JSONValue?

    /// Arm invalidations before the initial read so racing writes remain buffered.
    @MainActor
    public static func refreshOnChanges(
        paths: [URL],
        stores: Set<StoreChange.Store> = [],
        notifications: [Notification.Name] = [],
        debounceDelay: Duration = .milliseconds(250),
        directoryFiles: @escaping DirectoryFiles = { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) },
        fileReading: @escaping FileReading = { _ in nil },
        refresh: @escaping @MainActor @Sendable () async -> Void
    ) async {
        let observation = await readEvents(paths: paths, stores: stores, notifications: notifications,
            directoryFiles: directoryFiles, fileReading: fileReading)
        let debouncer = StoreReloadDebouncer(delay: debounceDelay) {
            await refresh()
        }
        // Arm before reading so a racing write remains buffered for replay.
        await refresh()
        guard !Task.isCancelled else {
            await debouncer.cancel()
            await observation.cancel()
            return
        }
        await debouncer.setVisible(true)

        for await _ in observation.stream {
            guard !Task.isCancelled else { break }
            await debouncer.signal()
        }
        await debouncer.cancel()
        await observation.cancel()
    }

    /// Exact source invalidations without scheduling a reread; the source owner holds and coalesces its work.
    public struct ReadEvents: Sendable {
        public let stream: AsyncStream<Void>
        public let cancel: @Sendable () async -> Void
    }

    @concurrent public static func readEvents(
        paths: [URL], stores: Set<StoreChange.Store> = [], notifications: [Notification.Name] = [],
        directoryFiles: @escaping DirectoryFiles = { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) },
        fileReading: @escaping FileReading = { _ in nil }
    ) async -> ReadEvents {
        let normalized = Set(paths.map(\.standardizedFileURL))
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let files = ReadFiles(paths: normalized, directoryFiles: directoryFiles, fileReading: fileReading, changed: pair.continuation)
        let changes = StoreChangeBus.shared.changes()
        let bus = Task {
            for await change in changes {
                guard !Task.isCancelled else { return }
                if stores.contains(change.store) { pair.continuation.yield(()) }
                else if normalized.contains(change.path.standardizedFileURL) { await files.receive() }
            }
        }
        let tokens = ObservationNotifications(center: .default, names: notifications) { pair.continuation.yield(()) }
        pair.continuation.onTermination = { _ in
            bus.cancel()
            tokens.cancel()
            Task { await files.cancel() }
        }
        await files.start()
        return ReadEvents(stream: pair.stream, cancel: {
            bus.cancel()
            tokens.cancel()
            await files.cancel()
            pair.continuation.finish()
        })
    }

    /// Directory metadata is not a page's input. Watch the owner's selected entries and traversal directories, including in-place edits.
    /// An unreadable identity cannot suppress its owner's read, which reports the source failure.
    private actor ReadFiles {
        private struct File: Equatable {
            let type: FileAttributeType
            let device: UInt64
            let inode: UInt64
            let size: UInt64
            let modified: Date
        }
        private enum Identity: Equatable {
            case missing
            case file(File)
            case directory(device: UInt64, inode: UInt64)
            case value(JSONValue)
        }
        private let paths: Set<URL>
        private let directoryFiles: DirectoryFiles
        private let fileReading: FileReading
        private let changed: AsyncStream<Void>.Continuation
        private var watcher: FileChangeWatcher?
        private var watched: Set<URL> = []
        private var previous: [URL: Identity]?
        private var stopped = false
        private let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        private var eventTask: Task<Void, Never>?

        init(paths: Set<URL>, directoryFiles: @escaping DirectoryFiles, fileReading: @escaping FileReading,
             changed: AsyncStream<Void>.Continuation) {
            self.paths = paths; self.directoryFiles = directoryFiles; self.fileReading = fileReading; self.changed = changed
        }

        func start() {
            guard !stopped else { return }
            receive(initial: true)
            let stream = events.stream
            eventTask = Task { [weak self] in
                for await _ in stream {
                    guard !Task.isCancelled else { return }
                    await self?.receive()
                }
            }
        }

        func receive(initial: Bool = false) {
            guard !stopped else { return }
            var selected: Set<URL> = []
            do {
                try Self.subscriptions(paths, into: &selected)
                if !selected.isSubset(of: watched) { arm(selected.union(watched)) }
                var current: [URL: Identity] = [:]
                for path in paths {
                    if let value = try fileReading(path) {
                        current[path] = .value(value)
                        continue
                    }
                    let identity = try Self.identity(path)
                    current[path] = identity
                    let readsDirectory: Bool
                    switch identity {
                    case .directory: readsDirectory = true
                    case .missing: readsDirectory = path.hasDirectoryPath
                    case .file, .value: readsDirectory = false
                    }
                    if readsDirectory {
                        for entry in try directoryFiles(path) {
                            current[entry.standardizedFileURL] = try Self.identity(entry)
                        }
                    }
                }
                try Self.subscriptions(Set(current.keys), into: &selected)
                if selected != watched { arm(selected) }
                defer { previous = current }
                if !initial, current != previous { changed.yield(()) }
            } catch {
                // A chain that cannot be read keeps every watch already armed and adds the link parents seen so far, so a repair reaches its owner.
                if !selected.isSubset(of: watched) { arm(selected.union(watched)) }
                previous = nil
                changed.yield(())
            }
        }

        private func arm(_ paths: Set<URL>) {
            let previous = watcher
            let pending = events.continuation
            watcher = FileChangeWatcher(paths: Array(paths), onFailure: { [weak self] _ in
                Task { await self?.failed() }
            }) { _ in
                pending.yield(())
            }
            watched = paths
            previous?.cancel()
        }

        private static func subscriptions(_ paths: Set<URL>, into selected: inout Set<URL>) throws {
            for path in paths {
                var remaining = ArraySlice(path.standardizedFileURL.pathComponents.dropFirst())
                var resolved = URL(fileURLWithPath: "/", isDirectory: true)
                // The kernel's symlink traversal limit also bounds expanding cycles such as link -> link/child.
                var linksLeft = Int(MAXSYMLINKS)
                while let component = remaining.first {
                    remaining = remaining.dropFirst()
                    if component == "." { continue }
                    if component == ".." { resolved = resolved.deletingLastPathComponent(); continue }
                    let next = resolved.appendingPathComponent(component)
                    let attributes: [FileAttributeKey: Any]
                    do { attributes = try FileManager.default.attributesOfItem(atPath: next.path) }
                    catch let error as CocoaError where error.isFileAbsent { resolved = next; continue }
                    catch { selected.insert(resolved); throw error }
                    guard let type = attributes[.type] as? FileAttributeType else {
                        selected.insert(resolved)
                        throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: next.path])
                    }
                    if type == .typeSymbolicLink {
                        selected.insert(resolved)
                        guard linksLeft > 0 else { throw POSIXError(.ELOOP) }
                        linksLeft -= 1
                        let target = try FileManager.default.destinationOfSymbolicLink(atPath: next.path)
                        if target.hasPrefix("/") { resolved = URL(fileURLWithPath: "/", isDirectory: true) }
                        remaining = ArraySlice(target.split(separator: "/").map(String.init) + Array(remaining))
                    } else {
                        resolved = next
                    }
                }
                selected.insert(resolved.standardizedFileURL)
            }
        }

        private func failed() {
            guard !stopped else { return }
            previous = nil
            changed.yield(())
        }

        func cancel() {
            stopped = true
            events.continuation.finish()
            eventTask?.cancel()
            eventTask = nil
            watcher?.cancel()
            watcher = nil
        }

        private static func file(_ url: URL) throws -> File {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            guard let type = attributes[.type] as? FileAttributeType,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            return File(type: type, device: device.uint64Value, inode: inode.uint64Value, size: size.uint64Value, modified: modified)
        }

        private static func identity(_ url: URL) throws -> Identity {
            let entry: File
            do { entry = try file(url) }
            catch let error as CocoaError where error.isFileAbsent { return .missing }
            guard entry.type == .typeDirectory else { return .file(entry) }
            return .directory(device: entry.device, inode: entry.inode)
        }
    }
}
