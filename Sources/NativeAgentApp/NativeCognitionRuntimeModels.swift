import Foundation
import ChatOrchestration
import CognitiveSubstrate
import Context
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting

struct NativeCognitionPreferenceDefaults: @unchecked Sendable {
    let defaults: UserDefaults

    static let standard = Self(defaults: .standard)
}

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
    /// Carries receipt-read availability through the runtime boundary.  The
    /// compatibility `receipts` projection below remains for older consumers,
    /// but the Observatory must render this state rather than infer from it.
    var receiptRead: CognitiveReceiptRead
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

/// The Observatory's complete projection plus the truthfulness of its
/// receipt-evidence lane. An otherwise useful live snapshot is still partial
/// when its durable loop receipts cannot be read; callers must carry that
/// state rather than treat the compatibility `receipts` array as a quiet zero.
struct CognitiveObservatoryDetailRead: Sendable {
    enum EvidenceStatus: Sendable, Equatable {
        case complete
        case receiptEvidenceUnavailable(CognitiveReceiptReadUnavailability)
    }

    let detail: CognitiveObservatoryDetail
    let evidenceStatus: EvidenceStatus

    init(detail: CognitiveObservatoryDetail) {
        self.detail = detail
        switch detail.receiptRead {
        case .available:
            self.evidenceStatus = .complete
        case .unavailable(let reason):
            self.evidenceStatus = .receiptEvidenceUnavailable(reason)
        }
    }
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

/// The observable result of invoking every registered cognition evaluation
/// sampler. A nil substrate result is an unavailable sampler, not an empty or
/// successful evaluation run.
struct CognitiveEvaluationSamplerOutcome: Sendable, Equatable {
    let recordedKinds: [CognitiveExperimentKind]
    let unavailableKinds: [CognitiveExperimentKind]
    let failureDetail: String?

    var isFailed: Bool { failureDetail != nil }

    var isComplete: Bool {
        !isFailed
            && unavailableKinds.isEmpty
            && recordedKinds.count == CognitiveExperimentKind.allCases.count
    }

    var presentationText: String {
        if let failureDetail {
            return "Cognitive evaluation samplers failed: \(failureDetail)."
        }
        if isComplete {
            return "Recorded \(recordedKinds.count) cognitive evaluation samples."
        }
        let unavailable = unavailableKinds.map(\.rawValue).joined(separator: ", ")
        if recordedKinds.isEmpty {
            return "Cognitive evaluation samplers unavailable: \(unavailable)."
        }
        return "Recorded \(recordedKinds.count) cognitive evaluation samples; unavailable: \(unavailable)."
    }
}

/// The exact provenance of the installed-physiology recorder decision. A
/// missing report is not evidence that installed collection was meant to be
/// active: normal app use, alternate roots, and test processes are deliberately
/// excluded unless a diagnostic/eval caller opts in.
enum InstalledPhysiologySoakEnablement: Sendable, Equatable {
    /// Routine app launches must not continuously run an evaluation recorder.
    case disabledByDefault
    /// An injected root must never write into the user's installed evidence feed.
    case disabledNonDefaultDataRoot
    /// Test processes must not create evidence that could be mistaken for an
    /// installed elapsed observation.
    case disabledTestProcess
    /// Explicit alternate-runtime controls are a test/diagnostic choice, not
    /// the production root gate.
    case forcedEnabled
    case forcedDisabled
    /// An injected recorder is generated/diagnostic evidence and retains that
    /// provenance even when the ambient root would otherwise be excluded.
    case injectedEvidence

    var createsInstalledRecorder: Bool {
        switch self {
        case .forcedEnabled:
            true
        case .disabledByDefault,
             .disabledNonDefaultDataRoot,
             .disabledTestProcess,
             .forcedDisabled,
             .injectedEvidence:
            false
        }
    }
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
    case reviewInFlight = "review_in_flight"
    case notAwaitingReview = "not_awaiting_review"
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

/// The mutation receipt behind the Observatory's Settle and Reset controls.
/// A body snapshot alone is not proof that a requested state made it to disk:
/// callers must be able to distinguish a committed change from an in-memory
/// change that was rolled back after the persistence barrier refused it.
enum OrganismContinuityApplyStatus: String, Sendable, Equatable {
    case applied
    case organismDisabled = "organism_disabled"
    case persistenceFailed = "persistence_failed"
}

struct OrganismContinuityApplyOutcome: Sendable, Equatable {
    var status: OrganismContinuityApplyStatus
    var snapshot: OrganismSnapshot
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
