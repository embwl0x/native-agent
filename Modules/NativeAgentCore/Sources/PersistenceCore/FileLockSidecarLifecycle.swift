import Foundation

private final class FileLockSidecarEnumerationFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    func record(_ error: Error) {
        lock.lock()
        stored = error
        lock.unlock()
    }

    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Outcome of one bounded sweep of orphaned `<target>.lock` sidecars.
///
/// A sidecar whose guarded target still exists is live bookkeeping and is never
/// removed. A fresh orphan is also left alone because an in-flight writer may
/// have taken the lock before creating its target. Only old, regular, non-link
/// orphan sidecars are candidates; `reaped` means the candidate was rechecked
/// and unlinked while holding that exact sidecar's flock.
public struct FileLockSidecarReapReport: Sendable, Equatable {
    public var discovered: Int = 0
    public var candidates: Int = 0
    public var attempted: Int = 0
    public var reaped: Int = 0
    public var skippedLiveTarget: Int = 0
    public var skippedFresh: Int = 0
    public var skippedAfterContention: Int = 0
    public var deferred: Int = 0
    public var failures: Int = 0
    /// Root-relative paths successfully removed by this pass. Their audit
    /// identity is captured before unlink so a deleted leaf cannot make
    /// symlink canonicalization lose the mounted data-root relationship.
    public var reapedArtifactPaths: [String] = []

    public init() {}
}

/// Generic lifecycle owner for the sidecars created by `withFileLock`.
///
/// The lock implementation intentionally leaves its sidecar behind: unlinking
/// it on every release is unsafe because a waiter may already hold an fd for
/// that inode. This reaper instead handles crash/deletion residue at a paced
/// maintenance boundary. It serializes with the exact sidecar, rechecks that
/// the guarded target is still absent and that the sidecar is still old, then
/// unlinks as the final act inside the flock. `withFileLock`'s inode validation
/// makes waiters re-open a fresh sidecar after that unlink rather than proceed
/// on the detached inode.
public enum FileLockSidecarLifecycle {
    /// Give an in-flight writer ample time to create its guarded target. This
    /// is intentionally a wall-clock grace, not a lock-age heuristic: lock
    /// sidecar mtimes are not refreshed by `flock` acquisition.
    public static let defaultMinimumAge: TimeInterval = 24 * 60 * 60

    /// A data root can contain years of residue. Bound one pass so background
    /// maintenance stays short and reports any remaining work honestly.
    public static let maximumCandidatesPerPass = 256

    /// Reap old orphaned lock sidecars below `dataRoot`.
    ///
    /// Individual acquisition/unlink failures are counted and the rest of the
    /// pass continues; callers must treat a nonzero `failures` result as a
    /// degraded sweep. Failure to enumerate an existing data root throws so it
    /// cannot masquerade as a clean, empty result.
    @discardableResult
    public static func reapOrphanedSidecars(
        dataRoot: URL = defaultDataRoot(),
        now: Date = Date(),
        minimumAge: TimeInterval = defaultMinimumAge,
        maximumCandidates: Int = maximumCandidatesPerPass,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) async throws -> FileLockSidecarReapReport {
        try await reapOrphanedSidecars(
            dataRoot: dataRoot,
            now: now,
            minimumAge: minimumAge,
            maximumCandidates: maximumCandidates,
            persistence: persistence,
            candidateBeforeAcquire: nil
        )
    }

