import Foundation
import NativeAgentCore

// MARK: - Need signal and authorization

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
    public let workingAtomIDs: Set<ContextAtomID>
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
    public let queryEmbeddingModelFingerprint: String?
    /// The embedder's model id; picks the semantic floor
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
        case workingAtomIDs, precoveredSourceIDs, mandatoryAtomIDs, deletedAtomIDs, tombstonedAtomIDs
        case staleRuntimeAtomIDs, secretBearingAtomIDs, queryEmbedding, alternateQueryEmbedding
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
        workingAtomIDs: Set<ContextAtomID> = [],
        precoveredSourceIDs: Set<ContextSourceID> = [],
        mandatoryAtomIDs: Set<ContextAtomID> = [],
        deletedAtomIDs: Set<ContextAtomID> = [],
        tombstonedAtomIDs: Set<ContextAtomID> = [],
        staleRuntimeAtomIDs: Set<ContextAtomID> = [],
        secretBearingAtomIDs: Set<ContextAtomID> = [],
        queryEmbedding: [Float]? = nil,
        alternateQueryEmbedding: [Float]? = nil,
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
        self.workingAtomIDs = workingAtomIDs
        self.precoveredSourceIDs = precoveredSourceIDs
        self.mandatoryAtomIDs = mandatoryAtomIDs
        self.deletedAtomIDs = deletedAtomIDs
        self.tombstonedAtomIDs = tombstonedAtomIDs
        self.staleRuntimeAtomIDs = staleRuntimeAtomIDs
        self.secretBearingAtomIDs = secretBearingAtomIDs
        self.queryEmbedding = queryEmbedding
        self.alternateQueryEmbedding = queryEmbedding == nil ? nil : alternateQueryEmbedding
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
        Date(timeIntervalSince1970: Double(selectionTimeBucket + 1) * Double(timeBucketSeconds))
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
        parts += workingAtomIDs.map(\.rawValue).sorted()
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

// MARK: - Selection output contracts

public enum ContextEligibilityReason: String, Codable, Sendable {
    case missingSource = "missing_source"
    case generationMismatch = "generation_mismatch"
    case deleted
    case tombstoned
    case sourceRemoved = "source_removed"
    case originDenied = "origin_denied"
    case permissionDenied = "permission_denied"
    case surfaceDenied = "surface_denied"
    case privacyDenied = "privacy_denied"
    case neverInject = "never_inject"
    case outsideContextScope = "outside_context_scope"
    case expired
    case staleRuntime = "stale_runtime"
    case secretBearing = "secret_bearing"
    case supersededByConflictResolution = "superseded_by_conflict_resolution"
}

public struct ContextEligibilityDecision: Codable, Equatable, Sendable {
    public let atomID: ContextAtomID
    public let eligible: Bool
    public let exclusionReason: ContextEligibilityReason?

    public init(
        atomID: ContextAtomID,
        eligible: Bool,
        exclusionReason: ContextEligibilityReason? = nil
    ) {
        self.atomID = atomID
        self.eligible = eligible
        self.exclusionReason = exclusionReason
    }
}

