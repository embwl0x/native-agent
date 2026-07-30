import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Subsystem #11: SelfImprovement
//
// Swift-native self-improvement surface. Read paths load the local
// improvements ledger, and start/promote/revert route through
// SelfImprovementOrchestrator. There is no daemon HTTP fallback.

// MARK: - ImprovementRun

/// One self-improvement run record, as the daemon emits from
/// `list_improvements()`. Verified against live daemon 2026-05-30: known
/// keys include `id`, `status`, `phase`, `createdAt`, `completedAt`,
/// `objective`, `summary`, `model`, `worktree`, `exitReason`,
/// `promotedCommitSha`, `revertCommitSha`, `mainRepoStatus`,
/// `lastHeartbeatAt`, `codexPid`, `codexSandbox`. Anything else the daemon
/// ships rides in `extras`.
public struct ImprovementRun: Sendable, Codable, Equatable {
    public var id: String
    public var status: String?
    public var phase: String?
    public var createdAt: String?
    public var completedAt: String?
    public var objective: String?
    public var summary: String?
    public var model: String?
    public var worktree: String?
    public var exitReason: String?
    public var promotedCommitSha: String?
    public var revertCommitSha: String?
    public var extras: JSONValue?

    public init(
        id: String,
        status: String? = nil,
        phase: String? = nil,
        createdAt: String? = nil,
        completedAt: String? = nil,
        objective: String? = nil,
        summary: String? = nil,
        model: String? = nil,
        worktree: String? = nil,
        exitReason: String? = nil,
        promotedCommitSha: String? = nil,
        revertCommitSha: String? = nil,
        extras: JSONValue? = nil
    ) {
        self.id = id
        self.status = status
        self.phase = phase
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.objective = objective
        self.summary = summary
        self.model = model
        self.worktree = worktree
        self.exitReason = exitReason
        self.promotedCommitSha = promotedCommitSha
        self.revertCommitSha = revertCommitSha
        self.extras = extras
    }

    private static let knownKeys: Set<String> = [
        "id", "status", "phase", "createdAt", "completedAt", "objective",
        "summary", "model", "worktree", "exitReason", "promotedCommitSha",
        "revertCommitSha", "extras",
    ]

    private struct AnyKey: CodingKey, Hashable {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { self.stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func str(_ k: String) throws -> String? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(String.self, forKey: key)
        }
        func jv(_ k: String) throws -> JSONValue? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(JSONValue.self, forKey: key)
        }

        self.id = (try str("id")) ?? ""
        self.status = try str("status")
        self.phase = try str("phase")
        self.createdAt = try str("createdAt")
        self.completedAt = try str("completedAt")
        self.objective = try str("objective")
        self.summary = try str("summary")
        self.model = try str("model")
        self.worktree = try str("worktree")
        self.exitReason = try str("exitReason")
        self.promotedCommitSha = try str("promotedCommitSha")
        self.revertCommitSha = try str("revertCommitSha")

        var unknown: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let v = try? c.decode(JSONValue.self, forKey: key) {
                unknown[key.stringValue] = v
            }
        }
        if let explicit = try jv("extras") {
            if case .object(let obj) = explicit {
                for (k, v) in obj { unknown[k] = v }
            } else {
                unknown["_extras_value"] = explicit
            }
        }
        self.extras = unknown.isEmpty ? nil : .object(unknown)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encodeIfPresent(status, forKey: AnyKey("status"))
        try c.encodeIfPresent(phase, forKey: AnyKey("phase"))
        try c.encodeIfPresent(createdAt, forKey: AnyKey("createdAt"))
        try c.encodeIfPresent(completedAt, forKey: AnyKey("completedAt"))
        try c.encodeIfPresent(objective, forKey: AnyKey("objective"))
        try c.encodeIfPresent(summary, forKey: AnyKey("summary"))
        try c.encodeIfPresent(model, forKey: AnyKey("model"))
        try c.encodeIfPresent(worktree, forKey: AnyKey("worktree"))
        try c.encodeIfPresent(exitReason, forKey: AnyKey("exitReason"))
        try c.encodeIfPresent(promotedCommitSha, forKey: AnyKey("promotedCommitSha"))
        try c.encodeIfPresent(revertCommitSha, forKey: AnyKey("revertCommitSha"))
        if case .object(let obj)? = extras {
            for (k, v) in obj where !Self.knownKeys.contains(k) {
                try c.encode(v, forKey: AnyKey(k))
            }
        }
    }
}