    /// Internal test seam. The production entry point always passes nil, so
    /// the observer cannot alter its normal lifecycle behavior. It runs after
    /// a sidecar was selected as an old orphan and immediately before this
    /// sweep tries to acquire that exact sidecar's flock.
    static func reapOrphanedSidecars(
        dataRoot: URL,
        now: Date,
        minimumAge: TimeInterval,
        maximumCandidates: Int,
        persistence: any PersistenceCoreProtocol,
        candidateBeforeAcquire: (@Sendable (URL) async -> Void)?
    ) async throws -> FileLockSidecarReapReport {
        let fm = FileManager.default
        var rootIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dataRoot.path, isDirectory: &rootIsDirectory) else {
            return FileLockSidecarReapReport()
        }
        guard rootIsDirectory.boolValue else {
            throw PersistenceCoreError.ioFailure("lock-sidecar root is not a directory: \(dataRoot.path)")
        }
        let enumerationFailure = FileLockSidecarEnumerationFailure()
        guard let enumerator = fm.enumerator(
            at: dataRoot,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationFailure.record(error)
                return false
            }
        ) else {
            throw PersistenceCoreError.ioFailure("could not enumerate lock-sidecar root: \(dataRoot.path)")
        }

        let cutoff = now.addingTimeInterval(-max(0, minimumAge))
        let limit = min(max(1, maximumCandidates), maximumCandidatesPerPass)
        var report = FileLockSidecarReapReport()
        var candidates: [URL] = []
        let entries = enumerator.allObjects.compactMap { $0 as? URL }

        for entry in entries {
            guard entry.pathExtension == "lock" else { continue }
            guard let state = sidecarState(at: entry, cutoff: cutoff) else { continue }
            report.discovered += 1
            let guarded = entry.deletingPathExtension()
            if fm.fileExists(atPath: guarded.path) {
                report.skippedLiveTarget += 1
                continue
            }
            guard state.isAged else {
                report.skippedFresh += 1
                continue
            }
            candidates.append(entry)
        }
        if let enumerationError = enumerationFailure.value {
            throw PersistenceCoreError.ioFailure(
                "could not fully enumerate lock-sidecar root \(dataRoot.path): \(enumerationError)"
            )
        }

        // Deterministic oldest-first reclamation makes a bounded pass fair and
        // lets the report's deferred count describe real remaining residue.
        candidates.sort { lhs, rhs in
            let lhsDate = sidecarState(at: lhs, cutoff: cutoff)?.modified ?? .distantFuture
            let rhsDate = sidecarState(at: rhs, cutoff: cutoff)?.modified ?? .distantFuture
            if lhsDate == rhsDate { return lhs.path < rhs.path }
            return lhsDate < rhsDate
        }
        report.candidates = candidates.count
        report.deferred = max(0, candidates.count - limit)

        for sidecar in candidates.prefix(limit) {
            let guarded = sidecar.deletingPathExtension()
            let auditPath = relativePath(sidecar, from: dataRoot)
            report.attempted += 1
            if let candidateBeforeAcquire {
                await candidateBeforeAcquire(sidecar)
            }
            do {
                let didReap = try await persistence.withFileLock(guarded) { () -> Bool in
                    // We now hold this candidate's flock. Recheck every
                    // destructive predicate after contention: a writer may
                    // have created the guarded target or replaced the sidecar
                    // while this sweep waited.
                    guard !FileManager.default.fileExists(atPath: guarded.path),
                          let state = sidecarState(at: sidecar, cutoff: cutoff),
                          state.isAged else {
                        return false
                    }
                    try FileManager.default.removeItem(at: sidecar)
                    return true
                }
                if didReap {
                    report.reaped += 1
                    report.reapedArtifactPaths.append(auditPath)
                } else {
                    report.skippedAfterContention += 1
                }
            } catch {
                // Do not let one permissions or IO problem starve other stale
                // sidecars; the mounted runner reports this as degraded.
                report.failures += 1
            }
        }
        return report
    }

    private struct SidecarState {
        var modified: Date
        var isAged: Bool
    }

    /// Fresh URL/resource values on every call; the in-lock check must not use
    /// an enumeration snapshot from before a writer changed the filesystem.
    private static func sidecarState(at sidecar: URL, cutoff: Date) -> SidecarState? {
        let fresh = URL(fileURLWithPath: sidecar.path)
        guard let values = try? fresh.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        let modified = values.contentModificationDate else {
            return nil
        }
        return SidecarState(modified: modified, isAged: modified < cutoff)
    }

    private static func relativePath(_ artifact: URL, from dataRoot: URL) -> String {
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let path = artifact.standardizedFileURL.resolvingSymlinksInPath().path
        precondition(path.hasPrefix(root + "/"), "lock sidecar artifact escaped its data root")
        return String(path.dropFirst(root.count + 1))
    }
}
