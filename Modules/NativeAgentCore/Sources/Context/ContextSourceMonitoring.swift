import Foundation
import NativeAgentShared
import PersistenceCore

// Blueprint: | `ContextSourceMonitoring.swift` | `ContextSourceRegistry`, monitor and coalescer: explicit source allowlists, owner inventories and bounded directory invalidations |

public struct ContextSourceRegistration: Sendable, Equatable {
    public let descriptor: ContextSourceDescriptor
    public let fileURL: URL
    public let allowedRoot: URL
    public let maximumUTF8Bytes: Int

    public init(
        descriptor: ContextSourceDescriptor,
        fileURL: URL,
        allowedRoot: URL,
        maximumUTF8Bytes: Int = 1_048_576
    ) {
        self.descriptor = descriptor
        self.fileURL = fileURL
        self.allowedRoot = allowedRoot
        self.maximumUTF8Bytes = max(1, maximumUTF8Bytes)
    }
}

public enum ContextSourceRegistryError: Error, Equatable, Sendable {
    case nonFileURL(String)
    case rootNotAllowed(String)
    case sourceOutsideRoot(source: String, root: String)
    case duplicateSource(String)
}

/// Explicit source allowlist. Registering one project file never authorizes a
/// scan of its parent tree or any other path on the Mac.
public actor ContextSourceRegistry {
    private var allowedRoots: Set<URL>
    private var registrations: [ContextSourceID: ContextSourceRegistration] = [:]
    private var authoritativeOwners: Set<String> = []

    public init(allowedRoots: [URL] = []) throws {
        self.allowedRoots = try Set(allowedRoots.map(Self.canonicalFileURL))
    }

    public func addAllowedRoot(_ root: URL) throws {
        allowedRoots.insert(try Self.canonicalFileURL(root))
    }

    public func replaceOwned(
        owner: String,
        with replacements: [ContextSourceRegistration]
    ) throws {
        var normalized: [ContextSourceID: ContextSourceRegistration] = [:]
        for replacement in replacements {
            guard replacement.descriptor.owner == owner else { continue }
            let value = try normalizedRegistration(replacement)
            guard normalized.updateValue(value, forKey: value.descriptor.id) == nil else {
                throw ContextSourceRegistryError.duplicateSource(value.descriptor.id.rawValue)
            }
        }
        let ownedIDs = registrations.compactMap { id, registration in
            registration.descriptor.owner == owner ? id : nil
        }
        for id in ownedIDs {
            registrations[id] = nil
        }
        for (id, registration) in normalized {
            registrations[id] = registration
        }
        authoritativeOwners.insert(owner)
    }

    /// `replaceOwned` declares each owner's complete inventory, including an
    /// empty inventory so a removed owner's last source can be
    /// retired even when discovery starts against a persisted generation.
    public func authoritativeSourceIDsByOwner() -> [String: Set<ContextSourceID>] {
        var result = Dictionary(uniqueKeysWithValues: authoritativeOwners.map {
            ($0, Set<ContextSourceID>())
        })
        for registration in registrations.values where
            authoritativeOwners.contains(registration.descriptor.owner) {
            result[registration.descriptor.owner, default: []].insert(registration.descriptor.id)
        }
        return result
    }

    public func allRegistrations() -> [ContextSourceRegistration] {
        registrations.values.sorted { $0.descriptor.id < $1.descriptor.id }
    }

    public func registrations(affectedBy directory: URL) throws -> [ContextSourceRegistration] {
        let canonicalDirectory = try Self.canonicalFileURL(directory)
        return registrations.values
            .filter { registration in
                let parent = registration.fileURL.deletingLastPathComponent()
                return NativeAgentWorkspaceRoot.relativePath(parent.path, under: canonicalDirectory.path) != nil
                    || NativeAgentWorkspaceRoot.relativePath(canonicalDirectory.path, under: parent.path) != nil
            }
            .sorted { $0.descriptor.id < $1.descriptor.id }
    }

    public func watchedDirectories() -> [URL] {
        var directories = Set(registrations.values.map { $0.fileURL.deletingLastPathComponent() })
        // Parent watches catch directory replacement so the child watch can be
        // rearmed after editors or migrations swap whole directories.
        for directory in Array(directories) {
            directories.insert(directory.deletingLastPathComponent())
        }
        return directories.sorted { $0.path < $1.path }
    }

    private static func canonicalFileURL(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw ContextSourceRegistryError.nonFileURL(url.absoluteString)
        }
        return NativeAgentWorkspaceRoot.canonicalFileURL(url,
            followFinalLink: FileManager.default.fileExists(atPath: url.standardizedFileURL.path))
    }

    private func normalizedRegistration(
        _ registration: ContextSourceRegistration
    ) throws -> ContextSourceRegistration {
        let source = try Self.canonicalFileURL(registration.fileURL)
        let declaredRoot = try Self.canonicalFileURL(registration.allowedRoot)
        guard allowedRoots.contains(declaredRoot) else {
            throw ContextSourceRegistryError.rootNotAllowed(declaredRoot.path)
        }
        guard NativeAgentWorkspaceRoot.relativePath(source.path, under: declaredRoot.path) != nil else {
            throw ContextSourceRegistryError.sourceOutsideRoot(
                source: source.path,
                root: declaredRoot.path
            )
        }
        return ContextSourceRegistration(
            descriptor: registration.descriptor,
            fileURL: source,
            allowedRoot: declaredRoot,
            maximumUTF8Bytes: registration.maximumUTF8Bytes
        )
    }
}

