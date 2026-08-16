import Foundation
import ChatOrchestration
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting

struct CognitiveObservatoryDetail: Sendable {
    var configuration: CognitiveConfiguration
    var summary: CognitiveObservatorySnapshot
    var substrate: CognitiveSubstrateSnapshot
    var workspace: CognitiveWorkspaceSnapshot
    var associations: [CognitiveAssociationEdge]
    var thoughtSeeds: [CognitiveThoughtSeed]
    var thoughtSuggestions: [CognitiveThoughtSuggestion]
    var episodes: [CognitiveEpisodeReference]
    var schemaProposals: [CognitiveSchemaProposal]
    var standingViews: [CognitiveStandingView]
    var developmentalTimeline: [CognitiveDevelopmentalTimelineEvent]
    var reflections: [CognitiveReflectionReceipt]
    var receipts: [CognitiveReceiptRecord]
    var facultyMeasurements: [CognitiveFacultyMeasurement]
    var experiments: [CognitiveExperimentResult]
    var welfareBounds: CognitiveWelfareBounds
    var organism: OrganismSnapshot
    var lastResearchExportPath: String?
    var capsulePreview: CognitiveCapsule?
    var capsulePreviewInfo: CapsulePreviewInfo?
    /// The aboutness under the felt words (U3, 2026-07-09) — a pure read of the same
    /// signals the fingerprint is built from. nil when cognition/affect is off or no
    /// mode is genuinely dominant. Read-only: it adds no capsule text and drives nothing.
    var feltMode: CognitiveSubstrate.FeltMode?
}

/// Provenance for the Observatory's Capsule Preview: whether the shown capsule is
/// the one Agent ACTUALLY received in her last live chat turn (mirrored at
/// injection), or a synthetic inspect-only compile shown only before any chat
/// injection this session. Lets the panel label what it's showing instead of
/// reading like a frozen constant.
struct CapsulePreviewInfo: Sendable {
    enum Source: Sendable { case liveInjected, synthetic }
    var source: Source
    /// The user message this capsule was built for (live injections only).
    var userMessage: String?
    /// When it was injected — the capsule's own compile time (live injections only).
    var at: Date?
}

struct CognitiveBridgeCapsuleSummary: Sendable {
    var source: String
    var generatedAt: Date?
    var hasBodyLine: Bool
    var bodyLine: String?
    var dynamicContextCharacters: Int
    var truncated: Bool?
}

struct NativeCognitionRuntimeChange: Sendable, Equatable {
    let revision: UInt64
    let occurredAt: Date
    let reason: String
}

struct NativeSubconsciousRuntimeState: Sendable, Equatable {
    let enabled: Bool
    let capsuleEnabled: Bool
    let backgroundEnabled: Bool
    let reflectionEnabled: Bool
    let reflectionBudget: Int
    let organismEnabled: Bool
}

struct NativeReflectionRouteStatus: Sendable, Equatable {
    let model: String
    let providerID: String
    let providerReady: Bool
    let modelKnown: Bool?
    let detail: String

    var isReady: Bool { providerReady && modelKnown != false }
}

struct NativeFrozenMindRead: Sendable {
    let fixedAt: Date
    let cognition: CognitiveFrozenRead
    let organism: OrganismFrozenRead
    let capsule: CognitiveCapsule
}

enum NativeFrozenMindReadError: Error, Sendable, Equatable {
    case runtimeNotBootstrapped
    case bootstrapFailed(String)
}

enum CognitiveTransientStateClearOutcome: Sendable, Equatable {
    case cleared
    case persistenceFailed(String)
}

enum OrganismDebugBodyScenario: String, CaseIterable, Sendable {
    case providerBrittle = "provider_brittle"
    case stalePhone = "stale_phone"
    case resourceTight = "resource_tight"
    case memoryBrittle = "memory_brittle"
    case approvalClosed = "approval_closed"
}

struct OrganismDebugBodyOverrideStatus: Sendable {
    var scenario: OrganismDebugBodyScenario
    var expiresAt: Date
}

enum OrganismDebugBodyOverrideError: Error, Sendable, CustomStringConvertible {
    case unknownScenario(String)

    var description: String {
        switch self {
        case .unknownScenario(let value):
            return "unknown organism debug scenario: \(value)"
        }
    }
}

enum OrganismReflexReviewApplyStatus: String, Sendable, Equatable {
    case applied
    case organismDisabled = "organism_disabled"
    case candidateNotFound = "candidate_not_found"
    case approvalRequiresLowRisk = "approval_requires_low_risk"
    case persistenceFailed = "persistence_failed"
}

struct OrganismReflexReviewApplyOutcome: Sendable, Equatable {
    var status: OrganismReflexReviewApplyStatus
    var snapshot: OrganismSnapshot
    var candidate: OrganismReflexCandidate?
    var receipt: OrganismReflexReviewReceipt?
    var error: String?

    var applied: Bool { status == .applied }
}

// internal for +Organism extension (move-only Wave C)
struct OrganismDebugBodyOverride: Sendable {
    var scenario: OrganismDebugBodyScenario
    var expiresAt: Date
}


