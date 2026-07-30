import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - U2b wave 1: hermetic candidate builder
//
// Builds an evolution candidate in an isolated git worktree at
// `<dataRoot>/evolution/candidates/<runId>/worktree` (memory-consolidation
// candidates-dir precedent), entirely outside the live checkout:
//
//   git worktree add --detach @ expectedHead
//     → git apply --3way (conflict = typed fail)
//     → FULL root `swift build` (closes the orchestrator's
//       NativeAgentCore-only gap)
//     → filtered `swift test` (suites mapped from the diff's touched
//       modules; full-suite escalation for out-of-module paths)
//
// Child processes run under the daemon-era env-scrub allowlist
// so API keys never reach the sandbox, with a
// per-candidate temp HOME + temp TMPDIR overlaid on top (hermeticEnvironment)
// so build/test children cannot reach the real user profile through
// env-derived paths. Build and test output stream straight to build.log /
// test.log (receipts). The machine-readable verdict is result.json, written
// under flock — wave 2's promote-on-approve requires a green result.json for
// the same diff sha before it will touch the live repo.
//
// THREAT MODEL (wave 1, decided 2026-06-10): the candidate sandbox is a
// MISTAKE-CONTAINMENT boundary, not a malicious-code boundary. Wave-1
// candidates build ONLY diffs that arrive through the approval-gated
// proposal store — every diff has passed the user's tap before it reaches this
// builder, so the adversary here is a *buggy* approved diff (a test that
// writes to $HOME, a build plugin that scribbles over user caches), not a
// hostile one. Containment layers: (1) env scrub — the child env is the
// daemon-era allowlist, so API keys and tokens never reach candidate
// processes; (2) temp HOME + temp TMPDIR — build/test children get a
// per-candidate home/ and tmp/ under the candidate dir, so SwiftPM caches,
// plugin state, and tmp droppings land inside the candidate dir instead of
// the real user profile; (3) detached worktree — source mutations never
// touch the live checkout. NOT provided in wave 1: network isolation and
// OS-enforced file containment — a malicious diff could still exfiltrate or
// write outside the sandbox via absolute paths. Defense against malicious
// diffs is the approval gate upstream, by design. Full OS sandboxing
// (sandbox-exec/Seatbelt profile around build/test children) is the named
// U4 follow-up, user-gated.
//
// NOTHING here executes installs or restarts. Worktree + temp home/tmp are
// removed on completion (terminal status); result.json + claim.json + logs
// are kept and reaped by `sweepCandidates`.

// MARK: - Config

public struct EvolutionBuildConfig: Sendable {
    /// Wall-clock budget for the full root `swift build`. Cold worktree
    /// builds use a fresh `.build` — budget generously (plan A3: the
    /// daemon-era 180s cap is known-insufficient for a full cold root build).
    public var buildTimeout: TimeInterval
    public var testTimeout: TimeInterval
    public var gitTimeout: TimeInterval
    /// Subpath of the package whose tests run (nil → test the worktree root
    /// package; used by fixture repos in tests).
    public var testPackageSubpath: String?
    public var moduleSourcePrefix: String
    public var moduleTestPrefix: String
    /// Keep the worktree on failure for post-mortem (default false: cleanup
    /// on every terminal status, logs + result.json carry the evidence).
    public var keepWorktreeOnFailure: Bool
    /// Test seam: nil → scrubbed live env (EvolutionSupport.scrubbedEnvironment).
    public var environmentOverride: [String: String]?

    public init(
        buildTimeout: TimeInterval = 1800,
        testTimeout: TimeInterval = 1800,
        gitTimeout: TimeInterval = 120,
        testPackageSubpath: String? = "Modules/NativeAgentCore",
        moduleSourcePrefix: String = "Modules/NativeAgentCore/Sources/",
        moduleTestPrefix: String = "Modules/NativeAgentCore/Tests/",
        keepWorktreeOnFailure: Bool = false,
        environmentOverride: [String: String]? = nil
    ) {
        self.buildTimeout = buildTimeout
        self.testTimeout = testTimeout
        self.gitTimeout = gitTimeout
        self.testPackageSubpath = testPackageSubpath
        self.moduleSourcePrefix = moduleSourcePrefix
        self.moduleTestPrefix = moduleTestPrefix
        self.keepWorktreeOnFailure = keepWorktreeOnFailure
        self.environmentOverride = environmentOverride
    }
}

