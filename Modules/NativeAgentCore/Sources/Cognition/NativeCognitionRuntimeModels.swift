import Foundation
import ChatOrchestration
import CognitiveSubstrate
import Context
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting

public struct NativeCognitionPreferenceDefaults: @unchecked Sendable {
    public let defaults: UserDefaults

    public static let standard = Self(defaults: .standard)
}

public struct CognitiveObservatoryDetail: Sendable {
    public var configuration: CognitiveConfiguration
    public var summary: CognitiveObservatorySnapshot
    public var substrate: CognitiveSubstrateSnapshot
    public var workspace: CognitiveWorkspaceSnapshot
    public var associations: [CognitiveAssociationEdge]
    public var thoughtSeeds: [CognitiveThoughtSeed]
    public var thoughtSuggestions: [CognitiveThoughtSuggestion]
    var episodes: [CognitiveEpisodeReference]
    public var schemaProposals: [CognitiveSchemaProposal]
    public var standingViews: [CognitiveStandingView]
    public var developmentalTimeline: [CognitiveDevelopmentalTimelineEvent]
    /// 2026-09-13: the seven-day readout — what changed this week and why —
    /// projected from the timeline above and grouped by lesson or view. The
    /// raw events remain below it: the readout is the answer, the events are
    /// the receipts behind it.
    public var growthWeek: CognitiveGrowthWeek
    public var reflections: [CognitiveReflectionReceipt]
    /// Carries receipt-read availability through the runtime boundary.  The
    /// compatibility `receipts` projection below remains for older consumers,
    /// but the Observatory must render this state rather than infer from it.
    public var receiptRead: CognitiveReceiptRead
    public var receipts: [CognitiveReceiptRecord]
    public var facultyMeasurements: [CognitiveFacultyMeasurement]
    public var experiments: [CognitiveExperimentResult]
    public var welfareBounds: CognitiveWelfareBounds
    public var organism: OrganismSnapshot
    public var lastResearchExportPath: String?
    public var capsulePreview: CognitiveCapsule?
    public var capsulePreviewInfo: CapsulePreviewInfo?
    /// The aboutness under the felt words (U3, 2026-07-09) — a pure read of the same
    /// signals the fingerprint is built from. nil when cognition/affect is off or no
    /// mode is genuinely dominant. Read-only: it adds no capsule text and drives nothing.
    public var feltMode: CognitiveSubstrate.FeltMode?
}

/// The Observatory's complete projection plus the truthfulness of its
/// receipt-evidence lane. An otherwise useful live snapshot is still partial
/// when its durable loop receipts cannot be read; callers must carry that
/// state rather than treat the compatibility `receipts` array as a quiet zero.
public struct CognitiveObservatoryDetailRead: Sendable {
    public enum EvidenceStatus: Sendable, Equatable {
        case complete
        case receiptEvidenceUnavailable(CognitiveReceiptReadUnavailability)
    }

    public let detail: CognitiveObservatoryDetail
    public let evidenceStatus: EvidenceStatus

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

/// Doctor's bounded, mutation-free read of mounted state; no Observatory refresh.
public struct CognitiveDoctorRead: Sendable {
    public let configuration: CognitiveConfiguration
    public let affect: CognitiveAffectState
    public let substrate: CognitiveSubstrateSnapshot
    public let workspace: CognitiveWorkspaceSnapshot
    public let associations: [CognitiveAssociationEdge]
    public let thoughtSeeds: [CognitiveThoughtSeed]
    public let receiptRead: CognitiveReceiptRead
    public let welfareBounds: CognitiveWelfareBounds
    public let organism: OrganismSnapshot
    public let capsulePreviewInfo: CapsulePreviewInfo?
}

/// Provenance for the Observatory's Capsule Preview: whether the shown capsule is
/// the one Agent ACTUALLY received in her last live chat turn (mirrored at
/// injection), or a synthetic inspect-only compile shown only before any chat
/// injection this session. Lets the panel label what it's showing instead of
/// reading like a frozen constant.
public struct CapsulePreviewInfo: Sendable {
    public enum Source: Sendable { case liveInjected, synthetic }
    public var source: Source
    /// The user message this capsule was built for (live injections only).
    public var userMessage: String?
    /// When it was injected — the capsule's own compile time (live injections only).
    public var at: Date?
}

public struct CognitiveBridgeCapsuleSummary: Sendable {
    public var source: String
    public var generatedAt: Date?
    public var hasBodyLine: Bool
    public var bodyLine: String?
    public var dynamicContextCharacters: Int
    public var truncated: Bool?
}

public struct NativeCognitionRuntimeChange: Sendable, Equatable {
    public let revision: UInt64
    public let occurredAt: Date
    public let reason: String
}

/// The observable result of invoking every registered cognition evaluation
/// sampler. A nil substrate result is an unavailable sampler, not an empty or
/// successful evaluation run.
public struct CognitiveEvaluationSamplerOutcome: Sendable, Equatable {
    let recordedKinds: [CognitiveExperimentKind]
    let unavailableKinds: [CognitiveExperimentKind]
    public let failureDetail: String?

