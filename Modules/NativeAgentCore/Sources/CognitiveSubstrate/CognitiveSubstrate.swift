import Foundation
import NativeAgentCore
import PersistenceCore

public actor CognitiveSubstrate {
    var configuration: CognitiveConfiguration
    let dependencies: CognitiveSubstrateDependencies
    let store: CognitiveSQLiteStore?
    var persistenceHealth: CognitivePersistenceHealth = .disabled
    var persistenceWritesBlocked = false
    var field = ContinuityField()
    var thoughtSeeds: [UUID: CognitiveThoughtSeed] = [:]
    var thoughtSeedRevision: UInt64 = 0
    /// Item 47: internal rather than private — the developmental recall pull
    /// (CognitiveSubstrate+DevelopmentalRecall.swift) is a read of these two
    /// stores from a sibling file in the same module. Still no external writer.
    var episodes: [UUID: CognitiveEpisodeReference] = [:]
    var schemaProposals: [UUID: CognitiveSchemaProposal] = [:]
    /// Wave E: proposal-shaped standing views. Every view enters `.proposed`; only
    /// `resolveStandingView(approved:)` (User) activates one. Persisted one artifact per view
    /// (kind "standing_view"), restored on boot. See CognitiveSubstrate+StandingViews.swift.
    var standingViews: [UUID: CognitiveStandingView] = [:]
    /// Unsaved holds retain their capacity releases until the whole transition lands.
    var pendingStandingViewHolds: [UUID: Set<UUID>] = [:]
    /// 2026-09-06: the cap repair's artifact deletes used to be swallowed, so a
    /// store that cannot accept deletes re-demoted the same views on every
    /// launch in silence. One log line per launch — the repair itself stays
    /// best-effort, and a line per overflowing view per restore would be noise.
    var didLogStandingViewCapRepairFailure = false
    var developmentalTimeline: [UUID: CognitiveDevelopmentalTimelineEvent] = [:]
    var replayEvidenceIds: Set<String> = []
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
    var experimentResults: [UUID: CognitiveExperimentResult] = [:]
    var affect = CognitiveAffectState()
    /// The slow felt layer — reflection-written, day-scale decay (see +Mood.swift).
    var disposition = CognitiveDisposition()
    /// Round 3 Wave A3 — day claims for the resolution-pattern nudge, keyed
    /// "path|kind" → day bucket. Enforces at-most-once per kind per day across
    /// the ~20h consolidation ticks; persisted inside the disposition artifact
    /// so a same-day restart cannot re-nudge. Pruned to the current day only.
    var resolutionPatternNudgeDay: [String: String] = [:]
    /// 2026-09-06 — which NIGHT's dream tone is already baked into the
    /// disposition above (same key the residue is claimed under). Recorded in
    /// the SAME artifact write as the value it describes, so a retry of a
    /// partially failed dream integration cannot nudge her twice for one night.
    var dreamDispositionNight: String?
    // Extensions implementing read projections must consult the same
    // actor-isolated intervention map; it remains module-internal rather than
    // becoming a second public configuration surface.
    var ablations: [String: Bool] = [:]

    // MARK: - Personality depth wave, items 6 and 7 (2026-09-02)
    // Four in-memory ledgers. NONE of them persists, on purpose:
    //   • a released nag re-derives from the seed's own age after a restart, and
    //     the seed is gone, so there is nothing to re-derive;
    //   • a re-feel budget that survives a restart would be a second clock to
    //     keep honest for no gain — the worst case is one extra small nudge;
    //   • the night's residue is by definition about the turns right after
    //     waking, and a restart is a different waking.
    // Each is bounded by its own owner (see `+Rumination`, `+Affect`, `+Mood`).

    /// Item 6 — seeds whose weight has been cleared, and when. Pruned past
    /// `ruminationReleaseMemory`.
    var ruminationReleasedAt: [UUID: Date] = [:]
    /// Item 6 — relief felt-moments staged for the runtime's drain, capped
    /// drop-oldest (`pendingRuminationReleaseCap`).
    var pendingRuminationReleases: [CognitiveEvent] = []
    /// Item 7 — the night's residue: a mood with no source, spent over the
    /// first accepted turns after waking. Persisted (family `dream_residue`)
    /// alongside its claim key so a restart neither loses nor re-mints it.
    var dreamResidue: CognitiveDreamResidue?
    /// Item 7 — which night the current residue belongs to (the committed
    /// dream's id, else the local calendar day). One night, one residue.
    var dreamResidueClaimKey: String?
    /// Item 6 (2026-09-02) — open things an EXTERNAL owner holds (Desk items
    /// she opened), pushed by the owner-side reader. In-memory: canonical Desk
    /// state is the durable copy, and re-reading it is one file away.
    var externalRuminations: [String: CognitiveExternalRumination] = [:]
    /// When that set was last read, so a turn can ask "is it stale" without
    /// touching disk.
    var externalRuminationsRefreshedAt: Date?
    /// Item 7 — when each felt node was last RE-FELT through recall. One nudge
    /// per node per hour; pruned by the same owner.
    var lastRefeltAt: [UUID: Date] = [:]
    /// Per-RECORD re-feel refractory beside the per-node one: every recall turn
    /// mints a fresh node naming the same record.
    var lastRefeltRecordAt: [String: Date] = [:]

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

    /// Item 46, review fix (1). `reconsolidatePendingCompletion` CONSUMES the
    /// slot during ingest, and the runtime asks for semantic metadata AFTER
    /// ingest — so by the time `semanticReactionLabel(for:)` runs the evidence
    /// it needs is already gone, every user reply came back unlabelled, and
    /// every expectation expired instead of resolving. The consume site now
    /// stashes what it read, and the metadata derivation reads the stash.
    ///
    /// One slot, same discipline as `pendingCompletion` itself: memory-only,
    /// single-use (cleared on read), session-scoped, and expired by the same
    /// `pendingCompletionMaxAge` so a stash can never answer a later turn.
    struct SemanticReactionStash: Sendable, Equatable {
        /// Session the completion and its reaction share.
        var sessionID: String
        /// The completion turn this reaction answers — `PendingCompletion.nodeKey`,
        /// which ChatOrchestration mints per turn. An opaque `type:id` key; no
        /// content.
        var turnID: String
        /// `pushback` / `confirmed` / `neutral`.
        var reaction: String
        var recordedAt: Date
    }
    var lastSemanticReaction: SemanticReactionStash?

    /// How long a completion stays open to being re-felt. Past this the next
    /// message is a new beginning, not a verdict on the last thing she said.
    static let pendingCompletionMaxAge: TimeInterval = 10 * 60

    /// W7/P10 — THE LANDING SIGNAL. The echo used to select exemplars by the
    /// room's temperature and nothing else; the comment above `soundEchoLine`
    /// is explicit that warmth on her turn is the room at encode, not proof the
    /// line landed. `pendingCompletion` + `conversationalAppraisal` were already
    /// built; this is the one number they were missing.
    ///
    /// Bounded −1…1, memory-only (a verdict that crosses a relaunch isn't a
    /// verdict), and keyed by node id so the echo's ranking can read it directly.
    /// Cleanup is `pruneLandingScores`: entries whose node has left the field are
    /// dropped, and the newest `landingScoreCapacity` survive a prune.
    private var landingScores: [UUID: (score: Double, at: Date)] = [:]
    static let landingScoreCapacity = 256

    /// W7/P5 — consecutive negative-register echoes. See
    /// `soundEchoNegativeRunLimit`. Memory-only and live-path only.
    var negativeSoundEchoRun = 0
    var settlingRun = 0

    /// 2026-09-01 — the rut nudge's change-driven cadence, and the inner line's
    /// per-text cadence ledger. Both are PRESENTATION state in exactly the sense
    /// the fingerprint run already is: memory-only, live-path only, advanced by
    /// `applyCapsulePresentationCommit` after the provider accepts the turn.
    var soundRutSignature: String?
    var soundRutLastSurfacedAt: Date?
    var soundRutTurnsSinceSurfaced = 0
    /// Bounded like every other counted family: once it is past any gate it
    /// could satisfy, a larger number carries no more meaning.
    static let soundRutTurnCounterCap = 10_000
    var innerLineRuns: [String: Int] = [:]
    /// Presentation receipts for the felt line's object + ambivalence organs
    /// (2026-09-02). Counters only — see `CognitiveCapsulePresentationState`.
    var feltObjectCount = 0
    var ambivalenceCount = 0
    var lastAmbivalenceAt: Date?
    /// REMINDED-OF (2026-09-02) — presentation cadence for the unbidden-recall
    /// line, and the id-only ledger of what it has already surfaced. Same shape
    /// and same lifetime as the rut nudge's: memory-only, live-path only, and
    /// advanced by `applyCapsulePresentationCommit` except for the turn counter,
    /// which free-runs on the accepted-turn tick below.
    var remindedOfLastSurfacedAt: Date?
    var remindedOfTurnsSinceSurfaced = 0
    var remindedOfSurfaced: [String: Date] = [:]
    /// The felt weight of MOMENTS this turn's recall actually saw, keyed by
    /// memory record id. This is what lets a served moment be RE-FELT with its
    /// own valence instead of neutrally: a MemoryV2 record carries a feeling the
    /// field may have no node for. Bounded, memory-only (see `+RemindedOf`).
    var momentAffect: [String: MomentAffect] = [:]
    /// Set when an accepted turn moved the durable cadence ledger; cleared by
    /// `flushCapsulePresentationIfNeeded`.
    var capsulePresentationDirty = false

    /// W7/P6 — TELEMETRY ONLY. The delivery envelope the mechanism WOULD have
    /// chosen for this turn, stashed at live capsule compile (the one place the
    /// real felt signals and the real user-turn size are both in hand) and paired
    /// with the actual reply length when the completion lands. Nothing reads it
    /// to shape a reply, and no flag exists that could make it do so.
    ///
    /// Single slot, overwritten every live compile, consumed on log, dropped on
    /// `clear()` — the same lifecycle discipline as `pendingCompletion`.
    var pendingDeliveryEnvelope: PendingDeliveryEnvelope?

    /// The last pairing row `consumeDeliveryEnvelopeTelemetry` produced, held
    /// IN MEMORY ONLY.
    ///
    /// Sweep item 21 (2026-09-01): the `logs/delivery_envelope_telemetry.jsonl`
    /// append is retired — nothing read the file, so it was write-only disk —
    /// and `storeDataRoot`, which existed solely to give that append a hermetic
    /// path, went with it. This slot keeps the pairing observable in-process
    /// without a durable feed nobody consumes. Single slot, overwritten per
    /// paired completion, dropped on `clear()`.
    var lastDeliveryEnvelopeTelemetryRow: JSONValue?

    /// W7/P10 — the bounded landing verdict for one exemplar node, 0 when the
    /// node has never been reacted to.
    func landingScore(forNodeId id: UUID) -> Double {
        landingScores[id]?.score ?? 0
    }

    /// Immutable Sound-ranking inputs for one frozen capsule epoch.
    func soundLandingScoreSnapshot() -> [UUID: Double] {
        landingScores.mapValues(\.score)
    }

    /// Presentation-only cadence state captured beside a frozen cognition read.
    func capsulePresentationStateSnapshot() -> CognitiveCapsulePresentationState {
        CognitiveCapsulePresentationState(
            fingerprintFamily: fingerprintFamilyRun?.family,
            fingerprintCount: fingerprintFamilyRun?.count ?? 0,
            fingerprintLastSurfacedAt: fingerprintFamilyRun?.lastSurfacedAt,
            lastLiveCapsuleAt: lastLiveCapsuleAt,
            lastSessionBridgeAt: lastSessionBridgeAt,
            negativeSoundEchoRun: negativeSoundEchoRun,
            settlingRun: settlingRun,
            soundRutSignature: soundRutSignature,
            soundRutLastSurfacedAt: soundRutLastSurfacedAt,
            soundRutTurnsSinceSurfaced: soundRutTurnsSinceSurfaced,
            innerLineRuns: innerLineRuns,
            feltObjectCount: feltObjectCount,
            ambivalenceCount: ambivalenceCount,
            lastAmbivalenceAt: lastAmbivalenceAt,
            remindedOfLastSurfacedAt: remindedOfLastSurfacedAt,
            remindedOfTurnsSinceSurfaced: remindedOfTurnsSinceSurfaced,
            remindedOfSurfaced: remindedOfSurfaced
        )
    }

    /// Stamp a bounded landing verdict on the node a completion produced.
    func stampLandingScore(_ score: Double, forNodeId id: UUID, at now: Date) {
        let bounded = Self.clampSigned(score)
        if bounded == 0 {
            // Neutral is NO evidence on a never-stamped node ("the file is at
            // line 40" says nothing about whether the exemplar landed). But on
            // a node that already carries a verdict it IS evidence — the
            // latest completion landed flat, and the stale bias must not keep
            // re-ranking echoes forever (gpt-5.5 SHOULD-FIX, 2026-08-11).
            if landingScores[id] != nil { landingScores[id] = (0, now) }
            return
        }
        landingScores[id] = (bounded, now)
        pruneLandingScores()
    }

    /// STATE LIFECYCLE. Every add above has its removal here: a landing verdict
    /// outlives its node only until the next stamp, and the dict can never grow
    /// past `landingScoreCapacity` no matter how long the process runs.
    private func pruneLandingScores() {
        let liveIds = Set(field.peekNodes().map(\.id))
        landingScores = landingScores.filter { liveIds.contains($0.key) }
        guard landingScores.count > Self.landingScoreCapacity else { return }
        let keep = landingScores
            .sorted { $0.value.at > $1.value.at }
            .prefix(Self.landingScoreCapacity)
        landingScores = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    /// W4/P1 — the live dynamics constants. Every felt-layer read goes through
    /// here rather than a `static let`, so a persona's numbers can drive its
    /// physics. `.default` reproduces the pre-P1 literals exactly.
    var dynamics: PersonalityDynamicsConfiguration { dependencies.dynamics() }

    /// W4/P4 — suppress-when-unchanged state for the fingerprint line. An
    /// identical "How you feel: warm" for forty consecutive turns is a stuck
    /// gauge and the model will express it, so a family that has not moved for
    /// `fingerprintFamilyRepeatLimit` capsules goes quiet until the family
    /// changes or `fingerprintSuppressionWindow` expires.
    ///
    /// LIVE-PATH ONLY. `compileFrozenCapsule` is a pure rendering of a captured
    /// read and must never advance this run (its own doc comment already
    /// promised "no suppress-when-unchanged mutation").
    struct FingerprintFamilyRun: Sendable, Equatable {
        var family: String
        /// Consecutive capsules that reported this family, including suppressed ones.
        var count: Int
        /// When the line last actually SURFACED — the anchor the suppression
        /// window expires from.
        var lastSurfacedAt: Date
    }
    var fingerprintFamilyRun: FingerprintFamilyRun?

    /// W4/P7 — when a live capsule was last compiled. The gap between this and
    /// now is what makes a turn "the first turn after a gap"; nothing else in the
    /// felt layer knows a gap occurred at all. Memory-only: a bridge that fires
    /// because the app restarted is a bug, not continuity.
    var lastLiveCapsuleAt: Date?
    /// The gap the session bridge last spoke for, so one gap yields at most one
    /// bridge line even if the first turn's capsule is recompiled.
    var lastSessionBridgeAt: Date?

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
        pendingStandingViewHolds.removeAll(keepingCapacity: false)
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
        dreamDispositionNight = nil
        ablations.removeAll(keepingCapacity: false)
        verificationNodeMayExist = false
        pendingCompletion = nil
        // Item 46: the reaction stash describes the completion slot above; it
        // clears with it.
        lastSemanticReaction = nil
        // W7: the three memory-only slots this wave added clear with the field
        // they describe — a landing verdict, an echo run, or a delivery envelope
        // that survived a wipe would be describing nodes that no longer exist.
        landingScores.removeAll(keepingCapacity: false)
        negativeSoundEchoRun = 0
        // The rut signature and the inner-line ledger name text that came from
        // the field being wiped; they clear with it.
        soundRutSignature = nil
        soundRutLastSurfacedAt = nil
        soundRutTurnsSinceSurfaced = 0
        // The reminded-of ledgers describe memories she was reminded OF while
        // this field existed; they clear with it.
        remindedOfLastSurfacedAt = nil
        remindedOfTurnsSinceSurfaced = 0
        remindedOfSurfaced.removeAll(keepingCapacity: false)
        momentAffect.removeAll(keepingCapacity: false)
        innerLineRuns.removeAll(keepingCapacity: false)
        capsulePresentationDirty = false
        pendingDeliveryEnvelope = nil
        lastDeliveryEnvelopeTelemetryRow = nil
        dirtySince = nil
        lastUserPresenceAt = nil
        lastWarmPresenceAt = nil
        lastEmotionalConsolidationAt = nil
        publishAttentionProjection(at: dependencies.now())
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


}

extension CognitiveSubstrate: CognitiveEventObserving {
    public func observe(_ event: CognitiveEvent) async {
        await ingest(event)
    }
}

extension CognitiveSubstrate: CognitiveContextProviding {}
extension CognitiveSubstrate: CognitiveRuntimeProviding {}
