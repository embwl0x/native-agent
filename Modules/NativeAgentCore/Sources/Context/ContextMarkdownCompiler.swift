import CryptoKit
import Foundation
import NativeAgentCore
import PersonaEngine
// Blueprint: | `ContextMarkdownCompiler.swift` | `ContextMarkdownCompiler`: bounded Markdown atom compilation and exact unchanged-source reuse; `triggerTokens` owns ordered trigger extraction with source-specific tokenization/filter/bound parameters; persona GROWTH uses the PersonaEngine episodic-log filter before hashing and parsing |

// Preserve the Context module's public policy name while readers/helpers use
// the same owner before composing source fragments into derived text.
public typealias ContextSecretContentPolicy = NativeAgentCore.ContextSecretContentPolicy

public protocol ContextMarkdownEmbeddingProvider: Sendable {
    var modelFingerprint: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

enum ContextMarkdownCompilerLimits {
    static let maxSourceUTF8Bytes = 2 * 1_024 * 1_024
    static let maxAtomUTF8Bytes = 64 * 1_024
    static let maxSummaryUTF8Bytes = 320
    static let maxTriggerUTF8Bytes = 64
    static let maxTriggersPerAtom = 12
}

public enum ContextMarkdownCompilerError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformedUTF8
    case emptySource
    case sourceTooLarge(actualBytes: Int, maximumBytes: Int)
    case atomTooLarge(index: Int, actualBytes: Int, maximumBytes: Int)
    case forbiddenSourceLocator
    case secretLikeContent
    case invalidModelFingerprint
    case embeddingCountMismatch(expected: Int, actual: Int)
    case invalidEmbedding(index: Int)

    public var description: String {
        switch self {
        case .malformedUTF8:
            "context source is not valid UTF-8"
        case .emptySource:
            "context source is empty"
        case .sourceTooLarge(let actual, let maximum):
            "context source is too large (\(actual) bytes; maximum \(maximum))"
        case .atomTooLarge(let index, let actual, let maximum):
            "context atom \(index) is too large (\(actual) bytes; maximum \(maximum))"
        case .forbiddenSourceLocator:
            "context source locator identifies a credential-bearing file class"
        case .secretLikeContent:
            "context source contains secret-like content"
        case .invalidModelFingerprint:
            "context embedding provider has an empty model fingerprint"
        case .embeddingCountMismatch(let expected, let actual):
            "context embedding provider returned \(actual) vectors for \(expected) atoms"
        case .invalidEmbedding(let index):
            "context embedding provider returned an invalid vector at batch index \(index)"
        }
    }
}

/// A deterministic, local-only compiler for registered Markdown sources.
public struct ContextMarkdownCompiler: Sendable {
    /// Ordered, unique triggers; each projection supplies its token and bound rules.
    public static func triggerTokens(
        _ texts: [String], minimumLength: Int, maximumCount: Int,
        excluding stopwords: Set<String>, tokens: (String) -> [String],
        bound: (String) -> String
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for text in texts {
            for token in tokens(text) where !stopwords.contains(token) {
                let value = bound(token)
                guard value.count >= minimumLength, seen.insert(value).inserted else { continue }
                result.append(value)
                if result.count == maximumCount { return result }
            }
        }
        return result
    }

    /// Bump when identical input produces different atoms; `sourceHash` includes this version.
    static let compilerFormatVersion = "4"

    /// Autogen marker comments are structural delimiters and never become atoms.
    static func isAutogenMarkerBlock(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == UserMDAutogenMarkers.bodyStart
            || trimmed == UserMDAutogenMarkers.bodyEnd
            || trimmed == UserMDAutogenMarkers.preambleStart
            || trimmed == UserMDAutogenMarkers.preambleEnd
    }
    private let embeddingProvider: any ContextMarkdownEmbeddingProvider

    public init(embeddingProvider: any ContextMarkdownEmbeddingProvider) {
        self.embeddingProvider = embeddingProvider
    }

    public func compile(
        sourceData: Data,
        descriptor: ContextSourceDescriptor,
        previous: ContextCompiledSource? = nil,
        updatedAt: Date
    ) async throws -> ContextCompiledSource {
        guard sourceData.count <= ContextMarkdownCompilerLimits.maxSourceUTF8Bytes else {
            throw ContextMarkdownCompilerError.sourceTooLarge(
                actualBytes: sourceData.count,
                maximumBytes: ContextMarkdownCompilerLimits.maxSourceUTF8Bytes
            )
        }
        guard let rawSource = String(data: sourceData, encoding: .utf8) else {
            throw ContextMarkdownCompilerError.malformedUTF8
        }
        let source = descriptor.kind == .persona && descriptor.canonicalLocator.hasSuffix("/GROWTH.md")
            ? SwiftNativePersonaEngine.filterEpisodicGrowthLines(rawSource) : rawSource
        let contextData = Data(source.utf8)
        // A document consisting only of legacy log lines must replace its
        // previous atoms with an empty set, rather than retain them on failure.
        guard source != rawSource || !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextMarkdownCompilerError.emptySource
        }
        guard !Self.isForbiddenLocator(descriptor.canonicalLocator) else {
            throw ContextMarkdownCompilerError.forbiddenSourceLocator
        }
        guard !ContextSecretContentPolicy.containsSecretLikeContent(source) else {
            throw ContextMarkdownCompilerError.secretLikeContent
        }

