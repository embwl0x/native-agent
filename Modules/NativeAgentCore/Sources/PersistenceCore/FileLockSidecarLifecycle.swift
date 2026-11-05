import Foundation
import Darwin
import os

// Blueprint: | `FileLockSidecarLifecycle.swift` | `FileLockSidecarLifecycle`; Reap only old locked orphan sidecars. |

/// Reap only old regular orphan sidecars, rechecked under their exact flock; fresh orphans may belong to in-flight writers.
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
    /// Capture root-relative audit identity before unlink so a missing leaf cannot change symlink canonicalization.
    public var reapedArtifactPaths: [String] = []

    public init() {}
}

/// Release leaves sidecars in place because waiters may hold their inode. Reap under the exact flock after rechecking absence and age; inode validation makes
/// waiters reopen detached sidecars.
public enum FileLockSidecarLifecycle {
    /// Allow in-flight writers to create their target; use wall-clock age because flock does not refresh mtime.
    public static let defaultMinimumAge: TimeInterval = 24 * 60 * 60

    /// Bound maintenance work so years of residue cannot monopolize one pass.
    public static let maximumCandidatesPerPass = 256

    /// Count individual failures and continue; enumeration failure throws so an unreadable root cannot look clean.
    @discardableResult
    public static func reapOrphanedSidecars(
        dataRoot: URL = defaultDataRoot(),
        now: Date = Date(),
        minimumAge: TimeInterval = defaultMinimumAge,
        maximumCandidates: Int = maximumCandidatesPerPass
    ) async throws -> FileLockSidecarReapReport {
        let fm = FileManager.default
        var rootIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dataRoot.path, isDirectory: &rootIsDirectory) else {
            return FileLockSidecarReapReport()
        }
        guard rootIsDirectory.boolValue else {
            throw PersistenceCoreError.ioFailure("lock-sidecar root is not a directory: \(dataRoot.path)")
        }
        let enumerationFailure = OSAllocatedUnfairLock<Error?>(initialState: nil)
        guard let enumerator = fm.enumerator(
            at: dataRoot,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationFailure.withLock { $0 = error }
                return false
            }
        ) else {
            throw PersistenceCoreError.ioFailure("could not enumerate lock-sidecar root: \(dataRoot.path)")
        }

        let cutoff = now.addingTimeInterval(-max(0, minimumAge))
        let limit = min(max(1, maximumCandidates), maximumCandidatesPerPass)
        var report = FileLockSidecarReapReport()
        var candidates: [(url: URL, modified: Date)] = []
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
            candidates.append((entry, state.modified))
        }
        if let enumerationError = enumerationFailure.withLock({ $0 }) {
            throw PersistenceCoreError.ioFailure(
                "could not fully enumerate lock-sidecar root \(dataRoot.path): \(enumerationError)"
            )
        }

        // Oldest-first order keeps bounded reclamation fair and deferred counts meaningful.
        candidates.sort { lhs, rhs in
            if lhs.modified == rhs.modified { return lhs.url.path < rhs.url.path }
            return lhs.modified < rhs.modified
        }
        report.candidates = candidates.count
        report.deferred = max(0, candidates.count - limit)

        for candidate in candidates.prefix(limit) {
            let sidecar = candidate.url
            let guarded = sidecar.deletingPathExtension()
            let auditPath = relativePath(sidecar, from: dataRoot)
            report.attempted += 1
            do {
                let didReap = try await SwiftNativePersistenceCore.withFileLock(guarded, waitingAtMost: 0) { () -> Bool in
                    // Recheck every destructive predicate under the flock because contention may have changed the target or sidecar.
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
            } catch let error as NSError where error.domain == "FileLock" && error.code == Int(ETIMEDOUT) {
                report.deferred += 1
            } catch {
                // Do not let one permissions or IO problem starve other stale sidecars; the mounted runner reports this as degraded.
                report.failures += 1
            }
        }
        return report
    }

    private struct SidecarState {
        var modified: Date
        var isAged: Bool
    }

    /// Fresh URL/resource values on every call; the in-lock check must not use an enumeration snapshot from before a writer changed the filesystem.
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
        guard let tail = NativeAgentWorkspaceRoot.relativePath(path, under: root), !tail.isEmpty else {
            preconditionFailure("lock sidecar artifact escaped its data root")
        }
        return tail
    }
}