enum CognitiveBackgroundRunOutcome: Sendable, Equatable {
    case completed(String)
    case skipped(String)
    case failed(String)
}

/// Process-local counters for the event-driven dirty-settlement pilot. This is
/// evidence only: it is not persisted into cognition, does not schedule work,
/// and has no control authority. An external manual sampler can correlate the
/// instance/process identity across real restarts without pretending the
/// counter itself survived one.
struct CognitiveMicrocycleTelemetry: Sendable, Equatable {
    let runtimeInstanceId: String
    let processIdentifier: Int32
    let runtimeInitializedAt: Date
    var scheduledSignalCount: UInt64 = 0
    var coalescedReplacementCount: UInt64 = 0
    var executedCount: UInt64 = 0
    var completedCount: UInt64 = 0
    var skippedCount: UInt64 = 0
    var failedCount: UInt64 = 0
    var lastScheduledAt: Date?
    var lastStartedAt: Date?
    var lastFinishedAt: Date?
    var lastReason: String?
    var lastOutcome: String?
    var lastDurationMilliseconds: Int?
    var lastTurnClass: InstalledPhysiologyTurnClass?

    static func fresh(now: Date = Date()) -> Self {
        Self(
            runtimeInstanceId: UUID().uuidString.lowercased(),
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            runtimeInitializedAt: now
        )
    }
}

/// Execution ownership for the dirty-settlement coalescer. Production uses the
/// trailing-edge task. The manual mode exists solely for deterministic proof:
/// tests can advance Agent's analytic clock by days and flush the exact same
/// settlement path without sleeping, adding a timer, or recruiting a model.
enum CognitiveMicrocycleSchedulingMode: Sendable {
    case automatic
    case manuallyFlushed
}

