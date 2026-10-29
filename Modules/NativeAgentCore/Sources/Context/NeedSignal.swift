import Foundation
import NativeAgentCore
// Blueprint: | `NeedSignal.swift` | Context need, admitted origin/authorization, cache identity and explicit conflict vocabulary |
public enum ContextOriginClass: String, Codable, CaseIterable, Sendable {
    case localAuthenticated = "local_authenticated"
    case remoteAuthenticated = "remote_authenticated"
    case untrusted
}
/// A fail-closed projection of authorization decisions made by the runtime.
/// Selection consumes these decisions; it never grants permissions itself.
public struct ContextSelectionAuthorization: Codable, Equatable, Sendable {
    public let allowedOrigins: Set<ContextOriginClass>
    public let allowedPrivacy: Set<ContextPrivacy>
    public let allowedSourceIDs: Set<ContextSourceID>
    public let allowedAtomIDs: Set<ContextAtomID>?
    public let permissionLabels: Set<String>

    public init(
        allowedOrigins: Set<ContextOriginClass>,
        allowedPrivacy: Set<ContextPrivacy>,
        allowedSourceIDs: Set<ContextSourceID>,
        allowedAtomIDs: Set<ContextAtomID>? = nil,
        permissionLabels: Set<String> = []
    ) {
        self.allowedOrigins = allowedOrigins
        self.allowedPrivacy = allowedPrivacy
        self.allowedSourceIDs = allowedSourceIDs
        self.allowedAtomIDs = allowedAtomIDs
        self.permissionLabels = permissionLabels
    }
}
public enum ContextSelectionCacheState: String, Codable, Sendable {
    case hit
    case miss
    case unavailable
}
public struct ContextConflictDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let memberAtomIDs: Set<ContextAtomID>
    public let resolvedAtomID: ContextAtomID?
    public let provenance: String

    public init(
        id: String,
        memberAtomIDs: Set<ContextAtomID>,
        resolvedAtomID: ContextAtomID? = nil,
        provenance: String
    ) {
        self.id = id
        self.memberAtomIDs = memberAtomIDs
        self.resolvedAtomID = resolvedAtomID
        self.provenance = provenance
    }
}
/// Pure, turn-scoped input to context selection. `selectionTimeBucket` is used
/// instead of wall-clock reads so identical inputs remain restart deterministic.
public struct NeedSignal: Codable, Equatable, Sendable {
    public let message: String
    public let extractedEntities: Set<ContextEntity>
    public let surface: ContextSurface
    public let origin: ContextOriginClass
    public let authorization: ContextSelectionAuthorization
    public let sessionID: String?
    public let currentProjectID: String?
    public let executionID: String?
    public let recentTurns: [String]
    public let activeTask: String?
    public let unresolvedQuestion: String?
    public let goal: String?
    public let predictedToolGroups: Set<String>
    public let contextualTerms: Set<String>
    public let cognitiveActivation: [ContextAtomID: Double]
    public let feedbackUtilityOverrides: [ContextAtomID: Double]
    public let feedbackDecayOverrides: [ContextAtomID: Double]
    /// How reachable each atom is from its history of use, 0...1
    /// (`ContextFeedbackAtomState.reachability`). The memory lane ranks by it.
    public let memoryReachability: [ContextAtomID: Double]
    /// Turns since the atom was last served in this session's supplied history
    /// (0 = the turn before this one).
    /// A memory served this recently rests unless the message singles it out.
    public let servedTurnsAgo: [ContextAtomID: Int]
    public let precoveredSourceIDs: Set<ContextSourceID>
    public let mandatoryAtomIDs: Set<ContextAtomID>
    public let deletedAtomIDs: Set<ContextAtomID>
    public let tombstonedAtomIDs: Set<ContextAtomID>
    public let staleRuntimeAtomIDs: Set<ContextAtomID>
    public let secretBearingAtomIDs: Set<ContextAtomID>
    public let queryEmbedding: [Float]?
    /// The question in the other voice, same vector space as `queryEmbedding`.
    /// See `ContextQueryEmbeddingValue.alternateValues`.
    public let alternateQueryEmbedding: [Float]?
    /// A follow-up's own words (and their other voice), each a separate
    /// reading. See `ContextQueryEmbeddingValue.ownWordsValues`. Nil or
    /// empty when the query is the message itself; absent in older saved signals.
    public let ownWordsQueryEmbeddings: [[Float]]?
    public let queryEmbeddingModelFingerprint: String?
    /// The embedder's model id; picks the meaning scale
    /// (`ContextSelectionConfiguration.memorySemanticFloors`).
    public let queryEmbeddingModelID: String?
    public let availableGenerationID: Int64?
    public let characterBudget: Int
    public let mandatoryCharacterBudget: Int
    /// Body length above which the CALLER's packet renderer replaces an atom's
    /// full text with a lead + `context_expand` pointer. The selector uses it
    /// to publish a matching expandable pointer. Summarized representations
    /// remain expandable independently. `0` = the caller renders bodies whole.
    public let packetAtomExpandThresholdChars: Int
    /// Upper bound on `.memory`-kind atoms in one packet. `nil` leaves the
    /// selector's own per-kind quota in charge (pre-existing behavior).
    public let memoryAtomRowLimit: Int?
    public let selectionTimeBucket: Int64
    public let timeBucketSeconds: Int
    public let explicitConflicts: [ContextConflictDefinition]
    public let cacheState: ContextSelectionCacheState
    public let measuredSelectionMicroseconds: Int?