public struct ContextCandidateScoreFeatures: Codable, Equatable, Sendable {
    public let lexicalExact: Double
    public let tokenOverlap: Double
    public let semanticCosine: Double
    public let sharedIdentifiers: Double
    public let activation: Double
    public let authority: Double
    public let confidence: Double
    public let recency: Double
    public let usefulness: Double
    public let decay: Double
    /// Share of the CURRENT message's tokens the atom covers (0…1). Added
    /// 2026-08-13 (selection-score-rebalance); absent in receipts persisted
    /// before then, so decoding tolerates a missing key as 0.
    public let messageCoverage: Double
    public let diversityBonus: Double
    public let redundancyPenalty: Double
    public let conflictPenalty: Double
    public let characterCostPenalty: Double
    public let total: Double

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lexicalExact = try c.decode(Double.self, forKey: .lexicalExact)
        tokenOverlap = try c.decode(Double.self, forKey: .tokenOverlap)
        semanticCosine = try c.decode(Double.self, forKey: .semanticCosine)
        sharedIdentifiers = try c.decode(Double.self, forKey: .sharedIdentifiers)
        activation = try c.decode(Double.self, forKey: .activation)
        authority = try c.decode(Double.self, forKey: .authority)
        confidence = try c.decode(Double.self, forKey: .confidence)
        recency = try c.decode(Double.self, forKey: .recency)
        usefulness = try c.decode(Double.self, forKey: .usefulness)
        decay = try c.decode(Double.self, forKey: .decay)
        messageCoverage = try c.decodeIfPresent(Double.self, forKey: .messageCoverage) ?? 0
        diversityBonus = try c.decode(Double.self, forKey: .diversityBonus)
        redundancyPenalty = try c.decode(Double.self, forKey: .redundancyPenalty)
        conflictPenalty = try c.decode(Double.self, forKey: .conflictPenalty)
        characterCostPenalty = try c.decode(Double.self, forKey: .characterCostPenalty)
        total = try c.decode(Double.self, forKey: .total)
    }

    init(
        lexicalExact: Double,
        tokenOverlap: Double,
        semanticCosine: Double,
        sharedIdentifiers: Double,
        activation: Double,
        authority: Double,
        confidence: Double,
        recency: Double,
        usefulness: Double,
        decay: Double,
        messageCoverage: Double,
        diversityBonus: Double,
        redundancyPenalty: Double,
        conflictPenalty: Double,
        characterCostPenalty: Double,
        total: Double
    ) {
        self.lexicalExact = lexicalExact
        self.tokenOverlap = tokenOverlap
        self.semanticCosine = semanticCosine
        self.sharedIdentifiers = sharedIdentifiers
        self.activation = activation
        self.authority = authority
        self.confidence = confidence
        self.recency = recency
        self.usefulness = usefulness
        self.decay = decay
        self.messageCoverage = messageCoverage
        self.diversityBonus = diversityBonus
        self.redundancyPenalty = redundancyPenalty
        self.conflictPenalty = conflictPenalty
        self.characterCostPenalty = characterCostPenalty
        self.total = total
    }

    func reranked(
        diversityBonus: Double,
        redundancyPenalty: Double,
        total: Double
    ) -> Self {
        Self(
            lexicalExact: lexicalExact,
            tokenOverlap: tokenOverlap,
            semanticCosine: semanticCosine,
            sharedIdentifiers: sharedIdentifiers,
            activation: activation,
            authority: authority,
            confidence: confidence,
            recency: recency,
            usefulness: usefulness,
            decay: decay,
            messageCoverage: messageCoverage,
            diversityBonus: diversityBonus,
            redundancyPenalty: redundancyPenalty,
            conflictPenalty: conflictPenalty,
            characterCostPenalty: characterCostPenalty,
            total: total
        )
    }
}

public struct ContextCandidateScore: Codable, Equatable, Sendable {
    public let atomID: ContextAtomID
    public let features: ContextCandidateScoreFeatures
    public let selectionOrdinal: Int?

    public init(
        atomID: ContextAtomID,
        features: ContextCandidateScoreFeatures,
        selectionOrdinal: Int? = nil
    ) {
        self.atomID = atomID
        self.features = features
        self.selectionOrdinal = selectionOrdinal
    }
}

public struct ContextAtomPointer: Codable, Equatable, Sendable {
    public let atomID: ContextAtomID
    public let sourceID: ContextSourceID
    public let sourceHash: String
    public let generationID: Int64
    public let kind: ContextAtomKind
    public let headingPath: [String]
    public let sourceRange: ContextSourceRange

    public init(atom: ContextStoredAtom, generationID: Int64) {
        atomID = atom.draft.id
        sourceID = atom.draft.sourceID
        sourceHash = atom.draft.sourceHash
        self.generationID = generationID
        kind = atom.draft.kind
        headingPath = atom.draft.headingPath
        sourceRange = atom.draft.sourceRange
    }
}

public enum ContextPacketRepresentation: String, Codable, Sendable {
    case body
    case deterministicSummary = "deterministic_summary"
}

