// The ONE definition of USER.md's section markers.
//
// Three subsystems read or write these strings and none of them can import
// the others:
//
//   * MemoryV2 (`UserMDGenerator`)      — writes them
//   * Context  (`ContextMarkdownCompiler`) — cuts per-fact atoms inside them
//   * Context  (`ContextPreparation`)  — decides precoverage from them
//
// They used to be three independent literals. A literal that drifts here does
// not fail loudly: the generator keeps writing, the compiler silently stops
// atomizing, and precoverage silently stops applying. Same class of bug as
// `MemoryDisplayText` — two renderers of one string compared for equality —
// so it gets the same treatment: one owner, in the base target both sides
// already depend on.

import Foundation

// Blueprint: | `UserMDAutogenMarkers.swift` | `UserMDAutogenMarkers`: one USER.md section marker vocabulary and shared prompt/pinned-section handling; `promptByteCap`, the person picture's bound (one floor turn's recall memory) |

public enum UserMDAutogenMarkers {
    /// Opens the human-edited preamble that generation must preserve.
    public static let preambleStart = "<!-- USER_PREAMBLE_START -->"
    /// Closes the human-edited preamble.
    public static let preambleEnd = "<!-- USER_PREAMBLE_END -->"
    /// Opens the machine-generated fact body.
    public static let bodyStart = "<!-- USER_MD_AUTOGEN_START -->"
    /// Closes the machine-generated fact body.
    public static let bodyEnd = "<!-- USER_MD_AUTOGEN_END -->"

    /// THE BOUND on the person picture, in UTF-8 bytes, including the
    /// renderer's `# USER\n` heading. The picture rides every turn, so it takes
    /// what one turn carries of memory at the floor window every model clears:
    /// recall's floor of 5 rows of 1,200 characters
    /// (`ContextBudgetPolicy.floorRecallRowLimit` × `floorMemoryRowChars`,
    /// which this base target cannot import; change them together). Bytes,
    /// not characters, so it never exceeds that allowance. Was 3,500 (no
    /// stated derivation); 10-27 the picture admits every person kind, and
    /// her person facts (about 3.7 KB once her generic saves are classified)
    /// no longer fit it, newest first, so the oldest (the email preference)
    /// would have fallen out. Facts past the bound are not lost: they stay
    /// in the memory lane (`ContextPreparation` precovers only the facts
    /// carried). Nil core preserves the whole document until the first pin;
    /// an empty core carries only prose.
    public static let promptByteCap = 5 * 1_200

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
