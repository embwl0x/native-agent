import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore

// MARK: - Result shapes

public struct SnapshotResult: Sendable, Codable, Equatable {
    public var ok: Bool
    public var runId: String
    public var error: String?
    public init(ok: Bool, runId: String, error: String? = nil) {
        self.ok = ok; self.runId = runId; self.error = error
    }
}

public struct PromoteOpResult: Sendable, Codable, Equatable {
    public var ok: Bool
    public var runId: String
    public var commitSha: String?
    public var error: String?
    /// R23 (2026-07-01): whether the promoted diff touches .swift sources —
    /// the running app is stale until a full rebuild when true.
    public var swiftChanged: Bool?
    public init(ok: Bool, runId: String, commitSha: String? = nil, error: String? = nil, swiftChanged: Bool? = nil) {
        self.ok = ok; self.runId = runId; self.commitSha = commitSha; self.error = error; self.swiftChanged = swiftChanged
    }
}

public struct RevertOpResult: Sendable, Codable, Equatable {
    public var ok: Bool
    public var runId: String
    public var error: String?
    public init(ok: Bool, runId: String, error: String? = nil) {
        self.ok = ok; self.runId = runId; self.error = error
    }
}

public struct SweepReport: Sendable, Codable, Equatable {
    public var ok: Bool
    public var inspected: Int
    public var kept: Int
    public var removed: Int
    public var error: String?
    public init(ok: Bool, inspected: Int = 0, kept: Int = 0, removed: Int = 0, error: String? = nil) {
        self.ok = ok; self.inspected = inspected; self.kept = kept; self.removed = removed; self.error = error
    }
}

// MARK: - Orchestrator

