import Foundation

// Blueprint: | `PhysiologySelfWriteRegistry.swift` | `PhysiologySelfWriteRegistry`: generation-based echo suppression without hiding external writes |

/// Suppress watcher echoes whose file identity matches the post-tick snapshot, never by time window.
/// A foreign write during a tick may fold into its stamp; periodic and deadline wakes still cover it.
public final class PhysiologySelfWriteRegistry: @unchecked Sendable {
    public static let shared = PhysiologySelfWriteRegistry()

    struct FileGeneration: Equatable {
        let exists: Bool
        /// Directory identity misses in-place child rewrites, so watched directories must disable suppression.
        let isDirectory: Bool
        /// Use APFS st_gen for content changes where supplied; zero means the volume provides no generation.
        let generation: UInt32
        let size: Int64
        /// Nanosecond mtime distinguishes writes within one second; coarser equality would suppress foreign changes.
        let modifiedNanoseconds: Int64
        let inode: UInt64
    }

    private let lock = NSLock()
    private var watched: [String: [URL]] = [:]
    private var stamp: [String: [FileGeneration]] = [:]

    public init() {}

    /// Carry one work identity through reflex and model execution regardless of authored part.
    public static func intentionWriteID(_ work: String, _ url: URL) -> String {
        "intention:" + work + ":" + url.standardizedFileURL.path
    }

    /// Re-arming clears prior stamps: a rebuilt listener cannot inherit suppression from time it did not observe.
    public func register(loopId: String, paths: [URL]) {
        let normalized = paths.map(\.standardizedFileURL)
        lock.lock(); defer { lock.unlock() }
        watched[loopId] = normalized
        stamp.removeValue(forKey: loopId)
    }

    /// Stamp only after an admitted body exits so subsequent unchanged identity proves its watcher echo.
    public func stampAfterTick(loopId: String) {
        lock.lock()
        let paths = watched[loopId]
        lock.unlock()
        guard let paths, !paths.isEmpty else { return }
        let generations = paths.map(Self.generation(of:))
        lock.lock(); defer { lock.unlock() }
        // Drop a stamp if registration changed during stat; comparing it against the replacement paths would be false evidence.
        guard watched[loopId] == paths else { return }
        stamp[loopId] = generations
    }

    /// Suppress only identity unchanged since a real tick; never suppress unregistered or not-yet-run loops.
    public func isSelfWriteEcho(loopId: String) -> Bool {
        lock.lock()
        let paths = watched[loopId]
        let previous = stamp[loopId]
        lock.unlock()
        guard let paths, let previous, previous.count == paths.count else { return false }
        let current = paths.map(Self.generation(of:))
        // Never suppress on evidence that cannot prove the file is unchanged.
        guard !current.contains(where: \.isDirectory) else { return false }
        return current == previous
    }

    public func clear(loopId: String) {
        lock.lock(); defer { lock.unlock() }
        watched.removeValue(forKey: loopId)
        stamp.removeValue(forKey: loopId)
    }

    /// Use lstat because URL caches resource values and can return pre-write identity, hiding foreign changes.
    /// Compare symlinks as links to match the scanner’s no-follow rule.
    static func generation(of url: URL) -> FileGeneration {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return FileGeneration(
                exists: false, isDirectory: false, generation: 0,
                size: 0, modifiedNanoseconds: 0, inode: 0
            )
        }
        let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(info.st_mtimespec.tv_nsec)
        return FileGeneration(
            exists: true,
            isDirectory: (info.st_mode & S_IFMT) == S_IFDIR,
            generation: info.st_gen,
            size: Int64(info.st_size),
            modifiedNanoseconds: mtime,
            inode: UInt64(info.st_ino)
        )
    }
}
