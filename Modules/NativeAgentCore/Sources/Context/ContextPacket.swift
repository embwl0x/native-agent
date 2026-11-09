import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ContextPacket.swift` | Context packet, expandable pointers, safe representation leads and retained memory roots |
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
    /// Carry the summary with its body so renderers can lead with the rule without a second store read; normalize blank summaries to nil for all readers.
    public let summary: String?
    /// Only a memory's recorded timestamp supports an age tag; missing source time claims no age.
    public let recordedAt: Date?
    /// A memory's roots, from the same atom as its text; other atoms carry none.
    public let roots: [MemoryRoot]?
    /// Untrusted sources of the selected text, retained from its exact atom.
    public let untrustedSources: [String]?

    public init(
        pointer: ContextAtomPointer,
        text: String,
        representation: ContextPacketRepresentation,
        mandatory: Bool,
        summary: String? = nil,
        recordedAt: Date? = nil,
        roots: [MemoryRoot]? = nil,
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
        self.roots = roots
        self.untrustedSources = untrustedSources
    }
    /// Carry recorded time and roots from the same atom as the text.
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
            roots: ContextMemoryLead.roots(for: atom.draft),
            untrustedSources: ContextMemoryLead.untrustedSources(for: atom.draft)
        )
    }
}
extension ContextPacketItem {
    /// Omitted content is expandable; a whole body never needs its own pointer.
    public func isExpandable(thresholdChars: Int) -> Bool {
        representation == .deterministicSummary || expansionLead(thresholdChars: thresholdChars) != nil
    }
    /// The renderer's lead, only when it saves text. Empty means pointer-only.
    public func expansionLead(thresholdChars: Int) -> String? {
        guard thresholdChars > 0, text.count > thresholdChars else { return nil }
        let summary = self.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = summary.flatMap { $0.isEmpty ? nil : $0 } ?? text
        // Memory keeps its complete decision clause; other atoms use safe sentences/words.
        let lead = pointer.kind == .memory || pointer.kind == .correction
            ? source : Self.firstSentences(of: source, upTo: 240)
        return lead.count < text.count ? lead : nil
    }
    /// Never cut inside inline code or a URL; an unbroken token has no safe lead.
    private static func firstSentences(of text: String, upTo limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0 else { return "" }
        guard trimmed.count > limit else { return trimmed }
        let window = String(trimmed.prefix(limit))

        var lastSentenceBoundary: String.Index?
        var lastSafeWhitespace: String.Index?
        var insideCodeSpan = false
        var tokenStart = window.startIndex
        var index = window.startIndex
        while index < window.endIndex {
            let character = window[index]
            let next = window.index(after: index)
            if character == "`" {
                insideCodeSpan.toggle()
            } else if character.isWhitespace {
                if !insideCodeSpan { lastSafeWhitespace = index }
                tokenStart = next
            } else if character == "." || character == "!" || character == "?" {
                let endsToken = next == window.endIndex || window[next].isWhitespace
                // A scheme in the token means its terminator may belong to the URL.
                let tokenIsURL = window[tokenStart..<next].contains("://")
                if endsToken, !insideCodeSpan, !tokenIsURL {
                    lastSentenceBoundary = next
                }
            }
            index = next
        }
        if let lastSentenceBoundary {
            let sentence = String(window[window.startIndex..<lastSentenceBoundary])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { return sentence }
        }
        if let lastSafeWhitespace {
            let words = String(window[window.startIndex..<lastSafeWhitespace])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { return words }
        }
        return ""
    }
}
public struct ContextPacket: Codable, Equatable, Sendable {
    public let generationID: Int64
    public let sourceFingerprint: String
    public let selectedItems: [ContextPacketItem]
    public let expandablePointers: [ContextAtomPointer]
    public let degradedSources: [ContextDegradedSourceNotice]
    /// Selection-time accounting, retained when verification excludes items.
    public let budget: ContextBudgetUsage
    /// Original selection evidence; outcome feedback retains these IDs while serve feedback credits only the verified delivered items.
    public let receipt: ContextSelectionReceipt

    public var characterCount: Int { budget.usedCharacters }
}
