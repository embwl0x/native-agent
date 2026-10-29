import Foundation
import CognitiveSubstrate
import Context
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting
// Blueprint: | `NativeCognitionRuntimeModels.swift` | `CognitiveObservatoryDetail` and runtime read models; shared affect validity and organism sample freshness/validity |

public struct CognitiveObservatoryDetail: Sendable {
    public var configuration: CognitiveConfiguration
    public var summary: CognitiveObservatorySnapshot
    public var substrate: CognitiveSubstrateSnapshot
    public var workspace: CognitiveWorkspaceSnapshot
    public var associations: [CognitiveAssociationEdge]
    public var schemaProposals: [CognitiveSchemaProposal]
    public var developmentalTimeline: [CognitiveDevelopmentalTimelineEvent]
    /// Seven-day timeline projection grouped by lesson or view; raw events remain its receipts.
    public var growthWeek: CognitiveGrowthWeek
    public var reflections: [CognitiveReflectionReceipt]
    /// Receipt evidence and its availability travel as one value.
    public var receiptRead: CognitiveReceiptRead
    public var organism: OrganismSnapshot
    public var capsulePreview: CognitiveCapsule?
    public var capsulePreviewInfo: CapsulePreviewInfo?
    /// Read-only fingerprint aboutness; nil when cognition/affect is off or no mode dominates.
    public var feltMode: CognitiveSubstrate.FeltMode?
}

/// Doctor's bounded, mutation-free read of mounted state; no Observatory refresh.
public struct CognitiveDoctorRead: Sendable {
    public let configuration: CognitiveConfiguration
    public let affect: CognitiveAffectState
    public let substrate: CognitiveSubstrateSnapshot
    public let workspace: CognitiveWorkspaceSnapshot
    public let associations: [CognitiveAssociationEdge]
    public let receiptRead: CognitiveReceiptRead
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

struct OrganismDebugBodyOverride: Sendable {
    var scenario: OrganismDebugBodyScenario
    var expiresAt: Date
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

extension CognitiveAffectState {
    public var observatoryValuesAreValid: Bool {
        [arousal, uncertainty, taskPressure, socialWarmth].allSatisfy {
            $0.isFinite && (0...1).contains($0)
        }
    }
}

extension OrganismSnapshot {
    public func observatorySampleIsCurrent(now: Date, maximumSampleAge: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(generatedAt)
        return generatedAt.timeIntervalSinceReferenceDate.isFinite
            && now.timeIntervalSinceReferenceDate.isFinite
            && age >= -60 && age <= maximumSampleAge
    }

    public var observatoryValuesAreValid: Bool {
        [
            chemicalState.warmth,
            chemicalState.vigilance,
            chemicalState.coherence,
            chemicalState.confidence,
            chemicalState.fatigue,
            chemicalState.agency,
            fieldSummary.strongestEdgeWeight,
            fieldSummary.totalCharge,
            fieldSummary.averageUncertainty,
            predictionSummary.peripheralUncertainty,
            predictionSummary.strategyCaution,
            predictionSummary.bodyConfidence.toolPath,
            predictionSummary.bodyConfidence.providerPath,
            predictionSummary.bodyConfidence.phonePath,
            residualRepairOpportunity.pressure,
        ].allSatisfy(\.isFinite)
    }
}
