import Foundation
import CognitiveSubstrate
import Context
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting
// Blueprint: | `NativeCognitionRuntimeModels.swift` | `CognitiveObservatoryDetail`. |

public struct CognitiveObservatoryDetail: Sendable {
    public var configuration: CognitiveConfiguration
    public var summary: CognitiveObservatorySnapshot
    public var substrate: CognitiveSubstrateSnapshot
    public var workspace: CognitiveWorkspaceSnapshot
    public var associations: [CognitiveAssociationEdge]
    public var schemaProposals: [CognitiveSchemaProposal]
    public var developmentalTimeline: [CognitiveDevelopmentalTimelineEvent]
    /// Keep raw events as receipts behind the grouped timeline projection.
    public var growthWeek: CognitiveGrowthWeek
    public var reflections: [CognitiveReflectionReceipt]
    /// Carry evidence and availability together.
    public var receiptRead: CognitiveReceiptRead
    public var organism: OrganismSnapshot
    public var capsulePreview: CognitiveCapsule?
    public var capsulePreviewInfo: CapsulePreviewInfo?
    /// Absent or nondominant cognition has no fingerprint aboutness.
    public var feltMode: CognitiveSubstrate.FeltMode?
}

/// Doctor reads mounted state without mutation or an Observatory refresh.
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

/// Distinguish the last delivered capsule from a cold synthetic inspection so Observatory can label its actual provenance.
public struct CapsulePreviewInfo: Sendable {
    public enum Source: Sendable { case liveInjected, synthetic }
    public var source: Source
    public var userMessage: String?
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

/// A snapshot cannot prove durable mutation; expose settlement receipts so callers distinguish committed state from failed persistence.
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


/// Process-local counters supply diagnostics only; they cannot persist into cognition, schedule work or grant authority.
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
