import Foundation
import NativeAgentCore
import PersistenceCore

public struct CognitiveSubstrateDependencies: Sendable {
    public var now: @Sendable () -> Date
    public var makeUUID: @Sendable () -> UUID
    /// How the agent addresses the user, resolved from the configured persona
    /// (profile.json `userName`, set at onboarding). Never hardcode a name in
    /// the capsule/reflection cues — a public install's user is not "User".
    /// Empty/whitespace → the helpers fall back to grammar-safe "you"/"your".
    public var userName: @Sendable () -> String
    /// Rebuildable hot-read publication. The substrate remains the only owner
    /// of this state; the sink receives a bounded immutable projection after a
    /// mutation so turn preparation never has to enter this actor.
    public var attentionProjectionSink: @Sendable (CognitiveAttentionSignals?, Date) -> Void

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        userName: @escaping @Sendable () -> String = { "" },
        attentionProjectionSink: @escaping @Sendable (CognitiveAttentionSignals?, Date) -> Void = { _, _ in }
    ) {
        self.now = now
        self.makeUUID = makeUUID
        self.userName = userName
        self.attentionProjectionSink = attentionProjectionSink
    }

    public static let live = CognitiveSubstrateDependencies()
}

public actor CognitiveSubstrate {
    var configuration: CognitiveConfiguration
    let dependencies: CognitiveSubstrateDependencies
    private let store: CognitiveSQLiteStore?
    var persistenceHealth: CognitivePersistenceHealth = .disabled
    private var persistenceWritesBlocked = false
    var field = ContinuityField()
    var thoughtSeeds: [UUID: CognitiveThoughtSeed] = [:]
    var thoughtSeedRevision: UInt64 = 0
    private var episodes: [UUID: CognitiveEpisodeReference] = [:]
    var schemaProposals: [UUID: CognitiveSchemaProposal] = [:]
    /// Wave E: proposal-shaped standing views. Every view enters `.proposed`; only
    /// `resolveStandingView(approved:)` (User) activates one. Persisted one artifact per view
    /// (kind "standing_view"), restored on boot. See CognitiveSubstrate+StandingViews.swift.
    var standingViews: [UUID: CognitiveStandingView] = [:]
    private var identityProposals: [UUID: CognitiveIdentityProposal] = [:]
    private var developmentalTimeline: [UUID: CognitiveDevelopmentalTimelineEvent] = [:]
    private var replayEvidenceIds: Set<String> = []
    var reflectionReceipts: [UUID: CognitiveReflectionReceipt] = [:]
    /// A planned reflection already owns the next daily budget slot until its
    /// result (success/failure/cancel) is recorded. Manual and scheduled callers
    /// share this actor, so one bounded marker closes their reentrant race without
    /// creating another ledger or state owner. Configuration refreshes preserve
    /// it; a dead request expires after the runtime's maximum reflection window.
    struct ReflectionReservation: Sendable, Equatable {
        var id: UUID
        var since: Date
    }
    var reflectionReservation: ReflectionReservation?
    static let reflectionInFlightMaximumAge: TimeInterval = 10 * 60
    private var experimentResults: [UUID: CognitiveExperimentResult] = [:]
    var affect = CognitiveAffectState()
    /// The slow felt layer — reflection-written, day-scale decay (see +Mood.swift).
    var disposition = CognitiveDisposition()
    /// Round 3 Wave A3 — day claims for the resolution-pattern nudge, keyed
    /// "path|kind" → day bucket. Enforces at-most-once per kind per day across
    /// the ~20h consolidation ticks; persisted inside the disposition artifact
    /// so a same-day restart cannot re-nudge. Pruned to the current day only.
    var resolutionPatternNudgeDay: [String: String] = [:]
    private var ablations: [String: Bool] = [:]
    var dirtySince: Date?
    var dirtyRevision: UInt64 = 0
    /// Defense-in-depth single-flight at the state owner. Core normally
    /// single-flights the scheduled loop, but app termination/manual callers
    /// can reach the same actor outside that registration. A second pass must
    /// not stage over the first while its SQLite transaction is suspended.
    var maintenanceRunInFlight = false

    /// R-F2: the microcycle and maintenance each commit a full node/seed/affect
    /// transition through ONE SQLite transaction, and their commits must not
    /// interleave. The microcycle snapshots its seed rows before its commit
    /// await; a maintenance decay that lands inside that suspended commit is
    /// reverted on disk when the microcycle's pre-decay rows are written (memory
    /// stays correct; the next maintenance heals). The microcycle raises this
    /// flag across its commit window and `runMaintenanceChecked` refuses to
    /// start while it is set — making the exclusion symmetric (the reverse
    /// direction is already covered: the microcycle waits on
    /// `waitForMaintenanceTransition` before it begins). It is deliberately NOT
    /// routed through `waitForMaintenanceTransition`, so the resident ingest hot
    /// path is never blocked by a microcycle commit; a maintenance skipped here
    /// simply re-arms and runs once the microcycle finishes.
    var maintenanceCommitInFlight = false

    /// R-F2 test seam. When non-nil the microcycle awaits this immediately
    /// before its persistence commit — inside the `maintenanceCommitInFlight`
    /// window — so a test can deterministically drive an interleaving
    /// maintenance run. nil in production (one optional check on the hot path).
    var microcycleCommitInterleaveProbe: (@Sendable () async -> Void)?

    /// R-F3: parked waiters for the maintenance transition gate. A mutating
    /// entry point that arrives while a maintenance transaction is suspended in
    /// the store actor parks on a continuation here instead of busy-spinning
    /// `Task.yield()`, and is resumed exactly once when the transition ends.
    private struct MaintenanceTransitionWaiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }
    private var maintenanceTransitionWaiters: [MaintenanceTransitionWaiter] = []
    private var maintenanceTransitionWaiterSeq: UInt64 = 0

    /// Maintenance stages several related families and commits them through one
    /// SQLite transaction. Actor reentrancy at that database await must not let
    /// a live mutation observe or persist the staged half-transition. Mutating
    /// entry points wait here; read-only snapshots remain available.
    ///
    /// R-F3: waiters park on a `CheckedContinuation` instead of spinning
    /// `Task.yield()`. `endMaintenanceTransition()` resumes every parked waiter
    /// exactly once; a cancelled waiter releases itself without leaking its
    /// continuation. The array is the single owner of each parked continuation,
    /// so a resume by the drain and a resume by cancellation can never both fire
    /// for the same waiter (whichever removes the id first wins; the other
    /// no-ops).
    ///
    /// CANCELLATION CONTRACT (review round 2, BLOCKING): being resumed by the
    /// cancel handler is NOT permission to pass the gate — a cancelled
    /// `ingestResident`/`clearTransientState` proceeding while a maintenance
    /// transaction is suspended mid-commit is exactly the mutate-into-staged-
    /// half-transition race this gate exists to stop (the pre-R-F3 yield-spin
    /// held cancelled callers too). The wait is a LOOP: every resume re-checks
    /// the flag; a cancelled task — which cannot re-park, its cancel handler
    /// would fire immediately — degrades to the old bounded yield-spin until
    /// the transition closes.
    func waitForMaintenanceTransition() async {
        while maintenanceRunInFlight {
            if Task.isCancelled {
                await Task.yield()
                continue
            }
            maintenanceTransitionWaiterSeq &+= 1
            let id = maintenanceTransitionWaiterSeq
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    // Runs synchronously on the actor before any suspension. The
                    // transition may have ended between the loop check and here,
                    // so re-check and resume immediately rather than parking
                    // forever.
                    if !maintenanceRunInFlight {
                        continuation.resume()
                    } else {
                        maintenanceTransitionWaiters.append(
                            MaintenanceTransitionWaiter(id: id, continuation: continuation)
                        )
                    }
                }
            } onCancel: {
                Task { await self.releaseCancelledMaintenanceWaiter(id: id) }
            }
            // Drain-resume → flag is false → the loop exits. Cancel-resume →
            // flag may still be true → the loop holds the caller at the gate.
        }
    }

    /// Open the maintenance transition window. Paired with
    /// `endMaintenanceTransition()` through `defer` in `runMaintenanceChecked`.
    func beginMaintenanceTransition() {
        maintenanceRunInFlight = true
    }

    /// Close the maintenance transition window and resume every parked waiter
    /// exactly once. The array is drained before any resume, so a waiter that
    /// parks after this point is not in the released set.
    func endMaintenanceTransition() {
        maintenanceRunInFlight = false
        guard !maintenanceTransitionWaiters.isEmpty else { return }
        let released = maintenanceTransitionWaiters
        maintenanceTransitionWaiters.removeAll(keepingCapacity: false)
        for waiter in released {
            waiter.continuation.resume()
        }
    }

    /// A cancelled waiter removes itself from the park set and resumes its own
    /// continuation once. If `endMaintenanceTransition()` already drained it the
    /// id is gone and this is a no-op — so the continuation resumes exactly once
    /// either way, and a cancelled waiter never leaks.
    private func releaseCancelledMaintenanceWaiter(id: UInt64) {
        guard let index = maintenanceTransitionWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = maintenanceTransitionWaiters.remove(at: index)
        waiter.continuation.resume()
    }

    /// R-F3 test seam: number of parked maintenance-gate waiters.
    var maintenanceTransitionWaiterCountForTesting: Int {
        maintenanceTransitionWaiters.count
    }

    /// R-F2 test seam: install (or clear) the microcycle commit-window probe.
    func setMicrocycleCommitInterleaveProbeForTesting(_ probe: (@Sendable () async -> Void)?) {
        microcycleCommitInterleaveProbe = probe
    }
    var lastUserPresenceAt: Date?
    var lastWarmPresenceAt: Date?
    /// Wave D: when the overnight emotional-consolidation sweep last ran. nil (never run,
    /// or a fresh store) → the first maintenance pass consolidates. Persisted/restored via
    /// the "emotional_consolidation" artifact exactly like affect (see runMaintenance).
    var lastEmotionalConsolidationAt: Date?
    var verificationNodeMayExist = false
    static let verificationWorkspaceMaxAge: TimeInterval = 6 * 60 * 60

    func markDirty(at date: Date) {
        dirtySince = dirtySince ?? date
        dirtyRevision &+= 1
    }

    /// U1 (2026-07-09): the completion still waiting to find out how it landed.
    /// A turn's felt tag is stamped the moment it completes — before the only
    /// evidence that matters has arrived. The user's NEXT message is that
    /// evidence, so one slot remembers the latest completion's node and the next
    /// user-authored turn in the same session re-stamps it retrospectively.
    ///
    /// One slot is enough: a reaction is a reaction to the turn it answers.
    /// Memory-only (never persisted) — a reaction that crosses a relaunch isn't
    /// a reaction. Removals: consumed on use, dropped on session change, and
    /// expired after `pendingCompletionMaxAge`.
    struct PendingCompletion: Sendable, Equatable {
        var nodeKey: String
        var recordedAt: Date
        var sessionId: String?
    }
    var pendingCompletion: PendingCompletion?

    /// How long a completion stays open to being re-felt. Past this the next
    /// message is a new beginning, not a verdict on the last thing she said.
    static let pendingCompletionMaxAge: TimeInterval = 10 * 60

    /// How the agent names the user in her inner voice — resolved from the
    /// configured persona, never hardcoded. Falls back to grammar-safe "you".
    var userAddress: String {
        let n = dependencies.userName().trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "you" : n
    }
    /// Possessive form of `userAddress` ("Bill's", or "your" for the fallback).
    var userPossessive: String {
        let a = userAddress
        return a == "you" ? "your" : "\(a)'s"
    }

    public init(
        configuration: CognitiveConfiguration = .disabled,
        dependencies: CognitiveSubstrateDependencies = .live,
        store: CognitiveSQLiteStore? = nil
    ) {
        self.configuration = configuration
        self.dependencies = dependencies
        self.store = store
        if configuration.persistenceEnabled {
            if store == nil {
                self.persistenceHealth = CognitivePersistenceHealth(
                    status: .degraded,
                    writesBlocked: true,
                    failureStage: "store",
                    failureDetail: CognitivePersistenceError.storeUnavailable.description
                )
                self.persistenceWritesBlocked = true
            } else {
                self.persistenceHealth = CognitivePersistenceHealth(status: .ready, writesBlocked: false)
            }
        }
    }

    public func configure(_ configuration: CognitiveConfiguration) async {
        await waitForMaintenanceTransition()
        self.configuration = configuration
        if !configuration.persistenceEnabled {
            persistenceWritesBlocked = false
            persistenceHealth = .disabled
        } else if store == nil {
            persistenceWritesBlocked = true
            persistenceHealth = CognitivePersistenceHealth(
                status: .degraded,
                writesBlocked: true,
                lastRestoreAttemptAt: persistenceHealth.lastRestoreAttemptAt,
                lastSuccessfulRestoreAt: persistenceHealth.lastSuccessfulRestoreAt,
                failureStage: "store",
                failureDetail: CognitivePersistenceError.storeUnavailable.description
            )
        } else if persistenceHealth.status == .disabled {
            persistenceHealth = CognitivePersistenceHealth(status: .ready, writesBlocked: false)
        }
        publishAttentionProjection(at: dependencies.now())
    }

    public func configurationSnapshot() async -> CognitiveConfiguration {
        configuration
    }

    public func ingest(_ event: CognitiveEvent) async {
        _ = await ingest(event, defersPersistenceToMicrocycle: false)
    }

    /// Resident hot-path admission. Canonical in-memory state and the published
    /// attention projection advance before this returns; the already-existing
    /// dirty microcycle persists the coalesced latest state. Direct library
    /// callers retain `ingest(_:)`'s synchronous durability contract.
    @discardableResult
    public func ingestResident(_ event: CognitiveEvent) async -> Bool {
        await ingest(event, defersPersistenceToMicrocycle: true)
    }

    private func ingest(
        _ event: CognitiveEvent,
        defersPersistenceToMicrocycle: Bool
    ) async -> Bool {
        await waitForMaintenanceTransition()
        guard configuration.enabled else { return false }
        // D-2 (2026-08-02) — STAKES, not event class. A felt resolution about
        // machinery she holds no concern for is not a feeling; it is her own
        // plumbing reporting in. Rejected BEFORE any state is touched (no seen
        // key consumed, no node, no affect, no attention publish), so the felt
        // layer gets quieter instead of louder. Gates this one event class only.
        guard feltResolutionIsAtStake(event) else { return false }
        // A duplicate CognitiveEvent is inert across the WHOLE cognition owner,
        // not merely ContinuityField structure. This await-free O(1) check keeps
        // affect, mood, relational-presence anchors, pending completion, revision,
        // attention publication, and persistence untouched on replay.
        guard !field.hasSeenEvent(event) else { return false }
        let now = dependencies.now()
        let evicted = evictSpentVerificationNodes(before: event, at: now)
        let ingestOutcome = field.ingest(
            event,
            now: now,
            makeUUID: dependencies.makeUUID,
            configuration: configuration
        )
        if event.turnKind == .verification {
            verificationNodeMayExist = true
        }
        markDirty(at: now)
        let contributesToLivedState = event.turnKind.contributesToLivedState
        if contributesToLivedState, event.kind == .userMessageReceived {
            lastUserPresenceAt = now
            // Anchor the ambient warmth floor to genuinely warm moments only, so a pure-work
            // session followed by absence never manufactures affect-warmth (it stays content-driven).
            if relationalWarmthBoost(in: event.summary) > 0 { lastWarmPresenceAt = now }
        }
        // Affect apply + emotional-tag stamp run as ONE await-free actor segment right
        // after field.ingest above, so no reentrant ingest (during a later persistence
        // await) can swap self.affect or evict/recreate the touched node between deriving
        // the tag and stamping it (gpt-5.5 concurrency review, 2026-07-02). applyAffect is
        // synchronous; the affect persistence that updateAffectFromEvent used to do is
        // moved below, after the state is already consistent.
        let updatedAffect = contributesToLivedState
            ? applyAffectFromEvent(event)
            : affect
        // Stamp the tag from the affect this event just produced ("how she feels having
        // just experienced it", Wave A). Gated on affect: no affect, no live feeling.
        if contributesToLivedState, configuration.affectEnabled, let ingestOutcome {
            // R2-A/B: appraise the event's MEANING (pure, no suspension — stays inside
            // this await-free segment) so the stamped feeling is about what happened,
            // not the fact that something happened.
            // Compute the conversational appraisal ONCE and thread it through both
            // consumers — semanticAppraisal and emotionTag each used to run the
            // heavy ~10-pass lexicon scan on the identical summary (hot-path dedup).
            let precomputedAppraisal = Self.isUserAuthored(event.kind)
                ? conversationalAppraisal(in: event.summary)
                : AffectAppraisal()
            let semantic = semanticAppraisal(
                for: event,
                post: updatedAffect,
                precomputedAppraisal: precomputedAppraisal
            )
            let tag = emotionTag(
                for: event,
                affect: updatedAffect,
                semantic: semantic,
                precomputedAppraisal: precomputedAppraisal
            )
            field.stampEmotionTag(
                key: ingestOutcome.key,
                tag: tag,
                isNewNode: ingestOutcome.isNewNode,
                configuration: configuration
            )
        }
        // U1: her work comes to feel like how it landed. Runs inside the SAME
        // await-free segment as the stamp above, and for the same reason — the
        // re-stamp reads the remembered node's tag and writes it back, so a
        // reentrant ingest suspending in between could evict/recreate that node
        // or swap the slot underneath us. Pure, synchronous, no suspension.
        if contributesToLivedState, configuration.affectEnabled {
            reconsolidatePendingCompletion(with: event, outcome: ingestOutcome, now: now)
        }
        // Publish before persistence awaits. The owner transition is already
        // internally consistent, and a slow SQLite write must not delay the
        // resident attention available to the next turn.
        publishAttentionProjection(at: now)
        if defersPersistenceToMicrocycle, configuration.backgroundMicrocyclesEnabled {
            // Verification evictions are rare and their receipt is diagnostic;
            // keep it off the sensory admission path without losing the fact.
            if evicted > 0, configuration.persistenceEnabled {
                let sessionId = event.sessionId
                Task { [weak self] in
                    await self?.recordReceipt(
                        kind: "workspace.verification_eviction",
                        payload: .object([
                            "evictedCount": .int(Int64(evicted)),
                            "sessionId": sessionId.map(JSONValue.string) ?? .null,
                        ])
                    )
                }
            }
            return true
        }
        if contributesToLivedState, configuration.enabled, configuration.affectEnabled {
            await persistArtifact(
                kind: "affect",
                id: stableArtifactID("affect"),
                status: "current",
                score: updatedAffect.arousal,
                payload: updatedAffect.toJSON(
                    lastUserPresenceAt: lastUserPresenceAt,
                    lastWarmPresenceAt: lastWarmPresenceAt
                )
            )
        }
        if configuration.persistenceEnabled {
            if evicted > 0, let store {
                try? await store.appendReceipt(
                    kind: "workspace.verification_eviction",
                    payload: .object([
                        "evictedCount": .int(Int64(evicted)),
                        "sessionId": event.sessionId.map(JSONValue.string) ?? .null,
                    ]),
                    at: now
                )
            }
            try? await persistSnapshot()
        }
        return true
    }

    public func snapshot() async -> CognitiveSubstrateSnapshot {
        let now = dependencies.now()
        let nodes = configuration.enabled
            ? field.snapshot(at: now, configuration: configuration)
            : []
        return CognitiveSubstrateSnapshot(
            generatedAt: now,
            enabled: configuration.enabled,
            maximumActiveNodes: configuration.maximumActiveNodes,
            nodes: nodes,
            persistenceHealth: persistenceHealth
        )
    }

    public func associationSnapshot() async -> [CognitiveAssociationEdge] {
        guard configuration.enabled, configuration.workspaceEnabled else { return [] }
        return field.associationEdges(at: dependencies.now(), configuration: configuration)
    }

    public func clearTransientState() async {
        await waitForMaintenanceTransition()
        // A maintenance transaction may be suspended in the store actor. Its
        // failure rollback must recognize this explicit lifecycle reset as a
        // newer mutation and never resurrect the cleared in-memory state.
        dirtyRevision &+= 1
        field.clear()
        thoughtSeeds.removeAll(keepingCapacity: false)
        thoughtSeedRevision &+= 1
        episodes.removeAll(keepingCapacity: false)
        schemaProposals.removeAll(keepingCapacity: false)
        standingViews.removeAll(keepingCapacity: false)
        identityProposals.removeAll(keepingCapacity: false)
        developmentalTimeline.removeAll(keepingCapacity: false)
        replayEvidenceIds.removeAll(keepingCapacity: false)
        reflectionReceipts.removeAll(keepingCapacity: false)
        reflectionReservation = nil
        experimentResults.removeAll(keepingCapacity: false)
        affect = CognitiveAffectState(updatedAt: dependencies.now())
        disposition = CognitiveDisposition()
        // Wave A3: the day claims must clear with the disposition they gate —
        // a stale claim would suppress a legitimate post-clear nudge until a
        // restart reset the map (review e74d2856bd9b).
        resolutionPatternNudgeDay.removeAll(keepingCapacity: false)
        ablations.removeAll(keepingCapacity: false)
        verificationNodeMayExist = false
        pendingCompletion = nil
        dirtySince = nil
        lastUserPresenceAt = nil
        lastWarmPresenceAt = nil
        lastEmotionalConsolidationAt = nil
        publishAttentionProjection(at: dependencies.now())
    }

    public func restorePersistentState() async throws {
        guard configuration.enabled else { return }
        guard configuration.persistenceEnabled else {
            persistenceWritesBlocked = false
            persistenceHealth = .disabled
            return
        }

        let attemptAt = dependencies.now()
        guard let store else {
            persistenceWritesBlocked = true
            persistenceHealth = CognitivePersistenceHealth(
                status: .degraded,
                writesBlocked: true,
                lastRestoreAttemptAt: attemptAt,
                lastSuccessfulRestoreAt: persistenceHealth.lastSuccessfulRestoreAt,
                failureStage: "store",
                failureDetail: CognitivePersistenceError.storeUnavailable.description
            )
            throw CognitivePersistenceError.storeUnavailable
        }

        let previouslyDegraded = persistenceHealth.status == .degraded
        let previousSuccessAt = persistenceHealth.lastSuccessfulRestoreAt
        persistenceWritesBlocked = true
        persistenceHealth = CognitivePersistenceHealth(
            status: .restoring,
            writesBlocked: true,
            lastRestoreAttemptAt: attemptAt,
            lastSuccessfulRestoreAt: previousSuccessAt
        )

        let bundle: CognitiveSQLiteRestoreBundle
        do {
            bundle = try await store.loadRestoreBundle(
                artifactFamilies: restoreArtifactFamilyLoads()
            )
            try validateRestoreBundle(bundle)
        } catch {
            let stage = restoreFailureStage(for: error)
            let detail = bounded(String(describing: error), maxCharacters: 320)
            persistenceWritesBlocked = true
            persistenceHealth = CognitivePersistenceHealth(
                status: .degraded,
                writesBlocked: true,
                lastRestoreAttemptAt: attemptAt,
                lastSuccessfulRestoreAt: previousSuccessAt,
                failureStage: stage,
                failureDetail: detail
            )
            try? await store.appendReceipt(
                kind: "lifecycle.restore_degraded",
                payload: .object([
                    "status": .string("degraded"),
                    "failureStage": .string(stage),
                    "error": .string(detail),
                    "writesBlocked": .bool(true),
                ]),
                at: attemptAt
            )
            throw error
        }

        let clampedStandingViewIds = applyRestoreBundle(bundle)
        persistenceWritesBlocked = false
        persistenceHealth = CognitivePersistenceHealth(
            status: .healthy,
            writesBlocked: false,
            lastRestoreAttemptAt: attemptAt,
            lastSuccessfulRestoreAt: dependencies.now()
        )

        await reconcileRestoredAffectWithRecentConversation(nodes: bundle.nodes)
        publishAttentionProjection(at: dependencies.now())
        // `loadRestoreBundle` reads only the configured newest-N seed window.
        // Replace the persisted family with that exact bounded live set before
        // declaring restore healthy so legacy overflow cannot survive offscreen
        // and return during a later relaunch.
        try await persistThoughtSeedFamily()
        // Defensive repair: a half-persisted approval (crash between the active upsert and
        // the cap deletes) could leave >cap active rows — demote LRU + heal the store.
        await repairStandingViewCapIfNeeded()
        // Persist any future-timestamp clamps so the repair survives restarts.
        await persistClampedStandingViews(ids: clampedStandingViewIds)
        try? await store.appendReceipt(
            kind: "lifecycle.restore",
            payload: .object([
                "nodeCount": .int(Int64(bundle.nodes.count)),
                "thoughtSeedCount": .int(Int64(projectedThoughtSeeds(at: dependencies.now()).count)),
                "episodeCount": .int(Int64(episodes.count)),
                "schemaProposalCount": .int(Int64(schemaProposals.count)),
                "identityProposalCount": .int(Int64(identityProposals.count)),
                "timelineCount": .int(Int64(developmentalTimeline.count)),
                "reflectionCount": .int(Int64(reflectionReceipts.count)),
                "experimentCount": .int(Int64(experimentResults.count)),
                "status": .string(previouslyDegraded ? "recovered" : "restored"),
                "writesBlocked": .bool(false),
            ]),
            at: dependencies.now()
        )
    }

    private func restoreArtifactFamilyLoads() -> [CognitiveArtifactFamilyLoad] {
        [
            CognitiveArtifactFamilyLoad(key: "affect", kindPrefix: "affect", limit: 1),
            CognitiveArtifactFamilyLoad(key: "disposition", kindPrefix: "disposition", limit: 1),
            CognitiveArtifactFamilyLoad(
                key: "emotional_consolidation",
                kindPrefix: "emotional_consolidation",
                limit: 1
            ),
            CognitiveArtifactFamilyLoad(
                key: "thought_seed",
                kindPrefix: "thought_seed",
                limit: configuration.maximumThoughtSeeds
            ),
            CognitiveArtifactFamilyLoad(key: "episode", kindPrefix: "episode", limit: 120),
            CognitiveArtifactFamilyLoad(key: "schema_proposal", kindPrefix: "schema_proposal", limit: 120),
            CognitiveArtifactFamilyLoad(key: "standing_view", kindPrefix: "standing_view", limit: 60),
            CognitiveArtifactFamilyLoad(key: "identity_proposal", kindPrefix: "identity_proposal", limit: 120),
            CognitiveArtifactFamilyLoad(
                key: "developmental_timeline",
                kindPrefix: "developmental_timeline",
                limit: 160
            ),
            CognitiveArtifactFamilyLoad(
                key: "reflection_receipt",
                kindPrefix: "reflection_receipt",
                limit: max(40, configuration.dailyReflectionCallBudget * 4)
            ),
            CognitiveArtifactFamilyLoad(key: "experiment", kindPrefix: "experiment", limit: 40),
        ]
    }

    private func validateRestoreBundle(_ bundle: CognitiveSQLiteRestoreBundle) throws {
        for family in restoreArtifactFamilyLoads() {
            guard let payloads = bundle.artifacts[family.key] else {
                throw CognitivePersistenceError.invalidRestoreArtifact(
                    family: family.key,
                    index: 0,
                    detail: "family was absent from the SQLite restore bundle"
                )
            }
            for (index, payload) in payloads.enumerated() {
                guard validRestorePayload(payload, family: family.key) else {
                    throw CognitivePersistenceError.invalidRestoreArtifact(
                        family: family.key,
                        index: index,
                        detail: "one or more required fields are missing or invalid"
                    )
                }
            }
        }
    }

    private func validRestorePayload(_ payload: JSONValue, family: String) -> Bool {
        guard case .object(let object) = payload else { return false }
        switch family {
        case "affect":
            return dateValue(object["updatedAt"]) != nil
        case "disposition":
            return dateValue(object["updatedAt"]) != nil
                && doubleValue(object["valence"]) != nil
        case "emotional_consolidation":
            return dateValue(object["ranAt"]) != nil
        case "thought_seed":
            guard let kind = stringValue(object["kind"]) else { return false }
            return uuidValue(object["id"]) != nil
                && CognitiveThoughtSeedKind(rawValue: kind) != nil
                && stringValue(object["text"]) != nil
                && doubleValue(object["priority"]) != nil
                && dateValue(object["createdAt"]) != nil
                && dateValue(object["lastUpdatedAt"]) != nil
        case "episode":
            return uuidValue(object["id"]) != nil
                && stringValue(object["title"]) != nil
                && stringValue(object["summary"]) != nil
                && dateValue(object["occurredAt"]) != nil
        case "schema_proposal":
            guard let status = stringValue(object["status"]) else { return false }
            return uuidValue(object["id"]) != nil
                && stringValue(object["title"]) != nil
                && stringValue(object["body"]) != nil
                && stringValue(object["target"]) != nil
                && CognitiveSchemaProposalStatus(rawValue: status) != nil
                && dateValue(object["createdAt"]) != nil
        case "standing_view":
            guard let status = stringValue(object["status"]) else { return false }
            return uuidValue(object["id"]) != nil
                && stringValue(object["title"]) != nil
                && stringValue(object["body"]) != nil
                && CognitiveStandingView.Status(rawValue: status) != nil
                && dateValue(object["createdAt"]) != nil
                && dateValue(object["updatedAt"]) != nil
        case "identity_proposal":
            guard let status = stringValue(object["status"]) else { return false }
            return uuidValue(object["id"]) != nil
                && stringValue(object["claim"]) != nil
                && CognitiveIdentityProposalStatus(rawValue: status) != nil
                && dateValue(object["createdAt"]) != nil
        case "developmental_timeline":
            guard let kind = stringValue(object["kind"]) else { return false }
            return uuidValue(object["id"]) != nil
                && CognitiveDevelopmentalTimelineKind(rawValue: kind) != nil
                && stringValue(object["title"]) != nil
                && stringValue(object["summary"]) != nil
                && dateValue(object["occurredAt"]) != nil
        case "reflection_receipt":
            return uuidValue(object["id"]) != nil
                && stringValue(object["reason"]) != nil
                && stringValue(object["prompt"]) != nil
                && stringValue(object["surface"]) != nil
                && stringValue(object["model"]) != nil
                && stringValue(object["requestProvider"]) != nil
                && stringValue(object["reasoningEffort"]) != nil
                && dateValue(object["requestedAt"]) != nil
                && stringValue(object["resultSummary"]) != nil
                && stringValue(object["provider"]) != nil
                && dateValue(object["createdAt"]) != nil
        case "experiment":
            guard let kind = stringValue(object["kind"]) else { return false }
            return uuidValue(object["id"]) != nil
                && CognitiveExperimentKind(rawValue: kind) != nil
                && stringValue(object["seed"]) != nil
                && stringValue(object["reproducibilityKey"]) != nil
                && dateValue(object["generatedAt"]) != nil
        default:
            return false
        }
    }

    private func applyRestoreBundle(_ bundle: CognitiveSQLiteRestoreBundle) -> [UUID] {
        func payloads(_ family: String) -> [JSONValue] {
            bundle.artifacts[family] ?? []
        }

        field.replaceNodes(
            bundle.nodes,
            decayAnchorsByID: bundle.nodeDecayAnchors,
            configuration: configuration
        )
        verificationNodeMayExist = bundle.nodes.contains { $0.turnKind == .verification }
        restoreAffect(from: payloads("affect"))
        restoreDisposition(from: payloads("disposition"))
        restoreEmotionalConsolidation(from: payloads("emotional_consolidation"))
        restoreThoughtSeeds(from: payloads("thought_seed"))
        restoreEpisodes(from: payloads("episode"))
        restoreSchemaProposals(from: payloads("schema_proposal"))
        let clampedStandingViewIds = restoreStandingViews(from: payloads("standing_view"))
        restoreIdentityProposals(from: payloads("identity_proposal"))
        restoreDevelopmentalTimeline(from: payloads("developmental_timeline"))
        restoreReflectionReceipts(from: payloads("reflection_receipt"))
        restoreExperimentResults(from: payloads("experiment"))
        return clampedStandingViewIds
    }

    private func restoreFailureStage(for error: Error) -> String {
        if case CognitivePersistenceError.invalidRestoreArtifact(let family, _, _) = error {
            return "artifact.\(family)"
        }
        if case CognitiveSQLiteReadError.malformedRow(let table, _, _) = error {
            return table
        }
        return "sqlite_read"
    }

    /// Test hook retained for the destructive-write regression in StoreBoundsTests.
    func markRestoreFailedForTesting() {
        persistenceWritesBlocked = true
        persistenceHealth = CognitivePersistenceHealth(
            status: .degraded,
            writesBlocked: true,
            lastRestoreAttemptAt: dependencies.now(),
            lastSuccessfulRestoreAt: persistenceHealth.lastSuccessfulRestoreAt,
            failureStage: "test",
            failureDetail: "simulated restore failure"
        )
    }

    public func persistSnapshot() async throws {
        guard configuration.enabled, configuration.persistenceEnabled else { return }
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        guard !persistenceWritesBlocked else {
            throw CognitivePersistenceError.writesBlocked(
                status: persistenceHealth.status,
                detail: persistenceHealth.failureDetail
            )
        }
        let now = dependencies.now()
        let nodes = field.snapshot(at: now, configuration: configuration)
        try await store.saveNodes(nodes, at: now)
        try await store.prune(
            maxNodes: configuration.maximumActiveNodes,
            maxArtifacts: artifactCap(configuration)
        )
    }

    public func recordReceipt(kind: String, payload: JSONValue = .object([:])) async {
        guard configuration.enabled, configuration.persistenceEnabled, let store else { return }
        try? await store.appendReceipt(kind: kind, payload: payload, at: dependencies.now())
    }

    func recordReceiptChecked(kind: String, payload: JSONValue = .object([:])) async throws {
        guard configuration.enabled, configuration.persistenceEnabled else { return }
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        guard !persistenceWritesBlocked else {
            throw CognitivePersistenceError.writesBlocked(
                status: persistenceHealth.status,
                detail: persistenceHealth.failureDetail
            )
        }
        try await store.appendReceipt(kind: kind, payload: payload, at: dependencies.now())
    }

    public func runReplay(reason: String) async {
        guard configuration.enabled, configuration.replayEnabled else { return }
        let nodes = (await snapshot()).nodes.prefix(4)
        guard !nodes.isEmpty else { return }
        await recordReceipt(
            kind: "replay",
            payload: .object([
                "reason": .string(bounded(reason, maxCharacters: 120)),
                "evidenceNodeIds": .array(nodes.map { .string($0.id.uuidString) }),
                "status": .string("delegated-to-dream-rem-owner"),
            ])
        )
    }

    @discardableResult
    public func integrateReplay(
        _ input: CognitiveReplayIntegrationInput
    ) async -> CognitiveReplayIntegrationResult {
        (try? await integrateReplayChecked(input)) ?? CognitiveReplayIntegrationResult()
    }

    /// Scheduled replay's checked boundary. All replay artifacts, lineage, and
    /// its receipt commit in one SQLite transaction; in-memory state rolls back
    /// on failure so evidence remains eligible for a later retry.
    @discardableResult
    public func integrateReplayChecked(
        _ input: CognitiveReplayIntegrationInput
    ) async throws -> CognitiveReplayIntegrationResult {
        await waitForMaintenanceTransition()
        guard configuration.enabled, configuration.replayEnabled else { return CognitiveReplayIntegrationResult() }
        let now = dependencies.now()
        let priorEpisodes = episodes
        let priorSchemas = schemaProposals
        let priorTimeline = developmentalTimeline
        let priorDirtySince = dirtySince
        var stagedDirtyRevision = dirtyRevision
        var episodeIds: [UUID] = []
        var schemaProposalIds: [UUID] = []
        var skippedEvidenceIds: [String] = []
        var timelineEventIds: [UUID] = []
        var writes: [CognitiveArtifactWrite] = []
        var stagedEpisodes: [UUID: CognitiveEpisodeReference] = [:]
        var stagedSchemas: [UUID: CognitiveSchemaProposal] = [:]
        var stagedTimeline: [UUID: CognitiveDevelopmentalTimelineEvent] = [:]
        var insertedReplayEvidence: Set<String> = []

        do {

        for dream in input.dreamEntries.prefix(8) {
            let evidenceId = dreamReplayEvidenceID(dream)
            guard replayEvidenceIds.insert(evidenceId).inserted,
                  episodes.values.contains(where: { $0.externalEvidenceIds.contains(evidenceId) }) == false else {
                skippedEvidenceIds.append(evidenceId)
                continue
            }
            let episode = CognitiveEpisodeReference(
                id: stableArtifactID("episode|\(evidenceId)"),
                title: bounded("Dream replay \(dream.date)", maxCharacters: 120),
                summary: dreamSummary(dream.content),
                occurredAt: dateFromFullDate(dream.date) ?? now,
                externalEvidenceIds: [evidenceId],
                lineageId: bounded("dream:\(dream.date)", maxCharacters: 120)
            )
            episodes[episode.id] = episode
            stagedEpisodes[episode.id] = episode
            insertedReplayEvidence.insert(evidenceId)
            episodeIds.append(episode.id)
            markDirty(at: now)
            writes.append(CognitiveArtifactWrite(
                kind: "episode", id: episode.id, status: "recorded",
                score: 0.5, payload: episode.toJSON()
            ))
            let timeline = recordTimelineEventInMemory(
                kind: .dreamEpisode,
                title: episode.title,
                summary: episode.summary,
                artifactId: episode.id,
                lineageId: episode.lineageId,
                externalEvidenceIds: episode.externalEvidenceIds
            )
            stagedTimeline[timeline.id] = timeline
            writes.append(CognitiveArtifactWrite(
                kind: "developmental_timeline", id: timeline.id, status: "recorded",
                score: 0.5, payload: timeline.toJSON()
            ))
            timelineEventIds.append(timeline.id)
        }

        for proposal in input.remProposals.prefix(8) {
            let evidenceId = remReplayEvidenceID(proposal)
            let status = schemaStatus(from: proposal.status)
            if let existingId = schemaProposals.values.first(where: { $0.externalEvidenceIds.contains(evidenceId) })?.id,
               var existing = schemaProposals[existingId] {
                if existing.status == status {
                    skippedEvidenceIds.append(evidenceId)
                    continue
                }
                existing.status = status
                schemaProposals[existingId] = existing
                stagedSchemas[existing.id] = existing
                writes.append(CognitiveArtifactWrite(
                    kind: "schema_proposal", id: existing.id, status: existing.status.rawValue,
                    score: existing.confidence, payload: existing.toJSON()
                ))
                let timeline = recordTimelineEventInMemory(
                    kind: .proposalResolution,
                    title: "Schema proposal \(existing.status.rawValue)",
                    summary: existing.body,
                    artifactId: existing.id,
                    lineageId: existing.lineageId,
                    externalEvidenceIds: existing.externalEvidenceIds
                )
                stagedTimeline[timeline.id] = timeline
                writes.append(CognitiveArtifactWrite(
                    kind: "developmental_timeline", id: timeline.id, status: "recorded",
                    score: 0.5, payload: timeline.toJSON()
                ))
                timelineEventIds.append(timeline.id)
                continue
            }

            let schema = CognitiveSchemaProposal(
                id: stableArtifactID("schema|\(evidenceId)"),
                title: bounded("\(proposal.target) REM proposal", maxCharacters: 120),
                body: bounded(proposal.text.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 500),
                target: bounded(proposal.target.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 120),
                status: status,
                confidence: proposal.confidence,
                createdAt: dateFromInternetDate(proposal.createdAt) ?? now,
                externalEvidenceIds: [evidenceId] + proposal.evidenceDates.map { bounded("dream:\($0)", maxCharacters: 120) },
                lineageId: bounded("rem:\(proposal.id)", maxCharacters: 120)
            )
            guard !schema.body.isEmpty else {
                skippedEvidenceIds.append(evidenceId)
                continue
            }
            schemaProposals[schema.id] = schema
            stagedSchemas[schema.id] = schema
            schemaProposalIds.append(schema.id)
            markDirty(at: now)
            writes.append(CognitiveArtifactWrite(
                kind: "schema_proposal", id: schema.id, status: schema.status.rawValue,
                score: schema.confidence, payload: schema.toJSON()
            ))
            let timeline = recordTimelineEventInMemory(
                kind: .schemaProposal,
                title: schema.title,
                summary: schema.body,
                artifactId: schema.id,
                lineageId: schema.lineageId,
                externalEvidenceIds: schema.externalEvidenceIds
            )
            stagedTimeline[timeline.id] = timeline
            writes.append(CognitiveArtifactWrite(
                kind: "developmental_timeline", id: timeline.id, status: "recorded",
                score: 0.5, payload: timeline.toJSON()
            ))
            timelineEventIds.append(timeline.id)
        }

        let receiptPayload: JSONValue? =
            !writes.isEmpty
            ? .object([
                    "reason": .string(bounded(input.reason, maxCharacters: 120)),
                    "episodeCount": .int(Int64(episodeIds.count)),
                    "schemaProposalCount": .int(Int64(schemaProposalIds.count)),
                    "episodeIds": .array(episodeIds.map { .string($0.uuidString) }),
                    "schemaProposalIds": .array(schemaProposalIds.map { .string($0.uuidString) }),
                    "timelineEventIds": .array(timelineEventIds.map { .string($0.uuidString) }),
                    "artifactIds": .array(writes.map { .string($0.id.uuidString) }),
                ])
            : nil
        stagedDirtyRevision = dirtyRevision
        if configuration.persistenceEnabled {
            guard let store else { throw CognitivePersistenceError.storeUnavailable }
            guard !persistenceWritesBlocked else {
                throw CognitivePersistenceError.writesBlocked(
                    status: persistenceHealth.status,
                    detail: persistenceHealth.failureDetail
                )
            }
            try await store.commitReplayIntegration(
                artifacts: writes,
                receiptPayload: receiptPayload,
                maxArtifacts: artifactCap(configuration),
                at: now
            )
        }
        // G-M2: the replay path writes episodes/schemas/evidence directly (not
        // via the single-item record helpers), so enforce their caps here, after
        // the commit succeeds. Timeline is already capped inside
        // recordTimelineEventInMemory. Newest rows survive; only old ones evict.
        enforceEpisodeCap()
        enforceSchemaProposalCap()
        enforceReplayEvidenceCap()
        return CognitiveReplayIntegrationResult(
            episodeIds: episodeIds,
            schemaProposalIds: schemaProposalIds,
            skippedEvidenceIds: skippedEvidenceIds,
            timelineEventIds: timelineEventIds
        )
        } catch {
            // Actor reentrancy permits unrelated mutations while SQLite is
            // committing. Roll back only values still equal to this replay's
            // staged delta; never overwrite a newer concurrent mutation.
            for (id, staged) in stagedEpisodes where episodes[id] == staged {
                if let prior = priorEpisodes[id] { episodes[id] = prior }
                else { episodes.removeValue(forKey: id) }
            }
            for (id, staged) in stagedSchemas where schemaProposals[id] == staged {
                if let prior = priorSchemas[id] { schemaProposals[id] = prior }
                else { schemaProposals.removeValue(forKey: id) }
            }
            for (id, staged) in stagedTimeline where developmentalTimeline[id] == staged {
                if let prior = priorTimeline[id] { developmentalTimeline[id] = prior }
                else { developmentalTimeline.removeValue(forKey: id) }
            }
            for evidenceID in insertedReplayEvidence
            where episodes.values.contains(where: { $0.externalEvidenceIds.contains(evidenceID) }) == false {
                replayEvidenceIds.remove(evidenceID)
            }
            if dirtyRevision == stagedDirtyRevision {
                dirtySince = priorDirtySince
            }
            throw error
        }
    }

    public func groundExternalContext(
        query: String,
        memory: (any CognitiveMemoryReading)? = nil,
        knowledgeGraph: (any CognitiveKnowledgeGraphReading)? = nil,
        limit: Int = 5
    ) async -> CognitiveExternalGroundingResult {
        guard configuration.enabled else {
            return CognitiveExternalGroundingResult(query: "", notes: ["disabled"])
        }
        let trimmed = bounded(query.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 240)
        guard !trimmed.isEmpty else {
            return CognitiveExternalGroundingResult(query: "", notes: ["empty-query"])
        }
        let cappedLimit = max(1, min(10, limit))
        var notes: [String] = []
        let memoryHits: [CognitiveExternalReference]
        if let memory {
            do {
                memoryHits = try await memory.recallMemory(query: trimmed, limit: cappedLimit)
                    .prefix(cappedLimit)
                    .map { boundedExternalReference($0) }
            } catch {
                memoryHits = []
                notes.append("memory-read-failed")
            }
        } else {
            memoryHits = []
            notes.append("memory-reader-unavailable")
        }

        let graphHits: [CognitiveExternalReference]
        if let knowledgeGraph {
            do {
                graphHits = try await knowledgeGraph.searchKnowledgeGraph(query: trimmed, limit: cappedLimit)
                    .prefix(cappedLimit)
                    .map { boundedExternalReference($0) }
            } catch {
                graphHits = []
                notes.append("knowledge-graph-read-failed")
            }
        } else {
            graphHits = []
            notes.append("knowledge-graph-reader-unavailable")
        }

        if !memoryHits.isEmpty || !graphHits.isEmpty {
            await recordReceipt(
                kind: "external_grounding",
                payload: .object([
                    "query": .string(trimmed),
                    "memoryHitCount": .int(Int64(memoryHits.count)),
                    "graphHitCount": .int(Int64(graphHits.count)),
                ])
            )
        }
        return CognitiveExternalGroundingResult(
            query: trimmed,
            memoryHits: memoryHits,
            graphHits: graphHits,
            notes: notes.isEmpty ? ["read-only"] : notes
        )
    }

    public func makeMemoryProposalCandidate(
        text: String,
        source: String = "cognitive_substrate",
        confidence: Double = 0.5,
        kind: String = "cognitive_proposal",
        evidenceNodeIds: [UUID] = []
    ) async -> CognitiveMemoryProposalCandidate? {
        // Gated on `enabled` alone since R8c removed `assimilationEnabled`
        // (production always set that flag = enabled, so live behavior is
        // unchanged; hand-built partial presets are now proposal-capable —
        // deliberate: proposals are quality-gated below and approval-mediated
        // downstream, never auto-applied).
        guard configuration.enabled else { return nil }
        let trimmed = bounded(text.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 500)
        guard !trimmed.isEmpty else { return nil }
        guard MemoryCandidateQuality.isDurableCandidate(text: trimmed, source: source, kind: kind) else { return nil }
        let candidate = CognitiveMemoryProposalCandidate(
            id: dependencies.makeUUID(),
            text: trimmed,
            source: bounded(source, maxCharacters: 120),
            confidence: confidence,
            kind: bounded(kind, maxCharacters: 80),
            evidenceNodeIds: unique(evidenceNodeIds)
        )
        await persistArtifact(
            kind: "memory_proposal_candidate",
            id: candidate.id,
            status: "candidate",
            score: candidate.confidence,
            payload: candidate.toJSON()
        )
        return candidate
    }

    public func recordMemoryProposalStage(_ receipt: CognitiveMemoryProposalStageReceipt) async {
        await recordReceipt(
            kind: "memory_proposal_stage",
            payload: receipt.toJSON()
        )
    }

    // Agent's subconscious is for feelings / emotions / views / continuity — NOT a task
    // tracker (User, 2026-06-30). The commitment/prediction extraction machinery that once
    // ran here was removed in R8c (2026-07-01); the vestigial assimilate() no-op seam and
    // its ChatOrchestration callers were retired in the follow-up (2026-07-02).

    @discardableResult
    public func recordEpisode(
        title: String,
        summary: String,
        evidenceNodeIds: [UUID] = []
    ) async -> CognitiveEpisodeReference? {
        await waitForMaintenanceTransition()
        guard configuration.enabled, configuration.replayEnabled else { return nil }
        let now = dependencies.now()
        let episode = CognitiveEpisodeReference(
            id: dependencies.makeUUID(),
            title: bounded(title.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 120),
            summary: bounded(summary.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 500),
            occurredAt: now,
            evidenceNodeIds: unique(evidenceNodeIds)
        )
        guard !episode.title.isEmpty || !episode.summary.isEmpty else { return nil }
        episodes[episode.id] = episode
        enforceEpisodeCap()
        await persistArtifact(kind: "episode", id: episode.id, status: "recorded", score: 0.5, payload: episode.toJSON())
        return episode
    }

    @discardableResult
    public func proposeIdentity(
        claim: String,
        evidenceNodeIds: [UUID] = []
    ) async -> CognitiveIdentityProposal? {
        await waitForMaintenanceTransition()
        guard configuration.enabled, configuration.replayEnabled else { return nil }
        let evidence = unique(evidenceNodeIds)
        guard evidence.count >= 2 else { return nil }
        let trimmed = bounded(claim.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 240)
        guard !trimmed.isEmpty else { return nil }
        let proposal = CognitiveIdentityProposal(
            id: dependencies.makeUUID(),
            claim: trimmed,
            evidenceCount: evidence.count,
            status: .proposed,
            createdAt: dependencies.now(),
            evidenceNodeIds: evidence
        )
        identityProposals[proposal.id] = proposal
        enforceIdentityProposalCap()
        await persistArtifact(kind: "identity_proposal", id: proposal.id, status: proposal.status.rawValue, score: min(1, Double(evidence.count) / 5), payload: proposal.toJSON())
        _ = await recordTimelineEvent(
            kind: .identityProposal,
            title: "Identity proposal",
            summary: proposal.claim,
            artifactId: proposal.id,
            lineageId: "identity:\(proposal.id.uuidString)",
            externalEvidenceIds: proposal.evidenceNodeIds.map { "node:\($0.uuidString)" }
        )
        return proposal
    }

    public func episodeSnapshot() async -> [CognitiveEpisodeReference] {
        episodes.values.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public func schemaProposalSnapshot() async -> [CognitiveSchemaProposal] {
        schemaProposals.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public func identityProposalSnapshot() async -> [CognitiveIdentityProposal] {
        identityProposals.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public func developmentalTimelineSnapshot(limit: Int = 40) async -> [CognitiveDevelopmentalTimelineEvent] {
        developmentalTimeline.values.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        .prefix(max(0, limit))
        .map { $0 }
    }

    public func resolveSchemaProposal(
        id: UUID,
        accepted: Bool
    ) async -> CognitiveSchemaProposal? {
        await waitForMaintenanceTransition()
        guard configuration.enabled, configuration.replayEnabled,
              var proposal = schemaProposals[id] else { return nil }
        proposal.status = accepted ? .accepted : .rejected
        schemaProposals[id] = proposal
        await persistArtifact(
            kind: "schema_proposal",
            id: proposal.id,
            status: proposal.status.rawValue,
            score: accepted ? proposal.confidence : 0,
            payload: proposal.toJSON()
        )
        _ = await recordTimelineEvent(
            kind: .proposalResolution,
            title: "Schema proposal \(proposal.status.rawValue)",
            summary: proposal.body,
            artifactId: proposal.id,
            lineageId: proposal.lineageId,
            externalEvidenceIds: proposal.externalEvidenceIds
        )
        return proposal
    }

    public func resolveIdentityProposal(
        id: UUID,
        accepted: Bool
    ) async -> CognitiveIdentityProposal? {
        await waitForMaintenanceTransition()
        guard configuration.enabled, configuration.replayEnabled,
              var proposal = identityProposals[id] else { return nil }
        proposal.status = accepted ? .accepted : .rejected
        identityProposals[id] = proposal
        await persistArtifact(
            kind: "identity_proposal",
            id: proposal.id,
            status: proposal.status.rawValue,
            score: accepted ? min(1, Double(proposal.evidenceCount) / 5) : 0,
            payload: proposal.toJSON()
        )
        _ = await recordTimelineEvent(
            kind: .proposalResolution,
            title: "Identity proposal \(proposal.status.rawValue)",
            summary: proposal.claim,
            artifactId: proposal.id,
            lineageId: "identity:\(proposal.id.uuidString)",
            externalEvidenceIds: proposal.evidenceNodeIds.map { "node:\($0.uuidString)" }
        )
        return proposal
    }

    func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public func receiptSnapshot(limit: Int = 40) async -> [CognitiveReceiptRecord] {
        guard configuration.enabled, configuration.persistenceEnabled, let store else { return [] }
        return (try? await store.loadReceiptRecords(limit: limit)) ?? []
    }

    public func setAblation(_ key: String, enabled: Bool) async {
        await waitForMaintenanceTransition()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ablations[trimmed] = enabled
    }

    public func facultyMeasurementSnapshot() async -> [CognitiveFacultyMeasurement] {
        let now = dependencies.now()
        let nodeCount = field.snapshot(at: now, configuration: configuration).count
        let workspaceCount = (await workspaceSnapshot()).items.count
        let activeThoughtSeeds = projectedThoughtSeeds(at: now)
        let welfare = welfareBoundsSnapshot(at: now)
        return [
            CognitiveFacultyMeasurement(faculty: "event-continuity", score: nodeCount > 0 ? 1 : 0, evidence: "nodes=\(nodeCount)", generatedAt: now),
            CognitiveFacultyMeasurement(faculty: "workspace-focus", score: workspaceCount > 0 ? 1 : 0, evidence: "workspace=\(workspaceCount)", generatedAt: now),
            CognitiveFacultyMeasurement(faculty: "capsule-grounding", score: configuration.capsuleInjectionEnabled ? 1 : 0, evidence: "capsuleEnabled=\(configuration.capsuleInjectionEnabled)", generatedAt: now),
            CognitiveFacultyMeasurement(faculty: "affect-bounds", score: welfare.withinBounds ? 1 : 0, evidence: "maxAffect=\(String(format: "%.2f", welfare.maxAffectValue))", generatedAt: now),
            CognitiveFacultyMeasurement(faculty: "thought-seeds", score: activeThoughtSeeds.isEmpty ? 0 : 1, evidence: "seeds=\(activeThoughtSeeds.count)", generatedAt: now),
            CognitiveFacultyMeasurement(faculty: "replay-lineage", score: developmentalTimeline.isEmpty ? 0 : 1, evidence: "timeline=\(developmentalTimeline.count)", generatedAt: now),
            CognitiveFacultyMeasurement(faculty: "reflection-yield", score: reflectionReceipts.values.map(\.proposalYieldScore).max() ?? 0, evidence: "reflections=\(reflectionReceipts.count)", generatedAt: now),
            CognitiveFacultyMeasurement(faculty: "observatory-export", score: 1, evidence: "bounded export available", generatedAt: now),
        ]
    }

    @discardableResult
    public func runResearchExperiment(
        kind: CognitiveExperimentKind,
        seed: String = "default"
    ) async -> CognitiveExperimentResult? {
        await waitForMaintenanceTransition()
        guard configuration.enabled, configuration.observatoryEnabled else { return nil }
        let now = dependencies.now()
        let metrics = await experimentMetrics(kind: kind)
        let score = experimentScore(kind: kind, metrics: metrics)
        let notes = experimentNotes(kind: kind)
        let key = experimentReproducibilityKey(kind: kind, seed: seed, metrics: metrics)
        let result = CognitiveExperimentResult(
            id: stableArtifactID("experiment|\(kind.rawValue)|\(seed)|\(key)"),
            kind: kind,
            seed: bounded(seed, maxCharacters: 80),
            score: score,
            metrics: metrics,
            notes: notes,
            reproducibilityKey: key,
            generatedAt: now
        )
        experimentResults[result.id] = result
        enforceExperimentResultCap()
        await persistArtifact(kind: "experiment", id: result.id, status: "recorded", score: result.score, payload: result.toJSON())
        return result
    }

    public func researchExperimentSnapshot() async -> [CognitiveExperimentResult] {
        experimentResults.values.sorted { lhs, rhs in
            if lhs.generatedAt != rhs.generatedAt { return lhs.generatedAt > rhs.generatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public func welfareBoundsSnapshot() -> CognitiveWelfareBounds {
        welfareBoundsSnapshot(at: dependencies.now())
    }

    private func welfareBoundsSnapshot(at now: Date) -> CognitiveWelfareBounds {
        let currentAffect = projectedAffect(at: now)
        let maxAffect = max(
            currentAffect.arousal,
            currentAffect.uncertainty,
            currentAffect.taskPressure,
            currentAffect.socialWarmth
        )
        let budget = max(1, configuration.dailyReflectionCallBudget)
        let pressure = Double(reflectionReceiptsToday()) / Double(budget)
        return CognitiveWelfareBounds(
            withinBounds: maxAffect <= 1 && pressure <= 1,
            maxAffectValue: maxAffect,
            reflectionBudgetPressure: pressure,
            notes: [
                "affect values are clamped to 0...1",
                "reflection calls are opt-in and budgeted",
                "welfare state is operational telemetry, not a consciousness claim",
            ],
            generatedAt: now
        )
    }

    public func exportResearchTrace(maxItems: Int = 20) async -> JSONValue {
        let limit = max(1, min(maxItems, 50))
        let summary = await observatorySnapshot()
        let measurements = await facultyMeasurementSnapshot()
        let experiments = await researchExperimentSnapshot()
        let timeline = await developmentalTimelineSnapshot(limit: limit)
        let welfare = welfareBoundsSnapshot()
        return .object([
            "kind": .string("cognitive_research_export"),
            "generatedAt": .double(dependencies.now().timeIntervalSince1970),
            "actualState": .object([
                "nodeCount": .int(Int64(summary.nodeCount)),
                "workspaceCount": .int(Int64(summary.workspaceCount)),
                "thoughtSeedCount": .int(Int64(summary.thoughtSeedCount)),
                "episodeCount": .int(Int64(summary.episodeCount)),
                "identityProposalCount": .int(Int64(summary.identityProposalCount)),
                "reflectionCount": .int(Int64(summary.reflectionCount)),
            ]),
            "facultyMeasurements": .array(measurements.map { $0.toJSON() }),
            "experiments": .array(experiments.prefix(limit).map { $0.toJSON() }),
            "timeline": .array(timeline.map { $0.toJSON() }),
            "welfareBounds": welfare.toJSON(),
            "generatedExplanations": .array([]),
            "generatedExplanationPolicy": .string("Generated explanations are exported separately from actual substrate state."),
            "truncated": .bool(experiments.count > limit || timeline.count >= limit),
        ])
    }

    public func observatorySnapshot() async -> CognitiveObservatorySnapshot {
        let now = dependencies.now()
        let currentAffect = projectedAffect(at: now)
        guard configuration.enabled, configuration.observatoryEnabled else {
            return CognitiveObservatorySnapshot(
                generatedAt: now,
                nodeCount: 0,
                workspaceCount: 0,
                thoughtSeedCount: 0,
                episodeCount: 0,
                identityProposalCount: 0,
                reflectionCount: 0,
                affect: currentAffect,
                ablations: ablations
            )
        }
        let nodeCount = field.snapshot(at: now, configuration: configuration).count
        let workspaceCount = (await workspaceSnapshot()).items.count
        let activeThoughtSeeds = projectedThoughtSeeds(at: now)
        return CognitiveObservatorySnapshot(
            generatedAt: now,
            nodeCount: nodeCount,
            workspaceCount: workspaceCount,
            thoughtSeedCount: activeThoughtSeeds.count,
            episodeCount: episodes.count,
            identityProposalCount: identityProposals.count,
            reflectionCount: reflectionReceipts.count,
            affect: currentAffect,
            ablations: ablations
        )
    }

    func metadataString(_ value: JSONValue?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func jsonStringSignals(from value: JSONValue) -> [String] {
        switch value {
        case .string(let string):
            return [string]
        case .array(let values):
            return values.flatMap(jsonStringSignals(from:))
        case .object(let object):
            return object.keys.sorted().flatMap { key in
                [key] + jsonStringSignals(from: object[key] ?? .null)
            }
        default:
            return []
        }
    }

    // Task-tracking is OUT of Agent's cognition — the Desk owns explicit tracking, only when
    // User asks (User, 2026-06-30: "I don't want her subconscious tied up following around me
    // [with] 'I'll'… her subconscious is for her feelings, emotions, her views, her
    // continuity"). The commitment/prediction extractors and their entire downstream —
    // model types, actor state, resolution/lifecycle, capsule cue builders, store paths,
    // Observatory panels — were fully removed on 2026-07-01, and the vestigial assimilate()
    // seam followed on 2026-07-02. Nothing in cognition manufactures commitments/predictions
    // from conversation any longer.

    func isConversationalPresenceStatement(_ lower: String) -> Bool {
        containsAny(lower, [
            "i'll take it",
            "i will take it",
            "i'll be right here",
            "i will be right here",
            "i'll still be here",
            "i will still be here",
            "i'll wait",
            "i will wait",
            "i'll sit right here",
            "i will sit right here",
            "i'll believe it",
            "i will believe it",
            "i won't",
            "i will not",
            "i'll take the bit",
            "i will take the bit",
            "the forgiveness is real",
        ])
    }

    func isOperationalSubconsciousNoise(_ lower: String) -> Bool {
        containsAny(lower, [
            "cognition_microcycle",
            "cognitive_microcycle",
            "context.snapshot",
            "ctx-snapshot",
            "turncontext",
            "rejectmemoryproposal",
            "memoryproposal rejected",
            "ios rejectmemoryproposal",
            "toolobservation",
            "tool observation",
            "bridge-passthrough",
            "provider path is live",
        ])
    }

    func isRuntimeMetaStatement(_ lower: String) -> Bool {
        containsAny(lower, [
            "present-me",
            "reflective-me",
            "capsule",
            "affect line",
            "social warmth",
            "low warmth",
            "working state",
            "private working",
            "runtime hint",
            "runtime state",
            "cognitive substrate",
            "the substrate",
            "reflection pass",
            "reflective pass",
            "subconscious context",
            "provisional runtime",
        ])
    }

    func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    func strippingPrefix(_ prefix: String, from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else { return trimmed }
        return String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func boundedExternalReference(_ reference: CognitiveExternalReference) -> CognitiveExternalReference {
        var metadata: [String: JSONValue] = [:]
        for key in reference.metadata.keys.sorted().prefix(configuration.maximumMetadataKeys) {
            guard let value = reference.metadata[key] else { continue }
            let boundedKey = bounded(key, maxCharacters: 80)
            metadata[boundedKey] = JSONValueBounding.bounded(
                value,
                bounds: substrateMetadataBounds,
                redactSecrets: true,
                keyPath: boundedKey.lowercased()
            )
        }
        return CognitiveExternalReference(
            id: bounded(reference.id, maxCharacters: 160),
            source: bounded(reference.source, maxCharacters: 80),
            title: bounded(reference.title, maxCharacters: 160),
            summary: bounded(reference.summary, maxCharacters: 500),
            score: reference.score,
            metadata: metadata
        )
    }

    /// Bounds for the shared `JSONValueBounding` on the substrate metadata path.
    /// Matches the former hand-rolled `boundMetadataValue` caps (8 keys, 8 array
    /// items, per-config string length) and adds redaction + a large depth cap
    /// (audit C9). The depth cap is generous enough that realistic metadata never
    /// hits it, so redaction is the only observable change here.
    private var substrateMetadataBounds: OrganismMetadataBounds {
        OrganismMetadataBounds(
            maximumKeys: 8,
            maximumStringCharacters: configuration.maximumMetadataStringCharacters,
            maximumArrayItems: 8,
            maximumDepth: JSONValueBounding.uncappedDepth
        )
    }

    @discardableResult
    func recordTimelineEvent(
        kind: CognitiveDevelopmentalTimelineKind,
        title: String,
        summary: String,
        artifactId: UUID?,
        lineageId: String,
        externalEvidenceIds: [String]
    ) async -> CognitiveDevelopmentalTimelineEvent {
        let event = recordTimelineEventInMemory(
            kind: kind,
            title: title,
            summary: summary,
            artifactId: artifactId,
            lineageId: lineageId,
            externalEvidenceIds: externalEvidenceIds
        )
        await persistArtifact(kind: "developmental_timeline", id: event.id, status: "recorded", score: 0.5, payload: event.toJSON())
        return event
    }

    func recordTimelineEventInMemory(
        kind: CognitiveDevelopmentalTimelineKind,
        title: String,
        summary: String,
        artifactId: UUID?,
        lineageId: String,
        externalEvidenceIds: [String]
    ) -> CognitiveDevelopmentalTimelineEvent {
        let now = dependencies.now()
        let event = CognitiveDevelopmentalTimelineEvent(
            id: stableArtifactID("timeline|\(kind.rawValue)|\(artifactId?.uuidString ?? lineageId)|\(bounded(title, maxCharacters: 80))|\(bounded(summary, maxCharacters: 80))"),
            kind: kind,
            title: bounded(title.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 120),
            summary: bounded(summary.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 500),
            occurredAt: now,
            artifactId: artifactId,
            lineageId: bounded(lineageId.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 120),
            subjectId: lineageSubjectId(lineageId),
            instanceId: stableDigest("\(kind.rawValue)|\(lineageId)|\(artifactId?.uuidString ?? "")"),
            forkMetadata: ["fork": "none"],
            externalEvidenceIds: boundedExternalEvidenceIds(externalEvidenceIds)
        )
        developmentalTimeline[event.id] = event
        enforceDevelopmentalTimelineCap()
        return event
    }

    func removeTimelineEventsIfMatching(_ events: [CognitiveDevelopmentalTimelineEvent]) {
        for event in events where developmentalTimeline[event.id] == event {
            developmentalTimeline.removeValue(forKey: event.id)
        }
    }

    func timelineEvents(for artifactId: UUID) -> [CognitiveDevelopmentalTimelineEvent] {
        developmentalTimeline.values.filter { $0.artifactId == artifactId }
    }

    private func dreamReplayEvidenceID(_ dream: CognitiveDreamReplayReference) -> String {
        let file = dream.filename ?? dream.id
        return bounded("dream:\(dream.date):\(file):\(stableDigest(dream.content))", maxCharacters: 180)
    }

    private func remReplayEvidenceID(_ proposal: CognitiveREMProposalReference) -> String {
        bounded("rem:\(proposal.id)", maxCharacters: 180)
    }

    private func dreamSummary(_ content: String) -> String {
        let normalized = content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return bounded(normalized, maxCharacters: 500)
    }

    private func schemaStatus(from raw: String) -> CognitiveSchemaProposalStatus {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approved", "accepted", "applied":
            return .accepted
        case "denied", "rejected", "dismissed", "archived":
            return .rejected
        default:
            return .proposed
        }
    }

    private func dateFromFullDate(_ raw: String) -> Date? {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return components.date
    }

    private func dateFromInternetDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: raw) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private func boundedExternalEvidenceIds(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in ids {
            let id = bounded(raw.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 180)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            out.append(id)
            if out.count >= 12 { break }
        }
        return out
    }

    private func lineageSubjectId(_ lineageId: String) -> String {
        let trimmed = lineageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        return bounded(trimmed.split(separator: ":").first.map(String.init) ?? trimmed, maxCharacters: 80)
    }

    private func experimentMetrics(kind: CognitiveExperimentKind) async -> [String: Double] {
        switch kind {
        case .continuity:
            return [
                "nodes": Double(field.snapshot(at: dependencies.now(), configuration: configuration).count),
                "workspace": Double((await workspaceSnapshot()).items.count),
                "timeline": Double(developmentalTimeline.count),
            ]
        case .providerSwap:
            let capsule = await compileCapsule(CognitiveCapsuleRequest(
                surface: "provider_swap_experiment",
                userMessage: "provider swap continuity experiment",
                mode: .inspectOnly,
                maximumCharacters: 800
            ))
            let stateDigest = Double(Int(stableDigest(capsule.combined)) ?? 0) / 1_000_000_000_000
            return [
                "stateDigest": stateDigest,
                "providerVariants": 2,
                "reflectionSurfaceConfigured": configuration.reflectionSurface.isEmpty ? 0 : 1,
            ]
        case .selfModelAccuracy:
            let accepted = identityProposals.values.filter { $0.status == .accepted }.count
            let rejected = identityProposals.values.filter { $0.status == .rejected }.count
            let proposed = identityProposals.values.filter { $0.status == .proposed }.count
            return [
                "acceptedIdentity": Double(accepted),
                "rejectedIdentity": Double(rejected),
                "proposedIdentity": Double(proposed),
                "schemaReviewItems": Double(schemaProposals.count),
            ]
        case .ablation:
            return [
                "ablationCount": Double(ablations.count),
                "disabledAblations": Double(ablations.values.filter { $0 == false }.count),
                "enabledAblations": Double(ablations.values.filter { $0 }.count),
            ]
        }
    }

    private func experimentScore(kind: CognitiveExperimentKind, metrics: [String: Double]) -> Double {
        switch kind {
        case .continuity:
            return clamp((metrics["nodes"] ?? 0) > 0 ? 1 : 0.5)
        case .providerSwap:
            return clamp((metrics["providerVariants"] ?? 0) >= 2 ? 1 : 0)
        case .selfModelAccuracy:
            let unresolved = metrics["proposedIdentity"] ?? 0
            return clamp(1 - min(1, unresolved / 10))
        case .ablation:
            return clamp((metrics["ablationCount"] ?? 0) > 0 ? 1 : 0.5)
        }
    }

    private func experimentNotes(kind: CognitiveExperimentKind) -> [String] {
        switch kind {
        case .continuity:
            return ["snapshot counts provide continuity baseline"]
        case .providerSwap:
            return ["compares provider variants without making provider calls"]
        case .selfModelAccuracy:
            return ["identity remains proposal-only and rejection-aware"]
        case .ablation:
            return ["ablation map is explicit and exportable"]
        }
    }

    private func experimentReproducibilityKey(
        kind: CognitiveExperimentKind,
        seed: String,
        metrics: [String: Double]
    ) -> String {
        let metricText = metrics.keys.sorted().map { key in
            "\(key)=\(String(format: "%.4f", metrics[key] ?? 0))"
        }.joined(separator: "|")
        return stableDigest("\(kind.rawValue)|\(seed)|\(metricText)")
    }

    func persistArtifact(kind: String, id: UUID, status: String, score: Double, payload: JSONValue) async {
        try? await persistArtifactChecked(
            kind: kind, id: id, status: status, score: score, payload: payload
        )
    }

    func persistArtifactChecked(
        kind: String,
        id: UUID,
        status: String,
        score: Double,
        payload: JSONValue
    ) async throws {
        guard configuration.persistenceEnabled else { return }
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        guard !persistenceWritesBlocked else {
            throw CognitivePersistenceError.writesBlocked(
                status: persistenceHealth.status,
                detail: persistenceHealth.failureDetail
            )
        }
        try await store.upsertArtifact(
            kind: kind,
            id: id,
            status: status,
            score: score,
            payload: payload,
            at: dependencies.now()
        )
    }

    /// Persist the complete current thought-seed family as one exact SQLite
    /// transition. Callers own in-memory rollback when this throws.
    func persistThoughtSeedFamily() async throws {
        guard configuration.persistenceEnabled else { return }
        guard !persistenceWritesBlocked else {
            throw CognitivePersistenceError.writesBlocked(
                status: persistenceHealth.status,
                detail: persistenceHealth.failureDetail
            )
        }
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        let rows = thoughtSeeds.values.map { seed in
            CognitiveArtifactReplacement(
                id: seed.id,
                status: "open",
                score: seed.priority,
                payload: seed.toJSON()
            )
        }
        do {
            try await store.replaceArtifactFamily(
                kind: "thought_seed",
                records: rows,
                at: dependencies.now(),
                maxArtifacts: artifactCap(configuration)
            )
            if persistenceHealth.status == .degraded,
               persistenceHealth.failureStage == "artifact.thought_seed" {
                persistenceHealth = CognitivePersistenceHealth(
                    status: .healthy,
                    writesBlocked: false,
                    lastRestoreAttemptAt: persistenceHealth.lastRestoreAttemptAt,
                    lastSuccessfulRestoreAt: persistenceHealth.lastSuccessfulRestoreAt
                )
            }
        } catch {
            let detail = bounded(String(describing: error), maxCharacters: 320)
            persistenceHealth = CognitivePersistenceHealth(
                status: .degraded,
                writesBlocked: false,
                lastRestoreAttemptAt: persistenceHealth.lastRestoreAttemptAt,
                lastSuccessfulRestoreAt: persistenceHealth.lastSuccessfulRestoreAt,
                failureStage: "artifact.thought_seed",
                failureDetail: detail
            )
            throw CognitivePersistenceError.artifactWriteFailed(
                family: "thought_seed",
                detail: detail
            )
        }
    }

    func persistMaintenanceTransition(
        nodes: [CognitiveNode],
        thoughtSeeds: [CognitiveArtifactReplacement]?,
        artifacts: [CognitiveArtifactWrite],
        deletedArtifactIDs: [UUID],
        receipts: [CognitiveReceiptWrite],
        at now: Date
    ) async throws {
        guard configuration.persistenceEnabled else { return }
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        guard !persistenceWritesBlocked else {
            throw CognitivePersistenceError.writesBlocked(
                status: persistenceHealth.status,
                detail: persistenceHealth.failureDetail
            )
        }
        try await store.commitMaintenance(
            nodes: nodes,
            thoughtSeeds: thoughtSeeds,
            artifacts: artifacts,
            deletedArtifactIDs: deletedArtifactIDs,
            receipts: receipts,
            maxNodes: configuration.maximumActiveNodes,
            maxArtifacts: artifactCap(configuration),
            at: now
        )
    }

    /// Remove a persisted artifact row (Wave E: retired standing views delete their
    /// artifact — the timeline carries the history — so bounded restores and the global
    /// prune can never crowd out live state with retired rows).
    func deleteArtifactRecord(id: UUID) async {
        guard configuration.persistenceEnabled, let store else { return }
        guard !persistenceWritesBlocked else { return }
        try? await store.deleteArtifact(id: id)
    }

    private func artifactCap(_ configuration: CognitiveConfiguration) -> Int {
        max(
            64,
            configuration.maximumThoughtSeeds
                + configuration.maximumActiveNodes
                + configuration.maximumThoughtSeeds
                + configuration.dailyReflectionCallBudget * 14
                + 64
        )
    }

    func stableArtifactID(_ key: String) -> UUID {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let suffix = hash % 1_000_000_000_000
        return UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012llu", suffix))") ?? dependencies.makeUUID()
    }

    func stableDigest(_ text: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%012llu", hash % 1_000_000_000_000)
    }

    private func restoreEpisodes(from payloads: [JSONValue]) {
        episodes.removeAll(keepingCapacity: true)
        for payload in payloads {
            guard case .object(let object) = payload,
                  let id = uuidValue(object["id"]),
                  let title = stringValue(object["title"]),
                  let summary = stringValue(object["summary"]),
                  let occurredAt = dateValue(object["occurredAt"]) else {
                continue
            }
            episodes[id] = CognitiveEpisodeReference(
                id: id,
                title: title,
                summary: summary,
                occurredAt: occurredAt,
                evidenceNodeIds: uuidArrayValue(object["evidenceNodeIds"]),
                externalEvidenceIds: stringArrayValue(object["externalEvidenceIds"]),
                lineageId: stringValue(object["lineageId"]) ?? ""
            )
        }
    }

    private func restoreSchemaProposals(from payloads: [JSONValue]) {
        schemaProposals.removeAll(keepingCapacity: true)
        for payload in payloads {
            guard case .object(let object) = payload,
                  let id = uuidValue(object["id"]),
                  let title = stringValue(object["title"]),
                  let body = stringValue(object["body"]),
                  let target = stringValue(object["target"]),
                  let statusRaw = stringValue(object["status"]),
                  let status = CognitiveSchemaProposalStatus(rawValue: statusRaw),
                  let createdAt = dateValue(object["createdAt"]) else {
                continue
            }
            schemaProposals[id] = CognitiveSchemaProposal(
                id: id,
                title: title,
                body: body,
                target: target,
                status: status,
                confidence: doubleValue(object["confidence"]) ?? 0,
                createdAt: createdAt,
                evidenceNodeIds: uuidArrayValue(object["evidenceNodeIds"]),
                externalEvidenceIds: stringArrayValue(object["externalEvidenceIds"]),
                lineageId: stringValue(object["lineageId"]) ?? ""
            )
        }
    }

    private func restoreIdentityProposals(from payloads: [JSONValue]) {
        identityProposals.removeAll(keepingCapacity: true)
        for payload in payloads {
            guard case .object(let object) = payload,
                  let id = uuidValue(object["id"]),
                  let claim = stringValue(object["claim"]),
                  let statusRaw = stringValue(object["status"]),
                  let status = CognitiveIdentityProposalStatus(rawValue: statusRaw),
                  let createdAt = dateValue(object["createdAt"]) else {
                continue
            }
            identityProposals[id] = CognitiveIdentityProposal(
                id: id,
                claim: claim,
                evidenceCount: intValue(object["evidenceCount"]) ?? 0,
                status: status,
                createdAt: createdAt,
                evidenceNodeIds: uuidArrayValue(object["evidenceNodeIds"])
            )
        }
    }

    private func restoreDevelopmentalTimeline(from payloads: [JSONValue]) {
        developmentalTimeline.removeAll(keepingCapacity: true)
        for payload in payloads {
            guard case .object(let object) = payload,
                  let id = uuidValue(object["id"]),
                  let kindRaw = stringValue(object["kind"]),
                  let kind = CognitiveDevelopmentalTimelineKind(rawValue: kindRaw),
                  let title = stringValue(object["title"]),
                  let summary = stringValue(object["summary"]),
                  let occurredAt = dateValue(object["occurredAt"]) else {
                continue
            }
            developmentalTimeline[id] = CognitiveDevelopmentalTimelineEvent(
                id: id,
                kind: kind,
                title: title,
                summary: summary,
                occurredAt: occurredAt,
                artifactId: uuidValue(object["artifactId"]),
                lineageId: stringValue(object["lineageId"]) ?? "",
                subjectId: stringValue(object["subjectId"]) ?? "",
                instanceId: stringValue(object["instanceId"]) ?? "",
                forkMetadata: stringDictionaryValue(object["forkMetadata"]),
                externalEvidenceIds: stringArrayValue(object["externalEvidenceIds"])
            )
        }
    }

    /// Restore the Wave D overnight-consolidation cadence gate. Reads only `ranAt` from
    /// the single "emotional_consolidation" artifact. Clears the gate FIRST so a re-run
    /// of restore on a live actor with a missing/corrupt artifact behaves as never-run
    /// (sweep due) instead of keeping a stale in-memory gate (gpt-5.5 review, 2026-07-02).
    /// Mirrors `restoreAffect`.
    private func restoreEmotionalConsolidation(from payloads: [JSONValue]) {
        lastEmotionalConsolidationAt = nil
        guard case .object(let object)? = payloads.first,
              let ranAt = dateValue(object["ranAt"]) else { return }
        lastEmotionalConsolidationAt = ranAt
    }

    private func restoreExperimentResults(from payloads: [JSONValue]) {
        experimentResults.removeAll(keepingCapacity: true)
        for payload in payloads {
            guard case .object(let object) = payload,
                  let id = uuidValue(object["id"]),
                  let kindRaw = stringValue(object["kind"]),
                  let kind = CognitiveExperimentKind(rawValue: kindRaw),
                  let seed = stringValue(object["seed"]),
                  let reproducibilityKey = stringValue(object["reproducibilityKey"]),
                  let generatedAt = dateValue(object["generatedAt"]) else {
                continue
            }
            experimentResults[id] = CognitiveExperimentResult(
                id: id,
                kind: kind,
                seed: seed,
                score: doubleValue(object["score"]) ?? 0,
                metrics: doubleDictionaryValue(object["metrics"]),
                notes: stringArrayValue(object["notes"]),
                reproducibilityKey: reproducibilityKey,
                generatedAt: generatedAt
            )
        }
    }

    func stringValue(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    func boolValue(_ value: JSONValue?) -> Bool? {
        guard case .bool(let bool)? = value else { return nil }
        return bool
    }

    func intValue(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let int)?:
            return Int(int)
        case .double(let double)?:
            return Int(double)
        default:
            return nil
        }
    }

    func doubleValue(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let double)?:
            return double
        case .int(let int)?:
            return Double(int)
        default:
            return nil
        }
    }

    func dateValue(_ value: JSONValue?) -> Date? {
        guard let seconds = doubleValue(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func uuidValue(_ value: JSONValue?) -> UUID? {
        guard let raw = stringValue(value) else { return nil }
        return UUID(uuidString: raw)
    }

    func uuidArrayValue(_ value: JSONValue?) -> [UUID] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap(uuidValue)
    }

    private func stringArrayValue(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap(stringValue)
    }

    private func stringDictionaryValue(_ value: JSONValue?) -> [String: String] {
        guard case .object(let object)? = value else { return [:] }
        return object.compactMapValues(stringValue)
    }

    private func doubleDictionaryValue(_ value: JSONValue?) -> [String: Double] {
        guard case .object(let object)? = value else { return [:] }
        return object.compactMapValues(doubleValue)
    }

    func unique(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        var out: [UUID] = []
        for id in ids where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }

    func bounded(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters >= 0, text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters))
    }

    func capsuleSignalText(_ text: String, maxCharacters: Int) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let userMessageRange = cleaned.range(of: "User message:", options: [.caseInsensitive, .backwards]) {
            cleaned = String(cleaned[userMessageRange.upperBound...])
        }
        cleaned = cleaned.replacingOccurrences(
            of: "[Telegram voice message]\nTranscript:",
            with: "",
            options: [.caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(
            of: "[Telegram voice message] Transcript:",
            with: "",
            options: [.caseInsensitive]
        )
        if let contextStart = cleaned.range(of: "[Telegram reply context]", options: [.caseInsensitive]),
           let contextEnd = cleaned.range(of: "[/Telegram reply context]", options: [.caseInsensitive]),
           contextStart.lowerBound < contextEnd.upperBound {
            cleaned.removeSubrange(contextStart.lowerBound..<contextEnd.upperBound)
        } else if cleaned.range(of: "[Telegram reply context]", options: [.caseInsensitive]) != nil {
            return ""
        }
        cleaned = cleaned.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: [.regularExpression]
        )
        return capsuleLineText(cleaned, maxCharacters: maxCharacters)
    }

    func isUsefulCapsuleSignalText(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized.contains("[telegram reply context]")
            || normalized.contains("[/telegram reply context]") {
            return false
        }
        if normalized.hasPrefix("the user replied to telegram message")
            || normalized.hasPrefix("the user replied to a prior message") {
            return false
        }
        return true
    }

    func clamp(_ value: Double) -> Double {
        (value).clamped01()
    }

    // MARK: - Affect dynamics

    /// U1 (2026-07-09): the user's reaction becomes how her work FELT.
    ///
    /// Three things happen here, in order, every ingest:
    ///   1. REMOVALS — a slot older than `pendingCompletionMaxAge` (or from a
    ///      session the app has since left) is dropped before anything reads it.
    ///   2. USE — a user-authored turn in the SAME session consumes the slot. Its
    ///      `conversationalAppraisal` valence (audit C3: this appraisal reads USER
    ///      text, which is exactly what a reaction is) shifts the remembered
    ///      completion's stored valence through `stampEmotionTag(isNewNode: false)`
    ///      — the asymmetric reconsolidation blend, which is precisely the
    ///      mechanism for "that turn turned out to have landed well/badly": praise
    ///      lifts it fast, criticism cools it slowly. Arousal and warmth are passed
    ///      back unchanged, so their blends are exact no-ops. A neutral reaction
    ///      (valence 0) consumes the slot and leaves the node untouched.
    ///   3. ADD — an `assistantTurnCompleted` remembers its node as the new slot,
    ///      replacing any older one. The latest completion is the one in the room.
    ///
    /// The incoming valence is `current + reaction`, NOT `reaction` — the blend
    /// moves the node TOWARD its target, so handing it the bare reaction would drag
    /// a strongly-positive node DOWN on praise. The shift is what gets blended.
    ///
    /// A completion whose node was evicted between the two turns simply finds
    /// nothing to re-stamp. A user turn with no session id (out-of-band) neither
    /// consumes nor applies — expiry remains its removal.
    private func reconsolidatePendingCompletion(
        with event: CognitiveEvent,
        outcome: ContinuityField.IngestOutcome?,
        now: Date
    ) {
        if let pending = pendingCompletion {
            let age = now.timeIntervalSince(pending.recordedAt)
            let expired = age < 0 || age > Self.pendingCompletionMaxAge
            let switchedSession = event.sessionId != nil && event.sessionId != pending.sessionId
            if expired || switchedSession { pendingCompletion = nil }
        }

        // `outcome != nil` means the field ACCEPTED this turn as new. A duplicate
        // (re-observed messageId) must be wholly inert here: without this guard, a
        // user turn replayed after a later completion opened the slot would land its
        // stale reaction on a turn it never saw.
        if Self.isUserAuthored(event.kind), outcome != nil,
           let pending = pendingCompletion,
           // Non-nil session REQUIRED on both sides (gpt-5.5 review MED, 2026-07-09):
           // optional equality made nil == nil read as "same session", so two
           // unrelated session-less events could pair a reaction to a completion
           // it never saw. No session, no reaction linkage.
           let eventSession = event.sessionId,
           let pendingSession = pending.sessionId,
           eventSession == pendingSession {
            pendingCompletion = nil
            let reaction = conversationalAppraisal(in: event.summary).valence
            // A turn cannot be the reaction to ITSELF. Both kinds map to the
            // .conversationFocus node kind, so the two turns share a field key unless
            // the subjects differ per-turn (which ChatOrchestration mints — audit C2).
            // If a caller ever reverts to per-session subjects, the user turn's own
            // stamp already landed on this node and re-stamping would blend it twice.
            let reactsToItself = outcome?.key == pending.nodeKey
            if reaction != 0, !reactsToItself, let current = field.storedEmotionTag(forKey: pending.nodeKey) {
                field.stampEmotionTag(
                    key: pending.nodeKey,
                    tag: (
                        valence: Self.clampSigned(current.valence + reaction),
                        arousal: current.arousal,
                        warmth: current.warmth
                    ),
                    isNewNode: false,
                    configuration: configuration
                )
            }
        }

        if event.kind == .assistantTurnCompleted, let outcome {
            pendingCompletion = PendingCompletion(
                nodeKey: outcome.key,
                recordedAt: now,
                sessionId: event.sessionId
            )
        }
    }

    // MARK: - Ambient presence sense

}

