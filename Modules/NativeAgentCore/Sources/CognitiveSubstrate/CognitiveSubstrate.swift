import Foundation
import NativeAgentCore
import PersistenceCore
import Experiences
// Blueprint: | `CognitiveSubstrate.swift` | `CognitiveSubstrate`: `waitForMaintenanceTransition`, `beginMaintenanceTransition` |

public actor CognitiveSubstrate {
    var configuration: CognitiveConfiguration
    let dependencies: CognitiveSubstrateDependencies
    let store: CognitiveSQLiteStore?
    var conversationDataRoot: URL {
        store?.databaseURL.deletingLastPathComponent().deletingLastPathComponent() ?? defaultDataRoot()
    }
    /// Persistence health admits writes only after successful restore or Clear.
    var persistenceHealth: CognitivePersistenceHealth = .disabled
    /// Stages whose last write failed; each has one owed repair.
    var unsavedStages: Set<String> = []
    /// True once a restore has read the agent's saved mind (or cleared it). A second restore over a live resident never runs (`restorePersistentState`).
    var persistenceRestored = false
    /// True while Clear holds the store (`forgetMind`): every substrate write is discarded rather than landing a pre-clear snapshot after the clear.
    var forgettingInFlight = false
    /// The per-piece writes the Clear hold discarded, by (kind, id). A failed Clear names them in one owed repair; a successful one drops the list. `kind`
    /// "snapshot" is the node field.
    var forgettingDiscarded: [(kind: String, id: UUID)] = []
    /// Once loaded or explicitly cleared, resident families own removals too.
    var residentRestoreIsAuthoritative = false
    var restoreInFlight = false
    var field = ContinuityField()
    /// Actor-owned episode and schema stores, shared with sibling extensions; no external writer.
    var episodes: [UUID: CognitiveEpisodeReference] = [:]
    var schemaProposals: [UUID: CognitiveSchemaProposal] = [:]
    /// Care artifacts own lived concerns; bootstrap markers prevent repeated imports and vector identity includes exact text plus embedding epoch.
    var cares: [UUID: CognitiveCare] = [:]
    var careMigration: CognitiveCareMigration?
    var careRetiredMigration: JSONValue?
    var careVectors: [UUID: (text: String, epoch: String, vector: [Float])] = [:]
    var carePersonAliases: [String: String] = [:]
    var carePeopleReadFailure: String?
    var selfKnowledge: CognitiveSelfKnowledge?
    var selfPersonLines: [String: String] = [:]
    var selfKnowledgeReadFailure: String?
    var developmentalTimeline: [UUID: CognitiveDevelopmentalTimelineEvent] = [:]
    var replayEvidenceIds: Set<String> = []
    var reflectionDispositionClaims: Set<UUID> = []
    var reflectionReceipts: [UUID: CognitiveReflectionReceipt] = [:]
    /// Reserve budget before suspension so manual and scheduled planners cannot claim the same slot; configuration refresh preserves it and dead requests
    /// expire.
    struct ReflectionReservation: Sendable, Equatable {
        var id: UUID
        var since: Date
    }
    var reflectionReservation: ReflectionReservation?
    static let reflectionInFlightMaximumAge: TimeInterval = 10 * 60
    var affect = CognitiveAffectState()
    /// The ADMISSION BUFFER between a turn's ingest and its recording as a lived moment. The fold reads the recorded entry, never this. Live turns are never
    /// evicted; only admissions with an explicit terminal edge are capped.
    var deferredTurns: [CognitiveDeferredTurnRecord] = []
    var caringRefusalRecorder: CaringRefusalRecording?
    var caringAppraisalGeneration: UInt64 = 0
    /// The durable forgetting epochs (see `AfterTurnContext.mindEpoch`). The mind's lives in `cognitive_epochs`, read at restore and bumped by Clear in the
    /// transaction that empties the store; the body's lives in its own file and is pushed here by the runtime (`adoptBodyEpoch`).
    var mindEpoch: UInt64 = 0
    /// When Clear last moved `mindEpoch`, kept beside it: a turn admitted again from words said before then carries the epoch before it.
    var mindClearedAt = Date.distantPast
    var bodyEpoch: UInt64 = 0
    /// Kernel revision prevents older body epochs from replacing newer adopted state.
    var bodyEpochRevision: UInt64?
    /// Adopt actual body doses as relay-distinctness evidence; inferred encounters cannot stand in.
    var recentCaringEncounters: [CaringAppraisalRequest.RecentEncounter] = []
    /// The last few turns per session, both sides, so the appraisal reads a turn in the exchange it happened in. Bounded, clipped, never written to disk.
    var recentTurnsBySession: [String: [CaringAppraisalRequest.ContextTurn]] = [:]
    /// The slow felt layer — reflection-written, day-scale decay (see +Mood.swift).
    var disposition = CognitiveDisposition()
    /// "path|kind" → day bucket: at most one nudge per key per day; pruned to the current day. Claims persist with disposition so a same-day restart cannot
    /// re-nudge.
    var resolutionPatternNudgeDay: [String: String] = [:]
    /// Every integrated night persists with its effect; a later night cannot erase an older journal's proof after a failed checkpoint.
    var dreamDispositionNights: Set<String> = []
    var dreamIntegrations: [String: Task<Bool, Never>] = [:]
    /// Bounded transitions record source, before, after-decay and after-contribution to distinguish fading from experience.
    var dispositionTransitions: [CognitiveDispositionTransition] = []
    /// Bounded rejected associations and one disposition undo share the `mind_ledger` row.
    var associationSuppressions: [CognitiveAssociationSuppression] = []
    var dispositionUndo: CognitiveUndoEntry?
    // Read projections share this actor-owned intervention map.
    var ablations: [String: Bool] = [:]

    /// The night's mood without a source, spent over the first accepted waking turns. Persists with its claim key in `dream_residue` so a restart neither loses
    /// nor re-mints it.
    var dreamResidue: CognitiveDreamResidue?
    /// One residue per night, keyed by committed dream id or local calendar day.
    var dreamResidueClaims: Set<String> = []
    /// Unsettled attention rows share the field's checkpoint: a saved application always retains its replay identity.
    var attentionLanding: AttentionLanding?
    /// Bound recall nudges to one per node per hour.
    var lastRefeltAt: [UUID: Date] = [:]
    /// Per-RECORD re-feel refractory beside the per-node one: every recall turn mints a fresh node naming the same record.
    var lastRefeltRecordAt: [String: Date] = [:]

    var dirtySince: Date?
    var dirtyRevision: UInt64 = 0
    /// Single-flight at the owner also covers manual and termination paths while SQLite suspends; a second pass cannot stage over the first.
    var maintenanceRunInFlight = false

    /// Microcycle commits and maintenance transitions exclude each other across awaits. Microcycles wait for maintenance; maintenance skips an active
    /// microcycle commit. Resident ingest waits only for maintenance, never for this commit hold.
    var maintenanceCommitInFlight = false
    var microcycleWaiters: [ScopedWaiter] = []

    private var maintenanceTransitionDone = ScopedWaiter()
    private var lifecycleHoldDone = ScopedWaiter()

    /// Restore and Clear are mutually exclusive under one hold: each waits while the other (or another of itself) is in flight.
    func waitForLifecycleHold() async {
        while restoreInFlight || forgettingInFlight {
            let done = lifecycleHoldDone
            await Task { await done.park() }.value
        }
    }

    /// Wake every waiter once; each re-checks the hold.
    func releaseLifecycleHold() {
        lifecycleHoldDone.resume()
        lifecycleHoldDone = ScopedWaiter()
    }

    /// Mutations wait for the whole durable transition, even when cancelled. Read-only snapshots remain available while the store is suspended.
    func waitForMaintenanceTransition() async {
        while maintenanceRunInFlight {
            let done = maintenanceTransitionDone
            await Task { await done.park() }.value
        }
    }

    /// Pair transition ownership with deferred release in `runMaintenanceChecked`.
    func beginMaintenanceTransition() {
        maintenanceRunInFlight = true
    }

    /// Resume each parked waiter once; later transitions get fresh waiters.
    func endMaintenanceTransition() {
        maintenanceRunInFlight = false
        maintenanceTransitionDone.resume()
        maintenanceTransitionDone = ScopedWaiter()
    }

    var lastUserPresenceAt: Date?
    var lastWarmPresenceAt: Date?
    /// Persist the consolidation clock; absent evidence leaves the first pass due.
    var lastEmotionalConsolidationAt: Date?
    var verificationNodeMayExist = false
    static let verificationWorkspaceMaxAge: TimeInterval = 6 * 60 * 60

    func markDirty(at date: Date) {
        dirtySince = dirtySince ?? date
        dirtyRevision &+= 1
    }

    /// One transient completion awaits the same session's next user reaction until consumed or expired.
    struct PendingCompletion: Sendable, Equatable {
        var nodeKey: String
        var recordedAt: Date
        var sessionId: String?
    }
    var pendingCompletion: PendingCompletion?

    /// How long a completion stays open to being re-felt. Past this the next message is a new beginning, not a verdict on the last thing the agent said.
    static let pendingCompletionMaxAge: TimeInterval = 10 * 60

    /// Memory-only landing verdicts in −1…1, keyed by node for exemplar ranking. Pruning retains live nodes and the newest `landingScoreCapacity` entries.
    private var landingScores: [UUID: (score: Double, at: Date)] = [:]
    static let landingScoreCapacity = 256

    /// One resident cadence value, frozen by value and committed only on acceptance.
    var capsulePresentationState = CognitiveCapsulePresentationState()
    /// Counters stop growing once every cadence gate is satisfied.
    static let soundRutTurnCounterCap = 10_000
    /// Set when an accepted turn moved the durable cadence ledger; cleared by `flushCapsulePresentationIfNeeded`.
    var capsulePresentationDirty = false

    /// Immutable Sound-ranking inputs for one frozen capsule epoch.
    func soundLandingScoreSnapshot() -> [UUID: Double] {
        landingScores.mapValues(\.score)
    }

    /// Stamp a bounded landing verdict on the node a completion produced.
    func stampLandingScore(_ score: Double, forNodeId id: UUID, at now: Date) {
        let bounded = (score).clampedSigned()
        if bounded == 0 {
            // Neutral clears an existing landing verdict; a never-stamped node provides no landing evidence.
            if landingScores[id] != nil { landingScores[id] = (0, now) }
            return
        }
        landingScores[id] = (bounded, now)
        pruneLandingScores()
    }

    /// Prune vanished nodes and enforce `landingScoreCapacity` at every stamp so long-lived processes remain bounded.
    private func pruneLandingScores() {
        let liveIds = Set(field.peekNodes().map(\.id))
        landingScores = landingScores.filter { liveIds.contains($0.key) }
        guard landingScores.count > Self.landingScoreCapacity else { return }
        let keep = landingScores
            .sorted { $0.value.at > $1.value.at }
            .prefix(Self.landingScoreCapacity)
        landingScores = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    /// Only successful checked reads change these derived parameters. This synchronous actor-owned calculation cannot publish out of read order.
    private var dynamicsReadFailure: String?
    /// Repair debt survives shutdown; the first healthy read of each launch settles it.
    private var dynamicsSettledThisLaunch = false
    var dynamics: PersonalityDynamicsConfiguration {
        do {
            let current = try dependencies.dynamics()
            if dynamicsReadFailure != nil || !dynamicsSettledThisLaunch {
                dynamicsReadFailure = nil
                dynamicsSettledThisLaunch = true
                RepairOwed.settle(conversationDataRoot, operation: "persona.profile.dynamics",
                    evidence: .init(source: "memory/profile.json", id: "checked-read"))
            }
            return current
        } catch {
            let why = error.localizedDescription
            if dynamicsReadFailure != why {
                dynamicsReadFailure = why
                RepairOwed.owe(conversationDataRoot, id: "profile-dynamics:" + UUID().uuidString, kind: .run,
                    operation: "persona.profile.dynamics", owner: "memory/profile.json",
                    words: """
                        Personality dynamics source unavailable: \(why) Trait-dependent felt signals and voice echoes are unavailable. Fixed decay rates \
                        remain available.
                        """,
                    tap: "Restore read access or repair memory/profile.json, preserving its content. A successful checked profile read settles this fault.")
            }
            return .unavailable
        }
    }

    /// All name-dependent projections share the checked profile owner.
    func oweUserNameRead(_ error: Error) {
        RepairOwed.owe(conversationDataRoot, id: "profile-name:" + UUID().uuidString, kind: .run,
            operation: "persona.profile.name", owner: "memory/profile.json",
            words: "The person's saved name is unavailable: \(error.localizedDescription)",
            tap: "Repair memory/profile.json, preserving its content, then refresh the inner life.")
    }

    func oweCareEmbedding(_ error: Error) {
        RepairOwed.owe(conversationDataRoot, id: "care-embedding:" + UUID().uuidString, kind: .run,
            operation: "cognition.cares.embedding", owner: "memory/embedding",
            words: "Care interpretation is unavailable because the resident embedder failed: \(error.localizedDescription)",
            tap: "Repair the embedding source in Settings → Memory before interpreting these cares again.")
    }

    func checkedUserName() -> String? {
        do { return try dependencies.userName().trimmingCharacters(in: .whitespacesAndNewlines) }
        catch { oweUserNameRead(error); return nil }
    }

    var userAddress: String {
        guard let name = checkedUserName() else { return "the person (saved name unavailable)" }
        return name.isEmpty ? "you" : name
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
            } else {
                // `.ready` means the store is open and the agent's mind is not yet read.
                self.persistenceHealth = CognitivePersistenceHealth(status: .ready, writesBlocked: true)
            }
        }
    }

    public func configure(_ configuration: CognitiveConfiguration) async {
        await waitForMaintenanceTransition()
        self.configuration = configuration
        if !configuration.persistenceEnabled {
            persistenceHealth = .disabled
        } else if store == nil {
            persistenceHealth = CognitivePersistenceHealth(
                status: .degraded,
                writesBlocked: true,
                lastRestoreAttemptAt: persistenceHealth.lastRestoreAttemptAt,
                lastSuccessfulRestoreAt: persistenceHealth.lastSuccessfulRestoreAt,
                failureStage: "store",
                failureDetail: CognitivePersistenceError.storeUnavailable.description
            )
        } else if persistenceHealth.status == .disabled {
            // Persistence switched back on: writes open again only if the agent's mind was already read in this process; otherwise the next restore opens them.
            persistenceHealth = CognitivePersistenceHealth(
                status: persistenceRestored ? .healthy : .ready, writesBlocked: !persistenceRestored)
        }
        if persistenceRestored { await restoreSelfKnowledge() }
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

    public func clearTransientState() async {
        await waitForMaintenanceTransition()
        clearResidentState()
    }

    /// The resident half of Clear, synchronous: `forgetMind` calls it while it itself holds the maintenance transition.
    func clearResidentState() {
        // A maintenance transaction may be suspended in the store actor. Its failure rollback must recognize this explicit lifecycle reset as a newer mutation
        // and never resurrect the cleared in-memory state.
        dirtyRevision &+= 1
        residentRestoreIsAuthoritative = true
        field.clear()
        attentionLanding = nil
        episodes.removeAll(keepingCapacity: false)
        schemaProposals.removeAll(keepingCapacity: false)
        cares.removeAll(keepingCapacity: false)
        careMigration = nil
        careRetiredMigration = nil
        careVectors.removeAll(keepingCapacity: false)
        selfKnowledge = nil
        selfPersonLines = [:]
        selfKnowledgeReadFailure = nil
        developmentalTimeline.removeAll(keepingCapacity: false)
        replayEvidenceIds.removeAll(keepingCapacity: false)
        reflectionReceipts.removeAll(keepingCapacity: false)
        reflectionDispositionClaims.removeAll(keepingCapacity: false)
        reflectionReservation = nil
        affect = CognitiveAffectState(updatedAt: dependencies.now())
        disposition = CognitiveDisposition()
        // Clear day claims with the disposition so they cannot suppress post-clear nudges.
        resolutionPatternNudgeDay.removeAll(keepingCapacity: false)
        dreamDispositionNights = []
        dispositionTransitions.removeAll(keepingCapacity: false)
        dispositionUndo = nil
        associationSuppressions.removeAll(keepingCapacity: false)
        dreamResidue = nil
        dreamResidueClaims = []
        lastRefeltAt.removeAll(keepingCapacity: false)
        lastRefeltRecordAt.removeAll(keepingCapacity: false)
        ablations.removeAll(keepingCapacity: false)
        verificationNodeMayExist = false
        pendingCompletion = nil
        // Landing and presentation ledgers describe the field being cleared.
        landingScores.removeAll(keepingCapacity: false)
        capsulePresentationState = CognitiveCapsulePresentationState()
        // Invalidate caring context, ledgers and in-flight verdicts; none may dose after Clear.
        clearCaringState()
        capsulePresentationDirty = false
        dirtySince = nil
        lastUserPresenceAt = nil
        lastWarmPresenceAt = nil
        lastEmotionalConsolidationAt = nil
        publishAttentionProjection(at: dependencies.now())
    }

    /// Clear holds every writer across awaits, atomically moves the store epoch, then empties RAM and saves post-clear state. Failed store clear preserves
    /// resident state; MemoryV2 is outside its scope.
    public func forgetMind() async throws {
        guard let store else { throw CognitivePersistenceError.storeUnavailable }
        // One hold for Clear and restore: wait out a restore in flight.
        await waitForLifecycleHold()
        // Hold maintenance and microcycle ownership through Clear so no suspended commit can land after forgetting.
        await waitForMaintenanceTransition()
        beginMaintenanceTransition()
        if maintenanceCommitInFlight {
            let done = ScopedWaiter()
            microcycleWaiters.append(done)
            await Task { await done.park() }.value
        } else {
            maintenanceCommitInFlight = true
        }
        forgettingInFlight = true
        forgettingDiscarded.removeAll()
        var supersededStages = unsavedStages.subtracting(["mind.self", "mind.self.read"])
        let epoch: UInt64
        let clearedAt: Date
        do {
            // Repair claims survive relaunch; RAM is not their owner. Read before deleting anything, so an unavailable ledger cannot leave a successful Clear
            // with debts it never learned about.
            let repairs = try await ExperienceStore.at(conversationDataRoot).projection()
            for repair in repairs where RepairOwed.isOwed(repair)
                && RepairDebt(repair).owner == "cognition" {
                guard let operation = RepairDebt(repair).operation,
                      operation.hasPrefix("cognition.persist:") else { continue }
                let stage = String(operation.dropFirst("cognition.persist:".count))
                if stage != "mind.self", stage != "mind.self.read", stage != "clear" { supersededStages.insert(stage) }
            }
            clearedAt = dependencies.now()
            epoch = try await store.clear(at: clearedAt)
        } catch {
            // A failed Clear owes one repair for discarded writes; mark affect/nodes dirty and let each other owner save its current state at its next write.
            oweFailedClear(forgettingDiscarded, error: error)
            forgettingDiscarded.removeAll()
            markDirty(at: dependencies.now())
            endForgetting()
            throw error
        }
        clearResidentState()
        mindEpoch = epoch
        mindClearedAt = clearedAt
        for stage in supersededStages {
            unsavedStages.remove(stage)
            RepairOwed.settle(conversationDataRoot, operation: "cognition.persist:" + stage,
                evidence: .init(source: "cognition/cognition.sqlite", id: "clear:mind:\(epoch)"))
        }
        RepairOwed.settle(conversationDataRoot, operation: "cognition.persist:clear",
            evidence: .init(source: "cognition/cognition.sqlite", id: "clear:mind:\(epoch)"))
        if configuration.persistenceEnabled {
            persistenceRestored = true
            persistenceHealth = CognitivePersistenceHealth(
                status: unsavedStages.isEmpty ? .healthy : .degraded, writesBlocked: false,
                lastRestoreAttemptAt: persistenceHealth.lastRestoreAttemptAt,
                lastSuccessfulRestoreAt: dependencies.now(),
                failureStage: unsavedStages.isEmpty ? nil : "unsaved",
                failureDetail: unsavedStages.isEmpty ? nil : "unsaved: " + unsavedStages.sorted().joined(separator: ", "))
        }
        await notingPersistence("mind.self") {
            let path = CognitiveSelfKnowledge.path(conversationDataRoot)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            // Checked deletion retires the old file's read debt as well; a read of an older valid file cannot retire a failed nightly save.
            await notingPersistence("mind.self.read") { }
        }
        endForgetting()
        forgettingDiscarded.removeAll()
        await saveResidentAfterForgetting()
    }

    /// Release Clear's holds: the lifecycle hold, the maintenance transition and the microcycle commit ownership (handed to a waiting microcycle).
    private func endForgetting() {
        forgettingInFlight = false
        if microcycleWaiters.isEmpty { maintenanceCommitInFlight = false }
        else { microcycleWaiters.removeFirst().resume() }
        endMaintenanceTransition()
        releaseLifecycleHold()
    }

    /// The resident affect and field after a successful Clear (every other family is empty or re-seeded by `establishCares`).
    private func saveResidentAfterForgetting() async {
        guard configuration.enabled, configuration.persistenceEnabled else { return }
        await notingPersistence("snapshot") { try await persistAffectAndNodes() }
    }


}

extension CognitiveSubstrate {
    public func observe(_ event: CognitiveEvent) async {
        await ingest(event)
    }
}
