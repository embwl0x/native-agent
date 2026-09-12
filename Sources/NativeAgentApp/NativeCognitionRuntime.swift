import Foundation
import ChatOrchestration
import CognitiveSubstrate
import Context
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting

actor NativeCognitionRuntime: CognitiveRuntimeProviding, OrganismPostureProviding {
    static let shared = NativeCognitionRuntime()

    let dataRoot: URL
    var usesLiveAppBody: Bool {  // internal for actor extensions (move-only Wave C)
        dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
    }
    let now: @Sendable () -> Date  // internal for actor extensions (move-only Wave C)
    /// Monotonic timing for duration evidence. Wall time remains the semantic
    /// event clock, but NTP/manual clock corrections cannot alter latency.
    private let monotonicNowNanoseconds: @Sendable () -> UInt64
    let microcycleSchedulingMode: CognitiveMicrocycleSchedulingMode  // internal for actor extensions (move-only Wave C)
    let configurationOverride: CognitiveConfiguration?  // internal for actor extensions (move-only Wave C)
    /// The durable preference owner used by the real Observatory/Settings
    /// control actions. Production uses `.standard`; isolated mounted tests
    /// inject a suite without replacing the action or runtime configuration.
    let preferenceDefaults: UserDefaults  // internal for actor extensions
    private let configurationEnvironment: [String: String]
    /// Explicit test-only escape hatch for proving the same canonical reflection
    /// route transaction on an injected root. Production defaults to false.
    let allowsReflectionSelectionMutationForTesting: Bool
    private let organismConfigurationOverride: OrganismConfiguration?
    private let cognitiveStore: CognitiveSQLiteStore?
    let substrate: CognitiveSubstrate  // internal for actor extensions (move-only Wave C)
    let organismKernel: OrganismKernel  // internal for actor extensions (move-only Wave C)
    private let somaticSignalBus: SomaticSignalBus  // G-M3: private — no external refs
    /// INTEROCEPTION (prerelease campaign): passive per-provider vitals sensor.
    /// Fed from `observeProviderCall` — the SAME lifecycle seam — with zero new
    /// provider calls and zero turn-path disk I/O. Band transitions become
    /// graded somatic signals; sustained degradation stages ONE approval card.
    let providerVitalsSensor = ProviderVitalsSensor()  // internal for actor extensions
    /// Single-flight latch for the background vitals card sweep (gpt-5.5
    /// review: proposal-store I/O must never be awaited on the turn path;
    /// card↔provider association is derived from the store via the evidence
    /// marker, never remembered in memory — restart-safe by construction).
    var providerVitalsCardSweepInFlight = false  // internal for actor extensions
    /// Published by the canonical owners after mutation; ordinary turns read
    /// this without entering the runtime, substrate, or organism actors.
    nonisolated let attentionProjection: CognitiveAttentionResidentProjection  // internal for actor extensions (move-only Wave C)
    /// Audit C4 (2026-07-09): bootstrap is memoized as a Task so REENTRANT callers
    /// (the two racing detached launch tasks: AppDelegate bootstrap + the background
    /// loops' first microcycle) share ONE execution instead of coin-flipping into a
    /// full second bootstrap (double restorePersistentState, double appWake into
    /// substrate + somatic bus, double persistOrganismContinuity). Actors are
    /// reentrant at await — a bool set at the END of an 8-await function is a gate
    /// with the door open.
    var bootstrapTask: Task<Void, Never>?  // internal for actor extensions (move-only Wave C)
    var bootstrapFailure: String?  // internal for actor extensions (move-only Wave C)
    /// One process-local subscription to the canonical ApprovalInbox owner.
    /// It turns durable request/resolution edges into correlated body evidence.
    var approvalLifecycleObservationTask: Task<Void, Never>?
    /// Provider picker authority can fail independently of cognitive-state
    /// restore. It closes only the provider-backed reflection lane and is
    /// cleared after a later checked routing refresh succeeds.
    var providerRoutingFailure: String?  // internal for actor extensions (move-only Wave C)
    private var lastResearchExportPath: String?
    /// The capsule from Agent's most recent live chat injection, mirrored so the
    /// Observatory shows what she actually received (timestamped) rather than a
    /// synthetic constant-message compile. Display-only — never affects injection.
    private var lastInjectedCapsule: (capsule: CognitiveCapsule, userMessage: String)?
    var organismDebugBodyOverride: OrganismDebugBodyOverride?  // internal for actor extensions (move-only Wave C)
    /// One pending durable reflex journal at a time. A single journal file is
    /// the cross-store transaction authority; the UI is only a convenience.
    var organismReflexReviewingIDs: Set<String> = []
    var organismReflexReviewTransactionInFlight = false
    /// Suppress-when-unchanged for the felt body line: the last line actually
    /// injected into a prompt, and when. A held-steady line goes quiet until it
    /// changes or the refresh window elapses, so she doesn't re-narrate the same
    /// mood every turn for hours. Observatory/snapshot paths are unaffected.
    var lastInjectedBodyLine: String?  // internal for actor extensions (move-only Wave C)
    var lastInjectedBodyLineAt: Date?  // internal for actor extensions (move-only Wave C)
    /// Event-coalesced owner for the fast dirty microcycle. A burst of sensory
    /// events becomes one settle pass; quiet time creates no wake at all.
    private var microcycleGeneration: UInt64 = 0
    private var pendingMicrocycleGeneration: UInt64?
    private var pendingMicrocycleTask: Task<Void, Never>?
    private var microcycleTelemetry: CognitiveMicrocycleTelemetry
    /// Installed elapsed evidence only. Tests and alternate runtimes remain
    /// off unless they inject a generated-evidence recorder explicitly.
    let physiologySoakRecorder: InstalledPhysiologySoakRecorder?  // internal for actor extensions (move-only Wave C)
    let physiologySoakEnablement: InstalledPhysiologySoakEnablement  // internal for actor extensions (move-only Wave C)
    var pendingPhysiologySubmissions = 0  // internal for actor extensions (move-only Wave C)
    var physiologySubmissionGeneration: UInt64 = 0  // internal for actor extensions (move-only Wave C)
    /// One worker preserves ingress/completion order without retaining an
    /// unbounded chain of tasks before the recorder's own bounded buffer.
    var physiologySubmissionQueue: [PhysiologySubmission] = []
    var pendingPhysiologySubmissionLoss: UInt64 = 0
    // Match the recorder's 256-row burst envelope; this is observation only,
    // never backpressure on cognition or chat admission.
    static let maximumPendingPhysiologySubmissions = InstalledPhysiologySoakRecorder.maximumPendingRecords
    var physiologySubmissionTail: Task<Void, Never>?  // internal for actor extensions (move-only Wave C)
    let physiologySubmissionDrainDeadlineSeconds: TimeInterval  // internal for actor extensions (move-only Wave C)
    var physiologySubmissionDrainTimeoutCount: UInt64 = 0  // internal for actor extensions (move-only Wave C)
    static let microcycleCoalescingDelay: TimeInterval = 0.25
    /// Test-visible, process-local proof only. This is not persisted or surfaced;
    /// it lets accelerated tests distinguish "no replay work ran" from "replay
    /// ran but found no evidence," which a receipt count alone cannot prove.
    var eventDrivenReplayAttemptCount: UInt64 = 0  // internal for actor extensions (move-only Wave C)
    private var replayReconciliationPending = false
    private var replayRetryTask: Task<Void, Never>?
    static let replayFailureRetryDelay: TimeInterval = 30
    /// A4.6: reflection rides the same dream/REM somatic commit signal replay
    /// does (clause 4 — no bare-interval LLM heartbeat). Single-flight; the
    /// substrate's budget/reservation gates stay the authority inside
    /// `runReflectionIfDue`. Proof counter mirrors the replay one above.
    var eventDrivenReflectionAttemptCount: UInt64 = 0  // internal for actor extensions
    var reflectionEventTask: Task<Void, Never>?  // internal for actor extensions
    /// Sleep-pressure dream lane (NORTHSTAR clause 4). Single-flight: the
    /// organism may only ever have ONE dream in the air, and the dream's own
    /// provider call must not block signal ingestion, so it rides a detached
    /// task exactly the way event-driven reflection does. See
    /// NativeCognitionRuntime+PressureDream.swift.
    var pressureDreamTask: Task<Void, Never>?  // internal for actor extensions
    var lastPressureDreamDecision: String?  // internal for actor extensions
    /// Change-only key for FIRE-path deferral receipts (kind + reason +
    /// decision), the twin of the quiet-decision suppression `lastPressureDreamDecision`
    /// provides. Cleared whenever a non-deferral pressure-dream receipt lands.
    var lastPressureDreamDeferral: String?  // internal for actor extensions
    var pressureDreamAttemptCount: UInt64 = 0  // internal for actor extensions
    /// Studio encounter lane (desk 903 phases 1 + 4). Single-flight and rate
    /// limited: composing an encounter reads the journal, the consults and the
    /// graph, so it rides the residual-repair deadline the dream lane already
    /// rides rather than owning a timer, and it does not re-read on every
    /// somatic signal. See NativeCognitionRuntime+StudioEncounters.swift.
    /// The event and deadline paths do the real cognition work for the
    /// `cognition_maintenance` / `cognition_replay` / `cognition_reflection`
    /// lanes, and used to report nothing — so those loops only ever recorded the
    /// daily integrity sweep's `.skipped` and their completion stamps never
    /// advanced, which Doctor's dormancy read cannot tell from a dead lane.
    /// They report through `reportLoopOutcome` now. Injectable so a test can
    /// observe the report without reaching into the shared loop manager.
    var loopResultReporterOverride:  // internal for actor extensions
        (@Sendable (String, String, Bool) async -> Void)?
    var studioEncounterTask: Task<Void, Never>?  // internal for actor extensions
    var lastStudioEncounterOutcome: String?  // internal for actor extensions
    var lastStudioEncounterAt: Date?  // internal for actor extensions
    var lastStudioRelationAuditVerdict: String?  // internal for actor extensions
    var studioEncounterAttemptCount: UInt64 = 0  // internal for actor extensions
    /// The ONE owner of the studio-encounter sidecar write. Each persist chains
    /// onto the previous one, so two state changes in quick succession land in
    /// the order they happened instead of racing (Astra audit 2026-09-11,
    /// finding 11). Flushed at termination.
    var studioEncounterPersistTask: Task<Void, Never>?  // internal for actor extensions
    let eventDrivenReflectionOperationOverride:  // internal for actor extensions
        (@Sendable (String) async -> Void)?
    static let eventDrivenReplayDeadlineSeconds: TimeInterval = 10
    static let physiologySubmissionDrainDeadlineSeconds: TimeInterval = 5
    private let eventDrivenReplayTimeoutSeconds: TimeInterval
    private let eventDrivenReplayOperationOverride:
        (@Sendable (String) async -> CognitiveBackgroundRunOutcome)?
    let deadlineLogger: @Sendable (String) -> Void  // internal for actor extensions (move-only Wave C)
    private var eventDrivenReplayTimeoutCount: UInt64 = 0
    /// One exact quiet-window deadline derived from prediction/field residuals.
    /// New sensory evidence cancels and re-arms it; an empty/low-pressure body
    /// owns no task and therefore creates no idle heartbeat. (C6: state +
    /// mechanics live in `CoalescingDeadline`; the projection/fire body stays
    /// below. This site never reads `scheduledAt`.)
    var residualDeadline = CoalescingDeadline()  // internal for actor extensions (move-only Wave C)
    /// One exact deadline derived from cognition's real discrete lifecycle
    /// boundaries. Continuous affect, node, and thought-seed decay stays
    /// analytic at read time and therefore owns no periodic wake. (C6: shares
    /// the `CoalescingDeadline` mechanics; the force/notBefore/short-circuit
    /// projection stays in `rescheduleCognitionMaintenanceDeadline`.)
    var cognitionDeadline = CoalescingDeadline()  // internal for actor extensions (move-only Wave C)
    /// Review round 2 (LOW): set by `flushForTermination`; blocks the wake
    /// re-anchor from resurrecting deadline timers during app teardown.
    var isFlushedForTermination = false  // internal for actor extensions (move-only Wave C)
    private static let cognitionMaintenanceRetryDelay: TimeInterval = 60 * 60
    /// Review round 2 (HIGH): when a DUE maintenance is excluded by the
    /// microcycle's commit window (R-F2), the natural next deadline is
    /// effectively "now" — a plain reschedule would arm a zero-delay task and
    /// hot-loop against a slow SQLite commit. Retry on a short bounded delay
    /// instead; the hour-scale retry above is for gate/error skips, not
    /// momentary commit contention.
    private static let cognitionMaintenanceContentionRetryDelay: TimeInterval = 30
    /// Comb 3 lane 2 item 2: a `conserve` loop budget used to be an INDEFINITE
    /// veto on reflection/replay/cue work. On the evening of 2026-09-11 that
    /// produced 90 deferrals and zero reflections while resource pressure stayed
    /// nominal — the body's fatigue alone closed the only processes that could
    /// integrate the day. Conserve is now a THROTTLE: each lane still gets
    /// deferred, but not starved past this interval. `sleep` is untouched and
    /// still refuses outright, and the thermal and low-power checks below still
    /// apply to the pass.
    static let conserveExpensiveStarvationFloor: TimeInterval = 45 * 60
    /// Last time each expensive lane was let through while conserving. Lives in
    /// the process, not on disk: it bounds how often conserve is overridden, and
    /// a fresh launch is allowed one pass per lane.
    private var conserveExpensivePassAt: [String: Date] = [:]
    /// Owner-emitted invalidations for visible cognition projections. Views
    /// subscribe while mounted instead of rereading the whole mind every five
    /// seconds. Buffering-newest coalesces bursts; the runtime state remains
    /// canonical and the notification carries no cognitive payload.
    private var changeRevision: UInt64 = 0
    private var changeContinuations: [UUID: AsyncStream<NativeCognitionRuntimeChange>.Continuation] = [:]

    /// C2 (2026-07-11), tightened 2026-07-14: her active WORKSHOP pursuit
    /// colors context selection without making a turn replay Desk's uncapped
    /// canonical op feed. Exact-path owner/file invalidations rebuild this
    /// bounded advisory projection off the cognition actor; the hot read only
    /// re-scores the resident candidates for the supplied time.
    var pursuitCandidates: [DeskItem] = []  // internal for actor extensions (move-only Wave C)
    var pursuitProjectionGeneration: UInt64 = 0  // internal for actor extensions (move-only Wave C)
    var pursuitRefreshInFlight = false  // internal for actor extensions (move-only Wave C)
    var pursuitRefreshQueued = false  // internal for actor extensions (move-only Wave C)
    var pursuitObservationTask: Task<Void, Never>?  // internal for actor extensions (move-only Wave C)
    var pursuitRefreshTask: Task<Void, Never>?
    let pursuitStateLoader: @Sendable () async throws -> DeskState  // internal for actor extensions (move-only Wave C)
    private static let bodyLineRefreshInterval: TimeInterval = 20 * 60
    var organismContinuityRestored = false  // internal for actor extensions (move-only Wave C)
    /// Audit C1: set when the organism continuity decode threw; freezes persistOrganismContinuity.
    var organismRestoreFailedHard = false  // internal for actor extensions (move-only Wave C)
    /// Organism continuity writes are serialized through one coalescing drain.
    /// Ordinary sensory acceptance only advances `requestedGeneration`; it never
    /// exports, encodes, or writes state inline. A burst therefore owns one task
    /// and at most one follow-up snapshot while the current write is in flight.
    var organismPersistenceRequestedGeneration: UInt64 = 0  // internal for actor extensions (move-only Wave C)
    var organismPersistenceCompletedGeneration: UInt64 = 0  // internal for actor extensions (move-only Wave C)
    var organismPersistenceLatestReason = "bootstrap"  // internal for actor extensions (move-only Wave C)
    var organismPersistenceDrainTask: Task<Void, Never>?  // internal for actor extensions (move-only Wave C)
    var organismPersistenceWaiters: [UInt64: [CheckedContinuation<Bool, Never>]] = [:]  // internal for actor extensions (move-only Wave C)
    var organismPersistenceLastResult = true  // internal for actor extensions (move-only Wave C)
    let organismPersistenceWriterOverride:  // internal for actor extensions (move-only Wave C)
        (@Sendable (OrganismPersistentState, URL) async throws -> Void)?
    /// Test seam for the required cognition-side half of a reflex review.
    /// Production uses CognitiveSubstrate.recordReceiptChecked.
    let organismReflexReceiptRecorderOverride:  // internal for actor extensions
        (@Sendable (UUID, String, JSONValue) async throws -> Void)?
    var pendingDebugReplySessionIds: Set<String> = []
    /// Sessions whose whole conversation is treated as debug traffic.
    ///
    /// M9 (2026-07-09): this was insert-only. Nothing ever removed a session, so
    /// the set grew for the process lifetime AND a session that was once debug
    /// stayed debug forever. Bounded as a FIFO ring: the oldest marking ages out.
    /// Use `markSessionDebug(_:)` — never `insert` directly, or the order array
    /// and the set drift apart.
    private(set) var debugSessionIds: Set<String> = []
    private var debugSessionIdOrder: [String] = []
    static let maximumDebugSessionIds = 256

    /// Non-live user turns must carry their classification through every event
    /// in the same tool/provider run. ChatOrchestration emits user, tool, and
    /// assistant events independently; without this run-scoped inheritance a
    /// bridge probe entered as `.debug` but Agent's ordinary-language reply was
    /// re-inferred as `.live` and could tint affect/organism continuity.
    var nonLiveTurnKindByRunId: [String: CognitiveTurnKind] = [:]
    private var nonLiveTurnKindRunOrder: [String] = []
    static let maximumNonLiveTurnKindRuns = 256

    /// Mark a session as debug, evicting the oldest marking when over capacity.
    func markSessionDebug(_ sessionId: String) {
        guard debugSessionIds.insert(sessionId).inserted else { return }
        debugSessionIdOrder.append(sessionId)
        guard debugSessionIdOrder.count > Self.maximumDebugSessionIds else { return }
        let stale = debugSessionIdOrder.removeFirst()
        debugSessionIds.remove(stale)
        pendingDebugReplySessionIds.remove(stale)
    }

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

    /// Real chat-turn lifecycle latch (review 2026-09-01, HIGH).
    ///
    /// The coalesced microcycle generation is NOT a turn. `runScheduledMicrocycle`
    /// clears `pendingMicrocycleGeneration` the moment the settlement it owns
    /// starts, while the user's turn — provider stream, tool loop, reply
    /// persistence — keeps running for minutes afterwards. A residual deadline
    /// landing in that window read "no turn in flight" and could start a
    /// pressure dream (or a studio encounter) on top of a live turn.
    ///
    /// No new app-side hook is needed: the runtime is already handed BOTH edges
    /// of every chat turn through `observe`. ChatOrchestration stamps a `runId`
    /// on the admitted `userMessageReceived` row and on that run's terminal
    /// `assistantTurnCompleted` / `providerFailure` (the same correlation
    /// `inheritNonLiveTurnKind` already reads). Keying the latch by runId counts
    /// nested and concurrent turns for free and is idempotent under exact replay.
    var liveTurnStartedAtByRunId: [String: Date] = [:]  // internal for actor extensions
    private var liveTurnRunOrder: [String] = []
    static let maximumLiveTurnRuns = 64
    /// Safety: a latch older than this is not trusted. ChatOrchestration's
    /// `WholeTurnWallClockBudget` clamps EVERY turn — interactive, telegram,
    /// bridge — to `defaultUnattendedSeconds` (3_900), so a latch older than
    /// that cannot belong to a turn that is still running; it belongs to a
    /// terminal event that never arrived. Mirrored rather than imported: that
    /// budget type is internal to the ChatOrchestration module.
    static let liveTurnLatchWallClockBudget: TimeInterval = 3_900

    /// Admission edge. The user's message row is persisted and observed BEFORE
    /// the provider call begins, so this is the earliest honest "a turn is
    /// running" moment the runtime is given.
    func noteTurnStarted(runId: String) {
        let key = runId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let startedAt = now()
        pruneExpiredLiveTurns(asOf: startedAt)
        if liveTurnStartedAtByRunId.updateValue(startedAt, forKey: key) == nil {
            liveTurnRunOrder.append(key)
        }
        while liveTurnRunOrder.count > Self.maximumLiveTurnRuns {
            let stale = liveTurnRunOrder.removeFirst()
            liveTurnStartedAtByRunId.removeValue(forKey: stale)
        }
    }

    /// Terminal settlement edge: the assistant reply (or the run's provider
    /// failure) has been persisted. Cancelled turns still append their assistant
    /// row, so they release the latch too.
    func noteTurnFinished(runId: String) {
        let key = runId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        liveTurnStartedAtByRunId.removeValue(forKey: key)
        liveTurnRunOrder.removeAll { $0 == key }
        pruneExpiredLiveTurns(asOf: now())
    }

    /// Latch the admission edge off the event the runtime already receives.
    func noteChatTurnAdmission(_ event: CognitiveEvent) {
        guard event.kind == .userMessageReceived,
              case .string(let runId)? = event.metadata["runId"] else { return }
        noteTurnStarted(runId: runId)
    }

    /// Turns admitted, not yet terminal, and still inside the wall-clock budget.
    func liveTurnLatchCount() -> Int {
        guard !liveTurnStartedAtByRunId.isEmpty else { return 0 }
        let instant = now()
        return liveTurnStartedAtByRunId.values.filter {
            instant.timeIntervalSince($0) <= Self.liveTurnLatchWallClockBudget
        }.count
    }

    private func pruneExpiredLiveTurns(asOf instant: Date) {
        guard !liveTurnStartedAtByRunId.isEmpty else { return }
        var expired: [String] = []
        for (key, startedAt) in liveTurnStartedAtByRunId
        where instant.timeIntervalSince(startedAt) > Self.liveTurnLatchWallClockBudget {
            expired.append(key)
        }
        guard !expired.isEmpty else { return }
        let expiredKeys = Set(expired)
        for key in expired { liveTurnStartedAtByRunId.removeValue(forKey: key) }
        liveTurnRunOrder.removeAll { expiredKeys.contains($0) }
    }

    init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        configurationOverride: CognitiveConfiguration? = nil,
        preferenceDefaults: NativeCognitionPreferenceDefaults = .standard,
        configurationEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        allowsReflectionSelectionMutationForTesting: Bool = false,
        organismConfigurationOverride: OrganismConfiguration? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        monotonicNowNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        microcycleSchedulingMode: CognitiveMicrocycleSchedulingMode = .automatic,
        installedPhysiologySoakEnabled: Bool? = nil,
        physiologySoakRecorderOverride: InstalledPhysiologySoakRecorder? = nil,
        eventDrivenReplayTimeoutSeconds: TimeInterval = NativeCognitionRuntime.eventDrivenReplayDeadlineSeconds,
        physiologySubmissionDrainDeadlineSeconds: TimeInterval = NativeCognitionRuntime.physiologySubmissionDrainDeadlineSeconds,
        eventDrivenReplayOperationOverride:
            (@Sendable (String) async -> CognitiveBackgroundRunOutcome)? = nil,
        eventDrivenReflectionOperationOverride:
            (@Sendable (String) async -> Void)? = nil,
        deadlineLogger: (@Sendable (String) -> Void)? = nil,
        pursuitStateLoaderOverride: (@Sendable () async throws -> DeskState)? = nil,
        organismPersistenceWriterOverride:
            (@Sendable (OrganismPersistentState, URL) async throws -> Void)? = nil,
        organismReflexReceiptRecorderOverride:
            (@Sendable (UUID, String, JSONValue) async throws -> Void)? = nil
    ) {
        self.dataRoot = dataRoot
        self.now = now
        self.monotonicNowNanoseconds = monotonicNowNanoseconds
        self.microcycleSchedulingMode = microcycleSchedulingMode
        self.preferenceDefaults = preferenceDefaults.defaults
        self.configurationEnvironment = configurationEnvironment
        let telemetry = CognitiveMicrocycleTelemetry.fresh(now: now())
        self.microcycleTelemetry = telemetry
        self.configurationOverride = configurationOverride
        self.allowsReflectionSelectionMutationForTesting = allowsReflectionSelectionMutationForTesting
        self.organismConfigurationOverride = organismConfigurationOverride
        self.eventDrivenReplayTimeoutSeconds = eventDrivenReplayTimeoutSeconds.isFinite
            && eventDrivenReplayTimeoutSeconds >= 0
            ? eventDrivenReplayTimeoutSeconds
            : Self.eventDrivenReplayDeadlineSeconds
        self.physiologySubmissionDrainDeadlineSeconds = physiologySubmissionDrainDeadlineSeconds.isFinite
            && physiologySubmissionDrainDeadlineSeconds >= 0
            ? physiologySubmissionDrainDeadlineSeconds
            : Self.physiologySubmissionDrainDeadlineSeconds
        self.eventDrivenReplayOperationOverride = eventDrivenReplayOperationOverride
        self.eventDrivenReflectionOperationOverride = eventDrivenReflectionOperationOverride
        self.organismPersistenceWriterOverride = organismPersistenceWriterOverride
        self.organismReflexReceiptRecorderOverride = organismReflexReceiptRecorderOverride
        self.pursuitStateLoader = pursuitStateLoaderOverride ?? {
            try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
        }
        self.deadlineLogger = deadlineLogger ?? { message in
            FileHandle.standardError.write(Data("[NativeCognitionRuntime] \(message)\n".utf8))
        }
        let configuration = configurationOverride ?? Self.loadConfiguration(
            defaults: preferenceDefaults.defaults,
            environment: configurationEnvironment
        )
        let organismConfiguration = organismConfigurationOverride
            ?? Self.loadOrganismConfiguration(
                dataRoot: dataRoot,
                defaults: preferenceDefaults.defaults
            )
        let store = try? CognitiveSQLiteStore(dataRoot: dataRoot)
        self.cognitiveStore = store
        let attentionProjection = CognitiveAttentionResidentProjection()
        self.attentionProjection = attentionProjection
        // Resolve the user's configured name live so the capsule/reflection cues
        // address whoever the install belongs to (never a hardcoded "User"). The
        // closure re-reads profile.json each call so a rename takes effect next
        // capsule; missing/blank → "" and the substrate falls back to "you".
        let root = dataRoot
        self.substrate = CognitiveSubstrate(
            configuration: store == nil
                ? Self.configurationWithoutPersistence(configuration)
                : configuration,
            dependencies: CognitiveSubstrateDependencies(
                now: now,
                userName: { NativeCognitionRuntime.resolveUserName(dataRoot: root) },
                attentionProjectionSink: { signals, publishedAt in
                    attentionProjection.replaceSubstrate(
                        signals,
                        publishedAt: publishedAt
                    )
                },
                // W4/P1 fix-round (gpt-5.5 BLOCKING): without this closure the
                // substrate always used `.default`, leaving the whole
                // traits→dynamics derivation dead in production — the exact
                // "eight dials nothing consumes" finding recreated one layer
                // up. Same re-read-per-call shape as `userName` above, so a
                // persona trait edit takes effect on the next capsule; any
                // read failure degrades to `.default`.
                dynamics: {
                    let traits = PersonaCompiler.loadProfile(dataRoot: root).traits
                    return .derived(from: PersonalityTraitDials(
                        warmth: traits.warmth,
                        directness: traits.directness,
                        humor: traits.humor,
                        proactivity: traits.proactivity,
                        rigor: traits.rigor,
                        autonomy: traits.autonomy,
                        creativity: traits.creativity,
                        brevity: traits.brevity
                    ))
                },
                // UNBIDDEN RECALL (2026-09-02). The substrate asks with the
                // words of its own felt line and gets back felt MOMENTS. Local
                // SQLite + the already-warm embedder — no provider call — and
                // any failure returns [], which reads as "nothing came to her".
                // Rooted at THIS runtime's data root and filtered by the turn's
                // own surface; both are correctness, not hygiene (see below).
                recallMoments: { feltLine, k, surface in
                    await NativeCognitionRuntime.recallMoments(
                        feltLine: feltLine, limit: k, surface: surface, dataRoot: root)
                }
            ),
            store: store
        )
        self.organismKernel = OrganismKernel(
            configuration: organismConfiguration,
            dependencies: OrganismDependencies(
                now: now,
                predictedToolGroupsSink: { groups in
                    attentionProjection.replacePredictedToolGroups(groups)
                }
            )
        )
        self.somaticSignalBus = SomaticSignalBus(
            configuration: organismConfiguration,
            observer: self.organismKernel
        )
        let testProcess = ProcessInfo.processInfo.processName.lowercased().contains("xctest")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let defaultSoakEnablement = Self.resolveInstalledPhysiologySoakEnablement(
            dataRoot: dataRoot,
            isTestProcess: testProcess
        )
        let soakEnablement: InstalledPhysiologySoakEnablement
        if physiologySoakRecorderOverride != nil {
            soakEnablement = .injectedEvidence
        } else if let installedPhysiologySoakEnabled {
            soakEnablement = installedPhysiologySoakEnabled ? .forcedEnabled : .forcedDisabled
        } else {
            soakEnablement = defaultSoakEnablement
        }
        self.physiologySoakEnablement = soakEnablement
        self.physiologySoakRecorder = physiologySoakRecorderOverride
            ?? (soakEnablement.createsInstalledRecorder
                ? InstalledPhysiologySoakRecorder(
                    dataRoot: dataRoot,
                    runtimeInstanceID: telemetry.runtimeInstanceId
                )
                : nil)
    }

    deinit {
        pursuitObservationTask?.cancel()
        pursuitRefreshTask?.cancel()
        organismPersistenceDrainTask?.cancel()
    }

    /// Installed physiology collection is an explicit diagnostic/eval mode.
    /// Keep default-root and test-process exclusion provenance typed so a
    /// missing report cannot be mistaken for a healthy zero-observation run.
    nonisolated static func resolveInstalledPhysiologySoakEnablement(
        dataRoot: URL,
        isTestProcess: Bool
    ) -> InstalledPhysiologySoakEnablement {
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL else {
            return .disabledNonDefaultDataRoot
        }
        return isTestProcess ? .disabledTestProcess : .disabledByDefault
    }

    /// Read the configured user name from `<dataRoot>/memory/profile.json`
    /// (`userName`, written at onboarding). Tolerant of a missing/malformed file.
    nonisolated static func resolveUserName(dataRoot: URL) -> String {
        let path = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("profile.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["userName"] as? String else {
            return ""
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Unbidden recall (2026-09-02)

    /// Memory kinds that count as a MOMENT — something that HAPPENED and left a
    /// feeling, as opposed to a fact she knows. `moment` is the lane's own kind;
    /// the other three are what episodic rows were called before it, so an
    /// install whose store predates the lane still has something to be reminded
    /// of. Everything else (facts, preferences, identity) is excluded: being
    /// "reminded of" a stored preference is not a memory arriving sideways.
    nonisolated static let momentMemoryKinds: Set<String> = [
        "moment", "experience", "episodic", "event",
    ]

    /// One local recall, mapped into the substrate's vocabulary. Never throws:
    /// a cold or unavailable store means she is reminded of nothing, which is
    /// the correct degraded behavior for an enhancer line.
    ///
    /// TWO THINGS HERE ARE LOAD-BEARING, and the first cut had neither:
    ///
    /// * **The surface**, which is the disclosure boundary. `recall` applies
    ///   `MemoryRecordDisclosurePolicy` against it; with no surface every record
    ///   classifies through, so a memory restricted to one surface could arrive
    ///   unbidden on another. Unbidden is the *worst* place for that leak,
    ///   because nobody asked and nobody is checking.
    /// * **The data root.** `SwiftNativeMemoryV2.shared` is the production
    ///   store; a runtime built on an alternate or test root must never read it.
    ///   `resolvedOwner(dataRoot:)` is the same rule the chat recall factory
    ///   uses (`makeChatMemoryRecaller`): the singleton for the default root, a
    ///   private hermetic actor otherwise.
    ///
    /// Persona is deliberately `nil` — the exact value the ordinary chat recall
    /// passes. `memoryRecallPersonaFilter` returns nil for the resident slot
    /// and, by policy, for custom slots too: the mask changes the voice, not the
    /// store. Anything else here would make unbidden recall stricter than the
    /// recall the same turn already did.
    nonisolated static func recallMoments(
        feltLine: String,
        limit: Int,
        surface: String,
        dataRoot: URL
    ) async -> [CognitiveRecalledMoment] {
        let query = feltLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let surface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        // No surface means no disclosure boundary to check against, and an
        // unchecked recall is precisely what this must never do.
        guard !query.isEmpty, !surface.isEmpty, limit > 0 else { return [] }
        let response: MemoryV2RecallResponse
        do {
            response = try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).recall(
                MemoryV2RecallRequest(
                    text: query, topK: limit, persona: nil, surface: surface))
        } catch {
            return []
        }
        return response.scored.compactMap { moment(from: $0.record, score: $0.score) }
    }

    /// The one mapper, shared by the recall lane and the served-moment lane, so
    /// "what counts as a moment" cannot come to mean two things.
    nonisolated static func moment(
        from record: MemoryV2.MemoryRecord,
        score: Double
    ) -> CognitiveRecalledMoment? {
        guard (record.status ?? "active") == "active" else { return nil }
        guard let kind = record.memoryKind?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              momentMemoryKinds.contains(kind) else { return nil }
        // The lane stores the felt weight beside the text; `extras` is the
        // record's metadata bag verbatim (see `toMemoryRecord`).
        let text = metadataString(record.extras, "quote") ?? record.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CognitiveRecalledMoment(
            id: record.id,
            text: text,
            valence: metadataDouble(record.extras, "valence") ?? 0,
            salience: metadataDouble(record.extras, "salience")
                ?? record.importance
                ?? 0.5,
            occurredAt: isoDate(record.observedAt)
                ?? isoDate(record.createdAt)
                ?? Date(),
            score: score)
    }

    /// How many served ids one turn may look up. The re-feel spends at most
    /// `refeelNodesPerTurn` of them, so a whole 32-id serve is never worth
    /// reading; this keeps the lane a few point reads, not a scan.
    nonisolated static let servedMomentLookupLimit = 8

    /// GIVE THE SERVED MOMENTS THEIR FEELING BEFORE THE EVENT IS INGESTED.
    ///
    /// The re-feel runs inside `ingest`, reading `memoryRecordIds` off the
    /// event. It can only re-feel a moment whose weight the substrate already
    /// holds, and nothing else fills that ledger for the ORDINARY recall lane —
    /// so without this hop an ordinary served moment arrived as a bare id and
    /// was re-felt neutrally, which is the exact complaint this wave answers.
    ///
    /// Disclosure: `readMemoryRecord` re-applies the policy against this event's
    /// own surface. Belt and braces — these ids are what the turn already
    /// served, and that path filtered them — but the check is local and cheap,
    /// and a lookup by id with no surface would be a bypass.
    func noteServedMoments(for event: CognitiveEvent) async {
        let ids = CognitiveSubstrate.memoryRecordIDs(fromEventMetadata: event.metadata)
        guard !ids.isEmpty else { return }
        guard case .string(let rawSurface)? = event.metadata["surface"] else { return }
        let surface = rawSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !surface.isEmpty else { return }
        // Only ids whose feeling is not already known — a moment surfaced by the
        // reminded-of lane this same turn is already in the ledger.
        let unknown = await substrate.momentIDsMissingFeeling(ids)
            .prefix(Self.servedMomentLookupLimit)
        guard !unknown.isEmpty else { return }
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        var moments: [CognitiveRecalledMoment] = []
        for id in unknown {
            guard let record = try? await memory.readMemoryRecord(
                id: id, persona: nil, surface: surface) else { continue }
            // Served rows are not scored here; the score gates the reminded-of
            // LINE, and this lane never renders anything.
            if let moment = Self.moment(from: record, score: 1) { moments.append(moment) }
        }
        guard !moments.isEmpty else { return }
        await substrate.noteServedMoments(moments)
    }

    private nonisolated static func metadataString(_ value: JSONValue?, _ key: String) -> String? {
        guard case .object(let object)? = value,
              case .string(let string)? = object[key] else { return nil }
        return string
    }

    private nonisolated static func metadataDouble(_ value: JSONValue?, _ key: String) -> Double? {
        guard case .object(let object)? = value else { return nil }
        switch object[key] {
        case .double(let number): return number
        case .int(let number): return Double(number)
        default: return nil
        }
    }

    private nonisolated static func isoDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    func bootstrap() async {
        if bootstrapTask == nil {
            bootstrapTask = Task { await self.bootstrapBody() }
        }
        await bootstrapTask?.value
    }

    private func bootstrapBody() async {
        // Desk 903 phase 2 — the ONE seam between a filed journal entry and the
        // cognitive bus. The tool lane that writes the journal holds no
        // cognition reference by design; whoever owns the live substrate
        // installs the sink once, and this is that owner. Until this line runs
        // the bus is inert and says so out loud.
        //
        // ROOT-GUARDED. The bus is process-global and a second install REPLACES
        // the first, so every runtime bootstrapped on an alternate data root —
        // a test harness, a workshop profile, a second window pointed elsewhere
        // — used to silently take over the resident mind's sink and feed her
        // journal entries into a substrate that is not hers. There is one
        // resident mind, and it is the one on the canonical root; a runtime on
        // any other root installs nothing and stays out of the way.
        if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL {
            await StudioJournalCognitiveBus.install { [substrate] entry in
                await substrate.ingestStudioJournalEntry(entry)
            }
        }
        startPursuitObservationIfNeeded()
        await ensureReflectionSurfaceSeed()
        await refreshConfiguration()
        do {
            try await substrate.restorePersistentState()
        } catch {
            bootstrapFailure = "cognitive restore failed: \(error.localizedDescription)"
            await substrate.recordReceipt(
                kind: "lifecycle.restore_failed",
                payload: .object(["error": .string(String(describing: error))])
            )
        }
        await restoreOrganismContinuityIfAvailable()
        await restoreProviderVitalsSnapshot()
        await startApprovalLifecycleObservationIfNeeded()
        await reconcilePendingApprovalExpectationsAtBootstrap()
        await recoverPendingOrganismReflexReviewIfNeeded()
        await restoreProviderLifecycleEvidence()
        await reconcileProviderVitalsNotices()
        // The only awaited Desk replay is launch/bootstrap work, performed in
        // a detached task so its synchronous JSONL parse never occupies this
        // actor. All later turns consume the resident projection.
        await startPursuitRefresh(waitForCompletion: true)
        let wakeAt = now()
        let wakeEvent = CognitiveEvent(
            id: "app-wake:\(Int(wakeAt.timeIntervalSince1970))",
            kind: .appWake,
            subject: CognitiveSubjectReference(type: "app", id: "NativeAgent", label: "NativeAgent"),
            sourceClass: .observed,
            occurredAt: wakeAt,
            summary: "NativeAgent app launched or resumed",
            importance: 0.35
        )
        await substrate.observe(wakeEvent)
        await somaticSignalBus.observe(wakeEvent)
        let runtimeStartReason = bootstrapFailure == nil ? "bootstrap_completed" : "bootstrap_degraded"
        submitPhysiology { recorder in
            await recorder.recordRuntimeStarted(reason: runtimeStartReason)
        }
        scheduleDirtyMicrocycle(reason: "app_wake_reconciliation", turnClass: .system)
        await refreshOrganismBodySchema(reason: "bootstrap")
        await persistOrganismContinuity(reason: "bootstrap")
        await rescheduleResidualRepairDeadline()
        await rescheduleCognitionMaintenanceDeadline()
        publishRuntimeChange(reason: "bootstrap")
        // (memoized via bootstrapTask — audit C4)
    }

    func changes() -> AsyncStream<NativeCognitionRuntimeChange> {
        let id = UUID()
        let pair = AsyncStream<NativeCognitionRuntimeChange>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        changeContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeChangeContinuation(id) }
        }
        return pair.stream
    }

    private func removeChangeContinuation(_ id: UUID) {
        changeContinuations.removeValue(forKey: id)
    }

    func publishRuntimeChange(reason: String) {  // internal for actor extensions (move-only Wave C)
        changeRevision &+= 1
        let change = NativeCognitionRuntimeChange(
            revision: changeRevision,
            occurredAt: now(),
            reason: String(reason.prefix(96))
        )
        for continuation in changeContinuations.values {
            continuation.yield(change)
        }
    }

    func refreshConfiguration() async {
        if configurationOverride == nil,
           NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot),
           preferenceDefaults.object(forKey: Self.enabledKey) == nil {
            let routing = SwiftNativeProviderRouting(dataRoot: dataRoot)
            if let snapshot = try? await routing.checkedRoutingSnapshot(),
               let providerID = snapshot.activeProviders["chat"],
               let provider = try? await routing.getProvider(id: providerID),
               provider.configured == true {
                Self.initializeMissingInnerLifePreferences(
                    dataRoot: dataRoot, providerReady: true, defaults: preferenceDefaults
                )
                if usesLiveAppBody {
                    await NativeContextFlowRuntime.shared.reloadConfiguration()
                }
            }
        }
        var configuration = configurationOverride ?? Self.loadConfiguration(
            defaults: preferenceDefaults,
            environment: configurationEnvironment
        )
        do {
            let routing = SwiftNativeProviderRouting(dataRoot: dataRoot)
            let routingSnapshot = try await routing.checkedRoutingSnapshot()
            if let reflection = routingSnapshot.preferences[configuration.reflectionSurface] {
                configuration.reflectionModel = reflection.model
                configuration.reflectionReasoningEffort = reflection.reasoningEffort
                configuration.reflectionProvider = routingSnapshot.activeProviders[configuration.reflectionSurface]
                    ?? routing.inferProviderForModel(reflection.model)
                    ?? configuration.reflectionProvider
                // 2026-09-06: the routing row is the ONLY authority for the
                // reflection mind, and this is where it is resolved — so mirror
                // it onto the two preference keys the Setup and Settings
                // pickers display. Changing the reflection row in Providers
                // writes routing and calls this; without the mirror those
                // pickers went on showing a stale provider/model forever, with
                // no way for the person to tell which one actually runs.
                if usesLiveAppBody {
                    preferenceDefaults.set(configuration.reflectionModel, forKey: Self.reflectionModelKey)
                    preferenceDefaults.set(
                        configuration.reflectionProvider, forKey: Self.reflectionProviderKey)
                }
            }
            providerRoutingFailure = nil
        } catch {
            // Provider files are authoritative for reflection. Corruption closes
            // only the provider-using lane instead of silently reviving a stale
            // UserDefaults route.
            configuration.reflectiveCallsEnabled = false
            providerRoutingFailure = "cognitive provider state unavailable: \(error.localizedDescription)"
        }
        await substrate.configure(configuration)
        // The caring appraisal's model seam (2026-09-11). Installed here for
        // the same reason the configuration is: this is the one place that
        // knows both the substrate and the app's provider routing. Without it
        // the substrate never appraises and nothing ever doses, which is what a
        // headless tool or a test should get.
        await substrate.setCaringAppraiser(MindCaringAppraiser())
        // And the door the verdict goes in by (2026-09-11, fourth pass). The
        // appraisal owner calls this the moment its model call returns, carrying
        // the originating turn's own timestamp; the kernel takes the fixed dose.
        // It used to ride out on the next somatic signal's metadata, which
        // scaled the dose by that signal's intensity and lost the verdict when no
        // further signal came.
        await substrate.setCaringEventSink { [weak self] reading, window in
            guard let self else { return .refused }
            return await self.admitCaringEventIntoBody(reading, window: window)
        }
        // And the receipt's other half (2026-09-11, review c4 item 4): a verdict
        // the substrate turns away never reaches the sink, so it amends its own
        // appraisal row from here instead, with the same fields the sink writes.
        await substrate.setCaringRefusalRecorder { [weak self] session, turn, why in
            guard let self else { return }
            await MindCaringAppraiser.amendReceiptRefused(
                session: session,
                turn: turn,
                why: why,
                tendernessAfter: await self.organismKernel.snapshot().chemicalState.tenderness
            )
        }
        let organismConfiguration = organismConfigurationOverride
            ?? Self.loadOrganismConfiguration(
                dataRoot: dataRoot,
                defaults: preferenceDefaults
            )
        await organismKernel.configure(organismConfiguration)
        await somaticSignalBus.configure(organismConfiguration)
    }


    func observe(_ event: CognitiveEvent) async {
        let acceptanceStartedAt = ProcessInfo.processInfo.systemUptime
        await bootstrap()
        let inherited = inheritNonLiveTurnKind(for: event)
        // Chat-turn lifecycle latch opens at admission, BEFORE the provider
        // call this event's run is about to make (see `noteTurnStarted`).
        noteChatTurnAdmission(inherited.event)
        let afterInheritance = ProcessInfo.processInfo.systemUptime
        // BEFORE ingest, because the re-feel happens inside it: a served moment
        // with no recorded feeling is re-felt neutrally, which is the thing
        // being fixed. No-op for the overwhelming majority of events (they carry
        // no `memoryRecordIds` at all).
        await noteServedMoments(for: inherited.event)
        let substrateAccepted = await substrate.ingestResident(inherited.event)
        let afterSubstrate = ProcessInfo.processInfo.systemUptime
        // Item 46's remaining hop (see the header of
        // CognitiveSubstrate+AppraisalConcerns.swift). Only the appraisal owner
        // holds standing views, so only it can say a lived concern is at stake
        // (mint) or how this turn lands on the completion it answers (react);
        // the organism reads the event's own metadata. This is the one place
        // that hands the SAME event to both owners. Pure, synchronous, no LLM,
        // and empty for the overwhelming majority of events. Read AFTER ingest
        // so a reaction can see the completion this turn is answering.
        var enriched = inherited.event
        for (key, value) in await substrate.semanticExpectationMetadata(for: inherited.event) {
            enriched.metadata[key] = value
        }
        // Tenderness's caring appraisal (2026-09-11) is LAUNCHED on the same hop
        // and crosses on no hop at all. Only the appraisal owner can say a turn
        // was an act of care, and only the body can feel it — so the owner calls
        // the body directly when its model call returns (`setCaringEventSink`
        // above). Nothing is stamped on the signal and nothing blocks here.
        await substrate.noteCaringTurn(for: inherited.event)
        let somaticAccepted = await somaticSignalBus.observe(enriched) != nil
        let afterSomatic = ProcessInfo.processInfo.systemUptime
        if let completedRunId = inherited.completedRunId {
            finishNonLiveTurn(runId: completedRunId)
            noteTurnFinished(runId: completedRunId)
        }
        // Exact replay is inert across both resident owners. It must not create
        // settlement work, persistence, invalidations, prewarm, or telemetry.
        guard substrateAccepted || somaticAccepted else { return }
        if somaticAccepted {
            cachedBodyRead = nil
            // Round 3 Wave A2 (review 3360e532dd3b, High): the MAIN event
            // path reaches the kernel through the somatic bus — without a
            // drain here, felt resolutions from ordinary tool events sat in
            // the memory-only buffer (rate stamp persisted, feeling lost on
            // shutdown). Both kernel-feed paths drain through the one door.
            await drainFeltResolutionsIntoSubstrate()
        }
        if substrateAccepted {
            scheduleDirtyMicrocycle(
                reason: "event:\(inherited.event.kind.rawValue)",
                turnClass: InstalledPhysiologySoakRecorder.physiologyTurnClass(inherited.event.turnKind)
            )
        }
        let afterSchedule = ProcessInfo.processInfo.systemUptime
        if somaticAccepted { await rescheduleResidualRepairDeadline() }
        let afterResidual = ProcessInfo.processInfo.systemUptime
        let acceptanceMilliseconds = max(
            0,
            (ProcessInfo.processInfo.systemUptime - acceptanceStartedAt) * 1_000
        )
        let acceptedEvent = inherited.event
        let acceptedSignalCount = microcycleTelemetry.scheduledSignalCount
        submitPhysiology { recorder in
            await recorder.recordCognitiveEvent(
                acceptedEvent,
                scheduledSignalCount: acceptedSignalCount,
                acceptanceMilliseconds: acceptanceMilliseconds,
                cognitiveSubstrateMilliseconds: max(0, (afterSubstrate - afterInheritance) * 1_000),
                somaticMilliseconds: max(0, (afterSomatic - afterSubstrate) * 1_000),
                residualSchedulingMilliseconds: max(0, (afterResidual - afterSchedule) * 1_000)
            )
        }
        publishRuntimeChange(reason: "event:\(inherited.event.kind.rawValue)")
        if usesLiveAppBody {
            Task {
                await NativeContextFlowRuntime.shared.prewarm(
                    kind: .cognitive,
                    id: inherited.event.subject.id,
                    terms: [
                        inherited.event.kind.rawValue,
                        inherited.event.subject.type,
                        inherited.event.subject.id,
                        inherited.event.subject.label ?? "",
                        inherited.event.summary,
                    ]
                )
            }
        }
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


    func eventDrivenReplayAttemptCountForProof() -> UInt64 {
        eventDrivenReplayAttemptCount
    }

    func replayReconciliationPendingForProof() -> Bool {
        replayReconciliationPending
    }

    func deadlineBailoutCountsForProof() -> (replay: UInt64, physiologyDrain: UInt64) {
        (eventDrivenReplayTimeoutCount, physiologySubmissionDrainTimeoutCount)
    }

    func handleEventDrivenReplayOutcome(  // internal for +Organism extension (move-only Wave C)
        _ outcome: CognitiveBackgroundRunOutcome,
        reason: String,
        allowRetry: Bool
    ) async {
        switch outcome {
        case .completed:
            replayReconciliationPending = false
            replayRetryTask?.cancel()
            replayRetryTask = nil
        case .skipped(let detail) where detail == "no new replay evidence":
            replayReconciliationPending = false
            replayRetryTask?.cancel()
            replayRetryTask = nil
        case .skipped(let detail), .failed(let detail):
            replayReconciliationPending = true
            await substrate.recordReceipt(
                kind: "replay.reconciliation_pending",
                payload: .object([
                    "reason": .string(reason),
                    "outcome": .string(String(detail.prefix(300))),
                    "retryScheduled": .bool(allowRetry),
                ])
            )
            guard allowRetry, replayRetryTask == nil else { return }
            replayRetryTask = Task { [weak self] in
                let nanos = UInt64(Self.replayFailureRetryDelay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled else { return }
                await self?.retryPendingReplayReconciliation()
            }
        }
    }

    private func retryPendingReplayReconciliation() async {
        // G-L1: hold `replayRetryTask` non-nil across the replay await. The
        // arm site guards on `replayRetryTask == nil`, so clearing it before
        // awaiting would let a concurrent dream signal observe "no retry armed"
        // and double-run replay. Reconciliation stays idempotent; the task
        // self-clears only after this body completes.
        guard replayReconciliationPending, !isFlushedForTermination else {
            replayRetryTask = nil
            return
        }
        eventDrivenReplayAttemptCount &+= 1
        let reason = "replay_event_retry"
        let outcome = await runEventDrivenReplayWithDeadline(reason: reason)
        await handleEventDrivenReplayOutcome(outcome, reason: reason, allowRetry: false)
        replayRetryTask = nil
    }

    /// Dream/REM signals are background tissue today, but this seam must remain
    /// safe if a foreground caller ever emits one. The unstructured race returns
    /// on the deadline without structurally awaiting a cancellation-insensitive
    /// replay body; reconciliation remains durable and gets one bounded retry.
    func runEventDrivenReplayWithDeadline(  // internal for +Organism extension (move-only Wave C)
        reason: String
    ) async -> CognitiveBackgroundRunOutcome {
        let override = eventDrivenReplayOperationOverride
        let outcome = await raceAgainstTimeout(seconds: eventDrivenReplayTimeoutSeconds) { [weak self] in
            if let override {
                return await override(reason)
            }
            guard let self else {
                return .failed("cognitive runtime released before event-driven replay")
            }
            return await self.runReplay(reason: reason)
        }
        switch outcome {
        case .value(let result):
            return result
        case .failure(let detail):
            return .failed("event-driven replay race failed: \(detail)")
        case .timedOut:
            eventDrivenReplayTimeoutCount &+= 1
            let detail = "event-driven replay '\(reason)' exceeded "
                + "\(eventDrivenReplayTimeoutSeconds)s deadline; task cancelled and reconciliation retained"
            deadlineLogger("TIMEOUT: \(detail)")
            return .failed(detail)
        case .cancelled:
            let detail = "event-driven replay '\(reason)' cancelled; reconciliation retained"
            deadlineLogger("CANCELLED: \(detail)")
            return .failed(detail)
        }
    }


    func substrateForIntegration() async -> CognitiveSubstrate {
        await bootstrap()
        return substrate
    }

    /// Fixed-time mutation-free read seam for provider transplantation. It
    /// deliberately refuses to bootstrap because launch/restore/app-wake are
    /// canonical mutations and cannot occur inside a frozen epoch.
    func frozenMindRead(
        at fixedAt: Date,
        surface: String,
        userMessage: String,
        sessionId: String? = nil
    ) async throws -> NativeFrozenMindRead {
        guard let bootstrapTask else { throw NativeFrozenMindReadError.runtimeNotBootstrapped }
        await bootstrapTask.value
        if let bootstrapFailure { throw NativeFrozenMindReadError.bootstrapFailed(bootstrapFailure) }
        let cognition = await substrate.frozenRead(at: fixedAt, currentSessionId: sessionId)
        let organism = await organismKernel.frozenRead(at: fixedAt)
        let capsule = await substrate.compileFrozenCapsule(
            CognitiveCapsuleRequest(
                surface: surface,
                userMessage: userMessage,
                sessionId: sessionId,
                mode: .inject,
                organismProjection: organism.projection
            ),
            from: cognition
        )
        return NativeFrozenMindRead(
            fixedAt: fixedAt,
            cognition: cognition,
            organism: organism,
            capsule: capsule
        )
    }

    func frozenMindOwnerRevisions() async -> [FrozenMindOwnerRevision] {
        [
            FrozenMindOwnerRevision(
                owner: "cognition",
                revision: await substrate.frozenRevisionToken()
            ),
            FrozenMindOwnerRevision(
                owner: "organism",
                revision: await organismKernel.frozenRevisionFingerprint()
            ),
        ]
    }

    /// The live turn seam is an actor-free read of the projection already
    /// published by CognitiveSubstrate, OrganismKernel, and the Desk pursuit
    /// projection. Bootstrap and owner I/O happen off this path; an early cold
    /// turn may receive nil, but can never wait for those owners.
    nonisolated func attentionSignals(at date: Date) async -> CognitiveAttentionSignals? {
        let trace = CognitiveAttentionTraceContext.recorder
        trace?.recordAdmission()
        guard !Task.isCancelled else {
            trace?.markCancellationObserved()
            return nil
        }
        let stageStarted = DispatchTime.now().uptimeNanoseconds
        let signals = attentionProjection.read(at: date)
        trace?.recordElapsed("resident", since: stageStarted)
        return signals
    }


    /// One-shot prepare+commit. This COMMITS AT PREPARE TIME (consumes the
    /// Body-line suppress window before any provider sees the capsule), so it
    /// must never sit on a turn-executor path — those go through
    /// `prepareTurnProjection` and commit only after the provider accepts the
    /// turn (R-F1, 2026-07-17). No production caller uses this today; it
    /// remains for the protocol requirement and direct-read tests.
    func prepareCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule? {
        let projection = await prepareTurnProjection(request)
        await commitTurnProjection(projection, request: request)
        return projection.capsule
    }

    /// Ordinary chat reads cognition and organism at one fixed time after one
    /// body refresh. It does not consume the surfaced-state window; the caller
    /// commits that only after the value is actually appended to provider input.
    func prepareTurnProjection(_ request: CognitiveCapsuleRequest) async -> CognitiveTurnProjection {
        await bootstrap()
        let fixedAt = now()
        let bodySample = await organismBodySample(at: fixedAt)
        let canonicalAffect = await substrate.canonicalAffectProjection(at: fixedAt)
        let organism = await organismKernel.refreshBodySchemaAndFrozenRead(
            bodySample.read,
            integratesChemistry: bodySample.integratesChemistry,
            canonicalAffect: canonicalAffect,
            fixedAt: fixedAt
        )
        let capsuleRequest = requestWithOrganismProjection(
            request,
            projection: organism.projection,
            toward: await towardRead(),
            at: fixedAt
        )
        let preparedCapsule = await substrate.prepareFrozenCapsulePresentation(
            capsuleRequest,
            at: fixedAt
        )
        return CognitiveTurnProjection(
            fixedAt: fixedAt,
            capsule: preparedCapsule?.capsule,
            posture: organism.posture,
            capsulePresentationCommit: preparedCapsule?.presentationCommit
        )
    }

    func commitTurnProjection(
        _ projection: CognitiveTurnProjection,
        request: CognitiveCapsuleRequest
    ) async {
        guard let capsule = projection.capsule else { return }
        // Mirror the real injection so the Observatory's Capsule Preview reflects
        // what Agent actually received this turn, not a synthetic constant. Only a
        // successful (.live, non-empty) injection updates the cache. Trusted
        // teammate bridges may receive a read-only non-live projection, but it
        // never replaces the last real capsule or consumes the Body-line window.
        let requestTurnKind = request.resolvedTurnKind
        if requestTurnKind == .live {
            lastInjectedCapsule = (capsule, request.userMessage)
            // Mark the body line as surfaced only after a real (.inject) capsule
            // actually built with it — so observatory previews and nil builds don't
            // consume the suppress-when-unchanged window. (gpt-5.5 review)
            if request.mode == .inject,
               let line = Self.bodyLine(inCapsuleDynamicContext: capsule.dynamicContext) {
                lastInjectedBodyLine = line
                lastInjectedBodyLineAt = projection.fixedAt
            }
            if request.mode == .inject,
               let presentationCommit = projection.capsulePresentationCommit {
                _ = await substrate.applyCapsulePresentationCommit(presentationCommit)
            }
            // W7/P6 — the envelope stash rides the same certification: this
            // request served a real live turn. The frozen capsule compile is a
            // pure rendering and cannot own it; previews and bridges (non-live
            // kinds) never reach here.
            if request.mode == .inject {
                await substrate.stashDeliveryEnvelopeForCommittedTurn(
                    request, at: projection.fixedAt)
            }
        }
    }

    @discardableResult
    func runMicrocycle(reason: String) async -> CognitiveBackgroundRunOutcome {
        await bootstrap()
        if let bootstrapFailure { return .failed(bootstrapFailure) }
        switch await backgroundCognitionGate(reason: reason) {
        case .skipped(let reason): return .skipped(reason)
        case .allowed: break
        }
        do {
            let snapshot = try await substrate.runMicrocycleChecked(reason: reason)
            guard snapshot != nil else {
                return .skipped("cognitive substrate disabled or clean")
            }
            publishRuntimeChange(reason: "microcycle:completed")
            return .completed("cognitive field settled through checked persistence")
        } catch {
            publishRuntimeChange(reason: "microcycle:failed")
            return .failed("cognitive microcycle failed: \(error.localizedDescription)")
        }
    }

    func scheduleDirtyMicrocycle(  // internal for actor extensions (move-only Wave C)
        reason: String,
        turnClass: InstalledPhysiologyTurnClass = .system
    ) {
        // gpt-5.5 fix round: post-flush arrivals (a replay tail, a late
        // organism drain) must not arm new microcycles after the terminal
        // snapshot. Same latch the reschedule bodies honor.
        guard !isFlushedForTermination else { return }
        microcycleTelemetry.scheduledSignalCount &+= 1
        if pendingMicrocycleGeneration != nil {
            microcycleTelemetry.coalescedReplacementCount &+= 1
        }
        microcycleTelemetry.lastScheduledAt = now()
        microcycleTelemetry.lastReason = String(reason.prefix(160))
        if pendingMicrocycleGeneration != nil,
           let pendingClass = microcycleTelemetry.lastTurnClass {
            microcycleTelemetry.lastTurnClass = Self.mergedPhysiologyTurnClass(
                pendingClass,
                turnClass
            )
        } else {
            microcycleTelemetry.lastTurnClass = turnClass
        }
        microcycleGeneration &+= 1
        let generation = microcycleGeneration
        pendingMicrocycleGeneration = generation
        pendingMicrocycleTask?.cancel()
        pendingMicrocycleTask = nil
        if physiologySoakRecorder != nil {
            let telemetry = microcycleTelemetry
            submitPhysiology { recorder in
                await recorder.recordMicrocycleScheduled(telemetry)
            }
        }
        guard microcycleSchedulingMode == .automatic else { return }
        pendingMicrocycleTask = Task { [weak self] in
            let nanos = UInt64(Self.microcycleCoalescingDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            await self.runScheduledMicrocycle(generation: generation, reason: reason)
        }
    }

    /// One coalesced settlement may consume several dirty events. If any live
    /// turn is present, the full measured transaction belongs to the ordinary
    /// turn population; diagnostic traffic can never downgrade it. System work
    /// similarly dominates debug/verification when no live event is present.
    private static func mergedPhysiologyTurnClass(
        _ lhs: InstalledPhysiologyTurnClass,
        _ rhs: InstalledPhysiologyTurnClass
    ) -> InstalledPhysiologyTurnClass {
        if lhs == .live || rhs == .live { return .live }
        if lhs == .system || rhs == .system { return .system }
        if lhs == .verification || rhs == .verification { return .verification }
        return .debug
    }

    private func runScheduledMicrocycle(generation: UInt64, reason: String) async {
        guard !isFlushedForTermination,
              generation == microcycleGeneration,
              pendingMicrocycleGeneration == generation else { return }
        // This generation is now in flight, not pending. A reentrant event
        // arriving while persistence awaits must start a distinct generation
        // and workload class instead of being merged into work already
        // snapshotted by this cycle.
        let scheduledSignalCount = microcycleTelemetry.scheduledSignalCount
        let settlementTurnClass = microcycleTelemetry.lastTurnClass
        pendingMicrocycleGeneration = nil
        pendingMicrocycleTask = nil
        let startedAt = now()
        let monotonicStartedAt = monotonicNowNanoseconds()
        microcycleTelemetry.executedCount &+= 1
        let executionOrdinal = microcycleTelemetry.executedCount
        microcycleTelemetry.lastStartedAt = startedAt
        let outcome = await runMicrocycle(reason: reason)
        switch outcome {
        case .completed:
            microcycleTelemetry.completedCount &+= 1
            microcycleTelemetry.lastOutcome = "completed"
        case .skipped:
            microcycleTelemetry.skippedCount &+= 1
            microcycleTelemetry.lastOutcome = "skipped"
        case .failed:
            microcycleTelemetry.failedCount &+= 1
            microcycleTelemetry.lastOutcome = "failed"
        }
        let finishedAt = now()
        let monotonicFinishedAt = monotonicNowNanoseconds()
        microcycleTelemetry.lastFinishedAt = finishedAt
        let elapsedNanoseconds = monotonicFinishedAt >= monotonicStartedAt
            ? monotonicFinishedAt - monotonicStartedAt
            : 0
        microcycleTelemetry.lastDurationMilliseconds = Int(min(
            elapsedNanoseconds / 1_000_000,
            UInt64(Int.max)
        ))
        var finishedTelemetry = microcycleTelemetry
        // Mutable global telemetry may now describe a newer reentrant
        // generation. The finish receipt must remain bound to the schedule that
        // actually began this measured settlement.
        finishedTelemetry.scheduledSignalCount = scheduledSignalCount
        finishedTelemetry.executedCount = executionOrdinal
        finishedTelemetry.lastReason = String(reason.prefix(160))
        finishedTelemetry.lastTurnClass = settlementTurnClass
        let completedTelemetry = finishedTelemetry
        submitPhysiology { recorder in
            await recorder.recordMicrocycleFinished(completedTelemetry)
        }
        // A microcycle may create or resolve thought seeds and standing views.
        // Re-project the single maintenance deadline after that canonical
        // transition; ordinary reads and quiet elapsed time remain wake-free.
        await rescheduleCognitionMaintenanceDeadline()
        // `runMicrocycle` publishes after the substrate commit; scheduled
        // settlement publishes once more after its telemetry has reached the
        // same terminal state so Observatory readers cannot see stale counters.
        publishRuntimeChange(reason: "microcycle_settlement:finished")
    }

    /// Deterministic proof seam for the resident coalescer. This is unavailable
    /// to automatic production scheduling and does not synthesize elapsed
    /// wall-clock evidence; it merely settles the currently pending generation.
    func flushPendingMicrocycleForProof() async {
        guard microcycleSchedulingMode == .manuallyFlushed,
              let generation = pendingMicrocycleGeneration else { return }
        let reason = microcycleTelemetry.lastReason ?? "accelerated_proof"
        await runScheduledMicrocycle(generation: generation, reason: reason)
    }




    func microcycleTelemetrySnapshot() -> CognitiveMicrocycleTelemetry {
        microcycleTelemetry
    }

    @discardableResult
    func runMaintenance(reason: String) async -> CognitiveBackgroundRunOutcome {
        await bootstrap()
        if let bootstrapFailure { return .failed(bootstrapFailure) }
        switch await backgroundCognitionGate(reason: reason) {
        case .skipped(let reason):
            await rescheduleCognitionMaintenanceDeadline(
                notBefore: now().addingTimeInterval(Self.cognitionMaintenanceRetryDelay)
            )
            return .skipped(reason)
        case .allowed: break
        }
        do {
            let persistenceEnabled = await substrate.configurationSnapshot().persistenceEnabled
            let ran = try await substrate.runMaintenanceChecked(reason: reason)
            guard ran else {
                // Review round 2 (HIGH): a not-ran outcome includes "still due
                // but excluded by the microcycle commit window" — re-arming at
                // the natural (already-due) deadline would spin. The bounded
                // contention delay wins only when the natural deadline is
                // effectively now; a genuinely future deadline still wins.
                await rescheduleCognitionMaintenanceDeadline(
                    notBefore: now().addingTimeInterval(Self.cognitionMaintenanceContentionRetryDelay)
                )
                return .skipped("cognitive maintenance not due or disabled")
            }
            await rescheduleCognitionMaintenanceDeadline()
            publishRuntimeChange(reason: "maintenance:completed")
            return .completed(persistenceEnabled
                ? "cognitive maintenance checkpoint and receipt are durable"
                : "cognitive maintenance completed in memory-only mode")
        } catch {
            await rescheduleCognitionMaintenanceDeadline(
                notBefore: now().addingTimeInterval(Self.cognitionMaintenanceRetryDelay)
            )
            publishRuntimeChange(reason: "maintenance:failed")
            return .failed("cognitive maintenance failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func runReplay(reason: String) async -> CognitiveBackgroundRunOutcome {
        await bootstrap()
        if let bootstrapFailure { return .failed(bootstrapFailure) }
        let configuration = await substrate.configurationSnapshot()
        guard configuration.enabled, configuration.replayEnabled else {
            return .skipped("cognitive replay disabled")
        }
        switch await backgroundCognitionGate(reason: reason) {
        case .skipped(let reason): return .skipped(reason)
        case .allowed: break
        }
        do {
            let persistenceEnabled = configuration.persistenceEnabled
            let result = try await substrate.integrateReplayChecked(
                await makeReplayIntegrationInput(reason: reason)
            )
            guard !result.episodeIds.isEmpty || !result.schemaProposalIds.isEmpty || !result.timelineEventIds.isEmpty else {
                return .skipped("no new replay evidence")
            }
            scheduleDirtyMicrocycle(reason: "replay_integration")
            publishRuntimeChange(reason: "replay:completed")
            return .completed(persistenceEnabled
                ? "replay artifacts and lineage committed atomically"
                : "replay evidence integrated in memory-only mode")
        } catch {
            publishRuntimeChange(reason: "replay:failed")
            return .failed("cognitive replay failed: \(error.localizedDescription)")
        }
    }


    func flushForTermination() async {
        // Review round 2 (LOW): latch shutdown so a delayed wake re-anchor
        // cannot resurrect the deadline timers this flush is about to cancel.
        isFlushedForTermination = true
        // Pursuit reads are advisory background work, not part of the final
        // persistence barrier. Quiesce their owner and reject any late result.
        pursuitProjectionGeneration &+= 1
        pursuitRefreshQueued = false
        pursuitObservationTask?.cancel()
        pursuitObservationTask = nil
        pursuitRefreshTask?.cancel()
        pursuitRefreshTask = nil
        residualDeadline.invalidate()
        cognitionDeadline.invalidate()
        // G-H2: quiesce the two remaining unstructured re-arm sources. A
        // 0.25s-debounced dirty microcycle or a pending replay retry could
        // otherwise commit — and re-arm a deadline this flush just cancelled —
        // AFTER the terminal snapshot below. The reschedule bodies also honor
        // `isFlushedForTermination` so any survivor no-ops instead of re-arming.
        pendingMicrocycleTask?.cancel()
        pendingMicrocycleTask = nil
        // gpt-5.5 fix round: cancel() alone leaves a hole — a task that passed
        // its Task.isCancelled check before this line still enters
        // runScheduledMicrocycle afterwards. Clearing the pending generation
        // fails its generation guard, and the latch guards below close the
        // schedule/retry entry points for anything that re-arrives later.
        pendingMicrocycleGeneration = nil
        replayRetryTask?.cancel()
        replayRetryTask = nil
        // A4.6: quiesce the event-driven reflection lane the same way — the
        // latch above stops new schedules; cancel any in-flight task so its
        // LLM call cannot outlive the terminal snapshot.
        reflectionEventTask?.cancel()
        reflectionEventTask = nil
        // Same latch for the pressure-fired dream: 03:30 remains the integrity
        // fallback, so a dream cancelled at termination is simply not owed.
        pressureDreamTask?.cancel()
        pressureDreamTask = nil
        let sleepAt = now()
        let sleepEvent = CognitiveEvent(
            id: "app-sleep:\(Int(sleepAt.timeIntervalSince1970))",
            kind: .appSleep,
            subject: CognitiveSubjectReference(type: "app", id: "NativeAgent", label: "NativeAgent"),
            sourceClass: .observed,
            occurredAt: sleepAt,
            summary: "NativeAgent app is terminating",
            importance: 0.35
        )
        await substrate.observe(sleepEvent)
        await somaticSignalBus.observe(sleepEvent)
        await substrate.runMaintenance(reason: "app termination")
        try? await substrate.persistSnapshot()
        await persistOrganismContinuity(reason: "app termination")
        submitPhysiology { recorder in
            await recorder.recordRuntimeStopped(reason: "app_termination")
        }
        await drainPhysiologySubmissions()
        await physiologySoakRecorder?.flush()
        // Termination is the runtime-owned snapshot point for provider vitals.
        // It follows lifecycle/physiology settlement so the final observed row
        // cannot be excluded by an early snapshot.
        await persistProviderVitalsSnapshot()
        // The studio sidecar's serial writer is the last thing owed: its final
        // queued write must be on disk before the process goes away.
        await flushStudioEncounterStateWrites()
    }


    func observatoryDetail() async -> CognitiveObservatoryDetail {
        await bootstrap()
        let configuration = await substrate.configurationSnapshot()
        let workspace = await substrate.workspaceSnapshot()
        await refreshOrganismBodySchema(reason: "observatory")
        let organism = await organismKernel.snapshot()
        // The Capsule Preview mirrors the capsule Agent ACTUALLY received in her
        // last live chat turn (cached at injection in prepareCapsule), timestamped —
        // so the panel moves as they talk instead of recompiling a synthetic compile
        // pinned to a constant "observatory preview" message (which never changes and
        // never reflects the live conversation). Only when nothing has been injected
        // this session (fresh boot, no chat yet) do we fall back to a synthetic
        // inspect-only compile, clearly labeled in the UI.
        // One organism-projected inspect request serves BOTH the mode chip below and the
        // synthetic capsule compile — the chip reads the same signals path the fingerprint
        // does, so what it names is what she'd feel about right now, not a parallel guess.
        let inspectFixedAt = now()
        let inspectRequest = requestWithOrganismProjection(
            CognitiveCapsuleRequest(
                surface: "chat",
                userMessage: lastInjectedCapsule?.userMessage ?? "observatory preview",
                mode: .inspectOnly,
                maximumCharacters: min(1_200, configuration.maximumCapsuleCharacters)
            ),
            projection: await organismKernel.projection(),
            toward: await towardRead(),
            at: inspectFixedAt
        )
        // Pass the workspace already snapshotted above: feltModeReading must not
        // re-snapshot (that advances field decay, and this panel refreshes every 5s).
        let feltMode = await substrate.feltModeReading(for: inspectRequest, workspace: workspace)

        let capsulePreview: CognitiveCapsule?
        let capsulePreviewInfo: CapsulePreviewInfo?
        if let last = lastInjectedCapsule {
            capsulePreview = last.capsule
            capsulePreviewInfo = CapsulePreviewInfo(
                source: .liveInjected,
                userMessage: last.userMessage,
                at: last.capsule.generatedAt
            )
        } else {
            let synthetic = await substrate.compileCapsule(inspectRequest)
            let nonEmpty = synthetic.combined.isEmpty ? nil : synthetic
            capsulePreview = nonEmpty
            capsulePreviewInfo = nonEmpty == nil ? nil : CapsulePreviewInfo(source: .synthetic, userMessage: nil, at: nil)
        }
        let receiptRead = await substrate.receiptReadSnapshot()
        return CognitiveObservatoryDetail(
            configuration: configuration,
            summary: await substrate.observatorySnapshot(),
            substrate: await substrate.snapshot(),
            workspace: workspace,
            associations: await substrate.associationSnapshot(),
            thoughtSeeds: await substrate.thoughtSeedSnapshot(),
            thoughtSuggestions: await substrate.thoughtSuggestionSnapshot(surface: "observatory"),
            episodes: await substrate.episodeSnapshot(),
            schemaProposals: await substrate.schemaProposalSnapshot(),
            standingViews: await substrate.standingViewSnapshot(),
            developmentalTimeline: await substrate.developmentalTimelineSnapshot(),
            reflections: await substrate.reflectionReceiptSnapshot(),
            receiptRead: receiptRead,
            receipts: receiptRead.receipts,
            facultyMeasurements: await substrate.facultyMeasurementSnapshot(),
            experiments: await substrate.researchExperimentSnapshot(),
            welfareBounds: await substrate.welfareBoundsSnapshot(),
            organism: organism,
            lastResearchExportPath: lastResearchExportPath,
            capsulePreview: capsulePreview,
            capsulePreviewInfo: capsulePreviewInfo,
            feltMode: feltMode
        )
    }

    /// The observational boundary used by mounted Observatory consumers.
    /// It retains the full live projection while making missing durable receipt
    /// evidence explicit, so disabled or unreadable persistence never becomes
    /// a success-shaped empty receipt list.
    func observatoryDetailRead() async -> CognitiveObservatoryDetailRead {
        CognitiveObservatoryDetailRead(detail: await observatoryDetail())
    }

    func setEnabled(_ enabled: Bool) async {
        preferenceDefaults.set(enabled, forKey: Self.enabledKey)
        await refreshConfiguration()
        if enabled { await bootstrap() }
        publishRuntimeChange(reason: "configuration:enabled")
    }

    func setCapsuleEnabled(_ enabled: Bool) async {
        preferenceDefaults.set(enabled, forKey: Self.capsuleKey)
        await refreshConfiguration()
        publishRuntimeChange(reason: "configuration:capsule")
    }

    func setBackgroundEnabled(_ enabled: Bool) async {
        preferenceDefaults.set(enabled, forKey: Self.backgroundKey)
        await refreshConfiguration()
        publishRuntimeChange(reason: "configuration:background")
    }

    func setReflectionEnabled(_ enabled: Bool) async {
        preferenceDefaults.set(enabled, forKey: Self.reflectionKey)
        await refreshConfiguration()
        publishRuntimeChange(reason: "configuration:reflection")
    }

    func setReflectionBudget(_ budget: Int) async {
        preferenceDefaults.set(max(0, budget), forKey: Self.reflectionBudgetKey)
        await refreshConfiguration()
        publishRuntimeChange(reason: "configuration:reflection_budget")
    }

    /// The user-facing Subconscious switch is one transaction over the
    /// existing cognition and organism owners. Keeping this composition here
    /// prevents UI call sites from omitting a lane or triggering a cascade of
    /// redundant configuration reloads and invalidations.
    func setSubconsciousMasterEnabled(
        _ enabled: Bool,
        reflectionBudget: Int
    ) async -> NativeSubconsciousRuntimeState {
        Self.writeInnerLifePreferences(
            enabled: enabled, reflectionBudget: reflectionBudget,
            defaults: preferenceDefaults, onlyMissing: false
        )

        let alreadyBootstrapped = bootstrapTask != nil
        await refreshConfiguration()
        if enabled {
            if alreadyBootstrapped {
                organismContinuityRestored = false
                await restoreOrganismContinuityIfAvailable()
                await refreshOrganismBodySchema(reason: "subconscious enabled")
                await persistOrganismContinuity(reason: "subconscious enabled")
            } else {
                await bootstrap()
            }
        }
        await rescheduleResidualRepairDeadline()
        await rescheduleCognitionMaintenanceDeadline()
        publishRuntimeChange(reason: "configuration:subconscious_master")
        return await subconsciousRuntimeState()
    }

    func refreshAfterOnboardingTransition() async -> NativeSubconsciousRuntimeState {
        await refreshConfiguration()
        let organism = await organismKernel.snapshot()
        if organism.enabled {
            organismContinuityRestored = false
            await restoreOrganismContinuityIfAvailable()
            await refreshOrganismBodySchema(reason: "onboarding transition")
            await persistOrganismContinuity(reason: "onboarding transition")
        } else {
            cachedBodyRead = nil
        }
        await rescheduleResidualRepairDeadline()
        await rescheduleCognitionMaintenanceDeadline()
        publishRuntimeChange(reason: "configuration:onboarding_transition")
        return await subconsciousRuntimeState()
    }

    /// Setup completion and launch share the explicit switch's preference
    /// transaction, but automatic initialization never replaces a saved choice.
    /// The independent hour preference is deliberately not part of this master.
    nonisolated static func initializeMissingInnerLifePreferences(
        dataRoot: URL, providerReady: Bool, defaults: UserDefaults
    ) {
        guard providerReady,
              NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot),
              defaults.object(forKey: enabledKey) == nil else { return }
        NativeContextFlowConfiguration.initializeMissingInnerLifeMode(defaults: defaults)
        writeInnerLifePreferences(
            enabled: true, reflectionBudget: 2, defaults: defaults, onlyMissing: true
        )
    }

    private nonisolated static func writeInnerLifePreferences(
        enabled: Bool, reflectionBudget: Int, defaults: UserDefaults, onlyMissing: Bool
    ) {
        for key in [capsuleKey, backgroundKey, reflectionKey, organismKernelEnabledKey] {
            if !onlyMissing || defaults.object(forKey: key) == nil {
                defaults.set(enabled, forKey: key)
            }
        }
        if !onlyMissing || defaults.object(forKey: reflectionBudgetKey) == nil {
            defaults.set(enabled ? max(1, reflectionBudget) : 0, forKey: reflectionBudgetKey)
        }
        // Write the master last so an interrupted initialization can resume.
        if !onlyMissing || defaults.object(forKey: enabledKey) == nil {
            defaults.set(enabled, forKey: enabledKey)
        }
    }

    func subconsciousRuntimeState() async -> NativeSubconsciousRuntimeState {
        let configuration = await substrate.configurationSnapshot()
        let organism = await organismKernel.snapshot()
        return NativeSubconsciousRuntimeState(
            enabled: configuration.enabled,
            capsuleEnabled: configuration.capsuleInjectionEnabled,
            backgroundEnabled: configuration.backgroundMicrocyclesEnabled,
            reflectionEnabled: configuration.reflectiveCallsEnabled,
            reflectionBudget: configuration.dailyReflectionCallBudget,
            organismEnabled: organism.enabled
        )
    }


    func lastInjectedCapsuleBridgeSummary() async -> CognitiveBridgeCapsuleSummary {
        guard let last = lastInjectedCapsule else {
            return CognitiveBridgeCapsuleSummary(
                source: "none",
                generatedAt: nil,
                hasBodyLine: false,
                bodyLine: nil,
                dynamicContextCharacters: 0,
                truncated: nil
            )
        }
        let bodyLine = Self.bodyLine(inCapsuleDynamicContext: last.capsule.dynamicContext)
        return CognitiveBridgeCapsuleSummary(
            source: "live_injected",
            generatedAt: last.capsule.generatedAt,
            hasBodyLine: bodyLine != nil,
            bodyLine: bodyLine,
            dynamicContextCharacters: last.capsule.dynamicContext.count,
            truncated: last.capsule.truncated
        )
    }


    /// H2 (audit, 2026-07-09): makeOrganismBodyRead does ~15 stats + JSON parses
    /// + a dream_diary directory listing — and it ran on EVERY tool result (×10
    /// per multi-tool turn), every prepareCapsule, every Observatory 5s poll,
    /// every LivingStatusPanel 60s tick, all serialized on THIS actor which the
    /// chat turn also needs. The underlying files change on the order of minutes;
    /// a 2s TTL cache removes the per-tool-result cost without dulling the body's
    /// senses. Debug overrides bypass staleness by construction (checked below).
    var cachedBodyRead: (read: OrganismBodyRead, at: Date)?  // internal for actor extensions (move-only Wave C)
    /// Payload-free, process-local provider lifecycle evidence. Canonical
    /// successful call receipts are reloaded from the injected trace root at
    /// bootstrap; live started/terminal events replace the same call ID.
    /// This is a transient belief input, never provider-selection authority.
    var providerLifecycleEvidenceByCallID: [String: ProviderPathEvidence] = [:]
    static let providerLifecycleExpiry: TimeInterval = 45
    static let maximumProviderLifecycleEvidence = 32


    private func requestWithOrganismProjection(
        _ request: CognitiveCapsuleRequest,
        projection initialProjection: OrganismProjection,
        toward: OrganismTowardRead? = nil,
        at fixedAt: Date
    ) -> CognitiveCapsuleRequest {
        var projection = initialProjection
        // The horizon rides BEFORE the neutral-projection early return: it
        // comes from the prediction ledger, not from chemistry, so a body with
        // nothing to say is no reason for her to stop looking forward to
        // Friday.
        var request = request
        request.toward = toward
        guard !projection.isNeutral else { return request }
        // Suppress-when-unchanged: only for REAL injections (.inject). If the same
        // line is still fresh, drop it so a held mood goes quiet instead of
        // repeating for hours. Observatory/preview (.inspectOnly) always sees the
        // true line and never touches the window. The surfaced-marker is set
        // post-build in prepareCapsule, so a preview OR a nil capsule can't consume
        // the window. (gpt-5.5 review)
        if request.mode == .inject,
           let line = projection.bodyLine,
           line == lastInjectedBodyLine,
           let last = lastInjectedBodyLineAt,
           fixedAt.timeIntervalSince(last) < Self.bodyLineRefreshInterval {
            projection.bodyLine = nil
        }
        var copy = request
        copy.organismProjection = projection
        return copy
    }

    nonisolated static func bodyLine(inCapsuleDynamicContext dynamicContext: String) -> String? {
        dynamicContext
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("- Body:") }
    }


    @discardableResult
    func clearTransientState() async -> CognitiveTransientStateClearOutcome {
        guard let cognitiveStore else {
            let detail = "cognitive persistent store unavailable"
            await substrate.recordReceipt(
                kind: "user.clear_transient_state_failed",
                payload: .object(["error": .string(detail)])
            )
            publishRuntimeChange(reason: "transient_clear:failed")
            return .persistenceFailed(detail)
        }
        do {
            try await cognitiveStore.clear()
        } catch {
            let detail = String(describing: error)
            await substrate.recordReceipt(
                kind: "user.clear_transient_state_failed",
                payload: .object(["error": .string(detail)])
            )
            publishRuntimeChange(reason: "transient_clear:failed")
            return .persistenceFailed(detail)
        }
        await substrate.clearTransientState()
        await organismKernel.clearTransientState()
        await rescheduleCognitionMaintenanceDeadline()
        lastInjectedBodyLine = nil
        lastInjectedBodyLineAt = nil
        await persistOrganismContinuity(reason: "clear transient")
        await substrate.recordReceipt(kind: "user.clear_transient_state")
        publishRuntimeChange(reason: "transient_clear:completed")
        return .cleared
    }

    func resolveSchemaProposal(id: UUID, accepted: Bool) async {
        _ = await substrate.resolveSchemaProposal(id: id, accepted: accepted)
        scheduleDirtyMicrocycle(reason: "schema_proposal_resolution")
        publishRuntimeChange(reason: "proposal:schema_resolved")
    }

    /// User's approval seam for Wave E standing views — a view she formed in reflection
    /// only reaches her capsule after this says approved.
    func resolveStandingView(id: UUID, approved: Bool) async -> CognitiveStandingView? {
        await resolveStandingViewChecked(id: id, approved: approved).view
    }

    /// Same seam, carrying the persistence outcome (2026-09-06) so the review
    /// surfaces can tell "saved" from "changed in memory only".
    func resolveStandingViewChecked(id: UUID, approved: Bool) async -> StandingViewTransition {
        let resolved = await substrate.resolveStandingViewChecked(id: id, approved: approved)
        guard resolved.view != nil else { return resolved }
        scheduleDirtyMicrocycle(reason: "standing_view_resolution")
        publishRuntimeChange(reason: "proposal:standing_view_resolved")
        return resolved
    }

    /// The user's RETIREMENT seam — the way out of `.active` that
    /// `resolveStandingView` never had (Agent, 2026-09-02: three of her five
    /// active views were three drafts of one phrasing view and nothing could
    /// retire them but a sixth approval pushing one off the LRU). Also the
    /// route for letting go of a `.held` view she adopted herself.
    func retireStandingView(id: UUID) async -> CognitiveStandingView? {
        await retireStandingViewChecked(id: id).view
    }

    /// Same seam, carrying the persistence outcome (2026-09-06).
    func retireStandingViewChecked(id: UUID) async -> StandingViewTransition {
        let retired = await substrate.retireStandingViewChecked(id: id)
        guard retired.view != nil else { return retired }
        scheduleDirtyMicrocycle(reason: "standing_view_retirement")
        publishRuntimeChange(reason: "proposal:standing_view_retired")
        return retired
    }

    func setAblation(_ key: String, enabled: Bool) async {
        await substrate.setAblation(key, enabled: enabled)
        publishRuntimeChange(reason: "experiment:ablation")
    }

    @discardableResult
    func pinTopConcern() async -> String? {
        await bootstrap()
        guard let suggestion = await substrate.thoughtSuggestionSnapshot(
            surface: "observatory",
            limit: 1,
            minimumInterruptionScore: 0
        ).first else { return nil }
        _ = await substrate.addThoughtSeed(
            kind: .followUp,
            text: "Pinned concern: \(suggestion.text)",
            priority: 1,
            sourceNodeIds: suggestion.sourceNodeIds
        )
        scheduleDirtyMicrocycle(reason: "concern_pinned")
        publishRuntimeChange(reason: "thought_seed:pinned")
        return suggestion.text
    }

    @discardableResult
    func runResearchHarness() async -> CognitiveEvaluationSamplerOutcome {
        await bootstrap()
        if let bootstrapFailure {
            let outcome = CognitiveEvaluationSamplerOutcome(
                recordedKinds: [],
                unavailableKinds: CognitiveExperimentKind.allCases,
                failureDetail: bootstrapFailure
            )
            publishRuntimeChange(reason: "experiment:harness_failed")
            return outcome
        }
        var recordedKinds: [CognitiveExperimentKind] = []
        var unavailableKinds: [CognitiveExperimentKind] = []
        for kind in CognitiveExperimentKind.allCases {
            if await substrate.runResearchExperiment(kind: kind, seed: "observatory") != nil {
                recordedKinds.append(kind)
            } else {
                unavailableKinds.append(kind)
            }
        }
        let outcome = CognitiveEvaluationSamplerOutcome(
            recordedKinds: recordedKinds,
            unavailableKinds: unavailableKinds,
            failureDetail: nil
        )
        publishRuntimeChange(
            reason: outcome.isComplete ? "experiment:harness_completed" : "experiment:harness_unavailable"
        )
        return outcome
    }

    @discardableResult
    func exportResearchTrace() async -> String? {
        await bootstrap()
        let payload = await substrate.exportResearchTrace()
        let dir = dataRoot
            .appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Second-granularity filenames collapsed repeated Export presses onto
        // one apparent success. Every completed export needs its own durable
        // artifact; retention owns the resulting bounded set.
        let path = dir.appendingPathComponent(
            "cognitive-research-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased()).json"
        )
        do {
            try await SwiftNativePersistenceCore().writeJSON(payload, to: path)
            Self.trimResearchExports(in: dir, keeping: 20, preserving: path)
            lastResearchExportPath = path.path
            publishRuntimeChange(reason: "experiment:trace_exported")
            return path.path
        } catch {
            await substrate.recordReceipt(
                kind: "observatory.export_failed",
                payload: .object(["error": .string(String(describing: error))])
            )
            return nil
        }
    }

    nonisolated private static func trimResearchExports(
        in directory: URL,
        keeping limit: Int,
        preserving freshlyWrittenPath: URL
    ) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let preservedPath = freshlyWrittenPath.standardizedFileURL.path
        let exports = files
            .filter { $0.lastPathComponent.hasPrefix("cognitive-research-") && $0.pathExtension == "json" }
            .sorted {
                let leftIsPreserved = $0.standardizedFileURL.path == preservedPath
                let rightIsPreserved = $1.standardizedFileURL.path == preservedPath
                if leftIsPreserved != rightIsPreserved { return leftIsPreserved }
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        guard exports.count > limit else { return }
        for stale in exports.dropFirst(limit) { try? FileManager.default.removeItem(at: stale) }
    }


    /// True while a chat turn is running, or while a settlement is still
    /// pending. The sleep-pressure dream lane and the studio-encounter lane read
    /// this so neither can land on top of a turn in flight.
    ///
    /// The turn latch is the authority (admission → terminal settlement, counted
    /// by runId, wall-clock-bounded). The coalescer generation is kept as the
    /// second term: it still covers non-chat sensory work and any turn admitted
    /// without a runId, and it is what this property used to mean.
    var liveTurnInFlight: Bool {  // internal for actor extensions
        if liveTurnLatchCount() > 0 { return true }
        return pendingMicrocycleGeneration != nil
    }

    /// The lane a gate reason belongs to, for the conserve starvation floor.
    /// Reasons are shaped `<lane>:<class>` ("transcript_aging:reflection",
    /// "studio_encounter:reflection"); the lane is what gets its own floor, so
    /// one busy lane cannot consume another's pass.
    static func expensiveLaneKey(for reason: String) -> String {
        let lane = reason.split(separator: ":", maxSplits: 1).first.map(String.init) ?? reason
        return String(lane.prefix(64))
    }

    func backgroundCognitionGate(reason: String) async -> CognitiveBackgroundGate {  // internal for actor extensions (move-only Wave C)
        let process = ProcessInfo.processInfo
        if process.isLowPowerModeEnabled {
            await substrate.recordReceipt(
                kind: "cognition.resource_skip",
                payload: .object([
                    "reason": .string(reason),
                    "resource": .string("low_power_mode"),
                ])
            )
            return .skipped("low power mode")
        }
        // Thermal is decided BEFORE the conserve lane bookkeeping below. A
        // refusal that never runs the operation must not consume the lane's
        // 45-minute starvation pass — otherwise a thermal spike that clears a
        // second later still costs the evening another full floor.
        switch process.thermalState {
        case .serious, .critical:
            await substrate.recordReceipt(
                kind: "cognition.resource_skip",
                payload: .object([
                    "reason": .string(reason),
                    "resource": .string("thermal_pressure"),
                    "state": .string(String(describing: process.thermalState)),
                ])
            )
            return .skipped("thermal pressure")
        default:
            break
        }
        if let posture = await organismKernel.behaviorPosture() {
            switch posture.loopBudget {
            case .sleep:
                await substrate.recordReceipt(
                    kind: "cognition.organism_loop_skip",
                    payload: .object([
                        "reason": .string(reason),
                        "loopBudget": .string(posture.loopBudget.rawValue),
                        "posture": .string(posture.posture),
                    ])
                )
                return .skipped("organism loop budget is sleep")
            case .conserve:
                let expensive = reason.contains("reflection")
                    || reason.contains("replay")
                    || reason.contains("cue")
                if expensive {
                    // Throttle, not a veto. A lane that has not been let through
                    // for the starvation floor gets one pass, so the evening can
                    // integrate; everything inside the floor is still deferred.
                    let lane = Self.expensiveLaneKey(for: reason)
                    let last = conserveExpensivePassAt[lane]
                    let waited = last.map { now().timeIntervalSince($0) }
                    if let waited, waited < Self.conserveExpensiveStarvationFloor {
                        await substrate.recordReceipt(
                            kind: "cognition.organism_loop_deferred",
                            payload: .object([
                                "reason": .string(reason),
                                "loopBudget": .string(posture.loopBudget.rawValue),
                                "posture": .string(posture.posture),
                                "lane": .string(lane),
                                "secondsSinceLanePass": .int(Int64(waited)),
                                "starvationFloorSeconds":
                                    .int(Int64(Self.conserveExpensiveStarvationFloor)),
                            ])
                        )
                        return .skipped("organism loop budget is conserve")
                    }
                    conserveExpensivePassAt[lane] = now()
                    await substrate.recordReceipt(
                        kind: "cognition.organism_loop_starvation_pass",
                        payload: .object([
                            "reason": .string(reason),
                            "loopBudget": .string(posture.loopBudget.rawValue),
                            "posture": .string(posture.posture),
                            "lane": .string(lane),
                            "secondsSinceLanePass": waited.map { .int(Int64($0)) } ?? .null,
                            "starvationFloorSeconds":
                                .int(Int64(Self.conserveExpensiveStarvationFloor)),
                        ])
                    )
                }
            case .normal:
                break
            }
        }
        return .allowed
    }


    static func loadConfiguration(  // internal for actor extensions (move-only Wave C)
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CognitiveConfiguration {
        let env = environment
        let enabled = defaults.bool(forKey: enabledKey)
            || env["NATIVE_AGENT_COGNITION_ENABLED"] == "1"
        let capsuleEnabled = enabled && (
            defaults.object(forKey: capsuleKey) as? Bool ?? true
        )
        let backgroundEnabled = enabled && (
            defaults.object(forKey: backgroundKey) as? Bool ?? true
        )
        let reflectionEnabled = enabled && (
            defaults.bool(forKey: reflectionKey)
                || env["NATIVE_AGENT_COGNITION_REFLECTION_ENABLED"] == "1"
        )
        // The old daily quota is now the HARD cost ceiling per rolling 24h —
        // same number, so nothing spends more by default; admission is load.
        let budgetDefault = reflectionEnabled ? 2 : 0
        let storedBudget = defaults.object(forKey: reflectionBudgetKey) as? Int
        let budget = max(0, storedBudget ?? budgetDefault)
        let storedLoadThreshold = defaults.object(forKey: reflectionLoadThresholdKey) as? Double
        let reflectionModel = configuredReflectionModel(env: env)
        let reflectionProvider = configuredReflectionProvider(for: reflectionModel)
        return CognitiveConfiguration(
            enabled: enabled,
            persistenceEnabled: enabled,
            workspaceEnabled: enabled,
            capsuleInjectionEnabled: capsuleEnabled,
            affectEnabled: enabled,
            thoughtSeedsEnabled: enabled,
            replayEnabled: enabled,
            backgroundMicrocyclesEnabled: backgroundEnabled,
            reflectiveCallsEnabled: reflectionEnabled,
            observatoryEnabled: enabled,
            maximumActiveNodes: 256,
            defaultDecayHalfLife: 60 * 60,
            maximumCapsuleCharacters: 4_000,
            maximumWorkspaceItems: 12,
            maximumThoughtSeeds: 64,
            dailyReflectionCallBudget: budget,
            reflectionLoadThreshold: storedLoadThreshold ?? CognitiveConfiguration().reflectionLoadThreshold,
            reflectionSurface: "cognition_reflection",
            reflectionModel: reflectionModel,
            reflectionProvider: reflectionProvider,
            reflectionReasoningEffort: "high"
        )
    }

    nonisolated static func organismConfigurationForLaunch(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storedEnabled: Bool? = nil,
        storedSubconsciousEnabled: Bool? = nil,
        defaults: UserDefaults = .standard
    ) -> OrganismConfiguration {
        if NativeAgentPublicSafety.shouldForceNeutralOrganism(dataRoot: dataRoot, environment: environment) {
            return .disabled
        }
        let explicitOrganism = storedEnabled
            ?? (defaults.object(forKey: organismKernelEnabledKey) as? Bool)
        let subconsciousMaster = storedSubconsciousEnabled
            ?? (defaults.object(forKey: enabledKey) as? Bool)
        let enabled = (explicitOrganism ?? subconsciousMaster ?? false)
            || environment["NATIVE_AGENT_ORGANISM_KERNEL_ENABLED"] == "1"
        return OrganismConfiguration(enabled: enabled)
    }

    private static func loadOrganismConfiguration(
        dataRoot: URL,
        defaults: UserDefaults = .standard
    ) -> OrganismConfiguration {
        reconcileOrganismPreferenceForLaunch(dataRoot: dataRoot, defaults: defaults)
    }

    /// Existing installs can predate the organism preference while already
    /// having the Subconscious master enabled. Inherit that master exactly
    /// once. An explicit organism choice always wins, and public clean-room
    /// safety remains authoritative before onboarding.
    nonisolated static func reconcileOrganismPreferenceForLaunch(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> OrganismConfiguration {
        let storedOrganism = defaults.object(forKey: organismKernelEnabledKey) as? Bool
        let storedMaster = defaults.object(forKey: enabledKey) as? Bool
        let configuration = organismConfigurationForLaunch(
            dataRoot: dataRoot,
            environment: environment,
            storedEnabled: storedOrganism,
            storedSubconsciousEnabled: storedMaster,
            defaults: defaults
        )
        if storedOrganism == nil,
           storedMaster == true,
           configuration.enabled,
           !NativeAgentPublicSafety.shouldForceNeutralOrganism(
               dataRoot: dataRoot,
               environment: environment
           ) {
            defaults.set(true, forKey: organismKernelEnabledKey)
        }
        return configuration
    }


    private static func configuredReflectionModel(env: [String: String]) -> String {
        let stored = UserDefaults.standard.string(forKey: reflectionModelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        let envModel = env["NATIVE_AGENT_COGNITION_REFLECTION_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return envModel.isEmpty ? defaultReflectionModel : envModel
    }

    private static func configuredReflectionProvider(for model: String) -> String {
        let stored = UserDefaults.standard.string(forKey: reflectionProviderKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? inferredReflectionProvider(for: model) : stored
    }

    static func inferredReflectionProvider(for model: String) -> String {  // internal for actor extensions (move-only Wave C)
        SwiftNativeProviderRouting.inferredProviderID(forModel: model)
            ?? defaultReflectionProvider
    }

    private static func configurationWithoutPersistence(_ configuration: CognitiveConfiguration) -> CognitiveConfiguration {
        var copy = configuration
        copy.persistenceEnabled = false
        return copy
    }



    static let defaultReflectionModel = "claude-opus-4-8"  // internal for actor extensions (move-only Wave C)
    private static let defaultReflectionProvider = "anthropic_oauth_direct"
    private static let enabledKey = "cognitiveSubstrateEnabled"
    private static let capsuleKey = "cognitiveSubstrateCapsuleEnabled"
    private static let backgroundKey = "cognitiveSubstrateBackgroundEnabled"
    private static let reflectionKey = "cognitiveSubstrateReflectionEnabled"
    private static let reflectionBudgetKey = "cognitiveSubstrateDailyReflectionBudget"
    /// Unresolved-load admission threshold for spontaneous reflection. No UI
    /// knob: the ceiling is what User steers; this is the shape's tuning seam.
    private static let reflectionLoadThresholdKey = "cognitiveSubstrateReflectionLoadThreshold"
    static let organismKernelEnabledKey = "organismKernelEnabled"  // internal for actor extensions (move-only Wave C)
    static let reflectionModelKey = "cognitiveSubstrateReflectionModel"
    static let reflectionProviderKey = "cognitiveSubstrateReflectionProvider"
}