public struct ContextPacketItem: Codable, Equatable, Sendable {
    public let pointer: ContextAtomPointer
    public let text: String
    public let representation: ContextPacketRepresentation
    public let mandatory: Bool
    public let characterCount: Int
    /// The atom's `deterministicSummary` (the `summary` column of
    /// `context_atom_versions`), carried alongside the body so a renderer can
    /// lead with the RULE and leave the story behind a pointer without a second
    /// store read. Nil when the compiler produced no summary for this atom.
    /// Empty/whitespace summaries are normalized to nil here so every reader
    /// gets one answer to "is there a lead".
    public let summary: String?
    /// When the memory this atom carries was recorded, so the renderer can lead
    /// with its age instead of handing every memory over as equally present.
    /// Memory atoms only; nil everywhere else and on legacy packets.
    public let recordedAt: Date?
    /// How the memory came to be known (`verified` / `told by X` / `inferred`),
    /// when the record says. nil on rows written before provenance existed.
    public let provenance: ContextMemoryProvenance?
    /// Untrusted sources of the selected text, retained from its exact atom.
    public let untrustedSources: [String]?

    public init(
        pointer: ContextAtomPointer,
        text: String,
        representation: ContextPacketRepresentation,
        mandatory: Bool,
        summary: String? = nil,
        recordedAt: Date? = nil,
        provenance: ContextMemoryProvenance? = nil,
        untrustedSources: [String]? = nil
    ) {
        self.pointer = pointer
        self.text = text
        self.representation = representation
        self.mandatory = mandatory
        self.characterCount = text.count
        let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.summary = (trimmedSummary?.isEmpty == false) ? trimmedSummary : nil
        self.recordedAt = recordedAt
        self.provenance = provenance
        self.untrustedSources = untrustedSources
    }

    /// The item as built from the atom it came from: identical to the
    /// designated init, plus the memory facts the renderer needs and only the
    /// atom knows (its recorded time and provenance).
    public init(
        atom: ContextStoredAtom,
        generationID: Int64,
        text: String,
        representation: ContextPacketRepresentation,
        mandatory: Bool
    ) {
        self.init(
            pointer: ContextAtomPointer(atom: atom, generationID: generationID),
            text: text,
            representation: representation,
            mandatory: mandatory,
            summary: atom.draft.deterministicSummary,
            recordedAt: ContextMemoryLead.recordedAt(for: atom.draft),
            provenance: ContextMemoryLead.provenance(for: atom.draft),
            untrustedSources: ContextMemoryLead.untrustedSources(for: atom.draft)
        )
    }
}

public enum ContextConflictHandling: String, Codable, Sendable {
    case resolved
    case includedUncertainty = "included_uncertainty"
    case omittedIrrelevant = "omitted_irrelevant"
    case omittedBudget = "omitted_budget"
    case ineligible
}

public struct ContextConflictSet: Codable, Equatable, Sendable {
    public let id: String
    public let claims: [ContextAtomPointer]
    public let resolvedAtomID: ContextAtomID?
    public let provenance: [String]
    public let handling: ContextConflictHandling

    public init(
        id: String,
        claims: [ContextAtomPointer],
        resolvedAtomID: ContextAtomID?,
        provenance: [String],
        handling: ContextConflictHandling
    ) {
        self.id = id
        self.claims = claims
        self.resolvedAtomID = resolvedAtomID
        self.provenance = provenance
        self.handling = handling
    }
}

public struct ContextDegradedSourceNotice: Codable, Equatable, Sendable {
    public let sourceID: ContextSourceID
    public let reason: String

    public init(sourceID: ContextSourceID, reason: String) {
        self.sourceID = sourceID
        self.reason = reason
    }
}

public struct ContextBudgetUsage: Codable, Equatable, Sendable {
    public let characterLimit: Int
    public let usedCharacters: Int
    public let mandatoryCharacters: Int

    public var remainingCharacters: Int { max(0, characterLimit - usedCharacters) }
}

/// Generation-pinned lexical material compiled once for the RAM hot path.
/// The canonical atom remains authoritative; this is rebuildable derived state.
public struct ContextSelectionIndexEntry: Equatable, Sendable {
    public let bodyTokens: Set<String>
    public let searchableTokens: Set<String>
    public let normalizedSearchableText: String
    public let logicalByteCount: Int

