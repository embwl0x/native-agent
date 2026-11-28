import Synchronization
import CryptoKit
import Foundation
import HashTreeCollections
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ContextFlowModels.swift` | Context identities, policy and immutable generations |

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

    public static func digest(parts: [String]) -> String {
        var hasher = SHA256()
        for part in parts {
            let bytes = Data(part.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { unsafe hasher.update(bufferPointer: $0) }
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Source and atom policy

public struct ContextSurface: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    /// Normalize surface IDs at construction, including decoding, so persisted and requested IDs intersect.
    public init(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { self.rawValue = "unknown"; return }
        if normalized == "agent-bridge" {
            self.rawValue = "bridge"
            return
        }
        // Studio Wander shares the workshop kernel and local-private sources while retaining its `studio_wander` route.
        if normalized == "studio_wander" {
            self.rawValue = WorkshopSurfaceVocabulary.canonical
            return
        }
        self.rawValue = normalized
    }

    public static let chat = ContextSurface(rawValue: "chat")
    public static let telegram = ContextSurface(rawValue: "telegram")
    public static let ios = ContextSurface(rawValue: "ios")
    public static let slack = ContextSurface(rawValue: "slack")
    public static let workshop = ContextSurface(rawValue: WorkshopSurfaceVocabulary.canonical)
    public static let bridge = ContextSurface(rawValue: "bridge")
    /// Standing bots use the agent's Trust.
    public static let bot = ContextSurface(rawValue: "bot")

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
    case news
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
    /// Select at most one lived relationship memory independently of ordinary memory.
    case personal
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

    private enum CodingKeys: String, CodingKey { case utf8Start, utf8End }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let start = try values.decode(Int.self, forKey: .utf8Start)
        let end = try values.decode(Int.self, forKey: .utf8End)
        guard start >= 0, end >= start else {
            throw DecodingError.dataCorruptedError(forKey: .utf8End, in: values,
                debugDescription: "Invalid UTF-8 source range")
        }
        utf8Start = start
        utf8End = end
    }
}

public struct ContextFreshness: Codable, Equatable, Sendable {
    public let createdAt: Date?
    public let recallSeedAt: Date?
    public let updatedAt: Date
    public let expiresAt: Date?
    public let startsAt: Date?

    public init(updatedAt: Date, expiresAt: Date? = nil, createdAt: Date? = nil, recallSeedAt: Date? = nil, startsAt: Date? = nil) {
        self.createdAt = createdAt
        self.recallSeedAt = recallSeedAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.startsAt = startsAt
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
    public let memoryRoots: [MemoryRoot]?
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
        memoryRoots: [MemoryRoot]? = nil,
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
        self.memoryRoots = memoryRoots
        self.triggers = triggers
        self.activation = min(1, max(0, activation))
        self.recentUsefulness = min(1, max(0, recentUsefulness))
        self.decayState = min(1, max(0, decayState))
        self.embedding = embedding
    }
}

public struct ContextCompiledSource: Codable, Equatable, Sendable {
    public let descriptor: ContextSourceDescriptor
    public let sourceHash: String
    public let atoms: [ContextAtomDraft]

    public init(
        descriptor: ContextSourceDescriptor,
        sourceHash: String,
        atoms: [ContextAtomDraft]
    ) {
        self.descriptor = descriptor
        self.sourceHash = sourceHash
        self.atoms = atoms
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

public struct ContextStoredGeneration: Codable, Equatable, Sendable {
    public private(set) var generation: ContextGenerationRecord
    private var sourceIndex: TreeDictionary<ContextSourceID, [ContextStoredSource]>
    private var atomIndexByID: TreeDictionary<ContextAtomID, [ContextStoredAtom]>
    private var atomsBySource: TreeDictionary<ContextSourceID, [ContextStoredAtom]>
    private(set) var compiledSources: ContextCompiledSources
    private(set) var degradedCount: Int
    private var ordered: OrderedRows

    private final class OrderedRows: Sendable {
        let sources: Mutex<[ContextStoredSource]?>
        let atoms: Mutex<[ContextStoredAtom]?>

        init(sources: [ContextStoredSource]? = nil, atoms: [ContextStoredAtom]? = nil) {
            self.sources = Mutex(sources)
            self.atoms = Mutex(atoms)
        }
    }

    public var sources: [ContextStoredSource] {
        ordered.sources.withLock { cached in
            if let rows = cached { return rows }
            let ids = sourceIndex.keys.sorted { $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8) }
            let rows = ids.flatMap { sourceIndex[$0] ?? [] }
            cached = rows
            return rows
        }
    }

    public var atoms: [ContextStoredAtom] {
        ordered.atoms.withLock { cached in
            if let rows = cached { return rows }
            let ids = atomsBySource.keys.sorted { $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8) }
            let rows = ids.flatMap { atomsBySource[$0] ?? [] }
            cached = rows
            return rows
        }
    }

    public func sources(id: ContextSourceID) -> [ContextStoredSource] { sourceIndex[id] ?? [] }
    public func atoms(id: ContextAtomID) -> [ContextStoredAtom] { atomIndexByID[id] ?? [] }
    public func atoms(sourceID: ContextSourceID) -> [ContextStoredAtom] { atomsBySource[sourceID] ?? [] }

    public init(generation: ContextGenerationRecord, sources: [ContextStoredSource], atoms: [ContextStoredAtom]) {
        self.generation = generation
        self.ordered = OrderedRows(sources: sources, atoms: atoms)
        sourceIndex = TreeDictionary(grouping: sources, by: \.descriptor.id)
        atomIndexByID = TreeDictionary(grouping: atoms, by: \.draft.id)
        atomsBySource = TreeDictionary(grouping: atoms, by: \.draft.sourceID)
        compiledSources = ContextCompiledSources()
        degradedCount = sources.filter { $0.health == .degraded }.count
        for source in sources {
            compiledSources[source.descriptor.id] = ContextCompiledSource(
                descriptor: source.descriptor, sourceHash: source.sourceHash,
                atoms: atomsBySource[source.descriptor.id]?.map(\.draft) ?? [])
        }
    }

    mutating func markDegraded(_ id: ContextSourceID, error: String) {
        guard let source = sourceIndex[id]?.first else { return }
        if source.health != .degraded { degradedCount += 1 }
        sourceIndex[id] = [ContextStoredSource(descriptor: source.descriptor, sourceHash: source.sourceHash,
            health: .degraded, lastError: error, validFromGeneration: source.validFromGeneration,
            validToGeneration: source.validToGeneration)]
        ordered = OrderedRows()
    }

    mutating func apply(_ record: ContextGenerationRecord, sources: [ContextStoredSource], atoms: [ContextStoredAtom],
                        replaced: Set<ContextSourceID>) -> Set<ContextAtomID> {
        var removed = Set<ContextAtomID>()
        for id in replaced {
            if sourceIndex.removeValue(forKey: id)?.first?.health == .degraded { degradedCount -= 1 }
            compiledSources[id] = nil
            for atom in atomsBySource.removeValue(forKey: id) ?? [] {
                removed.insert(atom.draft.id)
                atomIndexByID.removeValue(forKey: atom.draft.id)
            }
        }
        let bySource = Dictionary(grouping: atoms, by: \.draft.sourceID)
        for source in sources {
            let id = source.descriptor.id
            sourceIndex[id] = [source]
            if source.health == .degraded { degradedCount += 1 }
            let entries = bySource[id] ?? []
            compiledSources[id] = ContextCompiledSource(descriptor: source.descriptor, sourceHash: source.sourceHash,
                atoms: entries.map(\.draft))
            atomsBySource[id] = entries
            for atom in entries { atomIndexByID[atom.draft.id] = [atom] }
        }
        generation = record
        ordered = OrderedRows()
        return removed
    }

    private enum CodingKeys: CodingKey { case generation, sources, atoms }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(generation: values.decode(ContextGenerationRecord.self, forKey: .generation),
            sources: values.decode([ContextStoredSource].self, forKey: .sources),
            atoms: values.decode([ContextStoredAtom].self, forKey: .atoms))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(generation, forKey: .generation)
        try values.encode(sources, forKey: .sources)
        try values.encode(atoms, forKey: .atoms)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.generation == rhs.generation && (lhs.ordered === rhs.ordered ||
            (lhs.sources == rhs.sources && lhs.atoms == rhs.atoms))
    }
}

public struct ContextStorePruneResult: Codable, Equatable, Sendable {
    public let deletedGenerations: Int
    public let deletedAtomVersions: Int
    public let deletedSourceVersions: Int

    public init(
        deletedGenerations: Int,
        deletedAtomVersions: Int,
        deletedSourceVersions: Int
    ) {
        self.deletedGenerations = deletedGenerations
        self.deletedAtomVersions = deletedAtomVersions
        self.deletedSourceVersions = deletedSourceVersions
    }

    /// An all-zero prune frees no pages, so VACUUM would only rewrite the database.
    public var totalDeleted: Int {
        deletedGenerations + deletedAtomVersions + deletedSourceVersions
    }
}

public enum ContextFlowStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyGeneration
    case duplicateSource(String)
    case sourceRemovedAndChanged(String)
    case duplicateAtom(String)
    case atomSourceMismatch(atomID: String, expectedSourceID: String)
    case generationNotFound(Int64)
    case malformedStoredValue(String)

    public var description: String {
        switch self {
        case .emptyGeneration:
            "a noninitial generation has no source changes or removals"
        case .duplicateSource(let id):
            "duplicate source in generation: \(id)"
        case .sourceRemovedAndChanged(let id):
            "source cannot be changed and removed in one generation: \(id)"
        case .duplicateAtom(let id):
            "duplicate active atom id: \(id)"
        case .atomSourceMismatch(let atomID, let expectedSourceID):
            "atom \(atomID) does not belong to source \(expectedSourceID)"
        case .generationNotFound(let id):
            "context generation not found: \(id)"
        case .malformedStoredValue(let field):
            "malformed stored context value: \(field)"
        }
    }
}
