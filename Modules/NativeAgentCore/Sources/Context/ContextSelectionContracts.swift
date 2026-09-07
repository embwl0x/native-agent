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
    public let availableGenerationID: Int64?
    public let characterBudget: Int
    public let mandatoryCharacterBudget: Int
    /// Body length above which the CALLER's packet renderer replaces an atom's
    /// full text with a lead + `context_expand` pointer. The selector uses it
    /// only to publish a matching expandable pointer, and `ContextExpander`
    /// uses it to admit that pointer. `0` = the caller renders atoms whole.
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
        case queryEmbeddingModelFingerprint, availableGenerationID
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

    public init(
        pointer: ContextAtomPointer,
        text: String,
        representation: ContextPacketRepresentation,
        mandatory: Bool,
        summary: String? = nil,
        recordedAt: Date? = nil,
        provenance: ContextMemoryProvenance? = nil
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
            provenance: ContextMemoryLead.provenance(for: atom.draft)
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
    /// turn (`configuration.memorySemanticFloor`). Absent in receipts persisted
    /// before 2026-09-02, so decoding tolerates a missing key as 0 — the same
    /// contract `messageCoverage` got.
    public let memoryFloorDroppedCount: Int
    /// Correction atoms this turn's per-turn correction cap kept OUT of the
    /// packet. Zero on receipts written before the cap existed, which is the
    /// truth for those turns: nothing was dropped by a rule that did not run.
    public let correctionCapDropped: Int

    private enum CodingKeys: String, CodingKey {
        case id, needFingerprint, generationID, sourceFingerprint, selectionTimeBucket
        case eligibility, candidateScores, selectedAtomIDs, pointerAtomIDs
        case mandatoryAtomIDs, coveredMandatoryAtomIDs, mandatoryCoverage
        case conflicts, budget, degradedSources, cacheState
        case measuredSelectionMicroseconds, selectionLatencyProvenance
        case memoryFloorDroppedCount
        case correctionCapDropped
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
        memoryFloorDroppedCount: Int = 0,
        correctionCapDropped: Int = 0
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
        self.correctionCapDropped = max(0, correctionCapDropped)
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
            ) ?? 0,
            correctionCapDropped: try values.decodeIfPresent(Int.self, forKey: .correctionCapDropped) ?? 0
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
        if correctionCapDropped != 0 {
            try values.encode(correctionCapDropped, forKey: .correctionCapDropped)
        }
    }
}

