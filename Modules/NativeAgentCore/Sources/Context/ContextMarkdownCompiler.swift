import CryptoKit
import Foundation
import NativeAgentCore

/// One fail-closed secret-shape policy for material entering derived context.
/// Callers may reject content; this policy never redacts or authorizes it.
public enum ContextSecretContentPolicy {
    public static func containsSecretLikeContent(_ source: String) -> Bool {
        secretPatterns.contains { pattern in
            source.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    private static let secretPatterns = [
        #"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----"#,
        #"\bsk-(?:ant-)?[A-Za-z0-9_-]{20,}\b"#,
        #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#,
        #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#,
        #"\bBearer[ \t]+[A-Za-z0-9._~+/=-]{20,}"#,
        #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#,
        #"(?m)^\s*(?:api[_ -]?key|access[_ -]?token|auth[_ -]?token|password|passwd|client[_ -]?secret)\s*[:=]\s*[\"']?[A-Za-z0-9_./+~=-]{12,}"#,
    ]
}

public protocol ContextMarkdownEmbeddingProvider: Sendable {
    var modelFingerprint: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public struct ContextMarkdownCompilerLimits: Equatable, Sendable {
    public let maxSourceUTF8Bytes: Int
    public let maxAtomUTF8Bytes: Int
    public let maxSummaryUTF8Bytes: Int
    public let maxTriggerUTF8Bytes: Int
    public let maxTriggersPerAtom: Int

    public init(
        maxSourceUTF8Bytes: Int = 2 * 1_024 * 1_024,
        maxAtomUTF8Bytes: Int = 64 * 1_024,
        maxSummaryUTF8Bytes: Int = 320,
        maxTriggerUTF8Bytes: Int = 64,
        maxTriggersPerAtom: Int = 12
    ) {
        self.maxSourceUTF8Bytes = maxSourceUTF8Bytes
        self.maxAtomUTF8Bytes = maxAtomUTF8Bytes
        self.maxSummaryUTF8Bytes = maxSummaryUTF8Bytes
        self.maxTriggerUTF8Bytes = maxTriggerUTF8Bytes
        self.maxTriggersPerAtom = maxTriggersPerAtom
    }
}

public enum ContextMarkdownCompilerError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidLimits
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
        case .invalidLimits:
            "context Markdown compiler limits must all be positive"
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
    /// Compiled-output format version, folded into `sourceHash`. Bump when a
    /// compiler change alters the ATOMS produced for identical input bytes —
    /// otherwise the coordinator's hash-gated store update drops the new shape
    /// forever. v2 = per-fact USER.md autogen atomization (2026-07-25).
    /// v3 = autogen marker comments no longer emit atoms (2026-08-13): the two
    /// pure-HTML-comment paragraphs compiled to adaptive candidates whose
    /// static priors ranked #1-2 of the whole store — noise competing for
    /// packet slots.
    static let compilerFormatVersion = "3"

    /// True when a parsed block's body is exactly one autogen marker comment
    /// (modulo surrounding whitespace). Such blocks are structural delimiters
    /// owned by `UserMDAutogenMarkers`; they must never become atoms.
    /// Internal (not in the private parsing extension) so the atomization
    /// tests can pin the contract via @testable import.
    static func isAutogenMarkerBlock(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == UserMDAutogenMarkers.bodyStart
            || trimmed == UserMDAutogenMarkers.bodyEnd
            || trimmed == UserMDAutogenMarkers.preambleStart
            || trimmed == UserMDAutogenMarkers.preambleEnd
    }
    private let embeddingProvider: any ContextMarkdownEmbeddingProvider
    public let limits: ContextMarkdownCompilerLimits

    public init(
        embeddingProvider: any ContextMarkdownEmbeddingProvider,
        limits: ContextMarkdownCompilerLimits = ContextMarkdownCompilerLimits()
    ) {
        self.embeddingProvider = embeddingProvider
        self.limits = limits
    }

    public func compile(
        sourceData: Data,
        descriptor: ContextSourceDescriptor,
        previous: ContextCompiledSource? = nil,
        updatedAt: Date
    ) async throws -> ContextCompiledSource {
        try validateLimits()
        guard sourceData.count <= limits.maxSourceUTF8Bytes else {
            throw ContextMarkdownCompilerError.sourceTooLarge(
                actualBytes: sourceData.count,
                maximumBytes: limits.maxSourceUTF8Bytes
            )
        }
        guard let source = String(data: sourceData, encoding: .utf8) else {
            throw ContextMarkdownCompilerError.malformedUTF8
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

        // The COMPILER FORMAT VERSION is part of the hash (2026-07-25). The
        // coordinator only accepts a recompile into the store when sourceHash
        // changes — hashing content alone meant a compiler behavior change
        // (e.g. v2's per-fact USER.md atomization) could NEVER reach the live
        // generation until the document's bytes happened to change: compile
        // produced the new atoms every reconcile and the store silently
        // dropped them. Bump this version whenever compiled OUTPUT shape
        // changes for identical input; the cost is one full refresh per
        // source, with embeddings still reused via content matching.
        let sourceHash = Self.sha256(
            Data("\(Self.compilerFormatVersion)\u{0}".utf8) + sourceData
        )
        let documentName = Self.documentName(for: descriptor.canonicalLocator)
        let parsed = try parse(
            sourceData,
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
        // Every ID this compile will hand out. Seeded with the IDs inherited
        // from matched prior atoms, because those were minted at a HISTORICAL
        // ordinal that this pass does not reproduce: two blocks sharing an
        // anchor key, one matched and one new, could otherwise mint the ID the
        // matched one already holds and put two atoms with the same
        // `ContextAtomID` in one generation. Reachable in the generated
        // USER.md body, where sibling facts routinely share an anchor key.
        var assignedIDs = Set(matches.compactMap { $0.map { priorAtoms[$0].id } })
        // IDs actually emitted THIS compile. Distinct from `assignedIDs`, whose
        // seed also holds every matched prior ID — the seed cannot distinguish
        // "reserved for a later match" from "already emitted", which is exactly
        // the distinction the contamination guard below needs.
        var emittedIDs: Set<ContextAtomID> = []
        var drafts: [ContextAtomDraft] = []
        drafts.reserveCapacity(candidates.count)
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
            // Contamination guard (gpt-5.5 final review MED, 2026-07-25): if a
            // PRIOR generation ever stored two atoms sharing one ID (the exact
            // residue the bare-core date-sibling defect could have written),
            // unconditional matched-reuse re-emits the duplicate forever. A
            // matched ID is reusable only the FIRST time it appears this
            // compile; a second matched candidate carrying the same prior ID
            // falls through to minting, which self-heals the generation.
            if let matchedAtom, !emittedIDs.contains(matchedAtom.id) {
                atomID = matchedAtom.id
                anchorOrdinals[anchorKey] = anchorOrdinal + 1
            } else {
                // Advance past any ordinal whose ID is already spoken for. The
                // ordinal still climbs deterministically from the same start,
                // so a document whose blocks already mint distinct IDs keeps
                // minting exactly the IDs it had.
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

            let draft = ContextAtomDraft(
                id: atomID,
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
                embedding: reusableEmbedding
            )
            drafts.append(draft)
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
                let draftIndex = embeddingDraftIndices[batchIndex]
                drafts[draftIndex] = Self.replacingEmbedding(
                    in: drafts[draftIndex],
                    with: ContextEmbedding(modelFingerprint: fingerprint, values: vector)
                )
            }
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

    private func validateLimits() throws {
        guard limits.maxSourceUTF8Bytes > 0,
              limits.maxAtomUTF8Bytes > 0,
              limits.maxSummaryUTF8Bytes > 0,
              limits.maxTriggerUTF8Bytes > 0,
              limits.maxTriggersPerAtom > 0 else {
            throw ContextMarkdownCompilerError.invalidLimits
        }
    }
}

// MARK: - Markdown structure

private extension ContextMarkdownCompiler {
    enum BlockShape: String, Sendable {
        case paragraph
        case list
        case fence
    }

    struct SourceLine: Sendable {
        let start: Int
        let contentEnd: Int
        let end: Int
    }

    struct ParsedBlock: Sendable {
        let shape: BlockShape
        let headingPath: [String]
        let range: ContextSourceRange
        let body: String
        /// True only for a single bullet split out of the generated USER.md
        /// autogen region. Drives content-keyed atom identity (see
        /// `Candidate.identityDigest`) — nothing else branches on it.
        var isGeneratedUserFact: Bool = false
    }

    struct Candidate: Sendable {
        let block: ParsedBlock
        let shape: BlockShape
        let kind: ContextAtomKind
        let contentRole: ContextContentRole
        let semanticBody: String
        let summary: String
        /// What the atom's stable ID is anchored to. Ordinary blocks anchor on
        /// their whitespace-collapsed body; generated USER.md facts anchor on
        /// the `MemoryDisplayText.projectionJoinKey` core, so a bullet that is
        /// merely restamped by MemoryV2 keeps its atom (and its embedding is
        /// still recomputed, because reuse is keyed on the exact body).
        let identityDigest: String
        let triggers: [String]
    }

    func parse(
        _ data: Data,
        atomizingGeneratedUserFacts: Bool = false
    ) throws -> [ParsedBlock] {
        let bytes = [UInt8](data)
        let lines = Self.lines(in: bytes)
        let generatedBody = atomizingGeneratedUserFacts
            ? Self.generatedUserBodyByteRange(bytes: bytes, lines: lines)
            : nil
        var headings: [String?] = Array(repeating: nil, count: 6)
        var blocks: [ParsedBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let lineBytes = Array(bytes[line.start..<line.contentEnd])
            if Self.isBlank(lineBytes) {
                index += 1
                continue
            }
            if let heading = Self.atxHeading(lineBytes) {
                headings[heading.level - 1] = heading.title
                if heading.level < headings.count {
                    for deeper in heading.level..<headings.count { headings[deeper] = nil }
                }
                index += 1
                continue
            }

            let startIndex = index
            let shape: BlockShape
            if let fence = Self.fenceOpening(lineBytes) {
                shape = .fence
                index += 1
                while index < lines.count {
                    let candidate = Array(bytes[lines[index].start..<lines[index].contentEnd])
                    index += 1
                    if Self.isFenceClosing(candidate, opening: fence) { break }
                }
            } else if Self.isListStart(lineBytes) {
                shape = .list
                // A list that begins inside the autogen region ends at the
                // region boundary. Without this the closing marker — which is
                // neither blank, heading, nor fence — is swallowed by the last
                // bullet, and that bullet's atom carries a stray marker line.
                let generatedLimit = generatedBody
                    .flatMap { $0.contains(lines[index].start) ? $0.upperBound : nil }
                    ?? Int.max
                index += 1
                while index < lines.count, lines[index].start < generatedLimit {
                    let candidate = Array(bytes[lines[index].start..<lines[index].contentEnd])
                    if Self.isBlank(candidate)
                        || Self.atxHeading(candidate) != nil
                        || Self.fenceOpening(candidate) != nil {
                        break
                    }
                    index += 1
                }
            } else {
                shape = .paragraph
                index += 1
                while index < lines.count {
                    let candidate = Array(bytes[lines[index].start..<lines[index].contentEnd])
                    if Self.isBlank(candidate)
                        || Self.atxHeading(candidate) != nil
                        || Self.fenceOpening(candidate) != nil
                        || Self.isListStart(candidate) {
                        break
                    }
                    index += 1
                }
            }

            // The generated USER.md fact list is ONE contiguous Markdown list,
            // so it compiled to ONE ~15 KB atom that could never fit the 6 KB
            // dynamic packet budget — the packet could only ever admit its
            // 320-byte deterministic summary, i.e. roughly one of forty-odd
            // user facts, chosen by where the truncation landed. Split it per
            // bullet so individual facts compete for packet slots on their own
            // relevance. Only the autogen region is split; manual USER.md
            // prose and every other document keep whole-block atoms.
            let isGeneratedFact = shape == .list
                && generatedBody?.contains(lines[startIndex].start) == true
            let itemSpans = isGeneratedFact
                ? Self.topLevelListItemSpans(
                    bytes: bytes,
                    lines: lines,
                    from: startIndex,
                    to: index
                )
                : [(first: startIndex, last: index - 1)]

            for span in itemSpans {
                let first = lines[span.first]
                let last = lines[span.last]
                let bodyData = Data(bytes[first.start..<last.contentEnd])
                guard let body = String(data: bodyData, encoding: .utf8) else {
                    throw ContextMarkdownCompilerError.malformedUTF8
                }
                // Autogen marker comments are cut boundaries, not content —
                // as atoms they carried near-top static priors (tiny body →
                // ~zero cost penalty) while saying nothing. Never emit them.
                if Self.isAutogenMarkerBlock(body) { continue }
                guard bodyData.count <= limits.maxAtomUTF8Bytes else {
                    throw ContextMarkdownCompilerError.atomTooLarge(
                        index: blocks.count,
                        actualBytes: bodyData.count,
                        maximumBytes: limits.maxAtomUTF8Bytes
                    )
                }
                blocks.append(ParsedBlock(
                    shape: shape,
                    headingPath: headings.compactMap { $0 },
                    range: ContextSourceRange(utf8Start: first.start, utf8End: last.contentEnd),
                    body: body,
                    isGeneratedUserFact: isGeneratedFact
                ))
            }
        }
        return blocks
    }

    /// Byte range strictly between the autogen markers, or nil when the
    /// document does not carry exactly one well-formed pair. Deliberately
    /// tolerant of a manual preamble ahead of the start marker: this only
    /// decides *where atoms are cut*, never whether USER.md is a pure
    /// projection — that stricter question belongs to
    /// `ContextFlowCoordinator.generatedUserFacts`, which owns suppression.
    static func generatedUserBodyByteRange(
        bytes: [UInt8],
        lines: [SourceLine]
    ) -> Range<Int>? {
        let start = Array(UserMDAutogenMarkers.bodyStart.utf8)
        let end = Array(UserMDAutogenMarkers.bodyEnd.utf8)
        var startOffset: Int?
        var endOffset: Int?
        for line in lines {
            let content = Array(bytes[line.start..<line.contentEnd])
            let trimmed = trimmingASCIIWhitespace(content)
            if trimmed == start {
                guard startOffset == nil else { return nil }
                startOffset = line.end
            } else if trimmed == end {
                guard endOffset == nil else { return nil }
                endOffset = line.start
            }
        }
        guard let startOffset, let endOffset, startOffset <= endOffset else { return nil }
        return startOffset..<endOffset
    }

    static func trimmingASCIIWhitespace(_ bytes: [UInt8]) -> [UInt8] {
        var lower = 0
        var upper = bytes.count
        while lower < upper, bytes[lower] == 0x20 || bytes[lower] == 0x09 { lower += 1 }
        while upper > lower, bytes[upper - 1] == 0x20 || bytes[upper - 1] == 0x09 { upper -= 1 }
        return Array(bytes[lower..<upper])
    }

    /// Line spans of the top-level items in the list block `[from, to)`.
    ///
    /// A new item starts only at a marker in COLUMN ZERO. Indented markers and
    /// non-marker lines are continuations and stay attached to the item above
    /// them, so a nested bullet or a wrapped fact never becomes its own atom.
    /// Any lines before the first column-zero marker (there should be none —
    /// the block began at a list start) form their own leading span rather
    /// than being dropped.
    static func topLevelListItemSpans(
        bytes: [UInt8],
        lines: [SourceLine],
        from: Int,
        to: Int
    ) -> [(first: Int, last: Int)] {
        var spans: [(first: Int, last: Int)] = []
        for lineIndex in from..<to {
            let content = Array(bytes[lines[lineIndex].start..<lines[lineIndex].contentEnd])
            let startsItem = lineIndex == from
                || (content.first.map { $0 != 0x20 && $0 != 0x09 } ?? false) && isListStart(content)
            if startsItem {
                spans.append((lineIndex, lineIndex))
            } else if !spans.isEmpty {
                spans[spans.count - 1].last = lineIndex
            }
        }
        return spans.isEmpty ? [(from, to - 1)] : spans
    }

    static func lines(in bytes: [UInt8]) -> [SourceLine] {
        var result: [SourceLine] = []
        var start = 0
        while start < bytes.count {
            var cursor = start
            while cursor < bytes.count, bytes[cursor] != 0x0A, bytes[cursor] != 0x0D {
                cursor += 1
            }
            let contentEnd = cursor
            if cursor < bytes.count {
                if bytes[cursor] == 0x0D, cursor + 1 < bytes.count, bytes[cursor + 1] == 0x0A {
                    cursor += 2
                } else {
                    cursor += 1
                }
            }
            result.append(SourceLine(start: start, contentEnd: contentEnd, end: cursor))
            start = cursor
        }
        return result
    }

    static func isBlank(_ bytes: [UInt8]) -> Bool {
        bytes.allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    static func atxHeading(_ bytes: [UInt8]) -> (level: Int, title: String)? {
        var cursor = 0
        while cursor < min(3, bytes.count), bytes[cursor] == 0x20 { cursor += 1 }
        let markerStart = cursor
        while cursor < bytes.count, bytes[cursor] == 0x23 { cursor += 1 }
        let level = cursor - markerStart
        guard (1...6).contains(level) else { return nil }
        guard cursor == bytes.count || bytes[cursor] == 0x20 || bytes[cursor] == 0x09 else {
            return nil
        }
        while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 { cursor += 1 }
        var end = bytes.count
        while end > cursor, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 { end -= 1 }
        var hashStart = end
        while hashStart > cursor, bytes[hashStart - 1] == 0x23 { hashStart -= 1 }
        if hashStart < end,
           hashStart == cursor || bytes[hashStart - 1] == 0x20 || bytes[hashStart - 1] == 0x09 {
            end = hashStart
            while end > cursor, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 { end -= 1 }
        }
        let title = String(decoding: bytes[cursor..<end], as: UTF8.self)
        return (level, title)
    }

    static func fenceOpening(_ bytes: [UInt8]) -> (marker: UInt8, count: Int)? {
        var cursor = 0
        while cursor < min(3, bytes.count), bytes[cursor] == 0x20 { cursor += 1 }
        guard cursor < bytes.count, bytes[cursor] == 0x60 || bytes[cursor] == 0x7E else {
            return nil
        }
        let marker = bytes[cursor]
        let start = cursor
        while cursor < bytes.count, bytes[cursor] == marker { cursor += 1 }
        let count = cursor - start
        return count >= 3 ? (marker, count) : nil
    }

    static func isFenceClosing(
        _ bytes: [UInt8],
        opening: (marker: UInt8, count: Int)
    ) -> Bool {
        var cursor = 0
        while cursor < min(3, bytes.count), bytes[cursor] == 0x20 { cursor += 1 }
        let start = cursor
        while cursor < bytes.count, bytes[cursor] == opening.marker { cursor += 1 }
        guard cursor - start >= opening.count else { return false }
        return bytes[cursor...].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    static func isListStart(_ bytes: [UInt8]) -> Bool {
        var cursor = 0
        while cursor < min(3, bytes.count), bytes[cursor] == 0x20 { cursor += 1 }
        guard cursor < bytes.count else { return false }
        if bytes[cursor] == 0x2D || bytes[cursor] == 0x2A || bytes[cursor] == 0x2B {
            cursor += 1
            return cursor < bytes.count && (bytes[cursor] == 0x20 || bytes[cursor] == 0x09)
        }
        let digitStart = cursor
        while cursor < bytes.count,
              cursor - digitStart < 9,
              (0x30...0x39).contains(bytes[cursor]) {
            cursor += 1
        }
        guard cursor > digitStart,
              cursor < bytes.count,
              bytes[cursor] == 0x2E || bytes[cursor] == 0x29 else {
            return false
        }
        cursor += 1
        return cursor < bytes.count && (bytes[cursor] == 0x20 || bytes[cursor] == 0x09)
    }
}

// MARK: - Classification and deterministic metadata

private extension ContextMarkdownCompiler {
    func makeCandidate(
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
        let summary = Self.boundedUTF8(summarySource, maximumBytes: limits.maxSummaryUTF8Bytes)
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
                maximumCount: limits.maxTriggersPerAtom,
                maximumBytes: limits.maxTriggerUTF8Bytes
            )
        )
    }

    /// Does this source own a generated USER.md projection whose autogen body
    /// should be cut per bullet?
    static func isGeneratedUserProjection(
        descriptor: ContextSourceDescriptor,
        documentName: String
    ) -> Bool {
        descriptor.kind == .persona && documentName.uppercased() == "USER.MD"
    }

    /// Content key an atom's stable ID is anchored to.
    ///
    /// For a generated USER.md fact this is the `MemoryDisplayText.Key` — the
    /// same normalization family the precoverage join uses — rather than the
    /// bullet's raw text: the key is whitespace-canonical and it separates the
    /// bullet marker and list indentation from the fact itself, so identity
    /// tracks the FACT and not its rendering.
    ///
    /// It is the whole key (core AND stamp), never the bare core. Anchoring on
    /// the core alone reads as the stronger choice — a restamped fact would
    /// keep its ID by construction — but it merges records that genuinely
    /// differ, which is the exact mistake `MemoryDisplayText.Key`'s own doc
    /// comment records: `"2026-08-01 09:00 Dentist appointment downtown."` and
    /// `"2026-09-01 09:00 Dentist appointment downtown."` share a core. Two
    /// such bullets then rely on `anchorOrdinal` alone to stay apart, and the
    /// ordinal is POSITIONAL — when one of them is matched to a prior atom and
    /// the other is newly minted, the new one can mint the ID the matched one
    /// already holds. Restamp stability does not need that trade: `match`
    /// pairs a restamped bullet to its prior atom on similarity and hands over
    /// the existing ID before this digest is ever consulted.
    static func identityDigest(for block: ParsedBlock, summarySource: String) -> String {
        guard block.isGeneratedUserFact else {
            return ContextStableID.digest(parts: [semanticBody(block.body)])
        }
        let key = MemoryDisplayText.projectionJoinKey(summarySource)
        let content = key.isEmpty ? semanticBody(block.body) : key.description
        return ContextStableID.digest(parts: ["generated-user-fact", content])
    }

    static func classification(
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
                // Generated facts are ALWAYS .relationship (gpt-5.5 final
                // review MED, 2026-07-25): heading-token promotion to
                // .correction would make every generated fact mandatory
                // (.explicitCorrection authority) — with 43+ atoms that
                // exceeds the mandatory budget and THROWS the whole turn. A
                // generator heading mentioning "preferences" must not be able
                // to detonate selection; manual USER.md prose keeps the
                // promotion.
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
        case .dream, .standingView:
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

    static func summaryText(for block: ParsedBlock) -> String {
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

    static func triggers(
        documentName: String,
        headingPath: [String],
        summary: String,
        maximumCount: Int,
        maximumBytes: Int
    ) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        let orderedText = [documentName] + headingPath + [summary]
        for text in orderedText {
            for token in tokens(text) where !triggerStopwords.contains(token) {
                let bounded = boundedUTF8(token, maximumBytes: maximumBytes, appendEllipsis: false)
                guard bounded.count >= 2, seen.insert(bounded).inserted else { continue }
                result.append(bounded)
                if result.count == maximumCount { return result }
            }
        }
        return result
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static let triggerStopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "has", "in", "is",
        "it", "of", "on", "or", "that", "the", "this", "to", "was", "will", "with",
    ]

    static func semanticBody(_ body: String) -> String {
        body.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func normalizedHeadingPath(_ path: [String]) -> [String] {
        path.map { semanticBody($0).lowercased() }
    }

    static func normalizedToken(_ value: String) -> String {
        let joined = tokens(value).joined(separator: "-")
        return joined.isEmpty ? "document" : joined
    }

    static func confidence(for descriptor: ContextSourceDescriptor) -> Double {
        switch descriptor.authority {
        case .identity, .explicitCorrection, .canonical: 1
        case .approved: 0.95
        case .inferred: 0.8
        case .external: 0.7
        }
    }

    static func boundedUTF8(
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

// MARK: - Incremental identity and embeddings

private extension ContextMarkdownCompiler {
    func match(candidates: [Candidate], previous: [ContextAtomDraft]) -> [Int?] {
        var matches = [Int?](repeating: nil, count: candidates.count)
        var used: Set<Int> = []
        let previousOrder = previous.indices.sorted {
            previous[$0].sourceRange.utf8Start < previous[$1].sourceRange.utf8Start
        }

        func assignExact(requireSameHeading: Bool) {
            for candidateIndex in candidates.indices where matches[candidateIndex] == nil {
                let candidate = candidates[candidateIndex]
                let desiredHeading = Self.normalizedHeadingPath(candidate.block.headingPath)
                if let priorIndex = previousOrder.first(where: { priorIndex in
                    guard !used.contains(priorIndex) else { return false }
                    let prior = previous[priorIndex]
                    return prior.kind == candidate.kind
                        && Self.blockShape(of: prior.body) == candidate.shape
                        && Self.semanticBody(prior.body) == candidate.semanticBody
                        && (!requireSameHeading || Self.normalizedHeadingPath(prior.headingPath) == desiredHeading)
                }) {
                    matches[candidateIndex] = priorIndex
                    used.insert(priorIndex)
                }
            }
        }

        assignExact(requireSameHeading: true)
        assignExact(requireSameHeading: false)

        for candidateIndex in candidates.indices where matches[candidateIndex] == nil {
            let candidate = candidates[candidateIndex]
            let desiredHeading = Self.normalizedHeadingPath(candidate.block.headingPath)
            var best: (index: Int, score: Double)?
            for priorIndex in previousOrder where !used.contains(priorIndex) {
                let prior = previous[priorIndex]
                guard prior.kind == candidate.kind,
                      Self.blockShape(of: prior.body) == candidate.shape,
                      Self.normalizedHeadingPath(prior.headingPath) == desiredHeading else {
                    continue
                }
                let score = Self.similarity(Self.semanticBody(prior.body), candidate.semanticBody)
                guard score >= 0.45 else { continue }
                if best == nil || score > best!.score {
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

    static func blockShape(of body: String) -> BlockShape {
        let firstLine = body.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? body
        let bytes = Array(firstLine.utf8)
        if fenceOpening(bytes) != nil { return .fence }
        if isListStart(bytes) { return .list }
        return .paragraph
    }

    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        if lhs == rhs { return 1 }
        let leftTokens = Set(tokens(lhs))
        let rightTokens = Set(tokens(rhs))
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

    static func replacingEmbedding(
        in atom: ContextAtomDraft,
        with embedding: ContextEmbedding
    ) -> ContextAtomDraft {
        ContextAtomDraft(
            id: atom.id,
            sourceID: atom.sourceID,
            kind: atom.kind,
            headingPath: atom.headingPath,
            sourceRange: atom.sourceRange,
            sourceHash: atom.sourceHash,
            body: atom.body,
            deterministicSummary: atom.deterministicSummary,
            authority: atom.authority,
            confidence: atom.confidence,
            freshness: atom.freshness,
            privacy: atom.privacy,
            permittedSurfaces: atom.permittedSurfaces,
            injectionPolicy: atom.injectionPolicy,
            contentRole: atom.contentRole,
            entities: atom.entities,
            triggers: atom.triggers,
            activation: atom.activation,
            recentUsefulness: atom.recentUsefulness,
            decayState: atom.decayState,
            embedding: embedding
        )
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
