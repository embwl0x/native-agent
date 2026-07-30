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
    public let queryEmbeddingModelFingerprint: String?
    public let availableGenerationID: Int64?
    public let characterBudget: Int
    public let mandatoryCharacterBudget: Int
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
        case staleRuntimeAtomIDs, secretBearingAtomIDs, queryEmbedding, queryEmbeddingModelFingerprint, availableGenerationID
        case characterBudget, mandatoryCharacterBudget, selectionTimeBucket, timeBucketSeconds
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
        queryEmbeddingModelFingerprint: String? = nil,
        availableGenerationID: Int64? = nil,
        characterBudget: Int = 6_000,
        mandatoryCharacterBudget: Int? = nil,
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
        let embeddingFingerprint = queryEmbeddingModelFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.queryEmbeddingModelFingerprint = queryEmbedding == nil
            ? nil
            : ((embeddingFingerprint?.isEmpty == false) ? embeddingFingerprint : nil)
        self.availableGenerationID = availableGenerationID
        self.characterBudget = max(0, characterBudget)
        self.mandatoryCharacterBudget = max(0, mandatoryCharacterBudget ?? characterBudget)
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
    public let diversityBonus: Double
    public let redundancyPenalty: Double
    public let conflictPenalty: Double
    public let characterCostPenalty: Double
    public let total: Double

    fileprivate func reranked(
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

    public init(
        pointer: ContextAtomPointer,
        text: String,
        representation: ContextPacketRepresentation,
        mandatory: Bool
    ) {
        self.pointer = pointer
        self.text = text
        self.representation = representation
        self.mandatory = mandatory
        self.characterCount = text.count
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

public struct ContextSelectionConfiguration: Equatable, Sendable {
    public let maximumCandidates: Int
    public let maximumDynamicAtoms: Int
    public let maximumPointers: Int
    public let maximumAtomsPerSource: Int
    public let maximumAtomsPerKind: Int
    public let minimumRelevance: Double

    public init(
        maximumCandidates: Int = 256,
        maximumDynamicAtoms: Int = 12,
        maximumPointers: Int = 8,
        maximumAtomsPerSource: Int = 2,
        maximumAtomsPerKind: Int = 4,
        minimumRelevance: Double = 0.05
    ) {
        self.maximumCandidates = max(1, maximumCandidates)
        self.maximumDynamicAtoms = max(0, maximumDynamicAtoms)
        self.maximumPointers = max(0, maximumPointers)
        self.maximumAtomsPerSource = max(1, maximumAtomsPerSource)
        self.maximumAtomsPerKind = max(1, maximumAtomsPerKind)
        self.minimumRelevance = max(0, minimumRelevance)
    }
}

// MARK: - Deterministic hybrid selector

public struct ContextSelector: Sendable {
    public let configuration: ContextSelectionConfiguration

    public init(configuration: ContextSelectionConfiguration = .init()) {
        self.configuration = configuration
    }

    public func select(
        _ need: NeedSignal,
        from generation: ContextStoredGeneration,
        pinnedTo snapshot: ContextGenerationSnapshot? = nil,
        measureLatency: Bool = false
    ) throws -> ContextPacket {
        let selectionStarted = measureLatency ? DispatchTime.now().uptimeNanoseconds : nil
        guard need.characterBudget > 0 else { throw ContextSelectionError.invalidCharacterBudget }
        if let requested = need.availableGenerationID, requested != generation.generation.id {
            throw ContextSelectionError.requestedGenerationMismatch(
                requested: requested,
                actual: generation.generation.id
            )
        }
        if let snapshot {
            guard snapshot.generationID == generation.generation.id else {
                throw ContextSelectionError.snapshotGenerationMismatch(
                    snapshot: snapshot.generationID,
                    generation: generation.generation.id
                )
            }
            guard snapshot.sourceFingerprint == generation.generation.sourceFingerprint else {
                throw ContextSelectionError.snapshotFingerprintMismatch
            }
        }

        let groups = try conflictGroups(for: need, generation: generation)
        let resolutionLosers: [ContextAtomID: ContextEligibilityReason] = Dictionary(
            uniqueKeysWithValues: groups.flatMap { group -> [(ContextAtomID, ContextEligibilityReason)] in
            guard let resolved = group.resolvedAtomID else { return [] }
            return group.memberAtomIDs.filter { $0 != resolved }.map {
                ($0, ContextEligibilityReason.supersededByConflictResolution)
            }
        })
        let sourceByID = Dictionary(uniqueKeysWithValues: generation.sources.map {
            ($0.descriptor.id, $0)
        })
        let sortedAtoms = generation.atoms.sorted { $0.draft.id < $1.draft.id }
        let atomByID = Dictionary(uniqueKeysWithValues: sortedAtoms.map { ($0.draft.id, $0) })

        var decisions: [ContextEligibilityDecision] = []
        var eligible: [ContextStoredAtom] = []
        for atom in sortedAtoms {
            let reason = eligibilityReason(
                for: atom,
                generationID: generation.generation.id,
                source: sourceByID[atom.draft.sourceID],
                need: need,
                resolutionReason: resolutionLosers[atom.draft.id]
            )
            decisions.append(ContextEligibilityDecision(
                atomID: atom.draft.id,
                eligible: reason == nil,
                exclusionReason: reason
            ))
            if reason == nil { eligible.append(atom) }
        }

        var mandatoryIDs = need.mandatoryAtomIDs
        mandatoryIDs.formUnion(sortedAtoms.lazy.filter {
            $0.draft.injectionPolicy == .always
                && !need.precoveredSourceIDs.contains($0.draft.sourceID)
        }.map(\.draft.id))
        for group in groups where group.resolvedAtomID == nil
            && !mandatoryIDs.isDisjoint(with: group.memberAtomIDs) {
            mandatoryIDs.formUnion(group.memberAtomIDs.filter {
                atomByID[$0]?.draft.injectionPolicy != .onDemand
            })
        }

        let eligibleIDs = Set(eligible.map(\.draft.id))
        let unavailableMandatory = mandatoryIDs.subtracting(eligibleIDs).sorted()
        guard unavailableMandatory.isEmpty else {
            throw ContextSelectionError.mandatoryUnavailable(unavailableMandatory)
        }

        let groupByAtom = Dictionary(uniqueKeysWithValues: groups.flatMap { group in
            group.memberAtomIDs.map { ($0, group.id) }
        })
        let scoreContext = makeScoreContext(need)
        // Precovered sources are already present in the stable prompt. Keep
        // their eligibility receipts, but do not spend per-turn ranking work
        // on atoms that cannot become dynamic candidates. Explicit mandatory
        // atoms remain scorable for complete receipts.
        let scorable = eligible.filter {
            !need.precoveredSourceIDs.contains($0.draft.sourceID)
                || mandatoryIDs.contains($0.draft.id)
        }
        let lexicalIndex = Dictionary(uniqueKeysWithValues: scorable.map { atom in
            (
                atom.draft.id,
                snapshot?.selectionIndex[atom.draft.id]
                    ?? ContextSelectionIndexEntry(atom: atom.draft)
            )
        })
        var scores: [ContextAtomID: ContextCandidateScoreFeatures] = [:]
        for atom in scorable {
            scores[atom.draft.id] = score(
                atom,
                need: need,
                context: scoreContext,
                lexicalEntry: lexicalIndex[atom.draft.id]
                    ?? ContextSelectionIndexEntry(atom: atom.draft),
                hasUnresolvedConflict: groupByAtom[atom.draft.id] != nil
                    && groups.first(where: { $0.id == groupByAtom[atom.draft.id] })?.resolvedAtomID == nil
            )
        }
        let baseScores = scores

        var selectedItems: [ContextPacketItem] = []
        var selectedIDs = Set<ContextAtomID>()
        var selectionOrdinals: [ContextAtomID: Int] = [:]
        let mandatoryAtoms = mandatoryIDs.compactMap { atomByID[$0] }.sorted(by: mandatoryOrder)
        let mandatoryCharacters = mandatoryAtoms.reduce(0) { $0 + $1.draft.body.count }
        let mandatoryLimit = min(need.characterBudget, need.mandatoryCharacterBudget)
        guard mandatoryCharacters <= mandatoryLimit else {
            throw ContextSelectionError.mandatoryBudgetExceeded(
                required: mandatoryCharacters,
                limit: mandatoryLimit
            )
        }
        for atom in mandatoryAtoms {
            selectedItems.append(ContextPacketItem(
                pointer: ContextAtomPointer(atom: atom, generationID: generation.generation.id),
                text: atom.draft.body,
                representation: .body,
                mandatory: true
            ))
            selectedIDs.insert(atom.draft.id)
            selectionOrdinals[atom.draft.id] = selectedItems.count
        }

        let rankedCandidates = eligible
            .filter { !mandatoryIDs.contains($0.draft.id) }
            .filter { !need.precoveredSourceIDs.contains($0.draft.sourceID) }
            .filter { relevance(of: scores[$0.draft.id]) >= configuration.minimumRelevance }
            .sorted { rankedBefore($0, $1, scores: scores) }
        let boundedCandidates = Array(rankedCandidates.prefix(configuration.maximumCandidates))
        let candidateIDs = Set(boundedCandidates.map(\.draft.id))

        var units = makeSelectionUnits(
            candidates: boundedCandidates.filter { $0.draft.injectionPolicy != .onDemand },
            groups: groups,
            atomByID: atomByID,
            candidateIDs: candidateIDs,
            mandatoryIDs: mandatoryIDs
        )
        var selectedDynamicCount = 0
        var usedCharacters = mandatoryCharacters
        var sourceCounts: [ContextSourceID: Int] = [:]
        var kindCounts: [ContextAtomKind: Int] = [:]
        var omittedConflictIDs = Set<String>()
        let selectedTokenSets = selectedItems.map { Self.tokens($0.text) }
        var redundancyByAtom = Dictionary(uniqueKeysWithValues: boundedCandidates.map { atom in
            (
                atom.draft.id,
                maximumTokenSimilarity(
                    lexicalIndex[atom.draft.id]?.bodyTokens ?? [],
                    selectedTokenSets
                )
            )
        })

        while !units.isEmpty && selectedDynamicCount < configuration.maximumDynamicAtoms {
            var reranked: [(unit: SelectionUnit, value: Double)] = []
            for unit in units {
                var total = 0.0
                for atom in unit.atoms {
                    guard let original = baseScores[atom.draft.id] else { continue }
                    let redundancy = redundancyByAtom[atom.draft.id] ?? 0
                    let diversity = diversityBonus(
                        for: atom,
                        sourceCounts: sourceCounts,
                        kindCounts: kindCounts
                    )
                    let value = original.total + diversity - (1.1 * redundancy)
                    scores[atom.draft.id] = original.reranked(
                        diversityBonus: diversity,
                        redundancyPenalty: redundancy,
                        total: value
                    )
                    total += value
                }
                reranked.append((unit, total / Double(max(1, unit.atoms.count))))
            }
            reranked.sort {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.unit.stableKey < $1.unit.stableKey
            }
            let unit = reranked[0].unit
            units.removeAll { $0.stableKey == unit.stableKey }

            let remainingAtomSlots = configuration.maximumDynamicAtoms - selectedDynamicCount
            guard unit.atoms.count <= remainingAtomSlots,
                  quotaAllows(unit, sourceCounts: sourceCounts, kindCounts: kindCounts),
                  let planned = plannedItems(
                    for: unit,
                    generationID: generation.generation.id,
                    remainingCharacters: need.characterBudget - usedCharacters
                  ) else {
                if let conflictID = unit.conflictID { omittedConflictIDs.insert(conflictID) }
                continue
            }

            for item in planned {
                selectedItems.append(item)
                selectedIDs.insert(item.pointer.atomID)
                selectedDynamicCount += 1
                usedCharacters += item.characterCount
                selectionOrdinals[item.pointer.atomID] = selectedItems.count
                sourceCounts[item.pointer.sourceID, default: 0] += 1
                kindCounts[item.pointer.kind, default: 0] += 1
                let selectedTokens = Self.tokens(item.text)
                for remainingUnit in units {
                    for remainingAtom in remainingUnit.atoms {
                        let atomID = remainingAtom.draft.id
                        let similarity = Self.jaccard(
                            lexicalIndex[atomID]?.bodyTokens ?? [],
                            selectedTokens
                        )
                        redundancyByAtom[atomID] = max(
                            redundancyByAtom[atomID] ?? 0,
                            similarity
                        )
                    }
                }
            }
        }

        let pointers = boundedCandidates
            .filter { $0.draft.injectionPolicy == .onDemand }
            .sorted { rankedBefore($0, $1, scores: scores) }
            .prefix(configuration.maximumPointers)
            .map { ContextAtomPointer(atom: $0, generationID: generation.generation.id) }

        let conflicts = groups.map { group in
            conflictSet(
                group,
                generationID: generation.generation.id,
                atomByID: atomByID,
                eligibleIDs: eligibleIDs,
                candidateIDs: candidateIDs,
                selectedIDs: selectedIDs,
                omittedConflictIDs: omittedConflictIDs
            )
        }.sorted { $0.id < $1.id }
        let degraded = generation.sources.filter { $0.health == .degraded }.map {
            ContextDegradedSourceNotice(
                sourceID: $0.descriptor.id,
                reason: "last known good source retained"
            )
        }.sorted { $0.sourceID < $1.sourceID }
        let budget = ContextBudgetUsage(
            characterLimit: need.characterBudget,
            usedCharacters: usedCharacters,
            mandatoryCharacters: mandatoryCharacters
        )
        let selectedIDList = selectedItems.map(\.pointer.atomID)
        let pointerIDList = pointers.map(\.atomID)
        let mandatoryIDList = mandatoryIDs.sorted()
        let coveredMandatory = mandatoryIDList.filter { selectedIDs.contains($0) }
        let scoreReceiptIDs = mandatoryIDs.union(candidateIDs)
        let scoreReceipts = scores.compactMap { atomID, features -> ContextCandidateScore? in
            guard scoreReceiptIDs.contains(atomID) else { return nil }
            return ContextCandidateScore(
                atomID: atomID,
                features: features,
                selectionOrdinal: selectionOrdinals[atomID]
            )
        }.sorted { $0.atomID < $1.atomID }
        let receiptID = ContextStableID.digest(parts: [
            need.deterministicFingerprint,
            String(generation.generation.id),
            generation.generation.sourceFingerprint,
        ] + selectedIDList.map(\.rawValue) + pointerIDList.map(\.rawValue))
        let measuredSelectionMicroseconds = selectionStarted.map {
            Int((DispatchTime.now().uptimeNanoseconds &- $0) / 1_000)
        } ?? need.measuredSelectionMicroseconds
        let receipt = ContextSelectionReceipt(
            id: receiptID,
            needFingerprint: need.deterministicFingerprint,
            generationID: generation.generation.id,
            sourceFingerprint: generation.generation.sourceFingerprint,
            selectionTimeBucket: need.selectionTimeBucket,
            eligibility: decisions,
            candidateScores: scoreReceipts,
            selectedAtomIDs: selectedIDList,
            pointerAtomIDs: pointerIDList,
            mandatoryAtomIDs: mandatoryIDList,
            coveredMandatoryAtomIDs: coveredMandatory,
            mandatoryCoverage: mandatoryIDList.isEmpty
                ? 1
                : Double(coveredMandatory.count) / Double(mandatoryIDList.count),
            conflicts: conflicts,
            budget: budget,
            degradedSources: degraded,
            cacheState: need.cacheState,
            measuredSelectionMicroseconds: measuredSelectionMicroseconds
        )

        return ContextPacket(
            generationID: generation.generation.id,
            sourceFingerprint: generation.generation.sourceFingerprint,
            selectedItems: selectedItems,
            expandablePointers: Array(pointers),
            conflictSets: conflicts,
            degradedSources: degraded,
            budget: budget,
            receipt: receipt
        )
    }
}

// MARK: - Selection internals

private extension ContextSelector {
    struct ScoreContext {
        let queryTokens: Set<String>
        let normalizedMessage: String?
        let identifiers: Set<String>
        let contextualTokens: Set<String>
    }

    struct ConflictGroup {
        let id: String
        let memberAtomIDs: Set<ContextAtomID>
        let resolvedAtomID: ContextAtomID?
        let provenance: [String]
    }

    struct SelectionUnit {
        let stableKey: String
        let conflictID: String?
        let atoms: [ContextStoredAtom]
    }

    func eligibilityReason(
        for atom: ContextStoredAtom,
        generationID: Int64,
        source: ContextStoredSource?,
        need: NeedSignal,
        resolutionReason: ContextEligibilityReason?
    ) -> ContextEligibilityReason? {
        guard let source else { return .missingSource }
        guard atom.validFromGeneration <= generationID,
              atom.validToGeneration.map({ $0 >= generationID }) ?? true,
              source.validFromGeneration <= generationID,
              source.validToGeneration.map({ $0 >= generationID }) ?? true else {
            return .generationMismatch
        }
        if need.deletedAtomIDs.contains(atom.draft.id) { return .deleted }
        if need.tombstonedAtomIDs.contains(atom.draft.id) { return .tombstoned }
        if source.health == .removed { return .sourceRemoved }
        if !need.authorization.allowedOrigins.contains(need.origin) { return .originDenied }
        if !need.authorization.allowedSourceIDs.contains(atom.draft.sourceID) {
            return .permissionDenied
        }
        if let allowedAtoms = need.authorization.allowedAtomIDs,
           !allowedAtoms.contains(atom.draft.id) {
            return .permissionDenied
        }
        if !atom.draft.permittedSurfaces.contains(need.surface)
            || !source.descriptor.permittedSurfaces.contains(need.surface) {
            return .surfaceDenied
        }
        if !need.authorization.allowedPrivacy.contains(atom.draft.privacy)
            || !need.authorization.allowedPrivacy.contains(source.descriptor.privacy) {
            return .privacyDenied
        }
        if atom.draft.injectionPolicy == .neverInject
            || source.descriptor.injectionPolicy == .neverInject {
            return .neverInject
        }
        if atom.draft.freshness.isExpired(at: need.evaluationTime) { return .expired }
        if need.staleRuntimeAtomIDs.contains(atom.draft.id) { return .staleRuntime }
        if need.secretBearingAtomIDs.contains(atom.draft.id) { return .secretBearing }
        if let resolutionReason { return resolutionReason }
        return nil
    }

    func score(
        _ atom: ContextStoredAtom,
        need: NeedSignal,
        context: ScoreContext,
        lexicalEntry: ContextSelectionIndexEntry,
        hasUnresolvedConflict: Bool
    ) -> ContextCandidateScoreFeatures {
        let exact = context.normalizedMessage.map {
            lexicalEntry.normalizedSearchableText.contains($0) ? 1.0 : 0.0
        } ?? 0
        let overlap = Self.tokenOverlap(context.queryTokens, lexicalEntry.searchableTokens)
        let semantic: Double = {
            guard let queryFingerprint = need.queryEmbeddingModelFingerprint,
                  let atomEmbedding = atom.draft.embedding,
                  queryFingerprint == atomEmbedding.modelFingerprint else { return 0 }
            return Self.cosine(need.queryEmbedding, atomEmbedding.values)
        }()
        let shared = sharedIdentifierScore(atom.draft, context: context)
        let activation = max(
            atom.draft.activation,
            need.cognitiveActivation[atom.draft.id] ?? 0,
            need.workingAtomIDs.contains(atom.draft.id) ? 1 : 0
        )
        let authority = Double(atom.draft.authority.rank) / 6.0
        let confidence = atom.draft.confidence
        let ageDays = max(
            0,
            need.evaluationTime.timeIntervalSince(atom.draft.freshness.updatedAt) / 86_400
        )
        let recency = 1 / (1 + (ageDays / 30))
        let usefulness = need.feedbackUtilityOverrides[atom.draft.id]
            ?? atom.draft.recentUsefulness
        let decay = need.feedbackDecayOverrides[atom.draft.id]
            ?? atom.draft.decayState
        let conflictPenalty = hasUnresolvedConflict ? 0.12 : 0
        let costRatio = Double(atom.draft.body.count) / Double(max(1, need.characterBudget))
        let costPenalty = min(0.35, costRatio * 0.35)
        let total = (2.4 * exact)
            + (1.7 * overlap)
            + (1.2 * semantic)
            + (1.5 * shared)
            + (1.2 * activation)
            + (1.0 * authority)
            + (0.8 * confidence)
            + (0.5 * recency)
            + (0.7 * usefulness)
            + (0.5 * decay)
            - conflictPenalty
            - costPenalty
        return ContextCandidateScoreFeatures(
            lexicalExact: exact,
            tokenOverlap: overlap,
            semanticCosine: semantic,
            sharedIdentifiers: shared,
            activation: activation,
            authority: authority,
            confidence: confidence,
            recency: recency,
            usefulness: usefulness,
            decay: decay,
            diversityBonus: 0,
            redundancyPenalty: 0,
            conflictPenalty: conflictPenalty,
            characterCostPenalty: costPenalty,
            total: total
        )
    }

    func queryText(_ need: NeedSignal) -> String {
        ([
            need.message,
            need.activeTask,
            need.unresolvedQuestion,
            need.goal,
            need.currentProjectID,
            need.sessionID,
            need.executionID,
        ].compactMap { $0 }
            + need.recentTurns.suffix(4)
            + need.contextualTerms.sorted()
            + need.predictedToolGroups.sorted()
            + need.extractedEntities.flatMap { [$0.id, $0.label] })
            .joined(separator: " ")
    }

    func makeScoreContext(_ need: NeedSignal) -> ScoreContext {
        let contextualIDs = [need.currentProjectID, need.sessionID, need.executionID]
            .compactMap { $0 }
        var identifiers = Set(need.extractedEntities.map {
            "\($0.kind.lowercased()):\($0.id.lowercased())"
        })
        identifiers.formUnion(contextualIDs.map { "id:\($0.lowercased())" })
        let trimmedMessage = need.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScoreContext(
            queryTokens: Self.tokens(queryText(need)),
            normalizedMessage: trimmedMessage.isEmpty ? nil : need.message.lowercased(),
            identifiers: identifiers,
            contextualTokens: Set(contextualIDs.flatMap { Self.tokens($0) })
        )
    }

    func sharedIdentifierScore(_ atom: ContextAtomDraft, context: ScoreContext) -> Double {
        let atomIdentifiers = Set(atom.entities.flatMap { entity in
            [
                "\(entity.kind.lowercased()):\(entity.id.lowercased())",
                "id:\(entity.id.lowercased())",
            ]
        })
        if !context.identifiers.isDisjoint(with: atomIdentifiers) { return 1 }
        let labels = Set(atom.entities.flatMap { Self.tokens($0.label) })
        return labels.isDisjoint(with: context.contextualTokens) ? 0 : 0.5
    }

    func relevance(of score: ContextCandidateScoreFeatures?) -> Double {
        guard let score else { return 0 }
        return score.lexicalExact + score.tokenOverlap + score.semanticCosine
            + score.sharedIdentifiers + score.activation
    }

    func rankedBefore(
        _ lhs: ContextStoredAtom,
        _ rhs: ContextStoredAtom,
        scores: [ContextAtomID: ContextCandidateScoreFeatures]
    ) -> Bool {
        let left = scores[lhs.draft.id]?.total ?? -.infinity
        let right = scores[rhs.draft.id]?.total ?? -.infinity
        if left != right { return left > right }
        return lhs.draft.id < rhs.draft.id
    }

    func mandatoryOrder(_ lhs: ContextStoredAtom, _ rhs: ContextStoredAtom) -> Bool {
        let left = mandatoryKindRank(lhs.draft.kind)
        let right = mandatoryKindRank(rhs.draft.kind)
        if left != right { return left < right }
        return lhs.draft.id < rhs.draft.id
    }

    func mandatoryKindRank(_ kind: ContextAtomKind) -> Int {
        switch kind {
        case .identity: 0
        case .relationship: 1
        case .correction: 2
        case .runtimeTruth: 3
        default: 4
        }
    }

    func makeSelectionUnits(
        candidates: [ContextStoredAtom],
        groups: [ConflictGroup],
        atomByID: [ContextAtomID: ContextStoredAtom],
        candidateIDs: Set<ContextAtomID>,
        mandatoryIDs: Set<ContextAtomID>
    ) -> [SelectionUnit] {
        var consumed = Set<ContextAtomID>()
        var result: [SelectionUnit] = []
        for group in groups where group.resolvedAtomID == nil {
            let ids = group.memberAtomIDs
                .intersection(candidateIDs)
                .subtracting(mandatoryIDs)
            guard ids.count == group.memberAtomIDs.subtracting(mandatoryIDs).count,
                  ids.count > 1 else { continue }
            let atoms = ids.compactMap { atomByID[$0] }.sorted { $0.draft.id < $1.draft.id }
            guard atoms.allSatisfy({ $0.draft.injectionPolicy != .onDemand }) else { continue }
            result.append(SelectionUnit(stableKey: "conflict:\(group.id)", conflictID: group.id, atoms: atoms))
            consumed.formUnion(ids)
        }
        for atom in candidates where !consumed.contains(atom.draft.id) {
            result.append(SelectionUnit(
                stableKey: "atom:\(atom.draft.id.rawValue)",
                conflictID: nil,
                atoms: [atom]
            ))
        }
        return result
    }

    func quotaAllows(
        _ unit: SelectionUnit,
        sourceCounts: [ContextSourceID: Int],
        kindCounts: [ContextAtomKind: Int]
    ) -> Bool {
        // An unresolved conflict is atomic: completeness takes precedence over
        // diversity caps, while the character and atom budgets still apply.
        if unit.conflictID != nil { return true }
        for atom in unit.atoms {
            if sourceCounts[atom.draft.sourceID, default: 0] + 1
                > configuration.maximumAtomsPerSource { return false }
            if kindCounts[atom.draft.kind, default: 0] + 1
                > configuration.maximumAtomsPerKind { return false }
        }
        return true
    }

    func plannedItems(
        for unit: SelectionUnit,
        generationID: Int64,
        remainingCharacters: Int
    ) -> [ContextPacketItem]? {
        let bodyCount = unit.atoms.reduce(0) { $0 + $1.draft.body.count }
        if bodyCount <= remainingCharacters {
            return unit.atoms.map {
                ContextPacketItem(
                    pointer: ContextAtomPointer(atom: $0, generationID: generationID),
                    text: $0.draft.body,
                    representation: .body,
                    mandatory: false
                )
            }
        }
        let summaries = unit.atoms.map { $0.draft.deterministicSummary?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard summaries.allSatisfy({ !($0 ?? "").isEmpty }) else { return nil }
        let summaryCount = summaries.reduce(0) { $0 + ($1?.count ?? 0) }
        guard summaryCount <= remainingCharacters else { return nil }
        return zip(unit.atoms, summaries).map { atom, summary in
            ContextPacketItem(
                pointer: ContextAtomPointer(atom: atom, generationID: generationID),
                text: summary ?? "",
                representation: .deterministicSummary,
                mandatory: false
            )
        }
    }

    func diversityBonus(
        for atom: ContextStoredAtom,
        sourceCounts: [ContextSourceID: Int],
        kindCounts: [ContextAtomKind: Int]
    ) -> Double {
        (sourceCounts[atom.draft.sourceID, default: 0] == 0 ? 0.14 : 0)
            + (kindCounts[atom.draft.kind, default: 0] == 0 ? 0.10 : 0)
    }

    func maximumTokenSimilarity(
        _ candidateTokens: Set<String>,
        _ selectedTokenSets: [Set<String>]
    ) -> Double {
        selectedTokenSets.reduce(0) { current, selectedTokens in
            max(current, Self.jaccard(candidateTokens, selectedTokens))
        }
    }

    func conflictGroups(
        for need: NeedSignal,
        generation: ContextStoredGeneration
    ) throws -> [ConflictGroup] {
        var adjacency: [ContextAtomID: Set<ContextAtomID>] = [:]
        var relationshipProvenance: [(members: Set<ContextAtomID>, value: String)] = []
        var explicitByID: [String: ContextConflictDefinition] = [:]

        for definition in need.explicitConflicts.sorted(by: { $0.id < $1.id }) {
            guard definition.memberAtomIDs.count >= 2 else { continue }
            if let resolved = definition.resolvedAtomID,
               !definition.memberAtomIDs.contains(resolved) {
                throw ContextSelectionError.invalidConflictResolution(
                    conflictID: definition.id,
                    atomID: resolved
                )
            }
            explicitByID[definition.id] = definition
            connect(definition.memberAtomIDs, adjacency: &adjacency)
        }
        for relationship in generation.relationships.sorted(by: { $0.draft.id < $1.draft.id })
            where Self.isConflictKind(relationship.draft.kind) {
            let pair: Set<ContextAtomID> = [
                relationship.draft.sourceAtomID,
                relationship.draft.targetAtomID,
            ]
            connect(pair, adjacency: &adjacency)
            relationshipProvenance.append((pair, relationship.draft.provenance))
        }

        var visited = Set<ContextAtomID>()
        var groups: [ConflictGroup] = []
        for start in adjacency.keys.sorted() where !visited.contains(start) {
            var stack = [start]
            var members = Set<ContextAtomID>()
            while let current = stack.popLast() {
                guard visited.insert(current).inserted else { continue }
                members.insert(current)
                stack.append(contentsOf: (adjacency[current] ?? []).sorted(by: >))
            }
            let matchingDefinitions = explicitByID.values.filter {
                !$0.memberAtomIDs.isDisjoint(with: members)
            }.sorted { $0.id < $1.id }
            let resolutions = Set(matchingDefinitions.compactMap(\.resolvedAtomID))
            if resolutions.count > 1, let conflicting = resolutions.sorted().last {
                throw ContextSelectionError.invalidConflictResolution(
                    conflictID: matchingDefinitions.map(\.id).joined(separator: "+"),
                    atomID: conflicting
                )
            }
            let exactDefinition = matchingDefinitions.first { $0.memberAtomIDs == members }
            let id = exactDefinition?.id ?? "conflict:" + ContextStableID.digest(
                parts: members.map(\.rawValue).sorted()
            )
            var provenance = matchingDefinitions.map(\.provenance)
            provenance.append(contentsOf: relationshipProvenance.compactMap { edge in
                edge.members.isSubset(of: members) ? edge.value : nil
            })
            groups.append(ConflictGroup(
                id: id,
                memberAtomIDs: members,
                resolvedAtomID: resolutions.first,
                provenance: Array(Set(provenance)).sorted()
            ))
        }
        return groups.sorted { $0.id < $1.id }
    }

    func connect(
        _ members: Set<ContextAtomID>,
        adjacency: inout [ContextAtomID: Set<ContextAtomID>]
    ) {
        let sorted = members.sorted()
        for atom in sorted where adjacency[atom] == nil { adjacency[atom] = [] }
        guard let first = sorted.first else { return }
        for atom in sorted.dropFirst() {
            adjacency[first, default: []].insert(atom)
            adjacency[atom, default: []].insert(first)
        }
    }

    func conflictSet(
        _ group: ConflictGroup,
        generationID: Int64,
        atomByID: [ContextAtomID: ContextStoredAtom],
        eligibleIDs: Set<ContextAtomID>,
        candidateIDs: Set<ContextAtomID>,
        selectedIDs: Set<ContextAtomID>,
        omittedConflictIDs: Set<String>
    ) -> ContextConflictSet {
        let eligibleMembers = group.memberAtomIDs.intersection(eligibleIDs)
        let claims = eligibleMembers.compactMap { atomByID[$0] }
            .sorted { $0.draft.id < $1.draft.id }
            .map { ContextAtomPointer(atom: $0, generationID: generationID) }
        let handling: ContextConflictHandling
        if let resolved = group.resolvedAtomID {
            handling = eligibleIDs.contains(resolved) ? .resolved : .ineligible
        } else if eligibleMembers.count != group.memberAtomIDs.count {
            handling = .ineligible
        } else if group.memberAtomIDs.isSubset(of: selectedIDs) {
            handling = .includedUncertainty
        } else if omittedConflictIDs.contains(group.id)
            || !group.memberAtomIDs.intersection(candidateIDs).isEmpty {
            handling = .omittedBudget
        } else {
            handling = .omittedIrrelevant
        }
        return ContextConflictSet(
            id: group.id,
            claims: claims,
            resolvedAtomID: group.resolvedAtomID,
            provenance: group.provenance,
            handling: handling
        )
    }

    static func isConflictKind(_ kind: String) -> Bool {
        let normalized = kind.lowercased().replacingOccurrences(of: "-", with: "_")
        return normalized == "conflict" || normalized == "conflicts"
            || normalized == "contradicts" || normalized == "contradiction"
    }

    static func tokens(_ text: String) -> Set<String> {
        ContextLexicalTokenizer.tokens(text)
    }

    static func tokenOverlap(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let intersection = lhs.intersection(rhs)
        let queryCoverage = Double(intersection.count) / Double(lhs.count)
        return (queryCoverage + jaccard(lhs, rhs)) / 2
    }

    static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }

    static func cosine(_ lhs: [Float]?, _ rhs: [Float]?) -> Double {
        // Single source of truth: VectorMath.cosine (raw, finiteness-guarded,
        // equal-length required). Context selection preserves its historical
        // [0, 1] clamp at THIS call site — negative similarity is treated as
        // "no relevance" for selection.
        min(1, max(0, VectorMath.cosine(lhs, rhs)))
    }
}

private enum ContextLexicalTokenizer {
    /// Structural English words are useful to a model after selection but are
    /// not evidence that an adaptive source is relevant. Keeping them in the
    /// overlap gate made any prose-heavy resident truth match unrelated chat
    /// through words such as "the" or "is". Identifiers, numbers, domain
    /// terms, explicit triggers, and semantic vectors remain untouched.
    private static let routingStopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "by", "for",
        "from", "has", "have", "he", "her", "hers", "him", "his", "i", "in",
        "is", "it", "its", "me", "my", "of", "on", "or", "our", "ours", "she",
        "that", "the", "their", "theirs", "them", "they", "this", "to", "was",
        "we", "were", "what", "when", "where", "which", "who", "why", "will",
        "with", "you", "your", "yours",
    ]

    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.compactMap {
            let token = String($0)
            return routingStopWords.contains(token) ? nil : token
        })
    }
}
