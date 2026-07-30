import Foundation
import PersistenceCore

public struct CognitiveExternalReference: Sendable, Equatable, Identifiable {
    public var id: String
    public var source: String
    public var title: String
    public var summary: String
    public var score: Double
    public var metadata: [String: JSONValue]

    public init(
        id: String,
        source: String,
        title: String,
        summary: String,
        score: Double,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.score = (score).clamped01()
        self.metadata = metadata
    }
}

public struct CognitiveExternalGroundingResult: Sendable, Equatable {
    public var query: String
    public var memoryHits: [CognitiveExternalReference]
    public var graphHits: [CognitiveExternalReference]
    public var notes: [String]

    public init(
        query: String,
        memoryHits: [CognitiveExternalReference] = [],
        graphHits: [CognitiveExternalReference] = [],
        notes: [String] = []
    ) {
        self.query = query
        self.memoryHits = memoryHits
        self.graphHits = graphHits
        self.notes = notes
    }
}

public struct CognitiveMemoryProposalCandidate: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var source: String
    public var confidence: Double
    public var kind: String
    public var evidenceNodeIds: [UUID]

    public init(
        id: UUID,
        text: String,
        source: String,
        confidence: Double,
        kind: String,
        evidenceNodeIds: [UUID] = []
    ) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        self.confidence = (confidence).clamped01()
        self.kind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        self.evidenceNodeIds = evidenceNodeIds
    }
}

public struct CognitiveMemoryProposalStageReceipt: Sendable, Equatable {
    public var candidateId: UUID
    public var externalProposalId: String?
    public var status: String
    public var error: String?

    public init(
        candidateId: UUID,
        externalProposalId: String?,
        status: String,
        error: String? = nil
    ) {
        self.candidateId = candidateId
        self.externalProposalId = externalProposalId
        self.status = status
        self.error = error
    }
}

public protocol CognitiveMemoryReading: Sendable {
    func recallMemory(query: String, limit: Int) async throws -> [CognitiveExternalReference]
}

public protocol CognitiveKnowledgeGraphReading: Sendable {
    func searchKnowledgeGraph(query: String, limit: Int) async throws -> [CognitiveExternalReference]
}
