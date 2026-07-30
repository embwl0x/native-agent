import Foundation
import NativeAgentCore
import PersistenceCore
import Research
import KnowledgeGraph
import CapabilityFoundry

// MARK: - MCPSubprocessPool

/// Keyed pool of `MCPSubprocess` actors. Mirrors the daemon's
/// `self.mcp_processes` dict with two add-ons the
/// daemon implements inline: restart-with-backoff after a crash and a
/// per-server "last error" / "next-allowed retry" stamp.
public actor MCPSubprocessPool {
    public struct Spec: Sendable, Equatable {
        public var serverId: String
        public var command: String
        public var env: [String: String]?
        public var cwd: URL?
        public init(serverId: String, command: String, env: [String: String]? = nil, cwd: URL? = nil) {
            self.serverId = serverId
            self.command = command
            self.env = env
            self.cwd = cwd
        }
    }

    public struct CrashInfo: Sendable, Equatable {
        public var lastError: String
        public var nextRetryAt: Date
        public var consecutiveFailures: Int
    }

    private var processes: [String: MCPSubprocess] = [:]
    private var specs: [String: Spec] = [:]
    private var crashes: [String: CrashInfo] = [:]
    /// Round 5 Bug A fix (2026-05-31): per-server in-flight spawn task.
    /// Two concurrent cold `get(serverId:)` calls would otherwise each
    /// suspend across `await proc.start()` / `await proc.isRunning` and
    /// both reach `processes[serverId] = proc` — leaving two child
    /// subprocesses alive with the loser's termination handler eventually
    /// wiping the winner from the pool. We coalesce: the first cold caller
    /// installs a Task here, every subsequent caller joins via `.value`.
    private var spawnTasks: [String: Task<MCPSubprocess, Error>] = [:]
    /// Test/telemetry counter for actual spawn bodies entered per server.
    /// This intentionally increments in `_performSpawn`, not `get()`, so it
    /// proves concurrent cold callers joined the same spawn task.
    private var spawnAttemptCounts: [String: Int] = [:]
    /// Bug 5 fix (2026-05-31): per-server "spawn generation" counter.
    /// Bumped every time `get()` produces a fresh process. Crash
    /// recording is now idempotent per (serverId, generation) — the
    /// first record for a generation increments consecutiveFailures;
    /// subsequent records for the SAME generation are no-ops. This
    /// prevents the "synthetic crash from pool.get() + real crash from
    /// terminationHandler for the same death" doubling.
    private var processGenerations: [String: Int] = [:]
    /// Per-server set of spawn generations that have already had their
    /// crash recorded. U5 W-E (2026-06-11): was a flat
    /// `Set<String>` of `<serverId>:<gen>` composites that grew forever —
    /// now a dict so removed servers drop their whole entry and old
    /// generations get pruned on each new spawn (state-lifecycle rule:
    /// every add has a remove).
    private var recordedCrashGenerations: [String: Set<Int>] = [:]
    /// U5 W-E backoff-escalation fix (2026-06-11): timestamp of the last
    /// SUCCESSFUL spawn per server. Used to distinguish "ran stably for a
    /// while then died" (fresh failure streak) from "died right after
    /// start" (continuation of the existing streak).
    private var lastSpawnAt: [String: Date] = [:]
    /// Failure streak carried ACROSS a successful spawn. The old code
    /// cleared `crashes[serverId]` on every successful handshake, so a
    /// server that initialized fine but died seconds later reset
    /// consecutiveFailures every cycle — backoff never escalated past
    /// base. The streak parks here on spawn success and is resumed if the
    /// child dies again within `stabilityWindow`.
    private var carriedFailures: [String: Int] = [:]
    /// Uptime past which a die-after-start no longer counts as part of
    /// the previous crash streak.
    public var stabilityWindow: TimeInterval = 60
    /// R17: stdio children idle past this are stopped by the pool's reap
    /// deadline (specs stay — the next get() respawns cold). 0 disables reaping.
    /// lastUsedAt is stamped at request START, and per-request timeouts are
    /// far below this window, so an in-flight call can't be reaped mid-turn.
    public private(set) var idleTimeout: TimeInterval = 900
    private static let maximumIdleTimeout: TimeInterval = 7 * 24 * 60 * 60
    /// R17 / living-physiology convergence: one self-owned task sleeps until
    /// the earliest known idle deadline. Checkout, spawn, termination, spec
    /// replacement, stop, and timeout changes cancel/re-arm it. There is no
    /// periodic quarter-window polling while the children are merely alive.
    private var reapTask: Task<Void, Never>?
    private var reapScheduleGeneration: UInt64 = 0
    private var scheduledReapDeadline: Date?
    /// Deterministic test seam delivered immediately after a child/task actor
    /// hop and before identity revalidation. Nil in production.
    private var _getPostAwaitHook: (@Sendable () async -> Void)?
    private let reapNow: @Sendable () -> Date
    private let reapSleepUntil: @Sendable (Date) async throws -> Void
    /// R17 (review): stamped synchronously in `get()` when a pooled child is
    /// handed to a caller. `lastUsedAt` only updates at request() start (an
    /// actor hop away), so without this a reap pass interleaving between
    /// get()'s return and the caller's first request could stop a child the
    /// caller is holding. Reap anchors on the freshest of use/checkout/spawn.
    private var lastCheckedOutAt: [String: Date] = [:]
    /// Backoff base — daemon uses ad-hoc bumps; we use a tame exponential
    /// (0.5s, 1s, 2s, 4s, ... cap 30s) capped so a thrash never starves.
    public var baseBackoff: TimeInterval = 0.5
    public var maxBackoff: TimeInterval = 30

    public init() {
        self.reapNow = Date.init
        self.reapSleepUntil = Self.sleepUntil
    }

    /// Deterministic deadline/clock seam used only by focused pool tests.
    /// Production callers use `init()` above.
    init(
        reapNow: @escaping @Sendable () -> Date,
        reapSleepUntil: @escaping @Sendable (Date) async throws -> Void
    ) {
        self.reapNow = reapNow
        self.reapSleepUntil = reapSleepUntil
    }

    private nonisolated static func sleepUntil(_ deadline: Date) async throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining.isFinite, remaining > 0 else { return }
        let bounded = min(remaining, maximumIdleTimeout)
        try await Task.sleep(nanoseconds: UInt64(bounded * 1_000_000_000))
    }

    /// Replace the registered spec set. Specs not in the new list have their
    /// running processes stopped (and their pool side-state cleared). A
    /// same-id spec whose command/env/cwd CHANGED has its running process
    /// bounced — U5 W-E fix (2026-06-11): previously the old subprocess
    /// kept running the stale command until it died on its own. New specs
    /// are NOT spawned eagerly — first `get(serverId)` triggers the spawn.
    public func updateSpecs(_ newSpecs: [Spec]) async {
        // U5 fix-round (2026-06-11, gpt-5.5 review): mutate ALL pool state
        // synchronously — zero suspension points — BEFORE awaiting any child
        // shutdown. The old code awaited `proc.stop()` (an actor hop) while
        // the stale entry was still in `processes`/`specs`, so a concurrent
        // `get(serverId:)` re-entering the pool actor during that window
        // could return the stale subprocess mid-command-change. Now stale
        // processes are collected, state is swapped, and only THEN do we
        // stop the collected children.
        let newIDs = Set(newSpecs.map(\.serverId))
        var staleProcesses: [MCPSubprocess] = []
        for (id, proc) in processes where !newIDs.contains(id) {
            processes.removeValue(forKey: id)
            staleProcesses.append(proc)
        }
        // State-lifecycle: removed servers drop ALL side-tables, not just
        // the process entry (crashes/generations/counts leaked before).
        for id in specs.keys where !newIDs.contains(id) {
            crashes.removeValue(forKey: id)
            processGenerations.removeValue(forKey: id)
            spawnAttemptCounts.removeValue(forKey: id)
            recordedCrashGenerations.removeValue(forKey: id)
            lastSpawnAt.removeValue(forKey: id)
            carriedFailures.removeValue(forKey: id)
            lastCheckedOutAt.removeValue(forKey: id)
        }
        var dict: [String: Spec] = [:]
        for s in newSpecs { dict[s.serverId] = s }
        // Bounce running processes whose spec changed under the same id.
        for (id, newSpec) in dict {
            guard let old = specs[id], old != newSpec else { continue }
            if let proc = processes.removeValue(forKey: id) {
                NSLog("MCPSubprocessPool: spec changed for %@ — bouncing stale subprocess", id)
                staleProcesses.append(proc)
            }
            // A new command deserves a clean slate — the old command's
            // crash streak says nothing about the new one.
            crashes.removeValue(forKey: id)
            carriedFailures.removeValue(forKey: id)
        }
        specs = dict
        // Test seam: lets a test deterministically interleave a `get()`
        // inside the stop window (state already swapped, children not yet
        // stopped) and prove it never sees the stale subprocess.
        if let hook = _updateSpecsStopWindowHook { await hook() }
        for proc in staleProcesses {
            await proc.stop()
        }
        await rescheduleReapDeadline()
    }

    /// Test-only seam awaited inside `updateSpecs` AFTER pool state is
    /// swapped but BEFORE stale children are stopped. Actor re-entrancy
    /// lets the hook call back into the pool mid-window.
    private var _updateSpecsStopWindowHook: (@Sendable () async -> Void)?
    public func _setUpdateSpecsStopWindowHook(_ hook: (@Sendable () async -> Void)?) {
        _updateSpecsStopWindowHook = hook
    }

    public func _setGetPostAwaitHook(_ hook: (@Sendable () async -> Void)?) {
        _getPostAwaitHook = hook
    }

    /// Return (spawning if necessary) the subprocess actor for a server id.
    /// Respects the crash-backoff: if the previous attempt failed and we're
    /// still inside its cooldown window, throws the cached error. A pooled
    /// subprocess that has DIED (e.g. OOM, panic) since its last successful
    /// spawn is detected via `isRunning` and converted into the same crash
    /// backoff flow — otherwise a crashloop would respawn on every request.
    public func get(serverId: String) async throws -> MCPSubprocess {
        if let existing = processes[serverId] {
            let existingRunning = await existing.isRunning
            if let hook = _getPostAwaitHook { await hook() }
            if existingRunning {
                // `isRunning` is an actor hop. Spec replacement, stop, or a
                // reap may have evicted this child while we were suspended.
                // Re-enter selection instead of returning an actor the pool
                // no longer owns.
                guard let pooled = processes[serverId], pooled === existing else {
                    return try await get(serverId: serverId)
                }
                // Checkout stamp + return happen in one synchronous actor
                // slice — reap can never interleave between them.
                lastCheckedOutAt[serverId] = reapNow()
                rescheduleReapDeadlineFromPoolAnchors()
                return existing
            }
            // Pooled-but-dead — most commonly because the terminationHandler
            // path already recorded a crash. If it hasn't, fall back to a
            // synthetic crash record so the backoff window still arms.
            //
            // Bug 5 fix (2026-05-31): pass the current generation in so a
            // later real-terminationHandler crash record for the SAME
            // death gets deduped instead of double-bumping
            // consecutiveFailures.
            //
            // Round 5 Bug A fix: identity-compare before evicting — a
            // concurrent successful re-spawn may have already replaced the
            // dead actor in `processes[serverId]` while we were awaiting
            // `existing.isRunning`. Blind `removeValue` would wipe the
            // replacement.
            guard let pooled = processes[serverId], pooled === existing else {
                return try await get(serverId: serverId)
            }
            processes.removeValue(forKey: serverId)
            let currentGen = processGenerations[serverId] ?? 0
            recordCrashFromMessage(
                serverId: serverId,
                message: "pooled subprocess died before terminationHandler fired",
                generation: currentGen
            )
        }
        guard let spec = specs[serverId] else {
            throw MCPDispatcherError.serverNotFound(serverId)
        }
        if let crash = crashes[serverId], crash.nextRetryAt > Date() {
            throw MCPSubprocessError.spawnFailed(
                "\(spec.serverId) is in crash backoff (\(crash.lastError))"
            )
        }
        // Round 5 Bug A fix: coalesce concurrent cold spawns per server.
        // The PREVIOUS implementation suspended at `proc.start()` /
        // `proc.isRunning` with no in-flight marker — two callers could
        // both reach `processes[serverId] = proc`, leaving the loser's
        // child alive (and its eventual terminationHandler later wiping
        // the WINNER from the pool). Now: the first cold caller installs
        // a Task here; every subsequent cold caller awaits the same Task.
        if let inflight = spawnTasks[serverId] {
            let proc = try await inflight.value
            if let hook = _getPostAwaitHook { await hook() }
            guard let pooled = processes[serverId], pooled === proc else {
                if let current = spawnTasks[serverId], current == inflight {
                    spawnTasks[serverId] = nil
                }
                return try await get(serverId: serverId)
            }
            return proc
        }
        let task = Task<MCPSubprocess, Error> { [spec] in
            try await self._performSpawn(spec: spec)
        }
        spawnTasks[serverId] = task
        do {
            let proc = try await task.value
            if let hook = _getPostAwaitHook { await hook() }
            if let current = spawnTasks[serverId], current == task {
                spawnTasks[serverId] = nil
            }
            guard let pooled = processes[serverId], pooled === proc else {
                return try await get(serverId: serverId)
            }
            return proc
        } catch {
            if let current = spawnTasks[serverId], current == task {
                spawnTasks[serverId] = nil
            }
            throw error
        }
    }

    /// Round 5 Bug A fix: the actual spawn body, extracted so `get()` can
    /// wrap it in a per-server `spawnTasks[serverId]` Task. Actor-isolated;
    /// only one body runs at a time per server because `get()` checks for
    /// an in-flight Task synchronously before installing this one. The
    /// body still suspends on `proc.start()` / `proc.isRunning`, but any
    /// concurrent `get()` for the same id awaits the SAME Task instead of
    /// kicking off a parallel spawn.
    fileprivate func _performSpawn(spec: Spec) async throws -> MCPSubprocess {
        let serverId = spec.serverId
        spawnAttemptCounts[serverId, default: 0] += 1
        // Bump the generation BEFORE spawn. Spawn failure also records
        // against this new generation so the next get() honors backoff.
        let newGen = (processGenerations[serverId] ?? 0) + 1
        processGenerations[serverId] = newGen
        // Prune recorded-crash generations that can no longer get a late
        // terminationHandler fire (keep a small trailing window for
        // stragglers). Without this the set grows one entry per spawn for
        // the life of the pool.
        if var gens = recordedCrashGenerations[serverId] {
            gens = gens.filter { $0 >= newGen - 8 }
            recordedCrashGenerations[serverId] = gens.isEmpty ? nil : gens
        }
        let proc: MCPSubprocess
        do {
            proc = try MCPSubprocess.fromServerCommand(
                serverId: spec.serverId,
                command: spec.command,
                env: spec.env,
                cwd: spec.cwd
            )
        } catch {
            recordCrash(serverId: serverId, error: error, generation: newGen)
            throw error
        }
        // Bug 2 fix (2026-05-31, 3rd-round review): install the unexpected-
        // termination handler BEFORE start() so a child that dies during
        // (or microseconds after) the startup handshake fires the handler
        // immediately — there's no race window where pendingTermination
        // buffers a death that get() then races to "pool the dead actor
        // and clobber the crash record with crashes.removeValue".
        let captured = serverId
        let capturedGen = newGen
        let capturedProc = proc
        await proc.onUnexpectedTermination { [weak self] status, reason in
            guard let self = self else { return }
            Task {
                await self._recordTermination(
                    serverId: captured,
                    process: capturedProc,
                    generation: capturedGen,
                    status: status,
                    reason: reason
                )
            }
        }
        do {
            try await proc.start()
        } catch {
            recordCrash(serverId: serverId, error: error, generation: newGen)
            throw error
        }
        // Bug 2 fix: after start, synchronously detect a die-during-start
        // race. If the child already terminated, do NOT pool the dead
        // actor and do NOT clobber the (about-to-arrive) crash record.
        // stop() on the dead actor is teardown-only (terminate is skipped
        // when not running) — it clears pipes, the drain task, and waiters
        // so the failed spawn leaves nothing behind.
        if await !proc.isRunning {
            await proc.stop()
            recordCrashFromMessage(
                serverId: serverId,
                message: "process died during start handshake",
                generation: newGen
            )
            throw MCPSubprocessError.spawnFailed(
                "\(spec.serverId) died during start handshake"
            )
        }
        // Bug A fix (4th-round review): defensive check for the
        // suspension-window race where `await proc.isRunning` released
        // the actor long enough for the terminationHandler-fired
        // `_recordTermination` Task to run and record a crash for THIS
        // generation. Identity-compare by generation: if the genKey has
        // been recorded, the corpse is this spawn's, throw rather than
        // pool.
        if recordedCrashGenerations[serverId]?.contains(newGen) == true {
            await proc.stop()
            throw MCPSubprocessError.spawnFailed(
                "\(spec.serverId) terminated during start handshake (handler race)"
            )
        }
        // U5 W-E fix: the spec may have been removed or replaced (command
        // change) by an `updateSpecs` that ran during our start() awaits.
        // Pooling the orphan would leak a child running a retired/stale
        // command under a key updateSpecs already cleaned.
        guard let currentSpec = specs[serverId], currentSpec == spec else {
            await proc.stop()
            throw MCPSubprocessError.spawnFailed(
                "\(spec.serverId) spec removed or changed during spawn"
            )
        }
        // U5 W-E backoff-escalation fix: park the failure streak instead
        // of erasing it. `recordCrashFromMessage` resumes the streak if
        // this child dies again within `stabilityWindow`; a stable run
        // discards it there.
        if let prior = crashes.removeValue(forKey: serverId) {
            carriedFailures[serverId] = prior.consecutiveFailures
        }
        let spawnedAt = reapNow()
        lastSpawnAt[serverId] = spawnedAt
        lastCheckedOutAt[serverId] = spawnedAt
        processes[serverId] = proc
        // Do not suspend after publishing the child and before returning it.
        // The refresh task re-derives the exact deadline; an older fire also
        // re-reads the new checkout anchor and therefore cannot reap it.
        rescheduleReapDeadlineFromPoolAnchors()
        return proc
    }

    // MARK: - R17 idle reap

    /// One reap pass: stop pooled children whose last use (or start, for a
    /// never-used child) is older than `idleTimeout`. Returns the reaped ids.
    /// Same two-phase shape as `updateSpecs`: pool state is mutated with an
    /// identity re-check after every suspension point, children are stopped
    /// only after they're out of the pool.
    @discardableResult
    public func reapIdle(now: Date = Date()) async -> [String] {
        let reapedIds = await reapIdlePass(now: now)
        await rescheduleReapDeadline()
        return reapedIds
    }

    /// One pass without changing the deadline owner. The scheduled-fire path
    /// uses this so a checkout/spec mutation that interleaves at one of the
    /// child actor reads can install a newer generation which the stale fire
    /// is forbidden to overwrite afterward.
    private func reapIdlePass(now: Date) async -> [String] {
        guard idleTimeout > 0 else { return [] }
        var reapedIds: [String] = []
        var reapedProcs: [MCPSubprocess] = []
        for (id, proc) in processes {
            // Re-validate after each await — a concurrent get()/updateSpecs
            // may have evicted or replaced this entry mid-iteration.
            guard let pooled = processes[id], pooled === proc else { continue }
            let lastUsed = await proc.lastUsedAt
            let started = await proc.startedAt
            // Freshest of use / start / pool-side checkout. The checkout
            // stamp is re-read AFTER the awaits so a get() that handed this
            // child out mid-pass vetoes the reap (review round-2 race).
            let anchorCandidates = [lastUsed, started, lastCheckedOutAt[id], lastSpawnAt[id]]
                .compactMap { $0 }
            guard let anchor = anchorCandidates.max() else { continue }
            guard now.timeIntervalSince(anchor) >= idleTimeout else { continue }
            guard let stillPooled = processes[id], stillPooled === proc else { continue }
            processes.removeValue(forKey: id)
            // Intentional stop — same streak semantics as stop(serverId:):
            // a later respawn shouldn't inherit escalated backoff.
            carriedFailures.removeValue(forKey: id)
            lastSpawnAt.removeValue(forKey: id)
            lastCheckedOutAt.removeValue(forKey: id)
            reapedIds.append(id)
            reapedProcs.append(proc)
        }
        for proc in reapedProcs {
            await proc.stop()
        }
        if !reapedIds.isEmpty {
            NSLog("MCPSubprocessPool: reaped %d idle stdio child(ren): %@",
                  reapedIds.count, reapedIds.joined(separator: ", "))
        }
        return reapedIds.sorted()
    }

    /// Compute the earliest exact deadline from the freshest authoritative
    /// anchor each child exposes. Identity is rechecked after every actor hop:
    /// a replacement process must never inherit an old child's deadline.
    private func nextReapDeadline() async -> Date? {
        guard idleTimeout.isFinite, idleTimeout > 0, !processes.isEmpty else { return nil }
        var earliest: Date?
        for (id, proc) in processes {
            guard let pooled = processes[id], pooled === proc else { continue }
            let lastUsed = await proc.lastUsedAt
            guard let stillPooled = processes[id], stillPooled === proc else { continue }
            let started = await proc.startedAt
            guard let finalPooled = processes[id], finalPooled === proc else { continue }
            let anchors = [lastUsed, started, lastCheckedOutAt[id], lastSpawnAt[id]].compactMap { $0 }
            guard let anchor = anchors.max() else { continue }
            let deadline = anchor.addingTimeInterval(idleTimeout)
            if earliest == nil || deadline < earliest! { earliest = deadline }
        }
        return earliest
    }

    private func rescheduleReapDeadline() async {
        reapScheduleGeneration &+= 1
        let generation = reapScheduleGeneration
        reapTask?.cancel()
        reapTask = nil
        scheduledReapDeadline = nil

        guard idleTimeout.isFinite, idleTimeout > 0, !processes.isEmpty else { return }
        guard let deadline = await nextReapDeadline() else { return }
        // `nextReapDeadline()` crosses child actors. A concurrent mutation may
        // have installed a newer schedule while we were suspended.
        guard generation == reapScheduleGeneration,
              idleTimeout > 0,
              !processes.isEmpty else { return }

        scheduledReapDeadline = deadline
        let sleeper = reapSleepUntil
        reapTask = Task { [weak self] in
            do {
                try await sleeper(deadline)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.reapDeadlineFired(generation: generation, now: nil)
        }
    }

    /// Publish a safe exact deadline using only pool-owned anchors. This is
    /// intentionally synchronous so checkout/spawn can return the exact actor
    /// they just validated without opening a re-entrant stale-return window.
    /// A request that touched the child after checkout can only make this
    /// deadline early; the fire path re-reads child truth and re-arms instead
    /// of reaping a recently used process.
    private func rescheduleReapDeadlineFromPoolAnchors() {
        reapScheduleGeneration &+= 1
        let generation = reapScheduleGeneration
        reapTask?.cancel()
        reapTask = nil
        scheduledReapDeadline = nil
        guard idleTimeout.isFinite, idleTimeout > 0, !processes.isEmpty else { return }
        let earliest = processes.keys.compactMap { id -> Date? in
            [lastCheckedOutAt[id], lastSpawnAt[id]].compactMap { $0 }.max()
                .map { $0.addingTimeInterval(idleTimeout) }
        }.min()
        guard let deadline = earliest else { return }
        scheduledReapDeadline = deadline
        let sleeper = reapSleepUntil
        reapTask = Task { [weak self] in
            do {
                try await sleeper(deadline)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.reapDeadlineFired(generation: generation, now: nil)
        }
    }

    /// A deadline task may resume after checkout, replacement, stop, or a
    /// timeout change cancelled it. Generation equality is the fail-closed
    /// identity check: only the currently published task may reap or re-arm.
    private func reapDeadlineFired(generation: UInt64, now: Date?) async {
        guard generation == reapScheduleGeneration else { return }
        reapTask?.cancel()
        reapTask = nil
        scheduledReapDeadline = nil
        _ = await reapIdlePass(now: now ?? reapNow())
        guard generation == reapScheduleGeneration else { return }
        await rescheduleReapDeadline()
    }

    /// Called from the terminationHandler bridge. Removes the dead actor
    /// from the pool and records a crash so the next `get()` honors backoff.
    ///
    /// Bug 5 fix (2026-05-31): takes the spawn generation captured when
    /// the handler was installed. recordCrashFromMessage skips when this
    /// generation already has a crash recorded — so the synthetic
    /// "pooled-but-dead" record from `get()` plus the real
    /// terminationHandler record for the SAME death count as ONE bump
    /// of consecutiveFailures, not two.
    fileprivate func _recordTermination(
        serverId: String,
        process: MCPSubprocess,
        generation: Int,
        status: Int32,
        reason: String
    ) async {
        // Round 5 Bug A fix: identity-compare so a stale terminationHandler
        // fire from an older (already-evicted) process can never wipe a
        // fresh replacement out of `processes[serverId]`. Without this, the
        // Bug A scenario (two concurrent spawns; loser dies later) ended
        // with the winner getting evicted by the loser's handler.
        if let pooled = processes[serverId], pooled === process {
            processes.removeValue(forKey: serverId)
        }
        recordCrashFromMessage(
            serverId: serverId,
            message: "process \(reason) (exit=\(status))",
            generation: generation
        )
        await rescheduleReapDeadline()
    }

    /// Stop a server's subprocess if one is running, leaving the spec in place.
    public func stop(serverId: String) async {
        // An intentional stop ends any carried crash streak — a later
        // user-initiated respawn shouldn't inherit escalated backoff.
        carriedFailures.removeValue(forKey: serverId)
        lastSpawnAt.removeValue(forKey: serverId)
        lastCheckedOutAt.removeValue(forKey: serverId)
        guard let proc = processes.removeValue(forKey: serverId) else { return }
        await proc.stop()
        await rescheduleReapDeadline()
    }

    /// Stop and forget every spawned subprocess. Specs are kept.
    public func stopAll() async {
        // Swap pool ownership before the first child actor hop. A concurrent
        // get() may legitimately cold-spawn after this boundary; it must stay
        // pooled instead of being orphaned by a trailing `removeAll()` after
        // stop() suspension points.
        reapTask?.cancel()
        reapTask = nil
        reapScheduleGeneration &+= 1
        scheduledReapDeadline = nil
        let stopped = Array(processes.values)
        processes.removeAll()
        carriedFailures.removeAll()
        lastSpawnAt.removeAll()
        lastCheckedOutAt.removeAll()
        for proc in stopped {
            await proc.stop()
        }
        await rescheduleReapDeadline()
    }

    /// Snapshot every spec for the session-status surface — one row per
    /// registered server, status reflecting whether it's currently running.
    public func sessionStatuses() async -> [MCPSessionStatus] {
        var out: [MCPSessionStatus] = []
        for (id, _) in specs {
            let proc = processes[id]
            let live = await proc?.isRunning ?? false
            let pid = await proc?.pid
            let started = await proc?.startedAt
            let lastUsed = await proc?.lastUsedAt
            let crash = crashes[id]
            let status: String
            let health: String
            if live { status = "warm"; health = "ok" }
            else if crash != nil { status = "failed"; health = "error" }
            else { status = "idle"; health = "not_checked" }
            out.append(MCPSessionStatus(
                id: id,
                serverId: id,
                serverName: nil,
                transport: "stdio",
                status: status,
                healthStatus: health,
                toolCount: 0,
                resourceCount: 0,
                lastWarmedAt: started.map(SwiftNativeMCPDispatcher.isoTimestamp),
                lastUsedAt: lastUsed.map(SwiftNativeMCPDispatcher.isoTimestamp),
                pid: pid,
                lastError: crash?.lastError
            ))
        }
        return out.sorted { $0.id < $1.id }
    }

    /// Test seam — directly inject a CrashInfo so the cooldown branch can be
    /// exercised without forcing a real crash.
    public func _setCrashInfo(_ info: CrashInfo, for serverId: String) {
        crashes[serverId] = info
    }

    /// Test seam — widen/narrow crash-backoff windows without sleeping.
    public func _setBackoffDurations(base: TimeInterval, max: TimeInterval) {
        baseBackoff = base
        maxBackoff = max
    }

    /// Test seam — replace the actor backing a server id (used by tests that
    /// want to assert restart semantics without re-running a python helper).
    public func _injectProcess(_ proc: MCPSubprocess, spec: Spec) async {
        specs[spec.serverId] = spec
        processes[spec.serverId] = proc
        let stamp = reapNow()
        lastSpawnAt[spec.serverId] = stamp
        lastCheckedOutAt[spec.serverId] = stamp
        await rescheduleReapDeadline()
    }

    /// Test seam — number of actual spawn attempts entered for a server.
    public func _spawnAttemptCount(for serverId: String) -> Int {
        spawnAttemptCounts[serverId] ?? 0
    }

    /// Test seam — read the current crash record for a server (escalation
    /// tests assert consecutiveFailures across respawn cycles).
    public func _crashInfo(for serverId: String) -> CrashInfo? {
        crashes[serverId]
    }

    /// Test seam — shrink/grow the stability window without waiting 60s.
    public func _setStabilityWindow(_ seconds: TimeInterval) {
        stabilityWindow = seconds
    }

    /// Test seam — adjust the idle-reap window without waiting 15 minutes.
    public func _setIdleTimeout(_ seconds: TimeInterval) async {
        idleTimeout = seconds.isFinite
            ? min(Self.maximumIdleTimeout, max(0, seconds))
            : 0
        await rescheduleReapDeadline()
    }

    /// Test seam — whether an exact idle deadline is currently armed.
    public func _reapLoopArmed() -> Bool {
        reapTask != nil
    }

    public func _scheduledReapDeadline() -> Date? {
        scheduledReapDeadline
    }

    public func _reapScheduleGeneration() -> UInt64 {
        reapScheduleGeneration
    }

    /// Deterministically deliver a captured deadline in tests. Production
    /// delivery comes only from `reapSleepUntil`; stale generations no-op.
    public func _fireReapDeadlineForTests(generation: UInt64, now: Date) async {
        await reapDeadlineFired(generation: generation, now: now)
    }

    private func recordCrash(serverId: String, error: Error, generation: Int) {
        recordCrashFromMessage(
            serverId: serverId,
            message: String(describing: error),
            generation: generation
        )
    }

    /// Bug 5 fix (2026-05-31): per-generation idempotence. The first
    /// crash record per (serverId, generation) bumps consecutiveFailures
    /// and arms the backoff window. Subsequent records for the SAME
    /// generation update lastError only — they do NOT re-bump the
    /// counter. This prevents the double-count where both the
    /// `get()`-synthetic "pooled subprocess died" record and the real
    /// terminationHandler-fired record write for the same death.
    private func recordCrashFromMessage(
        serverId: String,
        message: String,
        generation: Int
    ) {
        if recordedCrashGenerations[serverId]?.contains(generation) == true {
            // Same-death duplicate. Refresh lastError so callers see the
            // latest/most-specific reason (terminationHandler reasons are
            // typically richer than the synthetic placeholder), but do
            // NOT bump consecutiveFailures or push out nextRetryAt.
            if var existing = crashes[serverId] {
                existing.lastError = message
                crashes[serverId] = existing
            }
            return
        }
        recordedCrashGenerations[serverId, default: []].insert(generation)
        var priorCount = crashes[serverId]?.consecutiveFailures ?? 0
        if priorCount == 0 {
            // U5 W-E backoff-escalation fix: a successful spawn parked the
            // previous streak in `carriedFailures` (crashes was cleared).
            // A death within `stabilityWindow` of that spawn is the same
            // crashloop — resume the streak so backoff keeps escalating.
            // A death after a stable run starts a fresh streak.
            let uptime = lastSpawnAt[serverId].map { Date().timeIntervalSince($0) }
            if let up = uptime, up < stabilityWindow {
                priorCount = carriedFailures[serverId] ?? 0
            } else {
                carriedFailures.removeValue(forKey: serverId)
            }
        }
        let failureCount = priorCount + 1
        // Exponential backoff: base * 2^(n-1), capped at maxBackoff.
        let multiplier = pow(2.0, Double(failureCount - 1))
        let waitSec = min(baseBackoff * multiplier, maxBackoff)
        crashes[serverId] = CrashInfo(
            lastError: message,
            nextRetryAt: Date().addingTimeInterval(waitSec),
            consecutiveFailures: failureCount
        )
    }
}