    enum CodingKeys: String, CodingKey {
        case message, extractedEntities, surface, origin, authorization
        case sessionID, currentProjectID
        case executionID = "missionID" // compatibility wire ID
        case recentTurns, activeTask, unresolvedQuestion, goal, predictedToolGroups, contextualTerms
        case cognitiveActivation, feedbackUtilityOverrides, feedbackDecayOverrides
        case memoryReachability, servedTurnsAgo, precoveredSourceIDs, mandatoryAtomIDs, deletedAtomIDs, tombstonedAtomIDs
        case staleRuntimeAtomIDs, secretBearingAtomIDs, queryEmbedding, alternateQueryEmbedding, ownWordsQueryEmbeddings
        case queryEmbeddingModelFingerprint, queryEmbeddingModelID, availableGenerationID
        case characterBudget, mandatoryCharacterBudget
        case packetAtomExpandThresholdChars, memoryAtomRowLimit
        case selectionTimeBucket, timeBucketSeconds
        case explicitConflicts, cacheState, measuredSelectionMicroseconds
    }
    public init(
        message: String,
        extractedEntities: Set<ContextEntity> = [],
        surface: ContextSurface,
        origin: ContextOriginClass,
        authorization: ContextSelectionAuthorization,
        sessionID: String? = nil,
        currentProjectID: String? = nil,
        executionID: String? = nil,
        recentTurns: [String] = [],
        activeTask: String? = nil,
        unresolvedQuestion: String? = nil,
        goal: String? = nil,
        predictedToolGroups: Set<String> = [],
        contextualTerms: Set<String> = [],
        cognitiveActivation: [ContextAtomID: Double] = [:],
        feedbackUtilityOverrides: [ContextAtomID: Double] = [:],
        feedbackDecayOverrides: [ContextAtomID: Double] = [:],
        memoryReachability: [ContextAtomID: Double] = [:],
        servedTurnsAgo: [ContextAtomID: Int] = [:],
        precoveredSourceIDs: Set<ContextSourceID> = [],
        mandatoryAtomIDs: Set<ContextAtomID> = [],
        deletedAtomIDs: Set<ContextAtomID> = [],
        tombstonedAtomIDs: Set<ContextAtomID> = [],
        staleRuntimeAtomIDs: Set<ContextAtomID> = [],
        secretBearingAtomIDs: Set<ContextAtomID> = [],
        queryEmbedding: [Float]? = nil,
        alternateQueryEmbedding: [Float]? = nil,
        ownWordsQueryEmbeddings: [[Float]]? = nil,
        queryEmbeddingModelFingerprint: String? = nil,
        queryEmbeddingModelID: String? = nil,
        availableGenerationID: Int64? = nil,
        characterBudget: Int = 6_000,
        mandatoryCharacterBudget: Int? = nil,
        packetAtomExpandThresholdChars: Int = 0,
        memoryAtomRowLimit: Int? = nil,
        now: Date = Date(),
        timeBucketSeconds: Int = 60,
        explicitConflicts: [ContextConflictDefinition] = [],
        cacheState: ContextSelectionCacheState = .unavailable,
        measuredSelectionMicroseconds: Int? = nil
    ) {
        let bucketSize = max(1, timeBucketSeconds)
        self.message = message
        self.extractedEntities = extractedEntities
        self.surface = surface
        self.origin = origin
        self.authorization = authorization
        self.sessionID = sessionID
        self.currentProjectID = currentProjectID
        self.executionID = executionID
        self.recentTurns = recentTurns
        self.activeTask = activeTask
        self.unresolvedQuestion = unresolvedQuestion
        self.goal = goal
        self.predictedToolGroups = predictedToolGroups
        self.contextualTerms = contextualTerms
        self.cognitiveActivation = cognitiveActivation.mapValues { min(1, max(0, $0)) }
        self.feedbackUtilityOverrides = feedbackUtilityOverrides.mapValues {
            min(1, max(-1, $0.isFinite ? $0 : 0))
        }
        self.feedbackDecayOverrides = feedbackDecayOverrides.mapValues {
            min(1, max(0, $0.isFinite ? $0 : 0))
        }
        self.memoryReachability = memoryReachability.mapValues { min(1, max(0, $0.isFinite ? $0 : 0)) }
        self.servedTurnsAgo = servedTurnsAgo
        self.precoveredSourceIDs = precoveredSourceIDs
        self.mandatoryAtomIDs = mandatoryAtomIDs
        self.deletedAtomIDs = deletedAtomIDs
        self.tombstonedAtomIDs = tombstonedAtomIDs
        self.staleRuntimeAtomIDs = staleRuntimeAtomIDs
        self.secretBearingAtomIDs = secretBearingAtomIDs
        self.queryEmbedding = queryEmbedding
        self.alternateQueryEmbedding = queryEmbedding == nil ? nil : alternateQueryEmbedding
        self.ownWordsQueryEmbeddings = queryEmbedding == nil || (ownWordsQueryEmbeddings ?? []).isEmpty
            ? nil : ownWordsQueryEmbeddings
        let embeddingFingerprint = queryEmbeddingModelFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.queryEmbeddingModelFingerprint = queryEmbedding == nil
            ? nil
            : ((embeddingFingerprint?.isEmpty == false) ? embeddingFingerprint : nil)
        self.queryEmbeddingModelID = queryEmbedding == nil ? nil : queryEmbeddingModelID
        self.availableGenerationID = availableGenerationID
        self.characterBudget = max(0, characterBudget)
        self.mandatoryCharacterBudget = max(0, mandatoryCharacterBudget ?? characterBudget)
        self.packetAtomExpandThresholdChars = max(0, packetAtomExpandThresholdChars)
        self.memoryAtomRowLimit = memoryAtomRowLimit.map { max(0, $0) }
        self.selectionTimeBucket = Int64(floor(now.timeIntervalSince1970 / Double(bucketSize)))
        self.timeBucketSeconds = bucketSize
        self.explicitConflicts = explicitConflicts
        self.cacheState = cacheState
        self.measuredSelectionMicroseconds = measuredSelectionMicroseconds
    }
    public var evaluationTime: Date {
        // Evaluate at the end of the bucket so expiry fails closed within it.
        Date(timeIntervalSince1970: (Double(selectionTimeBucket) + 1) * Double(timeBucketSeconds))
    }
    public var deterministicFingerprint: String {
        let entityParts = extractedEntities
            .map { "\($0.kind.lowercased()):\($0.id.lowercased()):\($0.label.lowercased())" }
            .sorted()
        var parts = [
            message,
            surface.rawValue,
            origin.rawValue,
            sessionID ?? "",
            currentProjectID ?? "",
            executionID ?? "",
            activeTask ?? "",
            unresolvedQuestion ?? "",
            goal ?? "",
            String(selectionTimeBucket),
            String(timeBucketSeconds),
            String(characterBudget),
            String(mandatoryCharacterBudget),
            String(packetAtomExpandThresholdChars),
            memoryAtomRowLimit.map(String.init) ?? "no-memory-atom-row-limit",
            String(availableGenerationID ?? -1),
            cacheState.rawValue,
        ]
        parts += entityParts
        parts += recentTurns
        parts += contextualTerms.sorted()
        parts += predictedToolGroups.sorted()
        parts += authorization.allowedOrigins.map(\.rawValue).sorted()
        parts += authorization.allowedPrivacy.map(\.rawValue).sorted()
        parts += authorization.allowedSourceIDs.map(\.rawValue).sorted()
        parts += authorization.allowedAtomIDs?.map(\.rawValue).sorted() ?? ["all-authorized-atoms"]
        parts += authorization.permissionLabels.sorted()
        parts += mandatoryAtomIDs.map(\.rawValue).sorted()
        parts += deletedAtomIDs.map(\.rawValue).sorted()
        parts += tombstonedAtomIDs.map(\.rawValue).sorted()
        parts += staleRuntimeAtomIDs.map(\.rawValue).sorted()
        parts += secretBearingAtomIDs.map(\.rawValue).sorted()
        parts += memoryReachability.map { "reachability:\($0.key.rawValue):\($0.value.bitPattern)" }.sorted()
        parts += servedTurnsAgo.map { "served:\($0.key.rawValue):\($0.value)" }.sorted()
        parts += precoveredSourceIDs.map(\.rawValue).sorted()
        parts += cognitiveActivation.map { atomID, value in
            "\(atomID.rawValue):\(value.bitPattern)"
        }.sorted()
        parts += feedbackUtilityOverrides.map { atomID, value in
            "feedback-utility:\(atomID.rawValue):\(value.bitPattern)"
        }.sorted()
        parts += feedbackDecayOverrides.map { atomID, value in
            "feedback-decay:\(atomID.rawValue):\(value.bitPattern)"
        }.sorted()
        parts += queryEmbedding?.map { String($0.bitPattern) } ?? ["no-query-embedding"]
        parts += alternateQueryEmbedding?.map { String($0.bitPattern) }
            ?? ["no-alternate-query-embedding"]
        for (index, reading) in (ownWordsQueryEmbeddings ?? []).enumerated() {
            parts.append("own-words-reading:\(index)")
            parts += reading.map { String($0.bitPattern) }
        }
        parts.append(queryEmbeddingModelFingerprint ?? "no-query-embedding-fingerprint")
        for conflict in explicitConflicts.sorted(by: { $0.id < $1.id }) {
            parts.append(conflict.id)
            parts.append(contentsOf: conflict.memberAtomIDs.map(\.rawValue).sorted())
            parts.append(conflict.resolvedAtomID?.rawValue ?? "unresolved")
            parts.append(conflict.provenance)
        }
        return ContextStableID.digest(parts: parts)
    }
}