    public init(atom: ContextAtomDraft) {
        let metadata = [atom.deterministicSummary].compactMap { $0 }
            + atom.headingPath
            + atom.triggers
            + atom.entities.flatMap { [$0.id, $0.label] }
        let searchableText = ([atom.body] + metadata).joined(separator: " ")
        let bodyTokens = ContextLexicalTokenizer.tokens(atom.body)
        var searchableTokens = bodyTokens
        searchableTokens.formUnion(ContextLexicalTokenizer.tokens(metadata.joined(separator: " ")))
        let normalizedSearchableText = searchableText.lowercased()
        self.bodyTokens = bodyTokens
        self.searchableTokens = searchableTokens
        self.normalizedSearchableText = normalizedSearchableText
        self.logicalByteCount = 64
            + normalizedSearchableText.utf8.count
            + bodyTokens.reduce(0) { $0 + 24 + $1.utf8.count }
            + searchableTokens.subtracting(bodyTokens).reduce(0) { $0 + 24 + $1.utf8.count }
    }
}

/// Where the selection latency value came from. Only a monotonic-clock value
/// taken around the selector is an operational live-latency sample; injected
/// values remain useful for deterministic fixtures but must never be mixed into
/// a production latency window.
public enum ContextSelectionLatencyProvenance: String, Codable, Equatable, Sendable {
    case monotonicClock = "monotonic_clock"
    case callerSupplied = "caller_supplied"
    case unavailable
    case invalidCallerSupplied = "invalid_caller_supplied"
}