    public var isFailed: Bool { failureDetail != nil }

    public var isComplete: Bool {
        !isFailed
            && unavailableKinds.isEmpty
            && recordedKinds.count == CognitiveExperimentKind.allCases.count
    }

    public var presentationText: String {
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

public struct NativeSubconsciousRuntimeState: Sendable, Equatable {
    public let enabled: Bool
    public let capsuleEnabled: Bool
    public let backgroundEnabled: Bool
    public let reflectionEnabled: Bool
    public let reflectionBudget: Int
    public let organismEnabled: Bool
}

public struct NativeReflectionRouteStatus: Sendable, Equatable {
    public let model: String
    public let providerID: String
    public let providerReady: Bool
    public let modelKnown: Bool?
    public let detail: String

    public var isReady: Bool { providerReady && modelKnown != false }
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

public enum CognitiveTransientStateClearOutcome: Sendable, Equatable {
    case cleared
    case persistenceFailed(String)
    case bodyPersistenceFailed
}

public enum OrganismDebugBodyScenario: String, CaseIterable, Sendable {
    case providerBrittle = "provider_brittle"
    case stalePhone = "stale_phone"
    case resourceTight = "resource_tight"
    case memoryBrittle = "memory_brittle"
    case approvalClosed = "approval_closed"
}

public struct OrganismDebugBodyOverrideStatus: Sendable {
    public var scenario: OrganismDebugBodyScenario
    public var expiresAt: Date
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

/// The mutation receipt behind the Observatory's Settle and Reset controls.
/// A body snapshot alone is not proof that a requested state made it to disk:
/// callers must be able to distinguish a committed change from an in-memory
/// change that was rolled back after the persistence barrier refused it.
public enum OrganismContinuityApplyStatus: String, Sendable, Equatable {
    case applied
    case organismDisabled = "organism_disabled"
    case persistenceFailed = "persistence_failed"
}

public struct OrganismContinuityApplyOutcome: Sendable, Equatable {
    public var status: OrganismContinuityApplyStatus
    public var snapshot: OrganismSnapshot
    public var error: String?

    public var applied: Bool { status == .applied }
}

// internal for +Organism extension (move-only Wave C)
struct OrganismDebugBodyOverride: Sendable {
    var scenario: OrganismDebugBodyScenario
    var expiresAt: Date
}


public enum CognitiveBackgroundRunOutcome: Sendable, Equatable {
    case completed(String)
    case skipped(String)
    case failed(String)
}

/// Process-local counters for the event-driven dirty-settlement pilot. This is
/// evidence only: it is not persisted into cognition, does not schedule work,
/// and has no control authority. An external manual sampler can correlate the
/// instance/process identity across real restarts without pretending the
/// counter itself survived one.
public struct CognitiveMicrocycleTelemetry: Sendable, Equatable {
    public let runtimeInstanceId: String
    public let processIdentifier: Int32
    public let runtimeInitializedAt: Date
    public var scheduledSignalCount: UInt64 = 0
    public var coalescedReplacementCount: UInt64 = 0
    public var executedCount: UInt64 = 0
    public var completedCount: UInt64 = 0
    public var skippedCount: UInt64 = 0
    public var failedCount: UInt64 = 0
    public var lastScheduledAt: Date?
    public var lastStartedAt: Date?
    public var lastFinishedAt: Date?
    public var lastReason: String?
    public var lastOutcome: String?
    public var lastDurationMilliseconds: Int?

    public static func fresh(now: Date = Date()) -> Self {
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
public enum CognitiveMicrocycleSchedulingMode: Sendable {
    case automatic
    case manuallyFlushed
}

// internal for +Reflection extension (move-only Wave C)
public enum CognitiveBackgroundGate: Sendable, Equatable {
    case allowed
    case skipped(String)
}
