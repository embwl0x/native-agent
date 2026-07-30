import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - U2b wave 1: post-install verify / auto-revert state machine
//
// Plan design #4: before the wave-2 executor fires systemRebuild it writes
// `<dataRoot>/evolution/pending_verify.json` (write-before-terminate). At the
// next launch the app-layer reconcile block (wave 2) calls `checkAtLaunch`,
// which compares the running bundle's VERSION_SHA against the run's expected
// commit, consults Doctor, counts attempts, and returns a DECISION:
//
//   verified            sha match + doctor green  → pending cleared
//   verifiedDegraded    sha match + doctor not-green-not-critical → cleared,
//                       reason carried for the inbox card
//   revert(reason)      attempts > maxAttempts | doctor critical | sha
//                       mismatch past install-grace → pending KEPT as the
//                       evidence record for the wave-2 revert executor, which
//                       calls clearPendingVerify(runId:) after the revert
//                       lands (that call is this file's remove path)
//   waitRetry           sha mismatch inside install-grace (install_app.sh is
//                       still building/swapping) → pending kept
//   noPending / corrupt fail-closed: corrupt file is NEVER deleted or
//                       overwritten — surfaced for a human
//
// EXECUTION of the revert (git revert + reinstall + inbox card) is wave 2.
// Wave 1 ships the decision machine + the layer-2 rollback-bundle mechanics
// (aside-copy of the current .app before install, restore without rebuild).
// Nothing here installs, restarts, or touches policy files.

// MARK: - Records

public struct EvolutionPendingVerify: Sendable, Codable, Equatable {
    public var runId: String
    public var proposalId: String
    /// Commit the new bundle's VERSION_SHA must match (install stamps git
    /// short HEAD — prefix compare).
    public var expectedSha: String
    /// The promoted commit to `git revert` if verification fails.
    public var revertSha: String
    public var attempts: Int
    public var createdAt: String
    public var updatedAt: String
    public var lastCheckedAt: String?

    public init(
        runId: String,
        proposalId: String,
        expectedSha: String,
        revertSha: String,
        attempts: Int = 0,
        createdAt: String,
        updatedAt: String,
        lastCheckedAt: String? = nil
    ) {
        self.runId = runId
        self.proposalId = proposalId
        self.expectedSha = expectedSha
        self.revertSha = revertSha
        self.attempts = attempts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastCheckedAt = lastCheckedAt
    }
}

/// Typed rollback-bundle metadata (meta.json). Decoded fail-closed under the
/// rollback ops lock — corrupt meta is a distinct error, never a default.
struct RollbackBundleMeta: Sendable, Codable, Equatable {
    var runId: String
    var sourcePath: String
    var bundleName: String
    var createdAt: String
}

public enum EvolutionDoctorState: String, Sendable, Codable {
    case green
    case degraded
    case critical
    case unknown
}

public enum EvolutionRevertReason: String, Sendable, Codable {
    case attemptsExceeded = "attempts_exceeded"
    case doctorCritical = "doctor_critical"
    case shaMismatch = "sha_mismatch"
}

public enum EvolutionVerifyDecision: Sendable, Equatable {
    case noPending
    /// Fail-closed: file present but unreadable. NOT deleted, NOT proceeded on.
    case corrupt(detail: String)
    case waitRetry(EvolutionPendingVerify)
    case verified(EvolutionPendingVerify)
    case verifiedDegraded(EvolutionPendingVerify, doctor: EvolutionDoctorState)
    case revert(EvolutionPendingVerify, reason: EvolutionRevertReason)
}

// MARK: - State machine