/// End-to-end self-improvement lifecycle. Holds pending runs on disk and
/// gates promotion behind a `swift build` compile check. Public-release
/// builds without a `.git` directory degrade to disabled stubs (every
/// boundary returns shape-matched no-git results, never throws).
public actor SelfImprovementOrchestrator {
    public static let shared = SelfImprovementOrchestrator()

    private let persistence: any PersistenceCoreProtocol
    private let dataRoot: URL
    private let repoRoot: URL
    private let packagePath: String?

    private var pending: [String: ImprovementRun] = [:]
    private var rehydrated = false
    /// U5 fix-round (2026-06-11, gpt-5.5 review): raw pending_actions.json
    /// entries that failed to decode as ImprovementRun (corrupt rows,
    /// future-schema rows). The old rehydrate silently SKIPPED them, and any
    /// later persistPending (e.g. an expiry rewrite) rewrote only the decoded
    /// map — permanently destroying them. Corrupt-preserve: hold the raw
    /// JSONValues here and carry them through every rewrite verbatim. Expiry
    /// applies only to decoded entries.
    private var undecodedPending: [JSONValue] = []

    public init(
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        dataRoot: URL = defaultDataRoot(),
        repoRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        packagePath: String? = "Modules/NativeAgentCore"
    ) {
        self.persistence = persistence
        self.dataRoot = dataRoot
        self.repoRoot = repoRoot
        self.packagePath = packagePath
    }

    // MARK: - Availability

    /// `(available, reason)`. Returns `(false, "no_git")` when the repo has no
    /// `.git` dir (public release / non-repo install). Callers use this to
    /// short-circuit every boundary into a shape-matched disabled stub.
    public func selfImprovementAvailable() -> (Bool, String?) {
        let git = repoRoot.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: git.path) {
            return (true, nil)
        }
        return (false, "no_git")
    }

    // MARK: - Public boundaries

    public func startImprovement(objective: String) async throws -> ImprovementRun {
        let (ok, reason) = selfImprovementAvailable()
        if !ok {
            return ImprovementRun(id: "", status: "disabled", phase: "disabled", objective: objective, exitReason: reason)
        }
        await rehydrateIfNeeded()
        let id = newRunId()
        let run = ImprovementRun(
            id: id,
            status: "pending",
            phase: "pending",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            objective: objective
        )
        pending[id] = run
        try await persistPending()
        return run
    }

    public func snapshot(runId: String) async throws -> SnapshotResult {
        let (ok, reason) = selfImprovementAvailable()
        if !ok { return SnapshotResult(ok: false, runId: runId, error: reason) }
        await rehydrateIfNeeded()
        guard var run = pending[runId] else {
            return SnapshotResult(ok: false, runId: runId, error: "not_found")
        }
        run.phase = "snapshotted"
        run.status = "staged"
        pending[runId] = run
        try await persistPending()
        return SnapshotResult(ok: true, runId: runId)
    }

    public func promote(runId: String) async throws -> PromoteOpResult {
        try await promote(runId: runId, expectedHead: nil, expectedDiffSHA256: nil)
    }

    public func promote(
        runId: String,
        expectedHead: String?,
        expectedDiffSHA256: String?
    ) async throws -> PromoteOpResult {
        let (ok, reason) = selfImprovementAvailable()
        if !ok { return PromoteOpResult(ok: false, runId: runId, error: reason) }
        await rehydrateIfNeeded()
        let ledger = await loadLedgerRun(runId: runId)
        let pendingRun = pending[runId]
        guard var run = ledger?.run ?? pendingRun else {
            return PromoteOpResult(ok: false, runId: runId, error: "not_found")
        }

        guard let artifact = try promotionArtifact(for: run, rawObject: ledger?.object) else {
            return PromoteOpResult(ok: false, runId: runId, error: "no_promotion_artifact")
        }
        if let expected = expectedDiffSHA256?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expected.isEmpty {
            let actual = sha256Hex(artifact.diffText)
            guard actual.lowercased() == expected.lowercased() else {
                return PromoteOpResult(ok: false, runId: runId, error: "expected_diff_mismatch")
            }
        }

        let effectiveExpectedHead = expectedHead ?? stringValue(ledger?.object, "expectedHead")
        let message = promotionCommitMessage(runId: runId, objective: run.objective)
        let git = SelfImprovementGitOps(repoRoot: repoRoot)
        let commitSha: String
        do {
            commitSha = try await git.applyDiffAndCommit(
                diffText: artifact.diffText,
                message: message,
                expectedHead: effectiveExpectedHead,
                validateAppliedDiff: { [repoRoot, packagePath] in
                    // U5 fix-round: awaited off-thread so the 900s build
                    // budget never pins the GitOps actor (finding 4).
                    let buildResult = await Self.runSwiftBuildGateOffThread(repoRoot: repoRoot, packagePath: packagePath)
                    guard buildResult.ok else {
                        throw SelfImprovementError.underlying("compile_gate_failed: \(Self.trimForError(buildResult.stderr))")
                    }
                }
            )
        } catch let error as SelfImprovementGitError {
            return PromoteOpResult(ok: false, runId: runId, error: Self.gitErrorCode(error))
        } catch {
            return PromoteOpResult(ok: false, runId: runId, error: error.localizedDescription)
        }
        run.phase = "promoted"
        run.status = "promoted"
        run.promotedCommitSha = commitSha
        run.completedAt = ISO8601DateFormatter().string(from: Date())
        if pendingRun != nil {
            pending[runId] = run
            try await persistPending()
        }
        if ledger != nil {
            try await markLedgerRunPromoted(runId: runId, commitSha: commitSha, completedAt: run.completedAt)
        }
        return PromoteOpResult(
            ok: true,
            runId: runId,
            commitSha: commitSha,
            swiftChanged: Self.diffTouchesSwift(artifact.diffText)
        )
    }

    /// R23: promotion commits source only — surface whether the applied diff
    /// touched .swift files so the UI can warn that a rebuild is needed.
    /// Classifies from file-header lines only (never diff content), and by
    /// exact `.swift` suffix so `.swift.orig` / prose mentions don't count.
    /// Header paths are normalized past git's optional `\t<mtime>` suffix and
    /// CRLF endings; pure copy/rename headers count too.
    static func diffTouchesSwift(_ diffText: String) -> Bool {
        let headerPrefixes = ["+++ ", "--- ", "rename to ", "rename from ", "copy to ", "copy from "]
        // split on \.isNewline, NOT "\n": Swift folds "\r\n" into one grapheme
        // cluster, so a Character separator of "\n" never splits CRLF text.
        for rawLine in diffText.split(whereSeparator: \.isNewline) {
            guard headerPrefixes.contains(where: { rawLine.hasPrefix($0) }) else { continue }
            var line = rawLine
            if let tab = line.firstIndex(of: "\t") { line = line[..<tab] }
            while line.hasSuffix("\r") { line = line.dropLast() }
            if line.hasSuffix(".swift") { return true }
        }
        return false
    }

    public func revert(runId: String) async throws -> RevertOpResult {
        try await revert(runId: runId, expectedCommitSha: nil)
    }

    /// U2b wave 1: the W6 honest stub replaced with the real wiring —
    /// `SelfImprovementGitOps.revertCommit` on the run's promoted commit,
    /// with an optional expectedCommitSha CAS. The honesty is preserved on
    /// every failure path: the record is left untouched unless the revert
    /// commit actually lands (revertCommit aborts conflicted reverts, so the
    /// repo comes back clean either way).
    public func revert(runId: String, expectedCommitSha: String?) async throws -> RevertOpResult {
        let (ok, reason) = selfImprovementAvailable()
        if !ok { return RevertOpResult(ok: false, runId: runId, error: reason) }
        await rehydrateIfNeeded()
        let ledger = await loadLedgerRun(runId: runId)
        let pendingRun = pending[runId]
        guard var run = ledger?.run ?? pendingRun else {
            return RevertOpResult(ok: false, runId: runId, error: "not_found")
        }
        guard let promoted = run.promotedCommitSha?.trimmingCharacters(in: .whitespacesAndNewlines),
              !promoted.isEmpty else {
            // CONTRACT (U2b wave 1): a run that exists but was never promoted
            // returns `no_promoted_commit`. The pre-wave W6 honest stub
            // returned `revert_not_implemented` on this path; that string is
            // retired — repo-wide grep (2026-06-10) found no remaining
            // code/test consumers, only historical docs. Exact-string callers
            // must match `no_promoted_commit`.
            return RevertOpResult(ok: false, runId: runId, error: "no_promoted_commit")
        }

        let git = SelfImprovementGitOps(repoRoot: repoRoot)
        let newHead: String
        do {
            newHead = try await git.revertCommit(
                commitSha: promoted,
                expectedCommitSha: expectedCommitSha
            )
        } catch let error as SelfImprovementGitError {
            return RevertOpResult(ok: false, runId: runId, error: Self.gitErrorCode(error))
        } catch {
            return RevertOpResult(ok: false, runId: runId, error: error.localizedDescription)
        }

        run.phase = "reverted"
        run.status = "reverted"
        run.revertCommitSha = newHead
        run.completedAt = ISO8601DateFormatter().string(from: Date())
        if pendingRun != nil {
            pending[runId] = run
            try await persistPending()
        }
        if ledger != nil {
            try await markLedgerRunReverted(runId: runId, revertCommitSha: newHead, completedAt: run.completedAt)
        }
        return RevertOpResult(ok: true, runId: runId)
    }

    public func sweep() async throws -> SweepReport {
        let (ok, reason) = selfImprovementAvailable()
        if !ok { return SweepReport(ok: false, error: reason) }
        await rehydrateIfNeeded()
        let inspected = pending.count
        // Keep all non-terminal phases; sweep terminal entries older than 7 days.
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let iso = ISO8601DateFormatter()
        var removed = 0
        for (id, run) in pending {
            let terminal = (run.phase == "promoted" || run.phase == "reverted")
            if !terminal { continue }
            let ts = run.completedAt ?? run.createdAt ?? ""
            if let d = iso.date(from: ts), d < cutoff {
                pending.removeValue(forKey: id)
                removed += 1
            }
        }
        try await persistPending()
        return SweepReport(ok: true, inspected: inspected, kept: pending.count, removed: removed)
    }

    public func listPending() async throws -> [ImprovementRun] {
        let (ok, _) = selfImprovementAvailable()
        if !ok { return [] }
        await rehydrateIfNeeded()
        return Array(pending.values).sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
    }

    /// Zero-arg wrapper for BackgroundLoopsManager.runTickOnce(loopId: "self_improvement_sweep").
    public func runSweepOnce() async {
        do {
            let report = try await sweep()
            if !report.ok {
                FileHandle.standardError.write(Data("self_improvement_sweep: disabled (\(report.error ?? "unknown"))\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("self_improvement_sweep: error \(error)\n".utf8))
        }
    }

    // MARK: - Internals

    private func pendingPath() -> URL {
        dataRoot.appendingPathComponent("improvements/pending_actions.json")
    }

    private func runsPath() -> URL {
        dataRoot.appendingPathComponent("improvements/runs.json")
    }

    private func rehydrateIfNeeded() async {
        if rehydrated { return }
        rehydrated = true
        // Same flock convention as every other shared store: pending_actions
        // is read and written under the file lock so a sibling process
        // mid-write can never hand us a torn read.
        let path = pendingPath()
        let raw = (try? await persistence.withFileLock(path) { [persistence] in
            await persistence.readJSON(path, defaultValue: .array([]))
        }) ?? .array([])
        guard case .array(let arr) = raw else { return }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        for entry in arr {
            guard let data = try? encoder.encode(entry),
                  let run = try? decoder.decode(ImprovementRun.self, from: data),
                  !run.id.isEmpty
            else {
                // Corrupt-preserve (U5 fix-round): an undecodable entry is
                // NEVER dropped — it rides along raw through every rewrite so
                // a corrupt/future-schema row survives expiry persists.
                undecodedPending.append(entry)
                continue
            }
            pending[run.id] = run
        }
        if !undecodedPending.isEmpty {
            NSLog("SelfImprovementOrchestrator: preserving %d undecodable pending_actions entrie(s) verbatim through rewrites",
                  undecodedPending.count)
        }
        await expireStalePendingActions()
    }

    /// U5 W-G (2026-06-11): pending_actions.json entries never expired —
    /// non-terminal ("pending"/"staged") AND terminal rows alike sat in the
    /// queue file forever. Sweep anything older than the retention window
    /// out of the queue (runs.json remains the durable history ledger) and
    /// log exactly what was dropped — no silent eviction.
    private static let pendingActionExpirySeconds: TimeInterval = 14 * 86_400

    private func expireStalePendingActions() async {
        let cutoff = Date().addingTimeInterval(-Self.pendingActionExpirySeconds)
        let fmt = ISO8601DateFormatter()
        var expiredIds: [String] = []
        for (id, run) in pending {
            // Entries without a parseable createdAt are kept — we can't
            // date them, and guessing risks dropping live work.
            guard let createdAt = run.createdAt, let created = fmt.date(from: createdAt) else { continue }
            if created < cutoff {
                expiredIds.append("\(id)(\(run.status ?? "unknown"))")
                pending.removeValue(forKey: id)
            }
        }
        guard !expiredIds.isEmpty else { return }
        NSLog("SelfImprovementOrchestrator: expired %d pending_actions entrie(s) past %dd retention: %@",
              expiredIds.count, Int(Self.pendingActionExpirySeconds / 86_400),
              expiredIds.joined(separator: ", "))
        do {
            try await persistPending()
        } catch {
            NSLog("SelfImprovementOrchestrator: failed to persist pending_actions expiry: %@",
                  String(describing: error))
        }
    }

    private func persistPending() async throws {
        let runs = Array(pending.values).sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
        let encoder = JSONEncoder()
        var entries: [JSONValue] = runs.compactMap { run in
            guard let data = try? encoder.encode(run),
                  let jv = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { return nil }
            return jv
        }
        // Corrupt-preserve (U5 fix-round): undecodable raw entries captured at
        // rehydrate ride through every rewrite verbatim — a rewrite (expiry or
        // otherwise) must never destroy rows we couldn't decode.
        entries.append(contentsOf: undecodedPending)
        let snapshot = entries
        // pending_actions.json writes go through the same cross-process flock
        // as runs.json (markLedgerRun*) — promote/revert update this record
        // while sibling processes may be sweeping or rehydrating it.
        let path = pendingPath()
        try await persistence.withFileLock(path) { [persistence] in
            try await persistence.writeJSON(.array(snapshot), to: path)
        }
    }

    private func newRunId() -> String {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let rand = UInt32.random(in: 0..<UInt32.max)
        return "imp_\(ts)_\(String(rand, radix: 16))"
    }

    private struct BuildResult { let ok: Bool; let stderr: String }

    /// U5 fix-round (2026-06-11, gpt-5.5 review): async wrapper — the
    /// blocking build (pipe drains + waitUntilExit, up to the 900s budget)
    /// runs on a GCD global queue; the caller (orchestrator actor or the
    /// GitOps validate closure) awaits a continuation without pinning any
    /// actor or cooperative-pool thread. Timeout semantics identical.
    private nonisolated static func runSwiftBuildGateOffThread(
        repoRoot: URL, packagePath: String?
    ) async -> BuildResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: runSwiftBuildGate(repoRoot: repoRoot, packagePath: packagePath))
            }
        }
    }

    /// U5 W-G (2026-06-11): wall-clock budget for the swift-build compile
    /// gate. Previously the gate had NO timeout — a wedged build pinned the
    /// promote path forever.
    private static let swiftBuildGateTimeoutSeconds: TimeInterval = 900

    /// Tiny lock-guarded flag the timeout work item shares with the gate.
    private final class _TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func set() { lock.lock(); fired = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    }

    private nonisolated static func runSwiftBuildGate(repoRoot: URL, packagePath: String?) -> BuildResult {
        guard let pkg = packagePath else { return BuildResult(ok: true, stderr: "") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["swift", "build", "--package-path", pkg]
        proc.currentDirectoryURL = repoRoot
        let errPipe = Pipe()
        let outPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = outPipe
        do {
            try proc.run()
        } catch {
            return BuildResult(ok: false, stderr: "spawn_failed: \(error)")
        }
        // U5 W-G: timeout (same DispatchWorkItem recipe as runGit).
        let timedOut = _TimeoutFlag()
        let timeoutItem = DispatchWorkItem { [weak proc] in
            if let p = proc, p.isRunning {
                timedOut.set()
                p.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + swiftBuildGateTimeoutSeconds, execute: timeoutItem
        )
        // U5 W-G: drain BOTH pipes before waitUntilExit. The old order
        // (waitUntilExit, then read stderr) deadlocked when a chatty build
        // filled either 64KB pipe buffer — and never read stdout at all.
        let outBox = _DataBox()
        let outDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            outBox.store(outPipe.fileHandleForReading.readDataToEndOfFile())
            outDone.signal()
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        outDone.wait()
        proc.waitUntilExit()
        timeoutItem.cancel()
        if timedOut.value {
            return BuildResult(
                ok: false,
                stderr: "build_timeout: swift build exceeded \(Int(swiftBuildGateTimeoutSeconds))s and was terminated"
            )
        }
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return BuildResult(ok: proc.terminationStatus == 0, stderr: stderr)
    }

    /// Lock-guarded Data cell for the cross-thread stdout drain above.
    private final class _DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func store(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    private struct LedgerRun {
        var run: ImprovementRun
        var object: [String: JSONValue]
    }

    private struct PromotionArtifact {
        var diffText: String
        var source: String
    }

    private func loadLedgerRun(runId: String) async -> LedgerRun? {
        let raw = await persistence.readJSON(runsPath(), defaultValue: .array([]))
        guard case .array(let entries) = raw else { return nil }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for entry in entries {
            guard case .object(let obj) = entry,
                  case .string(let id)? = obj["id"],
                  id == runId,
                  let data = try? encoder.encode(entry),
                  let run = try? decoder.decode(ImprovementRun.self, from: data)
            else { continue }
            return LedgerRun(run: run, object: obj)
        }
        return nil
    }

    private func promotionArtifact(for run: ImprovementRun, rawObject: [String: JSONValue]?) throws -> PromotionArtifact? {
        if let inline = firstString(rawObject, keys: ["patch", "diff", "diffText"]),
           !inline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PromotionArtifact(diffText: inline, source: "inline")
        }

        let pathKeys = ["patchPath", "patch_path", "diffPath", "diff_path"]
        for key in pathKeys {
            guard let path = stringValue(rawObject, key), !path.isEmpty else { continue }
            if let diff = try readDiffFile(path) {
                return PromotionArtifact(diffText: diff, source: key)
            }
        }

        let defaultPatch = dataRoot
            .appendingPathComponent("improvements", isDirectory: true)
            .appendingPathComponent("patches", isDirectory: true)
            .appendingPathComponent("\(run.id).patch")
        if let data = try? Data(contentsOf: defaultPatch),
           let diff = String(data: data, encoding: .utf8),
           !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PromotionArtifact(diffText: diff, source: "patch_file")
        }

        if let worktree = run.worktree, !worktree.isEmpty {
            let diff = try worktreeStagedDiff(URL(fileURLWithPath: worktree))
            if !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return PromotionArtifact(diffText: diff, source: "worktree_cached_diff")
            }
        }

        return nil
    }

    private func readDiffFile(_ path: String) throws -> String? {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dataRoot.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let diff = try String(contentsOf: url, encoding: .utf8)
        return diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : diff
    }

    private func worktreeStagedDiff(_ worktree: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: worktree.path) else { return "" }
        let result = try runProcess(["git", "-C", worktree.path, "diff", "--cached"])
        guard result.exit == 0 else {
            throw SelfImprovementError.underlying("worktree_diff_failed: \(Self.trimForError(result.stderr))")
        }
        return result.stdout
    }

    private func markLedgerRunPromoted(runId: String, commitSha: String, completedAt: String?) async throws {
        let path = runsPath()
        try await persistence.withFileLock(path) { [persistence] in
            let raw = await persistence.readJSON(path, defaultValue: .array([]))
            guard case .array(let entries) = raw else { return }
            var changed = false
            let updated: [JSONValue] = entries.map { entry in
                guard case .object(var obj) = entry,
                      case .string(let id)? = obj["id"],
                      id == runId else { return entry }
                obj["phase"] = .string("promoted")
                obj["status"] = .string("promoted")
                obj["promotedCommitSha"] = .string(commitSha)
                if let completedAt {
                    obj["completedAt"] = .string(completedAt)
                }
                changed = true
                return .object(obj)
            }
            if changed {
                try await persistence.writeJSON(.array(updated), to: path)
            }
        }
    }

    private func markLedgerRunReverted(runId: String, revertCommitSha: String, completedAt: String?) async throws {
        let path = runsPath()
        try await persistence.withFileLock(path) { [persistence] in
            let raw = await persistence.readJSON(path, defaultValue: .array([]))
            guard case .array(let entries) = raw else { return }
            var changed = false
            let updated: [JSONValue] = entries.map { entry in
                guard case .object(var obj) = entry,
                      case .string(let id)? = obj["id"],
                      id == runId else { return entry }
                obj["phase"] = .string("reverted")
                obj["status"] = .string("reverted")
                obj["revertCommitSha"] = .string(revertCommitSha)
                if let completedAt {
                    obj["completedAt"] = .string(completedAt)
                }
                changed = true
                return .object(obj)
            }
            if changed {
                try await persistence.writeJSON(.array(updated), to: path)
            }
        }
    }

    private struct ProcessResult {
        var stdout: String
        var stderr: String
        var exit: Int32
    }

    private nonisolated func runProcess(_ args: [String]) throws -> ProcessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice
        try proc.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return ProcessResult(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exit: proc.terminationStatus
        )
    }

    private nonisolated func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func promotionCommitMessage(runId: String, objective: String?) -> String {
        let trimmed = (objective ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Promote self-improvement \(runId.prefix(8))"
        }
        return "Promote self-improvement \(runId.prefix(8)): \(trimmed.prefix(80))"
    }

    private nonisolated func stringValue(_ obj: [String: JSONValue]?, _ key: String) -> String? {
        guard let obj, case .string(let s)? = obj[key] else { return nil }
        return s
    }

    private nonisolated func firstString(_ obj: [String: JSONValue]?, keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(obj, key) { return value }
        }
        return nil
    }

    private nonisolated static func trimForError(_ text: String, limit: Int = 600) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= limit { return oneLine }
        return String(oneLine.prefix(limit))
    }

    private nonisolated static func gitErrorCode(_ error: SelfImprovementGitError) -> String {
        switch error {
        case .workTreeNotClean(let detail):
            return "work_tree_not_clean: \(trimForError(detail))"
        case .expectedHeadMismatch:
            return "expected_head_mismatch"
        case .applyFailed(let stderr):
            return "apply_failed: \(trimForError(stderr))"
        case .commitFailed(let stderr):
            return "commit_failed: \(trimForError(stderr))"
        case .mergeConflict(let files):
            return "merge_conflict: \(files.joined(separator: ", "))"
        case .gitNotFound:
            return "git_not_found"
        case .underlying(let message):
            return trimForError(message)
        case .expectedCommitShaMismatch, .revertFailed:
            return error.localizedDescription
        }
    }
}
