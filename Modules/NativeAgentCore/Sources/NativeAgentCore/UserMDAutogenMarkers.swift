// The ONE definition of USER.md's section markers.
//
// Three subsystems read or write these strings and none of them can import
// the others:
//
//   * MemoryV2 (`UserMDGenerator`)      — writes them
//   * Context  (`ContextMarkdownCompiler`) — cuts per-fact atoms inside them
//   * Context  (`ContextFlowCoordinator`)  — decides precoverage from them
//
// They used to be three independent literals. A literal that drifts here does
// not fail loudly: the generator keeps writing, the compiler silently stops
// atomizing, and precoverage silently stops applying. Same class of bug as
// `MemoryDisplayText` — two renderers of one string compared for equality —
// so it gets the same treatment: one owner, in the base target both sides
// already depend on.

import Foundation

// Blueprint: | `UserMDAutogenMarkers.swift` | `UserMDAutogenMarkers`: one USER.md section marker vocabulary and shared prompt/pinned-section handling |

public enum UserMDAutogenMarkers {
    /// Opens the human-edited preamble that generation must preserve.
    public static let preambleStart = "<!-- USER_PREAMBLE_START -->"
    /// Closes the human-edited preamble.
    public static let preambleEnd = "<!-- USER_PREAMBLE_END -->"
    /// Opens the machine-generated fact body.
    public static let bodyStart = "<!-- USER_MD_AUTOGEN_START -->"
    /// Closes the machine-generated fact body.
    public static let bodyEnd = "<!-- USER_MD_AUTOGEN_END -->"

    /// Includes the renderer's `# USER\n` heading. Nil core preserves the
    /// whole document until the first pin; an empty core carries only prose.
    public static let promptByteCap = 3_500

    public static func promptText(_ document: String, pinnedCore: [String]?) -> String {
        guard let pinnedCore else { return document }
        let carried = carry(document, pinnedCore: pinnedCore)
        return ([carried.preamble].filter { !$0.isEmpty } + carried.facts.map { "- " + $0 })
            .joined(separator: "\n\n")
    }

    /// The pinned facts `promptText` carries (same order, same cap), as their
    /// own section for the turn's dynamic tail. The stable segment holds only
    /// what changes when her documents change; what memory adds rides after.
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