public struct ContextSelectionReceipt: Codable, Equatable, Sendable {
    public let id: String
    public let needFingerprint: String
    public let generationID: Int64
    public let sourceFingerprint: String
    public let selectionTimeBucket: Int64
    public let eligibility: [ContextEligibilityDecision]
    public let candidateScores: [ContextCandidateScore]
    public let selectedAtomIDs: [ContextAtomID]
    public let pointerAtomIDs: [ContextAtomID]
    public let mandatoryAtomIDs: [ContextAtomID]
    public let coveredMandatoryAtomIDs: [ContextAtomID]
    public let mandatoryCoverage: Double
    public let conflicts: [ContextConflictSet]
    public let budget: ContextBudgetUsage
    public let degradedSources: [ContextDegradedSourceNotice]
    public let cacheState: ContextSelectionCacheState
    public let measuredSelectionMicroseconds: Int?
    /// Optional for wire compatibility with receipts persisted before latency
    /// provenance existed. Readers must treat nil as unavailable, never zero.
    public let selectionLatencyProvenance: ContextSelectionLatencyProvenance?
    /// How many ranked `.memory` candidates the semantic floor refused this
    /// turn (`configuration.memorySemanticFloors`). Absent in receipts persisted
    /// before 2026-09-02, so decoding tolerates a missing key as 0 — the same
    /// contract `messageCoverage` got.
    public let memoryFloorDroppedCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, needFingerprint, generationID, sourceFingerprint, selectionTimeBucket
        case eligibility, candidateScores, selectedAtomIDs, pointerAtomIDs
        case mandatoryAtomIDs, coveredMandatoryAtomIDs, mandatoryCoverage
        case conflicts, budget, degradedSources, cacheState
        case measuredSelectionMicroseconds, selectionLatencyProvenance
        case memoryFloorDroppedCount
    }

    public init(
        id: String,
        needFingerprint: String,
        generationID: Int64,
        sourceFingerprint: String,
        selectionTimeBucket: Int64,
        eligibility: [ContextEligibilityDecision],
        candidateScores: [ContextCandidateScore],
        selectedAtomIDs: [ContextAtomID],
        pointerAtomIDs: [ContextAtomID],
        mandatoryAtomIDs: [ContextAtomID],
        coveredMandatoryAtomIDs: [ContextAtomID],
        mandatoryCoverage: Double,
        conflicts: [ContextConflictSet],
        budget: ContextBudgetUsage,
        degradedSources: [ContextDegradedSourceNotice],
        cacheState: ContextSelectionCacheState,
        measuredSelectionMicroseconds: Int?,
        selectionLatencyProvenance: ContextSelectionLatencyProvenance? = nil,
        memoryFloorDroppedCount: Int = 0
    ) {
        self.id = id
        self.needFingerprint = needFingerprint
        self.generationID = generationID
        self.sourceFingerprint = sourceFingerprint
        self.selectionTimeBucket = selectionTimeBucket
        self.eligibility = eligibility
        self.candidateScores = candidateScores
        self.selectedAtomIDs = selectedAtomIDs
        self.pointerAtomIDs = pointerAtomIDs
        self.mandatoryAtomIDs = mandatoryAtomIDs
        self.coveredMandatoryAtomIDs = coveredMandatoryAtomIDs
        self.mandatoryCoverage = mandatoryCoverage
        self.conflicts = conflicts
        self.budget = budget
        self.degradedSources = degradedSources
        self.cacheState = cacheState
        self.measuredSelectionMicroseconds = measuredSelectionMicroseconds
        self.selectionLatencyProvenance = selectionLatencyProvenance
        self.memoryFloorDroppedCount = memoryFloorDroppedCount
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            needFingerprint: try values.decode(String.self, forKey: .needFingerprint),
            generationID: try values.decode(Int64.self, forKey: .generationID),
            sourceFingerprint: try values.decode(String.self, forKey: .sourceFingerprint),
            selectionTimeBucket: try values.decode(Int64.self, forKey: .selectionTimeBucket),
            eligibility: try values.decode([ContextEligibilityDecision].self, forKey: .eligibility),
            candidateScores: try values.decode([ContextCandidateScore].self, forKey: .candidateScores),
            selectedAtomIDs: try values.decode([ContextAtomID].self, forKey: .selectedAtomIDs),
            pointerAtomIDs: try values.decode([ContextAtomID].self, forKey: .pointerAtomIDs),
            mandatoryAtomIDs: try values.decode([ContextAtomID].self, forKey: .mandatoryAtomIDs),
            coveredMandatoryAtomIDs: try values.decode([ContextAtomID].self, forKey: .coveredMandatoryAtomIDs),
            mandatoryCoverage: try values.decode(Double.self, forKey: .mandatoryCoverage),
            conflicts: try values.decode([ContextConflictSet].self, forKey: .conflicts),
            budget: try values.decode(ContextBudgetUsage.self, forKey: .budget),
            degradedSources: try values.decode([ContextDegradedSourceNotice].self, forKey: .degradedSources),
            cacheState: try values.decode(ContextSelectionCacheState.self, forKey: .cacheState),
            measuredSelectionMicroseconds: try values.decodeIfPresent(Int.self, forKey: .measuredSelectionMicroseconds),
            selectionLatencyProvenance: try values.decodeIfPresent(
                ContextSelectionLatencyProvenance.self,
                forKey: .selectionLatencyProvenance
            ),
            memoryFloorDroppedCount: try values.decodeIfPresent(
                Int.self,
                forKey: .memoryFloorDroppedCount
            ) ?? 0
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(needFingerprint, forKey: .needFingerprint)
        try values.encode(generationID, forKey: .generationID)
        try values.encode(sourceFingerprint, forKey: .sourceFingerprint)
        try values.encode(selectionTimeBucket, forKey: .selectionTimeBucket)
        try values.encode(eligibility, forKey: .eligibility)
        try values.encode(candidateScores, forKey: .candidateScores)
        try values.encode(selectedAtomIDs, forKey: .selectedAtomIDs)
        try values.encode(pointerAtomIDs, forKey: .pointerAtomIDs)
        try values.encode(mandatoryAtomIDs, forKey: .mandatoryAtomIDs)
        try values.encode(coveredMandatoryAtomIDs, forKey: .coveredMandatoryAtomIDs)
        try values.encode(mandatoryCoverage, forKey: .mandatoryCoverage)
        try values.encode(conflicts, forKey: .conflicts)
        try values.encode(budget, forKey: .budget)
        try values.encode(degradedSources, forKey: .degradedSources)
        try values.encode(cacheState, forKey: .cacheState)
        try values.encodeIfPresent(measuredSelectionMicroseconds, forKey: .measuredSelectionMicroseconds)
        try values.encodeIfPresent(selectionLatencyProvenance, forKey: .selectionLatencyProvenance)
        // Written only when the floor actually refused something, so a receipt
        // from a turn it never touched stays byte-identical to a pre-floor one.
        if memoryFloorDroppedCount != 0 {
            try values.encode(memoryFloorDroppedCount, forKey: .memoryFloorDroppedCount)
        }
    }
}