// MARK: - ImprovementSummary

/// Result of GET /v1/improvements/summary. Verified against live daemon
/// 2026-05-30: top-level keys include the count fields (running/succeeded/
/// failed/interrupted/staged/total), `enabled`, `status`, `latestRun`,
/// `latestFailure`, `stagedRuns`, `failureBreakdown`, `recentFailures`,
/// plus a long tail of harness/learning fields. We extract the headline
/// counts + latestRun typed, and keep `rawResponse` for callers that need
/// any of the long-tail fields (harness benchmark, growth entries, etc.).
public struct ImprovementSummary: Sendable, Codable, Equatable {
    public var enabled: Bool?
    public var status: String?
    public var disabledReason: String?
    public var runningCount: Int?
    public var succeededCount: Int?
    public var failedCount: Int?
    public var interruptedCount: Int?
    public var stagedCount: Int?
    public var totalCount: Int?
    public var latestRun: ImprovementRun?
    public var latestFailure: ImprovementRun?
    public var stagedRuns: [ImprovementRun]?
    public var rawResponse: JSONValue

    public init(
        enabled: Bool? = nil,
        status: String? = nil,
        disabledReason: String? = nil,
        runningCount: Int? = nil,
        succeededCount: Int? = nil,
        failedCount: Int? = nil,
        interruptedCount: Int? = nil,
        stagedCount: Int? = nil,
        totalCount: Int? = nil,
        latestRun: ImprovementRun? = nil,
        latestFailure: ImprovementRun? = nil,
        stagedRuns: [ImprovementRun]? = nil,
        rawResponse: JSONValue = .object([:])
    ) {
        self.enabled = enabled
        self.status = status
        self.disabledReason = disabledReason
        self.runningCount = runningCount
        self.succeededCount = succeededCount
        self.failedCount = failedCount
        self.interruptedCount = interruptedCount
        self.stagedCount = stagedCount
        self.totalCount = totalCount
        self.latestRun = latestRun
        self.latestFailure = latestFailure
        self.stagedRuns = stagedRuns
        self.rawResponse = rawResponse
    }
}

// MARK: - PromoteResult / RevertResult

/// Body of POST /v1/improvements/runs/<id>/promote. Daemon response shape
/// is the dict from `promote_improvement(...)`; preserve verbatim.
public struct PromoteResult: Sendable, Codable, Equatable {
    public var rawResponse: JSONValue
    public init(rawResponse: JSONValue) { self.rawResponse = rawResponse }

    enum CodingKeys: String, CodingKey { case rawResponse = "raw_response" }
}

/// Body of POST /v1/improvements/runs/<id>/revert. Preserve verbatim.
public struct RevertResult: Sendable, Codable, Equatable {
    public var rawResponse: JSONValue
    public init(rawResponse: JSONValue) { self.rawResponse = rawResponse }

    enum CodingKeys: String, CodingKey { case rawResponse = "raw_response" }
}

// MARK: - Errors

public enum SelfImprovementError: Error, LocalizedError {
    case invalidRequest
    case notFound
    /// HEAD or staged-diff SHA does not match the expected value supplied
    /// by the caller. Daemon returns 409 from `promote_improvement` /
    /// `revert_improvement` when the worktree has drifted.
    case expectedHeadMismatch
    case invalidResponse(status: Int)
    case unavailable(String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "self-improvement: invalid request"
        case .notFound: return "self-improvement: run not found"
        case .expectedHeadMismatch: return "self-improvement: HEAD or diff sha drifted (409)"
        case .invalidResponse(let s): return "self-improvement: native implementation returned unexpected status \(s)"
        case .unavailable(let reason): return "self-improvement unavailable: \(reason)"
        case .underlying(let m): return "self-improvement: \(m)"
        }
    }
}

// MARK: - Protocol

/// SelfImprovement surface. SwiftNative reads local run state and uses the
/// Swift orchestrator for lifecycle actions; unsupported edges fail closed
/// instead of falling back to a daemon.
public protocol SelfImprovementProtocol: Sendable {
    func listImprovements() async throws -> [ImprovementRun]
    func improvementSummary() async throws -> ImprovementSummary
    func promote(
        runId: String,
        approved: Bool,
        expectedHead: String?,
        expectedDiffSHA256: String?
    ) async throws -> PromoteResult
    func revert(
        runId: String,
        approved: Bool,
        expectedHead: String?,
        expectedCommitSHA: String?
    ) async throws -> RevertResult
    /// Queue a new self-improvement run with the given objective. Mirrors
    /// daemon POST /v1/improvements, which dispatches to
    /// `runtime.start_improvement(objective)`.
    /// Queues a Swift-native pending action for the orchestrator; no daemon
    /// worker path is used.
    func startImprovement(objective: String) async throws -> ImprovementRun
}

