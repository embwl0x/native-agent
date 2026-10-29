import Foundation
import ApprovalInbox
import ChatToolRuntime
import AgentConversations
import CognitiveSubstrate
import Context
import ContextFlow
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import Desk
import Experiences
import AuthoredCapabilities
import NativeAgentShared
import Studio
import Transcripts
import BackgroundLoops
import ChatTurnRuntime
import DreamREMCycle
import ProviderRouting
// Blueprint: | `NativeCognitionRuntime.swift` | `NativeCognitionRuntime` actor composition, retained state and sensory admission; run-scoped turn classification and live-turn latches |

public actor NativeCognitionRuntime: CognitiveRuntimeProviding {
    public let dataRoot: URL
    /// The app-owned pieces this mind reaches (see CognitionHost).
    let host: any CognitionHost
    /// The engine root's ContextFlow, reloaded from the live body.
    let contextFlow: NativeContextFlowRuntime
    public var usesLiveAppBody: Bool {
        dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
    }
    public let now: @Sendable () -> Date
    /// Monotonic timing for duration evidence. Wall time remains the semantic
    /// event clock, but NTP/manual clock corrections cannot alter latency.
    let monotonicNowNanoseconds: @Sendable () -> UInt64
    let preferenceDefaults = UserDefaults.standard
    let configurationEnvironment: [String: String]
    let cognitiveStore: CognitiveSQLiteStore?  // internal: the door (+Door) records moments in it
    public let substrate: CognitiveSubstrate
    public let organismKernel: OrganismKernel
    let somaticSignalBus: SomaticSignalBus
    /// Existing provider-call observations feed passive vitals and graded somatic signals.
    /// Adds no provider calls or turn-path disk I/O.
    let providerVitalsSensor = ProviderVitalsSensor()
    /// Published by the canonical owners after mutation; ordinary turns read
    /// this without entering the runtime, substrate, or organism actors.
    nonisolated let attentionProjection: ResidentAttention
    /// Reentrant launch callers join one bootstrap task.
    var bootstrapTask: Task<Void, Never>?
    var bootstrapChoresTask: Task<Void, Never>?
    var recentLifeTask: Task<Void, Never>?
    var bootstrapFailure: String?
    /// One process-local subscription to the canonical ApprovalInbox owner.
    /// It turns durable request/resolution edges into correlated body evidence.
    var approvalLifecycleObservationTask: Task<Void, Never>?
    /// Provider picker authority can fail independently of cognitive-state
    /// restore. It closes only the provider-backed reflection lane and is
    /// cleared after a later checked routing refresh succeeds.
    var providerRoutingFailure: String?
    /// The last live injection, mirrored for display without affecting injection.
    var lastInjectedCapsule: (capsule: CognitiveCapsule, userMessage: String)?
    var organismDebugBodyOverride: OrganismDebugBodyOverride?
    /// Suppress-when-unchanged for the felt body line: the last line actually
    /// injected into a prompt, and when. A held-steady line goes quiet until it
    /// changes or the refresh window elapses, so she doesn't re-narrate the same
    /// mood every turn for hours. Observatory/snapshot paths are unaffected.
    var lastInjectedBodyLine: String?
    var lastInjectedBodyLineAt: Date?
    /// Event-coalesced owner for the fast dirty microcycle. A burst of sensory
    /// events becomes one settle pass; quiet time creates no wake at all.
    var microcycleTimer = StoreReloadDebouncer.Timer()
    var microcycleTelemetry: CognitiveMicrocycleTelemetry
    static let microcycleCoalescingDelay: TimeInterval = 0.25
    var replayReconciliationPending = false
    var replayRetryTask: Task<Void, Never>?
    static let replayFailureRetryDelay: TimeInterval = 30
    /// Reflection rides the same dream/REM somatic commit signal replay
    /// does (clause 4 — no bare-interval LLM heartbeat). Single-flight; the
    /// substrate's budget/reservation gates stay the authority inside
    /// `runReflectionIfDue`.
    var reflectionEventTask: Task<Void, Never>?
    /// Studio canon tending: single-flight, throttled. See
    /// NativeCognitionRuntime+StudioCanon.swift.
    var studioCanonTask: Task<Void, Never>?
    /// The hour, including admission, terminal settlement and claim release.
    var studioWanderTask: Task<Void, Never>?
    var horizonRefreshTask: Task<Void, Never>?
    var reachTask: Task<Void, Never>?
    var sourceWakes = CognitiveSourceWakes()
    var lastStudioCanonTendingAt: Date?
    var lastStudioRelationAuditVerdict: String?
    public static let eventDrivenReplayDeadlineSeconds: TimeInterval = 10
    func deadlineLogger(_ message: String) {
        FileHandle.standardError.write(Data("[NativeCognitionRuntime] \(message)\n".utf8))
    }
    /// One exact quiet-window deadline derived from prediction/field residuals.
    /// New sensory evidence cancels and re-arms it; an empty/low-pressure body
    /// owns no task and therefore creates no idle heartbeat. State and
    /// mechanics and projection live in +Deadlines; this site never reads `scheduledAt`.
    var residualDeadline = CoalescingDeadline()
    /// One exact deadline derived from cognition's real discrete lifecycle
    /// boundaries. Continuous affect and node decay stay
    /// analytic at read time and therefore owns no periodic wake. Shares
    /// the `CoalescingDeadline` mechanics; the force/notBefore/short-circuit
    /// projection stays in `rescheduleCognitionMaintenanceDeadline`.
    var cognitionDeadline = CoalescingDeadline()
    /// Set by `sleep`; blocks the wake
    /// re-anchor from resurrecting deadline timers during app teardown.
    public internal(set) var isFlushedForTermination = false
    /// Owner-emitted invalidations for visible cognition projections. Views
    /// subscribe while mounted instead of rereading the whole mind every five
    /// seconds. Buffering-newest coalesces bursts; the runtime state remains
    /// canonical and the notification carries no cognitive payload.
    var changeRevision: UInt64 = 0
    var changeContinuations: [UUID: AsyncStream<NativeCognitionRuntimeChange>.Continuation] = [:]

    /// Her active Workshop pursuit
    /// colors context selection without making a turn replay Desk's uncapped
    /// canonical op feed. Exact-path owner/file invalidations rebuild this
    /// bounded advisory projection off the cognition actor; the hot read only
    /// re-scores the resident candidates for the supplied time.
    var pursuitCandidates: [DeskItem] = []
    var pursuitCarriedContext: MyQueue.Context?
    let pursuitRead = LatestRead()
    var pursuitReadRevision: UInt64?
    var pursuitCompletedRefreshRevision = SwiftNativeDeskStore.currentRevision
    var pursuitRefreshInFlight = false
    var pursuitRefreshQueued = false
    var pursuitObservationTask: Task<Void, Never>?
    var carriedExperienceObservationTask: Task<Void, Never>?
    var carriedReleaseRunning = false
    var carriedReleaseAgain = false
    var pursuitRefreshTask: Task<Void, Never>?
    var organismContinuityRestored = false
    /// True once the body's restore has FINISHED (decoded, absent, or failed
    /// and frozen). Persistence refuses until then.
    var organismContinuityReadable = false
    /// The one sleep settlement every quit path joins.
    var sleepTask: Task<NativeCognitionSleepOutcome, Never>?
    /// THE DOOR: one fold at a time, exclusive with Clear, Reset Body and
    /// restore (`enterDoor` / `leaveDoor`, +Door).
    var doorHeld = false
    var doorWaiters: [CheckedContinuation<Void, Never>] = []
    /// A failed organism decode freezes continuity persistence.
    var organismRestoreFailedHard = false
    /// Organism continuity writes are serialized through one coalescing drain.
    /// Ordinary sensory acceptance only advances `requestedGeneration`; it never
    /// exports, encodes, or writes state inline. A burst therefore owns one task
    /// and at most one follow-up snapshot while the current write is in flight.
    var organismPersistenceRequestedGeneration: UInt64 = 0
    var organismPersistenceCompletedGeneration: UInt64 = 0
    var organismPersistenceLatestReason = "bootstrap"
    var organismPersistenceDrainTask: Task<Void, Never>?
    var organismPersistenceWaiters: [UInt64: [CheckedContinuation<Bool, Never>]] = [:]
    var organismPersistenceLastResult = true
    var organismPersistenceLastWriteAt: ContinuousClock.Instant?
    var organismPersistenceDebounceTask: Task<Void, Never>?
    /// Non-live classification follows every user, tool and assistant event in its run.
    var nonLiveTurnKindByRunId: [String: CognitiveTurnKind] = [:]
    private var nonLiveTurnKindRunOrder: [String] = []
    static let maximumNonLiveTurnKindRuns = 256

    func rememberNonLiveTurnKind(_ turnKind: CognitiveTurnKind, runId: String) {
        guard turnKind != .live else {
            nonLiveTurnKindByRunId.removeValue(forKey: runId)
            nonLiveTurnKindRunOrder.removeAll { $0 == runId }
            return
        }
        if nonLiveTurnKindByRunId.updateValue(turnKind, forKey: runId) == nil {
            nonLiveTurnKindRunOrder.append(runId)
        }
        while nonLiveTurnKindRunOrder.count > Self.maximumNonLiveTurnKindRuns {
            let stale = nonLiveTurnKindRunOrder.removeFirst()
            nonLiveTurnKindByRunId.removeValue(forKey: stale)
        }
    }

    func finishNonLiveTurn(runId: String) {
        nonLiveTurnKindByRunId.removeValue(forKey: runId)
        nonLiveTurnKindRunOrder.removeAll { $0 == runId }
    }

    /// Unique admitted runs in admission order, independent of microcycles.
    private var liveTurnRunOrder: [String] = []
    static let maximumLiveTurnRuns = 64
    /// Admission edge. The user's message row is persisted and observed BEFORE
    /// the provider call begins, so this is the earliest honest "a turn is
    /// running" moment the runtime is given.
    func noteTurnStarted(runId: String) {
        let key = runId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if !liveTurnRunOrder.contains(key) {
            liveTurnRunOrder.append(key)
        }
        while liveTurnRunOrder.count > Self.maximumLiveTurnRuns {
            liveTurnRunOrder.removeFirst()
        }
    }

    /// Terminal settlement edge: the assistant reply (or the run's provider
    /// failure) has been persisted. Cancelled turns still append their assistant
    /// row, so they release the latch too.
    func noteTurnFinished(runId: String) {
        let key = runId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        liveTurnRunOrder.removeAll { $0 == key }
    }

    /// Latch the admission edge off the event the runtime already receives.
    func noteChatTurnAdmission(_ event: CognitiveEvent) {
        guard event.kind == .userMessageReceived,
              case .string(let runId)? = event.metadata["runId"] else { return }
        noteTurnStarted(runId: runId)
    }

    /// Turns admitted and not yet terminal, including long-running work.
    func liveTurnLatchCount() -> Int { liveTurnRunOrder.count }

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        host: any CognitionHost,
        contextFlow: NativeContextFlowRuntime,
        configurationEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() },
        monotonicNowNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        let preferenceDefaults = UserDefaults.standard
        self.dataRoot = dataRoot
        self.host = host
        self.contextFlow = contextFlow
        self.now = now
        self.monotonicNowNanoseconds = monotonicNowNanoseconds
        self.configurationEnvironment = configurationEnvironment
        let telemetry = CognitiveMicrocycleTelemetry.fresh(now: now())
        self.microcycleTelemetry = telemetry
        let configuration = Self.loadConfiguration(
            defaults: preferenceDefaults,
            environment: configurationEnvironment
        )
        let organismConfiguration = Self.loadOrganismConfiguration(
            dataRoot: dataRoot,
            defaults: preferenceDefaults
        )
        let store = try? CognitiveSQLiteStore(dataRoot: dataRoot)
        self.cognitiveStore = store
        let attentionProjection = ResidentAttention()
        self.attentionProjection = attentionProjection
        // Resolve the user's configured name live so the capsule/reflection cues
        // address whoever the install belongs to (never a hardcoded "User"). The
        // closure re-reads profile.json each call so a rename takes effect next
        // capsule; missing/blank → "" and the substrate falls back to "you".
        let root = dataRoot
        let kernel = OrganismKernel(
            configuration: organismConfiguration,
            dependencies: OrganismDependencies(
                now: now,
                predictedToolGroupsSink: { groups in
                    attentionProjection.replacePredictedToolGroups(groups)
                }
            )
        )
        let growthProjection = GrowthWeekFace(dataRoot: root, host: host)
        self.substrate = CognitiveSubstrate(
            configuration: store == nil
                ? Self.configurationWithoutPersistence(configuration)
                : configuration,
            dependencies: CognitiveSubstrateDependencies(
                now: now,
                userName: { NativeCognitionRuntime.resolveUserName(dataRoot: root) },
                attentionProjectionSink: { signals in
                    attentionProjection.replaceSubstrate(signals)
                },
                // Resolve traits once per calculation so edits take effect on its next read.
                dynamics: {
                    let traits = PersonaCompiler.loadProfile(dataRoot: root).traits
                    return .derived(warmth: traits.warmth, humor: traits.humor)
                },
                // Last night's dream residue and what happened in a
                // gap — local reads and the already-warm embedder, nothing else.
                dreamThemes: { message, spent in
                    let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: root)
                    return await NativeCognitionRuntime.dreamThemes(
                        message: message, excluding: spent, dataRoot: root, now: now(),
                        // Warm only: turn preparation never loads the model.
                        isWarm: {
                            guard let runtime = await memory.embeddingRuntimeSnapshot() else { return false }
                            return runtime.effectiveBackend != ManagedEmbeddingProvider.failClosedBackend
                                && runtime.coreMLLoaded
                        },
                        embeddingEpoch: { await memory.embeddingEpoch() },
                        embed: { try await memory.embedForDerivedContextWithEpoch($0) },
                        embedQuery: { try await memory.embedQueriesWithEpoch($0) })
                },
                // Warm only. `mind.reflect` can run this inside a
                // live turn, so it never loads the model or takes its load
                // lock; cold means the lexical match alone.
                embedTexts: { texts in
                    await SwiftNativeMemoryV2.resolvedOwner(dataRoot: root).embedIfWarm(texts)
                },
                peerTrusted: { PeerTrust.ownerTrusts($0, dataRoot: root) },
                surfaceIsPrivate: {
                    MemoryRecordDisclosurePolicy.localPrivateSurfaces.contains(
                        MemoryRecordDisclosurePolicy.canonicalSurface($0))
                },
                sinceGap: { from, to, surface in
                    await NativeCognitionRuntime.sinceGapItems(from: from, to: to, surface: surface, dataRoot: root)
                },
                decisions: {
                    do {
                        return try await SwiftNativeApprovalInbox(root: root)
                            .decisionsForREM()
                    } catch {
                        nativeLog("[cognition] decision unavailable: \(error)")
                        return [:]
                    }
                },
                growthProjection: { await growthProjection.read($0) }
            ),
            store: store
        )
        self.organismKernel = kernel
        self.somaticSignalBus = SomaticSignalBus(
            configuration: organismConfiguration,
            observer: self.organismKernel
        )
    }

    deinit {
        sourceWakes.cancelObservations()
        approvalLifecycleObservationTask?.cancel()
        pursuitObservationTask?.cancel()
        carriedExperienceObservationTask?.cancel()
        pursuitRefreshTask?.cancel()
        organismPersistenceDrainTask?.cancel()
    }

    public func observe(_ event: CognitiveEvent) async {
        await bootstrap()
        let inherited = inheritNonLiveTurnKind(for: event)
        // Chat-turn lifecycle latch opens at admission, BEFORE the provider
        // call this event's run is about to make (see `noteTurnStarted`).
        noteChatTurnAdmission(inherited.event)
        let admission = await substrate.ingestResident(inherited.event)
        // Semantic consequences arrive with the admission that produced them.
        var enriched = inherited.event
        for (key, value) in admission.semanticMetadata {
            enriched.metadata[key] = value
        }
        let somaticAccepted = await somaticSignalBus.observe(enriched) != nil
        // The signal itself is transport and moved no feeling;
        // when it is her own work landing (or failing), that is felt here.
        if somaticAccepted, let dose = CognitiveSomaticSignals.ownOutcomeDose(enriched) {
            await organismKernel.admitHumanCause(agency: dose.agency, confidence: dose.confidence)
        }
        if let completedRunId = inherited.completedRunId {
            finishNonLiveTurn(runId: completedRunId)
            noteTurnFinished(runId: completedRunId)
        }
        // Exact replay is inert across both resident owners. It must not create
        // settlement work, invalidations, or telemetry.
        guard admission.accepted || somaticAccepted else { return }
        // The completion slot and live-turn timing are in-memory sources.
        if inherited.event.kind == .userMessageReceived || inherited.event.kind == .assistantTurnCompleted || inherited.event.kind == .providerFailure {
            sourceWakes.horizonDirty = true
            sourceWakes.reachDirty = true
        }
        if somaticAccepted {
            cachedBodyRead = nil
            // Both kernel-feed paths drain felt resolutions into the substrate.
            await drainFeltResolutionsIntoSubstrate()
        }
        if admission.accepted {
            scheduleDirtyMicrocycle(reason: "event:\(inherited.event.kind.rawValue)")
        }
        if somaticAccepted { await rescheduleResidualRepairDeadline() }
        publishRuntimeChange(reason: "event:\(inherited.event.kind.rawValue)")
        // Keep this as the final non-suspending action. The sole persistence
        // drain cannot enter the actor until this acceptance turn returns.
        if somaticAccepted {
            scheduleOrganismContinuityPersistence(
                reason: "event:\(inherited.event.kind.rawValue)"
            )
        }
    }

    /// Existing cognition persistence owns this payload-free replay guard; it
    /// is not another action authority or memory system.
    func admitMotorConsequenceForResident(_ model: MotorActionReadModel, at: Date) async -> Bool {
        // The replay guard is part of her saved mind: admitted only after the opening.
        await bootstrap()
        guard let cognitiveStore else {
            deadlineLogger("motor consequence replay guard unavailable; resident observation skipped")
            return false
        }
        do {
            return try await cognitiveStore.admitMotorConsequence(model, at: at)
        } catch {
            deadlineLogger("motor consequence replay guard failed closed: \(error)")
            return false
        }
    }

    /// Composite body gauges are sampled for two seconds; debug overrides apply after the cache.
    var cachedBodyRead: (read: OrganismBodyRead, at: Date)?
    /// Payload-free, process-local provider lifecycle evidence. Canonical
    /// successful call receipts are reloaded from the injected trace root at
    /// bootstrap; live started/terminal events replace the same call ID.
    /// This is a transient belief input, never provider-selection authority.
    var providerLifecycleEvidenceByCallID: [String: ProviderPathEvidence] = [:]
    static let providerLifecycleExpiry: TimeInterval = 45
    static let maximumProviderLifecycleEvidence = 32

    @discardableResult
    public func clearTransientState() async -> CognitiveTransientStateClearOutcome {
        let outcome = await clearTransientStateOnce()
        await syncBodyEpoch()
        return outcome
    }

    private func clearTransientStateOnce() async -> CognitiveTransientStateClearOutcome {
        // Forgetting is checked recovery, but it still runs only on a mind that
        // has been opened: a clear before restore would be overlaid by it.
        await bootstrap()
        // Clear holds the door: it waits for a fold in flight, and a fold waits for it.
        await enterDoor()
        defer { leaveDoor() }
        guard cognitiveStore != nil else {
            let detail = "cognitive persistent store unavailable"
            await substrate.recordReceipt(
                kind: "user.clear_transient_state_failed",
                payload: .object(["error": .string(detail)])
            )
            publishRuntimeChange(reason: "transient_clear:failed")
            return .persistenceFailed(detail)
        }
        do {
            // The store, the mind's forgetting epoch and her resident mind,
            // under one logical exclusion (`CognitiveSubstrate.forgetMind`).
            try await substrate.forgetMind()
            bootstrapFailure = nil
        } catch {
            // A failed Clear marked her resident mind dirty: the microcycle
            // re-saves affect and nodes through its normal path.
            scheduleDirtyMicrocycle(reason: "clear_failed")
            let detail = String(describing: error)
            await substrate.recordReceipt(
                kind: "user.clear_transient_state_failed",
                payload: .object(["error": .string(detail)])
            )
            publishRuntimeChange(reason: "transient_clear:failed")
            return .persistenceFailed(detail)
        }
        // The wiped store keeps its four seeds; her life is read again at the next launch.
        await substrate.establishCares()
        await organismKernel.clearTransientState()
        await syncBodyEpoch()
        await rescheduleCognitionMaintenanceDeadline()
        lastInjectedCapsule = nil
        lastInjectedBodyLine = nil
        lastInjectedBodyLineAt = nil
        // Clear is checked recovery for the body too: an emptied body may be
        // written over a file whose restore failed (the freeze comes back if
        // that write fails).
        let wasRestoreFrozen = organismRestoreFailedHard
        organismRestoreFailedHard = false
        guard await persistOrganismContinuity(reason: "clear transient") else {
            // Clear again to finish a partial clear; forgetting is not journaled.
            organismRestoreFailedHard = wasRestoreFrozen
            await substrate.recordReceipt(kind: "user.clear_transient_state_partial")
            publishRuntimeChange(reason: "transient_clear:partial")
            return .bodyPersistenceFailed
        }
        await substrate.recordReceipt(kind: "user.clear_transient_state")
        publishRuntimeChange(reason: "transient_clear:completed")
        return .cleared
    }

    public func setAblation(_ key: String, enabled: Bool) async {
        await substrate.setAblation(key, enabled: enabled)
        publishRuntimeChange(reason: "experiment:ablation")
    }

    @discardableResult
    public func pinTopConcern(text: String? = nil, care: String? = nil, seat: StudioCanonTurnProvenance) async throws -> String? {
        guard seat.isComplete else { return nil }
        await bootstrap()
        guard let concern = try await substrate.pinConcern(text, in: care, source: "turn:\(seat.surface)/\(seat.turnID)") else { return nil }
        scheduleDirtyMicrocycle(reason: "concern_pinned")
        publishRuntimeChange(reason: "care:pinned")
        return concern
    }

    /// True from chat-turn admission through terminal settlement, counted by
    /// runId. Internal microcycles are not turns and do not hold her free time.
    public var liveTurnInFlight: Bool {
        liveTurnLatchCount() > 0
    }

}