/// Process-owned directory watcher group. It emits only dirty-directory
/// signals; the coordinator rereads registered canonical sources afterward.
public actor ContextSourceMonitor {
    public typealias DirectoryChangeSink = @Sendable (URL) async -> Void

    private let handler: DirectoryChangeSink
    private var watches: [URL: FileChangeWatcher] = [:]
    private let events: AsyncStream<URL>
    private let continuation: AsyncStream<URL>.Continuation
    private var delivery: Task<Void, Never>?
    private var stopped = false

    public init(handler: @escaping DirectoryChangeSink) {
        self.handler = handler
        (events, continuation) = AsyncStream.makeStream()
    }

    public func setDirectories(_ directories: [URL]) {
        guard !stopped else { return }
        if delivery == nil {
            delivery = Task { [events, handler] in
                for await directory in events {
                    guard !Task.isCancelled else { return }
                    await handler(directory)
                }
            }
        }
        let desired = Set(directories.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        for (directory, watch) in Array(watches) where !desired.contains(directory) {
            watch.cancel()
            watches[directory] = nil
        }
        for directory in desired.sorted(by: { $0.path < $1.path }) where watches[directory] == nil {
            watches[directory] = FileChangeWatcher(paths: [directory], eventHandler: { [continuation] path, _ in
                continuation.yield(path)
            })
        }
    }

    public func watchedDirectories() -> [URL] {
        watches.keys.sorted { $0.path < $1.path }
    }

    public func stop() async {
        stopped = true
        for watch in watches.values { watch.cancel() }
        watches.removeAll()
        continuation.finish()
        let active = delivery
        active?.cancel()
        await active?.value
        delivery = nil
    }
}

/// Debounces bursts from atomic editor saves without adding a polling loop.
public actor ContextSourceEventCoalescer {
    public typealias DirtyDirectoriesSink = @Sendable (Set<URL>) async -> Void

    private let delay: Duration
    private let handler: DirtyDirectoriesSink
    private var dirtyDirectories: Set<URL> = []
    private var timer = StoreReloadDebouncer.Timer()
    private var activeFlush: Task<Void, Never>?
    private var closed = false

    public init(
        delay: Duration = .milliseconds(150),
        handler: @escaping DirtyDirectoriesSink
    ) {
        self.delay = max(.zero, delay)
        self.handler = handler
    }

    public func enqueue(_ directory: URL) {
        guard !closed else { return }
        dirtyDirectories.insert(directory.standardizedFileURL)
        timer.schedule(delay: delay) { [weak self] expectedGeneration in
            await self?.scheduledFlushFired(expectedGeneration)
        }
    }

    public func flush() async {
        guard !closed else { return }
        timer.cancel()
        await activeFlush?.value
        deliverDirtyDirectories()
        await activeFlush?.value
    }

    private func scheduledFlushFired(_ expectedGeneration: UInt64) {
        guard !closed, timer.take(expectedGeneration) else { return }
        // A running build finishes; these directories go right after it.
        deliverDirtyDirectories()
    }

    private func deliverDirtyDirectories() {
        guard !closed, activeFlush == nil else { return }
        let directories = dirtyDirectories
        dirtyDirectories.removeAll()
        guard !directories.isEmpty else { return }
        // Retain the handler after the debounce fires. A newer burst waits for
        // it and goes next; only shutdown cancels a running build.
        activeFlush = Task {
            if !Task.isCancelled { await handler(directories) }
            activeFlush = nil
            if !timer.isPending { deliverDirtyDirectories() }
        }
    }

    public func cancel() async {
        closed = true
        let pending = timer.cancel()
        let active = activeFlush
        active?.cancel()
        dirtyDirectories.removeAll()
        await pending?.value
        await active?.value
        activeFlush = nil
    }
}
