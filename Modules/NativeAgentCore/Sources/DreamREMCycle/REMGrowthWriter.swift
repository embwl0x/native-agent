import Foundation
import PersistenceCore

// Blueprint: | `REMGrowthWriter.swift` | Exact standalone-paragraph ranges shared by approved append, pin survival and eviction; append preserves authored headings |

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

    /// An unready persona root has neither SOUL.md nor GROWTH.md; writing there would bypass onboarding.
    public struct PersonaRootUnready: Error, CustomStringConvertible {
        public let path: String
        public var description: String {
            "REMGrowthWriter: \(path) has neither SOUL.md nor GROWTH.md — "
            + "refusing to mint a GROWTH.md outside a real persona root."
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
    /// manual backfill) nothing is written and `false` returns. A missing
    /// GROWTH.md is created ONLY when the root carries a SOUL.md (a real
    /// persona root mid-migration); an unready root throws so the caller's
    /// approval never flips. Returns `true` when the entry landed.
    @discardableResult
    public static func appendApprovedLesson(
        personaRoot: URL,
        proposalText: String
    ) async throws -> Bool {
        let text = proposalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        // Pending approvals can predate the staging bound. Enforce it again
        // at the write boundary before any existing persona content changes.
        if let reason = REMProposalStore.growthPassageRefusal(text) {
            throw InvalidLesson(reason: reason)
        }
        let growth = personaRoot.appendingPathComponent("GROWTH.md")
        let fm = FileManager.default
        if !fm.fileExists(atPath: growth.path),
           !fm.fileExists(atPath: personaRoot.appendingPathComponent("SOUL.md").path) {
            throw PersonaRootUnready(path: personaRoot.path)
        }
        return try await SwiftNativePersistenceCore.withFileLock(growth) {
            // Only a missing file starts a new document; other read failures abort the append.
            let body: String
            do {
                body = try String(contentsOf: growth, encoding: .utf8)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                body = ""
            }
            if containsEntryParagraph(body, text) { return false }
            let entry = "\n\(text)\n"
            let rebuilt = body.isEmpty
                ? "# GROWTH.md\n" + entry
                : (body.hasSuffix("\n") ? body + entry : body + "\n" + entry)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(rebuilt.utf8), to: growth)
            return true
        }
    }
}