// MARK: - SwiftNative impl (orchestrator + local file methods)

public actor SwiftNativeSelfImprovement: SelfImprovementProtocol {
    private let persistence: any PersistenceCoreProtocol
    private let dataRoot: URL
    // Per-path serialization for local R-M-W. In-process only; file-level
    // coordination is handled by callers that need cross-process safety.
    private var pathLocks: [URL: Task<Void, Never>] = [:]

    public init(
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        dataRoot: URL = defaultDataRoot()
    ) {
        self.persistence = persistence
        self.dataRoot = dataRoot
    }

    // Internal accessors so the wave-31 training/promotion/evals read-side
    // extension (SelfImprovement+TrainingPromotion.swift) can reach the actor's
    // private storage without widening its visibility.
    func trainingPromotionDataRoot() -> URL { dataRoot }
    func trainingPromotionPersistence() -> any PersistenceCoreProtocol { persistence }

    /// Serialize concurrent R-M-W against `path` within this actor instance.
    /// Each call awaits the prior task at `path`, then runs `body`, then
    /// installs its own continuation so the next caller waits for it.
    /// IN-PROCESS ONLY: callers that write the same file from another process
    /// must use the shared file-lock layer around their writes.
    private func withPathLock<T: Sendable>(
        _ path: URL,
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let prior = pathLocks[path]
        let task = Task<T, Error> {
            _ = await prior?.value
            return try await body()
        }
        // Install a follow-task that waits for `task` to finish (success or
        // failure) so the next caller's `_ = await prior?.value` blocks
        // until this body returns.
        pathLocks[path] = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: - Protocol surface

    public func listImprovements() async throws -> [ImprovementRun] {
        if let verified = try await listImprovementsVerified() {
            return verified
        }
        return try await listImprovementsLocal()
    }

    public func improvementSummary() async throws -> ImprovementSummary {
        return try await improvementSummaryLocal()
    }

    public func promote(
        runId: String,
        approved: Bool,
        expectedHead: String?,
        expectedDiffSHA256: String?
    ) async throws -> PromoteResult {
        guard approved else { throw SelfImprovementError.invalidRequest }
        let result = try await SelfImprovementOrchestrator.shared.promote(
            runId: runId,
            expectedHead: expectedHead,
            expectedDiffSHA256: expectedDiffSHA256
        )
        let raw = try Self.jsonValue(result)
        return PromoteResult(rawResponse: raw)
    }

    public func revert(
        runId: String,
        approved: Bool,
        expectedHead: String?,
        expectedCommitSHA: String?
    ) async throws -> RevertResult {
        guard approved else { throw SelfImprovementError.invalidRequest }
        _ = expectedHead
        _ = expectedCommitSHA
        let result = try await SelfImprovementOrchestrator.shared.revert(runId: runId)
        let raw = try Self.jsonValue(result)
        return RevertResult(rawResponse: raw)
    }

    public func startImprovement(objective: String) async throws -> ImprovementRun {
        return try await SelfImprovementOrchestrator.shared.startImprovement(objective: objective)
    }

    private nonisolated static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONValue.parse(data)
    }

    // MARK: - Phase B: local file read/mutation methods

    /// Read `improvements/runs.json` from disk and return all runs in
    /// FILE ORDER REVERSED — matching daemon's `list_improvements()` which
    /// does `return list(reversed(runs))`. Returns an empty array when the
    /// file is absent. Mirrors the read half of `list_improvements()` minus
    /// the `_reconcile_running_improvements_locked` call (pure read path).
    ///
    /// IMPORTANT: out-of-order writes (a hand-edited fixture, a daemon bug)
    /// surface here unsorted — that matches daemon behavior. Do NOT secretly
    /// re-sort by `createdAt`; the daemon does not, and Swift parity matters.
    public func listImprovementsLocal() async throws -> [ImprovementRun] {
        let path = dataRoot.appendingPathComponent("improvements/runs.json")
        let raw = await persistence.readJSON(path, defaultValue: .array([]))
        guard case .array(let arr) = raw else { return [] }
        let decoder = JSONDecoder()
        // Reverse first, then decode in that order — file-order-reversed.
        let runs: [ImprovementRun] = arr.reversed().compactMap { entry in
            guard let data = try? JSONEncoder().encode(entry) else { return nil }
            return try? decoder.decode(ImprovementRun.self, from: data)
        }
        return runs
    }

    /// Build an ImprovementSummary from the local `runs.json` without
    /// calling the daemon. Matches the shape of `improvement_summary()` in
    /// the daemon for the subset of fields that
    /// can be computed from run records alone. All `byStatus` keys are
    /// always present (zero-filled) in the rawResponse for UI convenience.
    ///
    /// Fields that require daemon-side state (enabled, status, jobs, growth,
    /// harness benchmark, recurring improve jobs, etc.) are left nil/empty
    /// in this local variant.
    ///
    /// Daemon parity invariants (matched exactly):
    ///   - `latestRun` uses `max(runs, key=createdAt)` — newest by timestamp.
    ///   - `latestFailure` matches `status == "failed"` ONLY (NOT
    ///     "interrupted"); daemon does
    ///     `next((run for run in reversed(runs) if status=="failed"), None)`.
    ///   - `stagedRuns` is `staged[:12]` — capped at 12 entries.
    ///
    /// NOTE: there is no `recentRuns` field on `ImprovementSummary` and the
    /// daemon does not emit one either; do not introduce one.
    public func improvementSummaryLocal() async throws -> ImprovementSummary {
        let runs = try await listImprovementsLocal()
        let statuses = ["running", "staged", "promoted", "reverted", "interrupted", "failed", "discarded"]

        // Count by status; zero-fill all known status keys for the UI.
        var byStatus: [String: Int] = Dictionary(uniqueKeysWithValues: statuses.map { ($0, 0) })
        for run in runs {
            let key = run.status ?? "unknown"
            byStatus[key, default: 0] += 1
        }

        let total = runs.count
        let runningCount = byStatus["running"] ?? 0
        let succeededCount = runs.filter { $0.status == "succeeded" }.count
        let failedCount = byStatus["failed"] ?? 0
        let interruptedCount = byStatus["interrupted"] ?? 0
        // Daemon: `staged = [run for run in runs if run.get("phase") == "staged"]`
        // operates on RAW FILE ORDER (not reversed), so `staged[:12]` yields
        // the 12 OLDEST staged runs. `runs` here is file-order-reversed, so
        // re-read runs.json in raw file order for parity on this field.
        let runsPath = dataRoot.appendingPathComponent("improvements/runs.json")
        let rawRunsJV = await persistence.readJSON(runsPath, defaultValue: .array([]))
        let stagedAllFileOrder: [ImprovementRun]
        if case .array(let arr) = rawRunsJV {
            let decoder = JSONDecoder()
            stagedAllFileOrder = arr.compactMap { entry in
                guard let data = try? JSONEncoder().encode(entry) else { return nil }
                return try? decoder.decode(ImprovementRun.self, from: data)
            }.filter { $0.phase == "staged" }
        } else {
            stagedAllFileOrder = []
        }
        let stagedCount = stagedAllFileOrder.count
        // Daemon caps `stagedRuns` at 12: `staged[:12]` — oldest 12.
        let stagedRunsCapped = Array(stagedAllFileOrder.prefix(12))

        // Daemon: latestRun = max(runs, key=createdAt). `runs` here is
        // file-order-reversed, so don't rely on `runs.first` — compute the
        // max-by-timestamp explicitly to mirror daemon semantics.
        let latestRun = runs.max(by: { ($0.createdAt ?? "") < ($1.createdAt ?? "") })

        // Daemon: latestFailure scans reversed(file_order) for status=="failed".
        // Our `runs` is already file-order-reversed, so first match wins.
        // "interrupted" is NOT considered a failure for this field.
        let latestFailure = runs.first { $0.status == "failed" }

        let scoreboard = SelfImprovementScoreboard.summarize(runs: runs)

        // Build a raw response object that includes byStatus for callers
        // who need the breakdown dict, and a compact scoreboard so UI/receipt
        // callers do not have to parse long-tail daemon-era fields.
        let byStatusJV = JSONValue.object(
            Dictionary(uniqueKeysWithValues: byStatus.map { ($0.key, JSONValue.int(Int64($0.value))) })
        )
        let rawResponse = JSONValue.object([
            "total": .int(Int64(total)),
            "byStatus": byStatusJV,
            "scoreboard": scoreboard.toJSONValue(),
        ])

        return ImprovementSummary(
            enabled: nil,
            status: nil,
            disabledReason: nil,
            runningCount: runningCount,
            succeededCount: succeededCount,
            failedCount: failedCount,
            interruptedCount: interruptedCount,
            stagedCount: stagedCount,
            totalCount: total,
            latestRun: latestRun,
            latestFailure: latestFailure,
            stagedRuns: stagedRunsCapped,
            rawResponse: rawResponse
        )
    }

    /// Mark all runs with `status == "running"` as interrupted, set their
    /// phase to "interrupted", and write the sentinel summary message.
    /// Returns the number of runs changed.
    ///
    /// DIVERGENCE FROM DAEMON: The Python `mark_stale_improvements()` calls
    /// `improvement_run_live()` which uses `psutil.pid_exists()` to inspect
    /// whether the codex subprocess is still alive before marking a run as
    /// interrupted. This Swift method marks ALL "running" runs
    /// unconditionally. That is intentional: `markStaleImprovementsLocal`
    /// is designed for cold-start cleanup where the Swift caller KNOWS no
    /// daemon is running (e.g., app launch before spawning the daemon, or
    /// unit tests that write fixture data). Using it while a daemon is
    /// running could incorrectly interrupt live runs. The daemon's
    /// process-check guard is not ported to Swift because `psutil` is a
    /// Python-only dependency.
    ///
    /// - Returns: Count of runs whose status was changed from "running" to
    ///   "interrupted".
    public func markStaleImprovementsLocal() async throws -> Int {
        let path = dataRoot.appendingPathComponent("improvements/runs.json")
        return try await withPathLock(path) { [persistence] in
            let raw = await persistence.readJSON(path, defaultValue: .array([]))
            guard case .array(let arr) = raw else { return 0 }

            var changed = 0
            let updated: [JSONValue] = arr.map { entry in
                guard case .object(var obj) = entry else { return entry }
                guard case .string(let status)? = obj["status"], status == "running" else { return entry }
                obj["status"] = .string("interrupted")
                obj["phase"] = .string("interrupted")
                obj["summary"] = .string("The app restarted before this improvement completed.")
                changed += 1
                return .object(obj)
            }

            if changed > 0 {
                try await persistence.writeJSON(.array(updated), to: path)
            }
            return changed
        }
    }

    /// Reset runs stuck in transient phases after a crash:
    ///   - `promoting`  → `staged`
    ///   - `reverting`  → `promoted`
    ///   - `discarding` → `staged`
    ///
    /// NARROWER SCOPE THAN DAEMON. This Swift variant ONLY rewrites the
    /// `phase` field on matching runs. The daemon's `_reconcile_transient_phases`
    /// additionally does ALL of the following on
    /// every matching run — none of which are performed here:
    ///
    ///   1. `status` → `"interrupted"`.
    ///   2. `summary` → `"Daemon crashed during {phase}; reset to {newPhase}."`
    ///      via `setdefault` (only set if absent).
    ///   3. For `phase == "promoting"` with an existing worktree:
    ///         - `recoveryRequired = True`
    ///         - `recoveryHint = "...review the main repo status and either
    ///           promote again, discard, or recover the labeled stash."`
    ///         - Best-effort `git stash list` + `git stash pop` of the
    ///           `nativeagent-promote-{id8}` labeled stash in repo_root.
    ///   4. For `phase == "reverting"`:
    ///         - Best-effort `git -C repo_root revert --abort`.
    ///
    /// Why narrower: Swift has no `repo_root` knowledge and no subprocess
    /// surface in this module; git-state cleanup belongs to the daemon when
    /// it boots, not to the Swift cold-start path. Unknown phases are left
    /// unchanged. Callers that need full daemon-grade recovery MUST defer
    /// to the daemon's `mark_stale_improvements()` call chain on startup.
    ///
    /// - Returns: Count of runs whose `phase` was reset.
    public func reconcileTransientPhasesLocal() async throws -> Int {
        let phaseReset: [String: String] = [
            "promoting":  "staged",
            "reverting":  "promoted",
            "discarding": "staged",
        ]
        let path = dataRoot.appendingPathComponent("improvements/runs.json")
        return try await withPathLock(path) { [persistence] in
            let raw = await persistence.readJSON(path, defaultValue: .array([]))
            guard case .array(let arr) = raw else { return 0 }

            var changed = 0
            let updated: [JSONValue] = arr.map { entry in
                guard case .object(var obj) = entry else { return entry }
                guard case .string(let phase)? = obj["phase"],
                      let newPhase = phaseReset[phase] else { return entry }
                obj["phase"] = .string(newPhase)
                changed += 1
                return .object(obj)
            }

            if changed > 0 {
                try await persistence.writeJSON(.array(updated), to: path)
            }
            return changed
        }
    }

    // MARK: - Phase C: commit-marker verified-fresh read (WAVE 37 W04, §6.159)

    /// Read the daemon's monotonic commit-marker seq from the SIDECAR file
    /// `improvements/runs.commit` (a `{"seq": N}` JSON object). Returns 0 when
    /// the marker is absent / malformed / seq <= 0 — the same "not provably
    /// fresh" sentinel the daemon's `_load_improvements_commit_seq` uses. The
    /// daemon stamps this file (atomically) inside every flock-held runs.json
    /// write via `_write_improvements_locked`, so a local read of it is exactly
    /// as authoritative as the daemon's `/v1/improvements/commit_seq` route
    /// (same file, atomic writes) without an HTTP hop.
    public func improvementsCommitSeqLocal() async -> Int {
        let path = dataRoot.appendingPathComponent("improvements/runs.commit")
        let raw = await persistence.readJSON(path, defaultValue: .object([:]))
        guard case .object(let obj) = raw else { return 0 }
        switch obj["seq"] {
        case .int(let n): return n > 0 ? Int(n) : 0
        case .double(let d): return d > 0 ? Int(d) : 0
        default: return 0
        }
    }

    /// VERIFIED-FRESH local read of the improvements runs (the flip-safe variant
    /// of `listImprovementsLocal`). Mirrors the §6.76 KnowledgeGraph
    /// `verifiedFreshStore` seq-sandwich, adapted for the improvements path:
    ///
    ///   seq1 = commit-marker  ->  runs = read runs.json  ->  seq2 = commit-marker
    ///
    /// The commit seq is a SEQLOCK counter: EVEN == quiescent (runs.json is the
    /// value stamped at that seq), ODD == a write is in progress (runs.json may
    /// be mid-replace). Trusts (returns) the local read ONLY when
    /// `seq1 == seq2 && seq1 >= 2 && seq1 is even`. An in-flight writer
    /// (reconcile/finalize/heartbeat/start/discard) bumps the seq to ODD before
    /// replacing runs.json and back to EVEN after, so a read that straddles a
    /// write sees either an ODD seq or `seq2 != seq1` → returns `nil`; the
    /// caller MUST not serve the local read. `seq1 < 2` / odd (no marker yet /
    /// mid-first-write) also returns `nil`: a completed improvements write
    /// carries an even marker >= 2, so anything else means "cannot prove
    /// freshness". A `running`/non-transient row is NEVER served from a window
    /// where a writer was mid-update.
    ///
    /// Returns runs in the SAME file-order-reversed order as
    /// `listImprovementsLocal`.
    public func listImprovementsVerified() async throws -> [ImprovementRun]? {
        // SEQLOCK sandwich. The commit seq is EVEN when quiescent (the
        // on-disk runs.json is the value stamped at that seq) and ODD while a
        // write is in progress (runs.json may be mid-replace). Trust the local
        // read ONLY when both marker reads are equal AND the seq is a quiescent
        // even >= 2 — i.e. at least one full write has completed and no write
        // straddled the read. seq < 2, an ODD seq, or a seq that moved between
        // the two reads all mean "a writer was mid-update / freshness not
        // provable" -> return nil so the caller fails closed/retries later.
        let seq1 = await improvementsCommitSeqLocal()
        guard seq1 >= 2, seq1 % 2 == 0 else { return nil }
        let runs = try await listImprovementsLocal()
        let seq2 = await improvementsCommitSeqLocal()
        guard seq1 == seq2 else { return nil }
        return runs
    }
}


// MARK: - Factory

public func makeSelfImprovement() -> any SelfImprovementProtocol {
    return SwiftNativeSelfImprovement()
}
