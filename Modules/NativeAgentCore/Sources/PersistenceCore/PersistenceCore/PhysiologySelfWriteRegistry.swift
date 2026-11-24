import Synchronization
import Foundation
import Darwin
import NativeAgentShared

// Blueprint: | `PhysiologySelfWriteRegistry.swift` | `PhysiologySelfWriteRegistry`: loop snapshots and bounded, descriptor-verified file mutation generations |

/// Suppress watcher echoes whose file identity matches the post-tick snapshot, never by time window.
/// A foreign write during a tick may fold into its stamp; periodic and deadline wakes still cover it.
public final class PhysiologySelfWriteRegistry: Sendable {
    public static let shared = PhysiologySelfWriteRegistry()

    package struct FileGeneration: Equatable, Sendable {
        package let exists: Bool
        /// Directory identity misses in-place child rewrites, so watched directories must disable suppression.
        package let isDirectory: Bool
        /// Use APFS st_gen for content changes where supplied; zero means the volume provides no generation.
        let generation: UInt32
        package let size: Int64
        /// Nanosecond mtime distinguishes writes within one second; coarser equality would suppress foreign changes.
        let modifiedNanoseconds: Int64
        package let mode: mode_t
        var changedNanoseconds: Int64
        package let inode: UInt64
        package var changedWithContent: Bool { changedNanoseconds == modifiedNanoseconds }

        package var membership: [Int64] {
            return isDirectory ? [Int64(bitPattern: inode)] : [Int64(bitPattern: inode), size, modifiedNanoseconds,
                Int64(mode), changedNanoseconds, Int64(generation)]
        }

        package static let absent = Self(exists: false, isDirectory: false, generation: 0, size: 0, modifiedNanoseconds: 0,
                                         mode: 0, changedNanoseconds: 0, inode: 0)

        package static func read(_ fd: Int32) -> Self? {
            var info = stat()
            return unsafe fstat(fd, &info) == 0 ? Self.from(info) : nil
        }

        package func afterRename(to target: VerifiedPath.Parent) -> Self? {
            var info = stat()
            guard unsafe fstatat(target.fd, target.name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT ? self : nil }
            var expected = self
            expected.changedNanoseconds = Self.from(info).changedNanoseconds
            return expected
        }

        package static func from(_ info: stat) -> Self {
            Self(exists: true, isDirectory: info.st_mode & S_IFMT == S_IFDIR, generation: info.st_gen,
                 size: Int64(info.st_size), modifiedNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
                     + Int64(info.st_mtimespec.tv_nsec), mode: info.st_mode,
                 changedNanoseconds: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec),
                 inode: UInt64(info.st_ino))
        }
    }

    private struct State {
        var watched: [String: [URL]] = [:]
        var stamp: [String: [FileGeneration]] = [:]
        var pathStamps: [URL: FileGeneration] = [:]
        var mutations: [UUID: Mutation] = [:]
    }
    private let state = Mutex(State())
    private final class Mutation: Sendable {
        let paths: Set<URL>
        let done = ScopedWaiter()
        let confirmed = Mutex<[URL: FileGeneration]>([:])

        init(_ paths: [URL]) { self.paths = Set(paths.map(\.standardizedFileURL)) }
    }

    public init() {}

    package func beginMutation(at paths: [URL]) -> (id: UUID, release: () -> Void) {
        let id = UUID(), mutation = Mutation(paths)
        state.withLock { $0.mutations[id] = mutation }
        return (id, { [self] in
            state.withLock { _ = $0.mutations.removeValue(forKey: id) }
            mutation.done.resume()
        })
    }

    package enum Confirmation {
        case matched, concurrentWrite, unreadable

        package var receipt: [String: JSONValue] {
            switch self {
            case .matched: [:]
            case .concurrentWrite: ["concurrent_write": .bool(true)]
            case .unreadable: ["write_observation": .string("unavailable")]
            }
        }
    }

    package func confirm(_ expected: FileGeneration?, at path: URL, mutation: UUID, concurrent: Bool = false, stamp: Bool = true) -> Confirmation {
        let url = path.standardizedFileURL
        return state.withLock { state in
            guard !concurrent, let expected, let observed = Self.generation(of: url) else {
                state.pathStamps[url] = nil
                return concurrent ? .concurrentWrite : .unreadable
            }
            guard observed == expected else {
                state.pathStamps[url] = nil
                return .concurrentWrite
            }
            if stamp && expected.isDirectory {
                state.pathStamps[url] = nil
            } else if stamp {
                if state.pathStamps.count >= 1024, state.pathStamps[url] == nil, let first = state.pathStamps.keys.first {
                    state.pathStamps[first] = nil
                }
                state.pathStamps[url] = expected
                state.mutations[mutation]?.confirmed.withLock { $0[url] = expected }
            }
            return .matched
        }
    }

    package struct Observation: Sendable {
        package let generation: FileGeneration?
        package let isSelfWrite: @Sendable () async -> Bool
    }

    package func observe(_ path: URL) -> Observation {
        let url = path.standardizedFileURL
        return state.withLock { state in
            let generation = Self.generation(of: url)
            if let generation, state.pathStamps[url] == generation { return Observation(generation: generation, isSelfWrite: { true }) }
            state.pathStamps[url] = nil
            let pending = state.mutations.values.filter { $0.paths.contains(url) }
            return Observation(generation: generation) {
                guard let generation else { return false }
                for mutation in pending {
                    await mutation.done.park()
                    if mutation.confirmed.withLock({ $0[url] == generation }) { return true }
                }
                return false
            }
        }
    }

    /// Re-arming clears prior stamps: a rebuilt listener cannot inherit suppression from time it did not observe.
    public func register(loopId: String, paths: [URL]) {
        let normalized = paths.map(\.standardizedFileURL)
        state.withLock { state in
            state.watched[loopId] = normalized
            state.stamp.removeValue(forKey: loopId)
        }
    }

    /// Stamp only after an admitted body exits so subsequent unchanged identity proves its watcher echo.
    public func stampAfterTick(loopId: String) {
        let paths = state.withLock { $0.watched[loopId] }
        guard let paths, !paths.isEmpty else { return }
        let generations = paths.compactMap(Self.generation(of:))
        state.withLock { state in
            guard state.watched[loopId] == paths else { return }
            state.stamp[loopId] = generations.count == paths.count ? generations : nil
        }
    }

    /// Suppress only identity unchanged since a real tick; never suppress unregistered or not-yet-run loops.
    public func isSelfWriteEcho(loopId: String) -> Bool {
        let (paths, previous) = state.withLock { ($0.watched[loopId], $0.stamp[loopId]) }
        guard let paths, let previous, previous.count == paths.count else { return false }
        let current = paths.compactMap(Self.generation(of:))
        // Never suppress on evidence that cannot prove the file is unchanged.
        guard !current.contains(where: \.isDirectory) else { return false }
        return current == previous
    }

    public func clear(loopId: String) {
        state.withLock { state in
            state.watched.removeValue(forKey: loopId)
            state.stamp.removeValue(forKey: loopId)
        }
    }

    /// Use lstat because URL caches resource values and can return pre-write identity, hiding foreign changes.
    /// Compare symlinks as links to match the scanner’s no-follow rule.
    private static func generation(of url: URL) -> FileGeneration? {
        var info = stat()
        guard unsafe lstat(url.path, &info) == 0 else {
            return errno == ENOENT ? .absent : nil
        }
        return .from(info)
    }
}