public actor EvolutionVerifyRevert {
    private let persistence: any PersistenceCoreProtocol
    private let dataRoot: URL
    private let now: @Sendable () -> Date
    /// Launch checks past this many seconds since stage treat a sha mismatch
    /// as a failed install (install_app.sh full-builds before the swap —
    /// budget generously; plan A3).
    private let installGraceSeconds: TimeInterval
    /// Plan design #4: attempts > maxAttempts → auto-revert.
    private let maxAttempts: Int

    public init(
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        dataRoot: URL = defaultDataRoot(),
        installGraceSeconds: TimeInterval = 1800,
        maxAttempts: Int = 2,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.dataRoot = dataRoot
        self.installGraceSeconds = installGraceSeconds
        self.maxAttempts = maxAttempts
        self.now = now
    }

    // MARK: - Paths

    public nonisolated var pendingVerifyPath: URL {
        dataRoot
            .appendingPathComponent("evolution", isDirectory: true)
            .appendingPathComponent("pending_verify.json")
    }

    public nonisolated var rollbackBundlesDir: URL {
        dataRoot
            .appendingPathComponent("evolution", isDirectory: true)
            .appendingPathComponent("rollback_bundle", isDirectory: true)
    }

    public nonisolated func rollbackBundleDir(runId: String) -> URL {
        rollbackBundlesDir.appendingPathComponent(runId, isDirectory: true)
    }

    /// Rollback run lock: ALL rollback-bundle mutations (copy aside /
    /// restore / delete / retention sweep) serialize on this flock so a
    /// sweep can never race a restore (or two restores each other) —
    /// cross-process, same flock convention as the rest of the repo.
    /// (withFileLock locks `<path>.lock`, so the on-disk file is
    /// `rollback_bundle/ops.lock`.)
    public nonisolated var rollbackOpsLockPath: URL {
        rollbackBundlesDir.appendingPathComponent("ops")
    }

    // MARK: - Stage / clear (add path / remove path)

    /// Write-before-terminate. Refuses if a pending verify already exists —
    /// one evolution install in flight at a time, fail-closed.
    public func stagePendingVerify(
        runId: String,
        proposalId: String,
        expectedSha: String,
        revertSha: String
    ) async throws -> EvolutionPendingVerify {
        guard EvolutionSupport.isSafePathComponent(runId) else {
            throw EvolutionEngineError.invalidRunId(runId)
        }
        guard !expectedSha.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !revertSha.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EvolutionEngineError.underlying("stagePendingVerify: empty sha refused")
        }
        let path = pendingVerifyPath
        let stamp = EvolutionSupport.isoTimestamp(now())
        let record = EvolutionPendingVerify(
            runId: runId, proposalId: proposalId,
            expectedSha: expectedSha, revertSha: revertSha,
            attempts: 0, createdAt: stamp, updatedAt: stamp)
        return try await persistence.withFileLock(path) { [persistence] in
            if FileManager.default.fileExists(atPath: path.path) {
                // Corrupt OR live — either way refuse; a human (or the launch
                // reconcile) must resolve the existing record first.
                let existing = try? Self.loadLocked(path)
                throw EvolutionEngineError.alreadyPendingVerify(
                    existingRunId: existing?.runId ?? "unreadable")
            }
            let data = try JSONEncoder().encode(record)
            let jv = try JSONDecoder().decode(JSONValue.self, from: data)
            try await persistence.writeJSON(jv, to: path)
            return record
        }
    }

    /// Remove path. CAS on runId: clearing someone else's pending record is
    /// refused (typed error).
    public func clearPendingVerify(runId: String) async throws {
        let path = pendingVerifyPath
        try await persistence.withFileLock(path) {
            guard FileManager.default.fileExists(atPath: path.path) else { return }
            let existing = try Self.loadLocked(path)
            guard existing.runId == runId else {
                throw EvolutionEngineError.pendingVerifyMismatch(
                    expected: runId, actual: existing.runId)
            }
            try FileManager.default.removeItem(at: path)
        }
    }

    /// Locked read for callers that need the current record without deciding.
    public func currentPendingVerify() async throws -> EvolutionPendingVerify? {
        let path = pendingVerifyPath
        return try await persistence.withFileLock(path) {
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            return try Self.loadLocked(path)
        }
    }

    // MARK: - Launch-side check

    /// The launch-reconcile decision. Increments the attempts counter (under
    /// flock) on every parseable check so a crash-looping binary burns
    /// through `maxAttempts` even when nothing else is observable.
    ///
    /// `currentBundleSha`: the running bundle's Resources/VERSION_SHA (nil →
    /// treated as mismatch, fail-closed). `doctor`: injectable quick-pass.
    public func checkAtLaunch(
        currentBundleSha: String?,
        doctor: @Sendable () async -> EvolutionDoctorState
    ) async throws -> EvolutionVerifyDecision {
        let path = pendingVerifyPath
        let nowDate = now()
        let stamp = EvolutionSupport.isoTimestamp(nowDate)

        // Phase 1 (locked): load + increment attempts + persist.
        let record: EvolutionPendingVerify
        do {
            let loaded: EvolutionPendingVerify? = try await persistence.withFileLock(path) { [persistence] in
                guard FileManager.default.fileExists(atPath: path.path) else { return nil }
                var rec: EvolutionPendingVerify
                do {
                    rec = try Self.loadLocked(path)
                } catch {
                    // Fail-closed: leave the corrupt file in place for a human.
                    throw EvolutionEngineError.pendingVerifyCorrupt(
                        path: path.path, detail: "\(error)")
                }
                rec.attempts += 1
                rec.updatedAt = stamp
                rec.lastCheckedAt = stamp
                let data = try JSONEncoder().encode(rec)
                let jv = try JSONDecoder().decode(JSONValue.self, from: data)
                try await persistence.writeJSON(jv, to: path)
                return rec
            }
            guard let loaded else { return .noPending }
            record = loaded
        } catch let e as EvolutionEngineError {
            if case .pendingVerifyCorrupt(_, let detail) = e {
                return .corrupt(detail: detail)
            }
            throw e
        }

        // Phase 2 (decision, plan design #4 order):
        // attempts gate first — a crash-looping install reverts even when the
        // other signals look ambiguous.
        if record.attempts > maxAttempts {
            return .revert(record, reason: .attemptsExceeded)
        }

        let shaMatch = EvolutionSupport.shaMatches(currentBundleSha, record.expectedSha)
        if shaMatch {
            let doctorState = await doctor()
            switch doctorState {
            case .critical:
                return .revert(record, reason: .doctorCritical)
            case .green:
                try await clearPendingVerify(runId: record.runId)
                // Delete-after-verify: the aside bundle for a verified run
                // is no longer needed (best-effort; retention sweep backstops).
                _ = try? await deleteRollbackBundle(runId: record.runId)
                return .verified(record)
            case .degraded, .unknown:
                // sha landed; doctor is inconclusive — verified with the state
                // carried for the inbox card, not a revert trigger.
                try await clearPendingVerify(runId: record.runId)
                _ = try? await deleteRollbackBundle(runId: record.runId)
                return .verifiedDegraded(record, doctor: doctorState)
            }
        }

        // sha mismatch: inside install grace the installer may still be
        // building/swapping — wait. Past grace it is a failed install.
        let created = EvolutionSupport.parseISO(record.createdAt) ?? .distantPast
        if nowDate.timeIntervalSince(created) < installGraceSeconds {
            return .waitRetry(record)
        }
        return .revert(record, reason: .shaMismatch)
    }

    /// Convenience for the wave-2 reconcile: read the installed bundle's
    /// stamped VERSION_SHA (install_app.sh writes Resources/VERSION_SHA).
    public nonisolated static func readBundleVersionSha(resourcesDir: URL) -> String? {
        let url = resourcesDir.appendingPathComponent("VERSION_SHA")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Layer-2 rollback bundle (aside-copy mechanics)

    /// Copy the CURRENT bundle aside before install (install_app.sh deletes
    /// its own `.old` aside on success — the engine keeps its own copy).
    /// `ditto` preserves signatures/xattrs; FileManager.copyItem does not
    /// reliably. Refuses to overwrite an existing aside for the same run.
    public func copyBundleAside(bundlePath: URL, runId: String) async throws -> URL {
        guard EvolutionSupport.isSafePathComponent(runId) else {
            throw EvolutionEngineError.invalidRunId(runId)
        }
        let bundleName = bundlePath.lastPathComponent
        // Validate at WRITE time too, so restore never meets a name the
        // engine itself wrote but cannot safely use.
        guard EvolutionSupport.isSafePathComponent(bundleName) else {
            throw EvolutionEngineError.rollbackBundleNameInvalid(bundleName)
        }
        let destDir = rollbackBundleDir(runId: runId)
        let dest = destDir.appendingPathComponent(bundleName)
        let metaPath = destDir.appendingPathComponent("meta.json")
        let stamp = EvolutionSupport.isoTimestamp(now())
        return try await persistence.withFileLock(rollbackOpsLockPath) { [persistence] in
            guard FileManager.default.fileExists(atPath: bundlePath.path) else {
                throw EvolutionEngineError.rollbackCopyFailed(detail: "source missing: \(bundlePath.path)")
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                throw EvolutionEngineError.rollbackCopyFailed(detail: "aside already exists: \(dest.path)")
            }
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let result = try await EvolutionSupport.run(
                ["ditto", bundlePath.path, dest.path],
                cwd: destDir,
                environment: EvolutionSupport.scrubbedEnvironment(),
                timeout: 600)
            guard result.exit == 0, !result.timedOut else {
                // Cleanup the partial copy (add path failed → remove path fires).
                try? FileManager.default.removeItem(at: destDir)
                throw EvolutionEngineError.rollbackCopyFailed(
                    detail: result.timedOut ? "ditto timeout" : "ditto exit \(result.exit): \(result.stderr)")
            }
            let meta = RollbackBundleMeta(
                runId: runId, sourcePath: bundlePath.path,
                bundleName: bundleName, createdAt: stamp)
            let data = try JSONEncoder().encode(meta)
            let jv = try JSONDecoder().decode(JSONValue.self, from: data)
            try await persistence.writeJSON(jv, to: metaPath)
            return dest
        }
    }

    /// Restore a rollback bundle to `destination` (instant recovery, no
    /// rebuild). The drill is manual / wave-2; wave 1 ships + tests the
    /// mechanics. Fail-closed on a missing aside; DISTINCT fail on corrupt
    /// meta (left in place for a human); bundleName validated as a safe
    /// path component before any path is built from it. Serialized against
    /// sweep/delete/copy by the rollback ops lock.
    public func restoreBundle(runId: String, to destination: URL) async throws {
        guard EvolutionSupport.isSafePathComponent(runId) else {
            throw EvolutionEngineError.invalidRunId(runId)
        }
        let dir = rollbackBundleDir(runId: runId)
        let metaPath = dir.appendingPathComponent("meta.json")
        try await persistence.withFileLock(rollbackOpsLockPath) {
            guard FileManager.default.fileExists(atPath: metaPath.path) else {
                throw EvolutionEngineError.rollbackBundleMissing(runId: runId)
            }
            let meta: RollbackBundleMeta
            do {
                let data = try Data(contentsOf: metaPath)
                meta = try JSONDecoder().decode(RollbackBundleMeta.self, from: data)
            } catch {
                throw EvolutionEngineError.rollbackMetaCorrupt(path: metaPath.path, detail: "\(error)")
            }
            guard EvolutionSupport.isSafePathComponent(meta.bundleName) else {
                throw EvolutionEngineError.rollbackBundleNameInvalid(meta.bundleName)
            }
            let source = dir.appendingPathComponent(meta.bundleName)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw EvolutionEngineError.rollbackBundleMissing(runId: runId)
            }
            let result = try await EvolutionSupport.run(
                ["ditto", source.path, destination.path],
                cwd: dir,
                environment: EvolutionSupport.scrubbedEnvironment(),
                timeout: 600)
            guard result.exit == 0, !result.timedOut else {
                throw EvolutionEngineError.rollbackCopyFailed(
                    detail: result.timedOut ? "ditto timeout" : "ditto exit \(result.exit): \(result.stderr)")
            }
        }
    }

    /// Delete-after-verify remove path: once a run's install verifies, its
    /// aside bundle is dead weight — remove it immediately instead of waiting
    /// for the retention sweep (which remains the backstop for runs that
    /// never reach a verified decision). Returns whether a bundle existed.
    @discardableResult
    public func deleteRollbackBundle(runId: String) async throws -> Bool {
        guard EvolutionSupport.isSafePathComponent(runId) else {
            throw EvolutionEngineError.invalidRunId(runId)
        }
        let dir = rollbackBundleDir(runId: runId)
        return try await persistence.withFileLock(rollbackOpsLockPath) {
            guard FileManager.default.fileExists(atPath: dir.path) else { return false }
            try FileManager.default.removeItem(at: dir)
            return true
        }
    }

    /// Remove path for rollback bundles: keep the newest `keepLatest`, delete
    /// the rest (retention count is a NEEDS-USER policy decision; default 3).
    /// Serialized against restore/copy/delete by the rollback ops lock; only
    /// directories count as bundles (the ops lock file is skipped).
    @discardableResult
    public func sweepRollbackBundles(keepLatest: Int = 3) async -> [String] {
        let dirRoot = rollbackBundlesDir
        let removed = try? await persistence.withFileLock(rollbackOpsLockPath) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: dirRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
            else { return [String]() }
            let bundles = entries.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            let sorted = bundles.sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
            var removed: [String] = []
            for entry in sorted.dropFirst(max(0, keepLatest)) {
                try? fm.removeItem(at: entry)
                removed.append(entry.lastPathComponent)
            }
            return removed
        }
        return removed ?? []
    }

    // MARK: - Internals

    /// Fail-closed read; caller MUST hold the flock.
    private static func loadLocked(_ path: URL) throws -> EvolutionPendingVerify {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw EvolutionEngineError.pendingVerifyCorrupt(path: path.path, detail: "unreadable: \(error)")
        }
        do {
            return try JSONDecoder().decode(EvolutionPendingVerify.self, from: data)
        } catch {
            throw EvolutionEngineError.pendingVerifyCorrupt(path: path.path, detail: "decode failed: \(error)")
        }
    }
}