        let fingerprint = embeddingProvider.modelFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fingerprint.isEmpty else {
            throw ContextMarkdownCompilerError.invalidModelFingerprint
        }

        // Hash version and filtered bytes so compiler or GROWTH-filter changes reach the store.
        let sourceHash = Self.sha256(
            Data("\(Self.compilerFormatVersion)\u{0}".utf8) + contextData
        )
        if let previous, previous.descriptor == descriptor,
           previous.sourceHash == sourceHash,
           Set(previous.atoms.map(\.id)).count == previous.atoms.count,
           previous.atoms.allSatisfy({
               $0.freshness == ContextFreshness(updatedAt: updatedAt)
                   && $0.embedding?.modelFingerprint == fingerprint
           }) {
            return previous
        }
        let documentName = Self.documentName(for: descriptor.canonicalLocator)
        let parsed = try parse(
            contextData,
            atomizingGeneratedUserFacts: Self.isGeneratedUserProjection(
                descriptor: descriptor,
                documentName: documentName
            )
        )
        let candidates = parsed.map { block in
            makeCandidate(
                block: block,
                descriptor: descriptor,
                documentName: documentName
            )
        }
        let priorAtoms = previous?.descriptor.id == descriptor.id ? (previous?.atoms ?? []) : []
        let matches = match(candidates: candidates, previous: priorAtoms)

        var anchorOrdinals: [String: Int] = [:]
        // Reserve matched identities before minting any new sibling identity.
        var assignedIDs = Set(matches.compactMap { $0.map { priorAtoms[$0].id } })
        // Matched prior IDs are reserved; only emitted IDs cannot be reused.
        var emittedIDs: Set<ContextAtomID> = []
        var atomIDs: [ContextAtomID] = []
        var embeddings: [ContextEmbedding?] = []
        var embeddingInputs: [String] = []
        var embeddingDraftIndices: [Int] = []

        for (index, candidate) in candidates.enumerated() {
            let matchedAtom = matches[index].map { priorAtoms[$0] }
            let semanticDigest = candidate.identityDigest
            let anchorKey = [
                candidate.kind.rawValue,
                candidate.shape.rawValue,
                Self.normalizedHeadingPath(candidate.block.headingPath).joined(separator: "/"),
                semanticDigest,
            ].joined(separator: "|")
            var anchorOrdinal = anchorOrdinals[anchorKey, default: 0]
            let atomID: ContextAtomID
            // Reuse each matched ID once per compile; duplicate matches mint distinct IDs.
            if let matchedAtom, !emittedIDs.contains(matchedAtom.id) {
                atomID = matchedAtom.id
                anchorOrdinals[anchorKey] = anchorOrdinal + 1
            } else {
                // Skip reserved IDs while preserving deterministic sibling ordinals.
                var minted: ContextAtomID
                repeat {
                    minted = ContextStableID.atom(
                        sourceID: descriptor.id,
                        kind: candidate.kind,
                        headingPath: Self.normalizedHeadingPath(candidate.block.headingPath),
                        blockAnchor: "\(candidate.shape.rawValue):\(semanticDigest):\(anchorOrdinal)"
                    )
                    anchorOrdinal += 1
                } while assignedIDs.contains(minted)
                atomID = minted
                anchorOrdinals[anchorKey] = anchorOrdinal
            }
            assignedIDs.insert(atomID)
            emittedIDs.insert(atomID)

            let reusableEmbedding: ContextEmbedding?
            if let matchedAtom,
               matchedAtom.embedding?.modelFingerprint == fingerprint,
               Self.semanticBody(matchedAtom.body) == candidate.semanticBody {
                reusableEmbedding = matchedAtom.embedding
            } else {
                reusableEmbedding = nil
            }

            atomIDs.append(atomID)
            embeddings.append(reusableEmbedding)
            if reusableEmbedding == nil {
                embeddingInputs.append(candidate.semanticBody)
                embeddingDraftIndices.append(index)
            }
        }

