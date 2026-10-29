import CryptoKit
import Foundation
import NativeAgentCore
import PersonaEngine
// Blueprint: | `ContextAtomMatching.swift` | `ContextMarkdownCompiler` atom matching: ordered exact identity reuse and heading-scoped fuzzy matching |

// MARK: - Incremental identity and embeddings

extension ContextMarkdownCompiler {
    func match(candidates: [Candidate], previous: [ContextAtomDraft]) -> [Int?] {
        var matches = [Int?](repeating: nil, count: candidates.count)
        var used: Set<Int> = []
        let previousOrder = previous.indices.sorted {
            previous[$0].sourceRange.utf8Start < previous[$1].sourceRange.utf8Start
        }
        let priors = previous.map { atom in
            let body = Self.semanticBody(atom.body)
            return (key: [atom.kind.rawValue, Self.blockShape(of: atom.body).rawValue, body],
                    heading: Self.normalizedHeadingPath(atom.headingPath), body: body, tokens: Set(Self.tokens(body)))
        }
        let current = candidates.map { candidate in
            (key: [candidate.kind.rawValue, candidate.shape.rawValue, candidate.semanticBody],
             heading: Self.normalizedHeadingPath(candidate.block.headingPath),
             body: candidate.semanticBody, tokens: Set(Self.tokens(candidate.semanticBody)))
        }
        for sameHeading in [true, false] {
            let buckets = Dictionary(grouping: previousOrder) { index in
                priors[index].key + (sameHeading ? priors[index].heading : [])
            }
            for candidateIndex in candidates.indices where matches[candidateIndex] == nil {
                let candidate = current[candidateIndex]
                let key = candidate.key + (sameHeading ? candidate.heading : [])
                if let priorIndex = buckets[key]?.first(where: { !used.contains($0) }) {
                    matches[candidateIndex] = priorIndex
                    used.insert(priorIndex)
                }
            }
        }
        for candidateIndex in candidates.indices where matches[candidateIndex] == nil {
            let candidate = current[candidateIndex]
            var best: (index: Int, score: Double)?
            for priorIndex in previousOrder where !used.contains(priorIndex) {
                let prior = priors[priorIndex]
                guard prior.key.prefix(2) == candidate.key.prefix(2), prior.heading == candidate.heading else { continue }
                let score = Self.similarity(prior.body, candidate.body, leftTokens: prior.tokens, rightTokens: candidate.tokens)
                guard score >= 0.45 else { continue }
                if best.map({ score > $0.score }) ?? true {
                    best = (priorIndex, score)
                }
            }
            if let best {
                matches[candidateIndex] = best.index
                used.insert(best.index)
            }
        }
        return matches
    }

    private static func blockShape(of body: String) -> BlockShape {
        let firstLine = body.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? body
        let bytes = Array(firstLine.utf8)
        if fenceOpening(bytes) != nil { return .fence }
        if isListStart(bytes) { return .list }
        return .paragraph
    }

    private static func similarity(_ lhs: String, _ rhs: String, leftTokens: Set<String>, rightTokens: Set<String>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        if lhs == rhs { return 1 }
        let overlap = leftTokens.intersection(rightTokens).count
        let tokenDice = leftTokens.isEmpty && rightTokens.isEmpty
            ? 0
            : Double(2 * overlap) / Double(leftTokens.count + rightTokens.count)
        let shorter = min(lhs.utf8.count, rhs.utf8.count)
        let longer = max(lhs.utf8.count, rhs.utf8.count)
        let containment = lhs.contains(rhs) || rhs.contains(lhs)
            ? Double(shorter) / Double(max(1, longer))
            : 0
        return max(tokenDice, containment)
    }
}