// MARK: - Request / result

public struct EvolutionCandidateRequest: Sendable {
    public var runId: String
    public var proposalId: String
    public var diffText: String
    public var expectedHead: String
    /// Caller's CAS on the diff content (store's diffSHA256). Mismatch with
    /// the actual diff text → refuse before any git operation.
    public var expectedDiffSHA256: String?

    public init(
        runId: String,
        proposalId: String,
        diffText: String,
        expectedHead: String,
        expectedDiffSHA256: String? = nil
    ) {
        self.runId = runId
        self.proposalId = proposalId
        self.diffText = diffText
        self.expectedHead = expectedHead
        self.expectedDiffSHA256 = expectedDiffSHA256
    }
}

public enum EvolutionCandidatePhase: String, Sendable, Codable {
    case validate
    case worktreeAdd = "worktree_add"
    case headVerify = "head_verify"
    case apply
    case build
    case test
    case complete
}

public struct EvolutionCandidateResult: Sendable, Codable, Equatable {
    public var runId: String
    public var proposalId: String
    public var ok: Bool
    /// Furthest phase reached (== .complete on success).
    public var phase: EvolutionCandidatePhase
    public var expectedHead: String
    public var diffSHA256: String
    public var touchedPaths: [String]
    public var testFilters: [String]
    public var escalatedFullSuite: Bool
    public var testsSkippedReason: String?
    public var buildExit: Int32?
    public var testExit: Int32?
    public var timedOutPhase: String?
    public var error: String?
    public var startedAt: String
    public var finishedAt: String
    public var worktreeCleaned: Bool
}

// MARK: - Builder