        if !embeddingInputs.isEmpty {
            let vectors = try await embeddingProvider.embed(embeddingInputs)
            guard vectors.count == embeddingInputs.count else {
                throw ContextMarkdownCompilerError.embeddingCountMismatch(
                    expected: embeddingInputs.count,
                    actual: vectors.count
                )
            }
            for (batchIndex, vector) in vectors.enumerated() {
                guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else {
                    throw ContextMarkdownCompilerError.invalidEmbedding(index: batchIndex)
                }
                embeddings[embeddingDraftIndices[batchIndex]] = ContextEmbedding(
                    modelFingerprint: fingerprint, values: vector
                )
            }
        }

        let drafts = candidates.enumerated().map { index, candidate in
            ContextAtomDraft(
                id: atomIDs[index],
                sourceID: descriptor.id,
                kind: candidate.kind,
                headingPath: candidate.block.headingPath,
                sourceRange: candidate.block.range,
                sourceHash: sourceHash,
                body: candidate.block.body,
                deterministicSummary: candidate.summary,
                authority: descriptor.authority,
                confidence: Self.confidence(for: descriptor),
                freshness: ContextFreshness(updatedAt: updatedAt),
                privacy: descriptor.privacy,
                permittedSurfaces: descriptor.permittedSurfaces,
                injectionPolicy: descriptor.injectionPolicy,
                contentRole: candidate.contentRole,
                entities: [ContextEntity(
                    kind: "document",
                    id: Self.normalizedToken(documentName),
                    label: documentName
                )],
                triggers: candidate.triggers,
                embedding: embeddings[index]
            )
        }

        return ContextCompiledSource(
            descriptor: descriptor,
            sourceHash: sourceHash,
            atoms: drafts
        )
    }

    public func compile(
        source: String,
        descriptor: ContextSourceDescriptor,
        previous: ContextCompiledSource? = nil,
        updatedAt: Date
    ) async throws -> ContextCompiledSource {
        try await compile(
            sourceData: Data(source.utf8),
            descriptor: descriptor,
            previous: previous,
            updatedAt: updatedAt
        )
    }
}

// MARK: - Classification and deterministic metadata

extension ContextMarkdownCompiler {
    struct Candidate: Sendable {
        let block: ParsedBlock
        let shape: BlockShape
        let kind: ContextAtomKind
        let contentRole: ContextContentRole
        let semanticBody: String
        let summary: String
        /// Ordinary identity uses the semantic body; generated facts use the projection key.
        /// Embedding reuse still requires the same semantic body.
        let identityDigest: String
        let triggers: [String]
    }

    private func makeCandidate(
        block: ParsedBlock,
        descriptor: ContextSourceDescriptor,
        documentName: String
    ) -> Candidate {
        let classification = Self.classification(
            descriptor: descriptor,
            documentName: documentName,
            block: block
        )
        let semantic = Self.semanticBody(block.body)
        let summarySource = Self.summaryText(for: block)
        let summary = Self.boundedUTF8(summarySource, maximumBytes: ContextMarkdownCompilerLimits.maxSummaryUTF8Bytes)
        return Candidate(
            block: block,
            shape: block.shape,
            kind: classification.kind,
            contentRole: classification.role,
            semanticBody: semantic,
            summary: summary,
            identityDigest: Self.identityDigest(for: block, summarySource: summarySource),
            triggers: Self.triggers(
                documentName: documentName,
                headingPath: block.headingPath,
                summary: summary,
                maximumCount: ContextMarkdownCompilerLimits.maxTriggersPerAtom,
                maximumBytes: ContextMarkdownCompilerLimits.maxTriggerUTF8Bytes
            )
        )
    }

    /// Does this source own a generated USER.md projection whose autogen body
    /// should be cut per bullet?
    private static func isGeneratedUserProjection(
        descriptor: ContextSourceDescriptor,
        documentName: String
    ) -> Bool {
        descriptor.kind == .persona && documentName.uppercased() == "USER.MD"
    }

    /// Generated USER.md identity uses the whole projection key, core and stamp; `match` preserves restamped IDs.
    private static func identityDigest(for block: ParsedBlock, summarySource: String) -> String {
        guard block.isGeneratedUserFact else {
            return ContextStableID.digest(parts: [semanticBody(block.body)])
        }
        let key = MemoryDisplayText.projectionJoinKey(summarySource)
        let content = key.isEmpty ? semanticBody(block.body) : key.description
        return ContextStableID.digest(parts: ["generated-user-fact", content])
    }

