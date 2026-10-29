import Foundation
import Experiences
import PersistenceCore

// Blueprint: | `CognitiveEpisodeReplay.swift` | Episode, schema proposal, developmental timeline and dream/REM replay values |
public struct CognitiveEpisodeReference: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var summary: String
    public var occurredAt: Date
    public var evidenceNodeIds: [UUID]
    public var externalEvidenceIds: [String]
    public var lineageId: String

    public init(
        id: UUID,
        title: String,
        summary: String,
        occurredAt: Date,
        evidenceNodeIds: [UUID] = [],
        externalEvidenceIds: [String] = [],
        lineageId: String = ""
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.occurredAt = occurredAt
        self.evidenceNodeIds = evidenceNodeIds
        self.externalEvidenceIds = externalEvidenceIds
        self.lineageId = lineageId
    }
}
public enum CognitiveSchemaProposalStatus: String, Sendable, Equatable, CaseIterable {
    case proposed
    case accepted
    case rejected
    case unavailable
}
public struct CognitiveSchemaProposal: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var body: String
    public var target: String
    /// A read projection, never persisted as cognitive status.
    public var decision: Experience? = nil
    public var status: CognitiveSchemaProposalStatus {
        guard let decision else { return .unavailable }
        switch decision.outcome?.status {
        case "approved": return decision.claims.contains { $0.claim == "applied" } ? .accepted : .unavailable
        case "denied", "canceled": return .rejected
        default: return decision.isOpen ? .proposed : .rejected
        }
    }
    public var confidence: Double
    public var createdAt: Date
    public var evidenceNodeIds: [UUID]
    public var externalEvidenceIds: [String]
    public var lineageId: String

    public init(
        id: UUID,
        title: String,
        body: String,
        target: String,
        confidence: Double = 0,
        createdAt: Date,
        evidenceNodeIds: [UUID] = [],
        externalEvidenceIds: [String] = [],
        lineageId: String = ""
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.target = target
        self.confidence = (confidence).clamped01()
        self.createdAt = createdAt
        self.evidenceNodeIds = evidenceNodeIds
        self.externalEvidenceIds = externalEvidenceIds
        self.lineageId = lineageId
    }
}
public enum CognitiveDevelopmentalTimelineKind: String, Sendable, Equatable, CaseIterable {
    case dreamEpisode
    case schemaProposal
    /// Read compatibility for developmental timeline rows written by the
    /// retired identity-proposal experiment. No production path emits it.
    case identityProposal
    case proposalResolution
    case replayRun
}
public struct CognitiveDevelopmentalTimelineEvent: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: CognitiveDevelopmentalTimelineKind
    public var title: String
    public var summary: String
    public var occurredAt: Date
    public var artifactId: UUID?
    public var lineageId: String
    public var subjectId: String
    public var instanceId: String
    public var forkMetadata: [String: String]
    public var externalEvidenceIds: [String]

    public init(
        id: UUID,
        kind: CognitiveDevelopmentalTimelineKind,
        title: String,
        summary: String,
        occurredAt: Date,
        artifactId: UUID? = nil,
        lineageId: String = "",
        subjectId: String = "",
        instanceId: String = "",
        forkMetadata: [String: String] = [:],
        externalEvidenceIds: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.occurredAt = occurredAt
        self.artifactId = artifactId
        self.lineageId = lineageId
        self.subjectId = subjectId
        self.instanceId = instanceId
        self.forkMetadata = forkMetadata
        self.externalEvidenceIds = externalEvidenceIds
    }
}
public struct CognitiveDreamReplayReference: Sendable, Equatable, Identifiable {
    public var id: String
    public var date: String
    public var filename: String?
    public var content: String
    public var modifiedAt: String?

    public init(
        id: String,
        date: String,
        filename: String? = nil,
        content: String,
        modifiedAt: String? = nil
    ) {
        self.id = id
        self.date = date
        self.filename = filename
        self.content = content
        self.modifiedAt = modifiedAt
    }
}
public struct CognitiveREMProposalReference: Sendable, Equatable, Identifiable {
    public var id: String
    public var target: String
    public var text: String
    public var evidenceDates: [String]
    public var confidence: Double
    public var createdAt: String

    public init(
        id: String,
        target: String,
        text: String,
        evidenceDates: [String],
        confidence: Double,
        createdAt: String
    ) {
        self.id = id
        self.target = target
        self.text = text
        self.evidenceDates = evidenceDates
        self.confidence = (confidence).clamped01()
        self.createdAt = createdAt
    }
}
public struct CognitiveReplayIntegrationInput: Sendable, Equatable {
    public var reason: String
    public var dreamEntries: [CognitiveDreamReplayReference]
    public var remProposals: [CognitiveREMProposalReference]
    /// Evidence the reader could not read, each with its cause: the lists
    /// above are what was read, not the whole past.
    public var unavailableEvidence: [String]

    public init(
        reason: String,
        dreamEntries: [CognitiveDreamReplayReference] = [],
        remProposals: [CognitiveREMProposalReference] = [],
        unavailableEvidence: [String] = []
    ) {
        self.reason = reason
        self.dreamEntries = dreamEntries
        self.remProposals = remProposals
        self.unavailableEvidence = unavailableEvidence
    }
}
public struct CognitiveReplayIntegrationResult: Sendable, Equatable {
    public var episodeIds: [UUID]
    public var schemaProposalIds: [UUID]
    public var skippedEvidenceIds: [String]
    public var timelineEventIds: [UUID]

    public init(
        episodeIds: [UUID] = [],
        schemaProposalIds: [UUID] = [],
        skippedEvidenceIds: [String] = [],
        timelineEventIds: [UUID] = []
    ) {
        self.episodeIds = episodeIds
        self.schemaProposalIds = schemaProposalIds
        self.skippedEvidenceIds = skippedEvidenceIds
        self.timelineEventIds = timelineEventIds
    }
}
