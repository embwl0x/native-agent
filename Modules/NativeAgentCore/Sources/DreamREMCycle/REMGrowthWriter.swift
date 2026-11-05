import Foundation
import PersistenceCore
import PersonaEngine

// Blueprint: | `REMGrowthWriter.swift` | REMGrowthWriter owner. |

// Preserve approved text and authored headings; do not derive new headings from lesson prose.
public enum REMGrowthWriter {

    public struct InvalidLesson: Error, LocalizedError {
        public let reason: String
        public var errorDescription: String? {
            "REM growth lesson refused: \(reason)"
        }
    }

    /// Match only standalone line/document boundaries so a longer paragraph cannot count as an approved entry.
    public static func containsEntryParagraph(_ body: String, _ text: String) -> Bool {
        !entryParagraphRanges(body, text).isEmpty
    }

    static func entryParagraphRanges(_ body: String, _ text: String) -> [Range<String.Index>] {
        if text.isEmpty {
            return (Array(body.indices) + [body.endIndex]).filter {
                ($0 == body.startIndex || body[body.index(before: $0)] == "\n") && ($0 == body.endIndex || body[$0] == "\n")
            }.map { $0..<$0 }
        }
        var ranges: [Range<String.Index>] = []
        var searchFrom = body.startIndex
        while let range = body.range(of: text, range: searchFrom..<body.endIndex) {
            if (range.lowerBound == body.startIndex || body[body.index(before: range.lowerBound)] == "\n"),
               (range.upperBound == body.endIndex || body[range.upperBound] == "\n") { ranges.append(range) }
            // Overlapping matches may contain another standalone paragraph.
            searchFrom = body.index(after: range.lowerBound)
        }
        return ranges
    }

    /// Hold the shared GROWTH lock across checked read and append; exact existing paragraphs make retries idempotent.
    /// Missing or unreadable GROWTH fails before writing so approval cannot flip without saved text.
    @discardableResult
    public static func appendApprovedLesson(
        personaRoot: URL,
        proposalText: String
    ) async throws -> Bool {
        let text = proposalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw InvalidLesson(reason: "empty lesson") }
        // Recheck passage bounds at the write boundary because pending approvals may predate them.
        if let reason = REMProposalStore.growthPassageRefusal(text) {
            throw InvalidLesson(reason: reason)
        }
        let growth = personaRoot.appendingPathComponent("GROWTH.md")
        return try await SwiftNativePersistenceCore.withFileLock(growth) {
            let body: String
            do {
                body = try SwiftNativePersonaEngine.readPersonaDocument(at: growth)
            } catch {
                throw PersonaEngineError.rootUnreadable(
                    reason: "cannot read \(growth.path): \(error.localizedDescription). Repair or restore this document before continuing."
                )
            }
            if containsEntryParagraph(body, text) { return false }
            let entry = "\n\(text)\n"
            let rebuilt = body.hasSuffix("\n") ? body + entry : body + "\n" + entry
            try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(rebuilt.utf8), to: growth)
            return true
        }
    }
}