// internal for +Reflection extension (move-only Wave C)
enum CognitiveBackgroundGate: Sendable, Equatable {
    case allowed
    case skipped(String)
}


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
    var pendingPhysiologySubmissions = 0  // internal for actor extensions (move-only Wave C)
    var physiologySubmissionGeneration: UInt64 = 0  // internal for actor extensions (move-only Wave C)
    /// Off-path submissions form one serial tail. Separate unstructured tasks
    /// can reach an actor in scheduler order rather than source order, which
    /// would let an assistant completion overtake its user ingress and corrupt
    /// retry/chat-latency accounting.
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

    init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        configurationOverride: CognitiveConfiguration? = nil,
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
            (@Sendable (OrganismPersistentState, URL) async throws -> Void)? = nil
    ) {
        self.dataRoot = dataRoot
        self.now = now
        self.monotonicNowNanoseconds = monotonicNowNanoseconds
        self.microcycleSchedulingMode = microcycleSchedulingMode
        let telemetry = CognitiveMicrocycleTelemetry.fresh(now: now())
        self.microcycleTelemetry = telemetry
        self.configurationOverride = configurationOverride
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
        self.pursuitStateLoader = pursuitStateLoaderOverride ?? {
            try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
        }
        self.deadlineLogger = deadlineLogger ?? { message in
            FileHandle.standardError.write(Data("[NativeCognitionRuntime] \(message)\n".utf8))
        }
        let configuration = configurationOverride ?? Self.loadConfiguration()
        let organismConfiguration = organismConfigurationOverride
            ?? Self.loadOrganismConfiguration(dataRoot: dataRoot)
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
        let shouldCollectInstalledSoak = installedPhysiologySoakEnabled
            ?? (dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
                && !testProcess)
        self.physiologySoakRecorder = physiologySoakRecorderOverride
            ?? (shouldCollectInstalledSoak
                ? InstalledPhysiologySoakRecorder(
                    dataRoot: dataRoot,
                    runtimeInstanceID: telemetry.runtimeInstanceId
                )
                : nil)
    }

    deinit {
        pursuitObservationTask?.cancel()
        organismPersistenceDrainTask?.cancel()
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

    func bootstrap() async {
        if bootstrapTask == nil {
            bootstrapTask = Task { await self.bootstrapBody() }
        }
        await bootstrapTask?.value
    }

    private func bootstrapBody() async {
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
        await restoreProviderLifecycleEvidence()
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
        var configuration = configurationOverride ?? Self.loadConfiguration()
        do {
            let routing = SwiftNativeProviderRouting(dataRoot: dataRoot)
            let routingSnapshot = try await routing.checkedRoutingSnapshot()
            if let reflection = routingSnapshot.preferences[configuration.reflectionSurface] {
                configuration.reflectionModel = reflection.model
                configuration.reflectionReasoningEffort = reflection.reasoningEffort
                configuration.reflectionProvider = routingSnapshot.activeProviders[configuration.reflectionSurface]
                    ?? routing.inferProviderForModel(reflection.model)
                    ?? configuration.reflectionProvider
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
        let organismConfiguration = organismConfigurationOverride
            ?? Self.loadOrganismConfiguration(dataRoot: dataRoot)
        await organismKernel.configure(organismConfiguration)
        await somaticSignalBus.configure(organismConfiguration)
    }


    func observe(_ event: CognitiveEvent) async {
        let acceptanceStartedAt = ProcessInfo.processInfo.systemUptime
        await bootstrap()
        let inherited = inheritNonLiveTurnKind(for: event)
        let afterInheritance = ProcessInfo.processInfo.systemUptime
        let substrateAccepted = await substrate.ingestResident(inherited.event)
        let afterSubstrate = ProcessInfo.processInfo.systemUptime
        let somaticAccepted = await somaticSignalBus.observe(inherited.event) != nil
        let afterSomatic = ProcessInfo.processInfo.systemUptime
        if let completedRunId = inherited.completedRunId {
            finishNonLiveTurn(runId: completedRunId)
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
        let requestTurnKind = CognitiveTurnKind.inferred(fromSignals: [
            request.surface,
            request.sessionId ?? "",
            request.userMessage,
        ])
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
            receipts: await substrate.receiptSnapshot(),
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

    func setEnabled(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        await refreshConfiguration()
        if enabled { await bootstrap() }
        publishRuntimeChange(reason: "configuration:enabled")
    }

    func setCapsuleEnabled(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: Self.capsuleKey)
        await refreshConfiguration()
        publishRuntimeChange(reason: "configuration:capsule")
    }

    func setBackgroundEnabled(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: Self.backgroundKey)
        await refreshConfiguration()
        publishRuntimeChange(reason: "configuration:background")
    }

    func setReflectionEnabled(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: Self.reflectionKey)
        await refreshConfiguration()
        publishRuntimeChange(reason: "configuration:reflection")
    }

    func setReflectionBudget(_ budget: Int) async {
        UserDefaults.standard.set(max(0, budget), forKey: Self.reflectionBudgetKey)
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
        let budget = enabled ? max(1, reflectionBudget) : 0
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        UserDefaults.standard.set(enabled, forKey: Self.capsuleKey)
        UserDefaults.standard.set(enabled, forKey: Self.backgroundKey)
        UserDefaults.standard.set(enabled, forKey: Self.reflectionKey)
        UserDefaults.standard.set(budget, forKey: Self.reflectionBudgetKey)
        UserDefaults.standard.set(enabled, forKey: Self.organismKernelEnabledKey)

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
        at fixedAt: Date
    ) -> CognitiveCapsuleRequest {
        var projection = initialProjection
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
    func resolveStandingView(id: UUID, approved: Bool) async {
        _ = await substrate.resolveStandingView(id: id, approved: approved)
        scheduleDirtyMicrocycle(reason: "standing_view_resolution")
        publishRuntimeChange(reason: "proposal:standing_view_resolved")
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

    func runResearchHarness() async {
        await bootstrap()
        for kind in CognitiveExperimentKind.allCases {
            _ = await substrate.runResearchExperiment(kind: kind, seed: "observatory")
        }
        publishRuntimeChange(reason: "experiment:harness_completed")
    }

    @discardableResult
    func exportResearchTrace() async -> String? {
        await bootstrap()
        let payload = await substrate.exportResearchTrace()
        let dir = dataRoot
            .appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("cognitive-research-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try await SwiftNativePersistenceCore().writeJSON(payload, to: path)
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
                    await substrate.recordReceipt(
                        kind: "cognition.organism_loop_deferred",
                        payload: .object([
                            "reason": .string(reason),
                            "loopBudget": .string(posture.loopBudget.rawValue),
                            "posture": .string(posture.posture),
                        ])
                    )
                    return .skipped("organism loop budget is conserve")
                }
            case .normal:
                break
            }
        }
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
        return .allowed
    }
    }


    static func loadConfiguration() -> CognitiveConfiguration {  // internal for actor extensions (move-only Wave C)
        let env = ProcessInfo.processInfo.environment
        let enabled = UserDefaults.standard.bool(forKey: enabledKey)
            || env["NATIVE_AGENT_COGNITION_ENABLED"] == "1"
        let capsuleEnabled = enabled && (
            UserDefaults.standard.object(forKey: capsuleKey) as? Bool ?? true
        )
        let backgroundEnabled = enabled && (
            UserDefaults.standard.object(forKey: backgroundKey) as? Bool ?? true
        )
        let reflectionEnabled = enabled && (
            UserDefaults.standard.bool(forKey: reflectionKey)
                || env["NATIVE_AGENT_COGNITION_REFLECTION_ENABLED"] == "1"
        )
        let budgetDefault = reflectionEnabled ? 2 : 0
        let storedBudget = UserDefaults.standard.object(forKey: reflectionBudgetKey) as? Int
        let budget = max(0, storedBudget ?? budgetDefault)
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

    private static func loadOrganismConfiguration(dataRoot: URL) -> OrganismConfiguration {
        reconcileOrganismPreferenceForLaunch(dataRoot: dataRoot)
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
    static let organismKernelEnabledKey = "organismKernelEnabled"  // internal for actor extensions (move-only Wave C)
    static let reflectionModelKey = "cognitiveSubstrateReflectionModel"
    static let reflectionProviderKey = "cognitiveSubstrateReflectionProvider"
}
