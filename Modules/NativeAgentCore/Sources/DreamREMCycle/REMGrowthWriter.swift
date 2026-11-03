import Foundation
import PersistenceCore
import PersonaEngine

// Blueprint: | `REMGrowthWriter.swift` | Exact standalone-paragraph ranges shared by approved append, pin survival and eviction; approved append requires a checked existing GROWTH document and preserves authored content |

// Approved lessons append as standalone paragraphs to canonical GROWTH.md.
// The writer preserves the approved text and existing hand-authored headings;
// it does not derive a heading from the lesson.
public enum REMGrowthWriter {

    public struct InvalidLesson: Error, LocalizedError {
        public let reason: String
        public var errorDescription: String? {
            "REM growth lesson refused: \(reason)"
        }
    }

    /// Matches text only at line or document boundaries, never inside a longer paragraph.
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
            // Overlapping matches can contain another standalone paragraph.
            searchFrom = body.index(after: range.lowerBound)
        }
        return ranges
    }

    /// Append an approved REM lesson to `<personaRoot>/GROWTH.md` under the
    /// same cross-process flock every other GROWTH writer holds. Idempotent:
    /// when the doc already contains the exact proposal text as its own
    /// entry paragraph (a reconcile re-fire after a crash window, or a
    /// manual backfill) nothing is written and `false` returns. A missing or
    /// unreadable GROWTH.md throws with its path and repair remedy before any
    /// write, so the caller's approval never flips. Returns `true` when the entry landed.
    @discardableResult
    public static func appendApprovedLesson(
        personaRoot: URL,
        proposalText: String
    ) async throws -> Bool {
        let text = proposalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw InvalidLesson(reason: "empty lesson") }
        // Pending approvals can predate the staging bound. Enforce it again
        // at the write boundary before any existing persona content changes.
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
