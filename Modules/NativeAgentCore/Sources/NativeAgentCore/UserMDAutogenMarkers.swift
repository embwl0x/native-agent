// Generation, atomization and precoverage must share exact section markers; spelling drift silently disables derived context coverage.

import Foundation

// Blueprint: | `UserMDAutogenMarkers.swift` | `UserMDAutogenMarkers`, `promptByteCap`: markers and picture bound |

public enum UserMDAutogenMarkers {
    public static let preambleStart = "<!-- USER_PREAMBLE_START -->"
    public static let preambleEnd = "<!-- USER_PREAMBLE_END -->"
    public static let bodyStart = "<!-- USER_MD_AUTOGEN_START -->"
    public static let bodyEnd = "<!-- USER_MD_AUTOGEN_END -->"

    /// The person picture rides every turn, so cap UTF-8 bytes at recall's floor allowance: five rows of 1,200 characters. Keep this bound aligned with
    /// ContextBudgetPolicy.floorRecallRowLimit and floorMemoryRowChars, which this target cannot import. Excess facts remain in memory; only carried facts are
    /// precovered. Nil core preserves the whole document until the first pin; empty core carries only prose.
    public static let promptByteCap = 5 * 1_200

    public static func promptText(_ document: String, pinnedCore: [String]?) -> String {
        guard let pinnedCore else { return document }
        let carried = carry(document, pinnedCore: pinnedCore)
        return ([carried.preamble].filter { !$0.isEmpty } + carried.facts.map { "- " + $0 })
            .joined(separator: "\n\n")
    }

    /// The pinned facts `promptText` carries (same order, same cap), as their own section for the turn's dynamic tail. The stable segment holds only what
    /// changes when the agent's documents change; what memory adds rides after.
    public static func pinnedSection(_ document: String, pinnedCore: [String]?) -> String {
        guard let pinnedCore else { return "" }
        let facts = carry(document, pinnedCore: pinnedCore).facts
        return facts.isEmpty ? "" : "# USER (pinned)\n" + facts.map { "- " + $0 }.joined(separator: "\n\n")
    }

    private static func carry(_ document: String, pinnedCore: [String]) -> (preamble: String, facts: [String]) {
        let preamble: String
        if let start = document.range(of: preambleStart),
           let end = document.range(of: preambleEnd, range: start.upperBound..<document.endIndex) {
            preamble = String(document[start.upperBound..<end.lowerBound])
        } else if let start = document.range(of: bodyStart) {
            preamble = String(document[..<start.lowerBound])
        } else {
            preamble = document
        }
        let budget = promptByteCap - "# USER\n".utf8.count
        var result = ""
        var facts: [String] = []
        var bytes = 0
        for character in preamble.trimmingCharacters(in: .whitespacesAndNewlines) {
            let size = String(character).utf8.count
            guard bytes + size <= budget else { break }
            result.append(character)
            bytes += size
        }
        for fact in pinnedCore {
            let size = (result.isEmpty && facts.isEmpty ? 0 : 2) + "- ".utf8.count + fact.utf8.count
            guard bytes + size <= budget else { break }
            facts.append(fact)
            bytes += size
        }
        return (result, facts)
    }
}