/// Interprets the durable `context_receipts(kind: selection)` fields without
/// turning missing, replay-supplied, or malformed values into a calm zero.
/// This is deliberately a receipt reader, not a speed gate: callers may build
/// envelope reports from `.measured` samples without asserting a wall-clock
/// budget in ordinary functional tests.
public struct ContextSelectionLatencyObservation: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case measured
        case missing
        case invalid
    }

    public let status: Status
    public let microseconds: Int?
    public let provenance: ContextSelectionLatencyProvenance?
    public let surface: ContextSurface?

    public init(receipt: ContextStoreReceipt) {
        guard receipt.kind == .selection else {
            status = .invalid
            microseconds = nil
            provenance = nil
            surface = nil
            return
        }
        surface = receipt.details["surface"].flatMap(ContextSurface.init(rawValue:))
        let rawProvenance = receipt.details["selection_latency_provenance"]
        let provenance = rawProvenance.flatMap(ContextSelectionLatencyProvenance.init(rawValue:))
        self.provenance = provenance
        guard surface != nil else {
            status = .invalid
            microseconds = nil
            return
        }
        guard let rawMicroseconds = receipt.details["selection_microseconds"],
              rawMicroseconds != "absent",
              let parsed = Int(rawMicroseconds),
              parsed >= 0 else {
            status = rawProvenance == nil || provenance == .unavailable ? .missing : .invalid
            microseconds = nil
            return
        }
        guard provenance == .monotonicClock else {
            status = rawProvenance == nil || provenance == .unavailable ? .missing : .invalid
            microseconds = nil
            return
        }
        status = .measured
        microseconds = parsed
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

/// Every ranking weight in one place. Defaults are EXACTLY the literals that
/// lived inline in `score()`/the rerank loop through 2026-08-13, so
/// `ContextScoreWeights()` is byte-identical to the pre-seam selector — pinned
/// by `defaultScoreWeightsMatchTheHistoricalLiterals`. The seam exists for the
/// selection-score-rebalance A/B (docs/build_plans/selection-score-rebalance.md):
/// tuning happens by SHIPPING new defaults after the offline eval, never by
/// per-call-site overrides scattered through production code.
public struct ContextScoreWeights: Equatable, Sendable {
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
    public let redundancyPenalty: Double
    public let characterCostPenaltyCap: Double
    /// Weight for the `messageCoverage` feature: how much of the CURRENT user
    /// message's token set the atom covers. Default 1.5 — shipped 2026-08-13
    /// from the offline A/B in docs/build_plans/selection-score-rebalance.md
    /// (60 real queries, live store gen 1962: mean pairwise Jaccard of dynamic
    /// selections 0.324 → 0.242 vs weight 0, top-pick coverage 0.151 → 0.296,
    /// mandatory sets identical, dynamic count unchanged). 2.5 scored
    /// marginally better lexically but was rejected: measured WITHOUT the
    /// semantic feature, it risks drowning semantics on production turns.
    /// 0 disables the feature (score() still computes it for receipts).
    public let messageCoverage: Double
    /// Rank penalty applied while an atom's conflict group is unresolved.
    public let conflictPenalty: Double
    /// Rerank bonus for the first atom from a not-yet-selected source.
    public let diversityNewSourceBonus: Double
    /// Rerank bonus for the first atom of a not-yet-selected kind.
    public let diversityNewKindBonus: Double

    public init(
        lexicalExact: Double = 2.4,
        tokenOverlap: Double = 1.7,
        semanticCosine: Double = 1.2,
        sharedIdentifiers: Double = 1.5,
        activation: Double = 1.2,
        authority: Double = 1.0,
        confidence: Double = 0.8,
        recency: Double = 0.5,
        usefulness: Double = 0.7,
        decay: Double = 0.5,
        redundancyPenalty: Double = 1.1,
        characterCostPenaltyCap: Double = 0.35,
        messageCoverage: Double = 1.5,
        conflictPenalty: Double = 0.12,
        diversityNewSourceBonus: Double = 0.14,
        diversityNewKindBonus: Double = 0.10
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
        self.redundancyPenalty = redundancyPenalty
        self.characterCostPenaltyCap = characterCostPenaltyCap
        self.messageCoverage = messageCoverage
        self.conflictPenalty = conflictPenalty
        self.diversityNewSourceBonus = diversityNewSourceBonus
        self.diversityNewKindBonus = diversityNewKindBonus
    }
}

/// A floor for one content role inside one atom kind's budget.
///
/// Skills-as-recall (2026-07-03) dissolved the skill library into memory
/// pointer rows so craft would arrive the way remembering does. The legacy
/// recall lane honours that by sharing its result budget with skill hints
/// (`MemoryRecallScoring.selectRecallResults`, max(1, k/3)); the ContextFlow
/// lane had no equivalent, so 36 skill pointers competed against 177 other
/// memory atoms inside one 8-slot quota. Live arena generation 3046: the memory
/// quota saturated on 7 of 8 real skill-shaped queries, and the right skill for
/// the message lost on two of them at ranks 32 and 54.
///
/// The reservation has two halves, and needs both:
///   - a CAP on other roles, so the reserved slots stay free; and
///   - a PROMOTION, so a qualifying atom actually takes one — capping alone
///     just hands the freed slot to whatever ranks next.
/// It reallocates the quota and never widens it: the dynamic atom budget,
/// per-source cap and character budget all still apply unchanged. With no
/// qualifying candidate in the turn, selection is byte-identical to having no
/// reservation configured at all.
public struct ContextRoleReservation: Equatable, Sendable {
    public let role: ContextContentRole
    public let slots: Int
    /// Merit gate on the floor. A reserved slot is not a lottery: the atom has
    /// to be about THIS message, not merely above the global relevance floor.
    /// `messageCoverage` is the one score feature that cannot be diluted by
    /// carried context, so it is the honest predicate for "this skill is what
    /// the user just asked about".
    ///
    /// 0.35 is evidenced, not guessed. Live arena generation 3046 (36 skill
    /// pointers among 213 memory atoms, 8 real queries): the correct skill for
    /// a message scored messageCoverage 0.47-0.63 and every off-topic pointer
    /// scored <= 0.19 — a 2.4x gap with nothing inside it. Below the gate the
    /// reservation is inert and selection is byte-identical to having none.
    public let minimumMessageCoverage: Double

    public init(role: ContextContentRole, slots: Int, minimumMessageCoverage: Double = 0.35) {
        self.role = role
        self.slots = max(0, slots)
        self.minimumMessageCoverage = max(0, minimumMessageCoverage)
    }
}

public struct ContextSelectionConfiguration: Equatable, Sendable {
    public let maximumCandidates: Int
    public let maximumDynamicAtoms: Int
    public let maximumPointers: Int
    public let maximumAtomsPerSource: Int
    public let maximumAtomsPerKind: Int
    /// Kind-specific overrides of `maximumAtomsPerKind`. Memory atoms get a
    /// larger quota by default so high-scoring memories are not crowded out
    /// of the 12-atom dynamic budget by the uniform per-kind cap.
    public let maximumAtomsPerKindOverrides: [ContextAtomKind: Int]
    /// Reserved share of a kind's budget for one content role. Keyed by atom
    /// kind; the reservation is clamped at init so a reserve can never claim a
    /// kind's whole quota.
    public let reservedRoleSlotsPerKind: [ContextAtomKind: ContextRoleReservation]
    /// Per-turn ceiling on `.correction` atoms that are NOT about this message.
    ///
    /// Her store is nine-tenths corrections (live 2026-09-01: recall for
    /// "memory" returned twelve correction rows and two facts), so the ordinary
    /// per-kind quota let the packet describe her as mostly someone who got
    /// things wrong. A correction the CURRENT message is actually about is
    /// exempt (see `correctionIsAboutMessage`) and so are mandatory/pinned
    /// corrections, which never reach the dynamic quota at all — this caps the
    /// ambient ones only.
    public let maximumCorrectionAtomsPerTurn: Int
    public let minimumRelevance: Double
    /// Cosine below which a `.memory` atom is refused ADMISSION to the packet,
    /// however well it ranked on everything else. `0` is the kill switch for
    /// the whole 2026-09-02 precision pass — this floor AND
    /// `shortMessageMemoryRowCap` — and restores the pre-floor selector
    /// byte-for-byte, receipts included.
    ///
    /// The measured problem (live chat, 2026-09-01): on the short warm message
    /// "My days bright and fuckin shiny with you in it" the best memory hit
    /// scored cosine 0.41 and the selector still filled the whole 12-row memory
    /// quota down to 0.24 — 18 lead+pointer rows of noise riding a turn that
    /// asked for none of it. Targeted queries rank fine, so this is a PRECISION
    /// problem on small talk, and a rank threshold is the honest instrument.
    ///
    /// It is deliberately narrow:
    ///   - `.memory` atoms only. Identity, correction, instruction, relationship
    ///     and mandatory atoms are authority, not recall breadth.
    ///   - It never fires when the query has no embedding (cold embedder): with
    ///     nothing to compare, every cosine is 0 and the floor would delete the
    ///     memory lane instead of trimming it.
    ///   - It never fires on an atom that has no comparable embedding (absent,
    ///     or a different model epoch). That atom's 0 means "unknown", not
    ///     "irrelevant"; `semanticScoreFailsClosedWhenQueryAndAtomEmbeddingEpochs
    ///     Differ` is the same distinction one layer down.
    ///   - Four exemptions carry an atom over the floor regardless of cosine:
    ///     a whole-message lexical hit, a shared identifier, message coverage
    ///     >= 0.5, or activation >= 0.5 (attention/working set).
    public let memorySemanticFloor: Double
    /// Effective `.memory` row cap on a message of at most
    /// `shortMessageTokenCount` content tokens — the same token set (and the
    /// same "4") the `messageCoverage` length damp already uses, so a message
    /// too short to evidence coverage is also too short to earn a full memory
    /// lane. Applied as `min(cap, shortMessageMemoryRowCap)`. `0` disables the
    /// cap on its own, and `memorySemanticFloor == 0` disables it too.
    public let shortMessageMemoryRowCap: Int
    public let weights: ContextScoreWeights

    /// Content-token count at or below which a message counts as short.
    public static let shortMessageTokenCount = 4

    public init(
        maximumCandidates: Int = 256,
        maximumDynamicAtoms: Int = 12,
        maximumPointers: Int = 8,
        maximumAtomsPerSource: Int = 2,
        maximumAtomsPerKind: Int = 4,
        maximumAtomsPerKindOverrides: [ContextAtomKind: Int] = [.memory: 8, .relationship: 4],
        reservedRoleSlotsPerKind: [ContextAtomKind: ContextRoleReservation] = [
            .memory: ContextRoleReservation(role: .procedure, slots: 2),
        ],
        maximumCorrectionAtomsPerTurn: Int = 3,
        minimumRelevance: Double = 0.05,
        memorySemanticFloor: Double = 0.30,
        shortMessageMemoryRowCap: Int = 6,
        weights: ContextScoreWeights = ContextScoreWeights()
    ) {
        self.maximumCandidates = max(1, maximumCandidates)
        self.maximumDynamicAtoms = max(0, maximumDynamicAtoms)
        self.maximumPointers = max(0, maximumPointers)
        self.maximumAtomsPerSource = max(1, maximumAtomsPerSource)
        self.maximumAtomsPerKind = max(1, maximumAtomsPerKind)
        let overrides = maximumAtomsPerKindOverrides.mapValues { max(1, $0) }
        self.maximumAtomsPerKindOverrides = overrides
        // A reserve that could consume a kind's entire quota would turn a floor
        // for one role into a ceiling of zero for every other one.
        self.reservedRoleSlotsPerKind = Dictionary(
            uniqueKeysWithValues: reservedRoleSlotsPerKind.compactMap { kind, reservation in
                let cap = overrides[kind] ?? max(1, maximumAtomsPerKind)
                let slots = min(reservation.slots, cap - 1)
                guard slots > 0 else { return nil }
                return (kind, ContextRoleReservation(
                    role: reservation.role,
                    slots: slots,
                    minimumMessageCoverage: reservation.minimumMessageCoverage
                ))
            }
        )
        self.maximumCorrectionAtomsPerTurn = max(0, maximumCorrectionAtomsPerTurn)
        self.minimumRelevance = max(0, minimumRelevance)
        self.memorySemanticFloor = max(0, memorySemanticFloor)
        // 0 is OFF, not "no memories at all": a short message is a reason to
        // carry fewer rows, never a reason to empty the lane.
        self.shortMessageMemoryRowCap = max(0, shortMessageMemoryRowCap)
        self.weights = weights
    }

    /// Effective per-kind cap: the override for `kind` when present, else the
    /// uniform `maximumAtomsPerKind`.
    public func maximumAtoms(forKind kind: ContextAtomKind) -> Int {
        maximumAtomsPerKindOverrides[kind] ?? maximumAtomsPerKind
    }
}
