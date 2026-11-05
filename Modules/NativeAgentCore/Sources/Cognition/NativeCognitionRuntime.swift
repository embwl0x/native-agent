import Foundation
import ApprovalInbox
import ChatToolRuntime
import AgentConversations
import AgentWorkspace
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
// Blueprint: | `NativeCognitionRuntime.swift` | `NativeCognitionRuntime`. |

public actor NativeCognitionRuntime: CognitiveRuntimeProviding {
    public let dataRoot: URL
    let host: any CognitionHost
    let contextFlow: NativeContextFlowRuntime
    public var usesLiveAppBody: Bool {
        dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
    }
    public let now: @Sendable () -> Date
    /// Use monotonic time for latency so clock corrections cannot change durations; wall time still owns semantic event time.
    let monotonicNowNanoseconds: @Sendable () -> UInt64
    let preferenceDefaults = UserDefaults.standard
    let configurationEnvironment: [String: String]
    let cognitiveStore: CognitiveSQLiteStore?
    public let substrate: CognitiveSubstrate
    /// This mind's journal dependency, shared explicitly with its journal writer.
    public nonisolated let studioJournalBus: StudioJournalCognitiveBus
    public let organismKernel: OrganismKernel
    let somaticSignalBus: SomaticSignalBus
    /// Feed passive vitals from real provider observations without more calls or turn-path I/O.
    let providerVitalsSensor = ProviderVitalsSensor()
    /// Publish after owner mutation so ordinary turns need no runtime, substrate or body actor hop.
    nonisolated let attentionProjection: ResidentAttention
    /// Reentrant launch callers join one bootstrap task.
    var bootstrapTask: Task<Void, Never>?
    var bootstrapChoresTask: Task<Void, Never>?
    var bootstrapFailure: String?
    let cognitiveStoreOpeningFailure: String?
    let caringReceiptLog: CaringReceiptLog
    var eventReplayTask: Task<LoopTickOutcome, Never>?
    var eventReplayAgain = false
    var replayTask: Task<LoopTickOutcome, Never>?
    /// Nil requests no automatic reflection; dream work retains its own authority.
    var replayReflectionMaterial: [String: CognitiveReflectionCause]?
    /// Share one canonical inbox subscription so request and decision retain correlated body identity.
    var approvalLifecycleObservationTask: Task<Void, Never>?
    /// Routing authority failure closes only provider reflection; a later checked refresh can clear it independently of state restore.
    var providerRoutingFailure: String?
    /// Mirror the last injection for display without affecting cadence.
    var lastInjectedCapsule: (capsule: CognitiveCapsule, userMessage: String)?
    var organismDebugBodyOverride: OrganismDebugBodyOverride?
    /// Suppress unchanged injected body lines until change or refresh so a steady mood cannot repeat every turn.
    /// Inspection remains nonconsuming.
    var lastInjectedBodyLine: String?
    var lastInjectedBodyLineAt: Date?
    /// Coalesce sensory bursts into one dirty-settlement pass; quiet time creates no wake.
    var microcycleTimer = StoreReloadDebouncer.Timer()
    var microcycleTelemetry: CognitiveMicrocycleTelemetry
    static let microcycleCoalescingDelay: TimeInterval = 0.25
    var replayReconciliationPending = false
    var replayRetryTask: Task<Void, Never>?
    static let replayFailureRetryDelay: TimeInterval = 30
    /// Use committed dream/REM signals rather than an LLM heartbeat; runReflectionIfDue owns admission and reservation.
    var reflectionEventTask: Task<Void, Never>?
    var studioCanonTask: Task<Void, Never>?
    /// Retain the hour through admission, terminal settlement and claim release.
    var studioWanderTask: Task<Void, Never>?
    var horizonRefreshTask: Task<Void, Never>?
    var reachTask: Task<Void, Never>?
    var sourceWakes = CognitiveSourceWakes()
    var rhythm = RhythmRuntimeState()
    var lastStudioCanonTendingAt: Date?
    var lastStudioRelationAuditVerdict: String?
    public static let eventDrivenReplayDeadlineSeconds: TimeInterval = 10
    func deadlineLogger(_ message: String) {
        FileHandle.standardError.write(Data("[NativeCognitionRuntime] \(message)\n".utf8))
    }
    /// Arm only at the exact quiet-repair boundary; empty or low-pressure state owns no idle heartbeat.
    var residualDeadline = CoalescingDeadline()
    /// Use real discrete lifecycle boundaries; analytic affect and node decay require no periodic wake.
    var cognitionDeadline = CoalescingDeadline()
    /// Termination latches before cancellation so wake reanchoring cannot resurrect deadline tasks.
    public internal(set) var isFlushedForTermination = false
    /// Publish payload-free invalidations to mounted views instead of polling; canonical runtime state survives coalesced bursts.
    var changeRevision: UInt64 = 0
    var changeContinuations: [UUID: AsyncStream<NativeCognitionRuntimeChange>.Continuation] = [:]

    /// Rebuild pursuit off-actor from exact-path invalidations so turns score bounded resident candidates without replaying Desk I/O.
    var pursuitCandidates: [DeskItem] = []
    var pursuitCarriedContext: MyQueue.Context?
    let pursuitRead = LatestRead()
    var pursuitReadRevision: UInt64?
    var pursuitCompletedRefreshRevision = SwiftNativeDeskStore.currentRevision
    var pursuitRefreshInFlight = false
    var pursuitRefreshQueued = false
    var pursuitObservationTask: Task<Void, Never>?
    var carriedExperienceObservationTask: Task<Void, Never>?
    var turnIdleObservationTask: Task<Void, Never>?
    var carriedReleaseRunning = false
    var carriedReleaseAgain = false
    /// Keep intention speech and Desk/wake settlement in the same flight.
    var carriedSayInFlight = false
    var pursuitRefreshTask: Task<Void, Never>?
    var organismContinuityRestored = false
    /// Block persistence until restore finishes, including absent or failed/frozen outcomes.
    var organismContinuityReadable = false
    /// All quit paths join one sleep settlement.
    var sleepTask: Task<NativeCognitionSleepOutcome, Never>?
    /// Serialize folds with Clear, Reset and restore through one door.
    var doorHeld = false
    var doorDone = ScopedWaiter()
    /// A failed decode freezes continuity persistence.
    var organismRestoreFailedHard = false
    /// Serialize continuity writes through one drain; sensory acceptance advances desired generation without inline export or I/O.
    /// Coalesce arrivals to at most one follow-up snapshot per in-flight write.
    var organismPersistenceRequestedGeneration: UInt64 = 0
    var organismPersistenceCompletedGeneration: UInt64 = 0
    var organismPersistenceLatestReason = "bootstrap"
    var organismPersistenceDrainTask: Task<Void, Never>?
    struct OrganismPersistenceWait {
        let done: ScopedWaiter
        var result: Bool?
    }
    var organismPersistenceWaiters: [UInt64: [UUID: OrganismPersistenceWait]] = [:]
    var organismPersistenceLastResult = true
    var organismPersistenceLastWriteAt: ContinuousClock.Instant?
    var organismPersistenceDebounceTask: Task<Void, Never>?
    /// Carry non-live classification through every event in the same run.
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

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        host: any CognitionHost,
        contextFlow: NativeContextFlowRuntime,
        studioJournalBus: StudioJournalCognitiveBus = StudioJournalCognitiveBus(),
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
        self.studioJournalBus = studioJournalBus
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
        let store: CognitiveSQLiteStore?
        do {
            store = try CognitiveSQLiteStore(dataRoot: dataRoot)
            self.cognitiveStoreOpeningFailure = nil
        } catch {
            store = nil
            self.cognitiveStoreOpeningFailure = "cognitive store open failed: \(error.localizedDescription)"
        }
        self.caringReceiptLog = CaringReceiptLog(dataRoot: dataRoot)
        self.cognitiveStore = store
        let attentionProjection = ResidentAttention()
        self.attentionProjection = attentionProjection
        // Read the configured name at use time so renames affect the next capsule; absent names leave neutral address to the substrate.
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
            configuration: configuration,
            dependencies: CognitiveSubstrateDependencies(
                now: now,
                userName: { try NativeCognitionRuntime.resolveUserName(dataRoot: root) },
                attentionProjectionSink: { signals in
                    attentionProjection.replaceSubstrate(signals)
                },
                // Resolve traits once per calculation so edits apply consistently on the next read.
                dynamics: {
                    let traits = try PersonaCompiler.compileProfile(dataRoot: root).traits
                    return .derived(warmth: traits.warmth, humor: traits.humor)
                },
                // Use local continuity reads and an already-warm embedder only.
                dreamThemes: { message, spent in
                    let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: root)
                    return await NativeCognitionRuntime.dreamThemes(
                        message: message, excluding: spent, dataRoot: root, now: now(),
                        // Turn preparation cannot load the embedding model.
                        isWarm: {
                            guard let runtime = await memory.embeddingRuntimeSnapshot() else { return false }
                            return runtime.effectiveBackend != ManagedEmbeddingProvider.failClosedBackend
                                && runtime.coreMLLoaded
                        },
                        embeddingEpoch: { await memory.embeddingEpoch() },
                        embed: { try await memory.embedForDerivedContextWithEpoch($0) },
                        embedQuery: { try await memory.embedQueriesWithEpoch($0) })
                },
                // mind.reflect can run during a live turn; use only a warm embedder without its load lock and keep inference failures unavailable.
                embedTexts: { texts in
                    guard let batch = try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: root).embedIfWarmWithEpoch(texts) else { return nil }
                    return CognitiveEmbeddingBatch(epoch: batch.epoch.rawValue, vectors: batch.vectors)
                },
                embeddingEpoch: { await SwiftNativeMemoryV2.resolvedOwner(dataRoot: root).warmEmbeddingEpoch() },
                peerTrusted: { PeerTrust.ownerTrusts($0, dataRoot: root) },
                carePersonAliases: {
                    try AgentContactIdentity(dataRoot: root, peers: AgentPeerStore(dataRoot: root).list()).aliases
                },
                surfaceIsPrivate: {
                    MemoryRecordDisclosurePolicy.localPrivateSurfaces.contains(
                        MemoryRecordDisclosurePolicy.canonicalSurface($0))
                },
                sinceGap: { from, to, surface in
                    await NativeCognitionRuntime.sinceGapItems(from: from, to: to, surface: surface, dataRoot: root)
                },
                decisions: {
                    do {
                        return CognitiveCueRead(try await SwiftNativeApprovalInbox(root: root)
                            .decisionsForREM())
                    } catch {
                        return CognitiveCueRead([:],
                            unreadable: ["""
                                Approval decisions unavailable: \(error.localizedDescription). Repair the approval store before reading proposal outcomes.
                                """])
                    }
                },
                remReplacements: {
                    let read = REMProposalStore(dataRoot: root).loadAllChecked()
                    guard read.unreadable.isEmpty else {
                        return CognitiveCueRead<[String: String]>([:], unreadable: read.unreadable)
                    }
                    var descriptions: [String: String] = [:]
                    for row in read.rows { descriptions[row.id] = REMReplacement.describe(row.replaced) }
                    return CognitiveCueRead(descriptions, unreadable: read.unreadable)
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
        rhythm.observation?.cancel()
        rhythm.refresh?.cancel()
        approvalLifecycleObservationTask?.cancel()
        pursuitObservationTask?.cancel()
        carriedExperienceObservationTask?.cancel()
        turnIdleObservationTask?.cancel()
        pursuitRefreshTask?.cancel()
        organismPersistenceDrainTask?.cancel()
    }

    public func observe(_ event: CognitiveEvent) async {
        await bootstrap()
        let inherited = inheritNonLiveTurnKind(for: event)
        let admission = await substrate.ingestResident(inherited.event)
        // Keep semantic consequences attached to their originating admission.
        var enriched = inherited.event
        for (key, value) in admission.semanticMetadata {
            enriched.metadata[key] = value
        }
        let somaticAccepted = await somaticSignalBus.observe(enriched) != nil
        // Transport signals move no feeling; appraise only the agent's own work outcome here.
        if somaticAccepted, let dose = CognitiveSomaticSignals.ownOutcomeDose(enriched) {
            await organismKernel.admitHumanCause(agency: dose.agency, confidence: dose.confidence)
        }
        if let completedRunId = inherited.completedRunId {
            finishNonLiveTurn(runId: completedRunId)
        }
        // Exact replay is inert in both owners; it creates no settlement, invalidation or telemetry.
        guard admission.accepted || somaticAccepted else { return }
        // Completion and live-turn timing are in-memory sources.
        if inherited.event.kind == .userMessageReceived || inherited.event.kind == .assistantTurnCompleted || inherited.event.kind == .providerFailure {
            sourceWakes.horizonDirty = true
            sourceWakes.reachDirty = true
        }
        if somaticAccepted {
            cachedBodyRead = nil
            // Drain felt resolutions from both kernel-feed paths into the substrate.
            await drainFeltResolutionsIntoSubstrate()
        }
        if admission.accepted {
            scheduleDirtyMicrocycle(reason: "event:\(inherited.event.kind.rawValue)")
        }
        if somaticAccepted { await rescheduleResidualRepairDeadline() }
        publishRuntimeChange(reason: "event:\(inherited.event.kind.rawValue)")
        // Keep persistence scheduling last and nonsuspending so its drain cannot enter until acceptance returns.
        if somaticAccepted {
            scheduleOrganismContinuityPersistence(
                reason: "event:\(inherited.event.kind.rawValue)"
            )
        }
    }

    /// Keep payload-free replay deduplication in cognition persistence, never as another memory or action authority.
    func admitMotorConsequenceForResident(_ model: MotorActionReadModel, at: Date) async -> Bool {
        // Admit the saved replay guard only after opening.
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

    /// Apply debug overrides after the two-second composite-gauge cache.
    var cachedBodyRead: (read: OrganismBodyRead, at: Date)?
    /// Reload canonical successful receipts at bootstrap and replace live call IDs in transient evidence.
    /// Provider lifecycle beliefs never select routing authority.
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
        // Clear requires opened state or later restore could overwrite forgetting.
        await bootstrap()
        // Clear and folds exclude each other through the door.
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
            // Exclude store, forgetting epoch and resident state changes as one logical operation.
            try await substrate.forgetMind()
            bootstrapFailure = nil
        } catch {
            // A failed Clear remains dirty so normal microcycle persistence can settle affect and nodes.
            scheduleDirtyMicrocycle(reason: "clear_failed")
            let detail = String(describing: error)
            await substrate.recordReceipt(
                kind: "user.clear_transient_state_failed",
                payload: .object(["error": .string(detail)])
            )
            publishRuntimeChange(reason: "transient_clear:failed")
            return .persistenceFailed(detail)
        }
        // Keep four seeds after clearing; reread life on the next launch.
        await substrate.establishCares()
        await organismKernel.clearTransientState()
        await syncBodyEpoch()
        await rescheduleCognitionMaintenanceDeadline()
        lastInjectedCapsule = nil
        lastInjectedBodyLine = nil
        lastInjectedBodyLineAt = nil
        // Clear may replace damaged body continuity; a failed write restores its persistence freeze.
        let wasRestoreFrozen = organismRestoreFailedHard
        organismRestoreFailedHard = false
        guard await persistOrganismContinuity(reason: "clear transient") else {
            // Repeat Clear to finish partial forgetting because forgetting is not journalled.
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

    /// ChatTurnSteering owns live-turn windows; internal microcycles do not hold the agent's free time.
    public var liveTurnInFlight: Bool {
        ChatTurnSteering.hasOpenResidentTurn(dataRoot: dataRoot)
    }

    /// A live turn other than the one that asked.
    func liveTurnInFlight(besides session: String?) -> Bool {
        ChatTurnSteering.hasOpenResidentTurn(dataRoot: dataRoot, besides: session)
    }

}