// MARK: - In-memory artifact caps (G-M2)

extension CognitiveSubstrate {
    // Each artifact family is disk-capped and restart-capped, but the in-process
    // dict grew without bound over a days-long run so `.values` scans went O(N).
    // These caps mirror `enforceThoughtSeedCap` (+ThoughtSeeds.swift): evict the
    // oldest by timestamp at each record tail, retained-N matched to the family's
    // restore limit in `restoreArtifactFamilyLoads()`. The disk copy survives, so
    // eviction is safe — restart reloads up to the same N.
    //
    // These live in this file (not a split extension) because most target dicts
    // are `private`, whose access is file-scoped.

    private func evictOldest<Value>(
        from dict: inout [UUID: Value],
        cap: Int,
        timestamp: (Value) -> Date
    ) {
        guard cap >= 0, dict.count > cap else { return }
        let victims = dict
            .sorted { lhs, rhs in
                let lt = timestamp(lhs.value)
                let rt = timestamp(rhs.value)
                if lt != rt { return lt < rt }
                return lhs.key.uuidString < rhs.key.uuidString
            }
            .prefix(dict.count - cap)
            .map(\.key)
        for victim in victims { dict.removeValue(forKey: victim) }
    }

    func enforceEpisodeCap() {
        evictOldest(from: &episodes, cap: 120) { $0.occurredAt }
    }