public struct ContextPacket: Codable, Equatable, Sendable {
    public let generationID: Int64
    public let sourceFingerprint: String
    public let selectedItems: [ContextPacketItem]
    public let expandablePointers: [ContextAtomPointer]
    public let conflictSets: [ContextConflictSet]
    public let degradedSources: [ContextDegradedSourceNotice]
    public let budget: ContextBudgetUsage
    public let receipt: ContextSelectionReceipt

    public var characterCount: Int { budget.usedCharacters }
}

public enum ContextSelectionError: Error, Equatable, Sendable {
    case invalidCharacterBudget
    case requestedGenerationMismatch(requested: Int64, actual: Int64)
    case snapshotGenerationMismatch(snapshot: Int64, generation: Int64)
    case snapshotFingerprintMismatch
    case invalidConflictResolution(conflictID: String, atomID: ContextAtomID)
    case mandatoryUnavailable([ContextAtomID])
    case mandatoryBudgetExceeded(required: Int, limit: Int)
}

/// Shipped ranking weights have one owner.
public struct ContextScoreWeights: Equatable, Sendable {
    public let lexicalExact: Double = 2.4
    public let tokenOverlap: Double = 1.7
    public let semanticCosine: Double = 1.2
    public let sharedIdentifiers: Double = 1.5
    public let activation: Double = 1.2
    public let authority: Double = 1.0
    public let confidence: Double = 0.8
    public let recency: Double = 0.5
    public let usefulness: Double = 0.7
    public let decay: Double = 0.5
    public let redundancyPenalty: Double = 1.1
    public let characterCostPenaltyCap: Double = 0.35
    /// Weight for the `messageCoverage` feature: how much of the CURRENT user
    /// message's token set the atom covers. Default 1.5 — shipped 2026-08-13
    /// from the offline A/B in docs/build_plans/selection-score-rebalance.md
    /// (60 real queries, live store gen 1962: mean pairwise Jaccard of dynamic
    /// selections 0.324 → 0.242 vs weight 0, top-pick coverage 0.151 → 0.296,
    /// mandatory sets identical, dynamic count unchanged). 2.5 scored
    /// marginally better lexically but was rejected: measured WITHOUT the
    /// semantic feature, it risks drowning semantics on production turns.
    /// 0 disables the feature (score() still computes it for receipts).
    public let messageCoverage: Double = 1.5
    /// Rank penalty applied while an atom's conflict group is unresolved.
    public let conflictPenalty: Double = 0.12
    /// Rerank bonus for the first atom from a not-yet-selected source.
    public let diversityNewSourceBonus: Double = 0.14
    /// Rerank bonus for the first atom of a not-yet-selected kind.
    public let diversityNewKindBonus: Double = 0.10

    public init() {}
}