    private static func classification(
        descriptor: ContextSourceDescriptor,
        documentName: String,
        block: ParsedBlock
    ) -> (kind: ContextAtomKind, role: ContextContentRole) {
        let name = documentName.uppercased()
        switch descriptor.kind {
        case .persona:
            if name == "SOUL.MD" || name == "VOICE.MD" {
                return (.identity, .identity)
            }
            if name == "USER.MD" {
                // Generated facts stay .relationship; only manual prose can promote headings to .correction.
                if block.isGeneratedUserFact {
                    return (.relationship, .fact)
                }
                let headingTokens = Set(block.headingPath.flatMap(Self.tokens))
                if !headingTokens.isDisjoint(with: ["correction", "corrections", "boundary", "boundaries", "preference", "preferences"]) {
                    return (.correction, .fact)
                }
                return (.relationship, .fact)
            }
            if name == "MEMORY.MD" { return (.memory, .memory) }
            if name == "AGENTS.MD" {
                return block.shape == .paragraph ? (.instruction, .instruction) : (.procedure, .procedure)
            }
            if name == "GROWTH.MD" { return (.fact, .fact) }
            if descriptor.authority == .identity { return (.identity, .identity) }
            return block.shape == .paragraph ? (.instruction, .instruction) : (.procedure, .procedure)
        case .memory:
            return (.memory, .memory)
        case .skill:
            return (.procedure, .procedure)
        case .desk:
            return (.fact, .fact)
        case .dream:
            return (.evidence, .evidence)
        case .project:
            return (.project, .untrustedExternalData)
        case .capability:
            return (.capability, .fact)
        case .other:
            return descriptor.authority == .external
                ? (.evidence, .untrustedExternalData)
                : (.fact, .fact)
        }
    }

    private static func summaryText(for block: ParsedBlock) -> String {
        var lines = block.body.components(separatedBy: .newlines)
        if block.shape == .fence, lines.count > 1 {
            lines.removeFirst()
            if let last = lines.last,
               fenceOpening(Array(last.utf8)) != nil {
                lines.removeLast()
            }
        }
        if block.shape == .list {
            lines = lines.map { line in
                let bytes = Array(line.utf8)
                var cursor = 0
                while cursor < min(3, bytes.count), bytes[cursor] == 0x20 { cursor += 1 }
                if cursor < bytes.count, bytes[cursor] == 0x2D || bytes[cursor] == 0x2A || bytes[cursor] == 0x2B {
                    cursor += 1
                } else {
                    while cursor < bytes.count, (0x30...0x39).contains(bytes[cursor]) { cursor += 1 }
                    if cursor < bytes.count, bytes[cursor] == 0x2E || bytes[cursor] == 0x29 { cursor += 1 }
                }
                while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 { cursor += 1 }
                return String(decoding: bytes[cursor...], as: UTF8.self)
            }
        }
        return semanticBody(lines.joined(separator: " "))
    }

    private static func triggers(
        documentName: String,
        headingPath: [String],
        summary: String,
        maximumCount: Int,
        maximumBytes: Int
    ) -> [String] {
        triggerTokens([documentName] + headingPath + [summary], minimumLength: 2,
            maximumCount: maximumCount, excluding: triggerStopwords, tokens: tokens,
            bound: { boundedUTF8($0, maximumBytes: maximumBytes, appendEllipsis: false) })
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static let triggerStopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "has", "in", "is",
        "it", "of", "on", "or", "that", "the", "this", "to", "was", "will", "with",
    ]

    static func semanticBody(_ body: String) -> String {
        body.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func normalizedHeadingPath(_ path: [String]) -> [String] {
        path.map { semanticBody($0).lowercased() }
    }

    private static func normalizedToken(_ value: String) -> String {
        let joined = tokens(value).joined(separator: "-")
        return joined.isEmpty ? "document" : joined
    }

    private static func confidence(for descriptor: ContextSourceDescriptor) -> Double {
        switch descriptor.authority {
        case .identity, .explicitCorrection, .canonical: 1
        case .approved: 0.95
        case .inferred: 0.8
        case .external: 0.7
        }
    }

    private static func boundedUTF8(
        _ value: String,
        maximumBytes: Int,
        appendEllipsis: Bool = true
    ) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        let suffix = appendEllipsis && maximumBytes >= 3 ? "..." : ""
        let contentLimit = maximumBytes - suffix.utf8.count
        var output = ""
        var used = 0
        for character in value {
            let size = String(character).utf8.count
            if used + size > contentLimit { break }
            output.append(character)
            used += size
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }
}

// MARK: - Input safety

private extension ContextMarkdownCompiler {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func documentName(for locator: String) -> String {
        let name = (locator as NSString).lastPathComponent
        return name.isEmpty ? locator : name
    }

    static func isForbiddenLocator(_ locator: String) -> Bool {
        let normalized = locator.replacingOccurrences(of: "\\", with: "/").lowercased()
        let components = normalized.split(separator: "/").map(String.init)
        let name = components.last ?? normalized
        if components.dropLast().contains(where: { $0 == "secrets" || $0 == "credentials" }) {
            return true
        }
        if name == ".env" || name.hasPrefix(".env.") { return true }
        if ["credentials.json", "credential.json", "tokens.json", "token.json", "auth.json"].contains(name) {
            return true
        }
        return ["key", "pem", "p12", "pfx"].contains((name as NSString).pathExtension)
    }

}