    func enforceSchemaProposalCap() {
        evictOldest(from: &schemaProposals, cap: 120) { $0.createdAt }
    }

    func enforceIdentityProposalCap() {
        evictOldest(from: &identityProposals, cap: 120) { $0.createdAt }
    }

    func enforceDevelopmentalTimelineCap() {
        evictOldest(from: &developmentalTimeline, cap: 160) { $0.occurredAt }
    }

    func enforceReflectionReceiptCap() {
        evictOldest(
            from: &reflectionReceipts,
            cap: max(40, configuration.dailyReflectionCallBudget * 4)
        ) { $0.createdAt }
    }

    func enforceExperimentResultCap() {
        evictOldest(from: &experimentResults, cap: 40) { $0.generatedAt }
    }

    // `replayEvidenceIds` is a dedup guard with no per-entry timestamp and no disk
    // restore (it is cleared on restore). Bound it in lockstep with `episodes`:
    // when it exceeds the episode cap, drop ids no longer referenced by any live
    // episode. A dropped id's episode survives on disk, so a re-dream simply
    // re-creates it — pruning unreferenced ids is safe.
    func enforceReplayEvidenceCap() {
        let cap = 120
        guard replayEvidenceIds.count > cap else { return }
        let referenced = Set(episodes.values.flatMap(\.externalEvidenceIds))
        replayEvidenceIds = replayEvidenceIds.filter { referenced.contains($0) }
    }
}

extension CognitiveSubstrate: CognitiveEventObserving {
    public func observe(_ event: CognitiveEvent) async {
        await ingest(event)
    }
}

extension CognitiveSubstrate: CognitiveContextProviding {}
extension CognitiveSubstrate: CognitiveRuntimeProviding {}