public struct ContextSelectionConfiguration: Equatable, Sendable {
    public let maximumCandidates: Int = 256
    public let maximumDynamicAtoms: Int = 12
    public let maximumAtomsPerSource: Int = 2
    public let maximumAtomsPerKind: Int = 4
    /// Kind-specific overrides of `maximumAtomsPerKind`. Memory atoms get a
    /// larger quota by default so high-scoring memories are not crowded out
    /// of the 12-atom dynamic budget by the uniform per-kind cap.
    public let maximumAtomsPerKindOverrides: [ContextAtomKind: Int] = [.memory: 8, .relationship: 4]
    public let minimumRelevance: Double = 0.05
    /// Per embedding model (`model_id`): cosine below which a `.memory` or
    /// `.correction` atom is refused ADMISSION to the packet, however well it
    /// ranked on everything else. `0` turns off the whole 2026-09-02 precision
    /// pass — this floor AND `shortMessageMemoryRowCap` — and restores the
    /// pre-floor selector byte-for-byte, receipts included. Cosines are not
    /// comparable across models, so one number cannot serve two of them: a
    /// model with no entry admits no memory by meaning alone, only by the
    /// exemptions below (explicit lexical match, shared identifier, working
    /// set) and pins, and the coordinator logs the model once.
    ///
    /// The measured problem (live chat, 2026-09-01): on a short warm message
    /// the best memory hit scored cosine 0.41 and the selector still filled the whole 12-row memory
    /// quota down to 0.24 — 18 lead+pointer rows of noise riding a turn that
    /// asked for none of it. Targeted queries rank fine, so this is a PRECISION
    /// problem on small talk, and a rank threshold is the honest instrument.
    ///
    /// It is deliberately narrow:
    ///   - `.memory` and `.correction` atoms only (corrections since
    ///     2026-09-26: ambient ones rode nearly every turn). Identity,
    ///     instruction, relationship and mandatory atoms are authority, not
    ///     recall breadth; a scoped correction the message triggers is
    ///     mandatory and never reaches the floor.
    ///   - It never fires when the query has no embedding (cold embedder): with
    ///     nothing to compare, every cosine is 0 and the floor would delete the
    ///     memory lane instead of trimming it.
    ///   - It never fires on an atom that has no comparable embedding (absent,
    ///     or a different model epoch). That atom's 0 means "unknown", not
    ///     "irrelevant"; `semanticScoreFailsClosedWhenQueryAndAtomEmbeddingEpochs
    ///     Differ` is the same distinction one layer down.
    ///   - Four exemptions carry an atom over the floor regardless of cosine:
    ///     a whole-message lexical hit, a shared identifier, message coverage
    ///     >= 0.5, or the atom being in the turn's working set. Not
    ///     `activation`: it carries the record's own importance (0.5-0.95 on
    ///     half the store), which exempted those rows on every turn.
    ///
    /// Both values are from one replay (10-10: 987 turns of 10-03…10-10 with
    /// their query text, every memory atom of the live generation embedded by
    /// each model), set where a topical turn keeps its one relevant row.
    /// bge-large 0.55: its median query-to-memory cosine is 0.52, so the
    /// MiniLM-era 0.30 never fired; at 0.55 a turn carries 8.0 memory rows
    /// instead of 11.6 (5.3 instead of 10.7 on User's own turns, 18% of them
    /// none), a timezone question keeps its one relevant row (0.58), an
    /// unrelated design rule on a strategy question (0.54) stays out, and the
    /// recalls the 10-09 drive checked (0.75-0.81, rank 1) land. 0.60 also cut
    /// the topical row. MiniLM 0.25, the matching mark: 7.7 rows instead of
    /// 10.2 (4.9 on User's turns, 20% none), acknowledgements (0.19-0.22) and
    /// the unrelated design and greeting rules (0.07, 0.22) stay out, drive
    /// recalls 0.64-0.80 land (and 0.34 carried by message coverage).
    public let memorySemanticFloors: [String: Double] = ["bge-large-en-v1.5": 0.55, "all-MiniLM-L6-v2": 0.25]
    /// Effective `.memory` row cap on a message of at most
    /// `shortMessageTokenCount` content tokens — the same token set (and the
    /// same "4") the `messageCoverage` length damp already uses, so a message
    /// too short to evidence coverage is also too short to earn a full memory
    /// lane. Applied as `min(cap, shortMessageMemoryRowCap)`. `0` disables the
    /// cap on its own, and a zero semantic floor disables it too.
    public let shortMessageMemoryRowCap: Int = 6
    /// Phase 5 C3: `.personal` atoms leave the ordinary competition and get
    /// their own lane — the ONE with the highest lift (cosine minus the
    /// memory's own baseline, `ContextSelector.personalBaselines`) at or above
    /// this floor, or none. It takes one of the memory rows, never an extra
    /// one. `0` turns the lane off: personal atoms compete like any memory.
    ///
    /// 0.20 is from the replay (204 of User's turns, 09-24…10-03, bge-large):
    /// one personal memory on 11% of turns, 15 distinct (the old lane put 1-3
    /// on 47%). Raw cosine at any floor kept answering every turn that
    /// mentioned Claude with the same memory.
    public let personalRecallFloor: Double = 0.20
    public let weights: ContextScoreWeights = ContextScoreWeights()

    /// Content-token count at or below which a message counts as short.
    public static let shortMessageTokenCount = 4

    public init() {}

    /// The semantic floor for vectors from `modelID`; nil for a model with no
    /// entry, which no cosine clears.
    public func memorySemanticFloor(forModel modelID: String?) -> Double? {
        modelID.flatMap { memorySemanticFloors[$0] }
    }

    /// Effective per-kind cap: the override for `kind` when present, else the
    /// uniform `maximumAtomsPerKind`.
    public func maximumAtoms(forKind kind: ContextAtomKind) -> Int {
        maximumAtomsPerKindOverrides[kind] ?? maximumAtomsPerKind
    }
}
