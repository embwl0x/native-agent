import Foundation
import NativeAgentCore
// Blueprint: | `ContextRelevance.swift` | `ContextSelector` relevance mathematics: lexical/semantic scoring, memory-population standing, diversity and redundancy; `ContextLexicalTokenizer` shares recall normalization |

extension ContextSelector {
    struct ScoreContext {
        let queryTokens: Set<String>
        let normalizedMessage: String?
        let identifiers: Set<String>
        let contextualTokens: Set<String>
        /// Raw current-message tokens are messageCoverage's denominator;
        /// queryTokens additionally carries context and can dilute a single source.
        let messageTokens: Set<String>
        let tokenSpecificity: [String: Double]

        func matchedWeight(_ tokens: Set<String>, in document: Set<String>) -> Double {
            tokens.intersection(document).sorted().reduce(0) {
                $0 + (tokenSpecificity[$1] ?? 1)
            }
        }
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
        let matchedWeight = context.matchedWeight(context.queryTokens, in: lexicalEntry.searchableTokens)
        let overlap = context.queryTokens.isEmpty ? 0 : (
            matchedWeight / Double(context.queryTokens.count)
                + matchedWeight / Double(max(1, context.queryTokens.union(lexicalEntry.searchableTokens).count))
        ) / 2
        let semantic: Double = {
            guard let queryFingerprint = need.queryEmbeddingModelFingerprint,
                  let atomEmbedding = atom.draft.embedding,
                  queryFingerprint == atomEmbedding.modelFingerprint else { return 0 }
            // Take the best cosine across both voices and a follow-up's own words; nil scores zero.
            return ([need.queryEmbedding, need.alternateQueryEmbedding]
                + (need.ownWordsQueryEmbeddings ?? []).map { Optional($0) })
                .map { Self.cosine($0, atomEmbedding.values) }
                .max() ?? 0
        }()
        let shared = sharedIdentifierScore(atom.draft, context: context)
        let activation = max(atom.draft.activation, need.cognitiveActivation[atom.draft.id] ?? 0)
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
        let w = configuration.weights
        let conflictPenalty = hasUnresolvedConflict ? w.conflictPenalty : 0
        let costRatio = Double(atom.draft.body.count) / Double(max(1, need.characterBudget))
        let costPenalty = min(w.characterCostPenaltyCap, costRatio * w.characterCostPenaltyCap)
        // Current-message coverage excludes carried context and reaches full weight
        // at the memory lane's short-message boundary; tiny queries lean on semantics/overlap.
        let messageCoverage: Double = {
            guard !context.messageTokens.isEmpty else { return 0 }
            let hit = context.matchedWeight(context.messageTokens, in: lexicalEntry.searchableTokens)
            let raw = hit / Double(context.messageTokens.count)
            let lengthDamp = min(1.0, Double(context.messageTokens.count)
                / Double(ContextSelectionConfiguration.shortMessageTokenCount))
            return raw * lengthDamp
        }()
        // Model-scaled meaning runs from unrelated at its floor to identical at 1.
        let semanticFloor = min(0.99, max(0, configuration.memorySemanticFloor(forModel: need.queryEmbeddingModelID) ?? 0))
        let meaning = max(0, semantic - semanticFloor) / (1 - semanticFloor)
        let total = (w.lexicalExact * exact)
            + (w.tokenOverlap * overlap)
            + (w.semanticCosine * meaning)
            + (w.sharedIdentifiers * shared)
            + (w.activation * activation)
            + (w.authority * authority)
            + (w.confidence * confidence)
            + (w.recency * recency)
            + (w.usefulness * usefulness)
            + (w.decay * decay)
            + (w.messageCoverage * messageCoverage)
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
            messageCoverage: messageCoverage,
            diversityBonus: 0,
            redundancyPenalty: 0,
            conflictPenalty: conflictPenalty,
            characterCostPenalty: costPenalty,
            total: total
        )
    }

    private func queryText(_ need: NeedSignal) -> String {
        // Match the existing semantic-recall and correction-scope contract:
        // prior conversation helps resolve a referential follow-up, but is
        // not fresh topic evidence after a self-contained user request.
        // Otherwise old work can clear minimumRelevance on lexical overlap
        // alone even when the current message has changed subjects.
        let recentTurns = ContextCorrectionScope.isReferentialFollowup(need.message)
            ? need.recentTurns.suffix(2).map { String($0.prefix(600)) }
            : []
        return ([
            need.message,
            need.activeTask,
            need.unresolvedQuestion,
            need.goal,
            need.currentProjectID,
            need.sessionID,
            need.executionID,
        ].compactMap { $0 }
            + recentTurns
            + need.extractedEntities.flatMap { [$0.id, $0.label] })
            .joined(separator: " ")
    }

    func makeScoreContext(
        _ need: NeedSignal,
        lexicalIndex: [ContextAtomID: ContextSelectionIndexEntry]
    ) -> ScoreContext {
        let contextualIDs = [need.currentProjectID, need.sessionID, need.executionID]
            .compactMap { $0 }
        var identifiers = Set(need.extractedEntities.map {
            "\($0.kind.lowercased()):\($0.id.lowercased())"
        })
        identifiers.formUnion(contextualIDs.map { "id:\($0.lowercased())" })
        let trimmedMessage = need.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryTokens = Self.tokens(queryText(need))
        // Smoothed, normalized inverse document frequency: ubiquitous names
        // and boilerplate are weak relevance evidence, not multiple strong
        // votes against a semantic paraphrase. Only eligible/scorable atoms
        // participate, so inaccessible sources cannot influence ranking.
        // Uses the resident lexical index; no tokenization, I/O or model call.
        let documentCount = Double(lexicalIndex.count)
        let normalization = 1 + log(documentCount + 1)
        let specificity = Dictionary(uniqueKeysWithValues: queryTokens.map { token in
            let frequency = lexicalIndex.values.reduce(0) {
                $0 + ($1.searchableTokens.contains(token) ? 1 : 0)
            }
            return (token, (1 + log((documentCount + 1) / Double(frequency + 1))) / normalization)
        })
        return ScoreContext(
            queryTokens: queryTokens,
            normalizedMessage: trimmedMessage.isEmpty ? nil : need.message.lowercased(),
            identifiers: identifiers,
            contextualTokens: Set(contextualIDs.flatMap { Self.tokens($0) }),
            messageTokens: Self.tokens(need.message),
            tokenSpecificity: specificity
        )
    }

    private func sharedIdentifierScore(_ atom: ContextAtomDraft, context: ScoreContext) -> Double {
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
        // Only messageCoverage is weighted in the relevance gate; zero weight removes its contribution.
        return score.lexicalExact + score.tokenOverlap + score.semanticCosine
            + score.sharedIdentifiers + score.activation
            + (configuration.weights.messageCoverage * score.messageCoverage)
    }

    func diversityBonus(
        for atom: ContextStoredAtom,
        sourceCounts: [ContextSourceID: Int],
        kindCounts: [ContextAtomKind: Int]
    ) -> Double {
        (sourceCounts[atom.draft.sourceID, default: 0] == 0
            ? configuration.weights.diversityNewSourceBonus : 0)
            + (kindCounts[atom.draft.kind, default: 0] == 0
                ? configuration.weights.diversityNewKindBonus : 0)
    }

    func maximumTokenSimilarity(
        _ candidateTokens: Set<String>,
        _ selectedTokenSets: [Set<String>]
    ) -> Double {
        selectedTokenSets.reduce(0) { current, selectedTokens in
            max(current, Self.jaccard(candidateTokens, selectedTokens))
        }
    }

    static func tokens(_ text: String) -> Set<String> {
        ContextLexicalTokenizer.tokens(text)
    }

    static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }

    private static func cosine(_ lhs: [Float]?, _ rhs: [Float]?) -> Double {
        // VectorMath owns cosine validity; selection clamps negative similarity to no relevance.
        min(1, max(0, VectorMath.cosine(lhs, rhs)))
    }

    /// Memory touch is the best leave-one-out standing across query readings:
    /// primary, other voice, and a follow-up's own words and other voice.
    /// Remove each atom's mean pull toward others relative to the lane's mean.
    /// Summed unit vectors and aggregate moments keep this linear. The chance
    /// bar counts readings × atoms and assumes roughly independent Gaussian
    /// background scores; this is a heuristic, not a calibrated probability.
    /// Above a constant background, infinite standing saturates to finite Double.
    /// Fewer than three vectors use model-scaled semantics; no comparable vectors give no touch.
    func memoryRelevance(
        _ atoms: [ContextStoredAtom],
        need: NeedSignal,
        scores: [ContextAtomID: ContextCandidateScoreFeatures]
    ) -> (relevance: [ContextAtomID: Double], looks: Int) {
        guard let fingerprint = need.queryEmbeddingModelFingerprint,
              let primary = need.queryEmbedding, !primary.isEmpty else { return ([:], 0) }
        var units: [(id: ContextAtomID, vector: [Double])] = []
        for atom in atoms {
            guard let embedding = atom.draft.embedding, embedding.modelFingerprint == fingerprint,
                  embedding.values.count == (units.first?.vector.count ?? embedding.values.count) else { continue }
            let norm = embedding.values.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            guard norm > 0, norm.isFinite else { continue }
            units.append((atom.draft.id, embedding.values.map { Double($0) / norm }))
        }
        // One or two vectors cannot establish a relative population. Use the
        // same model-scaled semantic contribution as the ordinary score.
        if units.count < 3 {
            let floor = min(0.99, max(0, configuration.memorySemanticFloor(forModel: need.queryEmbeddingModelID) ?? 0))
            return (Dictionary(uniqueKeysWithValues: units.map {
                ($0.id, configuration.weights.semanticCosine * max(0, (scores[$0.id]?.semanticCosine ?? 0) - floor) / (1 - floor))
            }), units.count)
        }
        guard let dimension = units.first?.vector.count else { return ([:], 0) }
        var sum = [Double](repeating: 0, count: dimension)
        for unit in units { for index in sum.indices { sum[index] += unit.vector[index] } }
        let count = Double(units.count)
        let pull = units.map { unit in
            (zip(unit.vector, sum).reduce(0.0) { $0 + $1.0 * $1.1 } - 1) / (count - 1)
        }
        let meanPull = pull.reduce(0, +) / count
        let readings = ([primary] + [need.alternateQueryEmbedding].compactMap { $0 }
            + (need.ownWordsQueryEmbeddings ?? [])).filter { $0.count == dimension }
        var best = [Double](repeating: 0, count: units.count)
        var readingsLooked = 0
        for reading in readings {
            let norm = reading.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            guard norm > 0, norm.isFinite else { continue }
            let query = reading.map { Double($0) / norm }
            let touch = zip(units, pull).map { unit, pull in
                // The selector's [0, 1] cosine clamp (`cosine`), on unit vectors.
                min(1, max(0, zip(unit.vector, query).reduce(0.0) { $0 + $1.0 * $1.1 })) - (pull - meanPull)
            }
            for (index, standing) in VectorMath.standout(touch).enumerated() {
                guard let standing else { continue }
                best[index] = max(best[index], min(Double.greatestFiniteMagnitude, standing))
            }
            readingsLooked += 1
        }
        guard readingsLooked > 0 else { return ([:], 0) }
        return (Dictionary(zip(units, best).map { ($0.id, $1) }, uniquingKeysWith: { first, _ in first }),
                readingsLooked * units.count)
    }
}

enum ContextLexicalTokenizer {
    /// Structural English words provide no overlap evidence; identifiers, numbers,
    /// domain terms and triggers remain. MemoryV2 BM25 shares these stop words.
    private static let routingStopWords: Set<String> = RecallLexicalNormalization.stopWords

    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.compactMap {
            let token = String($0)
            return routingStopWords.contains(token) ? nil : RecallLexicalNormalization.term(token)
        })
    }
}
