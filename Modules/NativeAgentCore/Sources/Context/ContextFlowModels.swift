import CryptoKit
import Foundation
import NativeAgentCore

// MARK: - Stable identifiers

public struct ContextSourceID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ContextAtomID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ContextRelationshipID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ContextStableID {
    public static func source(owner: String, locator: String) -> ContextSourceID {
        ContextSourceID(rawValue: "source:" + digest(parts: [owner, locator]))
    }

    public static func atom(
        sourceID: ContextSourceID,
        kind: ContextAtomKind,
        headingPath: [String],
        blockAnchor: String
    ) -> ContextAtomID {
        ContextAtomID(rawValue: "atom:" + digest(parts: [
            sourceID.rawValue,
            kind.rawValue,
            headingPath.joined(separator: "/"),
            blockAnchor,
        ]))
    }

    public static func relationship(
        source: ContextAtomID,
        target: ContextAtomID,
        kind: String
    ) -> ContextRelationshipID {
        ContextRelationshipID(rawValue: "relationship:" + digest(parts: [
            source.rawValue,
            target.rawValue,
            kind,
        ]))
    }

    public static func digest(parts: [String]) -> String {
        var hasher = SHA256()
        for part in parts {
            let bytes = Data(part.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Source and atom policy

public struct ContextSurface: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    /// P2-3: `missions` was the Workshop surface's wire id through 0.3.7 and is
    /// still stored in `context.db`'s `permitted_surfaces_json`. Folding it here
    /// — the single construction point, which `Codable` synthesis also routes
    /// through — means an atom persisted with `missions` and a request minted
    /// with `workshop` still compare equal. Without the fold the two
    /// vocabularies never intersect and every Workshop context read returns
    /// zero atoms, silently.
    public init(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { self.rawValue = "unknown"; return }
        self.rawValue = WorkshopSurfaceVocabulary.canonicalSurface(normalized)
    }

    public static let chat = ContextSurface(rawValue: "chat")
    public static let telegram = ContextSurface(rawValue: "telegram")
    public static let ios = ContextSurface(rawValue: "ios")
    public static let slack = ContextSurface(rawValue: "slack")
    public static let workshop = ContextSurface(rawValue: WorkshopSurfaceVocabulary.canonical)
    public static let bridge = ContextSurface(rawValue: "bridge")

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ContextSourceKind: String, Codable, CaseIterable, Sendable {
    case persona
    case memory
    case skill
    case desk
    case dream
    case standingView = "standing_view"
    case project
    case capability
    case other
}

public enum ContextAtomKind: String, Codable, CaseIterable, Sendable {
    case identity
    case relationship
    case correction
    case instruction
    case fact
    case memory
    case procedure
    case evidence
    case project
    case capability
    case runtimeTruth = "runtime_truth"
    case other
}

public enum ContextAuthority: String, Codable, CaseIterable, Sendable {
    case identity
    case explicitCorrection = "explicit_correction"
    case canonical
    case approved
    case inferred
    case external

    public var rank: Int {
        switch self {
        case .identity: 6
        case .explicitCorrection: 5
        case .canonical: 4
        case .approved: 3
        case .inferred: 2
        case .external: 1
        }
    }
}

public enum ContextPrivacy: String, Codable, CaseIterable, Sendable {
    case localPrivate = "local_private"
    case trustedRemote = "trusted_remote"
    case publicSafe = "public_safe"
}

public enum ContextInjectionPolicy: String, Codable, CaseIterable, Sendable {
    case always
    case adaptive
    case onDemand = "on_demand"
    case neverInject = "never_inject"
}

public enum ContextContentRole: String, Codable, CaseIterable, Sendable {
    case identity
    case instruction
    case fact
    case memory
    case procedure
    case evidence
    case untrustedExternalData = "untrusted_external_data"
}

public enum ContextSourceHealth: String, Codable, CaseIterable, Sendable {
    case healthy
    case degraded
    case removed
}

public struct ContextSourceRange: Codable, Equatable, Hashable, Sendable {
    public let utf8Start: Int
    public let utf8End: Int

    public init(utf8Start: Int, utf8End: Int) {
        let start = max(0, utf8Start)
        self.utf8Start = start
        self.utf8End = max(start, utf8End)
    }
}

public struct ContextFreshness: Codable, Equatable, Sendable {
    public let updatedAt: Date
    public let expiresAt: Date?

    public init(updatedAt: Date, expiresAt: Date? = nil) {
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }
}

public struct ContextEntity: Codable, Equatable, Hashable, Sendable {
    public let kind: String
    public let id: String
    public let label: String

    public init(kind: String, id: String, label: String) {
        self.kind = kind
        self.id = id
        self.label = label
    }
}

public struct ContextSourceDescriptor: Codable, Equatable, Sendable {
    public let id: ContextSourceID
    public let owner: String
    public let kind: ContextSourceKind
    public let canonicalLocator: String
    public let authority: ContextAuthority
    public let privacy: ContextPrivacy
    public let permittedSurfaces: Set<ContextSurface>
    public let injectionPolicy: ContextInjectionPolicy

    public init(
        id: ContextSourceID,
        owner: String,
        kind: ContextSourceKind,
        canonicalLocator: String,
        authority: ContextAuthority,
        privacy: ContextPrivacy,
        permittedSurfaces: Set<ContextSurface>,
        injectionPolicy: ContextInjectionPolicy
    ) {
        self.id = id
        self.owner = owner
        self.kind = kind
        self.canonicalLocator = canonicalLocator
        self.authority = authority
        self.privacy = privacy
        self.permittedSurfaces = permittedSurfaces
        self.injectionPolicy = injectionPolicy
    }
}

// MARK: - Compiled generation inputs

public struct ContextEmbedding: Codable, Equatable, Sendable {
    public let modelFingerprint: String
    public let values: [Float]

    public init(modelFingerprint: String, values: [Float]) {
        self.modelFingerprint = modelFingerprint
        self.values = values
    }
}

public struct ContextAtomDraft: Codable, Equatable, Sendable {
    public let id: ContextAtomID
    public let sourceID: ContextSourceID
    public let kind: ContextAtomKind
    public let headingPath: [String]
    public let sourceRange: ContextSourceRange
    public let sourceHash: String
    public let body: String
    public let deterministicSummary: String?
    public let authority: ContextAuthority
    public let confidence: Double
    public let freshness: ContextFreshness
    public let privacy: ContextPrivacy
    public let permittedSurfaces: Set<ContextSurface>
    public let injectionPolicy: ContextInjectionPolicy
    public let contentRole: ContextContentRole
    public let entities: [ContextEntity]
    public let triggers: [String]
    public let activation: Double
    public let recentUsefulness: Double
    public let decayState: Double
    public let embedding: ContextEmbedding?

    public init(
        id: ContextAtomID,
        sourceID: ContextSourceID,
        kind: ContextAtomKind,
        headingPath: [String],
        sourceRange: ContextSourceRange,
        sourceHash: String,
        body: String,
        deterministicSummary: String? = nil,
        authority: ContextAuthority,
        confidence: Double,
        freshness: ContextFreshness,
        privacy: ContextPrivacy,
        permittedSurfaces: Set<ContextSurface>,
        injectionPolicy: ContextInjectionPolicy,
        contentRole: ContextContentRole,
        entities: [ContextEntity] = [],
        triggers: [String] = [],
        activation: Double = 0,
        recentUsefulness: Double = 0,
        decayState: Double = 1,
        embedding: ContextEmbedding? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.kind = kind
        self.headingPath = headingPath
        self.sourceRange = sourceRange
        self.sourceHash = sourceHash
        self.body = body
        self.deterministicSummary = deterministicSummary
        self.authority = authority
        self.confidence = min(1, max(0, confidence))
        self.freshness = freshness
        self.privacy = privacy
        self.permittedSurfaces = permittedSurfaces
        self.injectionPolicy = injectionPolicy
        self.contentRole = contentRole
        self.entities = entities
        self.triggers = triggers
        self.activation = min(1, max(0, activation))
        self.recentUsefulness = min(1, max(0, recentUsefulness))
        self.decayState = min(1, max(0, decayState))
        self.embedding = embedding
    }
}

public struct ContextRelationshipDraft: Codable, Equatable, Sendable {
    public let id: ContextRelationshipID
    public let sourceAtomID: ContextAtomID
    public let targetAtomID: ContextAtomID
    public let kind: String
    public let weight: Double
    public let provenance: String

    public init(
        id: ContextRelationshipID,
        sourceAtomID: ContextAtomID,
        targetAtomID: ContextAtomID,
        kind: String,
        weight: Double,
        provenance: String
    ) {
        self.id = id
        self.sourceAtomID = sourceAtomID
        self.targetAtomID = targetAtomID
        self.kind = kind
        self.weight = min(1, max(0, weight))
        self.provenance = provenance
    }
}

public struct ContextCompiledSource: Codable, Equatable, Sendable {
    public let descriptor: ContextSourceDescriptor
    public let sourceHash: String
    public let atoms: [ContextAtomDraft]
    public let relationships: [ContextRelationshipDraft]

    public init(
        descriptor: ContextSourceDescriptor,
        sourceHash: String,
        atoms: [ContextAtomDraft],
        relationships: [ContextRelationshipDraft] = []
    ) {
        self.descriptor = descriptor
        self.sourceHash = sourceHash
        self.atoms = atoms
        self.relationships = relationships
    }
}

public struct ContextGenerationDraft: Codable, Equatable, Sendable {
    public let reason: String
    public let changedSources: [ContextCompiledSource]
    public let removedSourceIDs: Set<ContextSourceID>
    public let createdAt: Date

    public init(
        reason: String,
        changedSources: [ContextCompiledSource],
        removedSourceIDs: Set<ContextSourceID> = [],
        createdAt: Date = Date()
    ) {
        self.reason = reason
        self.changedSources = changedSources
        self.removedSourceIDs = removedSourceIDs
        self.createdAt = createdAt
    }
}

// MARK: - Stored generation projections

public struct ContextGenerationRecord: Codable, Equatable, Sendable {
    public let id: Int64
    public let parentID: Int64?
    public let createdAt: Date
    public let reason: String
    public let sourceFingerprint: String
    public let atomCount: Int
    public let sourceCount: Int

    public init(
        id: Int64,
        parentID: Int64?,
        createdAt: Date,
        reason: String,
        sourceFingerprint: String,
        atomCount: Int,
        sourceCount: Int
    ) {
        self.id = id
        self.parentID = parentID
        self.createdAt = createdAt
        self.reason = reason
        self.sourceFingerprint = sourceFingerprint
        self.atomCount = atomCount
        self.sourceCount = sourceCount
    }
}

public struct ContextStoredSource: Codable, Equatable, Sendable {
    public let descriptor: ContextSourceDescriptor
    public let sourceHash: String
    public let health: ContextSourceHealth
    public let lastError: String?
    public let validFromGeneration: Int64
    public let validToGeneration: Int64?

    public init(
        descriptor: ContextSourceDescriptor,
        sourceHash: String,
        health: ContextSourceHealth,
        lastError: String?,
        validFromGeneration: Int64,
        validToGeneration: Int64?
    ) {
        self.descriptor = descriptor
        self.sourceHash = sourceHash
        self.health = health
        self.lastError = lastError
        self.validFromGeneration = validFromGeneration
        self.validToGeneration = validToGeneration
    }
}

public struct ContextStoredAtom: Codable, Equatable, Sendable {
    public let versionKey: String
    public let draft: ContextAtomDraft
    public let validFromGeneration: Int64
    public let validToGeneration: Int64?

    public init(
        versionKey: String,
        draft: ContextAtomDraft,
        validFromGeneration: Int64,
        validToGeneration: Int64?
    ) {
        self.versionKey = versionKey
        self.draft = draft
        self.validFromGeneration = validFromGeneration
        self.validToGeneration = validToGeneration
    }
}

public struct ContextStoredRelationship: Codable, Equatable, Sendable {
    public let versionKey: String
    public let draft: ContextRelationshipDraft
    public let validFromGeneration: Int64
    public let validToGeneration: Int64?

    public init(
        versionKey: String,
        draft: ContextRelationshipDraft,
        validFromGeneration: Int64,
        validToGeneration: Int64?
    ) {
        self.versionKey = versionKey
        self.draft = draft
        self.validFromGeneration = validFromGeneration
        self.validToGeneration = validToGeneration
    }
}

public struct ContextStoredGeneration: Codable, Equatable, Sendable {
    public let generation: ContextGenerationRecord
    public let sources: [ContextStoredSource]
    public let atoms: [ContextStoredAtom]
    public let relationships: [ContextStoredRelationship]

    public init(
        generation: ContextGenerationRecord,
        sources: [ContextStoredSource],
        atoms: [ContextStoredAtom],
        relationships: [ContextStoredRelationship]
    ) {
        self.generation = generation
        self.sources = sources
        self.atoms = atoms
        self.relationships = relationships
    }
}

public enum ContextReceiptKind: String, Codable, Sendable {
    case compile
    case selection
    case expansion
    case degraded
    case feedback
    case prewarm
    case pressure
}

public struct ContextStoreReceipt: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: ContextReceiptKind
    public let generationID: Int64?
    public let summary: String
    public let details: [String: String]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: ContextReceiptKind,
        generationID: Int64? = nil,
        summary: String,
        details: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.generationID = generationID
        self.summary = summary
        self.details = details
        self.createdAt = createdAt
    }
}

public struct ContextStorePruneResult: Codable, Equatable, Sendable {
    public let deletedGenerations: Int
    public let deletedAtomVersions: Int
    public let deletedSourceVersions: Int
    public let deletedRelationshipVersions: Int
    public let deletedReceipts: Int

    public init(
        deletedGenerations: Int,
        deletedAtomVersions: Int,
        deletedSourceVersions: Int,
        deletedRelationshipVersions: Int,
        deletedReceipts: Int
    ) {
        self.deletedGenerations = deletedGenerations
        self.deletedAtomVersions = deletedAtomVersions
        self.deletedSourceVersions = deletedSourceVersions
        self.deletedRelationshipVersions = deletedRelationshipVersions
        self.deletedReceipts = deletedReceipts
    }

    /// Total rows deleted across every category. A5.5(b): used to decide whether
    /// a follow-on VACUUM would reclaim anything (an all-zero prune freed no
    /// pages, so a rewrite would be pure churn).
    public var totalDeleted: Int {
        deletedGenerations + deletedAtomVersions + deletedSourceVersions
            + deletedRelationshipVersions + deletedReceipts
    }
}

public enum ContextFlowStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyGeneration
    case duplicateSource(String)
    case sourceRemovedAndChanged(String)
    case duplicateAtom(String)
    case atomSourceMismatch(atomID: String, expectedSourceID: String)
    case relationshipSourceMissing(String)
    case relationshipTargetMissing(String)
    case generationNotFound(Int64)
    case malformedStoredValue(String)

    public var description: String {
        switch self {
        case .emptyGeneration:
            "generation has no source changes or removals"
        case .duplicateSource(let id):
            "duplicate source in generation: \(id)"
        case .sourceRemovedAndChanged(let id):
            "source cannot be changed and removed in one generation: \(id)"
        case .duplicateAtom(let id):
            "duplicate active atom id: \(id)"
        case .atomSourceMismatch(let atomID, let expectedSourceID):
            "atom \(atomID) does not belong to source \(expectedSourceID)"
        case .relationshipSourceMissing(let id):
            "relationship source atom missing: \(id)"
        case .relationshipTargetMissing(let id):
            "relationship target atom missing: \(id)"
        case .generationNotFound(let id):
            "context generation not found: \(id)"
        case .malformedStoredValue(let field):
            "malformed stored context value: \(field)"
        }
    }
}
