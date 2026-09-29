import Foundation

/// C6 (2026-08-28): self-write suppression for event/deadline physiology
/// watchers, keyed on a WRITER GENERATION — never on a time window.
///
/// The problem: a physiology loop watches the very store its own tick writes.
/// The tick lands, the file changes, the watcher fires, the loop ticks again.
/// The github_tracking / desk lanes churned exactly this way. A time window
/// ("ignore events for 2s after a tick") is the wrong fix twice over: it drops
/// a genuine FOREIGN write that lands inside the window, and it still admits
/// the loop's own echo when FSEvents coalesces past the window — file-system
/// notifications carry no delivery deadline.
///
/// The generation is the answer because it is a property of the DATA, not of
/// the clock: after each tick the registry snapshots the identity of every
/// watched path (APFS `st_gen` where the volume supplies it, plus size,
/// nanosecond mtime and inode). A later watcher
/// event whose observed generation is IDENTICAL to that snapshot carries no new
/// information — nothing has changed since this loop last looked, so the event
/// is its own echo and is suppressed. Any differing generation is a real change
/// and is delivered, no matter how long after the tick it arrives.
///
/// Declared limit: a foreign write that lands DURING a tick, after the loop has
/// already read the file, is folded into that tick's stamp and therefore not
/// re-delivered. The loop's periodic cadence and its deadline lane still cover
/// it. Narrowing that would need the write itself to carry the generation,
/// which the file-system watcher cannot provide.
public final class PhysiologySelfWriteRegistry: @unchecked Sendable {
    public static let shared = PhysiologySelfWriteRegistry()

    /// Identity of one file at one instant. Equality means "unchanged".
    struct FileGeneration: Equatable {
        let exists: Bool
        /// A DIRECTORY's generation only moves when an ENTRY is added or
        /// removed — an in-place rewrite of a file inside it leaves the
        /// directory byte-identical. Suppressing on that would silently drop a
        /// real foreign write, so a watched directory disables suppression
        /// entirely (see `isSelfWriteEcho`).
        let isDirectory: Bool
        /// APFS bumps `st_gen` on content change; it is THE writer generation
        /// where the volume supplies it, and 0 where it does not.
        let generation: UInt32
        let size: Int64
        /// Nanosecond mtime. Second-granularity would let two writes inside the
        /// same second read as unchanged.
        let modifiedNanoseconds: Int64
        let inode: UInt64
    }

    private let lock = NSLock()
    private var watched: [String: [URL]] = [:]
    private var stamp: [String: [FileGeneration]] = [:]

    public init() {}

    /// Arm suppression for `loopId` over `paths`. Called by the event stream as
    /// it builds its watcher. Re-arming (a listener restart) drops any previous
    /// stamp: a rebuilt listener must not inherit a suppression decision taken
    /// against a window in which it was not listening.
    public func register(loopId: String, paths: [URL]) {
        let normalized = paths.map(\.standardizedFileURL)
        lock.lock(); defer { lock.unlock() }
        watched[loopId] = normalized
        stamp.removeValue(forKey: loopId)
    }

    /// Record the generation of `loopId`'s watched paths as of the END of a
    /// tick that actually ran its body. Everything unchanged from here is this
    /// loop's own work.
    public func stampAfterTick(loopId: String) {
        lock.lock()
        let paths = watched[loopId]
        lock.unlock()
        guard let paths, !paths.isEmpty else { return }
        let generations = paths.map(Self.generation(of:))
        lock.lock(); defer { lock.unlock() }
        // A concurrent `register` may have replaced the path set while we were
        // stat'ing; a stamp against the old set would be compared against the
        // new one. Drop it rather than store a mismatched snapshot.
        guard watched[loopId] == paths else { return }
        stamp[loopId] = generations
    }

    /// True when nothing under `loopId`'s watched paths has changed since the
    /// last `stampAfterTick`. An unregistered loop, or one that has not ticked
    /// yet, is never suppressed.
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

    /// Forget `loopId` entirely (unregistration / manager shutdown).
    public func clear(loopId: String) {
        lock.lock(); defer { lock.unlock() }
        watched.removeValue(forKey: loopId)
        stamp.removeValue(forKey: loopId)
    }

    /// `lstat(2)` deliberately, NOT `URL.resourceValues`: URL caches its
    /// resource values, so a second read of the same URL object returns the
    /// generation from BEFORE the write and every change reads as unchanged —
    /// which would suppress real foreign writes forever. (Caught by
    /// `sameSizeContentChangeIsDetected`, which saw an identical mtime across a
    /// rewrite.) `lstat` also means a watched path that is a symlink is
    /// compared as the LINK, matching the scanner's no-follow rule.
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