public actor EvolutionCandidateBuilder {
    private let repoRoot: URL
    private let dataRoot: URL
    private let persistence: any PersistenceCoreProtocol
    private let config: EvolutionBuildConfig
    private let now: @Sendable () -> Date

    /// Add-path/remove-path pair: inserted at build() entry, removed in defer.
    /// Guards duplicate-runId re-entry across actor suspension points.
    private var inFlight: Set<String> = []

    public init(
        repoRoot: URL,
        dataRoot: URL = defaultDataRoot(),
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        config: EvolutionBuildConfig = EvolutionBuildConfig(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repoRoot = repoRoot
        self.dataRoot = dataRoot
        self.persistence = persistence
        self.config = config
        self.now = now
    }

    // MARK: - Paths

    public nonisolated func candidatesDir() -> URL {
        dataRoot
            .appendingPathComponent("evolution", isDirectory: true)
            .appendingPathComponent("candidates", isDirectory: true)
    }

    public nonisolated func candidateDir(runId: String) -> URL {
        candidatesDir().appendingPathComponent(runId, isDirectory: true)
    }

    public nonisolated func worktreeDir(runId: String) -> URL {
        candidateDir(runId: runId).appendingPathComponent("worktree", isDirectory: true)
    }

    public nonisolated func resultPath(runId: String) -> URL {
        candidateDir(runId: runId).appendingPathComponent("result.json")
    }

    /// Cross-process run claim (flocked CAS). Written exactly once by the
    /// claim winner BEFORE any candidate filesystem effect; never released —
    /// a runId is single-use evidence, crash included (fail-closed: a
    /// crashed claim poisons its runId and the caller picks a fresh one).
    public nonisolated func claimPath(runId: String) -> URL {
        candidateDir(runId: runId).appendingPathComponent("claim.json")
    }

    /// Per-candidate temp HOME for build/test children (hermeticity).
    public nonisolated func homeDir(runId: String) -> URL {
        candidateDir(runId: runId).appendingPathComponent("home", isDirectory: true)
    }

    /// Per-candidate temp TMPDIR for build/test children (hermeticity).
    public nonisolated func tmpDir(runId: String) -> URL {
        candidateDir(runId: runId).appendingPathComponent("tmp", isDirectory: true)
    }

    // MARK: - Build

    /// Run the full candidate pipeline. Never throws for pipeline failures —
    /// every outcome (including refusals) is encoded in the returned result
    /// AND persisted to result.json so the verdict survives the process.
    public func build(_ request: EvolutionCandidateRequest) async -> EvolutionCandidateResult {
        let startedAt = EvolutionSupport.isoTimestamp(now())

        // Fail-closed validations before any filesystem effect.
        guard EvolutionSupport.isSafePathComponent(request.runId) else {
            return await finishWithoutWorktree(
                request, startedAt: startedAt, phase: .validate,
                error: "invalid_run_id: \(request.runId)", persistResult: false)
        }
        guard !inFlight.contains(request.runId) else {
            // Do NOT write result.json for a duplicate — the in-flight run
            // owns that file.
            return EvolutionCandidateResult(
                runId: request.runId, proposalId: request.proposalId, ok: false,
                phase: .validate, expectedHead: request.expectedHead,
                diffSHA256: EvolutionSupport.sha256Hex(request.diffText),
                touchedPaths: [], testFilters: [], escalatedFullSuite: false,
                testsSkippedReason: nil, buildExit: nil, testExit: nil,
                timedOutPhase: nil, error: "duplicate_run_in_flight",
                startedAt: startedAt, finishedAt: EvolutionSupport.isoTimestamp(now()),
                worktreeCleaned: false)
        }
        inFlight.insert(request.runId)
        defer { inFlight.remove(request.runId) }

        // Cross-process claim CAS. `inFlight` only protects THIS process;
        // two processes sharing a runId could otherwise share the candidate
        // dir/worktree and the loser could overwrite the winner's green
        // result.json (persistResult rewrites unconditionally). The claim is
        // a flocked test-and-set on claim.json taken BEFORE any candidate
        // dir/worktree/log creation; losers refuse without persisting (the
        // claim owner owns every write under this runId).
        switch await claimRun(request.runId, startedAt: startedAt) {
        case .claimed:
            break
        case .resultExists:
            // A prior run already wrote a verdict under this id. Refuse to
            // overwrite evidence (fail-closed; caller picks a fresh runId).
            return await finishWithoutWorktree(
                request, startedAt: startedAt, phase: .validate,
                error: "result_exists_for_run_id", persistResult: false)
        case .alreadyClaimed:
            return await finishWithoutWorktree(
                request, startedAt: startedAt, phase: .validate,
                error: "run_claimed_by_another_process", persistResult: false)
        case .claimFailed(let detail):
            return await finishWithoutWorktree(
                request, startedAt: startedAt, phase: .validate,
                error: "claim_failed: \(detail)", persistResult: false)
        }

        let actualSha = EvolutionSupport.sha256Hex(request.diffText)
        if let expected = request.expectedDiffSHA256?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expected.isEmpty, expected.lowercased() != actualSha.lowercased() {
            return await finishWithoutWorktree(
                request, startedAt: startedAt, phase: .validate,
                error: "diff_sha_mismatch: expected \(expected), actual \(actualSha)")
        }
        if request.diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return await finishWithoutWorktree(
                request, startedAt: startedAt, phase: .validate, error: "empty_diff_refused")
        }

        let worktree = worktreeDir(runId: request.runId)
        let candidateRoot = candidateDir(runId: request.runId)
        let mapping = Self.mapTouchedPathsToTests(
            diffText: request.diffText,
            sourcePrefix: config.moduleSourcePrefix,
            testPrefix: config.moduleTestPrefix)

        var result = EvolutionCandidateResult(
            runId: request.runId, proposalId: request.proposalId, ok: false,
            phase: .validate, expectedHead: request.expectedHead, diffSHA256: actualSha,
            touchedPaths: mapping.touchedPaths, testFilters: mapping.filters,
            escalatedFullSuite: mapping.escalate, testsSkippedReason: nil,
            buildExit: nil, testExit: nil, timedOutPhase: nil, error: nil,
            startedAt: startedAt, finishedAt: startedAt, worktreeCleaned: false)

        do {
            try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true)
            // Hermeticity: per-candidate HOME/TMPDIR so child processes
            // (SwiftPM, plugins, tests) write inside the candidate dir, not
            // the real user profile. See the file-header threat model.
            let home = homeDir(runId: request.runId)
            let tmp = tmpDir(runId: request.runId)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let env = EvolutionSupport.hermeticEnvironment(
                base: config.environmentOverride ?? EvolutionSupport.scrubbedEnvironment(),
                homeDir: home, tmpDir: tmp)

            // 1. Resolve + verify expectedHead exists as a commit.
            result.phase = .worktreeAdd
            let verify = try await git(
                ["rev-parse", "--verify", "--quiet", "\(request.expectedHead)^{commit}"],
                cwd: repoRoot, env: env)
            guard verify.exit == 0 else {
                throw EvolutionEngineError.commitNotFound(request.expectedHead)
            }

            // 2. Detached worktree at expectedHead (no branch → no branch cleanup).
            let add = try await git(
                ["worktree", "add", "--detach", worktree.path, request.expectedHead],
                cwd: repoRoot, env: env)
            guard add.exit == 0 else {
                throw EvolutionEngineError.worktreeFailed(detail: trimOutput(add.stderr))
            }

            // 3. Verify worktree HEAD == expectedHead. expectedHead may be a
            // ref name (tag/branch), so compare against its resolved sha.
            result.phase = .headVerify
            let head = try await git(["rev-parse", "HEAD"], cwd: worktree, env: env)
            let actualHead = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = try await git(
                ["rev-parse", "\(request.expectedHead)^{commit}"], cwd: repoRoot, env: env)
            let expectedSha = resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.exit == 0, resolved.exit == 0,
                  EvolutionSupport.shaMatches(actualHead, expectedSha) else {
                throw EvolutionEngineError.worktreeFailed(
                    detail: "worktree HEAD \(actualHead) != expected \(request.expectedHead) (\(expectedSha))")
            }

            // 4. Apply the diff (3-way; conflict → typed fail).
            result.phase = .apply
            let patchPath = candidateRoot.appendingPathComponent("candidate.patch")
            try request.diffText.write(to: patchPath, atomically: true, encoding: .utf8)
            let apply = try await git(["apply", "--3way", patchPath.path], cwd: worktree, env: env)
            guard apply.exit == 0 else {
                throw EvolutionEngineError.applyConflict(
                    detail: trimOutput(apply.stderr + "\n" + apply.stdout))
            }

            // 5. FULL root build, worktree-local .build, log streamed to file.
            result.phase = .build
            let buildLog = candidateRoot.appendingPathComponent("build.log")
            let build = try await EvolutionSupport.run(
                ["swift", "build", "--package-path", worktree.path],
                cwd: worktree, environment: env,
                timeout: config.buildTimeout, logURL: buildLog)
            result.buildExit = build.exit
            if build.timedOut { result.timedOutPhase = "build" }
            guard build.exit == 0, !build.timedOut else {
                throw EvolutionEngineError.underlying(
                    build.timedOut ? "build_timeout" : "build_failed (exit \(build.exit), see build.log)")
            }

            // 6. Filtered tests (skip only when the diff touches no code).
            result.phase = .test
            if mapping.filters.isEmpty && !mapping.escalate {
                result.testsSkippedReason = "no_code_paths_touched"
            } else {
                let testPackage = config.testPackageSubpath
                    .map { worktree.appendingPathComponent($0, isDirectory: true) } ?? worktree
                var args = ["swift", "test", "--package-path", testPackage.path]
                if !mapping.escalate {
                    for f in mapping.filters { args += ["--filter", f] }
                }
                let testLog = candidateRoot.appendingPathComponent("test.log")
                let test = try await EvolutionSupport.run(
                    args, cwd: worktree, environment: env,
                    timeout: config.testTimeout, logURL: testLog)
                result.testExit = test.exit
                if test.timedOut { result.timedOutPhase = "test" }
                guard test.exit == 0, !test.timedOut else {
                    throw EvolutionEngineError.underlying(
                        test.timedOut ? "test_timeout" : "tests_failed (exit \(test.exit), see test.log)")
                }
            }

            result.phase = .complete
            return await finish(&result, ok: true, error: nil, worktree: worktree, candidateRoot: candidateRoot)
        } catch {
            let message = (error as? EvolutionEngineError)?.errorDescription ?? "\(error)"
            return await finish(&result, ok: false, error: message, worktree: worktree, candidateRoot: candidateRoot)
        }
    }

    /// Fail-closed read of a persisted verdict. Missing → nil; corrupt →
    /// typed throw (never a default).
    public func loadResult(runId: String) async throws -> EvolutionCandidateResult? {
        guard EvolutionSupport.isSafePathComponent(runId) else {
            throw EvolutionEngineError.invalidRunId(runId)
        }
        let path = resultPath(runId: runId)
        return try await persistence.withFileLock(path) {
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            do {
                let data = try Data(contentsOf: path)
                return try JSONDecoder().decode(EvolutionCandidateResult.self, from: data)
            } catch {
                throw EvolutionEngineError.storeCorrupt(path: path.path, detail: "\(error)")
            }
        }
    }

    /// Remove path for the worktree (idempotent; also unregisters from git).
    public func cleanupWorktree(runId: String) async {
        guard EvolutionSupport.isSafePathComponent(runId) else { return }
        let worktree = worktreeDir(runId: runId)
        let env = config.environmentOverride ?? EvolutionSupport.scrubbedEnvironment()
        if FileManager.default.fileExists(atPath: worktree.path) {
            _ = try? await git(["worktree", "remove", "--force", worktree.path], cwd: repoRoot, env: env)
            // Belt and braces if git refused (e.g. repo gone).
            try? FileManager.default.removeItem(at: worktree)
        }
        _ = try? await git(["worktree", "prune"], cwd: repoRoot, env: env)
    }

    /// Remove path for whole candidate dirs (result.json + logs) once they
    /// age out. In-flight runs are never swept. Returns run ids removed.
    @discardableResult
    public func sweepCandidates(olderThanDays days: Int = 14) async -> [String] {
        let cutoff = now().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: candidatesDir(), includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        var removed: [String] = []
        for entry in entries {
            let runId = entry.lastPathComponent
            guard !inFlight.contains(runId) else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantFuture
            guard modified < cutoff else { continue }
            await cleanupWorktree(runId: runId)
            try? fm.removeItem(at: entry)
            removed.append(runId)
        }
        return removed
    }

    // MARK: - Test mapping

    struct TestMapping: Sendable {
        var touchedPaths: [String]
        var filters: [String]
        var escalate: Bool
    }

    /// diff path → test-suite mapping (plan open question #1 — proposed table):
    ///   Modules/NativeAgentCore/Sources/<M>/…  → filter "<M>Tests"
    ///   Modules/NativeAgentCore/Tests/<X>Tests/… → filter "<X>Tests"
    ///   docs/ *.md (docs-only diff)             → no tests
    ///   anything else (app target, Package.swift, script/) → ESCALATE to the
    ///   full core-package suite (change-class escalation per plan A3).
    static func mapTouchedPathsToTests(
        diffText: String,
        sourcePrefix: String,
        testPrefix: String
    ) -> TestMapping {
        var touched: [String] = []
        var seen = Set<String>()
        for line in diffText.split(separator: "\n", omittingEmptySubsequences: false) {
            let path: String?
            if line.hasPrefix("+++ b/") {
                path = String(line.dropFirst(6))
            } else if line.hasPrefix("--- a/") {
                path = String(line.dropFirst(6))
            } else {
                path = nil
            }
            guard let p = path, p != "/dev/null", !p.isEmpty, !seen.contains(p) else { continue }
            seen.insert(p)
            touched.append(p)
        }

        var filters = Set<String>()
        var escalate = false
        for p in touched {
            if p.hasPrefix(sourcePrefix) {
                let rest = p.dropFirst(sourcePrefix.count)
                if let module = rest.split(separator: "/").first, !module.isEmpty {
                    filters.insert("\(module)Tests")
                    continue
                }
                escalate = true
            } else if p.hasPrefix(testPrefix) {
                let rest = p.dropFirst(testPrefix.count)
                if let target = rest.split(separator: "/").first, target.hasSuffix("Tests") {
                    filters.insert(String(target))
                    continue
                }
                escalate = true
            } else if p.hasPrefix("docs/") || p.lowercased().hasSuffix(".md") {
                continue // docs-only paths carry no test obligation
            } else {
                escalate = true
            }
        }
        return TestMapping(
            touchedPaths: touched,
            filters: escalate ? [] : filters.sorted(),
            escalate: escalate)
    }

    // MARK: - Internals

    private enum ClaimOutcome: Sendable {
        case claimed
        case resultExists
        case alreadyClaimed
        case claimFailed(String)
    }

    /// Run-level flocked claim/CAS (cross-process). Under the flock:
    /// existing result.json OR existing claim.json → refuse; otherwise write
    /// claim.json and win. flock(2) is cross-process, so two daemons (or a
    /// daemon + a CLI) racing the same runId resolve to exactly one winner.
    private func claimRun(_ runId: String, startedAt: String) async -> ClaimOutcome {
        let claim = claimPath(runId: runId)
        let resultFile = resultPath(runId: runId)
        do {
            return try await persistence.withFileLock(claim) {
                if FileManager.default.fileExists(atPath: resultFile.path) {
                    return ClaimOutcome.resultExists
                }
                if FileManager.default.fileExists(atPath: claim.path) {
                    return ClaimOutcome.alreadyClaimed
                }
                let payload: [String: String] = [
                    "runId": runId,
                    "pid": String(ProcessInfo.processInfo.processIdentifier),
                    "claimedAt": startedAt,
                ]
                let data = try JSONEncoder().encode(payload)
                try data.write(to: claim, options: [.atomic])
                return ClaimOutcome.claimed
            }
        } catch {
            return .claimFailed("\(error)")
        }
    }

    private func finish(
        _ result: inout EvolutionCandidateResult,
        ok: Bool,
        error: String?,
        worktree: URL,
        candidateRoot: URL
    ) async -> EvolutionCandidateResult {
        result.ok = ok
        result.error = error
        result.finishedAt = EvolutionSupport.isoTimestamp(now())
        // Terminal-status cleanup: worktree + temp home/tmp go (build caches
        // are dead weight); result.json + claim.json + logs are kept.
        let keep = !ok && config.keepWorktreeOnFailure
        if !keep {
            await cleanupWorktree(runId: result.runId)
            try? FileManager.default.removeItem(at: homeDir(runId: result.runId))
            try? FileManager.default.removeItem(at: tmpDir(runId: result.runId))
            result.worktreeCleaned = true
        }
        await persistResult(result)
        return result
    }

    private func finishWithoutWorktree(
        _ request: EvolutionCandidateRequest,
        startedAt: String,
        phase: EvolutionCandidatePhase,
        error: String,
        persistResult shouldPersist: Bool = true
    ) async -> EvolutionCandidateResult {
        let result = EvolutionCandidateResult(
            runId: request.runId, proposalId: request.proposalId, ok: false,
            phase: phase, expectedHead: request.expectedHead,
            diffSHA256: EvolutionSupport.sha256Hex(request.diffText),
            touchedPaths: [], testFilters: [], escalatedFullSuite: false,
            testsSkippedReason: nil, buildExit: nil, testExit: nil,
            timedOutPhase: nil, error: error,
            startedAt: startedAt, finishedAt: EvolutionSupport.isoTimestamp(now()),
            worktreeCleaned: false)
        if shouldPersist, EvolutionSupport.isSafePathComponent(request.runId) {
            await persistResult(result)
        }
        return result
    }

    /// result.json write under the repo's flock convention.
    private func persistResult(_ result: EvolutionCandidateResult) async {
        let path = resultPath(runId: result.runId)
        do {
            try await persistence.withFileLock(path) { [persistence] in
                let data = try JSONEncoder().encode(result)
                let jv = try JSONDecoder().decode(JSONValue.self, from: data)
                try await persistence.writeJSON(jv, to: path)
            }
        } catch {
            FileHandle.standardError.write(
                Data("evolution candidate result write failed (\(result.runId)): \(error)\n".utf8))
        }
    }

    private func git(_ args: [String], cwd: URL, env: [String: String]) async throws -> EvolutionProcessResult {
        try await EvolutionSupport.run(["git"] + args, cwd: cwd, environment: env, timeout: config.gitTimeout)
    }

    private nonisolated func trimOutput(_ s: String, limit: Int = 600) -> String {
        let oneLine = s.split(separator: "\n").joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count <= limit ? oneLine : String(oneLine.prefix(limit))
    }
}
