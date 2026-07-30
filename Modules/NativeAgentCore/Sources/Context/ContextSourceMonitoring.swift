import Darwin
import Dispatch
import Foundation

public struct ContextSourceRegistration: Sendable, Equatable {
    public let descriptor: ContextSourceDescriptor
    public let fileURL: URL
    public let allowedRoot: URL
    public let maximumUTF8Bytes: Int
    public let requiredPersonaDocument: RequiredPersonaDocumentKind?
    public let personaID: ContextPersonaID?

    public init(
        descriptor: ContextSourceDescriptor,
        fileURL: URL,
        allowedRoot: URL,
        maximumUTF8Bytes: Int = 1_048_576,
        requiredPersonaDocument: RequiredPersonaDocumentKind? = nil,
        personaID: ContextPersonaID? = nil
    ) {
        self.descriptor = descriptor
        self.fileURL = fileURL
        self.allowedRoot = allowedRoot
        self.maximumUTF8Bytes = max(1, maximumUTF8Bytes)
        self.requiredPersonaDocument = requiredPersonaDocument
        self.personaID = personaID
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

    public init(allowedRoots: [URL] = []) throws {
        self.allowedRoots = try Set(allowedRoots.map(Self.canonicalFileURL))
    }

    public func addAllowedRoot(_ root: URL) throws {
        allowedRoots.insert(try Self.canonicalFileURL(root))
    }

    public func register(_ registration: ContextSourceRegistration) throws {
        let normalized = try normalizedRegistration(registration)
        guard registrations[registration.descriptor.id] == nil else {
            throw ContextSourceRegistryError.duplicateSource(registration.descriptor.id.rawValue)
        }
        registrations[registration.descriptor.id] = normalized
    }

    public func replace(_ registration: ContextSourceRegistration) throws {
        registrations[registration.descriptor.id] = try normalizedRegistration(registration)
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
    }

    public func remove(_ sourceID: ContextSourceID) -> ContextSourceRegistration? {
        registrations.removeValue(forKey: sourceID)
    }

    public func registration(for sourceID: ContextSourceID) -> ContextSourceRegistration? {
        registrations[sourceID]
    }

    public func allRegistrations() -> [ContextSourceRegistration] {
        registrations.values.sorted { $0.descriptor.id < $1.descriptor.id }
    }

    public func registrations(affectedBy directory: URL) throws -> [ContextSourceRegistration] {
        let canonicalDirectory = try Self.canonicalFileURL(directory)
        return registrations.values
            .filter { registration in
                let parent = registration.fileURL.deletingLastPathComponent()
                return parent == canonicalDirectory
                    || Self.isDescendant(parent, of: canonicalDirectory)
                    || Self.isDescendant(canonicalDirectory, of: parent)
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

    public func allowedRootList() -> [URL] {
        allowedRoots.sorted { $0.path < $1.path }
    }

    private static func canonicalFileURL(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw ContextSourceRegistryError.nonFileURL(url.absoluteString)
        }
        let standardized = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath()
        }
        let resolvedParent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        return resolvedParent.appendingPathComponent(standardized.lastPathComponent).standardizedFileURL
    }

    private func normalizedRegistration(
        _ registration: ContextSourceRegistration
    ) throws -> ContextSourceRegistration {
        let source = try Self.canonicalFileURL(registration.fileURL)
        let declaredRoot = try Self.canonicalFileURL(registration.allowedRoot)
        guard allowedRoots.contains(declaredRoot) else {
            throw ContextSourceRegistryError.rootNotAllowed(declaredRoot.path)
        }
        guard Self.isDescendant(source, of: declaredRoot) else {
            throw ContextSourceRegistryError.sourceOutsideRoot(
                source: source.path,
                root: declaredRoot.path
            )
        }
        return ContextSourceRegistration(
            descriptor: registration.descriptor,
            fileURL: source,
            allowedRoot: declaredRoot,
            maximumUTF8Bytes: registration.maximumUTF8Bytes,
            requiredPersonaDocument: registration.requiredPersonaDocument,
            personaID: registration.personaID
        )
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}

public struct ContextDirectoryEvent: Sendable, Equatable {
    public let directory: URL
    public let rawFlags: UInt
    public let observedAt: Date

    public init(directory: URL, rawFlags: UInt, observedAt: Date = Date()) {
        self.directory = directory
        self.rawFlags = rawFlags
        self.observedAt = observedAt
    }

    public var requiresRearm: Bool {
        let flags = DispatchSource.FileSystemEvent(rawValue: rawFlags)
        return !flags.intersection([.delete, .rename, .revoke]).isEmpty
    }
}

private final class ContextDirectoryWatch: @unchecked Sendable {
    let directory: URL
    private let source: DispatchSourceFileSystemObject
    private let descriptor: Int32

    init(
        directory: URL,
        queue: DispatchQueue,
        handler: @escaping @Sendable (ContextDirectoryEvent) -> Void
    ) throws {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        self.directory = directory
        self.descriptor = descriptor
        self.source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak source] in
            guard let source else { return }
            handler(ContextDirectoryEvent(
                directory: directory,
                rawFlags: source.data.rawValue
            ))
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
    }

    func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}

/// Process-owned directory watcher group. It emits only dirty-directory
/// signals; the coordinator rereads registered canonical sources afterward.
public actor ContextSourceMonitor {
    public typealias EventHandler = @Sendable (ContextDirectoryEvent) async -> Void

    private let queue = DispatchQueue(label: "NativeAgent.ContextSourceMonitor", qos: .utility)
    private let handler: EventHandler
    private var watches: [URL: ContextDirectoryWatch] = [:]

    public init(handler: @escaping EventHandler) {
        self.handler = handler
    }

    public func setDirectories(_ directories: [URL]) {
        let desired = Set(directories.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        for (directory, watch) in watches where !desired.contains(directory) {
            watch.cancel()
            watches[directory] = nil
        }
        for directory in desired.sorted(by: { $0.path < $1.path }) where watches[directory] == nil {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            guard let watch = try? ContextDirectoryWatch(
                directory: directory,
                queue: queue,
                handler: { [handler] event in
                    Task { await handler(event) }
                }
            ) else { continue }
            watches[directory] = watch
        }
    }

    public func watchedDirectories() -> [URL] {
        watches.keys.sorted { $0.path < $1.path }
    }

    public func stop() {
        for watch in watches.values { watch.cancel() }
        watches.removeAll()
    }
}

/// Debounces bursts from atomic editor saves without adding a polling loop.
public actor ContextSourceEventCoalescer {
    public typealias FlushHandler = @Sendable (Set<URL>) async -> Void

    private let delayNanoseconds: UInt64
    private let handler: FlushHandler
    private var dirtyDirectories: Set<URL> = []
    private var pendingFlush: Task<Void, Never>?
    private var flushGeneration: UInt64 = 0

    public init(
        delay: Duration = .milliseconds(150),
        handler: @escaping FlushHandler
    ) {
        let components = delay.components
        let seconds = max(0, components.seconds)
        let attoseconds = max(0, components.attoseconds)
        let nanosFromSeconds = UInt64(clamping: seconds) * 1_000_000_000
        let nanosFromAttoseconds = UInt64(clamping: attoseconds / 1_000_000_000)
        self.delayNanoseconds = nanosFromSeconds &+ nanosFromAttoseconds
        self.handler = handler
    }

    public func enqueue(_ directory: URL) {
        dirtyDirectories.insert(directory.standardizedFileURL)
        flushGeneration &+= 1
        let expectedGeneration = flushGeneration
        pendingFlush?.cancel()
        let delayNanoseconds = self.delayNanoseconds
        pendingFlush = Task { [weak self] in
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self?.scheduledFlushFired(expectedGeneration)
        }
    }

    public func flush() async {
        flushGeneration &+= 1
        let scheduledFlush = pendingFlush
        pendingFlush = nil
        scheduledFlush?.cancel()
        await deliverDirtyDirectories()
    }

    private func scheduledFlushFired(_ expectedGeneration: UInt64) async {
        guard expectedGeneration == flushGeneration else { return }
        pendingFlush = nil
        await deliverDirtyDirectories()
    }

    private func deliverDirtyDirectories() async {
        let directories = dirtyDirectories
        dirtyDirectories.removeAll()
        guard !directories.isEmpty else { return }
        await handler(directories)
    }

    public func cancel() {
        flushGeneration &+= 1
        pendingFlush?.cancel()
        pendingFlush = nil
        dirtyDirectories.removeAll()
    }
}
