import Foundation
import HashTreeCollections
import NativeAgentCore
// Blueprint: | `ContextRelevance.swift` | `ContextSelector`, `ContextLexicalTokenizer`: shared relevance and normalization |

extension ContextSelector {
    struct ScoreContext {
        let queryTokens: Set<String>
        let normalizedMessage: String?
        let identifiers: Set<String>
        let contextualTokens: Set<String>
        /// Raw current-message tokens are messageCoverage's denominator; queryTokens additionally carries context and can dilute a single source.
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
        semantic: Double,
        lexicalEntry: ContextSelectionIndexEntry
    ) -> ContextCandidateScoreFeatures {
        let exact = context.normalizedMessage.map {
            lexicalEntry.normalizedSearchableText.contains($0) ? 1.0 : 0.0
        } ?? 0
        let matchedWeight = context.matchedWeight(context.queryTokens, in: lexicalEntry.searchableTokens)
        let overlap = context.queryTokens.isEmpty ? 0 : (
            matchedWeight / Double(context.queryTokens.count)
                + matchedWeight / Double(max(1, context.queryTokens.union(lexicalEntry.searchableTokens).count))
        ) / 2
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
        let costRatio = Double(atom.draft.body.count) / Double(max(1, need.characterBudget))
        let costPenalty = min(w.characterCostPenaltyCap, costRatio * w.characterCostPenaltyCap)
        // Current-message coverage excludes carried context and reaches full weight at memory's short-message boundary; tiny queries lean on
        // semantics/overlap.
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
            characterCostPenalty: costPenalty,
            total: total
        )
    }

    private func queryText(_ need: NeedSignal) -> String {
        // Prior conversation resolves referential follow-ups but supplies no fresh topic evidence after a self-contained request changes subjects.
        let recentTurns = ContextCorrectionScope.isReferentialFollowup(need.message)
            ? need.recentTurns.suffix(2).map { String($0.prefix(600)) }
            : []
        return ([
            need.message,
            need.activeTask,
            need.unresolvedQuestion,
            need.goal,
            need.currentProjectID,
            need.executionID,
        ].compactMap { $0 }
            + recentTurns
            + need.extractedEntities.flatMap { [$0.id, $0.label] })
            .joined(separator: " ")
    }

    func makeScoreContext(
        _ need: NeedSignal,
        documentCount count: Int, tokenDocFreq: TreeDictionary<String, Int>
    ) -> ScoreContext {
        let contextualIDs = [need.currentProjectID, need.sessionID, need.executionID]
            .compactMap { $0 }
        var identifiers = Set(need.extractedEntities.map {
            "\($0.kind.lowercased()):\($0.id.lowercased())"
        })
        identifiers.formUnion(contextualIDs.map { "id:\($0.lowercased())" })
        let trimmedMessage = need.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryTokens = Self.tokens(queryText(need))
        // Normalized inverse document frequency weakens ubiquitous names and boilerplate; only eligible atoms influence ranking, using the resident lexical
        // index.
        let documentCount = Double(count)
        let normalization = 1 + log(documentCount + 1)
        let specificity = Dictionary(uniqueKeysWithValues: queryTokens.map { token in
            let frequency = tokenDocFreq[token, default: 0]
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

    typealias MemoryTouch = (relevance: [ContextAtomID: Double], cosines: [ContextAtomID: Double], looks: Int)

    func semanticScores(
        _ atoms: [ContextStoredAtom], need: NeedSignal, index: ContextVectorIndex, memoryKinds: Set<ContextAtomKind>
    ) -> (best: [ContextAtomID: Double], touch: MemoryTouch) {
        var best: [ContextAtomID: Double] = [:]
        var touch: MemoryTouch = ([:], [:], 0)
        guard let fingerprint = need.queryEmbeddingModelFingerprint,
              let matrices = index.models[fingerprint] else { return (best, touch) }
        let readings = ([need.queryEmbedding, need.alternateQueryEmbedding].compactMap { $0 }
            + (need.ownWordsQueryEmbeddings ?? [])).compactMap(VectorReading.init)
        var population: [Int] = []
        var populationWidth: Int?
        if let primary = need.queryEmbedding, !primary.isEmpty {
            for atom in atoms where memoryKinds.contains(atom.draft.kind) {
                guard let embedding = atom.draft.embedding, embedding.modelFingerprint == fingerprint else { continue }
                let width = embedding.values.count
                guard populationWidth == nil || populationWidth == width,
                      let row = matrices[width]?.index[atom.draft.id] else { continue }
                populationWidth = width
                population.append(row)
            }
        }
        for (width, matrix) in matrices {
            let members = width == populationWidth ? population : []
            let batch = matrix.score(readings.filter { $0.width == width }, population: members)
            for column in batch.cosines {
                for row in 0..<matrix.count {
                    let id = matrix.id(at: row)
                    best[id] = max(best[id] ?? 0, min(1, column[row]))
                }
            }
            if !members.isEmpty {
                touch = memoryRelevance(batch, members: members, ids: members.map { matrix.id(at: $0) },
                                        best: best, model: need.queryEmbeddingModelID)
            }
        }
        return (best, touch)
    }

    private func memoryRelevance(
        _ batch: VectorMatrix<ContextAtomID>.Scores, members: [Int], ids: [ContextAtomID], best: [ContextAtomID: Double], model: String?
    ) -> MemoryTouch {
        if ids.count < 3 {
            let floor = min(0.99, max(0, configuration.memorySemanticFloor(forModel: model) ?? 0))
            let cosines = Dictionary(uniqueKeysWithValues: ids.map { ($0, best[$0] ?? 0) })
            return (cosines.mapValues { configuration.weights.semanticCosine * max(0, $0 - floor) / (1 - floor) }, cosines, ids.count)
        }
        guard !batch.cosines.isEmpty else { return ([:], [:], 0) }
        let meanPull = batch.pull.reduce(0, +) / Double(ids.count)
        var standings = [Double](repeating: 0, count: ids.count)
        var cosines = standings
        for column in batch.cosines {
            let touches = ids.indices.map { index in
                let cosine = min(1, max(0, column[members[index]]))
                cosines[index] = max(cosines[index], cosine)
                return cosine - (batch.pull[index] - meanPull)
            }
            for (index, standing) in VectorMath.standout(touches).enumerated() {
                guard let standing else { continue }
                standings[index] = max(standings[index], min(Double.greatestFiniteMagnitude, standing))
            }
        }
        return (Dictionary(uniqueKeysWithValues: zip(ids, standings)), Dictionary(uniqueKeysWithValues: zip(ids, cosines)),
                batch.cosines.count * ids.count)
    }
}

struct ContextVectorIndex: Sendable, Equatable {
    struct Location: Equatable, Sendable {
        let model: String
        let width: Int
    }

    private(set) var models: TreeDictionary<String, TreeDictionary<Int, VectorMatrix<ContextAtomID>>>
    private var locations: TreeDictionary<ContextAtomID, Location>

    init(_ atoms: [ContextStoredAtom]) {
        var groups: [String: [(ContextAtomID, VectorReading)]] = [:]
        locations = [:]
        for atom in atoms.sorted(by: { $0.draft.id < $1.draft.id }) {
            guard let embedding = atom.draft.embedding, let vector = VectorReading(embedding.values) else { continue }
            let model = embedding.modelFingerprint
            groups[model, default: []].append((atom.draft.id, vector))
            locations[atom.draft.id] = Location(model: model, width: vector.width)
        }
        models = TreeDictionary(groups.mapValues { TreeDictionary(VectorMatrix.grouped($0, centering: true)) })
    }

    mutating func remove(_ id: ContextAtomID) {
        guard let location = locations.removeValue(forKey: id) else { return }
        models[location.model]?[location.width]?.remove(id)
        if models[location.model]?[location.width]?.count == 0 { models[location.model]?[location.width] = nil }
        if models[location.model]?.isEmpty == true { models[location.model] = nil }
    }

    mutating func set(_ atom: ContextStoredAtom) {
        let id = atom.draft.id
        guard let embedding = atom.draft.embedding, let vector = VectorReading(embedding.values) else {
            remove(id)
            return
        }
        let location = Location(model: embedding.modelFingerprint, width: vector.width)
        if locations[id] != location {
            remove(id)
            locations[id] = location
        }
        models[location.model, default: [:]][location.width,
            default: VectorMatrix([], width: location.width, centering: true)].set(vector, for: id)
    }

}

enum ContextLexicalTokenizer {
    /// Structural English words provide no overlap evidence; identifiers, numbers, domain terms and triggers remain. MemoryV2 BM25 shares these stop words.
    private static let routingStopWords: Set<String> = RecallLexicalNormalization.stopWords

    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.compactMap {
            let token = String($0)
            return routingStopWords.contains(token) ? nil : RecallLexicalNormalization.term(token)
        })
    }
}
